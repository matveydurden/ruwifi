"""Exercise the actual bundled core without installing routes or changing DNS."""
import json, pathlib, socket, struct, subprocess, tempfile, time, urllib.request, sys

def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0)); return s.getsockname()[1]

def dns(name, qtype, number):
    packet=struct.pack('!HHHHHH',0x4a32,0x0100,1,0,0,0)
    packet+=b''.join(bytes([len(x)])+x.encode() for x in name.split('.'))+b'\x00'+struct.pack('!HH',qtype,1)
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
        s.settimeout(3);s.sendto(packet,('127.0.0.1',number));return s.recv(4096)

core=str(pathlib.Path(sys.argv[1]).resolve())
config=json.loads(pathlib.Path('.build/config-test.json').read_text())
with tempfile.TemporaryDirectory(prefix='ruwifi-core-') as temp:
    dnsport,apiport,mixedport=port(),port(),port()
    config['inbounds']=[{'type':'direct','tag':'dns-in','listen':'127.0.0.1','listen_port':dnsport},{'type':'mixed','tag':'test','listen':'127.0.0.1','listen_port':mixedport}]
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
            for name in ['example.ru','a.b.c.example.ru','SITE.RU']:
                answer=dns(name,1,dnsport)
                assert struct.unpack('!H',answer[6:8])[0]==1,name
                assert answer[-4:-2]==bytes([198,19]),(name,answer.hex())
            answer=dns('a.b.example.ru',65,dnsport)
            assert answer[3]&15==0 and struct.unpack('!H',answer[6:8])[0]==0,'HTTPS hints must not bypass FakeIP'
            for name in ['Wi-Fi','Default','Wi-Fi']:
                api('/proxies/RU',{'name':name})
                assert json.loads(api('/proxies/RU'))['now']==name
            request=subprocess.run(['curl','--proxy',f'socks5h://127.0.0.1:{mixedport}','--noproxy','','--connect-timeout','5','--max-time','15','-I','-sS','-o','/dev/null','-w','%{http_code}','https://ya.ru'],capture_output=True,text=True)
            assert request.returncode==0,(request.stdout,request.stderr)
            remembered=dns('persistent.example.ru',1,dnsport)[-4:]
            api('/proxies/RU',{'name':'Default'})
            process.terminate(); process.wait(timeout=3)
            config['experimental']['cache_file']['cache_id']='fresh-start'
            pathlib.Path(temp+'/config.json').write_text(json.dumps(config))
            process=subprocess.Popen([core,'run','-c',temp+'/config.json'],stdout=log,stderr=log)
            for _ in range(40):
                try:api('/version');break
                except OSError:time.sleep(.1)
            assert json.loads(api('/proxies/RU'))['now']=='Wi-Fi','cold start must ignore stale selector cache'
            assert dns('persistent.example.ru',1,dnsport)[-4:]==remembered,'cold start lost cached FakeIP mapping'
            api('/proxies/RU',{'name':'Default'})
            process.kill(); process.wait(timeout=3)
            process=subprocess.Popen([core,'run','-c',temp+'/config.json'],stdout=log,stderr=log)
            for _ in range(40):
                try:api('/version');break
                except OSError:time.sleep(.1)
            assert json.loads(api('/proxies/RU'))['now']=='Default','crash restart lost applied Off state'
            assert dns('persistent.example.ru',1,dnsport)[-4:]==remembered,'crash restart lost FakeIP mapping'
            process.terminate();process.wait(timeout=3)
            for outbound in config['outbounds']:
                if outbound.get('tag')=='Wi-Fi':outbound['bind_interface']='en9999'
            pathlib.Path(temp+'/config.json').write_text(json.dumps(config))
            process=subprocess.Popen([core,'run','-c',temp+'/config.json'],stdout=log,stderr=log)
            for _ in range(40):
                try:api('/version');break
                except OSError:time.sleep(.1)
            api('/proxies/RU',{'name':'Wi-Fi'})
            failed=subprocess.run(['curl','--proxy',f'socks5h://127.0.0.1:{mixedport}','--noproxy','','--connect-timeout','2','--max-time','4','-I','-sS','https://ya.ru'],capture_output=True,text=True)
            assert failed.returncode!=0,'missing Wi-Fi unexpectedly fell back to default/VPN'
            print('PASS: cold startup, abrupt core crash/cache persistence, missing Wi-Fi without fallback')
            print('PASS: real core DNS for nested .ru names, HTTPS hint suppression, live selector switches and HTTPS via Wi-Fi')
        except Exception:
            log.flush();log.seek(0);print(log.read()[-5000:]);raise
        finally:
            process.terminate()
            try:process.wait(timeout=3)
            except subprocess.TimeoutExpired:process.kill();process.wait()
