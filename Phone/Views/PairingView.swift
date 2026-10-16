import SwiftUI

/// What an iPhone without a Mac opens on: how to pair one, and what works on this iPhone alone in the meantime.
struct PairingView: View {
    @Environment(MacConnection.self) private var connection
    @State private var dictating = false
    @State private var settingUpKeyboard = false
    @State private var capturing = false
    @State private var capture = CaptureSession.shared
    @State private var store = CaptureStore.shared
    /// `-open` is honored once, so Back from what it opened stays here.
    private static var openedForDevelopment = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                KeyboardMicBanner()
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Pair with your Mac")
                        .font(.largeTitle.bold())
                    Text("Pair with Binders on your Mac to have your to-dos, notes and meetings here, and to ask about them. It all stays on your own devices.")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 16) {
                    step(1, "On your Mac, open Binders, then Settings › iPhone, and turn it on.")
                    step(2, "Click Pair an iPhone.")
                    step(3, "Point your iPhone's Camera at the code, and tap the Binders link.")
                }
                if connection.state == .connecting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Pairing…")
                    }
                }
                if let error = connection.pairingError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button {
                    if let text = UIPasteboard.general.string, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        Task { await connection.pair(with: url) }
                    }
                } label: {
                    Label("Paste a pairing link", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                Text("Away from home, your iPhone reaches your Mac through Tailscale, if both use it. The Mac needs to be awake.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                onThisIPhone
                Link("Privacy Policy", destination: URL(string: "https://binders.io/privacy.html")!)
                    .font(.footnote)
            }
            .padding(24)
        }
        .navigationTitle("Binders")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $capturing) { CaptureView() }
        .sheet(isPresented: $dictating) { DictationSheet() }
        .sheet(isPresented: $settingUpKeyboard) { KeyboardSetupView() }
        .onAppear(perform: openForDevelopment)
    }

    /// For development, as on the paired home: `-open capture|dictate|keyboard` opens that straight away.
    private func openForDevelopment() {
        #if DEBUG
        guard !Self.openedForDevelopment else { return }
        Self.openedForDevelopment = true
        switch UserDefaults.standard.string(forKey: "open") {
        case "capture": capturing = true
        case "dictate": dictating = true
        case "keyboard": settingUpKeyboard = true
        default: break
        }
        #endif
    }

    /// Dictation, the keyboard and All-day capture all work without a Mac: what they write waits here until one is paired.
    private var onThisIPhone: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On this iPhone").font(.headline).accessibilityAddTraits(.isHeader)
            Button { dictating = true } label: {
                AloneRow(symbol: "mic.fill", title: "Dictate", detail: "Say something, then copy it or share it.")
            }
            .accessibilityIdentifier("aloneDictate")
            Button { settingUpKeyboard = true } label: {
                AloneRow(symbol: "keyboard", title: "Dictate in Any App", detail: "The Binders keyboard writes down what you say, on this iPhone.")
            }
            .accessibilityIdentifier("aloneKeyboard")
            NavigationLink { CaptureView() } label: {
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
                .font(.subheadline.bold())
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text)
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
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
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
                }
                if let mac = connection.mac {
                    Section("Addresses") {
                        ForEach(mac.hosts, id: \.self) { host in
                            HStack {
                                Text(host).monospacedDigit()
                                Spacer()
                                if host == mac.lastHost { Text("last used").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Section {
                    if !connection.isConnected {
                        Button("Try again") { Task { await connection.connect() } }
                    }
                    Button("Unpair this iPhone", role: .destructive) { confirmUnpair = true }
                } footer: {
                    Text("Unpairing deletes this iPhone's key. To remove it on the Mac too, use Settings › iPhone there.")
                }
                Section {
                    Link("Privacy Policy", destination: URL(string: "https://binders.io/privacy.html")!)
                }
            }
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
        case .offline(let reason): reason
        }
    }
}
