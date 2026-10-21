import Foundation
import Observation
import SwiftData
import SwiftUI
import BindersKit

/// Reads what a Claude Code run Binders started says it's doing, from what Claude Code writes in its folder anyway
/// (~/.claude, or the one in BINDERS_AGENT_HOME for the self-tests): the run's own task list, `tasks/<session>/`, and
/// nothing else there. No other session's files are read, nor the records of the sessions running. For a Codex, OpenCode
/// or GitHub Copilot CLI run, only Binders' own log of that run, at most its last 256 KB, while its record says it's going:
/// no tool's own files and no other session. In each Binders
/// process (the app, and each `Binders --mcp` an MCP host keeps open), a run's files are read at most once per
/// `AgentDoing.interval`, whoever asks in it (the board, the digest, the iPhone, MCP), and only the line is kept, in
/// memory. Run against a throwaway data folder, it reads a throwaway agent home or nothing, never yours.
final class AgentDoingReader: @unchecked Sendable {
    static let shared = AgentDoingReader()

    private let condition = NSCondition()
    /// Each run's line, by session, and when its files were read.
    private var lines: [String: (line: String?, at: Date)] = [:]
    /// Runs whose files are being read now: a caller meanwhile waits for what that read finds, rather than reading too.
    private var reading: Set<String> = []
    private var count = 0
    private var listed: Set<String> = []

    /// For the self-tests: how many times a run's files have been read.
    var reads: Int { condition.withLock { count } }

    /// For the self-tests: each folder read, as a path in Claude Code's folder ("tasks/<session>"). Noted only with a
    /// throwaway data folder.
    var folders: Set<String> { condition.withLock { listed } }

    /// For the self-tests: every line forgotten, so the next ask reads the files.
    func forget() { condition.withLock { lines = [:] } }

    /// Claude Code's folder in the agent home. Nil in a throwaway data folder without a throwaway agent home.
    static var claudeFolder: URL? { claudeFolder(environment: ProcessInfo.processInfo.environment, throwaway: AppPaths.isDemo) }

    /// The same, for an environment: BINDERS_AGENT_HOME's when it names one, else the home folder's, except with a
    /// throwaway data folder (`throwaway`), whose runs are never read from your own.
    static func claudeFolder(environment: [String: String], throwaway: Bool) -> URL? {
        if let home = environment["BINDERS_AGENT_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
        }
        guard !throwaway else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    /// The run's line: read from its task list when that hasn't been read in the last `AgentDoing.interval`, else as last
    /// read.
    func line(session: String, now: Date = Date()) -> String? {
        let session = session.lowercased()
        condition.lock()
        while reading.contains(session) { condition.wait() }
        if let entry = lines[session], now.timeIntervalSince(entry.at) < AgentDoing.interval {
            condition.unlock()
            return entry.line
        }
        reading.insert(session)
        condition.unlock()
        let line = read(session: session)
        condition.withLock {
            reading.remove(session)
            count += 1
            // A line is never given again once it's due to be read again: it goes.
            lines = lines.filter { now.timeIntervalSince($0.value.at) < AgentDoing.interval }
            lines[session] = (line, now)
            condition.broadcast()
        }
        return line
    }

    /// A CLI run's line: from its own log in Binders' logs folder, read when it hasn't been in the last
    /// `AgentDoing.interval`, else as last read.
    func cliLine(log: String, tool: CLIAgent, now: Date = Date()) -> String? {
        let key = "log:" + log
        condition.lock()
        while reading.contains(key) { condition.wait() }
        if let entry = lines[key], now.timeIntervalSince(entry.at) < AgentDoing.interval {
            condition.unlock()
            return entry.line
        }
        reading.insert(key)
        condition.unlock()
        let line = Self.readCLI(log: log, tool: tool)
        condition.withLock {
            reading.remove(key)
            count += 1
            lines = lines.filter { now.timeIntervalSince($0.value.at) < AgentDoing.interval }
            lines[key] = (line, now)
            condition.broadcast()
        }
        return line
    }

    /// The plan in the run's own log while its record says the run is going: a regular file, never a link, and at most
    /// its last 256 KB, where its latest plan is.
    private static func readCLI(log: String, tool: CLIAgent) -> String? {
        guard log.hasSuffix(".jsonl") else { return nil }
        let stem = String(log.dropLast(".jsonl".count))
        guard FileManager.default.fileExists(atPath: stem + ".run.json"),
              let values = try? URL(fileURLWithPath: log).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let tail = CLIRuns.tail(URL(fileURLWithPath: log), bytes: 256 * 1024) else { return nil }
        return AgentDoing.cliLine(tail, tool: tool)
    }

    /// The task in progress on the run's own task list, and nothing else of Claude Code's.
    private func read(session: String) -> String? {
        guard let folder = Self.claudeFolder, UUID(uuidString: session) != nil else { return nil }
        let tasks = files(in: "tasks/" + session, of: folder, limit: 200).compactMap(AgentDoing.ClaudeTask.init(json:))
        return AgentDoing.claudeLine(tasks: tasks)
    }

    /// The JSON files in a folder of Claude Code's, leaving out hidden ones and links: up to `limit` of them, of 64 KB at
    /// most each.
    private func files(in path: String, of claudeFolder: URL, limit: Int) -> [Data] {
        if AppPaths.isDemo { condition.withLock { _ = listed.insert(path) } }
        let folder = claudeFolder.appendingPathComponent(path, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(limit).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? .max) <= 64 * 1024 else { return nil }
            return try? Data(contentsOf: url)
        }
    }
}

