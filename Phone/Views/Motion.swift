import BindersKit
import SwiftUI
import UIKit

// How Binders moves and feels on the iPhone. Filing is the signature: a new item drops into Today with a short spring
// while its binder's chip slides in. Counts roll, the listening glyph moves only while speech is heard, and under Reduce
// Motion everything crossfades. By touch: success when something is filed or approved, a warning when something newly
// needs you while Binders is open, and nothing for what happens in the background.

// MARK: - Haptics

/// What the iPhone says by touch, the one way it says it everywhere: success when something is filed (a moment acted on,
/// a capture filed, a card, a to-do or a note added) or approved (an agent's request, a card from Review to Done), a
/// warning when something newly needs you, and a light tap for a change you make by hand. Only with Binders in front:
/// nothing for what happens in the background. The root view plays them, with `.sensoryFeedback` (`hapticFeedback()`).
@MainActor
@Observable
final class Haptics {
    static let shared = Haptics()

    private(set) var successes = 0
    private(set) var warnings = 0
    private(set) var taps = 0
    /// What waits on you, look after look.
    @ObservationIgnored private var waiting = NewlyWaiting()
    /// Several successes at once (a refresh that brings three outcomes) are one.
    @ObservationIgnored private var successPacing = TouchPacing(apart: 0.6)
    /// The question that rings and the card it puts in Needs you are one thing: warnings close together are one.
    @ObservationIgnored private var warningPacing = TouchPacing(apart: 5)

    private init() {}

    /// Filed or approved.
    func success() {
        guard inFront, successPacing.allows(at: Date()) else { return }
        successes &+= 1
    }

    /// A change you made by hand that isn't filing or approving: a to-do ticked, a card moved or handed over, a decline.
    func tap() {
        guard inFront else { return }
        taps &+= 1
    }

    /// Something newly waits on you: a question or a request for your approval just rang, or something joined Needs you.
    func newlyNeedsYou() {
        guard inFront, warningPacing.allows(at: Date()) else { return }
        warnings &+= 1
    }

    /// What waits on you now, by what it is (`NeedsYouSection.items`), from wherever it changes: anything new since the
    /// last look warns (NewlyWaiting). Looks in the background only keep up, so what came meanwhile doesn't warn later.
    func waits(_ items: Set<String>?) {
        if waiting.look(items) { newlyNeedsYou() }
    }

    private var inFront: Bool { UIApplication.shared.applicationState == .active }
}

private struct HapticFeedback: ViewModifier {
    @State private var haptics = Haptics.shared

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.success, trigger: haptics.successes)
            .sensoryFeedback(.warning, trigger: haptics.warnings)
            .sensoryFeedback(.impact(weight: .light), trigger: haptics.taps)
    }
}

extension View {
    /// Plays what `Haptics` says, for the whole app: once, at its root.
    func hapticFeedback() -> some View {
        modifier(HapticFeedback())
    }
}

// MARK: - Counts

private struct RollingCount<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value
    /// The number, so the digits roll the right way; nil for a line of counts, which rolls each digit that changes.
    let number: Double?

    func body(content: Content) -> some View {
        content
            .contentTransition(transition)
            .animation(Motion.filing(reduceMotion: reduceMotion), value: value)
    }

    private var transition: ContentTransition {
        if reduceMotion { return .opacity }
        if let number { return .numericText(value: number) }
        return .numericText()
    }
}

extension View {
    /// A count whose digits roll as it changes; under Reduce Motion it crossfades.
    func rollingCount(_ value: Int) -> some View {
        modifier(RollingCount(value: value, number: Double(value)))
    }

    /// A line of counts or a time ("5 · 3 filed", "2 h 5 min", "12 of 40"), rolling as it changes.
    func rollingCount(_ line: String) -> some View {
        modifier(RollingCount(value: line, number: nil))
    }
}

// MARK: - Filing

