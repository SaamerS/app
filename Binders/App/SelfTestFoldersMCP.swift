import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// The folder tools over MCP, as an agent calls them, in a throwaway folder (BINDERS_DATA_DIR): list_folders,
    /// create_folder, move_item (one id, or several at once), rename_folder, and `folder` on list_notes, add_note,
    /// search_knowledge, list_meetings and ask_knowledge (lane RF3), with the folder path on what list and search tools
    /// return, and list_notes paging through a whole binder.
    @MainActor
    static func foldersMCPSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test makes binders, folders and notes")
            return 1
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        let store = Store.shared
        let controller = DictationController()
        let write = MCPServer.writeInApp(controller: controller)
        let agent = BoardActor(name: "Claude Code", kind: .agent)
        func call(_ tool: String, _ arguments: [String: Any], reads: MCPServer.Reads = .everything) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: agent, reads: reads, host: "Claude Code")) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        func object(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:] }
        func list(_ text: String) -> [[String: Any]] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]) ?? [] }

        let names = Set(MCPServer.tools.map(\.name))
        check(names.isSuperset(of: ["list_folders", "create_folder", "move_item"]), "the tools are offered")
        check(MCPServer.tools.first { $0.name == "list_folders" }?.readOnly == true && MCPServer.tools.first { $0.name == "move_item" }?.readOnly == false,
              "list_folders only reads; move_item changes")
        for tool in ["list_notes", "add_note", "search_knowledge"] {
            check(MCPServer.tools.first { $0.name == tool }?.parameters.contains { $0.name == "folder" } == true, "\(tool) takes a folder")
        }

        let work = BinderRecord(name: "Work", colorIndex: 1)
        store.insert(work)
        let personal = BinderRecord(name: "Personal", colorIndex: 3)
        store.insert(personal)

        // create_folder: a path makes each folder in it.
        let made = await call("create_folder", ["name": "Ops/DevOps", "binder": "Work"])
        let devOpsID = (object(made.text)["id"] as? String).flatMap(UUID.init(uuidString:))
        let devOps = store.folder(devOpsID)
        check(made.ok && store.folderPath(devOpsID) == "Ops/DevOps" && devOps?.binderID == work.id, "create_folder makes Ops/DevOps: \(made.text)")
        let ops = store.folder(devOps?.parentID)
        let again = await call("create_folder", ["name": "DevOps", "binder": "Work", "parent": "Ops"])
        check(again.ok && object(again.text)["id"] as? String == devOpsID?.uuidString && (object(again.text)["message"] as? String ?? "").contains("already"),
              "one already there is given back as it is: \(again.text)")
        let nowhere = await call("create_folder", ["name": "X", "binder": "Work", "parent": "Nowhere"])
        check(!nowhere.ok && nowhere.text.contains("No folder “Nowhere”"), "a parent that isn't there is refused: \(nowhere.text)")

        // list_folders.
        let everything = list((await call("list_folders", ["binder": "Work"])).text)
        check(everything.map { $0["path"] as? String ?? "" } == ["Ops", "Ops/DevOps"], "list_folders gives every folder with its path: \(everything.map { $0["path"] ?? "" })")
        check(everything.last?["parent_id"] as? String == ops?.id.uuidString && everything.first?["parent_id"] as? String == ""
              && everything.first?["binder"] as? String == "Work" && everything.first?["folders"] as? Int == 1, "with its parent, binder and what it holds")
        check(list((await call("list_folders", ["binder": "Work", "parent": "/"])).text).map { $0["name"] as? String ?? "" } == ["Ops"], "parent / is the top level")
        check(list((await call("list_folders", ["binder": "Work", "parent": "Ops"])).text).map { $0["name"] as? String ?? "" } == ["DevOps"],
              "parent names a folder: what's directly in it")

        // add_note into a folder.
        let cleanup = await call("add_note", ["text": "Pipeline cleanup\n\nThe old runners go.", "binder": "Work", "folder": "Ops/DevOps"])
        let cleanupNote = (object(cleanup.text)["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap { store.note($0) }
        check(cleanupNote?.folderID == devOpsID && cleanupNote?.madeBy == "Claude Code" && (object(cleanup.text)["message"] as? String ?? "").contains("Work › Ops › DevOps"),
              "add_note files the note in the folder named: \(cleanup.text)")
        let post = await call("add_note", ["text": "Launch post", "binder": "Work", "folder": "Social posts"])
        let postNote = (object(post.text)["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap { store.note($0) }
        check(store.folder(postNote?.folderID)?.name == "Social posts", "a path that's missing is made")
        let gone = await call("add_note", ["text": "For a folder that's gone", "binder": "Work", "folder": UUID().uuidString])
        let goneNote = (object(gone.text)["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap { store.note($0) }
        check(gone.ok && goneNote?.folderID == nil && goneNote?.binderID == work.id && gone.text.contains("gone"),
              "a folder id that's gone puts the note at the top of the binder, and says so: \(gone.text)")
        let recipes = store.createFolder(named: "Recipes", in: personal.id)
        let byID = await call("add_note", ["text": "Soup", "binder": "No such binder", "folder": recipes?.id.uuidString ?? ""])
        let soup = (object(byID.text)["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap { store.note($0) }
        check(byID.ok && soup?.binderID == personal.id && soup?.folderID == recipes?.id, "a folder's id decides the binder, as for the phone's renamed binder")
        let mismatch = await call("add_note", ["text": "Stew", "binder": "Work", "folder": recipes?.id.uuidString ?? ""])
        check(!mismatch.ok && mismatch.text.contains("Personal"), "a folder in another binder than the one named is said: \(mismatch.text)")

        // list_notes with a folder, and the folder on what it returns.
        let inDevOps = list((await call("list_notes", ["binder": "Work", "folder": "Ops/DevOps"])).text)
        check(inDevOps.map { $0["title"] as? String ?? "" } == ["Pipeline cleanup"] && inDevOps.first?["folder"] as? String == "Ops/DevOps"
              && inDevOps.first?["folder_id"] as? String == devOpsID?.uuidString, "list_notes in a folder, with its path and id")
        check(list((await call("list_notes", ["binder": "Work", "folder": "Ops"])).text).isEmpty, "a folder's own notes, not those in its folders")
        check(list((await call("list_notes", ["binder": "Work", "folder": "Ops", "include_subfolders": true])).text).map { $0["title"] as? String ?? "" } == ["Pipeline cleanup"],
              "and with include_subfolders, those too")
        check(list((await call("list_notes", ["binder": "Work", "folder": "/"])).text).map { $0["title"] as? String ?? "" } == ["For a folder that's gone"],
              "folder / is the top of the binder")
        let flat = list((await call("list_notes", ["binder": "Work"])).text)
        check(flat.count == 3 && flat.allSatisfy { $0["folder"] is String && $0["folder_id"] is String }, "without folder, every note, flat, each saying its folder")
        check(!(await call("list_notes", ["binder": "Work", "folder": "Nope"])).ok, "a folder that isn't there is said")
        let got = object((await call("get_note", ["id": cleanupNote?.id.uuidString ?? ""])).text)
        check(got["folder"] as? String == "Ops/DevOps", "get_note says its folder")

        // move_item, every kind.
        let toTop = await call("move_item", ["id": cleanupNote?.id.uuidString ?? "", "to": "/"])
        check(toTop.ok && cleanupNote?.folderID == nil && toTop.text.contains("top of Work"), "a note to the top: \(toTop.text)")
        let back = await call("move_item", ["id": cleanupNote?.id.uuidString ?? "", "to": devOpsID?.uuidString ?? ""])
        check(back.ok && cleanupNote?.folderID == devOpsID, "and into a folder by its id")
        let byPath = await call("move_item", ["id": cleanupNote?.id.uuidString ?? "", "to": "Ops/Releases"])
        check(byPath.ok && store.folderPath(cleanupNote?.folderID) == "Ops/Releases", "or by a path, made if it's missing")
        let review = MeetingRecord(title: "Ops review", appName: "Zoom", templateID: "general")
        review.status = "ready"
        review.binderID = work.id
        store.insert(review)
        check((await call("move_item", ["id": review.id.uuidString, "to": "Ops"])).ok && review.folderID == ops?.id, "a meeting moves")
        let chat = MeetingRecord(title: "Hallway chat", appName: "iPhone", templateID: "conversation")
        chat.kind = MeetingRecord.conversationKind
        chat.status = "ready"
        chat.binderID = work.id
        store.insert(chat)
        let noCaptures = MCPServer.Reads(captures: false, transcripts: true, team: true)
        let refusedCapture = await call("move_item", ["id": chat.id.uuidString, "to": "Ops"], reads: noCaptures)
        check(!refusedCapture.ok && chat.folderID == nil, "a capture stays put for a tool that may not read captures: \(refusedCapture.text)")
        check((await call("move_item", ["id": chat.id.uuidString, "to": "Ops"])).ok && chat.folderID == ops?.id, "and moves for one that may")
        let theirs = MeetingRecord(title: "A teammate's sync", appName: "Zoom", templateID: "general")
        theirs.status = "ready"
        theirs.binderID = work.id
        theirs.isTeamCopy = true
        theirs.teamAuthorName = "Dana"
        store.insert(theirs)
        let refusedTheirs = await call("move_item", ["id": theirs.id.uuidString, "to": "Ops"])
        check(!refusedTheirs.ok && theirs.folderID == nil && refusedTheirs.text.contains("Dana"), "a teammate's meeting stays: \(refusedTheirs.text)")
        let intoItself = await call("move_item", ["id": ops?.id.uuidString ?? "", "to": "Ops/DevOps"])
        check(!intoItself.ok && ops?.parentID == nil && intoItself.text.contains("inside itself"), "a folder never into one of its own: \(intoItself.text)")
        let social = store.folder(postNote?.folderID)
        check((await call("move_item", ["id": social?.id.uuidString ?? "", "to": "Ops"])).ok && social?.parentID == ops?.id, "a folder moves into another")
        let across = await call("move_item", ["id": cleanupNote?.id.uuidString ?? "", "to": recipes?.id.uuidString ?? ""])
        check(!across.ok && across.text.contains("another binder"), "within its binder only: \(across.text)")
        check(!(await call("move_item", ["id": UUID().uuidString, "to": "/"])).ok, "an id nothing has is said")
        let noTarget = await call("move_item", ["id": cleanupNote?.id.uuidString ?? "", "to": ""])
        check(!noTarget.ok && cleanupNote?.folderID != nil, "an empty to moves nothing: the top is \"/\"")

        // Meetings say their folder.
        let meetings = list((await call("list_meetings", ["binder": "Work", "kind": "all"])).text)
        check(meetings.first { $0["title"] as? String == "Ops review" }?["folder"] as? String == "Ops", "list_meetings says each one's folder")
        check(object((await call("get_meeting", ["id": review.id.uuidString])).text)["folder"] as? String == "Ops", "and get_meeting")

        // search_knowledge inside a folder.
        let runbook = NoteItem(text: "# Runner runbook\n\nThe quillwort runners restart at noon.")
        runbook.binderID = work.id
        runbook.folderID = devOpsID
        store.insert(runbook)
        let stray = NoteItem(text: "# Stray runners\n\nThe quillwort runners at the top of the binder.")
        stray.binderID = work.id
        store.insert(stray)
        await controller.knowledge.indexNow()
        let scoped = list((await call("search_knowledge", ["query": "quillwort runners", "binder": "Work", "folder": "Ops"])).text)
        // Pipeline cleanup is in Ops/Releases by now, and mentions runners too; the stray note at the top isn't in Ops.
        let inOps: Set<String> = [runbook.id.uuidString, cleanupNote?.id.uuidString ?? ""]
        check(scoped.contains { $0["source_id"] as? String == runbook.id.uuidString } && scoped.allSatisfy { inOps.contains($0["source_id"] as? String ?? "") }
              && scoped.first { $0["source_id"] as? String == runbook.id.uuidString }?["folder"] as? String == "Ops/DevOps",
              "search_knowledge in Ops finds only what's in its folders, and says where (keyword index): \(scoped.map { $0["title"] ?? "" })")
        let wide = list((await call("search_knowledge", ["query": "quillwort runners", "binder": "Work"])).text)
        check(Set(wide.compactMap { $0["source_id"] as? String }).isSuperset(of: [runbook.id.uuidString, stray.id.uuidString])
              && wide.first { $0["source_id"] as? String == stray.id.uuidString }?["folder"] as? String == "", "without folder, the whole binder; the top says \"\"")
        check(!(await call("search_knowledge", ["query": "runners", "folder": "Nope"])).ok, "a folder that isn't there is said")

        // A teammate's binder's folders, only for what may read teammates' items.
        let shared = BinderRecord(name: "Dana's launch", colorIndex: 5)
        shared.isTeamCopy = true
        shared.sharedWithTeam = true
        shared.teamAuthorName = "Dana"
        store.insert(shared)
        _ = store.createFolder(named: "Booth", in: shared.id)
        let noTeam = MCPServer.Reads(captures: true, transcripts: true, team: false)
        let withoutTeam = list((await call("list_folders", [:], reads: noTeam)).text)
        let withTeam = list((await call("list_folders", [:])).text)
        check(!withoutTeam.contains { $0["binder"] as? String == "Dana's launch" } && withTeam.contains { $0["name"] as? String == "Booth" },
              "a teammate's folders only for a tool that may read their items")
        let withoutCaptures = list((await call("list_folders", ["binder": "Work"], reads: noCaptures)).text)
        let withCaptures = list((await call("list_folders", ["binder": "Work"])).text)
        check(withoutCaptures.allSatisfy { $0["captures"] == nil } && withCaptures.contains { $0["captures"] as? Int == 1 },
              "how many captures a folder holds, only for a tool that may read captures")

        // Several at once (lane RF1): one call, one folder, each said moved or not, and why.
        check(MCPServer.tools.first { $0.name == "move_item" }?.parameters.first { $0.name == "ids" }?.type == "array"
              && MCPServer.tools.first { $0.name == "move_item" }?.parameters.first { $0.name == "id" }?.required == false,
              "move_item takes ids, a list, beside id as it was")
        let batch = (1...3).map { index -> NoteItem in
            let note = NoteItem(text: "# Batch note \(index)\n\nTo be filed.")
            note.binderID = work.id
            store.insert(note)
            return note
        }
        let soupID = soup?.id.uuidString ?? ""
        let missing = UUID().uuidString
        let several = await call("move_item", ["ids": batch.map(\.id.uuidString) + [review.id.uuidString, chat.id.uuidString, soupID, missing], "to": "Archive/2026"],
                                 reads: noCaptures)
        let items = object(several.text)["items"] as? [[String: Any]] ?? []
        let archive = store.folder((object(several.text)["id"] as? String).flatMap(UUID.init(uuidString:)))
        func said(_ id: String) -> [String: Any]? { items.first { $0["id"] as? String == id } }
        check(several.ok && store.folderPath(archive?.id) == "Archive/2026" && batch.allSatisfy { $0.folderID == archive?.id } && review.folderID == archive?.id,
              "three notes and a meeting go into one folder, made from its path, in one call: \(object(several.text)["message"] ?? several.text)")
        check(items.count == 7 && items.filter { $0["moved"] as? Bool == true }.count == 4, "each one is said, moved or not, in the order asked")
        check(said(chat.id.uuidString)?["moved"] as? Bool == false && (said(chat.id.uuidString)?["why"] as? String ?? "").contains("Captures aren't shared")
              && chat.folderID == ops?.id && said(chat.id.uuidString)?["title"] == nil,
              "a capture this tool may not read stays put, said without its title: \(said(chat.id.uuidString) ?? [:])")
        check(said(soupID)?["moved"] as? Bool == false && (said(soupID)?["why"] as? String ?? "").contains("Personal") && soup?.folderID == recipes?.id,
              "one in another binder stays put, and says why: \(said(soupID)?["why"] ?? "")")
        check(said(missing)?["moved"] as? Bool == false && (said(missing)?["why"] as? String ?? "").contains("Nothing has that id"), "an id nothing has is said")
        let commaList = await call("move_item", ["ids": batch.map(\.id.uuidString).joined(separator: ", "), "to": "/"])
        check(commaList.ok && batch.allSatisfy { $0.folderID == nil }, "ids as one string, separated by commas, and \"/\" for the top: \(object(commaList.text)["message"] ?? "")")
        let noneMoved = await call("move_item", ["ids": [missing], "to": "Ops"])
        check(!noneMoved.ok && noneMoved.text.contains("Nothing moved"), "nothing moved is a failure that says why: \(noneMoved.text)")
        let single = await call("move_item", ["id": batch[0].id.uuidString, "to": "Ops"])
        check(single.ok && batch[0].folderID == ops?.id && object(single.text)["items"] == nil, "id alone works as it did, without items")

        // rename_folder; no tool deletes a folder.
        check(names.contains("rename_folder") && !names.contains { $0.contains("delete") && $0.contains("folder") }, "rename_folder is offered, and nothing deletes a folder")
        let renamed = await call("rename_folder", ["folder": "Archive/2026", "binder": "Work", "name": "Year 2026"])
        check(renamed.ok && archive?.name == "Year 2026" && review.folderID == archive?.id && store.folderPath(archive?.id) == "Archive/Year 2026",
              "a folder by its path gets a new name, and what's in it stays: \(object(renamed.text)["message"] ?? renamed.text)")
        let byIDRename = await call("rename_folder", ["folder": archive?.id.uuidString ?? "", "name": "2026"])
        check(byIDRename.ok && archive?.name == "2026", "or by its id")
        _ = store.createFolder(named: "Older", in: work.id, parent: archive?.parentID)
        let clash = await call("rename_folder", ["folder": archive?.id.uuidString ?? "", "name": "older"])
        check(!clash.ok && archive?.name == "2026" && clash.text.contains("already a folder"), "a name a folder beside it has is refused: \(clash.text)")
        let caseOnly = await call("rename_folder", ["folder": ops?.id.uuidString ?? "", "name": "OPS"])
        check(caseOnly.ok && ops?.name == "OPS", "its own name in other letters is fine")
        let blank = await call("rename_folder", ["folder": ops?.id.uuidString ?? "", "name": "   "])
        check(!blank.ok && ops?.name == "OPS", "a name that's empty once cleaned is refused: \(blank.text)")
        _ = store.createFolder(named: "Ops", in: personal.id)
        let ambiguous = await call("rename_folder", ["folder": "Ops", "name": "Operations"])
        check(!ambiguous.ok && ambiguous.text.contains("more than one binder"), "a path in two binders asks for the binder: \(ambiguous.text)")
        let theirsRename = await call("rename_folder", ["folder": "Booth", "binder": "Dana's launch", "name": "Stand"], reads: noTeam)
        check(!theirsRename.ok && theirsRename.text.contains("Teammates' items"), "a teammate's folder only for a tool that may read their items")

        // list_notes reaches every note in a binder, page by page.
        let big = BinderRecord(name: "Big", colorIndex: 2)
        store.insert(big)
        for index in 1...130 {
            let note = NoteItem(text: "# Paged note \(index)")
            note.binderID = big.id
            note.updatedAt = Date().addingTimeInterval(-Double(index) * 60)
            store.insert(note)
        }
        var pages: [[String]] = []
        for offset in stride(from: 0, through: 150, by: 50) {
            pages.append(list((await call("list_notes", ["binder": "Big", "limit": 50, "offset": offset])).text).compactMap { $0["id"] as? String })
        }
        let reached = pages.flatMap { $0 }
        check(pages.map(\.count) == [50, 50, 30, 0] && Set(reached).count == 130,
              "with offset, an agent pages through all 130 notes, newest first, none twice: \(pages.map(\.count))")
        let filteredPage = list((await call("list_notes", ["binder": "Big", "folder": "/", "limit": 50, "offset": 100])).text)
        check(filteredPage.count == 30, "paging works with a filter too (the notes not yet filed): \(filteredPage.count)")
        check(MCPServer.tools.first { $0.name == "list_notes" }?.parameters.contains { $0.name == "offset" && $0.type == "integer" } == true, "list_notes takes offset")

        // Lane RF3: list_meetings in a folder, as list_notes has it.
        let listMeetings = MCPServer.tools.first { $0.name == "list_meetings" }
        check(listMeetings?.parameters.contains { $0.name == "folder" } == true
              && listMeetings?.parameters.contains { $0.name == "include_subfolders" && $0.type == "boolean" } == true,
              "list_meetings takes a folder, and include_subfolders")
        func titles(_ arguments: [String: Any], reads: MCPServer.Reads = .everything) async -> [String] {
            list((await call("list_meetings", arguments, reads: reads)).text).compactMap { $0["title"] as? String }
        }
        check(await titles(["binder": "Work", "kind": "all", "folder": "Archive/2026"]) == ["Ops review"], "list_meetings in a folder, by its path")
        check(await titles(["binder": "Work", "kind": "all", "folder": archive?.id.uuidString ?? ""]) == ["Ops review"], "or by its id")
        check((await titles(["binder": "Work", "kind": "all", "folder": "Archive"])).isEmpty, "a folder's own meetings, not those in its folders")
        check(await titles(["binder": "Work", "kind": "all", "folder": "Archive", "include_subfolders": true]) == ["Ops review"], "and with include_subfolders, those too")
        check(await titles(["binder": "Work", "kind": "all", "folder": "/"]) == ["A teammate's sync"], "folder / is the top of the binder")
        check((await titles(["binder": "Work", "kind": "all", "folder": "/"], reads: noTeam)).isEmpty, "a teammate's meeting only for a tool that may read their items")
        let capturesInOps = list((await call("list_meetings", ["binder": "Work", "kind": "capture", "folder": "OPS"])).text)
        check(capturesInOps.map { $0["title"] as? String ?? "" } == ["Hallway chat"] && capturesInOps.first?["folder"] as? String == "OPS",
              "a capture in a folder, with its path")
        check((await titles(["binder": "Work", "folder": "OPS"])).isEmpty, "meetings alone there by default: the capture isn't one")
        check(!(await call("list_meetings", ["binder": "Work", "kind": "capture", "folder": "OPS"], reads: noCaptures)).ok, "captures in a folder, only for a tool that may read them")
        check(!(await call("list_meetings", ["binder": "Work", "folder": "Nope"])).ok, "a folder that isn't there is said")
        let otherBinder = await call("list_meetings", ["binder": "Work", "folder": recipes?.id.uuidString ?? ""])
        check(!otherBinder.ok && otherBinder.text.contains("Personal"), "a folder in another binder than the one named is said: \(otherBinder.text)")
        check(list((await call("list_meetings", ["binder": "Work", "kind": "all"])).text).count == 3, "without folder, every meeting, as before")

        // Lane RF3: ask_knowledge inside a folder, as search_knowledge has it.
        let askTool = MCPServer.tools.first { $0.name == "ask_knowledge" }
        check(askTool?.parameters.contains { $0.name == "folder" } == true && askTool?.parameters.contains { $0.name == "binder" } == true, "ask_knowledge takes a folder and a binder")
        controller.knowledge.answerModel = StandInModel(reply: "The quillwort runners restart at noon [1].")
        let askedInOps = object((await call("ask_knowledge", ["question": "When do the quillwort runners restart?", "binder": "Work", "folder": "OPS"])).text)
        let opsSources = (askedInOps["sources"] as? [[String: Any]] ?? []).compactMap { $0["source_id"] as? String }
        let inOpsNow = ops.map { store.itemIDs(inFolder: $0.id) } ?? []
        check(opsSources.contains(runbook.id.uuidString) && opsSources.allSatisfy(inOpsNow.contains) && !opsSources.contains(stray.id.uuidString)
              && askedInOps["answer"] as? String == "The quillwort runners restart at noon [1].",
              "ask_knowledge in a folder answers from what's in it and its folders only (keyword index): \(opsSources.count) passages")
        let askedWide = object((await call("ask_knowledge", ["question": "When do the quillwort runners restart?", "binder": "Work"])).text)
        check((askedWide["sources"] as? [[String: Any]] ?? []).contains { $0["source_id"] as? String == stray.id.uuidString }, "without folder, the whole binder")
        check(!(await call("ask_knowledge", ["question": "When?", "folder": "/"])).ok, "folder / is refused: leave it out for the whole binder")
        check(!(await call("ask_knowledge", ["question": "When?", "folder": "Nope"])).ok, "a folder that isn't there is said")
        check(!(await call("ask_knowledge", ["question": "When?", "binder": "No such binder"])).ok, "and a binder that isn't")
        controller.knowledge.answerModel = nil

        print(failures == 0 ? "FOLDERS_MCP_OK" : "FOLDERS_MCP_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
