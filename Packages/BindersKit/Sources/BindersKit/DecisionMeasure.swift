import Foundation

/// The measure's rules: from a decision model's answers to the bench's made-up cards, the bands it gets and whether it may
/// ever start an agent on its own. Fixed rules on fixed inputs, so measuring again can't tune a model, and nothing on the
/// test split picks a band: test can only take a start level away. On lane R1's numbers for Tev1 0.8B bf16 they give R1's
/// bands exactly: General below 0.45, and 0.33 with titles alone; suggest at 0.50; start at 0.97, with 3 dev starts and 4
/// test starts, none wrong (lane R2's DESIGN.md 7.4 and 7.5).
///
/// The app's pick for an item, at General threshold g and suggest level s, is what RouterRules does with no name said:
/// the best binder, or General when its probability is under g; the top agent, unless it's nobody, under s, or doesn't
/// take that binder's cards, and then none (never the next one down). It's right when the binder is one of the item's and
/// the agent (none counting as nobody) is too.
///
/// 1. **General**, for each form (What goes here and titles; titles alone): for t = 0.00, 0.01 … 0.90, how many dev
///    binders the app files right. The highest run of thresholds that reach the most; its middle (the lower of two).
/// 2. **Suggest:** the lowest of 0.50, 0.55 … 0.90 at which the app names an agent for at least 5 dev items and at least 7
///    in 10 of them are right. None: it names no agent and starts none.
/// 3. **Start:** the lowest of 0.95 … 0.99 at which, on dev in both forms, every app pick at or above it is right and no
///    wrong one lies from 0.005 under it; there must be at least 2 such starts (What goes here form).
/// 4. **Test, once,** at that level: no wrong start, at least 1 start, and at least 5 with dev's; else no start level.
/// 5. A test that took a model's start away keeps it away for that model (`testBefore`).
/// 6. A server whose answers named more than one model gets no start level (`severalModels`).
/// 7. **Auto's level**, from the same answers, counting only what Auto would hand to an agent that drafts first: `auto`.
public enum MeasureRules {
    public static let generalGrid: [Double] = (0...90).map { Double($0) / 100 }
    public static let suggestGrid: [Double] = (0...8).map { Double(50 + 5 * $0) / 100 }
    public static let startBars: [Double] = [0.95, 0.96, 0.97, 0.98, 0.99]
    /// No wrong pick may lie this close under a start level: lane R1's two runtimes put the same card's numbers up to
    /// 0.006 apart near the bar, and the warm-ups are held to 0.002.
    public static let nearMargin = 0.005
    /// A suggest level needs at least this many agents named, at least 7 in 10 of them right.
    public static let leastNamed = 5
    /// A start level needs this many dev starts, then at least 1 on test and 5 in all.
    public static let leastDevStarts = 2
    public static let leastTestStarts = 1
    public static let leastStarts = 5

    /// The app's pick for one item.
    public struct Pick: Equatable, Sendable {
        public var binder: String
        /// The agent named; nil for none.
        public var agent: String?
        /// The top agent's probability.
        public var p: Double
        public var binderRight: Bool
        /// The agent, none counting as nobody, is one of the item's.
        public var agentRight: Bool
    }

    /// A start: an app pick at a start level or above.
    public struct Start: Equatable, Sendable {
        public var id: String
        public var agent: String
        public var p: Double
        public var right: Bool
    }

    /// What dev gives: General for each form, the suggest level, and the start level it would have before test.
    public struct Dev: Equatable, Sendable {
        public var general: Double
        public var generalTitlesOnly: Double
        /// Nil: it names no agent.
        public var suggest: Double?
        /// The start level found on dev; nil with `noStart`.
        public var start: Double?
        /// namesNone, noLevel or fewStarts.
        public var noStart: DecisionMeasure.NoStart?
        /// Where starts are counted for the record: `start`, else the lowest level the rules try (0.95).
        public var level: Double
        /// Dev's starts at `level`, What goes here form.
        public var starts: [Start]
        /// The bench's scoring of dev, What goes here form.
        public var score: RouterBench.Score
        /// Binders right by the first pick with titles alone.
        public var titlesBinderOK: Int
    }

