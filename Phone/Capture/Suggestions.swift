import BindersKit
import Foundation
import Observation
import UserNotifications

/// What the Mac offers about the conversations this iPhone heard: a card to put on a board, an answer from your binders.
/// They come as notifications (Add to Board, Not Now) and wait on the conversation's page.
@MainActor
@Observable
final class SuggestionCenter {
    static let shared = SuggestionCenter()

    private(set) var suggestions: [ConversationSuggestion] = []
    /// Notify about them; they're on the conversation either way.
    var notifies: Bool {
        didSet { UserDefaults.standard.set(notifies, forKey: "suggestionNotifications") }
    }

    @ObservationIgnored weak var connection: MacConnection?
    @ObservationIgnored private var notified: Set<String>
    @ObservationIgnored private var refreshing = false

    static let add = "add"
    static let notNow = "not-now"

    private init() {
        notifies = UserDefaults.standard.object(forKey: "suggestionNotifications") as? Bool ?? true
        notified = Set(UserDefaults.standard.stringArray(forKey: "suggestionsNotified") ?? [])
        suggestions = (try? Data(contentsOf: Self.file)).map { ConversationSuggestion.decodeList(String(decoding: $0, as: UTF8.self)) } ?? []
    }

    func forConversation(_ id: UUID) -> [ConversationSuggestion] { suggestions.filter { $0.conversation == id } }

    /// The buttons the notifications carry.
    static func registerCategories() {
        let card = UNNotificationCategory(identifier: ConversationSuggestion.cardCategory, actions: [
            UNNotificationAction(identifier: add, title: "Add to Board"),
            UNNotificationAction(identifier: notNow, title: "Not Now"),
        ], intentIdentifiers: [])
        let answer = UNNotificationCategory(identifier: ConversationSuggestion.answerCategory, actions: [], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([card, answer])
    }

    /// Asks the Mac what it offers, and notifies about anything new on a conversation this iPhone heard.
    func refresh() async {
        guard !refreshing, let connection, connection.hasSuggestions else { return }
        refreshing = true
        defer { refreshing = false }
        guard let reply = try? await connection.request(ConversationSuggestion.listMethod) as? [String: Any],
              let list = reply["suggestions"] as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: list),
              let fresh = try? JSONDecoder().decode([ConversationSuggestion].self, from: data) else { return }
        let mine = Set(CaptureStore.shared.conversations.map(\.id))
        suggestions = fresh.filter { mine.contains($0.conversation) }
        save()
        for suggestion in suggestions where suggestion.status == .offered && !notified.contains(suggestion.id) {
            notified.insert(suggestion.id)
            if notifies { post(suggestion) }
        }
        UserDefaults.standard.set(Array(notified.suffix(500)), forKey: "suggestionsNotified")
    }

    /// Yes or no, from the notification or the conversation's page. Returns what the Mac said, or why it couldn't.
    @discardableResult
    func act(_ id: String, accept: Bool) async -> String {
        guard let connection, connection.mac != nil else { return "Pair with your Mac to put it on a board." }
        do {
            guard let reply = try await connection.request(ConversationSuggestion.actMethod, ["id": id, "action": accept ? "accept" : "dismiss"])
                    as? [String: Any] else { return "\(connection.mac?.name ?? "Your Mac") is out of reach. Try again from the capture." }
            if let index = suggestions.firstIndex(where: { $0.id == id }) {
                suggestions[index].status = accept ? .accepted : .dismissed
                save()
            }
            return reply["message"] as? String ?? ""
        } catch {
            return error.localizedDescription
        }
    }

    private func post(_ suggestion: ConversationSuggestion) {
        let content = UNMutableNotificationContent()
        let text = suggestion.notification
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.categoryIdentifier = suggestion.kind == .card ? ConversationSuggestion.cardCategory : ConversationSuggestion.answerCategory
        content.userInfo = ["suggestion": suggestion.id, "conversation": suggestion.conversation.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: suggestion.id, content: content, trigger: nil))
    }

    private static var file: URL { CaptureFiles.folder.appendingPathComponent("suggestions.json") }

    private func save() {
        try? Data(ConversationSuggestion.encodeList(suggestions).utf8).write(to: Self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Where a tapped notification leads.
@MainActor
@Observable
final class PhoneNavigation {
    static let shared = PhoneNavigation()
    /// A conversation to open on the capture screen.
    var pendingConversation: UUID?
}
