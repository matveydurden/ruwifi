import Foundation
import Darwin

@main struct StorageTests {
    static func main() throws {
        let root = "/private/tmp/ruwifi-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: root) }
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        func mustThrow(_ message: String, _ operation: () throws -> Void) { do { try operation(); failures.append(message) } catch {} }
        let original = Data("original".utf8), ours = Data("ours".utf8), foreign = Data("external".utf8)
        let source = root + "/source"
        try original.write(to: URL(fileURLWithPath: source)); chmod(source, 0o600)
        check(try checkedRead(source, owner: getuid()) == original, "RU-FILE: valid content not read")
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: source)
        mustThrow("RU-FILE: symlink was accepted") { _ = try checkedRead(root + "/link", owner: getuid()) }
        mustThrow("RU-FILE: wrong owner accepted") { _ = try checkedRead(source, owner: getuid() + 1) }
        chmod(source, 0o666)
        mustThrow("RU-FILE: writable policy accepted") { _ = try checkedRead(source, owner: getuid()) }
        chmod(source, 0o600)
        mustThrow("RU-FILE: oversized data accepted") { _ = try checkedRead(source, owner: getuid(), limit: 2) }
        mustThrow("RU-FILE: relative path accepted") { _ = try checkedRead("relative", owner: getuid()) }
        try FileManager.default.createSymbolicLink(atPath: root + "/parent-link", withDestinationPath: root)
        mustThrow("RU-FILE: symlink parent accepted") { _ = try checkedRead(root + "/parent-link/source", owner: getuid()) }
        try durableWrite(ours, to: source)
        check(try Data(contentsOf: URL(fileURLWithPath: source)) == ours, "RU-FILE: atomic write did not publish complete content")
        mustThrow("RU-FILE: write followed symlink") { try durableWrite(foreign, to: root + "/link") }
        let path = root + "/resolver", journal = root + "/journal"
        try original.write(to: URL(fileURLWithPath: path)); chmod(path, 0o640)
        let file = OwnedFile(path, journal: journal)
        try file.apply(ours); try file.apply(ours)
        check(try Data(contentsOf: URL(fileURLWithPath: path)) == ours, "RU-RESTORE: desired file not installed")
        try file.restore()
        check(try Data(contentsOf: URL(fileURLWithPath: path)) == original, "RU-RESTORE: repeated apply lost original")
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o640, "RU-RESTORE: original permissions lost")
        try file.apply(ours)
        try foreign.write(to: URL(fileURLWithPath: path))
        mustThrow("RU-RESTORE: external modification accepted") { try file.restore() }
        check(try Data(contentsOf: URL(fileURLWithPath: path)) == foreign, "RU-RESTORE: external modification overwritten")
        let absent = OwnedFile(root + "/absent", journal: root + "/absent-journal")
        try absent.apply(ours); try absent.restore()
        check(!FileManager.default.fileExists(atPath: root + "/absent"), "RU-RESTORE: absent file not removed")
        let snapshot = try FileSnapshot(path)
        try durableWrite(ours, to: path, mode: 0o600)
        try snapshot.restore()
        check(try checkedRead(path, owner: getuid()) == foreign, "RU-INSTALL: rollback lost previous content")
        let absentSnapshot = try FileSnapshot(root + "/new-install")
        try durableWrite(ours, to: absentSnapshot.path)
        try absentSnapshot.restore()
        check(!FileManager.default.fileExists(atPath: absentSnapshot.path), "RU-INSTALL: rollback kept new file")
        mustThrow("RU-INSTALL: snapshot followed symlink") { _ = try FileSnapshot(root + "/link") }
        let oldMask = umask(0o077)
        try ensureDirectory(root + "/public-policy", mode: 0o755)
        umask(oldMask)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root + "/public-policy")
        check((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o755, "RU-DNS: daemon umask hid managed preferences from browser")
        let started = Date()
        _ = try run("/bin/sh", ["-c", "sleep 2 & exit 0"], timeout: 1)
        check(Date().timeIntervalSince(started) < 1, "RU-PROCESS: inherited pipe kept supervisor waiting")
        mustThrow("RU-PROCESS: timeout did not terminate child") { _ = try run("/bin/sleep", ["2"], timeout: 0.03) }
        if !failures.isEmpty { failures.forEach { print("FAIL: \($0)") }; exit(1) }
        print("PASS: secure file access, atomic publication, idempotent restore and external-change preservation")
    }
}
