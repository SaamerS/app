import CryptoKit
import Foundation

// MARK: - Exchange format for team spaces

public struct TeamAuthor: Codable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct TeamMember: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var lastSeen: Date
    /// What this member's Binders knows of the team folder's newer ways (TeamFeatures). Nil from a Binders before them,
    /// which writes its file without it.
    public var features: [String]?

    public init(id: String, name: String, lastSeen: Date, features: [String]? = nil) {
        self.id = id
        self.name = name
        self.lastSeen = lastSeen
        self.features = features
    }

    /// Its Binders knows folders: it finds a note by its id wherever its file goes, and keeps a folder's front matter.
    public var knowsFolders: Bool { features?.contains(TeamFeatures.folders) == true }
}

/// What a Binders says it knows of the team folder, in its file in `_binders/members`, so the others hold back what an
/// older one would get wrong.
public enum TeamFeatures {
    /// Notes in folders: their files may move into subfolders of `Notes`.
    public static let folders = "folders"
    /// What this build writes in its member file.
    public static let thisMac = [folders]

    /// Whether note files may move into their folders' subfolders: only once every member's Binders knows folders. A
    /// member file that's there but can't be read yet (`unreadable`) counts as an older one. This Mac (`me`) knows.
    /// A Binders before folders matches a moved note by its id when it sees its file in one place, but one that sees it
    /// in two at once (a drive delivering the move as a copy, then a delete) makes it a second note.
    public static func filesMayMove(members: [TeamMember], unreadable: Int, me: String) -> Bool {
        unreadable == 0 && members.allSatisfy { $0.id == me || $0.knowsFolders }
    }

    /// The teammates whose Binders doesn't know folders yet, by name.
    public static func waitingForFolders(members: [TeamMember], me: String) -> [String] {
        members.filter { $0.id != me && !$0.knowsFolders }.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

public struct TeamManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var name: String
    public var createdAt: Date

    public init(version: Int = 1, name: String, createdAt: Date) {
        self.version = version
        self.name = name
        self.createdAt = createdAt
    }
}

/// A shared meeting, stored as JSON in the team folder (the Markdown next to it is a readable copy).
public struct TeamMeetingFile: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var author: TeamAuthor
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var duration: TimeInterval
    public var appName: String?
    public var attendees: [String]
    public var templateID: String
    public var summary: String
    public var notes: String
    public var speakerNames: [String: String]
    public var segments: [TranscriptSegment]
    /// The binder the author filed it in; absent in files from before binders existed.
    public var binderID: String?
    public var binderName: String?
    /// The folder the author filed it in, in that binder, and its path ("DevOps/Pipelines"); absent at the top, and in
    /// files from before folders, so their hash is as it was.
    public var folderID: String?
    public var folderPath: String?

    public init(version: Int = 1, id: String, author: TeamAuthor, title: String, createdAt: Date, updatedAt: Date,
                duration: TimeInterval, appName: String?, attendees: [String], templateID: String, summary: String, notes: String,
                speakerNames: [String: String], segments: [TranscriptSegment], binderID: String? = nil, binderName: String? = nil,
                folderID: String? = nil, folderPath: String? = nil) {
        self.binderID = binderID
        self.binderName = binderName
        self.folderID = folderID
        self.folderPath = folderPath
        self.version = version
        self.id = id
        self.author = author
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.appName = appName
        self.attendees = attendees
        self.templateID = templateID
        self.summary = summary
        self.notes = notes
        self.speakerNames = speakerNames
        self.segments = segments
    }
}

