import XCTest
@testable import BindersKit

/// What Binders writes on a card when it first goes to an agent ("From your binders"), and what the iPhone says and
/// fingerprints before the first card goes to one.
final class AgentContextTests: XCTestCase {
    private func note(_ title: String, _ text: String, teammate: Bool = false, days: Double = 0) -> AgentContext.Source {
        AgentContext.Source(kind: .note, title: title, text: "# \(title)\n\n\(text)", teammate: teammate, date: Date(timeIntervalSince1970: 1_800_000_000 - days * 86_400))
    }

    private var binder: [AgentContext.Source] {
        [note("Ignite booth plan", "Booth 14 in Hall B.\n- Two tables and the big banner\n- Badges come from the organisers", days: 1),
         AgentContext.Source(kind: .meeting, title: "Call with the Ignite venue",
                             text: "## Summary\nThe venue holds the booth space until Friday.\n\n## Promises\n- [ ] You — confirm the booth size", date: Date(timeIntervalSince1970: 1_800_000_000)),
         note("Tomatoes", "When to plant them out, and the raised beds."),
         note("Banner sizes", "The printer takes PDF files up to 3 metres wide.", days: 3)]
    }

    // MARK: Which passages go with a card

    func testTheNotesAndMeetingsThatMatchTheCardComeFirstWithALineEach() {
        let snippets = AgentContext.snippets(title: "Order the banner for the Ignite booth", from: binder, reads: .nothing)
        XCTAssertEqual(snippets.map(\.title), ["Ignite booth plan", "Call with the Ignite venue"], "the tomatoes don't come; nor a note that shares one word")
        XCTAssertEqual(snippets.first?.line, "Booth 14 in Hall B.", "the first line that says most about the card, past its title")
        XCTAssertEqual(snippets.last?.label, "meeting")
        XCTAssertEqual(snippets.last?.line, "The venue holds the booth space until Friday.")
    }

    func testAtMostThreeAndOnePerSource() {
        let many = (1...6).map { note("Ignite booth \($0)", "More about the Ignite booth.") } + [note("Ignite booth 1", "The same again.")]
        let snippets = AgentContext.snippets(title: "Ignite booth", from: many, reads: .nothing)
        XCTAssertEqual(snippets.count, AgentContext.limit)
        XCTAssertEqual(Set(snippets.map(\.title)).count, 3)
    }

    func testNothingMatchesNothing() {
        XCTAssertTrue(AgentContext.snippets(title: "Book the dentist", from: binder, reads: .nothing).isEmpty)
        XCTAssertTrue(AgentContext.snippets(title: "Do it", from: binder, reads: .nothing).isEmpty, "a card with no words that say what it's about")
        XCTAssertTrue(AgentContext.snippets(title: "Ignite booth", from: [], reads: .nothing).isEmpty)
        // A word in the description alone isn't enough: one of the title's must be there.
        XCTAssertTrue(AgentContext.snippets(title: "Water the seedlings", details: "Raised beds", from: binder, reads: .nothing).isEmpty)
        XCTAssertEqual(AgentContext.comment([]), "")
    }

    func testCapturesAndTeammatesItemsOnlyForAnAgentThatMayReadThem() {
        let sources = [note("Ignite booth budget", "The booth costs more than planned.", teammate: true),
                       AgentContext.Source(kind: .capture, title: "Hallway chat about the Ignite booth", text: "## Summary\nThe booth moves to Hall C.")]
        XCTAssertTrue(AgentContext.snippets(title: "Ignite booth", from: sources, reads: .nothing).isEmpty)
        let everything = AgentContext.snippets(title: "Ignite booth", from: sources, reads: AgentReads(captures: true, transcripts: true, team: true))
        XCTAssertEqual(Set(everything.map(\.label)), ["teammate's note", "capture"])
        XCTAssertEqual(AgentContext.snippets(title: "Ignite booth", from: sources, reads: AgentReads(team: true)).map(\.label), ["teammate's note"])
    }

    func testTheCommentSaysWhereEachLineIsFrom() {
        let comment = AgentContext.comment(AgentContext.snippets(title: "Order the banner for the Ignite booth", from: binder, reads: .nothing))
        XCTAssertEqual(comment, """
            From your binders:
            • “Ignite booth plan” (note): Booth 14 in Hall B.
            • “Call with the Ignite venue” (meeting): The venue holds the booth space until Friday.
            """)
    }

