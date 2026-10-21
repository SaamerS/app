import Foundation

/// Which running copies of Binders count as the app. The MCP server (`Binders --mcp`, started by Claude Code, Claude
/// Desktop and the like), self-tests and the decision model's folder check (`Binders --check-decision-folder`, which reads
/// a model's tokenizer and chat template outside the app) are the same executable run with a flag; they must not keep the
/// app from starting.
public enum AppInstances {
    /// True for a copy of the app proper; false for MCP servers, self-test runs and decision-folder checks.
    public static func isApp(arguments: [String]) -> Bool {
        !arguments.dropFirst().contains { $0 == "--mcp" || $0 == "--check-decision-folder" || $0.hasPrefix("--selftest") }
    }

    /// The arguments in a kernel `KERN_PROCARGS2` buffer: argc as a 32-bit integer, the executable path, NUL padding,
    /// then argc NUL-terminated strings (argv[0] first), then the environment. Nil when the buffer isn't that shape.
    public static func arguments(fromProcArgs buffer: [UInt8]) -> [String]? {
        let countSize = MemoryLayout<Int32>.size
        guard buffer.count > countSize else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        var index = countSize
        while index < buffer.count, buffer[index] != 0 { index += 1 }   // the executable path
        while index < buffer.count, buffer[index] == 0 { index += 1 }   // padding
        var arguments: [String] = []
        while arguments.count < Int(argc), index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == Int(argc) ? arguments : nil
    }
}
