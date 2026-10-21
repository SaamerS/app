import Foundation
import Network

/// One address on one of this Mac's interfaces, as getifaddrs gives it (a test builds them by hand).
public struct LinkInterface: Equatable, Sendable {
    public enum Medium: String, Sendable { case wifi, wired, unknown }
    /// The BSD name: en0, utun4, ipsec0.
    public var name: String
    /// Numeric, no "%scope": 192.168.1.20, fd7a:115c:a1e0::2.
    public var address: String
    public var isUp: Bool
    public var isLoopback: Bool
    public var isPointToPoint: Bool
    /// Wi-Fi or Ethernet when the system says.
    public var medium: Medium
    /// The VPN's own name, when the system has one for this interface.
    public var vpnName: String?

    public init(name: String, address: String, isUp: Bool = true, isLoopback: Bool = false,
                isPointToPoint: Bool = false, medium: Medium = .unknown, vpnName: String? = nil) {
        self.name = name
        self.address = address
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.isPointToPoint = isPointToPoint
        self.medium = medium
        self.vpnName = vpnName
    }
}

/// What a VPN's own tool says about this Mac. Only Tailscale has one today; another VPN with a status command (Covee
/// one day) would plug in here with no change to the classifier.
public struct LinkVPNStatus: Equatable, Sendable {
    /// LinkAddress.Kind for its addresses: "tailscale".
    public var kind: String
    public var label: String
    /// Tailscale: BackendState is "Running". Nothing else counts.
    public var isRunning: Bool
    /// Top-level TailscaleIPs, else Self.TailscaleIPs.
    public var ips: [String]
    /// Self.DNSName, lowercased, trailing dot removed, nil when empty. When CurrentTailnet is an object, only if its
    /// MagicDNSEnabled is true; when CurrentTailnet is absent or null, whenever the name isn't empty.
    public var dnsName: String?
    /// The last good answer, standing in while the tool fails: it only relabels addresses on an interface.
    public var fromCache: Bool

    public init(kind: String, label: String, isRunning: Bool, ips: [String], dnsName: String? = nil, fromCache: Bool = false) {
        self.kind = kind
        self.label = label
        self.isRunning = isRunning
        self.ips = ips
        self.dnsName = dnsName
        self.fromCache = fromCache
    }

