import Foundation

/// What the phone remembers about its Mac: who it is, and every address it knows for it. The device key lives in the
/// Keychain. Kept as JSON in the phone's preferences ("pairedMac"), with the keys builds 6-26 wrote; the newer fields
/// are Optional and read one by one, so a damaged one never unpairs the phone.
public struct PairedMac: Codable, Equatable, Sendable {
    public var device: UUID
    public var name: String
    /// From the pairing code, tried at `port`. A phone paired by Mac 0.8.0 has only the Wi-Fi address here.
    public var hosts: [String]
    public var port: UInt16
    /// The address that worked last, and its port when that isn't `port` (one added with its own). Always tried at once.
    public var lastHost: String?
    public var lastPort: UInt16?
    /// What the Mac said its addresses were at its last hello or notice: replaced each time. Nil for a Mac before 0.8.1.
    public var learned: [LinkAddress]?
    /// Addresses you added on this iPhone, as LinkAddresses.Typed.text.
    public var added: [String]?
    /// Addresses that won a dial in the last 30 days, newest first, at most 4: one a hello left out (its VPN was down on
    /// the Mac just then) is still tried.
    public var worked: [LinkWorked]?

    public init(device: UUID, name: String, hosts: [String], port: UInt16, lastHost: String? = nil, lastPort: UInt16? = nil,
                learned: [LinkAddress]? = nil, added: [String]? = nil, worked: [LinkWorked]? = nil) {
        self.device = device
        self.name = name
        self.hosts = hosts
        self.port = port
        self.lastHost = lastHost
        self.lastPort = lastPort
        self.learned = learned
        self.added = added
        self.worked = worked
    }

    private enum CodingKeys: String, CodingKey { case device, name, hosts, port, lastHost, lastPort, learned, added, worked }

    /// The five original fields as they always read; each newer one on its own, and the lists item by item, so one a
    /// newer build wrote differently is dropped alone.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try container.decode(UUID.self, forKey: .device)
        name = try container.decode(String.self, forKey: .name)
        hosts = try container.decode([String].self, forKey: .hosts)
        port = try container.decode(UInt16.self, forKey: .port)
        lastHost = try container.decodeIfPresent(String.self, forKey: .lastHost)
        lastPort = (try? container.decodeIfPresent(UInt16.self, forKey: .lastPort)).flatMap { $0 }.flatMap { $0 == 0 ? nil : $0 }
        learned = (try? container.decodeIfPresent(LossyList<LinkAddress>.self, forKey: .learned)).flatMap { $0 }?.items
        added = (try? container.decodeIfPresent(LossyList<String>.self, forKey: .added)).flatMap { $0 }?.items
        worked = (try? container.decodeIfPresent(LossyList<LinkWorked>.self, forKey: .worked)).flatMap { $0 }?.items
    }
}

/// An address that won a dial, with the label it had then.
public struct LinkWorked: Codable, Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var label: String
    public var at: Date

    public init(host: String, port: UInt16, label: String, at: Date) {
        self.host = host
        self.port = port
        self.label = label
        self.at = at
    }
}

/// One way to try the Mac: Bonjour, or one host and port, with where it came from.
public struct LinkCandidate: Equatable, Sendable, Identifiable {
    public enum Source: String, Sendable { case bonjour, learned, added, worked, paired, last }
    public static let bonjourID = "bonjour"

    /// "bonjour", or "host|port".
    public var id: String
    /// Nil for Bonjour.
    public var host: String?
    public var port: UInt16
    /// As the list shows it: "Bonjour", "192.168.1.20", "[fd7a:115c:a1e0::2]:7450".
    public var name: String
    /// "On this network", "Wi-Fi", "VPN · in the pairing code"…
    public var label: String
    /// The best source it came from: learned, then added, worked, paired, last.
    public var source: Source
    /// In `added`: Remove is offered.
    public var addedHere: Bool
    /// Only there because it worked (or was the last good one): Remove, which forgets it, is offered.
    public var workedOnly: Bool
    /// In `hosts`, from the pairing code.
    public var fromPairing: Bool
    /// Bonjour (found by the Mac's name), an address the Mac listed, or the last good one: one of these failing the key
    /// means the Mac doesn't know this iPhone, where a stale or typed address could be anything.
    public var vouched: Bool
    /// Starts at t=0.
    public var atOnce: Bool
    public var unlikely: Bool

