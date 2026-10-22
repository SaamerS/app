import Foundation
import BindersKit

/// What this Mac keeps for a team database, in `<support>/Team/<server key>/`: the outbox, and its place in the feed
/// (state.json): the last number it applied and the binders it saw then. The password isn't here: it's in the Keychain.
///
/// The outbox (lane DB10) is a file and a journal: outbox.json holds it as it was when last written whole, and
/// outbox-journal-<n>.jsonl one line for each change queued, answered or tried since, appended as it happens, so a change
/// costs what that change weighs rather than what the whole outbox weighs. Every 256 lines (or 4 MB) the outbox is written
/// whole again, off the main thread, and a new journal starts; reading it back replays the journals the file names on top
/// of it. Quitting writes it whole, so an earlier Binders, which reads only outbox.json, finds everything there.
@MainActor
final class TeamDatabaseFiles {
    struct State: Codable, Equatable {
        /// The feed's number this Mac applied up to.
        var acknowledgedSeq: Int64 = 0
        /// The binders it saw when it last caught up, to tell which were shared with it or taken away since.
        var binders: [UUID] = []
    }

    let folder: URL
    private(set) var outbox: TeamOutbox
    private(set) var state: State
    /// The journal appended to now, and what went into it since the outbox was last written whole.
    private var journal = 0
    private var lines = 0
    private var bytes = 0
    /// Writes the outbox whole, one after another, off the main thread.
    private let writer = DispatchQueue(label: "io.binders.mac.team-outbox", qos: .utility)

