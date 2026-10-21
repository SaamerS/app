import Foundation
import SwiftData
import SwiftUI
import BindersKit

/// Earlier versions of notes, kept as Markdown files in History/<note id>/ next to the database: the note as it was
/// before an editing session, every few minutes while you write, and before a teammate's or an agent's change lands.
@MainActor
enum NoteHistory {
    struct Version: Identifiable, Hashable {
        let url: URL
        let date: Date
        let text: String
        var id: URL { url }
    }

    static var folder: URL { AppPaths.support.appendingPathComponent("History", isDirectory: true) }
    private static func folder(for id: UUID) -> URL { folder.appendingPathComponent(id.uuidString, isDirectory: true) }
    /// The last version kept per note, so a keystroke costs a lookup, not a trip to the disk.
    private static var lastKept: [UUID: (date: Date, text: String)] = [:]

    /// Newest first. Files are named by the moment they were kept, in milliseconds.
    static func versions(of id: UUID) -> [Version] {
        ((try? FileManager.default.contentsOfDirectory(at: folder(for: id), includingPropertiesForKeys: nil)) ?? [])
            .compactMap { url -> Version? in
                guard url.pathExtension == "md", let milliseconds = Double(url.deletingPathExtension().lastPathComponent),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Version(url: url, date: Date(timeIntervalSince1970: milliseconds / 1000), text: text)
            }
            .sorted { $0.date > $1.date }
    }

    /// Call before changing a note's text from code: sync, an agent, a tick. `always` keeps it however recent the last
    /// version is, for changes that aren't yours, such as a teammate's.
    static func willChange(_ note: NoteItem, to newText: String, always: Bool = false) {
        guard newText != note.text else { return }
        changed(note.id, previous: note.text, always: always)
    }

    /// A note changed from `previous`: keep it if it's time.
    static func changed(_ id: UUID, previous: String, always: Bool = false) {
        let last = lastKept[id] ?? versions(of: id).first.map { ($0.date, $0.text) }
        let now = Date()
        let due = always ? last?.text != previous && !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         : NoteVersions.shouldKeep(previous, lastKept: last, now: now)
        guard due else {
            if lastKept[id] == nil, let last { lastKept[id] = last }
            return
        }
        keep(previous, for: id, at: now)
    }

    static func keep(_ text: String, for id: UUID, at date: Date) {
        let directory = folder(for: id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(Int64(date.timeIntervalSince1970 * 1000))
        try? text.write(to: directory.appendingPathComponent(name).appendingPathExtension("md"), atomically: true, encoding: .utf8)
        lastKept[id] = (date, text)
        let all = versions(of: id)
        let expired = Set(NoteVersions.expired(all.map(\.date), now: date))
        for version in all where expired.contains(version.date) { try? FileManager.default.removeItem(at: version.url) }
    }

    /// A deleted note's versions.
    static func forget(_ id: UUID) {
        lastKept[id] = nil
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    /// Clears the versions of notes that are gone: deleted and not put back before the app quit, or removed by sync.
    static func forgetDeletedNotes() {
        // A store that can't be read, or the empty one used when the database won't open, says nothing about which notes
        // are gone.
        guard !Store.shared.isFallback, let notes = try? Store.shared.context.fetch(FetchDescriptor<NoteItem>()) else { return }
        let kept = Set(notes.map(\.id))
        for folder in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: folder.lastPathComponent), !kept.contains(id) else { continue }
            forget(id)
        }
    }

    /// Puts a version back, keeping what's there now as a version first, so a restore can be undone the same way.
    static func restore(_ version: Version, to note: NoteItem) {
        keep(note.text, for: note.id, at: Date())
        note.text = version.text
        note.updatedAt = Date()
        Store.shared.save()
    }
}

/// A note's earlier versions: pick one to read it, or what changed since, then copy it or put it back.
struct NoteHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let note: NoteItem
    /// See What Changed on an agent's edit: opens at the version kept just before that moment, showing what changed since.
    var changesFrom: Date? = nil
    @State private var versions: [NoteHistory.Version] = []
    @State private var selected: NoteHistory.Version?
    @State private var showingChanges = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Earlier versions of “\(note.title)”").font(BindersTheme.cardTitle).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if versions.isEmpty {
                ContentUnavailableView("No earlier versions yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Binders keeps a note as it was before each time you edit it, every few minutes while you write, and before a teammate's or an agent's change lands. Versions stay for 30 days."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(versions, selection: $selected) { version in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                            Text(changeLabel(version)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(version)
                    }
                    .scrollContentBackground(.hidden)
                    .background(BindersTheme.ground2)
                    .frame(width: 230)
                    Divider()
                    if let selected {
                        VStack(alignment: .leading, spacing: 0) {
                            ScrollView {
                                if showingChanges {
                                    NoteChangesView(lines: NoteVersions.lines(from: selected.text, to: note.text))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(20)
                                } else {
                                    MarkdownBlocks(markdown: selected.text, onToggleTask: nil)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(20)
                                }
                            }
                            Divider()
                            HStack {
                                Button("Copy") { TextInserter.copyToClipboard(selected.text) }
                                Toggle("Show Changes Since", isOn: $showingChanges)
                                    .toggleStyle(.button)
                                    .help("What changed from this version to the note as it is now")
                                Spacer()
                                Button("Restore This Version") {
                                    NoteHistory.restore(selected, to: note)
                                    dismiss()
                                }
                                .help("Puts this version back. What's there now is kept as a version, so you can go back to it.")
                            }
                            .padding(12)
                        }
                    }
                }
            }
        }
        .frame(width: 780, height: 540)
        .pageGround()
        .task {
            versions = NoteHistory.versions(of: note.id)
            // The version kept as the change landed is from the same moment, give or take the rounding of its name.
            let before = changesFrom.flatMap { moment in versions.first { $0.date <= moment.addingTimeInterval(1) } }
            selected = before ?? versions.first
            showingChanges = before != nil
        }
    }

    /// "3 lines added, 1 removed since" / "Same as now".
    private func changeLabel(_ version: NoteHistory.Version) -> String {
        let change = NoteVersions.change(from: version.text, to: note.text)
        if change.added == 0, change.removed == 0 { return "Same as now" }
        var parts: [String] = []
        if change.added > 0 { parts.append("\(change.added) \(change.added == 1 ? "line" : "lines") added") }
        if change.removed > 0 { parts.append("\(change.removed) removed") }
        return parts.joined(separator: ", ") + " since"
    }
}

/// What changed from a version to the note as it is now, line by line: what was taken out struck through, what was
/// added marked with a plus, the rest as it was.
struct NoteChangesView: View {
    let lines: [NoteVersions.Line]

    private var unchanged: Bool {
        lines.allSatisfy { line in
            if case .same = line { return true }
            return false
        }
    }

    var body: some View {
        if unchanged {
            Text("Nothing has changed since this version.").foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func row(_ line: NoteVersions.Line) -> some View {
        switch line {
        case .same(let text):
            mark(" ", text).foregroundStyle(.secondary)
        case .added(let text):
            mark("+", text)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.infoFill(0.12)))
                .accessibilityLabel("Added: \(text)")
        case .removed(let text):
            mark("−", text, struck: true).foregroundStyle(.secondary)
                .accessibilityLabel("Taken out: \(text)")
        }
    }

    private func mark(_ sign: String, _ text: String, struck: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(sign).monospaced().frame(width: 12)
            Text(text.isEmpty ? " " : text).strikethrough(struck).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}
