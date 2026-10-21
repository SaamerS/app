import Foundation
import BindersKit

/// A model that picks one of a few options, with a probability for each: an MLX model inside Binders, or a decision server
/// on this Mac. Nothing else in Binders knows which model it is: the router gets its answers, and DecisionModels its bands.
/// `AnyObject`, so DecisionModels can tell one backend from another (`===`) when it checks a start.
protocol DecisionBackend: AnyObject, Sendable {
    func state() async -> DecisionBackendState
    /// The model that answers next and how it's read ("tev1.1/256", "chat.1/256", "jev.1"): a container in memory's own,
    /// else the folder's, worked out once and cached; a server's, from its fields and probes. Waits for it until
    /// `deadline`; nil when it isn't known by then or can't be.
    func identity(by deadline: ContinuousClock.Instant) async -> DecisionIdentity?
    /// The warm-up goldens of the bands that apply (DecisionBands), one per warm-up question: this launch's warm-ups are
    /// held to them. Nil: none, so numbersMatch() is false and numbersDiffer() false.
    func setGolden(_ golden: [[Double]]?) async
    /// This launch's warm-ups matched the goldens. Nothing starts on its own while it's false.
    func numbersMatch() async -> Bool
    /// A golden is set, a warm-up ran this launch, and they didn't match: false before the first load, and always false
    /// for a model with no golden (one never measured), as there's nothing to differ from.
    func numbersDiffer() async -> Bool
    /// This launch's warm-ups (a server's: its probes), for the measure to record. Nil before a load.
    func warmUp() async -> [[Double]]?
    /// An MLX model's: at each of this launch's warm-ups, the offered letters' share of the whole vocabulary's
    /// probability at the answer's first position, for the measure to record. Nil for a server, and before a load.
    func warmUpShares() async -> [Double]?
    /// Each question's option probabilities, in the order given, by `deadline` or a throw, from the model `expected` names:
    /// one that would answer from other files or as another model throws `.changed` without an answer. A server's answer
    /// comes back with the model it names (`answeredBy`), which `confirm` holds to the identity before any start. Waiting,
    /// a cold load and the questions all count. An MLX error is a throw, never a crash.
    func decide(_ questions: [DecisionQuestion], expecting expected: DecisionIdentity?,
                by deadline: ContinuousClock.Instant) async throws -> DecisionAnswers
    /// Loads it, or probes a server, by `deadline`: for the measure, which mustn't spend a card's 4 s on a cold load.
    func prepare(by deadline: ContinuousClock.Instant) async throws
    /// Right before a start, after the decision: still the model `identity` names. MLX: not retired or failed, and its
    /// folder still the files it was read from. A server: its fields and probes asked again now, and matching.
    func stillSame(_ identity: DecisionIdentity, by deadline: ContinuousClock.Instant) async -> StillSame
    /// Minutes unused before it lets go of its memory; 0 keeps it loaded (memory pressure still lets it go).
    func setIdle(minutes: Int) async
    func unload() async
    /// Switched away from, or deleted: no load or pass starts, a load under way is dropped when it lands, and the memory
    /// goes. `revive()` when it's chosen again.
    func retire() async
    func revive() async
    /// Binders is quitting: no load or pass starts; a pass under way may finish within `within`.
    func prepareForQuit(within: Duration) async
    /// Try Again or Check Again: clears a failure (and the marker a crash left), or probes a server now.
    func tryAgain() async
}


/// Whether the model that decided is still the one its identity names, right before a start.
enum StillSame: Equatable, Sendable {
    case same
    /// Another model, other files, or a backend switched away from or failed since.
    case changed
    /// A server didn't answer its probes in time: nothing is known either way.
    case notConfirmed
}

/// A decision's answers: each question's probabilities in option order, and the model a server says answered (nil for an
/// MLX model, and for a server that names none).
struct DecisionAnswers: Sendable {
    var probs: [[Double]]
    var answeredBy: String?
}

enum DecisionBackendState: Equatable, Sendable {
    /// The checks before MLX, or a server's first probe, are under way.
    case checking
    /// Can't be used: why.
    case unavailable(Unavailable)
    /// An MLX model on this Mac, not in memory.
    case ready(bytes: Int64)
    /// In memory, until it lets go.
    case loaded(bytes: Int64, resident: Int64, until: Date?)
    /// A server whose probe answered, with the names it gave.
    case answering(names: [String])
    /// It didn't load or decide, or the marker was found: until Try Again, a change to its folder, or the next launch.
    case failed(String)

    enum Unavailable: Equatable, Sendable {
        /// Tev1's folder isn't there.
        case noFolder
        /// A Hugging Face choice not in Models/MLX yet.
        case notDownloaded
        /// An Intel Mac, under 16 GB, or a model too big for this Mac's memory: why.
        case thisMac(String)
        /// The folder's check failed: why.
        case folder(String)
        /// It can't answer with a letter: its letters, its chat template, its thinking, its model type.
        case cantAnswer(String)
        /// LoopbackRule refused the server's address: why.
        case address(String)
        /// Nothing answered, a key was asked for, or it isn't a decision server: why.
        case unreachable(String)
    }

    var isUsable: Bool {
        switch self {
        case .ready, .loaded, .answering: true
        case .checking, .unavailable, .failed: false
        }
    }

    /// Worth asking for a card: usable; still being checked, which a card waits for inside its own time; or a server that
    /// didn't answer the last time, which the next card tries again (a refused connection costs it a millisecond, and a
    /// server that hangs is skipped for a minute by the backend itself).
    var worthAsking: Bool {
        switch self {
        case .ready, .loaded, .answering, .checking, .unavailable(.unreachable): true
        case .unavailable, .failed: false
        }
    }
}

enum DecisionError: LocalizedError, Equatable {
    /// Not on this Mac, or not usable now.
    case unavailable(String)
    /// MLX said something went wrong.
    case mlx(String)
    /// The card's time ran out.
    case timedOut
    /// Not enough memory free to load it now.
    case memory
    /// A question it can't be asked: fewer than 2 options or more than 24.
    case refused
    /// A server answered with an error, or with probabilities that don't map to the options.
    case server(String)
    /// Two options of one question with one key, which a server would collapse into one: refused before anything is sent.
    case refusedKeys
    /// The model that would answer isn't the one expected: a folder replaced, a container from other files, a server
    /// answering as another model.
    case changed
    /// Switched away from, deleted, or Binders is quitting.
    case retired
    /// A server answered the same probes differently twice in a row, so it can't be measured.
    case unsteady

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): why
        case .mlx(let message): "MLX: \(message)"
        case .timedOut: "It took more than its time."
        case .memory: "Not enough memory free to load it now."
        case .refused: "A question with fewer than 2 options or more than 24."
        case .server(let why): why
        case .refusedKeys: "two options with one key"
        case .changed: "it isn't the model its bands are for any more"
        case .retired: "the decision model changed"
        case .unsteady: "its answers to the same questions changed between two asks"
        }
    }
}
