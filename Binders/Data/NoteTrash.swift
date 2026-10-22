import Foundation
import Observation
import SwiftData
import BindersKit

/// Deleting a note takes one key, and Undo puts it back as it was, history and all. Notes shared with a team don't
/// come through here: deleting one removes it for everyone, so that still asks first and can't be undone.
@MainActor
@Observable
final class NoteTrash {
    static let shared = NoteTrash()

    /// A deleted note, everything it had.
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let text: String
        let binderID: UUID?
        /// The folder it was in, which Undo puts it back in while that folder is still in its binder.
        let folderID: UUID?
        let createdAt: Date
        let updatedAt: Date
        let digest: String
        let digestHash: String
        let status: String?
        let owner: String?
        let dueAt: Date?
        /// An agent's words in it stay the agent's: Undo doesn't make the note yours.
        let madeBy: String?
        let editedBy: String?
        let editedAt: Date?
        /// Made from what you said, it stays unshared when Undo puts it back.
        let staysUnshared: Bool

        var title: String {
            let firstLine = MarkdownSyntax.plainTitle(text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "")
            return firstLine.isEmpty ? "Untitled note" : String(firstLine.prefix(80))
        }

        init(_ note: NoteItem) {
            id = note.id
            text = note.text
            binderID = note.binderID
            folderID = note.folderID
            createdAt = note.createdAt
            updatedAt = note.updatedAt
            digest = note.digest
            digestHash = note.digestHash
            status = note.status
            owner = note.owner
            dueAt = note.dueAt
            madeBy = note.madeBy
            editedBy = note.editedBy
            editedAt = note.editedAt
            staysUnshared = note.staysUnshared
        }
    }

    /// The notes just deleted together, while their Undo button shows: one, or several deleted at once.
    private(set) var lastDeleted: [Entry] = []
    /// The note just deleted (the last of several), while its Undo button shows.
    var last: Entry? { lastDeleted.last }
    /// The note Undo just put back, for the list to select; `restoredNotes`, all of them when several came back.
    private(set) var restored: UUID?
    private(set) var restoredNotes: Set<UUID> = []
    @ObservationIgnored private var hiding: Task<Void, Never>?

    func delete(_ note: NoteItem, undoManager: UndoManager?) {
        delete([note], undoManager: undoManager)
    }

    /// Several notes at once: one Undo puts them all back.
    func delete(_ notes: [NoteItem], undoManager: UndoManager?) {
        guard !notes.isEmpty else { return }
        MarkdownEditor.flushAll()
        let entries = notes.map(Entry.init)
        for note in notes {
            ScratchpadController.shared.noteWillBeDeleted(note)
            NotePopouts.shared.close(note.id)
        }
        // Let the editor leave the hierarchy before the model is deleted. Its history stays until the app quits, for Undo.
        DispatchQueue.main.async { for note in notes { Store.shared.delete(note, keepingHistory: true) } }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] trash in trash.restore(entries, undoManager: undoManager) }
        undoManager?.setActionName(entries.count == 1 ? "Delete Note" : "Delete Notes")
        lastDeleted = entries
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, self?.lastDeleted == entries else { return }
            self?.lastDeleted = []
        }
    }

    /// Puts a deleted note back, with the same id, so links, history and the board still find it.
    @discardableResult
    func restore(_ entry: Entry, undoManager: UndoManager?) -> NoteItem? {
        restore([entry], undoManager: undoManager).first
    }

    /// Puts deleted notes back, as one change Undo can take away again.
    @discardableResult
    func restore(_ entries: [Entry], undoManager: UndoManager?) -> [NoteItem] {
        if lastDeleted.contains(where: { entry in entries.contains(entry) }) { lastDeleted = [] }
        var back: [NoteItem] = []
        for entry in entries where Store.shared.note(entry.id) == nil {
            let note = NoteItem(text: entry.text)
            note.id = entry.id
            note.binderID = Store.shared.binder(entry.binderID)?.id ?? Store.shared.defaultBinder().id
            note.folderID = Store.shared.shownFolder(entry.folderID, in: note.binderID)
            note.createdAt = entry.createdAt
            note.updatedAt = entry.updatedAt
            note.digest = entry.digest
            note.digestHash = entry.digestHash
            note.status = entry.status
            note.owner = entry.owner
            note.dueAt = entry.dueAt
            note.madeBy = entry.madeBy
            note.editedBy = entry.editedBy
            note.editedAt = entry.editedAt
            note.staysUnshared = entry.staysUnshared
            Store.shared.insert(note)
            back.append(note)
        }
        guard !back.isEmpty else { return [] }
        let ids = back.map(\.id)
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] trash in
            trash.delete(ids.compactMap { Store.shared.note($0) }, undoManager: undoManager)
        }
        undoManager?.setActionName(back.count == 1 ? "Delete Note" : "Delete Notes")
        restoredNotes = Set(ids)
        restored = ids.last
        return back
    }
}