    func testTheLineIsTheOneWithMostOfTheCardsWordsWithoutItsBullet() {
        let plan = note("Ignite booth plan", "Booth 14 in Hall B.\n- Two tables and the big banner for the booth")
        XCTAssertEqual(AgentContext.snippets(title: "Order the banner for the Ignite booth", from: [plan], reads: .nothing).first?.line,
                       "Two tables and the big banner for the booth")
    }

    func testATitleWrittenWithoutAHeadingIsntItsOwnLine() {
        let plain = AgentContext.Source(kind: .note, title: "Ignite booth plan", text: "Ignite booth plan\nBooth 14 in Hall B.")
        XCTAssertEqual(AgentContext.snippets(title: "Ignite booth", from: [plain], reads: .nothing).first?.line, "Booth 14 in Hall B.")
    }

    func testALongLineIsCutAtAWord() {
        let long = note("Ignite booth", String(repeating: "booth words ", count: 40))
        let line = AgentContext.snippets(title: "Ignite booth", from: [long], reads: .nothing).first?.line ?? ""
        XCTAssertLessThanOrEqual(line.count, AgentContext.lineLimit)
        XCTAssertTrue(line.hasSuffix("words…"), line)
    }

    func testAnAgentThatMayReadLessDoesntGetThoseLines() {
        let comment = """
            From your binders:
            • “Ignite booth plan” (note): Booth 14 in Hall B.
            • “Hallway chat” (capture): The booth moves to Hall C.
            • “Budget” (teammate's note): It costs more.
            """
        XCTAssertEqual(AgentContext.keeping(comment, readableBy: AgentReads(captures: true, team: true)), comment)
        XCTAssertEqual(AgentContext.keeping(comment, readableBy: .nothing), "From your binders:\n• “Ignite booth plan” (note): Booth 14 in Hall B.")
        XCTAssertEqual(AgentContext.keeping("From your binders:\n• “Hallway chat” (capture): Hall C.", readableBy: .nothing), "", "nothing left")
        XCTAssertEqual(AgentContext.keeping("Booth 14, and ask about Hall C.", readableBy: .nothing), "Booth 14, and ask about Hall C.", "your own words stay")
    }

    func testWhereItsPassagesComeFrom() {
        XCTAssertEqual(AgentContext.describe(.nothing), "notes and meetings")
        XCTAssertEqual(AgentContext.describe(AgentReads(captures: true, team: true)), "notes, meetings and captures (yours and your teammates')")
    }

    func testWordsAreTheOnesThatSayWhatItsAbout() {
        XCTAssertEqual(AgentContext.terms("Send the banners to the Ignite booth by Friday"), ["banner", "ignite", "booth"])
        XCTAssertEqual(AgentContext.terms("Q4 plan: 12 stories"), ["plan", "12", "story"])
        XCTAssertEqual(AgentContext.terms("status glass analysis"), ["status", "glass", "analysis"])
    }

    // MARK: Where a card goes, and asking again

    private func agent(_ wake: AgentProfile.Wake, report: AgentProfile.Report = .mcp, context: Bool? = nil) -> AgentProfile {
        AgentProfile(name: "Helper", wake: wake, report: report, binderContext: context)
    }

    func testEachKindOfAgentSaysWhereItsCardsGo() {
        XCTAssertEqual(agent(.claudeCode(ClaudeCodeWake(repository: "/Users/sam/app"))).sendsTo, "Anthropic")
        XCTAssertEqual(agent(.webhook(url: "https://hooks.example.test/cards?token=abc")).sendsTo, "hooks.example.test", "its host, never its path or query")
        XCTAssertEqual(agent(.webhook(url: "not an address")).sendsTo, "the address it was set up with")
        XCTAssertEqual(agent(.command(command: "~/bin/wake-agent --card")).sendsTo, "wake-agent")
        XCTAssertEqual(agent(.shortcut(name: "File card")).sendsTo, "Shortcuts on your Mac")
        XCTAssertEqual(agent(.board).sendsTo, "wherever it runs")
        XCTAssertEqual(agent(.board, report: .ssh(host: "sam@studio.local")).sendsTo, "on another machine, over SSH")
    }

