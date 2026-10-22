import Foundation
import SwiftData
import BindersKit

/// A folder inside a binder: it holds notes, meetings, captures and other folders, as deep as people want. Its sharing
/// is its binder's, and it never leaves its binder. In a shared binder anyone may make, rename, move or delete one, as
/// anyone may edit a note there; team sync keeps everyone's the same (TeamSyncService, `_binders/folders`).
@Model
final class FolderRecord {
    @Attribute(.unique) var id: UUID
    var binderID: UUID
    /// Nil at the top of the binder.
    var parentID: UUID?
    var name: String
    /// Kept for the team database's order; lists go by name.
    var position: Double = 0
    var createdAt: Date
    var updatedAt: Date

    init(name: String, binderID: UUID, parentID: UUID? = nil) {
        self.id = UUID()
        self.name = name
        self.binderID = binderID
        self.parentID = parentID
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var node: FolderNode { FolderNode(id: id, parentID: parentID, name: name, position: position) }
}

/// Why a move or a name was refused, in the words a window, a tool or the phone shows.
enum FolderProblem: LocalizedError, Equatable {
    case intoItself
    case otherBinder
    case noName
    case teammatesMeeting(String)
    case gone

    var errorDescription: String? {
        switch self {
        case .intoItself: "A folder can't go inside itself or one of its own folders."
        case .otherBinder: "A folder stays in its binder. Move what's in it instead."
        case .noName: "A folder needs a name."
        case .teammatesMeeting(let author): "Only \(author) can move this meeting: it's theirs, shared with you."
        case .gone: "That folder isn't there any more."
        }
    }
}

extension Store {
    // MARK: Reading

