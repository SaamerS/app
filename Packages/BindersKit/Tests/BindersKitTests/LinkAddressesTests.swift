import XCTest
@testable import BindersKit

/// The Mac's addresses for phones, on the founder's Mac as it is (Covee on utun0, Cloudflare WARP on utun8, Tailscale
/// installed but stopped) and on others. Addresses and names are made up where they don't matter.
final class LinkAddressesTests: XCTestCase {
    // MARK: Fixtures

    /// Fixture A: Wi-Fi, Covee, a macOS utun with only a link-local address, WARP, a VM bridge, a self-assigned en5, and
    /// an en1 that's down.
    static let founderMac: [LinkInterface] = [
        LinkInterface(name: "en0", address: "192.168.1.20", medium: .wifi),
        LinkInterface(name: "en0", address: "fe80::1c2b:3aff:fe11:2233%en0", medium: .wifi),
        LinkInterface(name: "lo0", address: "127.0.0.1", isLoopback: true),
        LinkInterface(name: "lo0", address: "::1", isLoopback: true),
        LinkInterface(name: "utun0", address: "100.64.0.2", isPointToPoint: true),
        LinkInterface(name: "utun0", address: "fd7a:115c:a1e0::2", isPointToPoint: true),
        LinkInterface(name: "utun0", address: "fe80::a%utun0", isPointToPoint: true),
        LinkInterface(name: "utun1", address: "fe80::b%utun1", isPointToPoint: true),
        LinkInterface(name: "utun8", address: "100.96.0.8", isPointToPoint: true),
        LinkInterface(name: "utun8", address: "2606:4700:cf1:1000::8", isPointToPoint: true),
        LinkInterface(name: "bridge100", address: "192.168.64.1"),
        LinkInterface(name: "en5", address: "169.254.20.20"),
        LinkInterface(name: "en1", address: "192.168.1.21", isUp: false),
    ]

    /// Fixture B's extra interface: Tailscale's own utun, running beside Covee.
    static let tailscaleTunnel: [LinkInterface] = [
        LinkInterface(name: "utun4", address: "100.101.102.103", isPointToPoint: true),
        LinkInterface(name: "utun4", address: "fd7a:115c:a1e0::7", isPointToPoint: true),
    ]

    /// `tailscale status --json --peers=false`, modelled on Tailscale's ipnstate.Status with made-up values.
    static func statusJSON(_ change: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var status: [String: Any] = [
            "Version": "1.80.0-t0123456789", "TUN": true, "BackendState": "Stopped", "HaveNodeKey": true, "AuthURL": "",
            "TailscaleIPs": ["100.80.1.33"],
            "Self": ["ID": "n1", "HostName": "studio-mac", "DNSName": "studio-mac.tail1234.ts.net.", "OS": "macOS",
                     "TailscaleIPs": ["100.80.1.33"], "Online": false] as [String: Any],
            "Health": ["Tailscale is stopped."], "MagicDNSSuffix": "tail1234.ts.net", "CurrentTailnet": NSNull(), "User": NSNull(),
        ]
        change(&status)
        return try! JSONSerialization.data(withJSONObject: status)
    }

    static var stoppedJSON: Data { statusJSON() }

    static var runningJSON: Data {
        statusJSON { status in
            status["BackendState"] = "Running"
            status["TailscaleIPs"] = ["100.101.102.103", "fd7a:115c:a1e0::7"]
            var node = status["Self"] as! [String: Any]
            node["TailscaleIPs"] = ["100.101.102.103", "fd7a:115c:a1e0::7"]
            node["Online"] = true
            status["Self"] = node
            status["Health"] = [String]()
            status["CurrentTailnet"] = ["Name": "example.com", "MagicDNSSuffix": "tail1234.ts.net", "MagicDNSEnabled": true] as [String: Any]
        }
    }

    static var stopped: LinkVPNStatus { LinkVPNStatus.tailscale(stoppedJSON)! }
    static var running: LinkVPNStatus { LinkVPNStatus.tailscale(runningJSON)! }

    private func offered(_ interfaces: [LinkInterface], vpns: [LinkVPNStatus] = [], added: [String] = [], leftOut: Set<String> = []) -> [LinkAddress] {
        LinkAddresses.offered(LinkAddresses.classify(interfaces: interfaces, vpns: vpns, added: added, leftOut: leftOut))
    }

    private func describe(_ list: [LinkAddress]) -> [String] {
        list.map { "\($0.name(defaultPort: Link.port)) \($0.kind)\($0.unlikely == true ? " unlikely" : "")" }
    }