    /// `tailscale status --json --peers=false` → its status; nil when the data isn't that (not JSON, no BackendState).
    public static func tailscale(_ json: Data) -> LinkVPNStatus? {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let state = object["BackendState"] as? String else { return nil }
        let node = object["Self"] as? [String: Any]
        var ips = (object["TailscaleIPs"] as? [Any])?.compactMap { $0 as? String } ?? []
        if ips.isEmpty { ips = (node?["TailscaleIPs"] as? [Any])?.compactMap { $0 as? String } ?? [] }
        var dnsName: String?
        if var name = (node?["DNSName"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() {
            if name.hasSuffix(".") { name.removeLast() }
            if !name.isEmpty {
                if let tailnet = object["CurrentTailnet"] as? [String: Any] {
                    if tailnet["MagicDNSEnabled"] as? Bool == true { dnsName = name }
                } else {
                    dnsName = name
                }
            }
        }
        return LinkVPNStatus(kind: LinkAddress.Kind.tailscale, label: "Tailscale", isRunning: state == "Running", ips: ips, dnsName: dnsName)
    }
}

/// One address a phone can try, as the Mac says it at hello and the phone keeps it.
public struct LinkAddress: Codable, Equatable, Hashable, Sendable {
    /// An open set of words, so a newer Mac's kind still reads on an older phone.
    public enum Kind {
        public static let local = "local", vpn = "vpn", tailscale = "tailscale", added = "added"
    }

    /// Canonical: IPv6 without brackets (inet_ntop's form), names lowercased with no trailing dot.
    public var host: String
    /// Nil: the link's port (the Mac fills it in before sending).
    public var port: UInt16?
    public var kind: String
    /// "Wi-Fi", "Ethernet", "Local network", "VPN", "Tailscale", "Added by you".
    public var label: String
    /// True: a VPN out to the internet (WARP), tried last.
    public var unlikely: Bool?

    public init(host: String, port: UInt16? = nil, kind: String, label: String, unlikely: Bool? = nil) {
        self.host = host
        self.port = port
        self.kind = kind
        self.label = label
        self.unlikely = unlikely
    }

    private enum CodingKeys: String, CodingKey { case host, port, kind, label, unlikely }

    /// Leniently, as a phone keeps it: the host is required; a port outside 1...65535 is the link's; kind and label
    /// default to "".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let host = try container.decode(String.self, forKey: .host)
        guard !host.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .host, in: container, debugDescription: "An address with no host")
        }
        self.host = host
        port = (try? container.decodeIfPresent(UInt16.self, forKey: .port)).flatMap { $0 }.flatMap { $0 == 0 ? nil : $0 }
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0 } ?? ""
        label = (try? container.decodeIfPresent(String.self, forKey: .label)).flatMap { $0 } ?? ""
        unlikely = (try? container.decodeIfPresent(Bool.self, forKey: .unlikely)).flatMap { $0 }
    }

    /// As it goes in a hello or a notice: "unlikely" only when true.
    public var jsonObject: [String: Any] {
        var object: [String: Any] = ["host": host, "kind": kind, "label": label]
        if let port { object["port"] = Int(port) }
        if unlikely == true { object["unlikely"] = true }
        return object
    }

    /// The `addresses` of a hello reply or a notice: nil when it's absent or not a list. An item that isn't an address
    /// (no host, a host that isn't one, a port that can't be) is skipped alone; at most `LinkAddresses.helloLimit`.
    public static func list(from value: Any?) -> [LinkAddress]? {
        guard let items = value as? [Any] else { return nil }
        var list: [LinkAddress] = []
        for item in items {
            guard list.count < LinkAddresses.helloLimit else { break }
            guard let object = item as? [String: Any], let text = object["host"] as? String,
                  let host = LinkAddresses.canonicalHost(text) else { continue }
            var port: UInt16?
            if let value = object["port"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let whole = Int(exactly: number.doubleValue), (1...65535).contains(whole) else { continue }
                port = UInt16(whole)
            }
            list.append(LinkAddress(host: host, port: port, kind: object["kind"] as? String ?? "", label: object["label"] as? String ?? "",
                                    unlikely: object["unlikely"] as? Bool == true ? true : nil))
        }
        return list
    }

    /// As lists show it: "fd7a:115c:a1e0::2", "[fd7a:115c:a1e0::2]:7450", "studio:7450". The port only when it isn't
    /// `defaultPort`.
    public func name(defaultPort: UInt16) -> String {
        LinkAddresses.text(host: host, port: port == defaultPort ? nil : port)
    }

    /// "host|port", with the port resolved: what de-duplicates.
    public func key(defaultPort: UInt16) -> String {
        "\(host)|\(port ?? defaultPort)"
    }

    /// "host:port", IPv6 in brackets, for LinkPairing.addresses.
    public func pairingText(port: UInt16) -> String {
        LinkAddresses.isIPv6(host) ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Not an IP address: a name to look up.
    var isName: Bool { LinkIP(host) == nil }
}

/// Where a phone can reach this Mac: the classifier that turns its interfaces (and Tailscale's word, while it runs) into
/// an ordered list, the pairing code's share of it, and the reading of an address someone typed.
public enum LinkAddresses {
    public static let pairingLimit = 5, pairingBudget = 128, helloLimit = 16, addedLimit = 8

    /// One of the Mac's addresses as its Settings lists it: offered, or left out by you.
    public struct Entry: Equatable, Sendable, Identifiable {
        public var address: LinkAddress
        /// "utun0"; nil for one you added, and for a VPN status's address that isn't on an interface.
        public var interface: String?
        public var leftOut: Bool

        public init(address: LinkAddress, interface: String? = nil, leftOut: Bool = false) {
            self.address = address
            self.interface = interface
            self.leftOut = leftOut
        }

        public var id: String { "\(address.host)|\(address.port.map(String.init) ?? "")" }
        /// Yours: Remove, rather than Leave Out.
        public var isAdded: Bool { address.kind == LinkAddress.Kind.added }
    }

