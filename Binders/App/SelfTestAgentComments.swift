import Foundation
import BindersKit

extension SelfTest {
    /// Your comment reaches the agent doing the work: a comment of yours on a card an agent holds in In progress wakes it,
    /// as your answer does (`"event": "commented"`, your words in `answer`), gathered for two seconds, capped per hour,
    /// after a run that's going, and never for an agent's own comment, a note by Binders, an agent that checks the board
    /// itself, a card in Review, Backlog or Done, or a phone that didn't ask first. With stand-in commands written into
    /// the throwaway folder, as `--selftest-agents` has them; a throwaway folder never runs a web hook, a Shortcut or the
    /// real tools. In a throwaway folder (BINDERS_DATA_DIR) only.
    @MainActor
    static func agentCommentsSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes cards and agents")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let controller = DictationController()
        let board = controller.board
        let dispatcher = controller.agents
        let registry = AgentRegistry.shared
        if registry.paused { registry.setPaused(false) }
        let write = MCPServer.writeInApp(controller: controller)
        func call(_ tool: String, _ arguments: [String: Any], as actor: BoardActor) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: actor)) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        func id(_ text: String) -> UUID? { ((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)) }
        Store.shared.insert(BinderRecord(name: "Launch", colorIndex: 2))
        let folder = AppPaths.support

        // Stand-ins: each writes a WAKE line with its event and card, then the card's JSON from its input. Echo fails on a
        // card whose title says so, as a hook that answers an error would; Slow takes three seconds to end.
        func command(_ file: String, then: String = "") -> String {
            #"case "$BINDERS_TITLE" in *Fails*) exit 1;; esac; printf 'WAKE %s %s\n' "$BINDERS_EVENT" "$BINDERS_CARD" >> \#(file); cat >> \#(file); printf '\n' >> \#(file)"#
                + then
        }
        let echo = AgentProfile(name: "Echo", wake: .command(command: command("echo.txt"), folder: folder.path), wakesPerHour: 30)
        let capped = AgentProfile(name: "Capped", wake: .command(command: command("capped.txt"), folder: folder.path), wakesPerHour: 1)
        let shared = AgentProfile(name: "Shared", wake: .command(command: command("shared.txt"), folder: folder.path), wakesPerHour: 1)
        let slow = AgentProfile(name: "Slow", wake: .command(command: command("slow.txt", then: "; sleep 3"), folder: folder.path), wakesPerHour: 30)
        let pennant = AgentProfile(name: "Pennant", wake: .board)
        for agent in [echo, capped, shared, slow, pennant] { check(registry.upsert(agent) == nil, "\(agent.name) is saved") }
        let echoActor = BoardActor(name: "Echo", kind: .agent)

        /// What a stand-in heard: each wake's line ("commented <card>") and the card's JSON that came with it.
        func heard(_ file: String) -> [(line: String, json: [String: Any])] {
            let lines = ((try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            var wakes: [(line: String, json: [String: Any])] = []
            for (index, line) in lines.enumerated() where line.hasPrefix("WAKE ") {
                let next = lines.indices.contains(index + 1) ? lines[index + 1] : ""
                let json = (try? JSONSerialization.jsonObject(with: Data(next.utf8)) as? [String: Any]) ?? [:]
                wakes.append((String(line.dropFirst("WAKE ".count)), json))
            }
            return wakes
        }
        func wakes(_ file: String, card: UUID) -> [(line: String, json: [String: Any])] { heard(file).filter { $0.line.hasSuffix(card.uuidString) } }
        /// Waits until the stand-in has heard `count` wakes for the card, with their JSON, or up to six seconds.
        func waitFor(_ count: Int, _ file: String, card: UUID) async {
            for _ in 0..<60 {
                let got = wakes(file, card: card)
                if got.count >= count, got.allSatisfy({ !$0.json.isEmpty }) { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        func gathered() async { try? await Task.sleep(for: .milliseconds(2700)) }
        /// A card in Backlog meant for `agent` by you, then claimed by it: in In progress, its claim live, with no ready wake.
        func held(by agent: AgentProfile, _ title: String) async -> TaskCard? {
            guard let made = id(await call("create_task", ["title": title, "binder": "Launch", "column": "backlog", "for": agent.name], as: .you).text),
                  let card = board.card(made) else { return nil }
            _ = await call("claim_task", ["id": made.uuidString], as: BoardActor(name: agent.name, kind: .agent))
            return card
        }
        func reach(_ card: TaskCard) -> CommentReach { dispatcher.commentReach(for: card, events: board.timeline(card.id)) }

        // a, b) Your comment on Echo's card in In progress wakes it, once, with your words; the composer said so before.
        if let card = await held(by: echo, "Update the pricing table") {
            check(card.column == .inProgress && card.assignee == "Echo", "Echo holds its card in In progress")
            if case .wakes(agent: "Echo", reason: .commented, left: nil) = reach(card) {
                check(true, "the composer's line before it: Binders sends your comment to Echo")
            } else {
                check(false, "the composer's line before it: \(reach(card))")
            }
            board.comment(card, text: "Use the 15% from the new price sheet.", by: .you)
            await waitFor(1, "echo.txt", card: card.id)
            await gathered()
            let got = wakes("echo.txt", card: card.id)
            check(got.map(\.line) == ["commented \(card.id.uuidString)"], "a comment of yours wakes Echo once, as commented: \(got.map(\.line))")
            check(got.first?.json["event"] as? String == "commented" && got.first?.json["answer"] as? String == "Use the 15% from the new price sheet.",
                  "its JSON has \"event\": \"commented\" and your words in answer: \(got.first?.json["answer"] ?? "none")")
            let receipt = board.timeline(card.id).last { $0.kind == .woke }
            check(receipt?.text == "Woke Echo with its command (you commented).", "the card's receipt says why: \(receipt?.text ?? "none")")

            // c) Two quick comments: one wake, both in answer, oldest first.
            board.comment(card, text: "Keep the footnote to one line.", by: .you)
            try? await Task.sleep(for: .milliseconds(400))
            board.comment(card, text: "And link the price sheet.", by: .you)
            await waitFor(2, "echo.txt", card: card.id)
            await gathered()
            let two = wakes("echo.txt", card: card.id)
            check(two.count == 2 && two.last?.line == "commented \(card.id.uuidString)", "two quick comments make one more wake: \(two.count)")
            check(two.last?.json["answer"] as? String == "Keep the footnote to one line.\n\nAnd link the price sheet.",
                  "with both, oldest first, a blank line between: \(two.last?.json["answer"] ?? "none")")

            // e) An agent's own comment, another agent's, and one by an agent calling itself Binders wake no one.
            board.comment(card, text: "On it.", by: echoActor)
            board.comment(card, text: "I can help.", by: BoardActor(name: "Helper", kind: .agent))
            board.comment(card, text: "I'm Binders.", by: BoardActor(name: "Binders", kind: .agent))
            await gathered()
            check(wakes("echo.txt", card: card.id).count == 2, "an agent's own comment, another's and one calling itself Binders wake no one")

            // f) A note by Binders itself on the card wakes no one.
            board.note(card, text: "Committed Echo's changes on binders-test: 1a2b3c4, 2 files.")
            await gathered()
            check(wakes("echo.txt", card: card.id).count == 2, "Binders' own note wakes no one")

            // t) With no comment of yours waiting, Wake Now carries what it always has: the newest comment not by an agent,
            // which here is Binders' note (other wakes keep their behaviour; LANE-NOTES proposes the fix).
            check(dispatcher.wakeNow(card) == nil, "Wake Now goes")
            await waitFor(3, "echo.txt", card: card.id)
            let third = wakes("echo.txt", card: card.id).last
            check(third?.line == "manual \(card.id.uuidString)" && third?.json["answer"] as? String == "Committed Echo's changes on binders-test: 1a2b3c4, 2 files.",
                  "Wake Now with no comment waiting carries what it did before: \(third?.json["answer"] ?? "none")")
        } else {
            check(false, "Echo's card is made")
        }

        // d) In Blocked with Echo's question waiting, your comment is still the answer.
        if let card = await held(by: echo, "Choose the plan names") {
            _ = await call("ask_on_task", ["id": card.id.uuidString, "question": "Starter or Basic?"], as: echoActor)
            board.comment(card, text: "Starter.", by: .you)
            await waitFor(1, "echo.txt", card: card.id)
            let got = wakes("echo.txt", card: card.id)
            check(got.map(\.line) == ["answered \(card.id.uuidString)"] && got.first?.json["answer"] as? String == "Starter.",
                  "in Blocked your comment is the answer, as before: \(got.map(\.line))")
        }

        // g, h) In Review a comment wakes no one; Send Back, as the card does it, wakes it once with your words.
        if let card = await held(by: echo, "Write onboarding email 5") {
            _ = await call("complete_task", ["id": card.id.uuidString, "summary": "Drafted email 5."], as: echoActor)
            check(card.column == .review, "Echo finished it, for review")
            board.comment(card, text: "The troubleshooting paragraph is long.", by: .you)
            await gathered()
            check(wakes("echo.txt", card: card.id).isEmpty, "in Review, a comment wakes no one")
            check(reach(card) == .finished("Echo", sendBackWakes: true), "and the composer says Send Back sends it back: \(reach(card))")
            try? CardActions.sendBack(card, words: "Cut it to three lines.", board: board)
            await waitFor(1, "echo.txt", card: card.id)
            await gathered()
            let got = wakes("echo.txt", card: card.id)
            check(got.map(\.line) == ["sent_back \(card.id.uuidString)"], "Send Back wakes it once, as sent_back: \(got.map(\.line))")
            check(got.first?.json["answer"] as? String == "Cut it to three lines.",
                  "with Send Back's words, as before; the comment in Review stays on the card: \(got.first?.json["answer"] ?? "none")")
        }

        failures += await agentCommentChecks(controller: controller, echo: echo, capped: capped, shared: shared, slow: slow, pennant: pennant, heard: heard)
        failures += await agentCommentLinkChecks(controller: controller, echo: echo, heard: heard)
        failures += await agentCommentRefusedChecks(controller: controller, heard: heard)
        failures += await agentCommentSendingChecks(controller: controller)

        for agent in [echo, capped, shared, slow, pennant] { registry.remove(agent.id) }
        print(failures == 0 ? "AGENT_COMMENTS_OK" : "AGENT_COMMENTS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// What a stand-in heard: each wake's line and the JSON that came with it.
    typealias Heard = (String) -> [(line: String, json: [String: Any])]

    /// The cap, a run going, paused, held, the agent that checks the board itself, Ready after a hand-off, a card you hold,
    /// a claim run out, a turned-off agent, and a stronger wake gathering when a comment comes.
    @MainActor
    private static func agentCommentChecks(controller: DictationController, echo: AgentProfile, capped: AgentProfile, shared: AgentProfile,
                                           slow: AgentProfile, pennant: AgentProfile, heard: Heard) async -> Int {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let board = controller.board
        let dispatcher = controller.agents
        let registry = AgentRegistry.shared
        let write = MCPServer.writeInApp(controller: controller)
        func call(_ tool: String, _ arguments: [String: Any], as actor: BoardActor) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: actor)) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        func id(_ text: String) -> UUID? { ((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)) }
        func wakes(_ file: String, card: UUID) -> [(line: String, json: [String: Any])] { heard(file).filter { $0.line.hasSuffix(card.uuidString) } }
        func waitFor(_ count: Int, _ file: String, card: UUID, seconds: Double = 6) async {
            for _ in 0..<Int(seconds * 10) {
                let got = wakes(file, card: card)
                if got.count >= count, got.allSatisfy({ !$0.json.isEmpty }) { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        func gathered() async { try? await Task.sleep(for: .milliseconds(2700)) }
        func made(_ title: String, for agent: AgentProfile, column: String = "backlog") async -> TaskCard? {
            id(await call("create_task", ["title": title, "binder": "Launch", "column": column, "for": agent.name], as: .you).text).flatMap(board.card)
        }
        func held(by agent: AgentProfile, _ title: String) async -> TaskCard? {
            guard let card = await made(title, for: agent) else { return nil }
            _ = await call("claim_task", ["id": card.id.uuidString], as: BoardActor(name: agent.name, kind: .agent))
            return card
        }
        func reach(_ card: TaskCard) -> CommentReach { dispatcher.commentReach(for: card, events: board.timeline(card.id)) }
        func buttons(_ card: TaskCard) -> [String] { reach(card).buttons(answering: CardAnswering.of(card, events: board.timeline(card.id))).map(\.title) }

        // i) At most its wakes an hour: Capped wakes once, says so before, and then the card says Wake Now does it.
        if let card = await held(by: capped, "Tidy the changelog") {
            check(reach(card) == .wakes(agent: "Capped", reason: .commented, left: .init(left: 1, cap: 1)),
                  "before its one wake of the hour, the composer says 1 of 1 is left: \(reach(card))")
            board.comment(card, text: "First.", by: .you)
            await waitFor(1, "capped.txt", card: card.id)
            try? await Task.sleep(for: .milliseconds(3000))
            board.comment(card, text: "Second.", by: .you)
            await gathered()
            check(wakes("capped.txt", card: card.id).count == 1, "the next comment, past its cap, wakes nothing")
            check(dispatcher.outcomes[card.id]?.message.hasPrefix("Not woken: Capped was woken 1 times in the last hour. Wake Now on the card does it.") == true,
                  "the card's line says why and that Wake Now does it: \(dispatcher.outcomes[card.id]?.message ?? "nothing")")
            check(reach(card) == .atCap("Capped", 1) && buttons(card) == ["Comment"], "and the composer offers no Send to: \(buttons(card))")
            check(dispatcher.unsent(for: card)?.why == "Not sent: Capped was woken 1 times in the last hour. Wake Now sends it.",
                  "under the comment: \(dispatcher.unsent(for: card)?.why ?? "nothing")")
            check(dispatcher.wakeNow(card) == nil, "Wake Now goes past the cap")
            await waitFor(2, "capped.txt", card: card.id)
            let got = wakes("capped.txt", card: card.id)
            check(got.last?.line == "manual \(card.id.uuidString)" && got.last?.json["answer"] as? String == "Second.",
                  "and wakes it, with the comment the cap held back: \(got.last?.json["answer"] ?? "none")")
        }

        // s) The hour's count is the agent's: a comment on one card spends the wake another card would have had.
        if let one = await held(by: shared, "Draft the FAQ"), let other = await held(by: shared, "Check the screenshots") {
            board.comment(one, text: "Ten questions at most.", by: .you)
            await waitFor(1, "shared.txt", card: one.id)
            check(reach(other) == .atCap("Shared", 1), "a comment on one card spends the wake the other had: \(reach(other))")
        }

        // s2) Held back by the cap, then sent: Wake Now carries both comments, oldest first, read from the timeline, so a
        // dispatcher made afresh, as after a relaunch, says the same.
        if let card = await held(by: capped, "Plan the launch party") {
            board.comment(card, text: "Forty people.", by: .you)
            board.comment(card, text: "The evening of the 28th.", by: .you)
            await gathered()
            check(wakes("capped.txt", card: card.id).isEmpty, "two comments at the cap wake nothing")
            let fresh = AgentDispatcher(registry: registry)
            fresh.board = board
            let afresh = registry.agent(named: "Capped").map { fresh.wakeAnswer(for: $0, on: card) } ?? ""
            check(afresh == "Forty people.\n\nThe evening of the 28th.", "a dispatcher made afresh carries both: \(afresh)")
            _ = dispatcher.wakeNow(card)
            await waitFor(1, "capped.txt", card: card.id)
            let got = wakes("capped.txt", card: card.id)
            check(got.count == 1 && got.first?.line == "manual \(card.id.uuidString)" && got.first?.json["answer"] as? String == afresh,
                  "Wake Now carries both, oldest first, as a relaunch would: \(got.first?.json["answer"] ?? "none")")
        }

        // j) An agent that checks the board itself is never woken: it reads your comment there.
        if let card = await held(by: pennant, "Book the dentist") {
            board.comment(card, text: "Tuesday morning, please.", by: .you)
            await gathered()
            check(card.assignee == "Pennant" && dispatcher.outcomes[card.id] == nil && reach(card) == .checksBoard("Pennant"),
                  "Pennant, which checks the board itself, isn't woken, and the composer says it reads it there: \(reach(card))")
        }

        // l) Handed over in Ready and not taken: a plain comment stays; Send to sends it again with your words, once.
        if let card = await made("Fix the import timeout", for: echo, column: "ready") {
            await waitFor(1, "echo.txt", card: card.id)
            check(wakes("echo.txt", card: card.id).map(\.line) == ["ready \(card.id.uuidString)"], "made ready for Echo, it's woken once")
            try? await Task.sleep(for: .milliseconds(500))
            board.comment(card, text: "The 50k-row file is in the shared drive.", by: .you)
            await gathered()
            check(wakes("echo.txt", card: card.id).count == 1, "a plain comment in Ready doesn't hand it over again")
            check(reach(card) == .sendsWithWakeNow(agent: "Echo", .notTaken) && buttons(card) == ["Send to Echo", "Comment"],
                  "the composer offers Send to Echo and Comment: \(reach(card))")
            check(dispatcher.unsent(for: card)?.why == "Not sent: Echo hasn't taken the card.", "under it: \(dispatcher.unsent(for: card)?.why ?? "nothing")")
            check(CardActions.sendToAgent(card, words: "Run it on staging first.", controller: controller) == nil, "Send to goes")
            await waitFor(2, "echo.txt", card: card.id)
            await gathered()
            let got = wakes("echo.txt", card: card.id)
            check(got.count == 2 && got.last?.line == "ready \(card.id.uuidString)" && got.last?.json["answer"] as? String == "Run it on staging first.",
                  "Send to: exactly one wake, ready, with your words: \(got.map(\.line))")
        }
        if let card = await made("Fails to take the card", for: echo, column: "ready") {
            for _ in 0..<50 where dispatcher.outcomes[card.id]?.message.hasPrefix("Stopped") != true { try? await Task.sleep(for: .milliseconds(100)) }
            if case .sendsWithWakeNow(agent: "Echo", .didntGo(let why)) = reach(card) {
                check(why == "Stopped (exit 1)", "a hand-off that failed: the composer says it didn't get the card, and why: \(why ?? "nothing")")
            } else {
                check(false, "a hand-off that failed: \(reach(card))")
            }
        }

        // m) Backlog and Done: no wake.
        if let card = await made("Write the welcome email", for: echo) {
            board.comment(card, text: "Short, please.", by: .you)
            await gathered()
            check(wakes("echo.txt", card: card.id).isEmpty && reach(card) == .notGiven("Echo"), "in Backlog, a comment wakes no one")
        }
        if let card = await held(by: echo, "Send the invoices") {
            try? board.move(card, to: .done, by: .you)
            board.comment(card, text: "Thanks.", by: .you)
            await gathered()
            check(wakes("echo.txt", card: card.id).isEmpty && reach(card) == .done("Echo"), "in Done, a comment wakes no one: \(reach(card))")
        }

        // n) Paused: no wake, and the composer says so; resumed, the next comment wakes it.
        if let card = await held(by: echo, "Order the stickers") {
            registry.setPaused(true)
            board.comment(card, text: "Matte, not glossy.", by: .you)
            await gathered()
            check(wakes("echo.txt", card: card.id).isEmpty && reach(card) == .paused, "paused, a comment wakes no one: \(reach(card))")
            registry.setPaused(false)
            board.comment(card, text: "And 500 of them.", by: .you)
            await waitFor(1, "echo.txt", card: card.id)
            let got = wakes("echo.txt", card: card.id)
            check(got.map(\.line) == ["commented \(card.id.uuidString)"] && got.first?.json["answer"] as? String == "Matte, not glossy.\n\nAnd 500 of them.",
                  "resumed, the next comment wakes it, with the one it missed: \(got.first?.json["answer"] ?? "none")")
        }

        // o) A run that's going: a comment waits for it to end, and goes then, once.
        if let card = await held(by: slow, "Run the import test") {
            board.comment(card, text: "Use the 50k file.", by: .you)
            await waitFor(1, "slow.txt", card: card.id)
            board.comment(card, text: "And the 100k one after it.", by: .you)
            await gathered()
            check(wakes("slow.txt", card: card.id).count == 1, "a comment while its command runs waits")
            if case .afterRun("Slow", .commented) = reach(card) {
                check(true, "and the composer says it goes when the run ends")
            } else {
                check(false, "and the composer says it goes when the run ends: \(reach(card))")
            }
            await waitFor(2, "slow.txt", card: card.id, seconds: 8)
            try? await Task.sleep(for: .milliseconds(3500))
            let got = wakes("slow.txt", card: card.id)
            check(got.count == 2 && got.last?.line == "commented \(card.id.uuidString)" && got.last?.json["answer"] as? String == "And the 100k one after it.",
                  "once the run ends, it's woken again, once, with that comment: \(got.map(\.line))")
        }

        // o2) A comment waits behind a run; the run asks, you answer, and the run ends while your answer gathers: the
        // comment's wake doesn't take the answer's place. One wake, answered, with the comment and the answer.
        let slower = AgentProfile(name: "Slower", wake: .command(command: #"printf 'WAKE %s %s\n' "$BINDERS_EVENT" "$BINDERS_CARD" >> slower.txt; cat >> slower.txt; printf '\n' >> slower.txt; sleep 4"#,
                                                                  folder: AppPaths.support.path), wakesPerHour: 30)
        check(registry.upsert(slower) == nil, "Slower is saved")
        if let card = await held(by: slower, "Run the long import") {
            board.comment(card, text: "Use the 50k file.", by: .you)
            await waitFor(1, "slower.txt", card: card.id)
            board.comment(card, text: "And the 100k one after it.", by: .you)
            await gathered()
            check(wakes("slower.txt", card: card.id).count == 1, "the second comment waits behind the run")
            _ = await call("ask_on_task", ["id": card.id.uuidString, "question": "Both in one go, or one at a time?"], as: BoardActor(name: "Slower", kind: .agent))
            board.comment(card, text: "One at a time.", by: .you)
            await waitFor(2, "slower.txt", card: card.id, seconds: 8)
            await gathered()
            let got = wakes("slower.txt", card: card.id)
            check(got.count == 2 && got.last?.line == "answered \(card.id.uuidString)"
                  && got.last?.json["answer"] as? String == "And the 100k one after it.\n\nOne at a time.",
                  "the run ends while your answer gathers: one wake, answered, with the comment and the answer: \(got.map(\.line)) \(got.last?.json["answer"] ?? "none")")
        }
        registry.remove(slower.id)

        // p) Sent back with words, then a comment within a second: one wake, sent_back, with both.
        if let card = await held(by: echo, "Draft the release notes") {
            _ = await call("complete_task", ["id": card.id.uuidString, "summary": "Drafted."], as: BoardActor(name: "Echo", kind: .agent))
            try? CardActions.sendBack(card, words: "Shorter.", board: board)
            try? await Task.sleep(for: .milliseconds(500))
            board.comment(card, text: "And no exclamation marks.", by: .you)
            await waitFor(1, "echo.txt", card: card.id)
            await gathered()
            let got = wakes("echo.txt", card: card.id)
            check(got.map(\.line) == ["sent_back \(card.id.uuidString)"] && got.first?.json["answer"] as? String == "Shorter.\n\nAnd no exclamation marks.",
                  "Send Back and a comment just after: one wake, sent_back, with both: \(got.map(\.line)) \(got.first?.json["answer"] ?? "none")")
        }

        // q) A comment, then Wake Now within a second: one wake, Wake Now's, with the comment.
        if let card = await held(by: echo, "Check the footer") {
            board.comment(card, text: "The link in the footer is broken.", by: .you)
            try? await Task.sleep(for: .milliseconds(400))
            _ = dispatcher.wakeNow(card)
            await waitFor(1, "echo.txt", card: card.id)
            await gathered()
            let got = wakes("echo.txt", card: card.id)
            check(got.map(\.line) == ["manual \(card.id.uuidString)"] && got.first?.json["answer"] as? String == "The link in the footer is broken.",
                  "a comment, then Wake Now: exactly one wake, with the comment: \(got.map(\.line))")
        }

        // r) An answer, then a comment within a second: one wake, answered, with both.
        if let card = await held(by: echo, "Pick the photographer") {
            _ = await call("ask_on_task", ["id": card.id.uuidString, "question": "Sam or the studio?"], as: BoardActor(name: "Echo", kind: .agent))
            board.comment(card, text: "The studio.", by: .you)
            try? await Task.sleep(for: .milliseconds(400))
            board.comment(card, text: "Ask for the Friday slot.", by: .you)
            await waitFor(1, "echo.txt", card: card.id)
            await gathered()
            let got = wakes("echo.txt", card: card.id)
            check(got.map(\.line) == ["answered \(card.id.uuidString)"] && got.first?.json["answer"] as? String == "The studio.\n\nAsk for the Friday slot.",
                  "an answer and a comment just after: one wake, answered, with both: \(got.first?.json["answer"] ?? "none")")
        }

        // u) A claim that has run out, before the sweep lets the card go: no wake, and Send to is offered.
        if let card = await held(by: echo, "Update the docs") {
            card.claimExpiresAt = Date().addingTimeInterval(-60)
            board.comment(card, text: "Still on this?", by: .you)
            await gathered()
            check(wakes("echo.txt", card: card.id).isEmpty && reach(card) == .sendsWithWakeNow(agent: "Echo", .wentQuiet),
                  "with its claim run out, a comment wakes no one, and Send to is offered: \(reach(card))")
        }

        // v) You hold it: a comment wakes no one; Send to wakes it with your words, and the card stays yours.
        if let card = await made("Draft the launch FAQ", for: echo) {
            try? board.move(card, to: .inProgress, by: .you)
            board.comment(card, text: "Ten questions at most.", by: .you)
            await gathered()
            check(card.assignee == BoardActor.you.name && wakes("echo.txt", card: card.id).isEmpty && reach(card) == .sendsWithWakeNow(agent: "Echo", .youHoldIt),
                  "you hold it: a comment wakes no one, and Send to is offered: \(reach(card))")
            check(dispatcher.unsent(for: card)?.why == "Not sent: you have the card.", "under it: \(dispatcher.unsent(for: card)?.why ?? "nothing")")
            _ = CardActions.sendToAgent(card, words: "Link the pricing page from the first one.", controller: controller)
            await waitFor(1, "echo.txt", card: card.id)
            let got = wakes("echo.txt", card: card.id)
            check(got.map(\.line) == ["manual \(card.id.uuidString)"] && got.first?.json["answer"] as? String == "Link the pricing page from the first one."
                  && card.assignee == BoardActor.you.name, "Send to: one wake, manual, with your words, and the card still yours: \(got.map(\.line))")
        }

        // w) A stale reason: made ready, Echo claims it within the two seconds, then your comment: one wake, commented.
        if let card = await made("Plan the offsite", for: echo) {
            try? board.move(card, to: .ready, by: .you)
            try? await Task.sleep(for: .milliseconds(300))
            _ = await call("claim_task", ["id": card.id.uuidString], as: BoardActor(name: "Echo", kind: .agent))
            board.comment(card, text: "Book the room for Thursday.", by: .you)
            await waitFor(1, "echo.txt", card: card.id)
            await gathered()
            let got = wakes("echo.txt", card: card.id)
            check(got.map(\.line) == ["commented \(card.id.uuidString)"] && got.first?.json["answer"] as? String == "Book the room for Thursday.",
                  "a ready wake gone stale still carries your comment, as commented: \(got.map(\.line))")
        }

        // x) A holder that's turned off: no wake, and the composer says so.
        if let card = await held(by: echo, "Archive the old plans") {
            registry.setEnabled(echo.id, false)
            board.comment(card, text: "Keep the 2025 ones.", by: .you)
            await gathered()
            check(wakes("echo.txt", card: card.id).isEmpty && reach(card) == .turnedOff("Echo"), "turned off, it isn't woken: \(reach(card))")
            registry.setEnabled(echo.id, true)
        }
        return failures
    }

    /// Over the link, as a phone sends it: the hello says the Mac wakes on comments; a phone that asks first wakes only the
    /// agent it names; one that doesn't ask wakes no one, and the card says Wake Now sends it.
    @MainActor
    private static func agentCommentLinkChecks(controller: DictationController, echo: AgentProfile, heard: Heard) async -> Int {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let board = controller.board
        let dispatcher = controller.agents
        let manager = FileManager.default
        func wakes(card: UUID) -> [(line: String, json: [String: Any])] { heard("echo.txt").filter { $0.line.hasSuffix(card.uuidString) } }
        func held(_ title: String) -> TaskCard {
            let card = board.create(title: title, binderID: Store.shared.binders().first { $0.name == "Launch" }?.id, column: .backlog, by: .you)
            board.assign(card, to: echo.name, by: .you)
            try? board.claim(card, by: BoardActor(name: echo.name, kind: .agent))
            return card
        }
        let devicesURL = manager.temporaryDirectory.appendingPathComponent("comment-devices-\(UUID().uuidString).json")
        defer { try? manager.removeItem(at: devicesURL) }
        let server = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: devicesURL)
        server.start()
        for _ in 0..<50 where server.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
        guard let port = server.boundPort, var pairing = await server.beginPairing(), let pairingPort = server.boundPairingPort else {
            server.stop()
            check(false, "the link starts")
            return failures
        }
        pairing.addresses = ["127.0.0.1:\(pairingPort)"]
        do {
            let paired = try await LinkClient.pair(pairing, deviceName: "Test iPhone")
            let phone = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
            try await phone.connect()
            let hello = try await phone.hello(device: paired.device, key: paired.key, name: "Test iPhone", features: LinkFeatures.thisPhone)
            check((hello["features"] as? [String])?.contains(LinkFeatures.commentWakes) == true, "the Mac says it wakes on comments")

            // A phone that asks first, naming the agent it asked about: it wakes that agent.
            let named = held("Shoot the booth photos")
            _ = try await phone.callTool("comment_task", ["id": named.id.uuidString, "text": "From the phone.", "to": "Echo"])
            for _ in 0..<60 where wakes(card: named.id).first?.json.isEmpty != false { try? await Task.sleep(for: .milliseconds(100)) }
            check(wakes(card: named.id).map(\.line) == ["commented \(named.id.uuidString)"] && wakes(card: named.id).first?.json["answer"] as? String == "From the phone.",
                  "a phone that asked you about Echo wakes it with its comment: \(wakes(card: named.id).map(\.line))")

            // Naming no one, or another agent: it stays on the card, and the card says why.
            for to in [nil, "Pennant"] as [String?] {
                let card = held("Print the banner \(to ?? "none")")
                var arguments: [String: Any] = ["id": card.id.uuidString, "text": "From the phone."]
                if let to { arguments["to"] = to }
                _ = try await phone.callTool("comment_task", arguments)
                try? await Task.sleep(for: .milliseconds(2700))
                check(wakes(card: card.id).isEmpty && dispatcher.unsent(for: card)?.why == "Not sent to Echo: your iPhone didn't ask you about Echo first. Wake Now sends it."
                      && dispatcher.outcomes[card.id]?.ok == false,
                      "a phone comment naming \(to ?? "no one") wakes no one, and the card says the iPhone didn't ask: \(dispatcher.unsent(for: card)?.why ?? "nothing")")
            }
            phone.close()

            // iPhone 2.0 and the builds that don't ask first: nothing wakes, with `to` or without, and the card says why.
            let old = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
            try await old.connect()
            _ = try await old.hello(device: paired.device, key: paired.key, name: "Old iPhone")
            for to in [nil, "Echo"] as [String?] {
                let card = held("Hang the banner \(to ?? "none")")
                var arguments: [String: Any] = ["id": card.id.uuidString, "text": "From an older phone."]
                if let to { arguments["to"] = to }
                _ = try await old.callTool("comment_task", arguments)
                try? await Task.sleep(for: .milliseconds(2700))
                check(wakes(card: card.id).isEmpty
                      && dispatcher.unsent(for: card)?.why == "Not sent to Echo: Binders on your iPhone needs an update before its comments wake an agent. Wake Now sends it.",
                      "a comment from a phone that doesn't ask first, \(to == nil ? "without" : "with") to, wakes no one: \(dispatcher.unsent(for: card)?.why ?? "nothing")")
                // Echo then lets go of it: the refusal was about your comment, not a hand-off that didn't go.
                if to == "Echo" {
                    try? board.release(card, by: BoardActor(name: echo.name, kind: .agent))
                    let reach = dispatcher.commentReach(for: card, events: board.timeline(card.id))
                    let line = reach.line(answering: nil) ?? ""
                    check(card.column == .ready && reach == .sendsWithWakeNow(agent: "Echo", .didntGo(nil)) && !line.contains("Not sent") && !line.contains("iPhone"),
                          "let go after a refused phone comment, the composer doesn't read the refusal as a failed hand-off: \(line)")
                }
            }
            old.close()
        } catch {
            check(false, "the link failed: \(error.localizedDescription)")
        }
        server.stop()
        return failures
    }

    /// y) No wake for a comment on a card held by an agent that doesn't take this binder's cards, one changed outside
    /// Binders, or one Binders holds back: nothing runs, the card's last wake is as it was, and the composer says which.
    @MainActor
    private static func agentCommentRefusedChecks(controller: DictationController, heard: Heard) async -> Int {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let board = controller.board
        let dispatcher = controller.agents
        let registry = AgentRegistry.shared
        let folder = AppPaths.support
        let launch = Store.shared.binders().first { $0.name == "Launch" }
        let elsewhereBinder = BinderRecord(name: "Elsewhere", colorIndex: 4)
        Store.shared.insert(elsewhereBinder)
        func standIn(_ file: String) -> String { #"printf 'WAKE %s %s\n' "$BINDERS_EVENT" "$BINDERS_CARD" >> \#(file)"# }
        /// A card meant by you for `agent` and held by it, in In progress.
        func held(by name: String, _ title: String) -> TaskCard {
            let card = board.create(title: title, binderID: launch?.id, column: .backlog, by: .you)
            board.assign(card, to: name, by: .you)
            try? board.claim(card, by: BoardActor(name: name, kind: .agent))
            return card
        }
        func refused(_ name: String, _ file: String, _ card: TaskCard, _ expected: CommentReach, _ line: String, _ label: String) async {
            let before = dispatcher.outcomes[card.id]
            board.comment(card, text: "Use the 15% from the new price sheet.", by: .you)
            try? await Task.sleep(for: .milliseconds(2700))
            let reach = dispatcher.commentReach(for: card, events: board.timeline(card.id))
            check(card.column == .inProgress && card.assignee == name && heard(file).isEmpty && !board.timeline(card.id).contains { $0.kind == .woke }
                  && dispatcher.outcomes[card.id] == before && reach == expected && dispatcher.unsent(for: card)?.why == line,
                  "\(label): no wake, its last wake as it was, and the composer says so: \(reach), \(dispatcher.unsent(for: card)?.why ?? "nothing")")
        }

        // Takes only another binder's cards.
        let elsewhere = AgentProfile(name: "Elsewhere", wake: .command(command: standIn("elsewhere.txt"), folder: folder.path),
                                     binders: [elsewhereBinder.id], wakesPerHour: 30)
        check(registry.upsert(elsewhere) == nil, "Elsewhere is saved")
        await refused("Elsewhere", "elsewhere.txt", held(by: "Elsewhere", "Rename the plans"), .notThisBoard("Elsewhere"),
                      "Not sent: Elsewhere doesn't take this board's cards.", "an agent that doesn't take this board's cards")

        // Changed outside Binders: its command edited in agents.json since you saved it.
        let outside = AgentProfile(name: "Outside", wake: .command(command: standIn("outside.txt"), folder: folder.path), wakesPerHour: 30)
        check(registry.upsert(outside) == nil, "Outside is saved")
        let outsideCard = held(by: "Outside", "Check the invoices")
        let path = folder.appendingPathComponent("agents.json")
        let edited = ((try? String(contentsOf: path, encoding: .utf8)) ?? "").replacingOccurrences(of: "outside.txt", with: "outside-edited.txt")
        try? edited.write(to: path, atomically: true, encoding: .utf8)
        registry.load()
        check(registry.changedOutside.contains(outside.id), "Outside is changed outside Binders")
        await refused("Outside", "outside-edited.txt", outsideCard, .changedOutside("Outside"), "Not sent: Outside was changed outside Binders.",
                      "an agent changed outside Binders")
        check(heard("outside.txt").isEmpty, "and its command as saved didn't run either")

        // Held: a command saved before Binders refused one that turns a tool's checks off.
        let holdy = AgentProfile(name: "Holdy", wake: .command(command: "copilot -p x --allow-all-tools", folder: folder.path), wakesPerHour: 30)
        registry.saveAsBefore(holdy)
        registry.load()
        if let why = registry.held[holdy.id] {
            await refused("Holdy", "holdy.txt", held(by: "Holdy", "Tidy the backlog"), .held("Holdy", why: why), "Not sent: Binders holds Holdy back.",
                          "an agent Binders holds back")
        } else {
            check(false, "Holdy is held")
        }
        for agent in [elsewhere, outside, holdy] { registry.remove(agent.id) }
        return failures
    }

    /// z) A web hook post or a Shortcut run on its way, with a stand-in in their place (nothing leaves this Mac): a wake that
    /// carries your comments waits for the card's last one to settle, so a failure line always follows its own wake's
    /// receipt, the line under your words says which arrived, and comments a failed one didn't deliver go with the next.
    @MainActor
    private static func agentCommentSendingChecks(controller: DictationController) async -> Int {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let board = controller.board
        let dispatcher = controller.agents
        let registry = AgentRegistry.shared
        let write = MCPServer.writeInApp(controller: controller)
        func call(_ tool: String, _ arguments: [String: Any], as actor: BoardActor) async -> String {
            (try? await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: actor)) ?? ""
        }
        func id(_ text: String) -> UUID? { ((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)) }

        /// The stand-in: each post's JSON, and what each one does in turn (how long it takes, and whether it fails).
        final class Hook {
            var posts: [[String: Any]] = []
            var steps: [(seconds: Double, fails: String?)] = []
        }
        let hook = Hook()
        dispatcher.standIn = { _, json in
            let step = hook.steps.isEmpty ? (seconds: 0, fails: nil) : hook.steps.removeFirst()
            hook.posts.append((try? JSONSerialization.jsonObject(with: json) as? [String: Any]) ?? [:])
            try await Task.sleep(for: .milliseconds(Int(step.seconds * 1000)))
            if let fails = step.fails { throw NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: fails]) }
        }
        defer { dispatcher.standIn = nil }
        let hooky = AgentProfile(name: "Hooky", wake: .webhook(url: "https://hooks.example.test/cards"), wakesPerHour: 30)
        let shorty = AgentProfile(name: "Shorty", wake: .shortcut(name: "Grok"), wakesPerHour: 30)
        for agent in [hooky, shorty] { check(registry.upsert(agent) == nil, "\(agent.name) is saved") }
        func held(by agent: AgentProfile, _ title: String) async -> TaskCard? {
            guard let made = id(await call("create_task", ["title": title, "binder": "Launch", "column": "backlog", "for": agent.name], as: .you)),
                  let card = board.card(made) else { return nil }
            _ = await call("claim_task", ["id": made.uuidString], as: BoardActor(name: agent.name, kind: .agent))
            return card
        }
        func timeline(_ card: TaskCard) -> [TaskEvent] { board.timeline(card.id) }
        func deliveries(_ card: TaskCard, _ agent: String) -> [Int: CardConversation.Delivery] {
            CardConversation.delivery(timeline(card).map(\.conversation), agent: agent, failureLines: AgentDispatcher.failureLines)
        }
        func index(_ card: TaskCard, _ text: String) -> Int? { timeline(card).firstIndex { $0.text == text } }
        func wokeLines(_ card: TaskCard) -> [String] { timeline(card).filter { $0.kind == .woke }.map(\.text) }

        // z1) Two comments: the first one's post is slow and fails after the second came, which waits for it.
        if let card = await held(by: hooky, "Update the pricing table") {
            hook.posts = []
            hook.steps = [(4, "The request timed out."), (0, nil)]
            board.comment(card, text: "Use the 15%.", by: .you)
            try? await Task.sleep(for: .milliseconds(2500))
            check(hook.posts.count == 1 && hook.posts.first?["event"] as? String == "commented", "the first comment's wake is on its way: \(hook.posts.count)")
            board.comment(card, text: "And keep the footnote short.", by: .you)
            try? await Task.sleep(for: .milliseconds(2600))
            check(hook.posts.count == 1 && wokeLines(card).count == 1 && dispatcher.unsent(for: card)?.why == "Sending in a moment",
                  "the second waits for it to settle: \(hook.posts.count) posts, \(dispatcher.unsent(for: card)?.why ?? "nothing")")
            for _ in 0..<40 where hook.posts.count < 2 { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(300))
            let lines = wokeLines(card)
            check(lines.count == 3 && lines[1].hasPrefix("Its web hook didn't take the card: The request timed out."),
                  "its failure line follows its own receipt, before the next: \(lines)")
            check(hook.posts.count == 2 && hook.posts.last?["event"] as? String == "commented"
                  && hook.posts.last?["answer"] as? String == "Use the 15%.\n\nAnd keep the footnote short.",
                  "then the wake that waited goes, with both: \(hook.posts.last?["answer"] ?? "none")")
            if let first = index(card, "Use the 15%."), let second = index(card, "And keep the footnote short.") {
                let shown = deliveries(card, "Hooky")
                let receipt = timeline(card).lastIndex { $0.kind == .woke }
                check(shown[first] == receipt.map { .sent(receipt: $0) } && shown[second] == receipt.map { .sent(receipt: $0) },
                      "and each comment's line says it's sent, by the wake that arrived: \(shown)")
            }
        }

        // z2) A comment, then Wake Now while its post is on its way: Wake Now waits, and carries the comment.
        if let card = await held(by: hooky, "Check the footer") {
            hook.posts = []
            hook.steps = [(3, "The request timed out."), (0, nil)]
            board.comment(card, text: "The footer link is broken.", by: .you)
            try? await Task.sleep(for: .milliseconds(2500))
            check(dispatcher.wakeNow(card) == nil, "Wake Now goes")
            try? await Task.sleep(for: .milliseconds(500))
            check(hook.posts.count == 1, "and waits for the comment's post to settle: \(hook.posts.count)")
            for _ in 0..<40 where hook.posts.count < 2 { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(300))
            check(hook.posts.count == 2 && hook.posts.last?["event"] as? String == "manual" && hook.posts.last?["answer"] as? String == "The footer link is broken.",
                  "then goes, with the comment the failed post didn't deliver: \(hook.posts.last?["answer"] ?? "none")")
            if let comment = index(card, "The footer link is broken.") {
                let receipt = timeline(card).lastIndex { $0.kind == .woke }
                check(deliveries(card, "Hooky")[comment] == receipt.map { .sent(receipt: $0) }, "and the comment's line says Wake Now's wake took it")
            }
        }

        // z3) A Shortcut that fails, for a wake that carried your comment: the card says so, and Wake Now carries it again.
        if let card = await held(by: shorty, "Post the launch note") {
            hook.posts = []
            hook.steps = [(0, "The Shortcut couldn't be found."), (0, nil)]
            board.comment(card, text: "Post it at noon.", by: .you)
            for _ in 0..<40 where !wokeLines(card).contains(where: { $0.hasPrefix("Its Shortcut") }) { try? await Task.sleep(for: .milliseconds(100)) }
            let lines = wokeLines(card)
            check(lines == ["Ran the Shortcut “Grok” for Shorty (you commented).", "Its Shortcut didn't take the card: The Shortcut couldn't be found."],
                  "a failed Shortcut says so after its receipt: \(lines)")
            if let comment = index(card, "Post it at noon.") {
                if case .didntArrive = deliveries(card, "Shorty")[comment] {
                    check(true, "and the comment's line says it didn't reach Shorty")
                } else {
                    check(false, "and the comment's line says it didn't reach Shorty: \(String(describing: deliveries(card, "Shorty")[comment]))")
                }
                check(dispatcher.wakeNow(card) == nil, "Wake Now goes")
                for _ in 0..<30 where hook.posts.count < 2 { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(200))
                check(hook.posts.last?["answer"] as? String == "Post it at noon." && deliveries(card, "Shorty")[comment] == timeline(card).lastIndex { $0.kind == .woke }.map { .sent(receipt: $0) },
                      "and carries it again: \(hook.posts.last?["answer"] ?? "none")")
            }
        }

        // z4) A Shortcut that fails for a wake with no comment of yours (a hand-off): as before, only the card's last-wake line
        // says so.
        if let made = id(await call("create_task", ["title": "Share the changelog", "binder": "Launch", "column": "backlog"], as: .you)),
           let card = board.card(made) {
            hook.posts = []
            hook.steps = [(0, "The Shortcut couldn't be found.")]
            board.give(card, to: shorty.name, by: .you)
            for _ in 0..<30 where dispatcher.outcomes[card.id]?.ok != false { try? await Task.sleep(for: .milliseconds(100)) }
            check(dispatcher.outcomes[card.id]?.message == "“Grok”: The Shortcut couldn't be found." && wokeLines(card) == ["Ran the Shortcut “Grok” for Shorty (made ready for it)."],
                  "a hand-off's failed Shortcut leaves the card as before: \(wokeLines(card))")
        }
        for agent in [hooky, shorty] { registry.remove(agent.id) }
        return failures
    }
}
