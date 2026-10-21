import CoreImage.CIFilterBuiltins
import CryptoKit
import Darwin
import Foundation
import Network
import BindersKit

extension SelfTest {
    /// Where a phone can reach this Mac, played on spare ports in a throwaway folder (part of --selftest-link): the
    /// founder's network as a fixed scan (Wi-Fi, Covee, WARP, Tailscale installed but stopped), the pairing code, the
    /// addresses in a hello only for a phone that reads them, the notice when they change, the parallel dial (a stalled
    /// try never holds up a good one, and hellos never overlap), Tailscale's tool through stand-ins (never the real one),
    /// and this Mac's own interfaces, read only.
    @MainActor
    static func linkAddressesSelfTest(_ check: (Bool, String) -> Void, controller: DictationController) async {
        let devicesURL = FileManager.default.temporaryDirectory.appendingPathComponent("link-devices-addresses-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: devicesURL) }
        let server = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: devicesURL)
        let founder = LinkAddressScan(interfaces: founderMac, vpns: [LinkVPNStatus.tailscale(Data(stoppedTailscale.utf8))].compactMap { $0 })
        server.networkForTests = founder
        server.start()
        for _ in 0..<50 where server.status != .listening || !server.addressesRead { try? await Task.sleep(for: .milliseconds(100)) }
        guard server.status == .listening, let port = server.boundPort else {
            check(false, "addresses: the Mac is listening")
            return
        }
        let addedBefore = server.addedAddresses, leftOutBefore = server.leftOutAddresses
        check(server.addAddress("Studio-Mac.Covee.Example.") == nil && server.addedAddresses.last == "studio-mac.covee.example",
              "a name you add is kept as it's looked up: \(server.addedAddresses)")
        var clients: [LinkClient] = []
        defer {
            for client in clients { client.close() }
        }

        // 1. The pairing code: the likeliest few, which every iPhone build reads.
        guard let pairing = await server.beginPairing(), let pairingPort = server.boundPairingPort else {
            check(false, "addresses: pairing opens")
            server.stop()
            return
        }
        let expected = ["192.168.1.20", "100.64.0.2", "studio-mac.covee.example", "[fd7a:115c:a1e0::2]"].map { "\($0):\(pairingPort)" }
        let code = pairing.addresses
        check(code == expected && code.allSatisfy { LinkClient.split($0) != nil }
              && !code.contains { $0.contains("100.96.0.8") || $0.contains("100.80.1.33") || $0.contains("tail1234") },
              "the pairing code has Wi-Fi, Covee and the name you added, IPv6 last, and no WARP or stopped Tailscale: \(code)")

        do {
            // 2. A phone that reads them gets the addresses in its hello.
            var local = pairing
            local.addresses = ["127.0.0.1:\(pairingPort)"]
            let paired = try await LinkClient.pair(local, deviceName: "Test iPhone")
            func phone(_ features: [String], notices: LinkNotices? = nil) async throws -> (client: LinkClient, hello: [String: Any]) {
                let client = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
                clients.append(client)
                try await client.connect(timeout: 3)
                if let notices { client.onNotification { notices.add($0) } }
                let hello = try await client.hello(device: paired.device, key: paired.key, name: "Test iPhone", features: features, timeout: 5)
                return (client, hello)
            }
            let heard = LinkNotices()
            let modern = try await phone(LinkFeatures.thisPhone, notices: heard)
            let list = LinkAddress.list(from: modern.hello["addresses"]) ?? []
            check(list.map(\.host) == ["192.168.1.20", "studio-mac.covee.example", "100.64.0.2", "fd7a:115c:a1e0::2", "100.96.0.8"]
                  && list.map(\.kind) == ["local", "added", "vpn", "vpn", "vpn"] && list.last?.unlikely == true
                  && list.dropLast().allSatisfy { $0.unlikely == nil } && list.allSatisfy { $0.port == port }
                  && (modern.hello["features"] as? [String] ?? []).contains(LinkFeatures.addresses),
                  "a phone that reads them gets the Mac's addresses at hello, in order, each with the link's port: \(list.map { "\($0.host) \($0.kind)" })")

            // 16. Which address it came in on.
            check(server.connectedOver(paired.device) == "127.0.0.1", "Paired devices says which address a phone came in on: \(server.connectedOver(paired.device) ?? "none")")

            // 3. iPhone 2.0, and a build that reads everything else, aren't told.
            let oldHeard = LinkNotices(), midHeard = LinkNotices()
            let old = try await phone([], notices: oldHeard)
            let middle = try await phone(LinkFeatures.thisPhone.filter { $0 != LinkFeatures.addresses && $0 != LinkFeatures.notification(LinkFeatures.addressesMethod) },
                                         notices: midHeard)
            check(old.hello["addresses"] == nil && middle.hello["addresses"] == nil,
                  "a phone that lists nothing, or not the addresses, gets no addresses in its hello")

            // 4. A change goes to the phone that reads it, and only to it.
            for client in [modern.client, old.client, middle.client] { _ = try await client.request("binders/subscribe", timeout: 5) }
            server.leaveOut("100.96.0.8", true)
            for _ in 0..<20 where heard.addressLists.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(200))
            let notice = heard.addressLists.last ?? []
            check(heard.addressLists.count == 1 && !notice.isEmpty && !notice.contains { $0.host == "100.96.0.8" } && oldHeard.count == 0 && midHeard.count == 0,
                  "leaving WARP out tells the phone that reads it, at once, and no other: \(notice.map(\.host))")

            // 5. Tailscale running beside Covee: its name and address are added, and Covee's stays.
            var withTailscale = founder
            withTailscale.interfaces += [LinkInterface(name: "utun4", address: "100.101.102.103", isPointToPoint: true),
                                         LinkInterface(name: "utun4", address: "fd7a:115c:a1e0::7", isPointToPoint: true)]
            withTailscale.vpns = [LinkVPNStatus.tailscale(Data(runningTailscale.utf8))].compactMap { $0 }
            server.networkForTests = withTailscale
            await server.refreshAddresses()
            let running = server.helloAddresses()
            let nameAt = running.firstIndex { $0.host == "studio-mac.tail1234.ts.net" }, ipAt = running.firstIndex { $0.host == "100.101.102.103" }
            check(nameAt != nil && ipAt != nil && nameAt! < ipAt! && running[nameAt!].kind == LinkAddress.Kind.tailscale
                  && running[ipAt!].kind == LinkAddress.Kind.tailscale && running.first { $0.host == "100.64.0.2" }?.kind == LinkAddress.Kind.vpn,
                  "a running Tailscale adds its name and address, and Covee's address stays: \(running.map { "\($0.host) \($0.kind)" })")

            // 6. A hello reads the network first, so it never carries a list older than that.
            server.helloRereadAfter = 0
            var coveeDown = founder
            coveeDown.interfaces.removeAll { $0.name == "utun0" }
            server.networkForTests = coveeDown
            let fresh = try await phone(LinkFeatures.thisPhone)
            let freshList = (LinkAddress.list(from: fresh.hello["addresses"]) ?? []).map(\.host)
            check(!freshList.isEmpty && !freshList.contains("100.64.0.2") && !freshList.contains("fd7a:115c:a1e0::2"),
                  "a hello reads the Mac's network first: Covee gone a moment ago isn't in it: \(freshList)")
            server.helloRereadAfter = 5
            server.networkForTests = founder
            await server.refreshAddresses()

            // 7. A phone whose hello came before a change hears the new list when it subscribes, before the reply.
            let lateHeard = LinkNotices()
            let late = try await phone(LinkFeatures.thisPhone, notices: lateHeard)
            var moved = founder
            moved.interfaces[0].address = "192.168.1.44"
            server.networkForTests = moved
            await server.refreshAddresses()
            try? await Task.sleep(for: .milliseconds(200))
            let quietBefore = lateHeard.count
            _ = try await late.client.request("binders/subscribe", timeout: 5)
            let first = lateHeard.addressLists
            _ = try await late.client.request("binders/subscribe", timeout: 5)
            try? await Task.sleep(for: .milliseconds(200))
            check(quietBefore == 0 && first.count == 1 && first.first == server.helloAddresses() && lateHeard.count == 1
                  && first.first?.first?.host == "192.168.1.44",
                  "a phone that said hello before the Mac changed Wi-Fi hears the new list as it subscribes, once: \(first.first?.map(\.host) ?? [])")
            server.networkForTests = founder
            await server.refreshAddresses()

            // 8. Typing the link's own port keeps the detected address's place, and the pairing code.
            check(server.addAddress("100.64.0.2:\(port)") == nil && server.addedAddresses.last == "100.64.0.2"
                  && server.addresses.first { $0.address.host == "100.64.0.2" }?.address.kind == LinkAddress.Kind.added,
                  "an address added with the link's port is kept without it, and takes the detected one's place: \(server.addedAddresses)")
            if let again = await server.beginPairing(), let againPort = server.boundPairingPort {
                check(again.addresses.contains("100.64.0.2:\(againPort)"), "and stays in the pairing code: \(again.addresses)")
                server.cancelPairing()
            } else {
                check(false, "pairing opens again")
            }
            server.removeAddress("100.64.0.2")
            check(server.addresses.first { $0.address.host == "100.64.0.2" }?.address.kind == LinkAddress.Kind.vpn,
                  "Remove brings the detected one back")

            for client in clients { client.close() }
            clients.removeAll()
            try? await Task.sleep(for: .milliseconds(500))
            try await dialChecks(check, server: server, port: port, device: paired.device, key: paired.key)
        } catch {
            check(false, "addresses: the conversation failed: \(error.localizedDescription)")
        }

