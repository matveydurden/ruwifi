import Foundation

@main struct RoutingHealthTests {
    static func main() throws {
        var failures: [String] = []
        let validDNS = "198.19.0.42\n"
        let validRoute = "destination: 198.19.0.0\ninterface: utun7\nflags: <UP,DONE>"
        func probe(dns: String = "198.19.0.42\n", route: String = "interface: utun7", failCommand: String? = nil) throws {
            try checkRoutingHealth { program, args, timeout in
                guard timeout > 0 && timeout <= 10 else { throw appError("Unbounded health check") }
                if program == failCommand { throw appError("Local command failed") }
                switch program {
                case "/usr/bin/dig":
                    guard args.starts(with: ["@127.0.0.1", "-p", "15453"]) else {
                        throw appError("DNS check must use loopback")
                    }
                    return dns
                case "/sbin/route":
                    guard args == ["-n", "get", "198.19.0.1"] else { throw appError("Unexpected route probe") }
                    return route
                default:
                    throw appError("External or unexpected health command: " + program)
                }
            }
        }
        do { try probe(dns: validDNS, route: validRoute) }
        catch { failures.append("local DNS and route must be sufficient without internet: " + error.localizedDescription) }
        for invalid in ["", "1.1.1.1\n"] {
            do { try probe(dns: invalid); failures.append("invalid local DNS accepted") } catch {}
        }
        for invalid in ["interface: en0", "interface: lo0\nflags: <UP,REJECT>", "interface: utun7\nflags: <REJECT>", ""] {
            do { try probe(route: invalid); failures.append("invalid local route accepted") } catch {}
        }
        for failed in ["/usr/bin/dig", "/sbin/route"] {
            do { try probe(failCommand: failed); failures.append("failed local command accepted") } catch {}
        }
        if !failures.isEmpty { failures.forEach { print("FAIL: " + $0) }; exit(1) }
        print("PASS: routing readiness needs only loopback DNS and the local route table; failures remain visible")
    }
}
