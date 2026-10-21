import Foundation
import BindersKit

/// The card router's record of what it decided, for tuning it: router-log.jsonl in the data folder, on this Mac only. MCP
/// never reads it, team sync never touches it, and it holds no words and no names: binders and agents by id, with
/// probabilities, times and what was done (RouterLogEntry). One line a decision, then a line for each thing you did
/// about it later: moved the card, gave it to an agent, stopped one, or took the moment back. Lines older than 90 days go,
/// and past 5,000 lines or 2 MB the newest 4,000 stay. Written on a serial queue of its own, off the main thread, in order.
final class RouterLogFile: @unchecked Sendable {
    static let shared = RouterLogFile()

    let url: URL
    private let queue = DispatchQueue(label: "io.binders.router-log")
    /// Confined to `queue`: the recent decisions by what they made (card, to-do or moment), and the file's lines, bytes
    /// and oldest line, read lazily.
    private var index: [String: (id: UUID, at: Date)]?
    private var order: [(id: UUID, keys: [String])] = []
    private var lines = 0
    private var bytes = 0
    private var oldest: Date?
    /// Decisions an outcome is matched to: the last 1,000, from the last 30 days.
    static let indexed = 1_000
    static let outcomeWithin: TimeInterval = 30 * 86_400

    init(url: URL = AppPaths.support.appendingPathComponent("router-log.jsonl")) {
        self.url = url
        queue.async { self.trimIfDue(now: Date(), force: true) }
    }

    // MARK: Writing

    /// One decision.
    func write(_ entry: RouterLogEntry) {
        queue.async { self.append(entry) }
    }

    /// What you did about a decision later: "moved" (to a binder), "gave" (to an agent), "stopped" or "undone", found by
    /// the card, the to-do or the moment it made. Nothing when no decision made it in the last 30 days.
    func outcome(_ event: String, card: UUID? = nil, todo: String? = nil, moment: UUID? = nil, to: UUID? = nil) {
        let at = Date()
        queue.async {
            self.loadIndex()
            let keys = [card.map { "card:\($0.uuidString)" }, todo.map { "todo:\($0)" }, moment.map { "moment:\($0.uuidString)" }].compactMap { $0 }
            guard let found = keys.lazy.compactMap({ self.index?[$0] }).first, at.timeIntervalSince(found.at) <= Self.outcomeWithin else { return }
            self.append(RouterLogEntry(id: found.id, at: at, card: card, todo: todo, moment: moment, event: event, to: to))
        }
    }

    /// Settings' Clear… and Delete all history.
    func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: self.url)
            self.index = [:]
            self.order = []
            self.lines = 0
            self.bytes = 0
            self.oldest = nil
        }
    }

    /// Waits for the writes so far: for the self-tests and the count Settings shows.
    func flush() { queue.sync {} }

    /// How many decisions it holds.
    func decisions() -> Int {
        queue.sync {
            (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").filter { line in
                RouterLogEntry.decode(String(line)).map { $0.event == nil } ?? false
            }.count ?? 0
        }
    }

    /// The file's lines, for the self-tests.
    func entries() -> [RouterLogEntry] {
        queue.sync { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { RouterLogEntry.decode(String($0)) } }
    }

    // MARK: On the queue

    private func append(_ entry: RouterLogEntry) {
        guard let line = entry.line() else { return }
        loadIndex()
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        lines += 1
        bytes += data.count
        if oldest == nil { oldest = entry.at }
        if entry.event == nil { remember(entry) }
        trimIfDue(now: entry.at, force: false)
    }

    private func remember(_ entry: RouterLogEntry) {
        let keys = [entry.card.map { "card:\($0.uuidString)" }, entry.todo.map { "todo:\($0)" }, entry.moment.map { "moment:\($0.uuidString)" }]
            .compactMap { $0 }
        guard !keys.isEmpty else { return }
        for key in keys { index?[key] = (entry.id, entry.at) }
        order.append((entry.id, keys))
        while order.count > Self.indexed {
            let (id, gone) = order.removeFirst()
            for key in gone where index?[key]?.id == id { index?[key] = nil }
        }
    }

    /// The index, the counts and the oldest line, from the file, the first time they're needed.
    private func loadIndex() {
        guard index == nil else { return }
        index = [:]
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let all = text.split(separator: "\n")
        lines = all.count
        bytes = text.utf8.count
        for line in all {
            guard let entry = RouterLogEntry.decode(String(line)) else { continue }
            if oldest == nil { oldest = entry.at }
            if entry.event == nil { remember(entry) }
        }
    }

    /// At launch and on each write: lines older than 90 days go, and past the caps the newest 4,000 stay, rewritten
    /// atomically.
    private func trimIfDue(now: Date, force: Bool) {
        loadIndex()
        let tooOld = oldest.map { now.timeIntervalSince($0) > RouterLog.maxAge } ?? false
        guard force || tooOld || lines > RouterLog.maxLines || bytes > RouterLog.maxBytes else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let all = text.split(separator: "\n").map(String.init)
        let kept = RouterLog.trimmed(all, now: now)
        guard kept.count != all.count else { return }
        let rewritten = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try? Data(rewritten.utf8).write(to: url, options: .atomic)
        index = nil
        order = []
        oldest = nil
        loadIndex()
    }
}
