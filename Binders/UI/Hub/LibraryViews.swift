import AppKit
import SwiftData
import SwiftUI
import BindersKit

struct DictionaryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationController.self) private var controller
    @Query(sort: \DictionaryWord.createdAt, order: .reverse) private var words: [DictionaryWord]
    @State private var term = ""
    @State private var aliases = ""
    @State private var message: String?

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Dictionary",
                       subtitle: "Names, jargon and spellings Binders should always get right. Used to steer recognition and formatting.")
            HStack {
                TextField("Word or phrase, e.g. Binders", text: $term)
                TextField("Often heard as (optional, comma-separated)", text: $aliases)
                Button("Add", action: add).disabled(term.trimmed.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(add)

            HStack {
                Toggle("Learn from my corrections", isOn: $settings.autoLearnDictionary)
                    .help("When you fix a word right after dictating, Binders adds it here.")
                Spacer()
                if WisprImporter.isAvailable {
                    Button("Import from Wispr Flow") { runImport() }
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }

            List {
                ForEach(words) { word in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(word.term).font(.body.weight(.medium))
                            if !word.aliases.isEmpty {
                                Text("Heard as: " + word.aliases.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        switch word.source {
                        case "auto": Badge(text: "Learned", tinted: true)
                        case "wispr": Badge(text: "Imported")
                        default: EmptyView()
                        }
                        Button { Store.shared.delete(word) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if words.isEmpty {
                    ContentUnavailableView("No words yet", systemImage: "book.closed",
                                           description: Text("Add names and terms, or fix a word right after dictating and Binders will learn it."))
                }
            }
        }
        .padding(28)
    }

    private func add() {
        let value = term.trimmed
        guard !value.isEmpty, Store.shared.allowsSave() else { return }
        let heardAs = aliases.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
        if !Store.shared.addDictionaryWord(value, aliases: heardAs, source: "manual") {
            message = "“\(value)” is already in your dictionary."
        } else {
            message = nil
        }
        term = ""
        aliases = ""
    }

    private func runImport() {
        guard Store.shared.allowsSave() else { return }
        do {
            let summary = try WisprImporter.importAll()
            AppDefaults.store.set(true, forKey: "importedFromWispr")
            message = "Imported \(summary.words) words and \(summary.snippets) snippets from Wispr Flow."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }
}

struct SnippetsView: View {
    @Query(sort: \SnippetItem.createdAt, order: .reverse) private var snippets: [SnippetItem]
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var editing: SnippetItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Snippets",
                       subtitle: "Say a trigger phrase and Binders types the full text — links, addresses, intros, sign-offs.")
            VStack(alignment: .leading, spacing: 8) {
                TextField("Trigger phrase, e.g. my calendar link", text: $trigger)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $expansion)
                    .font(.body)
                    .frame(height: 70)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(BindersTheme.lineStrong))
                HStack {
                    Text("\(expansion.count)/4000").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Snippet") {
                        guard Store.shared.allowsSave() else { return }
                        Store.shared.insert(SnippetItem(trigger: trigger.trimmed, expansion: String(expansion.prefix(4000))))
                        trigger = ""
                        expansion = ""
                    }
                    .disabled(trigger.trimmed.isEmpty || expansion.trimmed.isEmpty)
                }
            }

            List {
                ForEach(snippets) { snippet in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            // The phrase you say, quoted.
                            Text("“\(snippet.trigger)”").font(BindersTheme.quote())
                            Text(snippet.expansion).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Spacer()
                        Button { editing = snippet } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                        Button { Store.shared.delete(snippet) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if snippets.isEmpty {
                    ContentUnavailableView("No snippets yet", systemImage: "text.badge.plus",
                                           description: Text("Try “my calendar link” → your booking URL."))
                }
            }
        }
        .padding(28)
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet)
        }
    }
}

private struct SnippetEditor: View {
    @Bindable var snippet: SnippetItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Snippet").font(BindersTheme.cardTitle)
            TextField("Trigger", text: $snippet.trigger).textFieldStyle(.roundedBorder)
            TextEditor(text: $snippet.expansion)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(BindersTheme.lineStrong))
            HStack {
                Spacer()
                Button("Done") {
                    Store.shared.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .pageGround()
    }
}

