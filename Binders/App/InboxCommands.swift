import AppKit
import SwiftData
import BindersKit

/// The writes that arrive through the inbox (see `Inbox` in BindersKit): notes, binders, meetings from elsewhere, to-dos.
@MainActor
enum InboxCommands {
    static var directory: URL { AppPaths.support.appendingPathComponent(Inbox.folder, isDirectory: true) }

    /// binders://apply?file=<name>: performs the request and leaves the result beside it.
    static func apply(named name: String, controller: DictationController) async {
        guard Inbox.isValidName(name) else {
            Log.app.error("Inbox: request name is not a UUID")
            return
        }
        let requestURL = directory.appendingPathComponent(Inbox.requestFile(name))
        let resultURL = directory.appendingPathComponent(Inbox.resultFile(name))
        let result: InboxResult
        if let data = try? Data(contentsOf: requestURL), let request = try? JSONDecoder().decode(InboxRequest.self, from: data) {
            result = await perform(fromAgent(request), controller: controller)
        } else {
            result = .failure("Couldn't read the request")
        }
        try? JSONEncoder().encode(result).write(to: resultURL, options: .atomic)
        try? FileManager.default.removeItem(at: requestURL)
    }

    /// A request file comes only from `Binders --mcp`, but any process on this Mac can write one: whoever it names acts as
    /// an agent, and never as you. The phone and the app's own windows act in-process, as you.
    static func fromAgent(_ request: InboxRequest) -> InboxRequest {
        var request = request
        request.fields["actor_kind"] = BoardActor.Kind.agent.rawValue
        if BoardRules.isReserved(request.fields["actor"] ?? "") { request.fields["actor"] = "AI agent" }
        return request
    }

    /// An agent adding, changing or taking away a correction in a note that isn't its own (yours, or another agent's),
    /// where it would count as theirs: refused, with where it goes instead. Anything else an agent writes in a note is
    /// fine; its history keeps what it said before.
    static func agentCorrecting(_ note: NoteItem, to text: String, _ request: InboxRequest) -> InboxResult? {
        guard request.fields["actor_kind"] == BoardActor.Kind.agent.rawValue else { return nil }
        let own = note.madeBy != nil && note.madeBy == request.fields["actor"]
        guard !own, KnowledgeCorrection.parse(text) != KnowledgeCorrection.parse(note.text) else { return nil }
        return .failure("A correction from an agent goes through correct_knowledge, which keeps it as the agent's until the user makes it their own. It can't go into, or out of, a note that isn't the agent's.")
    }

    /// An agent changing a note that isn't its own marks it as that agent's edit, with when, until the user makes it
    /// theirs: the note says so, and answers and corrections leave it out. Returns what the agent hears about that.
    static func markAgentEdit(_ note: NoteItem, _ request: InboxRequest) -> String {
        guard request.fields["actor_kind"] == BoardActor.Kind.agent.rawValue else { return "" }
        let actor = (request.fields["actor"] ?? "").trimmed
        let agent = actor.isEmpty ? "An AI agent" : actor
        guard note.markEdited(by: agent) else { return "" }
        return " It's marked as edited by \(agent), so answers leave it out until the user makes it their own."
    }

    static func perform(_ request: InboxRequest, controller: DictationController) async -> InboxResult {
        // Nothing is saved while the library didn't open: a write said to have worked would be gone at quit. A calendar
        // event is kept in Calendar, not the library, so it still goes.
        if !Store.shared.canSave, request.action != "add_to_calendar" { return .failure(Store.refusedMessage) }
        // Sent again with the same request_id (the iPhone's outbox, its reply lost on the way): the first answer, and
        // nothing done twice. Only what worked is kept, so one that failed can be sent again.
        guard let handled = HandledRequests.key(for: request) else { return await carryOut(request, controller: controller) }
        if let earlier = HandledRequests.shared.answer(for: handled) { return earlier }
        let result = await carryOut(request, controller: controller)
        if result.ok { HandledRequests.shared.remember(result, for: handled) }
        return result
    }

