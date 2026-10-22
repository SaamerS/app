import AppKit
import SwiftData
import BindersKit

/// Lane DB9's self-test, on TeamDBTestBed's throwaway Postgres: three Macs from a folder team, each the app itself. This
/// process is Sam's Mac (the team's first member, who moves the team); Robin's and Kim's Macs are this same Binders run
/// again as separate processes, each with its own throwaway folder (`--selftest-join-copies-mac`), reaching the same
/// database and the same team folder, as their Macs would.
///
///     Binders --selftest-teamdb-join-copies   Sam moves a folder team to the database; a teammate deletes some notes there;
///                                             the database holds deletions as this member that an earlier Binders could
///                                             have left, while moves and properties of those notes wait to go; then
///                                             Robin (Turn On and Join, Move) and Kim (Join, Cancel, a relaunch with both
///                                             set up, then Move) join from their team-folder copies: no note under a new
///                                             id, one row per note, every note's words as they were; then copies as build
///                                             39 made them, removed from Settings → Team's repair: gone on all three Macs,
///                                             nothing else changed, and a second look finds none
extension SelfTest {
    /// What the three Macs share: the database and how to reach it, the team folder, the members' invites, and the notes'
    /// ids, for the other two Macs (a file the child processes read).
    struct JoinCopiesPlan: Codable {
        var port: Int
        var database: String
        var certificate: String
        var folder: String
        var binder: UUID
        var robinBinder: UUID
        var invites: [String: TeamInvite]
        var names: [String: String]
        /// Notes by what happens to them: "teammateDeleted" (a teammate deletes them in the database), "robinDeleted",
        /// "robinEdited" (Robin's own, deleted by a teammate; one Robin changes in the folder afterwards).
        var sets: [String: [UUID]]
        /// The words Robin adds in the folder to the note of his the team deleted.
        var robinLine: String
        /// The notes copied as build 39 copied them (their texts), and once made, the copies' and the near copy's ids.
        var copied: [String] = []
        var copies: [UUID] = []
        var near: [UUID] = []
    }