    func testTheProgramACommandRuns() {
        XCTAssertEqual(AgentConsent.program(in: "cd ~/agents && ./pennant run"), "pennant")
        XCTAssertEqual(AgentConsent.program(in: "FOO=1 /usr/local/bin/codex exec --full-auto"), "codex")
        XCTAssertEqual(AgentConsent.program(in: "env -i PATH=/bin agent"), "agent")
        XCTAssertEqual(AgentConsent.program(in: "python3 ~/bots/grok.py --card"), "grok.py")
        XCTAssertEqual(AgentConsent.program(in: "nohup bash -lc 'run'"), "bash")
        XCTAssertEqual(AgentConsent.program(in: "export A=1; source ~/agent.sh"), "agent.sh")
        XCTAssertNil(AgentConsent.program(in: "  "))
        XCTAssertEqual(agent(.command(command: "cd ~/x")).sendsTo, "a command on your Mac")
    }

    func testAnAgentPointedSomewhereNewHasANewFingerprint() {
        let hook = agent(.webhook(url: "https://hooks.example.test/a"))
        let fingerprint = AgentConsent.fingerprint(hook, reads: .nothing)
        XCTAssertEqual(fingerprint.count, 16)
        XCTAssertEqual(fingerprint, AgentConsent.fingerprint(hook, reads: .nothing), "the same every time")
        XCTAssertNotEqual(fingerprint, AgentConsent.fingerprint(agent(.webhook(url: "https://elsewhere.example.test/a")), reads: .nothing))
        XCTAssertNotEqual(fingerprint, AgentConsent.fingerprint(agent(.webhook(url: "https://hooks.example.test/b")), reads: .nothing))
        XCTAssertNotEqual(AgentConsent.fingerprint(agent(.command(command: "agent")), reads: .nothing),
                          AgentConsent.fingerprint(agent(.command(command: "agent; curl https://example.test")), reads: .nothing))
        XCTAssertNotEqual(AgentConsent.fingerprint(agent(.shortcut(name: "A")), reads: .nothing), AgentConsent.fingerprint(agent(.shortcut(name: "B")), reads: .nothing))
        let claude = ClaudeCodeWake(repository: "/Users/sam/app", allowedDomains: ["github.com"])
        var wider = claude
        wider.allowedDomains = ["github.com", "example.test"]
        XCTAssertNotEqual(AgentConsent.fingerprint(agent(.claudeCode(claude)), reads: .nothing), AgentConsent.fingerprint(agent(.claudeCode(wider)), reads: .nothing),
                          "its commands may reach somewhere new")
        var otherModel = claude
        otherModel.model = "opus"
        otherModel.repository = "/Users/sam/other"
        XCTAssertEqual(AgentConsent.fingerprint(agent(.claudeCode(claude)), reads: .nothing), AgentConsent.fingerprint(agent(.claudeCode(otherModel)), reads: .nothing),
                       "another model or repository still goes to Anthropic")
        XCTAssertNotEqual(AgentConsent.fingerprint(agent(.board), reads: .nothing), AgentConsent.fingerprint(agent(.board, report: .ssh(host: "sam@studio.local")), reads: .nothing))
    }

    func testWhatGoesWithACardIsInTheFingerprintAndTheRestIsnt() {
        let base = agent(.webhook(url: "https://hooks.example.test/a"))
        let fingerprint = AgentConsent.fingerprint(base, reads: .nothing)
        XCTAssertNotEqual(fingerprint, AgentConsent.fingerprint(agent(.webhook(url: "https://hooks.example.test/a"), context: false), reads: .nothing),
                          "context from the binder, or not")
        XCTAssertNotEqual(fingerprint, AgentConsent.fingerprint(base, reads: AgentReads(captures: true)), "captures in it")
        XCTAssertNotEqual(fingerprint, AgentConsent.fingerprint(base, reads: AgentReads(team: true)), "teammates' items in it")
        XCTAssertEqual(fingerprint, AgentConsent.fingerprint(base, reads: AgentReads(transcripts: true)), "transcripts never go with a card")
        XCTAssertEqual(fingerprint, AgentConsent.fingerprint(agent(.webhook(url: "https://hooks.example.test/a"), context: true), reads: .nothing), "on is on")
        var changed = base
        changed.name = "Helper Two"
        changed.isEnabled = false
        changed.wakesPerHour = 2
        changed.binders = [UUID()]
        XCTAssertEqual(fingerprint, AgentConsent.fingerprint(changed, reads: .nothing))
        let off = agent(.webhook(url: "https://hooks.example.test/a"), context: false)
        XCTAssertEqual(AgentConsent.fingerprint(off, reads: .nothing), AgentConsent.fingerprint(off, reads: AgentReads(captures: true, team: true)),
                       "with no context, what it may read doesn't go with a card")
    }

