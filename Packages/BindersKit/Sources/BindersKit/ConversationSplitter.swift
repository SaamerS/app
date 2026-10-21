import Foundation

/// Cuts a day of listening into conversations. It hears, stretch by stretch, whether someone was speaking: the first
/// speech after a quiet spell opens a conversation, and it closes once nobody has spoken for `silenceToClose`, or when it
/// reaches `maxLength`, where it's split and the next one carries on. A conversation with less than `minSpeech` of
/// speech in it is dropped: a cough, a "thanks", the radio in the next room.
///
/// Times are seconds on any one clock (the iPhone uses seconds since 1970). Pure and deterministic, so the iPhone and
/// the tests cut a day the same way.
public struct ConversationSplitter: Sendable {
    public struct Settings: Equatable, Sendable {
        public var silenceToClose: TimeInterval
        public var maxLength: TimeInterval
        public var minSpeech: TimeInterval

        public init(silenceToClose: TimeInterval = 180, maxLength: TimeInterval = 90 * 60, minSpeech: TimeInterval = 20) {
            self.silenceToClose = silenceToClose
            self.maxLength = maxLength
            self.minSpeech = minSpeech
        }
    }

    public struct Conversation: Equatable, Sendable {
        /// When the first speech began.
        public var start: TimeInterval
        /// When the last speech ended.
        public var end: TimeInterval
        /// Seconds of speech in it.
        public var speech: TimeInterval

        public init(start: TimeInterval, end: TimeInterval, speech: TimeInterval) {
            self.start = start
            self.end = end
            self.speech = speech
        }
    }

    public enum Event: Equatable, Sendable {
        case opened(at: TimeInterval)
        /// Closed with enough speech in it to keep.
        case closed(Conversation)
        /// Closed with too little speech: let it go.
        case dropped(Conversation)
    }

    public let settings: Settings
    /// The conversation in progress, if any.
    public private(set) var current: Conversation?

    /// How long after the last speech a listening glyph still moves: the gaps between words. Not the quiet of a
    /// conversation that's still open, which lasts until `silenceToClose`.
    public static let speakingGrace: TimeInterval = 1

