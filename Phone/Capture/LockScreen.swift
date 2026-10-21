import BindersKit
import Foundation
import UserNotifications
import WidgetKit

/// What notifications may say on the Lock Screen: titles and counts by default, never what you said. With iOS showing
/// previews Always (the default with Touch ID), a notification says what was done and leaves your words for the app, unless
/// you turned on "Show what you said on the Lock Screen". With previews hidden until you unlock, your words can be there:
/// until then iOS shows the title and each category's placeholder, with a count. The rules are LockScreenText's.
@MainActor
enum LockScreen {
    /// Your words on the Lock Screen while previews show Always: off unless you turn it on on the capture screen. Kept in
    /// the folder the app shares with the widgets, which read it too.
    static var showsWordsAlways: Bool {
        get { LockScreenWords.allowed }
        set {
            UserDefaults(suiteName: WidgetSnapshot.group)?.set(newValue, forKey: LockScreenWords.key)
            // The widgets' snapshot keeps a card's title only while this is on: written again with or without it.
            CaptureActivity.update()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// How iOS shows Binders' previews now. One this build doesn't know counts as Always, the careful reading.
    static func previews() async -> NotificationPreviews {
        switch await UNUserNotificationCenter.current().notificationSettings().showPreviewsSetting {
        case .whenAuthenticated: .whenUnlocked
        case .never: .never
        default: .always
        }
    }

    /// Whether a notification posted now may hold what you said.
    static func showsWords() async -> Bool {
        LockScreenText.showsWords(await previews(), allowed: showsWordsAlways)
    }
}
