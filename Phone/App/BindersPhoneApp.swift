import SwiftUI
import UserNotifications

@main
struct BindersPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @State private var connection: MacConnection
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Made here rather than when a window appears: a background launch, to process conversations while the phone
        // charges, has no window.
        let connection = MacConnection()
        _connection = State(initialValue: connection)
        CaptureWiring.connect(connection)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(connection)
                .onOpenURL { url in
                    // The Binders keyboard opens binders://keyboard to have the app listen for it.
                    if url == KeyboardBridge.listenURL {
                        // Opened cold by the keyboard, this can come before .task.
                        KeyboardListener.shared.connection = connection
                        KeyboardListeningWindow.show()
                        Task { await KeyboardListener.shared.listen() }
                    } else {
                        // The Camera opens binders://pair links from the QR code on the Mac.
                        Task { await connection.pair(with: url) }
                    }
                }
                .task {
                    KeyboardListener.shared.connection = connection
                    #if DEBUG
                    // For development: `-unpair YES` forgets the Mac on launch, to see the iPhone on its own.
                    if UserDefaults.standard.bool(forKey: "unpair") { connection.unpair() }
                    #endif
                    // For development: `-pairURL <link>` pairs on launch, as the Simulator has no camera.
                    if let link = UserDefaults.standard.string(forKey: "pairURL"), let url = URL(string: link) {
                        await connection.pair(with: url)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            connection.sceneChanged(active: phase == .active)
            if phase == .active {
                ConversationProcessor.shared.appBecameActive()
            } else {
                ConversationProcessor.shared.appLeftForeground(toBackground: phase == .background)
            }
        }
    }
}

struct RootView: View {
    @Environment(MacConnection.self) private var connection
    @State private var capture = CaptureSession.shared

    var body: some View {
        Group {
            if connection.mac == nil || showsPairingForDevelopment {
                // Without a Mac, what works on this iPhone alone: dictation, the keyboard and All-day capture.
                NavigationStack { PairingView() }
            } else {
                BindersView()
            }
        }
        // All-day capture never turns itself back on after a quit: it asks.
        .alert("Resume all-day capture?", isPresented: Binding(get: { capture.askToResume },
                                                                 set: { if !$0 { capture.askToResume = false } })) {
            Button("Resume") { Task { await capture.turnOn() } }
            Button("Not Now", role: .cancel) { capture.declineResume() }
        } message: {
            Text("It was on when Binders last closed.")
        }
    }

    /// For development, on a Simulator that's paired: `-showPairing YES` shows the screen an unpaired iPhone opens on.
    private var showsPairingForDevelopment: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "showPairing")
        #else
        false
        #endif
    }
}

/// Puts All-day capture's pieces together as the app starts.
@MainActor
enum CaptureWiring {
    static func connect(_ connection: MacConnection) {
        let processor = ConversationProcessor.shared
        processor.connection = connection
        connection.onConversationSent = { id in CaptureStore.shared.update(id) { $0.state = .sent } }
        connection.onConversationRefused = { id in
            CaptureStore.shared.update(id) {
                $0.state = .failed
                $0.error = "Your Mac couldn't read this capture."
            }
        }
        CaptureSession.shared.onConversationClosed = { processor.conversationClosed($0) }
        processor.recover()
        // What the Mac offers once it has written a conversation up, asked for whenever the Mac's meetings change.
        let suggestions = SuggestionCenter.shared
        suggestions.connection = connection
        connection.onMeetingsChanged = { Task { await suggestions.refresh() } }
        // While capture listens, stay connected, so those offers arrive while you're out.
        keep { CaptureSession.shared.isListening } changing: { connection.keepsConnected = $0 }
        #if DEBUG
        // For development, as the Simulator can't listen: `-processSample YES` runs the sample recording through it all.
        if UserDefaults.standard.bool(forKey: "processSample") { processor.processSample() }
        // `-openConversation latest` opens the newest conversation.
        if UserDefaults.standard.string(forKey: "openConversation") == "latest" {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                PhoneNavigation.shared.pendingConversation = CaptureStore.shared.conversations.first?.id
            }
        }
        #endif
    }
}

/// Calls `changing` with the value now and whenever it changes.
@MainActor
private func keep<T: Equatable>(_ value: @escaping @MainActor () -> T, changing: @escaping @MainActor (T) -> Void) {
    let now = withObservationTracking { value() } onChange: {
        Task { @MainActor in keep(value, changing: changing) }
    }
    changing(now)
}

/// The app's delegate, for what SwiftUI doesn't do: the background task that processes conversations while the phone
/// charges, and the "All-day capture paused" notification.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        ConversationProcessor.setUp()
        UNUserNotificationCenter.current().delegate = self
        SuggestionCenter.registerCategories()
        return true
    }

    /// Tapping "All-day capture paused" brings it back. A suggestion: Add to Board or Not Now say so to the Mac; a tap opens
    /// the conversation.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        if content.categoryIdentifier == CaptureSession.pausedCategory {
            await CaptureSession.shared.resume()
            return
        }
        guard let suggestion = content.userInfo["suggestion"] as? String else { return }
        let conversation = (content.userInfo["conversation"] as? String).flatMap(UUID.init(uuidString:))
        switch response.actionIdentifier {
        case SuggestionCenter.add:
            let message = await SuggestionCenter.shared.act(suggestion, accept: true)
            let done = UNMutableNotificationContent()
            done.body = message
            try? await center.add(UNNotificationRequest(identifier: "done-\(suggestion)", content: done, trigger: nil))
        case SuggestionCenter.notNow, UNNotificationDismissActionIdentifier:
            await SuggestionCenter.shared.act(suggestion, accept: false)
        default:
            await MainActor.run { PhoneNavigation.shared.pendingConversation = conversation }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

/// The dot and name in every screen's toolbar: is the Mac there? Tapping it shows the details. Nothing without a Mac.
struct MacStatusButton: View {
    @Environment(MacConnection.self) private var connection
    @State private var showing = false

    var body: some View {
        if connection.mac != nil {
            Button { showing = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(label).font(.footnote.weight(.medium)).lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Mac: \(label)")
            .sheet(isPresented: $showing) { MacSheet() }
        }
    }

    private var color: Color {
        switch connection.state {
        case .connected: .green
        case .connecting: .yellow
        default: .gray
        }
    }

    private var label: String {
        switch connection.state {
        case .connected: connection.mac?.name ?? "Mac"
        case .connecting: "Connecting…"
        default: "Offline"
        }
    }
}

extension View {
    func macToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) { MacStatusButton() }
        }
    }
}

/// Shown when a screen has something from last time but the Mac isn't reachable.
struct OfflineBanner: View {
    @Environment(MacConnection.self) private var connection

    var body: some View {
        if !connection.isConnected {
            Label("Showing what you had. \(connection.mac?.name ?? "Your Mac") is out of reach.", systemImage: "wifi.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
