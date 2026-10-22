import AppKit
import Foundation
import BindersKit

/// Note templates: the ones Binders comes with, and your own, kept as Markdown files in Templates, next to the database.
/// One of yours with the same name as a built-in one takes its place. One of yours can name a folder in its front matter
/// (`folder: Social posts`): notes made from it are filed there, and the folder is made if it's missing.
@MainActor
enum TemplateStore {
    static var folder: URL { AppPaths.support.appendingPathComponent("Templates", isDirectory: true) }

    static var all: [NoteTemplate] {
        let yours = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            // Front matter naming a folder files its notes there, and binders_distill: true turns Distill on for them.
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { NoteTemplate.parse(name: url.deletingPathExtension().lastPathComponent, file: $0) } }
        let names = Set(yours.map { $0.name.lowercased() })
        return NoteTemplate.builtIn.filter { !names.contains($0.name.lowercased()) } + yours
    }

    /// Keeps a note as a template, named after its title, filing its notes in `folder` (a path from the top of the
    /// binder) when given. Returns the file.
    @discardableResult
    static func save(_ note: NoteItem, folder notesFolder: String? = nil) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(TeamFiles.safeFileName(note.title))
        do {
            try NoteTemplate(name: note.title, body: note.text, folder: notesFolder, distill: note.distill).fileText.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    static func showFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// A new note in `binder`, from a template or blank: in the folder its template names (made if it's missing), else in
    /// `folder` (nil: the top of the binder).
    static func newNote(from template: NoteTemplate?, in binder: BinderRecord, folder: UUID? = nil) -> NoteItem {
        let note = NoteItem(text: template?.filled(date: Date(), binder: binder.name) ?? "")
        note.binderID = binder.id
        note.sharedWithTeam = binder.sharedWithTeam
        if let path = template?.folder {
            note.folderID = Store.shared.ensureFolder(path: FolderTree.components(path), in: binder.id)?.id
        } else {
            note.folderID = Store.shared.shownFolder(folder, in: binder.id)
        }
        // A Spec template, or one of yours that says so, starts a note with Distill on.
        note.distill = template?.distill ?? false
        Store.shared.insert(note)
        return note
    }
}
