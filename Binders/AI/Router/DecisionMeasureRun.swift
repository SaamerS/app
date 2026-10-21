import Darwin
import Foundation
import BindersKit

/// How far a measure has got: the calls done of all it makes, from when the first began.
struct MeasureProgress: Equatable, Sendable {
    var done: Int
    var of: Int
    /// When the first call began, after the load; nil before.
    var started: Date?

    /// Seconds left from the average so far, once 10 calls are done; nil before.
    func secondsLeft(at now: Date = Date()) -> Double? {
        guard done >= 10, let started else { return nil }
        return now.timeIntervalSince(started) / Double(done) * Double(max(0, of - done))
    }
}

/// The measure (Settings → AI → Decision model → Measure, and `--selftest-router-bench --measure`): the chosen model sorts
/// the made-up cards that come with Binders (RouterBench), and the measure's rules (MeasureRules) pick its bands from the
/// dev cards and hold its start level to the test cards, once.
///
/// 1. Loaded first, outside any card's time: an MLX model with its warm-ups; a server's fields and probes read, then the
///    probes asked again, which must answer alike.
/// 2. Which model it is, after the load (a container in memory's own), and its warm-ups (a server's probes) and letter
///    shares, which become the measure's goldens.
/// 3. The 111 dev cards, both questions, binders described by What goes here and their titles; the same 111, the binder
///    question alone, by their titles alone (the agent question doesn't depend on how binders are described, so its
///    answers are reused); then the 167 test cards, both questions. 389 calls, 667 questions.
/// 4. Still the same model at the end: every call expected its identity, and a server is probed once more.
///
/// Every call has a card's own 4 s and every guard a card has, and the cards are the bench's, never yours: the measure
/// never touches the tuning log. A call that throws stops it, and so do Cancel, a switch, Delete and a quit, which let a
/// pass under way finish first; nothing is kept from a measure that didn't finish.
enum DecisionMeasureRun {
    /// The calls a measure makes: dev with What goes here, dev with titles alone, test.
    static let calls = 111 + 111 + 167
    /// What each call may take: a card's.
    static let cardBudget: Duration = .seconds(4)
    /// The load, or a server's two rounds of probes, before the first card.
    static let prepareWithin: Duration = .seconds(30)
    static let identityWithin: Duration = .seconds(60)
    /// A server's probes at the end.
    static let confirmWithin: Duration = .seconds(10)

    /// A measure that finished, before it's kept: the record, the verdict to keep if its test took the start level away
    /// or raised Auto's level or took it away, what the rules found (the bands with Auto's level among them), what Auto's
    /// rule found, and every answer, for the dev tool to hold to a fixture.
    struct Result: Sendable {
        var identity: DecisionIdentity
        var measure: DecisionMeasure
        var verdict: DecisionMeasure.TestVerdict?
        var outcome: MeasureRules.Outcome
        var auto: MeasureRules.AutoOutcome
        var devBoth: [RouterBench.Answer]
        var devTitles: [RouterBench.Answer]
        var test: [RouterBench.Answer]
        /// From the first call to the last.
        var seconds: Double
    }

    /// Why a measure stopped, or didn't begin.
    enum Stop: Error, Equatable {
        case notUsable
        case noBench(String)
        case notReady(String)
        case unsteady
        case unknownModel
        case tooSlow
        case noAnswer(String)
        case changed
        case unconfirmed

        /// Row E's words.
        var words: String {
            switch self {
            case .notUsable: "It can't sort cards now, so Binders didn't measure it."
            case .noBench(let why): "The made-up cards that come with Binders can't be read (\(why)), so nothing was measured."
            case .notReady(let why): "It didn't get ready for the measure (\(why)), so nothing was measured."
            case .unsteady: "The server's answers to the same questions changed between two asks, so Binders can't measure it: a measure needs the same answer to the same card."
            case .unknownModel: "Binders couldn't tell which model it is, so it didn't measure it."
            case .tooSlow: "A made-up card took more than 4 seconds, a card's limit, so the measure stopped: this model is too slow to sort cards on this Mac. Nothing was kept."
            case .noAnswer(let why): "A made-up card got no answer (\(why)), so the measure stopped. Nothing was kept."
            case .changed: "The model changed while it was measured, so nothing was kept."
            case .unconfirmed: "The server didn't answer its probes at the end of the measure, so Binders can't be sure one model answered throughout. Nothing was kept."
            }
        }
    }

