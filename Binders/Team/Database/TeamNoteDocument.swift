import Foundation
import BindersAutomerge
import BindersKit

/// One shared note's Automerge document on this Mac (lane DB3), in BindersKit's terms: its text, its props as TeamJSON,
/// splices from TextEdits. Automerge itself is in the BindersAutomerge framework (NoteDocument), which only speaks
/// Foundation.
///
/// - The first change, the skeleton that makes `text` and `props`, is the same change on every Mac; every change after it
///   is this Mac's, under an actor of its own (`actorID`).
/// - After a change of its own, a document's only head is that change: "the note as its author left it" is the text at
///   that one hash.
///
/// Sendable so it can be saved to disk off the main thread (lane DB10): Automerge's Document takes a lock around every
/// call, and the rest of it never changes.
final class TeamNoteDocument: @unchecked Sendable {
    let note: UUID
    private let document: NoteDocument

    var actorID: UUID { document.actorID }

    /// A new note's document: the skeleton, then this Mac's actor, ready for its first words.
    init(new note: UUID, actor: UUID) throws {
        self.note = note
        document = try NoteDocument(new: note, actor: actor)
    }

    /// A note's document from what the database has: its saved copy (if any), then every change.
    init(note: UUID, saved: Data?, changes: [Data], actor: UUID) throws {
        self.note = note
        document = try NoteDocument(note: note, saved: saved, changes: changes, actor: actor)
    }

    /// The skeleton's hash, the same for the note on every Mac.
    static func skeletonHash(_ note: UUID) -> String? { NoteDocument.skeletonHash(note) }

    /// A fresh actor for this Mac's changes to a note: random, so no two Macs (or two copies) ever write as one.
    static func newActor() -> UUID { UUID() }

    // MARK: Reading

    var text: String { document.text }
    var props: [String: TeamJSON] { document.props.mapValues(Self.json) }
    var heads: [String] { document.heads }
    var changeCount: Int { document.changeCount }

    func has(_ hash: String) -> Bool { document.has(hash) }
    func text(at heads: [String]) throws -> String { try document.text(at: heads) }
    func props(at heads: [String]) throws -> [String: TeamJSON] { try document.props(at: heads).mapValues(Self.json) }
    func deps(of hash: String) -> [String]? { document.deps(of: hash) }
    func changeBytes(_ hash: String) -> Data? { document.changeBytes(hash) }
    func save() -> Data { document.save() }

    // MARK: Changing

    /// One change of this Mac's: the splices, in order, and the props given, at `date`. Nil when nothing changed.
    func change(splices: [TextSplice], props: [String: TeamJSON], at date: Date = Date()) throws -> (hash: String, deps: [String], bytes: Data)? {
        let made = try document.change(splices: splices.map(Self.splice), props: props.mapValues(Self.value), at: date)
        return made.map { ($0.hash, $0.deps, $0.bytes) }
    }

    /// Changes from the database (or the outbox), in order. Ones it has change nothing.
    func apply(_ changes: [Data]) throws { try document.apply(changes) }

    /// A change made as if from `heads` (an older version) to `text` and `props`, then applied here: a three-way merge
    /// that keeps everything written since. For a team folder's edits made after a note was brought in. Nil when there was
    /// nothing to change.
    func change(from heads: [String], to text: String, props: [String: TeamJSON], actor: UUID, at date: Date = Date()) throws
        -> (hash: String, deps: [String], bytes: Data)? {
        let base = try self.text(at: heads)
        let baseProps = try self.props(at: heads)
        let splices = TextEdits.splices(from: base, to: text)
        let changed = props.filter { (baseProps[$0.key] ?? .null) != $0.value }
        guard !splices.isEmpty || !changed.isEmpty else { return nil }
        let fork = try document.fork(at: heads, actor: actor)
        guard let made = try fork.change(splices: splices.map(Self.splice), props: changed.mapValues(Self.value), at: date) else { return nil }
        try document.apply([made.bytes])
        return (made.hash, made.deps, made.bytes)
    }

    // MARK: Values

    private static func splice(_ splice: TextSplice) -> NoteDocumentSplice {
        NoteDocumentSplice(start: splice.start, delete: splice.delete, insert: splice.insert)
    }

    private static func json(_ value: NoteDocumentValue) -> TeamJSON {
        switch value {
        case .null: .null
        case .string(let text): .string(text)
        case .bool(let flag): .bool(flag)
        case .number(let number): .number(number)
        }
    }

    private static func value(_ json: TeamJSON) -> NoteDocumentValue {
        switch json {
        case .string(let text): .string(text)
        case .bool(let flag): .bool(flag)
        case .number(let number): .number(number)
        default: .null
        }
    }
}
