import XCTest
@testable import BindersKit

/// The worktrees Binders makes for the CLI tools: their names, every git call's arguments, and what stops a commit or the
/// next run.
final class AgentWorktreeTests: XCTestCase {
    private let card = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let root = "/Users/sam/.binders"

    func testNamesAndPlaces() {
        XCTAssertEqual(AgentWorktree.name(card: card, tool: .codex), "binders-3f2504e04f89-codex", "12 hex digits of the card")
        XCTAssertEqual(AgentWorktree.branch(card: card, tool: .opencode), "binders-card-3f2504e04f89-opencode")
        XCTAssertEqual(AgentWorktree.branch(card: card, tool: .copilot), "binders-card-3f2504e04f89-copilot")
        let app = AgentWorktree.repositoryFolder("/Users/sam/code/app")
        XCTAssertTrue(app.hasPrefix("app-") && app.count == "app-".count + 8, app)
        XCTAssertEqual(AgentWorktree.repositoryFolder("/Users/sam/code/app/"), app, "a trailing slash is the same repository")
        XCTAssertNotEqual(AgentWorktree.repositoryFolder("/Users/sam/other/app"), app, "two repositories called app don't share a folder")
        XCTAssertTrue(AgentWorktree.repositoryFolder("/Users/sam/My Projects/café app").hasPrefix("caf--app-"), "spaces and other letters as -")
        XCTAssertTrue(AgentWorktree.repositoryFolder("/Users/sam/" + String(repeating: "x", count: 50)).hasPrefix(String(repeating: "x", count: 32) + "-"))
        XCTAssertTrue(AgentWorktree.repositoryFolder("/").hasPrefix("repo-"))
        XCTAssertEqual(AgentWorktree.path(root: root + "/", repository: "/Users/sam/code/app", card: card, tool: .codex),
                       "\(root)/worktrees/\(app)/binders-3f2504e04f89-codex")
        // Two cards that share their first 8 hex digits get folders of their own.
        let twin = UUID(uuidString: "3F2504E0-1234-11D3-9A0C-0305E82C3301")!
        XCTAssertNotEqual(AgentWorktree.name(card: twin, tool: .codex), AgentWorktree.name(card: card, tool: .codex))
        // And never Claude Code's: its worktree is binders-<8> in the repository.
        XCTAssertNotEqual(AgentWorktree.name(card: card, tool: .codex), ClaudeCodeLaunch.worktreeName(for: card))
        XCTAssertEqual(AgentWorktree.commitMessage(card: card, agent: "Codex · app"), "Binders card 3f2504e04f89: changes from Codex · app")
    }

