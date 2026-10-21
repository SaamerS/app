import Darwin
import Foundation
import BindersKit

/// The records the CLI tools' runs leave beside their logs while they go, so a run outlives Binders and still ends
/// properly: written when a run starts, renamed when its end steps begin (which makes them happen once), and deleted when
/// they're done. When Binders opens, it adopts a run that's still going and ends one that stopped while it was closed.
enum CLIRuns {
    /// A run's files, by its stem (the log's path without its extension).
    static func log(_ stem: String) -> URL { URL(fileURLWithPath: stem + ".jsonl") }
    static func errors(_ stem: String) -> URL { URL(fileURLWithPath: stem + ".err.log") }
    static func running(_ stem: String) -> URL { URL(fileURLWithPath: stem + ".run.json") }
    static func ending(_ stem: String) -> URL { URL(fileURLWithPath: stem + ".ending.json") }

    /// A new run's stem in the logs folder: "<card8>-<stamp>", with a number after it when a run of the card already has
    /// that one.
    static func newStem(for card: UUID) -> String {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        let base = AgentPlaces.logs.appendingPathComponent("\(card.uuidString.prefix(8).lowercased())-\(stamp)").path
        var stem = base, number = 2
        while FileManager.default.fileExists(atPath: stem + ".jsonl") || FileManager.default.fileExists(atPath: stem + ".run.json") {
            stem = "\(base)-\(number)"
            number += 1
        }
        return stem
    }

    /// The run's own temp folder: <root>/tmp/<the stem's name>.
    static func temporary(_ stem: String) -> URL {
        AgentPlaces.temporary.appendingPathComponent((stem as NSString).lastPathComponent, isDirectory: true)
    }

    static func write(_ record: CLIRunRecord) {
        guard let data = try? record.encoded() else { return }
        try? AgentPlaces.write(data, to: running(record.stem))
    }

    /// Claims a run's end: true for the one path that renamed its record. Any other path ends here.
    static func claimEnd(_ record: CLIRunRecord) -> Bool {
        (try? FileManager.default.moveItem(at: running(record.stem), to: ending(record.stem))) != nil
    }

    static func endDone(_ record: CLIRunRecord) {
        try? FileManager.default.removeItem(at: ending(record.stem))
        try? FileManager.default.removeItem(at: running(record.stem))
    }

    /// The records in the logs folder: runs still going (or that stopped while Binders was closed), and ends that were
    /// interrupted. `stems` names every record there, read or not: one this build can't read (a later Binders' run, for a
    /// tool this one doesn't know) still has its run, and its temp folder, in use.
    static func saved() -> (running: [CLIRunRecord], ending: [CLIRunRecord], stems: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: AgentPlaces.logs, includingPropertiesForKeys: nil)) ?? []
        func read(_ suffix: String) -> [CLIRunRecord] {
            files.filter { $0.lastPathComponent.hasSuffix(suffix) }.compactMap { (try? Data(contentsOf: $0)).flatMap(CLIRunRecord.decode) }
        }
        var stems: Set<String> = []
        for file in files {
            let name = file.lastPathComponent
            for suffix in [".run.json", ".ending.json"] where name.hasSuffix(suffix) && name.count > suffix.count {
                stems.insert(String(name.dropLast(suffix.count)))
            }
        }
        return (read(".run.json"), read(".ending.json"), stems)
    }

    // MARK: Processes

    /// When the kernel says a process started, in seconds since 1970; nil when there's no such process, or it has
    /// already exited and waits to be reaped.
    static func startTime(of pid: Int32) -> Double? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        // A zombie has ended: its run is over.
        guard info.kp_proc.p_stat != 5 else { return nil }
        let start = info.kp_proc.p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }

    /// Whether the record's process is still the one it started: alive, and started when the record says.
    static func isAlive(_ record: CLIRunRecord) -> Bool {
        guard let start = startTime(of: record.pid) else { return false }
        return abs(start - record.processStart) < 1
    }

    /// Asks a run to stop, as each tool ends a turn cleanly on it: SIGINT, then SIGTERM after 10 seconds if it's still
    /// going. Only the process the record names: a reused pid is never hit.
    static func interrupt(_ record: CLIRunRecord) {
        guard isAlive(record) else { return }
        kill(record.pid, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if isAlive(record) { kill(record.pid, SIGTERM) }
        }
    }

    /// The same for a process Binders started in this session.
    static func interrupt(_ process: Process) {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: Reading a run's output

    /// The run's whole log, read in 64 KB chunks and fed a line at a time; a line longer than 4 MB is skipped. With what its
    /// stderr says, for reasons: its line for the card (`CLIAgentOutput.reason(inErrors:)`), and the last 64 KB of it,
    /// where a tool's way of saying it isn't signed in can take several lines.
    static func read(_ record: CLIRunRecord) -> (result: CLIAgentResult, said: String?, errors: String) {
        var reader = CLIAgentOutputReader(tool: record.tool)
        if let handle = try? FileHandle(forReadingFrom: log(record.stem)) {
            defer { try? handle.close() }
            var pending = Data()
            var skipping = false
            while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<newline]
                    if !skipping, line.count <= CLIAgentOutput.lineLimit { reader.feed(Substring(String(decoding: line, as: UTF8.self))) }
                    skipping = false
                    pending.removeSubrange(pending.startIndex...newline)
                }
                if pending.count > CLIAgentOutput.lineLimit {
                    pending.removeAll()
                    skipping = true
                }
            }
            if !skipping, !pending.isEmpty { reader.feed(Substring(String(decoding: pending, as: UTF8.self))) }
        }
        let stderr = tail(errors(record.stem), bytes: 64 * 1024) ?? ""
        return (reader.result, CLIAgentOutput.reason(inErrors: stderr), stderr)
    }

    /// At most `bytes` from the end of a file, without reading the rest.
    static func tail(_ url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return (try? handle.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
    }
}