    // MARK: The founder's Mac

    func testCoveeIsAVPNAndWARPComesLast() {
        let entries = LinkAddresses.classify(interfaces: Self.founderMac, vpns: [Self.stopped])
        let list = LinkAddresses.offered(entries)
        XCTAssertEqual(describe(list), ["192.168.1.20 local", "100.64.0.2 vpn", "fd7a:115c:a1e0::2 vpn", "100.96.0.8 vpn unlikely"])
        XCTAssertEqual(list.map(\.label), ["Wi-Fi", "VPN", "VPN", "VPN"])
        XCTAssertEqual(entries.map(\.interface), ["en0", "utun0", "utun0", "utun8"])
        XCTAssertTrue(entries.allSatisfy { !$0.leftOut })
    }

    func testAStoppedTailscaleIsIgnored() {
        let withStopped = offered(Self.founderMac, vpns: [Self.stopped])
        XCTAssertEqual(withStopped, offered(Self.founderMac), "a stopped Tailscale changes nothing")
        let hosts = withStopped.map(\.host)
        for never in ["100.80.1.33", "studio-mac.tail1234.ts.net", "2606:4700:cf1:1000::8", "169.254.20.20", "192.168.64.1", "192.168.1.21", "127.0.0.1", "::1"] {
            XCTAssertFalse(hosts.contains(never), never)
        }
        XCTAssertFalse(hosts.contains { $0.hasPrefix("fe80") })
        XCTAssertFalse(Self.stopped.isRunning)
    }

    func testARunningTailscaleAddsItsAddressesAndNameAndCoveeStays() {
        let entries = LinkAddresses.classify(interfaces: Self.founderMac + Self.tailscaleTunnel, vpns: [Self.running])
        let list = LinkAddresses.offered(entries)
        XCTAssertEqual(describe(list), ["192.168.1.20 local", "studio-mac.tail1234.ts.net tailscale", "100.101.102.103 tailscale",
                                        "100.64.0.2 vpn", "fd7a:115c:a1e0::7 tailscale", "fd7a:115c:a1e0::2 vpn", "100.96.0.8 vpn unlikely"])
        XCTAssertEqual(entries.first { $0.address.host == "100.101.102.103" }?.interface, "utun4")
        XCTAssertEqual(entries.first { $0.address.host == "100.64.0.2" }?.address.label, "VPN")
        XCTAssertEqual(entries.first { $0.address.host == "100.101.102.103" }?.address.label, "Tailscale")
    }

    func testTailscaleInUserspaceAndWithoutMagicDNS() {
        // C1: running in userspace (no utun of its own), MagicDNS off.
        let c1 = LinkVPNStatus.tailscale(Self.statusJSON { status in
            status["BackendState"] = "Running"
            status["TUN"] = false
            status["TailscaleIPs"] = ["100.101.102.103", "fd7a:115c:a1e0::7"]
            status["CurrentTailnet"] = ["Name": "example.com", "MagicDNSEnabled": false] as [String: Any]
        })!
        let first = LinkAddresses.classify(interfaces: Self.founderMac, vpns: [c1])
        XCTAssertEqual(describe(LinkAddresses.offered(first)), ["192.168.1.20 local", "100.101.102.103 tailscale", "100.64.0.2 vpn",
                                                                 "fd7a:115c:a1e0::7 tailscale", "fd7a:115c:a1e0::2 vpn", "100.96.0.8 vpn unlikely"])
        XCTAssertNil(first.first { $0.address.host == "100.101.102.103" }?.interface, "on no interface")
        // C2: no CurrentTailnet at all: the name counts.
        let c2 = LinkVPNStatus.tailscale(Self.statusJSON { status in
            status["BackendState"] = "Running"
            status["TUN"] = false
            status["TailscaleIPs"] = ["100.101.102.103"]
            status["CurrentTailnet"] = NSNull()
        })!
        XCTAssertEqual(offered(Self.founderMac, vpns: [c2]).map(\.host).prefix(3), ["192.168.1.20", "studio-mac.tail1234.ts.net", "100.101.102.103"])
        // C3: and with no name, none.
        let c3 = LinkVPNStatus.tailscale(Self.statusJSON { status in
            status["BackendState"] = "Running"
            status["TailscaleIPs"] = ["100.101.102.103"]
            var node = status["Self"] as! [String: Any]
            node["DNSName"] = ""
            status["Self"] = node
        })!
        XCTAssertFalse(offered(Self.founderMac, vpns: [c3]).contains { $0.isName })
    }