/// A shared binder's card in the team folder, so teammates see it by name and colour even before its items arrive.
public struct TeamBinderFile: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var name: String
    public var colorIndex: Int
    public var author: TeamAuthor
    public var createdAt: Date
    public var updatedAt: Date

    public init(version: Int = 1, id: String, name: String, colorIndex: Int, author: TeamAuthor, createdAt: Date, updatedAt: Date) {
        self.version = version
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A folder in a shared binder, in the team folder (`_binders/folders/<id>.json`), so everyone's Macs keep the same
/// folders. Anyone in the binder may change it; the change made last wins. Once deleted it stays a while with
/// `deletedAt`, so every Mac learns of it and moves what was in it up to where it was (`parentID`). Binders before
/// folders never read this folder.
public struct TeamFolderFile: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var binderID: String
    /// Nil at the top of the binder.
    public var parentID: String?
    public var name: String
    public var position: Double?
    /// Who changed it last.
    public var editedBy: TeamAuthor
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(version: Int = 1, id: String, binderID: String, parentID: String?, name: String, position: Double? = nil,
                editedBy: TeamAuthor, createdAt: Date, updatedAt: Date, deletedAt: Date? = nil) {
        self.version = version
        self.id = id
        self.binderID = binderID
        self.parentID = parentID
        self.name = name
        self.position = position
        self.editedBy = editedBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// What sync compares: where it is, what it's called, and whether it's gone; not who or when.
    public var syncHash: String {
        TeamFolderFile.syncHash(binderID: binderID, parentID: parentID, name: name, position: position ?? 0, deleted: deletedAt != nil)
    }

    public static func syncHash(binderID: String, parentID: String?, name: String, position: Double, deleted: Bool) -> String {
        TeamFiles.sha256(Data("\(binderID)\u{1}\(parentID ?? "")\u{1}\(name)\u{1}\(position)\u{1}\(deleted ? "deleted" : "")".utf8))
    }
}

public struct TeamTombstone: Codable, Equatable, Sendable {
    public var id: String
    public var deletedBy: TeamAuthor
    public var deletedAt: Date

    public init(id: String, deletedBy: TeamAuthor, deletedAt: Date) {
        self.id = id
        self.deletedBy = deletedBy
        self.deletedAt = deletedAt
    }
}

/// A shared note: a Markdown file whose front matter carries the Binders id, so it can also be edited in Obsidian.
/// What a note says about itself besides its words: where it's at, whose it is, when it's due. In the team folder they're
/// front matter, which Obsidian shows as the note's properties.
public struct NoteProperties: Equatable, Sendable {
    public var status: String?
    public var owner: String?
    /// A day; the time doesn't matter.
    public var due: Date?
    /// Distill is on: the note can be distilled into work items, shows its work's progress and keeps its whole history.
    /// `binders_distill: true` in the Markdown copy. Off for every note until someone turns it on.
    public var distill: Bool

    public init(status: String? = nil, owner: String? = nil, due: Date? = nil, distill: Bool = false) {
        self.status = status.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        self.owner = owner.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        self.due = due
        self.distill = distill
    }

    public var isEmpty: Bool { status == nil && owner == nil && due == nil && !distill }

    /// The front matter line that turns Distill on, written as it is (a YAML boolean, which Obsidian shows as a checkbox).
    public static let distillKey = "binders_distill"
    public static let distillLine = distillKey + ": true"

    /// Whether a front matter value turns Distill on: true, yes or 1, however written.
    public static func distills(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["true", "yes", "1", "on"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The statuses offered; any other word someone writes in the front matter is kept as it is.
    public static let statuses = ["Idea", "Draft", "In progress", "Waiting", "Done"]
}

public struct TeamNote: Equatable, Sendable {
    public var id: String?
    public var author: TeamAuthor?
    public var editedBy: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var body: String
    /// Front matter written by other tools (Obsidian tags, aliases…), kept line for line.
    public var extraFrontmatter: [String]
    public var binderID: String?
    public var binderName: String?
    public var properties: NoteProperties
    /// The folder it's filed in, in its binder (`binders_folder_id`): an id, or "" for the top of the binder once it has
    /// left its folders. Nil when the file says nothing, as files from a Binders before folders, or one such a Binders
    /// wrote again from scratch.
    public var folderID: String?
    /// The folder's path ("DevOps/Pipelines", `binders_folder`), for people and Obsidian; Binders goes by the id.
    public var folderPath: String?

    public init(id: String? = nil, author: TeamAuthor? = nil, editedBy: String? = nil, createdAt: Date? = nil, updatedAt: Date? = nil,
                body: String, extraFrontmatter: [String] = [], binderID: String? = nil, binderName: String? = nil,
                properties: NoteProperties = NoteProperties(), folderID: String? = nil, folderPath: String? = nil) {
        self.properties = properties
        self.binderID = binderID
        self.binderName = binderName
        self.folderID = folderID
        self.folderPath = folderPath
        self.id = id
        self.author = author
        self.editedBy = editedBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.body = body
        self.extraFrontmatter = extraFrontmatter
    }
}

/// Whose words a shared note holds, in its file's front matter, so it travels with the note: the agent that wrote it
/// (`binders_made_by`), and the agent that last changed it and when (`binders_edited_by`, `binders_edited_at`), until
/// someone makes it theirs. On a teammate's Mac it's labelled, Ask leaves it out and a correction in it steers nothing,
/// as on yours. Names are kept exactly as the note has them, so what's written reads back the same and the sync hash
/// agrees on both Macs. A Binders that doesn't know a line keeps it as it is (`extraFrontmatter`), so an older teammate's
/// edit doesn't take the mark off.
public struct TeamNoteMark: Equatable, Sendable {
    public static let madeByKey = "binders_made_by:"
    public static let editedByKey = "binders_edited_by:"
    public static let editedAtKey = "binders_edited_at:"

    public var madeBy: String?
    public var editedBy: String?
    public var editedAt: Date?

    /// An empty name counts as none, and a time goes only with the agent that edited.
    public init(madeBy: String? = nil, editedBy: String? = nil, editedAt: Date? = nil) {
        self.madeBy = madeBy.flatMap { $0.isEmpty ? nil : $0 }
        self.editedBy = editedBy.flatMap { $0.isEmpty ? nil : $0 }
        self.editedAt = self.editedBy == nil ? nil : editedAt
    }

    /// The mark a note file's front matter lines carry; none when they carry nothing, as in files from before edits
    /// were marked.
    public init(lines: [String]) {
        self.init(madeBy: Self.value(Self.madeByKey, in: lines), editedBy: Self.value(Self.editedByKey, in: lines),
                  editedAt: Self.value(Self.editedAtKey, in: lines).flatMap { try? Date($0, strategy: .iso8601) })
    }

    /// No agent's words in it, or someone made it theirs.
    public var isEmpty: Bool { madeBy == nil && editedBy == nil }

    /// Its lines, to go after the note's other front matter; none for a note that's all yours.
    public var lines: [String] {
        var lines: [String] = []
        if let madeBy { lines.append(Self.line(Self.madeByKey, madeBy)) }
        if let editedBy {
            lines.append(Self.line(Self.editedByKey, editedBy))
            if let editedAt { lines.append(Self.line(Self.editedAtKey, editedAt.formatted(.iso8601))) }
        }
        return lines
    }

    /// A note file's other front matter lines, with any mark taken out, to write the note's own in their place.
    public static func removing(from lines: [String]) -> [String] {
        lines.filter { line in ![madeByKey, editedByKey, editedAtKey].contains { line.hasPrefix($0) } }
    }

    /// What it adds to the note's sync hash: nothing for a note that's all yours, and for a note an agent wrote exactly
    /// what was added before edits were marked, so updating makes no note look changed. The time isn't in it: it comes
    /// with an edit, whose words change the hash anyway, and a file keeps it only to the second.
    public var hashSuffix: String {
        (madeBy.map { "\n\u{1}made by \($0)" } ?? "") + (editedBy.map { "\n\u{1}edited by \($0)" } ?? "")
    }

    /// A line's value, unquoted as `line` quotes it; nil when the line is missing or empty.
    static func value(_ key: String, in lines: [String]) -> String? {
        guard let line = lines.first(where: { $0.hasPrefix(key) }) else { return nil }
        var value = String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        return value.isEmpty ? nil : value
    }

    /// `binders_made_by: "Claude Code"`, as Binders has always written it.
    static func line(_ key: String, _ value: String) -> String {
        key + " \"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public enum TeamCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Markdown

public enum Frontmatter {
    /// Values are written as JSON strings (valid YAML), so any text round-trips. `extraLines` are written verbatim.
    public static func render(_ fields: [(String, String)], extraLines: [String] = [], body: String) -> String {
        guard !fields.isEmpty || !extraLines.isEmpty else { return body }
        let lines = fields.map { "\($0.0): \(quoted($0.1))" } + extraLines
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
    }

    /// Top-level fields, each key's raw lines in order (with indented or list continuation lines), and the body.
    public static func parse(_ text: String) -> (fields: [String: String], entries: [(key: String, lines: [String])], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let end = closingLine(normalized) else { return ([:], [], text) }
        let lines = normalized.components(separatedBy: "\n")
        var fields: [String: String] = [:]
        var entries: [(key: String, lines: [String])] = []
        for line in lines[1..<end] {
            let continues = line.isEmpty || line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("-")
            if continues, !entries.isEmpty {
                entries[entries.count - 1].lines.append(line)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                entries.append((key: "", lines: [line]))
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = unquoted(raw) }
            entries.append((key: key, lines: [line]))
        }
        return (fields, entries, lines[(end + 1)...].joined(separator: "\n"))
    }

    /// Sets one top-level field in place, leaving the rest of the file untouched.
    public static func setting(_ key: String, to value: String, in text: String) -> String {
        let line = "\(key): \(quoted(value))"
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let end = closingLine(normalized) else { return "---\n\(line)\n---\n" + text }
        var lines = normalized.components(separatedBy: "\n")
        if let index = lines[1..<end].firstIndex(where: { $0.hasPrefix(key + ":") }) {
            lines[index] = line
        } else {
            lines.insert(line, at: 1)
        }
        return lines.joined(separator: "\n")
    }

    static func closingLine(_ normalized: String) -> Int? {
        guard normalized.hasPrefix("---\n") else { return nil }
        let lines = normalized.components(separatedBy: "\n")
        return lines.indices.dropFirst().first { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }
    }

    static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8) else { return "\"\"" }
        return string
    }

    static func unquoted(_ raw: String) -> String {
        if raw.hasPrefix("\""), let data = raw.data(using: .utf8),
           let string = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
            return string
        }
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }
}

/// Finds the team space near the folder someone picked, as people pick the one next to it as often as the right one: the
/// folder inside it (Notes, Meetings, _binders), or the drive the shared folder sits in.
public enum TeamLocator {
    public enum Result: Equatable {
        case found(URL)
        /// More than one team space in the folder picked; their folders.
        case several([URL])
        /// Only a team space's `_binders` folder, which a drive can sync on its own when that's what was shared; the folder.
        case dataFolderOnly(URL)
        case none
    }

    /// `isTeamSpace` says whether a folder holds `_binders/team.json`, `isDataFolder` whether it holds `team.json` itself,
    /// and `children` lists a folder's subfolders.
    public static func locate(near picked: URL, isTeamSpace: (URL) -> Bool, isDataFolder: (URL) -> Bool = { _ in false },
                              children: (URL) -> [URL]) -> Result {
        let picked = picked.standardizedFileURL
        if isTeamSpace(picked) { return .found(picked) }
        // Something inside a team space: _binders, Notes, Meetings, or a folder in one of those.
        var ancestor = picked
        for _ in 0..<2 {
            ancestor = ancestor.deletingLastPathComponent()
            if ancestor.pathComponents.count > 1, isTeamSpace(ancestor) { return .found(URL(fileURLWithPath: ancestor.path)) }
        }
        // The folder a shared team space sits in, such as the top of your OneDrive.
        let subfolders = children(picked)
        let inside = subfolders.filter(isTeamSpace).sorted { $0.path < $1.path }
        switch inside.count {
        case 1: return .found(inside[0])
        case 2...: return .several(inside)
        default:
            if isDataFolder(picked) { return .dataFolderOnly(picked) }
            return subfolders.first(where: isDataFolder).map { .dataFolderOnly($0) } ?? .none
        }
    }

    /// The top of a cloud drive (a folder directly in ~/Library/CloudStorage), which can't be shared as a whole.
    public static func isDriveRoot(_ folder: URL, home: URL) -> Bool {
        folder.standardizedFileURL.deletingLastPathComponent().path == home.appendingPathComponent("Library/CloudStorage").standardizedFileURL.path
    }
}

public enum TeamFiles {
    public static let dataFolder = "_binders"
    public static let meetingsFolder = "Meetings"
    public static let notesFolder = "Notes"

    /// A filename safe on every sync service: "2026-09-13 Launch plan.md".
    public static func safeFileName(_ title: String, date: Date? = nil) -> String {
        var name = title.replacingOccurrences(of: "[/\\\\:*?\"<>|\\n\\r\\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        if name.isEmpty { name = "Untitled" }
        name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
        if let date { name = dayString(date) + " " + name }
        return name + ".md"
    }

    public static func noteMarkdown(_ note: TeamNote) -> String {
        var fields: [(String, String)] = []
        if let id = note.id { fields.append(("binders_id", id)) }
        if let author = note.author {
            fields.append(("author", author.name))
            fields.append(("author_id", author.id))
        }
        if let editedBy = note.editedBy { fields.append(("edited_by", editedBy)) }
        if let binderID = note.binderID { fields.append(("binder_id", binderID)) }
        if let binderName = note.binderName { fields.append(("binder", binderName)) }
        if let folderID = note.folderID { fields.append((folderIDKey, folderID)) }
        if let folderPath = note.folderPath, !folderPath.isEmpty, note.folderID?.isEmpty == false { fields.append((folderPathKey, folderPath)) }
        if let status = note.properties.status { fields.append(("status", status)) }
        if let owner = note.properties.owner { fields.append(("owner", owner)) }
        if let due = note.properties.due { fields.append(("due", dayString(due))) }
        if let createdAt = note.createdAt { fields.append(("created", createdAt.formatted(.iso8601))) }
        if let updatedAt = note.updatedAt { fields.append(("updated", updatedAt.formatted(.iso8601))) }
        // Distill, as a YAML boolean rather than a quoted string, and only when it's on.
        let distill = note.properties.distill ? [NoteProperties.distillLine] : []
        return Frontmatter.render(fields, extraLines: distill + note.extraFrontmatter, body: note.body)
    }

    /// The folder a note is in, in its front matter: its id, and its path for whoever reads the file.
    public static let folderIDKey = "binders_folder_id"
    public static let folderPathKey = "binders_folder"

    static let noteFields: Set<String> = ["binders_id", "author", "author_id", "edited_by", "created", "updated", "binder_id", "binder",
                                          "status", "owner", "due", folderIDKey, folderPathKey, NoteProperties.distillKey]

    public static func parseNote(_ text: String) -> TeamNote {
        let parsed = Frontmatter.parse(text)
        let fields = parsed.fields
        let author = fields["author"].map { TeamAuthor(id: fields["author_id"] ?? "", name: $0) }
        return TeamNote(id: fields["binders_id"].flatMap { $0.isEmpty ? nil : $0 }, author: author, editedBy: fields["edited_by"],
                        createdAt: fields["created"].flatMap { try? Date($0, strategy: .iso8601) },
                        updatedAt: fields["updated"].flatMap { try? Date($0, strategy: .iso8601) },
                        body: String(parsed.body.drop(while: { $0.isNewline })),
                        extraFrontmatter: parsed.entries.filter { !noteFields.contains($0.key) }.flatMap(\.lines),
                        binderID: fields["binder_id"].flatMap { $0.isEmpty ? nil : $0 }, binderName: fields["binder"],
                        properties: NoteProperties(status: fields["status"], owner: fields["owner"], due: fields["due"].flatMap(day(from:)),
                                                   distill: NoteProperties.distills(fields[NoteProperties.distillKey])),
                        folderID: fields[folderIDKey].map { $0.trimmingCharacters(in: .whitespaces) },
                        folderPath: fields[folderPathKey].flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: Folders in the team copy

    /// A folder's name as a folder on disk, safe on every sync service and in Obsidian: no `/\:*?"<>|`, no dot in front
    /// (which would hide it, and every note in it, from the scan) or at the end, not a name Binders or Windows keeps for
    /// itself, at most 60 characters.
    public static func safeFolderName(_ name: String) -> String {
        var safe = name.replacingOccurrences(of: "[/\\\\:*?\"<>|\\n\\r\\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        safe = String(safe.prefix(60)).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        if safe.isEmpty { return "Folder" }
        let reserved: Set<String> = [MarkdownMedia.folder, dataFolder, "con", "prn", "aux", "nul"]
        let lower = safe.lowercased()
        if reserved.contains(lower) || lower.range(of: #"^(com|lpt)[0-9]$"#, options: .regularExpression) != nil { safe += " folder" }
        return safe
    }

    /// Where a note in a folder goes in the team folder: "Notes/DevOps/Pipelines"; "Notes" at the top.
    public static func notesDirectory(_ folderPath: [String]) -> String {
        ([notesFolder] + folderPath.map(safeFolderName)).joined(separator: "/")
    }

    /// The same for a meeting's readable copy: "Meetings/DevOps".
    public static func meetingsDirectory(_ folderPath: [String]) -> String {
        ([meetingsFolder] + folderPath.map(safeFolderName)).joined(separator: "/")
    }

    /// "2026-10-02", as a date at the start of that day here.
    static func day(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.trimmingCharacters(in: .whitespaces).prefix(10)))
    }

    /// The id for a note file added outside Binders (e.g. in Obsidian), derived from its path so every Mac picks the same one.
    public static func stableID(forPath path: String) -> String {
        let digest = Array(SHA256.hash(data: Data(("binders-note:" + path.precomposedStringWithCanonicalMapping).utf8)))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString
    }

    public static func meetingMarkdown(_ meeting: TeamMeetingFile) -> String {
        let fields: [(String, String)] = [
            ("binders_id", meeting.id),
            ("type", "meeting"),
            ("author", meeting.author.name),
            ("date", meeting.createdAt.formatted(.iso8601)),
            ("duration_minutes", "\(max(1, Int((meeting.duration / 60).rounded())))"),
            ("attendees", meeting.attendees.joined(separator: ", ")),
            ("note", "Shared from Binders. Edit this meeting in Binders; changes made here are overwritten."),
        ]
        let body = MeetingMarkdown.document(title: meeting.title, dateText: meeting.createdAt.formatted(date: .abbreviated, time: .shortened),
                                            duration: meeting.duration, appName: meeting.appName, attendees: meeting.attendees,
                                            summary: meeting.summary, notes: meeting.notes, segments: meeting.segments,
                                            names: meeting.speakerNames.merging([TranscriptSegment.you: meeting.author.name]) { current, _ in current })
        return Frontmatter.render(fields, body: body)
    }

    /// Content hash that ignores when the file was written and the order segments arrive in.
    public static func contentHash(_ meeting: TeamMeetingFile) -> String {
        var copy = meeting
        copy.updatedAt = Date(timeIntervalSince1970: 0)
        copy.segments.sort { ($0.start, $0.channel.rawValue, $0.id.uuidString) < ($1.start, $1.channel.rawValue, $1.id.uuidString) }
        return sha256((try? TeamCoding.encoder().encode(copy)) ?? Data())
    }

    /// What a note's sync state compares. A note without properties hashes exactly as before they existed, so adding them
    /// never makes every shared note look changed at once.
    public static func noteHash(_ body: String, _ properties: NoteProperties = NoteProperties()) -> String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !properties.isEmpty else { return sha256(Data(text.utf8)) }
        // Distill joins only when it's on, so every note without it hashes as before.
        let extra = "status=\(properties.status ?? "");owner=\(properties.owner ?? "");due=\(properties.due.map(dayString) ?? "")"
            + (properties.distill ? ";distill=1" : "")
        return sha256(Data((text + "\n\u{1}" + extra).utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Sync decisions

public enum SyncDecision: Equatable, Sendable {
    case upToDate, pushLocal, pullRemote, conflict

    /// Three-way comparison against the version both sides last agreed on.
    public static func decide(local: String?, remote: String?, lastSynced: String?) -> SyncDecision {
        switch (local, remote) {
        case (nil, nil): return .upToDate
        case (nil, _): return .pullRemote
        case (_, nil): return .pushLocal
        case let (local?, remote?):
            if local == remote { return .upToDate }
            if lastSynced == local { return .pullRemote }
            if lastSynced == remote { return .pushLocal }
            return .conflict
        }
    }
}