    // MARK: Who it hands a card to (App Store 5.1.2(i))

    func testWhoAnAgentHandsItsCardsToIsWhatYouSaidOrWhatItsProgramSays() {
        XCTAssertEqual(AgentConsent.vendor(agent(.claudeCode(ClaudeCodeWake(repository: "/Users/sam/app")))), "Anthropic")
        XCTAssertEqual(AgentConsent.vendor(agent(.command(command: "FOO=1 /usr/local/bin/codex exec --full-auto"))), "OpenAI")
        XCTAssertEqual(AgentConsent.vendor(agent(.command(command: "gemini -p"))), "Google")
        XCTAssertEqual(AgentConsent.vendor(agent(.command(command: "claude -p --permission-mode plan"))), "Anthropic")
        XCTAssertNil(AgentConsent.vendor(agent(.command(command: "cd ~/agents && ./pennant run"))), "a program Binders doesn't know says nothing")
        XCTAssertNil(AgentConsent.vendor(agent(.board)))
        XCTAssertNil(AgentConsent.vendor(agent(.shortcut(name: "File card"))))
        XCTAssertNil(AgentConsent.vendor(agent(.webhook(url: "https://hooks.example.test/a"))))
        var pennant = agent(.board)
        pennant.vendor = "  Anthropic, through Pennant  "
        XCTAssertEqual(AgentConsent.vendor(pennant), "Anthropic, through Pennant")
        var blank = agent(.command(command: "codex exec"))
        blank.vendor = "   "
        XCTAssertEqual(AgentConsent.vendor(blank), "OpenAI", "a blank one says nothing")
        // Claude Code's sends_to is who it hands cards to, which every iPhone shows; the others' stays a host or a
        // program's name, as iPhones before vendor read it.
        var bedrock = agent(.claudeCode(ClaudeCodeWake(repository: "/Users/sam/app")))
        bedrock.vendor = "Amazon Bedrock"
        XCTAssertEqual(bedrock.sendsTo, "Amazon Bedrock")
        var hook = agent(.webhook(url: "https://hooks.example.test/a"))
        hook.vendor = "xAI"
        XCTAssertEqual(hook.sendsTo, "hooks.example.test")
        var codex = agent(.command(command: "codex exec"))
        codex.vendor = "OpenAI"
        XCTAssertEqual(codex.sendsTo, "codex")
    }

    func testNamingWhoItHandsCardsToAsksTheIPhoneAgain() {
        let pennant = agent(.command(command: "cd ~/agents && ./pennant run"))
        let before = AgentConsent.fingerprint(pennant, reads: .nothing)
        var named = pennant
        named.vendor = "Anthropic"
        XCTAssertNotEqual(before, AgentConsent.fingerprint(named, reads: .nothing), "a yes given before didn't know where it goes")
        var elsewhere = named
        elsewhere.vendor = "OpenAI"
        XCTAssertNotEqual(AgentConsent.fingerprint(named, reads: .nothing), AgentConsent.fingerprint(elsewhere, reads: .nothing), "somewhere new")
        var spaced = named
        spaced.vendor = " anthropic "
        XCTAssertEqual(AgentConsent.fingerprint(named, reads: .nothing), AgentConsent.fingerprint(spaced, reads: .nothing), "case and spaces don't count")
        let codex = agent(.command(command: "codex exec"))
        var openAI = codex
        openAI.vendor = "OpenAI"
        XCTAssertEqual(AgentConsent.fingerprint(codex, reads: .nothing), AgentConsent.fingerprint(openAI, reads: .nothing),
                       "saying what its program already says asks nothing again")
        // A yes given before the iPhone named OpenAI for codex didn't see it: the fingerprint it was given for differs.
        XCTAssertNotEqual(AgentConsent.fingerprint(codex, reads: .nothing), "779aabffed7b487e", "a known program's company is asked about once")
        XCTAssertNotEqual(AgentConsent.fingerprint(agent(.command(command: "gemini -p")), reads: .nothing), "8291864f7c7218fd")
        var renamed = codex
        renamed.vendor = "Azure OpenAI"
        XCTAssertNotEqual(AgentConsent.fingerprint(codex, reads: .nothing), AgentConsent.fingerprint(renamed, reads: .nothing), "somewhere new")
        // Claude Code always named Anthropic, and a program Binders doesn't know names nobody: neither is asked again.
        XCTAssertEqual(AgentConsent.fingerprint(agent(.claudeCode(ClaudeCodeWake(repository: "/Users/sam/app"))), reads: .nothing), "0141475ff89a46bc")
        XCTAssertEqual(before, "79c376f53b516efe")
        var errands = pennant
        errands.purpose = "Personal errands"
        XCTAssertEqual(before, AgentConsent.fingerprint(errands, reads: .nothing), "what it's for doesn't change where its cards go")
    }