    func testACachedTailscaleAnswerOnlyRelabels() {
        var cached = Self.running
        cached.fromCache = true
        // G: Tailscale quit (utun4 gone) within the five minutes its last answer stands in for: nothing of it is offered.
        XCTAssertEqual(offered(Self.founderMac, vpns: [cached]), offered(Self.founderMac, vpns: [Self.stopped]))
        // With its utun still up, the cached answer labels its addresses, and its name comes with them.
        let up = offered(Self.founderMac + Self.tailscaleTunnel, vpns: [cached])
        XCTAssertEqual(up.first { $0.host == "100.101.102.103" }?.kind, LinkAddress.Kind.tailscale)
        XCTAssertTrue(up.contains { $0.host == "studio-mac.tail1234.ts.net" })
        // A cached answer adds no address of its own.
        var userspace = Self.running
        userspace.fromCache = true
        userspace.ips = ["100.101.102.104"]
        XCTAssertFalse(offered(Self.founderMac + Self.tailscaleTunnel, vpns: [userspace]).contains { $0.host == "100.101.102.104" })
    }

    // MARK: Yours

    func testAddedAddressesNamesFirstAndAnAddedOneReplacesTheSameDetectedOne() {
        let added = ["Studio-Mac.Covee.Example.", "203.0.113.7:17447", "fd7a:115c:a1e0::2"]
        let entries = LinkAddresses.classify(interfaces: Self.founderMac, vpns: [Self.stopped], added: added, leftOut: ["100.96.0.8"])
        let list = LinkAddresses.offered(entries)
        XCTAssertEqual(list.map { $0.name(defaultPort: Link.port) }, ["192.168.1.20", "studio-mac.covee.example", "203.0.113.7:17447",
                                                                       "100.64.0.2", "fd7a:115c:a1e0::2"])
        XCTAssertEqual(list.map(\.kind), ["local", "added", "added", "vpn", "added"])
        XCTAssertEqual(list.filter { $0.kind == LinkAddress.Kind.added }.map(\.label), ["Added by you", "Added by you", "Added by you"])
        XCTAssertEqual(list[2].port, 17447)
        XCTAssertEqual(entries.filter { $0.address.host == "fd7a:115c:a1e0::2" }.count, 1, "shown once, as yours")
        XCTAssertNil(entries.first { $0.address.host == "fd7a:115c:a1e0::2" }?.interface)
        // Yours is offered whether its interface is up or not.
        XCTAssertTrue(offered([], added: ["100.64.0.2"]).contains { $0.host == "100.64.0.2" && $0.kind == LinkAddress.Kind.added })
        // An added one with the link's own port is the same address as the detected one.
        let samePort = LinkAddresses.classify(interfaces: Self.founderMac, added: ["100.64.0.2:7447"])
        XCTAssertEqual(samePort.filter { $0.address.host == "100.64.0.2" }.map(\.address.kind), ["added"])
    }

    func testLeftOutAreListedButNotOffered() {
        let entries = LinkAddresses.classify(interfaces: Self.founderMac, added: ["100.64.0.9"], leftOut: ["100.96.0.8", "100.64.0.9", "FD7A:115C:A1E0:0::2"])
        XCTAssertEqual(entries.last?.address.host, "100.96.0.8")
        XCTAssertEqual(entries.last?.leftOut, true)
        XCTAssertEqual(entries.first { $0.address.host == "fd7a:115c:a1e0::2" }?.leftOut, true, "written either way, it's one address")
        let list = LinkAddresses.offered(entries).map(\.host)
        XCTAssertFalse(list.contains("100.96.0.8"))
        XCTAssertFalse(list.contains("fd7a:115c:a1e0::2"))
        XCTAssertTrue(list.contains("100.64.0.9"), "yours are removed, never left out")
    }

