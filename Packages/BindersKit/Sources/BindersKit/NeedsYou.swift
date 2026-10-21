import Foundation

/// What waits on you, in counts: questions agents asked (cards in Blocked), finished work to check (Review), agents'
/// suggestions of who should take a card, things you said to yourself that Binders offers to add (Add / Not Now), and
/// captures with something for you to look at. The same on the Mac, the iPhone and the Lock Screen, which shows only
/// these counts. Only the iPhone counts what you said: its offers are answered there.
public struct NeedsYou: Codable, Equatable, Sendable {
    public var questions: Int
    public var reviews: Int
    public var handOffs: Int
    /// Things you said to yourself, offered with Add and Not Now and not answered yet.
    public var moments: Int
    public var captures: Int

    public init(questions: Int = 0, reviews: Int = 0, handOffs: Int = 0, moments: Int = 0, captures: Int = 0) {
        self.questions = questions
        self.reviews = reviews
        self.handOffs = handOffs
        self.moments = moments
        self.captures = captures
    }

    /// Counts written before `moments` read as none of those.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        questions = try container.decode(Int.self, forKey: .questions)
        reviews = try container.decode(Int.self, forKey: .reviews)
        handOffs = try container.decode(Int.self, forKey: .handOffs)
        moments = try container.decodeIfPresent(Int.self, forKey: .moments) ?? 0
        captures = try container.decode(Int.self, forKey: .captures)
    }

    public enum Kind: String, CaseIterable, Sendable {
        case questions, reviews, handOffs, moments, captures

        public var symbol: String {
            switch self {
            case .questions: "questionmark.bubble"
            case .reviews: "eye"
            case .handOffs: "arrow.forward.circle"
            case .moments: "text.bubble"
            case .captures: "waveform"
            }
        }

        /// In the board's own words: "1 waiting for your answer", "2 ready for you to check"; a question where it's yours
        /// to decide: "Add 1 thing you said?".
        public func line(_ count: Int) -> String {
            switch self {
            case .questions: "\(count) waiting for your answer"
            case .reviews: "\(count) ready for you to check"
            case .handOffs: count == 1 ? "Give 1 card to an agent?" : "Give \(count) cards to agents?"
            case .moments: count == 1 ? "Add 1 thing you said?" : "Add \(count) things you said?"
            case .captures: count == 1 ? "1 capture to look at" : "\(count) captures to look at"
            }
        }
    }

    public func count(_ kind: Kind) -> Int {
        switch kind {
        case .questions: questions
        case .reviews: reviews
        case .handOffs: handOffs
        case .moments: moments
        case .captures: captures
        }
    }

    public var total: Int { questions + reviews + handOffs + moments + captures }
    public var isEmpty: Bool { total == 0 }

    /// Counts only, safe for the Lock Screen: "2 questions · 1 to check · 1 to give · 1 to add · 3 captures".
    public var summary: String {
        var parts: [String] = []
        if questions > 0 { parts.append(questions == 1 ? "1 question" : "\(questions) questions") }
        if reviews > 0 { parts.append("\(reviews) to check") }
        if handOffs > 0 { parts.append("\(handOffs) to give") }
        if moments > 0 { parts.append("\(moments) to add") }
        if captures > 0 { parts.append(captures == 1 ? "1 capture" : "\(captures) captures") }
        return parts.isEmpty ? "Nothing waits on you" : parts.joined(separator: " · ")
    }

    /// How long something heard waits on you: a capture the Mac couldn't write up, or something you said that's offered
    /// and not answered. After that it's still on its own page, but no longer counted.
    public static let waitsFor: TimeInterval = 3 * 86_400

    /// Of the things you said to yourself (a moment's id, when it was heard, the Mac's word on it and what can be done
    /// with it now), those offered with Add and not answered, heard in the last three days: newest first.
    public static func offered(_ moments: [(id: UUID, heard: Date, state: String?, actions: [String]?)], now: Date = Date()) -> [UUID] {
        moments.filter { moment in
            moment.state == "offered" && (moment.actions.map { $0.contains("add") } ?? true) && moment.heard > now.addingTimeInterval(-waitsFor)
        }
        .sorted { $0.heard > $1.heard }
        .map(\.id)
    }
}