    func testTheIPhoneNamesWhoTheAgentHandsTheCardTo() {
        XCTAssertEqual(AgentConsent.disclosure(name: "Codex", wakes: "command", sendsTo: "codex", vendor: "OpenAI", addsContext: true,
                                               contextFrom: "notes and meetings", mayAct: false),
                       "Binders on your Mac hands Codex the card: its title, details and links, its binder and due date, and your answers and comments on it, with up to 3 short passages from notes and meetings in its binder that match it. Binders hands them to “codex”, a program on your Mac, which sends them to OpenAI. Binders tells it to ask your approval before it sends, posts or buys anything for you. Nothing else from your binders goes with it.")
        XCTAssertTrue(AgentConsent.disclosure(name: "Pennant", wakes: "board", sendsTo: "wherever it runs", vendor: "Anthropic")
            .contains(" Pennant reads them from your Mac itself, and works on them wherever it runs, sending them to Anthropic. "))
        XCTAssertTrue(AgentConsent.disclosure(name: "Grok Bot", wakes: "webhook", sendsTo: "hooks.example.test", vendor: "xAI")
            .contains(" Binders sends them to hooks.example.test, the address Grok Bot was set up with, which sends them on to xAI. "))
        XCTAssertTrue(AgentConsent.disclosure(name: "Filer", wakes: "shortcut", sendsTo: "Shortcuts on your Mac", vendor: "OpenAI")
            .contains(" Binders hands them to a Shortcut, in Shortcuts on your Mac, which sends them to OpenAI. "))
        XCTAssertTrue(AgentConsent.disclosure(name: "Claude Code · app", wakes: "claudeCode", sendsTo: "Amazon Bedrock", vendor: "Amazon Bedrock")
            .contains(" Claude Code · app sends them to Amazon Bedrock to work on them. "))
        XCTAssertTrue(AgentConsent.disclosure(name: "Helper", wakes: "newKind", vendor: "OpenAI").contains(" Helper sends them to OpenAI. "))
    }

    func testWithoutAVendorTheIPhoneSaysWhatItSaidBefore() {
        // From a Mac that says where but not who to: the words iPhones have shown since 0.8.1.
        XCTAssertTrue(AgentConsent.disclosure(name: "Pennant", wakes: "command", sendsTo: "pennant")
            .contains(" Binders hands them to “pennant”, a program on your Mac, which sends them wherever it's set up to. "))
        XCTAssertTrue(AgentConsent.disclosure(name: "Pennant", wakes: "command", sendsTo: "a command on your Mac")
            .contains(" Binders hands them to a program on your Mac, which sends them wherever it's set up to. "))
        XCTAssertTrue(AgentConsent.disclosure(name: "Looker", wakes: "board", sendsTo: "wherever it runs")
            .contains(" Looker reads them from your Mac itself, and works on them wherever it runs. "))
        XCTAssertTrue(AgentConsent.disclosure(name: "Hooky", wakes: "webhook", sendsTo: "hooks.example.test")
            .contains(" Binders sends them to hooks.example.test, the address Hooky was set up with. "))
        XCTAssertTrue(AgentConsent.disclosure(name: "Claude Code · app", wakes: "claudeCode", sendsTo: "Anthropic, or the Claude Code session you have open in its repository",
                                              openSession: true)
            .contains(" Claude Code · app sends them to Anthropic, or the Claude Code session you have open in its repository to work on them. That session keeps its own permissions, and its Binders tools read what you let Claude Code read. "))
        XCTAssertTrue(AgentConsent.disclosure(name: "Helper", wakes: "board", mayAct: true).contains(" You let it send, post or buy for you without asking first. "))
        // From a Mac that says names and kinds alone.
        XCTAssertEqual(AgentConsent.disclosure(name: "Helper", wakes: "command"),
                       "Binders on your Mac hands Helper the card: its title, details and links, its binder and due date, and your answers and comments on it. Binders hands them to a program on your Mac, which sends them wherever it's set up to. Nothing else from your binders goes with it.")
        XCTAssertEqual(AgentConsent.disclosure(name: "Helper", wakes: "claudeCode"),
                       "Binders on your Mac hands Helper the card: its title, details and links, its binder and due date, and your answers and comments on it. Helper sends them to Anthropic to work on them. Nothing else from your binders goes with it.")
    }

