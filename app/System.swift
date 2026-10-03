import Foundation
import Darwin
import CryptoKit

let serviceLabel = "local.matvey.RUWiFi.Service"
let runtimeRoot = "/Library/Application Support/RUWiFi"
let installedHelper = "/Library/PrivilegedHelperTools/local.matvey.RUWiFi.Helper"
let installedEngine = "/Library/PrivilegedHelperTools/local.matvey.RUWiFi.Engine"
let engineLabel = "local.matvey.RUWiFi.Engine"
let enginePlist = runtimeRoot + "/engine.plist"
let daemonPlist = "/Library/LaunchDaemons/" + serviceLabel + ".plist"
let installedApp = "/Applications/RU напрямую.app"
let resolverPath = "/private/etc/resolver/ru"
let resolverData = Data("# Managed by RUWiFi\nnameserver 127.0.0.1\nport 15453\ntimeout 2\nsearch_order 1\n".utf8)

struct Identity: Codable { var uid: UInt32; var name: String; var home: String }
func identity(_ uid: UInt32) throws -> Identity {
    guard uid >= 501, let entry = getpwuid(uid), let name = entry.pointee.pw_name, let home = entry.pointee.pw_dir else { throw appError("Не удалось определить пользователя") }
    return Identity(uid: uid, name: String(cString: name), home: String(cString: home))
}
func policyPath(_ user: Identity) -> String { user.home + "/Library/Application Support/RUWiFi/preferences.json" }
func buildIdentity(helper: String, engine: String) -> String { checksum(Data((helper + engine).utf8)) }
func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func readPreferences(_ user: Identity) throws -> Preferences {
    try JSONDecoder().decode(Preferences.self, from: checkedRead(policyPath(user), owner: user.uid))
}
func savePreferences(_ value: Preferences, user: Identity, expected: String? = nil) throws {
    let parent = URL(fileURLWithPath: policyPath(user)).deletingLastPathComponent().path
    try ensureDirectory(parent, mode: 0o700)
    let fd = open(parent + "/lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw appError("Не удалось заблокировать настройки") }; defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw appError("Настройки уже меняются") }
    if let expected { guard try readPreferences(user).generation == expected else { throw appError("Настройки изменились. Повторите действие.") } }
    try writeJSON(value, policyPath(user))
}

struct NetworkInfo {
    var wifi: String
    var wifiActive: Bool
    var vpnConnected: Bool
    static func read() throws -> NetworkInfo {
        let hardware = try run("/usr/sbin/networksetup", ["-listallhardwareports"])
        let block = hardware.components(separatedBy: "\n\n").first { $0.contains("Hardware Port: Wi-Fi") } ?? ""
        let wifi = block.components(separatedBy: "\n").first { $0.hasPrefix("Device: ") }?.replacingOccurrences(of: "Device: ", with: "") ?? ""
        guard wifi.range(of: "^en[0-9]+$", options: .regularExpression) != nil else { throw appError("Интерфейс Wi-Fi не найден") }
        let description = try run("/sbin/ifconfig", [wifi])
        let vpn = try run("/usr/sbin/scutil", ["--nc", "list"])
        return NetworkInfo(wifi: wifi, wifiActive: description.contains("status: active") && description.contains("inet "),
            vpnConnected: vpn.components(separatedBy: "\n").contains { $0.contains("(Connected)") && $0.contains("hidemyname.vpn") })
    }
}

final class DNSSettings {
    let user: Identity
    let resolver = OwnedFile(resolverPath, journal: runtimeRoot + "/resolver-journal.json")
    var chromePath: String { "/Library/Managed Preferences/" + user.name + "/com.google.Chrome.plist" }
    var chrome: OwnedFile { OwnedFile(chromePath, journal: runtimeRoot + "/chrome-journal.json") }
    init(_ user: Identity) { self.user = user }
    func enable() throws {
        try ensureDirectory("/private/etc/resolver")
        try ensureDirectory("/Library/Managed Preferences")
        try ensureDirectory("/Library/Managed Preferences/" + user.name)
        let baseline: Data?
        if let journal = try optionalFile(runtimeRoot + "/chrome-journal.json") {
            baseline = try JSONDecoder().decode(OwnedFileRecord.self, from: journal).original
        } else { baseline = try optionalFile(chromePath) }
        var plist: [String: Any] = [:]
        if let baseline {
            guard let original = try PropertyListSerialization.propertyList(from: baseline, format: nil) as? [String: Any] else { throw appError("Некорректные настройки Chrome") }
            plist = original
        }
        plist["DnsOverHttpsMode"] = "off"
        plist["BuiltInDnsClientEnabled"] = false
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let changed = try optionalFile(chromePath) != data || optionalFile(resolverPath) != resolverData
        try chrome.apply(data)
        try resolver.apply(resolverData)
        if changed { refresh() }
    }
    func disable() throws {
        let changed = FileManager.default.fileExists(atPath: runtimeRoot + "/resolver-journal.json") || FileManager.default.fileExists(atPath: runtimeRoot + "/chrome-journal.json")
        var problems: [String] = []
        do { try resolver.restore() } catch { problems.append(error.localizedDescription) }
        do { try chrome.restore() } catch { problems.append(error.localizedDescription) }
        if changed { refresh() }
        if !problems.isEmpty { throw appError(problems.joined(separator: "\n")) }
    }
    func refresh() {
        _ = try? run("/usr/bin/dscacheutil", ["-flushcache"])
        // cfprefsd caches managed preferences; this targets only the owning user's cache daemon.
        _ = try? run("/usr/bin/killall", ["-u", user.name, "cfprefsd"])
    }
}

final class EngineControl {
    let secret: String
    init(secret: String) { self.secret = secret }
    var pid: Int32? {
        guard let text = try? run("/bin/launchctl", ["print", "system/" + engineLabel]), text.contains("state = running") else { return nil }
        return text.components(separatedBy: "\n").compactMap { line -> Int32? in
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
            return parts.count == 2 && parts[0] == "pid" ? Int32(parts[1]) : nil
        }.first
    }
    func loaded() -> Bool { (try? run("/bin/launchctl", ["print", "system/" + engineLabel])) != nil }
    func validateJob() throws {
        guard let data = try optionalFile(enginePlist), let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == engineLabel,
              plist["ProgramArguments"] as? [String] == [installedEngine, "run", "-c", runtimeRoot + "/engine.json"] else { throw appError("Неизвестный владелец сетевой службы") }
    }
    func api(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:15454" + path)!)
        request.httpMethod = method; request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        session.dataTask(with: request) { data, response, error in
            if let error { result = .failure(error) }
            else if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) { result = .success(data ?? Data()) }
            else { result = .failure(appError("Движок отклонил команду")) }
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 4) == .success, let result else { throw appError("Движок не отвечает") }
        return try result.get()
    }
    func select(_ enabled: Bool) throws {
        let selected = enabled ? "Wi-Fi" : "Default"
        let state = try JSONSerialization.jsonObject(with: api("/proxies/RU")) as? [String: Any]
        if state?["now"] as? String != selected { _ = try api("/proxies/RU", method: "PUT", body: ["name": selected]) }
        let checked = try JSONSerialization.jsonObject(with: api("/proxies/RU")) as? [String: Any]
        guard checked?["now"] as? String == selected else { throw appError("Маршрут не применён") }
    }
    func ensure(wifi: String, initiallyEnabled: Bool) throws {
        let object = try RoutingConfiguration.make(wifi: wifi, cache: runtimeRoot + "/fakeip.db", secret: secret)
        let desired = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if loaded() {
            try validateJob()
            if let currentData = try optionalFile(runtimeRoot + "/engine.json"), var current = try JSONSerialization.jsonObject(with: currentData) as? [String: Any],
               var outbounds = current["outbounds"] as? [[String: Any]], !outbounds.isEmpty {
                outbounds[0]["default"] = "Wi-Fi"; current["outbounds"] = outbounds
                if var experimental = current["experimental"] as? [String: Any], var cache = experimental["cache_file"] as? [String: Any] {
                    cache.removeValue(forKey: "cache_id"); experimental["cache_file"] = cache; current["experimental"] = experimental
                }
                if try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]) == desired {
                    _ = try api("/version"); return
                }
            }
            try stop()
        }
        var startup = object
        // Selected-outbound cache is scoped; FakeIP mappings remain global in sing-box 1.14.2.
        // A cold start must follow current preferences rather than an old cached selection.
        var experimental = startup["experimental"] as! [String: Any]
        var cache = experimental["cache_file"] as! [String: Any]
        cache["cache_id"] = UUID().uuidString; experimental["cache_file"] = cache; startup["experimental"] = experimental
        var outbounds = startup["outbounds"] as! [[String: Any]]
        outbounds[0]["default"] = initiallyEnabled ? "Wi-Fi" : "Default"; startup["outbounds"] = outbounds
        try durableWrite(JSONSerialization.data(withJSONObject: startup, options: [.sortedKeys]), to: runtimeRoot + "/engine.json")
        _ = try run(installedEngine, ["check", "-c", runtimeRoot + "/engine.json"])
        let logPath = runtimeRoot + "/engine.log"
        if let attributes = try? FileManager.default.attributesOfItem(atPath: logPath), let size = attributes[.size] as? NSNumber, size.intValue > 2_000_000 { try durableWrite(Data(), to: logPath) }
        if !FileManager.default.fileExists(atPath: logPath) { try durableWrite(Data(), to: logPath) }
        let plist: [String: Any] = ["Label": engineLabel, "ProgramArguments": [installedEngine, "run", "-c", runtimeRoot + "/engine.json"],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 2, "ProcessType": "Background", "Umask": 0o077,
            "StandardOutPath": logPath, "StandardErrorPath": logPath]
        try durableWrite(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: enginePlist, mode: 0o644)
        _ = try run("/bin/launchctl", ["enable", "system/" + engineLabel])
        _ = try run("/bin/launchctl", ["bootstrap", "system", enginePlist])
        for _ in 0..<25 {
            if (try? api("/version")) != nil { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw appError("Сетевой движок не запустился. macOS повторит запуск автоматически.")
    }
    func stop() throws {
        if loaded() { try validateJob(); _ = try run("/bin/launchctl", ["bootout", "system/" + engineLabel], timeout: 10) }
    }

}

