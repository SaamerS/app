import AppKit
import SwiftData
import SwiftUI
import BindersKit

/// What [[links]] point to, and going there: notes, meetings and binders by title, and the knowledge graph's people,
/// projects and topics by name. A link to nothing yet makes a note of that name.
@MainActor
enum LinkTargets {
    enum Target {
        case note(NoteItem), meeting(MeetingRecord), binder(BinderRecord), entity(Int64)
    }

    /// The graph's names, read now and then so linking never waits on the index.
    private static var entities: [(id: Int64, name: String)] = []
    private static var entitiesRead = Date.distantPast
    /// Every title's key, for fading links to nothing; built at most every couple of seconds, as it's asked per link.
    private static var keys: Set<String> = []
    private static var keysBuilt = Date.distantPast
    /// Every note's and meeting's title, newest first: read when first asked for, and again only after a save that could
    /// change one (a card moving can't), so typing after "[[" doesn't read the whole library at each letter.
    private static var titles: [String]?
    private static var watching: NSObjectProtocol?

    private static var allTitles: [String] {
        if watching == nil {
            watching = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { notification in
                guard !TaskCard.onlyBoards(notification.userInfo) else { return }
                MainActor.assumeIsolated {
                    titles = nil
                    keysBuilt = .distantPast
                }
            }
        }
        if let titles { return titles }
        var meetingTitles = FetchDescriptor<MeetingRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        meetingTitles.propertiesToFetch = [\.title]
        let read = notes.map(\.title) + ((try? Store.shared.context.fetch(meetingTitles)) ?? []).map(\.title)
        titles = read
        return read
    }

    static func refreshEntities(_ knowledge: KnowledgeService) async {
        guard Date().timeIntervalSince(entitiesRead) > 30 else { return }
        entitiesRead = Date()
        entities = await knowledge.store.entities(limit: 2000).map { ($0.id, $0.name) }
        keysBuilt = .distantPast
    }

