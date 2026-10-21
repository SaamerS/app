import XCTest
@testable import BindersKit

/// What the phone keeps about its Mac, and the order it tries the Mac's addresses in. The founder's phone was paired by
/// Mac 0.8.0, whose code held only the Wi-Fi address, and must reach the Mac over Covee without pairing again.
final class LinkCandidatesTests: XCTestCase {
    static let device = UUID(uuidString: "6A1F0C2E-5B3D-4E7A-9C11-2D4F6B8A0E13")!
    static let wifi = LinkAddress(host: "192.168.1.20", port: 7447, kind: "local", label: "Wi-Fi")
    static let coveeName = LinkAddress(host: "studio-mac.covee.example", port: 7447, kind: "added", label: "Added by you")
    static let covee4 = LinkAddress(host: "100.64.0.2", port: 7447, kind: "vpn", label: "VPN")
    static let covee6 = LinkAddress(host: "fd7a:115c:a1e0::2", port: 7447, kind: "vpn", label: "VPN")
    static let warp = LinkAddress(host: "100.96.0.8", port: 7447, kind: "vpn", label: "VPN", unlikely: true)
    /// The hello of section 4.2: Wi-Fi, the name added on the Mac, Covee's two, WARP.
    static let learned = [wifi, coveeName, covee4, covee6, warp]
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A record as iPhone builds 6-26 wrote it: five keys.
    static let oldRecord = """
        {"device":"6A1F0C2E-5B3D-4E7A-9C11-2D4F6B8A0E13","name":"Studio Mac","hosts":["192.168.1.20"],"port":7447,"lastHost":"192.168.1.20"}
        """

    private func decode(_ text: String) throws -> PairedMac {
        try JSONDecoder().decode(PairedMac.self, from: Data(text.utf8))
    }

    private func paired(hosts: [String] = ["192.168.1.20"], lastHost: String? = nil, learned: [LinkAddress]? = nil, added: [String]? = nil,
                     worked: [LinkWorked]? = nil) -> PairedMac {
        PairedMac(device: Self.device, name: "Studio Mac", hosts: hosts, port: 7447, lastHost: lastHost, learned: learned, added: added, worked: worked)
    }

    // MARK: On disk

    func testAPairedMacFromBefore081StillReads() throws {
        let mac = try decode(Self.oldRecord)
        XCTAssertEqual(mac.device, Self.device)
        XCTAssertEqual(mac.hosts, ["192.168.1.20"])
        XCTAssertEqual(mac.lastHost, "192.168.1.20")
        XCTAssertNil(mac.lastPort)
        XCTAssertNil(mac.learned)
        XCTAssertNil(mac.added)
        XCTAssertNil(mac.worked)
        let candidates = mac.candidates(bonjour: false)
        XCTAssertEqual(candidates.map(\.name), ["192.168.1.20"])
        XCTAssertEqual(candidates.first?.atOnce, true)
        XCTAssertEqual(candidates.first?.label, "From pairing")
        // And one with no last host at all.
        XCTAssertNil(try decode(#"{"device":"6A1F0C2E-5B3D-4E7A-9C11-2D4F6B8A0E13","name":"Studio Mac","hosts":[],"port":7447}"#).lastHost)
        // Written the old way when nothing new is set, so a downgraded phone reads it as it always did.
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mac)) as? [String: Any]
        XCTAssertEqual(Set(written.map { Array($0.keys) } ?? []), ["device", "name", "hosts", "port", "lastHost"])
    }

    func testAPairedMacRoundTrips() throws {
        let full = PairedMac(device: Self.device, name: "Studio Mac", hosts: ["192.168.1.20", "100.64.0.2"], port: 7447, lastHost: "100.64.0.9",
                             lastPort: 7450, learned: Self.learned, added: ["studio-mac.covee.example", "100.64.0.9:7450"],
                             worked: [LinkWorked(host: "100.64.0.2", port: 7447, label: "VPN", at: Self.now)])
        let data = try JSONEncoder().encode(full)
        XCTAssertEqual(try JSONDecoder().decode(PairedMac.self, from: data), full)
        // An iPhone build from before reads it too, and only sees the keys it knows.
        struct Before: Codable {
            var device: UUID
            var name: String
            var hosts: [String]
            var port: UInt16
            var lastHost: String?
        }
        let before = try JSONDecoder().decode(Before.self, from: data)
        XCTAssertEqual(before.hosts, ["192.168.1.20", "100.64.0.2"])
        XCTAssertEqual(before.lastHost, "100.64.0.9")
    }