    public init(id: String, host: String?, port: UInt16, name: String, label: String, source: Source, addedHere: Bool = false,
                workedOnly: Bool = false, fromPairing: Bool = false, vouched: Bool = false, atOnce: Bool = false, unlikely: Bool = false) {
        self.id = id
        self.host = host
        self.port = port
        self.name = name
        self.label = label
        self.source = source
        self.addedHere = addedHere
        self.workedOnly = workedOnly
        self.fromPairing = fromPairing
        self.vouched = vouched
        self.atOnce = atOnce
        self.unlikely = unlikely
    }

    /// What you'd type for it: "100.64.0.2", "studio:7450".
    public var text: String { name }
}

public enum LinkCandidates {
    /// Host addresses a dial tries, besides Bonjour.
    public static let dialLimit = 12
    /// Addresses kept because they worked, and for how long.
    public static let workedLimit = 4
    public static let workedDays = 30
}

extension PairedMac {
    /// Every way to try this Mac, in order, each once: at once Bonjour (when the browser sees the Mac), the address that
    /// worked last and `preferred` (one just tested); then what you added here, what the Mac said (apart from ones it can
    /// rarely be reached at), what worked before (in the last 30 days), the pairing code's, and last the rarely reachable
    /// ones. `limit` caps the host addresses (nil for the Your Mac list).
    public func candidates(bonjour: Bool, preferred: String? = nil, limit: Int? = LinkCandidates.dialLimit,
                           at now: Date = Date()) -> [LinkCandidate] {
        struct Draft {
            var host: String
            var port: UInt16
            var sources: Set<LinkCandidate.Source>
            var learned: LinkAddress?
            var workedLabel: String?
            var unlikely = false
        }
        var drafts: [Draft] = []
        var positions: [String: Int] = [:]
        func note(_ host: String, _ port: UInt16, _ source: LinkCandidate.Source, learned: LinkAddress? = nil, worked: LinkWorked? = nil) {
            let host = Self.canonical(host)
            let id = "\(host)|\(port)"
            if let index = positions[id] {
                drafts[index].sources.insert(source)
                if drafts[index].learned == nil { drafts[index].learned = learned }
                if drafts[index].workedLabel == nil { drafts[index].workedLabel = worked?.label }
                if learned?.unlikely == true { drafts[index].unlikely = true }
                return
            }
            positions[id] = drafts.count
            drafts.append(Draft(host: host, port: port, sources: [source], learned: learned, workedLabel: worked?.label,
                                unlikely: learned?.unlikely == true))
        }
        if let lastHost { note(lastHost, lastPort ?? port, .last) }
        for text in added ?? [] {
            guard case .success(let typed) = LinkAddresses.parse(text) else { continue }
            note(typed.host, typed.port ?? port, .added)
        }
        let learned = learned ?? []
        for address in learned where address.unlikely != true { note(address.host, address.port ?? port, .learned, learned: address) }
        for entry in worked ?? [] where now.timeIntervalSince(entry.at) < Double(LinkCandidates.workedDays) * 86_400 {
            note(entry.host, entry.port, .worked, worked: entry)
        }
        for host in hosts { note(host, port, .paired) }
        for address in learned where address.unlikely == true { note(address.host, address.port ?? port, .learned, learned: address) }

        var list = drafts.map { draft -> LinkCandidate in
            let id = "\(draft.host)|\(draft.port)"
            let sources = draft.sources
            let addedHere = sources.contains(.added)
            let unlikely = draft.unlikely && !addedHere
            let order: [LinkCandidate.Source] = [.learned, .added, .worked, .paired, .last]
            let best = order.first(where: sources.contains) ?? .last
            var parts: [String] = []
            switch best {
            case .learned: parts.append(Self.macLabel(draft.learned))
            case .added: parts.append("Added on this iPhone")
            case .worked: parts.append(draft.workedLabel.map { $0.isEmpty ? "Worked before" : "\($0) · worked before" } ?? "Worked before")
            case .paired: parts.append("From pairing")
            case .last, .bonjour: parts.append("Used last time")
            }
            if addedHere, best != .added { parts.append("added on this iPhone") }
            if sources.contains(.paired), best != .paired { parts.append("in the pairing code") }
            if unlikely { parts.append("rarely reachable") }
            return LinkCandidate(id: id, host: draft.host, port: draft.port,
                                 name: LinkAddresses.text(host: draft.host, port: draft.port == port ? nil : draft.port),
                                 label: parts.joined(separator: " · "), source: best, addedHere: addedHere,
                                 workedOnly: sources.isSubset(of: [.worked, .last]), fromPairing: sources.contains(.paired),
                                 vouched: sources.contains(.learned) || sources.contains(.last),
                                 atOnce: sources.contains(.last) || id == preferred, unlikely: unlikely)
        }
        // At once first: the last good one, then the one just tested.
        let first = list.filter(\.atOnce).sorted { ($0.source == .last || $0.id == lastKey ? 0 : 1) < ($1.source == .last || $1.id == lastKey ? 0 : 1) }
        list = first + list.filter { !$0.atOnce }
        if let limit { list = Array(list.prefix(limit)) }
        if bonjour {
            list.insert(LinkCandidate(id: LinkCandidate.bonjourID, host: nil, port: port, name: "Bonjour", label: "On this network",
                                      source: .bonjour, vouched: true, atOnce: true), at: 0)
        }
        return list
    }