    /// What test, asked once, does to dev's start level.
    public struct Test: Equatable, Sendable {
        /// Dev's start level, when test kept it.
        public var start: Double?
        /// testWrong or testFew when test took dev's level away; else dev's own reason, if any.
        public var noStart: DecisionMeasure.NoStart?
        /// This test took a start level away, which then holds for the model (rule 5).
        public var tookStart: Bool
        /// Where its starts were counted: dev's level.
        public var level: Double
        public var starts: [Start]
        /// The bench's scoring of test: the score shown.
        public var score: RouterBench.Score
    }

    /// A whole measure.
    public struct Outcome: Equatable, Sendable {
        public var dev: Dev
        public var test: Test
        /// The bands kept: dev's General thresholds and suggest level, and its start level if test kept it and nothing else
        /// takes it away.
        public var bands: RouterBands
        public var noStart: DecisionMeasure.NoStart?
        /// testWrong or testFew when this measure's test took the start level away: the verdict to keep for the model.
        public var verdict: DecisionMeasure.NoStart?
    }

    // MARK: The rules

    /// Rules 1 to 3, on the dev split's answers in both forms (the titles-alone run may reuse the agent answers).
    public static func dev(both: [RouterBench.Answer], titles: [RouterBench.Answer], library: RouterBench.Library) -> Dev {
        let reading = Reading(library)
        let general = generalThreshold(both, reading), generalTitlesOnly = generalThreshold(titles, reading)
        let suggest = suggestLevel(both, reading, general: general)
        var start: Double?
        var noStart: DecisionMeasure.NoStart? = suggest == nil ? .namesNone : .noLevel
        if let suggest {
            for bar in startBars {
                let inBoth = starts(both, reading, general: general, suggest: suggest, bar: bar)
                let inTitles = starts(titles, reading, general: generalTitlesOnly, suggest: suggest, bar: bar)
                guard (inBoth.starts + inTitles.starts).allSatisfy(\.right), inBoth.near.isEmpty, inTitles.near.isEmpty else { continue }
                if inBoth.starts.count >= leastDevStarts {
                    start = bar
                    noStart = nil
                } else {
                    noStart = .fewStarts
                }
                break
            }
        }
        let level = start ?? startBars[0]
        return Dev(general: general, generalTitlesOnly: generalTitlesOnly, suggest: suggest, start: start, noStart: noStart, level: level,
                   starts: starts(both, reading, general: general, suggest: suggest ?? RouterBands.never, bar: level).starts,
                   score: RouterBench.score(both, library: library), titlesBinderOK: RouterBench.score(titles, library: library).binderOK)
    }

    /// Rule 4: the test split, asked once, at dev's bands.
    public static func test(_ answers: [RouterBench.Answer], dev: Dev, library: RouterBench.Library) -> Test {
        let found = starts(answers, Reading(library), general: dev.general, suggest: dev.suggest ?? RouterBands.never, bar: dev.level).starts
        var test = Test(start: dev.start, noStart: dev.noStart, tookStart: false, level: dev.level, starts: found,
                        score: RouterBench.score(answers, library: library))
        guard dev.start != nil else { return test }
        if !found.allSatisfy(\.right) {
            (test.start, test.noStart, test.tookStart) = (nil, .testWrong, true)
        } else if found.count < leastTestStarts || dev.starts.count + found.count < leastStarts {
            (test.start, test.noStart, test.tookStart) = (nil, .testFew, true)
        }
        return test
    }

