import Foundation

// Lane Y2: a sentence said on its own without a cue, read by the rules alone as a fix, a to-do or an idea, for Auto's gate
// (which also needs Apple's model to agree, MomentGate.confirmsUncued) and the Mac's classify call. English, like every
// moment rule; pure, so the gate's bench and Y2's phrases hold it (MomentUncuedTests). The patterns are the bench's
// (scratch-Y2/bench/rules.py), as fixed before the held-out set's second run.

extension MomentRules {
    /// What a sentence said with no cue is, by the rules alone: "fix", "todo" or "idea", or nil. Nil for anything with a
    /// cue (cue(in:) reads those). The first sentence that reads as one, in order, each without its leading interjections.
    /// An idea first ("We should add…" is an idea, "I should email…" a to-do), then a to-do, then a fix, which has to be
    /// about one of the things software is made of (`things`), and not someone's ("their website") or a bare "it".
    public static func uncued(in text: String) -> String? {
        guard cue(in: text) == nil else { return nil }
        for raw in sentences(in: text) {
            var said = Uncued.withoutInterjections(Uncued.straightened(raw)).trimmingCharacters(in: .whitespaces)
            said = said.replacingOccurrences(of: #"(?i)^(?:and|but|also|plus|then)\s+"#, with: "", options: .regularExpression)
            let plain = said.trimmingCharacters(in: CharacterSet(charactersIn: ".!?\u{2026} ")).trimmingCharacters(in: .whitespaces)
            let low = plain.lowercased()
            guard !low.isEmpty else { continue }
            if let kind = Uncued.kind(of: low) { return kind }
        }
        return nil
    }

    /// The words of apps, sites and the work on them that a fix without a cue has to be about, as one pattern.
    public static let things = Uncued.things
}

enum Uncued {
    static let things = #"apps?|site|website|web\s?site|page|pages|homepage|home\s+page|landing\s+page|pricing(?:\s+page|\s+table)?|screen|screens|button|buttons|login|log-?in|sign-?in|sign\s+in|sign-?up|sign\s+up|password\s+reset|search|sync|syncing|upload|uploads|download|downloads|export|exports|import|imports|menu|menus|settings|setting|link|links|form|forms|field|fields|notifications?|widgets?|keyboard|board|boards|cards?|sidebar|header|footer|fonts?|icons?|logo|dark\s+mode|light\s+mode|onboarding|checkout|dashboard|charts?|editor|toolbar|tabs?|dialog|pop-?up|banner|video|player|build|builds|tests?|deploy|deployment|server|api|database|docs|documentation|readme|changelog|release\s+notes|installer|timer|filters?|layout|spacing|copy|labels?|titles?|tooltips?|shortcuts?|hotkeys?|animations?|scroll(?:ing)?|toggle|switch|slider|picker|inbox|outbox|feed|demo|transcripts?|transcription|dictation|captures?|recordings?|agents?|router|binders?|notes\s+list|card\s+list|list\s+view|calendar\s+view|share\s+sheet|share\s+button|preview|previews|thumbnail|thumbnails|attachment|attachments|newsletter|digest|template|templates|webhook|web\s+hook|command|commands|plugin|plugins|extension|update|updater|release|version|beta|tests?\s+suite|ci|pipeline|login\s+page|error\s+page|404\s+page|blog|post|posts|rss|feed|map\s+view|install|setup|wizard|tutorial|tour|faq|help\s+page|help"#
    static let leads = #"(?:(?:i\s+(?:just\s+)?(?:think|noticed|found|saw|realised|realized|feel\s+like|swear|guess|bet)|(?:it\s+)?(?:looks|seems)\s+like|apparently|honestly|seriously|so|okay|ok|and|but|also|oh|man|ugh|wow|hmm+|um+|uh+|right|anyway|actually|you\s+know)\s*,?\s+)*"#
    static let problem = #"\b(?:crash(?:es|ed|ing)?|(?:is|are|'s|was|were)\s+(?:still\s+)?(?:broken|buggy)|broke\b|(?:times?|timed)\s+out|timing\s+out|freez(?:es|ing\s+up)|froze(?:\s+up)?|hangs\b|(?:doesn't|does\s+not|won't|will\s+not|can't|cannot|never)\s+(?:work|load|save|sync|scroll|refresh|render|connect|respond|upload|download|open|play|update)\b|(?:isn't|is\s+not|aren't|are\s+not|wasn't|weren't)\s+(?:working|loading|saving|syncing|updating|rendering|connecting|uploading|downloading|showing\s+up)\b|keeps?\s+(?:crashing|failing|freezing|hanging|timing\s+out|logging\s+(?:me|us|people|you)\s+out|disconnecting|dropping|resetting|reloading|flickering|jumping|forgetting)\b|throws?\s+an?\s+error|(?:gives|shows)\s+an?\s+error|error\s+messages?|takes?\s+(?:forever|ages|too\s+long)\s+to\s+(?:load|open|sync|start|save|show\s+up|appear|finish|upload|send))"#
    static let complaint = #"\b(?:is|are|'s|was|were|looks?|feels?|seems?|gets?)\s+(?:still\s+)?(?:way\s+|much\s+|really\s+|a\s+bit\s+|a\s+little\s+|kind\s+of\s+|kinda\s+|so\s+|super\s+|pretty\s+|getting\s+|too\s+)*(?:slow|sluggish|cramped|cluttered|crowded|confusing|ugly|wrong|off|misaligned|cut\s+off|blurry|missing|hidden|truncated|laggy|flaky|janky|stale|outdated|out\s+of\s+date|unreadable|buried|inconsistent|backwards|clunky|annoying|empty|blank|unclear|hard\s+to\s+(?:find|read|use|see|click|tap|follow|understand))\b|\b(?:is|are|'s|was|were|looks?|feels?|seems?|gets?)\s+(?:still\s+)?(?:way\s+|much\s+|really\s+|a\s+bit\s+|a\s+little\s+|kind\s+of\s+|kinda\s+|far\s+)*too\s+(?:fast|quick|small|tiny|big|huge|long|short|bright|dark|light|faint|wide|narrow|busy|much|little|loud|quiet)\b|\b(?:shows?|says?|gives?|uses?|has|have|picks?|puts?|sends?|counts?)\s+the\s+wrong\b|\b(?:doesn't|does\s+not|won't|never)\s+(?:include|show|remember|wrap|fit|match|sort|say|keep|ask|warn|list)\b|\b(?:has|have)\s+(?:a\s+|no\s+)?(?:typo|typos|bug|bugs|glitch)\b|\b(?:cuts?|cutting)\s+off\b|\b(?:drops?|loses?|skips?|swallows?|duplicates?|mangles?)\s+(?:the\s+|a\s+|my\s+|some\s+)?(?:last\s+|first\s+)?\w+|\b(?:comes?|shows?|appears?|fires?|sends?|asks?|runs?|rings?|pops?\s+up|opens?)\s+(?:(?:for|up)\s+)?(?:the\s+\w+\s+)?(?:twice|double)\b|\bstill\s+(?:says|shows|uses|has|points\s+to|links\s+to|lists)\s+the\s+old\b|\b(?:is|are|'s|was|were)\s+(?:still\s+|really\s+|kind\s+of\s+|such\s+)?(?:a\s+mess|a\s+pain|a\s+nightmare|a\s+maze)\b|\b(?:doesn't|does\s+not|won't|never|can't)\s+find\b"#
    static let request = #"\b(?:should|ought\s+to|needs\s+to|has\s+to|could)\s+(?:also\s+|really\s+|probably\s+|just\s+)?(?:be|have|show|include|let|remember|support|say|use|open|close|load|sort|default|start|stop|work|keep|ask|warn|tell|list|hide|wrap|fit|match|sync|offer|link|group|save|export|import)\b"#
    static let needs = #"\b(?:needs|could\s+use|could\s+do\s+with)\s+(?:a\s+|an\s+|some\s+|more\s+|less\s+|better\s+|another\s+)?\w+"#
    static let iShould = #"^(?:maybe\s+|perhaps\s+|so\s+)?(?:i|we)\s+(?:really\s+|probably\s+|definitely\s+|seriously\s+|honestly\s+|just\s+|also\s+)*should\s+(?:really\s+|probably\s+|definitely\s+|just\s+|also\s+)*(?!have\b|be\b|know\b|go\b|get\s+going\b|head\b|leave\b|sleep\b|relax\b|rest\b|eat\b|feel\b|think\b|probably\b|stay\b|wait\b|see\b|watch\b|stop\b|worry\b|calm\b|try\s+to\s+relax\b|get\s+(?:more|some)\s+sleep\b)(\w[\w'-]*)\b(.*)$"#
    static let obliged = #"^(?:i|we)(?:'d|\s+had)?\s+(?:really\s+|still\s+|also\s+|just\s+|definitely\s+|seriously\s+|probably\s+|actually\s+)*(?:must|ought\s+to|better)\s+(?!be\b|have\b|go\b|get\s+going\b|leave\b)(\w[\w'-]*)\b(.*)$"#
    static let must = #"^(?:must|should)\s+(?:really\s+|probably\s+|definitely\s+|just\s+|also\s+)*(?!be\b|have\b|go\b|get\s+going\b|know\b|stop\b|worry\b)(\w[\w'-]*)\b(.+)$"#
    static let todoLabel = #"^(?:to-do|todo|to\s+do)\s*[:,]?\s+(.+)$|^(?:add|create|make|new)\s+(?:a\s+|another\s+|new\s+)?(?:to[- ]?do|task|reminder)[,:]?\s+(?:to\s+)?(.+)$"#
    static let weShouldDo = #"^(?:maybe\s+)?we\s+(?:really\s+|probably\s+|definitely\s+|just\s+|also\s+)*(?:should|must|ought\s+to|better)\s+(?:really\s+|probably\s+|just\s+|also\s+)*(?:fix|update|change|clean\s+up|look\s+into|check|test|rename|refactor|speed\s+up|simplify|finish|rewrite|redo|tidy|sort\s+out|cut|shorten|move)\b"#
    static let wantTo = #"^i(?:'d|\s+would)?\s+(?:really\s+|also\s+|just\s+)?(?:want|like)\s+to\s+(?:fix|add|build|write|ship|change|rewrite|redo|try|test|update|move|rename|refactor|finish|send|email|call|book|order|buy|look\s+into|check|set\s+up|clean\s+up|sort\s+out|publish|post|record|draft|plan|research|compare|schedule|cancel|renew|return|pay|file|print|back\s+up|reply|answer|redesign|simplify|speed\s+up)\b(.+)$"#
    static let announced = #"^(?:(?:here's|here\s+is|i\s+have|i've\s+got|i\s+got|got|quick|new|another|a|an|random|crazy|wild)\s+)*(?:(?:feature|product|app|post|talk)\s+)?(?:ideas?|thought)(?![\w])(.*)$"#
    static let whatIf = #"^(?:what\s+if|imagine\s+if|imagine)\s+(?:we|i)(?!(?:\s*|\s+)(?:'m|'re|am|are|was|were|is|get|got|fail|failed|lose|lost|miss|missed|forget|forgot|can't|don't|didn't|never|run\s+out)\b)\b|^(?:what\s+if|imagine\s+if)\s+(?:the|our|binders)\b(?=.*\b(?:apps?|site|website|web\s?site|page|pages|homepage|home\s+page|landing\s+page|pricing(?:\s+page|\s+table)?|screen|screens|button|buttons|login|log-?in|sign-?in|sign\s+in|sign-?up|sign\s+up|password\s+reset|search|sync|syncing|upload|uploads|download|downloads|export|exports|import|imports|menu|menus|settings|setting|link|links|form|forms|field|fields|notifications?|widgets?|keyboard|board|boards|cards?|sidebar|header|footer|fonts?|icons?|logo|dark\s+mode|light\s+mode|onboarding|checkout|dashboard|charts?|editor|toolbar|tabs?|dialog|pop-?up|banner|video|player|build|builds|tests?|deploy|deployment|server|api|database|docs|documentation|readme|changelog|release\s+notes|installer|timer|filters?|layout|spacing|copy|labels?|titles?|tooltips?|shortcuts?|hotkeys?|animations?|scroll(?:ing)?|toggle|switch|slider|picker|inbox|outbox|feed|demo|transcripts?|transcription|dictation|captures?|recordings?|agents?|router|binders?|notes\s+list|card\s+list|list\s+view|calendar\s+view|share\s+sheet|share\s+button|preview|previews|thumbnail|thumbnails|attachment|attachments|newsletter|digest|template|templates|webhook|web\s+hook|command|commands|plugin|plugins|extension|update|updater|release|version|beta|tests?\s+suite|ci|pipeline|login\s+page|error\s+page|404\s+page|blog|post|posts|rss|feed|map\s+view|install|setup|wizard|tutorial|tour|faq|help\s+page|help)\b)"#
    static let wouldBeAfter = #"^(?:a|an|the|some)\s+(?:[\w-]+\s+){0,6}?(?:apps?|site|website|web\s?site|page|pages|homepage|home\s+page|landing\s+page|pricing(?:\s+page|\s+table)?|screen|screens|button|buttons|login|log-?in|sign-?in|sign\s+in|sign-?up|sign\s+up|password\s+reset|search|sync|syncing|upload|uploads|download|downloads|export|exports|import|imports|menu|menus|settings|setting|link|links|form|forms|field|fields|notifications?|widgets?|keyboard|board|boards|cards?|sidebar|header|footer|fonts?|icons?|logo|dark\s+mode|light\s+mode|onboarding|checkout|dashboard|charts?|editor|toolbar|tabs?|dialog|pop-?up|banner|video|player|build|builds|tests?|deploy|deployment|server|api|database|docs|documentation|readme|changelog|release\s+notes|installer|timer|filters?|layout|spacing|copy|labels?|titles?|tooltips?|shortcuts?|hotkeys?|animations?|scroll(?:ing)?|toggle|switch|slider|picker|inbox|outbox|feed|demo|transcripts?|transcription|dictation|captures?|recordings?|agents?|router|binders?|notes\s+list|card\s+list|list\s+view|calendar\s+view|share\s+sheet|share\s+button|preview|previews|thumbnail|thumbnails|attachment|attachments|newsletter|digest|template|templates|webhook|web\s+hook|command|commands|plugin|plugins|extension|update|updater|release|version|beta|tests?\s+suite|ci|pipeline|login\s+page|error\s+page|404\s+page|blog|post|posts|rss|feed|map\s+view|install|setup|wizard|tutorial|tour|faq|help\s+page|help|email|emails|summary|report|feature|mode|plan|tier|view)\b.*\bwould\s+be\s+(?:so\s+|really\s+)?(?:nice|great|cool|useful|handy|good|neat)\b"#
    static let wouldBe = #"^(?:(?:would|wouldn't)\s+it\s+be|it'd\s+be|it\s+would\s+be)\s+(?:so\s+|really\s+)?(?:cool|nice|great|neat|good|awesome|useful|handy)\s+(?:if|to)\b"#
    static let wouldBeWhat = #"\bto\s+(?:have|add|let|make|build|show|offer|get)\b|\b(?:apps?|site|website|web\s?site|page|pages|homepage|home\s+page|landing\s+page|pricing(?:\s+page|\s+table)?|screen|screens|button|buttons|login|log-?in|sign-?in|sign\s+in|sign-?up|sign\s+up|password\s+reset|search|sync|syncing|upload|uploads|download|downloads|export|exports|import|imports|menu|menus|settings|setting|link|links|form|forms|field|fields|notifications?|widgets?|keyboard|board|boards|cards?|sidebar|header|footer|fonts?|icons?|logo|dark\s+mode|light\s+mode|onboarding|checkout|dashboard|charts?|editor|toolbar|tabs?|dialog|pop-?up|banner|video|player|build|builds|tests?|deploy|deployment|server|api|database|docs|documentation|readme|changelog|release\s+notes|installer|timer|filters?|layout|spacing|copy|labels?|titles?|tooltips?|shortcuts?|hotkeys?|animations?|scroll(?:ing)?|toggle|switch|slider|picker|inbox|outbox|feed|demo|transcripts?|transcription|dictation|captures?|recordings?|agents?|router|binders?|notes\s+list|card\s+list|list\s+view|calendar\s+view|share\s+sheet|share\s+button|preview|previews|thumbnail|thumbnails|attachment|attachments|newsletter|digest|template|templates|webhook|web\s+hook|command|commands|plugin|plugins|extension|update|updater|release|version|beta|tests?\s+suite|ci|pipeline|login\s+page|error\s+page|404\s+page|blog|post|posts|rss|feed|map\s+view|install|setup|wizard|tutorial|tour|faq|help\s+page|help)\b"#
    static let weCould = #"^(?:maybe\s+|perhaps\s+)?we\s+(?:could|should|might|can)\s+(?:maybe\s+|also\s+|just\s+|really\s+|probably\s+)*(?:add|build|make|have|offer|ship|start|use|let|show|support|turn|run|write|create|put|give|include|try|launch|record|film|design|redesign|automate|charge|sell|integrate|connect|track|send|collect|publish|post|open\s+source|pair|bundle|split|merge|drop|replace|rename|remove|hide|move|sort|group|highlight|explain)\b"#
    static let howAbout = #"^how\s+about\s+(?:adding|making|building|putting|letting|showing|turning|having|using|offering|trying|giving|sending)\b"#
    static let interjections = #"^(?:oh\s+my\s+god|my\s+god|oh\s+man|oh\s+god|all\s+right|alright|okay|ok|man|so|oh|ah|well|right|yeah|god|ugh|damn|jeez|actually|anyway|hmm+|um+|uh+)(?:[,.!]+\s*|\s+)"#
    static let persons: Set<String> = ["dad", "everybody", "everyone", "he", "he's", "i", "i'd", "i'll", "i'm", "i've", "it", "it's", "mom", "mum", "my", "nobody", "people", "sam", "she", "she's", "somebody", "someone", "that", "that's", "there", "there's", "they", "they're", "this", "we", "we're", "what", "who", "you", "you're"]
    static let notAThing: Set<String> = ["the", "a", "an", "our", "my", "this", "that", "these", "those", "its", "their", "still", "really",
                                         "just", "also", "now", "again", "so", "and", "but", "kind", "of", "sort", "like", "um", "uh"]