    /// Someone is speaking at `now`, going by when speech was last heard (nil: not since listening began, or no
    /// conversation is open): what a listening glyph moves with, and holds still without.
    public static func isSpeaking(lastSpeech: Date?, now: Date = Date()) -> Bool {
        guard let lastSpeech else { return false }
        return now.timeIntervalSince(lastSpeech) < speakingGrace
    }

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Whether a conversation opening at `start` continues the one before it (lane Y2): that one was closed by a cut (the
    /// 90-minute split, or listening stopping: a call, Siri, Mute), at `lastCut`, and this opens within the quiet that would
    /// otherwise have closed it, `silenceToClose` after its last speech (`lastEnd`). A close after quiet, or a Wrap Up, is
    /// no cut: pass nil for `lastCut`.
    public static func continues(lastEnd: Date?, lastCut: Date?, start: Date, settings: Settings = Settings()) -> Bool {
        guard let lastEnd, let lastCut, start >= lastCut else { return false }
        return start.timeIntervalSince(lastEnd) < settings.silenceToClose
    }

    /// One stretch of audio, `duration` seconds from `time`: speech or not.
    public mutating func add(speech: Bool, at time: TimeInterval, duration: TimeInterval) -> [Event] {
        var events: [Event] = []
        if let open = current {
            if time - open.start >= settings.maxLength {
                // Long enough: split here, and a stretch of speech carries on in the next one.
                events.append(close(open))
            } else if !speech, time + duration - open.end >= settings.silenceToClose {
                events.append(close(open))
            }
        }
        guard speech else { return events }
        if var open = current {
            open.end = max(open.end, time + duration)
            open.speech += duration
            current = open
        } else {
            current = Conversation(start: time, end: time + duration, speech: duration)
            events.append(.opened(at: time))
        }
        return events
    }

    /// No more audio (capture turned off, or the input ended): whatever is open closes where its speech ended.
    public mutating func finish() -> [Event] {
        guard let open = current else { return [] }
        return [close(open)]
    }

    /// You said it's over (Wrap up now): whatever is open closes now, kept from `minimum` seconds of speech, as you asked
    /// for it to be written down. Listening goes on; the next speech opens a new one.
    public mutating func wrapUp(keepingFrom minimum: TimeInterval) -> [Event] {
        guard let open = current else { return [] }
        current = nil
        return [open.speech >= min(minimum, settings.minSpeech) ? .closed(open) : .dropped(open)]
    }

    /// Lets the open conversation go without an event, for when a moment took its words and nothing else was said in it.
    /// Returns what was open; the next speech opens a new one.
    @discardableResult
    public mutating func discard() -> Conversation? {
        let open = current
        current = nil
        return open
    }

    /// A conversation `discard` let go comes back, as the moment that took its words wasn't kept after all: open again
    /// when nothing is (its quiet counted from where its speech ended), or one with the conversation open now, which then
    /// runs from the earlier of the two starts to the later of the two ends, with the speech of both. True when it's open
    /// again on its own.
    @discardableResult
    public mutating func takeBack(_ earlier: Conversation) -> Bool {
        guard var open = current else {
            current = earlier
            return true
        }
        open.start = min(open.start, earlier.start)
        open.end = max(open.end, earlier.end)
        open.speech += earlier.speech
        current = open
        return false
    }

    private mutating func close(_ conversation: Conversation) -> Event {
        current = nil
        return conversation.speech >= settings.minSpeech ? .closed(conversation) : .dropped(conversation)
    }

    /// The conversations kept from a whole run of decisions, for tests and for processing a recording in one go.
    public static func conversations(in decisions: [(time: TimeInterval, speech: Bool, duration: TimeInterval)],
                                     settings: Settings = Settings()) -> [Conversation] {
        var splitter = ConversationSplitter(settings: settings)
        var kept: [Conversation] = []
        for decision in decisions {
            for case .closed(let conversation) in splitter.add(speech: decision.speech, at: decision.time, duration: decision.duration) {
                kept.append(conversation)
            }
        }
        for case .closed(let conversation) in splitter.finish() { kept.append(conversation) }
        return kept
    }
}

/// Decides, stretch by stretch, whether someone is speaking from how loud it is, when there's no voice detector model:
/// louder than `onDB` starts speech, and it takes `hangover` seconds below `offDB` to end it, so the gaps between words
/// don't count as silence.
public struct LoudnessGate: Sendable {
    public var onDB: Float
    public var offDB: Float
    public var hangover: TimeInterval
    public private(set) var speaking = false
    private var quietFor: TimeInterval = 0

    public init(onDB: Float = -42, offDB: Float = -48, hangover: TimeInterval = 0.6) {
        self.onDB = onDB
        self.offDB = offDB
        self.hangover = hangover
    }

    public mutating func isSpeech(_ samples: [Float], duration: TimeInterval) -> Bool {
        let level = AudioMath.decibels(AudioMath.rms(samples))
        if level >= onDB {
            speaking = true
            quietFor = 0
        } else if speaking, level < offDB {
            quietFor += duration
            if quietFor >= hangover { speaking = false }
        }
        return speaking
    }
}

/// Where each stretch of a capture file came from. The iPhone writes only speech, with a little padding, so a minute
/// into the file can be an hour into the day; these spans map one to the other.
public struct CaptureSpans: Codable, Equatable, Sendable {
    public struct Span: Codable, Equatable, Sendable {
        /// Seconds into the file.
        public var fileStart: TimeInterval
        /// The wall-clock time it was heard.
        public var wallStart: Date
        public var duration: TimeInterval

        public init(fileStart: TimeInterval, wallStart: Date, duration: TimeInterval) {
            self.fileStart = fileStart
            self.wallStart = wallStart
            self.duration = duration
        }
    }

    public private(set) var spans: [Span] = []

    public init(spans: [Span] = []) {
        self.spans = spans.sorted { $0.fileStart < $1.fileStart }
    }

    /// Seconds of audio in the file.
    public var fileDuration: TimeInterval { spans.last.map { $0.fileStart + $0.duration } ?? 0 }

    /// Audio written to the file, heard at `wallStart`. Audio that follows on from the last span without a gap extends it.
    public mutating func append(wallStart: Date, duration: TimeInterval) {
        guard duration > 0 else { return }
        if var last = spans.last, abs(last.wallStart.addingTimeInterval(last.duration).timeIntervalSince(wallStart)) < 0.05 {
            last.duration += duration
            spans[spans.count - 1] = last
        } else {
            spans.append(Span(fileStart: fileDuration, wallStart: wallStart, duration: duration))
        }
    }

