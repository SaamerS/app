import AVFoundation
import BindersKit
import FluidAudio
import Foundation

/// The audio side of All-day capture, off the main thread: hears whether someone is speaking, cuts the day into
/// conversations, and writes only the speech (with a second either side) to one file per conversation. Nothing else
/// that's heard is kept.
actor CaptureWorker {
    enum Event: Sendable {
        case opened(CapturedConversation)
        /// Closed with enough speech to keep: ready to transcribe.
        case closed(CapturedConversation)
        /// Closed with too little speech: its audio is already gone.
        case dropped(UUID)
        /// Seconds of speech heard since the last report.
        case heard(speech: TimeInterval)
    }

    /// 256 ms at 16 kHz, the voice detector's step.
    static let chunk = VadManager.chunkSize
    static let chunkSeconds = Double(chunk) / 16_000
    /// Kept before speech starts and after it stops, so no word is clipped.
    static let padding: TimeInterval = 1

    private struct Open {
        var record: CapturedConversation
        var file: AVAudioFile
        /// The end of the last audio written.
        var writtenUntil: Date
        /// Seconds of quiet still to write after the last speech.
        var tail: TimeInterval
        var savedAt: Date
    }

    private var splitter: ConversationSplitter
    private var gate = LoudnessGate()
    private var detector: VadManager?
    private var detectorState: VadStreamState?
    private var pending: [Float] = []
    private var pendingStart: Date?
    private var recent: [(samples: [Float], start: Date)] = []
    private var open: Open?
    private var speechToReport: TimeInterval = 0
    /// While you dictate: what's heard counts as quiet and isn't written. Dictations are kept as dictations.
    private var ignoring = false
    private let report: @Sendable (Event) -> Void

    init(settings: ConversationSplitter.Settings = .init(), report: @escaping @Sendable (Event) -> Void) {
        splitter = ConversationSplitter(settings: settings)
        self.report = report
    }

    func ignore(_ ignoring: Bool) {
        self.ignoring = ignoring
    }

    func useDetector(_ detector: VadManager?) {
        self.detector = detector
        detectorState = nil
    }

    /// Audio from the source, heard at `time`.
    func append(_ samples: [Float], at time: Date) async {
        if let start = pendingStart {
            // A gap in what arrived (the engine restarted): start counting again from here.
            let expected = start.addingTimeInterval(Double(pending.count) / 16_000)
            if abs(time.timeIntervalSince(expected)) > 0.5 {
                pending = []
                pendingStart = time
            }
        } else {
            pendingStart = time
        }
        pending += samples
        while pending.count >= Self.chunk, let start = pendingStart {
            let chunk = Array(pending.prefix(Self.chunk))
            pending.removeFirst(Self.chunk)
            pendingStart = start.addingTimeInterval(Self.chunkSeconds)
            await process(chunk, start: start)
        }
    }

    /// Capture stopped, was muted or interrupted: whatever is open closes, and the next speech starts afresh.
    func finish() {
        for event in splitter.finish() { handle(event) }
        pending = []
        pendingStart = nil
        recent = []
        detectorState = nil
        flushReport()
    }

    private func process(_ chunk: [Float], start: Date) async {
        var speech: Bool
        if let detector, let result = try? await detector.processStreamingChunk(chunk, state: detectorState ?? VadStreamState.initial()) {
            detectorState = result.state
            speech = result.state.triggered
        } else {
            speech = gate.isSpeech(chunk, duration: Self.chunkSeconds)
        }
        // Exact zeros are a muted or dead input, never speech.
        if speech, !chunk.contains(where: { $0 != 0 }) { speech = false }
        if ignoring {
            speech = false
            open?.tail = 0
        }

        let events = splitter.add(speech: speech, at: start.timeIntervalSince1970, duration: Self.chunkSeconds)
        for event in events { handle(event) }

        if var current = open {
            if speech {
                // Back to speech after a pause: the second before it first, as far as it wasn't written already.
                for earlier in recent where earlier.start >= current.writtenUntil.addingTimeInterval(-0.01) {
                    write(earlier.samples, at: earlier.start, to: &current)
                }
                write(chunk, at: start, to: &current)
                current.tail = Self.padding
            } else if current.tail > 0, !ignoring {
                write(chunk, at: start, to: &current)
                current.tail -= Self.chunkSeconds
            }
            if Date().timeIntervalSince(current.savedAt) > 15 {
                CaptureFiles.write(current.record)
                current.savedAt = Date()
            }
            open = current
        }

        // Dictation never becomes the second before someone's first word.
        if ignoring { recent.removeAll() } else { recent.append((chunk, start)) }
        while recent.count > Int((Self.padding / Self.chunkSeconds).rounded(.up)) { recent.removeFirst() }
        if speech { speechToReport += Self.chunkSeconds }
        if speechToReport >= 10 { flushReport() }
    }

    private func handle(_ event: ConversationSplitter.Event) {
        switch event {
        case .opened(let time):
            let id = UUID()
            let started = Date(timeIntervalSince1970: time)
            let record = CapturedConversation(id: id, started: started, ended: started, speech: 0, state: .recording, spans: CaptureSpans())
            guard let file = try? AVAudioFile(forWriting: CaptureFiles.audioURL(id), settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false) else { return }
            var current = Open(record: record, file: file, writtenUntil: .distantPast, tail: Self.padding, savedAt: Date())
            // The second before the first word.
            for earlier in recent { write(earlier.samples, at: earlier.start, to: &current) }
            CaptureFiles.write(current.record)
            open = current
            report(.opened(current.record))
        case .closed(let conversation):
            guard open != nil else { return }
            var record: CapturedConversation
            do {
                // Letting go of the file closes it, before anyone reads it.
                record = open!.record
                open = nil
            }
            record.started = Date(timeIntervalSince1970: conversation.start)
            record.ended = Date(timeIntervalSince1970: conversation.end)
            record.speech = conversation.speech
            record.state = .recorded
            CaptureFiles.write(record)
            report(.closed(record))
        case .dropped:
            guard let current = open else { return }
            open = nil
            let id = current.record.id
            try? FileManager.default.removeItem(at: CaptureFiles.audioURL(id))
            try? FileManager.default.removeItem(at: CaptureFiles.recordURL(id))
            report(.dropped(id))
        }
    }

    private func write(_ samples: [Float], at start: Date, to current: inout Open) {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: SixteenKilohertz.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        do {
            try current.file.write(from: buffer)
        } catch {
            return
        }
        let seconds = Double(samples.count) / 16_000
        current.record.spans.append(wallStart: start, duration: seconds)
        current.writtenUntil = start.addingTimeInterval(seconds)
    }

    private func flushReport() {
        guard speechToReport > 0 else { return }
        report(.heard(speech: speechToReport))
        speechToReport = 0
    }
}
