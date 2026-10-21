import ActivityKit
import BindersKit
import Foundation
import Observation
import OSLog
import UIKit
import UserNotifications
import WidgetKit

/// Keeps All-day capture's Live Activity, the widgets and the Control Center control in step with the app. The activity
/// is the sign on the Lock Screen and in the Dynamic Island that capture is on (App Store 2.5.14): it starts when capture
/// is on, follows what capture does, and ends when it's turned off. iOS starts one only while Binders is in front or one of
/// capture's own buttons runs, and ends it after eight hours, so one that ends while capture is on is asked for again at
/// each of those chances, with one quiet notification meanwhile. It shows counts and states, never what was said.
@MainActor
enum CaptureActivity {
    private static var activity: Activity<CaptureActivityAttributes>?
    private static var started: Date?
    /// Activities on their way out (ending takes a moment): never taken up again as one left from before.
    private static var ending: Set<String> = []
    /// Waits for iOS to end the activity in use.
    private static var watching: Task<Void, Never>?
    /// Whether it ended while capture was on, and whether that's been said.
    private static var indicator = CaptureIndicator()
    /// A notice left from before Binders last stopped goes at the first update.
    private static var leftoverWithdrawn = false
    /// What the capture screen says about it.
    static let status = LiveActivityStatus()
    static let lostCategory = "capture-indicator-lost"
    private static let log = Logger(subsystem: "io.binders.app", category: "capture")

    /// Capture's state and the counts, everywhere they show. `finished`: the cards the Mac's digest just said were finished
    /// today; otherwise the last it said today stands.
    static func update(finished: Int? = nil) {
        if !leftoverWithdrawn {
            leftoverWithdrawn = true
            withdrawLostNotice()
        }
        let session = CaptureSession.shared
        let waiting = NeedsYouSection.fromCopies()
        // Something new waiting on you, with Binders in front: a warning, by touch. Something you said that your Mac
        // offers to add is one of those.
        Haptics.shared.waits(waiting.items)
        var before = WidgetSnapshot.read()
        let snapshot = snapshot(phase: phase(session.status), needs: waiting.needs, finished: finished ?? before.today(at: Date()).finished)
        before.updated = snapshot.updated
        if before != snapshot {
            snapshot.write()
            WidgetCenter.shared.reloadAllTimelines()
            if #available(iOS 18.0, *) { ControlCenter.shared.reloadControls(ofKind: "io.binders.app.capture") }
        }
        guard session.isOn else { return end() }
        if activity == nil {
            // One left from before Binders last stopped carries on, rather than a second beside it. One iOS ended stays on
            // the Lock Screen, the only sign left, until a new one shows.
            let left = Activity<CaptureActivityAttributes>.activities
                .filter { !ending.contains($0.id) && ($0.activityState == .active || $0.activityState == .stale) }
            activity = left.first
            for extra in left.dropFirst() { finish(extra) }
            if let activity {
                if started == nil { started = Date() }
                watch(activity)
            }
        }
        var reason: String?
        if case .paused(let why) = session.status { reason = why }
        // "3 filed · 1 needs you", as the widgets count them: what Binders did today with what it heard, moments and
        // captures alike, and everything Needs you holds.
        let state = CaptureActivityAttributes.ContentState(phase: snapshot.capture == "off" ? "paused" : snapshot.capture,
                                                           since: session.listeningStarted ?? started ?? Date(), filed: snapshot.filedToday,
                                                           needsYou: snapshot.needsYou, reason: reason)
        // While listening, shown as possibly stopped if Binders doesn't touch it for a quarter of an hour (the watchdog does
        // every five minutes). Muted or paused, Binders may be suspended, and that's no sign of trouble: never stale.
        let content = ActivityContent(state: state, staleDate: session.isListening ? Date().addingTimeInterval(15 * 60) : nil)
        if let activity, activity.activityState == .active || activity.activityState == .stale {
            Task { await activity.update(content) }
        } else {
            request(content, listening: session.isListening)
        }
    }

    /// Capture turned off: the activity goes, and any left from an earlier launch, with anything said about one that
    /// ended.
    static func end() {
        watching?.cancel()
        watching = nil
        activity = nil
        started = nil
        if indicator.told { withdrawLostNotice() }
        indicator.settled()
        status.show(problem: nil)
        for current in Activity<CaptureActivityAttributes>.activities { finish(current) }
    }

    private static func finish(_ current: Activity<CaptureActivityAttributes>) {
        guard ending.insert(current.id).inserted else { return }
        Task {
            await current.end(nil, dismissalPolicy: .immediate)
            ending.remove(current.id)
        }
    }

    /// A Live Activity lasts eight hours at most. Back in front after six, a fresh one replaces it, so it lasts the day.
    static func refreshIfOld() {
        guard let started, Date().timeIntervalSince(started) > 6 * 3_600 else { return update() }
        end()
        update()
    }

    /// While the capture screen shows: Live Activities turned on or off for Binders in Settings, as it happens. Turned
    /// back on with capture on, the activity shows again.
    static func followSettings() async {
        let info = ActivityAuthorizationInfo()
        status.show(enabled: info.areActivitiesEnabled)
        for await enabled in info.activityEnablementUpdates {
            status.show(enabled: enabled)
            if enabled, CaptureSession.shared.isOn { update() }
        }
    }

    // MARK: Asking for one

