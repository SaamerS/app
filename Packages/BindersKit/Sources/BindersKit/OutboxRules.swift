import Foundation

/// The rules of the iPhone's outbox, kept apart from its files and its link: what an item carries so the Mac saves it
/// once however many times it's sent, how an answer that already arrived is known, and how something tried at once is
/// kept while it's tried.
public enum OutboxRules {
    /// The argument that carries an outbox item's id to a Mac that lists LinkFeatures.dedupe.
    public static let requestKey = "request_id"

    /// An item's arguments as they go to the Mac: with its id as `request_id` when the Mac remembers those, so an item
    /// sent again after its reply was lost (a timeout, the link gone on the way) is saved once. Without, the arguments as
    /// they were: an older Mac is sent nothing new.
    public static func arguments(_ arguments: [String: Any], id: UUID, dedupe: Bool) -> [String: Any] {
        guard dedupe else { return arguments }
        var arguments = arguments
        arguments[requestKey] = id.uuidString
        return arguments
    }

    /// One event on a card's timeline, as get_task gives it.
    public typealias Event = (kind: String, when: String, agent: Bool, text: String)

    /// Whether `text` is already on the card as the answer to the question asked at `asked`: an answer or a comment from
    /// you with those words, after that question. An answer sent again after the Mac's reply was lost has then arrived,
    /// rather than being turned down for the question it answered itself.
    public static func answerArrived(_ text: String, card: String, asked: String, in timeline: [Event]) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = BoardRules.questionKey(card: card, asked: asked)
        guard !words.isEmpty, let question = timeline.lastIndex(where: {
            $0.kind == "question" && BoardRules.questionKey(card: card, asked: $0.when) == key
        }) else { return false }
        return timeline[timeline.index(after: question)...].contains {
            !$0.agent && ["answer", "comment"].contains($0.kind) && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == words
        }
    }

    /// The outbox as something is tried at once rather than in its turn (Give to, tapped while connected), before the
    /// try: what was kept for the same thing (`replaces`) goes, and the item takes its place when it would be kept should
    /// the try fail (`keeps`). Written down before the try, so an app suspended on the way, then closed, still has it.
    public static func beforeTrying<Item>(_ item: Item, in outbox: [Item], keeps: Bool, replaces: (Item) -> Bool) -> [Item] {
        outbox.filter { !replaces($0) } + (keeps ? [item] : [])
    }

    /// What an outbox run sends next: the first item `sends` lets go now that the run hasn't tried, passing over those
    /// being tried at once meanwhile (`trying`), which would otherwise go twice at the same time and be settled twice.
    public static func next<Item: Identifiable>(in outbox: [Item], tried: Set<Item.ID>, trying: Set<Item.ID>,
                                                sends: (Item) -> Bool) -> Item? {
        outbox.first { !tried.contains($0.id) && !trying.contains($0.id) && sends($0) }
    }
}
