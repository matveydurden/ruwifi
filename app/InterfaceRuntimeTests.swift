import AppKit
import Foundation
import CoreFoundation

@main struct InterfaceRuntimeTests {
    static func main() throws {
        _ = NSApplication.shared
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
        var failures: [String] = []
        // A service has already published a changed status. The UI must display it
        // promptly, including while the status menu runs its tracking loop.
        for mode in [RunLoop.Mode.default, .eventTracking] {
            var shown = "old"
            let timer = makeInterfaceRefreshTimer { shown = "updated" }
            let start = ProcessInfo.processInfo.systemUptime
            let deadline = Date().addingTimeInterval(0.6)
            while shown != "updated" && Date() < deadline {
                _ = RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.01))
            }
            timer.invalidate()
            if shown != "updated" { failures.append("published status not shown promptly in \(mode.rawValue)") }
            else { print("PASS: \(mode.rawValue) update in \(Int((ProcessInfo.processInfo.systemUptime-start)*1000)) ms") }
        }
        let lockPath = "/private/tmp/ruwifi-ui-lock-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: lockPath) }
        var first: InterfaceInstanceLock? = try InterfaceInstanceLock(path: lockPath)
        if first?.acquired != true { failures.append("first UI must own the instance lock") }
        let duplicate = try InterfaceInstanceLock(path: lockPath)
        if duplicate.acquired { failures.append("second UI must not start its own window or timer") }
        first = nil
        let reopened = try InterfaceInstanceLock(path: lockPath)
        if !reopened.acquired { failures.append("UI must reopen after the owner exits") }
        let handoffPath = lockPath + "-handoff"
        defer { try? FileManager.default.removeItem(atPath: handoffPath) }
        var exitingOwner: InterfaceInstanceLock? = try InterfaceInstanceLock(path: handoffPath)
        if exitingOwner?.acquired != true { failures.append("handoff fixture could not acquire lock") }
        let quitTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in exitingOwner = nil }
        let successor = try acquireInterface(path: handoffPath, background: false)
        quitTimer.invalidate()
        if successor?.acquired != true { failures.append("open during owner exit must acquire the released lock instead of disappearing") }
        if !failures.isEmpty { failures.forEach { print("FAIL: " + $0) }; exit(1) }
    }
}
