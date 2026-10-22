import XCTest
@testable import BindersKit

/// Who an invite is from (lane DB7): the Mac that opens it says who invited, and an invite an earlier Binders made, or an
/// earlier Binders opening this one, works as before.
final class TeamInviteFromTests: XCTestCase {
    private let server = TeamDatabaseServer(host: "10.20.0.4", port: 6432, database: "binders_team", login: "robin", serverName: "team.postgres.example")

    func testAnInviteSaysWhoItsFromAsALinkAndAsAFile() throws {
        let invite = TeamInvite(server: server, oneTimePassword: "ab12-CD34+ef/56=&?", teamName: "Design & Ops", invitedBy: "Sam & Alex")
        let link = try XCTUnwrap(invite.link)
        XCTAssertTrue(link.absoluteString.hasPrefix("binders://team/join?v=1&team=Design%20%26%20Ops&by=Sam%20%26%20Alex&host="), link.absoluteString)
        XCTAssertEqual(TeamInvite(link: link), invite)
        XCTAssertEqual(TeamInvite(link: link)?.invitedBy, "Sam & Alex")
        let file = invite.fileData()
        XCTAssertEqual(TeamInvite(fileData: file), invite)
        let text = String(data: file, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"invited_by\"") && text.contains("An invite from Sam & Alex to join “Design & Ops”"), text)
    }

    func testAnInviteAnEarlierBindersMadeHasNoOneItsFrom() throws {
        // As Binders 0.10.0 makes them: no `by` in the link, no `invited_by` in the file.
        let link = URL(string: "binders://team/join?v=1&team=Harbor&host=db.example&port=5432&database=binders&login=robin&password=p1")!
        let fromLink = try XCTUnwrap(TeamInvite(link: link))
        XCTAssertNil(fromLink.invitedBy)
        XCTAssertEqual(fromLink.teamName, "Harbor")
        let file = Data("""
        {"binders_invite": 1, "team": "Harbor", "host": "db.example", "port": 5432, "database": "binders", "login": "robin",
         "one_time_password": "p1", "about": "An invite to join “Harbor” in Binders, as robin."}
        """.utf8)
        let fromFile = try XCTUnwrap(TeamInvite(fileData: file))
        XCTAssertNil(fromFile.invitedBy)
        XCTAssertEqual(fromFile, fromLink)
        // Saved as JSON before the field existed, it still reads.
        let old = Data(#"{"server": {"host": "db.example", "port": 5432, "database": "binders", "login": "robin"}, "oneTimePassword": "p1", "teamName": "Harbor"}"#.utf8)
        let decoded = try JSONDecoder().decode(TeamInvite.self, from: old)
        XCTAssertNil(decoded.invitedBy)
        XCTAssertEqual(decoded, fromLink)
        // Without who it's from, the link and the file read as they did.
        XCTAssertFalse(fromLink.link?.absoluteString.contains("by=") ?? true)
        XCTAssertFalse(String(data: fromLink.fileData(), encoding: .utf8)?.contains("invited_by") ?? true)
        let blank = TeamInvite(server: server, oneTimePassword: "p", teamName: "Harbor", invitedBy: "  ")
        XCTAssertFalse(blank.link?.absoluteString.contains("by=") ?? true, "a blank name isn't sent")
    }

    func testAnEarlierBindersReadsWhatItKnowsOfANewInvite() throws {
        // What 0.10.0's reader does with this one: it knows every key but `by`, and ignores keys it doesn't know.
        let invite = TeamInvite(server: server, oneTimePassword: "p2", teamName: "Harbor", invitedBy: "Sam")
        let link = try XCTUnwrap(invite.link)
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let known: Set<String> = ["v", "team", "host", "port", "database", "login", "tls", "password"]
        XCTAssertEqual(Set(items.map(\.name)).subtracting(known), ["by"])
        var withoutBy = URLComponents(url: link, resolvingAgainstBaseURL: false)!
        withoutBy.queryItems = items.filter { $0.name != "by" }
        var expected = invite
        expected.invitedBy = nil
        XCTAssertEqual(TeamInvite(link: withoutBy.url!), expected)
    }
}
