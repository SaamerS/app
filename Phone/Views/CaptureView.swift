import BindersKit
import SwiftUI

/// All-day capture: on and off, mute, what it heard today, and how it's doing. Audio stays on this iPhone; the Mac only
/// gets text.
struct CaptureView: View {
    @Environment(MacConnection.self) private var connection
    @State private var capture = CaptureSession.shared
    @State private var store = CaptureStore.shared
    @State private var processor = ConversationProcessor.shared
    @State private var models = CaptureModels.shared
    @State private var teaching = false
    @State private var voiceTaught = VoicePrint.isTaught
    @State private var sharing: SharedFile?
    @State private var sharingIDs: [UUID] = []
    /// Shown once, before All-day capture first listens.
    @AppStorage("captureNoticeAcknowledged") private var noticeAcknowledged = false
    @State private var askingFirst = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { capture.isOn }, set: { on in
                    if !on {
                        capture.turnOff()
                    } else if noticeAcknowledged {
                        Task { await capture.turnOn() }
                    } else {
                        askingFirst = true
                    }
                })) {
                    Label("All-day capture", systemImage: "waveform.and.mic")
                }
                .accessibilityIdentifier("captureToggle")
                if capture.isOn {
                    HStack {
                        Circle().fill(statusColor).frame(width: 9, height: 9)
                        Text(capture.status.title).accessibilityIdentifier("captureStatus")
                        if case .paused(let reason) = capture.status {
                            Text(reason).foregroundStyle(.secondary).lineLimit(2)
                        } else if capture.inConversation {
                            Text("in a conversation").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if case .paused = capture.status {
                            Button("Resume") { Task { await capture.resume() } }.buttonStyle(.bordered)
                        }
                    }
                    Button {
                        if capture.isMuted { capture.unmute() } else { capture.mute() }
                    } label: {
                        Label(capture.isMuted ? "Unmute" : "Mute", systemImage: capture.isMuted ? "mic.fill" : "mic.slash.fill")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(capture.isMuted ? .accentColor : .red)
                    .accessibilityIdentifier("captureMute")
                }
                if let error = capture.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                if waitingForNewerMac {
                    Label("Update Binders on your Mac to receive captures. They wait here until then.", systemImage: "arrow.down.circle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } footer: {
                if let mac = connection.mac {
                    Text("Binders listens for conversations, writes them down on this iPhone and sends only the text to \(mac.name). Audio never leaves this iPhone and is deleted once it's written down. Mute turns the microphone off completely.")
                } else {
                    Text("Binders listens for conversations and writes them down on this iPhone; once you pair a Mac, only the text goes to it. Audio never leaves this iPhone and is deleted once it's written down. Mute turns the microphone off completely.")
                }
            }

            Section("Today") {
                LabeledContent("Listening", value: hours(capture.onToday()))
                LabeledContent("Speech heard", value: minutes(capture.speechSeconds))
                LabeledContent("Captures", value: "\(today.count)")
                ForEach(capture.gaps) { gap in
                    Label("Paused \(time(gap.from))\(gap.to.map { "–" + time($0) } ?? "") · \(gap.reason)", systemImage: "pause.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if !today.isEmpty {
                Section {
                    ForEach(today) { row($0) }
                } header: {
                    Text("Captures today")
                } footer: {
                    if !waiting.isEmpty {
                        Button {
                            shareWaiting()
                        } label: {
                            Label(waiting.count == 1 ? "Send the waiting capture by AirDrop…" : "Send \(waiting.count) waiting captures by AirDrop…",
                                  systemImage: "square.and.arrow.up")
                        }
                        .font(.footnote)
                        .padding(.top, 4)
                    }
                }
            }

            ForEach(store.earlier(), id: \.day) { day in
                Section(day.day.formatted(.dateTime.weekday(.wide).month(.wide).day())) {
                    ForEach(day.conversations) { row($0) }
                }
            }

            Section {
                Picker("Language", selection: Binding(get: { models.language }, set: { models.language = $0 })) {
                    ForEach(CaptureModels.Language.allCases) { Text($0.title).tag($0) }
                }
                if models.isTranscriberDownloaded {
                    LabeledContent("Speech model", value: "On this iPhone")
                } else if models.downloading {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Downloading the speech model…")
                        ProgressView(value: models.progress)
                    }
                } else {
                    Button("Download the speech model (about 500 MB)") { Task { await models.download() } }
                        .disabled(!models.onWiFi)
                }
                if let error = models.downloadError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("Speech model")
            } footer: {
                Text("\(models.language.detail). It downloads once, over Wi-Fi only.\(models.isTranscriberDownloaded ? "" : " Until then, Apple's speech recognition on this iPhone writes things down where it can.")")
            }

            Section {
                Toggle("Notify me", isOn: Binding(get: { SuggestionCenter.shared.notifies }, set: { SuggestionCenter.shared.notifies = $0 }))
            } header: {
                Text("After a capture")
            } footer: {
                if connection.mac == nil {
                    Text("Tells you when captures are waiting to be written down. Once you pair a Mac, it also offers what you said you'd do for the binder's board, and answers to questions your binders hold.")
                } else {
                    Text("Once your Mac has written a capture up, it offers to put what you said you'd do on the binder's board, and answers a question you asked if your binders hold the answer. They wait on the capture either way; turn them on or off for good in Binders on your Mac, Settings → All-day capture. This iPhone also tells you when captures are waiting to be written down.")
                }
            }

            Section {
                if voiceTaught {
                    Label("Binders knows your voice", systemImage: "checkmark.circle")
                    Button("Forget My Voice", role: .destructive) {
                        VoicePrint.forget()
                        voiceTaught = false
                    }
                } else {
                    Button { teaching = true } label: { Label("Teach Binders Your Voice", systemImage: "person.wave.2") }
                }
            } header: {
                Text("Your voice")
            } footer: {
                Text("Read a short passage for twenty seconds, and your lines in a conversation are marked as you. The voice print stays in this iPhone's keychain; the recording isn't kept.")
            }

            #if DEBUG
            Section {
                Toggle("Keep audio for 24 hours", isOn: Binding(get: { processor.keepsAudio }, set: { processor.keepsAudio = $0 }))
                Button("Process Sample File") { processor.processSample() }
            } header: {
                Text("Developer")
            } footer: {
                Text("Debug builds only. Keeps each capture's audio on this iPhone for a day after it's written down, to check how well it was transcribed.")
            }
            #endif
        }
        .navigationTitle("All-day capture")
        .alert("Binders will write down conversations around you", isPresented: $askingFirst) {
            Button("Turn It On") {
                noticeAcknowledged = true
                Task { await capture.turnOn() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if connection.mac == nil {
                Text("All-day capture listens with this iPhone's microphone and writes down what's said, on this iPhone; once you pair a Mac, the text goes to it. Many places require everyone's consent before a conversation is recorded. Let the people around you know, and mute it or turn it off when someone objects.")
            } else {
                Text("All-day capture listens with this iPhone's microphone and sends what's said, as text, to your Mac. Many places require everyone's consent before a conversation is recorded. Let the people around you know, and mute it or turn it off when someone objects.")
            }
        }
        .macToolbar()
        .navigationDestination(for: CapturedConversationLink.self) { ConversationDetailView(id: $0.id) }
        .sheet(isPresented: $teaching, onDismiss: { voiceTaught = VoicePrint.isTaught }) { VoiceTeachingSheet() }
        .sheet(item: $sharing) { file in
            ShareSheet(url: file.url) { activity, completed in
                if completed { ConversationSharing.shared(sharingIDs, via: activity, connection: connection) }
                sharing = nil
            }
        }
        .onAppear { processor.processWaiting() }
    }

    private func row(_ conversation: CapturedConversation) -> some View {
        NavigationLink(value: CapturedConversationLink(id: conversation.id)) {
            ConversationCaptureRow(conversation: conversation, activity: processor.working == conversation.id ? processor.activity : nil,
                                   queuedLabel: queuedLabel)
        }
        .accessibilityIdentifier("conversationRow")
        .swipeActions {
            if conversation.isUnsent, conversation.state != .recording {
                Button("Delete", role: .destructive) {
                    processor.forget(conversation.id)
                    connection.forgetConversation(conversation.id)
                    store.delete(conversation.id)
                }
            }
        }
    }

    /// Written down, and not with the Mac yet.
    private var waiting: [CapturedConversation] {
        store.conversations.filter { $0.state == .queued && $0.transcript != nil }
    }

    /// Everything waiting, in one Binders file, for when the Mac isn't reachable over the network.
    private func shareWaiting() {
        let device = UIDevice.current.model
        let conversations = waiting
        sharingIDs = conversations.map(\.id)
        sharing = ConversationSharing.file(for: conversations.compactMap { $0.payload(device: device) }).map(SharedFile.init)
    }

    private var today: [CapturedConversation] { store.today() }

    private var waitingForNewerMac: Bool {
        connection.mac != nil && !connection.takesConversations && connection.outbox.contains { $0.tool == PendingSave.conversation }
    }

    /// Written down, and where it is now.
    private var queuedLabel: String {
        if connection.mac == nil { return "On this iPhone" }
        return connection.takesConversations ? "Waiting for Mac" : "Waiting for a newer Mac app"
    }

    private var statusColor: Color {
        switch capture.status {
        case .listening: .red
        case .muted: .gray
        case .paused: .orange
        default: .yellow
        }
    }

    private func hours(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private func minutes(_ seconds: TimeInterval) -> String { "\(Int((seconds / 60).rounded())) min" }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

struct CapturedConversationLink: Hashable {
    let id: UUID
}

private struct ConversationCaptureRow: View {
    let conversation: CapturedConversation
    let activity: String?
    let queuedLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(conversation.started.formatted(date: .omitted, time: .shortened))–\(conversation.ended.formatted(date: .omitted, time: .shortened))")
                    .font(.body.monospacedDigit())
                Spacer()
                Text(state).font(.footnote).foregroundStyle(stateColor)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private var state: String {
        switch conversation.state {
        case .recording: "Recording"
        case .recorded: "Waiting"
        case .transcribing: "Transcribing"
        case .labelling: "Labelling speakers"
        case .queued: queuedLabel
        case .sent: conversation.sharedVia == "AirDrop" ? "AirDropped" : "Sent"
        case .failed: conversation.transcript == nil ? "Not written down" : "Not sent"
        }
    }

    private var stateColor: Color {
        switch conversation.state {
        case .sent: .green
        case .failed: .red
        case .queued: .orange
        default: .secondary
        }
    }

    private var detail: String {
        var parts = ["\(max(1, Int((conversation.duration / 60).rounded()))) min"]
        if let words = conversation.words { parts.append("\(words) words") }
        if let first = conversation.transcript?.first?.text { parts.append("“\(first)”") }
        if let activity {
            parts.append(activity)
        } else if let error = conversation.error {
            parts.append(error)
        } else if conversation.state == .recorded {
            parts.append(CaptureModels.mayInferInBackground ? "written down while Binders is open, or while the phone charges"
                                                            : "written down while Binders is open")
        }
        if conversation.canRetry { parts.append("tried again when Binders opens") }
        if conversation.state == .sent || conversation.audioDeleted { parts.append("audio deleted") }
        else if conversation.keepAudioUntil != nil { parts.append("audio kept for a day") }
        return parts.joined(separator: " · ")
    }
}

private struct VoiceTeachingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var teaching = VoiceTeaching()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Read this out loud, at your normal pace, somewhere quiet.").foregroundStyle(.secondary)
                Text(VoiceTeaching.passage).font(.title3)
                switch teaching.phase {
                case .ready:
                    Button { Task { await teaching.start() } } label: {
                        Label("Start Reading", systemImage: "mic.fill").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                case .listening:
                    ProgressView(value: teaching.progress) { Text("Listening…") }
                case .learning:
                    ProgressView("Learning your voice…")
                case .done:
                    Label("Done. Your lines will be marked as you.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Try Again") { Task { await teaching.start() } }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Teach Binders your voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(teaching.phase == .done ? "Done" : "Cancel") {
                        teaching.cancel()
                        dismiss()
                    }
                }
            }
        }
    }
}

/// The row on the home screen: is it on, and how's it going.
struct CaptureStatusLabel: View {
    @State private var capture = CaptureSession.shared
    @State private var store = CaptureStore.shared

    var body: some View {
        HStack {
            Label("All-day capture", systemImage: "waveform.and.mic")
            Spacer()
            Text(summary).foregroundStyle(capture.isListening ? .red : .secondary)
        }
    }

    private var summary: String {
        guard capture.isOn else { return "Off" }
        let count = store.today().count
        return capture.status.title + (count > 0 ? " · \(count)" : "")
    }
}