    /// The whole measure: dev, test once, then rules 5 and 6. `testBefore`: a test verdict already holds for the model.
    /// The answers' `answeredBy` are a server's: more than one model among them leaves no start level.
    public static func measure(devBoth: [RouterBench.Answer], devTitles: [RouterBench.Answer], test answers: [RouterBench.Answer],
                               library: RouterBench.Library, testBefore: Bool = false) -> Outcome {
        let dev = dev(both: devBoth, titles: devTitles, library: library)
        let test = test(answers, dev: dev, library: library)
        let models = Set((devBoth + devTitles + answers).map(\.answeredBy))
        var noStart = test.noStart
        if models.count > 1 {
            noStart = .severalModels
        } else if noStart == nil, testBefore {
            noStart = .testBefore
        }
        let bands = RouterBands(start: noStart == nil ? test.start : nil, suggest: dev.suggest ?? RouterBands.never, generalBelow: dev.general,
                                generalBelowTitlesOnly: dev.generalTitlesOnly)
        return Outcome(dev: dev, test: test, bands: bands, noStart: noStart, verdict: test.tookStart ? test.noStart : nil)
    }

    /// Rule 1's choice on a curve of binders right over `generalGrid`: the highest run of thresholds that reach the most,
    /// and its middle, the lower of the two middles for a run of even length.
    public static func general(curve: [Int]) -> Double {
        guard let top = curve.max() else { return 0 }
        var runs: [(first: Int, last: Int)] = []
        var first: Int?
        for (index, count) in curve.enumerated() {
            if count == top {
                if first == nil { first = index }
            } else if let open = first {
                runs.append((open, index - 1))
                first = nil
            }
        }
        if let open = first { runs.append((open, curve.count - 1)) }
        guard let run = runs.last else { return 0 }
        return Double(run.first + (run.last - run.first) / 2) / 100
    }

    /// The app's pick for an item at General threshold `general` and suggest level `suggest`.
    public static func pick(_ answer: RouterBench.Answer, library: RouterBench.Library, general: Double, suggest: Double) -> Pick {
        Reading(library).pick(answer, general: general, suggest: suggest)
    }

    // MARK: Inside the rules

    static func generalThreshold(_ answers: [RouterBench.Answer], _ reading: Reading) -> Double {
        general(curve: generalGrid.map { t in answers.filter { reading.pick($0, general: t, suggest: RouterBands.never).binderRight }.count })
    }

    static func suggestLevel(_ answers: [RouterBench.Answer], _ reading: Reading, general: Double) -> Double? {
        for level in suggestGrid {
            let named = answers.map { reading.pick($0, general: general, suggest: level) }.filter { $0.agent != nil }
            let right = named.filter(\.agentRight).count
            if named.count >= leastNamed, right * 10 >= 7 * named.count { return level }
        }
        return nil
    }

    /// The app's picks at `bar` or above, and the wrong ones from `bar` − 0.005 to just under it.
    static func starts(_ answers: [RouterBench.Answer], _ reading: Reading, general: Double, suggest: Double, bar: Double) -> (starts: [Start], near: [Start]) {
        var starts: [Start] = [], near: [Start] = []
        for answer in answers {
            let pick = reading.pick(answer, general: general, suggest: suggest)
            guard let agent = pick.agent else { continue }
            let start = Start(id: answer.id, agent: agent, p: pick.p, right: pick.agentRight)
            if pick.p >= bar {
                starts.append(start)
            } else if pick.p >= bar - nearMargin, !pick.agentRight {
                near.append(start)
            }
        }
        return (starts, near)
    }

    /// The library read once: the binders' ids for RouterRules, and each binder's takers.
    struct Reading {
        let library: RouterBench.Library
        let ids: [UUID]
        let names: [UUID: String]
        let takers: [String: [String]]

        init(_ library: RouterBench.Library) {
            self.library = library
            ids = library.binders.map { RouterBench.id(binder: $0) }
            names = Dictionary(zip(ids, library.binders).map { ($0, $1) }, uniquingKeysWith: { first, _ in first })
            takers = Dictionary((library.binders + [library.general]).map { ($0, library.takers($0)) }, uniquingKeysWith: { first, _ in first })
        }

