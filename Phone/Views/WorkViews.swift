import BindersKit
import SwiftUI
import UIKit

// Distill on the iPhone, read-only, through the Mac (lane DS1): a note's Work bar, its cards and its report, and a binder's
// Work list, from note_progress. Only for a Mac that lists LinkFeatures.distill; an older Mac shows none of it.

/// A Distill note's work, under it: the bar and its numbers, each card with where it stands, who has it, what its agent says
/// and what it waits for, and the report.
struct NoteWorkSection: View {
    @Environment(MacConnection.self) private var connection
    let noteID: String
    @State private var progress: DistillProgress.Progress?
    @State private var reporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress {
                HStack(alignment: .firstTextBaseline) {
                    Label("Work", systemImage: "square.stack.3d.down.right").font(Typeface.title(.headline)).foregroundStyle(Palette.ink)
                    Spacer()
                    if progress.counts.total > 0 {
                        Button("Report") { reporting = true }.font(.subheadline.weight(.semibold))
                    }
                }
                if progress.counts.total > 0 { PhoneWorkBar(counts: progress.counts) }
                Text(progress.counts.total > 0 ? progress.line : "Nothing from it is on the board yet.")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Palette.muted)
                if let proposed = progress.proposed {
                    Label(proposed == 1 ? "1 proposed item waits for your review on your Mac." : "\(proposed) proposed items wait for your review on your Mac.",
                          systemImage: "tray.full")
                        .font(.footnote)
                        .foregroundStyle(Palette.needsYou)
                }
                ForEach(progress.items, id: \.card) { item in
                    NavigationLink(value: CardLink(id: item.card)) { PhoneWorkItem(item: item) }
                        .buttonStyle(.plain)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .surfaceCard()
        .task(id: connection.revision("tasks") + connection.revision("notes")) { await load() }
        .sheet(isPresented: $reporting) {
            if let progress { PhoneReportSheet(report: progress.report) }
        }
    }

    private func load() async {
        let key = "progress-\(noteID)"
        if progress == nil { progress = connection.cached(key, as: DistillProgress.Progress.self) }
        // The saved copy leaves out what runs say they're doing, which is shown only fresh.
        if let fresh = await connection.fetch("note_progress", ["id": noteID], cache: key, as: DistillProgress.Progress.self,
                                              keeping: DistillProgress.keepable).value {
            progress = fresh
        }
    }
}

/// The bar: done, then in progress, then what waits on you, out of the whole.
struct PhoneWorkBar: View {
    let counts: DistillProgress.Counts

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let total = max(1, Double(counts.total))
            HStack(spacing: 0) {
                Rectangle().fill(Palette.done).frame(width: width * Double(counts.done) / total)
                Rectangle().fill(Palette.agent.opacity(0.8)).frame(width: width * Double(counts.inProgress) / total)
                Rectangle().fill(Palette.needsYou).frame(width: width * Double(counts.waitsOnYou) / total)
                Spacer(minLength: 0)
            }
            .background(Palette.line)
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("\(counts.done) of \(counts.total) done")
    }
}

