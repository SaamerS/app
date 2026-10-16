import AVFoundation
import Foundation

/// Where All-day capture's audio comes from: 16 kHz mono samples, each stretch with the moment it was heard. The
/// iPhone's or the Mac's microphone today; a wearable later, behind this same seam, with nothing downstream changing.
protocol CaptureSource: AnyObject {
    /// Called off the main thread, in order.
    var onAudio: (@Sendable ([Float], Date) -> Void)? { get set }
    /// What the audio session and the system call it ("iPhone microphone").
    var name: String { get }
    func start() throws
    /// Stops completely: for the microphone, the engine is torn down so the orange dot goes away.
    func stop()
}

/// The built-in microphone (on the Mac, the input chosen in System Settings), converted to 16 kHz mono.
final class MicSource: CaptureSource {
    var onAudio: (@Sendable ([Float], Date) -> Void)?
    let name = "Microphone"
    private var engine: AVAudioEngine?

    func start() throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noMicrophone }
        let converter = SixteenKilohertz(from: format)
        let deliver = onAudio
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            // When the first sample of this buffer was heard.
            let seconds = Double(buffer.frameLength) / format.sampleRate
            let heard = Date().addingTimeInterval(-seconds)
            guard let samples = converter.convert(buffer), !samples.isEmpty else { return }
            deliver?(samples, heard)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }
}

/// Nothing but quiet, a second at a time: stands in for the microphone in the Simulator and in UI tests
/// (`-captureSource silence`), where there's no voice to hear.
final class SilenceSource: CaptureSource {
    var onAudio: (@Sendable ([Float], Date) -> Void)?
    let name = "Silence (testing)"
    private var timer: DispatchSourceTimer?

    func start() throws {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let deliver = onAudio
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            deliver?([Float](repeating: 0, count: 16_000), Date().addingTimeInterval(-1))
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

enum CaptureError: LocalizedError {
    case microphone, noMicrophone

    var errorDescription: String? {
        switch self {
        #if os(macOS)
        case .microphone: "Binders needs the microphone for All-day capture. Allow it in System Settings → Privacy & Security → Microphone."
        #else
        case .microphone: "Binders needs the microphone for All-day capture. Allow it in Settings → Binders."
        #endif
        case .noMicrophone: "There's no microphone to listen with right now."
        }
    }
}

/// Converts whatever the microphone gives (usually 48 kHz) to 16 kHz mono floats, the rate the speech models use.
final class SixteenKilohertz: @unchecked Sendable {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let converter: AVAudioConverter?
    private let input: AVAudioFormat

    init(from input: AVAudioFormat) {
        self.input = input
        converter = AVAudioConverter(from: input, to: Self.format)
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / input.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return nil }
        var used = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if used {
                status.pointee = .noDataNow
                return nil
            }
            used = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
