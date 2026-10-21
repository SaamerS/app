import AppKit
import Foundation
import UserNotifications
import BindersKit

/// Binders' notifications on the Mac: reminders for what's due, what a conversation brought up (a card to put on a
/// board, an answer from your binders), and an agent's question on a card, answered right in the notification. Shown
/// even while Binders is in front; a click opens what it's about.
final class MacNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = MacNotifications()
    @MainActor weak var controller: DictationController?
    private var installed = false

    static let add = "add"
    static let notNow = "not-now"
    static let questionCategory = "board-question"
    static let answer = "answer"
    static let openCard = "open-card"
    static let statusCategory = "board-status"

    /// Takes over the notification centre's delegate and registers the buttons the notifications carry.
    func install() {
        guard !installed else { return }
        installed = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Dismissing one says Not Now, as the button does.
        let card = UNNotificationCategory(identifier: ConversationSuggestion.cardCategory, actions: [
            UNNotificationAction(identifier: Self.add, title: "Add to Board"),
            UNNotificationAction(identifier: Self.notNow, title: "Not Now"),
        ], intentIdentifiers: [], options: [.customDismissAction])
        let answer = UNNotificationCategory(identifier: ConversationSuggestion.answerCategory, actions: [], intentIdentifiers: [])
        let question = UNNotificationCategory(identifier: Self.questionCategory, actions: [
            UNTextInputNotificationAction(identifier: Self.answer, title: "Answer", options: [], textInputButtonTitle: "Send",
                                          textInputPlaceholder: "Your answer"),
            UNNotificationAction(identifier: Self.openCard, title: "Open Card", options: [.foreground]),
        ], intentIdentifiers: [])
        let status = UNNotificationCategory(identifier: Self.statusCategory, actions: [
            UNNotificationAction(identifier: Self.openCard, title: "Open Card", options: [.foreground]),
        ], intentIdentifiers: [])
        // Decided on the card, where exactly who it goes to and what it says are in front of you.
        let approval = UNNotificationCategory(identifier: Self.approvalCategory, actions: [
            UNNotificationAction(identifier: Self.openCard, title: "Open Card", options: [.foreground]),
        ], intentIdentifiers: [], options: [.hiddenPreviewsShowTitle])
        center.setNotificationCategories([card, answer, question, status, approval])
    }

    static let approvalCategory = "board-approval"

    /// An agent asks your approval: what it wants to do, in words safe for the Lock Screen, never who it goes to or what it
    /// says. In place of a question waiting on the same card.
    @MainActor func post(approval: AgentApproval, on card: TaskCard, by agent: String) {
        guard !AppPaths.isDemo else { return }
        install()
        let cardID = card.id
        let id = card.id.uuidString
        let title = card.title
        let headline = approval.headline(by: agent)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Decided while you were asked to allow notifications: nothing to ring about.
                    guard self.controller?.board.card(cardID)?.column == .blocked else { return }
                    let content = UNMutableNotificationContent()
                    content.title = headline
                    content.subtitle = title
                    content.body = AgentApproval.Notice.openToDecide
                    content.sound = .default
                    content.categoryIdentifier = Self.approvalCategory
                    content.userInfo = ["card": id]
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.questionIdentifier(id), content: content, trigger: nil))
                }
            }
        }
    }

    /// What an agent's card did that's worth a word: picked up (quietly), finished for you to check, or stopped.
    enum Status {
        case pickedUp, review, stopped

        init(_ news: BoardNews) {
            switch news {
            case .pickedUp: self = .pickedUp
            case .review: self = .review
            }
        }
    }

    /// One notification per card, the next replacing it. Never asks to notify: only when you've already let Binders.
    @MainActor func post(status: Status, on card: TaskCard, by agent: String, summary: String) {
        guard !AppPaths.isDemo else { return }
        install()
        let cardID = card.id.uuidString, title = card.title
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            switch status {
            case .pickedUp:
                content.title = "\(agent) picked it up"
                content.interruptionLevel = .passive
            case .review:
                content.title = "Ready for review"
                content.body = summary.isEmpty ? "From \(agent)" : "From \(agent): \(summary.split(separator: "\n").first.map(String.init) ?? "")"
                content.sound = .default
            case .stopped:
                content.title = "\(agent) stopped"
                content.body = summary
                content.interruptionLevel = .passive
            }
            content.subtitle = title
            content.categoryIdentifier = Self.statusCategory
            content.userInfo = ["card": cardID]
            center.add(UNNotificationRequest(identifier: "status-\(cardID)", content: content, trigger: nil))
        }
    }

    /// The card left Review (approved, sent back): "Ready for review" goes.
    func withdrawStatus(_ card: UUID) {
        guard !AppPaths.isDemo else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["status-\(card.uuidString)"])
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
            content.categoryIdentifier = suggestion.kind == .answer ? ConversationSuggestion.answerCategory : ConversationSuggestion.cardCategory
            content.userInfo = ["suggestion": suggestion.id, "conversation": suggestion.conversation.uuidString]
            center.add(UNNotificationRequest(identifier: suggestion.id, content: content, trigger: nil))
        }
    }

    /// An agent's question on a card. One per card: a newer question replaces the one before, `quietly` without a sound.
    @MainActor func post(question: String, on card: TaskCard, by agent: String, quietly: Bool = false) {
        guard !AppPaths.isDemo else { return }
        install()
        let cardID = card.id
        let id = card.id.uuidString
        let title = card.title
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Answered while you were asked to allow notifications: nothing to ring about.
                    guard self.controller?.board.card(cardID)?.column == .blocked else { return }
                    let content = UNMutableNotificationContent()
                    content.title = "\(agent) asked"
                    content.subtitle = title
                    content.body = question
                    content.sound = quietly ? nil : .default
                    content.categoryIdentifier = Self.questionCategory
                    content.userInfo = ["card": id]
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.questionIdentifier(id), content: content, trigger: nil))
                }
            }
        }
    }

    /// The card isn't waiting any more, answered here, on the iPhone or by a move: its question, or its request for your
    /// approval, goes.
    func withdrawQuestion(_ card: UUID) {
        guard !AppPaths.isDemo else { return }
        let id = Self.questionIdentifier(card.uuidString)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    private static func questionIdentifier(_ card: String) -> String { "question-\(card)" }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let suggestion = info["suggestion"] as? String
        let conversation = info["conversation"] as? String
        let card = (info["card"] as? String).flatMap(UUID.init(uuidString:))
        let reply = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let card {
                    if action == Self.answer {
                        self.answer(card, with: reply ?? "")
                    } else if action != UNNotificationDismissActionIdentifier {
                        self.open(card)
                    }
                    return
                }
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

    /// The answer typed into the notification, as if typed on the card. An empty one opens the card instead.
    @MainActor private func answer(_ id: UUID, with text: String) {
        guard let controller else { return }
        guard let card = controller.board.card(id) else {
            return controller.flowBar.toast("That card isn't on the board any more", symbol: "exclamationmark.triangle", duration: 4)
        }
        guard !text.isEmpty else { return open(id) }
        let waiting = card.column == .blocked
        // Once the card has left Blocked, your words are a comment, which wakes the agent holding it in progress: asked
        // before the comment goes, so the toast says what it did.
        let wakes: String? = if case .wakes(let agent, _, _) = controller.agents.commentReach(for: card, events: controller.board.timeline(id)) {
            agent.components(separatedBy: " · ").first
        } else { nil }
        controller.board.comment(card, text: text, by: .you)
        let added = wakes.map { "Added your answer to “\(card.title)”, and sent it to \($0)." } ?? "Added your answer to “\(card.title)”."
        controller.flowBar.toast(waiting ? "Answered. “\(card.title)” is back in \(card.column.title)." : added, symbol: "text.bubble", duration: 4)
    }

    /// The card, in its own window, without the Binders window: answering from a notification leaves that as it was.
    @MainActor private func open(_ id: UUID) {
        guard let card = controller?.board.card(id) else { return HubWindowController.shared.show(section: .home) }
        CardWindows.shared.open(card)
    }
}
