import Foundation
import BindersKit

extension SelfTest {
    /// Two Macs, as two TeamDatabase clients in one test: a change by one reaches the other through LISTEN within a
    /// second; two agents race for one card and exactly one wins; a retried operation applies once; a change made while
    /// offline is refused when it arrives, and the refusal reaches whoever made it, after a restart too.
    @MainActor
    static func teamDatabaseLiveChecks(_ bed: TeamDBTestBed) async throws {
        let check = bed.check
        let samClient = bed.client(bed.sam), alexClient = bed.client(bed.alex)
        try await bed.waitConnected(samClient)
        try await bed.waitConnected(alexClient)
        check(alexClient.binders == [bed.shared], "Alex's Mac sees the binder shared with them, and not Sam's own")
        var alexUpdates: [TeamUpdate] = []
        let collector = Task { @MainActor in
            for await update in alexClient.updates {
                alexUpdates.append(update)
                alexClient.acknowledge(update)
            }
        }
        defer { collector.cancel() }

        // Live: a card Sam's Mac makes reaches Alex's in about a second.
        let live = UUID()
        let made = try await samClient.call(.createCard(live, binder: bed.shared, title: "Live card", fields: ["column": "ready"]))
        let sent = Date()
        let arrived = await bed.eventually(5) { alexUpdates.contains { $0.rows[.cards]?.contains { $0.rowID == live } == true } }
        let latency = Date().timeIntervalSince(sent)
        check(made.ok && arrived && latency < 1, "a card one Mac makes reaches the other through LISTEN within a second (\(Int(latency * 1000)) ms)")
        let row = alexUpdates.lazy.compactMap { $0.rows[.cards]?.first { $0.rowID == live } }.first
        check(row?["title"]?.string == "Live card" && TeamCard(row: row ?? [:])?.column == .ready, "with the card as it is now")
        check(alexUpdates.contains { $0.rows[.cardEvents]?.contains { $0["card_id"]?.uuid == live && $0["kind"]?.string == "created" } == true },
              "and its timeline's first line")
        // Through the outbox too.
        let queued = samClient.send(.claimCard(live, agent: bed.agentA))
        let claimedOutcome = await samClient.outcome(of: queued)
        let claimSeen = await bed.eventually(5) {
            alexUpdates.contains { $0.rows[.cards]?.contains { $0.rowID == live && $0["holder_name"]?.string == "Agent A" } == true }
        }
        if case .applied(let result) = claimedOutcome {
            check(result.card?.holderName == "Agent A" && claimSeen, "a change sent through the outbox is applied and reaches the other Mac")
        } else {
            check(false, "a change sent through the outbox is applied (\(claimedOutcome))")
        }
        check(alexClient.acknowledgedSeq > 0, "the other Mac records how far it applied the feed")

        // A race: Sam's agent A and Alex's agent C claim the same card at once, twenty times.
        var exactlyOne = 0
        var loserHeard = 0
        var raced: [UUID] = []
        for round in 1...20 {
            let card = UUID()
            raced.append(card)
            _ = try await samClient.call(.createCard(card, binder: bed.shared, title: "Race \(round)", fields: ["column": "ready"]))
            async let first = samClient.call(.claimCard(card, agent: bed.agentA))
            async let second = alexClient.call(.claimCard(card, agent: bed.agentC))
            let (a, c) = try await (first, second)
            if a.ok != c.ok { exactlyOne += 1 }
            let winner = a.ok ? "Agent A" : "Agent C"
            let loser = a.ok ? c : a
            if loser.refusal?.code == "claimed_by", loser.refusal?.holder == winner,
               loser.refusal?.errorDescription == BoardError.claimedBy(winner, until: loser.refusal?.until).errorDescription {
                loserHeard += 1
            }
        }
        check(exactlyOne == 20, "two agents racing for one card: exactly one wins, every time (\(exactlyOne) of 20)")
        check(loserHeard == 20, "and the other hears who has it, in BoardError's words")
        let root = try await bed.root()
        let claims = try await root.value("""
            SELECT count(*)::bigint FROM binders.card_events WHERE kind = 'claimed' AND card_id = ANY (ARRAY(SELECT jsonb_array_elements_text($1::jsonb)::uuid))
            """, [TeamJSON(raced).text], as: Int64.self)
        check(claims == 20, "one claim on each card's timeline (\(claims ?? 0))")

        // A retry: the same operation sent twice applies once, and both get the first answer.
        let operation = UUID()
        let report = TeamCall.report(live, progress: "Once only", agent: bed.agentA, operation: operation)
        let once = try await samClient.call(report)
        let twice = try await samClient.call(report)
        let reports = try await root.value("SELECT count(*)::bigint FROM binders.card_events WHERE card_id = $1::uuid AND text = 'Once only'",
                                           [live.uuidString], as: Int64.self)
        check(once.ok && !once.replayed && twice.replayed && twice.card == once.card && reports == 1,
              "a retried operation applies once and gets the first answer back")
        // Sent twice at the same moment, on two connections: one applies, the other waits for it and gets its answer.
        let racing = TeamCall.report(live, progress: "At the same moment", agent: bed.agentA)
        let samAgain = try await bed.link(bed.sam)
        async let left = samClient.call(racing)
        async let right = samAgain.call(racing)
        let (l, r) = try await (left, right)
        let atOnce = try await root.value("SELECT count(*)::bigint FROM binders.card_events WHERE card_id = $1::uuid AND text = 'At the same moment'",
                                          [live.uuidString], as: Int64.self)
        check(l.ok && r.ok && l.replayed != r.replayed && atOnce == 1, "the same operation twice at once applies once")
        let misuse = await bed.failure { _ = try await samClient.call(TeamCall.report(live, progress: "Something else", operation: operation)) }
        check(misuse == "22023", "an operation id used again for another change is refused (\(misuse ?? "applied"))")
        // A refusal is an answer too: given again, even after the card changed.
        let refusedOnce = TeamCall.claimCard(live, agent: bed.agentC)
        let refusal = try await alexClient.call(refusedOnce)
        _ = try await samClient.call(.release(live))
        let refusalAgain = try await alexClient.call(refusedOnce)
        check(refusal.refusal?.code == "claimed_by" && refusalAgain.replayed && refusalAgain.refusal == refusal.refusal,
              "a refused operation retried gets the same refusal, though the card is free now")

        // Offline: Sam's Mac queues a claim while away; Alex's agent takes the card meanwhile; when Sam's Mac is back
        // (restarted: a new client reading the same folder), the database refuses it and the refusal comes back.
        let contested = UUID()
        _ = try await alexClient.call(.createCard(contested, binder: bed.shared, title: "Contested", fields: ["column": "ready"]))
        await samClient.stop()
        check(samClient.status == .off, "Sam's Mac is offline")
        let offlineClaim = samClient.send(.claimCard(contested, agent: bed.agentA))
        check(samClient.waiting == 1, "the change waits in the outbox, saved on disk")
        let taken = try await alexClient.call(.claimCard(contested, agent: bed.agentC))
        check(taken.ok, "meanwhile Alex's agent takes the card")
        let restarted = bed.client(bed.sam)
        var heard: [TeamOutboxOutcome] = []
        let listener = Task { @MainActor in
            for await outcome in restarted.outcomes { heard.append(outcome) }
        }
        defer { listener.cancel() }
        restarted.start()
        let came = await bed.eventually(10) { heard.contains { $0.operation == offlineClaim } }
        let outcome = heard.first { $0.operation == offlineClaim }?.outcome
        if case .refused(let refused) = outcome {
            check(came && refused.code == "claimed_by" && refused.holder == "Agent C",
                  "the offline change is refused when it arrives, and the refusal reaches the caller: “\(refused.errorDescription ?? "")”")
        } else {
            check(false, "the offline change is refused when it arrives (\(String(describing: outcome)))")
        }
        let asked = await restarted.outcome(of: offlineClaim)
        check(asked == outcome, "asking for that change's outcome gives the same answer")
        check(restarted.waiting == 0 && restarted.queued.isEmpty, "and it left the outbox")
        let card = try await root.json("SELECT to_jsonb(c)::text FROM binders.cards c WHERE id = $1::uuid", [contested.uuidString])
        check(card["holder_name"]?.string == "Agent C", "the card stays with the agent that took it")
        let contestedClaims = try await root.value("SELECT count(*)::bigint FROM binders.card_events WHERE card_id = $1::uuid AND kind = 'claimed'",
                                                   [contested.uuidString], as: Int64.self)
        check(contestedClaims == 1, "and the refused claim left no line on its timeline")

        // A database it can't reach: offline since then, saying why, and trying again on its own.
        var nowhere = bed.sam!
        nowhere.port = try ThrowawayPostgres.sparePort()
        TeamDatabase.keep(password: "unused", for: nowhere)
        let lost = bed.client(nowhere, folder: "nowhere")
        lost.start()
        let offline = await bed.eventually(10) {
            if case .offline(_, _, true) = lost.status { return true }
            return false
        }
        check(offline && lost.status.summary().hasPrefix("Offline since "), "a Mac that can't reach it is offline since then: \(lost.status.summary())")
        await lost.stop()
        TeamDatabase.forget(nowhere)
        await restarted.stop()
        await alexClient.stop()
    }
}
