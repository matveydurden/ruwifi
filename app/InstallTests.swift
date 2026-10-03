import Foundation
import Darwin

@main struct InstallTests {
    static func main() throws {
        let root = "/private/tmp/ruwifi-install-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/Library/Application Support", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let user = Identity(uid: getuid(), name: "installer-test", home: root)
        var failures: [String] = []
        func check(_ condition: Bool, _ reason: String) { if !condition { failures.append(reason) } }
        try prepareUserInstallation(user)
        check(FileManager.default.fileExists(atPath: policyPath(user)), "first install must create user preferences")
        if FileManager.default.fileExists(atPath: policyPath(user)) {
            check(try readPreferences(user).enabled, "first install must enable routing")
            let disabled = Preferences(enabled: false)
            try savePreferences(disabled, user: user)
            try prepareUserInstallation(user)
            check(try readPreferences(user) == disabled, "update must preserve Off and generation")
        }
        try configureLoginItem(for: user)
        let agent = root + "/Library/LaunchAgents/local.matvey.RUWiFi.Login.plist"
        check(FileManager.default.fileExists(atPath: agent), "terminal install must configure login startup")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: agent)), let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            check(plist["ProgramArguments"] as? [String] == [installedApp + "/Contents/MacOS/RUWiFi", "--background"], "login must use installed app")
        }
        if !failures.isEmpty { failures.forEach { print("FAIL: " + $0) }; exit(1) }
        print("PASS: first installation, retained Off state and login startup")
    }
}
