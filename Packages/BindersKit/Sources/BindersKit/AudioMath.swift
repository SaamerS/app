import Foundation

public enum AudioMath {
    public static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    public static func decibels(_ amplitude: Float) -> Float {
        20 * log10(max(amplitude, 1e-7))
    }

    /// Loudness of the voiced part: the 90th-percentile RMS over 30 ms frames, so silence doesn't dilute it.
    public static func speechLevel(_ samples: [Float], frameSize: Int = 480) -> Float {
        guard samples.count >= frameSize else { return rms(samples) }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frameSize)
        var start = 0
        while start + frameSize <= samples.count {
            levels.append(rms(samples[start..<start + frameSize]))
            start += frameSize
        }
        levels.sort()
        return levels[min(levels.count - 1, Int(Double(levels.count) * 0.9))]
    }

    public static func isSilent(_ samples: [Float], thresholdDB: Float = -52) -> Bool {
        decibels(speechLevel(samples)) < thresholdDB
    }

    /// Brings quiet (whispered or far-field) speech up to a consistent level with a soft limiter.
    public static func normalize(_ samples: [Float], targetDB: Float = -20, maxGainDB: Float = 20) -> [Float] {
        let level = speechLevel(samples)
        guard level > 0 else { return samples }
        let gainDB = min(max(targetDB - decibels(level), 0), maxGainDB)
        guard gainDB > 0.5 else { return samples }
        let gain = pow(10, gainDB / 20)
        let knee: Float = 0.85
        return samples.map { sample in
            let y = sample * gain
            let magnitude = abs(y)
            guard magnitude > knee else { return y }
            let limited = knee + (1 - knee) * tanh((magnitude - knee) / (1 - knee))
            return y < 0 ? -limited : limited
        }
    }

    public static func padded(_ samples: [Float], toAtLeast count: Int) -> [Float] {
        guard samples.count < count else { return samples }
        return samples + [Float](repeating: 0, count: count - samples.count)
    }

    /// From the first loud 30 ms frame to the end of the last: the quiet at either end let go. A frame is loud within
    /// `belowPeakDB` of the loudest and above `floorDB`. All of it when no frame is loud, or it's shorter than a frame.
    public static func trimmedQuiet(_ samples: [Float], frameSize: Int = 480, belowPeakDB: Float = 30, floorDB: Float = -55) -> ArraySlice<Float> {
        guard frameSize > 0, samples.count >= frameSize else { return samples[...] }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frameSize + 1)
        var start = 0
        while start < samples.count {
            levels.append(decibels(rms(samples[start..<min(samples.count, start + frameSize)])))
            start += frameSize
        }
        let bar = max(floorDB, (levels.max() ?? floorDB) - belowPeakDB)
        guard let first = levels.firstIndex(where: { $0 >= bar }), let last = levels.lastIndex(where: { $0 >= bar }) else { return samples[...] }
        return samples[(first * frameSize)..<min(samples.count, (last + 1) * frameSize)]
    }

    /// The diarizer's window, in samples at 16 kHz: it hears a voice ten seconds at a time.
    public static let voiceWindow = 10 * 16_000

    /// A clip a few seconds long, made ready for its voice to be scored against your print: its quiet ends trimmed, then
    /// what's left said again end to end until it fills `count` samples (the diarizer's window). The diarizer pads a short
    /// clip with silence to its window, and a voice heard that way comes out far from the print taught from twenty seconds,
    /// whoever spoke: on the bench, 2-5 s clips of the very voice a print was taught from scored about 0.33 against it, and
    /// other voices 0.28, so nothing passed 0.65. Filled this way, the same voice scores about 0.85, others about 0.3.
    /// A clip already as long as the window comes back trimmed, as it is.
    public static func filledForVoice(_ samples: [Float], toAtLeast count: Int = voiceWindow) -> [Float] {
        let speech = trimmedQuiet(samples)
        guard !speech.isEmpty, speech.count < count else { return Array(speech) }
        var filled: [Float] = []
        filled.reserveCapacity(count)
        while filled.count < count { filled.append(contentsOf: speech.prefix(count - filled.count)) }
        return filled
    }
}

public struct UsageRecord: Sendable {
    public var date: Date
    public var words: Int
    public var duration: TimeInterval

    public init(date: Date, words: Int, duration: TimeInterval) {
        self.date = date
        self.words = words
        self.duration = duration
    }
}

public struct UsageStats: Equatable, Sendable {
    public var totalWords: Int
    public var sessions: Int
    public var averageWPM: Int
    public var streakDays: Int
    public var minutesSaved: Int
    public var wordsThisWeek: Int
}

public enum StatsCalculator {
    public static func compute(_ records: [UsageRecord], now: Date = Date(), calendar: Calendar = .current,
                               typingWPM: Double = 40) -> UsageStats {
        let totalWords = records.reduce(0) { $0 + $1.words }
        let totalMinutes = records.reduce(0) { $0 + $1.duration } / 60
        let wpm = totalMinutes > 0.05 ? Int((Double(totalWords) / totalMinutes).rounded()) : 0
        let saved = max(0, Double(totalWords) / typingWPM - totalMinutes)

        let days = Set(records.map { calendar.startOfDay(for: $0.date) })
        var streak = 0
        var day = calendar.startOfDay(for: now)
        if !days.contains(day), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) {
            day = yesterday
        }
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }

        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let weekWords = records.filter { $0.date >= weekStart }.reduce(0) { $0 + $1.words }

        return UsageStats(totalWords: totalWords, sessions: records.count, averageWPM: wpm, streakDays: streak,
                          minutesSaved: Int(saved.rounded()), wordsThisWeek: weekWords)
    }

    /// Words per day for the last `days` days, oldest first, with quiet days as zero.
    public static func dailyWords(_ records: [UsageRecord], days: Int = 14, now: Date = Date(), calendar: Calendar = .current) -> [(date: Date, words: Int)] {
        let today = calendar.startOfDay(for: now)
        var totals: [Date: Int] = [:]
        for record in records { totals[calendar.startOfDay(for: record.date), default: 0] += record.words }
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (day, totals[day] ?? 0)
        }
    }
}
