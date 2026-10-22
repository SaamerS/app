import Foundation

/// Who made a version of a note: you, a teammate (their copy arrived through the team folder), or an agent, and whose
/// agent it is. As the team database will keep it with each version (`note_versions`).
public struct NoteAuthor: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case person, teammate, agent
    }

    /// "You", a teammate's name, or an agent's board name.
    public var name: String
    public var kind: Kind
    /// Whose agent it is, for an agent: "You" for yours (it came through this Mac), a teammate's name for theirs.
    public var owner: String?

    public init(name: String, kind: Kind, owner: String? = nil) {
        self.name = name
        self.kind = kind
        self.owner = kind == .agent ? (owner ?? BoardActor.you.name) : nil
    }

    public static let you = NoteAuthor(name: BoardActor.you.name, kind: .person)

    /// Binders itself: a to-do ticked when its card was done, a link following a renamed note.
    public static let binders = NoteAuthor(name: "Binders", kind: .person)

    public static func agent(_ name: String, owner: String? = nil) -> NoteAuthor { NoteAuthor(name: name, kind: .agent, owner: owner) }
    public static func teammate(_ name: String) -> NoteAuthor { NoteAuthor(name: name, kind: .teammate) }

    public var isAgent: Bool { kind == .agent }
    public var isYou: Bool { kind == .person && name == BoardActor.you.name }

    /// "you", "Sam", "Claude Code (your agent)", "Pennant (Sam's agent)": as a sentence says who changed something.
    public var phrase: String {
        switch kind {
        case .person: return isYou ? "you" : name
        case .teammate: return name
        case .agent:
            let whose = owner.map { $0 == BoardActor.you.name ? "your agent" : "\($0)'s agent" } ?? "an agent"
            return "\(name) (\(whose))"
        }
    }

    /// The same, at the start of a sentence or alone: "You", "Sam", "Claude Code (your agent)".
    public var label: String {
        let phrase = self.phrase
        return phrase.prefix(1).uppercased() + phrase.dropFirst()
    }

    private enum CodingKeys: String, CodingKey {
        case name, kind, owner
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? BoardActor.you.name
        // A kind a later build adds reads as a person's.
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .person
        // As the memberwise init has it: an agent is yours unless it says whose, and only an agent has an owner.
        let owner = try c.decodeIfPresent(String.self, forKey: .owner)
        self.owner = kind == .agent ? (owner ?? BoardActor.you.name) : nil
    }
}

/// What Binders knows of a note's kept versions beyond their text (History/<note id>/versions.json): who made each one,
/// the name someone gave it, and the distills that read it; who wrote the note's text as it is now; and, for a heading,
/// who last changed its section and when. Kept for notes with Distill on.
public struct NoteVersionIndex: Codable, Equatable, Sendable {
    public struct Version: Codable, Equatable, Sendable {
        /// Who wrote the text this version keeps.
        public var by: NoteAuthor
        /// "Approved", "v2": given by someone.
        public var name: String?
        /// The distills that read this version.
        public var distills: [UUID]
        /// Put back from an earlier version (its id), when that's what made it.
        public var restoredFrom: String?

        public init(by: NoteAuthor, name: String? = nil, distills: [UUID] = [], restoredFrom: String? = nil) {
            self.by = by
            self.name = name
            self.distills = distills
            self.restoredFrom = restoredFrom
        }

        private enum CodingKeys: String, CodingKey {
            case by, name, distills, restoredFrom
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            by = (try? c.decodeIfPresent(NoteAuthor.self, forKey: .by)) ?? .you
            name = try c.decodeIfPresent(String.self, forKey: .name)
            distills = (try? c.decodeIfPresent([UUID].self, forKey: .distills)) ?? []
            restoredFrom = try c.decodeIfPresent(String.self, forKey: .restoredFrom)
        }
    }

    /// Who wrote the text as it is now, since when, and the version it was put back from.
    public struct Current: Codable, Equatable, Sendable {
        public var by: NoteAuthor
        public var since: Date
        public var restoredFrom: String?

        public init(by: NoteAuthor, since: Date, restoredFrom: String? = nil) {
            self.by = by
            self.since = since
            self.restoredFrom = restoredFrom
        }
    }

    /// Who last changed a section, and when, with the section's hash then.
    public struct Stamp: Codable, Equatable, Sendable {
        public var hash: String
        public var by: NoteAuthor
        public var at: Date

        public init(hash: String, by: NoteAuthor, at: Date) {
            self.hash = hash
            self.by = by
            self.at = at
        }
    }

    public var versions: [String: Version]
    public var current: Current?
    /// By heading (`DistillSections.Section.title`).
    public var sections: [String: Stamp]

