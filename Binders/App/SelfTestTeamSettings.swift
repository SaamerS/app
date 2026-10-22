import Foundation
import BindersKit

/// Lane DB2's Settings → Team (`--selftest-teamdb-team`): setting up again changes nothing; a headless agent's invite, as
/// a link and a file, joined, its one-time password changed and no longer working; the same invite opened again is a
/// no-op; a person added, given a new password, and removed; a folder team rules a database out; the members' and
/// binders' lines; leaving the team database on this Mac. Lane DB7: invites say who made them; Settings → Team on a Mac
/// connected to a team database, drawn; and a Mac with no team, its team databases off, joining with Turn On and Join.
///
///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-teamdb-team [dir] -notesShowMarkdown NO   (dir: where to draw)
extension SelfTest {
    /// Where `--selftest-teamdb-team` draws Settings → Team, when a folder follows the flag.
    @MainActor static var teamDrawings: URL?

    @MainActor
    static func teamSettingsChecks(_ bed: TeamDBTestBed) async throws {
        let check = bed.check
        let mac = try await TeamMac.start(bed)

        // MARK: Set up again: nothing changes, and this Mac keeps its login.
        let membersBefore = mac.team.directory.members.count
        let rerun = try await mac.team.setUp(host: "127.0.0.1", port: bed.postgres.port, database: bed.database, serverName: "localhost",
                                             adminLogin: bed.adminLogin, adminPassword: bed.adminPassword, teamName: "Self-test team", yourName: "Sam")
        check(rerun == "The team database is set up. It was up to date.", "setting up again changes nothing: \(rerun)")
        check(TeamBoard.savedServer() == bed.sam, "this Mac keeps its login")
        await mac.team.readDirectory(mac.team.database!)
        check(mac.team.directory.members.count == membersBefore, "and nobody new: \(mac.team.directory.members.count)")
        // A Mac shares one way.
        AppSettings.shared.teamFolderPath = AppPaths.support.appendingPathComponent("folder-team").path
        do {
            _ = try await TeamBoard().join(TeamInvite(server: bed.alex, oneTimePassword: "x", teamName: "Self-test team"))
            check(false, "a Mac with a team folder can't join a team database")
        } catch {
            check(error.localizedDescription.hasPrefix("This Mac shares through a team folder."), "a Mac with a team folder can't join a team database: \(error.localizedDescription)")
        }
        AppSettings.shared.teamFolderPath = nil

        // MARK: A headless agent's invite: as a link and as a file, joined once, its one-time password changed.
        let invite = try await mac.team.addMember(login: "night_shift", name: "Night shift login", agentName: "Night Shift")
        check(invite.server.login == "night_shift" && invite.teamName == "Self-test team" && invite.oneTimePassword.count >= 24,
              "Add Member… for a headless agent makes an invite: \(invite.server.login), \(invite.teamName)")
        check(invite.link.flatMap { TeamInvite(link: $0) } == invite, "as a binders://team/join link")
        check(invite.invitedBy == "Sam" && invite.link?.absoluteString.contains("&by=Sam&") == true, "the invite says who made it: Sam")
        let file = invite.fileData()
        check(TeamInvite(fileData: file) == invite && (String(data: file, encoding: .utf8) ?? "").contains(TeamInvite.sendPrivately),
              "and as a .binders-invite file that says to send it privately")
        let nightShift = mac.team.directory.agents.values.first { $0.name == "Night Shift (Sam)" }
        check(nightShift?.owner == bed.samID && nightShift?.login != nil, "its agent is listed, with its owner and its own login")
        let joined = TeamDatabase.join(invite, trust: bed.postgres.trust)
        joined.testHooks.reconnectDelay = 0.2
        try await bed.waitConnected(joined)
        let password = Keychain.read(TeamDatabase.passwordKey(invite.server)) ?? ""
        check(!password.isEmpty && password != invite.oneTimePassword && joined.member?["temporary_password"]?.bool == false,
              "joining changed the one-time password for one only that Mac knows")
        await joined.stop()
        let used = await bed.failure { _ = try await TeamDatabaseLink.connect(to: invite.server, password: invite.oneTimePassword, trust: bed.postgres.trust) }
        check(used == "28P01", "the one-time password logs in no more: \(used ?? "it did")")
        // Opened again on the Mac that joined with it: nothing changes, and the password that works stays.
        TeamBoard.save(invite.server)
        let again = try await TeamBoard().join(invite)
        check(again == "This Mac is already in “Self-test team” as night_shift.", "the same invite again: \(again)")
        check(Keychain.read(TeamDatabase.passwordKey(invite.server)) == password, "and never puts the used password back")
        TeamBoard.save(bed.sam)
        TeamDatabase.forget(invite.server)

        // MARK: A person: added, a new password, removed.
        let robinInvite = try await mac.team.addMember(login: "robin", name: "Robin")
        let robin = TeamDatabase.join(robinInvite, trust: bed.postgres.trust)
        robin.testHooks.reconnectDelay = 0.2
        try await bed.waitConnected(robin)
        let robinPassword = Keychain.read(TeamDatabase.passwordKey(robinInvite.server)) ?? ""
        await robin.stop()
        await mac.team.readDirectory(mac.team.database!)
        if let member = mac.team.directory.members.values.first(where: { $0.login == "robin" }) {
            check(member.isAdmin && member.kind == "person", "Robin is a person, and an admin, as every person is")
            let reset = try await mac.team.resetPassword(member)
            check(reset.invitedBy == "Sam", "Reset Password's invite says who made it too")
            let old = await bed.failure { _ = try await TeamDatabaseLink.connect(to: robinInvite.server, password: robinPassword, trust: bed.postgres.trust) }
            check(old == "28P01", "Reset Password: the old password stops working (\(old ?? "it didn't"))")
            TeamDatabase.forget(robinInvite.server)
            let rejoined = TeamDatabase.join(reset, trust: bed.postgres.trust)
            rejoined.testHooks.reconnectDelay = 0.2
            try await bed.waitConnected(rejoined)
            check(rejoined.status == .connected, "and the new invite works")
            let newPassword = Keychain.read(TeamDatabase.passwordKey(reset.server)) ?? ""
            await rejoined.stop()
            TeamDatabase.forget(reset.server)
            try await mac.team.removeMember(member)
            let removed = await bed.failure { _ = try await TeamDatabaseLink.connect(to: reset.server, password: newPassword, trust: bed.postgres.trust) }
            check(removed != nil, "Remove: their login stops working (\(removed ?? "it didn't"))")
            check(mac.team.directory.members[member.id]?.removed == true, "and they're listed as removed")
            let mine = await bed.failure { try await mac.team.removeMember(mac.team.directory.members[bed.samID]!) }
            check(mine != nil, "an admin can't remove themselves")
        } else {
            check(false, "Robin is in the team")
        }

        // MARK: Settings → Team's lines
        let alex = try await bed.teammate()
        _ = try await alex.call(.seen(seq: 0, agents: []))
        await mac.team.readDirectory(mac.team.database!)
        let directory = mac.team.directory
        check(TeamDatabaseSection.memberLine(directory.members[bed.samID]!, me: bed.samID) == "Admin", "you: Admin")
        check(directory.members[bed.alexID].map { TeamDatabaseSection.memberLine($0, me: bed.samID).hasPrefix("Admin · seen ") } == true,
              "a teammate: Admin, and when their Mac was last seen")
        if let shared = Store.shared.binder(bed.shared), let personal = Store.shared.binder(bed.personal) {
            check(TeamDatabaseSection.sharingLine(shared, team: mac.team) == "Shared with Alex", "Shared: \(TeamDatabaseSection.sharingLine(shared, team: mac.team))")
            check(TeamDatabaseSection.sharingLine(personal, team: mac.team) == "Shared with no one but you", "Private: shared with no one but you")
        }
        let local = BinderRecord(name: "Home", colorIndex: 1)
        Store.shared.insert(local)
        check(TeamDatabaseSection.sharingLine(local, team: mac.team) == "Not shared", "a binder of this Mac's: not shared")
        let offline = TeamDatabaseStatus.offline(since: Date(), reason: "Binders can't reach the team database", retrying: true)
        check(offline.summary().hasPrefix("Offline since") && offline.check?.contains("VPN (such as Covee)") == true,
              "offline: since when, and what to check: \(offline.check ?? "-")")
        // The new switch is fingerprinted only when it says something, so an agent saved before it reads the same.
        let plain = AgentProfile(name: "Scout", wake: .board)
        var off = plain
        off.takesTeamCards = false
        check(AgentRegistry.routeFingerprint(plain) == "" && AgentRegistry.routeFingerprint(off) != "" && AgentRegistry.fingerprint(off) == AgentRegistry.fingerprint(plain),
              "Take cards from teammates off is fingerprinted, apart from what Mac 0.8.0 fingerprints")

        // MARK: Settings → Team on a team database (lane DB7)
        check(TeamDatabaseFeature.way == .database, "this Mac is on a team database")
        // The page's Your name field, so a drawing shows a name of the test's, not this Mac's user's.
        let nameBefore = AppSettings.shared.teamMemberName
        AppSettings.shared.teamMemberName = "Sam"
        let page = await teamSettingsDrawn(controller: mac.controller, name: "team-on-database", directory: teamDrawings, height: 1500)
        check(page.contains("team.database") && page.contains("team.footer.database") && !page.contains("team.join") && !page.contains("team.setUp"),
              "Settings → Team shows the team, with the team database's words in its footer, and no Join a Team…")
        // An invite for a teammate whose Mac has no team, used below once this Mac has left.
        let kimInvite = try await mac.team.addMember(login: "kim", name: "Kim")

        // MARK: Leave the team database on this Mac.
        await mac.team.leaveDatabase()
        check(TeamBoard.savedServer() == nil && (Keychain.read(TeamDatabase.passwordKey(bed.sam)) ?? "").isEmpty,
              "Leave: this Mac forgets the database and its password")
        check(Store.shared.binder(bed.shared)?.teamDatabaseKey == "" && !mac.board.cards(in: bed.shared).contains { !$0.teamShadow.isEmpty },
              "binders made here stay, local again")

        // MARK: A Mac with no team, its team databases off, gets an invite (lane DB7)
        AppDefaults.store.removeObject(forKey: TeamDatabaseFeature.key)
        check(await bed.eventually(5) { !TeamDatabaseFeature.isOn && mac.team.database == nil } && TeamDatabaseFeature.way == .folderOnly,
              "with team databases off and no team, Settings → Team is the shared folder alone")
        if let link = kimInvite.link { URLCommands.handle(link, controller: mac.controller) }
        check(mac.team.pendingInvite == kimInvite && !TeamDatabaseFeature.isOn
                && TeamDatabaseFeature.question(kimInvite, turningOn: true) == "Turn on team databases and join “Self-test team”?"
                && TeamDatabaseFeature.detail(kimInvite, turningOn: true, folderTeam: false).hasPrefix("Sam invited you, as kim. Team databases are a preview"),
              "the invite asks once, naming the team and who invited")
        mac.team.declineInvite()
        check(mac.team.pendingInvite == nil && !TeamDatabaseFeature.isOn && AppSettings.shared.teamDatabase == nil
                && (Keychain.read(TeamDatabase.passwordKey(kimInvite.server)) ?? "").isEmpty,
              "Cancel changes nothing")
        URLCommands.openInvite(kimInvite, controller: mac.controller)
        let step = try await mac.team.acceptInvite(kimInvite)
        check(step == .joined("Joined “Self-test team” as kim. Binders changes the one-time password the first time it connects.") && TeamDatabaseFeature.isOn,
              "Turn On and Join turns team databases on and joins: \(step)")
        let connected = await bed.eventually(30) { mac.team.isConnected && mac.team.directory.myName == "Kim" }
        let kimPassword = Keychain.read(TeamDatabase.passwordKey(kimInvite.server)) ?? ""
        check(connected && !kimPassword.isEmpty && kimPassword != kimInvite.oneTimePassword && mac.team.database?.member?["temporary_password"]?.bool == false,
              "this Mac is in the team as Kim, connected, its one-time password changed for one only it knows")
        let usedOnce = await bed.failure { _ = try await TeamDatabaseLink.connect(to: kimInvite.server, password: kimInvite.oneTimePassword, trust: bed.postgres.trust) }
        check(usedOnce == "28P01", "the invite's one-time password logs in no more: \(usedOnce ?? "it did")")
        AppSettings.shared.teamMemberName = "Kim"
        let joinedPage = await teamSettingsDrawn(controller: mac.controller, name: "team-joined-connected", directory: teamDrawings, height: 1300)
        check(joinedPage.contains("team.database") && joinedPage.contains("team.footer.database"), "Settings → Team shows the team Kim joined")
        AppSettings.shared.teamMemberName = nameBefore
        await mac.team.leaveDatabase()
        await alex.stop()
    }
}