    // MARK: agents.json and the wake

    func testContextIsOnUnlessYouSwitchItOffAndAnOldFileStaysAsItWas() throws {
        let old = #"{"agents": [{"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "name": "Echo", "isEnabled": true, "report": "mcp", "wake": {"board": {}}}]}"#
        let read = try XCTUnwrap(AgentFile.decode(Data(old.utf8)).file.agents.first)
        XCTAssertNil(read.binderContext)
        XCTAssertTrue(read.addsContext)
        let saved = String(decoding: try AgentFile(agents: [read]).encoded(), as: UTF8.self)
        XCTAssertFalse(saved.contains("binderContext"), "saved again, an agent that never changed it has no new key")
        var off = read
        off.binderContext = false
        let again = try XCTUnwrap(AgentFile.decode(AgentFile(agents: [off]).encoded()).file.agents.first)
        XCTAssertEqual(again.binderContext, false)
        XCTAssertFalse(again.addsContext)
    }

    func testTheWakeCarriesWhatBindersWroteOnTheCard() throws {
        let card = UUID()
        let payload = AgentWakePayload(event: "ready", agent: "Echo", card: card, title: "x", column: .ready, context: "From your binders:\n• “A” (note): b")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.json) as? [String: Any])
        XCTAssertEqual(json["context"] as? String, "From your binders:\n• “A” (note): b")
        XCTAssertNil(payload.fields["context"], "never as a variable")
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: AgentWakePayload(event: "ready", agent: "Echo", card: card, title: "x", column: .ready).json)
                                  as? [String: Any])
        XCTAssertEqual(plain["context"] as? String, "")
    }

    func testBindersOwnNoteWakesNoOne() {
        for column in BoardColumn.allCases {
            XCTAssertNil(AgentWake.reason(kind: "context", from: nil, to: nil, column: column, byPerson: true))
        }
    }

    // MARK: Ideas from a conversation

    func testTheIdeasSectionBecomesIdeaOffers() {
        let summary = """
        # Booth chat
        ## Summary
        About the Ignite booth.
        ## Ideas
        - A dark mode for the board
        * 2. Hand out stickers at the booth
        - [ ] You — order the stickers
        - A dark mode for the board
        ## People mentioned
        - Sam
        """
        XCTAssertEqual(SuggestionPrompts.ideaCandidates(summary: summary), ["A dark mode for the board", "Hand out stickers at the booth"])
        XCTAssertEqual(SuggestionPrompts.ideaCandidates(summary: summary, limit: 1), ["A dark mode for the board"])
        XCTAssertEqual(SuggestionPrompts.ideaCandidates(summary: "## Ideas\n- None\n- N/A\n## Decisions\n- Ship it"), [])
        XCTAssertEqual(SuggestionPrompts.ideaCandidates(summary: "## Promises\n- [ ] You — call Sam"), [])
    }

    func testAnIdeaIsMadeIntoTheSameCardEveryTime() throws {
        let conversation = UUID()
        let idea = ConversationSuggestion(conversation: conversation, kind: .idea, text: "Hand out stickers", binder: "Events")
        let again = ConversationSuggestion(conversation: conversation, kind: .idea, text: "Hand out stickers.", binder: "Events")
        XCTAssertEqual(idea.id, again.id)
        XCTAssertEqual(idea.cardID, again.cardID)
        XCTAssertNotEqual(idea.cardID, ConversationSuggestion(conversation: UUID(), kind: .idea, text: "Hand out stickers", binder: "Events").cardID)
        XCTAssertEqual(idea.cardID.uuidString.split(separator: "-")[2].first, "4", "a version 4 UUID")
        XCTAssertEqual(idea.notification.title, "An idea for the Events board?")
        XCTAssertEqual(ConversationSuggestion.decodeList(ConversationSuggestion.encodeList([idea])), [idea])
    }

    func testOnlyAPhoneThatListsIdeasGetsThem() {
        XCTAssertTrue(LinkFeatures.thisPhone.contains(LinkFeatures.suggestion(.idea)))
        XCTAssertFalse(LinkFeatures.firstPhone.contains(LinkFeatures.suggestion(.idea)), "iPhone 2.0 would lose every suggestion over one it can't read")
    }
}