    static func kind(of low: String) -> String? {
        // Ideas.
        if let rest = groups(announced, low)?.first, let said = rest,
           !said.trimmingCharacters(in: CharacterSet(charactersIn: " ,:;.-\u{2013}\u{2014}")).isEmpty { return "idea" }
        if found(whatIf, low) { return "idea" }
        if let range = range(wouldBe, low), found(wouldBeWhat, String(low[range.upperBound...])) { return "idea" }
        if found(weCould, low) || found(wouldBeAfter, low) || found(howAbout, low) { return "idea" }
        // To-dos.
        if found(iShould, low), found(#"^(?:maybe\s+|perhaps\s+|so\s+)?i\b"#, low) { return "todo" }
        if found(obliged, low) || found(must, low) || found(todoLabel, low) || found(wantTo, low) || found(weShouldDo, low) { return "todo" }
        // Fixes.
        if found("^(?:" + leads + #")there(?:'s|\s+is|\s+are|'re)\s+(?:a\s+|an\s+|some\s+|another\s+)?(?:bug|bugs|typo|typos|glitch|glitches|regression)\s+(?:in|on|with|when|where)\b"#, low) {
            return "fix"
        }
        if let rest = groups("^(?:" + leads + #")there(?:'s|\s+is|\s+are|'re)\s+(?:a\s+|an\s+|some\s+|another\s+)?(?:problem|issue|issues|problems)\s+(?:in|on|with|when|where)\b(.*)$"#, low)?.first,
           let after = rest, found(#"\b(?:"# + things + #")\b"#, after) { return "fix" }
        if found("^(?:" + leads + #")(?:a\s+)?typo\s+(?:in|on)\b"#, low) { return "fix" }
        for (pattern, needsThing) in [(problem, false), (complaint, true), (request, true), (needs, true)] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = low as NSString
            for match in regex.matches(in: low, range: NSRange(location: 0, length: ns.length)) {
                let subject = subjectBefore(ns.substring(to: match.range.location))
                guard isAThing(subject) else { continue }
                if needsThing, !found(#"\b(?:"# + things + #")\b"#, subject.joined(separator: " ")) { continue }
                return "fix"
            }
        }
        return nil
    }

    /// The words before a problem phrase, as its subject: without leads.
    static func subjectBefore(_ before: String) -> [String] {
        let trimmed = before.replacingOccurrences(of: "(?i)^" + leads, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        return TextNorm.normalizedWords(trimmed)
    }

    /// A subject that's a thing: not a person, not someone else's, not a bare "it".
    static func isAThing(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        if ["their", "his", "her", "your", "someone's", "somebody's", "everyone's"].contains(first) { return false }
        if persons.contains(first), !(["my", "this", "that"].contains(first) && words.count > 1) { return false }
        let content = words.filter { !notAThing.contains($0) }
        return !content.isEmpty && content != ["it"]
    }

    static func withoutInterjections(_ text: String) -> String {
        var said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<3 {
            guard let match = range("(?i)" + interjections, said) ?? range(#"(?i)^(?:wait|listen|shoot)[,.!]+\s*"#, said),
                  match.upperBound < said.endIndex else { break }
            said = String(said[match.upperBound...])
        }
        return said
    }

    static func straightened(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var regexes: [String: NSRegularExpression] = [:]
        func regex(_ pattern: String) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }
            if let known = regexes[pattern] { return known }
            guard let made = try? NSRegularExpression(pattern: pattern) else { return nil }
            regexes[pattern] = made
            return made
        }
    }

    private static let cache = Cache()

    static func found(_ pattern: String, _ text: String) -> Bool {
        guard let regex = cache.regex(pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func range(_ pattern: String, _ text: String) -> Range<String.Index>? {
        guard let regex = cache.regex(pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return Range(match.range, in: text)
    }

    static func groups(_ pattern: String, _ text: String) -> [String?]? {
        guard let regex = cache.regex(pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<max(1, match.numberOfRanges)).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
