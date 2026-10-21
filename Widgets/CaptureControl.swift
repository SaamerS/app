import AppIntents
import BindersKit
import SwiftUI
import WidgetKit

/// All-day capture in Control Center, on the Lock Screen and on the Action Button: on listens, off mutes. From off it
/// turns capture on only once it was turned on in the app (with its reminder to let people know) and with the iPhone
/// unlocked; otherwise a notification says what to do. Red while it listens, the one sign it's on; otherwise it says what
/// capture is: muted, paused or off.
@available(iOS 18.0, *)
struct CaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.binders.app.capture", provider: CaptureControlValue()) { phase in
            ControlWidgetToggle("All-day Capture", isOn: phase == "listening", action: SetCaptureIntent()) { on in
                // Just turned off from listening, it's muted.
                let look = CaptureLook(phase: on ? "listening" : phase == "listening" ? "muted" : phase)
                Label(look.word, systemImage: look.symbol)
            }
            .tint(Palette.live)
        }
        .displayName("All-day Capture")
        .description("Mute All-day capture, or listen again.")
    }
}

/// Capture's phase as the app last wrote it: off, listening, muted or paused.
@available(iOS 18.0, *)
struct CaptureControlValue: ControlValueProvider {
    var previewValue: String { "listening" }

    func currentValue() async throws -> String {
        WidgetSnapshot.read().capture
    }
}