    /// The write itself, once: what `perform` hands on when it isn't refused or answered already.
    private static func carryOut(_ request: InboxRequest, controller: DictationController) async -> InboxResult {
        // A note being typed in is read as it is on screen, not as it was a moment ago.
        MarkdownEditor.flushAll()
        func field(_ key: String) -> String { (request.fields[key] ?? "").trimmed }
        let store = Store.shared
        switch request.action {
        case "add_note":
            let text = field("text")
            guard !text.isEmpty else { return .failure("text is required") }
            guard let binder = binder(named: field("binder")) else { return .failure(noBinder(field("binder"))) }
            let note = NoteItem(text: text)
            note.binderID = binder.id
            note.sharedWithTeam = binder.sharedWithTeam
            // An agent's note says so.
            if field("actor_kind") == BoardActor.Kind.agent.rawValue { note.madeBy = field("actor").isEmpty ? "An AI agent" : field("actor") }
            store.insert(note)
            return InboxResult(ok: true, id: note.id.uuidString, message: "Note “\(note.title)” added to \(binder.name)")

        case "append_to_note":
            guard let id = UUID(uuidString: field("id")) else { return .failure("id must be a note id") }
            let text = field("text")
            guard !text.isEmpty else { return .failure("text is required") }
            guard let note = (try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })))?.first else {
                return .failure("No note with that id")
            }
            let appended = note.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + text
            if let refused = agentCorrecting(note, to: appended, request) { return refused }
            NoteHistory.willChange(note, to: appended, always: true)
            note.text = appended
            note.updatedAt = Date()
            let marked = markAgentEdit(note, request)
            store.save()
            return InboxResult(ok: true, id: note.id.uuidString, message: "Appended to “\(note.title)”.\(marked)")

        case "update_note":
            guard let id = UUID(uuidString: field("id")) else { return .failure("id must be a note id") }
            guard let note = store.note(id) else { return .failure("No note with that id") }
            let find = request.fields["find"] ?? "", replace = request.fields["replace"] ?? "", whole = field("text")
            let updated: String
            if !find.isEmpty {
                switch KnowledgeCorrections.occurrences(of: find, in: note.text) {
                case 0: return .failure("That passage isn't in “\(note.title)”. Give it exactly as get_note shows it.")
                case 1: updated = note.text.replacingOccurrences(of: find, with: replace)
                case let count: return .failure("That passage is in “\(note.title)” \(count) times. Give more of it, so it's there once.")
                }
            } else if !whole.isEmpty {
                updated = whole
            } else {
                return .failure("Give find and replace, to change a passage, or text, to replace the whole note")
            }
            guard updated != note.text else { return InboxResult(ok: true, id: note.id.uuidString, message: "“\(note.title)” already says that") }
            if let refused = agentCorrecting(note, to: updated, request) { return refused }
            // What it said before stays in its history, so the change can be undone.
            NoteHistory.willChange(note, to: updated, always: true)
            let oldTitle = MarkdownSyntax.noteTitle(note.text)
            note.text = updated
            note.updatedAt = Date()
            let marked = markAgentEdit(note, request)
            store.save()
            // A new title: links to the old one follow it.
            let renamed = oldTitle.isEmpty ? nil : LinkTargets.renameNote(note.id, from: oldTitle, to: note.title, itself: true)
            let links = renamed.map { $0.links > 0 ? ". Links that follow the new title: \($0.counted)" : "" } ?? ""
            return InboxResult(ok: true, id: note.id.uuidString, message: "Updated “\(note.title)”; the earlier version is in its history\(links).\(marked)")

        case "correct_knowledge":
            let correction = KnowledgeCorrection(wrong: field("wrong"), right: field("right"), reason: field("reason"))
            guard !correction.wrong.isEmpty, !correction.right.isEmpty else { return .failure("wrong and right are required") }
            guard correction.isSpecific else {
                return .failure("Quote at least a few words of the wrong statement as it's written, so it can be recognised where it appears")
            }
            // Where the wrong thing is: a note is fixed; a meeting, dictation or message stays as it was said.
            var source: (title: String, binderID: UUID?)?
            var fixed = false
            let byAgent = field("actor_kind") == BoardActor.Kind.agent.rawValue
            if let id = UUID(uuidString: field("source_id")) {
                if let note = store.note(id) {
                    source = (note.title, note.binderID)
                    // An agent fixes only a note of its own: yours, or another agent's, stays as written, with the correction beside it.
                    if !byAgent || (note.madeBy != nil && note.madeBy == field("actor")),
                       let updated = KnowledgeCorrections.fixing(note.text, wrong: correction.wrong, right: correction.right) {
                        NoteHistory.willChange(note, to: updated, always: true)
                        note.text = updated
                        note.updatedAt = Date()
                        fixed = true
                    }
                } else if let meeting = (try? store.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id })))?.first {
                    source = (meeting.title, meeting.binderID)
                } else if let writing = (try? store.context.fetch(FetchDescriptor<WritingRecord>(predicate: #Predicate { $0.id == id })))?.first {
                    source = (writing.title, writing.binderID)
                } else if let dictation = (try? store.context.fetch(FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.id == id })))?.first {
                    source = ("Dictation, \(dictation.createdAt.formatted(date: .abbreviated, time: .shortened))", nil)
                } else {
                    return .failure("Nothing has that source_id. Use the source_id from search_knowledge, or leave it out.")
                }
            }
            let named = field("binder").isEmpty ? nil : binder(named: field("binder"))
            if !field("binder").isEmpty, named == nil { return .failure(noBinder(field("binder"))) }
            // About a capture, or something said to yourself, it quotes it: kept in a binder that isn't shared, when there is one.
            // A note made from what you said counts by its own mark too, as Delete All may have taken its moment away.
            let sourceID = UUID(uuidString: field("source_id"))
            let quotesCapture = store.isConversation(sourceID) || sourceID.map(store.isMoment) == true
                || sourceID.flatMap { store.note($0) }?.staysUnshared == true
            var target = named ?? source?.binderID.flatMap { store.binder($0) } ?? binder(named: "")
            if quotesCapture, let shared = target, shared.sharedWithTeam || shared.isTeamCopy {
                target = store.binders().first { !$0.sharedWithTeam && !$0.isTeamCopy } ?? shared
            }
            guard let target else { return .failure(noBinder("")) }
            let where_ = source.map { fixed ? "fixed in “\($0.title)”, and kept" : "kept beside “\($0.title)”, which stays as it was" } ?? "kept"
            // The same correction made again (for another place that said it) stays one correction, an agent's too.
            let same = controller.knowledge.corrections(includingAgents: true).first {
                KnowledgeCorrections.normalize($0.correction.wrong) == KnowledgeCorrections.normalize(correction.wrong)
                    && KnowledgeCorrections.normalize($0.correction.right) == KnowledgeCorrections.normalize(correction.right)
            }
            if let same {
                store.save()
                return InboxResult(ok: true, id: same.id.uuidString, message: "Correction \(where_). It was already kept; search and answers follow it.")
            }
            var kept = correction
            kept.source = source?.title
            let note = NoteItem(text: kept.markdown)
            note.binderID = target.id
            // It quotes its source: about a capture, it stays off the team folder like the capture, even in a shared binder,
            // and wherever it's moved or its binder shared later.
            note.sharedWithTeam = target.sharedWithTeam && !quotesCapture
            note.staysUnshared = quotesCapture
            // An agent's correction is its note: answers follow only yours.
            if byAgent { note.madeBy = field("actor").isEmpty ? "An AI agent" : field("actor") }
            store.insert(note)
            store.save()
            return InboxResult(ok: true, id: note.id.uuidString, message: byAgent
                ? "Correction \(where_) in \(target.name), in a note marked as yours, an agent's. Answers follow it once the user makes it their own."
                : "Correction \(where_) in \(target.name). Search marks what still says the wrong thing; answers use the correction.")

        case "create_binder":
            let name = field("name")
            guard !name.isEmpty else { return .failure("name is required") }
            let all = store.binders(includeArchived: true)
            if let existing = all.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                return InboxResult(ok: true, id: existing.id.uuidString, message: "Binder “\(existing.name)” already exists")
            }
            let used = Set(all.map(\.colorIndex))
            let binder = BinderRecord(name: name, colorIndex: (0..<BinderRecord.paletteSize).first { !used.contains($0) } ?? all.count % BinderRecord.paletteSize)
            store.insert(binder)
            return InboxResult(ok: true, id: binder.id.uuidString, message: "Binder “\(name)” created")

        case "add_meeting":
            let title = field("title"), notes = field("notes")
            guard !title.isEmpty, !notes.isEmpty else { return .failure("title and notes are required") }
            guard let binder = binder(named: field("binder")) else { return .failure(noBinder(field("binder"))) }
            let record = MeetingRecord(title: title, appName: field("app").isEmpty ? "Imported" : field("app"), templateID: AppSettings.shared.meetingTemplateID)
            let date = parseDate(field("date")) ?? Date()
            record.createdAt = date
            record.duration = Double(max(0, Int(field("duration_minutes")) ?? 0) * 60)
            record.endedAt = date.addingTimeInterval(record.duration)
            record.attendees = field("attendees").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            record.summary = notes
            record.status = "ready"
            record.binderID = binder.id
            record.sharedWithTeam = binder.sharedWithTeam
            store.insert(record)
            return InboxResult(ok: true, id: record.id.uuidString, message: "Meeting “\(title)” added to \(binder.name)")

        case "set_todo_status":
            let status = field("status").lowercased()
            guard ["open", "done", "dismissed"].contains(status) else { return .failure("status must be open, done or dismissed") }
            if let reference = BoardTaskReference(field("id")) {
                guard status != "dismissed" else { return .failure("Only promises can be dismissed. Mark this one done instead.") }
                return setTask(reference, done: status == "done")
            }
            guard let id = UUID(uuidString: field("id")) else { return .failure("id must be a to-do id from list_todos") }
            guard let todo = store.commitments().first(where: { $0.id == id }) else { return .failure("No to-do with that id") }
            controller.commitments.setStatus(todo, status)
            return InboxResult(ok: true, id: todo.id.uuidString, message: "“\(todo.task)” is now \(status)")

        case "add_todo":
            let text = field("text")
            guard !text.isEmpty else { return .failure("text is required") }
            // Into the named binder, when one is given; otherwise the current one.
            let target = field("binder").isEmpty ? nil : binder(named: field("binder"))
            if !field("binder").isEmpty, target == nil { return .failure(noBinder(field("binder"))) }
            // An agent's or a tool's to-do says whose it is, as its card would, and your automations leave it be unless a
            // rule takes such to-dos. The iPhone's is yours.
            let byAgent = field("actor_kind") == BoardActor.Kind.agent.rawValue
            let added = controller.commitments.addSpoken(text, binderID: target?.id, origin: byAgent ? .agent : .phone,
                                                         madeBy: byAgent ? (field("actor").isEmpty ? "AI agent" : field("actor")) : nil)
            return InboxResult(ok: true, id: added.commitment.id.uuidString, message: added.line)

        case "create_task":
            return await createTask(field: field, controller: controller)

        case "claim_task", "update_task", "ask_on_task", "comment_task", "release_task", "complete_task", "report_run", "request_approval":
            return boardAction(request.action, fields: request.fields, field: field, controller: controller)

        case "add_to_calendar":
            let text = field("text")
            guard !text.isEmpty else { return .failure("text is required") }
            let result = await controller.addToCalendar(described: text)
            return result.added ? InboxResult(ok: true, message: result.line) : .failure(result.line)

        default:
            return .failure("Unknown action \(request.action)")
        }
    }

    /// Ticks or unticks a checklist item in a meeting's notes, a note's digest or a note, found by its words.
    private static func setTask(_ reference: BoardTaskReference, done: Bool) -> InboxResult {
        guard let text = Todos.setDone(reference.string, done, commitments: nil) else { return .failure(todoGone) }
        return InboxResult(ok: true, id: reference.string, message: "“\(text)” is now \(done ? "done" : "open")")
    }

    private static let todoGone = "That to-do has changed or is gone. list_todos has the current ones."

    /// A new card, by the actor named in the request: an agent or a tool over MCP, or you from the iPhone. Its binder is the
    /// one named; an agent or a tool that names none gets the binder the router picks for it (Tev1 at its General
    /// threshold), else the current binder, as the tool says. Who it's for is `for`, as before (from an agent, a suggestion
    /// that waits for your tap); without it, the router suggests the agent whose work it is a moment later. Nothing from
    /// MCP or the iPhone starts an agent without your tap.
    private static func createTask(field: (String) -> String, controller: DictationController) async -> InboxResult {
        let board = controller.board
        let actor = BoardActor(name: field("actor").isEmpty ? "AI agent" : field("actor"),
                               kind: BoardActor.Kind(rawValue: field("actor_kind")) ?? .agent)
        let column: BoardColumn = BoardColumn(loose: field("column")) == .ready ? .ready : .backlog
        // A card the iPhone makes from a to-do carries the to-do's words, which may be an agent's or a meeting's: read as
        // Add to Board on the Mac reads them, by Tev1 alone, never as you naming an agent.
        let origin: RouteOrigin = actor.isAgent ? .mcp : (field("todo").isEmpty ? .phone : .toBoard)
        if !field("todo").isEmpty {
            // A card for a to-do goes to the to-do's binder unless another is named, and stays linked to it.
            guard let todo = Todos.find(field("todo")) else { return .failure(todoGone) }
            if !field("binder").isEmpty, binder(named: field("binder")) == nil { return .failure(noBinder(field("binder"))) }
            let target = field("binder").isEmpty ? nil : binder(named: field("binder"))?.id
            let made = board.create(from: todo, column: column, binderID: target, title: field("title").isEmpty ? nil : field("title"),
                                    details: field("details"), by: actor)
            if !made.existed, !field("for").isEmpty {
                board.assign(made.card, to: field("for"), by: actor)
                // Yours, from the iPhone: in Ready for someone, it's a hand-off, made at once.
                if !actor.isAgent { controller.agents.handOff(made.card) }
            } else if !made.existed {
                controller.router.suggestLater(for: made.card, origin: origin)
            }
            let name = Store.shared.binder(made.card.binderID)?.name ?? "binder's"
            return InboxResult(ok: true, id: made.card.id.uuidString, message: made.existed
                ? "That to-do is already on the \(name) board as “\(made.card.title)”, in \(made.card.column.title)."
                : "Card “\(made.card.title)” added to the \(name) board, in \(made.card.column.title). The to-do is ticked off when the card is done.")
        }
        guard !field("title").isEmpty else { return .failure("title is required") }
        var target: BinderRecord
        var routed: CardRouter.Decision?
        if field("binder").isEmpty, actor.isAgent {
            (target, routed) = await controller.router.binderForMCP(title: field("title"))
        } else {
            guard let named = binder(named: field("binder")) else { return .failure(noBinder(field("binder"))) }
            target = named
        }
        let card = board.create(title: field("title"), details: field("details"), binderID: target.id, column: column, by: actor)
        if var routed {
            routed.card = card.id
            controller.router.record(routed)
        }
        if !field("for").isEmpty {
            board.assign(card, to: field("for"), by: actor)
            if !actor.isAgent { controller.agents.handOff(card) }
        } else {
            controller.router.suggestLater(for: card, origin: origin)
        }
        return InboxResult(ok: true, id: card.id.uuidString, message: "Card “\(card.title)” added to the \(target.name) board, in \(card.column.title)")
    }

    /// A change to a card, by the actor named in the request (an agent over MCP, or you from the phone).
    private static func boardAction(_ action: String, fields: [String: String], field: (String) -> String, controller: DictationController) -> InboxResult {
        let board = controller.board
        let actor = BoardActor(name: field("actor").isEmpty ? "AI agent" : field("actor"),
                               kind: BoardActor.Kind(rawValue: field("actor_kind")) ?? .agent)
        guard let id = UUID(uuidString: field("id")), let card = board.card(id) else {
            return .failure("No card with that id. list_tasks shows them.")
        }
        do {
            switch action {
            case "claim_task":
                // Paused: agents leave the cards alone, the ones that check the board themselves too.
                if actor.isAgent, AgentRegistry.shared.paused {
                    return .failure("Agents are paused in Binders, so leave the card for now. The user resumes them in Settings → Agents.")
                }
                if let meant = meantForAnother(card, actor: actor) { return .failure(meantForLine(meant)) }
                try board.claim(card, by: actor)
                let until = card.claimExpiresAt.map { " until \($0.formatted(date: .omitted, time: .shortened)); every update extends it" } ?? ""
                return InboxResult(ok: true, id: card.id.uuidString, message: "“\(card.title)” is yours\(until). It's \(card.column.title).")
            case "update_task":
                let heldBefore = BoardRules.isClaimed(card.state, at: Date()) && card.assignee == actor.name
                let placed = (card.column, card.meantFor, card.meantForByAgent)
                // Your Give to from the iPhone, who it's for and then Ready: a hand-off, made at once, as Give to on this Mac
                // is. Edits on this Mac wait the usual moment.
                defer {
                    if !actor.isAgent, fields["for"] != nil || !field("column").isEmpty, placed != (card.column, card.meantFor, card.meantForByAgent) {
                        controller.agents.handOff(card)
                    }
                }
                // Paused: no taking a card by moving it to In progress either; one it already holds it may report on.
                if actor.isAgent, AgentRegistry.shared.paused, !heldBefore, BoardColumn(loose: field("column")) == .inProgress {
                    return .failure("Agents are paused in Binders, so leave the card for now. The user resumes them in Settings → Agents.")
                }
                // Taking it by moving it to In progress is a claim too.
                if !heldBefore, BoardColumn(loose: field("column")) == .inProgress, let meant = meantForAnother(card, actor: actor) {
                    return .failure(meantForLine(meant))
                }
                // Who it's for, when given, first: then a move to Ready hands it over in one go. An agent's choice is a
                // suggestion until you assign it yourself, and never replaces yours.
                var kept = ""
                if fields["for"] != nil, !board.assign(card, to: field("for"), by: actor) {
                    kept = " The user chose who it's for (\(card.meantFor ?? "")), so that stays; say what you think in a comment."
                }
                if let column = BoardColumn(loose: field("column")) { try board.move(card, to: column, by: actor) }
                if !field("progress").isEmpty || !field("links").isEmpty {
                    let links = field("links").split(whereSeparator: { $0 == "\n" || $0 == "," }).map(String.init)
                    board.report(card, progress: field("progress"), links: links, by: actor)
                }
                // An agent reporting on a card it doesn't hold (taken over, or lapsed) hears so; not one that just let it
                // go or finished it.
                let holder = BoardRules.isClaimed(card.state, at: Date()) ? card.assignee : nil
                var lost = ""
                if actor.isAgent, !heldBefore, card.column != .done, holder != actor.name {
                    lost = holder.map { " \($0 == BoardActor.you.name ? "The user" : $0) has it now, so pick another card." }
                        ?? " You don't hold it; claim_task it to keep working on it."
                }
                return InboxResult(ok: true, id: card.id.uuidString, message: "Updated “\(card.title)”. It's \(card.column.title).\(lost)\(kept)")
            case "ask_on_task":
                try board.ask(card, question: field("text"), by: actor)
                return InboxResult(ok: true, id: card.id.uuidString, message: "Asked. “\(card.title)” waits in Blocked until the user answers; get_task shows the answer.")
            case "request_approval":
                // Exactly what the user is shown; the text as written, past the space around it.
                let asked = AgentApproval(action: field("what"), recipients: AgentApproval.recipients(from: fields["recipients"] ?? ""),
                                          text: fields["text"] ?? "", link: field("link"))
                if let problem = asked.problem { return .failure(problem) }
                try board.requestApproval(card, asked, by: actor)
                return InboxResult(ok: true, id: card.id.uuidString,
                                   message: "Asked. “\(card.title)” waits in Blocked until the user approves or declines. Stop here, and do nothing outside Binders for it until then: their answer, “Approved” or “Declined: …”, comes back on the card (get_task).")
            case "comment_task":
                // A phone's comment names the agent it asked you about, or none: it wakes that agent at most.
                board.comment(card, text: field("text"), by: actor, wake: CommentWake(field: fields["wake_for"]))
                return InboxResult(ok: true, id: card.id.uuidString, message: "Comment added to “\(card.title)”.")
            case "release_task":
                try board.release(card, note: field("text"), by: actor)
                return InboxResult(ok: true, id: card.id.uuidString, message: "Released “\(card.title)”. It's back in \(card.column.title).")
            case "complete_task":
                if actor.isAgent, AgentRegistry.shared.paused, !(BoardRules.isClaimed(card.state, at: Date()) && card.assignee == actor.name) {
                    return .failure("Agents are paused in Binders, so leave the card for now. The user resumes them in Settings → Agents.")
                }
                try board.complete(card, summary: field("text"), by: actor)
                return InboxResult(ok: true, id: card.id.uuidString,
                                   message: card.column == .done ? "“\(card.title)” is done." : "“\(card.title)” is in Review for the user to check.")
            case "report_run":
                // A Stop or SessionEnd hook of a Claude Code run Binders started (`Binders --agent-hook`): its last word on
                // the card, once a run. Not one of the MCP tools.
                let posted = controller.agents.reported(card, session: field("session"), text: field("text"), by: actor)
                return InboxResult(ok: true, id: card.id.uuidString, message: posted ? "Reported on “\(card.title)”." : "Nothing more to report on “\(card.title)” for this run.")
            default:
                return .failure("Unknown action \(action)")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// The agent a card made from what the iPhone heard is meant for, when you or Binders meant it for one (not an agent's
    /// suggestion) and `actor` is another agent: such a card is that agent's to take, as Auto may have made it ready for
    /// an agent it couldn't wake yet (DESIGN 3.9). Cards from anywhere else keep the board's rule: any agent may take a free
    /// card. Nil when the actor may take it.
    static func meantForAnother(_ card: TaskCard, actor: BoardActor) -> String? {
        guard actor.isAgent, let meant = card.meantFor, !card.meantForByAgent, MCPServer.fromCapture(card) else { return nil }
        if actor.name.trimmed.localizedCaseInsensitiveCompare(meant.trimmed) == .orderedSame { return nil }
        let registry = AgentRegistry.shared
        if let mine = registry.agent(named: actor.name), mine.id == registry.agent(named: meant)?.id { return nil }
        return meant
    }

    /// What another agent hears when it tries to take a card meant for `agent`.
    static func meantForLine(_ agent: String) -> String {
        "This card is meant for \(agent). Leave it for them."
    }

    /// The named binder, or the current one when no name is given. Nil when a name is given and nothing matches.
    private static func binder(named name: String) -> BinderRecord? {
        guard !name.isEmpty else { return Store.shared.binder(AppSettings.shared.currentBinderID) ?? Store.shared.defaultBinder() }
        // By name, or by the id list_binders gives.
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = Store.shared.binders(includeArchived: true)
        if let id = UUID(uuidString: key), let byID = all.first(where: { $0.id == id }) { return byID }
        return all.first { $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame }
    }

    private static func noBinder(_ name: String) -> String {
        "No binder named “\(name)”. list_binders shows the names; create_binder makes a new one."
    }

    private static func parseDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
