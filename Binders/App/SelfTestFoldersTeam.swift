import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// Folders through the team folder, in a throwaway folder (BINDERS_DATA_DIR), with two throwaway team folders:
    /// - Team A: Maya and Dana on this build and Olga on a Binders before folders (`OlderMacTeamSync`, that code itself).
    ///   Notes moved into a folder while Olga is older keep their files where they are, and Olga's edits keep them in
    ///   their folder; once her Binders knows folders, files move into subfolders; a rename and a delete follow.
    /// - Team B: what the older code does when a note's file moves: it follows a move it sees at once, and makes a second
    ///   note of one it sees in two places at once, which a newer Mac doesn't.
    @MainActor
    static func foldersTeamSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test makes team folders there")
            return 1
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        let fileManager = FileManager.default
        let root = AppPaths.support.appendingPathComponent("team-folders-test", isDirectory: true)
        try? fileManager.removeItem(at: root)
        let teamA = root.appendingPathComponent("Team A"), teamB = root.appendingPathComponent("Team B")
        for team in [teamA, teamB] {
            try? fileManager.createDirectory(at: team, withIntermediateDirectories: true)
            try? TeamSyncService.prepareTeamFolder(team)
        }
        func newer(_ name: String, in team: URL, store: Store? = nil) -> (store: Store, team: TeamSyncService) {
            let store = store ?? Store(url: root.appendingPathComponent("\(name).store"))
            let sync = TeamSyncService(flowBar: nil, store: store, stateURL: root.appendingPathComponent("\(name)-sync.json"))
            sync.identityOverride = (team, TeamAuthor(id: "id-\(name)", name: name))
            sync.deletionGrace = 0
            sync.idAssignmentAge = 0
            return (store, sync)
        }
        func older(_ name: String, in team: URL) -> (store: Store, team: OlderMacTeamSync) {
            let store = Store(url: root.appendingPathComponent("\(name).store"))
            let sync = OlderMacTeamSync(flowBar: nil, store: store, stateURL: root.appendingPathComponent("\(name)-sync.json"))
            sync.identityOverride = (team, TeamAuthor(id: "id-\(name)", name: name))
            sync.deletionGrace = 0
            sync.idAssignmentAge = 0
            return (store, sync)
        }
        func notes(_ store: Store) -> [NoteItem] { (try? store.context.fetch(FetchDescriptor<NoteItem>())) ?? [] }
        func titled(_ store: Store, _ title: String) -> NoteItem? { notes(store).first { $0.title == title } }
        func note(_ text: String, in binder: BinderRecord, store: Store, folder: UUID? = nil) -> NoteItem {
            let note = NoteItem(text: text)
            note.binderID = binder.id
            note.sharedWithTeam = true
            note.folderID = folder
            store.insert(note)
            return note
        }
        /// Every Markdown file under Notes, by its path in the team folder, with the binders_id each has.
        func noteFiles(_ team: URL) -> [String: String] {
            var result: [String: String] = [:]
            let base = team.resolvingSymlinksInPath().path + "/"
            let walk = fileManager.enumerator(at: team.appendingPathComponent(TeamFiles.notesFolder), includingPropertiesForKeys: nil)
            for case let url as URL in walk?.allObjects ?? [] where url.pathExtension == "md" {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                result[String(url.resolvingSymlinksInPath().path.dropFirst(base.count))] = Frontmatter.parse(text).fields["binders_id"] ?? ""
            }
            return result
        }
        func allFiles(_ team: URL) -> [String: Date] {
            var result: [String: Date] = [:]
            let base = team.resolvingSymlinksInPath().path + "/"
            let walk = fileManager.enumerator(at: team, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
            for case let url as URL in walk?.allObjects ?? [] {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                guard values?.isDirectory != true else { continue }
                result[String(url.resolvingSymlinksInPath().path.dropFirst(base.count))] = values?.contentModificationDate
            }
            return result
        }
        func path(of id: UUID, in team: URL) -> String? { noteFiles(team).first { $0.value == id.uuidString }?.key }
        func text(_ path: String?, in team: URL) -> String { path.flatMap { try? String(contentsOf: team.appendingPathComponent($0), encoding: .utf8) } ?? "" }
        /// Each note once in the team folder and once on each Mac.
        func once(_ team: URL, _ stores: [Store]) -> Bool {
            let ids = Array(noteFiles(team).values)
            return Set(ids).count == ids.count && stores.allSatisfy { store in
                let mine = notes(store).map(\.id)
                return Set(mine).count == mine.count && Set(mine.map(\.uuidString)) == Set(ids)
            }
        }

        // MARK: Team A: an older Mac in the team

        let maya = newer("Maya", in: teamA)
        let dana = newer("Dana", in: teamA)
        let olga = older("Olga", in: teamA)
        let work = BinderRecord(name: "Work", colorIndex: 1)
        work.sharedWithTeam = true
        maya.store.insert(work)
        let cleanup = note("# Pipeline cleanup\n\nOld runners go.", in: work, store: maya.store)
        let alerts = note("# Alert rules\n\nPage on errors only.", in: work, store: maya.store)
        await maya.team.syncNow()
        await dana.team.syncNow()
        await olga.team.syncNow()
        // Olga, on her older Binders, adds a note to Maya's binder.
        _ = note("# Olga's runbook\n\nRestart at noon.", in: work, store: olga.store)
        await olga.team.syncNow()
        await maya.team.syncNow()
        await dana.team.syncNow()
        check(notes(maya.store).count == 3 && notes(dana.store).count == 3 && notes(olga.store).count == 3, "three teammates, three notes each")
        check(!maya.team.status.filesMove && maya.team.status.waitingForFolders == ["Olga"],
              "Olga's older Binders holds file moves back, and Settings says who for: \(maya.team.status.waitingForFolders)")

        // Maya files her note and Olga's in a new folder.
        let before = noteFiles(teamA)
        guard let devOps = maya.store.createFolder(named: "DevOps", in: work.id), let mayasRunbook = titled(maya.store, "Olga's runbook") else {
            print("FOLDERS_TEAM_FAILED: the folder or Olga's note isn't on Maya's Mac")
            return 1
        }
        maya.store.move(cleanup, toFolder: devOps.id)
        maya.store.move(mayasRunbook, toFolder: devOps.id)
        await maya.team.syncNow()
        check(noteFiles(teamA) == before, "with an older Mac in the team, no note file moves")
        check(fileManager.fileExists(atPath: teamA.appendingPathComponent("_binders/folders/\(devOps.id.uuidString).json").path), "the folder is in _binders/folders")
        let cleanupText = text(path(of: cleanup.id, in: teamA), in: teamA)
        check(cleanupText.contains("binders_folder_id: \"\(devOps.id.uuidString)\"") && cleanupText.contains("binders_folder: \"DevOps\""),
              "the note's folder is in its front matter")
        await dana.team.syncNow()
        check(dana.store.folder(devOps.id)?.binderID == work.id && titled(dana.store, "Pipeline cleanup")?.folderID == devOps.id
              && titled(dana.store, "Olga's runbook")?.folderID == devOps.id, "Dana has the folder with both notes in it")
        await olga.team.syncNow()
        check(once(teamA, [olga.store]) && notes(olga.store).count == 3, "the older Mac still has each note once")

        // The older Mac edits both notes, as its code does.
        titled(olga.store, "Pipeline cleanup")?.text += "\n- Olga's line"
        titled(olga.store, "Olga's runbook")?.text += "\n- Checked on Tuesday"
        olga.store.save()
        await olga.team.syncNow()
        check(Set(noteFiles(teamA).keys) == Set(before.keys), "its edits are written to the files where they are: no second copy, no old path")
        let edited = text(path(of: cleanup.id, in: teamA), in: teamA)
        check(edited.contains("- Olga's line") && edited.contains("binders_folder_id: \"\(devOps.id.uuidString)\""), "and keep the note's folder")
        await maya.team.syncNow()
        await dana.team.syncNow()
        check(cleanup.text.hasSuffix("- Olga's line") && cleanup.folderID == devOps.id, "Maya has Olga's edit, and the note is still in DevOps")
        check(titled(dana.store, "Olga's runbook")?.text.hasSuffix("- Checked on Tuesday") == true && titled(dana.store, "Olga's runbook")?.folderID == devOps.id,
              "so does Dana")
        check(once(teamA, [maya.store, dana.store, olga.store]), "nothing lost, duplicated or deleted")

        // A new note in a folder goes straight into its subfolder, which the older Mac reads and edits there.
        let incident = note("# Incident review\n\nWhat happened.", in: work, store: maya.store, folder: devOps.id)
        await maya.team.syncNow()
        check(path(of: incident.id, in: teamA) == "Notes/DevOps/Incident review.md", "a new note in a folder is written in its subfolder at once")
        await olga.team.syncNow()
        titled(olga.store, "Incident review")?.text += "\n- Olga's note"
        olga.store.save()
        await olga.team.syncNow()
        await maya.team.syncNow()
        check(path(of: incident.id, in: teamA) == "Notes/DevOps/Incident review.md" && incident.text.hasSuffix("- Olga's note") && incident.folderID == devOps.id,
              "the older Mac's edit lands there, and the note stays in DevOps")

        // A file a Binders before folders writes from scratch, with no folder line, isn't taken for a move.
        if let cleanupPath = path(of: cleanup.id, in: teamA) {
            let rewritten = OlderTeamFiles.noteMarkdown(TeamNote(id: cleanup.id.uuidString, author: TeamAuthor(id: "id-Maya", name: "Maya"), editedBy: "Olga",
                                                                 createdAt: cleanup.createdAt, updatedAt: Date(), body: cleanup.text,
                                                                 binderID: work.id.uuidString, binderName: work.name))
            try? rewritten.write(to: teamA.appendingPathComponent(cleanupPath), atomically: true, encoding: .utf8)
        }
        await maya.team.syncNow()
        await dana.team.syncNow()
        check(cleanup.folderID == devOps.id && titled(dana.store, "Pipeline cleanup")?.folderID == devOps.id,
              "a file without its folder line leaves the note in its folder")
        check(text(path(of: cleanup.id, in: teamA), in: teamA).contains("binders_folder_id: \"\(devOps.id.uuidString)\""),
              "and the line is written back, for a Mac reading the file for the first time")
        // Moved to the top while its file has no folder line: the file says so, and teammates take the move.
        if let cleanupPath = path(of: cleanup.id, in: teamA) {
            let rewritten = OlderTeamFiles.noteMarkdown(TeamNote(id: cleanup.id.uuidString, author: TeamAuthor(id: "id-Maya", name: "Maya"), editedBy: "Olga",
                                                                 createdAt: cleanup.createdAt, updatedAt: Date(), body: cleanup.text,
                                                                 binderID: work.id.uuidString, binderName: work.name))
            try? rewritten.write(to: teamA.appendingPathComponent(cleanupPath), atomically: true, encoding: .utf8)
        }
        maya.store.move(cleanup, toFolder: nil)
        await maya.team.syncNow()
        await dana.team.syncNow()
        check(text(path(of: cleanup.id, in: teamA), in: teamA).contains("binders_folder_id: \"\"") && titled(dana.store, "Pipeline cleanup")?.folderID == nil,
              "moved to the top while its file had no folder line, the file says so and Dana's Mac takes the move")
        maya.store.move(cleanup, toFolder: devOps.id)
        await maya.team.syncNow()
        await dana.team.syncNow()
        check(titled(dana.store, "Pipeline cleanup")?.folderID == devOps.id, "and back into DevOps")

        // Meetings in a folder.
        let review = MeetingRecord(title: "Platform review", appName: "Zoom", templateID: "general")
        review.status = "ready"
        review.duration = 600
        review.summary = "## Decisions\n- Retire the old runners"
        review.binderID = work.id
        review.sharedWithTeam = true
        review.folderID = devOps.id
        maya.store.insert(review)
        await maya.team.syncNow()
        let meetingCopy = allFiles(teamA).keys.first { $0.hasPrefix("Meetings/") && $0.hasSuffix("Platform review.md") }
        check(meetingCopy?.hasPrefix("Meetings/DevOps/") == true, "a meeting's readable copy is in its folder's subfolder: \(meetingCopy ?? "none")")
        await dana.team.syncNow()
        await olga.team.syncNow()
        let danaReview = ((try? dana.store.context.fetch(FetchDescriptor<MeetingRecord>())) ?? []).first { $0.id == review.id }
        let olgaMeetings = ((try? olga.store.context.fetch(FetchDescriptor<MeetingRecord>())) ?? []).filter { $0.id == review.id }
        check(danaReview?.folderID == devOps.id && danaReview?.isTeamCopy == true, "Dana has it in DevOps")
        check(olgaMeetings.count == 1, "the older Mac has it once")

        // Olga updates Binders: every member's now knows folders, and files go into subfolders.
        let olgaNow = newer("Olga", in: teamA, store: olga.store)
        await olgaNow.team.syncNow()
        let olgaMember = (try? Data(contentsOf: teamA.appendingPathComponent("_binders/members/id-Olga.json")))
            .flatMap { try? TeamCoding.decoder().decode(TeamMember.self, from: $0) }
        check(olgaMember?.knowsFolders == true, "her member file now says her Binders knows folders")
        check(titled(olga.store, "Pipeline cleanup")?.folderID == devOps.id && olga.store.folder(devOps.id) != nil,
              "and her Mac files the notes in the folder, from its older sync state")
        await maya.team.syncNow()
        check(maya.team.status.filesMove && maya.team.status.waitingForFolders.isEmpty, "Maya's Mac now moves files")
        await olgaNow.team.syncNow()
        await dana.team.syncNow()
        await maya.team.syncNow()
        let placed = noteFiles(teamA)
        check(placed.keys.contains("Notes/DevOps/Pipeline cleanup.md") && placed.keys.contains("Notes/DevOps/Olga's runbook.md")
              && placed.keys.contains("Notes/DevOps/Incident review.md") && placed["Notes/Alert rules.md"] == alerts.id.uuidString,
              "each note's file is in its folder's subfolder, each moved by its author's Mac: \(placed.keys.sorted())")
        check(once(teamA, [maya.store, dana.store, olga.store]), "and still each note once, on every Mac")
        check(text("Notes/DevOps/Pipeline cleanup.md", in: teamA).contains("binders_folder: \"DevOps\""), "it reads as a folder in Obsidian, its path in its properties")

        // A folder renamed: its notes follow into the new subfolder, each over two passes of its author's Mac (the path in
        // its front matter first, then its file).
        maya.store.rename(devOps, to: "Platform")
        await maya.team.syncNow()
        await olgaNow.team.syncNow()
        await dana.team.syncNow()
        await maya.team.syncNow()
        await olgaNow.team.syncNow()
        await dana.team.syncNow()
        let renamed = noteFiles(teamA)
        check(renamed.keys.contains("Notes/Platform/Pipeline cleanup.md") && renamed.keys.contains("Notes/Platform/Olga's runbook.md")
              && !renamed.keys.contains { $0.hasPrefix("Notes/DevOps/") }, "renamed, its notes move to Notes/Platform: \(renamed.keys.sorted())")
        check(!fileManager.fileExists(atPath: teamA.appendingPathComponent("Notes/DevOps").path), "and the empty DevOps subfolder goes")
        check(dana.store.folder(devOps.id)?.name == "Platform" && olga.store.folder(devOps.id)?.name == "Platform", "everyone has the new name")
        check(once(teamA, [maya.store, dana.store, olga.store]), "still each note once")

        // Dana deletes the folder: what was in it goes to the top, on every Mac, and its files to Notes.
        if let platform = dana.store.folder(devOps.id) { dana.store.deleteFolder(platform) }
        await dana.team.syncNow()
        await maya.team.syncNow()
        await olgaNow.team.syncNow()
        await dana.team.syncNow()
        await maya.team.syncNow()
        check(maya.store.folder(devOps.id) == nil && olga.store.folder(devOps.id) == nil && cleanup.folderID == nil && incident.folderID == nil
              && titled(olga.store, "Olga's runbook")?.folderID == nil, "deleted on Dana's Mac, the folder goes everywhere and its notes go to the top")
        let flat = noteFiles(teamA)
        check(flat.keys.allSatisfy { !$0.dropFirst("Notes/".count).contains("/") }, "and their files to Notes: \(flat.keys.sorted())")
        check(once(teamA, [maya.store, dana.store, olga.store]) && notes(maya.store).count == 4, "nothing lost, duplicated or deleted")
        // A move and an edit together: the front matter first, where the file is; the file on the next pass, unchanged.
        guard let releases = maya.store.createFolder(named: "Releases", in: work.id) else {
            print("FOLDERS_TEAM_FAILED: couldn't make Releases")
            return 1
        }
        await maya.team.syncNow()
        maya.store.move(alerts, toFolder: releases.id)
        alerts.text += "\n- Paged twice in March"
        maya.store.save()
        await maya.team.syncNow()
        let written = text(path(of: alerts.id, in: teamA), in: teamA)
        check(path(of: alerts.id, in: teamA) == "Notes/Alert rules.md" && written.contains("Paged twice") && written.contains("binders_folder: \"Releases\""),
              "a move with an edit writes the note where it is first: \(path(of: alerts.id, in: teamA) ?? "none")")
        await maya.team.syncNow()
        check(path(of: alerts.id, in: teamA) == "Notes/Releases/Alert rules.md" && text("Notes/Releases/Alert rules.md", in: teamA) == written,
              "and its file moves on the next pass, word for word as it was")
        // The move seen half done on Dana's Mac (the old file still there, word for word), then another edit: one note.
        let moved = teamA.appendingPathComponent("Notes/Releases/Alert rules.md"), leftover = teamA.appendingPathComponent("Notes/Alert rules.md")
        try? fileManager.copyItem(at: moved, to: leftover)
        await dana.team.syncNow()
        await maya.team.syncNow()
        let danaAlerts = notes(dana.store).filter { $0.id == alerts.id }
        check(danaAlerts.count == 1 && danaAlerts.first?.folderID == releases.id && notes(dana.store).count == 4 && notes(maya.store).count == 4,
              "a move seen half done is one note, in its folder, on both Macs")
        alerts.text += "\n- Quiet in April"
        maya.store.save()
        await maya.team.syncNow()
        await dana.team.syncNow()
        await maya.team.syncNow()
        check(danaAlerts.first?.text.hasSuffix("- Quiet in April") == true && notes(dana.store).count == 4 && notes(maya.store).count == 4
              && Frontmatter.parse(text("Notes/Alert rules.md", in: teamA)).fields["binders_id"] == alerts.id.uuidString,
              "the next edit goes to the note, and the copy left behind stays set aside, not a second note")
        try? fileManager.removeItem(at: leftover)
        await maya.team.syncNow()
        await dana.team.syncNow()

        // A folder deleted and put back with Undo is back for everyone, with what it held.
        let removal = maya.store.deleteFolder(releases)
        await maya.team.syncNow()
        await dana.team.syncNow()
        check(dana.store.folder(releases.id) == nil && danaAlerts.first?.folderID == nil, "deleted, it goes on Dana's Mac too")
        maya.store.restore(removal)
        await maya.team.syncNow()
        await dana.team.syncNow()
        let releasesFile = (try? Data(contentsOf: teamA.appendingPathComponent("_binders/folders/\(releases.id.uuidString).json")))
            .flatMap { try? TeamCoding.decoder().decode(TeamFolderFile.self, from: $0) }
        check(releasesFile?.deletedAt == nil && maya.store.folder(releases.id) != nil && alerts.folderID == releases.id
              && dana.store.folder(releases.id) != nil && danaAlerts.first?.folderID == releases.id,
              "put back with Undo, it's back for the team, with its note")

        // A teammate's binder whose card can't be read for a moment: its folders aren't deleted for anyone.
        let ops = BinderRecord(name: "Ops", colorIndex: 4)
        ops.sharedWithTeam = true
        dana.store.insert(ops)
        guard let runbooks = dana.store.createFolder(named: "Runbooks", in: ops.id) else { return 1 }
        await dana.team.syncNow()
        await maya.team.syncNow()
        await maya.team.syncNow()
        check(maya.store.folder(runbooks.id)?.binderID == ops.id, "Maya has the folder in Dana's binder")
        let card = teamA.appendingPathComponent("_binders/binders/\(ops.id.uuidString).json"), aside = root.appendingPathComponent("card-aside.json")
        try? fileManager.moveItem(at: card, to: aside)
        await maya.team.syncNow()
        try? fileManager.moveItem(at: aside, to: card)
        await maya.team.syncNow()
        await maya.team.syncNow()
        await dana.team.syncNow()
        let runbooksURL = teamA.appendingPathComponent("_binders/folders/\(runbooks.id.uuidString).json")
        let runbooksFile = (try? Data(contentsOf: runbooksURL)).flatMap { try? TeamCoding.decoder().decode(TeamFolderFile.self, from: $0) }
        check(runbooksFile?.deletedAt == nil && dana.store.folder(runbooks.id) != nil && maya.store.folder(runbooks.id) != nil,
              "and once the card reads again, Maya has the folder back")
        // A folder file that can't be read yet isn't missing: Maya's older copy doesn't go over Dana's rename.
        dana.store.rename(runbooks, to: "Playbooks")
        await dana.team.syncNow()
        let renamedFile = (try? Data(contentsOf: runbooksURL)) ?? Data()
        try? Data("{".utf8).write(to: runbooksURL)
        await maya.team.syncNow()
        check((try? String(contentsOf: runbooksURL, encoding: .utf8)) == "{", "a folder file that can't be read yet isn't written over")
        try? renamedFile.write(to: runbooksURL)
        await maya.team.syncNow()
        check(maya.store.folder(runbooks.id)?.name == "Playbooks", "and the rename is taken once it reads")

        // A folder made, synced once, and deleted before the next sync stays deleted.
        if let scratch = maya.store.createFolder(named: "Scratch", in: work.id) {
            await maya.team.syncNow()
            maya.store.deleteFolder(scratch)
            await maya.team.syncNow()
            await dana.team.syncNow()
            await maya.team.syncNow()
            let file = (try? Data(contentsOf: teamA.appendingPathComponent("_binders/folders/\(scratch.id.uuidString).json")))
                .flatMap { try? TeamCoding.decoder().decode(TeamFolderFile.self, from: $0) }
            check(maya.store.folder(scratch.id) == nil && dana.store.folder(scratch.id) == nil && file?.deletedAt != nil,
                  "a folder deleted right after it first synced stays deleted, for everyone")
        }
        let settled = allFiles(teamA)
        await maya.team.syncNow()
        await dana.team.syncNow()
        await olgaNow.team.syncNow()
        check(allFiles(teamA) == settled, "a sync with no changes writes nothing")

        // MARK: Team B: what the older code does with a moved file

        let pia = newer("Pia", in: teamB)
        let oscar = older("Oscar", in: teamB)
        let lab = BinderRecord(name: "Lab", colorIndex: 2)
        lab.sharedWithTeam = true
        pia.store.insert(lab)
        let bench = note("# Bench notes\n\nCalibrate on Monday.", in: lab, store: pia.store)
        let supplies = note("# Supply list\n\nGloves.", in: lab, store: pia.store)
        await pia.team.syncNow()
        await oscar.team.syncNow()
        await pia.team.syncNow()
        check(!pia.team.status.filesMove, "an older Mac in this team too: Pia's Mac moves no files")
        let notesB = teamB.appendingPathComponent(TeamFiles.notesFolder)
        try? fileManager.createDirectory(at: notesB.appendingPathComponent("Bench"), withIntermediateDirectories: true)
        // 1. A move it sees at once, as when a file is moved in one step (Obsidian, or a drive passing a move on).
        try? fileManager.moveItem(at: notesB.appendingPathComponent("Bench notes.md"), to: notesB.appendingPathComponent("Bench/Bench notes.md"))
        await oscar.team.syncNow()
        check(notes(oscar.store).count == 2, "the older code finds a moved note by its id")
        titled(oscar.store, "Bench notes")?.text += "\n- Oscar's line"
        oscar.store.save()
        await oscar.team.syncNow()
        check(text("Notes/Bench/Bench notes.md", in: teamB).contains("Oscar's line") && !fileManager.fileExists(atPath: notesB.appendingPathComponent("Bench notes.md").path),
              "and writes its next edit to the moved file, not back to the old path")
        await pia.team.syncNow()
        check(bench.text.hasSuffix("- Oscar's line") && notes(pia.store).count == 2, "so nothing is duplicated")
        // 2. A move seen half done: the moved file and the old one, both there, word for word.
        try? fileManager.copyItem(at: notesB.appendingPathComponent("Supply list.md"), to: notesB.appendingPathComponent("Bench/Supply list.md"))
        await pia.team.syncNow()
        check(notes(pia.store).count == 2 && Frontmatter.parse(text("Notes/Bench/Supply list.md", in: teamB)).fields["binders_id"] == supplies.id.uuidString,
              "this build takes one note's file in two places for one note, and rewrites neither")
        await oscar.team.syncNow()
        let copyID = Frontmatter.parse(text("Notes/Bench/Supply list.md", in: teamB)).fields["binders_id"]
        check(notes(oscar.store).count == 3 && copyID != supplies.id.uuidString,
              "the older code makes it a second note and writes a new id into the moved file: why no file moves while an older Mac is in the team")

        // A member file that can't be read yet holds moves back too.
        try? Data("{".utf8).write(to: teamB.appendingPathComponent("_binders/members/half-written.json"))
        let quinn = newer("Quinn", in: teamB)
        await quinn.team.syncNow()
        check(!quinn.team.status.filesMove && quinn.team.status.unreadableMembers == 1, "a member file that doesn't read counts as an older Binders")

        print("TEAM_FOLDERS: \(root.path)")
        for path in noteFiles(teamA).keys.sorted() { print("  A \(path)") }
        print(failures == 0 ? "FOLDERS_TEAM_OK" : "FOLDERS_TEAM_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