        /// RouterRules' binder and agent with no name said, as the app reads a card, at these bands.
        func pick(_ answer: RouterBench.Answer, general: Double, suggest: Double) -> Pick {
            let bands = RouterBands(start: nil, suggest: suggest, generalBelow: general, generalBelowTitlesOnly: general)
            let sure = RouterRules.modelBinder(Array(zip(ids, answer.binders)).map { (id: $0.0, p: $0.1) }, form: .both, bands: bands)
            let binder = sure.flatMap { names[$0.id] } ?? library.general
            let options = zip(library.agents, answer.agents).map { RankedOption(key: $0.0, p: $0.1) }
            let outcome = RouterRules.agent(kind: .todo, named: [], model: options, bands: bands, takers: takers[binder] ?? library.takers(binder),
                                            llmAgent: nil, llmFits: nil)
            let top = RouterMath.argmax(answer.agents).map { answer.agents[$0] } ?? 0
            let agent = outcome.pick?.name
            return Pick(binder: binder, agent: agent, p: top, binderRight: answer.acceptableBinders.contains(binder),
                        agentRight: answer.acceptableAgents.contains(agent ?? RouterQuestions.nobody))
        }
    }
}

// MARK: - Auto's level

extension MeasureRules {
    /// Why a measure gives a model no Auto level, so that Auto hands nothing over with it.
    public enum NoAuto: String, Codable, Sendable, CaseIterable {
        /// It names no agent (no suggest level).
        case namesNone
        /// On dev it would hand an agent that drafts first fewer than `autoLeast` things on its own judgment, at every level.
        case devFew
        /// At every level with enough of them on dev, fewer than 4 in 5 went to the right agent, too many went to an agent
        /// where the answer was nobody, or the ones it was least sure of were no better.
        case devShare
        /// At the level dev found, the cards kept for scoring had fewer than 4 in 5 right, too many where the answer was
        /// nobody, or none at all; or, with them counted, no level dev holds at kept its least-sure band at 4 in 5.
        case testShare
        /// An earlier measure's test took Auto away for this model, and that holds.
        case testBefore
    }

    /// A level needs at least this many of the model's own picks on dev at the level or above, at least `autoShare` of them
    /// right.
    public static let autoLeast = 5
    public static let autoShare = 0.8
    /// At most this share of a split's to-dos and ideas whose answer was nobody may go to an agent at the level.
    public static let autoFalse = 0.1
    /// The levels tried: the suggest band, then each `autoStep` above it, up to `autoTop`. A level's least-sure band is
    /// from it to under the next.
    public static let autoStep = 0.10
    public static let autoTop = 0.90
    /// A least-sure band is held to `autoShare` only with at least this many picks in it, dev and test together.
    public static let autoBandLeast = 3

    /// One thing Auto would hand over of the bench's cards.
    public struct AutoPick: Equatable, Sendable {
        public var id: String
        public var agent: String
        /// The model's probability for that agent.
        public var p: Double
        /// It's one of the item's agents.
        public var right: Bool
        /// Not right, and the bench's answer was nobody: it was no agent's work.
        public var falseAssignment: Bool
        /// A name said in it decided, whatever the model's top pick: counted apart, the same at every level.
        public var named: Bool
    }

    /// What the Auto rule found for a model.
    public struct AutoOutcome: Equatable, Sendable {
        /// Auto's level; nil with `noAuto`.
        public var level: Double?
        public var noAuto: NoAuto?
        /// The level the counts were taken at: Auto's level, the one that failed on test, or the lowest tried; nil when
        /// the model names no agent.
        public var countedAt: Double?
        public var dev: DecisionMeasure.AutoCounts
        public var test: DecisionMeasure.AutoCounts
        /// The level dev alone gave, before test's picks were counted in the least-sure band.
        public var devLevel: Double?
        /// This measure's test raised the level above dev's own (`raisedTo`), or took Auto away (`tookAway`): what the
        /// model's test verdict keeps of it.
        public var raisedTo: Double?
        public var tookAway: NoAuto?

