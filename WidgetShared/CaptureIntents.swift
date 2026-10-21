import AppIntents
import Foundation

/// What the Live Activity's buttons and the control ask of All-day capture. They run in the app, which hands them on.
enum CaptureAction: String, Sendable {
    case mute, listen, wrapUp
}

@MainActor
enum CaptureControls {
    /// Set by the app as it starts: the widget extension itself never runs these.
    static var handler: ((CaptureAction) async -> Void)?
}

/// Mute, from the Live Activity: the microphone off, capture still on.
struct MuteCaptureIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute All-day Capture"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await CaptureControls.handler?(.mute)
        return .result()
    }
}

/// Wrap up, from the Live Activity: what's being heard closes now and is written down.
struct WrapUpCaptureIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Wrap Up the Capture"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await CaptureControls.handler?(.wrapUp)
        return .result()
    }
}

/// Listen again, from the Live Activity or the Lock Screen: the only way iOS lets an app start its microphone from the
/// background, which is why it records audio. Never offered to Shortcuts or automations: capture never turns itself on.
@available(iOS 18.0, *)
struct ListenCaptureIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Listen Again"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await CaptureControls.handler?(.listen)
        return .result()
    }
}

/// The Control Center, Lock Screen and Action Button control: on listens, off mutes (capture stays on). Your own tap
/// each time; never offered to Shortcuts or automations.
@available(iOS 18.0, *)
struct SetCaptureIntent: SetValueIntent, AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "All-day Capture"
    static let isDiscoverable = false

    @Parameter(title: "Listening")
    var value: Bool

    func perform() async throws -> some IntentResult {
        await CaptureControls.handler?(value ? .listen : .mute)
        return .result()
    }
}