    /// Row E's words for a measure stopped from outside, which keeps nothing.
    static let cancelled = "Cancelled. Nothing was kept."
    static let switched = "The decision model changed, so the measure stopped. Nothing was kept."
    static let deleted = "The model went to the Trash, so the measure stopped. Nothing was kept."
    static let quit = "Binders quit during the measure, so nothing was kept."

    /// What row E says for any error a measure ended with.
    static func words(_ error: Error) -> String {
        switch error {
        case let stop as Stop: stop.words
        case is CancellationError: cancelled
        default: Stop.noAnswer(clause(error)).words
        }
    }

    /// The bench that comes with Binders, as its names were checked (RouterBench.reviewedSHA256).
    static func bundledBench() throws -> RouterBench.Data {
        guard let library = Bundle.main.url(forResource: RouterBench.bundledLibrary, withExtension: "json"),
              let routing = Bundle.main.url(forResource: RouterBench.bundledRouting, withExtension: "json") else {
            throw Stop.noBench("they aren't in Binders' bundle")
        }
        let libraryData = try Data(contentsOf: library), routingData = try Data(contentsOf: routing)
        guard RouterBench.sha256(libraryData) == RouterBench.reviewedSHA256["library.json"],
              RouterBench.sha256(routingData) == RouterBench.reviewedSHA256["routing.json"] else {
            throw Stop.noBench("they aren't the files whose names were checked")
        }
        return try RouterBench.Data(library: libraryData, routing: routingData)
    }