    /// Every address a phone could use, best first (the rules are in docs/LINK.md, "Finding the Mac"). `port` is the
    /// link's, for telling an added "100.64.0.2:7447" from a detected 100.64.0.2.
    public static func classify(interfaces: [LinkInterface], vpns: [LinkVPNStatus] = [], added: [String] = [],
                                leftOut: Set<String> = [], port: UInt16 = Link.port) -> [Entry] {
        struct Item {
            var entry: Entry
            var family: Int
            var source: Int
            var order: Int
            /// 0 the local network, 1 names, 2 VPN addresses, 3 ones a phone can rarely reach.
            var group: Int {
                if entry.address.kind == LinkAddress.Kind.local { return 0 }
                if entry.address.isName { return 1 }
                return entry.address.unlikely == true ? 3 : 2
            }
        }
        let interfaceSource = 2, statusSource = 1, addedSource = 0
        var items: [Item] = []
        var nextOrder = 0
        func key(_ address: LinkAddress) -> String { address.key(defaultPort: port) }
        func append(_ entry: Entry, family: Int, source: Int) {
            guard !items.contains(where: { key($0.entry.address) == key(entry.address) }) else { return }
            items.append(Item(entry: entry, family: family, source: source, order: nextOrder))
            nextOrder += 1
        }

        // Rule 1: what's up, isn't loopback, and parses.
        let parsed: [(interface: LinkInterface, ip: LinkIP)] = interfaces.compactMap { interface in
            guard interface.isUp, !interface.isLoopback else { return nil }
            let bare = String(interface.address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            guard let ip = LinkIP(bare), !ip.isNeverOffered else { return nil }
            return (interface, ip)
        }
        // Rule 4: a tunnel that also carries a public address is a VPN out to the internet.
        let outToInternet = Set(parsed.filter { isTunnel($0.interface) && $0.ip.isPublic }.map(\.interface.name))
        for (interface, ip) in parsed {
            if interface.name.hasPrefix("en") {
                // Rule 2: the local network, IPv4 only (Bonjour covers IPv6 there).
                guard ip.family == .v4 else { continue }
                let label = switch interface.medium {
                case .wifi: "Wi-Fi"
                case .wired: "Ethernet"
                case .unknown: "Local network"
                }
                append(Entry(address: LinkAddress(host: ip.text, kind: LinkAddress.Kind.local, label: label), interface: interface.name),
                       family: 0, source: interfaceSource)
            } else if isTunnel(interface) {
                // Rule 3: a VPN's private, CGNAT or unique-local address.
                guard ip.isVPNRange else { continue }
                let unlikely = outToInternet.contains(interface.name) ? true : nil
                append(Entry(address: LinkAddress(host: ip.text, kind: LinkAddress.Kind.vpn, label: interface.vpnName ?? "VPN", unlikely: unlikely),
                             interface: interface.name),
                       family: ip.family == .v4 ? 0 : 1, source: interfaceSource)
            }
            // Rule 5: everything else (VM networks, Apple's own links) is skipped.
        }

        // Rule 6: a running VPN's own word relabels its addresses, and a fresh one adds what no interface has.
        for status in vpns where status.isRunning {
            var onInterface = false
            for text in status.ips {
                guard let ip = LinkIP(text), ip.isVPNRange else { continue }
                if let index = items.firstIndex(where: { $0.entry.address.host == ip.text && $0.entry.address.kind == LinkAddress.Kind.vpn }) {
                    items[index].entry.address.kind = status.kind
                    items[index].entry.address.label = status.label
                    items[index].source = statusSource
                    onInterface = true
                } else if !status.fromCache, !items.contains(where: { $0.entry.address.host == ip.text }) {
                    append(Entry(address: LinkAddress(host: ip.text, kind: status.kind, label: status.label)),
                           family: ip.family == .v4 ? 0 : 1, source: statusSource)
                }
            }
            if let name = status.dnsName.flatMap(canonicalName), !status.fromCache || onInterface {
                append(Entry(address: LinkAddress(host: name, kind: status.kind, label: status.label)), family: 0, source: statusSource)
            }
        }

        // Rule 7: yours, in place of a detected one with the same key, whether its interface is up or not.
        var addedKeys = Set<String>()
        for text in added {
            guard case .success(let typed) = parse(text) else { continue }
            let address = LinkAddress(host: typed.host, port: typed.port == port ? nil : typed.port, kind: LinkAddress.Kind.added, label: "Added by you")
            let addedKey = key(address)
            guard !addedKeys.contains(addedKey) else { continue }
            addedKeys.insert(addedKey)
            items.removeAll { key($0.entry.address) == addedKey }
            let family = LinkIP(address.host)?.family == .v6 ? 1 : 0
            items.append(Item(entry: Entry(address: address), family: family, source: addedSource, order: nextOrder))
            nextOrder += 1
        }

        // Rule 8: left out stays listed, and isn't offered. Yours are removed instead.
        let out = Set(leftOut.compactMap(canonicalHost))
        for index in items.indices where !items[index].entry.isAdded {
            items[index].entry.leftOut = out.contains(items[index].entry.address.host)
        }

        // Rule 10: the local network, names, VPN addresses (IPv4 first; yours, then a VPN's own, then the interfaces'),
        // then the ones a phone can rarely reach.
        return items.sorted {
            ($0.group, $0.family, $0.source, $0.order) < ($1.group, $1.family, $1.source, $1.order)
        }.map(\.entry)
    }

    /// What's offered: not left out, in order.
    public static func offered(_ entries: [Entry]) -> [LinkAddress] {
        entries.filter { !$0.leftOut }.map(\.address)
    }

    /// The pairing code's addresses, which an iPhone 2.0 build (6-26) tries one by one, 4 s each, every time it connects
    /// (and every build as it pairs): the likeliest few. None a phone can rarely reach and none with their own port; the
    /// local network's IPv4 first, then other IPv4, then names, then IPv6, at most `pairingLimit` within `pairingBudget`
    /// bytes; each as "host:port" at the pairing port.
    public static func pairingAddresses(_ offered: [LinkAddress], port: UInt16) -> [String] {
        func group(_ address: LinkAddress) -> Int {
            switch LinkIP(address.host)?.family {
            case .v4?: address.kind == LinkAddress.Kind.local ? 0 : 1
            case nil: 2
            case .v6?: 3
            }
        }
        let candidates = offered.enumerated()
            .filter { $0.element.unlikely != true && $0.element.port == nil }
            .sorted { (group($0.element), $0.offset) < (group($1.element), $1.offset) }
            .map(\.element)
        var texts: [String] = []
        var used = 0
        for address in candidates where texts.count < pairingLimit {
            let text = address.pairingText(port: port)
            guard used + text.utf8.count <= pairingBudget else { continue }
            texts.append(text)
            used += text.utf8.count
        }
        return texts
    }

    /// Which address a phone came in on, as Paired devices says it: "100.64.0.2 (VPN)", "192.168.1.20 (Wi-Fi)", or "the
    /// local network" for a link-local address and for this Mac's IPv6 on Wi-Fi or Ethernet (only Bonjour reaches those).
    /// One you added is named as this Mac found it rather than "Added by you"; one it can't place is the address alone.
    /// `host` is canonical (`hostText`); `entries` is what Settings lists.
    public static func connectedOver(_ host: String, interfaces: [LinkInterface], vpns: [LinkVPNStatus] = [], entries: [Entry] = [],
                                     port: UInt16 = Link.port) -> String {
        if let found = classify(interfaces: interfaces, vpns: vpns, port: port).first(where: { $0.address.host == host }) {
            return "\(host) (\(found.address.label))"
        }
        let onLocalNetwork = interfaces.contains { interface in
            let bare = String(interface.address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            return interface.isUp && interface.name.hasPrefix("en") && LinkIP(bare)?.text == host
        }
        if onLocalNetwork || isLinkLocal(host) { return "the local network" }
        if let entry = entries.first(where: { $0.address.host == host }) { return "\(host) (\(entry.address.label))" }
        return host
    }

    // MARK: What people type

    /// An address someone typed, cleaned up: `text` is what's kept ("studio-mac.covee.example", "100.64.0.9:7450",
    /// "[fd7a:115c:a1e0::2]:7450", "fd7a:115c:a1e0::2").
    public struct Typed: Equatable, Sendable {
        public var host: String
        public var port: UInt16?
        public var text: String

        public init(host: String, port: UInt16?) {
            self.host = host
            self.port = port
            text = LinkAddresses.text(host: host, port: port)
        }

        /// The same with no port when its port is `port` (the link's): "100.64.0.2:7447" is kept as "100.64.0.2".
        public func dropping(port: UInt16) -> Typed {
            self.port == port ? Typed(host: host, port: nil) : self
        }

        /// "host|port", the port resolved with `defaultPort`, as LinkAddress.key says it.
        public func key(defaultPort: UInt16) -> String { "\(host)|\(port ?? defaultPort)" }
    }

    public enum Problem: Error, Equatable, Sendable {
        case empty, unreadable, port, duplicate, tooMany

        /// What Settings and the iPhone say. `port` is the link's, for "only if it isn't 7447".
        public func words(port: UInt16) -> String {
            switch self {
            case .empty: "Type a name or an IP address."
            case .unreadable: "Binders can't read that as an address. Type a name or an IP address, with :port at the end only if it isn't \(port). An IPv6 address with a port goes in brackets: [fd7a::2]:7450."
            case .port: "That port can't be used: it has to be between 1 and 65535."
            case .duplicate: "You've already added that address."
            case .tooMany: "You can add up to \(LinkAddresses.addedLimit) addresses. Remove one first."
            }
        }
    }

    /// Reads a name or an IP address, with an optional port: "studio-mac.covee.example", "100.64.0.9:7450",
    /// "[fd7a::2]:7450", "fd7a::2". IPv6 with a port needs brackets; a zone, a path, a user or a scheme isn't an address.
    public static func parse(_ raw: String) -> Result<Typed, Problem> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        let hostText: Substring
        var portText: Substring?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return .failure(.unreadable) }
            hostText = text[text.index(after: text.startIndex)..<close]
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return .failure(.unreadable) }
                portText = rest.dropFirst()
            }
            guard let ip = LinkIP(String(hostText)), ip.family == .v6 else { return .failure(.unreadable) }
            return port(portText).map { Typed(host: ip.text, port: $0) }
        }
        if text.filter({ $0 == ":" }).count > 1 {
            // A bare IPv6 address, which can't carry a port.
            guard let ip = LinkIP(text), ip.family == .v6 else { return .failure(.unreadable) }
            return .success(Typed(host: ip.text, port: nil))
        }
        if let colon = text.lastIndex(of: ":"), case let after = text[text.index(after: colon)...], !after.isEmpty,
           after.allSatisfy(\.isASCIIDigitCharacter) {
            hostText = text[..<colon]
            portText = after
        } else {
            hostText = text[...]
        }
        guard let host = canonicalHost(String(hostText)), LinkIP(host)?.family != .v6 else { return .failure(.unreadable) }
        return port(portText).map { Typed(host: host, port: $0) }
    }

    private static func port(_ text: Substring?) -> Result<UInt16?, Problem> {
        guard let text else { return .success(nil) }
        guard !text.isEmpty, text.allSatisfy(\.isASCIIDigitCharacter) else { return .failure(.unreadable) }
        guard let value = Int(text), (1...65535).contains(value) else { return .failure(.port) }
        return .success(UInt16(value))
    }

    // MARK: Helpers

    /// "host" or "host:port", IPv6 in brackets only with a port.
    static func text(host: String, port: UInt16?) -> String {
        guard let port else { return host }
        return isIPv6(host) ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    static func isIPv6(_ host: String) -> Bool { host.contains(":") }

    /// An IP address in its one written form, or a name as it's looked up (lowercased, no trailing dot). Nil for
    /// anything else.
    public static func canonicalHost(_ text: String) -> String? {
        if let ip = LinkIP(text) { return ip.text }
        return canonicalName(text)
    }

    /// A DNS name: ASCII letters, digits and hyphens in labels of 1 to 63 characters, none starting or ending with a
    /// hyphen, at most 253 characters. Digits and dots alone must be an IPv4 address, so "192.168.1" isn't a name.
    /// Checked scalar by scalar, and before lowercasing: a letter followed by a joiner or a combining mark is still one
    /// Character, which a range of Characters lets through, and lowercasing makes "İ" an "i" with a combining dot.
    static func canonicalName(_ text: String) -> String? {
        guard text.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        var name = text.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= 253 else { return nil }
        guard !name.allSatisfy({ $0 == "." || $0.isASCIIDigitCharacter }) else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.utf8.count), !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.unicodeScalars.allSatisfy({ $0 == "-" || ("a"..."z").contains($0) || ("0"..."9").contains($0) }) else { return nil }
        }
        return name
    }

    /// Whether this interface is a tunnel a VPN would make: by its name, or point to point (but not an IPv6 transition
    /// tunnel or one of Apple's own).
    static func isTunnel(_ interface: LinkInterface) -> Bool {
        let name = interface.name
        let skipped = ["gif", "stf", "bridge", "vmenet", "vnic", "awdl", "llw", "anpi", "ap", "lo"]
        if skipped.contains(where: name.hasPrefix) { return false }
        let tunnels = ["utun", "ipsec", "ppp", "wg", "tun", "tap", "feth", "zt"]
        return tunnels.contains(where: name.hasPrefix) || interface.isPointToPoint
    }

    /// The text of an endpoint's host as an address: IPv4 for an IPv4-mapped IPv6 one, no zone. For what a connection
    /// came in on, and what Bonjour reached.
    public static func hostText(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address):
            return LinkIP(bytes: [UInt8](address.rawValue))?.text
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return LinkIP(bytes: Array(bytes[12..<16]))?.text
            }
            return LinkIP(bytes: bytes)?.text
        case .name(let name, _):
            return canonicalHost(name) ?? name
        @unknown default:
            return nil
        }
    }

    /// Whether this host is a link-local IPv6 address (fe80::/10), which says only "the local network".
    public static func isLinkLocal(_ host: String) -> Bool {
        guard let ip = LinkIP(String(host.split(separator: "%").first ?? "")), ip.family == .v6 else { return false }
        return ip.bytes[0] == 0xFE && ip.bytes[1] & 0xC0 == 0x80
    }
}