    /// Paired devices names the address a phone came in on as this Mac found it, even when you added it.
    func testConnectedOverSaysHowTheMacFoundIt() {
        // The home router also gives the Wi-Fi a unique-local IPv6, which isn't offered (Bonjour reaches it).
        let interfaces = Self.founderMac + [LinkInterface(name: "en0", address: "fd12:3456:789a::1c2b", medium: .wifi)]
        let entries = LinkAddresses.classify(interfaces: interfaces, added: ["100.64.0.2", "studio-mac.covee.example", "100.64.0.77"])
        XCTAssertEqual(entries.first { $0.address.host == "100.64.0.2" }?.address.label, "Added by you")
        func over(_ host: String, _ interfaces: [LinkInterface] = interfaces, vpns: [LinkVPNStatus] = []) -> String {
            LinkAddresses.connectedOver(host, interfaces: interfaces, vpns: vpns, entries: entries)
        }
        XCTAssertEqual(over("100.64.0.2"), "100.64.0.2 (VPN)", "Covee's address you added is still Covee's")
        XCTAssertEqual(over("192.168.1.20"), "192.168.1.20 (Wi-Fi)")
        XCTAssertEqual(over("fd7a:115c:a1e0::2"), "fd7a:115c:a1e0::2 (VPN)")
        XCTAssertEqual(over("fd12:3456:789a::1c2b"), "the local network", "the Wi-Fi's IPv6, over Bonjour")
        XCTAssertEqual(over("fe80::1c2b:3aff:fe11:2233"), "the local network")
        XCTAssertEqual(over("100.64.0.77"), "100.64.0.77 (Added by you)", "one this Mac can't place keeps your label")
        XCTAssertEqual(over("127.0.0.1"), "127.0.0.1")
        // A VPN's own name, and Tailscale's word while it runs.
        var named = interfaces
        for index in named.indices where named[index].name == "utun0" { named[index].vpnName = "Covee" }
        XCTAssertEqual(over("100.64.0.2", named), "100.64.0.2 (Covee)")
        XCTAssertEqual(over("100.101.102.103", interfaces + Self.tailscaleTunnel, vpns: [Self.running]), "100.101.102.103 (Tailscale)")
    }

    // MARK: Other Macs

    func testEveryKindOfTunnel() {
        let interfaces = [
            LinkInterface(name: "ipsec0", address: "10.10.0.5", isPointToPoint: true),
            LinkInterface(name: "ppp0", address: "192.168.200.2", isPointToPoint: true),
            LinkInterface(name: "wg0", address: "10.0.0.2"),
            LinkInterface(name: "feth4021", address: "172.27.0.3"),
            LinkInterface(name: "tun0", address: "10.8.0.6"),
            LinkInterface(name: "utun5", address: "198.51.100.4", isPointToPoint: true),
            LinkInterface(name: "gif0", address: "2001:db8::1", isPointToPoint: true),
            LinkInterface(name: "xyz0", address: "10.1.2.3", isPointToPoint: true),
            LinkInterface(name: "zt3jn", address: "10.147.17.4"),
        ]
        let list = offered(interfaces)
        XCTAssertEqual(list.map(\.host), ["10.10.0.5", "192.168.200.2", "10.0.0.2", "172.27.0.3", "10.8.0.6", "10.1.2.3", "10.147.17.4"])
        XCTAssertTrue(list.allSatisfy { $0.kind == LinkAddress.Kind.vpn && $0.unlikely == nil })
    }

    /// A VPN that registered with the system says its own name; one that didn't, and anything not a tunnel, doesn't.
    func testAVPNsOwnNameLabelsItsAddresses() {
        let interfaces = [
            LinkInterface(name: "en0", address: "192.168.1.20", medium: .wifi, vpnName: "Home"),
            LinkInterface(name: "utun0", address: "100.64.0.2", isPointToPoint: true, vpnName: "Covee"),
            LinkInterface(name: "utun0", address: "fd7a:115c:a1e0::2", isPointToPoint: true, vpnName: "Covee"),
            LinkInterface(name: "utun3", address: "10.8.0.6", isPointToPoint: true),
        ]
        XCTAssertEqual(offered(interfaces).map(\.label), ["Wi-Fi", "Covee", "VPN", "Covee"])
        XCTAssertTrue(offered(interfaces).dropFirst().allSatisfy { $0.kind == LinkAddress.Kind.vpn })
    }

    func testWiFiEthernetAndUnknown() {
        let interfaces = [
            LinkInterface(name: "en0", address: "192.168.1.20", medium: .wifi),
            LinkInterface(name: "en1", address: "192.168.1.30", medium: .wired),
            LinkInterface(name: "en2", address: "192.168.1.40"),
            // A carrier hotspot's address on en* is still the local network.
            LinkInterface(name: "en3", address: "100.70.0.5"),
        ]
        XCTAssertEqual(offered(interfaces).map(\.label), ["Wi-Fi", "Ethernet", "Local network", "Local network"])
        XCTAssertTrue(offered(interfaces).allSatisfy { $0.kind == LinkAddress.Kind.local })
    }

