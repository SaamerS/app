import BindersKit
import SwiftUI
import UIKit

/// One conversation All-day capture heard: what was said, by whom and when, and, once the Mac has written it up, its notes.
struct ConversationDetailView: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var store = CaptureStore.shared
    @State private var processor = ConversationProcessor.shared
    @State private var suggestions = SuggestionCenter.shared
    @State private var notes: Meeting?
    @State private var outcome: String?
    @State private var sharing: SharedFile?
    let id: UUID

    private var conversation: CapturedConversation? { store.conversation(id) }

    var body: some View {
        ScrollView {
            if let conversation {
                VStack(alignment: .leading, spacing: 18) {
                    header(conversation)
                    suggestionsSection
                    if let notes, !notes.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Notes from \(connection.mac?.name ?? "your Mac")", systemImage: "desktopcomputer").font(.headline)
                            Text([notes.title, notes.binder].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                            MarkdownText(markdown: notes.notes)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                    }
                    transcript(conversation)
                }
                .padding()
            } else {
                ContentUnavailableView("Deleted", systemImage: "trash")
            }
        }
        .navigationTitle(conversation.map { $0.started.formatted(date: .abbreviated, time: .shortened) } ?? "Capture")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { share() } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                        .disabled(conversation?.payload(device: UIDevice.current.model) == nil)
                    if let conversation, conversation.isUnsent, conversation.state != .recording {
                        Button("Delete", role: .destructive) {
                            ConversationProcessor.shared.forget(id)
                            connection.forgetConversation(id)
                            store.delete(id)
                            dismiss()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("conversationMenu")
            }
        }
        .sheet(item: $sharing) { file in
            ShareSheet(url: file.url) { activity, completed in
                if completed { ConversationSharing.shared([id], via: activity, connection: connection) }
                sharing = nil
            }
        }
        .task(id: "\(connection.revision("meetings"))|\(conversation?.state.rawValue ?? "")") {
            // Written up on the Mac once it's there.
            guard conversation?.state == .sent || conversation?.sharedAt != nil else { return }
            notes = await connection.fetch("get_meeting", ["id": id.uuidString], cache: "conversation-\(id.uuidString)", as: Meeting.self).value
            await suggestions.refresh()
        }
    }

    /// What the Mac offers: cards to put on a board, answers from your binders.
    @ViewBuilder
    private var suggestionsSection: some View {
        // Offers need the Mac to act on them; answers can be read without one.
        let offered = suggestions.forConversation(id).filter { ($0.status == .offered && connection.mac != nil) || $0.kind == .answer }
        if !offered.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(offered) { suggestion in
                    if suggestion.kind == .card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Put this on the \(suggestion.binder) board?", systemImage: "rectangle.split.3x1").font(.subheadline.weight(.semibold))
                            Text(suggestion.text)
                            HStack {
                                Button("Add to Board") { act(suggestion.id, accept: true) }.buttonStyle(.borderedProminent)
                                Button("Not Now") { act(suggestion.id, accept: false) }.buttonStyle(.bordered)
                            }
                            .controlSize(.small)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("You asked: \(suggestion.text)", systemImage: "questionmark.bubble").font(.subheadline.weight(.semibold))
                            Text(suggestion.answer ?? "")
                            if !suggestion.sources.isEmpty {
                                Text("From " + suggestion.sources.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.1)))
        }
        // Outside the offers: the last one said yes to takes them away, not what the Mac said.
        if let outcome {
            Label(outcome, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func act(_ suggestion: String, accept: Bool) {
        Task { outcome = await suggestions.act(suggestion, accept: accept) }
    }

    private func header(_ conversation: CapturedConversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(conversation.started.formatted(date: .omitted, time: .shortened))–\(conversation.ended.formatted(date: .omitted, time: .shortened))")
                .font(.title2.bold())
            Text(details(conversation)).font(.subheadline).foregroundStyle(.secondary)
            if processor.working == id, let activity = processor.activity {
                Label(activity, systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
            } else if let error = conversation.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private func details(_ conversation: CapturedConversation) -> String {
        var parts = ["\(max(1, Int((conversation.duration / 60).rounded()))) min"]
        if let words = conversation.words { parts.append("\(words) words") }
        switch conversation.state {
        case .sent: parts.append(conversation.sharedVia.map { "shared by \($0)" } ?? "sent to your Mac")
        case .queued: parts.append(conversation.sharedVia.map { "shared by \($0)" }
                                   ?? (connection.mac == nil ? "on this iPhone until you pair a Mac" : "waiting for your Mac"))
        case .failed:
            parts.append(conversation.transcript != nil ? "not sent"
                         : conversation.canRetry ? "not written down, tried again when Binders opens" : "not written down")
        default: parts.append("not written down yet")
        }
        if let engine = conversation.engine { parts.append(engine) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func transcript(_ conversation: CapturedConversation) -> some View {
        if let segments = conversation.transcript, !segments.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Transcript", systemImage: "text.quote").font(.headline)
                ForEach(Array(TranscriptFormatter.blocks(segments, names: conversation.speakers ?? [:]).enumerated()), id: \.offset) { _, block in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(block.speaker).font(.subheadline.weight(.semibold))
                                .foregroundStyle(block.speaker == TranscriptSegment.you ? Color.accentColor : .primary)
                            Text(conversation.started.addingTimeInterval(block.start).formatted(date: .omitted, time: .shortened))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(block.text).textSelection(.enabled)
                    }
                }
            }
        } else {
            Text(placeholder(conversation)).foregroundStyle(.secondary)
        }
    }

    private func placeholder(_ conversation: CapturedConversation) -> String {
        switch conversation.state {
        case .recording: "Still listening. The transcript is written once the conversation is over."
        case .failed: conversation.canRetry ? "It couldn't be written down. It's tried again when Binders opens." : "It couldn't be written down."
        default: CaptureModels.mayInferInBackground
            ? "The transcript is written on this iPhone, right away while Binders is open, or while the phone charges."
            : "The transcript is written on this iPhone while Binders is open."
        }
    }

    private func share() {
        guard let conversation, let payload = conversation.payload(device: UIDevice.current.model) else { return }
        sharing = ConversationSharing.file(for: [payload]).map(SharedFile.init)
    }
}

/// Conversations as a Binders file, for AirDrop, Files or Mail, and what happens once one's been shared.
@MainActor
enum ConversationSharing {
    /// A Binders file in a temporary folder, ready for the share sheet.
    static func file(for conversations: [ConversationPayload]) -> URL? {
        guard !conversations.isEmpty, let data = try? BindersTransfer(conversations: conversations).encoded() else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(BindersTransfer.fileName(for: conversations))
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Shared: by AirDrop it went straight to a Mac, so it leaves the outbox. Anywhere else (Files, Mail), it still goes
    /// over the link too, and the Mac keeps it once.
    static func shared(_ ids: [UUID], via activity: UIActivity.ActivityType?, connection: MacConnection) {
        let airDrop = activity == .airDrop
        let via = airDrop ? "AirDrop" : (activity.map(describe) ?? "a file")
        for id in ids {
            CaptureStore.shared.update(id) {
                $0.sharedAt = Date()
                $0.sharedVia = via
                if airDrop { $0.state = .sent }
            }
            if airDrop { connection.forgetConversation(id) }
        }
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true))
    }

    private static func describe(_ activity: UIActivity.ActivityType) -> String {
        switch activity {
        case .mail: "Mail"
        case .message: "Messages"
        default: activity.rawValue.contains("DocumentManager") || activity.rawValue.contains("SaveToFiles") ? "Files" : "a file"
        }
    }
}

/// The system share sheet for one file, saying how it went.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let done: (UIActivity.ActivityType?, Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { activity, completed, _, _ in done(activity, completed) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A file on its way to the share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