    /// The folders in a binder, untangled as they're shown (`FolderTree.untangled`): any order.
    func folders(in binderID: UUID?) -> [FolderRecord] {
        guard let binderID else { return [] }
        return (try? context.fetch(FetchDescriptor<FolderRecord>(predicate: #Predicate { $0.binderID == binderID }))) ?? []
    }

    func allFolders() -> [FolderRecord] {
        (try? context.fetch(FetchDescriptor<FolderRecord>())) ?? []
    }

    func meeting(_ id: UUID) -> MeetingRecord? {
        var descriptor = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func folder(_ id: UUID?) -> FolderRecord? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<FolderRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// The folders as nodes for the rules, untangled.
    func folderNodes(in binderID: UUID?) -> [FolderNode] {
        FolderTree.untangled(folders(in: binderID).map(\.node))
    }

    /// The folder an item shows in: its own, when that folder is in its binder; else the top (nil), as for a teammate's
    /// folder that hasn't synced yet.
    func shownFolder(_ id: UUID?, in binderID: UUID?) -> UUID? {
        guard let id, let folder = folder(id), folder.binderID == binderID else { return nil }
        return id
    }

    /// "DevOps/Pipelines"; "" at the top.
    func folderPath(_ id: UUID?) -> String {
        folderNames(id).joined(separator: FolderTree.separator)
    }

    /// The names from the top of its binder down to the folder.
    func folderNames(_ id: UUID?) -> [String] {
        guard let folder = folder(id) else { return [] }
        return FolderTree.chain(to: id, in: FolderTree.index(folderNodes(in: folder.binderID))).map(\.name)
    }

    /// Where a note, meeting or capture is, by its id, for search results: the names from the top of its binder down to
    /// its folder; nil at the top, or for anything else (a dictation, a message).
    func folderNames(ofItem id: UUID) -> [String]? {
        guard let folder = folderOfItem(id) else { return nil }
        let names = folderNames(folder)
        return names.isEmpty ? nil : names
    }

    /// The folder a note, meeting or capture shows in, by the item's id; nil at the top or for anything else.
    func folderOfItem(_ id: UUID) -> UUID? {
        if let note = note(id) { return shownFolder(note.folderID, in: note.binderID) }
        if let meeting = ((try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id }))) ?? []).first {
            return shownFolder(meeting.folderID, in: meeting.binderID)
        }
        return nil
    }

    /// The ids of the notes, meetings and captures in a folder and the folders inside it, as search results name their
    /// source: what searching inside a folder keeps.
    func itemIDs(inFolder id: UUID) -> Set<String> {
        guard let folder = folder(id) else { return [] }
        let binderID = folder.binderID
        let inside = FolderTree.subtree(of: id, in: folderNodes(in: binderID))
        let notes = (try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID }))) ?? []
        let meetings = (try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binderID }))) ?? []
        return Set(notes.filter { $0.folderID.map(inside.contains) == true }.map(\.id.uuidString)
                   + meetings.filter { $0.folderID.map(inside.contains) == true }.map(\.id.uuidString))
    }

    /// What a folder holds directly: notes, meetings, captures and folders.
    func contents(of folder: FolderRecord) -> (notes: Int, meetings: Int, captures: Int, folders: Int) {
        let id = Optional(folder.id)
        let notes = (try? context.fetchCount(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.folderID == id }))) ?? 0
        let kind = MeetingRecord.conversationKind
        let meetings = (try? context.fetchCount(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.folderID == id && $0.kind != kind }))) ?? 0
        let captures = (try? context.fetchCount(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.folderID == id && $0.kind == kind }))) ?? 0
        let folders = (try? context.fetchCount(FetchDescriptor<FolderRecord>(predicate: #Predicate { $0.parentID == id }))) ?? 0
        return (notes, meetings, captures, folders)
    }

    // MARK: Changing

    /// A new folder in `binderID`, inside `parent` (nil: the top). One of that name there already is given back as it is.
    /// Nil for a name that's empty once cleaned, or a parent in another binder.
    @discardableResult
    func createFolder(named name: String, in binderID: UUID, parent: UUID? = nil) -> FolderRecord? {
        guard let name = FolderTree.cleanName(name), canSave else { return nil }
        let parent = parent.flatMap { folder($0)?.binderID == binderID ? $0 : nil }
        if let existing = FolderTree.resolve([name], in: folderNodes(in: binderID), from: parent) { return folder(existing) }
        let folder = FolderRecord(name: name, binderID: binderID, parentID: parent)
        insert(folder)
        return folder
    }

    /// The folder at a path in a binder, from `parent` (nil: the top), made where it's missing ("Marketing/Social posts"
    /// makes both). Nil for the top itself (an empty path).
    @discardableResult
    func ensureFolder(path: [String], in binderID: UUID, from parent: UUID? = nil) -> FolderRecord? {
        let found = FolderTree.resolvePartially(path, in: folderNodes(in: binderID), from: parent)
        var current = found.deepest.flatMap { folder($0) }
        for name in found.missing {
            guard let made = createFolder(named: name, in: binderID, parent: current?.id) else { return current }
            current = made
        }
        return current
    }

    /// True when it was renamed.
    @discardableResult
    func rename(_ folder: FolderRecord, to name: String) -> Bool {
        guard let name = FolderTree.cleanName(name), name != folder.name, canSave else { return false }
        folder.name = name
        folder.updatedAt = Date()
        save()
        return true
    }

    /// Moves a folder into another in its binder, or to the top (nil). Never into itself or one of its own folders.
    func move(_ folder: FolderRecord, into parent: UUID?) throws {
        if let parent {
            guard let target = self.folder(parent) else { throw FolderProblem.gone }
            guard target.binderID == folder.binderID else { throw FolderProblem.otherBinder }
            guard FolderTree.canMove(folder.id, into: parent, in: folderNodes(in: folder.binderID)) else { throw FolderProblem.intoItself }
        }
        guard folder.parentID != parent else { return }
        folder.parentID = parent
        folder.updatedAt = Date()
        save()
    }

    /// Files a note in a folder (nil: the top of its binder). A folder in another binder moves it to that binder too,
    /// which then decides its sharing, as any move to a binder does.
    func move(_ note: NoteItem, toFolder id: UUID?) {
        if let id, let target = folder(id), target.binderID != note.binderID, let binder = binder(target.binderID) {
            move(note, to: binder)
        }
        let shown = shownFolder(id, in: note.binderID)
        guard note.folderID != shown else { return }
        note.folderID = shown
        save()
    }

    /// The same for a meeting or a capture. A teammate's meeting is theirs to move.
    func move(_ meeting: MeetingRecord, toFolder id: UUID?) throws {
        guard !meeting.isTeamCopy else { throw FolderProblem.teammatesMeeting(meeting.teamAuthorName ?? "the person who shared it") }
        if let id, let target = folder(id), target.binderID != meeting.binderID, let binder = binder(target.binderID) {
            move(meeting, to: binder)
        }
        let shown = shownFolder(id, in: meeting.binderID)
        guard meeting.folderID != shown else { return }
        meeting.folderID = shown
        save()
    }

    /// Deletes a folder and moves what it held (notes, meetings, captures and folders) up to where it was; nothing is
    /// deleted with it. What moved, for Undo.
    @discardableResult
    func deleteFolder(_ folder: FolderRecord) -> FolderRemoval {
        let id = Optional(folder.id)
        let binderID = folder.binderID
        let up = shownFolder(folder.parentID, in: binderID)
        let removal = FolderRemoval(id: folder.id, binderID: binderID, parentID: folder.parentID, name: folder.name, position: folder.position,
                                    createdAt: folder.createdAt,
                                    notes: ((try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.folderID == id }))) ?? []).map(\.id),
                                    meetings: ((try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.folderID == id }))) ?? []).map(\.id),
                                    folders: ((try? context.fetch(FetchDescriptor<FolderRecord>(predicate: #Predicate { $0.parentID == id }))) ?? []).map(\.id))
        moveUp(from: folder.id, to: up)
        context.delete(folder)
        save()
        return removal
    }

    /// What a folder held, to wherever it was: what a deleted folder leaves, here or on a teammate's Mac.
    func moveUp(from id: UUID, to parent: UUID?) {
        let gone = Optional(id)
        for note in (try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.folderID == gone }))) ?? [] { note.folderID = parent }
        for meeting in (try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.folderID == gone }))) ?? [] { meeting.folderID = parent }
        for child in (try? context.fetch(FetchDescriptor<FolderRecord>(predicate: #Predicate { $0.parentID == gone }))) ?? [] {
            child.parentID = parent
            child.updatedAt = Date()
        }
    }

    /// Puts a deleted folder back as it was, with what it held then, wherever those are now in its binder.
    func restore(_ removal: FolderRemoval) {
        guard folder(removal.id) == nil, canSave, binder(removal.binderID) != nil else { return }
        let folder = FolderRecord(name: removal.name, binderID: removal.binderID, parentID: shownFolder(removal.parentID, in: removal.binderID))
        folder.id = removal.id
        folder.position = removal.position
        folder.createdAt = removal.createdAt
        context.insert(folder)
        for id in removal.notes { if let note = note(id), note.binderID == removal.binderID { note.folderID = removal.id } }
        for id in removal.meetings {
            if let meeting = ((try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id }))) ?? []).first,
               meeting.binderID == removal.binderID { meeting.folderID = removal.id }
        }
        for id in removal.folders {
            if let child = self.folder(id), child.binderID == removal.binderID {
                child.parentID = removal.id
                child.updatedAt = Date()
            }
        }
        save()
    }
}

