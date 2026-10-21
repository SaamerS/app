import Foundation

// An agent that could act in the world drafts first. Unless you let it act for you (AgentProfile.mayAct), it's told to
// ask your approval on its card before it sends, posts, buys or deletes anything outside Binders (request_approval), with
// exactly who it goes to and exactly what it says, and to wait. The card waits in Blocked until you approve or decline,
// on the Mac or on an unlocked iPhone, and a receipt of what you decided stays on the card. Binders can't stop an agent
// from using its own tools: this is what it's told, what it asks with, and the record of your answer.

/// What an agent asks your approval for: what it wants to do, in a few words ("send an email"), exactly who or where it
/// goes, exactly what it says (or what it buys, or deletes), and a page or file to look at with it.
public struct AgentApproval: Equatable, Sendable {
    public var action: String
    /// Email addresses, a channel, a phone number, a shop: as the agent gave them, one each. Empty when it goes to no one,
    /// as for a deletion.
    public var recipients: [String]
    public var text: String
    public var link: String

    /// The most of an action that's kept, in characters; it's said in a few words.
    public static let actionLimit = 120
    /// How many recipients one request may name.
    public static let recipientLimit = 50
    /// How much text one request may hold, in bytes of UTF-8: as much of a description as goes with a card. Longer isn't
    /// cut, it's refused, since what you approve must be all of it.
    public static let textLimit = AgentWakePayload.detailsLimit
    /// The most of a reason for declining that goes back, in characters.
    public static let reasonLimit = 1_000

    /// Each line of the action, the recipients and the link is made one line; the text is kept as it is, without the blank
    /// space around it.
    public init(action: String, recipients: [String] = [], text: String, link: String = "") {
        self.action = String(Self.line(action).prefix(Self.actionLimit))
        self.recipients = recipients.map(Self.line).filter { !$0.isEmpty }
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.link = Self.line(link)
    }

    /// Recipients as request_approval takes them: one per line. Commas stay, since a name can hold one ("Smith, Sam").
    public static func recipients(from text: String) -> [String] {
        text.components(separatedBy: .newlines).map(line).filter { !$0.isEmpty }
    }

    /// Why it can't be asked as it is, in words for the agent, or nil.
    public var problem: String? {
        if action.isEmpty { return "Say what you want to do, in a few words, such as “send an email”." }
        if text.isEmpty { return "Give the exact text: what would be sent or posted, or exactly what would be bought or deleted." }
        if text.utf8.count > Self.textLimit {
            return "That text is too long to approve: \(Self.textLimit / 1024) KB at most. Put the rest in a file, give it as the link, and say so in the text."
        }
        if recipients.count > Self.recipientLimit { return "That's too many recipients for one approval: \(Self.recipientLimit) at most." }
        return nil
    }

    // MARK: On the card

    /// As the card's timeline keeps it, readable as it is: what it wants to do, a line for each recipient ("To: …") and the
    /// link ("Link: …"), then a blank line and the text, exactly. `init?(timeline:)` reads it back.
    public var timelineText: String {
        var head = [action] + recipients.map { "To: \($0)" }
        if !link.isEmpty { head.append("Link: \(link)") }
        return head.joined(separator: "\n") + "\n\n" + text
    }

    /// Reads what `timelineText` wrote. Nil for anything else.
    public init?(timeline: String) {
        guard let blank = timeline.range(of: "\n\n") else { return nil }
        let head = timeline[..<blank.lowerBound].components(separatedBy: "\n")
        guard let action = head.first, !action.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var recipients: [String] = []
        var link = ""
        for line in head.dropFirst() {
            if line.hasPrefix("To: ") {
                recipients.append(String(line.dropFirst(4)))
            } else if line.hasPrefix("Link: ") {
                link = String(line.dropFirst(6))
            } else {
                return nil
            }
        }
        self.init(action: action, recipients: recipients, text: String(timeline[blank.upperBound...]), link: link)
    }

    /// What it asks, in words safe for the Lock Screen: "Claude Code asks to send an email". Never who it goes to or what
    /// it says.
    public func headline(by agent: String) -> String {
        "\(agent) asks to \(Self.phrase(action))"
    }

    /// What it asks, on one line, for the card's conversation: "Send an email to beta-list@example.com", with the second
    /// recipient or how many more ("… to sam@example.com and 2 more"). Never what it says, which the request has in full.
    public var summary: String {
        let phrase = Self.phrase(action)
        let what = phrase.prefix(1).uppercased() + phrase.dropFirst()
        guard let first = recipients.first else { return what }
        let more = recipients.count - 1
        return "\(what) to \(first)" + (more == 0 ? "" : more == 1 ? " and \(recipients[1])" : " and \(more) more")
    }

