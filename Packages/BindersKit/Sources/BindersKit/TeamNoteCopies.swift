import Foundation

// Notes copied under new ids when a Mac connected or joined (lane DB9). Build 39 kept a note "aside" whenever the team
// database said it was deleted while any call for it waited: a new note with the same words, under a new id, which the
// Mac then shared as its own. On a Mac that connected over deletions an earlier Binders left, and on each teammate's Mac
// that joined from its team-folder copies, every such note came back once more. These are the rules for telling an edit
// made here from the calls that bring a note in, and for finding those copies again so an admin can remove them.

/// The operation ids of the note changes a Mac makes on its own, besides an edit made here: what a Mac merges into a note
/// another Mac shared first, and what a move brings in from the team folder. The same words always give the same id, so
/// each goes at most once.
public enum TeamNoteOperations {
    /// A note this Mac tried to make that the database already had: this Mac's words, as a change from where it came in.
    public static func merge(note: UUID, hash: String) -> UUID {
        TeamOperationID.derived("merge note \(note.uuidString.lowercased()) \(hash)")
    }

    /// What changed in the team folder since a note came in, brought in by a move.
    public static func bringIn(note: UUID, member: UUID, hash: String) -> UUID {
        TeamOperationID.derived("move note \(note.uuidString.lowercased()) by \(member.uuidString.lowercased()) \(hash)")
    }

    /// Whether a call is an edit made on this Mac (typing, an agent's write, a restore, a property): an `add_note_changes`
    /// that isn't a merge or a move's bringing in. `member`: this Mac's member, whose moves those are.
    public static func isEditMadeHere(_ call: TeamCall, member: UUID?) -> Bool {
        guard call.function == "add_note_changes", let note = call.note else { return false }
        let hashes = call.argument("p_changes").flatMap { TeamJSON(text: $0) }?.array?.compactMap { $0["hash"]?.string } ?? []
        for hash in hashes {
            if call.operation == merge(note: note, hash: hash) { return false }
            if let member, call.operation == bringIn(note: note, member: member, hash: hash) { return false }
        }
        return true
    }

    /// Whether a call puts a deleted note back (`create_note` with `p_undelete`, as Undo sends it).
    public static func isUndelete(_ call: TeamCall) -> Bool {
        call.function == "create_note" && call.argument("p_undelete") == "true"
    }
}

/// Finding the copies of notes an earlier Binders made (lane DB9), for Settings → Team → Remove copies made when teammates
/// joined…. Only what the database can tell: each live note's title and words, who made it, when, and when the feed first
/// had it.
public enum TeamNoteCopies {
    /// One live note of a binder.
    public struct Note: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var binder: UUID
        public var folder: UUID?
        public var title: String
        /// Its words as the database has them now: its saved copy with every change since.
        public var text: String
        /// The member it's by (`created_by`).
        public var maker: UUID?
        public var createdAt: Date?
        /// Where the feed first had it (the `insert` change's number); nil when that part of the feed was pruned, so it's
        /// older than any it has.
        public var firstSeen: Int64?

        public init(id: UUID, binder: UUID, folder: UUID? = nil, title: String, text: String, maker: UUID?, createdAt: Date? = nil, firstSeen: Int64? = nil) {
            self.id = id
            self.binder = binder
            self.folder = folder
            self.title = title
            self.text = text
            self.maker = maker
            self.createdAt = createdAt
            self.firstSeen = firstSeen
        }
    }

    /// A copy to remove, and the note it copies, which stays.
    public struct Copy: Equatable, Sendable, Identifiable {
        public var note: Note
        public var keeps: Note
        public var id: UUID { note.id }
    }

    public struct Found: Equatable, Sendable {
        /// The copies to remove.
        public var copies: [Copy] = []
        /// Notes left as they are that share a title with another note made by someone else, with different words: for a
        /// person to look at.
        public var near: [Note] = []

        public init(copies: [Copy] = [], near: [Note] = []) {
            self.copies = copies
            self.near = near
        }

        public var isEmpty: Bool { copies.isEmpty && near.isEmpty }
    }

    /// Which came first: the one the feed had first (a pruned part of the feed is older than any it still has), then the
    /// one made first, then by id, so the answer never changes from one run to the next.
    public static func first(_ a: Note, _ b: Note) -> Bool {
        switch (a.firstSeen, b.firstSeen) {
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(x), .some(y)) where x != y: return x < y
        default: break
        }
        let (x, y) = (a.createdAt ?? .distantPast, b.createdAt ?? .distantPast)
        if x != y { return x < y }
        return a.id.uuidString < b.id.uuidString
    }

    /// The copies in a binder's live notes. Exact copies are notes with the same title and the same words, character for
    /// character, made by at least two members; blank notes are never copies. Of each set of exact copies, the one that
    /// stays is the binder's owner's (the first of theirs), else the first; each one made by someone else than the one
    /// that stays is a copy to remove. One made by the same member as the one that stays is left: that's theirs to keep
    /// twice. Run again after the copies are gone, it finds none.
    public static func find(_ notes: [Note], owner: UUID?) -> Found {
        var found = Found()
        let written = notes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        struct Words: Hashable { var binder: UUID; var title: String; var text: String }
        var removed: Set<UUID> = []
        for (_, group) in Dictionary(grouping: written, by: { Words(binder: $0.binder, title: $0.title, text: $0.text) }) where group.count > 1 {
            guard Set(group.map(\.maker)).count > 1 else { continue }
            let ordered = group.sorted(by: first)
            let keeps = ordered.first { owner != nil && $0.maker == owner } ?? ordered[0]
            for note in ordered where note.id != keeps.id && note.maker != keeps.maker {
                found.copies.append(Copy(note: note, keeps: keeps))
                removed.insert(note.id)
            }
        }
        struct Title: Hashable { var binder: UUID; var title: String }
        for (_, group) in Dictionary(grouping: written.filter { !removed.contains($0.id) }, by: { Title(binder: $0.binder, title: $0.title) }) {
            guard Set(group.map(\.text)).count > 1, Set(group.map(\.maker)).count > 1 else { continue }
            found.near += group.sorted(by: first)
        }
        found.copies.sort { $0.note.title == $1.note.title ? first($0.note, $1.note) : $0.note.title.localizedStandardCompare($1.note.title) == .orderedAscending }
        found.near.sort { $0.title == $1.title ? first($0, $1) : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return found
    }
}
