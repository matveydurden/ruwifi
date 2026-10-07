"""Exercise the actual bundled core without installing routes or using the internet."""
import json, pathlib, socket, struct, subprocess, tempfile, time, urllib.request, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0)); return s.getsockname()[1]

def dns(name, qtype, number):
    packet=struct.pack('!HHHHHH',0x4a32,0x0100,1,0,0,0)
    packet+=b''.join(bytes([len(x)])+x.encode() for x in name.split('.'))+b'\x00'+struct.pack('!HH',qtype,1)
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
        s.settimeout(3);s.sendto(packet,('127.0.0.1',number));return s.recv(4096)

class LocalDns:
    """Tiny loopback DNS fixture; every A query resolves to the local HTTP fixture."""
    def __init__(self, address, target_ip):
        self.address = address
        self.target_ip = socket.inet_aton(target_ip)
        self.stop = threading.Event()
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def _serve(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind(self.address)
            self.ready.set()
            sock.settimeout(.2)
            while not self.stop.is_set():
                try:
                    packet, peer = sock.recvfrom(4096)
                except socket.timeout:
                    continue
                if len(packet) < 12:
                    continue
                answer = packet[:2] + b'\x81\x80' + packet[4:6] + b'\x00\x01\x00\x00\x00\x00'
                question_end = 12
                while question_end < len(packet) and packet[question_end]:
                    question_end += packet[question_end] + 1
                question_end += 5
                question = packet[12:question_end]
                answer += question + b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04' + self.target_ip
                sock.sendto(answer, peer)

    def __enter__(self):
        self.thread.start()
        if not self.ready.wait(timeout=1):
            raise RuntimeError('local DNS fixture failed to bind')
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(timeout=1)

class LocalHttp(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'RUWiFi local integration fixture\n'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass

core=str(pathlib.Path(sys.argv[1]).resolve())
config=json.loads(pathlib.Path('.build/config-test.json').read_text())
with tempfile.TemporaryDirectory(prefix='ruwifi-core-') as temp:
    dnsport,apiport,mixedport,upstream_dnsport,httpport=port(),port(),port(),port(),port()
    fixture_ip='127.0.0.1'
    httpserver = ThreadingHTTPServer((fixture_ip, httpport), LocalHttp)
    httpthread = threading.Thread(target=httpserver.serve_forever, daemon=True)
    httpthread.start()
    local_dns = LocalDns(('127.0.0.1', upstream_dnsport), fixture_ip)
    local_dns.__enter__()
    config['inbounds']=[{'type':'direct','tag':'dns-in','listen':'127.0.0.1','listen_port':dnsport},{'type':'mixed','tag':'test','listen':'127.0.0.1','listen_port':mixedport}]
    # Keep this test entirely offline. Production still uses the configured Wi-Fi DNS;
    # this fixture only replaces both upstream resolvers for the child core process.
    fake_server=next(server for server in config['dns']['servers'] if server.get('type')=='fakeip')
    config['dns']['servers']=[fake_server,{'type':'udp','tag':'wifi-dns','server':'127.0.0.1','server_port':upstream_dnsport},{'type':'udp','tag':'ordinary-dns','server':'127.0.0.1','server_port':upstream_dnsport}]
    config['dns']['final']='ordinary-dns'
    for outbound in config['outbounds']:
        if outbound.get('tag')=='Wi-Fi': outbound['bind_interface']='lo0'
    config['experimental']['cache_file']['path']=temp+'/cache.db'
    config['experimental']['clash_api']={'external_controller':f'127.0.0.1:{apiport}','secret':'integration-only'}
    pathlib.Path(temp+'/config.json').write_text(json.dumps(config))
    with open(temp+'/core.log','w+') as log:
        process=subprocess.Popen([core,'run','-c',temp+'/config.json'],stdout=log,stderr=log)
        def api(path,body=None):
            payload=json.dumps(body).encode() if body is not None else None
            request=urllib.request.Request(f'http://127.0.0.1:{apiport}'+path,data=payload,method='PUT' if body is not None else 'GET',headers={'Authorization':'Bearer integration-only','Content-Type':'application/json'})
            return urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request,timeout=2).read()
        try:
            for _ in range(40):
                if process.poll() is not None:raise RuntimeError('core exited')
                try:api('/version');break
                except OSError:time.sleep(.1)
            idn_names=['www.xn--80aa3anexr8c.xn--p1acf','a.b.xn--80aa3anexr8c.xn--p1acf','xn--e1afmkfd.xn--p1ai','a.b.xn--e1afmkfd.xn--p1ai','WWW.XN--80AA3ANEXR8C.XN--P1ACF','XN--E1AFMKFD.XN--P1AI']
            beget_names=['beget.com','cp.beget.com','a.b.beget.com','CP.BEGET.COM','beget.com.ru']
            for name in ['example.ru','a.b.c.example.ru','SITE.RU','1cfresh.com','msk1.1cfresh.com','a.b.1cfresh.com','1cfresh.com.ru']+idn_names+beget_names:
                answer=dns(name,1,dnsport)
                assert struct.unpack('!H',answer[6:8])[0]==1,name
                assert answer[-4:-2]==bytes([198,19]),(name,answer.hex())
            for name in ['1cfresh.com','a.b.1cfresh.com']+idn_names+beget_names:
                answer=dns(name,28,dnsport)
                assert struct.unpack('!H',answer[6:8])[0]==1 and answer[-16:-10]==bytes.fromhex('fd7a72757769'), 'AAAA must use the owned FakeIP range'
            for name in ['example.com','evil1cfresh.com','1cfresh.com.evil','site.xn--p1acf.com','site.xn--p1ai.com','sitexn--p1ai','site.xn--p1acfe','site.xn--90ais','xn--e1afmkfd.com','notbeget.com','beget.com.evil','cp.beget.com.evil']:
                answer=dns(name,1,dnsport)
                assert answer[-4:]==socket.inet_aton('127.0.0.1'), 'unrelated name incorrectly captured: '+name
            for name in ['a.b.example.ru','1cfresh.com','msk1.1cfresh.com']+idn_names+beget_names:
                for qtype in [64,65]:
                    answer=dns(name,qtype,dnsport)
                    assert answer[3]&15==0 and struct.unpack('!H',answer[6:8])[0]==0,'HTTPS/SVCB hints must not bypass FakeIP: '+name
            for name in ['Wi-Fi','Default','Wi-Fi']:
                api('/proxies/RU',{'name':name})
                assert json.loads(api('/proxies/RU'))['now']==name
                for host in ['cp.beget.com','msk1.1cfresh.com','www.xn--80aa3anexr8c.xn--p1acf','a.b.xn--e1afmkfd.xn--p1ai']:
                    request=subprocess.run(['curl','--proxy',f'socks5h://127.0.0.1:{mixedport}','--noproxy','','--connect-timeout','2','--max-time','5','-fsS',f'http://{host}:{httpport}/health'],capture_output=True,text=True)
                    assert request.returncode==0 and request.stdout=='RUWiFi local integration fixture\n', (name,host,request.stderr)
            request=subprocess.run(['curl','--proxy',f'socks5h://127.0.0.1:{mixedport}','--noproxy','','--connect-timeout','5','--max-time','15','-fsS',f'http://fixture.1cfresh.com:{httpport}/health'],capture_output=True,text=True)
            assert request.returncode==0,(request.stdout,request.stderr)
            assert request.stdout=='RUWiFi local integration fixture\n',request.stdout
            remembered=dns('persistent.1cfresh.com',1,dnsport)[-4:]
            api('/proxies/RU',{'name':'Default'})
            process.terminate(); process.wait(timeout=3)
            config['experimental']['cache_file']['cache_id']='fresh-start'
            pathlib.Path(temp+'/config.json').write_text(json.dumps(config))
            process=subprocess.Popen([core,'run','-c',temp+'/config.json'],stdout=log,stderr=log)
            for _ in range(40):
                try:api('/version');break
                except OSError:time.sleep(.1)
            assert json.loads(api('/proxies/RU'))['now']=='Wi-Fi','cold start must ignore stale selector cache'
            assert dns('persistent.1cfresh.com',1,dnsport)[-4:]==remembered,'cold start lost cached FakeIP mapping'
            api('/proxies/RU',{'name':'Default'})
            process.kill(); process.wait(timeout=3)
            process=subprocess.Popen([core,'run','-c',temp+'/config.json'],stdout=log,stderr=log)
            for _ in range(40):
                try:api('/version');break
                except OSError:time.sleep(.1)
            assert json.loads(api('/proxies/RU'))['now']=='Default','crash restart lost applied Off state'
            assert dns('persistent.1cfresh.com',1,dnsport)[-4:]==remembered,'crash restart lost FakeIP mapping'
            process.terminate();process.wait(timeout=3)
            for outbound in config['outbounds']:
                if outbound.get('tag')=='Wi-Fi':
                    outbound['bind_interface']='en9999'
                    # Darwin permits loopback connections even with an invalid
                    # interface name. An unassigned source address exercises
                    # a failed bound outbound without leaving this machine.
                    outbound['inet4_bind_address']='192.0.2.1'
            pathlib.Path(temp+'/config.json').write_text(json.dumps(config))
            process=subprocess.Popen([core,'run','-c',temp+'/config.json'],stdout=log,stderr=log)
            for _ in range(40):
                try:api('/version');break
                except OSError:time.sleep(.1)
            api('/proxies/RU',{'name':'Wi-Fi'})
            failed=subprocess.run(['curl','--proxy',f'socks5h://127.0.0.1:{mixedport}','--noproxy','','--connect-timeout','2','--max-time','4','-fsS',f'http://fixture.1cfresh.com:{httpport}/health'],capture_output=True,text=True)
            assert failed.returncode!=0,'unavailable outbound unexpectedly fell back to default/VPN'
            print('PASS: cold startup, abrupt core crash/cache persistence, unavailable outbound without fallback')
            print('PASS: real core DNS for .ru, .рус, .рф, 1cfresh.com and beget.com boundaries, HTTPS hint suppression, live selector switches and local HTTP with interface binding')
        except Exception:
            log.flush();log.seek(0);print(log.read()[-5000:]);raise
        finally:
            process.terminate()
            try:process.wait(timeout=3)
            except subprocess.TimeoutExpired:process.kill();process.wait()
            httpserver.shutdown(); httpserver.server_close(); local_dns.__exit__()