    /// The test's own Mac, in a child process: its lines come back, each PASS or FAIL counted here.
    @MainActor
    static func runJoinMac(_ name: String, step: String, plan: URL, bed: TeamDBTestBed, timeout: TimeInterval = 300) async -> [String: String] {
        let folder = AppPaths.support.appendingPathComponent("macs/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let executable = Bundle.main.executableURL else {
            bed.check(false, "\(name)'s Mac started (no executable)")
            return [:]
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--selftest-join-copies-mac", step, "-notesShowMarkdown", "NO"]
        var environment = ProcessInfo.processInfo.environment
        environment["BINDERS_DATA_DIR"] = folder.path
        environment["BINDERS_SELFTEST_PLAN"] = plan.path
        environment["BINDERS_SELFTEST_MAC"] = name
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            bed.check(false, "\(name)'s Mac started (\(error.localizedDescription))")
            return [:]
        }
        let text: String = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                stop.cancel()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
        var values: [String: String] = [:]
        var counted = 0
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("PASS: ") {
                bed.check(true, "\(name)'s Mac (\(step)): \(line.dropFirst(6))")
                counted += 1
            } else if line.hasPrefix("FAIL: ") {
                bed.check(false, "\(name)'s Mac (\(step)): \(line.dropFirst(6))")
                counted += 1
            } else if line.hasPrefix("VALUE "), let space = line.dropFirst(6).firstIndex(of: "=") {
                let rest = line.dropFirst(6)
                values[String(rest[..<space])] = String(rest[rest.index(after: space)...])
            }
        }
        bed.check(process.terminationStatus == 0 && counted > 0,
                  "\(name)'s Mac (\(step)) ran to the end (exit \(process.terminationStatus), \(counted) checks)")
        return values
    }

    @MainActor
    final class Holder {
        var on = false
    }

    @MainActor
    static func teamJoinCopiesChecks(_ bed: TeamDBTestBed) async throws {
        let root = try await bed.root()
        func count(_ sql: String, _ values: [String?] = []) async throws -> Int64 { try await root.value(sql, values, as: Int64.self) ?? -1 }
        let fileManager = FileManager.default
        let base = AppPaths.support.appendingPathComponent("join-copies", isDirectory: true)
        let folder = base.appendingPathComponent("Team", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try TeamSyncService.prepareTeamFolder(folder)

        // MARK: The team: Sam (this Mac), Alex (on the database already), Robin and Kim (on the folder, invited).
        let admin = try await bed.link(bed.sam)
        let robinInvite = try await bed.client(bed.sam).addMemberDirect(on: admin, login: "robin", name: "Robin")
        let kimInvite = try await bed.client(bed.sam).addMemberDirect(on: admin, login: "kim", name: "Kim")
        let mac = try await TeamMac.start(bed)
        _ = await bed.eventually(20) { mac.team.directory.myName != nil }
        let notes = mac.team.notes
        notes.gather = .milliseconds(150)
        let sync = mac.controller.team
        sync.identityOverride = (folder, TeamAuthor(id: "folder-sam", name: "Sam"))
        sync.deletionGrace = 0
        sync.idAssignmentAge = 0

        // MARK: The folder days: Sam's binder, two folders, notes for each case.
        let binder = BinderRecord(name: "Team binder", colorIndex: 4)
        binder.sharedWithTeam = true
        Store.shared.insert(binder)
        guard let design = Store.shared.createFolder(named: "Design", in: binder.id),
              let plans = Store.shared.createFolder(named: "Plans", in: binder.id) else { throw TeamDatabase.Problem.refused("no folders") }
        var texts: [UUID: String] = [:]
        func make(_ kind: String, _ count: Int) -> [UUID] {
            (1...count).map { index in
                let text = "# \(kind) \(index)\n\nWhat \(kind.lowercased()) \(index) says, from the folder days.\n\n- one\n- two\n"
                let note = NoteItem(text: text)
                note.binderID = binder.id
                note.sharedWithTeam = true
                note.folderID = index % 2 == 0 ? design.id : nil
                Store.shared.context.insert(note)
                texts[note.id] = text
                return note.id
            }
        }
        let plain = make("Plain", 6)
        let moved = make("Moved", 4)
        let marked = make("Marked", 4)
        let deletedOnly = make("Gone", 2)
        let teammateDeleted = make("Dropped", 3)
        Store.shared.save()
        await sync.syncNow()
        let robinBinder = UUID()
        let robinDeleted = UUID(), robinEdited = UUID()
        let plan = JoinCopiesPlan(port: bed.postgres.port, database: bed.database, certificate: bed.postgres.certificate, folder: folder.path,
                                  binder: binder.id, robinBinder: robinBinder,
                                  invites: ["robin": robinInvite, "kim": kimInvite], names: ["robin": "Robin", "kim": "Kim"],
                                  sets: ["founder": plain + moved + marked + deletedOnly + teammateDeleted, "teammateDeleted": teammateDeleted,
                                         "robinDeleted": [robinDeleted], "robinEdited": [robinEdited]],
                                  robinLine: "Robin, in the folder after the move: one more line.")
        let planURL = base.appendingPathComponent("plan.json")
        try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)

        // Robin's Mac on the folder: Sam's notes come as copies, and Robin's own binder with two notes goes to it.
        _ = await runJoinMac("robin", step: "folder", plan: planURL, bed: bed)
        await sync.syncNow()
        bed.check(Store.shared.note(robinDeleted) != nil && Store.shared.note(robinEdited) != nil, "Robin's two notes reached Sam's Mac through the folder")
        texts[robinDeleted] = Store.shared.note(robinDeleted)?.text
        texts[robinEdited] = Store.shared.note(robinEdited)?.text
        // Kim's Mac on the folder: everyone's notes, as copies.
        _ = await runJoinMac("kim", step: "folder", plan: planURL, bed: bed)

        // MARK: Sam moves the team to the database.
        let summary = try await notes.moveFolderTeam(from: sync)
        bed.check(summary.notes == texts.count && summary.binders == 2, "Sam moves the team: \(summary.line)")
        _ = await mac.drained(60)
        try? await Task.sleep(for: .seconds(2))
        await notes.engine?.saveDue(now: Date().addingTimeInterval(3_600))
        _ = await mac.drained(30)
        let own = try await bed.link(bed.sam)
        func live() async throws -> [UUID: TeamNoteRow] {
            var rows: [UUID: TeamNoteRow] = [:]
            for id in [binder.id, robinBinder] {
                for row in try await own.rows(.notes, binder: id).compactMap(TeamNoteRow.init(row:)) where row.deletedAt == nil { rows[row.id] = row }
            }
            return rows
        }
        let afterMove = try await live()
        bed.check(Set(afterMove.keys) == Set(texts.keys), "the database has every note once (\(afterMove.count) of \(texts.count))")
        // The repair refuses while teammates haven't connected: their Macs may still be on the folder.
        let early = try await notes.findCopies()
        bed.check(early.found.copies.isEmpty && early.refusal?.hasPrefix("Kim and Robin haven't connected to the team database yet") == true,
                  "Remove copies… refuses while Robin and Kim haven't connected: “\(early.refusal?.prefix(70) ?? "")…”")
        var refused = false
        do { _ = try await notes.removeCopies() } catch { refused = true }
        bed.check(refused, "and Remove refuses too")

        // A teammate deletes notes in the database, a real deletion: Sam's Mac follows.
        let alex = try await bed.link(bed.alex)
        for id in teammateDeleted + [robinDeleted, robinEdited] { try await bed.expectOK(alex, .delete(id, from: .notes)) }
        let followed = await bed.eventually(15) { (teammateDeleted + [robinDeleted, robinEdited]).allSatisfy { Store.shared.note($0) == nil } }
        bed.check(followed, "Alex deletes five notes in the database: they go from Sam's Mac")

        // MARK: Sam's Mac, as at the first connect with build 39: moves and properties wait to go while the database holds
        // deletions of those notes (and two others) as Sam, which an earlier Binders could have left.
        let holding = Holder()
        mac.team.database?.testHooks.holdBeforeSending = { item in holding.on && item.call.note != nil }
        holding.on = true
        for id in moved { Store.shared.note(id)?.folderID = Store.shared.note(id)?.folderID == nil ? plans.id : nil }
        for id in marked { Store.shared.note(id)?.status = "Review" }
        Store.shared.save()
        notes.sweep()
        let queued = mac.team.database?.queued ?? []
        let waitingMoves = moved.filter { id in queued.contains { $0.call.note == id && $0.call.function == "move_note" } }.count
        let waitingProps = marked.filter { id in queued.contains { $0.call.note == id && $0.call.function == "add_note_changes" } }.count
        bed.check(waitingMoves == moved.count && waitingProps == marked.count,
                  "moves and properties wait to go (\(waitingMoves) moves, \(waitingProps) properties)")
        for id in moved + marked + deletedOnly { try await bed.expectOK(own, .delete(id, from: .notes)) }
        // The feed brings those deletions to this Mac while what it sends waits.
        try? await Task.sleep(for: .seconds(3))
        holding.on = false
        _ = await mac.drained(30)
        try? await Task.sleep(for: .seconds(2))
        _ = await mac.drained(30)
        await notes.engine?.saveDue(now: Date().addingTimeInterval(3_600))
        _ = await mac.drained(30)
        try? await Task.sleep(for: .seconds(1))

        let samKnown = Set(plain + moved + marked + deletedOnly)
        func local(_ binderID: UUID) -> [NoteItem] {
            (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID }))) ?? []
        }
        let here = local(binder.id)
        let newHere = here.filter { texts[$0.id] == nil }
        bed.check(newHere.isEmpty && Set(here.map(\.id)) == samKnown,
                  "Sam's Mac: no note under a new id, every note there (\(newHere.count) new, \(here.count) of \(samKnown.count))")
        bed.check(here.allSatisfy { texts[$0.id] == $0.text }, "Sam's Mac: every note's words as they were")
        let afterSam = try await live()
        let newThere = afterSam.keys.filter { texts[$0] == nil }
        bed.check(newThere.isEmpty && Set(afterSam.keys) == samKnown,
                  "the database after Sam's Mac connects: no new ids, every note of Sam's live (\(newThere.count) new, \(afterSam.count) live)")
        bed.check(samKnown.allSatisfy { afterSam[$0]?.body == texts[$0] }, "the database: every note's words as they were")
        bed.check(moved.allSatisfy { afterSam[$0]?.folderID == Store.shared.note($0)?.folderID }
                  && marked.allSatisfy { afterSam[$0]?.properties["status"]?.string == "Review" },
                  "the moves and the properties that waited reached the database, on the notes' own ids")

        // MARK: Robin joins: Turn On and Join on an invite, then Move, from the folder copies.
        _ = await runJoinMac("robin", step: "join", plan: planURL, bed: bed)
        let afterRobin = try await live()
        let robinNew = afterRobin.keys.filter { texts[$0] == nil }
        bed.check(robinNew.isEmpty && Set(afterRobin.keys) == samKnown,
                  "after Robin joins: no new ids, the deleted notes stay deleted (\(robinNew.count) new, \(afterRobin.count) live)")
        bed.check(samKnown.allSatisfy { afterRobin[$0]?.body == texts[$0] }, "after Robin joins: every note's words as they were")

        // MARK: Kim joins from the Move sheet and cancels, then Binders opens again with both set up, then Kim moves.
        let kimID = try await root.value("SELECT id::text FROM binders.members WHERE login = 'kim'", as: String.self) ?? ""
        _ = await runJoinMac("kim", step: "join-cancel", plan: planURL, bed: bed)
        let kimChanges = try await count("SELECT count(*) FROM binders.changes WHERE member_id = $1::uuid AND table_name IN ('notes', 'note_changes', 'folders')", [kimID])
        bed.check(kimChanges == 0, "Kim joined and cancelled the move: Kim's Mac changed nothing of the folder's binders in the database (\(kimChanges) changes)")
        _ = await runJoinMac("kim", step: "both", plan: planURL, bed: bed)
        let afterKim = try await live()
        let kimNew = afterKim.keys.filter { texts[$0] == nil }
        bed.check(kimNew.isEmpty && Set(afterKim.keys) == samKnown,
                  "after Kim joins: no new ids, the deleted notes stay deleted (\(kimNew.count) new, \(afterKim.count) live)")
        bed.check(samKnown.allSatisfy { afterKim[$0]?.body == texts[$0] }, "after Kim joins: every note's words as they were")
        try? await Task.sleep(for: .seconds(2))
        let samAfter = local(binder.id)
        bed.check(samAfter.allSatisfy { texts[$0.id] != nil } && samAfter.count == samKnown.count,
                  "Sam's Mac after both joins: \(samAfter.count) notes, \(samAfter.filter { texts[$0.id] == nil }.count) under new ids")

        // MARK: Copies as build 39 made them, and Settings → Team's repair.
        // Sam's Mac kept four notes aside (a new note with the same words, the note itself deleted for the team); Robin's
        // and Kim's Macs each shared the same words again as their own; Robin's has one with a character changed.
        var plan2 = plan
        let copied = Array(plain.prefix(4))
        plan2.copied = copied.compactMap { texts[$0] }
        var samCopies: [UUID] = []
        for id in copied {
            guard let note = Store.shared.note(id) else { continue }
            let copy = NoteItem(text: note.text)
            copy.binderID = note.binderID
            copy.folderID = note.folderID
            Store.shared.context.insert(copy)
            Store.shared.delete(note)
            samCopies.append(copy.id)
            texts[copy.id] = copy.text
        }
        Store.shared.save()
        notes.sweep()
        _ = await mac.drained(30)
        try JSONEncoder().encode(plan2).write(to: planURL, options: .atomic)
        let robinMade = await runJoinMac("robin", step: "copies", plan: planURL, bed: bed)
        let kimMade = await runJoinMac("kim", step: "copies", plan: planURL, bed: bed)
        let joinerCopies = ((robinMade["copies"] ?? "") + "," + (kimMade["copies"] ?? "")).split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        let nearCopy = robinMade["near"].flatMap(UUID.init(uuidString:))
        let arrived = await bed.eventually(30) { joinerCopies.allSatisfy { Store.shared.note($0) != nil } && nearCopy.flatMap { Store.shared.note($0) } != nil }
        await notes.engine?.saveDue(now: Date().addingTimeInterval(3_600))
        _ = await mac.drained(30)
        bed.check(arrived && joinerCopies.count == 8, "Robin's and Kim's copies reached Sam's Mac (\(joinerCopies.count))")
        let beforeRepair = try await live()

        let found = try await notes.findCopies()
        let foundIDs = Set(found.found.copies.map(\.note.id))
        bed.check(foundIDs == Set(joinerCopies) && found.found.copies.allSatisfy { samCopies.contains($0.keeps.id) },
                  "Remove copies… finds Robin's and Kim's eight copies, and keeps Sam's (\(foundIDs.count) found)")
        bed.check(nearCopy.map { id in found.found.near.contains { $0.id == id } } == true && !foundIDs.contains(nearCopy ?? UUID()),
                  "Robin's note with a character changed is left, listed as one to look at (\(found.found.near.count) listed)")
        bed.check(found.refusal == nil && found.caution?.contains("still syncs the old team folder") == true,
                  "with everyone connected it may run, and it says to make sure no Mac still syncs the old team folder")
        // What Sam sees: Settings → Team offers the repair, and its sheet lists what it would remove (drawn to the folder
        // after the flag, when one is given).
        let page = await teamSettingsDrawn(controller: mac.controller, name: "team-copies", directory: teamDrawings, height: 1600)
        bed.check(page.contains("team.copies"), "Settings → Team offers Remove Copies Made When Teammates Joined… on Sam's Mac, an admin's")
        let sheet = await drawnAlone(TeamNoteCopiesSheet(found: found) { _ in }, controller: mac.controller, name: "team-copies-sheet",
                                     size: NSSize(width: 640, height: 760), directory: teamDrawings)
        bed.check(sheet["team.copies.remove"] != nil, "its sheet lists them, with Remove 8 Copies…")
        let removed = try await notes.removeCopies()
        _ = await mac.drained(30)
        try? await Task.sleep(for: .seconds(1))
        let afterRepair = try await live()
        let unchanged = beforeRepair.filter { !foundIDs.contains($0.key) }
        bed.check(removed == 8 && foundIDs.allSatisfy { afterRepair[$0] == nil } && Set(afterRepair.keys) == Set(unchanged.keys),
                  "removed: the eight copies are deleted in the database, every other note still there (\(removed) removed, \(afterRepair.count) live)")
        bed.check(unchanged.allSatisfy { afterRepair[$0.key]?.body == $0.value.body && afterRepair[$0.key]?.folderID == $0.value.folderID
                    && afterRepair[$0.key]?.createdBy == $0.value.createdBy },
                  "nothing else changed: every other note's words, folder and maker as they were")
        bed.check(foundIDs.allSatisfy { Store.shared.note($0) == nil } && samCopies.allSatisfy { Store.shared.note($0) != nil },
                  "Sam's Mac: the copies are gone, Sam's notes stay")
        let again = try await notes.findCopies()
        bed.check(again.found.copies.isEmpty, "a second look finds no copies")
        plan2.copies = joinerCopies
        plan2.near = nearCopy.map { [$0] } ?? []
        try JSONEncoder().encode(plan2).write(to: planURL, options: .atomic)
        _ = await runJoinMac("robin", step: "after", plan: planURL, bed: bed)
        _ = await runJoinMac("kim", step: "after", plan: planURL, bed: bed)

        // MARK: A teammate deletes notes while something of Sam's for them waits to go.
        // An edit typed here: the note stays, and is back for the team under its own id with the edit. A property, or a
        // move: the teammate's deletion stands.
        guard plain.count > 5, let typed = Store.shared.note(plain[4]), let propped = Store.shared.note(plain[5]),
              let shifted = Store.shared.note(moved[0]) else { throw TeamDatabase.Problem.refused("no notes for the last part") }
        holding.on = true
        typed.text += "\nTyped on Sam's Mac while Alex deleted it.\n"
        propped.status = "Done"
        shifted.folderID = shifted.folderID == nil ? design.id : nil
        Store.shared.save()
        notes.sweep()
        let waitingNow = mac.team.database?.queued ?? []
        bed.check(waitingNow.contains { $0.call.note == typed.id && $0.call.function == "add_note_changes" }
                  && waitingNow.contains { $0.call.note == propped.id && $0.call.function == "add_note_changes" }
                  && waitingNow.contains { $0.call.note == shifted.id && $0.call.function == "move_note" },
                  "an edit, a property and a move wait to go")
        for id in [typed.id, propped.id, shifted.id] { try await bed.expectOK(alex, .delete(id, from: .notes)) }
        try? await Task.sleep(for: .seconds(3))
        holding.on = false
        _ = await mac.drained(30)
        try? await Task.sleep(for: .seconds(2))
        _ = await mac.drained(30)
        await notes.engine?.saveDue(now: Date().addingTimeInterval(3_600))
        _ = await mac.drained(30)
        let last = try await live()
        bed.check(last[typed.id]?.body.contains("Typed on Sam's Mac") == true && Store.shared.note(typed.id)?.text.contains("Typed on Sam's Mac") == true,
                  "the note typed in is back for the team under its own id, with what was typed (database: \(last[typed.id] == nil ? "deleted" : "live"), "
                  + "here: \(Store.shared.note(typed.id) == nil ? "gone" : "kept"))")
        if last.keys.contains(where: { texts[$0] == nil && $0 != nearCopy }) || local(binder.id).contains(where: { texts[$0.id] == nil && $0.id != nearCopy }) {
            print("NOTE: new there: \(last.values.filter { texts[$0.id] == nil }.map(\.title)); new here: \(local(binder.id).filter { texts[$0.id] == nil && $0.id != nearCopy }.map(\.title)); turned down: \(notes.turnedDown.suffix(6))")
        }
        bed.check(last[propped.id] == nil && last[shifted.id] == nil && Store.shared.note(propped.id) == nil && Store.shared.note(shifted.id) == nil,
                  "the notes with a property or a move waiting stay deleted, and go from Sam's Mac")
        bed.check(last.keys.allSatisfy { texts[$0] != nil || $0 == nearCopy } && local(binder.id).allSatisfy { texts[$0.id] != nil || $0.id == nearCopy },
                  "still no note under a new id")

        for invite in [robinInvite, kimInvite] { TeamDatabase.forget(invite.server) }
        await mac.stop()
    }

    // MARK: Robin's and Kim's Macs

    /// One step of a teammate's Mac (`BINDERS_SELFTEST_MAC`), from the plan Sam's Mac wrote: on the team folder; joining and
    /// moving; joining and cancelling; opening again with both set up, then moving. Prints PASS and FAIL lines, and VALUE
    /// lines for Sam's Mac.
    @MainActor
    static func joinCopiesMac(_ step: String) async -> Int32 {
        guard AppPaths.isDemo, let path = ProcessInfo.processInfo.environment["BINDERS_SELFTEST_PLAN"],
              let name = ProcessInfo.processInfo.environment["BINDERS_SELFTEST_MAC"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let plan = try? JSONDecoder().decode(JoinCopiesPlan.self, from: data),
              let invite = plan.invites[name], let myName = plan.names[name] else {
            print("FAIL: no plan for this Mac")
            return 1
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        func eventually(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                guard Date() < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return true
        }
        let controller = DictationController()
        _ = controller.board
        let team = controller.teamBoard
        team.trust = .certificates([plan.certificate])
        team.prepare = { $0.testHooks.reconnectDelay = 0.2 }
        team.editDelay = .milliseconds(150)
        team.notes.gather = .milliseconds(150)
        let sync = controller.team
        sync.deletionGrace = 0
        sync.idAssignmentAge = 0
        let settings = AppSettings.shared
        let folder = URL(fileURLWithPath: plan.folder, isDirectory: true)
        func notes(in binder: UUID) -> [NoteItem] {
            (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binder }))) ?? []
        }
        func allNotes() -> [NoteItem] { (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>())) ?? [] }
        let known = Set((plan.sets["founder"] ?? []) + (plan.sets["robinDeleted"] ?? []) + (plan.sets["robinEdited"] ?? []))
        let deletedThere = Set((plan.sets["teammateDeleted"] ?? []) + (plan.sets["robinDeleted"] ?? []) + (plan.sets["robinEdited"] ?? []))
        func drained(_ timeout: TimeInterval = 30) async -> Bool { await eventually(timeout) { (team.database?.waiting ?? 1) == 0 } }

        /// What this Mac has before it moves, and what it must have after: nothing new, the team's deletions left out.
        func moveAndCheck(before: [UUID: (text: String, binder: UUID?)]) async {
            do {
                let summary = try await team.notes.moveFolderTeam(from: sync)
                check(summary.notes >= known.count - deletedThere.count, "moved: \(summary.line)")
            } catch {
                check(false, "moved (\(error.localizedDescription))")
                return
            }
            _ = await drained(60)
            try? await Task.sleep(for: .seconds(3))
            _ = await drained(30)
            await team.notes.engine?.saveDue(now: Date().addingTimeInterval(3_600))
            _ = await drained(30)
            try? await Task.sleep(for: .seconds(2))
            let after = allNotes()
            let new = after.filter { before[$0.id] == nil }
            check(new.isEmpty, "no note under a new id on this Mac (\(new.count): \(new.map(\.title).sorted().prefix(4).joined(separator: ", ")))")
            let teamDeletedHere = after.filter { (plan.sets["teammateDeleted"] ?? []).contains($0.id) || (plan.sets["robinDeleted"] ?? []).contains($0.id) }
            check(teamDeletedHere.isEmpty, "the notes the team deleted, unchanged here, are left out (\(teamDeletedHere.count) still here)")
            let kept = after.filter { id in !deletedThere.contains(id.id) && known.contains(id.id) }
            check(kept.allSatisfy { before[$0.id]?.text == $0.text && before[$0.id]?.binder == $0.binderID },
                  "every other note as it was, in its binder (\(kept.count))")
            if name == "robin", let edited = plan.sets["robinEdited"]?.first {
                let note = Store.shared.note(edited)
                let general = Store.shared.defaultBinder()
                check(note?.binderID == general.id && note?.text.contains(plan.robinLine) == true && note?.isTeamCopy == false,
                      "Robin's note the team deleted, changed here since, stays on this Mac in General with Robin's words")
                check(!team.covers(general.id), "General isn't shared, so it stays on this Mac")
            }
        }

        switch step {
        case "folder":
            settings.teamMemberName = myName
            settings.teamFolderPath = folder.path
            if name == "robin" {
                let binder = BinderRecord(name: "Robin's binder", colorIndex: 2)
                binder.id = plan.robinBinder
                binder.sharedWithTeam = true
                Store.shared.insert(binder)
                for (id, title) in [(plan.sets["robinDeleted"]?.first, "Robin's list"), (plan.sets["robinEdited"]?.first, "Robin's plan")] {
                    let note = NoteItem(text: "# \(title)\n\nWhat Robin wrote in the folder days.\n")
                    if let id { note.id = id }
                    note.binderID = binder.id
                    note.sharedWithTeam = true
                    Store.shared.context.insert(note)
                }
                Store.shared.save()
            }
            await sync.syncNow()
            await sync.syncNow()
            let copies = notes(in: plan.binder)
            check(copies.count == (plan.sets["founder"] ?? []).count && copies.allSatisfy(\.isTeamCopy),
                  "on the team folder: Sam's \(copies.count) notes, as copies")
        case "join":
            // Robin changes the note of his the team deleted, in the folder, before joining.
            if let edited = plan.sets["robinEdited"]?.first, let note = Store.shared.note(edited) {
                note.text += "\n\(plan.robinLine)\n"
                Store.shared.save()
                await sync.syncNow()
            }
            let before = Dictionary(allNotes().map { ($0.id, (text: $0.text, binder: $0.binderID)) }, uniquingKeysWith: { first, _ in first })
            do {
                let step = try await team.acceptInvite(invite)
                check(step == .move && team.pendingInvite == invite, "Turn On and Join on a Mac on a team folder: it joins from Move This Team to a Database…")
                // The Move sheet: its Join.
                team.movingFolderTeam = true
                _ = try await team.join(invite)
            } catch {
                check(false, "joined (\(error.localizedDescription))")
                return 1
            }
            check(await eventually(30) { team.isConnected && team.directory.me != nil }, "connected to the team database as \(invite.server.login)")
            try? await Task.sleep(for: .seconds(4))
            let joined = allNotes()
            check(joined.count == before.count && joined.allSatisfy { before[$0.id]?.text == $0.text },
                  "joined, not moved yet: the folder's notes as they were (\(joined.count) of \(before.count))")
            await moveAndCheck(before: before)
            team.movingFolderTeam = false
        case "join-cancel":
            // What teammates changed in the folder since (Robin's line) comes first.
            await sync.syncNow()
            let before = Dictionary(allNotes().map { ($0.id, (text: $0.text, binder: $0.binderID)) }, uniquingKeysWith: { first, _ in first })
            do {
                _ = try await team.acceptInvite(invite)
                team.movingFolderTeam = true
                _ = try await team.join(invite)
            } catch {
                check(false, "joined (\(error.localizedDescription))")
                return 1
            }
            check(await eventually(30) { team.isConnected && team.directory.me != nil }, "joined from the Move sheet, connected")
            try? await Task.sleep(for: .seconds(4))
            // Cancel: the Move sheet closes, the team folder stays.
            team.movingFolderTeam = false
            await sync.syncNow()
            team.notes.sweep()
            try? await Task.sleep(for: .seconds(3))
            _ = await drained(20)
            let after = allNotes()
            check(after.count == before.count && after.allSatisfy { before[$0.id]?.text == $0.text && before[$0.id]?.binder == $0.binderID },
                  "joined and cancelled: every note here as it was, the team's deletions too (\(after.count) of \(before.count))")
            check(sync.isConfigured, "the team folder is still this Mac's")
        case "both":
            // Binders opens again with a team folder and a team database both set up.
            await sync.syncNow()
            let before = Dictionary(allNotes().map { ($0.id, (text: $0.text, binder: $0.binderID)) }, uniquingKeysWith: { first, _ in first })
            team.start()
            check(await eventually(30) { team.isConnected && team.directory.me != nil }, "opened again with both: connected")
            await sync.syncNow()
            try? await Task.sleep(for: .seconds(4))
            team.notes.sweep()
            try? await Task.sleep(for: .seconds(2))
            _ = await drained(20)
            await sync.syncNow()
            let after = allNotes()
            check(after.count == before.count && after.allSatisfy { before[$0.id]?.text == $0.text && before[$0.id]?.binder == $0.binderID },
                  "opened again with both: every note here as it was (\(after.count) of \(before.count))")
            team.movingFolderTeam = true
            await moveAndCheck(before: before)
            team.movingFolderTeam = false
        case "copies":
            // Shares the plan's words again as this Mac's own notes, as build 39 kept a note aside.
            team.start()
            check(await eventually(30) { team.isConnected && team.directory.me != nil }, "connected")
            var made: [UUID] = []
            func copy(_ text: String) -> UUID {
                let original = notes(in: plan.binder).first { $0.text == text }
                let note = NoteItem(text: text)
                note.binderID = plan.binder
                note.folderID = original?.folderID
                Store.shared.context.insert(note)
                return note.id
            }
            for text in plan.copied { made.append(copy(text)) }
            print("VALUE copies=\(made.map(\.uuidString).joined(separator: ","))")
            if name == "robin", let first = plan.copied.first {
                print("VALUE near=\(copy(first.replacingOccurrences(of: "from the folder days.", with: "from the folder days!")).uuidString)")
            }
            Store.shared.save()
            team.notes.sweep()
            _ = await drained(30)
            await team.notes.engine?.saveDue(now: Date().addingTimeInterval(3_600))
            _ = await drained(30)
            check(made.count == plan.copied.count, "shared \(made.count) copies as this Mac's own, as build 39 did")
        case "after":
            // Opens again after Sam's repair: the copies go here too.
            team.start()
            check(await eventually(30) { team.isConnected && team.directory.me != nil }, "connected")
            let gone = await eventually(30) { plan.copies.allSatisfy { Store.shared.note($0) == nil } }
            check(gone, "the eight copies went from this Mac too (\(plan.copies.filter { Store.shared.note($0) != nil }.count) still here)")
            check(plan.near.allSatisfy { Store.shared.note($0) != nil }, "Robin's note with other words stays")
            let left = notes(in: plan.binder)
            check(left.count == (plan.sets["founder"] ?? []).count - (plan.sets["teammateDeleted"] ?? []).count + plan.near.count,
                  "this Mac has the team's \(left.count) notes in the binder, none twice")
        default:
            check(false, "a step this Mac knows (\(step))")
        }
        await team.stop()
        fflush(stdout)
        return failures == 0 ? 0 : 1
    }
}