/// A deleted folder and what it held, for Undo.
struct FolderRemoval: Equatable {
    let id: UUID
    let binderID: UUID
    let parentID: UUID?
    let name: String
    let position: Double
    let createdAt: Date
    let notes: [UUID]
    let meetings: [UUID]
    let folders: [UUID]

    var isEmpty: Bool { notes.isEmpty && meetings.isEmpty && folders.isEmpty }
}

/// Every folder, read once for a reply (a tool's list, the phone's): where each item is, by its folder id.
@MainActor
struct FolderLookup {
    private let nodes: [UUID: [FolderNode]]
    private let binderOf: [UUID: UUID]

    init(store: Store? = nil) {
        let store = store ?? .shared
        var nodes: [UUID: [FolderNode]] = [:]
        var binderOf: [UUID: UUID] = [:]
        for folder in store.allFolders() {
            nodes[folder.binderID, default: []].append(folder.node)
            binderOf[folder.id] = folder.binderID
        }
        self.nodes = nodes.mapValues(FolderTree.untangled)
        self.binderOf = binderOf
    }

    /// The folder an item in `binderID` shows in: its own when that's in the binder, else the top (nil).
    func shown(_ id: UUID?, in binderID: UUID?) -> UUID? {
        guard let id, let binderID, binderOf[id] == binderID else { return nil }
        return id
    }

    /// "DevOps/Pipelines", "" at the top.
    func path(_ id: UUID?, in binderID: UUID?) -> String {
        names(id, in: binderID).joined(separator: FolderTree.separator)
    }

    /// The names from the top of the binder down to the folder; none at the top.
    func names(_ id: UUID?, in binderID: UUID?) -> [String] {
        guard let shown = shown(id, in: binderID), let binderID else { return [] }
        return FolderTree.chain(to: shown, in: FolderTree.index(nodes[binderID] ?? [])).map(\.name)
    }

    /// `folder` and `folder_id` for a reply: the path and the id, "" at the top.
    func keys(_ id: UUID?, in binderID: UUID?) -> [String: Any] {
        ["folder": path(id, in: binderID), "folder_id": shown(id, in: binderID)?.uuidString ?? ""]
    }

    func folders(in binderID: UUID) -> [FolderNode] { nodes[binderID] ?? [] }
}