    /// One measure of `backend` on `bench`. `testBefore`: a test verdict that took starting away already holds for the
    /// model it turns out to be; `autoBefore`: what a verdict that holds says about Auto (DecisionMeasure.TestVerdict
    /// .autoBefore). `progress` hears each call done, with when the first began.
    static func run(_ backend: any DecisionBackend, bench: RouterBench.Data, testBefore: @escaping @Sendable (DecisionIdentity) -> Bool,
                    autoBefore: @escaping @Sendable (DecisionIdentity) -> (level: Double?, noAuto: MeasureRules.NoAuto?)? = { _ in nil },
                    progress: @escaping @Sendable (Int, Date) async -> Void) async throws -> Result {
        guard await backend.state().isUsable else { throw Stop.notUsable }
        let library = bench.library
        let dev = bench.items(.dev), test = bench.items(.test)
        guard dev.count + dev.count + test.count == calls else { throw Stop.noBench("\(dev.count) dev and \(test.count) test cards") }
        // Every question built first, as the router builds them, with its options in the order the rules read them.
        typealias Asked = (item: RouterBench.Item, binder: DecisionQuestion, agent: DecisionQuestion)
        func built(_ items: [RouterBench.Item], _ form: RouterQuestions.Form) throws -> [Asked] {
            try items.map { item in
                guard let asked = bench.questions(item, form: form), asked.binder.offered.map(\.name) == library.binders,
                      asked.agent.question.options.map(\.key) == library.agents else {
                    throw Stop.noBench("\(item.id)'s questions aren't the library's")
                }
                return (item, asked.binder.question, asked.agent.question)
            }
        }
        let devBothAsked = try built(dev, .both), devTitlesAsked = try built(dev, .titles), testAsked = try built(test, .both)

        // Loaded first, outside any card's time; a server probed twice, which must answer alike.
        do {
            try await backend.prepare(by: .now + prepareWithin)
        } catch {
            if error is CancellationError || (error as? DecisionError) == .retired { throw CancellationError() }
            if (error as? DecisionError) == .unsteady { throw Stop.unsteady }
            throw Stop.notReady(clause(error))
        }
        try Task.checkCancellation()
        guard let identity = await backend.identity(by: .now + identityWithin) else { throw Stop.unknownModel }
        let golden = await backend.warmUp()
        let shares = await backend.warmUpShares()

        var done = 0
        var started: Date?
        var cardMs: [Double] = []
        func ask(_ questions: [DecisionQuestion]) async throws -> DecisionAnswers {
            try Task.checkCancellation()
            let first = started ?? Date()
            started = first
            let began = ContinuousClock.now
            // Not cancelled with the measure: a pass under way finishes first, as MLX can't be interrupted.
            let call = Task { try await backend.decide(questions, expecting: identity, by: .now + cardBudget) }
            let answers: DecisionAnswers
            do {
                answers = try await call.value
            } catch {
                throw stop(for: error)
            }
            try Task.checkCancellation()
            guard answers.probs.count == questions.count, zip(answers.probs, questions).allSatisfy({ $0.count == $1.options.count }) else {
                throw Stop.noAnswer("no probability for each option")
            }
            if questions.count == 2 { cardMs.append(milliseconds(began.duration(to: .now))) }
            done += 1
            await progress(done, first)
            return answers
        }

        var devBoth: [RouterBench.Answer] = [], devTitles: [RouterBench.Answer] = [], tested: [RouterBench.Answer] = []
        for asked in devBothAsked {
            let answers = try await ask([asked.binder, asked.agent])
            devBoth.append(RouterBench.Answer(item: asked.item, binders: answers.probs[0], agents: answers.probs[1], answeredBy: answers.answeredBy))
        }
        let agents = Dictionary(devBoth.map { ($0.id, $0.agents) }, uniquingKeysWith: { first, _ in first })
        for asked in devTitlesAsked {
            let answers = try await ask([asked.binder])
            devTitles.append(RouterBench.Answer(item: asked.item, binders: answers.probs[0], agents: agents[asked.item.id] ?? [],
                                                answeredBy: answers.answeredBy))
        }
        for asked in testAsked {
            let answers = try await ask([asked.binder, asked.agent])
            tested.append(RouterBench.Answer(item: asked.item, binders: answers.probs[0], agents: answers.probs[1], answeredBy: answers.answeredBy))
        }
        let seconds = started.map { Date().timeIntervalSince($0) } ?? 0

        // Still the same model: each call expected its identity; a server is probed once more and held to it.
        switch await backend.stillSame(identity, by: .now + confirmWithin) {
        case .same: break
        case .changed: throw Stop.changed
        case .notConfirmed: throw Stop.unconfirmed
        }
        try Task.checkCancellation()

        let at = Date()
        var outcome = MeasureRules.measure(devBoth: devBoth, devTitles: devTitles, test: tested, library: library, testBefore: testBefore(identity))
        // Auto's level after the test pass, from the same answers (no more calls): only what Auto would hand an agent that
        // drafts first, on dev (What goes here) and test, at these bands.
        let auto = MeasureRules.auto(dev: devBoth, test: tested, bands: outcome.bands, library: library, verdictBefore: autoBefore(identity))
        outcome.bands.auto = auto.level
        let models = Set((devBoth + devTitles + tested).compactMap(\.answeredBy)).sorted()
        let measure = DecisionMeasure(identity: identity, outcome: outcome, at: at, build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
                                      mac: thisMac(), golden: golden, letterShare: shares, answeredBy: models.isEmpty ? nil : models,
                                      ms: DecisionMeasure.Timing(p50: Int(percentile(cardMs, 0.5).rounded()), p95: Int(percentile(cardMs, 0.95).rounded())),
                                      auto: auto)
        return Result(identity: identity, measure: measure, verdict: outcome.testVerdict(for: identity, at: at, auto: auto), outcome: outcome, auto: auto,
                      devBoth: devBoth, devTitles: devTitles, test: tested, seconds: seconds)
    }

    /// What a call's error means for the measure. A switch, a Delete or a quit retires the backend, and whoever did it
    /// says why the measure stopped.
    static func stop(for error: Error) -> Error {
        switch error {
        case is CancellationError: return error
        case DecisionError.retired: return CancellationError()
        case DecisionError.timedOut: return Stop.tooSlow
        case DecisionError.changed: return Stop.changed
        case let stop as Stop: return stop
        default: return Stop.noAnswer(clause(error))
        }
    }

    /// An error's words as a clause inside a sentence: no period at the end, no capital at the start (but "MLX").
    static func clause(_ error: Error) -> String {
        var text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        if let first = text.first, first.isUppercase, text.dropFirst().first?.isLowercase == true {
            text = first.lowercased() + text.dropFirst()
        }
        return text
    }

    /// This Mac's model and chip, as the measure records them: "Mac17,6, Apple M5 Max".
    static func thisMac() -> String {
        func sysctl(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var value = [CChar](repeating: 0, count: max(1, size))
            sysctlbyname(name, &value, &size, nil, 0)
            return String(cString: value)
        }
        return "\(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string"))"
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// Linear interpolation between ranks, as numpy's default percentile does; 0 for none.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let k = Double(sorted.count - 1) * p
        let low = Int(k), high = min(low + 1, sorted.count - 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (k - Double(low))
    }
}