extension AgentDoing {
    /// What the runs Binders started say they're doing, by card: each of these cards that's in progress and held by an
    /// agent, with the line of the run its latest wake receipt names (`runReceipt`: a Claude Code session, or a CLI tool's
    /// run and its log among the card's links), unless the line only says the card's title. Their timelines are read in
    /// one fetch, on the context's own thread.
    static func lines(for cards: [TaskCard], on context: ModelContext, now: Date = Date()) -> [UUID: String] {
        let held = cards.filter { $0.column == .inProgress && $0.assigneeIsAgent && $0.assignee != nil && BoardRules.isClaimed($0.state, at: now) }
        guard !held.isEmpty else { return [:] }
        let ids = held.map(\.id)
        // Only the lines that say which run it is, or that end it or wake a newer one.
        let kinds = runKinds
        let events = (try? context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { ids.contains($0.taskID) && kinds.contains($0.kindRaw) },
                                                                    sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let timelines = Dictionary(grouping: events, by: \.taskID)
        var lines: [UUID: String] = [:]
        for card in held {
            guard let holder = card.assignee else { continue }
            let timeline = (timelines[card.id] ?? []).map {
                Entry(kind: $0.kindRaw, author: $0.author, byAgent: $0.authorIsAgent, text: $0.text, from: $0.fromColumn, to: $0.toColumn)
            }
            guard let receipt = runReceipt(timeline: timeline, holder: holder, column: card.column) else { continue }
            let said: String?
            if let tool = cliRun(inReceipt: receipt.text) {
                guard let log = runLog(links: card.links, card: card.id, logs: AgentPlaces.logs.path) else { continue }
                said = AgentDoingReader.shared.cliLine(log: log, tool: tool, now: now)
            } else {
                // Claude Code's folder: none with a throwaway data folder and no throwaway agent home.
                guard AgentDoingReader.claudeFolder != nil, let session = session(inReceipt: receipt.text) else { continue }
                said = AgentDoingReader.shared.line(session: session, now: now)
            }
            guard let line = line(said, for: card.title) else { continue }
            lines[card.id] = line
        }
        return lines
    }
}

/// What the runs Binders started say they're doing, for the board's cards, a card's page and the work-streams pages: read
/// when one of them appears, every `AgentDoing.interval` while one shows and when the boards change, off the main thread.
/// Kept in memory only, and let go when nothing shows it.
@MainActor
@Observable
final class AgentDoingFeed {
    static let shared = AgentDoingFeed()

    /// The line of each card in progress in a run Binders started, by card.
    private(set) var lines: [UUID: String] = [:]

    /// For self-tests: updates finished.
    @ObservationIgnored private(set) var updates = 0
    @ObservationIgnored private var showing = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var changes: SaveWatcher?
    @ObservationIgnored private var updating = false
    @ObservationIgnored private var stale = false
    /// For the drawings: lines shown in place of what runs say, and no run read while they are.
    @ObservationIgnored private var pinned: [UUID: String]?

    /// For the drawings, in a throwaway data folder only: shows these lines, by card, and stops reading runs while pinned.
    func pin(_ lines: [UUID: String]) {
        guard AppPaths.isDemo else { return }
        pinned = lines
        self.lines = lines
    }

    /// A page that shows the lines appeared.
    func show() {
        showing += 1
        if timer == nil {
            // Just after a run's line is due again, so a tick never finds it a moment short and waits another round.
            timer = Timer.scheduledTimer(withTimeInterval: AgentDoing.interval + 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            changes = SaveWatcher(kinds: ["TaskCard", "TaskEvent"]) { [weak self] in self?.refresh() }
        }
        refresh()
    }

    /// One went away. With none left, nothing is read and the lines go.
    func hide() {
        showing = max(0, showing - 1)
        guard showing == 0, pinned == nil else { return }
        timer?.invalidate()
        timer = nil
        changes = nil
        if !lines.isEmpty { lines = [:] }
    }

    /// Reads again: the boards, and each run's files when they're due.
    func refresh() {
        guard showing > 0 else { return }
        guard !updating else { return stale = true }
        Task { await update() }
    }

    /// Reads the lines now, while a page shows them, and tells the digest's pages when they changed. One at a time, so the
    /// lines shown are the latest read.
    func update() async {
        guard showing > 0, pinned == nil else { return }
        while updating { try? await Task.sleep(for: .milliseconds(20)) }
        updating = true
        let container = Store.shared.container
        let fresh = await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let inProgress = BoardColumn.inProgress.rawValue
            let cards = (try? context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.columnRaw == inProgress && $0.assigneeIsAgent }))) ?? []
            return AgentDoing.lines(for: cards, on: context)
        }.value
        updating = false
        updates += 1
        if showing > 0, fresh != lines {
            lines = fresh
            // The digest on Home, Today and Work says it too.
            WorkStreamsFeed.shared.changed()
        }
        if stale {
            stale = false
            refresh()
        }
    }
}

extension View {
    /// Keeps what agents say they're doing up to date while this shows: the board, a card, the work-streams pages.
    func followingAgentDoing() -> some View {
        onAppear { AgentDoingFeed.shared.show() }
            .onDisappear { AgentDoingFeed.shared.hide() }
    }
}