    func testWhatIsNeverOffered() {
        let never: [LinkInterface] = [
            LinkInterface(name: "en0", address: "192.168.1.20", isUp: false),
            LinkInterface(name: "lo0", address: "127.0.0.1", isLoopback: true),
            LinkInterface(name: "en0", address: "127.0.0.2"),
            LinkInterface(name: "en0", address: "0.0.0.0"),
            LinkInterface(name: "en0", address: "169.254.1.1"),
            LinkInterface(name: "en0", address: "224.0.0.251"),
            LinkInterface(name: "en0", address: "fd00::5"),
            LinkInterface(name: "en0", address: "2001:db8::5"),
            LinkInterface(name: "utun2", address: "fe80::1%utun2", isPointToPoint: true),
            LinkInterface(name: "utun2", address: "::1", isPointToPoint: true),
            LinkInterface(name: "utun2", address: "::", isPointToPoint: true),
            LinkInterface(name: "utun2", address: "ff02::1", isPointToPoint: true),
            LinkInterface(name: "utun2", address: "::ffff:10.0.0.1", isPointToPoint: true),
            LinkInterface(name: "utun2", address: "8.8.4.4", isPointToPoint: true),
            LinkInterface(name: "utun2", address: "2606:4700::1", isPointToPoint: true),
            LinkInterface(name: "utun2", address: "not an address", isPointToPoint: true),
            LinkInterface(name: "bridge100", address: "192.168.64.1"),
            LinkInterface(name: "vmenet0", address: "192.168.65.1"),
            LinkInterface(name: "vnic0", address: "10.211.55.2"),
            LinkInterface(name: "awdl0", address: "fd00::1"),
            LinkInterface(name: "llw0", address: "fd00::2"),
            LinkInterface(name: "anpi0", address: "10.0.5.1"),
            LinkInterface(name: "ap1", address: "10.0.6.1"),
            LinkInterface(name: "stf0", address: "fd00::3", isPointToPoint: true),
            LinkInterface(name: "gif0", address: "10.0.7.1", isPointToPoint: true),
        ]
        for interface in never {
            XCTAssertEqual(offered([interface]), [], "\(interface.name) \(interface.address)")
        }
    }

    // MARK: Tailscale's word

    func testTailscaleStatusReads() throws {
        let stopped = try XCTUnwrap(LinkVPNStatus.tailscale(Self.stoppedJSON))
        XCTAssertFalse(stopped.isRunning)
        XCTAssertEqual(stopped.ips, ["100.80.1.33"])
        XCTAssertEqual(stopped.dnsName, "studio-mac.tail1234.ts.net", "read, though only a running one counts")
        let running = try XCTUnwrap(LinkVPNStatus.tailscale(Self.runningJSON))
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.ips, ["100.101.102.103", "fd7a:115c:a1e0::7"])
        XCTAssertEqual(running.dnsName, "studio-mac.tail1234.ts.net")
        XCTAssertEqual(running.kind, LinkAddress.Kind.tailscale)
        XCTAssertEqual(running.label, "Tailscale")
        XCTAssertFalse(running.fromCache)