    public init(versions: [String: Version] = [:], current: Current? = nil, sections: [String: Stamp] = [:]) {
        self.versions = versions
        self.current = current
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey {
        case versions, current, sections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        versions = (try? c.decodeIfPresent([String: Version].self, forKey: .versions)) ?? [:]
        current = try? c.decodeIfPresent(Current.self, forKey: .current)
        sections = (try? c.decodeIfPresent([String: Stamp].self, forKey: .sections)) ?? [:]
    }

    /// A change by `author` is about to land: the text there now is kept as version `id`, by whoever wrote it, and the
    /// note's text is the author's from `at`. `restoring`: the version being put back.
    public mutating func kept(_ id: String?, before change: NoteAuthor, at date: Date, restoring: String? = nil) {
        let wrote = current?.by ?? .you
        if let id {
            var version = versions[id] ?? Version(by: wrote)
            version.by = wrote
            if let from = current?.restoredFrom { version.restoredFrom = from }
            versions[id] = version
        }
        current = Current(by: change, since: date, restoredFrom: restoring)
    }

    /// Whether a change by `author` should keep the text first, whatever the time since the last version: the text there
    /// now is someone else's.
    public func authorChanges(to author: NoteAuthor) -> Bool {
        guard let current else { return false }
        return current.by != author
    }

    /// Notes who changed each section that differs from its stamp, as `text` now reads, by `author` at `date`. Returns the
    /// headings whose stamp changed.
    @discardableResult
    public mutating func stamp(_ text: String, by author: NoteAuthor, at date: Date) -> [String] {
        var changed: [String] = []
        for section in DistillSections.sections(of: text) {
            let hash = section.hash
            guard sections[section.title]?.hash != hash else { continue }
            // A section seen for the first time (Distill just turned on) is stamped by whoever wrote the text now.
            sections[section.title] = Stamp(hash: hash, by: author, at: date)
            changed.append(section.title)
        }
        return changed
    }
}

extension NoteVersions {
    /// One version as history lists it: its id (the moment it was kept, in milliseconds), when, who, its name, lines added
    /// and removed since the version before it, the sections it touched, and the distills that read it.
    public struct Entry: Equatable, Sendable {
        public var id: String
        public var at: Date
        public var by: NoteAuthor
        public var name: String?
        public var added: Int
        public var removed: Int
        public var sections: [String]
        public var distills: [UUID]
        public var restoredFrom: String?

        /// One made elsewhere: a shared note's version on the team database (lane DB3).
        public init(id: String, at: Date, by: NoteAuthor, name: String? = nil, added: Int = 0, removed: Int = 0, sections: [String] = [],
                    distills: [UUID] = [], restoredFrom: String? = nil) {
            self.id = id
            self.at = at
            self.by = by
            self.name = name
            self.added = added
            self.removed = removed
            self.sections = sections
            self.distills = distills
            self.restoredFrom = restoredFrom
        }
    }

    /// Kept versions, newest first, with the note as it is now first of all (id "now"), each compared with the one before
    /// it. `texts` are the kept versions' (id, when, text) in any order; versions the index doesn't know are by you.
    public static func entries(texts: [(id: String, at: Date, text: String)], now text: String, index: NoteVersionIndex,
                               now date: Date = Date()) -> [Entry] {
        let ordered = texts.sorted { $0.at < $1.at }
        var entries: [Entry] = []
        var previous: String?
        for version in ordered {
            let info = index.versions[version.id]
            let counts: (added: Int, removed: Int) = previous.map { change(from: $0, to: version.text) }
                ?? (added: version.text.components(separatedBy: "\n").count, removed: 0)
            entries.append(Entry(id: version.id, at: version.at, by: info?.by ?? .you, name: info?.name, added: counts.added, removed: counts.removed,
                                 sections: previous.map { DistillSections.touched(from: $0, to: version.text) } ?? [],
                                 distills: info?.distills ?? [], restoredFrom: info?.restoredFrom))
            previous = version.text
        }
        if previous != text {
            let counts: (added: Int, removed: Int) = previous.map { change(from: $0, to: text) }
                ?? (added: text.components(separatedBy: "\n").count, removed: 0)
            entries.append(Entry(id: nowID, at: index.current?.since ?? date, by: index.current?.by ?? .you, name: nil, added: counts.added,
                                 removed: counts.removed, sections: previous.map { DistillSections.touched(from: $0, to: text) } ?? [],
                                 distills: [], restoredFrom: index.current?.restoredFrom))
        }
        return entries.reversed()
    }

    /// The id that stands for the note as it is now.
    public static let nowID = "now"

    /// "3 lines added, 1 removed"; "No change" when neither.
    public static func counts(added: Int, removed: Int) -> String {
        var parts: [String] = []
        if added > 0 { parts.append("\(added) \(added == 1 ? "line" : "lines") added") }
        if removed > 0 { parts.append("\(removed) removed") }
        return parts.isEmpty ? "No change" : parts.joined(separator: ", ")
    }
}