struct StyleView: View {
    @Environment(AppSettings.self) private var settings
    @State private var category: StyleCategory = .personal
    @State private var newIdentifier = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Style", subtitle: "Binders formats your words differently depending on where you're typing.")

                Picker("Category", selection: $category) {
                    ForEach(StyleCategory.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(category.summary).foregroundStyle(.secondary)

                if category.usesTone {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(Tone.allCases) { tone in
                            ToneCard(tone: tone, selected: settings.styles.tone(for: category) == tone) {
                                settings.styles.tones[category.rawValue] = tone
                            }
                        }
                    }
                } else {
                    Text("In terminals and editors Binders keeps commands, flags, file paths and identifiers exact, understands “camel case” and spoken symbols, and skips the trailing period on short commands.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paperCard(padding: 14)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom instructions").font(BindersTheme.cardTitle)
                    TextEditor(text: Binding(
                        get: { settings.styles.customInstructions[category.rawValue] ?? "" },
                        set: { settings.styles.customInstructions[category.rawValue] = $0 }))
                        .font(.body)
                        .frame(minHeight: 70)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(BindersTheme.lineStrong))
                    Text("For example: “Use British spelling”, “Never use em dashes”, “Sign emails with – Maya”.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("App & website categories").font(BindersTheme.cardTitle)
                    Text("Binders recognizes common apps automatically. Override any app or site here.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(settings.styles.appOverrides.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(displayName(for: key))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { settings.styles.appOverrides[key] ?? .other },
                                set: { settings.styles.appOverrides[key] = $0 })) {
                                ForEach(StyleCategory.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                            Button { settings.styles.appOverrides.removeValue(forKey: key) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Menu("Add running app") {
                            ForEach(runningApps, id: \.bundleIdentifier) { app in
                                Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                                    if let id = app.bundleIdentifier { settings.styles.appOverrides[id] = category }
                                }
                            }
                        }
                        .frame(width: 170)
                        TextField("or a website, e.g. notion.so", text: $newIdentifier)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addDomain)
                        Button("Add as \(category.displayName)", action: addDomain).disabled(newIdentifier.trimmed.isEmpty)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func displayName(for identifier: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return identifier
    }

    private func addDomain() {
        var domain = newIdentifier.trimmed.lowercased()
        if let host = URL(string: domain.contains("://") ? domain : "https://\(domain)")?.host { domain = host }
        if domain.hasPrefix("www.") { domain.removeFirst(4) }
        guard !domain.isEmpty else { return }
        settings.styles.appOverrides[domain] = category
        newIdentifier = ""
    }
}

private struct ToneCard: View {
    let tone: Tone
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tone.displayName).font(BindersTheme.cardTitle)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.tintText) : AnyShapeStyle(.secondary))
                }
                Text(tone.example).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? AnyShapeStyle(TintFill().opacity(0.08)) : AnyShapeStyle(Color.clear)))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BindersTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(.tintFill) : AnyShapeStyle(BindersTheme.line), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NotesView: View {
    @Environment(DictationController.self) private var controller
    @Environment(HubNavigation.self) private var navigation
    @Environment(TeamSyncService.self) private var team
    @Environment(\.undoManager) private var undoManager
    @ReducedMotion private var reduceMotion
    @Query private var notes: [NoteItem]
    @State private var selection: UUID?
    /// A note just made, whose editor takes the cursor.
    @State private var focusID: UUID?
    /// A heading or block to show in a note, from a link to it.
    @State private var reveal: (note: UUID, place: EditorReveal)?
    @State private var noteToDelete: NoteItem?
    /// Show only notes with this status, or this #tag.
    @State private var statusFilter: String?
    @State private var tagFilter: String?
    let binderID: UUID?

    private var shown: [NoteItem] {
        notes.filter { note in
            (statusFilter == nil || note.status == statusFilter) && (tagFilter.map { NoteTagCache.tags(of: note).contains($0) } ?? true)
        }
    }

    /// The tags in these notes, most used first.
    private var tags: [String] {
        let counts = notes.flatMap { NoteTagCache.tags(of: $0) }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(30).map(\.key)
    }

    /// The notes in one binder, or every note when `binderID` is nil.
    init(binderID: UUID? = nil) {
        self.binderID = binderID
        if let binderID {
            _notes = Query(filter: #Predicate<NoteItem> { $0.binderID == binderID }, sort: [SortDescriptor(\NoteItem.updatedAt, order: .reverse)])
        } else {
            _notes = Query(sort: [SortDescriptor(\NoteItem.updatedAt, order: .reverse)])
        }
    }

    var body: some View {
        content
            .onAppear {
                navigation.currentNoteID = selection
                consumePendingNote()
            }
            .onChange(of: navigation.pendingNoteID) { consumePendingNote() }
            .onChange(of: NoteTrash.shared.restored) { _, id in if let id { selection = id } }
            // Not on appearing: then it would see the selection from before a new note's, and the new note would open
            // without the cursor in it.
            .onChange(of: selection) { _, now in
                if now != focusID { focusID = nil }
                navigation.currentNoteID = now
            }
            .onDisappear { navigation.currentNoteID = nil }
            .onReceive(NotificationCenter.default.publisher(for: TeamSyncService.itemsWillBeRemoved)) { notification in
                // A teammate removed the open note: close it before sync deletes it.
                if let ids = notification.userInfo?["ids"] as? Set<UUID>, let selection, ids.contains(selection) { self.selection = nil }
            }
    }

    private func newNote(from template: NoteTemplate?) {
        guard Store.shared.allowsSave() else { return }
        let binder = Store.shared.binder(binderID ?? AppSettings.shared.currentBinderID) ?? Store.shared.defaultBinder()
        let note = TemplateStore.newNote(from: template, in: binder)
        focusID = note.id
        selection = note.id
    }

    private func consumePendingNote() {
        guard let pending = navigation.pendingNoteID else { return }
        if navigation.pendingNoteIsNew { focusID = pending }
        navigation.pendingNoteIsNew = false
        reveal = navigation.pendingNotePlace.map { (pending, EditorReveal(place: $0)) }
        navigation.pendingNotePlace = nil
        selection = pending
        navigation.pendingNoteID = nil
    }

    private var content: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Notes").font(BindersTheme.columnTitle).foregroundStyle(.sectionInk)
                    Spacer()
                    Menu {
                        Section("Status") {
                            Button("Any") { statusFilter = nil }
                            ForEach(NoteProperties.statuses + Array(Set(notes.compactMap(\.status)).subtracting(NoteProperties.statuses)).sorted(), id: \.self) { status in
                                Button(status) { statusFilter = status }
                            }
                        }
                        if !tags.isEmpty {
                            Section("Tag") {
                                Button("Any") { tagFilter = nil }
                                ForEach(tags, id: \.self) { tag in Button("#\(tag)") { tagFilter = tag } }
                            }
                        }
                    } label: {
                        Image(systemName: statusFilter != nil || tagFilter != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .quietControl()
                    .help("Show only notes with a status or a tag")
                    // A click makes a blank note; the menu starts one from a template.
                    Menu {
                        Section("From a template") {
                            ForEach(TemplateStore.all) { template in
                                Button(template.name) { newNote(from: template) }
                            }
                        }
                        Divider()
                        if let note = notes.first(where: { $0.id == selection }) {
                            Button("Save “\(note.title)” as a Template") {
                                MarkdownEditor.flushAll()
                                TemplateStore.save(note)
                            }
                        }
                        Button("Show Templates Folder") { TemplateStore.showFolder() }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    } primaryAction: {
                        newNote(from: nil)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .quietControl()
                    .help("New note. The arrow starts one from a template.")
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 8)
                if statusFilter != nil || tagFilter != nil {
                    HStack(spacing: 6) {
                        if let statusFilter { filterChip(statusFilter) { self.statusFilter = nil } }
                        if let tagFilter { filterChip("#\(tagFilter)") { self.tagFilter = nil } }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                }
                List(shown, selection: $selection) { note in
                    NoteRow(note: note)
                    .tag(note.id)
                    // Two fingers to the left on the trackpad.
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { requestDelete(note) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                .scrollContentBackground(.hidden)
                // ⌫ or ⌦ on the selected note, or right-click. Undo puts it back; a team note asks first.
                .onDeleteCommand { if let note = notes.first(where: { $0.id == selection }) { requestDelete(note) } }
                .onKeyPress(.deleteForward) {
                    guard let note = notes.first(where: { $0.id == selection }) else { return .ignored }
                    requestDelete(note)
                    return .handled
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let note = notes.first(where: { $0.id == id }) {
                        Button("Open in Its Own Window") { NotePopouts.shared.open(note) }
                        Button("Fold into a Bubble") { NotePopouts.shared.open(note, collapsed: true) }
                        Button("Put on Board") {
                            guard Store.shared.allowsSave() else { return }
                            MarkdownEditor.flushAll()
                            let card = controller.board.create(from: note, by: .you)
                            controller.router.suggestLater(for: card, origin: .toBoard)
                            let name = Store.shared.binder(card.binderID)?.name
                            controller.flowBar.toast(name.map { "Added to the \($0) board" } ?? "Added to the board", symbol: "checkmark.circle")
                        }
                        Divider()
                        Button(sharedWithTeam(note) ? "Delete for Everyone…" : "Delete", role: .destructive) { requestDelete(note) }
                    }
                } primaryAction: { ids in
                    // A double-click opens the note in a window of its own.
                    if let id = ids.first, let note = notes.first(where: { $0.id == id }) { NotePopouts.shared.open(note) }
                }
                .confirmationDialog(deleteTitle, isPresented: Binding(get: { noteToDelete != nil }, set: { if !$0 { noteToDelete = nil } }),
                                    presenting: noteToDelete) { note in
                    Button(sharedWithTeam(note) ? "Delete for Everyone" : "Delete", role: .destructive) { delete(note) }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel", role: .cancel) {}
                } message: { note in
                    Text(sharedWithTeam(note) ? "It's removed for everyone on the team. This can't be undone." : "This can't be undone.")
                }
                if let deleted = NoteTrash.shared.last {
                    HStack(spacing: 8) {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                        Text("Deleted “\(deleted.title)”").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button("Undo") { NoteTrash.shared.restore(deleted, undoManager: undoManager) }
                            .help("Put the note back (⌘Z)")
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(BindersTheme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(BindersTheme.line))
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    // It rises into place; under Reduce Motion it fades in.
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                Button("Open Scratchpad (\(AppSettings.shared.hotkeys.scratchpad?.displayString() ?? "menu bar"))") {
                    ScratchpadController.shared.show()
                }
                .themedLink()
                .padding(12)
            }
            .frame(width: 260)
            .animation(.easeOut(duration: 0.2), value: NoteTrash.shared.last?.id)
            Divider()
            if let note = notes.first(where: { $0.id == selection }) {
                // A fresh editor per note: reusing one would take the switch for an edit and move the note to the top.
                NoteEditor(note: note, focused: note.id == focusID, reveal: reveal?.note == note.id ? reveal?.place : nil) {
                    selection = neighbour(of: note)?.id
                }
                    .id(note.id)
            } else {
                ContentUnavailableView("Select a note", systemImage: "note.text",
                                       description: Text("Dictate into the Scratchpad and your notes land here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var deleteTitle: String {
        guard let noteToDelete else { return "Delete this note?" }
        return sharedWithTeam(noteToDelete) ? "Delete “\(noteToDelete.title)” for everyone on the team?" : "Delete “\(noteToDelete.title)”?"
    }

    private func sharedWithTeam(_ note: NoteItem) -> Bool {
        team.isConfigured && (note.sharedWithTeam || note.isTeamCopy)
    }

    /// The note below this one in the list, or above it at the end, so deleting several in a row is ⌫ ⏎ ⌫ ⏎.
    private func neighbour(of note: NoteItem) -> NoteItem? {
        let list = shown
        guard let index = list.firstIndex(where: { $0.id == note.id }) else { return nil }
        if list.indices.contains(index + 1) { return list[index + 1] }
        return index > 0 ? list[index - 1] : nil
    }

    private func filterChip(_ label: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(TintFill().opacity(0.14)))
            .foregroundStyle(.tintText)
        }
        .buttonStyle(.plain)
        .help("Show all notes again")
    }

    /// A note of your own goes at once, and Undo brings it back; one shared with the team is deleted for everyone, so
    /// that asks first.
    private func requestDelete(_ note: NoteItem) {
        if sharedWithTeam(note) { noteToDelete = note } else { delete(note) }
    }

    private func delete(_ note: NoteItem) {
        if selection == note.id { selection = neighbour(of: note)?.id }
        if sharedWithTeam(note) { NoteEditor.remove(note) } else { NoteTrash.shared.delete(note, undoManager: undoManager) }
    }
}

/// The edge between a page and a side panel: drag it to resize the panel, or all the way across to hide it.
struct PanelEdge: View {
    @Binding var width: Double
    @Binding var visible: Bool
    var minimum: Double = 220
    var maximum: Double = 620
    /// Narrower than this when let go, and the panel hides.
    var hideBelow: Double = 140
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(BindersTheme.line).frame(width: 1).opacity(visible ? 1 : 0)
            Color.clear.frame(width: 7).contentShape(Rectangle())
        }
        .frame(width: 7)
        .onHover { inside in
            if inside, !hovering { NSCursor.resizeLeftRight.push() } else if !inside, hovering { NSCursor.pop() }
            hovering = inside
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { drag in
                let from = start ?? (visible ? width : 0)
                if start == nil { start = from }
                let wanted = from - drag.translation.width
                if from == 0 {
                    // Hidden: a short pull brings it out, at its narrowest, and it follows from there.
                    guard wanted > 24 else { return }
                    visible = true
                    width = min(max(wanted, minimum), maximum)
                } else if wanted < hideBelow {
                    visible = false
                } else {
                    visible = true
                    width = min(max(wanted, minimum), maximum)
                }
            }
            .onEnded { _ in start = nil })
        .help(visible ? "Drag to resize the digest, or all the way to hide it" : "Drag to show the digest")
        .accessibilityLabel("Digest width")
    }
}

/// A note in the notes list. A view of its own, so typing in one note redraws its row and leaves the others.
private struct NoteRow: View {
    let note: NoteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title).lineLimit(1)
            HStack(spacing: 4) {
                if note.isTeamCopy {
                    Image(systemName: "person.2.fill")
                    Text("\(note.teamAuthorName ?? "Team") ·")
                } else if note.sharedWithTeam, AppSettings.shared.teamFolderPath != nil {
                    Image(systemName: "person.2")
                    Text("Shared ·")
                }
                // An agent's words in it: whose, until you make it yours.
                if !note.agentMark.isEmpty {
                    AgentLabel(note.agentMark)
                    Text("·")
                }
                Text(note.updatedAt, format: .relative(presentation: .named)).monospacedDigit()
                if let status = note.status { Text("· \(status)") }
                if let due = note.dueAt {
                    // Late needs you: amber, with its clock.
                    let late = due < Calendar.current.startOfDay(for: Date()) && note.status != "Done"
                    Text("·")
                    if late { Image(systemName: "clock").foregroundStyle(BindersTheme.needsYou).accessibilityHidden(true) }
                    Text("due \(due.formatted(.dateTime.month(.abbreviated).day()))").foregroundStyle(late ? AnyShapeStyle(BindersTheme.needsYou) : AnyShapeStyle(.secondary))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

struct NoteEditor: View {
    @Environment(DictationController.self) private var controller
    @Environment(TeamSyncService.self) private var team
    @Environment(KnowledgeService.self) private var knowledge
    @Environment(AppSettings.self) private var settings
    @Environment(\.undoManager) private var undoManager
    @Bindable var note: NoteItem
    /// Just made: the editor takes the cursor.
    var focused = false
    /// A heading or block to show, from a link to it.
    var reveal: EditorReveal? = nil
    var onDelete: () -> Void
    @State private var confirmDelete = false
    @State private var showingHistory = false
    /// See What Changed: the history opens at the version from before an agent's change, showing what changed since.
    @State private var historyFrom: Date?
    /// Every note follows the same choice.
    @AppStorage("notesShowDigest", store: AppDefaults.store) private var digestVisible = true
    @AppStorage("notesDigestWidth", store: AppDefaults.store) private var digestWidth: Double = 300
    @State private var digestCopied = false
    /// "Updated 3 links in 2 notes", for a moment after a new title.
    @State private var renameNotice: String?
    /// Put on Board: the card it made, and where, for a few seconds.
    @State private var boardNotice: (card: TaskCard, line: String)?

    private var digesting: Bool { knowledge.digestingNoteIDs.contains(note.id) }
    private var digestStale: Bool { !note.digest.isEmpty && note.digestHash != KnowledgeService.noteContentHash(note.text) }

    var body: some View {
        VStack(spacing: 0) {
            if !note.agentMark.isEmpty {
                AgentNoteBanner(note: note, seeChanges: {
                    MarkdownEditor.flushAll()
                    historyFrom = note.editedAt
                    showingHistory = true
                }, madeMine: { knowledge.correctionsChanged() })
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }
            if note.isTeamCopy {
                Label("\(note.teamAuthorName ?? "A teammate") shared this note. Your edits sync to everyone on the team.", systemImage: "person.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
            }
            HStack(spacing: 0) {
                // The note page: a sheet, light paper in the light appearance and a dark page in the dark.
                MarkdownNoteEditor(text: $note.text, fontSize: 15, placeholder: "Write, or hold fn to dictate.",
                                   links: LinkTargets.forNote(note) { renamed($0) }, focused: focused, reveal: reveal, accessories: AnyView(noteButtons),
                                   paper: true)
                    .paperSheet()
                    .padding([.leading, .vertical], 14)
                    .padding(.trailing, 4)
                    .onChange(of: note.text) { previous, _ in
                        note.updatedAt = Date()
                        NoteHistory.changed(note.id, previous: previous)
                    }
                // Drag the edge to make the digest wider or narrower; most of the way closed, it hides. Dragged out again,
                // it comes back.
                PanelEdge(width: $digestWidth, visible: $digestVisible)
                if digestVisible {
                    digestColumn.frame(width: digestWidth)
                }
            }
            HStack {
                Text("\(note.text.wordCount) words").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if let renameNotice {
                    Label(renameNotice, systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .transition(.opacity)
                        .help("They follow the note's new title. Undo, with the cursor in the note, puts them back.")
                }
                if !note.isTeamCopy, let binder = Store.shared.binder(note.binderID) {
                    Menu {
                        MoveToBinderItems(current: note.binderID) { target in
                            MarkdownEditor.flushAll()
                            Store.shared.move(note, to: target)
                            team.scheduleSync(after: 0.5)
                        }
                    } label: {
                        // Made from what you said, it's on this Mac only, though its binder is shared.
                        let shared = binder.sharedWithTeam && !note.staysUnshared
                        Label(shared ? "\(binder.name) · shared" : binder.sharedWithTeam ? "\(binder.name) · on this Mac only" : binder.name,
                              systemImage: shared ? "person.2" : "books.vertical")
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .padding(.leading, 8)
                    .help(note.staysUnshared ? "Which binder this note is in. Made from what you said, it stays on this Mac, even in a shared binder."
                          : "Which binder this note is in. Sharing follows the binder.")
                }
                Spacer()
                if let boardNotice {
                    // What was done, with the way to it.
                    Label(boardNotice.line, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                    Button("Open") { HubWindowController.shared.navigation.open(card: boardNotice.card) }
                        .controlSize(.small)
                        .help("Open the card on its board")
                }
                Button { putOnBoard() } label: { Label("Put on Board", systemImage: "rectangle.split.3x1") }
                    .help("A card on this binder's board with the note's title, its first lines and a link back to the note")
                Button {
                    MarkdownEditor.flushAll()
                    historyFrom = nil
                    showingHistory = true
                } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .help("Earlier versions of this note, to read or put back")
                Button("Copy") {
                    MarkdownEditor.flushAll()
                    TextInserter.copyToClipboard(note.text)
                }
                Button("Delete", role: .destructive) {
                    if team.isConfigured, note.sharedWithTeam || note.isTeamCopy { confirmDelete = true } else { delete() }
                }
            }
            .padding(12)
        }
        .sheet(isPresented: $showingHistory) { NoteHistorySheet(note: note, changesFrom: historyFrom) }
        .confirmationDialog("Delete this note for everyone on the team?", isPresented: $confirmDelete) {
            Button("Delete for Everyone", role: .destructive, action: delete)
        }
    }

    /// Put on Board: a card in the note's binder, and a word that says where, with Open, for a few seconds.
    private func putOnBoard() {
        guard Store.shared.allowsSave() else { return }
        MarkdownEditor.flushAll()
        let card = controller.board.create(from: note, by: .you)
        controller.router.suggestLater(for: card, origin: .toBoard)
        let line = Store.shared.binder(card.binderID).map { "Added to the \($0.name) board" } ?? "Added to the board"
        withAnimation { boardNotice = (card, line) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if boardNotice?.card.id == card.id { withAnimation { boardNotice = nil } }
        }
    }

    /// Says how many links a new title changed, for a few seconds.
    private func renamed(_ rename: LinkRename) {
        let notice = rename.summary
        DispatchQueue.main.async {
            withAnimation { renameNotice = notice }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if renameNotice == notice { withAnimation { renameNotice = nil } }
            }
        }
    }

    /// At the top right of the note: the digest beside it, shown or not, and popping the note out.
    private var noteButtons: some View {
        HStack(spacing: 4) {
            Toggle(isOn: $digestVisible) {
                Image(systemName: "sidebar.right").frame(width: 24, height: 20)
                    .foregroundStyle(digestVisible ? AnyShapeStyle(.tintText) : AnyShapeStyle(.secondary))
            }
            .toggleStyle(.button)
            .help(digestVisible ? "Hide the digest and properties" : "Show the digest and properties beside the note")
            .accessibilityLabel("Digest")
            Button { NotePopouts.shared.open(note) } label: {
                Label("Pop Out", systemImage: "macwindow.on.rectangle").labelStyle(.titleAndIcon).font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open this note in a small window that stays in front of everything and folds into a bubble. Or double-click it in the list.")
            .padding(.leading, 4)
        }
    }

    /// The model's short take on the note, kept next to it and searchable in Knowledge.
    private var digestColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotePropertiesPanel(note: note)
            Divider().padding(.vertical, 4)
            HStack {
                Text("Digest").font(BindersTheme.cardTitle).foregroundStyle(.sectionInk)
                Spacer()
                if !note.digest.isEmpty {
                    Button(action: copyDigest) {
                        Image(systemName: digestCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .quietControl()
                    .help("Copy the digest as Markdown")
                }
                if digesting {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        MarkdownEditor.flushAll()
                        Task { await knowledge.digest(note) }
                    } label: {
                        // The model writes it; no agent does, so not the sparkle.
                        Image(systemName: note.digest.isEmpty ? BindersTheme.modelSymbol : "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .quietControl()
                    .disabled(note.text.wordCount < 3)
                    .help(note.digest.isEmpty ? "Write a digest with your local model" : "Write the digest again")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let digestIssue {
                        StatusLabel(digestIssue, .problem)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if note.digest.isEmpty {
                        if digestIssue == nil {
                            Text(digestPlaceholder)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        if digestStale {
                            Label(digesting ? "Updating…" : "The note changed since this was written.", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        MarkdownBlocks(markdown: note.digest, foldable: true, onToggleTask: { line in
                            note.digest = NotesEditing.toggleCheckbox(in: note.digest, line: line)
                        })
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            Button("Copy Digest", action: copyDigest)
                        }
                    }
                    // Notes and meetings that link to this one, or mention it.
                    Divider().padding(.vertical, 6)
                    MentionsPanel(title: note.title, excluding: note.id)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .task { await LinkTargets.refreshEntities(knowledge) }
    }

    /// The whole digest, as Markdown, so it pastes cleanly into another note, Obsidian or a message.
    private func copyDigest() {
        TextInserter.copyToClipboard(note.digest.trimmingCharacters(in: .whitespacesAndNewlines))
        digestCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            digestCopied = false
        }
    }

    private var digestIssue: String? {
        digesting ? nil : knowledge.digestIssues[note.id]
    }

    private var digestPlaceholder: String {
        if digesting { return "Reading the note…" }
        if note.text.wordCount < NoteDigest.minimumWords {
            return "Short notes speak for themselves. Click the wand to digest this one anyway."
        }
        if !settings.noteDigests {
            return "Digests are off in Settings → Knowledge. Click the wand to write one now."
        }
        return "A digest is written about a minute and a half after you stop editing: a title, a summary, key points and to-dos, all searchable in Knowledge."
    }

    private func delete() {
        onDelete()
        if team.isConfigured, note.sharedWithTeam || note.isTeamCopy {
            Self.remove(note)
        } else {
            NoteTrash.shared.delete(note, undoManager: undoManager)
        }
    }

    /// For good, history and all: for notes shared with the team, once deleting for everyone was confirmed.
    static func remove(_ note: NoteItem) {
        ScratchpadController.shared.noteWillBeDeleted(note)
        NotePopouts.shared.close(note.id)
        // Let the editor leave the hierarchy before the model is deleted.
        DispatchQueue.main.async { Store.shared.delete(note) }
    }
}