        XCTAssertEqual(LinkVPNStatus.tailscale(Self.statusJSON { $0["BackendState"] = "NeedsLogin" })?.isRunning, false)
        // Top-level IPs only, then Self's only.
        let topOnly = LinkVPNStatus.tailscale(Self.statusJSON { status in
            status["TailscaleIPs"] = ["100.101.102.103"]
            status["Self"] = ["DNSName": "studio-mac.tail1234.ts.net."]
        })
        XCTAssertEqual(topOnly?.ips, ["100.101.102.103"])
        let selfOnly = LinkVPNStatus.tailscale(Self.statusJSON { status in
            status["TailscaleIPs"] = nil
            status["Self"] = ["TailscaleIPs": ["100.101.102.105"]]
        })
        XCTAssertEqual(selfOnly?.ips, ["100.101.102.105"])
        XCTAssertNil(selfOnly?.dnsName)
        // MagicDNS: absent and null mean the name counts; an object says.
        XCTAssertEqual(LinkVPNStatus.tailscale(Self.statusJSON { $0["CurrentTailnet"] = nil })?.dnsName, "studio-mac.tail1234.ts.net")
        XCTAssertEqual(LinkVPNStatus.tailscale(Self.statusJSON { $0["CurrentTailnet"] = NSNull() })?.dnsName, "studio-mac.tail1234.ts.net")
        XCTAssertNil(LinkVPNStatus.tailscale(Self.statusJSON { $0["CurrentTailnet"] = ["MagicDNSEnabled": false] })?.dnsName)
        XCTAssertNil(LinkVPNStatus.tailscale(Self.statusJSON { $0["CurrentTailnet"] = ["Name": "example.com"] })?.dnsName)
        XCTAssertNil(LinkVPNStatus.tailscale(Self.statusJSON { status in
            var node = status["Self"] as! [String: Any]
            node["DNSName"] = ""
            status["Self"] = node
        })?.dnsName)
        // Not a status.
        XCTAssertNil(LinkVPNStatus.tailscale(Data("garbage".utf8)))
        XCTAssertNil(LinkVPNStatus.tailscale(Data("[1, 2]".utf8)))
        XCTAssertNil(LinkVPNStatus.tailscale(Data("{\"Version\": \"1.80.0\"}".utf8)))
        XCTAssertNil(LinkVPNStatus.tailscale(Data()))
    }

    // MARK: What people type

    func testWhatPeopleTypeReads() throws {
        func read(_ text: String) throws -> LinkAddresses.Typed { try LinkAddresses.parse(text).get() }
        XCTAssertEqual(try read("studio-mac.covee.example"), LinkAddresses.Typed(host: "studio-mac.covee.example", port: nil))
        XCTAssertEqual(try read("  Studio-Mac.Covee.Example.  ").text, "studio-mac.covee.example")
        XCTAssertEqual(try read("100.64.0.9:7450"), LinkAddresses.Typed(host: "100.64.0.9", port: 7450))
        XCTAssertEqual(try read("100.64.0.9:7450").text, "100.64.0.9:7450")
        XCTAssertEqual(try read("[fd7a:115c:a1e0::2]:7450").text, "[fd7a:115c:a1e0::2]:7450")
        XCTAssertEqual(try read("[fd7a:115c:a1e0::2]").text, "fd7a:115c:a1e0::2")
        XCTAssertEqual(try read("fd7a:115c:a1e0::2").text, "fd7a:115c:a1e0::2")
        XCTAssertEqual(try read("studio").text, "studio")
        XCTAssertEqual(try read("studio:7450").port, 7450)
        XCTAssertEqual(try read("1password.example").host, "1password.example")
        XCTAssertEqual(try read("010.001.0.9").host, "10.1.0.9", "decimal, whatever the zeros")
        XCTAssertEqual(try read("mac-1.local").host, "mac-1.local")
    }

    func testWhatIsntAnAddressIsRefused() {
        func problem(_ text: String) -> LinkAddresses.Problem? {
            if case .failure(let problem) = LinkAddresses.parse(text) { return problem }
            return nil
        }
        XCTAssertEqual(problem(""), .empty)
        XCTAssertEqual(problem("   "), .empty)
        for unreadable in ["192.168.1", "999.1.1.1", "1.2.3.4.5", "http://studio", "http://studio:7447", "studio/notes", "studio mac",
                           "sam@studio", "-studio.example", "studio-.example", "studio..example", "fe80::1%en0", "[fe80::1%en0]:7447",
                           "[fd7a::2", "[fd7a::2]7447", "[100.64.0.2]:7447", "studio:", "studio:abc", "fd7a::2:zz", "[]",
                           String(repeating: "a", count: 64) + ".example", "studio_mac.example", "café.example", "12345"] {
            XCTAssertEqual(problem(unreadable), .unreadable, unreadable)
        }
        for badPort in ["studio:0", "studio:65536", "100.64.0.2:70000", "[fd7a::2]:0", "studio:99999999999999999999"] {
            XCTAssertEqual(problem(badPort), .port, badPort)
        }
        XCTAssertEqual(LinkAddresses.Problem.unreadable.words(port: 7450),
                       "Binders can't read that as an address. Type a name or an IP address, with :port at the end only if it isn't 7450. An IPv6 address with a port goes in brackets: [fd7a::2]:7450.")
        XCTAssertEqual(LinkAddresses.Problem.tooMany.words(port: 7447), "You can add up to 8 addresses. Remove one first.")
        // An IPv6 address with a port and no brackets can't be told from a longer address: it's kept as that address,
        // which is why the words say brackets.
        XCTAssertEqual(try? LinkAddresses.parse("fd7a:115c:a1e0::2:7450").get(), LinkAddresses.Typed(host: "fd7a:115c:a1e0::2:7450", port: nil))
    }

    func testLookalikeNamesAreRefused() {
        func problem(_ text: String) -> LinkAddresses.Problem? {
            if case .failure(let problem) = LinkAddresses.parse(text) { return problem }
            return nil
        }
        // Each looks like an ASCII name on screen, and isn't one.
        let lookalikes = [
            "studio\u{200D}-mac.covee.example",     // a zero-width joiner after a letter: one Character with it
            "studio-mac\u{0332}.covee.example",     // a combining mark that composes with nothing
            "STUD\u{0130}O-MAC.covee.example",      // "İ", which lowercases to "i" and a combining dot
            "\u{212A}itchen-mac.covee.example",     // the Kelvin sign, which lowercases to "k"
            "studio-mac.covee.examp\u{200B}le",     // a zero-width space
        ]
        for text in lookalikes {
            XCTAssertNil(LinkAddresses.canonicalHost(text), text.debugDescription)
            XCTAssertEqual(problem(text), .unreadable, text.debugDescription)
        }
        // A digit with a combining mark isn't a digit: not a port, nor part of an IPv4 address.
        XCTAssertEqual(problem("studio:7\u{0301}450"), .unreadable)
        XCTAssertEqual(problem("100.64.0.2\u{0301}"), .unreadable)
        XCTAssertFalse(Character("7\u{0301}").isASCIIDigitCharacter)
        XCTAssertTrue(Character("7").isASCIIDigitCharacter)
        // In a hello, such a host is skipped on its own.
        let heard = LinkAddress.list(from: [["host": "studio\u{200D}-mac.covee.example", "kind": "vpn", "label": "VPN"],
                                            ["host": "studio-mac.covee.example", "kind": "added", "label": "Added by you"]])
        XCTAssertEqual(heard?.map(\.host), ["studio-mac.covee.example"])
    }

    func testIPv6IsWrittenOneWay() throws {
        XCTAssertEqual(try LinkAddresses.parse("FD7A:115C:A1E0:0:0:0:0:2").get().host, "fd7a:115c:a1e0::2")
        XCTAssertEqual(try LinkAddresses.parse("[FD7A:115C:A1E0::0002]:7450").get().text, "[fd7a:115c:a1e0::2]:7450")
        let address = LinkAddress(host: "fd7a:115c:a1e0::2", kind: LinkAddress.Kind.vpn, label: "VPN")
        XCTAssertEqual(address.pairingText(port: 7448), "[fd7a:115c:a1e0::2]:7448")
        XCTAssertEqual(address.name(defaultPort: 7447), "fd7a:115c:a1e0::2")
        var withPort = address
        withPort.port = 7450
        XCTAssertEqual(withPort.name(defaultPort: 7447), "[fd7a:115c:a1e0::2]:7450")
        withPort.port = 7447
        XCTAssertEqual(withPort.name(defaultPort: 7447), "fd7a:115c:a1e0::2", "the link's own port isn't shown")
        XCTAssertEqual(address.key(defaultPort: 7447), "fd7a:115c:a1e0::2|7447")
        XCTAssertEqual(LinkAddress(host: "studio", port: 7450, kind: "added", label: "").name(defaultPort: 7447), "studio:7450")
        XCTAssertEqual(LinkAddress(host: "100.64.0.2", kind: "vpn", label: "").pairingText(port: 7448), "100.64.0.2:7448")
        // An interface's address comes in the same form, whatever getifaddrs wrote.
        let interface = LinkInterface(name: "utun0", address: "FD7A:115C:A1E0:0000::2%utun0", isPointToPoint: true)
        XCTAssertEqual(offered([interface]).map(\.host), ["fd7a:115c:a1e0::2"])
    }

    func testTheLinksPortIsDropped() throws {
        XCTAssertEqual(try LinkAddresses.parse("100.64.0.2:7447").get().dropping(port: 7447).text, "100.64.0.2")
        XCTAssertEqual(try LinkAddresses.parse("[fd7a:115c:a1e0::2]:7447").get().dropping(port: 7447).text, "fd7a:115c:a1e0::2")
        XCTAssertEqual(try LinkAddresses.parse("studio:7450").get().dropping(port: 7447).text, "studio:7450")
        XCTAssertNil(try LinkAddresses.parse("100.64.0.2:7447").get().dropping(port: 7447).port)
    }

    // MARK: The pairing code

    func testThePairingCode() {
        func code(_ interfaces: [LinkInterface], added: [String] = []) -> [String] {
            LinkAddresses.pairingAddresses(offered(interfaces, vpns: [Self.stopped], added: added), port: 7448)
        }
        XCTAssertEqual(code(Self.founderMac), ["192.168.1.20:7448", "100.64.0.2:7448", "[fd7a:115c:a1e0::2]:7448"])
        XCTAssertEqual(code(Self.founderMac, added: ["studio-mac.covee.example"]),
                       ["192.168.1.20:7448", "100.64.0.2:7448", "studio-mac.covee.example:7448", "[fd7a:115c:a1e0::2]:7448"])
        // An address with its own port isn't forwarded by anything at the pairing port.
        XCTAssertFalse(code(Self.founderMac, added: ["203.0.113.7:17447"]).contains { $0.hasPrefix("203.0.113.7") })
        // At most five.
        let many = (1...8).map { LinkInterface(name: "utun\($0 + 10)", address: "10.0.\($0).1", isPointToPoint: true) }
        XCTAssertEqual(code(many).count, LinkAddresses.pairingLimit)
        // One too long for the budget is skipped, and a shorter one after it still goes.
        let long = String(repeating: "a", count: 60) + "." + String(repeating: "b", count: 40) + ".example"
        let budget = code([LinkInterface(name: "en0", address: "192.168.1.20", medium: .wifi)], added: [long, "studio.example"])
        XCTAssertEqual(budget, ["192.168.1.20:7448", "studio.example:7448"])
        XCTAssertLessThanOrEqual(budget.joined().utf8.count, LinkAddresses.pairingBudget)
        // Three local addresses, two names and Covee: Covee's IPv4 comes ahead of both names.
        let busy = [LinkInterface(name: "en0", address: "192.168.1.20", medium: .wifi), LinkInterface(name: "en1", address: "192.168.2.20"),
                    LinkInterface(name: "en2", address: "192.168.3.20"), LinkInterface(name: "utun0", address: "100.64.0.2", isPointToPoint: true)]
        XCTAssertEqual(code(busy, added: ["one.example", "two.example"]),
                       ["192.168.1.20:7448", "192.168.2.20:7448", "192.168.3.20:7448", "100.64.0.2:7448", "one.example:7448"])
        // Each reads back with the split every iPhone build has.
        for text in code(Self.founderMac, added: ["studio-mac.covee.example"]) {
            XCTAssertNotNil(LinkClient.split(text), text)
        }
    }

    // MARK: On the wire

    func testHelloAddressesReadBack() {
        XCTAssertNil(LinkAddress.list(from: nil))
        XCTAssertNil(LinkAddress.list(from: "192.168.1.20"))
        XCTAssertNil(LinkAddress.list(from: ["host": "192.168.1.20"]))
        XCTAssertEqual(LinkAddress.list(from: [Any]()), [])
        let good: [String: Any] = ["host": "100.64.0.2", "port": 7447, "kind": "vpn", "label": "VPN"]
        let items: [Any] = [
            ["port": 7447, "kind": "vpn"],
            ["host": "100.64.0.3", "port": 70000],
            ["host": "100.64.0.4", "port": true],
            ["host": "", "kind": "vpn"],
            ["host": "not a host!", "kind": "vpn"],
            "100.64.0.5",
            good,
            ["host": "FD7A:115C:A1E0::2", "kind": "something-new", "label": "Mesh", "unlikely": true],
        ]
        let list = LinkAddress.list(from: items)
        XCTAssertEqual(list, [LinkAddress(host: "100.64.0.2", port: 7447, kind: "vpn", label: "VPN"),
                              LinkAddress(host: "fd7a:115c:a1e0::2", kind: "something-new", label: "Mesh", unlikely: true)])
        let lots = (0..<20).map { ["host": "10.0.0.\($0 + 1)", "kind": "vpn", "label": "VPN"] }
        XCTAssertEqual(LinkAddress.list(from: lots)?.count, LinkAddresses.helloLimit)
        // What the Mac sends is what the phone reads, through JSON.
        let sent = LinkAddresses.offered(LinkAddresses.classify(interfaces: Self.founderMac, added: ["studio-mac.covee.example"]))
            .map { address -> LinkAddress in
                var filled = address
                filled.port = filled.port ?? 7447
                return filled
            }
        let wire = try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: ["addresses": sent.map(\.jsonObject)])) as! [String: Any]
        XCTAssertEqual(LinkAddress.list(from: wire["addresses"]), sent)
        XCTAssertNil(LinkAddress(host: "100.64.0.2", kind: "vpn", label: "VPN").jsonObject["unlikely"])
        // Kept on the phone and read back.
        let kept = try! JSONDecoder().decode([LinkAddress].self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(kept, sent)
    }
}
