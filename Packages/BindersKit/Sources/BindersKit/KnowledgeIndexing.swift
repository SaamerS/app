import CryptoKit
import Foundation

// MARK: - Content hashes

/// The content hash the knowledge index keeps for each document. A document is written again (its passages re-embedded,
/// its people and topics extracted again) only when this hash changes, so it has to stay exactly as it is: a different
/// hash for the same words would index everything again after an update.
public enum KnowledgeContentHash {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// SHA-256 of each part followed by a zero byte, in lowercase hex.
    public static func of(_ parts: [String]) -> String {
        var hasher = SHA256()
        for part in parts {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        var hex: [UInt8] = []
        hex.reserveCapacity(64)
        for byte in hasher.finalize() {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }
}

// MARK: - What a pass reads

/// What one pass of the index does with one kind of item, from the items there now (`live`), the ones the last pass saw
/// (`known`) and the ones saved since (`saved`): it reads the new ones and the saved ones that are still there, and drops
/// the ones that are gone. Nothing else is read.
public struct IndexDelta<ID: Hashable> {
    public var read: Set<ID>
    public var gone: Set<ID>

    public init(live: Set<ID>, known: Set<ID>, saved: Set<ID>) {
        read = live.subtracting(known).union(saved.intersection(live))
        gone = known.subtracting(live)
    }
}

// MARK: - Notes waiting for a digest

/// Notes whose digest isn't for their current words, and which of them are due one: long enough, and left alone long
/// enough, the longest-waiting first. Kept up to date as the index reads notes, so finding them doesn't read every note.
public struct DigestQueue<ID: Hashable> {
    private var waiting: [ID: (edited: Date, words: Int)] = [:]

    public init() {}

    /// How many notes wait, due or not.
    public var count: Int { waiting.count }

    /// A note read again: it waits when its digest isn't for its words (`stale`), and stops waiting otherwise.
    public mutating func update(_ id: ID, stale: Bool, words: Int, edited: Date) {
        waiting[id] = stale ? (edited, words) : nil
    }

    public mutating func remove(_ id: ID) {
        waiting[id] = nil
    }

    /// The notes due a digest now, the one edited longest ago first.
    public func due(at now: Date = Date()) -> [ID] {
        waiting.filter { NoteDigest.isEligible(wordCount: $0.value.words, secondsSinceEdit: now.timeIntervalSince($0.value.edited)) }
            .sorted { $0.value.edited < $1.value.edited }
            .map(\.key)
    }
}