    /// Replaces what the Mac said; true when it changed (the phone saves only then).
    public mutating func learn(_ list: [LinkAddress]) -> Bool {
        guard learned != list else { return false }
        learned = list
        return true
    }

    /// Adds one you typed: read, with a port equal to `port` dropped; refused when it's already among the ones you added
    /// (`duplicate`) or there are `addedLimit` already. A learned, paired or worked address is taken: it becomes yours,
    /// and stays whatever the Mac says.
    public mutating func add(_ text: String) -> LinkAddresses.Problem? {
        let typed: LinkAddresses.Typed
        switch LinkAddresses.parse(text) {
        case .failure(let problem): return problem
        case .success(let read): typed = read.dropping(port: port)
        }
        var list = added ?? []
        let key = typed.key(defaultPort: port)
        if list.contains(where: { addedKey($0) == key }) { return .duplicate }
        guard list.count < LinkAddresses.addedLimit else { return .tooMany }
        list.append(typed.text)
        added = list
        return nil
    }

    /// The id one you typed would have: "host|port".
    public func id(ofTyped text: String) -> String? {
        guard case .success(let typed) = LinkAddresses.parse(text) else { return nil }
        return typed.dropping(port: port).key(defaultPort: port)
    }

    /// Remove on a row you added: it goes from what you added. One the Mac lists, or the pairing code had, stays as theirs,
    /// and keeps what it did (what worked, the last good one), so a hello that misses it later still can't lose it. Any
    /// other goes from what worked and from the last good one too, so the row goes.
    public mutating func removeAdded(_ id: String) {
        added = added?.filter { addedKey($0) != id }
        if added?.isEmpty == true { added = nil }
        guard !listed(id) else { return }
        dropWorked(id)
        if lastKey == id { forgetLast() }
    }

    /// Remove on a row that's only there because it worked: forgotten, and no longer the last good one.
    public mutating func forget(_ id: String) {
        dropWorked(id)
        if lastKey == id { forgetLast() }
    }

    /// The address that just won: the last good one (its port kept when it isn't `port`), and first of what worked, its
    /// date refreshed when it's a day old; ones older than 30 days are dropped, and at most 4 kept. Bonjour changes
    /// nothing. True when anything changed, so a connect rarely writes.
    public mutating func used(_ candidate: LinkCandidate, at now: Date = Date()) -> Bool {
        guard candidate.source != .bonjour, let host = candidate.host else { return false }
        var changed = false
        let port = candidate.port == self.port ? nil : candidate.port
        if lastHost.map(Self.canonical) != host || lastPort != port {
            lastHost = host
            lastPort = port
            changed = true
        }
        let before = worked ?? []
        var list = before.filter { now.timeIntervalSince($0.at) < Double(LinkCandidates.workedDays) * 86_400 }
        let id = candidate.id
        if let index = list.firstIndex(where: { "\(Self.canonical($0.host))|\($0.port)" == id }) {
            var entry = list.remove(at: index)
            if now.timeIntervalSince(entry.at) >= 86_400 { entry.at = now }
            if let label = label(forWorked: id), !label.isEmpty { entry.label = label }
            list.insert(entry, at: 0)
        } else {
            list.insert(LinkWorked(host: host, port: candidate.port, label: label(forWorked: id) ?? "", at: now), at: 0)
        }
        if list.count > LinkCandidates.workedLimit { list = Array(list.prefix(LinkCandidates.workedLimit)) }
        if list != before {
            worked = list
            changed = true
        }
        return changed
    }