        /// The verdict to keep for the model when this measure's test raised Auto's level or took it away; it says
        /// nothing about starting (MeasureRules.Outcome.testVerdict(for:at:auto:) gives one that says both).
        public func testVerdict(for identity: DecisionIdentity, at: Date) -> DecisionMeasure.TestVerdict? {
            guard raisedTo != nil || tookAway != nil else { return nil }
            return DecisionMeasure.TestVerdict(key: identity.key, server: identity.server, at: at, level: nil, noStart: nil, autoLevel: raisedTo,
                                               noAuto: tookAway)
        }
    }

    /// Auto's level for a model, from its own measure. Counted: what Auto would hand over on its own judgment (to-dos and
    /// ideas; no name said, as a name decides by itself; the app's pick at the level or more; never an agent only
    /// mentioned, nor one beside another agent's name heard loosely), and only to an agent that drafts first
    /// (`RouterBench.Library.draftsFirst`): `autoPicks`. The level is the lowest of the suggest band and each `autoStep`
    /// above it, up to `autoTop`, at which
    /// (a) dev (What goes here form) has at least `autoLeast` such picks at the level or more, right at least `autoShare`
    ///     of the time, with false assignments at most `autoFalse` of dev's to-dos and ideas whose answer was nobody;
    /// (b) the picks it is least sure of, from the level to under the next step, dev and test together, are right at least
    ///     `autoShare` of the time when there are at least `autoBandLeast` of them;
    /// then (c) test, once, at that level: at least one pick, right at least `autoShare` of the time, the same cap on false
    /// assignments, or no level (`testShare`). Test can raise the level (b) or take it away (c), never lower it or give one
    /// dev doesn't: the search starts where dev alone, (b) on its own picks, holds. A verdict that did either holds for the
    /// model's key (`verdictBefore`, from DecisionMeasure.TestVerdict.autoBefore): no lower level than its own, or none
    /// (`testBefore`). On lane R1's Swift runs of Tev1 0.8B bf16 it gives 0.60: dev 23 picks, 19 right, 1 false; test 31,
    /// all right; named dev 4 and test 6, all right (lane Y1's DESIGN.md 3.1 and 10.2).
    public static func auto(dev: [RouterBench.Answer], test: [RouterBench.Answer], bands: RouterBands, library: RouterBench.Library,
                            verdictBefore: (level: Double?, noAuto: NoAuto?)? = nil) -> AutoOutcome {
        let devPicks = autoPicks(dev, library: library, bands: bands), testPicks = autoPicks(test, library: library, bands: bands)
        let nobodyDev = nobodyCount(dev), nobodyTest = nobodyCount(test)
        func counts(_ picks: [AutoPick], at level: Double?) -> DecisionMeasure.AutoCounts {
            let own = level.map { level in picks.filter { !$0.named && $0.p >= level } } ?? [], named = picks.filter(\.named)
            return DecisionMeasure.AutoCounts(picks: own.count, right: own.filter(\.right).count, falseAssignments: own.filter(\.falseAssignment).count,
                                              named: named.count, namedRight: named.filter(\.right).count)
        }
        func outcome(_ level: Double?, _ why: NoAuto?, at: Double?, devLevel: Double? = nil, raisedTo: Double? = nil,
                     tookAway: NoAuto? = nil) -> AutoOutcome {
            AutoOutcome(level: level, noAuto: why, countedAt: at, dev: counts(devPicks, at: at), test: counts(testPicks, at: at), devLevel: devLevel,
                        raisedTo: raisedTo, tookAway: tookAway)
        }
        guard bands.suggest < RouterBands.never else { return outcome(nil, .namesNone, at: nil) }
        // The levels, in hundredths: from the suggest band (no lower than a verdict's level) up to autoTop.
        let from = (bands.suggest * 100).rounded(), step = (autoStep * 100).rounded(), top = (autoTop * 100).rounded()
        let floor = verdictBefore?.level.map { ($0 * 100).rounded() } ?? from
        let levels = stride(from: from, through: top, by: step).filter { $0 >= floor }
        guard let lowest = levels.first else { return outcome(nil, .devShare, at: nil) }
        func own(_ picks: [AutoPick], from hundredths: Double, band: Bool = false) -> [AutoPick] {
            let low = hundredths / 100, high = band ? (hundredths + step) / 100 : .infinity
            return picks.filter { !$0.named && $0.p >= low && $0.p < high }
        }
        func holds(_ picks: [AutoPick], nobody: Int, least: Int) -> Bool {
            let right = picks.filter(\.right).count, wrongNobody = picks.filter(\.falseAssignment).count
            return picks.count >= least && Double(right) >= autoShare * Double(picks.count) - 1e-9
                && Double(wrongNobody) <= autoFalse * Double(nobody) + 1e-9
        }
        func bandHolds(_ picks: [AutoPick]) -> Bool {
            picks.count < autoBandLeast || Double(picks.filter(\.right).count) >= autoShare * Double(picks.count) - 1e-9
        }
        // (a), and (b) on dev's own picks: where dev alone puts it.
        guard let devLevel = levels.first(where: { holds(own(devPicks, from: $0), nobody: nobodyDev, least: autoLeast)
            && bandHolds(own(devPicks, from: $0, band: true)) }) else {
            let few = own(devPicks, from: lowest).count < autoLeast
            return outcome(nil, few ? .devFew : .devShare, at: lowest / 100)
        }
        // (b) with test's picks too, from there up: test may raise it.
        guard let level = levels.first(where: { $0 >= devLevel && holds(own(devPicks, from: $0), nobody: nobodyDev, least: autoLeast)
            && bandHolds(own(devPicks + testPicks, from: $0, band: true)) }) else {
            return outcome(nil, .testShare, at: devLevel / 100, devLevel: devLevel / 100, tookAway: verdictBefore?.noAuto == nil ? .testShare : nil)
        }
        // (c) test, once, at that level.
        guard holds(own(testPicks, from: level), nobody: nobodyTest, least: 1) else {
            return outcome(nil, .testShare, at: level / 100, devLevel: devLevel / 100, tookAway: verdictBefore?.noAuto == nil ? .testShare : nil)
        }
        if verdictBefore?.noAuto != nil { return outcome(nil, .testBefore, at: level / 100, devLevel: devLevel / 100) }
        return outcome(level / 100, nil, at: level / 100, devLevel: devLevel / 100, raisedTo: level > devLevel ? level / 100 : nil)
    }

