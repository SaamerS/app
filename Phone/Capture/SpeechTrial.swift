#if DEBUG
import AVFoundation
import BindersKit
@preconcurrency import FluidAudio
import Foundation
import Observation
import SwiftUI
import UIKit

/// Debug builds only, for the device spike: Apple's SpeechTranscriber (iOS 26) beside Parakeet on short clips, the first 3
/// to 15 seconds of speech in each of the latest captures. The capture screen's "Try SpeechTranscriber on the last clips"
/// writes the last three down with both, with the app open. With "Also try it while locked" on, each capture that closes
/// with the app in the background is clipped and written down there at once: by SpeechTranscriber, then by Parakeet where
/// it may run there without getting in the way of the capture's own writing down. Each run notes how long its engine took
/// to get ready (SpeechTranscriber's preparing, Parakeet's load) and in all, and is noted as it starts, so one iOS stopped
/// shows as never finished. Clips and what came of them stay in the capture folder, out of backups, for a day. None of
/// this is in a release build.
@MainActor
@Observable
final class SpeechTrial {
    static let shared = SpeechTrial()

    /// One engine on one clip.
    struct Run: Codable, Equatable, Identifiable {
        var id = UUID()
        var engine: String
        /// With the app in the background, and whether the iPhone was locked then.
        var background: Bool
        var locked: Bool
        var started: Date
        /// Of `seconds`, how long the engine took to get ready.
        var setup: Double?
        var seconds: Double?
        var text: String?
        /// What went wrong; with no `seconds`, why it wasn't tried.
        var error: String?
    }

    /// The first speech of a capture, kept as a small audio file beside the results.
    struct Clip: Codable, Equatable, Identifiable {
        let id: UUID
        let capture: UUID
        var heard: Date
        var made: Date
        var seconds: Double
        var runs: [Run]
    }

    /// Newest first.
    private(set) var clips: [Clip] = []
    private(set) var running = false
    /// Said under the button when there was nothing to try.
    private(set) var note: String?
    var whileLocked: Bool {
        didSet { UserDefaults.standard.set(whileLocked, forKey: "speechTrialWhileLocked") }
    }

    static let speechTranscriber = "SpeechTranscriber"
    private static let kept = 8
    private static let lastClips = 3
    private static let clipSeconds = 15.0
    @ObservationIgnored private var attempt = 0

    private init() {
        whileLocked = UserDefaults.standard.bool(forKey: "speechTrialWhileLocked")
        clips = (try? JSONDecoder().decode([Clip].self, from: Data(contentsOf: Self.resultsURL))) ?? []
        tidy()
    }

