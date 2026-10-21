import ActivityKit
import BindersKit
import Foundation

/// All-day capture as its Live Activity shows it, on the Lock Screen and in the Dynamic Island while capture is on.
/// Counts and short reasons only: never what was said.
struct CaptureActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// listening, muted or paused.
        var phase: String
        /// When it began listening, for the time shown.
        var since: Date
        /// Captures filed today, and what waits on you.
        var filed: Int
        var needsYou: Int
        /// Why it's paused, in a few words.
        var reason: String?
    }
}

/// What the widgets and the Control Center control read (BindersKit's WidgetSnapshot, where its rules are tested), kept
/// by the app in the folder it shares with them.
extension WidgetSnapshot {
    static let key = "widgetSnapshot"
    static let group = "group.io.binders.app"

    static func read() -> WidgetSnapshot {
        guard let data = UserDefaults(suiteName: group)?.data(forKey: key), let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    func write() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Self.group)?.set(data, forKey: Self.key)
    }
}

/// Whether notifications, widgets and the Live Activity may show what you said when the Lock Screen shows previews
/// (iOS's "Always"). Off unless you turn it on in Capture; set by the app in the folder it shares with the widgets.
enum LockScreenWords {
    static let key = "lockScreenShowsWords"

    static var allowed: Bool { UserDefaults(suiteName: WidgetSnapshot.group)?.bool(forKey: key) ?? false }
}
