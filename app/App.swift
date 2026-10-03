import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var tray: NSStatusItem!
    let titleLabel = NSTextField(labelWithString: "RU напрямую")
    let stateLabel = NSTextField(labelWithString: "Подготовка…")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let networkLabel = NSTextField(labelWithString: "")
    let button = NSButton(title: "", target: nil, action: nil)
    let footer = NSTextField(wrappingLabelWithString: "")
    var timer: Timer?
    var preferences = Preferences(enabled: true)
    var user: Identity!
    var installing = false
    var installError: String?
    var expectedBuild: String?
    var isInstalled = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            user = try identity(getuid())
            try prepareUserInstallation(user)
            preferences = try readPreferences(user)
            if let data = try? Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/manifest.json")),
               let manifest = try JSONSerialization.jsonObject(with: data) as? [String: String], let helper = manifest["helper"], let engine = manifest["engine"] { expectedBuild = buildIdentity(helper: helper, engine: engine) }
        } catch { installError = error.localizedDescription }
        let appMenu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
        submenu.addItem(withTitle: "Закрыть интерфейс", action: #selector(quitUI), keyEquivalent: "q").target = self
        item.submenu = submenu; appMenu.addItem(item); NSApp.mainMenu = appMenu
        makeWindow(); makeTray(); refresh()
        if !CommandLine.arguments.contains("--background") { show() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 410), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "RU напрямую"; window.center(); window.delegate = self; window.isReleasedWhenClosed = false
        let body = NSStackView(); body.orientation = .vertical; body.alignment = .centerX; body.spacing = 18
        body.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(body)
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 30), body.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -30), body.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26)])
        titleLabel.font = .systemFont(ofSize: 27, weight: .semibold)
        stateLabel.font = .systemFont(ofSize: 19, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 14); detailLabel.alignment = .center; detailLabel.maximumNumberOfLines = 4
        networkLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular); networkLabel.textColor = .secondaryLabelColor
        button.bezelStyle = .rounded; button.controlSize = .large; button.font = .systemFont(ofSize: 17, weight: .semibold)
        button.target = self; button.action = #selector(toggle)
        footer.font = .systemFont(ofSize: 12); footer.textColor = .secondaryLabelColor; footer.alignment = .center; footer.maximumNumberOfLines = 3
        let diagnostics = NSButton(title: "Скопировать диагностику", target: self, action: #selector(copyDiagnostics)); diagnostics.bezelStyle = .inline
        for view in [titleLabel, stateLabel, detailLabel, networkLabel, button, footer, diagnostics] as [NSView] { body.addArrangedSubview(view) }
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 250), button.heightAnchor.constraint(equalToConstant: 44), detailLabel.widthAnchor.constraint(equalTo: body.widthAnchor), footer.widthAnchor.constraint(equalTo: body.widthAnchor)])
    }
    func makeTray() {
        tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        tray.button?.title = ".ru"; tray.button?.toolTip = "RU напрямую"
        let menu = NSMenu()
        menu.addItem(withTitle: "Открыть RU напрямую", action: #selector(show), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Включить / выключить", action: #selector(toggle), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Закрыть интерфейс (служба продолжит работу)", action: #selector(quitUI), keyEquivalent: "q").target = self
        tray.menu = menu
    }
    @objc func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func quitUI() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func refresh() {
        guard user != nil else { stateLabel.stringValue = "Ошибка запуска"; detailLabel.stringValue = installError ?? ""; return }
        if let value = try? readPreferences(user) { preferences = value }
        let data = try? checkedRead(runtimeRoot + "/status.json", owner: 0)
        let status = data.flatMap { try? JSONDecoder().decode(ServiceStatus.self, from: $0) }
        let fields = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        isInstalled = expectedBuild != nil && (fields?["build"] as? String) == expectedBuild
        button.isEnabled = !installing
        if installing {
            stateLabel.stringValue = "Установка службы…"; stateLabel.textColor = .secondaryLabelColor
            detailLabel.stringValue = "Подтверди запрос macOS. После установки сервис запустится автоматически."
            button.title = "Ожидание macOS…"; return
        }
        if !isInstalled {
            stateLabel.stringValue = "Нужна установка службы"; stateLabel.textColor = .labelColor
            detailLabel.stringValue = installError ?? "Один раз подтверди установку. Затем включение и выключение будут работать без пароля."
            button.title = "Установить и включить"
            footer.stringValue = "Сервис настроит DNS macOS и Chrome.\nПри выключении прежние настройки вернутся."
            return
        }
        if let installError { detailLabel.stringValue = installError }
        button.title = preferences.enabled ? "Выключить" : "Включить"
        footer.stringValue = "Автозапуск включён. Служба работает в фоне,\nдаже когда это окно закрыто."
        guard let status, status.isFresh(for: preferences) else {
            stateLabel.stringValue = "Применяю настройки…"; stateLabel.textColor = .secondaryLabelColor
            detailLabel.stringValue = "Ожидаю подтверждение фоновой службы."; return
        }
        switch status.phase {
        case "active": stateLabel.stringValue = "Работает"; stateLabel.textColor = .systemGreen
        case "off": stateLabel.stringValue = "Выключено"; stateLabel.textColor = .secondaryLabelColor
        case "waiting": stateLabel.stringValue = "Ожидание подключения"; stateLabel.textColor = .systemOrange
        case "error": stateLabel.stringValue = "Нужна проверка"; stateLabel.textColor = .systemRed
        default: stateLabel.stringValue = "Применяю настройки…"; stateLabel.textColor = .secondaryLabelColor
        }
        detailLabel.stringValue = installError ?? status.detail
        networkLabel.stringValue = "Wi-Fi: \(status.wifi ?? "—")   ·   VPN: \(status.vpnConnected ? "подключён" : "не подключён")"
        tray.button?.title = status.phase == "active" ? ".ru ✓" : ".ru"
    }
    @objc func toggle() {
        guard !installing, user != nil else { return }
        if !isInstalled { install(); return }
        do {
            let current = try readPreferences(user)
            try savePreferences(Preferences(enabled: !current.enabled), user: user, expected: current.generation)
            installError = nil
        } catch { installError = error.localizedDescription }
        refresh()
    }
    func install() {
        installing = true; installError = nil; refresh()
        let bundle = Bundle.main.bundleURL
        let staging = URL(fileURLWithPath: user.home + "/Library/Application Support/RUWiFi/install-" + UUID().uuidString + ".app")
        let uid = user.uid
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String?
            do {
                // Stage outside privacy-protected Documents before elevating the installer.
                try FileManager.default.copyItem(at: bundle, to: staging)
                defer { try? FileManager.default.removeItem(at: staging) }
                let helper = staging.appendingPathComponent("Contents/Helpers/RUWiFiHelper").path
                let shell = "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "' --install " + String(uid)
                let literal = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                var error: NSDictionary?
                let script = NSAppleScript(source: "do shell script \"" + literal + "\" with administrator privileges")
                guard let script else { throw appError("Не удалось открыть установщик macOS") }
                _ = script.executeAndReturnError(&error)
                message = error?[NSAppleScript.errorMessage] as? String
            } catch { message = error.localizedDescription }
            DispatchQueue.main.async {
                self.installing = false
                if let message { self.installError = message }
                else {
                    do { try configureLoginItem(for: self.user) } catch { self.installError = error.localizedDescription }
                }
                self.refresh()
            }
        }
    }
    @objc func copyDiagnostics() {
        let status = (try? String(contentsOfFile: runtimeRoot + "/status.json", encoding: .utf8)) ?? "Служба не установлена"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("RU напрямую " + version + "\n" + status, forType: .string)
    }
}

@main struct RUWiFiApp {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty && arguments != ["--background"] {
            do {
                guard arguments.count == 1 else { throw appError("Укажите одну команду") }
                switch arguments[0] {
                case "--prepare-install": try prepareUserInstallation(identity(getuid()))
                case "--finish-install":
                    try configureLoginItem(for: identity(getuid()))
                    // Updates must open the new UI, not reuse an old process and its build hash.
                    let previous = NSRunningApplication.runningApplications(withBundleIdentifier: "local.matvey.RUWiFi").filter { $0.processIdentifier != getpid() }
                    for application in previous { _ = application.terminate() }
                    for _ in 0..<30 {
                        if previous.allSatisfy({ $0.isTerminated }) { break }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                    }
                    guard previous.allSatisfy({ $0.isTerminated }) else { throw appError("Служба установлена. Закройте старый интерфейс RU напрямую через ⌘Q и откройте приложение снова.") }
                case "--version": print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
                default: throw appError("Неизвестная команда: " + arguments[0])
                }
                return
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate; app.setActivationPolicy(.regular)
        app.run()
    }
}