    /// Pairing again with a Mac of the same name: what you added and what worked carry over (the device id is new, the
    /// Mac's addresses aren't).
    public mutating func carryOver(from old: PairedMac) {
        guard old.name == name else { return }
        var list = added ?? []
        for text in old.added ?? [] where !list.contains(where: { addedKey($0) == addedKey(text) }) && list.count < LinkAddresses.addedLimit {
            list.append(text)
        }
        added = list.isEmpty ? nil : list
        var kept = worked ?? []
        for entry in old.worked ?? [] where !kept.contains(where: { $0.host == entry.host && $0.port == entry.port }) {
            kept.append(entry)
        }
        kept = Array(kept.sorted { $0.at > $1.at }.prefix(LinkCandidates.workedLimit))
        worked = kept.isEmpty ? nil : kept
    }

    /// The id of the address that worked last, "host|port", as its candidate has it.
    public var lastID: String? { lastKey }

    // MARK: Helpers

    /// The last good address's id, "host|port".
    var lastKey: String? { lastHost.map { "\(Self.canonical($0))|\(lastPort ?? port)" } }

    private func addedKey(_ text: String) -> String? { id(ofTyped: text) }

    /// The Mac said it at its last hello, or the pairing code had it.
    private func listed(_ id: String) -> Bool {
        (learned ?? []).contains { "\(Self.canonical($0.host))|\($0.port ?? port)" == id }
            || hosts.contains { "\(Self.canonical($0))|\(port)" == id }
    }

    private mutating func dropWorked(_ id: String) {
        worked = worked?.filter { "\(Self.canonical($0.host))|\($0.port)" != id }
        if worked?.isEmpty == true { worked = nil }
    }

    private mutating func forgetLast() {
        lastHost = nil
        lastPort = nil
    }

    /// What it is, as a worked address keeps it: the Mac's word for it, or what it had before.
    private func label(forWorked id: String) -> String? {
        if let address = learned?.first(where: { "\(Self.canonical($0.host))|\($0.port ?? port)" == id }) { return Self.macLabel(address) }
        return worked?.first(where: { "\(Self.canonical($0.host))|\($0.port)" == id })?.label
    }

    /// The Mac's label as the phone says it: its own words, except that "Added by you" there is "Added on your Mac" here.
    static func macLabel(_ address: LinkAddress?) -> String {
        guard let address else { return "From your Mac" }
        switch address.kind {
        case LinkAddress.Kind.added: return "Added on your Mac"
        case LinkAddress.Kind.local: return address.label.isEmpty ? "Local network" : address.label
        case LinkAddress.Kind.vpn: return address.label.isEmpty ? "VPN" : address.label
        case LinkAddress.Kind.tailscale: return address.label.isEmpty ? "Tailscale" : address.label
        default: return address.label.isEmpty ? "From your Mac" : address.label
        }
    }

    static func canonical(_ host: String) -> String {
        LinkAddresses.canonicalHost(host) ?? host.lowercased()
    }
}

/// What the phone's network looks like, from NWPathMonitor, for telling when it's worth trying the Mac again.
public struct LinkNetwork: Equatable, Sendable {
    public var reachable: Bool
    public var interfaces: Set<String>
    public var gateways: Set<String>

    public init(reachable: Bool, interfaces: Set<String> = [], gateways: Set<String> = []) {
        self.reachable = reachable
        self.interfaces = interfaces
        self.gateways = gateways
    }

    /// Reachable now, and it wasn't before, or an interface appeared, or the gateways changed (a different Wi-Fi).
    public func gainsRoute(over old: LinkNetwork) -> Bool {
        reachable && (!old.reachable || !interfaces.subtracting(old.interfaces).isEmpty || gateways != old.gateways)
    }

    /// That interface was there before and isn't now. One iOS never listed (a VPN's utun, sometimes) is never lost.
    public func lost(_ interface: String?, since old: LinkNetwork) -> Bool {
        guard let interface else { return false }
        return old.interfaces.contains(interface) && !interfaces.contains(interface)
    }
}

/// A list read item by item: one that doesn't decode is dropped, and the rest are kept.
struct LossyList<Element: Decodable>: Decodable {
    var items: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [Element] = []
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) {
                items.append(item)
            } else if (try? container.decode(Skipped.self)) == nil {
                break
            }
        }
        self.items = items
    }

    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