    /// The file's audio (`samples`, `rate` a second) cut span by span, each with when it was heard: for writing two
    /// conversations' audio into one file, in the order it was said. A span past the samples' end is cut short or left out.
    public func pieces(of samples: [Float], rate: Double = 16_000) -> [(wallStart: Date, samples: [Float])] {
        spans.compactMap { span in
            let from = max(0, min(samples.count, Int((span.fileStart * rate).rounded())))
            let to = max(from, min(samples.count, Int(((span.fileStart + span.duration) * rate).rounded())))
            return to > from ? (span.wallStart, Array(samples[from..<to])) : nil
        }
    }

    /// Where in the file a moment heard at `wall` is (lane Y2): `wallTime(atFile:)`'s inverse. A moment between two spans,
    /// or outside them, goes to the nearest edge of the nearest span; nil without spans.
    public func fileTime(atWall wall: Date) -> TimeInterval? {
        guard !spans.isEmpty else { return nil }
        if let inside = spans.first(where: { wall >= $0.wallStart && wall <= $0.wallStart.addingTimeInterval($0.duration) }) {
            return inside.fileStart + wall.timeIntervalSince(inside.wallStart)
        }
        let nearest = spans.min { a, b in
            func distance(_ span: Span) -> TimeInterval {
                wall < span.wallStart ? span.wallStart.timeIntervalSince(wall) : wall.timeIntervalSince(span.wallStart.addingTimeInterval(span.duration))
            }
            return distance(a) < distance(b)
        }!
        return wall < nearest.wallStart ? nearest.fileStart : nearest.fileStart + nearest.duration
    }

    /// When a moment of the file was heard. A moment past the end belongs to the last span.
    public func wallTime(atFile seconds: TimeInterval) -> Date? {
        guard !spans.isEmpty else { return nil }
        let span = spans.last { $0.fileStart <= seconds } ?? spans[0]
        return span.wallStart.addingTimeInterval(seconds - span.fileStart)
    }
}

/// Turning a capture's transcript into the one that's kept: voices labelled, times on the clock.
public enum CaptureTranscript {
    /// A segment's speaker until the voices are known.
    public static let unlabelled = "?"

    /// Each segment gets the voice it overlaps most, "Speaker 1", "Speaker 2"… in the order they first speak. A segment
    /// no voice covers takes its nearest neighbour's; with no voices at all, it's all one speaker. Also returns which
    /// label each diarizer id became.
    public static func label(_ segments: [TranscriptSegment], turns: [SpeakerTurn]) -> (segments: [TranscriptSegment], labels: [String: String]) {
        let labels = SpeakerTurns.labels(for: turns)
        var labelled = segments.map { segment -> TranscriptSegment in
            var overlap: [String: Double] = [:]
            for turn in turns where turn.start < segment.end && turn.end > segment.start {
                overlap[turn.speakerID, default: 0] += min(turn.end, segment.end) - max(turn.start, segment.start)
            }
            var copy = segment
            copy.speaker = overlap.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })
                .flatMap { labels[$0.key] } ?? unlabelled
            return copy
        }
        let known = labelled.indices.filter { labelled[$0].speaker != unlabelled }
        for index in labelled.indices where labelled[index].speaker == unlabelled {
            let nearest = known.min { abs(labelled[$0].start - labelled[index].start) < abs(labelled[$1].start - labelled[index].start) }
            labelled[index].speaker = nearest.map { labelled[$0].speaker } ?? "Speaker 1"
        }
        return (labelled, labels)
    }

    /// From times in the audio file, which holds only speech, to seconds since the conversation started on the clock.
    public static func onTheClock(_ segments: [TranscriptSegment], spans: CaptureSpans, started: Date, ended: Date) -> [TranscriptSegment] {
        let length = max(0, ended.timeIntervalSince(started))
        return segments.map { segment in
            var copy = segment
            let start = spans.wallTime(atFile: segment.start).map { $0.timeIntervalSince(started) } ?? segment.start
            let end = spans.wallTime(atFile: segment.end).map { $0.timeIntervalSince(started) } ?? segment.end
            copy.start = min(max(0, start), length)
            copy.end = min(max(copy.start, end), max(length, copy.start))
            return copy
        }
    }
}
