import Foundation
import BindersKit

extension SelfTest {
    /// The shared board cases (the kit's Fixtures/team/board-cases.json, beside this build's source) against the SQL
    /// functions: each card is put in its starting state directly, then the case's actor acts through the function, as
    /// Sam (P, and Sam's agents A and B) or Alex (Q, and Alex's agent C). The kit's TeamBoardCasesTests runs the same cases
    /// against the Swift rules. Then what only the database checks: dependency loops, and a receipt for something else.
    @MainActor
    static func teamDatabaseCaseChecks(_ bed: TeamDBTestBed) async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/BindersKit/Tests/BindersKitTests/Fixtures/team/board-cases.json")
        let cases = try TeamBoardCases.load(url)
        bed.check(cases.lease == BoardRules.lease, "the cases' lease is the board's")
        let root = try await bed.root()
        let samLink = try await bed.link(bed.sam)
        let alexLink = try await bed.link(bed.alex)
        let agents: [String: UUID] = ["A": bed.agentA, "B": bed.agentB, "C": bed.agentC]
        let people: [String: UUID] = ["P": bed.samID, "Q": bed.alexID]
        func key(kind: String?, member: UUID?, agent: UUID?, name: String?) -> String? {
            if name == "Binders", kind == "person", member == nil { return "Binders" }
            if kind == "agent" { return agents.first { $0.value == agent }?.key }
            if kind == "person" { return people.first { $0.value == member }?.key }
            return nil
        }
        func near(_ date: Date?, _ expected: Date?) -> Bool {
            switch (date, expected) {
            case (nil, nil): true
            case let (date?, expected?): abs(date.timeIntervalSince(expected)) < 5
            default: false
            }
        }
        let tolerance = "(leases compared to 5 s)"
        var passed = 0, failed = 0, waiting = 0

