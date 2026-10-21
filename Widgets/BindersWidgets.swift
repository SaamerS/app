import SwiftUI
import WidgetKit

/// Binders on the Lock Screen, the Home Screen and in Control Center: All-day capture's Live Activity and control, what
/// waits on you, and today at a glance. They wear the app's palette (WidgetStyle.swift) and follow the iPhone's appearance.
@main
struct BindersWidgets: WidgetBundle {
    var body: some Widget {
        CaptureLiveActivity()
        NeedsYouWidget()
        TodayWidget()
        if #available(iOS 18.0, *) { CaptureControl() }
    }
}
