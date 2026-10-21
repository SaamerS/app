import CryptoKit
import Darwin
import Foundation
import MLX
import BindersKit

// The decision model's two dev tools. They need a model folder, so they aren't part of the normal self-test run; time
// things in a Release build. Both run the app's own code, through the setting: the folder is cloned into the throwaway
// data folder's Models (as tev1-0.8b-mlx-bf16, so the choice is Tev1 0.8B itself, for that folder; beside it, as a folder
// chosen, for any other), Settings' decisionModel is set, DecisionModels chooses it, and its backend (MLXDecisionBackend)
// answers, with the bands DecisionModels resolves for its fingerprint.
//
//     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-router-model <model folder> <fixtures.json> \
//         [--goldens <file>] [--write-goldens <file>] [--reference <python ref json>] [--rounds 3] [--pieces 256] \
//         [--tolerance 0.1] [--truncated] [--watchdog] [--lifecycle [<other conversion's folder>]] \
//         [--concurrent-chat <chat model folder>] [--out <json>] -notesShowMarkdown NO
//     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-router-bench <model folder> [<bench folder>] \
//         [--split test|dev] [--desc both|titles] [--pieces 256] [--against <measure fixture.json>] [--out <jsonl>] -notesShowMarkdown NO
//     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-router-bench <model folder> [<bench folder>] --measure \
//         [--against <measure fixture.json>] -notesShowMarkdown NO      (the button's measure, kept in this data folder)
//     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-router-bench <model folder> <bench folder> \
//         --dump-questions <file> [--full <id>,<id>] -notesShowMarkdown NO      (writes the questions' hashes; loads nothing)

/// One fixture prompt: what the case asks, the prompt Python built, and what Python found.
private struct FixturePrompt {
    let name: String
    let devItem: Bool
    let kind: String
    let question: DecisionQuestion
    let prompt: String
    let tokenIDs: [Int]?
    let probs: [Double]
    var reference: [Double]?
}

/// The Swift goldens: this runtime's own ids and logits for every fixture prompt, and the first warm-up's probabilities.
/// `backend` is the folder's name and the pieces ("tev1-0.8b-mlx-bf16/256"), as lane R1 wrote it.
private struct RouterGoldens: Codable {
    struct Prompt: Codable, Equatable {
        let name: String
        /// The prompt's token ids, by their count and a SHA-256 of them as comma-separated decimals.
        let tokens: Int
        let idsSHA256: String
        /// The logits' float32 bit patterns, so they're held exactly.
        let logitBits: [UInt32]
        enum CodingKeys: String, CodingKey { case name, tokens, idsSHA256 = "ids_sha256", logitBits = "logit_bits" }

        init(name: String, ids: [Int], logits: [Double]) {
            self.name = name
            tokens = ids.count
            idsSHA256 = SHA256.hash(data: Data(ids.map(String.init).joined(separator: ",").utf8)).map { String(format: "%02x", $0) }.joined()
            logitBits = logits.map { Float($0).bitPattern }
        }
    }

    var schema = "binders-router-goldens/1"
    let backend: String
    let written: String
    let mac: String
    let warmUp: [Double]
    let prompts: [Prompt]
    enum CodingKeys: String, CodingKey { case schema, backend, written, mac, prompts, warmUp = "warm_up" }
}

/// The identities of the three Tev1 0.8B conversions lane R1 measured on, by their folders' names: only bf16 has bands
/// built in.
private let knownConversions: [String: (fingerprint: String, bands: String)] = [
    "tev1-0.8b-mlx-bf16": ("mlx1-b73a343455582c89eed2254a", "built-in"),
    "tev1-0.8b-mlx-8bit": ("mlx1-3e64dbd1bfe8abd4c77552bb", "unmeasured"),
    "tev1-0.8b-mlx-4bit": ("mlx1-6797669efe158bc4ff019342", "unmeasured"),
]

extension SelfTest {
    // MARK: --selftest-router-model

    /// Parity with Python, and how fast and how big the decision model is, on one model folder chosen through the
    /// setting: every fixture prompt rebuilt with BindersKit's builder byte for byte, the token ids exactly, the picks
    /// except near-ties, the probabilities within the parity bar (largest 0.1, median 0.01: no second implementation
    /// reaches the brief's 0.01), the backend's own checks after load, its identity and bands, its three warm-ups and the
    /// letters' share at each, held to the goldens of its bands. With `--goldens`, this runtime's own goldens held exactly;
    /// `--write-goldens` writes them. `--truncated` checks that a cut folder is refused before MLX reads it, the process
    /// still running; `--watchdog`, that a pass past the watchdog fails the backend; `--lifecycle`, a switch during a load
    /// and during a pass, a folder replaced while loaded, and a quit during a measure.
    @MainActor
    static func routerModelSelfTest(_ args: [String]) async -> Int32 {
        // It chooses a decision model, clones the folder into Models and writes its fingerprint, so only into a throwaway
        // data folder, as --selftest-router does: without BINDERS_DATA_DIR that's your own.
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this tool chooses a decision model and writes measures there")
            return 1
        }
        guard let index = args.firstIndex(of: "--selftest-router-model"), args.indices.contains(index + 2) else {
            print("Usage: --selftest-router-model <model folder> <fixtures.json> [--goldens <file>] [--write-goldens <file>] [--rounds 3] [--lifecycle]")
            return 2
        }
        func value(_ flag: String) -> String? {
            guard let at = args.firstIndex(of: flag), args.indices.contains(at + 1) else { return nil }
            return args[at + 1]
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        let source = URL(fileURLWithPath: args[index + 1], isDirectory: true).standardizedFileURL
        let fixturesURL = URL(fileURLWithPath: args[index + 2])
        let rounds = max(0, Int(value("--rounds") ?? "") ?? 3)
        let piecesValue = Int(value("--pieces") ?? "") ?? MLXDecisionBackend.defaultPieces
        let pieces: Int? = piecesValue > 0 ? piecesValue : nil
        let tolerance = Double(value("--tolerance") ?? "") ?? 0.1
        /// The goldens' name for the backend, lane R1's: the folder's name and the pieces.
        let label = "\(source.lastPathComponent)/\(pieces.map(String.init) ?? "whole")"
        print("ROUTER MODEL: \(source.lastPathComponent), " + (pieces.map { "prompts in pieces of \($0) tokens" } ?? "whole prompts") + ", \(rounds) timing rounds")

        // The fixtures: Python's (dm/router/fixtures.json) or the kit's (Fixtures/router/prompts.json).
        var prompts: [FixturePrompt]
        do {
            prompts = try loadFixturePrompts(fixturesURL)
        } catch {
            print("FAIL: reading \(fixturesURL.path): \(error.localizedDescription)")
            return 1
        }
        print("FIXTURES: \(prompts.count) prompts, \(prompts.filter(\.devItem).count) from dev items")
        let built = prompts.filter { Array(Tev1Prompt.prompt($0.question).utf8) == Array($0.prompt.utf8) }.count
        check(built == prompts.count, "BindersKit's builder rebuilds every fixture prompt byte for byte: \(built) of \(prompts.count)")
        if let path = value("--reference") {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let folders = object?["folders"] as? [String: Any] ?? [:]
                let entry = folders.first { ($0.key as NSString).lastPathComponent == source.lastPathComponent }?.value as? [String: Any]
                var found: [String: [Double]] = [:]
                for row in entry?["prompts"] as? [[String: Any]] ?? [] {
                    if let name = row["case"] as? String, let question = row["question"] as? String, let probs = row["probs"] as? [Double] {
                        found["\(name) \(question)"] = probs
                    }
                }
                for index in prompts.indices { prompts[index].reference = found[prompts[index].name] }
                print("REFERENCE: \(found.count) of Python's prompts on \(source.lastPathComponent)")
            } catch {
                print("FAIL: reading \(path): \(error.localizedDescription)")
                return 1
            }
        }

        // A folder cut short is refused before MLX reads a byte of it, and Binders goes on.
        if args.contains("--truncated") {
            await truncatedFolderCheck(source, pieces: pieces, check: check)
        }