    private static var notes: [NoteItem] {
        (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
    }

    private static var meetings: [MeetingRecord] {
        (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
    }

    /// What a link's target is: a note, meeting, binder or person by its whole name, or else by the page before a
    /// "#Heading" ("Launch plan#Risks" is the note "Launch plan").
    static func resolve(_ title: String) -> Target? {
        if let whole = find(title) { return whole }
        let page = WikiTarget(title).page
        return page.isEmpty || WikiLinks.key(page) == WikiLinks.key(title) ? nil : find(page)
    }

    private static func find(_ title: String) -> Target? {
        let key = WikiLinks.key(title)
        guard !key.isEmpty else { return nil }
        if let note = notes.first(where: { WikiLinks.key($0.title) == key }) { return .note(note) }
        if let meeting = meetings.first(where: { WikiLinks.key($0.title) == key }) { return .meeting(meeting) }
        if let binder = Store.shared.binders(includeArchived: true).first(where: { WikiLinks.key($0.name) == key }) { return .binder(binder) }
        return entities.first { WikiLinks.key($0.name) == key }.map { .entity($0.id) }
    }

    static func exists(_ title: String) -> Bool {
        if Date().timeIntervalSince(keysBuilt) > 2 {
            keysBuilt = Date()
            keys = Set(allTitles.map { WikiLinks.key($0) }
                       + Store.shared.binders(includeArchived: true).map { WikiLinks.key($0.name) } + entities.map { WikiLinks.key($0.name) })
        }
        if keys.contains(WikiLinks.key(title)) { return true }
        let destination = WikiTarget(title)
        // A heading in the same note is the editor's to find.
        if destination.page.isEmpty { return true }
        if keys.contains(WikiLinks.key(destination.page)) { return true }
        return destination.isFile && attachment(destination.page) != nil
    }

    /// The file a link names, when it's in the attachments folder.
    private static func attachment(_ name: String) -> URL? {
        guard let url = Attachments.url(for: name), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Titles to offer after "[[", best first: the most recent notes and meetings when nothing's typed yet.
    static func suggestions(for typed: String) -> [String] {
        var seen = Set<String>()
        let titles = (allTitles + Store.shared.binders().map(\.name) + entities.map(\.name))
            .filter { $0 != "Untitled note" && seen.insert(WikiLinks.key($0)).inserted }
        let typed = typed.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return Array(titles.prefix(12)) }
        return titles.compactMap { title in FuzzyMatch.score(typed, in: title).map { (title, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(12)
            .map(\.0)
    }

    /// Opens what a link points to, in the Binders window, at the heading or block it names. A link to a file opens the
    /// file. A link to nothing yet makes a note of that name in `binderID`. `navigation` is the window's unless given.
    static func open(_ title: String, from binderID: UUID?, in given: HubNavigation? = nil) {
        let destination = WikiTarget(title)
        let whole = find(title)
        // A place in the same note is the editor's to go to.
        guard whole != nil || !destination.page.isEmpty else { return }
        if whole == nil, resolve(title) == nil, destination.isFile || attachment(destination.page) != nil {
            if let file = attachment(destination.page) { NSWorkspace.shared.open(file) } else { NSSound.beep() }
            return
        }
        let place = whole == nil ? destination.place : nil
        let navigation: HubNavigation
        if let given {
            navigation = given
        } else {
            HubWindowController.shared.show()
            navigation = HubWindowController.shared.navigation
        }
        func show(binder id: UUID?, tab: BinderTab, then: (HubNavigation) -> Void = { _ in }) {
            navigation.binderID = id ?? Store.shared.defaultBinder().id
            navigation.pendingBinderTab = tab
            then(navigation)
            navigation.selection = .binder
        }
        switch whole ?? resolve(title) {
        case .note(let note):
            show(binder: note.binderID, tab: .notes) {
                $0.pendingNoteID = note.id
                $0.pendingNotePlace = place
            }
        case .meeting(let meeting): show(binder: meeting.binderID, tab: .listing(meeting)) { $0.pendingMeetingID = meeting.id }
        case .binder(let binder): show(binder: binder.id, tab: .overview)
        case .entity(let id):
            navigation.pendingEntityID = id
            navigation.selection = .knowledge
        case nil:
            guard Store.shared.allowsSave() else { return }
            let binder = Store.shared.binder(binderID) ?? Store.shared.defaultBinder()
            let note = NoteItem(text: "# \(destination.page)\n\n")
            note.binderID = binder.id
            note.sharedWithTeam = binder.sharedWithTeam
            Store.shared.insert(note)
            keysBuilt = .distantPast
            titles = nil
            show(binder: binder.id, tab: .notes) { $0.pendingNoteID = note.id }
        }
    }

    /// Everything a note editor in `binderID` needs for its links.
    static func forEditor(in binderID: UUID?) -> NoteLinks {
        NoteLinks(suggestions: { suggestions(for: $0) }, exists: { exists($0) }, open: { open($0, from: binderID) })
    }

    /// The same for the editor of a note, whose first line is its title: a new title renames the links to it.
    /// `renamed` hears how many changed.
    static func forNote(_ note: NoteItem, renamed: ((LinkRename) -> Void)? = nil) -> NoteLinks {
        var links = forEditor(in: note.binderID)
        let id = note.id
        links.rename = { old, new, itself in
            let rename = renameNote(id, from: old, to: new, itself: itself)
            if let rename, rename.links > 0 { renamed?(rename) }
            return rename
        }
        return links
    }

    // MARK: Renaming

    /// Points the links to a note that was `old` and is now `new` at its new title, everywhere else; with `itself`, in
    /// the note too, which its open editor otherwise does. Nil when the note isn't called `new` (it has gone, say).
    @discardableResult
    static func renameNote(_ id: UUID, from old: String, to new: String, itself: Bool) -> LinkRename? {
        guard let note = Store.shared.note(id), WikiLinks.key(note.title) == WikiLinks.key(new) else { return nil }
        return renameLinks(from: old, to: new, except: itself ? nil : id)
    }

    /// Points every link to `old`, something just renamed, at `new`: in notes, in your meetings' notes and summaries,
    /// and on cards. Nothing changes while something else still goes by `old`, as the links may be to that. Nil when
    /// nothing should change; otherwise what did, which `undo(_:)` puts back.
    @discardableResult
    static func renameLinks(from old: String, to new: String, except: UUID? = nil) -> LinkRename? {
        let old = old.trimmingCharacters(in: .whitespaces), new = new.trimmingCharacters(in: .whitespaces)
        guard WikiLinks.key(old) != WikiLinks.key(new), WikiLinks.canLink(old), WikiLinks.canLink(new),
              ![old, new].contains("Untitled note") else { return nil }
        keysBuilt = .distantPast
        titles = nil
        guard find(old) == nil else { return nil }
        // Typing not yet handed to its note would be lost when the note changes under it.
        MarkdownEditor.flushAll()
        var rename = LinkRename(old: old, new: new)
        func rewrite(_ kind: LinkRename.Kind, _ id: UUID, _ text: String, _ set: (String) -> Void) {
            guard let renamed = WikiLinks.renaming(from: old, to: new, in: text) else { return }
            rename.changes.append(.init(kind: kind, id: id, before: text, after: renamed.text))
            rename.links += renamed.links
            set(renamed.text)
        }
        for note in notes where note.id != except {
            rewrite(.note, note.id, note.text) { text in
                NoteHistory.willChange(note, to: text, always: true)
                note.text = text
            }
        }
        for meeting in meetings where !meeting.isTeamCopy {
            rewrite(.meetingNotes, meeting.id, meeting.userNotes) { meeting.userNotes = $0 }
            rewrite(.meetingSummary, meeting.id, meeting.summary) { meeting.summary = $0 }
        }
        for card in (try? Store.shared.context.fetch(FetchDescriptor<TaskCard>())) ?? [] {
            rewrite(.card, card.id, card.details) { card.details = $0 }
        }
        if !rename.changes.isEmpty { Store.shared.save() }
        return rename
    }

    /// Takes a rename's links back to the old name, or with `redo` to the new one again. Text changed since is left as it is.
    static func undo(_ rename: LinkRename, redo: Bool = false) {
        MarkdownEditor.flushAll()
        let context = Store.shared.context
        for change in rename.changes {
            let (from, to) = redo ? (change.before, change.after) : (change.after, change.before)
            let id = change.id
            switch change.kind {
            case .note:
                guard let note = Store.shared.note(id), note.text == from else { continue }
                note.text = to
            case .meetingNotes, .meetingSummary:
                guard let meeting = try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id })).first else { continue }
                if change.kind == .meetingNotes, meeting.userNotes == from { meeting.userNotes = to }
                if change.kind == .meetingSummary, meeting.summary == from { meeting.summary = to }
            case .card:
                guard let card = try? context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.id == id })).first, card.details == from else { continue }
                card.details = to
            }
        }
        keysBuilt = .distantPast
        titles = nil
        Store.shared.save()
    }
}

