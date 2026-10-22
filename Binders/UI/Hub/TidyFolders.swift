import AppKit
import SwiftData
import SwiftUI
import BindersKit

/// Tidy into Folders: a folder for each prefix the titles at the top of a binder share ("DevOps | …"), its notes moved
/// in and the prefix taken off their titles through the rename path, so every [[link]] follows. Nothing changes until
/// Apply, and one Undo puts it all back.
@MainActor
enum FolderTidyRun {
    /// What Tidy offers in a binder: its proposals, from the notes at its top, newest first so a tie in spelling goes to
    /// the newest.
    static func proposals(in binderID: UUID) -> [FolderTidy.Proposal] {
        let store = Store.shared
        let known = Set(store.folders(in: binderID).map(\.id))
        let notes = ((try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID },
                                                                          sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? [])
            .filter { note in note.folderID.map { !known.contains($0) } ?? true }
        return FolderTidy.proposals(for: notes.map { FolderTidy.Note(id: $0.id, title: $0.title) }, existing: store.folderNodes(in: binderID))
    }

    /// Titles a new one mustn't take, by WikiLinks.key, as links go by title: every note's but the ones being renamed,
    /// every meeting's and every binder's.
    static func takenTitles(besides renamed: Set<UUID>) -> Set<String> {
        let store = Store.shared
        let notes = ((try? store.context.fetch(FetchDescriptor<NoteItem>())) ?? []).filter { !renamed.contains($0.id) }.map(\.title)
        var meetingTitles = FetchDescriptor<MeetingRecord>()
        meetingTitles.propertiesToFetch = [\.title]
        let meetings = ((try? store.context.fetch(meetingTitles)) ?? []).map(\.title)
        return Set((notes + meetings + store.binders(includeArchived: true).map(\.name)).map(WikiLinks.key))
    }

    /// What one Apply did, to put back.
    struct Change {
        /// A title taken off (the note's text before and after), or the links a new title took with it.
        enum Step {
            case title(note: UUID, before: String, after: String)
            case links(LinkRename)
        }

        var madeFolders: [UUID] = []
        /// Each note moved, and the folder it was in.
        var moves: [(note: UUID, from: UUID?)] = []
        /// Titles and links, in the order they changed: a note's new title can change the links in a note retitled after
        /// it, so they're put back in exactly the reverse order.
        var steps: [Step] = []

        /// How many titles changed.
        var titles: Int { steps.filter { if case .title = $0 { true } else { false } }.count }
    }

    /// Makes the ticked folders, moves the ticked notes into them and takes the prefix off each title but those in
    /// `keeping` (whose new title another note has), with links following. Undo on `undoManager` puts it all back.
    @discardableResult
    static func apply(_ proposals: [FolderTidy.Proposal], in binderID: UUID, keeping: Set<UUID>, undoManager: UndoManager?) -> Change? {
        let store = Store.shared
        guard store.canSave, !proposals.isEmpty else { return nil }
        MarkdownEditor.flushAll()
        var change = Change()
        for proposal in proposals where !proposal.items.isEmpty {
            let folder: FolderRecord
            if let existing = proposal.existingFolder.flatMap({ store.folder($0) }), existing.binderID == binderID {
                folder = existing
            } else if let found = FolderTree.resolve([proposal.folderName], in: store.folderNodes(in: binderID)).flatMap({ store.folder($0) }) {
                folder = found
            } else {
                guard let made = store.createFolder(named: proposal.folderName, in: binderID) else { continue }
                change.madeFolders.append(made.id)
                folder = made
            }
            for item in proposal.items {
                guard let note = store.note(item.id), note.binderID == binderID else { continue }
                change.moves.append((note.id, note.folderID))
                note.folderID = folder.id
                guard !keeping.contains(note.id), let retitled = FolderTidy.removingPrefix(from: note.text) else { continue }
                let old = note.title
                change.steps.append(.title(note: note.id, before: note.text, after: retitled))
                NoteHistory.willChange(note, to: retitled, always: true)
                note.text = retitled
                // The same path a new title typed in the note takes: every link to it follows.
                if let rename = LinkTargets.renameLinks(from: old, to: note.title), !rename.changes.isEmpty { change.steps.append(.links(rename)) }
            }
        }
        store.save()
        registerUndo(of: change, proposals: proposals, binderID: binderID, keeping: keeping, undoManager: undoManager)
        HubWindowController.shared.controller?.team.scheduleSync(after: 0.5)
        return change
    }

    /// Puts back what an Apply did: the titles and links, in exactly the reverse order, then where each note was, then the
    /// folders it made, if nothing else went into them since. Text changed since is left as it is.
    static func undo(_ change: Change) {
        let store = Store.shared
        MarkdownEditor.flushAll()
        for step in change.steps.reversed() {
            switch step {
            case .links(let rename):
                LinkTargets.undo(rename)
            case .title(let id, let before, let after):
                guard let note = store.note(id), note.text == after else { continue }
                NoteHistory.willChange(note, to: before, always: true)
                note.text = before
            }
        }
        for move in change.moves.reversed() { store.note(move.note)?.folderID = move.from }
        for id in change.madeFolders.reversed() {
            guard let folder = store.folder(id) else { continue }
            let held = store.contents(of: folder)
            if held.notes + held.meetings + held.captures + held.folders == 0 { store.context.delete(folder) }
        }
        store.save()
        HubWindowController.shared.controller?.team.scheduleSync(after: 0.5)
    }