        for item in cases.cases {
            if item.waits { waiting += 1 }
            try await root.execute("UPDATE binders.binders SET agents_may_finish = \(item.agentsMayFinish) WHERE id = $1::uuid",
                                   [bed.shared.uuidString])
            let card = UUID()
            let start = Date()
            let holder = item.card.holder
            let holderName = holder.flatMap { cases.actor($0)?.name }
            try await root.execute("""
                INSERT INTO binders.cards (id, binder_id, title, board_column, holder_kind, holder_member_id, holder_agent_id, holder_name,
                                           lease_until, created_by_name, meant_for, meant_for_by_agent)
                VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6::uuid, $7::uuid, $8, now() + make_interval(secs => $9::double precision), 'Sam',
                        $10, $11::boolean)
                """, [card.uuidString, bed.shared.uuidString, item.name.prefix(200).description, item.card.column.rawValue,
                      holder.map { agents[$0] != nil ? "agent" : "person" }, holder.flatMap { people[$0]?.uuidString },
                      holder.flatMap { agents[$0]?.uuidString }, holderName, item.card.lease.map { String($0) },
                      item.card.meantFor.flatMap { cases.actor($0)?.name }, String(item.card.meantFor != nil && item.card.suggested)])
            for (index, column) in item.card.waitsFor.enumerated() {
                let other = UUID()
                try await root.execute("""
                    INSERT INTO binders.cards (id, binder_id, title, board_column, created_by_name) VALUES ($1::uuid, $2::uuid, $3, $4, 'Sam')
                    """, [other.uuidString, bed.shared.uuidString, "Waited for \(index + 1)", column.rawValue])
                try await root.execute("""
                    INSERT INTO binders.card_dependencies (id, binder_id, card_id, waits_for_id) VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid)
                    """, [UUID().uuidString, bed.shared.uuidString, card.uuidString, other.uuidString])
            }
            var approval: UUID?
            for line in item.card.timeline {
                let event = UUID()
                if line.kind == "approval" { approval = event }
                try await root.execute("""
                    INSERT INTO binders.card_events (id, binder_id, card_id, kind, author_kind, author_name, author_member_id, author_agent_id,
                                                     text, from_column, to_column)
                    VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6, $7::uuid, $8::uuid, $9, $10, $11)
                    """, [event.uuidString, bed.shared.uuidString, card.uuidString, line.kind, agents[line.by] != nil ? "agent" : "person",
                          cases.actor(line.by)?.name ?? line.by, people[line.by]?.uuidString, agents[line.by]?.uuidString, line.text,
                          line.from, line.to])
            }
            let lastBefore = try await root.value("SELECT coalesce(max(number), 0)::bigint FROM binders.card_events WHERE card_id = $1::uuid",
                                                  [card.uuidString], as: Int64.self) ?? 0

            let agent = agents[item.by]
            // Alex acts, or Alex's agent through Alex's Mac; everyone else through Sam's.
            let link = cases.person(item.by) == "Q" ? alexLink : samLink
            let call: TeamCall = switch item.action {
            case .claim: .claimCard(card, agent: agent)
            case .move(let column): .moveCard(card, to: column, agent: agent)
            case .report(let text, let links, let renewing): .report(card, progress: text, links: links, agent: agent, renewing: renewing)
            case .keepAlive: .keepAlive(card, agent: agent)
            case .ask(let text): .ask(card, question: text, agent: agent)
            case .answer(let text): .answer(card, text: text, agent: agent)
            case .requestApproval(let text): .requestApproval(card, text: text, agent: agent)
            case .decide(let approve, let reason, let which, let receipt):
                .decide(card, approve: approve, reason: reason, device: "Test Mac", approval: which == .stale ? UUID() : (which == .current ? approval : nil),
                        receipt: receipt, agent: agent)
            case .release(let text): .release(card, agent: agent, note: text)
            case .finish(let text): .finish(card, summary: text, agent: agent)
            }
            let acted = Date()
            let result = try await link.call(call)

            var problems: [String] = []
            let expected = item.expect
            if let refused = expected.refused {
                if result.ok { problems.append("applied, expected refused \(refused.code)") }
                if let refusal = result.refusal {
                    if refusal.code != refused.code { problems.append("refused \(refusal.code), expected \(refused.code)") }
                    let holderKey = refusal.holder.flatMap { cases.key(named: $0) }
                    if holderKey != refused.holder { problems.append("refusal names \(holderKey ?? "no one"), expected \(refused.holder ?? "no one")") }
                    if let deciders = refused.deciders, refusal.deciders.map({ cases.key(named: $0) ?? $0 }) != deciders {
                        problems.append("refusal says \(refusal.deciders) decide, expected \(deciders)")
                    }
                    // Who decides is the Swift rules' too: the database says it in their words.
                    if refusal.code == "not_yours_to_decide", refusal.message != BoardRules.onlyDeciders(owner: refusal.owner, meantFor: refusal.meantFor) {
                        problems.append("words “\(refusal.message)”, BoardRules says “\(BoardRules.onlyDeciders(owner: refusal.owner, meantFor: refusal.meantFor))”")
                    }
                    if !near(refusal.until, refused.until.map { start.addingTimeInterval($0) }) {
                        problems.append("refusal's time \(String(describing: refusal.until)), expected \(String(describing: refused.until)) \(tolerance)")
                    }
                    if let swift = refusal.boardError, refusal.message.replacingOccurrences(of: "\u{202F}", with: " ")
                        != (swift.errorDescription ?? "").replacingOccurrences(of: "\u{202F}", with: " ")
                        && refusal.until == nil {
                        problems.append("words “\(refusal.message)”, BoardError says “\(swift.errorDescription ?? "")”")
                    }
                }
            } else if let refusal = result.refusal {
                problems.append("refused \(refusal.code): \(refusal.message)")
            }
            let after = expected.card ?? (expected.refused != nil ? item.card : nil)
            let row = try await root.json("SELECT to_jsonb(c)::text FROM binders.cards c WHERE id = $1::uuid", [card.uuidString])
            if let after {
                if row["board_column"]?.string != after.column.rawValue {
                    problems.append("in \(row["board_column"]?.string ?? "?"), expected \(after.column.rawValue)")
                }
                let heldBy = key(kind: row["holder_kind"]?.string, member: row["holder_member_id"]?.uuid, agent: row["holder_agent_id"]?.uuid,
                                 name: row["holder_name"]?.string)
                if heldBy != after.holder { problems.append("held by \(heldBy ?? "no one"), expected \(after.holder ?? "no one")") }
                // A lease that was set before the call is measured from then, one set by it from the call.
                let base = after.lease.map { $0 == item.card.lease && after.holder == holder ? start : acted }
                if !near(row["lease_until"]?.date, after.lease.flatMap { lease in base.map { $0.addingTimeInterval(lease) } }) {
                    problems.append("lease \(String(describing: row["lease_until"]?.date)), expected \(after.lease.map { "+\(Int($0)) s" } ?? "none") \(tolerance)")
                }
            }
            let written = try await root.json("""
                SELECT coalesce(json_agg(e ORDER BY e.number), '[]')::text FROM binders.card_events e WHERE card_id = $1::uuid AND number > $2::bigint
                """, [card.uuidString, String(lastBefore)]).array ?? []
            let lines = written.map { event in
                TeamBoardCase.Line(kind: event["kind"]?.string ?? "", by: key(kind: event["author_kind"]?.string, member: event["author_member_id"]?.uuid,
                                                                             agent: event["author_agent_id"]?.uuid, name: event["author_name"]?.string) ?? "?",
                                   from: event["from_column"]?.string, to: event["to_column"]?.string, text: event["text"]?.string ?? "")
            }
            if lines != expected.events { problems.append("timeline \(lines), expected \(expected.events)") }
            let label = "case\(item.waits ? " (waits)" : ""): \(item.name)"
            if problems.isEmpty {
                passed += 1
                bed.check(true, label)
            } else {
                failed += 1
                bed.check(false, label + " — " + problems.joined(separator: "; "))
            }
        }
        bed.check(failed == 0, "all \(cases.cases.count) shared cases agree with the SQL (\(passed) passed, \(waiting) about waiting cards)")