/// The links a rename pointed at the new name, to say how many and to undo.
struct LinkRename {
    enum Kind { case note, meetingNotes, meetingSummary, card }

    struct Change {
        let kind: Kind
        let id: UUID
        let before: String
        let after: String
    }

    let old: String
    let new: String
    var changes: [Change] = []
    var links = 0

    /// "Updated 3 links in 2 notes and 1 meeting".
    var summary: String { "Updated " + counted }

    /// "3 links in 2 notes and 1 meeting".
    var counted: String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        let notes = Set(changes.filter { $0.kind == .note }.map(\.id)).count
        let meetings = Set(changes.filter { $0.kind == .meetingNotes || $0.kind == .meetingSummary }.map(\.id)).count
        let cards = Set(changes.filter { $0.kind == .card }.map(\.id)).count
        let places = [notes > 0 ? count(notes, "note", "notes") : nil, meetings > 0 ? count(meetings, "meeting", "meetings") : nil,
                      cards > 0 ? count(cards, "card", "cards") : nil].compactMap { $0 }
        let listed = places.count > 1 ? places.dropLast().joined(separator: ", ") + " and " + places.last! : places.first ?? "this note"
        return "\(count(links, "link", "links")) in \(listed)"
    }
}

/// A name typed into a field renames the links to it once the field is done with: on Return, or when it loses focus.
private struct RenamesLinks: ViewModifier {
    let name: String
    @FocusState private var focused: Bool
    @State private var before: String?

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { _, focused in
                if focused { before = name } else { commit() }
            }
            .onSubmit(commit)
    }

    private func commit() {
        if let before { LinkTargets.renameLinks(from: before, to: name) }
        before = focused ? name : nil
    }
}

extension View {
    /// Renaming what this field names (a meeting's title, say) renames the links to it.
    func renamesLinks(of name: String) -> some View { modifier(RenamesLinks(name: name)) }
}

/// Where a title is linked or named in each note and meeting, looked for again only when the text or the title changes:
/// the panel redraws whenever any note does.
@MainActor
private enum MentionCache {
    private static var found: [String: (hash: Int, hit: (linked: Bool, range: NSRange)?)] = [:]