    func testEveryGitCall() {
        let safety = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "submodule.recurse=false", "-c", "diff.ignoreSubmodules=all",
                      "-c", "status.submoduleSummary=false", "-c", "gc.auto=0", "-c", "maintenance.auto=false"]
        XCTAssertEqual(AgentWorktree.safety, safety)
        let repo = "/Users/sam/code/app", wt = "\(root)/worktrees/app-1/binders-3f2504e04f89-codex", git = "/Users/sam/code/app/.git/worktrees/binders-3f2504e04f89-codex"
        let branch = "binders-card-3f2504e04f89-codex"
        XCTAssertEqual(AgentWorktree.checkRepository(repo), ["-C", repo] + safety + ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"])
        XCTAssertEqual(AgentWorktree.list(repo), ["-C", repo] + safety + ["worktree", "list", "--porcelain"])
        XCTAssertEqual(AgentWorktree.addNew(repo, path: wt, branch: branch), ["-C", repo] + safety + ["worktree", "add", "-b", branch, wt, "HEAD"])
        XCTAssertEqual(AgentWorktree.addExisting(repo, path: wt, branch: branch), ["-C", repo] + safety + ["worktree", "add", wt, branch])
        XCTAssertEqual(AgentWorktree.addReplacing(repo, path: wt, branch: branch), ["-C", repo] + safety + ["worktree", "add", "--force", wt, branch])
        XCTAssertEqual(AgentWorktree.remove(repo, path: wt), ["-C", repo] + safety + ["worktree", "remove", "--force", wt])
        XCTAssertEqual(AgentWorktree.absoluteGitDir(wt), ["-C", wt] + safety + ["rev-parse", "--absolute-git-dir"])
        let on = ["--git-dir=\(git)", "--work-tree=\(wt)"] + safety
        XCTAssertEqual(AgentWorktree.status(gitDir: git, workTree: wt), on + ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all"])
        XCTAssertEqual(AgentWorktree.addAll(gitDir: git, workTree: wt), on + ["add", "-A"])
        XCTAssertEqual(AgentWorktree.staged(gitDir: git, workTree: wt), on + ["diff", "--cached", "--raw", "-z", "--no-renames"])
        XCTAssertEqual(AgentWorktree.unstage(gitDir: git, workTree: wt), on + ["reset", "-q"])
        XCTAssertEqual(AgentWorktree.commit(gitDir: git, workTree: wt, message: "m"), on + ["-c", "commit.gpgsign=false", "commit", "--no-verify", "-q", "-m", "m"])
        XCTAssertEqual(AgentWorktree.head(gitDir: git, workTree: wt), on + ["symbolic-ref", "HEAD"])
        // Every call on a worktree names its git folder and work tree; none prunes your repository's worktrees.
        let onWorktree = [AgentWorktree.status(gitDir: git, workTree: wt), AgentWorktree.addAll(gitDir: git, workTree: wt), AgentWorktree.staged(gitDir: git, workTree: wt),
                          AgentWorktree.tracked(gitDir: git, workTree: wt), AgentWorktree.unstage(gitDir: git, workTree: wt),
                          AgentWorktree.commit(gitDir: git, workTree: wt, message: "m"), AgentWorktree.shortHead(gitDir: git, workTree: wt),
                          AgentWorktree.committedFiles(gitDir: git, workTree: wt), AgentWorktree.head(gitDir: git, workTree: wt)]
        for arguments in onWorktree {
            XCTAssertEqual(Array(arguments.prefix(2)), ["--git-dir=\(git)", "--work-tree=\(wt)"])
            XCTAssertEqual(Array(arguments[2..<(2 + safety.count)]), safety)
        }
        let all = onWorktree + [AgentWorktree.checkRepository(repo), AgentWorktree.list(repo), AgentWorktree.addNew(repo, path: wt, branch: branch),
                                AgentWorktree.addExisting(repo, path: wt, branch: branch), AgentWorktree.addReplacing(repo, path: wt, branch: branch),
                                AgentWorktree.remove(repo, path: wt), AgentWorktree.branchExists(repo, branch: branch)]
        XCTAssertFalse(all.contains { $0.contains("prune") })
        XCTAssertFalse(all.contains { $0.contains("checkout") || $0.contains("switch") || $0.contains("stash") || $0.contains("clean") })
    }

    func testReadingGitsAnswers() {
        let porcelain = "worktree /Users/sam/code/app\nHEAD abc\nbranch refs/heads/main\n\nworktree /Users/sam/.binders/worktrees/app-1/binders-x-codex\nHEAD def\nbranch refs/heads/binders-card-x-codex\nprunable gitdir file points to non-existent location\n\nworktree /tmp/detached\nHEAD 123\ndetached\n"
        XCTAssertEqual(AgentWorktree.listed(porcelain), [
            AgentWorktree.Listed(path: "/Users/sam/code/app", branch: "refs/heads/main"),
            AgentWorktree.Listed(path: "/Users/sam/.binders/worktrees/app-1/binders-x-codex", branch: "refs/heads/binders-card-x-codex"),
            AgentWorktree.Listed(path: "/tmp/detached", branch: nil),
        ])
        let raw = ":100644 100644 aaa bbb M\0README.md\0:000000 100644 000 ccc A\0new file.txt\0:100644 000000 ddd 000 D\0gone.txt\0"
        XCTAssertEqual(AgentWorktree.changes(raw), [AgentWorktree.Change(status: "M", newMode: "100644", path: "README.md"),
                                                    AgentWorktree.Change(status: "A", newMode: "100644", path: "new file.txt"),
                                                    AgentWorktree.Change(status: "D", newMode: "000000", path: "gone.txt")])
        XCTAssertEqual(AgentWorktree.nestedRepository(status: " M README.md\0?? notes.txt\0?? sub/\0"), "sub/", "a folder git shows whole")
        XCTAssertNil(AgentWorktree.nestedRepository(status: " M README.md\0?? docs/new.md\0R  new.md\0old.md\0"))
        XCTAssertEqual(AgentWorktree.pointer("gitdir: /Users/sam/code/app/.git/worktrees/binders-x-codex\n"), "/Users/sam/code/app/.git/worktrees/binders-x-codex")
        XCTAssertNil(AgentWorktree.pointer("not a pointer"))
    }

    func testWhatStopsACommit() {
        func change(_ status: String, _ mode: String = "100644", _ path: String = "f") -> AgentWorktree.Change {
            AgentWorktree.Change(status: status, newMode: mode, path: path)
        }
        XCTAssertNil(AgentWorktree.stagedProblem([change("M"), change("A")], tracked: 40, bytes: 1_000), "a change that passes")
        XCTAssertEqual(AgentWorktree.stagedProblem([change("A", "160000", "vendor/lib")], tracked: 40, bytes: 0), .gitlink("vendor/lib"))
        XCTAssertEqual(AgentWorktree.stagedProblem(Array(repeating: change("A"), count: 2_001), tracked: 40, bytes: 0), .tooMany(2_001))
        XCTAssertNil(AgentWorktree.stagedProblem(Array(repeating: change("M"), count: 2_000), tracked: 4_000, bytes: 0), "2,000 is all right")
        XCTAssertEqual(AgentWorktree.stagedProblem([change("A")], tracked: 40, bytes: 101 * 1024 * 1024), .tooBig(101 * 1024 * 1024))
        XCTAssertEqual(AgentWorktree.stagedProblem(Array(repeating: change("D"), count: 21), tracked: 40, bytes: 0), .deletes(21, of: 40))
        XCTAssertNil(AgentWorktree.stagedProblem(Array(repeating: change("D"), count: 20), tracked: 30, bytes: 0), "20 or fewer")
        XCTAssertNil(AgentWorktree.stagedProblem(Array(repeating: change("D"), count: 30), tracked: 100, bytes: 0), "half or fewer")
        let wt = "~/.binders/worktrees/app-1/binders-3f2504e04f89-codex"
        XCTAssertEqual(AgentWorktree.describe(.deletes(21, of: 40), tool: .codex, worktree: wt),
                       "Didn't commit Codex's changes: they delete 21 of the branch's 40 files. They're still in \(wt). Commit them yourself if that's right.")
        XCTAssertEqual(AgentWorktree.describe(.nested("sub/"), tool: .opencode, worktree: wt),
                       "Didn't commit OpenCode's changes: it made a git repository inside the worktree, at sub/. They're still in \(wt).")
        XCTAssertEqual(AgentWorktree.describe(.pointerChanged, tool: .copilot, worktree: wt),
                       "Didn't commit GitHub Copilot CLI's changes: the worktree's .git file was changed during the run. They're still in \(wt).")
        XCTAssertTrue(AgentWorktree.describe(.tooMany(2_001), tool: .codex, worktree: wt).contains("2,001 files, more than the 2,000"))
        XCTAssertTrue(AgentWorktree.describe(.noIdentity, tool: .codex, worktree: wt).hasPrefix("Couldn't commit Codex's changes: git needs your name and email"))
    }

    func testUsingAWorktreeAgain() {
        let record = AgentWorktreeRecord(card: card, tool: .codex, repository: "/Users/sam/code/app", commonDir: "/Users/sam/code/app/.git",
                                         path: "\(root)/worktrees/app-1/binders-3f2504e04f89-codex", branch: "binders-card-3f2504e04f89-codex",
                                         gitDir: "/Users/sam/code/app/.git/worktrees/binders-3f2504e04f89-codex", ready: true, made: Date(timeIntervalSince1970: 1_792_000_000))
        XCTAssertNil(AgentWorktree.reuseProblem(record, pointsTo: record.gitDir, head: "refs/heads/binders-card-3f2504e04f89-codex\n"))
        XCTAssertTrue(AgentWorktree.reuseProblem(record, pointsTo: "/Users/sam/code/app/.git", head: "refs/heads/main")?.contains("points at another git folder") == true,
                      "a pointer to another git folder: your checkout's, say")
        XCTAssertTrue(AgentWorktree.reuseProblem(record, pointsTo: nil, head: nil)?.contains("isn't one git wrote") == true)
        XCTAssertEqual(AgentWorktree.reuseProblem(record, pointsTo: record.gitDir, head: "refs/heads/main"),
                       "The worktree at \(record.path) isn't as Binders left it (it isn't on binders-card-3f2504e04f89-codex). Nothing was started.")
        // Before the first run for a card and tool.
        var other = record
        other.card = UUID()
        XCTAssertEqual(AgentWorktree.placeProblem(path: record.path, records: [other], card: card, tool: .codex, folderExists: true),
                       "A worktree at \(record.path) belongs to another card. Nothing was started.")
        XCTAssertTrue(AgentWorktree.placeProblem(path: record.path, records: [], card: card, tool: .codex, folderExists: true)?
            .hasPrefix("A folder is already at \(record.path), and Binders didn't finish making it. Nothing was started.") == true, "no record: never deleted")
        var half = record
        half.ready = false
        XCTAssertNotNil(AgentWorktree.placeProblem(path: record.path, records: [half], card: card, tool: .codex, folderExists: true), "a record that isn't ready")
        XCTAssertNil(AgentWorktree.placeProblem(path: record.path, records: [record], card: card, tool: .codex, folderExists: true), "its own")
        XCTAssertNil(AgentWorktree.placeProblem(path: record.path, records: [], card: card, tool: .codex, folderExists: false), "nothing there yet")
    }

    private var record: AgentWorktreeRecord {
        AgentWorktreeRecord(card: card, tool: .codex, repository: "/Users/sam/code/app", commonDir: "/Users/sam/code/app/.git",
                            path: "\(root)/worktrees/app-1/binders-3f2504e04f89-codex", branch: "binders-card-3f2504e04f89-codex",
                            gitDir: "/Users/sam/code/app/.git/worktrees/binders-3f2504e04f89-codex", ready: true, made: Date(timeIntervalSince1970: 1_792_000_000))
    }

    func testTheRecordsFileComesBackTheSame() throws {
        let file = AgentWorktreeFile(records: [record])
        XCTAssertEqual(AgentWorktreeFile.decode(try file.encoded()), file)
        XCTAssertEqual(AgentWorktreeFile.decode(Data()), AgentWorktreeFile(), "an empty file holds no records")
        XCTAssertNil(AgentWorktreeFile.decode(Data("nope".utf8)), "one that isn't a list can't be read, so nothing is saved over it")
        XCTAssertNil(AgentWorktreeFile.decode(Data(#"[{"card":"#.utf8)), "nor one cut short")
        // As a list of the records alone was written.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try file.encoded(), try encoder.encode([record]))
    }

    func testARecordFromALaterBindersIsKept() throws {
        // A later Binders adds a tool, and writes its record into the same file.
        let later = #"{"branch":"binders-card-3f2504e04f89-gemini","card":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","commonDir":"/Users/sam/code/app/.git","gitDir":"/g","made":"2026-10-18T12:00:00Z","path":"/Users/sam/.binders/worktrees/app-1/binders-3f2504e04f89-gemini","ready":true,"repository":"/Users/sam/code/app","tool":"gemini"}"#
        var mine = record
        mine.path += "-2"
        let text = "[" + String(decoding: try AgentWorktreeFile(records: [record]).encoded(), as: UTF8.self).dropFirst().dropLast() + "," + later + "]"
        var file = try XCTUnwrap(AgentWorktreeFile.decode(Data(text.utf8)))
        XCTAssertEqual(file.records, [record], "the one it knows")
        XCTAssertEqual(file.kept.count, 1, "and the later one, as it was")
        file.records.append(mine)
        let again = try XCTUnwrap(AgentWorktreeFile.decode(try file.encoded()))
        XCTAssertEqual(again.records, [record, mine])
        XCTAssertEqual(again.kept, file.kept, "saving here never drops it")
        XCTAssertTrue(String(decoding: try file.encoded(), as: UTF8.self).contains(#""tool" : "gemini""#))
    }

    func testALinkThatLeadsOut() {
        XCTAssertTrue(AgentWorktree.isInside("/w/t", "/w/t"))
        XCTAssertTrue(AgentWorktree.isInside("/w/t/a/b", "/w/t/"))
        XCTAssertFalse(AgentWorktree.isInside("/w/tt", "/w/t"), "a folder whose name begins the same isn't inside")
        XCTAssertFalse(AgentWorktree.isInside("/Users/sam/.ssh/id_ed25519", "/w/t"))
        XCTAssertTrue(AgentWorktree.isInside("/x", "/"))
        XCTAssertEqual(AgentWorktree.outwardLinkProblem("docs/keys", tool: .opencode),
                       "Binders didn't start OpenCode: docs/keys in the card's worktree is a link to somewhere outside it, and OpenCode's file tools would follow it there. Remove the link there if the card doesn't need it, or give the card to another agent, then Wake Now.")
    }
}
