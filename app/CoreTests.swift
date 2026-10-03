import Foundation

@main struct CoreTests {
    static func main() throws {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            if !condition() { failures.append(description) }
        }
        // RU-ROUTE: arbitrary depth, case, absolute names; reject lookalike suffixes.
        for name in ["site.ru", "a.b.c.site.ru", "SITE.RU", "site.ru.", "xn--e1afmkfd.ru"] {
            check(RoutingConfiguration.isRU(name), "RU-ROUTE: did not classify \(name)")
        }
        for name in ["ru.com", "site.ru.com", "notru", ".ru", "a..ru", "https://site.ru", "a/ru", "foo.com"] {
            check(!RoutingConfiguration.isRU(name), "RU-ROUTE: falsely classified \(name)")
        }
        // RU-OWNERSHIP: off must preserve an administrator's external changes.
        check(restorationDecision(current: Data("foreign".utf8), installed: Data("ours".utf8)) == .preserveExternalChange, "RU-OWNERSHIP: overwrites externally changed file")
        check(restorationDecision(current: nil, installed: Data("ours".utf8)) == .preserveExternalChange, "RU-OWNERSHIP: recreates externally removed file")
        check(restorationDecision(current: Data("ours".utf8), installed: Data("ours".utf8)) == .restore, "RU-OWNERSHIP: does not restore owned file")
        let legacy = "destination: 77.88.55.88\ngateway: 192.168.0.1\ninterface: en0\nflags: <UP,GATEWAY,HOST,DONE,STATIC>"
        check(ownsLegacyRoute(legacy, ip: "77.88.55.88", gateway: "192.168.0.1", wifi: "en0"), "RU-MIGRATION: owned legacy route not recognized")
        for changed in [legacy.replacingOccurrences(of: "destination: 77.88.55.88", with: "destination: default"),
                        legacy.replacingOccurrences(of: "en0", with: "utun4"),
                        legacy.replacingOccurrences(of: "192.168.0.1", with: "10.0.0.1"),
                        legacy.replacingOccurrences(of: "STATIC", with: "WASCLONED")] {
            check(!ownsLegacyRoute(changed, ip: "77.88.55.88", gateway: "192.168.0.1", wifi: "en0"), "RU-MIGRATION: foreign/default/cloned route accepted")
        }
        let pref = Preferences(enabled: true)
        var status = ServiceStatus(generation: pref.generation, enabled: true, phase: "active", detail: "", checked: Date(), wifi: "en0", vpnConnected: true)
        check(status.isFresh(for: pref), "RU-STATUS: fresh status not accepted")
        status.generation = "other"
        check(!status.isFresh(for: pref), "RU-STATUS: stale generation accepted")
        status.generation = pref.generation; status.checked = Date().addingTimeInterval(-60)
        check(!status.isFresh(for: pref), "RU-STATUS: stale heartbeat accepted")
        let config = try RoutingConfiguration.make(wifi: "en0", cache: "/tmp/ru-cache.db", secret: "test")
        let inbounds = config["inbounds"] as? [[String: Any]] ?? []
        let tun = inbounds.first { ($0["type"] as? String) == "tun" } ?? [:]
        check(tun["route_address"] as? [String] == ["198.19.0.0/16", "fd7a:7275:7769::/48"], "RU-ISOLATION: must capture only owned FakeIP networks")
        check(tun["interface_name"] == nil, "RU-RECOVERY: must not reserve a fixed utun")
        let outbounds = config["outbounds"] as? [[String: Any]] ?? []
        check(outbounds.contains { ($0["tag"] as? String) == "Wi-Fi" && ($0["bind_interface"] as? String) == "en0" }, "RU-ROUTE: Wi-Fi outbound not bound")
        check(outbounds.contains { ($0["type"] as? String) == "selector" && ($0["interrupt_exist_connections"] as? Bool) == true }, "RU-TOGGLE: old selected connections must close on toggle")
        check(outbounds.first { ($0["type"] as? String) == "selector" }?["default"] as? String == "Wi-Fi", "RU-RECOVERY: enabled startup must not briefly select VPN")
        do { _ = try RoutingConfiguration.make(wifi: "en0; rm", cache: "/tmp/cache", secret: "test"); failures.append("RU-INPUT: invalid interface accepted") } catch {}
        if !failures.isEmpty { for failure in failures { print("FAIL: \(failure)") }; exit(1) }
        if CommandLine.arguments.count > 1 { try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print("PASS: domain boundaries, route isolation, switch semantics, status freshness and restore ownership")
    }
}