/// One card of a note's work.
struct PhoneWorkItem: View {
    let item: DistillProgress.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.body.weight(.medium)).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(state).font(.caption.weight(.semibold)).foregroundStyle(color)
                // Its column on the board, where its state doesn't already say it.
                if item.columnTitle != state { Text(item.columnTitle).font(.caption).foregroundStyle(Palette.faint).lineLimit(1) }
                if let who = item.who {
                    if item.whoIsAgent {
                        Label(who, systemImage: "sparkles").font(.caption).foregroundStyle(Palette.agent).lineLimit(1)
                    } else {
                        Text(item.meant ? "for \(who == "You" ? "you" : who)" : who).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                }
            }
            // What its run says it's doing: its words, in lavender with the sparkle.
            if let doing = item.doing {
                Label(doing, systemImage: "sparkles").font(.footnote).foregroundStyle(Palette.agent).lineLimit(2)
            }
            // Its last update and when, beside what its run says.
            if let last = item.lastUpdate?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty, last != item.doing {
                Text("Last update\(item.lastUpdateAt.flatMap { Date(iso: $0) }.map { " " + Self.ago($0) } ?? ""): \(last)")
                    .font(.footnote).foregroundStyle(Palette.muted).lineLimit(2)
            }
            if !item.waitsFor.isEmpty {
                Label("Waits for " + item.waitsFor.prefix(3).map { "“\($0)”" }.joined(separator: ", "), systemImage: "hourglass")
                    .font(.footnote).foregroundStyle(Palette.muted).lineLimit(2)
            }
            if let section = item.section {
                Text(item.sectionChanged ? "\(section) · changed since" : section).font(.caption).foregroundStyle(item.sectionChanged ? Palette.needsYou : Palette.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "just now" within a minute, else "5 minutes ago", as the Mac's Work panel says it.
    private static func ago(_ date: Date) -> String {
        abs(Date().timeIntervalSince(date)) < 60 ? "just now" : date.formatted(.relative(presentation: .named))
    }

    private var state: String {
        switch item.state {
        case .done: "Done"
        case .inProgress: "In progress"
        case .waitsOnYou:
            item.column == BoardColumn.review.rawValue ? (item.waitsOn.map { "For \($0) to check" } ?? "To check")
                : (item.waitsOn.map { "Waits on \($0)" } ?? "Waits on you")
        case .heldUp: "Held up"
        case .notStarted: "Not started"
        }
    }

    private var color: Color {
        switch item.state {
        case .done: Palette.done
        case .inProgress: Palette.agent
        case .waitsOnYou: Palette.needsYou
        case .heldUp, .notStarted: Palette.muted
        }
    }
}

/// The report, as the Mac works it out from the board: what finished, what's in progress, what waits on whom, what's held
/// up, what's not started, and the sections changed since their cards were made. Copy as Markdown.
struct PhoneReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: DistillProgress.Report

    var body: some View {
        NavigationStack {
            List {
                Section { Text(report.line).font(.headline.monospacedDigit()).foregroundStyle(Palette.ink) }
                part(report.since == nil ? "Finished" : "Finished since you last looked", report.finished.map { "“\($0.title)”" + ($0.who.map { ", by \($0)" } ?? "") })
                part("In progress", report.inProgress.map { "“\($0.title)”: \($0.who ?? "someone")" + ($0.detail.map { ", who says: \($0)" } ?? "") })
                part("Waits on someone", report.waiting.map { "“\($0.title)” waits on \($0.who ?? "you"): \($0.detail ?? "")" })
                part("Held up", report.heldUp.map { "“\($0.title)” \($0.detail ?? "")" })
                part("Not started", report.notStarted.map { "“\($0.title)”" + ($0.who.map { ", for \($0)" } ?? ", for no one yet") })
                part("Sections changed since their cards were made", report.sections.map { section in
                    "\(section.section), by \(section.by)" + (section.behind.isEmpty ? ": its cards caught up" : ": \(section.behind.count) not caught up yet")
                })
            }
            .listGround()
            .navigationTitle(report.note)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { UIPasteboard.general.string = report.markdown.isEmpty ? report.line : report.markdown } label: {
                        Label("Copy as Markdown", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func part(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            Section(title) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.subheadline).foregroundStyle(Palette.ink)
                }
            }
            .surfaceRows()
        }
    }
}

/// A binder's Work list, above its notes: every note with Distill on, with its bar and numbers. `NotesList` loads it
/// (`load`), as a view with nothing in it yet would never start its own task.
struct BinderWorkList: View {
    let binder: String
    let entries: [DistillProgress.WorkListEntry]

    var body: some View {
        Section("Work") {
            ForEach(entries, id: \.note) { entry in
                NavigationLink(value: NoteSummary(id: entry.note, title: entry.title, updated: "", binder: binder, preview: "", distill: true)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title).font(.headline).foregroundStyle(Palette.ink).lineLimit(1)
                        if entry.counts.total > 0 { PhoneWorkBar(counts: entry.counts) }
                        Text(entry.line).font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .surfaceRows()
    }

    /// The binder's Work list from the Mac: last time's copy first, then the Mac's. None from a Mac without Distill.
    @MainActor
    static func load(_ binder: String, connection: MacConnection, into entries: Binding<[DistillProgress.WorkListEntry]>) async {
        guard connection.macFeatures.contains(LinkFeatures.distill) else { return entries.wrappedValue = [] }
        let key = "worklist-\(binder)"
        if entries.wrappedValue.isEmpty, let copy = connection.cached(key, as: [DistillProgress.WorkListEntry].self) { entries.wrappedValue = copy }
        if let fresh = await connection.fetch("note_progress", ["binder": binder], cache: key, as: [DistillProgress.WorkListEntry].self).value {
            entries.wrappedValue = fresh
        }
    }
}
