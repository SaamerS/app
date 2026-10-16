import CryptoKit
import Foundation

/// One conversation the iPhone heard during the day, as it sends it to the Mac: text only, transcribed and labelled with
/// speakers on the phone. The audio never leaves the phone.
///
/// Segment times are seconds since `started` on the wall clock, quiet spells included, so "[12:30]" in a transcript is
/// twelve and a half minutes into the conversation.
public struct ConversationPayload: Codable, Equatable, Sendable {
    public var id: UUID
    public var started: Date
    public var ended: Date
    public var segments: [TranscriptSegment]
    /// Speaker label → the name to show: "Speaker 1" → "You".
    public var speakers: [String: String]
    /// The device that heard it, e.g. "iPhone".
    public var device: String
    /// The speech engine that wrote the transcript, e.g. "parakeet-v2".
    public var engine: String

    public init(id: UUID = UUID(), started: Date, ended: Date, segments: [TranscriptSegment], speakers: [String: String] = [:],
                device: String, engine: String) {
        self.id = id
        self.started = started
        self.ended = ended
        self.segments = segments
        self.speakers = speakers
        self.device = device
        self.engine = engine
    }

    /// The link method that carries one, and the feature a Mac advertises in `binders/hello` when it takes them.
    public static let method = "binders/conversation"
    public static let feature = "conversation"

    public var duration: TimeInterval { max(0, ended.timeIntervalSince(started)) }
    public var wordCount: Int { segments.reduce(0) { $0 + TextNorm.words($1.text).count } }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

    public static func decode(_ data: Data) throws -> ConversationPayload { try decoder.decode(ConversationPayload.self, from: data) }

    /// As JSON-RPC params.
    public func jsonObject() throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: encoded()) as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
        return object
    }

    public init(jsonObject: [String: Any]) throws {
        self = try Self.decode(JSONSerialization.data(withJSONObject: jsonObject))
    }

    /// The payload in parts that each fit in a link message, split by time. A 90-minute conversation is a couple of hundred
    /// kilobytes, so this is almost always the payload itself. Each part has an id derived from this one's, so sending a
    /// part again is still recognised as the same part.
    public func parts(maxBytes: Int = Link.maximumMessageSize - 64 * 1024) -> [ConversationPayload] {
        let size = (try? encoded().count) ?? 0
        guard size > maxBytes, segments.count > 1 else { return [self] }
        let count = Int((Double(size) / Double(maxBytes)).rounded(.up))
        let sorted = segments.sorted { $0.start < $1.start }
        let perPart = Int((Double(sorted.count) / Double(count)).rounded(.up))
        var parts: [ConversationPayload] = []
        var index = 0
        while index < sorted.count {
            let slice = Array(sorted[index..<min(sorted.count, index + perPart)])
            let offset = index == 0 ? 0 : slice[0].start
            let partStart = started.addingTimeInterval(offset)
            let partEnd = index + perPart >= sorted.count ? ended : started.addingTimeInterval(slice.last!.end)
            let rebased = slice.map { segment -> TranscriptSegment in
                var copy = segment
                copy.start -= offset
                copy.end -= offset
                return copy
            }
            parts.append(ConversationPayload(id: Self.partID(id, parts.count), started: partStart, ended: partEnd, segments: rebased,
                                             speakers: speakers, device: device, engine: engine))
            index += perPart
        }
        // Still too big (one enormous segment): halve again.
        return parts.flatMap { part in
            ((try? part.encoded().count) ?? 0) > maxBytes && part.segments.count > 1 && part.segments.count < segments.count
                ? part.parts(maxBytes: maxBytes) : [part]
        }
    }

    static func partID(_ id: UUID, _ index: Int) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(id.uuidString)#\(index)".utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// The Mac's side of a conversation: when it's too slight to keep, and the prompts for its notes and its binder.
public enum ConversationPrompts {
    /// Fewer words than this aren't worth a model's time: a conversation this short is kept as trivial straight away.
    public static let minimumWords = 40

    /// A conversation's notes, from a transcript the iPhone made during the day. The first line is TRIVIAL when there's
    /// nothing worth keeping.
    public static func summarySystemPrompt() -> String {
        """
        You write short notes on a conversation the user's iPhone heard during their day, from its transcript. "You" is the user.
        The conversation may be informal, partial or only one side of a phone call, and speech recognition can mishear words.

        If there is nothing worth keeping (small talk, a passing exchange, ordering food, media playing such as TV, radio, a podcast or music, or speech too fragmentary to follow), reply with exactly one line and nothing else:
        TRIVIAL

        Otherwise output Markdown in exactly this shape:
        - First line: "# " and a short, specific title for the conversation (at most 8 words).
        - Then these sections, leaving out any section that would be empty:
        \(MeetingTemplate.conversation.sections)

        Rules:
        - Use only what is in the transcript. Never invent facts, names, numbers, dates or commitments.
        - Promises only when someone clearly said they would do something. A promise the user made is owned by You; one made to the user is owned by the person who made it.
        - Refer to people by name when known, otherwise by their speaker label.
        - Be concise: short bullets, no filler, no preamble.
        - Write in the language the conversation was held in.

        After the notes, if the conversation makes clear who a generic label such as "Speaker 1" is, add one final line:
        SPEAKERS: Speaker 1=Name; Speaker 2=Name
        Leave that line out when you are not sure.
        """
    }