        // MARK: What only the database checks

        let first = UUID(), second = UUID(), third = UUID(), elsewhere = UUID()
        for (id, binder) in [(first, bed.shared), (second, bed.shared), (third, bed.shared), (elsewhere, bed.personal)] {
            try await bed.expectOK(samLink, .createCard(id, binder: binder, title: "Dependency \(id.uuidString.prefix(4))", fields: ["column": "ready"]))
        }
        let selfWait = try await samLink.call(.addDependency(first, waitsFor: first))
        bed.check(selfWait.refusal?.code == "cycle", "a card can't wait for itself")
        let chain = try await samLink.call(.addDependency(first, waitsFor: second))
        let chained = try await samLink.call(.addDependency(second, waitsFor: third))
        bed.check(chain.ok && chained.ok && chain.events.first?.text.hasPrefix("Waits for “") == true, "cards wait for others, with a line on the timeline")
        let loop = try await samLink.call(.addDependency(third, waitsFor: first))
        bed.check(loop.refusal?.code == "cycle", "nor through others: \(loop.refusal?.message ?? "added")")
        let across = try await samLink.call(.addDependency(first, waitsFor: elsewhere))
        bed.check(across.refusal?.code == "other_board", "a card waits only for cards on its own board")
        let held = try await samLink.call(.claimCard(first, agent: bed.agentA))
        bed.check(held.refusal?.code == "waits_for" && held.refusal?.waitsFor.map(\.id) == [second],
                  "an agent can't claim it while what it waits for isn't done: \(held.refusal?.message ?? "claimed")")
        _ = try await samLink.call(.finish(third, summary: "Done"))
        _ = try await samLink.call(.finish(second, summary: "Done"))
        let claimed = try await samLink.call(.claimCard(first, agent: bed.agentA))
        bed.check(claimed.ok && claimed.card?.holderAgentID == bed.agentA, "once they're done, it can")
        let removed = try await samLink.call(.removeDependency(first, waitsFor: second))
        bed.check(removed.ok && removed.events.first?.text.hasPrefix("No longer waits for") == true, "and a wait can be taken off")

        // A decision whose receipt is for another request than the one waiting.
        let asking = UUID()
        try await bed.expectOK(samLink, .createCard(asking, binder: bed.shared, title: "Send the update", fields: ["column": "ready"]))
        _ = try await samLink.call(.claimCard(asking, agent: bed.agentA))
        let request = AgentApproval(action: "Send an email", recipients: ["team@example.com"], text: "The update.")
        let asked = try await samLink.call(.requestApproval(asking, text: request.timelineText, agent: bed.agentA))
        let other = AgentApproval(action: "Send an email", recipients: ["everyone@example.com"], text: "Another update.")
        let wrong = try await samLink.call(.decide(asking, approve: true, device: "Test Mac",
                                                   receipt: other.receipt(approved: true, by: "Sam", on: "Test Mac", at: Date())))
        bed.check(wrong.refusal?.code == "changed", "a receipt for something else than what waits is refused")
        let right = try await samLink.call(.decide(asking, approve: true, device: "Test Mac", approval: asked.body["approval"]?.uuid,
                                                   receipt: request.receipt(approved: true, by: "Sam", on: "Test Mac", at: Date())))
        bed.check(right.ok && right.message == "Approved. Agent A can go ahead with exactly that." && right.card?.column == .inProgress,
                  "the right one goes through: \(right.message ?? right.refusal?.message ?? "")")
    }
}
