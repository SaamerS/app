import Foundation
import BindersKit

extension SelfTest {
    /// The reading's bench (lane Y2, DESIGN 3.3), a dev tool like --selftest-router-bench: the monologues, the two long
    /// walks and the held-out calls in `Fixtures/solo`, read through the language model chosen in this data folder's
    /// Settings → AI, with the reading's own prompt and parser. For each: the reply, what the parser kept, and how long the
    /// call took; then the counts against the target, on the captures the pipeline would read (found 36 of 42 or more,
    /// false 4 or fewer, NONE for walk-02, none of the walks' negatives kept, each call under its 300 s), and what each
    /// held-out call came to. Only in a throwaway data folder. Usage: --selftest-solo-bench <Fixtures/solo folder> [--out <jsonl>]
    @MainActor
    static func soloBenchSelfTest(_ args: [String]) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this tool reads its model from that folder's settings")
            return 1
        }
        guard let index = args.firstIndex(of: "--selftest-solo-bench"), args.indices.contains(index + 1) else {
            print("Usage: --selftest-solo-bench <Fixtures/solo folder> [--out <jsonl>]")
            return 2
        }
        struct Item: Decodable { let kind: String; let from: [String] }
        struct Monologue: Decodable {
            let id: String
            let segments: [String]
            let items: [Item]
            let moments: [String]?
            let capture: Bool
            let negatives: [String]?
        }
        struct Call: Decodable { let id: String; let segments: [String] }
        struct Monologues: Decodable { let agents: [String]; let monologues: [Monologue] }
        struct Calls: Decodable { let calls: [Call] }
        let folder = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        guard let monologues = try? JSONDecoder().decode(Monologues.self, from: Data(contentsOf: folder.appendingPathComponent("monologues.json"))),
              let calls = try? JSONDecoder().decode(Calls.self, from: Data(contentsOf: folder.appendingPathComponent("calls_heldout.json"))) else {
            print("ERROR: no monologues.json and calls_heldout.json in \(folder.path)")
            return 2
        }
        guard let client = AppSettings.shared.makeLLMClient(lane: .later) else {
            print("ERROR: no language model is set up in this data folder's Settings → AI, so the reading can't be benched")
            return 3
        }
        let out = args.firstIndex(of: "--out").flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        var lines: [String] = []
        print("Model: \(client.model)")

        /// The reading's reply to these sentences, timed.
        func read(_ sentences: [SoloPrompts.Sentence]) async -> (reply: SoloPrompts.Reply, raw: String, seconds: Double) {
            let began = Date()
            let raw = (try? await client.complete(system: SoloPrompts.systemPrompt(),
                                                  user: SoloPrompts.userPrompt(date: "Sunday 19 October, 10:42", duration: 240, sentences: sentences),
                                                  maxTokens: SoloPrompts.maxTokens, temperature: 0.1, timeout: SoloPrompts.timeout)) ?? ""
            return (SoloPrompts.parse(raw, sentences: sentences, agents: monologues.agents), raw, Date().timeIntervalSince(began))
        }

        var found = 0, expected = 0, falseItems = 0, wrongSentence = 0, negativesKept = 0, overTime = 0
        var walk02None = false
        var unanswered = 0
        for monologue in monologues.monologues {
            let sentences = SoloPrompts.numbered(monologue.segments, leavingOut: monologue.moments ?? [])
            let wanted = monologue.items.map { item in
                (action: item.kind != "idea", numbers: Set(item.from.compactMap { phrase in
                    sentences.first { $0.text.lowercased().contains(phrase.lowercased()) }?.number
                }))
            }
            let result = await read(sentences)
            if result.raw.isEmpty { unanswered += 1 }
            let kept = result.reply.items
            var hit = Set<Int>()
            var falseHere = 0, wrongHere = 0
            for item in kept {
                let action = item.kind != "idea"
                if let match = wanted.indices.first(where: { wanted[$0].action == action && !wanted[$0].numbers.isDisjoint(with: item.numbers) }) {
                    hit.insert(match)
                } else if wanted.contains(where: { want in want.numbers.contains { n in item.numbers.contains { abs($0 - n) == 1 } } }) {
                    wrongHere += 1
                } else {
                    falseHere += 1
                }
            }
            let negatives = (monologue.negatives ?? []).filter { phrase in kept.contains { $0.said.lowercased().contains(phrase.lowercased()) } }
            print("\(monologue.id)\(monologue.capture ? "" : " (parser only)"): \(result.reply.state.rawValue), \(kept.count) kept, "
                  + "\(hit.count) of \(wanted.count) found, \(falseHere) false, \(wrongHere) on a sentence next to its own, "
                  + "\(String(format: "%.1f", result.seconds)) s" + (negatives.isEmpty ? "" : ", negatives kept: \(negatives)")
                  + (kept.count > SoloPrompts.through ? ", \(kept.count - SoloPrompts.through) offered past the eighth" : ""))
            if monologue.capture {
                found += hit.count
                expected += wanted.count
                falseItems += falseHere
                wrongSentence += wrongHere
                negativesKept += negatives.count
                if result.seconds > SoloPrompts.timeout { overTime += 1 }
            }
            if monologue.id == "walk-02" { walk02None = result.reply.state == .none }
            let entry: [String: Any] = ["id": monologue.id, "reply": result.raw, "state": result.reply.state.rawValue,
                                        "kept": kept.map { ["kind": $0.kind, "title": $0.title, "numbers": $0.numbers] }, "refused": result.reply.refused,
                                        "seconds": result.seconds]
            if let data = try? JSONSerialization.data(withJSONObject: entry), let line = String(data: data, encoding: .utf8) { lines.append(line) }
        }
        var heldOut = 0
        for call in calls.calls {
            let sentences = SoloPrompts.numbered(call.segments)
            let result = await read(sentences)
            let fine = result.reply.state == .talking || result.reply.items.isEmpty
            if fine { heldOut += 1 }
            print("\(call.id): \(result.reply.state.rawValue), \(result.reply.items.count) kept\(fine ? "" : " (read as thinking out loud)")")
        }
        print("Target, on the captures the pipeline would read: found \(found) of \(expected) (36 or more), false \(falseItems) (4 or fewer), "
              + "\(wrongSentence) on a sentence next to its own, NONE for walk-02 \(walk02None ? "yes" : "no"), negatives kept \(negativesKept), "
              + "calls over \(Int(SoloPrompts.timeout)) s \(overTime)")
        print("Held-out calls read as talking, or with nothing kept: \(heldOut) of \(calls.calls.count)")
        if unanswered > 0 { print("The model gave no reply for \(unanswered) of \(monologues.monologues.count): is it downloaded and loading? (Settings → AI)") }
        if let out { try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8) }
        let met = found >= 36 && falseItems <= 4 && walk02None && negativesKept == 0 && overTime == 0
        print(met ? "SOLO_BENCH_MET" : "SOLO_BENCH_UNDER_TARGET")
        return met ? 0 : 1
    }
}
