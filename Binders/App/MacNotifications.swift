import AppKit
import Foundation
import UserNotifications
import BindersKit

/// Binders' notifications on the Mac: reminders for what's due, and what a conversation brought up: a card to put on a
/// board, an answer from your binders. Shown even while Binders is in front; a click opens what it's about.
final class MacNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = MacNotifications()
    @MainActor weak var controller: DictationController?
    private var installed = false

    static let add = "add"
    static let notNow = "not-now"

    /// Takes over the notification centre's delegate and registers the buttons the notifications carry.
    func install() {
        guard !installed else { return }
        installed = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let card = UNNotificationCategory(identifier: ConversationSuggestion.cardCategory, actions: [
            UNNotificationAction(identifier: Self.add, title: "Add to Board"),
            UNNotificationAction(identifier: Self.notNow, title: "Not Now"),
        ], intentIdentifiers: [])
        let answer = UNNotificationCategory(identifier: ConversationSuggestion.answerCategory, actions: [], intentIdentifiers: [])
        center.setNotificationCategories([card, answer])
    }

    /// A suggestion from a conversation this Mac heard.
    func post(_ suggestion: ConversationSuggestion) {
        // Self-tests run on throwaway data: nothing to tell anyone about.
        guard !AppPaths.isDemo else { return }
        install()
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            let text = suggestion.notification
            content.title = text.title
            content.body = text.body
            content.sound = .default
            content.categoryIdentifier = suggestion.kind == .card ? ConversationSuggestion.cardCategory : ConversationSuggestion.answerCategory
            content.userInfo = ["suggestion": suggestion.id, "conversation": suggestion.conversation.uuidString]
            center.add(UNNotificationRequest(identifier: suggestion.id, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let suggestion = info["suggestion"] as? String
        let conversation = info["conversation"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let suggestion, let conversation else {
                    // A reminder: Home, where the to-dos are.
                    HubWindowController.shared.show(section: .home)
                    return
                }
                switch action {
                case Self.add:
                    if let result = self.controller?.conversations.accept(suggestion) {
                        self.controller?.flowBar.toast(result.message, symbol: result.ok ? "rectangle.split.3x1" : "exclamationmark.triangle", duration: 4)
                    }
                case Self.notNow, UNNotificationDismissActionIdentifier:
                    self.controller?.conversations.dismiss(suggestion)
                default:
                    KnowledgeNavigator.openSource(kind: .conversation, sourceID: conversation)
                }
            }
        }
        completionHandler()
    }
}
