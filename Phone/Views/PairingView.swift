import BindersKit
import SwiftUI

/// What an iPhone without a Mac opens on: how to pair one, and what works on this iPhone alone in the meantime.
struct PairingView: View {
    @Environment(MacConnection.self) private var connection
    @State private var dictating = false
    @State private var settingUpKeyboard = false
    @State private var path = NavigationPath()
    @State private var capture = CaptureSession.shared
    @State private var store = CaptureStore.shared
    /// `-open` is honored once, so Back from what it opened stays here.
    private static var openedForDevelopment = false

    /// Where it goes from here. All by value, as the capture screen pushes its captures by value: SwiftUI loses track
    /// of a stack that mixes those with other kinds of push.
    enum Place: Hashable { case capture }

    var body: some View {
        NavigationStack(path: $path) { content }
            .sheet(isPresented: $dictating) { DictationSheet() }
            .sheet(isPresented: $settingUpKeyboard) { KeyboardSetupView() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                KeyboardMicBanner(onCard: true)
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Pair with your Mac")
                        .font(Typeface.title(.largeTitle))
                        .foregroundStyle(Palette.ink)
                    Text("Pair with Binders on your Mac to have your to-dos, notes and meetings here, and to ask about them. It all stays on your own devices.")
                        .foregroundStyle(Palette.muted)
                }
                VStack(alignment: .leading, spacing: 16) {
                    step(1, "On your Mac, open Binders, then Settings › iPhone, and turn it on.")
                    step(2, "Click Pair an iPhone.")
                    step(3, "Point your iPhone's Camera at the code, and tap the Binders link.")
                }
                if connection.state == .connecting {
                    HStack(spacing: 10) {
                        ProgressView().tint(Palette.muted)
                        Text("Pairing…").foregroundStyle(Palette.muted)
                    }
                }
                if let error = connection.pairingError {
                    ProblemLabel(error)
                }
                Button {
                    if let text = UIPasteboard.general.string, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        Task { await connection.pair(with: url) }
                    }
                } label: {
                    Label("Paste a Pairing Link", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                Text("Away from home, your iPhone reaches your Mac through your VPN (Covee, Tailscale or another), if both use it. The Mac needs to be awake.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                onThisIPhone
                // Before a Mac is paired too, as in Your Mac after.
                HStack {
                    Text("Appearance").foregroundStyle(Palette.ink)
                    Spacer()
                    AppearancePicker().pickerStyle(.menu)
                }
                .surfaceCard(padding: 12)
                Link("Privacy Policy", destination: URL(string: "https://binders.io/privacy.html")!)
                    .font(.footnote)
            }
            .padding(24)
        }
        .screenGround()
        .navigationTitle("Binders")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Place.self) { _ in CaptureView() }
        .onAppear(perform: openForDevelopment)
        // A notification's conversation, tapped, as on the paired home.
        .onChange(of: PhoneNavigation.shared.pendingConversation, initial: true) { _, id in
            guard let id else { return }
            PhoneNavigation.shared.pendingConversation = nil
            path = NavigationPath()
            path.append(Place.capture)
            path.append(CapturedConversationLink(id: id))
        }
        // The capture screen, from the Live Activity or a capture notice: it works without a Mac too.
        .onChange(of: PhoneNavigation.shared.pendingCapture, initial: true) { _, open in
            guard open else { return }
            PhoneNavigation.shared.pendingCapture = false
            path = NavigationPath()
            path.append(Place.capture)
        }
    }

    /// For development, as on the paired home: `-open capture|dictate|keyboard` opens that straight away.
    private func openForDevelopment() {
        #if DEBUG
        guard !Self.openedForDevelopment else { return }
        Self.openedForDevelopment = true
        switch UserDefaults.standard.string(forKey: "open") {
        case "capture": path.append(Place.capture)
        case "dictate": dictating = true
        case "keyboard": settingUpKeyboard = true
        default: break
        }
        #endif
    }

    /// Dictation, the keyboard and All-day capture all work without a Mac: what they write waits here until one is paired.
    private var onThisIPhone: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On this iPhone").font(Typeface.title(.headline)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            Button { dictating = true } label: {
                AloneRow(symbol: "mic.fill", title: "Dictate", detail: "Say something, then copy it or share it.")
            }
            .accessibilityIdentifier("aloneDictate")
            Button { settingUpKeyboard = true } label: {
                AloneRow(symbol: "keyboard", title: "Dictate in Any App", detail: "The Binders keyboard writes down what you say, on this iPhone.")
            }
            .accessibilityIdentifier("aloneKeyboard")
            NavigationLink(value: Place.capture) {
                AloneRow(symbol: "waveform.and.mic", title: "All-day capture", detail: captureDetail)
            }
            .accessibilityIdentifier("aloneCapture")
        }
        .buttonStyle(.plain)
    }

    /// Whether it's on, as on the paired home.
    private var captureDetail: String {
        guard capture.isOn else { return "Writes your conversations down on this iPhone. Audio never leaves it." }
        let count = store.today().count
        return capture.status.title + (count > 0 ? " · \(count) today" : "")
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(Typeface.count(.subheadline))
                .foregroundStyle(Palette.accentText)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.accent.opacity(0.15)))
            Text(text).foregroundStyle(Palette.ink)
        }
    }
}

/// One thing that works without a Mac, as a tappable row.
private struct AloneRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(detail).font(.footnote).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.faint)
                .accessibilityHidden(true)
        }
        .surfaceCard()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Details about the paired Mac, and a way to forget it.
struct MacSheet: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Mac", value: connection.mac?.name ?? "—")
                    LabeledContent("Status", value: status)
                    if !connection.isConnected, let seen = connection.lastSeen?.seenPhrase() {
                        LabeledContent("Last seen") { Text(seen.prefix(1).uppercased() + seen.dropFirst()).monospacedDigit() }
                    }
                } footer: {
                    // Why it's out of reach, when that's something to act on, and what each address did.
                    if !connection.isConnected {
                        VStack(alignment: .leading, spacing: 6) {
                            if let reason = connection.offlineReason { ProblemLabel(reason) }
                            if let tried = LinkDial.summary(connection.lastAttempts, again: connection.state == .connecting) { Text(tried) }
                        }
                    }
                }
                .surfaceRows()
                if connection.mac != nil {
                    MacAddressesSection()
                }
                Section {
                    if !connection.isConnected {
                        Button("Try Again") { connection.retryNow() }
                    }
                    Button("Unpair This iPhone", role: .destructive) { confirmUnpair = true }
                } footer: {
                    Text("Unpairing deletes this iPhone's key. To remove it on the Mac too, use Settings › iPhone there.")
                }
                .surfaceRows()
                // How Binders looks here: dark unless you choose otherwise, as on the Mac.
                Section("This iPhone") {
                    AppearancePicker()
                }
                .surfaceRows()
                Section {
                    Link("Privacy Policy", destination: URL(string: "https://binders.io/privacy.html")!)
                }
                .surfaceRows()
            }
            .listGround()
            .navigationTitle("Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Unpair this iPhone from \(connection.mac?.name ?? "your Mac")?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    connection.unpair()
                    dismiss()
                }
            }
        }
    }

    private var status: String {
        switch connection.state {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .unpaired: "Not paired"
        // A reason to act on is said under the section, in full.
        case .offline(let reason): connection.offlineReason == nil ? reason : "Offline"
        }
    }
}
