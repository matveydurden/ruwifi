import Foundation

@main struct CoreTests {
    static func main() throws {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            if !condition() { failures.append(description) }
        }
        // RU-ROUTE: arbitrary depth, case, absolute names; reject lookalike suffixes.
        for name in ["site.ru", "a.b.c.site.ru", "SITE.RU", "site.ru.", "xn--e1afmkfd.ru", "1cfresh.com", "msk1.1cfresh.com", "a.b.1cfresh.com", "MSK1.1CFRESH.COM.", "1cfresh.com.ru"] {
            check(RoutingConfiguration.isDirectDomain(name), "RU-ROUTE: did not classify \(name)")
        }
        for name in ["ru.com", "site.ru.com", "notru", ".ru", "a..ru", "https://site.ru", "a/ru", "foo.com", "not1cfresh.com", "1cfresh.com.evil.com", "1cfresh.com..", "a..1cfresh.com"] {
            check(!RoutingConfiguration.isDirectDomain(name), "RU-ROUTE: falsely classified \(name)")
        }
        // IDN-ROUTE: browser DNS uses ASCII Punycode for .рус and .рф.
        for name in ["www.xn--80aa3anexr8c.xn--p1acf", "a.b.xn--80aa3anexr8c.xn--p1acf", "xn--e1afmkfd.xn--p1ai", "a.b.xn--e1afmkfd.xn--p1ai", "WWW.XN--80AA3ANEXR8C.XN--P1ACF.", "XN--E1AFMKFD.XN--P1AI."] {
            check(RoutingConfiguration.isDirectDomain(name), "IDN-ROUTE: did not classify \(name)")
        }
        for name in ["site.xn--p1acf.com", "site.xn--p1ai.com", "sitexn--p1ai", "site.xn--p1acfe", "site.xn--90ais", "xn--e1afmkfd.com", "a..xn--p1acf", ".xn--p1ai"] {
            check(!RoutingConfiguration.isDirectDomain(name), "IDN-ROUTE: falsely classified \(name)")
        }
        // VPN-DETECTION: provider-independent service and route indicators.
        let hidemyName = "(Connected) VPN (hidemyname.vpn) \"hidemyname.vpn (OpenVPN)\" [VPN:hidemyname.vpn]"
        check(vpnIsDetected(scutilList: hidemyName, publicRoute: "interface: en0"), "VPN-DETECTION: OpenVPN service not recognized")
        check(vpnIsDetected(scutilList: "(Connected) Work tunnel [VPN:WireGuard]", publicRoute: "interface: en0"), "VPN-DETECTION: generic VPN service not recognized")
        check(vpnIsDetected(scutilList: "(Connected) Office VPN [IPSec:ikev2]", publicRoute: "interface: en0"), "VPN-DETECTION: IPSec service not recognized")
        check(vpnIsDetected(scutilList: "(Connected) PPP --> L2TP [PPP:L2TP]", publicRoute: "interface: ppp0"), "VPN-DETECTION: L2TP service not recognized")
        check(vpnIsDetected(scutilList: "", publicRoute: "destination: default\ninterface: utun5"), "VPN-DETECTION: tunnel route not recognized")
        check(!vpnIsDetected(scutilList: "(Disconnected) Work tunnel [VPN:WireGuard]", publicRoute: "interface: en0"), "VPN-DETECTION: disconnected service accepted")
        check(!vpnIsDetected(scutilList: "(Connected) PPP modem [PPP:Modem]", publicRoute: "interface: ppp0"), "VPN-DETECTION: PPP modem accepted as VPN")
        check(!vpnIsDetected(scutilList: "(Connected) WireGuard [PPP:Modem]", publicRoute: "interface: ppp0"), "VPN-DETECTION: modem with VPN-like name accepted")
        check(!vpnIsDetected(scutilList: "", publicRoute: "destination: 198.19.0.1\ninterface: utun0"), "VPN-DETECTION: RUWiFi FakeIP route accepted as external VPN")
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
        let dnsRules = (config["dns"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []
        let expectedSuffixes = ["ru", "1cfresh.com", "xn--p1acf", "xn--p1ai"]
        check(dnsRules.count == 2 && dnsRules.allSatisfy { $0["domain_suffix"] as? [String] == expectedSuffixes }, "DIRECT-DNS: A/AAAA and HTTPS/SVCB rules must include only approved suffixes")
        let routeRules = (config["route"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []
        check(routeRules.contains { $0["outbound"] as? String == "RU" && $0["domain_suffix"] as? [String] == expectedSuffixes }, "DIRECT-ROUTE: every approved suffix must use the same on/off selector")
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
