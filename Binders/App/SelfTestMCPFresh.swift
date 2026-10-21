import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// `Binders --mcp` reads what the app has now, not what it had when the agent first asked: a real `Binders --mcp` on
    /// this folder reads a card, a note and a to-do, the app (this test) changes them, and the second read must show the
    /// change. In a throwaway folder (BINDERS_DATA_DIR) only.
    @MainActor
    static func mcpFreshSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes cards")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        func object(_ text: String?) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data((text ?? "").utf8))) as? [String: Any] ?? [:] }
        func objects(_ text: String?) -> [[String: Any]] { (try? JSONSerialization.jsonObject(with: Data((text ?? "").utf8))) as? [[String: Any]] ?? [] }
        let controller = DictationController()
        let store = Store.shared
        let board = controller.board
        let binder = store.defaultBinder()
        let card = board.create(title: "Book the Ignite booth", details: "Stand 14, by the north entrance.", binderID: binder.id, column: .ready, by: .you)
        let leaving = board.create(title: "Print the flyers", binderID: binder.id, column: .ready, by: .you)
        let note = NoteItem(text: "# Booth plan\n\nThe booth is stand 14.")
        note.binderID = binder.id
        store.insert(note)
        let todo = controller.commitments.addSpoken("Call the venue about the loading dock")
        store.save()

        guard let child = MCPChild(controller: controller) else {
            check(false, "a Binders --mcp of its own starts")
            return 1
        }
        defer { child.stop() }
        guard await child.initialize() else {
            check(false, "a Binders --mcp of its own answers")
            return 1
        }

        // First reads: what the child sees before the app changes anything.
        let firstCard = object(await child.call("get_task", ["id": card.id.uuidString]))
        check(firstCard["title"] as? String == "Book the Ignite booth" && firstCard["column"] as? String == "ready",
              "the child reads the card: \(firstCard["title"] as? String ?? "nothing")")
        let firstList = objects(await child.call("list_tasks", [:]))
        check(firstList.contains { $0["id"] as? String == leaving.id.uuidString }, "and lists both cards")
        let firstNote = object(await child.call("get_note", ["id": note.id.uuidString]))
        check((firstNote["text"] as? String)?.contains("stand 14") == true, "reads the note")
        let firstTodos = objects(await child.call("list_todos", ["status": "all"]))
        check(firstTodos.first { $0["id"] as? String == todo.commitment.id.uuidString }?["status"] as? String == "open", "and the to-do, open")

        // The app changes them: a new title and details, a move, a comment, the note's words, the to-do ticked, a card
        // deleted and a new one made.
        board.edit(card, title: "Book the Ignite booth by Friday", details: "Stand 16 now, by the café.", by: .you)
        try? board.move(card, to: .backlog, by: .you)
        board.comment(card, text: "The organisers moved us to stand 16.", by: .you)
        NoteHistory.willChange(note, to: "# Booth plan\n\nThe booth is stand 16.", always: true)
        note.text = "# Booth plan\n\nThe booth is stand 16."
        note.updatedAt = Date()
        controller.commitments.setStatus(todo.commitment, "done")
        board.delete(leaving)
        let fresh = board.create(title: "Order the banner", binderID: binder.id, column: .ready, by: .you)
        store.save()

        // Second reads, by the same child: each must show the change.
        let again = object(await child.call("get_task", ["id": card.id.uuidString]))
        check(again["title"] as? String == "Book the Ignite booth by Friday", "get_task after the app renamed the card: \(again["title"] as? String ?? "nothing")")
        check(again["column"] as? String == "backlog", "its column after the app moved it: \(again["column"] as? String ?? "nothing")")
        check((again["details"] as? String)?.contains("Stand 16") == true, "its details: \(again["details"] as? String ?? "nothing")")
        check((again["timeline"] as? [[String: Any]])?.contains { ($0["text"] as? String)?.contains("stand 16") == true } == true,
              "and its timeline has the app's comment")
        let listed = objects(await child.call("list_tasks", [:]))
        check(listed.first { $0["id"] as? String == card.id.uuidString }?["title"] as? String == "Book the Ignite booth by Friday",
              "list_tasks has the new title")
        check(!listed.contains { $0["id"] as? String == leaving.id.uuidString }, "and not the card the app deleted")
        check(listed.contains { $0["id"] as? String == fresh.id.uuidString }, "and the card the app made")
        let noteAgain = object(await child.call("get_note", ["id": note.id.uuidString]))
        check((noteAgain["text"] as? String)?.contains("stand 16") == true, "get_note has the app's edit: \((noteAgain["text"] as? String ?? "").suffix(24))")
        let todosAgain = objects(await child.call("list_todos", ["status": "all"]))
        check(todosAgain.first { $0["id"] as? String == todo.commitment.id.uuidString }?["status"] as? String == "done",
              "list_todos has the to-do ticked")

        // A change the child itself handed the app (through the inbox) reads back too.
        let commented = await child.call("comment_task", ["id": card.id.uuidString, "text": "Booked stand 16."])
        check(commented != nil && card.column == .backlog, "the child comments through the app")
        board.edit(card, title: "Ignite booth: booked", by: .you)
        store.save()
        let third = object(await child.call("get_task", ["id": card.id.uuidString]))
        check(third["title"] as? String == "Ignite booth: booked"
              && (third["timeline"] as? [[String: Any]])?.contains { $0["text"] as? String == "Booked stand 16." } == true,
              "and a read after that has both its comment and the app's newer title")

        // A run Binders woke for one card (the board's tools, that card only) reads it fresh too.
        if let run = MCPChild(controller: controller, environment: ["BINDERS_AGENT": "Claude Code · booth", "BINDERS_TOOLS": "board",
                                                                     "BINDERS_CARD": card.id.uuidString]), await run.initialize() {
            let before = objects(await run.call("list_tasks", [:]))
            board.edit(card, title: "Ignite booth: stand 16, booked", by: .you)
            try? board.move(card, to: .ready, by: .you)
            store.save()
            let after = objects(await run.call("list_tasks", [:]))
            let read = object(await run.call("get_task", ["id": card.id.uuidString]))
            check(before.first?["title"] as? String == "Ignite booth: booked" && after.first?["title"] as? String == "Ignite booth: stand 16, booked"
                  && read["column"] as? String == "ready", "a woken run reads its card as the app changed it: \(after.first?["title"] as? String ?? "nothing")")
            run.stop()
        } else {
            check(false, "a woken run's Binders --mcp answers")
        }

        print(failures == 0 ? "MCP_FRESH_OK" : "MCP_FRESH_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

/// A `Binders --mcp` of its own on the test's folder, as an agent's host starts it: requests in on standard input,
/// answers out on standard output. The writes it hands the app through the inbox are done by the test, which plays the
/// app, while it waits for an answer.
@MainActor
final class MCPChild {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let heard = MCPChildOutput()
    private let controller: DictationController
    private var next = 1

    /// Started with `environment` on top of this test's own (BINDERS_AGENT, BINDERS_TOOLS, BINDERS_CARD, as an agent's
    /// MCP entry or a woken run sets them). Nil if it can't start.
    init?(controller: DictationController, environment extra: [String: String] = [:]) {
        guard let executable = Bundle.main.executableURL else { return nil }
        self.controller = controller
        process.executableURL = executable
        process.arguments = ["--mcp", "-notesShowMarkdown", "NO"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["BINDERS_AGENT", "BINDERS_TOOLS", "BINDERS_CARD"] { environment[key] = nil }
        environment.merge(extra) { _, new in new }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let heard = heard
        output.fileHandleForReading.readabilityHandler = { handle in heard.append(handle.availableData) }
        // A child that has gone doesn't take the test with it.
        signal(SIGPIPE, SIG_IGN)
        do { try process.run() } catch { return nil }
    }

    /// The handshake, as Claude Code makes it.
    func initialize() async -> Bool {
        let id = send("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                     "clientInfo": ["name": "claude-code", "title": "Claude Code", "version": "1"]])
        return await wait(for: id) != nil
    }

    /// A tool's text, or nil when the child didn't answer within 30 seconds. A tool that failed answers with why.
    func call(_ tool: String, _ arguments: [String: Any]) async -> String? {
        await wait(for: send("tools/call", ["name": tool, "arguments": arguments]))?.text
    }

    /// The same, with whether the tool said it failed.
    func result(_ tool: String, _ arguments: [String: Any]) async -> (ok: Bool, text: String)? {
        guard let answer = await wait(for: send("tools/call", ["name": tool, "arguments": arguments])) else { return nil }
        return (!answer.isError, answer.text)
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func send(_ method: String, _ params: [String: Any]) -> Int {
        let id = next
        next += 1
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        if let data = try? JSONSerialization.data(withJSONObject: message) {
            try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
        }
        return id
    }

    /// Waits for the answer to `id`, doing what the child hands the app through the inbox meanwhile.
    private func wait(for id: Int) async -> (text: String, isError: Bool)? {
        for _ in 0..<300 {
            for line in heard.lines() {
                guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      message["id"] as? Int == id else { continue }
                guard let result = message["result"] as? [String: Any] else { return ("", true) }
                let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                return (text, result["isError"] as? Bool == true)
            }
            let waiting = (try? FileManager.default.contentsOfDirectory(atPath: InboxCommands.directory.path)) ?? []
            for file in waiting where file.hasSuffix(".request.json") {
                await InboxCommands.apply(named: String(file.dropLast(".request.json".count)), controller: controller)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}

/// What the child wrote to its standard output, gathered on whatever queue it arrives on.
private final class MCPChildOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    /// Whole lines so far.
    func lines() -> [String] {
        let text = lock.withLock { String(decoding: data, as: UTF8.self) }
        return text.components(separatedBy: "\n").dropLast().map { $0 }
    }
}