/// An IP address in the one form Binders writes it: inet_ntop's text of its bytes.
struct LinkIP: Equatable {
    enum Family { case v4, v6 }
    let family: Family
    let bytes: [UInt8]
    let text: String

    /// IPv4 as exactly four dotted decimal parts of 0-255 (no shorthand), or IPv6 (no zone). Nil for anything else.
    init?(_ string: String) {
        if let bytes = Self.ipv4Bytes(string) {
            self.init(bytes: bytes)
            return
        }
        guard string.contains(":"), !string.contains("%"), let address = IPv6Address(string) else { return nil }
        self.init(bytes: [UInt8](address.rawValue))
    }

    init?(bytes: [UInt8]) {
        switch bytes.count {
        case 4: family = .v4
        case 16: family = .v6
        default: return nil
        }
        self.bytes = bytes
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
        let written = bytes.withUnsafeBytes { raw in
            inet_ntop(bytes.count == 4 ? AF_INET : AF_INET6, raw.baseAddress, &buffer, socklen_t(buffer.count))
        }
        guard written != nil else { return nil }
        text = String(cString: buffer)
    }

    private static func ipv4Bytes(_ string: String) -> [UInt8]? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCIIDigitCharacter), let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    /// Never offered to a phone: unspecified, loopback, self-assigned, multicast and the like.
    var isNeverOffered: Bool {
        switch family {
        case .v4:
            return bytes[0] == 0 || bytes[0] == 127 || (bytes[0] == 169 && bytes[1] == 254) || bytes[0] >= 224
        case .v6:
            let zeroPrefix = bytes[0..<10].allSatisfy { $0 == 0 }
            if zeroPrefix, bytes[10] == 0xFF, bytes[11] == 0xFF { return true }      // ::ffff:0:0/96
            if bytes.allSatisfy({ $0 == 0 }) { return true }                          // ::
            if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }  // ::1
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }              // fe80::/10
            return bytes[0] == 0xFF                                                   // ff00::/8
        }
    }

    /// A VPN's kind of address: IPv4 private (10/8, 172.16/12, 192.168/16) or CGNAT (100.64/10), IPv6 unique-local
    /// (fc00::/7).
    var isVPNRange: Bool {
        switch family {
        case .v4:
            return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 100 && (64...127).contains(bytes[1]))
        case .v6:
            return bytes[0] & 0xFE == 0xFC
        }
    }

    /// An address out on the internet: IPv4 that isn't private, CGNAT or never offered; IPv6 in 2000::/3.
    var isPublic: Bool {
        switch family {
        case .v4: return !isVPNRange && !isNeverOffered
        case .v6: return bytes[0] & 0xE0 == 0x20
        }
    }
}

extension Character {
    /// 0-9 only, and alone: `isNumber` takes other scripts' digits too, and a range of Characters takes a digit with a
    /// combining mark after it.
    var isASCIIDigitCharacter: Bool { asciiValue.map { (0x30...0x39).contains($0) } ?? false }
}
