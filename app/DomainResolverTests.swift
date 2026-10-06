import Foundation
import Darwin

@main struct DomainResolverTests {
    static func main() throws {
        let root = "/private/tmp/ruwifi-resolvers-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let settings = DomainResolvers(directory: root, journals: root)
        let ru = root + "/ru", fresh = root + "/1cfresh.com"
        let ruJournal = root + "/resolver-journal.json", freshJournal = root + "/resolver-1cfresh.com-journal.json"
        let idnFiles = ["xn--p1acf", "xn--p1ai"].map { root + "/" + $0 }
        let idnJournals = ["xn--p1acf", "xn--p1ai"].map { root + "/resolver-" + $0 + "-journal.json" }
        let old = Data("nameserver 192.0.2.53\n".utf8)
        var failures: [String] = []
        func check(_ value: Bool, _ reason: String) { if !value { failures.append(reason) } }
        check(Set(settings.snapshotPaths) == Set([ru, fresh, ruJournal, freshJournal] + idnFiles + idnJournals), "DIRECT-ROLLBACK: all DNS files and journals must be in install snapshots")
        // Upgrade: retain the existing .ru journal; create the newly added resolver.
        try durableWrite(old, to: ru, mode: 0o640)
        try OwnedFile(ru, journal: ruJournal).apply(resolverData)
        try settings.apply(); try settings.apply()
        check(try optionalFile(ru) == resolverData, "FRESH-ON: .ru stopped being managed")
        check(try optionalFile(fresh) == resolverData, "FRESH-ON: 1cfresh.com resolver was not created")
        for file in idnFiles { check(try optionalFile(file) == resolverData, "IDN-ON: resolver was not created: " + file) }
        try settings.restore()
        check(try optionalFile(ru) == old, "FRESH-UPGRADE: original .ru DNS lost")
        check(try optionalFile(fresh) == nil && optionalFile(freshJournal) == nil, "FRESH-OFF: newly created 1cfresh resolver/journal remained")
        for file in idnFiles + idnJournals { check(try optionalFile(file) == nil, "IDN-OFF: newly created resolver/journal remained: " + file) }
        // Upgrade preserves an existing Cyrillic-zone resolver and its permissions.
        for file in idnFiles { try durableWrite(old, to: file, mode: 0o640) }
        try settings.apply(); try settings.apply(); try settings.restore()
        for file in idnFiles {
            check(try optionalFile(file) == old, "IDN-OFF: original DNS lost: " + file)
            let permissions = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber
            check(permissions?.intValue == 0o640, "IDN-OFF: original permissions lost: " + file)
        }
        // Existing 1C resolver must recover its original bytes and permissions.
        try durableWrite(old, to: fresh, mode: 0o640)
        try settings.apply(); try settings.restore()
        check(try optionalFile(fresh) == old, "FRESH-OFF: previous 1cfresh DNS not restored")
        let attrs = try FileManager.default.attributesOfItem(atPath: fresh)
        check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o640, "FRESH-OFF: previous permissions lost")
        // Install rollback removes newly created journals and restores both files.
        let snapshots = try settings.snapshotPaths.map { try FileSnapshot($0) }
        try settings.apply()
        for snapshot in snapshots { try snapshot.restore() }
        check(try optionalFile(ru) == old && optionalFile(fresh) == old, "FRESH-ROLLBACK: DNS baseline not recovered")
        for file in idnFiles { check(try optionalFile(file) == old, "IDN-ROLLBACK: DNS baseline not recovered: " + file) }
        check(!settings.hasJournals, "FRESH-ROLLBACK: new journals remained")
        // An externally changed resolver survives Off; the other resolver still restores.
        try settings.apply()
        let external = Data("nameserver 192.0.2.54\n".utf8)
        try durableWrite(external, to: fresh)
        do { try settings.restore(); failures.append("FRESH-OWNERSHIP: external change not reported") } catch {}
        check(try optionalFile(fresh) == external, "FRESH-OWNERSHIP: external DNS overwritten")
        check(try optionalFile(ru) == old, "FRESH-OWNERSHIP: other resolver failed to restore")
        // Restore fixture ownership, then verify symbolic links are never followed.
        try durableWrite(resolverData, to: fresh)
        try settings.restore()
        try FileManager.default.removeItem(atPath: fresh)
        let outside = root + "/outside"
        try durableWrite(external, to: outside)
        try FileManager.default.createSymbolicLink(atPath: fresh, withDestinationPath: outside)
        do { try settings.apply(); failures.append("FRESH-OWNERSHIP: symbolic-link resolver accepted") } catch {}
        check(try optionalFile(outside) == external, "FRESH-OWNERSHIP: symbolic link target changed")
        if !failures.isEmpty { failures.forEach { print("FAIL: " + $0) }; exit(1) }
        print("PASS: all domain resolvers including .рус/.рф, upgrade, repeated enable, Off, rollback and external ownership")
    }
}