    static func find(_ title: String, in text: String, key: String) -> (linked: Bool, range: NSRange)? {
        var hasher = Hasher()
        hasher.combine(title)
        hasher.combine(text)
        let hash = hasher.finalize()
        if let known = found[key], known.hash == hash { return known.hit }
        let wanted = WikiLinks.key(title)
        let hit: (linked: Bool, range: NSRange)?
        if let link = WikiLinks.links(in: text).first(where: { WikiLinks.links($0, to: wanted) }) {
            hit = (true, link.range)
        } else if let range = WikiLinks.plainMention(of: title, in: text) {
            hit = (false, range)
        } else {
            hit = nil
        }
        found[key] = (hash, hit)
        return hit
    }
}

/// Where something is mentioned: notes that [[link]] to it, then notes and meetings that name it without a link. A note's
/// mention becomes a link with one click.
struct MentionsPanel: View {
    let title: String
    /// The item itself, which isn't listed.
    var excluding: UUID? = nil
    var heading = "Mentioned in"
    @Query(sort: \NoteItem.updatedAt, order: .reverse) private var notes: [NoteItem]
    @Query(sort: \MeetingRecord.createdAt, order: .reverse) private var meetings: [MeetingRecord]

    struct Mention: Identifiable {
        let id: UUID
        let title: String
        let snippet: String
        let isMeeting: Bool
        let linked: Bool
        var note: NoteItem?
        var binderID: UUID?
    }

    private var searchable: Bool { Self.searchable(title) }

    /// Titles too generic to look for.
    static func searchable(_ title: String) -> Bool {
        let key = WikiLinks.key(title)
        return key.count >= 3 && key != "untitled note"
    }

    private var mentions: [Mention] { Self.mentions(of: title, excluding: excluding, notes: notes, meetings: meetings) }

    static func mentions(of title: String, excluding: UUID?, notes: [NoteItem], meetings: [MeetingRecord]) -> [Mention] {
        guard searchable(title) else { return [] }
        var found: [Mention] = []
        for note in notes where note.id != excluding {
            let text = note.text
            guard !text.isEmpty, let hit = MentionCache.find(title, in: text, key: "n" + note.id.uuidString) else { continue }
            found.append(Mention(id: note.id, title: note.title, snippet: Self.snippet(text, around: hit.range), isMeeting: false, linked: hit.linked,
                                 note: note, binderID: note.binderID))
        }
        for meeting in meetings where meeting.id != excluding {
            for (index, text) in [meeting.summary, meeting.userNotes].enumerated() where !text.isEmpty {
                guard let hit = MentionCache.find(title, in: text, key: "m\(index)" + meeting.id.uuidString) else { continue }
                found.append(Mention(id: meeting.id, title: meeting.title, snippet: Self.snippet(text, around: hit.range), isMeeting: true, linked: hit.linked,
                                     binderID: meeting.binderID))
                break
            }
        }
        return found
    }

    var body: some View {
        let mentions = mentions
        let linked = mentions.filter(\.linked), unlinked = mentions.filter { !$0.linked }
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(BindersTheme.cardTitle)
            if mentions.isEmpty {
                Text(searchable ? "Nothing else mentions “\(title)” yet. Type [[ in a note to link to it." : "Give this a title to see where it's mentioned.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(linked.prefix(30)) { row($0) }
            if !unlinked.isEmpty {
                Text("Not linked yet")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, linked.isEmpty ? 0 : 4)
                ForEach(unlinked.prefix(30)) { row($0) }
            }
        }
    }

    private func row(_ mention: Mention) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: mention.isMeeting ? "person.2.wave.2" : "note.text")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Button(mention.title) { LinkTargets.open(mention.title, from: mention.binderID) }
                    .themedLink()
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(mention.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !mention.linked, let note = mention.note {
                Button("Link") {
                    MarkdownEditor.flushAll()
                    if let text = WikiLinks.linkingFirstMention(of: title, in: note.text) {
                        NoteHistory.willChange(note, to: text)
                        note.text = text
                        note.updatedAt = Date()
                        Store.shared.save()
                    }
                }
                .controlSize(.small)
                .help("Make this mention of “\(title)” a link")
            }
        }
    }

    /// The words around a mention, on one line, without markup brackets.
    static func snippet(_ text: String, around range: NSRange) -> String {
        let string = text as NSString
        let line = string.lineRange(for: range)
        var snippet = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        snippet = snippet.replacingOccurrences(of: #"^([-*+]|\d+\.)\s+(\[[ xX]\]\s+)?|^#+\s+"#, with: "", options: .regularExpression)
        // A link reads as what it shows.
        snippet = snippet.replacingOccurrences(of: #"\[\[[^\]|]+\|([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        return snippet.count > 140 ? String(snippet.prefix(140)) + "…" : snippet
    }
}