/// A row that came while its screen was showing drops in from just above, with the filing spring; one that was there as
/// the screen opened is simply there. A row's own state remembers it has shown, so it drops in once: again only if it
/// leaves the list and comes back. Under Reduce Motion it fades in.
private struct Arrival<ID: Hashable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: ID
    /// What the list held as its screen opened, until each of those has shown; nil before the list's first look.
    @Binding var present: Set<ID>?
    /// What it shows now: at a first look as the screen opens, all of it was there already.
    let showing: () -> Set<ID>
    /// When the screen first showed; nil takes every first look as its opening.
    let since: Date?
    /// Above its place, about to drop in; false once it has, or when it was there all along. Nil until it appears.
    @State private var above: Bool?

    func body(content: Content) -> some View {
        let up = above ?? isNew
        content
            .opacity(up ? 0 : 1)
            .offset(y: up && !reduceMotion ? -14 : 0)
            .onAppear {
                guard above == nil else { return }
                let new = isNew
                if present == nil { present = opening ? showing() : [] }
                present?.remove(id)
                above = new
                guard new else { return }
                withAnimation(Motion.filing(reduceMotion: reduceMotion)) { above = false }
            }
    }

    /// The screen is still opening: what shows now was already there (from the copy kept from last time, say).
    private var opening: Bool { since.map { Date().timeIntervalSince($0) < 1 } ?? true }

    private var isNew: Bool { present.map { !$0.contains(id) } ?? !opening }
}

extension View {
    /// Drops in, as filing does, when it joined its list while the screen showed. `present` is the list's memory of what
    /// it held as the screen opened (nil to start), `showing` what it shows now, and `since` when the screen first showed.
    func arrival<ID: Hashable>(_ id: ID, present: Binding<Set<ID>?>, showing: @escaping () -> Set<ID>, since: Date?) -> some View {
        modifier(Arrival(id: id, present: present, showing: showing, since: since))
    }
}

/// A binder as something filed in it shows it: the binder's own colour and its name, like the tab on a binder.
struct BinderChip: View {
    let name: String
    /// Nil for a binder this iPhone hasn't heard of yet: plain.
    let tint: BinderTint?

    var body: some View {
        let colour = tint?.base ?? Palette.faint
        HStack(spacing: 4) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(name).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint?.text ?? Palette.muted)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(colour.opacity(0.14)))
    }
}

/// Where something on Today was filed, once it is: its binder's chip, sliding in from the side with the filing spring
/// (fading in under Reduce Motion). Its line already says where, so VoiceOver reads that rather than the chip.
struct FiledChip: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil until it's filed.
    let binder: String?

    var body: some View {
        ZStack {
            if let binder {
                // Its own width, up to a point, so a long binder name never squeezes the line beside it.
                BinderChip(name: binder, tint: BinderColors.tint(binder, connection: connection))
                    .frame(maxWidth: 140)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.filing(reduceMotion: reduceMotion), value: binder)
        .accessibilityHidden(true)
    }
}

// MARK: - Listening

/// All-day capture's glyph on its screen. While it listens, the waveform moves only while speech is heard, and holds
/// still in the quiet; otherwise it's the state's own glyph, still. Capture is asked whether it hears speech four times a
/// second, and only while this shows with Binders in front.
struct ListeningGlyph: View {
    @Environment(\.scenePhase) private var scenePhase
    let look: CaptureStatusLook
    let listening: Bool
    @State private var speaking = false

    var body: some View {
        Image(systemName: look.symbol)
            .foregroundStyle(look.tint)
            // Brightening and dimming through its bars, never moving about: the same under Reduce Motion.
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: listening && speaking)
            .task(id: listening && scenePhase == .active) {
                speaking = false
                guard listening, scenePhase == .active else { return }
                while !Task.isCancelled {
                    let heard = await CaptureSession.shared.hearsSpeech()
                    if heard != speaking { speaking = heard }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            .accessibilityHidden(true)
    }
}
