import AppKit
import SwiftUI
import BindersKit

extension SelfTest {
    /// Lane DB5: a team's database set up with migrations 1 to 7, as Binders 0.10.0 (38) leaves it, with a team's work in
    /// it (boards, notes, folders, meetings, to-dos, knowledge, a headless agent), then this build. This Mac (Sam, an admin)
    /// and a teammate's Mac each say it needs an update; a member who isn't an admin hears who can run it; a wrong admin
    /// password changes nothing; Update the Team Database… with the server's admin login applies 8 and this Mac connects
    /// again; everything made before is as it was, migrations 1 to 7 untouched; the rules migration 8 brings hold from
    /// then on; turning the team database's default off while Binders runs disconnects at once, and on reconnects.
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-teamdb-update -notesShowMarkdown NO
    @MainActor
    static func teamUpdateChecks(_ bed: TeamDBTestBed) async throws {
        let check = bed.check
        let root = try await bed.root()
        let samLink = try await bed.link(bed.sam)
        let alexLink = try await bed.link(bed.alex)
        let shared = bed.shared

        let applied = try await root.json("""
            SELECT json_agg(json_build_object('version', version, 'name', name, 'checksum', checksum, 'at', applied_at, 'by', applied_by)
                            ORDER BY version)::text FROM binders.schema_migrations
            """).array ?? []
        check(applied.map { $0["version"]?.int ?? 0 } == Array(1...7)
                && applied.map { $0["checksum"]?.string ?? "" } == TeamSchema.migrations.prefix(7).map(\.checksum),
              "the team's database is as Binders 0.10.0 sets it up: migrations 1 to 7, with their checksums")

        // MARK: A team's work, made at 7 through 7's own functions.

        let waitedFor = UUID(), waiting = UUID(), asked = UUID(), approval = UUID(), meant = UUID()
        try await bed.expectOK(samLink, .createCard(waitedFor, binder: shared, title: "Book the hall", fields: ["column": "ready"]))
        try await bed.expectOK(samLink, .createCard(waiting, binder: shared, title: "Print the badges", fields: ["column": "ready", "waits_for": .array([TeamJSON(waitedFor)])]))
        try await bed.expectOK(alexLink, .createCard(asked, binder: shared, title: "Write the welcome note", fields: ["column": "ready"]))
        try await bed.expectOK(alexLink, .claimCard(asked, agent: bed.agentC))
        try await bed.expectOK(alexLink, .report(asked, progress: "Drafted two lines", agent: bed.agentC))
        try await bed.expectOK(alexLink, .ask(asked, question: "Formal or friendly?", agent: bed.agentC))
        try await bed.expectOK(alexLink, .answer(asked, text: "Friendly."))
        try await bed.expectOK(samLink, .createCard(approval, binder: shared, title: "Send the invitations", fields: ["column": "ready"]))
        try await bed.expectOK(samLink, .claimCard(approval, agent: bed.agentA))
        let request = AgentApproval(action: "Send an email", recipients: ["guests@example.com"], text: "You're invited.")
        try await bed.expectOK(samLink, .requestApproval(approval, text: request.timelineText, agent: bed.agentA))
        try await bed.expectOK(samLink, .createCard(meant, binder: shared, title: "Order the banners", fields: ["column": "backlog"]))
        try await bed.expectOK(samLink, .assignCard(meant, to: "Alex"))
        let folder = UUID(), note = UUID(), meeting = UUID(), todo = UUID()
        try await bed.expectOK(samLink, .putFolder(folder, binder: shared, fields: ["name": "Launch"]))
        // A note as Binders' note engine makes one (its Automerge document and changes), sent as an earlier Mac sent it.
        let plan = "# Launch plan\n\nThe hall on Main Street."
        let earlier = bed.client(bed.sam, folder: "sam-at-7")
        TeamNoteEngine(database: earlier, folder: AppPaths.support.appendingPathComponent("sam-at-7-documents", isDirectory: true))
            .share(note, binder: shared, folder: folder, text: plan, props: TeamNoteProps().values, fields: ["title": "Launch plan"])
        for item in earlier.queued { try await bed.expectOK(samLink, item.call) }
        let rows: [(TeamTable, TeamRow)] = [
            (.meetings, ["id": TeamJSON(meeting), "binder_id": TeamJSON(shared), "title": "Launch standup", "live": false]),
            (.meetingSegments, ["id": TeamJSON(UUID()), "binder_id": TeamJSON(shared), "meeting_id": TeamJSON(meeting), "position": 0,
                                "speaker": "Sam", "text": "The banners arrive Monday."]),
            (.todos, ["id": TeamJSON(todo), "binder_id": TeamJSON(shared), "source_kind": "meeting", "source_id": TeamJSON(meeting),
                      "text": "Call the printer"]),
            (.knowledgeChunks, ["id": TeamJSON(UUID()), "binder_id": TeamJSON(shared), "source_kind": "meeting", "source_id": TeamJSON(meeting),
                                "text": "The banners arrive Monday."]),
        ]
        for (table, row) in rows { try await bed.expectOK(samLink, .put(row, in: table)) }
        // A headless agent listed before migration 8, with a login of its own: Sam's.
        let robot = UUID(), robotLogin = UUID()
        try await bed.expectOK(samLink, .addMember(robotLogin, login: "build_bot", name: "Build bot", verifier: TeamPassword.verifier(for: "unused-1"),
                                                   agent: (robot, "Build bot (Sam)")))
        try await bed.expectOK(samLink, .shareBinder(shared, with: robotLogin))
        let robotServer = bed.postgres.server(database: bed.database, login: "build_bot")
        let robotPassword = TeamPassword.generate()
        TeamDatabase.keep(password: "unused-1", for: robotServer)
        defer { TeamDatabase.forget(robotServer) }
        let robotLink = try await bed.link(robotServer)
        try await bed.expectOK(robotLink, .changePassword(verifier: TeamPassword.verifier(for: robotPassword)))
        TeamDatabase.keep(password: robotPassword, for: robotServer)
        // A person who isn't an admin, as an admin could make one with SQL: Robin, on a one-time password.
        let robinInvite = try await bed.client(bed.sam, folder: "sam-invites").addMemberDirect(on: samLink, login: "robin", name: "Robin")
        try await root.execute("UPDATE binders.members SET is_admin = false WHERE login = 'robin'")
        TeamDatabase.keep(password: robinInvite.oneTimePassword, for: robinInvite.server)
        defer { TeamDatabase.forget(robinInvite.server) }
        try await bed.expectOK(samLink, .shareBinder(shared, with: try await root.value("SELECT id::text FROM binders.members WHERE login = 'robin'",
                                                                                       as: String.self).flatMap(UUID.init(uuidString:)) ?? UUID()))
        // 7's rules: an agent hands a card that still waits for another over for review.
        let handedOver = UUID()
        try await bed.expectOK(samLink, .createCard(handedOver, binder: shared, title: "Hang the banners", fields: ["column": "ready", "waits_for": .array([TeamJSON(meant)])]))
        let oldRule = try await samLink.call(.moveCard(handedOver, to: .review, agent: bed.agentA))
        check(oldRule.ok, "under 7's rules an agent hands over a card that still waits for another")
        let oldRobot = try await robotLink.call(.claimCard(waitedFor))
        check(oldRobot.ok, "and a headless agent takes a card with no Auto step")
        try await bed.expectOK(samLink, .release(waitedFor))

        /// Everything the team's database holds, as fingerprints: every binder table and the team's, the feed up to
        /// `through`, and 1 to 7's records. A Mac's word that it's around (`seen`: when, how far it read, its agents online)
        /// isn't the team's work, and agents leave out the column 8 adds.
        func fingerprints(through: Int64) async throws -> [String: String] {
            var prints: [String: String] = [:]
            for table in TeamTable.binderTables + [.members, .agents, .teamSettings] {
                let row = switch table {
                case .agents: "to_jsonb(t) - 'auto' - 'online_at' - 'updated_at'"
                case .members: "to_jsonb(t) - 'seen_at' - 'seen_seq' - 'updated_at'"
                default: "to_jsonb(t)"
                }
                prints[table.rawValue] = try await root.value("""
                    SELECT coalesce(md5(string_agg((\(row))::text, ',' ORDER BY t.id)), '') || ':' || count(*) FROM binders.\(table.rawValue) t
                    """, as: String.self) ?? ""
            }
            prints["changes"] = try await root.value("""
                SELECT coalesce(md5(string_agg(to_jsonb(c)::text, ',' ORDER BY c.seq)), '') FROM binders.changes c WHERE c.seq <= $1::bigint
                """, [String(through)], as: String.self) ?? ""
            prints["schema_migrations"] = try await root.value("""
                SELECT md5(string_agg(version || '|' || name || '|' || checksum || '|' || applied_at || '|' || applied_by, ',' ORDER BY version))
                FROM binders.schema_migrations WHERE version <= 7
                """, as: String.self) ?? ""
            return prints
        }
        // The test's own connections, before this Mac makes any.
        let ownConnections = try await root.value("SELECT count(*)::bigint FROM pg_stat_activity WHERE usename = 'sam'", as: Int64.self) ?? 0

        // MARK: This build meets it

        let controller = DictationController()
        _ = controller.board
        let team = controller.teamBoard
        team.trust = bed.postgres.trust
        team.folderOverride = AppPaths.support.appendingPathComponent("board-sam", isDirectory: true)
        team.prepare = { $0.testHooks.reconnectDelay = 0.2 }
        AppDefaults.store.set(true, forKey: TeamDatabaseFeature.key)
        TeamBoard.save(bed.sam)
        team.start()
        let told = await bed.eventually(15) { team.database?.update != nil }
        let update = team.database?.update
        check(told && update?.missing == [8] && update?.youAreAdmin == true && update?.otherAdmins == ["Alex"],
              "this Mac says the team's database needs an update, that Sam can run it, and that Alex can too: \(String(describing: update))")
        let summary = team.status.summary()
        check(summary.contains("needs an update that this version of Binders brings") && !summary.lowercased().contains("migration")
                && !summary.lowercased().contains("schema") && team.status.check == nil,
              "the status line says so in plain words, with no VPN to check: “\(summary)”")
        check(!team.isConnected && Store.shared.binder(shared) == nil, "and it doesn't connect, so nothing of the team's comes yet")
        check(await settingsShow("team.update", controller: controller), "Settings → Team offers Update the Team Database…")

        let robin = bed.client(robinInvite.server, folder: "robin")
        robin.start()
        let robinTold = await bed.eventually(15) { robin.update != nil }
        check(robinTold && robin.update?.youAreAdmin == false && robin.update?.otherAdmins == ["Alex", "Sam"],
              "a member who isn't an admin hears that Alex or Sam can, their one-time password changed meanwhile: \(String(describing: robin.update))")
        check(TeamDatabaseSection.askAdmins(robin.update?.otherAdmins ?? []) == "Ask Alex or Sam to update it: an admin runs it once, from Settings → Team.",
              "in Settings → Team's words: \(TeamDatabaseSection.askAdmins(robin.update?.otherAdmins ?? []))")
        await robin.stop()
        let changedRobin = try await root.value("SELECT NOT temporary_password FROM binders.members WHERE login = 'robin'", as: Bool.self)
        check(changedRobin == true, "Robin's one-time password went as it would have once connected")

        // A wrong admin password changes nothing.
        let wrong = await bed.failure { _ = try await team.updateDatabase(adminLogin: bed.adminLogin, adminPassword: "not-it") }
        let stillSeven = try await root.value("SELECT max(version) FROM binders.schema_migrations", as: Int32.self)
        check(wrong != nil && stillSeven == 7, "a wrong admin password updates nothing (\(wrong ?? "updated"))")

        // MARK: Update the Team Database…

        let lastSeq = try await root.value("SELECT coalesce(max(seq), 0)::bigint FROM binders.changes", as: Int64.self) ?? 0
        let before = try await fingerprints(through: lastSeq)
        let started = Date()
        let words = try await team.updateDatabase(adminLogin: bed.adminLogin, adminPassword: bed.adminPassword)
        check(words.hasPrefix("Updated the team's database.") && !words.lowercased().contains("migration"), "Update says what it did: “\(words)”")
        let reconnected = await bed.eventually(30) {
            team.isConnected && team.database?.update == nil && Store.shared.binder(shared)?.teamDatabaseKey == bed.sam.key
        }
        check(reconnected, "and this Mac connects again, in \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(team.status)")
        let after = try await root.json("""
            SELECT json_agg(json_build_object('version', version, 'name', name, 'checksum', checksum, 'at', applied_at, 'by', applied_by)
                            ORDER BY version)::text FROM binders.schema_migrations
            """).array ?? []
        check(after.map { $0["version"]?.int ?? 0 } == Array(1...8) && after.last?["checksum"]?.string == TeamSchema.migrations.last?.checksum
                && after.last?["by"]?.string == bed.adminLogin, "migration 8 is applied, recorded with its checksum, by the admin login")
        check(Array(after.prefix(7)) == applied, "migrations 1 to 7 are recorded exactly as they were")
        let unchanged = try await fingerprints(through: lastSeq)
        let differ = before.keys.sorted().filter { before[$0] != unchanged[$0] }
        check(differ.isEmpty, "everything made before is as it was, the feed included: boards, timelines, notes, folders, meetings, to-dos, knowledge, members, agents \(differ)")
        // What the update itself wrote is in the feed with no member (the admin login isn't one); this Mac's own word
        // that it's around, since it connected again, is Sam's.
        let byUpdate = try await root.json("""
            SELECT coalesce(json_agg(json_build_object('table', table_name, 'kind', kind) ORDER BY seq), '[]')::text
            FROM binders.changes WHERE seq > $1::bigint AND member_id IS NULL
            """, [String(lastSeq)]).array ?? []
        let bySam = try await root.json("""
            SELECT coalesce(json_agg(json_build_object('table', table_name, 'kind', kind) ORDER BY seq), '[]')::text
            FROM binders.changes WHERE seq > $1::bigint AND member_id IS NOT NULL
            """, [String(lastSeq)])
        check(byUpdate.isEmpty, "and the update itself changed no row: nothing in the feed from it (this Mac since: \(bySam))")
        let adminServer = TeamDatabaseServer(host: bed.sam.host, port: bed.sam.port, database: bed.database, login: bed.adminLogin, serverName: bed.sam.serverName)
        check(Keychain.read(TeamDatabase.passwordKey(adminServer)).map(\.isEmpty) ?? true && AppSettings.shared.teamDatabase?.contains(bed.adminLogin) != true,
              "the admin login isn't kept on this Mac")

        // The Mac's copy: the boards as the database has them.
        let cards = [waitedFor, waiting, asked, approval, meant, handedOver]
        let copied = await bed.eventually(15) { cards.allSatisfy { controller.board.card($0) != nil } }
        check(copied && controller.board.card(asked)?.column == .inProgress && controller.board.card(approval)?.column == .blocked
                && controller.board.card(meant)?.meantFor == "Alex" && controller.board.card(waiting)?.waitsFor == [waitedFor.uuidString]
                && controller.board.timeline(asked).count >= 5,
              "this Mac's copy of the shared board is as it was made: columns, who it's for, what waits, timelines")
        let noted = await bed.eventually(15) { Store.shared.note(note)?.text == plan }
        check(noted && Store.shared.note(note)?.folderID == folder, "and the note made at 7 is here, word for word, in its folder")

        // MARK: Migration 8's rules from now on

        let newRule = try await samLink.call(.moveCard(waiting, to: .review, agent: bed.agentA))
        check(newRule.refusal?.code == "waits_for", "an agent can't hand over a card that still waits for another now")
        let robotRow = try await root.value("SELECT auto FROM binders.agents WHERE id = $1::uuid", [robot.uuidString], as: Bool.self)
        let robotClaim = try await robotLink.call(.claimCard(waitedFor))
        check(robotRow == false && robotClaim.refusal?.code == "auto_off" && robotClaim.refusal?.owner == "Sam",
              "a headless agent listed before migration 8 starts with its Auto off, and hears Sam can turn it on")
        let decision = try await alexLink.call(.decide(approval, approve: true, device: "Alex's Mac"))
        check(decision.refusal?.code == "not_yours_to_decide", "Alex can't decide on what Sam's agent asked approval for")
        // The Auto switch, from Settings → Team on Sam's Mac.
        await team.readDirectory(team.database!)
        guard let listed = team.directory.agents[robot] else { return check(false, "Settings → Team lists the headless agent") }
        check(listed.isHeadless && listed.auto == false && TeamDatabaseSection.agentLine(listed, directory: team.directory).hasSuffix("Auto off: takes no cards"),
              "Settings → Team lists it with its Auto off: “\(TeamDatabaseSection.agentLine(listed, directory: team.directory))”")
        check(await settingsShow("team.auto", controller: controller), "and an Auto switch on it, as it's Sam's")
        try await team.setAuto(listed, on: true)
        let robotNow = try await robotLink.call(.claimCard(waitedFor))
        check(team.directory.agents[robot]?.auto == true && robotNow.ok, "Sam turns its Auto on, and it takes the card")
        let alex = try await bed.teammate()
        let alexsView = TeamDirectory.Agent(row: (try await alex.rows(.agents, ids: [robot])).first ?? [:])
        check(alexsView?.auto == true && alexsView.map { TeamDatabaseSection.agentLine($0, directory: team.directory) }?.contains("Auto on") == true,
              "a teammate's Mac shows that its owner turned Auto on")
        await alex.stop()

        // MARK: The default, turned off and on while Binders runs

        AppDefaults.store.set(false, forKey: TeamDatabaseFeature.key)
        let off = await bed.eventually(5) { team.database == nil && team.server == nil }
        check(off && team.status == .off && !team.covers(shared) && TeamBoard.current == nil && controller.board.isTeams(controller.board.card(asked)!) == false,
              "turned off while Binders runs, it disconnects at once, and no board goes through it")
        var connections: Int64 = 99
        let deadline = Date().addingTimeInterval(5)
        repeat {
            connections = try await root.value("SELECT count(*)::bigint FROM pg_stat_activity WHERE usename = 'sam'", as: Int64.self) ?? 99
            if connections <= ownConnections { break }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        check(connections <= ownConnections, "this Mac's connections closed (\(connections) left, the test's own \(ownConnections))")
        AppDefaults.store.set(true, forKey: TeamDatabaseFeature.key)
        let back = await bed.eventually(30) { team.isConnected && team.covers(shared) }
        check(back, "on again, it connects to the database set up here: \(team.status)")
        await team.stop()
    }

    /// Settings → Team drawn in a window as tall as the page: whether a part named `probe` (FitProbe) showed.
    @MainActor
    static func settingsShow(_ probe: String, controller: DictationController) async -> Bool {
        FitProbe.isOn = true
        defer { FitProbe.isOn = false }
        let navigation = HubNavigation()
        navigation.selection = .settings
        navigation.pendingSettingsPage = .team
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 2400), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let hosting = NSHostingView(rootView: SettingsView()
            .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
            .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1_800))
        let shown = !FitProbe.frames(probe, in: window).isEmpty
        window.close()
        return shown
    }
}