    private static func registerUndo(of change: Change, proposals: [FolderTidy.Proposal], binderID: UUID, keeping: Set<UUID>, undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: Store.shared) { [weak undoManager] _ in
            undo(change)
            // Redo tidies again, as it was asked.
            undoManager?.registerUndo(withTarget: Store.shared) { [weak undoManager] _ in
                apply(proposals, in: binderID, keeping: keeping, undoManager: undoManager)
            }
            undoManager?.setActionName("Tidy into Folders")
        }
        undoManager.setActionName("Tidy into Folders")
    }

    /// "Moved 5 notes into 2 folders. 1 kept its title, as another note has that title."
    static func summary(of change: Change, keeping: Int) -> String {
        let moved = change.moves.count
        let into = Set(change.moves.compactMap { Store.shared.note($0.note)?.folderID }).count
        var line = "Moved \(moved) \(moved == 1 ? "note" : "notes") into \(into) \(into == 1 ? "folder" : "folders")."
        if keeping == 1 { line += " 1 kept its title, as another note has that title." }
        if keeping > 1 { line += " \(keeping) kept their titles, as other notes have them." }
        return line
    }
}

/// The sheet: one proposed folder per prefix, with its notes, all ticked. Untick a folder or a note to leave it be.
struct TidyFoldersSheet: View {
    let binder: BinderRecord
    var undoManager: UndoManager?
    /// Told what was done, for the page to say with Undo.
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var proposals: [FolderTidy.Proposal] = []
    @State private var leftOutFolders: Set<String> = []
    @State private var leftOutNotes: Set<UUID> = []
    @State private var loaded = false

    /// What Apply would do: the ticked folders, each with its ticked notes.
    private var chosen: [FolderTidy.Proposal] {
        proposals.filter { !leftOutFolders.contains($0.key) }.compactMap { proposal in
            let items = proposal.items.filter { !leftOutNotes.contains($0.id) }
            return items.isEmpty ? nil : FolderTidy.Proposal(key: proposal.key, folderName: proposal.folderName,
                                                             existingFolder: proposal.existingFolder, items: items)
        }
    }

    /// The ticked notes that keep their titles, as another note has the new one (or two would share it).
    private var keeping: Set<UUID> {
        let items = chosen.flatMap(\.items)
        return FolderTidy.keepingTitles(items, taken: FolderTidyRun.takenTitles(besides: Set(items.map(\.id))))
    }

    var body: some View {
        let keeping = keeping
        let chosen = chosen
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tidy “\(binder.name)” into Folders").font(BindersTheme.cardTitle)
                Text("Notes at the top of the binder whose titles start with the same words before |, · or - go into a folder of that name, and the words come off their titles. Links to them follow. Nothing changes until you choose Apply, and Undo puts it all back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loaded, proposals.isEmpty {
                ContentUnavailableView("Nothing to tidy", systemImage: "folder",
                                       description: Text("No two notes at the top of \(binder.name) start with the same words before |, · or -."))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List {
                    ForEach(proposals) { proposal in
                        Section {
                            ForEach(proposal.items) { item in
                                Toggle(isOn: noteBinding(item.id)) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).lineLimit(1)
                                        if keeping.contains(item.id) {
                                            Text("Keeps its title: another note is called “\(item.newTitle)”")
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        } else {
                                            Text("becomes “\(item.newTitle)”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .disabled(leftOutFolders.contains(proposal.key))
                                .padding(.leading, 18)
                            }
                        } header: {
                            Toggle(isOn: folderBinding(proposal.key)) {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder")
                                    Text(proposal.folderName).font(.body.weight(.semibold))
                                    Text(proposal.existingFolder == nil ? "new folder" : "folder already there")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(minHeight: 260)
            }
            HStack {
                let notes = chosen.reduce(0) { $0 + $1.items.count }
                let folders = chosen.count
                Text(notes == 0 ? "Nothing ticked" : "\(folders) \(folders == 1 ? "folder" : "folders") · \(notes) \(notes == 1 ? "note" : "notes")")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if let change = FolderTidyRun.apply(chosen, in: binder.id, keeping: keeping, undoManager: undoManager) {
                        done(FolderTidyRun.summary(of: change, keeping: change.moves.count - change.titles))
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(notes == 0)
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 380)
        .pageGround()
        .onAppear {
            proposals = FolderTidyRun.proposals(in: binder.id)
            loaded = true
        }
    }

    private func folderBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { !leftOutFolders.contains(key) }, set: { ticked in
            if ticked { leftOutFolders.remove(key) } else { leftOutFolders.insert(key) }
        })
    }

    private func noteBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { !leftOutNotes.contains(id) }, set: { ticked in
            if ticked { leftOutNotes.remove(id) } else { leftOutNotes.insert(id) }
        })
    }
}