        await tailscaleToolChecks(check)
        await tailscaleGoneCheck(check, server: server)
        interfaceChecks(check)
        longestPairingCode(check)

        // What this run added and left out goes with it.
        for text in server.addedAddresses where !addedBefore.contains(text) { server.removeAddress(text) }
        for host in server.leftOutAddresses where !leftOutBefore.contains(host) { server.leaveOut(host, false) }
        server.stop()
    }

    // MARK: The dial

    @MainActor
    private static func dialChecks(_ check: (Bool, String) -> Void, server: LinkServer, port: UInt16, device: UUID, key: SymmetricKey) async throws {
        func candidate(_ host: String, _ port: UInt16, atOnce: Bool = false) -> LinkCandidate {
            let name = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
            return LinkCandidate(id: "\(host)|\(port)", host: host, port: port, name: name, label: "Added on this iPhone", source: .added,
                                 addedHere: true, atOnce: atOnce)
        }
        func hello(timeout: TimeInterval, as who: UUID = device) -> @Sendable (LinkClient, Data) async throws -> [String: Any] {
            { link, nonce in
                let reply = try await link.prove(nonce, device: who, key: key, name: "Test iPhone", features: LinkFeatures.thisPhone, timeout: timeout)
                _ = try await link.request("binders/subscribe", timeout: timeout)
                return reply
            }
        }
        func dial(_ candidates: [LinkCandidate], key dialKey: SymmetricKey = key, connect: TimeInterval = 2, handshake: TimeInterval = 5,
                  prove: (@Sendable (LinkClient, Data) async throws -> [String: Any])?) async -> (result: LinkDial.Result, seconds: Double) {
            let started = Date()
            let result = await LinkDial.dial(candidates, bonjour: nil, identity: device.uuidString, key: dialKey, connect: connect,
                                             stagger: 0.25, handshake: handshake, prove: prove)
            return (result, Date().timeIntervalSince(started))
        }
        func outcomes(_ result: LinkDial.Result) -> String {
            result.attempts.map { "\($0.name) \($0.outcome.rawValue)" }.joined(separator: ", ")
        }

        // 9. Every address at once: one says hello, the rest are closed, here and on the Mac.
        let silent = try SilentListener()
        let silentPort = try await silent.ready()
        defer { silent.stop() }
        let closed = try await closedPort()
        let sessionsBefore = server.sessionCount, hellosBefore = server.hellos, phonesBefore = server.phoneFeatures.count
        let race = await dial([candidate("127.0.0.1", silentPort, atOnce: true), candidate("127.0.0.1", closed), candidate("localhost", port),
                               candidate("::1", port), candidate("127.0.0.1", port)], prove: hello(timeout: 5))
        let silentOutcome = race.result.attempts.first?.outcome, closedOutcome = race.result.attempts.dropFirst().first?.outcome
        check(race.result.client != nil && race.seconds < 1.5 && server.hellos == hellosBefore + 1 && silentOutcome == .cancelled && closedOutcome == .refused,
              "the dial tries every address at once and one wins, in \(String(format: "%.2f", race.seconds)) s, with one hello: \(outcomes(race.result))")
        try? await Task.sleep(for: .seconds(1))
        check(server.sessionCount == sessionsBefore + 1 && server.phoneFeatures.count == phonesBefore + 1,
              "every other try is closed on the Mac too: \(server.sessionCount - sessionsBefore) session left")
        race.result.client?.close()

        // 10. A try that stalls after it opened (a path going as you leave the house) doesn't hold up a good one.
        server.stallsNextSession = true
        let hellos10 = server.hellos
        let stalled = await dial([candidate("127.0.0.1", port, atOnce: true), candidate("localhost", port, atOnce: true)], prove: hello(timeout: 5))
        server.stallsNextSession = false
        check(stalled.result.client != nil && stalled.seconds < 1.5 && server.hellos == hellos10 + 1
              && stalled.result.attempts.contains { $0.outcome == .cancelled },
              "a try that stalls doesn't hold up one that answers: \(String(format: "%.2f", stalled.seconds)) s, \(outcomes(stalled.result))")
        stalled.result.client?.close()

        // 11. One hello at a time: the second only once the first has failed on its own.
        server.stallsNextHello = true
        let hellos11 = server.hellos
        let queued = await dial([candidate("127.0.0.1", port, atOnce: true), candidate("localhost", port, atOnce: true)], handshake: 1,
                                prove: hello(timeout: 1))
        server.stallsNextHello = false
        print("DIAL: \(outcomes(queued.result))")
        check(queued.result.client != nil && queued.seconds >= 0.9 && queued.seconds < 2.5 && server.hellos == hellos11 + 1
              && queued.result.attempts.filter { $0.outcome == .noAnswer }.count == 1,
              "hellos never overlap: the second went once the first timed out, \(String(format: "%.2f", queued.seconds)) s")
        queued.result.client?.close()

        // 12. The Mac saying no ends the dial: every address leads to the same Mac.
        let refused = await dial([candidate("127.0.0.1", port, atOnce: true), candidate("localhost", port, atOnce: true)],
                                 prove: hello(timeout: 5, as: UUID()))
        check(refused.result.rejection == "This device isn't paired with this Mac" && refused.result.client == nil && refused.seconds < 1,
              "a hello the Mac turns down ends the dial with its words: \(refused.result.rejection ?? "none"), \(outcomes(refused.result))")

        // 13. A wrong key.
        let wrong = await dial([candidate("127.0.0.1", port, atOnce: true)], key: SymmetricKey(size: .bits256), prove: hello(timeout: 5))
        print("WRONG_KEY: \(outcomes(wrong.result))")
        check(wrong.result.attempts.first?.outcome == .keyRefused && wrong.result.attempts.first?.opened == false,
              "a wrong key is \"doesn't know this iPhone\", and nothing opened")

        // 14. Test: the challenge alone, which counts no connection.
        let hellos14 = server.hellos
        let tested = await dial([candidate("127.0.0.1", port, atOnce: true)], prove: nil)
        tested.result.client?.close()
        check(tested.result.attempts.first?.outcome == .answered && server.hellos == hellos14, "Test asks for a challenge only: answered, and no hello")

        // 15. A connection that never says who it is is closed.
        server.helloDeadline = 1
        let mute = LinkClient(host: "127.0.0.1", port: port, identity: device.uuidString, key: key)
        try await mute.connect(timeout: 3)
        server.helloDeadline = 20
        for _ in 0..<20 where !mute.isClosed { try? await Task.sleep(for: .milliseconds(100)) }
        check(mute.isClosed, "a connection that says nothing is closed by the Mac")
        mute.close()
    }

    // MARK: Tailscale's tool, through stand-ins

    @MainActor
    private static func tailscaleToolChecks(_ check: (Bool, String) -> Void) async {
        check(LinkAddressScanner.tailscaleTool == nil, "in a throwaway folder Tailscale's tool is never looked for")
        let folder = AppPaths.support.appendingPathComponent("tailscale-stand-ins", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func standIn(_ name: String, _ body: String) -> URL {
            // By its absolute path: Process loses a relative one's "..", as a throwaway folder's path can be.
            let url = URL(fileURLWithPath: folder.appendingPathComponent(name).path)
            try? Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        func run(_ tool: URL) async -> (status: LinkVPNStatus?, seconds: Double) {
            let started = Date()
            let status: LinkVPNStatus? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { continuation.resume(returning: LinkAddressScanner.tailscale(tool: tool, timeout: 2)) }
            }
            return (status, Date().timeIntervalSince(started))
        }
        let slow = await run(standIn("slow", "exec sleep 5"))
        check(slow.status == nil && slow.seconds < 2.6, "a tool that hangs is given up on in its time: \(String(format: "%.2f", slow.seconds)) s")
        let stubborn = await run(standIn("stubborn", "trap '' TERM\nexec sleep 5"))
        check(stubborn.status == nil && stubborn.seconds < 3.1, "and one that ignores being told to stop: \(String(format: "%.2f", stubborn.seconds)) s")
        let wordy = await run(standIn("wordy", """
            printf '{"BackendState":"Running","TailscaleIPs":["100.101.102.103"],"Pad":"'
            head -c 1048576 /dev/zero | tr '\\000' x
            printf '"}'
            """))
        check(wordy.status?.isRunning == true && wordy.status?.ips == ["100.101.102.103"] && wordy.seconds < 1.5,
              "a long answer is read while it comes, never stalling the tool: \(String(format: "%.2f", wordy.seconds)) s")
        let stopped = await run(standIn("stopped", "cat <<'EOF'\n\(stoppedTailscale)\nEOF"))
        check(stopped.status != nil && stopped.status?.isRunning == false, "a stopped Tailscale says so, and isn't running")
        let failing = await run(standIn("failing", "echo '{\"BackendState\":\"Running\"}'\nexit 1"))
        check(failing.status == nil, "a tool that fails says nothing")
        // Whatever the stand-ins left behind is gone with them.
        try? await Task.sleep(for: .milliseconds(600))
    }

    /// Tailscale's tool gone (uninstalled, or moved by an update) after it said Running: what it named that no interface
    /// has, its address in userspace and its name, stops being offered, and Covee's stays. The Mac asks a stand-in as it
    /// would the tool, then finds no tool.
    @MainActor
    private static func tailscaleGoneCheck(_ check: (Bool, String) -> Void, server: LinkServer) async {
        let folder = AppPaths.support.appendingPathComponent("tailscale-gone", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // By its absolute path, as the other stand-ins.
        let tool = URL(fileURLWithPath: folder.appendingPathComponent("tailscale").path)
        try? Data("#!/bin/sh\ncat <<'EOF'\n\(runningTailscale)\nEOF\n".utf8).write(to: tool)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        server.tailscaleStandIn = tool
        await server.refreshAddresses(force: true)
        let running = server.helloAddresses().map(\.host)
        try? FileManager.default.removeItem(at: tool)
        await server.refreshAddresses(force: true)
        let gone = server.helloAddresses().map(\.host)
        check(running.contains("studio-mac.tail1234.ts.net") && running.contains("100.101.102.103")
              && !gone.contains("studio-mac.tail1234.ts.net") && !gone.contains("100.101.102.103") && gone.contains("100.64.0.2"),
              "Tailscale's tool gone after it said Running: its name and the address no interface has stop being offered, Covee's stays: \(gone)")
        server.tailscaleStandIn = nil
        await server.refreshAddresses()
    }

    // MARK: This Mac's network, read only

    @MainActor
    private static func interfaceChecks(_ check: (Bool, String) -> Void) {
        let interfaces = LinkAddressScanner.interfaces()
        let offered = LinkAddresses.offered(LinkAddresses.classify(interfaces: interfaces))
        // An independent walk: every up en* interface's IPv4 address, as the link offered them before.
        var local: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let entry = pointer.pointee
                guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                      entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                      String(cString: entry.ifa_name).hasPrefix("en") else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let text = String(cString: host)
                if !text.hasPrefix("169.254.") { local.append(text) }
            }
            freeifaddrs(list)
        }
        let missing = local.filter { host in !offered.contains { $0.host == host && $0.kind == LinkAddress.Kind.local } }
        let bad = offered.filter { $0.host.hasPrefix("127.") || $0.host == "::1" || $0.host.hasPrefix("fe80") || $0.host.contains("%") }
        let interfacesOK = !interfaces.contains { $0.address.contains("%") }
        let named = Set(interfaces.filter { $0.vpnName != nil }.map(\.name)).count
        print("INTERFACES: \(interfaces.count) addresses, \(offered.count) offered, \(local.count) on the local network; tunnels with a VPN's own name: \(named)")
        check(interfacesOK && bad.isEmpty && missing.isEmpty,
              interfacesOK && bad.isEmpty && missing.isEmpty ? "this Mac's own interfaces read cleanly, and every local address is offered"
                  : "this Mac's own interfaces: missing \(missing), never offered \(bad.map(\.host))")
    }

    // MARK: The longest pairing code

    @MainActor
    private static func longestPairingCode(_ check: (Bool, String) -> Void) {
        let name = String(repeating: "M", count: 63)
        // Five names that, with the longest port, fill the budget to the byte: the most text a code can carry.
        let offered = [19, 19, 19, 19, 22].enumerated().map { index, length in
            LinkAddress(host: "m\(index)" + String(repeating: "x", count: length - 10) + ".example", kind: LinkAddress.Kind.added, label: "")
        }
        let addresses = LinkAddresses.pairingAddresses(offered, port: 65535)
        let pairing = LinkPairing(name: name, addresses: addresses, secret: Link.randomBytes(16), expires: Date().addingTimeInterval(600))
        let url = pairing.url.absoluteString
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"
        let modules = Int(filter.outputImage?.extent.width ?? 0)
        print("PAIRING_CODE: \(addresses.count) addresses, \(addresses.joined().utf8.count) bytes, URL \(url.count) characters, QR \(modules) modules")
        check(modules > 0 && modules <= 81, "the longest pairing code fits a QR code of \(modules) modules")
    }

    // MARK: Fixtures

    /// The founder's Mac, made up where it doesn't matter: Wi-Fi, Covee (utun0), a macOS utun with only a link-local
    /// address, Cloudflare WARP (utun8), a VM bridge, a self-assigned en5 and an en1 that's down.
    static let founderMac: [LinkInterface] = [
        LinkInterface(name: "en0", address: "192.168.1.20", medium: .wifi),
        LinkInterface(name: "en0", address: "fe80::1c2b:3aff:fe11:2233", medium: .wifi),
        LinkInterface(name: "lo0", address: "127.0.0.1", isLoopback: true),
        LinkInterface(name: "lo0", address: "::1", isLoopback: true),
        LinkInterface(name: "utun0", address: "100.64.0.2", isPointToPoint: true),
        LinkInterface(name: "utun0", address: "fd7a:115c:a1e0::2", isPointToPoint: true),
        LinkInterface(name: "utun0", address: "fe80::a", isPointToPoint: true),
        LinkInterface(name: "utun1", address: "fe80::b", isPointToPoint: true),
        LinkInterface(name: "utun8", address: "100.96.0.8", isPointToPoint: true),
        LinkInterface(name: "utun8", address: "2606:4700:cf1:1000::8", isPointToPoint: true),
        LinkInterface(name: "bridge100", address: "192.168.64.1"),
        LinkInterface(name: "en5", address: "169.254.20.20"),
        LinkInterface(name: "en1", address: "192.168.1.21", isUp: false),
    ]

    /// `tailscale status --json --peers=false` from a Tailscale that's installed and stopped, made up on the tool's
    /// documented shape.
    static let stoppedTailscale = #"{"Version":"1.80.0-t0123456789","TUN":true,"BackendState":"Stopped","HaveNodeKey":true,"AuthURL":"","TailscaleIPs":["100.80.1.33"],"Self":{"ID":"n1","HostName":"studio-mac","DNSName":"studio-mac.tail1234.ts.net.","OS":"macOS","TailscaleIPs":["100.80.1.33"],"Online":false},"Health":["Tailscale is stopped."],"MagicDNSSuffix":"tail1234.ts.net","CurrentTailnet":null,"User":null}"#
    /// The same, running, with MagicDNS on.
    static let runningTailscale = #"{"Version":"1.80.0-t0123456789","TUN":true,"BackendState":"Running","HaveNodeKey":true,"AuthURL":"","TailscaleIPs":["100.101.102.103","fd7a:115c:a1e0::7"],"Self":{"ID":"n1","HostName":"studio-mac","DNSName":"studio-mac.tail1234.ts.net.","OS":"macOS","TailscaleIPs":["100.101.102.103","fd7a:115c:a1e0::7"],"Online":true},"Health":[],"MagicDNSSuffix":"tail1234.ts.net","CurrentTailnet":{"Name":"example.com","MagicDNSSuffix":"tail1234.ts.net","MagicDNSEnabled":true},"User":null}"#

    /// A port nothing listens on: one a listener had a moment ago.
    private static func closedPort() async throws -> UInt16 {
        let listener = try SilentListener()
        let port = try await listener.ready()
        listener.stop()
        try? await Task.sleep(for: .milliseconds(100))
        return port
    }
}

/// A TCP port that takes connections and never says a word: an address whose path stalls after it opened.
private final class SilentListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.binders.selftest.silent")
    private var connections: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connections.append(connection)
            connection.start(queue: queue)
        }
    }

    /// Starts it, and says its port once it's ready.
    func ready() async throws -> UInt16 {
        let once = SelfTestOnce()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: self?.listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: NWError.posix(.ECANCELED)) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
        listener.cancel()
    }
}

/// True the first time only, from any queue.
private final class SelfTestOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// The notices a test phone hears, which arrive on the link's queue.
private final class LinkNotices: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [[String: Any]] = []

    func add(_ message: [String: Any]) {
        lock.withLock { heard.append(message) }
    }

    /// Every `binders/addresses` list heard, in order.
    var addressLists: [[LinkAddress]] {
        lock.withLock {
            heard.filter { $0["method"] as? String == LinkFeatures.addressesMethod }
                .compactMap { LinkAddress.list(from: ($0["params"] as? [String: Any])?["addresses"]) }
        }
    }

    /// How many notices of any kind.
    var count: Int { lock.withLock { heard.count } }
}