    /// What Auto would hand over of these answers, at the suggest band or above: to-dos and ideas only (`Answer.kind`), to an
    /// agent that drafts first (`Library.draftsFirst`), as the app takes them. A name `NamedAgents.find` finds in what was
    /// said decides (the one that takes the app binder's cards, or the model's top among several: RouterRules.agent);
    /// otherwise the model's pick (RouterRules.agent at these bands), unless another agent's name is heard loosely in it
    /// (NamedAgents.heard) or the pick is only mentioned (NamedAgents.mentioned and not .find, on the words as heard).
    public static func autoPicks(_ answers: [RouterBench.Answer], library: RouterBench.Library, bands: RouterBands) -> [AutoPick] {
        let reading = Reading(library)
        let agents = library.agents.filter { $0 != RouterQuestions.nobody }
        return answers.compactMap { answer in
            guard answer.kind == MomentKind.todo.rawValue || answer.kind == MomentKind.idea.rawValue else { return nil }
            let text = answer.text ?? ""
            let sure = RouterRules.modelBinder(Array(zip(reading.ids, answer.binders)).map { (id: $0.0, p: $0.1) }, form: .both, bands: bands)
            let binder = sure.flatMap { reading.names[$0.id] } ?? library.general
            let options = zip(library.agents, answer.agents).map { RankedOption(key: $0.0, p: $0.1) }
            let named = NamedAgents.find(in: [text], agents: agents)
            let picked = RouterRules.agent(kind: .todo, named: named, model: options, bands: bands, takers: reading.takers[binder] ?? library.takers(binder),
                                           llmAgent: nil, llmFits: nil)
            guard let agent = picked.pick?.name, library.draftsFirst.contains(agent) else { return nil }
            if named.isEmpty {
                // Another agent's name heard loosely, or this one only mentioned in the words as heard: Give to, not Auto.
                guard NamedAgents.heard(in: [text], agents: agents).allSatisfy({ $0.agent == agent }) else { return nil }
                let asHeard = NamedAgents.asHeard(text, agents: agents)
                if !NamedAgents.mentioned(in: [asHeard], agents: [agent]).isEmpty, NamedAgents.find(in: [asHeard], agents: [agent]).isEmpty {
                    return nil
                }
            }
            let right = answer.acceptableAgents.contains(agent)
            return AutoPick(id: answer.id, agent: agent, p: options.first { $0.key == agent }?.p ?? 0, right: right,
                            falseAssignment: !right && answer.expectedAgent == RouterQuestions.nobody, named: !named.isEmpty)
        }
    }