    private static var folder: URL {
        let url = CaptureFiles.folder.appendingPathComponent("SpeechTrial", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var resultsURL: URL { folder.appendingPathComponent("results.json") }
    private static func audioURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).caf") }

    // MARK: Trying

    /// A capture just closed. With the app in the background and the switch on, its first speech becomes a clip, written
    /// down there and then.
    func closed(_ conversation: CapturedConversation, inBackground: Bool) {
        guard whileLocked, inBackground, let clip = cut(conversation) else { return }
        Task { await run(clip.id) }
    }

    /// The latest three captures' clips, cut now from those that still have their audio, each written down by
    /// SpeechTranscriber and by Parakeet.
    func tryLastClips() {
        guard !running else { return }
        tidy()
        var ids: [UUID] = []
        for conversation in CaptureStore.shared.conversations where ids.count < Self.lastClips && conversation.state != .recording {
            if let clip = clips.first(where: { $0.capture == conversation.id }) {
                ids.append(clip.id)
            } else if !conversation.audioDeleted, let record = CaptureStore.shared.conversation(conversation.id), let clip = cut(record) {
                ids.append(clip.id)
            }
        }
        guard !ids.isEmpty else {
            note = "No clips: none of the latest captures still has its audio. Turn on Keep audio for 24 hours or Also try it while locked, then capture again."
            return
        }
        note = nil
        running = true
        attempt += 1
        let attempt = attempt
        Task {
            for id in ids { await run(id) }
            if self.attempt == attempt { running = false }
        }
        // A run that never comes back doesn't keep the button away: it shows as still running.
        Task {
            try? await Task.sleep(for: .seconds(180))
            if self.attempt == attempt { running = false }
        }
    }

    /// One clip through SpeechTranscriber, then Parakeet, each timed.
    private func run(_ id: UUID) async {
        guard let samples = Self.read(Self.audioURL(id)) else { return }
        let clip = AudioMath.normalize(samples)
        await timed(id, Self.speechTranscriber) {
            guard #available(iOS 26.0, *) else { throw TrialError.needsIOS26 }
            return try await Self.transcribeWithApple(clip)
        }
        let models = CaptureModels.shared
        let engine = CaptureModels.engineName(models.version)
        let background = UIApplication.shared.applicationState == .background
        if background, let why = Self.parakeetWaits {
            return skipped(id, engine, why)
        }
        await timed(id, engine) {
            let began = Date()
            guard models.hasTranscriber, let manager = await models.transcriber() else { throw TrialError.noParakeet }
            let setup = Date().timeIntervalSince(began)
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let text = try await manager.transcribe(AudioMath.padded(clip, toAtLeast: 16_000), decoderState: &state, language: nil).text
            return (text, setup)
        }
        // In the background the big model goes again once it's done, as after a moment.
        if background, UIApplication.shared.applicationState == .background, ConversationProcessor.shared.working == nil {
            models.unloadTranscriber()
        }
    }

    /// Why Parakeet isn't tried on a clip in the background now, or nil when it may be: only where iOS lets it run there,
    /// once it's been readied with the app open (its first load is a compile), and not while a capture is being written
    /// down, which lets go of Parakeet there to make room for telling the voices apart.
    private static var parakeetWaits: String? {
        if !CaptureModels.mayInferInBackground { return "Not tried in the background: iOS keeps the models from background apps." }
        if !CaptureModels.shared.isReadyForBackground { return "Not tried in the background: open Binders once to ready the models." }
        if ConversationProcessor.shared.working != nil { return "Not tried in the background: Binders was writing a capture down." }
        return nil
    }

    /// Apple's engine on a clip of 16 kHz audio, as the app writes things down with it, with how long it took to get
    /// ready (its assets, the analyzer).
    @available(iOS 26.0, *)
    private static func transcribeWithApple(_ clip: [Float]) async throws -> (text: String, setup: Double?) {
        guard AnalyzerEngine.isSupported else { throw TrialError.unsupported }
        let began = Date()
        let engine = AnalyzerEngine()
        try await engine.prepare()
        let setup = Date().timeIntervalSince(began)
        guard let buffer = buffer(clip) else { throw TrialError.unreadable }
        engine.append(buffer)
        return (try await engine.finish(), setup)
    }

    /// Notes the run as it starts, then what came of it and how long it took.
    private func timed(_ id: UUID, _ engine: String, _ work: () async throws -> (text: String, setup: Double?)) async {
        let run = Self.newRun(engine)
        update(id) { $0.runs = Array(($0.runs + [run]).suffix(8)) }
        var result: (text: String, setup: Double?)?
        var error: String?
        do {
            result = try await work()
        } catch let failure {
            error = failure.localizedDescription
        }
        let seconds = Date().timeIntervalSince(run.started)
        update(id) { clip in
            guard let index = clip.runs.firstIndex(where: { $0.id == run.id }) else { return }
            clip.runs[index].seconds = seconds
            clip.runs[index].setup = result?.setup
            clip.runs[index].text = result?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            clip.runs[index].error = error
        }
    }

    /// An engine that wasn't tried on this clip, and why.
    private func skipped(_ id: UUID, _ engine: String, _ why: String) {
        var run = Self.newRun(engine)
        run.error = why
        update(id) { $0.runs = Array(($0.runs + [run]).suffix(8)) }
    }

    private static func newRun(_ engine: String) -> Run {
        let app = UIApplication.shared
        return Run(engine: engine, background: app.applicationState == .background, locked: !app.isProtectedDataAvailable, started: Date())
    }

    private enum TrialError: LocalizedError {
        case needsIOS26, unsupported, noParakeet, unreadable

        var errorDescription: String? {
            switch self {
            case .needsIOS26: "SpeechTranscriber needs iOS 26."
            case .unsupported: "SpeechTranscriber isn't available on this iPhone."
            case .noParakeet: "Parakeet isn't on this iPhone yet, or can't load now."
            case .unreadable: "The clip couldn't be read."
            }
        }
    }

    // MARK: Clips

    /// Up to 15 seconds of the first speech in a capture's audio, cut at a pause as the transcriber would, and saved as a
    /// clip; nil when there's no audio, or only silence near its start.
    private func cut(_ conversation: CapturedConversation) -> Clip? {
        guard let file = try? AVAudioFile(forReading: CaptureFiles.audioURL(conversation.id)) else { return nil }
        var position: AVAudioFramePosition = 0
        var samples: [Float] = []
        for _ in 0..<8 where position < file.length {
            guard let window = try? ConversationProcessor.read(file, from: position, frames: 30 * 16_000), !window.isEmpty else { break }
            let length = max(1, SpeechChunker.nextBoundary(window[...], maxSeconds: Self.clipSeconds, isFinal: true) ?? window.count)
            let chunk = Array(window.prefix(length))
            if !AudioMath.isSilent(chunk) {
                samples = chunk
                break
            }
            position += AVAudioFramePosition(length)
        }
        let id = UUID()
        guard !samples.isEmpty, Self.write(samples, to: Self.audioURL(id)) else { return nil }
        let heard = conversation.spans.wallTime(atFile: Double(position) / 16_000) ?? conversation.started
        let clip = Clip(id: id, capture: conversation.id, heard: heard, made: Date(), seconds: Double(samples.count) / 16_000, runs: [])
        // Newest heard first; the oldest go, so the latest captures' clips stay.
        clips = (clips + [clip]).sorted { $0.heard > $1.heard }
        for old in clips.dropFirst(Self.kept) { try? FileManager.default.removeItem(at: Self.audioURL(old.id)) }
        clips = Array(clips.prefix(Self.kept))
        save()
        return clip
    }

    /// Clips go a day after they were made, with what came of them.
    private func tidy(now: Date = Date()) {
        let old = clips.filter { now.timeIntervalSince($0.made) > 86_400 }
        guard !old.isEmpty else { return }
        for clip in old { try? FileManager.default.removeItem(at: Self.audioURL(clip.id)) }
        clips.removeAll { now.timeIntervalSince($0.made) > 86_400 }
        save()
    }

    private func update(_ id: UUID, _ change: (inout Clip) -> Void) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        change(&clips[index])
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(clips) else { return }
        try? data.write(to: Self.resultsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: SixteenKilohertz.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    private static func write(_ samples: [Float], to url: URL) -> Bool {
        guard let buffer = buffer(samples) else { return false }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            return true
        } catch {
            return false
        }
    }

    private static func read(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let samples = try? ConversationProcessor.read(file, from: 0, frames: Int(file.length)), !samples.isEmpty else { return nil }
        return samples
    }
}

extension SpeechTrial.Run {
    /// "SpeechTranscriber, locked · 1.9 s, 0.8 s to get ready: “…”", or why it didn't write anything.
    var line: String {
        let place = locked ? ", locked" : background ? ", in the background" : ""
        guard let seconds else {
            // Not tried, and why; or noted as it started, and nothing since: still going, or iOS stopped Binders first.
            if let error { return "\(engine)\(place): \(error)" }
            return "\(engine)\(place): " + (Date().timeIntervalSince(started) > 300 ? "never finished" : "running…")
        }
        let took = String(format: "%.1f s", seconds) + (setup.map { String(format: ", %.1f s to get ready", $0) } ?? "")
        if let error { return "\(engine)\(place) · \(took): \(error)" }
        return "\(engine)\(place) · \(took): “\(text ?? "")”"
    }
}

/// One clip on the capture screen's Developer section: when it was heard, how long it is, and each engine's go at it.
struct SpeechTrialRow: View {
    let clip: SpeechTrial.Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(clip.heard.formatted(date: .omitted, time: .shortened)) · \(Int(clip.seconds.rounded())) s clip")
                .font(.footnote.monospacedDigit()).foregroundStyle(Palette.muted)
            if clip.runs.isEmpty {
                Text("Not tried yet").font(.caption).foregroundStyle(Palette.muted)
            }
            ForEach(clip.runs) { run in
                // For the developer: plainly, an error in the line's own words rather than a colour.
                Text(run.line).font(.caption).foregroundStyle(run.error == nil ? Palette.ink : Palette.muted).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