    /// Lines, or bytes, after which the outbox is written whole again.
    static let linesPerJournal = 256
    static let bytesPerJournal = 4 << 20

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let read = Self.read(folder)
        outbox = read.outbox
        journal = read.journal
        state = (try? Data(contentsOf: folder.appendingPathComponent("state.json"))).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
            ?? State()
        // What the journals said, written whole, so the next start reads one file.
        if read.replayed > 0 { writeWhole() }
    }

    /// The folder for a server's login on this Mac.
    static func folder(for server: TeamDatabaseServer) -> URL {
        AppPaths.support.appendingPathComponent("Team", isDirectory: true).appendingPathComponent(server.key, isDirectory: true)
    }

    // MARK: Reading

    nonisolated private static func outboxURL(_ folder: URL) -> URL { folder.appendingPathComponent("outbox.json") }

    nonisolated private static func journalURL(_ folder: URL, _ number: Int) -> URL { folder.appendingPathComponent("outbox-journal-\(number).jsonl") }

    /// The journals in the folder, by number.
    nonisolated private static func journals(in folder: URL) -> [(number: Int, url: URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> (Int, URL)? in
            guard name.hasPrefix("outbox-journal-"), name.hasSuffix(".jsonl"),
                  let number = Int(name.dropFirst("outbox-journal-".count).dropLast(".jsonl".count)) else { return nil }
            return (number, folder.appendingPathComponent(name))
        }.sorted { $0.0 < $1.0 }
    }

    /// The outbox as it is on disk now: the file, then the journals that go on from it, as a Mac that crashed this
    /// moment would read it. An unreadable file is kept aside, never overwritten, so nothing in it is lost. Returns the
    /// journal to append to next and how many lines were replayed.
    nonisolated static func read(_ folder: URL, keepingAside: Bool = true) -> (outbox: TeamOutbox, journal: Int, replayed: Int) {
        var outbox = TeamOutbox()
        var from = 0
        let url = outboxURL(folder)
        if let data = try? Data(contentsOf: url) {
            if let read = try? TeamOutbox(data: data) {
                outbox = read
                from = TeamOutbox.journal(after: data)
            } else if keepingAside {
                let aside = folder.appendingPathComponent("outbox-unread-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: aside)
                Log.app.error("The team database's outbox couldn't be read; it was kept aside")
            }
        }
        var replayed = 0
        var last = from
        for (number, url) in journals(in: folder) where number >= from {
            guard let data = try? Data(contentsOf: url) else { continue }
            let (entries, unread) = TeamOutbox.entries(in: data)
            if unread > 0 { Log.app.error("The team database's outbox journal had \(unread) line(s) it couldn't read") }
            for entry in entries { outbox.apply(entry) }
            replayed += entries.count + unread
            last = number
        }
        return (outbox, last, replayed)
    }

    // MARK: The outbox

    @discardableResult
    func add(_ call: TeamCall, sendBy: Date? = nil) -> Bool {
        guard outbox.add(call, sendBy: sendBy) else { return false }
        if let item = outbox.items.last(where: { $0.id == call.operation }) { record(.add(item)) }
        return true
    }

    @discardableResult
    func settle(_ operation: UUID) -> TeamOutboxItem? {
        let item = outbox.settle(operation)
        if item != nil { record(.settle(operation)) }
        return item
    }

    func attempted(_ operation: UUID, error: String?) {
        guard outbox.items.contains(where: { $0.id == operation }) else { return }
        outbox.attempted(operation, error: error)
        record(.attempted(operation, error: error))
    }

    /// One line onto the journal, now: small, so it costs little, and a crash right after loses nothing.
    private func record(_ entry: TeamOutboxEntry) {
        do {
            let line = try TeamOutbox.line(entry)
            try Self.append(line, to: Self.journalURL(folder, journal))
            lines += 1
            bytes += line.count
            TeamPerf.shared.count { $0.outboxAppends += 1; $0.outboxAppendBytes += line.count }
        } catch {
            Log.app.error("The team database's outbox couldn't be saved: \(error.localizedDescription, privacy: .public)")
            // Written whole instead, so the change is on disk all the same.
            writeWhole()
            return
        }
        if lines >= Self.linesPerJournal || bytes >= Self.bytesPerJournal { writeWholeSoon() }
    }

    /// Appends to a file, made when it isn't there (open, write, close: a few microseconds, where FileHandle took
    /// milliseconds).
    nonisolated private static func append(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { buffer in write(descriptor, buffer.baseAddress, buffer.count) }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The outbox written whole off the main thread, and a new journal started: the file says it goes on from that one.
    private func writeWholeSoon() {
        let snapshot = outbox
        journal += 1
        lines = 0
        bytes = 0
        let folder = folder, next = journal
        writer.async { Self.writeWhole(snapshot, journal: next, in: folder) }
    }

    /// The outbox written whole now (starting, quitting, stopping), after any write still under way.
    func writeWhole() {
        let snapshot = outbox
        journal += 1
        lines = 0
        bytes = 0
        let folder = folder, next = journal
        writer.sync { Self.writeWhole(snapshot, journal: next, in: folder) }
    }

    /// Whatever the journal holds since the outbox was last written whole goes into the file: for quitting.
    func flush() {
        if lines > 0 { writeWhole() } else { writer.sync {} }
    }

    nonisolated private static func writeWhole(_ outbox: TeamOutbox, journal: Int, in folder: URL) {
        do {
            let data = try outbox.encoded(journal: journal)
            try data.write(to: outboxURL(folder), options: [.atomic])
            TeamPerf.shared.count { $0.outboxSaves += 1; $0.outboxBytes += data.count }
            // The journals before it are in the file now.
            for (number, url) in journals(in: folder) where number < journal { try? FileManager.default.removeItem(at: url) }
        } catch {
            Log.app.error("The team database's outbox couldn't be saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: The feed

    func acknowledge(through seq: Int64, binders: Set<UUID>) {
        let next = State(acknowledgedSeq: max(state.acknowledgedSeq, seq), binders: binders.sorted { $0.uuidString < $1.uuidString })
        guard next != state else { return }
        state = next
        // Written off the main thread, in order (lane DB10): it changes with every update the feed brings.
        let url = folder.appendingPathComponent("state.json")
        writer.async {
            if let data = try? JSONEncoder().encode(next) { try? data.write(to: url, options: [.atomic]) }
        }
    }
}