    func testADamagedNewFieldKeepsThePairing() throws {
        let damaged = try decode("""
            {"device":"6A1F0C2E-5B3D-4E7A-9C11-2D4F6B8A0E13","name":"Studio Mac","hosts":["192.168.1.20"],"port":7447,
             "lastHost":"100.64.0.2","lastPort":-1,"learned":"not a list","added":5,"worked":"nope"}
            """)
        XCTAssertEqual(damaged.lastHost, "100.64.0.2")
        XCTAssertNil(damaged.lastPort)
        XCTAssertNil(damaged.learned)
        XCTAssertNil(damaged.added)
        XCTAssertNil(damaged.worked)
        let mixed = try decode("""
            {"device":"6A1F0C2E-5B3D-4E7A-9C11-2D4F6B8A0E13","name":"Studio Mac","hosts":["192.168.1.20"],"port":7447,
             "learned":[{"host":"100.64.0.2","port":7447,"kind":"vpn","label":"VPN"},{"port":7447},7,
                        {"host":"fd7a:115c:a1e0::2","port":70000,"kind":"vpn"},{"host":""}],
             "added":["studio-mac.covee.example",3,"100.64.0.9:7450"],
             "worked":[{"host":"100.64.0.2","port":7447,"label":"VPN","at":0},{"host":"x"},{"host":"100.64.0.9","port":7450,"label":"","at":1}]}
            """)
        XCTAssertEqual(mixed.learned?.map(\.host), ["100.64.0.2", "fd7a:115c:a1e0::2"])
        XCTAssertNil(mixed.learned?.last?.port, "a port that can't be is the link's")
        XCTAssertEqual(mixed.learned?.last?.label, "")
        XCTAssertEqual(mixed.added, ["studio-mac.covee.example", "100.64.0.9:7450"])
        XCTAssertEqual(mixed.worked?.map(\.host), ["100.64.0.2", "100.64.0.9"])
        // Missing what every record has, it isn't a paired Mac.
        XCTAssertThrowsError(try decode(#"{"name":"Studio Mac","hosts":[],"port":7447}"#))
    }

    // MARK: His phone

    func testHisPhoneFrom080KeepsCoveeWhenAHelloMissesIt() throws {
        var mac = try decode(Self.oldRecord)
        // The first hello at home after the update.
        XCTAssertTrue(mac.learn([Self.wifi, Self.covee4, Self.covee6, Self.warp]))
        // Away, Covee won.
        let covee = try XCTUnwrap(mac.candidates(bonjour: false).first { $0.host == "100.64.0.2" })
        XCTAssertTrue(mac.used(covee, at: Self.now))
        XCTAssertEqual(mac.lastHost, "100.64.0.2")
        XCTAssertEqual(mac.worked, [LinkWorked(host: "100.64.0.2", port: 7447, label: "VPN", at: Self.now)])
        // A hello while Covee was down on the Mac.
        XCTAssertTrue(mac.learn([Self.wifi, Self.warp]))
        let after = mac.candidates(bonjour: false, at: Self.now)
        XCTAssertEqual(after.map(\.name), ["100.64.0.2", "192.168.1.20", "100.96.0.8"])
        XCTAssertEqual(after.first?.atOnce, true)
        XCTAssertEqual(after.first?.label, "VPN · worked before")
        XCTAssertEqual(after[1].label, "Wi-Fi · in the pairing code")

        // The state the review found: the last good address in no list, nothing in worked.
        var found = paired(hosts: ["192.168.1.20"], lastHost: "100.64.0.2")
        _ = found.learn([Self.wifi, Self.warp])
        let last = try XCTUnwrap(found.candidates(bonjour: false).first)
        XCTAssertEqual(last.name, "100.64.0.2")
        XCTAssertTrue(last.atOnce)
        XCTAssertEqual(last.label, "Used last time")
        XCTAssertTrue(last.vouched)
    }

    func testTheLastGoodAddressIsAlwaysDialledAtOnce() {
        let list = paired(lastHost: "100.64.0.77", learned: Self.learned).candidates(bonjour: true)
        XCTAssertEqual(list.prefix(2).map(\.name), ["Bonjour", "100.64.0.77"])
        XCTAssertEqual(list.prefix(2).map(\.atOnce), [true, true])
        XCTAssertEqual(list[1].label, "Used last time")
        XCTAssertTrue(list.dropFirst(2).allSatisfy { !$0.atOnce })
        XCTAssertTrue(list[1].workedOnly, "it can be removed, which forgets it")
    }

    func testAnAddressThatWorkedIsKept() throws {
        var mac = paired(learned: Self.learned)
        func candidate(_ host: String, _ port: UInt16 = 7447) -> LinkCandidate {
            LinkCandidate(id: "\(host)|\(port)", host: host, port: port, name: host, label: "", source: .learned)
        }
        // At most four, newest first.
        for (offset, host) in ["10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5"].enumerated() {
            XCTAssertTrue(mac.used(candidate(host), at: Self.now.addingTimeInterval(Double(offset))))
        }
        XCTAssertEqual(mac.worked?.map(\.host), ["10.0.0.5", "10.0.0.4", "10.0.0.3", "10.0.0.2"])
        // The same one again within a day writes nothing; a day later, its date moves.
        XCTAssertFalse(mac.used(candidate("10.0.0.5"), at: Self.now.addingTimeInterval(3_600)))
        XCTAssertEqual(mac.worked?.first?.at, Self.now.addingTimeInterval(4))
        XCTAssertTrue(mac.used(candidate("10.0.0.5"), at: Self.now.addingTimeInterval(90_000)))
        XCTAssertEqual(mac.worked?.first?.at, Self.now.addingTimeInterval(90_000))
        // Older than 30 days: not tried, and gone at the next win.
        let later = Self.now.addingTimeInterval(31 * 86_400)
        XCTAssertFalse(mac.candidates(bonjour: false, at: later).contains { $0.host == "10.0.0.2" })
        XCTAssertTrue(mac.used(candidate("100.64.0.2"), at: later))
        XCTAssertEqual(mac.worked?.map(\.host), ["100.64.0.2", "10.0.0.5"])
        XCTAssertEqual(mac.worked?.first?.label, "VPN", "with the Mac's word for it")
        // Bonjour changes nothing.
        let before = mac
        let bonjour = try XCTUnwrap(mac.candidates(bonjour: true).first)
        XCTAssertFalse(mac.used(bonjour, at: later))
        XCTAssertEqual(mac, before)
        // A win at its own port keeps the port.
        XCTAssertTrue(mac.used(candidate("100.64.0.9", 7450), at: later))
        XCTAssertEqual(mac.lastHost, "100.64.0.9")
        XCTAssertEqual(mac.lastPort, 7450)
        XCTAssertEqual(mac.candidates(bonjour: false, at: later).first?.name, "100.64.0.9:7450")
    }

    // MARK: The order

    func testTheWorkedExample() {
        let mac = paired(hosts: ["192.168.1.20"], lastHost: "100.64.0.2", learned: Self.learned,
                      added: ["studio-mac.covee.example", "100.64.0.9:7450"],
                      worked: [LinkWorked(host: "100.64.0.2", port: 7447, label: "VPN", at: Self.now)])
        let list = mac.candidates(bonjour: true, at: Self.now)
        XCTAssertEqual(list.map(\.name), ["Bonjour", "100.64.0.2", "studio-mac.covee.example", "100.64.0.9:7450", "192.168.1.20",
                                          "fd7a:115c:a1e0::2", "100.96.0.8"])
        XCTAssertEqual(list.map(\.label), ["On this network", "VPN", "Added on your Mac · added on this iPhone", "Added on this iPhone",
                                           "Wi-Fi · in the pairing code", "VPN", "VPN · rarely reachable"])
        XCTAssertEqual(list.map(\.atOnce), [true, true, false, false, false, false, false])
        XCTAssertEqual(Set(list.map(\.id)).count, list.count, "each address once")
        XCTAssertEqual(list.map(\.vouched), [true, true, true, false, true, true, true])
        XCTAssertEqual(list.map(\.addedHere), [false, false, true, true, false, false, false])
        XCTAssertEqual(list.last?.unlikely, true)
    }

    func testEachAddressOnceWithTheBestLabel() {
        let mac = paired(hosts: ["100.64.0.2"], lastHost: "100.64.0.2", learned: [Self.covee4], added: ["100.64.0.2:7447"],
                      worked: [LinkWorked(host: "100.64.0.2", port: 7447, label: "VPN", at: Self.now)])
        let list = mac.candidates(bonjour: false, at: Self.now)
        XCTAssertEqual(list.map(\.name), ["100.64.0.2"])
        XCTAssertEqual(list.first?.label, "VPN · added on this iPhone · in the pairing code")
        XCTAssertEqual(list.first?.source, .learned)
        XCTAssertEqual(list.first?.addedHere, true)
        XCTAssertEqual(list.first?.fromPairing, true)
        XCTAssertEqual(list.first?.workedOnly, false)
        // Worked only, with what it was: "VPN · worked before", or "Worked before" when nothing said.
        let workedOnly = PairedMac(device: Self.device, name: "Studio Mac", hosts: [], port: 7447,
                                   worked: [LinkWorked(host: "100.64.0.2", port: 7447, label: "VPN", at: Self.now),
                                            LinkWorked(host: "100.64.0.3", port: 7447, label: "", at: Self.now)])
        XCTAssertEqual(workedOnly.candidates(bonjour: false, at: Self.now).map(\.label), ["VPN · worked before", "Worked before"])
        XCTAssertTrue(workedOnly.candidates(bonjour: false, at: Self.now).allSatisfy(\.workedOnly))
        // The Mac's kinds, as the phone says them.
        let kinds = paired(hosts: [], learned: [LinkAddress(host: "10.0.0.1", kind: "local", label: ""),
                                             LinkAddress(host: "10.0.0.2", kind: "vpn", label: ""),
                                             LinkAddress(host: "10.0.0.3", kind: "tailscale", label: ""),
                                             LinkAddress(host: "10.0.0.4", kind: "added", label: "Added by you"),
                                             LinkAddress(host: "10.0.0.5", kind: "something-new", label: "Mesh"),
                                             LinkAddress(host: "10.0.0.6", kind: "something-new", label: "")])
        XCTAssertEqual(kinds.candidates(bonjour: false).map(\.label),
                       ["Local network", "VPN", "Tailscale", "Added on your Mac", "Mesh", "From your Mac"])
        // One written two ways is one address.
        let twoWays = paired(hosts: ["FD7A:115C:A1E0:0::2"], learned: [Self.covee6])
        XCTAssertEqual(twoWays.candidates(bonjour: false).map(\.name), ["fd7a:115c:a1e0::2"])
    }

    func testThePortMakesItAnotherAddress() {
        let list = paired(hosts: [], learned: [Self.covee4], added: ["100.64.0.2:7450"]).candidates(bonjour: false)
        XCTAssertEqual(list.map(\.name), ["100.64.0.2:7450", "100.64.0.2"])
        XCTAssertEqual(list.map(\.port), [7450, 7447])
        XCTAssertEqual(list.map(\.id), ["100.64.0.2|7450", "100.64.0.2|7447"])
    }

    func testATestedAddressStartsAtOnce() {
        let list = paired(lastHost: "192.168.1.20", learned: Self.learned).candidates(bonjour: false, preferred: "fd7a:115c:a1e0::2|7447")
        XCTAssertEqual(list.prefix(2).map(\.name), ["192.168.1.20", "fd7a:115c:a1e0::2"])
        XCTAssertEqual(list.prefix(2).map(\.atOnce), [true, true])
        XCTAssertEqual(list.filter(\.atOnce).count, 2)
    }

    func testAMac080HasOnlyThePairedHosts() {
        let list = paired(hosts: ["192.168.1.20", "100.64.0.2"]).candidates(bonjour: true)
        XCTAssertEqual(list.map(\.name), ["Bonjour", "192.168.1.20", "100.64.0.2"])
        XCTAssertEqual(list.dropFirst().map(\.label), ["From pairing", "From pairing"])
        XCTAssertEqual(list.dropFirst().map(\.vouched), [false, false], "a stale address from the code could be anything now")
        XCTAssertEqual(list.map(\.atOnce), [true, false, false])
    }

    func testTheDialIsCapped() {
        let many = (1...20).map { LinkAddress(host: "10.0.0.\($0)", port: 7447, kind: "vpn", label: "VPN") }
        let mac = paired(hosts: ["192.168.1.20"], learned: many)
        XCTAssertEqual(mac.candidates(bonjour: true).count, LinkCandidates.dialLimit + 1, "twelve addresses, and Bonjour")
        XCTAssertEqual(mac.candidates(bonjour: false).count, LinkCandidates.dialLimit)
        XCTAssertEqual(mac.candidates(bonjour: false, limit: nil).count, 21, "the Your Mac list has them all")
    }

    // MARK: Changes

    func testAddingAndRemoving() {
        var mac = paired(lastHost: "100.64.0.9", learned: Self.learned)
        XCTAssertNil(mac.add("100.64.0.9"))
        XCTAssertEqual(mac.add("100.64.0.9:7447"), .duplicate, "the link's own port is the same address")
        XCTAssertNil(mac.add("[FD7A:115C:A1E0::2]:7447"))
        XCTAssertNil(mac.add("100.64.0.2"), "one the Mac lists becomes yours")
        XCTAssertNil(mac.add("Studio-Mac.Covee.Example."), "a learned name too")
        XCTAssertEqual(mac.add("not an address!"), .unreadable)
        XCTAssertEqual(mac.add("studio:0"), .port)
        XCTAssertEqual(mac.added, ["100.64.0.9", "fd7a:115c:a1e0::2", "100.64.0.2", "studio-mac.covee.example"])
        XCTAssertEqual(mac.id(ofTyped: "100.64.0.9:7447"), "100.64.0.9|7447")
        for host in ["10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4"] { XCTAssertNil(mac.add(host)) }
        XCTAssertEqual(mac.add("10.0.0.5"), .tooMany)
        // Remove clears the last good address when it's that one, and what worked.
        mac.worked = [LinkWorked(host: "100.64.0.9", port: 7447, label: "", at: Self.now)]
        mac.removeAdded("100.64.0.9|7447")
        XCTAssertFalse(mac.added?.contains("100.64.0.9") ?? false)
        XCTAssertNil(mac.lastHost)
        XCTAssertNil(mac.worked)
        XCTAssertFalse(mac.candidates(bonjour: false, limit: nil).contains { $0.host == "100.64.0.9" })
        // One the Mac lists stays, as the Mac's.
        mac.removeAdded("100.64.0.2|7447")
        XCTAssertEqual(mac.candidates(bonjour: false, limit: nil).first { $0.host == "100.64.0.2" }?.label, "VPN")
        // Forget, on one that's only there because it worked.
        mac.lastHost = "100.64.0.50"
        mac.worked = [LinkWorked(host: "100.64.0.50", port: 7447, label: "VPN", at: Self.now)]
        let row = mac.candidates(bonjour: false, limit: nil, at: Self.now).first { $0.host == "100.64.0.50" }
        XCTAssertEqual(row?.workedOnly, true)
        mac.forget("100.64.0.50|7447")
        XCTAssertNil(mac.lastHost)
        XCTAssertNil(mac.worked)
        // Forget leaves another last good address alone.
        mac.lastHost = "192.168.1.20"
        mac.forget("100.64.0.51|7447")
        XCTAssertEqual(mac.lastHost, "192.168.1.20")
    }

    /// Remove on Covee's address, kept on this iPhone and also listed by the Mac: the row stays as the Mac's, and keeps
    /// what it did, so a later hello taken while Covee was down on the Mac can't lose it.
    func testRemovingOneYouAddedThatTheMacListsKeepsWhatItDid() {
        let worked = [LinkWorked(host: "100.64.0.2", port: 7447, label: "VPN", at: Self.now)]
        var mac = paired(lastHost: "100.64.0.2", learned: Self.learned, added: ["100.64.0.2"], worked: worked)
        mac.removeAdded("100.64.0.2|7447")
        XCTAssertNil(mac.added)
        XCTAssertEqual(mac.lastHost, "100.64.0.2", "still the last good one")
        XCTAssertEqual(mac.worked, worked, "and still what worked")
        XCTAssertEqual(mac.candidates(bonjour: false, limit: nil, at: Self.now).first { $0.host == "100.64.0.2" }?.label, "VPN")
        XCTAssertTrue(mac.learn([Self.wifi, Self.warp]))
        let row = mac.candidates(bonjour: false, at: Self.now).first { $0.host == "100.64.0.2" }
        XCTAssertEqual(row?.atOnce, true, "a hello without it still has it dialled at once")
        // One the pairing code had is the same.
        var fromCode = paired(hosts: ["192.168.1.20", "100.64.0.2"], lastHost: "100.64.0.2", added: ["100.64.0.2"], worked: worked)
        fromCode.removeAdded("100.64.0.2|7447")
        XCTAssertEqual(fromCode.lastHost, "100.64.0.2")
        XCTAssertEqual(fromCode.worked, worked)
        // One nobody else lists goes with its row: from what worked, and as the last good one.
        var onlyMine = paired(lastHost: "100.64.0.9", learned: Self.learned, added: ["100.64.0.9"],
                              worked: [LinkWorked(host: "100.64.0.9", port: 7447, label: "", at: Self.now)])
        onlyMine.removeAdded("100.64.0.9|7447")
        XCTAssertNil(onlyMine.lastHost)
        XCTAssertNil(onlyMine.worked)
        XCTAssertFalse(onlyMine.candidates(bonjour: false, limit: nil, at: Self.now).contains { $0.host == "100.64.0.9" })
    }

    func testLearnReplaces() {
        var mac = paired()
        XCTAssertTrue(mac.learn(Self.learned))
        XCTAssertFalse(mac.learn(Self.learned), "the same list: nothing to save")
        XCTAssertTrue(mac.learn([Self.wifi]))
        XCTAssertEqual(mac.learned, [Self.wifi])
        XCTAssertTrue(mac.learn([]))
        XCTAssertEqual(mac.learned, [])
    }

    func testPairingAgainCarriesWhatYouAddedAndWhatWorked() {
        let old = paired(lastHost: "100.64.0.2", learned: Self.learned, added: ["studio-mac.covee.example"],
                      worked: [LinkWorked(host: "100.64.0.2", port: 7447, label: "VPN", at: Self.now)])
        var again = PairedMac(device: UUID(), name: "Studio Mac", hosts: ["192.168.1.20", "100.64.0.2"], port: 7447, lastHost: "192.168.1.20")
        again.carryOver(from: old)
        XCTAssertEqual(again.added, ["studio-mac.covee.example"])
        XCTAssertEqual(again.worked?.map(\.host), ["100.64.0.2"])
        XCTAssertEqual(again.lastHost, "192.168.1.20", "the address it just paired at")
        XCTAssertNotEqual(again.device, old.device)
        var other = PairedMac(device: UUID(), name: "Another Mac", hosts: ["192.168.1.30"], port: 7447)
        other.carryOver(from: old)
        XCTAssertNil(other.added)
        XCTAssertNil(other.worked)
    }

    // MARK: The phone's network

    func testANetworkGainsARoute() {
        let home = LinkNetwork(reachable: true, interfaces: ["en0", "pdp_ip0"], gateways: ["192.168.1.1:0"])
        XCTAssertTrue(home.gainsRoute(over: LinkNetwork(reachable: false)), "back from nothing")
        XCTAssertFalse(home.gainsRoute(over: home), "nothing changed")
        var vpn = home
        vpn.interfaces.insert("utun3")
        XCTAssertTrue(vpn.gainsRoute(over: home), "a VPN came up")
        var away = home
        away.interfaces = ["pdp_ip0"]
        away.gateways = []
        XCTAssertTrue(away.gainsRoute(over: home), "off the Wi-Fi: the route changed")
        var otherWiFi = home
        otherWiFi.gateways = ["10.0.0.1:0"]
        XCTAssertTrue(otherWiFi.gainsRoute(over: home), "another Wi-Fi")
        var gone = home
        gone.interfaces = ["en0"]
        XCTAssertFalse(gone.gainsRoute(over: home), "only an interface going isn't a new way to the Mac")
        XCTAssertFalse(LinkNetwork(reachable: false).gainsRoute(over: home))
    }

    func testALinksInterfaceIsLostOnlyIfItWasThere() {
        let before = LinkNetwork(reachable: true, interfaces: ["en0", "pdp_ip0"])
        let after = LinkNetwork(reachable: true, interfaces: ["pdp_ip0"])
        XCTAssertTrue(after.lost("en0", since: before))
        XCTAssertFalse(after.lost("pdp_ip0", since: before))
        XCTAssertFalse(after.lost("utun3", since: before), "a VPN iOS never listed is never taken for lost")
        XCTAssertFalse(after.lost(nil, since: before))
    }
}