        // The model, chosen as Settings chooses it, and the bands DecisionModels resolves for it.
        MLX.Memory.peakMemory = 0
        let footprintBefore = MLXDecisionBackend.physFootprint()
        guard let chosen = chooseForDevTool(source, pieces: pieces) else {
            print("FAIL: couldn't clone \(source.path) into this data folder's Models and choose it")
            return 1
        }
        let backend = chosen.backend
        print("CHOSEN: \(chosen.choice == .tev1 ? "Tev1 0.8B" : "a folder"), from \(chosen.folder.path)" + (chosen.throughSetting ? "" : ", outside the setting (its pieces)"))
        let resolved = chosen.throughSetting ? await DecisionModels.shared.bands(by: .now + .seconds(120)) : nil
        let identity = chosen.throughSetting ? resolved?.identity : await backend.identity(by: .now + .seconds(120))
        let state = await backend.state()
        check(state.isUsable, "the folder passes the checks before loading, the helper's and the hash included: \(state)")
        print("IDENTITY: \(identity?.fingerprint ?? "unknown") read as \(identity?.reader ?? "unknown"), bands \(resolved?.source.logName ?? "none")")
        if let known = knownConversions[source.lastPathComponent], pieces == MLXDecisionBackend.defaultPieces {
            check(identity?.fingerprint == known.fingerprint && identity?.reader == "tev1.1/256" && resolved?.source.logName == known.bands,
                  "\(source.lastPathComponent) is \(known.fingerprint) read as tev1.1/256, with \(known.bands) bands")
        }
        let report: MLXDecisionBackend.LoadReport
        do {
            report = try await backend.loadNow()
        } catch {
            print("FAIL: the backend didn't load \(chosen.folder.path): \(error.localizedDescription)")
            return 1
        }
        let tev1Read = report.reader.hasPrefix(DecisionReader.tev1.rawValue + ".")
        print("BACKEND: \(label), \(report.modelType), read as \(report.reader)" + (report.rowsAbout.isEmpty ? "" : ", letter rows from \(report.rowsAbout)"))
        for line in report.checks { check(true, "after load: \(line)") }
        if tev1Read { check(report.hiddenStateHook, "the hidden state comes from the model's drafter hook, never the full head") }
        for (number, warm) in report.warmUps.enumerated() {
            print("WARM-UP \(number + 1): " + warm.map { String(format: "%.17g", $0) }.joined(separator: ", "))
        }
        print("LETTER SHARES: " + report.letterShares.map { String(format: "%.6f", $0) }.joined(separator: ", ")
              + (report.letterShares.allSatisfy { $0 > 0.999 } ? " (each over 0.999)" : " (not all over 0.999)"))
        check(report.warmUps.count == 3 && report.letterShares.count == 3 && report.letterShares.allSatisfy { $0 >= MLXDecisionBackend.letterShareFloor },
              "three warm-ups, and at each the offered letters hold at least half of what it would say first")
        if let golden = resolved?.golden {
            let binder = zip(golden.first ?? [], report.warmUps.first ?? []).map { abs($0 - $1) }.max() ?? 1
            check(golden.first?.count == report.warmUps.first?.count && binder <= DecisionBands.goldenTolerance,
                  String(format: "the binder warm-up is within %.3f of its %@ bands' golden: largest difference %.2e", DecisionBands.goldenTolerance,
                         resolved?.source.logName ?? "", binder))
            if resolved?.source == .builtIn {
                let agents = zip(golden.dropFirst(), report.warmUps.dropFirst()).flatMap { kept, now in zip(kept, now).map { abs($0 - $1) } }.max() ?? 1
                check(golden.count == 3 && report.warmUps.count == 3 && agents <= 1e-6,
                      String(format: "the two agent warm-ups are lane R1's dev answers for short-02 and fr-06 within 1e-6: largest difference %.2e", agents))
            }
            let matched = await backend.numbersMatch()
            check(matched, "numbersMatch() through the \(resolved?.source.logName ?? "") bands' goldens, so agents may start")
        } else {
            let differ = await backend.numbersDiffer()
            check(!differ, "this model's bands have no golden (it isn't measured): its numbers never differ, and nothing starts on its own until it's measured")
        }
        let afterLoad = MLX.Memory.activeMemory

        // Every prompt once: ids, logits and probabilities.
        var results: [(ids: [Int], logits: [Double], probs: [Double])] = []
        for prompt in prompts {
            do {
                let result = try await backend.probe(prompt.question)
                results.append((result.ids, result.logits, result.probs))
            } catch {
                print("FAIL: \(prompt.name): \(error.localizedDescription)")
                return 1
            }
        }
        let pairs = Array(zip(prompts, results))
        let withIDs = pairs.filter { $0.0.tokenIDs != nil }
        if !withIDs.isEmpty, tev1Read {
            let equal = withIDs.filter { $0.0.tokenIDs == $0.1.ids }.count
            check(equal == withIDs.count, "the token ids are the fixtures' exactly: \(equal) of \(withIDs.count)")
            for (prompt, result) in withIDs where prompt.tokenIDs != result.ids {
                print("  ids differ: \(prompt.name): \(result.ids.count) against \(prompt.tokenIDs?.count ?? 0)")
            }
        }
        if tev1Read {
            check(pairs.allSatisfy { Array($0.1.ids.prefix(3)) == MLXDecisionBackend.promptStart && Array($0.1.ids.suffix(5)) == MLXDecisionBackend.promptEnd },
                  "every prompt starts and ends with the template's special tokens")
        }
        /// Picks held to `expected`, except near-ties: a top two under 0.01 apart in the fixtures (Python's bf16 numbers, as
        /// `line-separators agent` at 0.0093), in the numbers compared, or in this runtime's own. Two correct runtimes differ
        /// by up to about 0.05 here, so a pick decided by less is a coin toss, not a regression.
        func compare(_ expected: (FixturePrompt) -> [Double]?, label: String) -> (picks: Int, of: Int, largest: Double, worst: String, median: Double, compared: Int) {
            var picks = 0, of = 0, largest = 0.0, worst = ""
            var diffs: [Double] = []
            func gap(_ values: [Double]) -> Double {
                let sorted = values.sorted(by: >)
                return sorted.count < 2 ? 1 : sorted[0] - sorted[1]
            }
            for (prompt, result) in pairs {
                guard let want = expected(prompt), want.count == result.probs.count else { continue }
                let diff = zip(want, result.probs).map { abs($0 - $1) }.max() ?? 0
                diffs.append(diff)
                if diff > largest { largest = diff; worst = prompt.name }
                guard gap(want) >= 0.01, gap(prompt.probs) >= 0.01, gap(result.probs) >= 0.01 else { continue }
                of += 1
                if RouterMath.argmax(want) == RouterMath.argmax(result.probs) {
                    picks += 1
                } else {
                    let mine = RouterMath.argmax(result.probs) ?? 0, theirs = RouterMath.argmax(want) ?? 0
                    print(String(format: "  pick differs from %@: %@: %@ %.4f (gap %.4f) here, %@ %.4f (gap %.4f) there", label, prompt.name,
                                 prompt.question.options[mine].key, result.probs[mine], gap(result.probs), prompt.question.options[theirs].key,
                                 want[theirs], gap(want)))
                }
            }
            return (picks, of, largest, worst, percentile(diffs, 0.5), diffs.count)
        }
        let quantized = !source.lastPathComponent.hasSuffix("bf16")
        let fixtures = compare({ $0.probs }, label: "the bf16 fixtures")
        let fixtureLine = String(format: "against Python's bf16 fixtures: the same pick on %d of %d (near-ties aside), largest probability difference %.4f (%@), median %.4f",
                                 fixtures.picks, fixtures.of, fixtures.largest, fixtures.worst, fixtures.median)
        if quantized, prompts.contains(where: { $0.reference != nil }) {
            print("INFO: \(fixtureLine)")
            let python = compare({ $0.reference }, label: "Python on this folder")
            check(python.compared == prompts.count, "Python's numbers on this folder cover every prompt: \(python.compared) of \(prompts.count)")
            check(python.picks == python.of, "the same pick as Python on this folder on \(python.picks) of \(python.of), near-ties aside")
            check(python.largest <= tolerance && python.median <= 0.01,
                  String(format: "within the parity bar of Python on this folder: largest %.4f (%@, bar %.2f), median %.4f (bar 0.01)",
                         python.largest, python.worst, tolerance, python.median))
        } else if quantized {
            print("INFO: \(fixtureLine) (another conversion, so not held to bf16's)")
        } else {
            check(fixtures.picks == fixtures.of, "the same pick as the fixtures on \(fixtures.picks) of \(fixtures.of), near-ties aside")
            check(fixtures.largest <= tolerance && fixtures.median <= 0.01,
                  String(format: "within the parity bar: largest probability difference %.4f (%@, bar %.2f), median %.4f (bar 0.01)",
                         fixtures.largest, fixtures.worst, tolerance, fixtures.median))
        }