    /// A new activity, or why there can't be one: logged, said on the capture screen, and after one ended while capture
    /// listens, said once in a quiet notification.
    private static func request(_ content: ActivityContent<CaptureActivityAttributes.ContentState>, listening: Bool) {
        let allowed = ActivityAuthorizationInfo().areActivitiesEnabled
        status.show(enabled: allowed)
        // Turned off for Binders: the capture screen says the microphone indicator is the only sign.
        guard allowed else { return status.show(problem: nil) }
        do {
            let new = try Activity.request(attributes: CaptureActivityAttributes(), content: content, pushType: nil)
            activity = new
            started = Date()
            watch(new)
            // One iOS ended stays on the Lock Screen for up to four hours more: it goes now, so only one shows.
            for old in Activity<CaptureActivityAttributes>.activities where old.id != new.id { finish(old) }
            status.show(problem: nil)
            if indicator.lost { log.notice("Capture's Live Activity shows again") }
            if indicator.told { withdrawLostNotice() }
            indicator.settled()
        } catch {
            log.error("Capture's Live Activity didn't start: \(String(describing: error), privacy: .public)")
            status.show(problem: problem(error))
            if indicator.couldNotShow(listening: listening, allowed: allowed) { postLostNotice() }
        }
    }

    /// Until iOS ends the activity in use: after eight hours, when it's swiped away, or when Live Activities are turned off.
    private static func watch(_ current: Activity<CaptureActivityAttributes>) {
        watching?.cancel()
        watching = Task {
            for await state in current.activityStateUpdates where state == .ended || state == .dismissed {
                ended(current)
                return
            }
        }
    }

    /// iOS ended it. With capture still on, another is asked for at once, which iOS allows only with Binders in front or
    /// one of capture's buttons running; otherwise at the next of those.
    private static func ended(_ current: Activity<CaptureActivityAttributes>) {
        guard activity?.id == current.id, !ending.contains(current.id) else { return }
        activity = nil
        started = nil
        let on = CaptureSession.shared.isOn
        indicator.ended(captureOn: on)
        guard on else { return }
        log.notice("iOS ended capture's Live Activity while capture was on")
        update()
    }

    /// Why iOS didn't show it, and what brings it back, for the capture screen.
    private static func problem(_ error: Error) -> String {
        switch error as? ActivityAuthorizationError {
        case .visibility?:
            "Capture isn't on the Lock Screen: iOS lets Binders put it back only while Binders is open."
        case .globalMaximumExceeded?, .targetMaximumExceeded?:
            "Capture isn't on the Lock Screen: too many Live Activities are showing. End one, then tap Try Again."
        case .unsupported?, .unsupportedTarget?:
            "This iPhone doesn't show Live Activities, so iOS's microphone indicator is the only sign that capture is on."
        default:
            "Capture isn't on the Lock Screen: \(error.localizedDescription)"
        }
    }

    /// The one quiet word while capture listens without its Live Activity. A tap opens the capture screen, and with Binders
    /// in front it shows again.
    private static func postLostNotice() {
        let content = UNMutableNotificationContent()
        content.title = "All-day capture"
        content.body = "Capture is still listening. Open Binders to show it on the Lock Screen again."
        content.categoryIdentifier = lostCategory
        content.interruptionLevel = .passive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: lostCategory, content: content, trigger: nil))
        log.notice("Said that capture listens without its Live Activity")
    }

    private static func withdrawLostNotice() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [lostCategory])
        center.removeDeliveredNotifications(withIdentifiers: [lostCategory])
    }

    // MARK: The widgets

    /// What the widgets and the Live Activity show: capture's state, what waits on you, and today at a glance, from the
    /// copies this iPhone keeps. Filed today counts the moments your Mac acted on as well as the captures it filed. The
    /// busiest work stream names its card only when you let the Lock Screen show what you said.
    private static func snapshot(phase: String, needs: NeedsYou, finished: Int?) -> WidgetSnapshot {
        let now = Date()
        let heard = MomentCenter.shared.moments.map { (at: $0.heard, state: $0.outcomeState) }
            + CaptureStore.shared.conversations.map { (at: $0.started, state: $0.outcomeState) }
        let cards = Cache.load("tasks-all").flatMap { try? MacConnection.decode([Card].self, from: $0) } ?? []
        let digest = WorkStreams.digest(cards.map { card in
            WorkStreams.Card(title: card.title, binder: card.binder, column: card.board, assignee: card.assignee.isEmpty ? nil : card.assignee,
                             assigneeIsAgent: card.assigneeIsAgent, meantFor: card.meantFor, updated: Date(iso: card.updated) ?? now)
        }, now: now)
        return WidgetSnapshot(capture: phase, needs: needs, heard: heard, finished: finished,
                              stream: WidgetSnapshot.Stream(digest, words: LockScreenWords.allowed), now: now)
    }

    private static func phase(_ status: CaptureSession.Status) -> String {
        switch status {
        case .off: "off"
        case .starting, .listening: "listening"
        case .muted: "muted"
        case .paused: "paused"
        }
    }
}

/// What the capture screen says about capture's Live Activity.
@MainActor
@Observable
final class LiveActivityStatus {
    /// Live Activities are allowed for Binders (Settings → Binders → Live Activities).
    private(set) var enabled = ActivityAuthorizationInfo().areActivitiesEnabled
    /// Why the last one asked for didn't show, until one does or capture goes off.
    private(set) var problem: String?

    /// Only a change redraws the capture screen.
    fileprivate func show(enabled: Bool) {
        if self.enabled != enabled { self.enabled = enabled }
    }

    fileprivate func show(problem: String?) {
        if self.problem != problem { self.problem = problem }
    }
}
