import Foundation

/// Cleaning up a dictation made on the iPhone within one budget of a few seconds: the Mac first (waiting for the link and
/// the Mac's model share the budget), then the iPhone's own model with what's left, then Binders' rules, which take no
/// time. When time is up nothing more is waited for.
public enum DictationCleanup {
    /// Who cleaned it up.
    public enum Cleaner: Equatable, Sendable {
        /// The Mac's model, with its dictionary and snippets: its name, when it said.
        case mac(model: String)
        /// This device's own model.
        case device
        /// Binders' rules alone: there was no model to ask, or its answer wasn't used.
        case rules
        /// Binders' rules alone, as the model asked didn't answer in time: the Mac's (`mac`), or this device's.
        case outOfTime(mac: Bool)
    }

    public struct Result: Equatable, Sendable {
        public var text: String
        public var cleaner: Cleaner
    }

    /// With less than this left, this device's model isn't asked: it couldn't answer in time.
    public static let shortestForDevice: TimeInterval = 0.5

    /// `mac` gets the budget and gives back the Mac's cleanup, or nil when the Mac can't give one in it (out of reach,
    /// too old to know how, too slow); `device` is this device's model, when it has one.
    public static func run(_ raw: String, app: String, budget: TimeBudget,
                           mac: @Sendable (TimeBudget) async -> (text: String, model: String)?,
                           device: LLMCompletion?) async -> Result {
        if let cleaned = await mac(budget), !cleaned.text.isEmpty {
            return Result(text: cleaned.text, cleaner: .mac(model: cleaned.model))
        }
        // The Mac used the time: it was there, and too slow.
        let macRanOut = budget.left < shortestForDevice
        let late = Flag()
        var model: LLMCompletion?
        if let device, !macRanOut {
            model = { system, user in
                do {
                    return try await TimeLimit.run(within: budget.left) { try await device(system, user) }
                } catch let error as TimeLimit.Exceeded {
                    late.set()
                    throw error
                }
            }
        }
        let result = await DictationPipeline.process(raw: raw, context: AppContext(appName: app),
                                                     config: PipelineConfig(aiFormatting: model != nil), llm: model)
        if result.usedLLM { return Result(text: result.text, cleaner: .device) }
        if late.isSet { return Result(text: result.text, cleaner: .outOfTime(mac: false)) }
        return Result(text: result.text, cleaner: macRanOut ? .outOfTime(mac: true) : .rules)
    }
}

/// Set once, read from anywhere.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
