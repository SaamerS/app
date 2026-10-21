import Foundation

// The iPhone's yes page for an agent (Review… on the Auto sheet): what `AgentConsent.disclosure` says, every fact of it,
// in labelled parts with a line for each thing, so it reads at a glance. The iPhone's own; the Mac and Give to's
// question keep the disclosure's sentences.

extension AgentConsent {
    /// The yes page's words: its title, a line under it, and its parts in order.
    public struct Page: Equatable, Sendable {
        /// One labelled part: a header, a line per thing, and a line after them.
        public struct Part: Equatable, Sendable {
            public enum Kind: String, Sendable { case gets, goes, acting, starts }
            public var kind: Kind
            public var header: String
            public var lines: [String]
            public var footer: String?
        }

        public var title: String
        public var intro: String
        public var parts: [Part]

        /// Every line on the page, in order, for the tests and for VoiceOver.
        public var allText: [String] { [title, intro] + parts.flatMap { [$0.header] + $0.lines + [$0.footer].compactMap { $0 } } }
    }

    /// The yes page for an agent, from what list_agents said of it: the same parts as `disclosure`, each fact on its own line.
    public static func page(name: String, wakes: String, sendsTo: String? = nil, vendor: String? = nil, addsContext: Bool? = nil,
                            contextFrom: String? = nil, mayAct: Bool? = nil, openSession: Bool? = nil, startsOnItsOwn: Bool? = nil,
                            autoModeStart: Bool? = nil, soloStart: Bool? = nil) -> Page {
        let from = contextFrom.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let solo = autoModeStart == true && soloStart == true
        let auto = autoModeStart == true

        var gets = ["The card's title, details and links", "Its binder and due date", "Your answers and comments on it"]
        if addsContext == true { gets.append("Up to 3 short passages from \(from ?? "notes and meetings") in its binder that match it") }
        if solo {
            gets.append("Your words, when Auto hands it something you said: from what you think out loud, only the sentences it came from")
        } else if auto {
            gets.append("Your words, when Auto hands it something you said")
        }
        var parts = [Page.Part(kind: .gets, header: PageText.getsHeader, lines: gets, footer: PageText.nothingElse)]

        var goes = [goesSentence(name: name, wakes: wakes, sendsTo: sendsTo, vendor: vendor, openSession: nil)]
        if wakes == "claudeCode", openSession == true { goes.append(openSessionSentence) }
        parts.append(Page.Part(kind: .goes, header: PageText.goesHeader, lines: goes))

        if let mayAct {
            parts.append(mayAct ? Page.Part(kind: .acting, header: PageText.mayActHeader, lines: [PageText.mayActLine])
                : Page.Part(kind: .acting, header: PageText.asksHeader, lines: [PageText.asksLine]))
        }

        if auto || startsOnItsOwn == true {
            var starts = [PageText.startsCue]
            if solo { starts.append(PageText.startsSolo) } else if auto { starts.append(PageText.startsAuto) }
            parts.append(Page.Part(kind: .starts, header: PageText.startsHeader, lines: starts))
        }
        return Page(title: AutoPhoneText.Sheet.reviewTitle(name), intro: PageText.intro(name), parts: parts)
    }

    /// The page's fixed words.
    public enum PageText {
        public static func intro(_ name: String) -> String { "Binders on your Mac hands \(name) the card. This is all that goes." }
        public static let getsHeader = "What it gets"
        public static let nothingElse = "Nothing else from your binders goes with it."
        public static let goesHeader = "Where it goes"
        public static let asksHeader = "What it won't do without asking"
        public static let asksLine = "Send, post or buy anything for you: Binders tells it to ask your approval first."
        public static let mayActHeader = "What it may do without asking"
        public static let mayActLine = "You let it send, post or buy for you without asking first."
        public static let startsHeader = "When it gets a card without asking"
        public static let startsCue = "When a “Binders, …” you say in your voice is clearly its work."
        public static let startsAuto = "While this iPhone is in Auto, when something you say on your own looks like its work, even hours later."
        public static let startsSolo = "While this iPhone is in Auto, when something you say on your own, or think out loud where only you speak, "
            + "looks like its work, even hours later."
        public static let sayYes = "Say Yes"
        public static let cancel = "Cancel"
        /// Under the button: nothing has gone yet.
        public static let nothingGoesYet = "Saying yes sends it nothing now."
    }
}
