import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// Lane RF3, part of --selftest-folders: new notes, meetings and captures go in the folder the window shows for their
    /// binder, and at its top when it shows none of that binder's folders: ⌘P's New Note and New Note: <template> (one that
    /// names its own folder still files there), ⌥⌘N, ⌘N on another binder, a meeting started (the hotkey, the menu bar,
    /// ⌘P and binders://meeting all start one through MeetingService.start), and the Captures page's Open a Binders File…
    /// inside a folder, which keeps the capture there once it's read, while one opened from Finder is filed as before.
    @MainActor
    static func newThingsHereSelfTest(check: (Bool, String) -> Void) async {
        let store = Store.shared
        let settings = AppSettings.shared
        let controller = DictationController()
        let work = BinderRecord(name: "Field work", colorIndex: 2)
        store.insert(work)
        let other = BinderRecord(name: "Field elsewhere", colorIndex: 5)
        store.insert(other)
        guard let ops = store.createFolder(named: "Ops", in: work.id), let away = store.createFolder(named: "Away", in: other.id) else {
            return check(false, "the folders for new things are made")
        }
        let navigation = HubWindowController.shared.navigation
        let kept = (navigation.selection, navigation.binderID, navigation.folderID, settings.currentBinderID)
        defer {
            navigation.selection = kept.0
            navigation.binderID = kept.1
            navigation.folderID = kept.2
            navigation.pendingNoteID = nil
            navigation.pendingBinderTab = nil
            settings.currentBinderID = kept.3
        }
        /// The window as it would be: on a binder's page in one of its folders, at its top, or on another page.
        func show(_ binder: BinderRecord, _ folder: FolderRecord?, page: HubSection = .binder) {
            navigation.selection = page
            navigation.binderID = binder.id
            navigation.folderID = folder?.id
        }
        settings.currentBinderID = work.id

        // ⌘P's New Note.
        show(work, ops)
        let inFolder = QuickSwitcher.newNote(from: nil, in: work, navigation: navigation)
        check(inFolder?.binderID == work.id && inFolder?.folderID == ops.id && navigation.pendingNoteID == inFolder?.id && navigation.folderID == ops.id,
              "⌘P's New Note goes in the folder the window shows, and opens there: \(store.folderPath(inFolder?.folderID))")
        show(work, nil)
        check(QuickSwitcher.newNote(from: nil, in: work, navigation: navigation)?.folderID == nil, "at the binder's top, it goes at the top")
        show(other, away)
        let elsewhere = QuickSwitcher.newNote(from: nil, in: work, navigation: navigation)
        check(elsewhere?.binderID == work.id && elsewhere?.folderID == nil, "for a binder the window doesn't show, at that binder's top")
        show(work, ops, page: .home)
        check(QuickSwitcher.newNote(from: nil, in: work, navigation: navigation)?.folderID == nil, "and with the window on another page, at the top")

        // ⌘P's New Note: <template>.
        show(work, ops)
        let plain = TemplateStore.all.first { $0.folder == nil }
        let fromPlain = plain.flatMap { QuickSwitcher.newNote(from: $0, in: work, navigation: navigation) }
        check(fromPlain?.folderID == ops.id, "⌘P's New Note: \(plain?.name ?? "a template") goes in the folder the window shows")
        show(work, ops)
        let named = TemplateStore.all.first { $0.folder != nil }
        let fromNamed = named.flatMap { QuickSwitcher.newNote(from: $0, in: work, navigation: navigation) }
        check(fromNamed != nil && store.folderPath(fromNamed?.folderID) == named?.folder && fromNamed?.folderID != ops.id && navigation.pendingNoteID == fromNamed?.id,
              "a template that names its own folder still files there (the Notes page then opens it there): \(store.folderPath(fromNamed?.folderID))")

        // ⌥⌘N: a note in its own window.
        let popoutsKept = AppDefaults.store.data(forKey: "notePopouts")
        func newInItsWindow() -> NoteItem? {
            let before = Set(((try? store.context.fetch(FetchDescriptor<NoteItem>())) ?? []).map(\.id))
            HubWindowController.shared.newNoteWindow(nil)
            let made = ((try? store.context.fetch(FetchDescriptor<NoteItem>())) ?? []).first { !before.contains($0.id) }
            if let made { NotePopouts.shared.close(made.id) }
            return made
        }
        show(work, ops)
        let popped = newInItsWindow()
        check(popped?.binderID == work.id && popped?.folderID == ops.id, "⌥⌘N's note in its own window goes in the folder the window shows")
        show(other, away)
        let poppedElsewhere = newInItsWindow()
        check(poppedElsewhere?.binderID == work.id && poppedElsewhere?.folderID == nil, "and with the window on another binder's folder, at the current binder's top")
        AppDefaults.store.set(popoutsKept, forKey: "notePopouts")

        // ⌘N with the window on another binder's folder: it goes in that binder, in that folder.
        show(other, away)
        HubWindowController.shared.newNote(nil)
        let commandN = navigation.pendingNoteID.flatMap { store.note($0) }
        check(commandN?.binderID == other.id && commandN?.folderID == away.id, "⌘N goes in the binder and folder the window shows")

        // A meeting, from the meeting hotkey, the menu bar, ⌘P's Start Meeting Notes or binders://meeting: each starts it
        // through MeetingService.start, which files it with MeetingService.file.
        func started() -> MeetingRecord {
            let record = MeetingRecord(title: "Standup", appName: "Zoom", templateID: "general")
            MeetingService.file(record)
            return record
        }
        show(work, ops)
        let meeting = started()
        check(meeting.binderID == work.id && meeting.folderID == ops.id && meeting.sharedWithTeam == work.sharedWithTeam,
              "a meeting started goes in the folder the window shows for the current binder")
        check(MeetingService.newPlace().folder == ops.id, "and ⌘P's Start Meeting Notes says so")
        show(work, nil)
        check(started().folderID == nil, "a meeting started with the window at the binder's top goes at the top")
        show(other, away)
        let startedElsewhere = started()
        check(startedElsewhere.binderID == work.id && startedElsewhere.folderID == nil, "with the window on another binder's folder, at the current binder's top")
        show(work, ops, page: .today)
        check(started().folderID == nil, "and with the window on another page, at the top")

        // The Captures page's Open a Binders File… inside a folder. The stand-in reads every capture as the other binder's,
        // so one the router may file moves there.
        controller.conversations.model = { StandInModel(reply: "BINDER: Field elsewhere\nREASON: it's about the other binder") }
        let words = "We walked through the booth plan for the Ignite booth, who brings the banners, when the stand goes up on Tuesday, "
            + "and that the printer needs the files by Friday so the posters arrive in time for the opening on Wednesday morning."
        func file() -> (url: URL, id: UUID) {
            let segment = TranscriptSegment(channel: .microphone, start: 0, end: 40, text: words, speaker: TranscriptSegment.you)
            let conversation = ConversationPayload(started: Date().addingTimeInterval(-900), ended: Date().addingTimeInterval(-860), segments: [segment],
                                                   device: "iPhone", engine: "parakeet-v2")
            let url = AppPaths.support.appendingPathComponent("Capture \(conversation.id.uuidString.prefix(8)).\(BindersTransfer.fileExtension)")
            try? BindersTransfer(conversations: [conversation]).encoded().write(to: url)
            return (url, conversation.id)
        }
        show(work, ops)
        let opened = file()
        BindersFiles.open(opened.url, controller: controller, folder: ops.id)
        check(store.meeting(opened.id)?.binderID == work.id && store.meeting(opened.id)?.folderID == ops.id,
              "a capture opened from a Binders file on the Captures page inside a folder goes in it")
        let fromFinder = file()
        BindersFiles.open(fromFinder.url, controller: controller)
        for _ in 0..<150 where !controller.conversations.processing.isEmpty
            || [opened.id, fromFinder.id].contains(where: { store.meeting($0)?.status == "processing" }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        check(store.meeting(opened.id)?.binderID == work.id && store.meeting(opened.id)?.folderID == ops.id && store.meeting(opened.id)?.status == "ready",
              "once it's read, it stays in that folder: the router leaves a capture you put in a folder where it is")
        check(store.meeting(fromFinder.id)?.binderID == other.id && store.meeting(fromFinder.id)?.folderID == nil,
              "one opened another way (AirDrop, Finder) is filed by the router as before: \(store.binder(store.meeting(fromFinder.id)?.binderID)?.name ?? "nowhere")")
    }

    /// Lane RF3, part of --selftest-folders: several meetings and captures at once, into a folder and to another binder, dragged
    /// and deleted, each with one Undo, and each by its own rules: a teammate's meeting stays and says why, one still recording
    /// stays in its binder (any folder in it will do) and isn't deleted, captures in a shared binder stay unshared.
    @MainActor
    static func severalMeetingsSelfTest(check: (Bool, String) -> Void, undoManager: () -> UndoManager) async {
        let store = Store.shared
        let controller = DictationController()
        let booth = BinderRecord(name: "Booth", colorIndex: 3)
        store.insert(booth)
        let shared = BinderRecord(name: "Team booth", colorIndex: 2)
        shared.sharedWithTeam = true
        store.insert(shared)
        func meeting(_ title: String, capture: Bool = false) -> MeetingRecord {
            let record = MeetingRecord(title: title, appName: capture ? "iPhone" : "Zoom", templateID: capture ? "conversation" : "general")
            if capture { record.kind = MeetingRecord.conversationKind }
            record.status = "ready"
            record.binderID = booth.id
            store.insert(record)
            return record
        }
        let mine = (1...3).map { meeting("Booth sync \($0)") }
        let theirs = meeting("A teammate's booth plan")
        theirs.isTeamCopy = true
        theirs.teamAuthorName = "Dana"
        let live = meeting("Booth standup")
        live.status = "recording"
        let several = mine + [theirs, live]
        let mineIDs = mine.map(\.id)
        guard let plans = store.createFolder(named: "Plans", in: booth.id) else { return check(false, "the folder to move meetings into is made") }

        // Into a folder: the four of yours go, the one still recording too, as it stays in its binder.
        let moves = undoManager()
        moves.beginUndoGrouping()
        let into = MeetingMoves.move(several, toFolder: plans.id, in: booth.id, undoManager: moves)
        moves.endUndoGrouping()
        check(into.moved.count == 4 && (mine + [live]).allSatisfy { $0.folderID == plans.id } && theirs.folderID == nil,
              "four meetings go into a folder at once, the one still recording too")
        let why = MeetingMoves.whyStayed(into.stayed) ?? ""
        check(into.stayed.map(\.id) == [theirs.id] && why.contains("Dana"), "a teammate's meeting stays where they filed it, and says why: \(why)")
        let line = into.line(asked: several.count, noun: ("meeting", "meetings"), place: FolderPrompts.place(binderID: booth.id, folder: plans.id), whyStayed: why)
        check(line == "Moved 4 meetings to Booth › Plans. Only Dana can move “A teammate's booth plan”: it's theirs, shared with you.", "it says so: \(line ?? "")")
        moves.undo()
        check(several.allSatisfy { $0.folderID == nil } && !moves.canUndo, "one Undo puts all four back")
        moves.redo()
        check((mine + [live]).allSatisfy { $0.folderID == plans.id }, "and Redo moves them again")

        // To another binder, shared with the team: three go and take on its sharing; the one recording and the teammate's stay.
        moves.beginUndoGrouping()
        let away = MeetingMoves.move(several, to: shared, undoManager: moves)
        moves.endUndoGrouping()
        check(away.moved.count == 3 && mine.allSatisfy { $0.binderID == shared.id && $0.folderID == nil && $0.sharedWithTeam },
              "to another binder, shared with the team: three go to its top, shared as it is")
        check(Set(away.stayed.map(\.id)) == [theirs.id, live.id] && live.binderID == booth.id && live.folderID == plans.id,
              "the one still recording stays in its binder and its folder")
        let both = MeetingMoves.whyStayed(away.stayed) ?? ""
        check(both.contains("still recording, so it stays in Booth") && both.contains("Dana"), "and each says why: \(both)")
        moves.undo()
        check(mine.allSatisfy { $0.binderID == booth.id && $0.folderID == plans.id && !$0.sharedWithTeam }, "one Undo puts all three back in their binder, folder and sharing")

        // Captures: to a shared binder, where they stay unshared, and into a folder; one Undo each.
        let chats = (1...2).map { meeting("Booth hallway \($0)", capture: true) }
        moves.beginUndoGrouping()
        let chatsAway = MeetingMoves.move(chats, to: shared, undoManager: moves)
        moves.endUndoGrouping()
        check(chatsAway.moved.count == 2 && chats.allSatisfy { $0.binderID == shared.id && !$0.sharedWithTeam }, "two captures go to a shared binder, and stay unshared")
        check(MeetingMoves.captureSharing(chatsAway.moved, in: shared) == "They stay on this Mac: captures aren't shared.", "and it says so")
        moves.undo()
        check(chats.allSatisfy { $0.binderID == booth.id }, "one Undo puts both captures back")
        moves.beginUndoGrouping()
        let chatsIn = MeetingMoves.move(chats, toFolder: plans.id, in: booth.id, undoManager: moves)
        moves.endUndoGrouping()
        check(chatsIn.moved.count == 2 && chats.allSatisfy { $0.folderID == plans.id }, "two captures go into a folder at once")
        moves.undo()
        check(chats.allSatisfy { $0.folderID == nil }, "and one Undo takes them out again")

        // Dragged together, onto the binder (as onto a folder, in a list, the path or the sidebar): one Undo each time.
        let payload = DraggedItem.payload(several.map { .meeting($0.id) })
        check(payload.split(separator: "\n").count == 5 && payload.split(separator: "\n").allSatisfy { DraggedItem(String($0)) != nil },
              "several meetings dragged together carry a line each")
        let drops = undoManager()
        drops.beginUndoGrouping()
        let dropped = DraggedItem.drop([payload], into: nil, binder: booth.id, undoManager: drops)
        drops.endUndoGrouping()
        check(dropped && (mine + [live]).allSatisfy { $0.folderID == nil }, "dropped on their binder, they all go to its top")
        drops.undo()
        check((mine + [live]).allSatisfy { $0.folderID == plans.id }, "one Undo puts the drop back")
        drops.beginUndoGrouping()
        _ = DraggedItem.drop([payload], into: nil, binder: shared.id, undoManager: drops)
        drops.endUndoGrouping()
        check(mine.allSatisfy { $0.binderID == shared.id } && live.binderID == booth.id && theirs.binderID == booth.id,
              "dropped on another binder, each keeps its own rules")
        drops.undo()
        check(mine.allSatisfy { $0.binderID == booth.id && $0.folderID == plans.id }, "and one Undo brings them back")

        // Deleted at once, each by its own rule; one Undo brings back the rest, their transcripts and recordings too.
        for (index, record) in mine.enumerated() {
            store.replaceSegments(for: record.id, with: [TranscriptSegment(channel: .microphone, start: 0, end: 5, text: "Line \(index) of the booth sync.",
                                                                           speaker: TranscriptSegment.you)])
        }
        let audio = "\(mine[0].id.uuidString)-mic.wav"
        let audioURL = AppPaths.meetings.appendingPathComponent(audio)
        try? Data("RIFF".utf8).write(to: audioURL)
        mine[0].micAudioFile = audio
        store.save()
        let service = controller.meetings
        let cannot = several.filter { MeetingDeletes.staysPut($0, service: service) != nil }
        let reasons = MeetingDeletes.whyStaying(cannot, service: service) ?? ""
        check(Set(cannot.map(\.id)) == [theirs.id, live.id] && reasons.contains("Only Dana can delete") && reasons.contains("still recording"),
              "a teammate's meeting and one still recording can't be deleted now, and say why: \(reasons)")
        let deletes = undoManager()
        deletes.beginUndoGrouping()
        let stayed = MeetingDeletes.delete(several, service: service, team: controller.team, undoManager: deletes)
        deletes.endUndoGrouping()
        try? await Task.sleep(for: .milliseconds(200))
        check(Set(stayed.map(\.id)) == [theirs.id, live.id] && mineIDs.allSatisfy { store.meeting($0) == nil } && store.meeting(theirs.id) != nil
              && store.meeting(live.id) != nil, "three deleted at once; the teammate's and the one recording stay")
        check(MeetingTrash.shared.lastDeleted.count == 3 && !FileManager.default.fileExists(atPath: audioURL.path) && store.segments(for: mineIDs[1]).isEmpty,
              "said as three, their transcripts gone and the recording set aside")
        deletes.undo()
        let back = mineIDs.compactMap { store.meeting($0) }
        check(back.count == 3 && back.allSatisfy { $0.binderID == booth.id && $0.folderID == plans.id } && MeetingTrash.shared.restoredMeetings == Set(mineIDs),
              "one Undo puts all three back, in their folder")
        check(store.segments(for: mineIDs[1]).first?.text == "Line 1 of the booth sync." && FileManager.default.fileExists(atPath: audioURL.path)
              && back.first { $0.id == mineIDs[0] }?.micAudioFile == audio, "with their transcripts and recordings")
        deletes.redo()
        try? await Task.sleep(for: .milliseconds(200))
        check(mineIDs.allSatisfy { store.meeting($0) == nil }, "Redo deletes them again")
        MeetingTrash.forgetWaiting(keepingThisRun: false)
        let waiting = (try? FileManager.default.contentsOfDirectory(at: MeetingTrash.waitingRoom, includingPropertiesForKeys: nil)) ?? []
        check(waiting.isEmpty && !FileManager.default.fileExists(atPath: audioURL.path), "at quit, the recordings that waited for Undo go for good")
    }

    /// Lane RF3, part of --selftest-folders: ⌘O says where a note or meeting is: its binder and the folders down to it.
    /// Drawn to `directory` when one is given, the switcher open on a query.
    @MainActor
    static func switcherPlacesSelfTest(check: (Bool, String) -> Void, work: BinderRecord, folder: FolderRecord?, drawingTo directory: URL?) async {
        let store = Store.shared
        let note = NoteItem(text: "# Quillback runner rota\n\nWho restarts the runners. #ops")
        note.binderID = work.id
        note.folderID = folder?.id
        store.insert(note)
        let review = MeetingRecord(title: "Quillback runner review", appName: "Zoom", templateID: "general")
        review.status = "ready"
        review.binderID = work.id
        review.folderID = folder?.id
        store.insert(review)
        let top = NoteItem(text: "# Quillback at the top")
        top.binderID = work.id
        store.insert(top)
        let folders = FolderLookup()
        let noteLine = QuickSwitcher.subtitle(of: note, binder: work.name, folders: folders)
        check(noteLine == "Note · Work › Platform › Pipelines", "⌘O shows a note's folder path beside its binder: \(noteLine)")
        let meetingLine = QuickSwitcher.subtitle(of: review, binder: work.name, folders: folders)
        check(meetingLine.hasPrefix("Meeting · Work › Platform › Pipelines · "), "and a meeting's, before its date: \(meetingLine)")
        check(QuickSwitcher.subtitle(of: top, binder: work.name, folders: folders) == "Note · Work", "at the top of a binder, the binder alone")
        let tagged = QuickSwitcher.subtitle(of: note, binder: work.name, folders: folders, tags: ["ops"])
        check(tagged == "Note · Work › Platform › Pipelines · #ops", "and with #tags, the path before them: \(tagged)")
        guard let directory else { return }
        // The switcher itself, open on a query, as you'd see it.
        let controller = DictationController()
        let navigation = HubNavigation()
        navigation.switcherQuery = "Quillback"
        navigation.switcher = .open
        let window = HubWindowController.makeWindow(HubView()
            .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
            .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        window.alphaValue = 0
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1500))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let content = window.contentView { capture(content, name: "folders-switcher", directory: directory) }
        window.close()
    }

    /// The meetings and captures pages with several selected (a teammate's meeting among them), in the real window at its
    /// default size and at its smallest: the page says how many; one selected opens it, as before; Select All (⌘A) selects
    /// every one in the list. Drawn to `directory`.
    @MainActor
    static func drawSeveralMeetings(into directory: URL, check: (Bool, String) -> Void) async {
        FitProbe.isOn = true
        defer { FitProbe.isOn = false }
        let store = Store.shared
        let binder = BinderRecord(name: "Events", colorIndex: 4)
        store.insert(binder)
        guard let folder = store.createFolder(named: "Ignite booth", in: binder.id) else { return check(false, "the folder to draw is made") }
        for (index, title) in ["Booth layout review", "Banner proofs with the printer", "Staffing the stand", "Shipping the crates"].enumerated() {
            let record = MeetingRecord(title: title, appName: "Zoom", templateID: "general")
            record.status = "ready"
            record.binderID = binder.id
            record.folderID = folder.id
            record.createdAt = Date().addingTimeInterval(-Double(index) * 3_600)
            record.summary = "## Summary\n\n- " + title
            if index == 2 {
                record.isTeamCopy = true
                record.teamAuthorName = "Dana"
            }
            store.insert(record)
        }
        for (index, title) in ["Hallway chat about the banners", "Lunch talk about the crates", "Walk back from the venue"].enumerated() {
            let record = MeetingRecord(title: title, appName: "iPhone", templateID: "conversation")
            record.kind = MeetingRecord.conversationKind
            record.status = "ready"
            record.binderID = binder.id
            record.folderID = folder.id
            record.createdAt = Date().addingTimeInterval(-Double(index) * 5_400)
            store.insert(record)
        }
        let controller = DictationController()
        let all = (try? store.context.fetch(FetchDescriptor<MeetingRecord>())) ?? []
        for (tab, captures) in [(BinderTab.meetings, false), (.conversations, true)] {
            let kind = captures ? "captures" : "meetings"
            let here = all.filter { $0.binderID == binder.id && $0.isConversation == captures }.map(\.id)
            let navigation = HubNavigation()
            navigation.selection = .binder
            navigation.binderID = binder.id
            navigation.folderID = folder.id
            navigation.pendingBinderTab = tab
            MeetingsView.selectOnOpen = Set(here)
            defer { MeetingsView.selectOnOpen = nil }
            let window = HubWindowController.makeWindow(HubView()
                .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
                .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
                .modelContainer(Store.shared.container))
            window.alphaValue = 0
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(1800))
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let content = window.contentView { capture(content, name: "folders-several-\(kind)-1020", directory: directory) }
            check(!FitProbe.frames("meetings.several", in: window).isEmpty, "the \(kind) page with several selected says how many and offers what to do with them")
            MeetingsView.selectOnOpen = nil
            window.setContentSize(HubWindowController.smallestSize)
            try? await Task.sleep(for: .milliseconds(900))
            if let content = window.contentView { capture(content, name: "folders-several-\(kind)-840", directory: directory) }
            // One, then Select All, as ⌘A sends it to the list.
            func tables(_ view: NSView) -> [NSTableView] { ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables) }
            navigation.pendingMeetingID = here.first
            try? await Task.sleep(for: .milliseconds(700))
            check(FitProbe.frames("meetings.several", in: window).isEmpty, "one of the \(kind) selected opens it, as before")
            if let list = window.contentView.map(tables)?.first {
                window.makeFirstResponder(list)
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: list, from: nil)
                try? await Task.sleep(for: .milliseconds(700))
                check(!FitProbe.frames("meetings.several", in: window).isEmpty && list.selectedRowIndexes.count >= here.count,
                      "Select All (⌘A) in the \(kind) list selects every one in it: \(list.selectedRowIndexes.count) rows")
            } else {
                check(false, "the \(kind) list is there to select in")
            }
            window.close()
        }
    }
}