    /// `partNotes` are raw notes on each part of a long conversation, as for a long meeting.
    public static func summaryUserPrompt(date: String, duration: TimeInterval, transcript: String, partNotes: [String] = []) -> String {
        var parts = ["Heard on the iPhone: \(date), about \(max(1, Int((duration / 60).rounded()))) min."]
        if !partNotes.isEmpty {
            let notes = partNotes.enumerated().map { "### Part \($0.offset + 1)\n\($0.element)" }.joined(separator: "\n\n")
            parts.append("Raw notes taken on each part, a checklist so nothing is missed (the transcript is the source of truth):\n<part_notes>\n\(notes)\n</part_notes>")
        }
        parts.append("Transcript:\n<transcript>\n\(transcript)\n</transcript>")
        return parts.joined(separator: "\n\n")
    }

    /// True when the model said there's nothing worth keeping.
    public static func isTrivial(_ output: String) -> Bool {
        let first = OutputGuard.sanitize(output).components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return first.trimmingCharacters(in: CharacterSet(charactersIn: "*_#>`.:! ").union(.whitespaces)).uppercased() == "TRIVIAL"
    }

    // MARK: Routing

    /// A binder the router can pick, with a few titles of what's in it so the model can tell what it's for.
    public struct BinderHint: Equatable, Sendable {
        public var name: String
        public var titles: [String]

        public init(name: String, titles: [String]) {
            self.name = name
            self.titles = titles
        }
    }

    public static func routingSystemPrompt() -> String {
        """
        You file a conversation into one of the user's binders. Each binder is a project or an area of their life; you see its name and the titles of a few things already in it.
        Pick the one binder the conversation clearly belongs to. When none clearly fits, or it's a mix, say none.
        Reply with exactly two lines and nothing else:
        BINDER: <the binder's name exactly as given, or none>
        REASON: <a few words on why>
        """
    }

    public static func routingUserPrompt(binders: [BinderHint], title: String, summary: String) -> String {
        let list = binders.map { binder in
            let titles = binder.titles.prefix(6).map { "  - \($0)" }.joined(separator: "\n")
            return "- \(binder.name)" + (titles.isEmpty ? "" : "\n" + titles)
        }.joined(separator: "\n")
        return """
        Binders:
        \(list)

        The conversation: \(title)
        \(summary)
        """
    }

    /// The binder the model picked, spelled as in `names`, and its reason; nil for none or an answer that names no binder.
    public static func parseRouting(_ output: String, names: [String]) -> (binder: String?, reason: String?) {
        var picked: String?
        var reason: String?
        for line in OutputGuard.sanitize(output).components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "*_` ").union(.whitespaces))
            if let range = trimmed.range(of: "BINDER:", options: [.caseInsensitive, .anchored]) {
                picked = String(trimmed[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'*_`. ").union(.whitespaces))
            } else if let range = trimmed.range(of: "REASON:", options: [.caseInsensitive, .anchored]) {
                let text = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                reason = text.isEmpty ? nil : String(text.prefix(200))
            }
        }
        guard let picked, picked.lowercased() != "none" else { return (nil, reason) }
        let match = names.first { $0.compare(picked, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return (match, reason)
    }
}

/// A Binders file: conversations handed from the iPhone to the Mac without the network, by AirDrop, Files or Mail. Opening
/// one on the Mac keeps what's in it, once: a conversation that also arrives over the link isn't kept twice.
public struct BindersTransfer: Codable, Equatable, Sendable {
    public static let fileExtension = "binders"
    public static let typeIdentifier = "io.binders.transfer"
    public static let currentVersion = 1

    /// Always "binders", so any other JSON file isn't taken for one.
    public var format: String
    public var version: Int
    public var conversations: [ConversationPayload]

    public init(conversations: [ConversationPayload]) {
        format = "binders"
        version = Self.currentVersion
        self.conversations = conversations
    }

    public enum Failure: LocalizedError, Equatable {
        case notBinders, newer(Int)

        public var errorDescription: String? {
            switch self {
            case .notBinders: "This isn't a Binders file."
            case .newer(let version): "This file comes from a newer Binders (format \(version)). Update Binders on this Mac to open it."
            }
        }
    }

    public func encoded() throws -> Data { try ConversationPayload.encoder.encode(self) }

    public static func decode(_ data: Data) throws -> BindersTransfer {
        guard let transfer = try? ConversationPayload.decoder.decode(BindersTransfer.self, from: data), transfer.format == "binders" else {
            throw Failure.notBinders
        }
        guard transfer.version <= currentVersion else { throw Failure.newer(transfer.version) }
        return transfer
    }

    /// "Conversation 2026-10-15 10.42.binders", or "3 conversations 2026-10-15.binders" for several.
    public static func fileName(for conversations: [ConversationPayload], timeZone: TimeZone = .current) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = timeZone
        time.dateFormat = "HH.mm"
        let first = conversations.map(\.started).min() ?? Date()
        let name = conversations.count == 1 ? "Capture \(day.string(from: first)) \(time.string(from: first))"
            : "\(conversations.count) captures \(day.string(from: first))"
        return "\(name).\(fileExtension)"
    }
}