// Cover a larger reserved prefix than the TUN. If the engine dies, cached FakeIP
// traffic hits this reject route rather than escaping through the VPN default.
func ensureGuards() throws {
    for (family, prefix, sample, gateway) in [("-inet", "198.18.0.0/15", "198.18.0.1", "127.0.0.1"), ("-inet6", "fd7a:7275::/32", "fd7a:7275::1", "::1")] {
        let current = (try? run("/sbin/route", ["-n", "get", family, sample])) ?? ""
        if current.contains("REJECT") && current.contains("interface: lo0") { continue }
        if current.contains("destination: 198.18.0.0") || current.contains("destination: fd7a:7275::") { throw appError("Диапазон маршрутов уже занят другим приложением") }
        _ = try run("/sbin/route", ["-n", "add", family, "-net", prefix, gateway, "-reject"])
    }
}

// Retire the previously installed, independently scheduled route writer. Its files
// stay intact; only routes listed in its own state and still matching are removed.
final class LegacyRetirement {
    let label = "com.codex.eis-split-tunnel"
    let plist = "/Library/LaunchDaemons/com.codex.eis-split-tunnel.plist"
    let receipt = runtimeRoot + "/legacy-retired.json"
    var changed = false, wasLoaded = false, wasDisabled = false
    var removed: [String] = [], gateway = "", wifi = ""
    func retire() throws {
        if try optionalFile(receipt) != nil || !FileManager.default.fileExists(atPath: plist) { return }
        let script = try checkedRead("/usr/local/sbin/eis-split-tunnel", owner: 0)
        guard checksum(script) == "8d1d93f6c30f1109076b155415df474124b987ad3e1869e675815b554a4a1649",
              let job = try PropertyListSerialization.propertyList(from: checkedRead(plist, owner: 0), format: nil) as? [String: Any],
              job["ProgramArguments"] as? [String] == ["/usr/local/sbin/eis-split-tunnel"] else { throw appError("Старая служба маршрутов изменена; автоматический перенос остановлен") }
        wifi = try NetworkInfo.read().wifi
        gateway = try run("/usr/sbin/ipconfig", ["getoption", wifi, "router"]).trimmingCharacters(in: .whitespacesAndNewlines)
        wasLoaded = (try? run("/bin/launchctl", ["print", "system/" + label])) != nil
        let disabled = try run("/bin/launchctl", ["print-disabled", "system"])
        wasDisabled = disabled.contains("\"" + label + "\" => true")
        _ = try run("/bin/launchctl", ["disable", "system/" + label]); changed = true
        if wasLoaded { _ = try run("/bin/launchctl", ["bootout", "system/" + label], timeout: 10) }
        let state = try optionalFile("/private/var/db/eis-split-tunnel.ips") ?? Data()
        let ips = String(data: state, encoding: .utf8)?.components(separatedBy: .newlines).filter { !$0.isEmpty } ?? []
        for ip in Set(ips) {
            var address = in_addr()
            guard inet_pton(AF_INET, ip, &address) == 1 else { throw appError("Некорректный журнал старой службы") }
            let route = try run("/sbin/route", ["-n", "get", ip])
            if ownsLegacyRoute(route, ip: ip, gateway: gateway, wifi: wifi) {
                removed.append(ip)
                try writeJSON(["removed": removed, "gateway": [gateway], "wifi": [wifi]], receipt)
                _ = try run("/sbin/route", ["-n", "delete", "-host", ip, gateway])
            }
        }
        try writeJSON(["removed": removed, "gateway": [gateway], "wifi": [wifi]], receipt)
    }
    func rollback() throws {
        guard changed else { return }
        for ip in removed {
            let route = try run("/sbin/route", ["-n", "get", ip])
            if !route.contains("destination: " + ip) { _ = try run("/sbin/route", ["-n", "add", "-host", ip, gateway]) }
        }
        if !wasDisabled { _ = try run("/bin/launchctl", ["enable", "system/" + label]) }
        if wasLoaded { _ = try run("/bin/launchctl", ["bootstrap", "system", plist]) }
        try removeOwnedFile(receipt)
    }
}

func prepareUserInstallation(_ user: Identity) throws {
    if try optionalFile(policyPath(user)) != nil { _ = try readPreferences(user) }
    else { try savePreferences(Preferences(enabled: true), user: user) }
}

func configureLoginItem(for user: Identity) throws {
    let directory = user.home + "/Library/LaunchAgents"
    try ensureDirectory(directory)
    let plist: [String: Any] = ["Label": "local.matvey.RUWiFi.Login", "ProgramArguments": [installedApp + "/Contents/MacOS/RUWiFi", "--background"], "RunAtLoad": true, "ProcessType": "Interactive"]
    try durableWrite(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: directory + "/local.matvey.RUWiFi.Login.plist", mode: 0o644)
}