    /// A split's to-dos and ideas whose answer was nobody: what the cap on false assignments is a share of.
    static func nobodyCount(_ answers: [RouterBench.Answer]) -> Int {
        answers.filter { ($0.kind == MomentKind.todo.rawValue || $0.kind == MomentKind.idea.rawValue) && $0.expectedAgent == RouterQuestions.nobody }.count
    }
}

// MARK: - The record of a measure

extension MeasureRules.Outcome {
    /// The verdict to keep for the model when this measure's test took starting away.
    public func testVerdict(for identity: DecisionIdentity, at: Date) -> DecisionMeasure.TestVerdict? {
        verdict.map { DecisionMeasure.TestVerdict(key: identity.key, server: identity.server, at: at, level: test.level, noStart: $0) }
    }

    /// The one verdict to keep for the model when this measure's test took starting away, raised Auto's level, or took
    /// Auto away (`auto`, MeasureRules.auto on the same answers): both parts in one.
    public func testVerdict(for identity: DecisionIdentity, at: Date, auto: MeasureRules.AutoOutcome?) -> DecisionMeasure.TestVerdict? {
        let start = testVerdict(for: identity, at: at), forAuto = auto?.testVerdict(for: identity, at: at)
        guard var verdict = start ?? forAuto else { return nil }
        verdict.autoLevel = forAuto?.autoLevel
        verdict.noAuto = forAuto?.noAuto
        return verdict
    }
}

extension DecisionMeasure {
    /// A measure's record: its outcome, the model it was of, and the load it was made on; with `auto`, Auto's level, or why
    /// there's none, and what it would have handed over. Without it, a record from before Auto.
    public init(identity: DecisionIdentity, outcome: MeasureRules.Outcome, at: Date, build: String?, mac: String?, golden: [[Double]]?,
                letterShare: [Double]?, answeredBy: [String]? = nil, ms: Timing? = nil, auto: MeasureRules.AutoOutcome? = nil) {
        let dev = outcome.dev, test = outcome.test
        var bands = Bands(outcome.bands)
        bands.auto = auto?.level
        self.init(key: identity.key, fingerprint: identity.fingerprint, reader: identity.reader, server: identity.server, at: at, build: build,
                  mac: mac, golden: golden, letterShare: letterShare, bands: bands, noStart: outcome.noStart,
                  dev: Numbers(items: dev.score.items, binderOK: dev.score.binderOK, agentOK: dev.score.agentOK, score: dev.score.score,
                               starts: dev.starts.count, wrongStarts: dev.starts.filter { !$0.right }.count, titlesBinderOK: dev.titlesBinderOK,
                               level: dev.level),
                  test: Numbers(items: test.score.items, binderOK: test.score.binderOK, agentOK: test.score.agentOK, score: test.score.score,
                                starts: test.starts.count, wrongStarts: test.starts.filter { !$0.right }.count, level: test.level),
                  answeredBy: answeredBy, ms: ms, noAuto: auto?.noAuto, auto: auto.map { Auto(dev: $0.dev, test: $0.test) })
    }
}