    /// The action as it follows "asks to": "Send an email." and "To send an email" both read "send an email"; a word in
    /// capitals ("SMS") keeps them. At most 60 characters, cut at a word.
    static func phrase(_ action: String) -> String {
        var words = line(action)
        if words.lowercased().hasPrefix("to ") { words = String(words.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        while let last = words.last, ".!".contains(last) { words.removeLast() }
        if let first = words.first, first.isUppercase {
            let next = words.dropFirst().first
            if next.map({ !$0.isUppercase }) ?? true { words = first.lowercased() + words.dropFirst() }
        }
        guard words.count > 60 else { return words.isEmpty ? "do something outside Binders" : words }
        let head = words.prefix(60)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Your answer

    /// The card's answer, which the agent reads: "Approved", or "Declined" with your reason after a colon when you gave one.
    public static func answer(approved: Bool, reason: String = "") -> String {
        if approved { return "Approved" }
        let reason = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(reasonLimit))
        return reason.isEmpty ? "Declined" : "Declined: \(reason)"
    }

    /// The receipt kept on the card when you decide: who decided, on which device and when, and exactly what was approved
    /// or declined. `device` is the Mac's or the iPhone's name.
    public func receipt(approved: Bool, reason: String = "", by who: String = "You", on device: String, at date: Date) -> String {
        let reason = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.reasonLimit))
        let place = device.trimmingCharacters(in: .whitespacesAndNewlines)
        let when = date.formatted(date: .abbreviated, time: .shortened)
        let said = approved ? "approved" : "declined"
        let why = !approved && !reason.isEmpty ? ": \(Self.line(reason))" : "."
        return "\(who) \(said) this on \(place.isEmpty ? "a device of yours" : place), \(when)\(why)\n\(timelineText)"
    }

    /// One line, with its spaces tidied.
    static func line(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Between the Mac and the iPhone

    /// What the Mac tells a phone that reads it (`LinkFeatures.approvalMethod`) when an agent asks: the card and its title,
    /// which request it is, who asks, what it asks in Lock Screen words, and when. Never who it goes to or what it says: the
    /// card has that, for the app to show.
    public struct Notice: Equatable, Sendable {
        public var card: String
        /// The request's own id, so a decision is for this one and no other.
        public var approval: String
        public var agent: String
        public var headline: String
        public var title: String
        /// When it was asked, ISO 8601.
        public var asked: String

        public init(card: String, approval: String, agent: String, headline: String, title: String, asked: String) {
            self.card = card
            self.approval = approval
            self.agent = agent
            self.headline = headline
            self.title = title
            self.asked = asked
        }

        /// Nil without a card, a request or who asks.
        public init?(params: [String: Any]) {
            func string(_ key: String) -> String { (params[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !string("card").isEmpty, !string("approval").isEmpty, !string("agent").isEmpty else { return nil }
            self.init(card: string("card"), approval: string("approval"), agent: string("agent"),
                      headline: string("headline").isEmpty ? "\(string("agent")) asks for your approval" : string("headline"),
                      title: string("title"), asked: string("asked"))
        }

        public var params: [String: Any] {
            ["card": card, "approval": approval, "agent": agent, "headline": headline, "title": title, "asked": asked]
        }

        /// What the notification says, on the Mac and the iPhone alike: who asks and what, the card's title, and to open the
        /// card. Never who it goes to or what it says, and so no button decides from it: the card shows both above Approve
        /// and Decline, on an unlocked device.
        public var notification: NotificationText {
            NotificationText(title: headline, subtitle: title, body: Self.openToDecide)
        }

        /// The notification's words under its title.
        public static let openToDecide = "Open the card to see who it goes to and exactly what it says, then approve or decline."
    }

    /// Your decision, as a phone sends it (`LinkFeatures.decisionMethod`): for which card and which request, yes or no, and
    /// your reason for a no.
    public struct Decision: Equatable, Sendable {
        public var card: String
        public var approval: String
        public var approve: Bool
        public var reason: String

        public init(card: String, approval: String, approve: Bool, reason: String = "") {
            self.card = card
            self.approval = approval
            self.approve = approve
            self.reason = reason
        }

        /// Nil without a card, a request, or a yes or no.
        public init?(params: [String: Any]) {
            guard let card = params["card"] as? String, !card.isEmpty, let approval = params["approval"] as? String, !approval.isEmpty,
                  let approve = params["approve"] as? Bool else { return nil }
            self.init(card: card, approval: approval, approve: approve, reason: params["reason"] as? String ?? "")
        }

        public var params: [String: Any] {
            ["card": card, "approval": approval, "approve": approve, "reason": reason]
        }
    }
}
