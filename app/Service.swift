import Foundation
import Darwin

@main struct Service {
    static func main() {
        do {
            guard getuid() == 0 else { throw appError("Службе нужны права администратора") }
            let args = CommandLine.arguments
            if args.count == 3, args[1] == "--install", let uid = UInt32(args[2]) { try install(uid: uid); return }
            if args.count == 2, args[1] == "--daemon" { try serve(); return }
            throw appError("Неизвестная команда службы")
        } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    }
    static func install(uid: UInt32) throws {
        let user = try identity(uid)
        _ = try readPreferences(user)
        try ensureDirectory(runtimeRoot)
        try ensureDirectory("/Library/PrivilegedHelperTools")
        try ensureDirectory("/Library/LaunchDaemons")
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let contents = source.appendingPathComponent("Contents")
        var sourceInfo = stat()
        guard lstat(contents.path, &sourceInfo) == 0, sourceInfo.st_uid == uid || sourceInfo.st_uid == 0 else { throw appError("Неверный владелец сборки") }
        let sourceOwner = sourceInfo.st_uid
        let manifestData = try checkedRead(contents.appendingPathComponent("Resources/manifest.json").path, owner: sourceOwner)
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: String] else { throw appError("Нет манифеста сборки") }
        let helper = try checkedRead(contents.appendingPathComponent("Helpers/RUWiFiHelper").path, owner: sourceOwner, limit: 268_435_456)
        let engine = try checkedRead(contents.appendingPathComponent("Helpers/sing-box").path, owner: sourceOwner, limit: 268_435_456)
        guard checksum(helper) == manifest["helper"], checksum(engine) == manifest["engine"] else { throw appError("Сборка изменена: контрольные суммы не совпадают") }
        if let data = try optionalFile(runtimeRoot + "/identity.json") {
            guard try JSONDecoder().decode(Identity.self, from: data).uid == uid else { throw appError("Служба установлена для другого пользователя") }
        }
        if FileManager.default.fileExists(atPath: installedApp) {
            let info = try checkedRead(installedApp + "/Contents/Info.plist", owner: 0)
            let plist = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any]
            guard plist?["CFBundleIdentifier"] as? String == "local.matvey.RUWiFi" else { throw appError("Папка приложения занята") }
        }
        // Reject symlinks in the input bundle before the authorized fixed-path install.
        if let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let file as URL in files {
                guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw appError("Символическая ссылка в сборке") }
            }
        }
        let installLock = open(runtimeRoot + "/install.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard installLock >= 0, flock(installLock, LOCK_EX | LOCK_NB) == 0 else { throw appError("Установка уже выполняется") }
        defer { close(installLock) }
        let stage = "/Applications/.RUWiFi-" + UUID().uuidString + ".app"
        defer { try? FileManager.default.removeItem(atPath: stage) }
        _ = try run("/usr/bin/ditto", [source.path, stage], timeout: 30)
        _ = try run("/usr/sbin/chown", ["-R", "root:wheel", stage], timeout: 15)
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stage])
        let wasLoaded = (try? run("/bin/launchctl", ["print", "system/" + serviceLabel])) != nil
        if wasLoaded { _ = try run("/bin/launchctl", ["bootout", "system/" + serviceLabel], timeout: 10) }
        let legacy = LegacyRetirement()
        var snapshots: [FileSnapshot] = []
        var backup: String?, placedApp = false
        do {
            let oldSecret = (try optionalFile(runtimeRoot + "/api-secret")).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            try EngineControl(secret: oldSecret).stop()
            let settings = DNSSettings(user)
            let paths = [installedHelper, installedEngine, daemonPlist, enginePlist,
                runtimeRoot + "/identity.json", runtimeRoot + "/manifest.json", runtimeRoot + "/api-secret",
                runtimeRoot + "/engine.json", runtimeRoot + "/status.json", runtimeRoot + "/resolver-journal.json",
                runtimeRoot + "/chrome-journal.json", resolverPath, settings.chromePath]
            snapshots = try paths.map { try FileSnapshot($0) }
            try legacy.retire()
            if FileManager.default.fileExists(atPath: installedApp) {
                let previous = runtimeRoot + "/previous-" + UUID().uuidString + ".app"
                guard rename(installedApp, previous) == 0 else { throw appError("Не удалось сохранить предыдущую версию") }
                backup = previous
            }
            guard rename(stage, installedApp) == 0 else { throw appError("Не удалось установить приложение") }
            placedApp = true
            try durableWrite(helper, to: installedHelper, mode: 0o755)
            try durableWrite(engine, to: installedEngine, mode: 0o755)
            try writeJSON(user, runtimeRoot + "/identity.json")
            try durableWrite(manifestData, to: runtimeRoot + "/manifest.json", mode: 0o644)
            if oldSecret.isEmpty { try durableWrite(Data((UUID().uuidString + UUID().uuidString).utf8), to: runtimeRoot + "/api-secret") }
            let plist: [String: Any] = ["Label": serviceLabel, "ProgramArguments": [installedHelper, "--daemon"],
                "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 3, "Umask": 0o077,
                "StandardOutPath": runtimeRoot + "/service.log", "StandardErrorPath": runtimeRoot + "/service.log",
                "ProcessType": "Background"]
            try durableWrite(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: daemonPlist, mode: 0o644)
            guard try checkedRead(installedHelper, owner: 0, limit: 268_435_456) == helper,
                  try checkedRead(installedEngine, owner: 0, limit: 268_435_456) == engine else { throw appError("Установленные файлы не прошли проверку") }
            _ = try run("/bin/launchctl", ["enable", "system/" + serviceLabel])
            _ = try run("/bin/launchctl", ["bootstrap", "system", daemonPlist])
            var ready = false
            for _ in 0..<50 {
                if let data = try optionalFile(runtimeRoot + "/status.json"),
                   let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any], fields["build"] as? String == buildIdentity(helper: checksum(helper), engine: checksum(engine)),
                   let status = try? JSONDecoder().decode(ServiceStatus.self, from: data), Date().timeIntervalSince(status.checked) < 5 {
                    ready = true; break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard ready else { throw appError("Новая служба не подтвердила запуск") }
        } catch {
            let reason = error.localizedDescription
            var rollbackErrors: [String] = []
            func recover(_ operation: () throws -> Void) { do { try operation() } catch { rollbackErrors.append(error.localizedDescription) } }
            if placedApp {
                if (try? run("/bin/launchctl", ["print", "system/" + serviceLabel])) != nil {
                    recover { _ = try run("/bin/launchctl", ["bootout", "system/" + serviceLabel], timeout: 10) }
                }
                recover { try EngineControl(secret: "").stop() }
                for snapshot in snapshots {
                    // Missing parent means this absent file was never created.
                    if snapshot.data == nil && !FileManager.default.fileExists(atPath: URL(fileURLWithPath: snapshot.path).deletingLastPathComponent().path) { continue }
                    recover { try snapshot.restore() }
                }
                recover { try FileManager.default.removeItem(atPath: installedApp) }
                DNSSettings(user).refresh()
            }
            if let backup { recover { guard rename(backup, installedApp) == 0 else { throw appError("Не удалось вернуть приложение") } } }
            recover { try legacy.rollback() }
            if wasLoaded { recover { _ = try run("/bin/launchctl", ["bootstrap", "system", daemonPlist]) } }
            throw appError(reason + (rollbackErrors.isEmpty ? "\nПредыдущая установка сохранена." : "\nОшибка восстановления: " + rollbackErrors.joined(separator: "; ")))
        }
        print("RUWiFi installed and checksums verified")
    }
    static func serve() throws {
        let lock = open(runtimeRoot + "/service.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw appError("Служба уже запущена") }
        defer { close(lock) }
        let user = try JSONDecoder().decode(Identity.self, from: checkedRead(runtimeRoot + "/identity.json", owner: 0))
        let secret = String(data: try checkedRead(runtimeRoot + "/api-secret", owner: 0), encoding: .utf8)!
        let build = buildIdentity(helper: checksum(try checkedRead(installedHelper, owner: 0, limit: 268_435_456)), engine: checksum(try checkedRead(installedEngine, owner: 0, limit: 268_435_456)))
        let engine = EngineControl(secret: secret), settings = DNSSettings(user)
        var network: NetworkInfo?, lastNetwork = Date.distantPast, lastProbe = Date.distantPast
        var health = false, lastGeneration = "", lastError = ""
        while true {
            var generation = "", enabled = false
            do {
                let preferences = try readPreferences(user)
                generation = preferences.generation; enabled = preferences.enabled
                if Date().timeIntervalSince(lastNetwork) >= 5 || network == nil {
                    network = try NetworkInfo.read(); lastNetwork = Date()
                }
                guard let network else { throw appError("Ожидание сети") }
                if generation != lastGeneration {
                    health = false; lastProbe = .distantPast
                    try publish(ServiceStatus(generation: generation, enabled: enabled, phase: "applying", detail: "Применяю настройки…", checked: Date(), wifi: network.wifi, vpnConnected: network.vpnConnected, enginePID: engine.pid), build: build)
                }
                if !enabled { try settings.disable() }
                try ensureGuards()
                let previousPID = engine.pid
                try engine.ensure(wifi: network.wifi, initiallyEnabled: enabled)
                if previousPID != engine.pid { health = false; lastProbe = .distantPast }
                try engine.select(enabled)
                if enabled { try settings.enable() }
                if enabled && network.wifiActive && Date().timeIntervalSince(lastProbe) > 30 {
                    try checkRoutingHealth()
                    health = true; lastProbe = Date()
                }
                let phase: String, detail: String
                if !enabled { phase = "off"; detail = "Обычные системные маршруты. VPN управляется отдельно." }
                else if !network.wifiActive { phase = "waiting"; detail = "Нет Wi-Fi. Адреса .ru ждут подключения."; health = false; lastProbe = .distantPast }
                else if !network.vpnConnected { phase = "waiting"; detail = ".ru идут через Wi-Fi. VPN-туннель не обнаружен." }
                else if health { phase = "active"; detail = "Маршрутизация .ru и поддоменов через Wi-Fi настроена." }
                else { phase = "applying"; detail = "Проверяю подключение…" }
                try publish(ServiceStatus(generation: generation, enabled: enabled, phase: phase, detail: detail, checked: Date(), wifi: network.wifi, vpnConnected: network.vpnConnected, enginePID: engine.pid), build: build)
                lastGeneration = generation; lastError = ""
            } catch {
                health = false
                let text = error.localizedDescription
                if text != lastError { print("\(Date()): \(text)"); fflush(stdout); lastError = text }
                try? publish(ServiceStatus(generation: generation, enabled: enabled, phase: "error", detail: text, checked: Date(), wifi: network?.wifi, vpnConnected: network?.vpnConnected ?? false, enginePID: engine.pid), build: build)
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }
    static func publish(_ status: ServiceStatus, build: String) throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as! [String: Any]
        object["build"] = build
        try durableWrite(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: runtimeRoot + "/status.json", mode: 0o644)
    }
}
