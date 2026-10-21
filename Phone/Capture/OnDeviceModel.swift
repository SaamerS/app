import BindersKit
import Foundation
import FoundationModels

/// Apple's on-device model (Apple Intelligence, iOS 26), as the fourth check on something heard on its own: what kind of
/// thing was said, from a closed list (MomentGate). Off the main thread, and never longer than MomentGate.modelTimeout:
/// when the model isn't on this iPhone, is slow or fails, the other three checks stand alone. Only the words go to it, and
/// it runs on this iPhone.
enum OnDeviceModel {
    /// What it made of something said.
    enum Reading: Equatable {
        case kind(MomentKind)
        /// No model on this iPhone, or it isn't ready (Apple Intelligence off, or still downloading).
        case unavailable
        /// It didn't answer in time, or couldn't (busy, or held back in the background).
        case noAnswer
    }

    /// Whether this iPhone has the model now.
    static var isAvailable: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return SystemLanguageModel.default.availability == .available
    }

    /// The kind of `said`, within `limit` seconds. What it's still doing then is cancelled, and nothing waits for it.
    /// `instructions` (lane Y2): MomentGate.uncuedInstructions for a sentence the rules read without a cue, in Auto.
    static func kind(of said: String, instructions: String = MomentGate.instructions, within limit: TimeInterval = MomentGate.modelTimeout) async -> Reading {
        guard #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available else { return .unavailable }
        return await withCheckedContinuation { continuation in
            let answer = FirstAnswer(continuation)
            let work = Task.detached(priority: .userInitiated) { await read(said, instructions: instructions) }
            let timer = Task.detached {
                try? await Task.sleep(for: .seconds(limit))
                work.cancel()
                answer.give(.noAnswer)
            }
            Task.detached {
                let kind = await work.value
                timer.cancel()
                answer.give(kind.map(Reading.kind) ?? .noAnswer)
            }
        }
    }

    /// One short session per clip: nothing from one is carried to the next.
    @available(iOS 26.0, *)
    private static func read(_ said: String, instructions: String) async -> MomentKind? {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 24)
        guard let reply = try? await session.respond(to: MomentGate.prompt(said), generating: MomentKindAnswer.self, options: options) else { return nil }
        return MomentGate.kind(reply.content.kind)
    }
}

/// The model's answer: one of MomentGate's kinds, and nothing else.
@available(iOS 26.0, *)
@Generable
struct MomentKindAnswer {
    // MomentGate.kinds, spelled out where the schema is made (the kit's tests hold them to these words).
    @Guide(description: "What kind of thing they said", .anyOf(["todo", "question", "idea", "status", "note", "none"]))
    var kind: String
}

/// Resumes once, whichever comes first: the answer or the time running out.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OnDeviceModel.Reading, Never>?

    init(_ continuation: CheckedContinuation<OnDeviceModel.Reading, Never>) {
        self.continuation = continuation
    }

    func give(_ reading: OnDeviceModel.Reading) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: reading)
    }
}
