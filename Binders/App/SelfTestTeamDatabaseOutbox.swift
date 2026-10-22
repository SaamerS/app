import Foundation
import BindersKit

extension SelfTest {
    /// A dropped connection mid-outbox: thirty changes queued, the connection dropped three times just after the database
    /// applied one and before its answer was kept, and once more from the server's side in the middle of the run. Every
    /// change is applied once, in order, and every answer reaches the caller once.
    @MainActor
    static func teamDatabaseOutboxChecks(_ bed: TeamDBTestBed) async throws {
        let check = bed.check
        let root = try await bed.root()
        let samLink = try await bed.link(bed.sam)
        let card = UUID()
        try await bed.expectOK(samLink, .createCard(card, binder: bed.shared, title: "Thirty steps", fields: ["column": "ready"]))
        try await bed.expectOK(samLink, .claimCard(card, agent: bed.agentA))

        let client = bed.client(bed.sam, folder: "sam-outbox")
        let calls = (1...30).map { TeamCall.report(card, progress: "Step \($0)", agent: bed.agentA) }
        let order = Dictionary(uniqueKeysWithValues: calls.enumerated().map { ($1.operation, $0 + 1) })
        // Queued before connecting, as on a Mac that was offline: on disk, in order.
        for call in calls.prefix(20) { client.send(call) }
        check(client.waiting == 20, "twenty changes wait in the outbox while offline")
        let file = AppPaths.support.appendingPathComponent("team-sam-outbox/outbox.json")
        // The file and its journal (lane DB10), as a Mac reads them.
        let saved = Optional(TeamDatabaseFiles.read(file.deletingLastPathComponent(), keepingAside: false).outbox)
        check(saved?.items.map(\.id) == calls.prefix(20).map(\.operation), "saved on disk, in order, each with its operation id")

        var lost: Set<Int> = [4, 11, 19]
        client.testHooks.dropAfterAnswer = { item in
            guard let step = order[item.id], lost.contains(step) else { return false }
            lost.remove(step)
            return true
        }
        var heard: [TeamOutboxOutcome] = []
        let listener = Task { @MainActor in
            for await outcome in client.outcomes { heard.append(outcome) }
        }
        defer { listener.cancel() }
        client.start()
        // The rest while it runs, and the connection cut from the server's side partway.
        let halfway = await bed.eventually(20) { heard.count >= 12 }
        for call in calls.dropFirst(20) { client.send(call) }
        let cut = try await root.value("""
            SELECT count(pg_terminate_backend(pid))::bigint FROM pg_stat_activity WHERE usename = 'sam' AND datname = $1
            """, [bed.database], as: Int64.self) ?? 0
        let finished = await bed.eventually(30) { heard.count >= 30 }
        check(halfway && cut > 0, "the server cut Sam's connections partway through (\(cut))")
        check(finished, "every change was answered (\(heard.count) of 30)")
        check(lost.isEmpty, "the connection dropped three times between a change's applying and its answer")

        let operations = heard.map(\.operation)
        check(operations == calls.map(\.operation), "answers came once each, in the order the changes were made")
        let applied = heard.compactMap { outcome -> TeamResult? in
            if case .applied(let result) = outcome.outcome { return result }
            return nil
        }
        check(applied.count == 30, "all applied, none refused or failed")
        check(applied.filter(\.replayed).count >= 3, "the ones whose answer was lost came back as the first answer (\(applied.filter(\.replayed).count) replayed)")
        let steps = try await root.json("""
            SELECT coalesce(json_agg(text ORDER BY number), '[]')::text FROM binders.card_events WHERE card_id = $1::uuid AND kind = 'progress'
            """, [card.uuidString]).array?.compactMap(\.string) ?? []
        check(steps == (1...30).map { "Step \($0)" }, "the card's timeline has each step once, in order (\(steps.count) lines)")
        let recorded = try await root.value("""
            SELECT count(*)::bigint FROM binders.operations WHERE op_id = ANY (ARRAY(SELECT jsonb_array_elements_text($1::jsonb)::uuid))
            """, [TeamJSON(calls.map(\.operation)).text], as: Int64.self)
        check(recorded == 30, "the database kept each operation id once (\(recorded ?? 0))")
        check(client.waiting == 0, "the outbox is empty")
        let after = Optional(TeamDatabaseFiles.read(file.deletingLastPathComponent(), keepingAside: false).outbox)
        check(after?.isEmpty == true, "and so is its file")
        let lease = try await root.json("SELECT to_jsonb(c)::text FROM binders.cards c WHERE id = $1::uuid", [card.uuidString])
        check(lease["holder_name"]?.string == "Agent A" && (lease["lease_until"]?.date ?? .distantPast) > Date().addingTimeInterval(25 * 60),
              "the agent's reports kept its claim alive")
        await client.stop()
    }
}