        // This runtime's own goldens, held exactly.
        let goldens = RouterGoldens(backend: label, written: ISO8601DateFormatter().string(from: Date()), mac: Self.macModel(),
                                    warmUp: report.warmUps.first ?? [], prompts: pairs.map { prompt, result in
                                        RouterGoldens.Prompt(name: prompt.name, ids: result.ids, logits: result.logits)
                                    })
        if let path = value("--goldens") {
            do {
                let held = try JSONDecoder().decode(RouterGoldens.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                let byName = Dictionary(held.prompts.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                let same = goldens.prompts.filter { byName[$0.name] == $0 }.count
                check(held.backend == label, "the goldens are for this backend: \(held.backend)")
                check(same == goldens.prompts.count, "the logits equal the Swift goldens exactly on \(same) of \(goldens.prompts.count)")
                let first = report.warmUps.first ?? []
                let warm = zip(held.warmUp, first).map { abs($0 - $1) }.max() ?? 1
                check(held.warmUp.count == first.count && warm <= DecisionBands.goldenTolerance,
                      String(format: "the first warm-up is within %.3f of the goldens': %.2e", DecisionBands.goldenTolerance, warm))
            } catch {
                check(false, "reading the goldens at \(path): \(error.localizedDescription)")
            }
        }
        if let path = value("--write-goldens") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do {
                try encoder.encode(goldens).write(to: URL(fileURLWithPath: path))
                print("WROTE GOLDENS: \(path)")
            } catch {
                check(false, "writing the goldens: \(error.localizedDescription)")
            }
        }

        // Warm timing: the dev prompts, `rounds` times, a whole decision each, and a card as its two questions.
        MLX.Memory.peakMemory = 0
        var perQuestion: [String: [Double]] = [:]
        var perCard: [Double] = []
        for _ in 0..<rounds {
            var binderMs: Double?
            for prompt in prompts where prompt.devItem {
                guard let result = try? await backend.probe(prompt.question) else { continue }
                perQuestion[prompt.kind, default: []].append(result.ms)
                if prompt.kind == "binder" {
                    binderMs = result.ms
                } else if let binder = binderMs {
                    perCard.append(binder + result.ms)
                    binderMs = nil
                }
            }
        }
        func stats(_ values: [Double]) -> String {
            String(format: "p50 %.1f, p95 %.1f ms (n %d)", percentile(values, 0.5), percentile(values, 0.95), values.count)
        }
        print(String(format: "TIME: load %.0f ms, three warm-ups %.0f ms", report.loadMs, report.warmUpMs))
        for kind in ["binder", "agent"] where perQuestion[kind] != nil { print("TIME \(kind): \(stats(perQuestion[kind] ?? []))") }
        if !perCard.isEmpty { print("TIME a card (both questions): \(stats(perCard))") }
        let warmFootprint = MLXDecisionBackend.physFootprint()
        print(String(format: "MEMORY: MLX active after load %.0f MiB, peak while deciding %.0f MiB, phys_footprint before %.0f MiB, warm %.0f MiB",
                     Double(afterLoad) / 1_048_576, Double(MLX.Memory.peakMemory) / 1_048_576, Double(footprintBefore) / 1_048_576,
                     Double(warmFootprint) / 1_048_576))

        // A card while the chat model writes, in the same process.
        if let chat = value("--concurrent-chat") {
            await concurrentChatCheck(chatFolder: URL(fileURLWithPath: chat, isDirectory: true), backend: backend, prompts: prompts)
        }

        // The watchdog, with its 10 seconds cut to a millisecond on a backend of its own: the first pass outlives it, so the
        // backend fails for the launch, and the next card doesn't ask.
        if args.contains("--watchdog") {
            let impatient = MLXDecisionBackend(folder: chosen.folder, kind: chosen.choice == .tev1 ? .tev1 : .folder, pieces: pieces, watchdog: 0.001,
                                               marker: AppPaths.support.appendingPathComponent("router-running-watchdog"))
            _ = try? await impatient.loadNow()
            _ = try? await impatient.decide([prompts[0].question], by: .now + .seconds(30))
            let failed = await impatient.state()
            check({ if case .failed(let why) = failed { return why.hasPrefix("a decision took more than") } else { return false } }(),
                  "a pass that outlives the watchdog fails the backend for the launch: \(failed)")
            do {
                _ = try await impatient.decide([prompts[0].question], by: .now + .seconds(30))
                check(false, "and the next card doesn't ask")
            } catch {
                check(true, "and the next card doesn't ask: \(error.localizedDescription)")
            }
            await impatient.unload()
        }

        // The checks that need a container to land, through DecisionModels: last, as the quit retires the model.
        if let at = args.firstIndex(of: "--lifecycle") {
            let given = args.indices.contains(at + 1) && !args[at + 1].hasPrefix("-") ? URL(fileURLWithPath: args[at + 1], isDirectory: true) : nil
            let sibling = source.deletingLastPathComponent().appendingPathComponent("tev1-0.8b-mlx-8bit", isDirectory: true)
            let other = given ?? (source.lastPathComponent != sibling.lastPathComponent && MLXModels.isModel(sibling) ? sibling : nil)
            if chosen.throughSetting {
                await lifecycleChecks(chosen, other: other, prompts: prompts.map(\.question), check: check)
            } else {
                print("INFO: --lifecycle goes through the setting, which reads 256-token pieces only")
            }
        }

        await backend.unload()
        try? await Task.sleep(for: .seconds(3))
        print(String(format: "MEMORY: phys_footprint 3 s after letting it go %.0f MiB", Double(MLXDecisionBackend.physFootprint()) / 1_048_576))
        if let out = value("--out") {
            let rows: [[String: Any]] = pairs.map { prompt, result in
                ["name": prompt.name, "ids_equal": prompt.tokenIDs.map { $0 == result.ids } ?? NSNull(), "logits": result.logits, "probs": result.probs,
                 "fixture_probs": prompt.probs, "reference_probs": prompt.reference ?? []]
            }
            let summary: [String: Any] = ["folder": source.path, "backend": label, "identity": identity?.key ?? NSNull(), "rows": rows,
                                          "warm_ups": report.warmUps, "letter_shares": report.letterShares,
                                          "load_ms": report.loadMs, "warm_ups_ms": report.warmUpMs,
                                          "ms": ["binder": perQuestion["binder"] ?? [], "agent": perQuestion["agent"] ?? [], "card": perCard]]
            if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: out))
                print("WROTE \(out)")
            }
        }
        print(failures == 0 ? "ROUTER_MODEL_OK" : "ROUTER_MODEL_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// A dev tool's model folder chosen as Settings would choose it: cloned (no space) into this throwaway data folder's
    /// Models, as tev1-0.8b-mlx-bf16 for a folder of that name, so the choice is Tev1 0.8B itself with lane R1's marker,
    /// else under its own name as a folder chosen; decisionModel set, DecisionModels choosing it, and its backend. With
    /// pieces other than the reader's 256 (the dev tools' experiments), a backend of its own on the clone, outside the
    /// setting, as no bands were measured with those.
    @MainActor
    private static func chooseForDevTool(_ source: URL, pieces: Int?) -> (choice: DecisionChoice, folder: URL, backend: MLXDecisionBackend, throughSetting: Bool)? {
        let isTev1 = source.lastPathComponent == MLXDecisionBackend.tev1FolderName
        let clone = isTev1 ? MLXDecisionBackend.tev1Folder : AppPaths.support.appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent, isDirectory: true)
        guard cloneModel(source, to: clone) else { return nil }
        let choice: DecisionChoice = isTev1 ? .tev1 : .folder(clone.path)
        guard pieces == MLXDecisionBackend.defaultPieces else {
            let marker = AppPaths.support.appendingPathComponent("router-running-pieces")
            return (choice, clone, MLXDecisionBackend(folder: clone, kind: isTev1 ? .tev1 : .folder, pieces: pieces, marker: marker), false)
        }
        AppSettings.shared.decisionModel = choice.stored
        DecisionModels.shared.choose(choice)
        guard let backend = DecisionModels.shared.backend as? MLXDecisionBackend else { return nil }
        return (choice, clone, backend, true)
    }

    /// A model folder's top-level files cloned into `clone`, made anew: a clone costs no space, and the original stays as
    /// it was. A file that can't be cloned is copied.
    static func cloneModel(_ source: URL, to clone: URL) -> Bool {
        let manager = FileManager.default
        try? manager.removeItem(at: clone)
        guard (try? manager.createDirectory(at: clone, withIntermediateDirectories: true)) != nil,
              let names = try? manager.contentsOfDirectory(atPath: source.path) else { return false }
        for name in names where !name.hasPrefix(".") {
            let from = source.appendingPathComponent(name), to = clone.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: from.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            if clonefile(from.path, to.path, 0) != 0 {
                guard (try? manager.copyItem(at: from, to: to)) != nil else { return false }
            }
        }
        return true
    }

    /// The fixture prompts, from Python's fixtures (`binders-router-fixtures/1`: each item's state, prompt and token ids,
    /// with the options asked) or the kit's (`binders-kit-router-fixture/1`: the library, and each case's state and
    /// prompt), each question built with BindersKit's builder.
    private static func loadFixturePrompts(_ url: URL) throws -> [FixturePrompt] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        let schema = object["schema"] as? String ?? ""
        var found: [FixturePrompt] = []
        if schema.hasPrefix("binders-router-fixtures/") {
            let questions = object["questions"] as? [String: [String: Any]] ?? [:]
            for (devItem, key) in [(true, "items"), (false, "extra_cases")] {
                for item in object[key] as? [[String: Any]] ?? [] {
                    let name = item["id"] as? String ?? item["name"] as? String ?? "?"
                    let state = item["state"] as? String ?? ""
                    for kind in ["binder", "agent"] {
                        guard let asked = questions[kind], let own = (item["questions"] as? [String: Any])?[kind] as? [String: Any] else { continue }
                        let options = (asked["options"] as? [[String: Any]] ?? []).map {
                            DecisionOption(key: $0["key"] as? String ?? "", description: $0["description"] as? String ?? "")
                        }
                        found.append(FixturePrompt(name: "\(name) \(kind)", devItem: devItem, kind: kind,
                                                   question: DecisionQuestion(state: state, question: asked["question"] as? String ?? "", options: options),
                                                   prompt: own["prompt"] as? String ?? "", tokenIDs: own["token_ids"] as? [Int],
                                                   probs: (own["options"] as? [[String: Any]] ?? []).compactMap { $0["prob"] as? Double }))
                    }
                }
            }
        } else if schema.hasPrefix("binders-kit-router-fixture/") {
            let library = object["library"] as? [String: Any] ?? [:]
            let inputs = RouterInputs(
                binders: (library["binders"] as? [[String: Any]] ?? []).map {
                    RouterInputs.Binder(name: $0["name"] as? String ?? "", whatGoesHere: $0["what_goes_here"] as? String ?? "", titles: $0["titles"] as? [String] ?? [])
                },
                agents: (library["agents"] as? [[String: Any]] ?? []).map {
                    RouterInputs.Agent(name: $0["name"] as? String ?? "", description: $0["what_its_for"] as? String)
                })
            for item in object["cases"] as? [[String: Any]] ?? [] {
                let name = item["name"] as? String ?? "?"
                let state = item["state"] as? String ?? ""
                let devItem = name.contains("-") && name.last?.isNumber == true
                for kind in ["binder", "agent"] {
                    guard let own = item[kind] as? [String: Any],
                          let question = kind == "binder" ? RouterQuestions.binders(state: state, inputs: inputs)?.question
                              : RouterQuestions.agents(state: state, inputs: inputs)?.question else { continue }
                    found.append(FixturePrompt(name: "\(name) \(kind)", devItem: devItem, kind: kind, question: question,
                                               prompt: own["prompt"] as? String ?? "", tokenIDs: nil, probs: own["probs"] as? [Double] ?? []))
                }
            }
        } else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "not a router fixture file (\(schema))"])
        }
        guard !found.isEmpty else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "no prompts in it"]) }
        return found
    }

    /// A clone of the folder with its weights cut to half: refused with the reason before MLX reads it.
    @MainActor
    private static func truncatedFolderCheck(_ folder: URL, pieces: Int?, check: (Bool, String) -> Void) async {
        let manager = FileManager.default
        let clone = AppPaths.support.appendingPathComponent("router-truncated", isDirectory: true)
        try? manager.removeItem(at: clone)
        try? manager.createDirectory(at: clone, withIntermediateDirectories: true)
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let source = folder.appendingPathComponent(name), copy = clone.appendingPathComponent(name)
            if name.hasSuffix(".safetensors") {
                // A clone costs no space, and cutting it leaves the original as it was.
                guard clonefile(source.path, copy.path, 0) == 0 else { continue }
                let size = ((try? manager.attributesOfItem(atPath: copy.path))?[.size] as? NSNumber)?.int64Value ?? 0
                _ = truncate(copy.path, off_t(size / 2))
            } else {
                try? manager.copyItem(at: source, to: copy)
            }
        }
        let problem = MLXDecisionBackend.problem(in: clone)
        check(problem?.contains("shorter than its header says") == true, "a folder whose weights are cut to half is refused before loading: \(problem ?? "not refused")")
        let backend = MLXDecisionBackend(folder: clone, kind: .tev1, pieces: pieces, marker: AppPaths.support.appendingPathComponent("router-running-truncated"))
        let state = await backend.state()
        check(state == .unavailable(.folder(problem ?? "")), "its state says why: \(state)")
        do {
            _ = try await backend.decide([RouterQuestions.warmUps[0]], by: .now + .seconds(10))
            check(false, "a decision on it is refused")
        } catch {
            check(true, "a decision on it is refused, and Binders goes on: \(error.localizedDescription)")
        }
        let started = await backend.startedMLX
        check(!started, "and MLX never started for it")
        try? manager.removeItem(at: clone)
    }

    /// Cards timed while the chat model writes 400 tokens through MLXRuntime, beside cards timed idle.
    @MainActor
    private static func concurrentChatCheck(chatFolder: URL, backend: MLXDecisionBackend, prompts: [FixturePrompt]) async {
        let questions = stride(from: 0, to: prompts.count - 1, by: 2).compactMap { index -> [DecisionQuestion]? in
            prompts[index].kind == "binder" && prompts[index + 1].kind == "agent" && prompts[index].devItem ? [prompts[index].question, prompts[index + 1].question] : nil
        }
        func card(_ pair: [DecisionQuestion]) async -> Double? {
            let started = Date()
            guard (try? await backend.decide(pair, by: .now + MLXDecisionBackend.cardBudget)) != nil else { return nil }
            return Date().timeIntervalSince(started) * 1000
        }
        var idle: [Double] = []
        for pair in questions.prefix(10) { if let ms = await card(pair) { idle.append(ms) } }
        let client = MLXClient(model: chatFolder.path, idleMinutes: 0)
        let chat = Task.detached {
            try await client.complete(system: "You write long, plain paragraphs.", user: "Describe a walk along a river, in detail, for a long time.",
                                      maxTokens: 400, temperature: 0.7, timeout: 300)
        }
        var busy: [Double] = []
        var over = 0
        var cards = 0
        let started = Date()
        while Date().timeIntervalSince(started) < 300 {
            for pair in questions {
                cards += 1
                if let ms = await card(pair) { busy.append(ms) } else { over += 1 }
                if busy.count + over >= 40 { break }
            }
            if busy.count + over >= 40 { break }
        }
        let wrote = try? await chat.value
        print(String(format: "CONCURRENT: idle p50 %.0f ms, p95 %.0f ms; while the chat model wrote (%@), p50 %.0f ms, p95 %.0f ms, %d of %d past the 4 s budget",
                     percentile(idle, 0.5), percentile(idle, 0.95), wrote == nil ? "it didn't answer" : "\(wrote?.count ?? 0) characters",
                     percentile(busy, 0.5), percentile(busy, 0.95), over, cards))
        await MLXRuntime.shared.release()
    }

    /// The checks that need a container to land, with the real model, through DecisionModels: a switch during a cold load
    /// (the load is dropped when it lands, and MLX's memory is back where it was), a switch during a pass (its answer
    /// comes back, then nothing is held), a folder replaced while its model is in memory (the next identity is the new
    /// files', no answer comes from the old ones, and the next load and its warm-ups are the new files'), and a quit during
    /// a measure (it returns within a second, the pass under way takes its marker with it, and nothing was kept).
    @MainActor
    private static func lifecycleChecks(_ chosen: (choice: DecisionChoice, folder: URL, backend: MLXDecisionBackend, throughSetting: Bool), other: URL?,
                                        prompts: [DecisionQuestion], check: (Bool, String) -> Void) async {
        let models = DecisionModels.shared
        let backend = chosen.backend
        let manager = FileManager.default
        func choose(_ choice: DecisionChoice) async {
            AppSettings.shared.decisionModel = choice.stored
            models.choose(choice)
            await models.settled()
        }
        func refused(_ outcome: Result<DecisionAnswers, Error>, with expected: DecisionError) -> Bool {
            if case .failure(let error) = outcome, (error as? DecisionError) == expected { return true }
            return false
        }
        let warmUp = RouterQuestions.warmUps[0]
        print("LIFECYCLE: \(chosen.folder.lastPathComponent)" + (other.map { ", its files replaced by \($0.lastPathComponent)'s" } ?? ""))

        // A switch during a cold load.
        await backend.unload()
        try? await Task.sleep(for: .milliseconds(300))
        let identity = await backend.identity(by: .now + .seconds(60))
        let activeBefore = MLX.Memory.activeMemory
        let cold = Task { try await backend.decide([warmUp], expecting: identity, by: .now + .seconds(60)) }
        try? await Task.sleep(for: .milliseconds(100))
        let loadingAtSwitch = await backend.isLoading
        await choose(.off)
        let coldOutcome = await cold.result
        try? await Task.sleep(for: .milliseconds(300))
        let heldAfterLoad = await backend.hasContainer
        let activeAfter = MLX.Memory.activeMemory
        check(loadingAtSwitch && refused(coldOutcome, with: .retired) && !heldAfterLoad && abs(activeAfter - activeBefore) <= 50 * 1_048_576,
              String(format: "a switch during a cold load: the load is dropped when it lands, nothing is held, and MLX's active memory is back within 50 MB (%+.1f MB)",
                     Double(activeAfter - activeBefore) / 1_048_576))
        await choose(chosen.choice)
        let sameBackend = models.backend === backend
        let stillRetired = await backend.retiredNow
        check(sameBackend && !stillRetired, "choosing it again gives the same backend, revived")

        // A switch during a pass.
        var loadedAgain = true
        do {
            try await backend.prepare(by: .now + .seconds(60))
        } catch {
            loadedAgain = false
        }
        let loadedIdentity = await backend.identity(by: .now + .seconds(10))
        let inFlight = Task { try await backend.decide([warmUp], expecting: loadedIdentity, by: .now + .seconds(30)) }
        var inPass = false
        for _ in 0..<20_000 {
            if await backend.passRunning {
                inPass = true
                break
            }
            try? await Task.sleep(for: .microseconds(200))
        }
        await choose(.off)
        let passOutcome = await inFlight.result
        let heldAfterPass = await backend.hasContainer
        let answered = (try? passOutcome.get())?.probs.first?.count == warmUp.options.count
        check(loadedAgain && inPass && answered && !heldAfterPass, "a switch during a pass: its answer comes back, then nothing is held")
        await choose(chosen.choice)

        // A folder replaced while its model is in memory, under a name that says no conversion, as a folder chosen.
        if let other {
            let neutral = AppPaths.support.appendingPathComponent("Models/lifecycle-model", isDirectory: true)
            let otherClone = AppPaths.support.appendingPathComponent("Models/lifecycle-other", isDirectory: true)
            if cloneModel(chosen.folder, to: neutral), cloneModel(other, to: otherClone) {
                // The other conversion's own warm-ups, from a backend of its own on a clone of it.
                let reference = MLXDecisionBackend(folder: otherClone, kind: .folder, marker: AppPaths.support.appendingPathComponent("router-running-lifecycle-other"))
                let referenceWarm = (try? await reference.loadNow())?.warmUps ?? []
                let referenceIdentity = await reference.identity(by: .now + .seconds(120))
                await reference.unload()
                await choose(.folder(neutral.path))
                let swapped = models.backend as? MLXDecisionBackend
                let before = await swapped?.identity(by: .now + .seconds(120))
                try? await swapped?.prepare(by: .now + .seconds(60))
                let heldBefore = await swapped?.hasContainer ?? false
                let warmBefore = await swapped?.warmUp() ?? []
                // Each file removed and the other's cloned in its place: new inodes, so a new stamp.
                for name in (try? manager.contentsOfDirectory(atPath: neutral.path)) ?? [] { try? manager.removeItem(at: neutral.appendingPathComponent(name)) }
                _ = cloneModel(other, to: neutral)
                let after = await swapped?.identity(by: .now + .seconds(120))
                let heldAfterSwap = await swapped?.hasContainer ?? true
                var refusedOld = false
                do {
                    _ = try await swapped?.decide([warmUp], expecting: before, by: .now + .seconds(30))
                } catch DecisionError.changed {
                    refusedOld = true
                } catch {}
                var reloaded = true
                do {
                    try await swapped?.prepare(by: .now + .seconds(60))
                } catch {
                    reloaded = false
                }
                let warmAfter = await swapped?.warmUp() ?? []
                let loadedAs = await swapped?.identity(by: .now + .seconds(10))
                func same(_ a: [[Double]], _ b: [[Double]], within: Double) -> Bool {
                    a.count == b.count && !a.isEmpty && zip(a, b).allSatisfy { x, y in x.count == y.count && zip(x, y).allSatisfy { abs($0 - $1) <= within } }
                }
                check(heldBefore && before != nil && after != nil && before?.fingerprint != after?.fingerprint && after?.fingerprint == referenceIdentity?.fingerprint
                      && !heldAfterSwap && refusedOld,
                      "the folder's files replaced while loaded: its next identity is the new files' (\(after?.fingerprint ?? "none"), was \(before?.fingerprint ?? "none")), "
                      + "the old container goes, and an answer expecting the old files is refused")
                check(reloaded && loadedAs == after && same(warmAfter, referenceWarm, within: 1e-9) && !same(warmAfter, warmBefore, within: 1e-6),
                      "and the next load is the new files', with their own warm-ups, not the old ones', so a measure now would be kept under their key with their numbers")
                await swapped?.unload()
                await choose(chosen.choice)
            } else {
                check(false, "cloning \(chosen.folder.lastPathComponent) and \(other.lastPathComponent) for the replacement")
            }
        } else {
            print("INFO: no other conversion to replace the folder's files with (--lifecycle <folder>), so that check is left out")
        }

        // A quit during a measure (the button's own, DecisionModels.measure): after 50 calls, DecisionModels' quit, as
        // applicationShouldTerminate makes it.
        try? await backend.prepare(by: .now + .seconds(60))
        let quitIdentity = await backend.identity(by: .now + .seconds(10))
        let measuring = models.measure()
        for _ in 0..<6_000 where (models.measuring?.done ?? 0) < 50 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let doneAtQuit = models.measuring?.done ?? 0
        let quitAsked = ContinuousClock.now
        await models.prepareForQuit(within: .seconds(3))
        let quitTook = quitAsked.duration(to: .now)
        let markerGone = !manager.fileExists(atPath: backend.marker.path)
        let measured = await measuring?.value
        let keptNothing = quitIdentity.map { models.measures.all.measure(for: $0) == nil } ?? false
        check(measuring != nil && doneAtQuit >= 50 && doneAtQuit < DecisionMeasureRun.calls && quitTook < .seconds(1) && markerGone && measured == nil
              && keptNothing && models.measuring == nil && models.lastMeasureProblem == DecisionMeasureRun.quit,
              "a quit during a measure, after \(doneAtQuit) of its \(DecisionMeasureRun.calls) calls: it returns within a second (\(quitTook)), the pass under way takes its marker with it, and the measure stopped and kept nothing")
    }

    /// Linear interpolation between ranks, as numpy's default percentile does.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let k = Double(sorted.count - 1) * p
        let low = Int(k), high = min(low + 1, sorted.count - 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (k - Double(low))
    }

    /// This Mac's model and chip, for the goldens.
    static func macModel() -> String {
        func sysctl(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var value = [CChar](repeating: 0, count: max(1, size))
            sysctlbyname(name, &value, &size, nil, 0)
            return String(cString: value)
        }
        return "\(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string"))"
    }

    // MARK: --selftest-router-bench

    /// The router bench through the app's own router, with the model chosen through the setting: the bench's standard
    /// library as RouterInputs and every question built as CardRouter builds them (RouterBench, held to lane R1's 834
    /// question hashes), the backend's answers expecting its own identity, and RouterRules at the bands DecisionModels
    /// resolves. The bench is the folder given, else the copy that comes with Binders. Scored the bench's way (first picks,
    /// General never chosen) and the app's way (the General threshold for the form, the takers rule, the bands), which on
    /// dev must start no wrong agent at the bar. With `--against`, every item held to the fixture's answers within 1e-6 and
    /// the score to its count exactly (lane R1's runs: 265 of 334 on test, 171 of 222 on dev).
    @MainActor
    static func routerBenchSelfTest(_ args: [String]) async -> Int32 {
        // It chooses a decision model, clones the folder into Models and writes its fingerprint, so only into a throwaway
        // data folder, as --selftest-router does: without BINDERS_DATA_DIR that's your own.
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this tool chooses a decision model and writes measures there")
            return 1
        }
        guard let index = args.firstIndex(of: "--selftest-router-bench"), args.indices.contains(index + 1) else {
            print("Usage: --selftest-router-bench <model folder> [<bench folder>] [--split test|dev] [--desc both|titles] [--against <fixture.json>] [--out <jsonl>]")
            return 2
        }
        func value(_ flag: String) -> String? {
            guard let at = args.firstIndex(of: flag), args.indices.contains(at + 1) else { return nil }
            return args[at + 1]
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        let source = URL(fileURLWithPath: args[index + 1], isDirectory: true).standardizedFileURL
        let benchFolder = args.indices.contains(index + 2) && !args[index + 2].hasPrefix("-") ? URL(fileURLWithPath: args[index + 2], isDirectory: true) : nil
        let split = value("--split") ?? "test"
        let desc = value("--desc") ?? "both"
        let piecesValue = Int(value("--pieces") ?? "") ?? MLXDecisionBackend.defaultPieces
        let pieces: Int? = piecesValue > 0 ? piecesValue : nil
        if let path = value("--dump-questions") {
            guard let benchFolder else {
                print("Usage: --selftest-router-bench <model folder> <bench folder> --dump-questions <file> [--full <id>,<id>]")
                return 2
            }
            return dumpBenchQuestions(to: URL(fileURLWithPath: path), bench: benchFolder, full: Set((value("--full") ?? "").split(separator: ",").map(String.init)))
        }
        // The bench: the folder given, else the copy that comes with Binders, which must be the files as their names were checked.
        let data: RouterBench.Data
        do {
            if let benchFolder {
                data = try RouterBench.Data(folder: benchFolder)
                print("BENCH: \(benchFolder.path)")
            } else {
                guard let library = Bundle.main.url(forResource: RouterBench.bundledLibrary, withExtension: "json"),
                      let routing = Bundle.main.url(forResource: RouterBench.bundledRouting, withExtension: "json") else {
                    print("FAIL: the bench that comes with Binders isn't in its bundle")
                    return 1
                }
                let libraryData = try Data(contentsOf: library), routingData = try Data(contentsOf: routing)
                check(RouterBench.sha256(libraryData) == RouterBench.reviewedSHA256["library.json"] && RouterBench.sha256(routingData) == RouterBench.reviewedSHA256["routing.json"],
                      "the bench that comes with Binders is the two files as their names were checked")
                data = try RouterBench.Data(library: libraryData, routing: routingData)
                print("BENCH: the copy that comes with Binders")
            }
        } catch {
            print("FAIL: reading the bench: \(error.localizedDescription)")
            return 1
        }
        guard let chosen = chooseForDevTool(source, pieces: pieces) else {
            print("FAIL: couldn't clone \(source.path) into this data folder's Models and choose it")
            return 1
        }
        let backend = chosen.backend
        // The bands of the model the folder holds, by its fingerprint and reader (DecisionBands), never by its name.
        let resolved = chosen.throughSetting ? await DecisionModels.shared.bands(by: .now + .seconds(120)) : nil
        let identity = chosen.throughSetting ? resolved?.identity : await backend.identity(by: .now + .seconds(120))
        let bands = resolved?.bands
        let form: RouterQuestions.Form = desc == "titles" ? .titles : .both
        let items = data.items(split == "dev" ? .dev : .test)
        let library = data.library
        let inputs = data.inputs(form)
        print("ROUTER BENCH: \(source.lastPathComponent)/\(pieces.map(String.init) ?? "whole"), \(identity?.fingerprint ?? "unknown") read as \(identity?.reader ?? "unknown") "
              + "with \(resolved?.source.logName ?? "no") bands, \(split) split, \(items.count) items, binders described by "
              + "\(desc == "titles" ? "their titles" : "what goes here and their titles"), bands "
              + (bands.map { "start \($0.start.map { String($0) } ?? "none"), suggest \($0.suggest), General below \($0.generalBelow) or \($0.generalBelowTitlesOnly) for titles alone" } ?? "none"))
        if let known = knownConversions[source.lastPathComponent], pieces == MLXDecisionBackend.defaultPieces {
            check(identity?.fingerprint == known.fingerprint && identity?.reader == "tev1.1/256" && resolved?.source.logName == known.bands,
                  "\(source.lastPathComponent) is \(known.fingerprint) read as tev1.1/256, with \(known.bands) bands")
        }
        if args.contains("--measure") {
            guard chosen.throughSetting else {
                print("FAIL: --measure goes through the setting, which reads 256-token pieces only")
                return 1
            }
            let code = await benchMeasure(source, bench: data, bundled: benchFolder == nil, against: value("--against"))
            return failures == 0 ? code : 1
        }
        // The fixture's answers to hold these to, item by item.
        var against: [String: RouterBench.Answer]?
        if let path = value("--against") {
            let key = split == "dev" ? (form == .titles ? "dev_titles" : "dev_both") : "test"
            guard let object = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
                  object["binders"] as? [String] == library.binders, object["agents"] as? [String] == library.agents,
                  let rows = object[key] as? [[String: Any]] else {
                print("FAIL: \(path) isn't a measure fixture for this bench's library, with \(key)")
                return 1
            }
            against = Dictionary(rows.compactMap { row -> (String, RouterBench.Answer)? in
                guard let id = row["id"] as? String, let binders = row["binders"] as? [Double], let agents = row["agents"] as? [Double] else { return nil }
                return (id, RouterBench.Answer(id: id, acceptableBinders: row["acceptable_binders"] as? [String] ?? [],
                                               acceptableAgents: row["acceptable_agents"] as? [String] ?? [], binders: binders, agents: agents))
            }, uniquingKeysWith: { first, _ in first })
            print("AGAINST: \(path), \(key), \(against?.count ?? 0) items")
        }
        do {
            _ = try await backend.loadNow()
        } catch {
            print("FAIL: the backend didn't load \(chosen.folder.path): \(error.localizedDescription)")
            return 1
        }
        var out: FileHandle?
        if let path = value("--out") {
            FileManager.default.createFile(atPath: path, contents: nil)
            out = FileHandle(forWritingAtPath: path)
        }
        defer { try? out?.close() }

        let general = RouterBench.id(binder: data.general)
        let byID = Dictionary(data.binderNames.map { (RouterBench.id(binder: $0), $0) }, uniquingKeysWith: { first, _ in first })
        var answers: [RouterBench.Answer] = []
        var largest = 0.0, worst = "", within = 0, missing = 0
        var nobodyItems = 0, falseAssignments = 0
        var rawBands: [String: (picked: Int, right: Int)] = [:]
        var appBinderOK = 0, appAgentOK = 0
        var starts: [(id: String, agent: String, p: Double, right: Bool)] = []
        var suggested = 0, suggestedRight = 0, nones = 0, nonesRight = 0, fallbacks = 0
        var ms: [Double] = []
        for item in items {
            guard let questions = data.questions(item, form: form) else {
                print("FAIL: \(item.id): no questions")
                return 1
            }
            let binderQ = questions.binder, agentQ = questions.agent
            let started = Date()
            let probs: [[Double]]
            do {
                probs = try await backend.decide([binderQ.question, agentQ.question], expecting: identity, by: .now + .seconds(60)).probs
            } catch {
                print("FAIL: \(item.id): \(error.localizedDescription)")
                return 1
            }
            ms.append(Date().timeIntervalSince(started) * 1000)
            let binderProbs = probs[0], agentProbs = probs[1]
            let agentKeys = agentQ.question.options.map(\.key)
            answers.append(RouterBench.Answer(item: item, binders: binderProbs, agents: agentProbs))
            if let against {
                if let held = against[item.id], held.binders.count == binderProbs.count, held.agents.count == agentProbs.count {
                    let binderDiffs: [Double] = zip(held.binders, binderProbs).map { abs($0 - $1) }
                    let agentDiffs: [Double] = zip(held.agents, agentProbs).map { abs($0 - $1) }
                    let diff = (binderDiffs + agentDiffs).max() ?? 0
                    if diff > largest { largest = diff; worst = item.id }
                    if diff <= 1e-6 { within += 1 }
                } else {
                    missing += 1
                }
            }
            // The bench's scoring: the raw picks.
            let rawBinder = binderQ.offered[RouterMath.argmax(binderProbs) ?? 0].name
            let rawAgentIndex = RouterMath.argmax(agentProbs) ?? 0
            let rawAgent = agentKeys[rawAgentIndex]
            let rawP = agentProbs[rawAgentIndex]
            if item.expectedAgent == RouterQuestions.nobody {
                nobodyItems += 1
                falseAssignments += rawAgent != RouterQuestions.nobody ? 1 : 0
            }
            if rawAgent != RouterQuestions.nobody, let bands {
                let band = switch bands.band(rawP) { case .start: "start"; case .suggest: "suggest"; case .none: "none" }
                rawBands[band, default: (0, 0)].picked += 1
                rawBands[band, default: (0, 0)].right += item.acceptableAgents.contains(rawAgent) ? 1 : 0
            }
            // The app's rules.
            let pick = RouterRules.binder(named: nil, model: Array(zip(binderQ.offered.map(\.id), binderProbs)), form: binderQ.form, bands: bands,
                                          llm: nil, fallback: general)
            let appBinder = byID[pick.id] ?? data.general
            if pick.how == .fallback { fallbacks += 1 }
            appBinderOK += item.acceptableBinders.contains(appBinder) ? 1 : 0
            let takers = inputs.agents.filter { $0.takesCards(from: pick.id) }.map(\.name)
            let outcome = RouterRules.agent(kind: .todo, named: [], model: zip(agentKeys, agentProbs).map { RankedOption(key: $0.0, p: $0.1) }, bands: bands,
                                            takers: takers, llmAgent: nil, llmFits: nil)
            let appAgent = outcome.pick?.name ?? RouterQuestions.nobody
            let appRight = item.acceptableAgents.contains(appAgent)
            appAgentOK += appRight ? 1 : 0
            if let picked = outcome.pick, let p = picked.p {
                if bands?.band(p) == .start {
                    starts.append((item.id, picked.name, p, appRight))
                } else {
                    suggested += 1
                    suggestedRight += appRight ? 1 : 0
                }
            } else {
                nones += 1
                nonesRight += appRight ? 1 : 0
            }
            if let out {
                let line: [String: Any] = ["id": item.id, "binder_probs": Dictionary(uniqueKeysWithValues: zip(binderQ.offered.map(\.name), binderProbs)),
                                           "agent_probs": Dictionary(uniqueKeysWithValues: zip(agentKeys, agentProbs)), "binder": rawBinder, "agent": rawAgent,
                                           "app_binder": appBinder, "app_agent": appAgent, "binder_ok": item.acceptableBinders.contains(rawBinder),
                                           "agent_ok": item.acceptableAgents.contains(rawAgent), "ms": ms.last ?? 0]
                if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
                    out.write(data)
                    out.write(Data("\n".utf8))
                }
            }
        }
        let n = items.count
        guard n > 0 else {
            print("FAIL: no items in the \(split) split")
            return 1
        }
        let scored = RouterBench.score(answers, library: library)
        let appScore = Double(appBinderOK + appAgentOK) / Double(2 * n)
        print(String(format: "BENCH SCORING (first picks, General never chosen): score %.4f (%d of %d): binder ok %d, agent ok %d of %d; false assignments %d of %d",
                     scored.score, scored.binderOK + scored.agentOK, 2 * n, scored.binderOK, scored.agentOK, n, falseAssignments, nobodyItems))
        for band in ["start", "suggest", "none"] {
            let found = rawBands[band] ?? (0, 0)
            print("  raw agent picks in the \(band) band: \(found.picked), \(found.right) right")
        }
        print(String(format: "APP RULES: score %.4f: binder ok %d (General %d times), agent ok %d of %d", appScore, appBinderOK, fallbacks, appAgentOK, n))
        print("  starts at the bar: \(starts.count), \(starts.filter(\.right).count) right" + (starts.isEmpty ? "" : ": "
            + starts.map { String(format: "%@ %@ %.4f %@", $0.id, $0.agent, $0.p, $0.right ? "right" : "WRONG") }.joined(separator: "; ")))
        print("  suggestions: \(suggested), \(suggestedRight) right; no agent named: \(nones), \(nonesRight) right")
        print(String(format: "TIME a card: p50 %.0f ms, p95 %.0f ms", percentile(ms, 0.5), percentile(ms, 0.95)))
        if let against {
            let held = RouterBench.score(items.compactMap { against[$0.id] }, library: library)
            check(missing == 0 && within == n, String(format: "every item's answers are the fixture's within 1e-6: %d of %d, largest difference %.2e (%@)",
                                                       within, n, largest, worst.isEmpty ? "none" : worst))
            check(scored.binderOK == held.binderOK && scored.agentOK == held.agentOK,
                  "the bench's count is the fixture's exactly: \(scored.binderOK + scored.agentOK) of \(2 * n) (\(scored.binderOK) and \(scored.agentOK)), "
                  + "the fixture's \(held.binderOK + held.agentOK) (\(held.binderOK) and \(held.agentOK))")
        }
        // Python's numbers for the same config (chosen.json, the bf16 conversion): test 265 of 334, dev 172 of 222. A second
        // check: --against is the bar, as 0.01 would let 3 of 334 answers change.
        let python = split == "test" && desc == "both" ? 0.793413 : split == "dev" && desc == "both" ? 0.774775 : nil
        if let python, knownConversions[source.lastPathComponent]?.bands == "built-in" || source.lastPathComponent.hasSuffix("bf16") {
            check(abs(scored.score - python) <= 0.01, String(format: "the bench score %.4f is Python's %.4f within 0.01", scored.score, python))
        }
        if split == "dev", bands?.start != nil {
            check(starts.allSatisfy(\.right), "on dev, no wrong agent starts at the bar")
        }
        print(failures == 0 ? "ROUTER_BENCH_OK" : "ROUTER_BENCH_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// `--measure`: the measure as the button runs it (DecisionModels.measure, DecisionMeasureRun) on the model chosen
    /// through the setting, kept in this throwaway data folder's decision-measures.json: its progress every 50 calls, then
    /// General for both forms, suggest, the start level or why there's none, the dev and test numbers with each start, the
    /// time, and whether its bands now resolve as measured. With `--against`, every answer of the three runs held to the
    /// fixture's within 1e-6 and the bench's counts to its exactly; for Tev1 0.8B bf16, lane R1's bands.
    @MainActor
    private static func benchMeasure(_ source: URL, bench data: RouterBench.Data, bundled: Bool, against path: String?) async -> Int32 {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        let models = DecisionModels.shared
        print("MEASURE: \(DecisionMeasureRun.calls) calls (111 dev cards, the same 111 with titles alone, 167 test cards), "
              + "a card's 4 s each, on \(bundled ? "the bench that comes with Binders" : "the bench folder given")")
        let began = Date()
        guard let task = models.measure(bench: data, onProgress: { done in
            if done % 50 == 0 || done == DecisionMeasureRun.calls { print("MEASURE PROGRESS: \(done) of \(DecisionMeasureRun.calls)") }
        }) else {
            print("FAIL: the measure didn't begin: \(models.lastMeasureProblem ?? "no model chosen, or a measure runs")")
            return 1
        }
        guard let result = await task.value else {
            print("FAIL: the measure stopped: \(models.lastMeasureProblem ?? "no reason given")")
            return 1
        }
        let took = Date().timeIntervalSince(began)
        let outcome = result.outcome, measure = result.measure
        func level(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "none" }
        func starts(_ found: [MeasureRules.Start]) -> String {
            found.isEmpty ? "none" : found.map { String(format: "%@ %@ %.4f %@", $0.id, $0.agent, $0.p, $0.right ? "right" : "WRONG") }.joined(separator: "; ")
        }
        print("MEASURED: \(result.identity.fingerprint) read as \(result.identity.reader), on \(measure.mac ?? "this Mac"), build \(measure.build ?? "?")")
        print("  General below \(level(outcome.dev.general)) (What goes here and titles), \(level(outcome.dev.generalTitlesOnly)) (titles alone); suggest at \(level(outcome.dev.suggest))")
        print("  start level " + (outcome.bands.start.map { String(format: "%.2f", $0) } ?? "none (\(outcome.noStart?.rawValue ?? "?"))")
              + "; dev found " + level(outcome.dev.start) + (outcome.dev.noStart.map { " (\($0.rawValue))" } ?? ""))
        print(String(format: "  dev: score %.4f (%d of %d): binder ok %d, agent ok %d of %d; titles alone binder ok %d; starts at %.2f: %d, %d wrong: %@",
                     outcome.dev.score.score, outcome.dev.score.binderOK + outcome.dev.score.agentOK, 2 * outcome.dev.score.items, outcome.dev.score.binderOK,
                     outcome.dev.score.agentOK, outcome.dev.score.items, outcome.dev.titlesBinderOK, outcome.dev.level, outcome.dev.starts.count,
                     outcome.dev.starts.filter { !$0.right }.count, starts(outcome.dev.starts)))
        print(String(format: "  test: score %.4f (%d of %d): binder ok %d, agent ok %d of %d; starts at %.2f: %d, %d wrong: %@",
                     outcome.test.score.score, outcome.test.score.binderOK + outcome.test.score.agentOK, 2 * outcome.test.score.items, outcome.test.score.binderOK,
                     outcome.test.score.agentOK, outcome.test.score.items, outcome.test.level, outcome.test.starts.count, outcome.test.starts.filter { !$0.right }.count,
                     starts(outcome.test.starts)))
        let auto = result.auto
        func autoCounts(_ counts: DecisionMeasure.AutoCounts) -> String {
            "\(counts.picks) of its own picks, \(counts.right) right, \(counts.falseAssignments) where the answer was nobody; named \(counts.named), \(counts.namedRight) right"
        }
        print("  Auto level " + (auto.level.map { String(format: "%.2f", $0) } ?? "none (\(auto.noAuto?.rawValue ?? "?"))")
              + "; dev alone \(level(auto.devLevel))" + (auto.raisedTo.map { String(format: ", raised by test to %.2f", $0) } ?? "")
              + "; counted at \(level(auto.countedAt)): dev \(autoCounts(auto.dev)); test \(autoCounts(auto.test))")
        print(String(format: "TIME: %.1f s in all, %.1f s from the first card to the last; a card p50 %d ms, p95 %d ms", took, result.seconds,
                     measure.ms?.p50 ?? 0, measure.ms?.p95 ?? 0))
        print("LETTER SHARES: " + (measure.letterShare ?? []).map { String(format: "%.6f", $0) }.joined(separator: ", "))
        for (number, golden) in (measure.golden ?? []).enumerated() {
            print("GOLDEN \(number + 1): " + golden.map { String(format: "%.17g", $0) }.joined(separator: ", "))
        }
        let kept = models.measures.all.measure(for: result.identity)
        check(kept == measure && FileManager.default.fileExists(atPath: models.measures.url.path),
              "the measure is kept in this data folder's decision-measures.json, under \(result.identity.key)")
        let resolved = await models.bands(by: .now + .seconds(10))
        let measuredSource: Bool = { if case .measured = resolved?.source { return true } else { return false } }()
        check(measuredSource && resolved?.bands == outcome.bands && resolved?.golden == measure.golden,
              "its bands now resolve as measured, with its goldens, in place of any built in")
        let matched = await models.backend?.numbersMatch() ?? false
        check(matched, "this launch's warm-ups match the goldens it recorded, so its starts, if it has a level, aren't held back")
        if let path {
            guard let object = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
                  object["binders"] as? [String] == data.library.binders, object["agents"] as? [String] == data.library.agents else {
                print("FAIL: \(path) isn't a measure fixture for this bench's library")
                return 1
            }
            func rows(_ key: String) -> [String: RouterBench.Answer] {
                Dictionary((object[key] as? [[String: Any]] ?? []).compactMap { row -> (String, RouterBench.Answer)? in
                    guard let id = row["id"] as? String, let binders = row["binders"] as? [Double], let agents = row["agents"] as? [Double] else { return nil }
                    return (id, RouterBench.Answer(id: id, acceptableBinders: row["acceptable_binders"] as? [String] ?? [],
                                                   acceptableAgents: row["acceptable_agents"] as? [String] ?? [], binders: binders, agents: agents))
                }, uniquingKeysWith: { first, _ in first })
            }
            for (key, mine) in [("dev_both", result.devBoth), ("dev_titles", result.devTitles), ("test", result.test)] {
                let held = rows(key)
                var within = 0, largest = 0.0, worst = ""
                for answer in mine {
                    guard let fixture = held[answer.id], fixture.binders.count == answer.binders.count, fixture.agents.count == answer.agents.count else { continue }
                    let binderDiffs: [Double] = zip(fixture.binders, answer.binders).map { abs($0 - $1) }
                    let agentDiffs: [Double] = zip(fixture.agents, answer.agents).map { abs($0 - $1) }
                    let diff = (binderDiffs + agentDiffs).max() ?? 0
                    if diff > largest { (largest, worst) = (diff, answer.id) }
                    if diff <= 1e-6 { within += 1 }
                }
                let scored = RouterBench.score(mine, library: data.library), heldScore = RouterBench.score(mine.compactMap { held[$0.id] }, library: data.library)
                check(within == mine.count && held.count == mine.count && scored == heldScore,
                      String(format: "%@: every answer is the fixture's within 1e-6 (%d of %d, largest %.2e%@), and the bench's count is its exactly: %d and %d",
                             key, within, mine.count, largest, worst.isEmpty ? "" : " at \(worst)", scored.binderOK, scored.agentOK))
            }
            if knownConversions[source.lastPathComponent]?.bands == "built-in" {
                check(outcome.bands == DecisionBands.tev1?.bands && outcome.noStart == nil,
                      "Tev1 0.8B bf16's measure gives lane R1's bands: start 0.97, suggest 0.50, General 0.45 and 0.33 for titles alone")
                check(outcome.dev.starts.map(\.id).sorted() == ["coding-13", "de-05", "fr-04"] && outcome.dev.starts.allSatisfy(\.right)
                      && outcome.test.starts.map(\.id).sorted() == ["de-03", "explicit-06", "long-14", "writing-11"] && outcome.test.starts.allSatisfy(\.right),
                      "with lane R1's starts: dev's coding-13, fr-04 and de-05, and test's explicit-06, writing-11, long-14 and de-03, none wrong, 7 in all")
                check(auto.level == 0.60 && measure.bands?.auto == 0.60 && auto.dev == DecisionBands.tev1?.auto?.dev && auto.test == DecisionBands.tev1?.auto?.test,
                      "and Auto's level 0.60, with the built-in counts: dev 23 picks, 19 right, 1 false, named 4; test 31, all right, named 6")
                check(abs(outcome.dev.score.score - 171.0 / 222) < 1e-12 && abs(outcome.test.score.score - 265.0 / 334) < 1e-12,
                      String(format: "and its scores: dev %.4f (171 of 222), test %.4f (265 of 334)", outcome.dev.score.score, outcome.test.score.score))
            }
        }
        print(failures == 0 ? "MEASURE_OK" : "MEASURE_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// `--dump-questions <file> [--full <id>,…]`: every question this tool asks the bench, as SHA-256s of Tev1Prompt's
    /// prompt for each item's binder question in both forms (What goes here and titles; titles alone) and its agent
    /// question, for both splits, in routing.json's order, built the way lane R1's bench tool built them inline. Written
    /// once from that construction before lane R2 moved it into BindersKit (RouterBench), which is held to it question by
    /// question (Fixtures/router/bench-questions-r1.json); run again, it writes the same file. Also the questions of the
    /// items `--full` names, whole, and the first warm-up with its golden. Nothing is loaded and no model is asked.
    private static func dumpBenchQuestions(to url: URL, bench: URL, full: Set<String>) -> Int32 {
        guard let library = try? JSONSerialization.jsonObject(with: Data(contentsOf: bench.appendingPathComponent("library.json"))) as? [String: Any],
              let routing = try? JSONSerialization.jsonObject(with: Data(contentsOf: bench.appendingPathComponent("routing.json"))) as? [String: Any],
              let variant = (library["variants"] as? [String: Any])?["standard"] as? [String: Any] else {
            print("FAIL: reading library.json and routing.json in \(bench.path)")
            return 1
        }
        // The library as lane R1's tool read it.
        let general = library["default_binder"] as? String ?? "General"
        let allBinders = Dictionary((library["binders"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        let allAgents = Dictionary((library["agents"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        let binderNames = variant["binders"] as? [String] ?? []
        let agentNames = variant["agents"] as? [String] ?? []
        var ids: [String: UUID] = [:]
        for name in binderNames { ids[name] = UUID() }
        func makeInputs(_ desc: String) -> RouterInputs {
            RouterInputs(
                binders: binderNames.filter { $0 != general }.map { name in
                    RouterInputs.Binder(id: ids[name] ?? UUID(), name: name, whatGoesHere: desc == "titles" ? "" : allBinders[name]?["what_goes_here"] as? String ?? "",
                                        titles: allBinders[name]?["titles"] as? [String] ?? [])
                },
                agents: agentNames.map { name in
                    RouterInputs.Agent(name: name, description: allAgents[name]?["what_its_for"] as? String,
                                       takes: (allAgents[name]?["binders"] as? [String]).map { $0.compactMap { ids[$0] } })
                })
        }
        let both = makeInputs("both"), titles = makeInputs("titles")
        let items = routing["items"] as? [[String: Any]] ?? []
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
        func sha256(_ text: String) -> String { hex(SHA256.hash(data: Data(text.utf8))) }
        func file(_ name: String) -> String { (try? Data(contentsOf: bench.appendingPathComponent(name))).map { hex(SHA256.hash(data: $0)) } ?? "" }
        func whole(_ question: DecisionQuestion) -> [String: Any] {
            ["state": question.state, "question": question.question,
             "options": question.options.map { ["key": $0.key, "description": $0.description] }]
        }
        func json(_ value: Any) -> String {
            (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "null"
        }
        var rows: [[String: Any]] = []
        var shown: [String: Any] = [:]
        for item in items {
            let id = item["id"] as? String ?? "?"
            let text = item["text"] as? String ?? ""
            guard let binderBoth = RouterQuestions.binders(state: text, inputs: both), let binderTitles = RouterQuestions.binders(state: text, inputs: titles),
                  let agent = RouterQuestions.agents(state: text, inputs: both), let agentTitles = RouterQuestions.agents(state: text, inputs: titles) else {
                print("FAIL: \(id): no questions")
                return 1
            }
            // The agent question doesn't depend on how binders are described, and each form is the one asked for.
            guard binderBoth.form == .both, binderTitles.form == .titles, Array(Tev1Prompt.prompt(agentTitles.question).utf8) == Array(Tev1Prompt.prompt(agent.question).utf8) else {
                print("FAIL: \(id): the binder forms or the agent question aren't what they should be")
                return 1
            }
            rows.append(["id": id, "split": item["split"] as? String ?? "", "binder_both": sha256(Tev1Prompt.prompt(binderBoth.question)),
                         "binder_titles": sha256(Tev1Prompt.prompt(binderTitles.question)), "agent": sha256(Tev1Prompt.prompt(agent.question))])
            if full.contains(id) {
                shown[id] = ["binder_both": whole(binderBoth.question), "binder_titles": whole(binderTitles.question), "agent": whole(agent.question)]
            }
        }
        let missing = full.subtracting(shown.keys)
        guard missing.isEmpty else {
            print("FAIL: no items \(missing.sorted().joined(separator: ", ")) in routing.json")
            return 1
        }
        // The first warm-up is lane R1's, moved to BindersKit byte for byte, and its golden is R1's, now the built-in entry's.
        let first = RouterQuestions.warmUps[0]
        var warmUp: [String: Any] = ["question": whole(first), "prompt_sha256": sha256(Tev1Prompt.prompt(first))]
        if let golden = DecisionBands.tev1?.golden.first { warmUp["golden"] = golden }
        let about = "Lane R1's --selftest-router-bench, as merged, building the bench's questions (the standard library, General left out; "
            + "binders by what goes here and their titles, or by their titles alone; agents by what each is for, then nobody), before lane R2 "
            + "moved that construction into BindersKit. Each hash is the SHA-256 of the UTF-8 bytes of Tev1Prompt.prompt(question), in "
            + "lowercase hex. Everything in the bench is made up."
        var text = "{\n\"schema\": \"binders-router-bench-questions/1\",\n"
        text += "\"about\": \(json(about)),\n"
        text += "\"bench\": \(json(["library.json": file("library.json"), "routing.json": file("routing.json")])),\n"
        text += "\"count\": \(rows.count * 3),\n"
        text += "\"warm_up_r1\": \(json(warmUp)),\n"
        text += "\"full\": \(json(shown)),\n"
        text += "\"items\": [\n" + rows.map(json).joined(separator: ",\n") + "\n]\n}\n"
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            print("FAIL: writing \(url.path): \(error.localizedDescription)")
            return 1
        }
        print("WROTE \(rows.count * 3) question hashes for \(rows.count) items (\(rows.filter { $0["split"] as? String == "dev" }.count) dev, "
              + "\(rows.filter { $0["split"] as? String == "test" }.count) test) to \(url.path)")
        print("ROUTER_BENCH_QUESTIONS_OK")
        return 0
    }
}
