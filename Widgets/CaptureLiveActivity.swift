import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// All-day capture while it's on: listening, muted or paused, how long, what's been filed and what needs you, with Mute
/// and Wrap Up. Doubles as the sign that the microphone is on, so it's red only while it is.
struct CaptureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CaptureActivityAttributes.self) { context in
            LockScreenCapture(state: context.state, stale: context.isStale)
                .padding(14)
                .activityBackgroundTint(Palette.surface)
                .activitySystemActionForegroundColor(Palette.ink)
                .widgetURL(URL(string: "binders://capture"))
        } dynamicIsland: { context in
            let state = context.state
            let look = CaptureLook(phase: state.phase, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(look.word, systemImage: look.symbol)
                        .font(Typeface.title(.headline))
                        .widgetInk(look.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .island()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if look.live {
                        Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
                            .font(Typeface.time(.headline))
                            .widgetInk(Palette.ink)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 70, alignment: .trailing)
                            .island()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if context.isStale {
                            Text("Open Binders to check it's listening.").font(.subheadline).widgetInk(Palette.muted, or: .secondary)
                        } else {
                            CaptureCounts(state: state)
                        }
                        CaptureButtons(state: state)
                    }
                    .island()
                }
            } compactLeading: {
                Image(systemName: look.symbol).widgetInk(look.tint)
                    .accessibilityLabel(look.word)
                    .island()
            } compactTrailing: {
                CompactCount(state: state).island()
            } minimal: {
                Image(systemName: look.symbol).widgetInk(look.tint)
                    .accessibilityLabel(look.word)
                    .island()
            }
            .keylineTint(look.live ? Palette.live : nil)
            .widgetURL(URL(string: "binders://capture"))
        }
    }
}

/// On the Lock Screen: what capture is doing and for how long, the counts, and the buttons.
private struct LockScreenCapture: View {
    let state: CaptureActivityAttributes.ContentState
    let stale: Bool

    private var look: CaptureLook { CaptureLook(phase: state.phase, stale: stale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    if stale {
                        Text("All-day capture may have stopped")
                    } else {
                        Text("All-day capture · \(Text(look.word).foregroundStyle(look.tint))")
                    }
                } icon: {
                    Image(systemName: look.symbol).widgetInk(look.tint)
                }
                .font(Typeface.title(.headline))
                .widgetInk(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel(stale ? "All-day capture may have stopped" : "All-day capture, \(look.word)")
                Spacer(minLength: 8)
                if look.live {
                    // Room for "10:00:00": a timer takes all the width it's given.
                    Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
                        .font(Typeface.time(.subheadline))
                        .widgetInk(Palette.muted, or: .secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 70, alignment: .trailing)
                }
            }
            if stale {
                Text("Open Binders to check it's listening.").font(.subheadline).widgetInk(Palette.muted, or: .secondary)
            } else {
                CaptureCounts(state: state)
                CaptureButtons(state: state)
            }
        }
    }
}

/// "3 filed · 1 needs you" as counts: rounded and heavy, what needs you in amber, and why it's paused after them. Counts
/// and short reasons only: never what was said.
private struct CaptureCounts: View {
    let state: CaptureActivityAttributes.ContentState

    private var reason: String? { state.phase == "paused" ? state.reason : nil }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Tally(value: state.filed, label: "filed")
                if state.needsYou > 0 {
                    Tally(value: state.needsYou, label: state.needsYou == 1 ? "needs you" : "need you", tint: Palette.needsYou)
                }
            }
            if let reason {
                Text("· \(reason)").font(.subheadline).widgetInk(Palette.muted, or: .secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// The same, as VoiceOver reads it.
    private var spoken: String {
        var parts = ["\(state.filed) filed"]
        if state.needsYou > 0 { parts.append("\(state.needsYou) \(state.needsYou == 1 ? "needs" : "need") you") }
        if let reason { parts.append(reason) }
        return parts.joined(separator: ", ")
    }
}

/// The Dynamic Island's one number: what needs you, in amber, or else what's been filed today.
private struct CompactCount: View {
    let state: CaptureActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.needsYou > 0 {
                Text("\(state.needsYou)").widgetInk(Palette.needsYou).rollingCount(state.needsYou)
                    .accessibilityLabel("\(state.needsYou) \(state.needsYou == 1 ? "needs" : "need") you")
            } else {
                Text("\(state.filed)").widgetInk(Palette.ink).rollingCount(state.filed)
                    .accessibilityLabel("\(state.filed) filed")
            }
        }
        .font(Typeface.count(.body))
    }
}

/// Mute and Wrap Up while listening, in ink; Listen, the brand's button, when muted or paused. Mute and Wrap Up work with
/// the iPhone locked.
private struct CaptureButtons: View {
    let state: CaptureActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            if state.phase == "listening" {
                Button(intent: MuteCaptureIntent()) { Label("Mute", systemImage: "mic.slash") }
                Button(intent: WrapUpCaptureIntent()) { Label("Wrap Up", systemImage: "checkmark.circle") }
            } else if #available(iOS 18.0, *) {
                Button(intent: ListenCaptureIntent()) { Label("Listen", systemImage: "waveform") }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
        }
        .buttonStyle(.bordered)
        .tint(Palette.ink)
        .font(.subheadline.weight(.semibold))
    }
}

private extension View {
    /// The Dynamic Island is black in either appearance, so the tokens take their dark values there.
    func island() -> some View { environment(\.colorScheme, .dark) }
}
