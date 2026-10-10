import Foundation
import Darwin

struct Preferences: Codable, Equatable {
    var enabled: Bool
    var generation: String
    init(enabled: Bool) { self.enabled = enabled; generation = UUID().uuidString }
}

// This is an indicator, not a claim about the VPN provider or final egress.
// scutil covers registered VPN services; the route fallback covers Network
// Extension clients such as WireGuard.
func vpnIsDetected(scutilList: String, publicRoute: String) -> Bool {
    // Match scutil's protocol tags, never a user-controlled service name.
    let serviceMarkers = ["[vpn:", "[ipsec:", "[ppp:l2tp]", "[ppp:pptp]"]
    let registered = scutilList.split(whereSeparator: \.isNewline).contains { rawLine in
        let line = rawLine.lowercased()
        guard line.contains("(connected)") else { return false }
        return serviceMarkers.contains { line.contains($0) }
    }
    if registered { return true }
    let route = publicRoute.lowercased()
    if route.contains("198.18.") || route.contains("198.19.") || route.contains("fd7a:7275:") {
        return false
    }
    return route.range(of: #"interface:\s*(utun|tun|tap|ipsec)[0-9]+\b"#, options: .regularExpression) != nil
}

enum RoutingConfiguration {
    // DNS uses the ASCII Punycode names for .рус and .рф.
    static let directDomainSuffixes = ["ru", "1cfresh.com", "xn--p1acf", "xn--p1ai", "beget.com", "pachca.com"]
    static func isDirectDomain(_ name: String) -> Bool {
        var host = name.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard host.utf8.count <= 253, directDomainSuffixes.contains(where: { host.hasSuffix("." + $0) || ($0.contains(".") && host == $0) }) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
    static func make(wifi: String, cache: String, secret: String) throws -> [String: Any] {
        guard wifi.range(of: "^en[0-9]+$", options: .regularExpression) != nil else {
            throw NSError(domain: "RUWiFi", code: 1, userInfo: [NSLocalizedDescriptionKey: "Некорректный интерфейс Wi-Fi"])
        }
        func resolver(_ tag: String, interface: String?) -> [String: Any] {
            var value: [String: Any] = ["type": "https", "tag": tag, "server": "1.1.1.1", "server_port": 443,
                "path": "/dns-query", "tls": ["enabled": true, "server_name": "cloudflare-dns.com"]]
            if let interface { value["bind_interface"] = interface }
            return value
        }
        return [
            "log": ["level": "warn", "timestamp": true],
            "dns": ["servers": [
                ["type": "fakeip", "tag": "fake", "inet4_range": "198.19.0.0/16", "inet6_range": "fd7a:7275:7769::/48"],
                resolver("wifi-dns", interface: wifi), resolver("ordinary-dns", interface: nil)],
                "rules": [
                    ["domain_suffix": directDomainSuffixes, "query_type": ["A", "AAAA"], "action": "route", "server": "fake", "rewrite_ttl": 5],
                    ["domain_suffix": directDomainSuffixes, "query_type": ["HTTPS", "SVCB"], "action": "predefined", "rcode": "NOERROR"]
                ], "final": "ordinary-dns"],
            "inbounds": [
                ["type": "direct", "tag": "dns-in", "listen": "127.0.0.1", "listen_port": 15453],
                ["type": "tun", "tag": "ru-in", "address": ["172.30.253.1/30", "fdfe:dcba:9875::1/126"],
                 "auto_route": true, "route_address": ["198.19.0.0/16", "fd7a:7275:7769::/48"],
                 "dns_mode": "disabled", "stack": "gvisor", "mtu": 1500]
            ],
            "outbounds": [
                ["type": "selector", "tag": "RU", "outbounds": ["Wi-Fi", "Default"], "default": "Wi-Fi", "interrupt_exist_connections": true],
                ["type": "direct", "tag": "Wi-Fi", "bind_interface": wifi,
                 "domain_resolver": ["server": "wifi-dns", "strategy": "ipv4_only"]],
                ["type": "direct", "tag": "Default", "domain_resolver": ["server": "ordinary-dns", "strategy": "prefer_ipv4"]]
            ],
            "route": ["rules": [
                ["inbound": ["dns-in"], "action": "hijack-dns"],
                ["domain_suffix": directDomainSuffixes, "action": "route", "outbound": "RU"],
                ["action": "reject"]
            ]],
            "experimental": [
                "cache_file": ["enabled": true, "path": cache, "store_fakeip": true],
                "clash_api": ["external_controller": "127.0.0.1:15454", "secret": secret]
            ]
        ]
    }
}

enum RestoreDecision: Equatable { case restore, preserveExternalChange }
func restorationDecision(current: Data?, installed: Data) -> RestoreDecision { current == installed ? .restore : .preserveExternalChange }

struct ServiceStatus: Codable {
    var version = 1
    var generation: String
    var enabled: Bool
    var phase: String
    var detail: String
    var checked: Date
    var wifi: String?
    var vpnConnected: Bool
    var enginePID: Int32?
    func isFresh(for preferences: Preferences, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(checked)
        return generation == preferences.generation && enabled == preferences.enabled && age >= -5 && age < 20
    }
}

func ownsLegacyRoute(_ description: String, ip: String, gateway: String, wifi: String) -> Bool {
    func field(_ name: String) -> String {
        description.components(separatedBy: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + ":") }?
            .components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces) ?? ""
    }
    let flags = field("flags")
    return field("destination") == ip && field("gateway") == gateway && field("interface") == wifi &&
        flags.contains("HOST") && flags.contains("STATIC") && !flags.contains("WASCLONED")
}
