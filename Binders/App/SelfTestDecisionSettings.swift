import Foundation
import BindersKit

extension SelfTest {
    /// Settings → AI → Decision model and Settings → Agents → Sorting new cards, without drawing anything (part of
    /// `--selftest-router`): every row's words (DecisionModelText) in the states the design lists, Also on this Mac, a
    /// choice kept among the recent ones, a Tev1 name refused by Another Hugging Face Model… and by MLXModels' download,
    /// and that no line exclaims or says "successfully". A DecisionModels of its own, whose factory makes no backend, so
    /// the router's own is left as it was; the preferences it writes are this throwaway folder's, and put back.
    @MainActor
    static func decisionSettingsSelfTest(folder: URL, check: (Bool, String) -> Void) async {
        var shown: [String] = []
        func rowA(_ choice: DecisionChoice, _ state: DecisionBackendState?, refused: String? = nil, deleted: String? = nil,
                  downloading: Double? = nil, failure: String? = nil, bytes: Int64? = nil, trouble: Bool = false) -> DecisionModelText.Where {
            let row = DecisionModelText.rowA(choice, state: state, stored: choice.stored, appleSilicon: true, refused: refused, deleted: deleted,
                                             downloading: downloading, failure: failure, bytes: bytes, trouble: trouble)
            shown.append(row.line)
            return row
        }
        func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

        // MARK: Row A, where the model is
        let tev1Bytes: Int64 = 1_524_861_517
        let checking = rowA(.tev1, .checking)
        check(checking == .init("Checking Tev1 0.8B's folder, once, before Binders uses it…", .waiting),
              "row A while Tev1 0.8B's folder is checked: \(checking.line)")
        let here = rowA(.tev1, .ready(bytes: tev1Bytes))
        check(here == .init("On this Mac · \(size(tev1Bytes))", .ready, .showInFinder), "row A for Tev1 0.8B on this Mac: \(here.line), Show in Finder")
        let loadedHere = rowA(.tev1, .loaded(bytes: tev1Bytes, resident: 1_504_706_560, until: nil))
        check(loadedHere == here, "and the same while it's in memory")
        let missing = rowA(.tev1, .unavailable(.noFolder))
        check(missing == .init("Not on this Mac, and Binders can't download it until Together publishes its weights' licence: copy its folder, tev1-0.8b-mlx-bf16, into Binders' Models folder.",
                               .plain, .showModelsFolder),
              "row A for Tev1 0.8B without its folder says why it can't be downloaded, with Show Models Folder: \(missing.line)")
        let refusedRow = rowA(.tev1, .ready(bytes: tev1Bytes), refused: MLXModels.tev1Refused)
        check(refusedRow == .init("Binders doesn't download Tev1 0.8B until Together publishes its weights' licence: choose Tev1 0.8B as the decision model, and copy its folder, tev1-0.8b-mlx-bf16, into Binders' Models folder.",
                                  .problem, .showModelsFolder),
              "row A for a Hugging Face name taken for Tev1, until the next choice: \(refusedRow.line)")
        let small = rowA(.tev1, .unavailable(.thisMac(MLXDecisionBackend.needsMemory)))
        check(small == .init(MLXDecisionBackend.needsMemory + ".", .plain) && small.line.hasPrefix("Built-in decision models need a Mac with 16 GB of memory; this one has "),
              "row A on a Mac under 16 GB: \(small.line)")
        let refusedFolder = rowA(.tev1, .unavailable(.folder("its tokenizer.json is over 64 MB")))
        check(refusedFolder == .init("Its folder isn't usable: its tokenizer.json is over 64 MB.", .problem, .showInFinder), "row A for Tev1's folder refused: \(refusedFolder.line)")
        let hfID = "mlx-community/Qwen3.5-4B-MLX-4bit"
        let hf = DecisionChoice.huggingFace(hfID)
        let downloading = rowA(hf, .unavailable(.notDownloaded), downloading: 0.42)
        check(downloading == .init("Downloading Qwen3.5-4B-MLX-4bit… 42%", .downloading(0.42), .cancel), "row A while a Hugging Face model downloads: \(downloading.line), Cancel")
        let downloaded = rowA(hf, .ready(bytes: 2_400_000_000))
        check(downloaded == .init("Downloaded · \(size(2_400_000_000))", .ready, .delete), "row A for a downloaded model: \(downloaded.line), Delete")
        let notYet = rowA(hf, .unavailable(.notDownloaded))
        check(notYet == .init("Not downloaded yet.", .plain, .download), "row A for one not downloaded yet: Download")
        let failed = rowA(hf, .unavailable(.notDownloaded), failure: "The download of “\(hfID)” failed (HTTP 500).")
        check(failed == .init("The download of “\(hfID)” failed (HTTP 500).", .problem, .download), "row A for a download that failed, in the download's own words")
        let moved = rowA(hf, .unavailable(.notDownloaded), deleted: hfID)
        check(moved == .init("Moved \(hfID) to the Trash. Download it again, or choose another model.", .plain, .download), "row A once it's deleted: \(moved.line)")
        let folderPath = NSHomeDirectory() + "/Models/Pocketfold Decider"
        let chosenFolder = DecisionChoice.folder(folderPath)
        let fromFolder = rowA(chosenFolder, .ready(bytes: 2_400_000_000))
        check(fromFolder == .init("From ~/Models/Pocketfold Decider · \(size(2_400_000_000))", .ready, .showInFinder), "row A for a folder chosen: \(fromFolder.line)")
        let noModel = rowA(chosenFolder, .unavailable(.folder(MLXDecisionBackend.noModel)))
        check(noModel == .init("There's no MLX model in that folder: it needs its config.json and .safetensors weights.", .problem), "row A for a folder with no model in it")
        let gone = rowA(chosenFolder, .unavailable(.noFolder))
        check(gone == .init("That folder isn't there any more: choose it again with Use a Model Folder….", .problem), "row A for a folder that's gone")
        let noK = "in its tokenizer, “K” isn't a token of its own, and Binders reads the model's choice as one letter from A to X"
        let cantAnswer = rowA(chosenFolder, .unavailable(.cantAnswer(noK)))
        check(cantAnswer == .init("It can't sort cards: \(noK).", .problem, .showInFinder), "row A for a model that can't answer with a letter: \(cantAnswer.line)")
        let tooBigWhy = MLXDecisionBackend.tooBig(9_300_000_000, memory: 16 * 1_073_741_824)
        let tooBig = rowA(chosenFolder, .unavailable(.thisMac(tooBigWhy)))
        check(tooBig == .init("At 9.3 GB it's more than a quarter of this Mac's 16 GB of memory: choose a smaller model to sort cards.", .problem, .showInFinder),
              "row A for a model too big for this Mac: \(tooBig.line)")
        // The same for a model Binders downloaded: its size and Delete, as nothing else in the section removes it.
        let refusedDownload = DecisionChoice.huggingFace("mlx-community/Qwen3.5-9B-MLX-4bit")
        let downloadCantAnswer = rowA(refusedDownload, .unavailable(.cantAnswer(noK)), bytes: 5_200_000_000)
        check(downloadCantAnswer == .init("Downloaded · 5.2 GB, but it can't sort cards: \(noK). Delete it, or choose another model.", .problem, .delete),
              "row A for a download that can't answer with a letter: \(downloadCantAnswer.line), Delete")
        let downloadTooBig = rowA(refusedDownload, .unavailable(.thisMac(tooBigWhy)), bytes: 9_300_000_000)
        check(downloadTooBig == .init("At 9.3 GB it's more than a quarter of this Mac's 16 GB of memory: choose a smaller model to sort cards, and Delete this one to free its space.", .problem, .delete),
              "row A for a download too big for this Mac: \(downloadTooBig.line), Delete")
        let tev1CantAnswer = rowA(.tev1, .unavailable(.cantAnswer(noK)))
        check(tev1CantAnswer.action == .showInFinder, "row A for Tev1's folder that can't answer: Show in Finder")
        let server = DecisionChoice.server("http://127.0.0.1:18708")
        let asking = rowA(server, .checking)
        check(asking == .init("Asking 127.0.0.1:18708 what it serves…", .waiting), "row A at a server's first contact: \(asking.line)")
        let answers = rowA(server, .answering(names: ["kev-latest"]))
        check(answers == .init("Answers at 127.0.0.1:18708 as kev-latest.", .ready, .checkAgain), "row A for a server that answers: \(answers.line), Check Again")
        let display = "127.0.0.1:18708"
        let serverLines: [(JevDecisionBackend.Trouble, String, Bool)] = [
            (.nothingAnswers, "Nothing answers at 127.0.0.1:18708. Start your decision server there, then Check Again. Meanwhile Binders sorts without it.", false),
            (.hanging, "The server at 127.0.0.1:18708 took more than 4 seconds twice. Binders asks it again in a minute; meanwhile it sorts without it.", false),
            (.lookupSlow, "This Mac didn't say where localhost is within half a second, so Binders didn't connect. Use 127.0.0.1 and the port, or Check Again.", false),
            (.wantsKey, "The server at 127.0.0.1:18708 wants a key. Binders sends none to a decision server: start it without one, listening on this Mac only.", true),
            (.notADecisionServer(status: 404, path: "/v1/systemone"), "127.0.0.1:18708 answered, but not as a decision server (HTTP 404 for /v1/systemone).", true),
            (.noProbabilities, "The server at 127.0.0.1:18708 answered, but not with a probability for each option.", true),
        ]
        for (trouble, line, problem) in serverLines {
            let row = rowA(server, .unavailable(.unreachable(trouble.line(display))), trouble: trouble.isProblem)
            check(row == .init(line, problem ? .problem : .plain, .checkAgain), "row A for a server: \(row.line)")
        }
        let lan = LoopbackRule.check("http://192.168.1.20:8008")
        if case .failure(let refusal) = lan {
            let refusedServer = rowA(.server("http://192.168.1.20:8008"), .unavailable(.address(refusal.words)))
            check(refusedServer == .init(refusal.words, .problem) && refusal.words.contains("isn't one of its own addresses"),
                  "row A for an address that isn't this Mac's: \(refusedServer.line)")
        } else {
            check(false, "192.168.1.20 is refused")
        }
        let off = rowA(.off, nil)
        check(off == .init("Off. Binders sorts as it does without a decision model: " + RouterStatusSection.meanwhile),
              "row A for Off says what Binders does without a decision model: \(off.line)")
        let intel = DecisionModelText.rowA(.off, state: nil, stored: "", appleSilicon: false)
        let intelChosen = DecisionModelText.rowA(.off, state: nil, stored: "tev1", appleSilicon: false)
        let intelOff = DecisionModelText.rowA(.off, state: nil, stored: "off", appleSilicon: false)
        shown += [intel.line, intelOff.line]
        check(intel == .init("Off. Built-in decision models need a Mac with Apple silicon.", meanwhile: RouterStatusSection.meanwhile) && intelChosen == intel
              && intelOff == off, "on an Intel Mac, a built-in model chosen or none reads as Off and says why; Off chosen says Off")

        // MARK: Rows B, C and D
        let now = Date()
        let resident: Int64 = 1_504_706_560
        let memory = ByteCountFormatter.string(fromByteCount: resident, countStyle: .memory)
        let rowsC = [
            DecisionModelText.rowC("Tev1 0.8B", state: .ready(bytes: tev1Bytes), alsoLanguageModel: false, now: now),
            DecisionModelText.rowC("Tev1 0.8B", state: .loaded(bytes: tev1Bytes, resident: resident, until: now.addingTimeInterval(270)), alsoLanguageModel: false, now: now),
            DecisionModelText.rowC("Tev1 0.8B", state: .loaded(bytes: tev1Bytes, resident: resident, until: now.addingTimeInterval(30)), alsoLanguageModel: false, now: now),
            DecisionModelText.rowC("Tev1 0.8B", state: .loaded(bytes: tev1Bytes, resident: resident, until: nil), alsoLanguageModel: false, now: now),
            DecisionModelText.rowC("Qwen3.5-4B-MLX-4bit", state: .ready(bytes: 1), alsoLanguageModel: true, now: now),
        ]
        shown += rowsC.compactMap { $0 }
        check(rowsC == ["Tev1 0.8B is not in memory. It loads when a card comes in.",
                        "Tev1 0.8B is in memory (\(memory)) · frees in 4 min unless used again",
                        "Tev1 0.8B is in memory (\(memory)) · frees in under a minute unless used again",
                        "Tev1 0.8B is in memory (\(memory)) · kept loaded",
                        "Qwen3.5-4B-MLX-4bit is not in memory. It loads when a card comes in. It's also your language model: sorting keeps its own copy in memory."]
              && DecisionModelText.rowC("Tev1 0.8B", state: .checking, alsoLanguageModel: false) == nil,
              "row C says whether it's in memory and until when, and that the language model's folder is a second copy: \(rowsC[1] ?? "none")")
        check(DecisionModelText.idleChoices.map(\.minutes) == [5, 15, 30, 60, 0] && DecisionModelText.idleChoices.first?.label == "after 5 minutes idle"
              && DecisionModelText.freeItsMemory == "Free its memory" && AppSettings.shared.decisionIdleMinutes == 5,
              "row B, Free its memory, has the language model's five choices, after 5 minutes idle by default")
        let stopped = DecisionModelText.rowD("Tev1 0.8B", why: MLXDecisionBackend.markerFound)
        shown.append(stopped)
        check(stopped == "Tev1 0.8B stopped: Binders quit while its decision model was working. Until you try again, Binders sorts without it.",
              "row D, beside Try Again: \(stopped)")

        // MARK: Row E, the measure, beside Tev1 0.8B's
        let at = Date(timeIntervalSince1970: 1_792_425_600)
        let day = at.formatted(.dateTime.day().month(.abbreviated))
        let decider = DecisionIdentity(fingerprint: "mlx1-0123456789abcdef01234567", reader: DecisionReader.chat.id)
        func measured(start: Double?, noStart: DecisionMeasure.NoStart?, binderOK: Int = 150, agentOK: Int = 120, starts: Int, wrong: Int,
                      level: Double, answeredBy: [String]? = nil, verdict: DecisionMeasure.TestVerdict? = nil) -> DecisionModelText.Measure? {
            let measure = DecisionMeasure(key: decider.key, fingerprint: decider.fingerprint, reader: decider.reader, at: at,
                                          bands: .init(start: start, suggest: noStart == .namesNone ? nil : 0.5, generalBelow: 0.45, generalBelowTitlesOnly: 0.33),
                                          noStart: noStart,
                                          test: .init(items: 167, binderOK: binderOK, agentOK: agentOK, score: Double(binderOK + agentOK) / 334, starts: starts,
                                                      wrongStarts: wrong, level: level),
                                          answeredBy: answeredBy)
            let bands = RouterBands(start: verdict == nil ? start : nil, suggest: 0.5, generalBelow: 0.45, generalBelowTitlesOnly: 0.33)
            let row = DecisionModelText.rowE(ResolvedBands(identity: decider, bands: bands, golden: [[0.5, 0.5]], source: .measured(at), measure: measure, verdict: verdict))
            if let row { shown.append(row.line) }
            return row
        }
        let unmeasured = DecisionModelText.rowE(ResolvedBands(identity: decider, bands: DecisionBands.unmeasured, golden: nil, source: .unmeasured))
        check(unmeasured == .init(line: "Not measured yet: it names agents on Give to and starts none on its own. Measuring sorts 278 made-up cards that come with Binders, in about a minute for a small model, to find how sure it must be to start one.",
                                  button: "Measure"),
              "row E for a model not measured yet, with Measure")
        let builtIn = DecisionModelText.rowE(ResolvedBands(identity: DecisionBands.tev1BF16, bands: DecisionBands.tev1?.bands ?? DecisionBands.unmeasured,
                                                           golden: DecisionBands.tev1?.golden, source: .builtIn))
        check(builtIn?.line == "Binders measured it on 278 made-up cards: score 0.79. Of the 167 kept for scoring, its first pick was the right binder for 147 and the right agent, or nobody, for 118. It would have started 4 agents on its own, none of them wrong. It starts an agent you let start on its own at a level of 0.97 or more. In Auto it hands a to-do or an idea you say on your own to an agent that drafts first at a level of 0.60 or more, or to the agent you name: on the cards kept for scoring it would have handed over 37, all of them to the right agent."
              && builtIn?.button == "Measure on This Mac" && builtIn?.help == "Its score to four places: 0.7934.",
              "row E for Tev1 0.8B on Binders' own numbers, with Measure on This Mac: \(builtIn?.line ?? "none")")
        // A record from before Auto (neither an Auto level nor a reason for none): Auto waits for Measure Again.
        let autoBefore = " It hands nothing over in Auto until it's measured again: Measure Again."
        let withStart = measured(start: 0.98, noStart: nil, starts: 3, wrong: 0, level: 0.98)
        check(withStart?.line == "Measured on \(day): score 0.81, beside Tev1 0.8B's 0.79. Of the 167 cards kept for scoring, its first pick was the right binder for 150 (Tev1: 147) and the right agent, or nobody, for 120 (Tev1: 118). It would have started 3 agents on its own, none of them wrong (Tev1: 4, none wrong). It starts an agent you let start on its own at a level of 0.98 or more.\(autoBefore)"
              && withStart?.button == "Measure Again" && withStart?.help == "Its score to four places: 0.8084 (Tev1 0.8B: 0.7934).",
              "row E for a model measured with a start level, beside Tev1's: \(withStart?.line ?? "none")")
        let noLevel = measured(start: nil, noStart: .noLevel, starts: 5, wrong: 1, level: 0.95)
        check(noLevel?.line == "Measured on \(day): score 0.81, beside Tev1 0.8B's 0.79. Of the 167 cards kept for scoring, its first pick was the right binder for 150 (Tev1: 147) and the right agent, or nobody, for 120 (Tev1: 118). At a level of 0.95 it would have started 5 agents on its own, 1 of them wrong (Tev1: 4 at 0.97, none wrong). It names agents on Give to but starts none on its own: on the made-up cards, at every level from 0.95, it was as sure of a wrong agent as of right ones.\(autoBefore)",
              "row E for a model measured with no start level counts its starts at 0.95: \(noLevel?.line ?? "none")")
        let tail = "It names agents on Give to but starts none on its own: "
        let few = measured(start: nil, noStart: .fewStarts, starts: 1, wrong: 0, level: 0.95)
        let testWrong = measured(start: nil, noStart: .testWrong, starts: 2, wrong: 1, level: 0.97)
        let testFew = measured(start: nil, noStart: .testFew, starts: 0, wrong: 0, level: 0.97)
        let several = measured(start: nil, noStart: .severalModels, starts: 4, wrong: 0, level: 0.97, answeredBy: ["english", "multilingual"])
        let before = measured(start: nil, noStart: .testBefore, starts: 4, wrong: 0, level: 0.97,
                              verdict: .init(key: decider.key, at: at, level: 0.97, noStart: .testWrong))
        let namesNone = measured(start: nil, noStart: .namesNone, starts: 0, wrong: 0, level: 0.95)
        check(few?.line.hasSuffix("At a level of 0.95 it would have started 1 agent on its own, and it was the right one (Tev1: 4 at 0.97, none wrong). \(tail)it was that sure of fewer than 2 agents.\(autoBefore)") == true
              && testWrong?.line.hasSuffix("At a level of 0.97 it would have started 2 agents on its own, 1 of them wrong (Tev1: 4, none wrong). \(tail)on the cards kept for scoring it would have started a wrong agent at the level its other cards found.\(autoBefore)") == true
              && testFew?.line.hasSuffix("At a level of 0.97 it would have started no agent on its own (Tev1: 4, none wrong). \(tail)at the level its other cards found, it would have started too few agents on the cards kept for scoring to be trusted with starts: it needs at least 1 there and 5 in all.\(autoBefore)") == true
              && several?.line.hasSuffix("\(tail)the server answered with more than one model (english, multilingual), so no one model was held to a level: start it with one.\(autoBefore)") == true
              && before?.line.hasSuffix("\(tail)its measure on \(day) took starting away on the cards kept for scoring, and measuring again doesn't give it back.\(autoBefore)") == true
              && namesNone?.line.hasSuffix("(Tev1: 118). It names no agent on Give to: fewer than 7 in 10 of the agents it named were right, at every level.\(autoBefore)") == true,
              "row E says why a measured model starts nothing, for each reason, its starts counted at the level dev found: \(testWrong?.line ?? "none")")
        // Auto's sentence for a model measured with this build: its level and counts beside Tev1's, or why none.
        func autoMeasured(level: Double?, noAuto: MeasureRules.NoAuto?, test: DecisionMeasure.AutoCounts?) -> String {
            let measure = DecisionMeasure(key: decider.key, fingerprint: decider.fingerprint, reader: decider.reader, at: at,
                                          bands: .init(start: nil, suggest: 0.5, generalBelow: 0.45, generalBelowTitlesOnly: 0.33, auto: level),
                                          noStart: .noLevel, noAuto: noAuto, auto: .init(dev: nil, test: test))
            let line = DecisionModelText.autoLine(ResolvedBands(identity: decider, bands: measure.bands?.routerBands ?? DecisionBands.unmeasured,
                                                                golden: [[0.5, 0.5]], source: .measured(at), measure: measure))
            shown.append(line)
            return line
        }
        let autoLevel = autoMeasured(level: 0.7, noAuto: nil, test: .init(picks: 25, right: 23, falseAssignments: 1, named: 4, namedRight: 4))
        let autoShare = autoMeasured(level: nil, noAuto: .devShare, test: nil), autoFew = autoMeasured(level: nil, noAuto: .devFew, test: nil)
        let autoTest = autoMeasured(level: nil, noAuto: .testShare, test: nil)
        check(autoLevel == "In Auto it hands one over at a level of 0.70 or more (Tev1: 0.60): on the cards kept for scoring it would have handed over 29, 27 of them to the right agent (Tev1: 37, all right)."
              && autoShare == "It hands nothing over in Auto: of what it would have handed over on the made-up cards, fewer than 4 in 5 went to the right agent, at every level."
              && autoFew == "It hands nothing over in Auto: on the made-up cards it would have handed an agent that drafts first fewer than 5 things, at every level."
              && autoTest == "It hands nothing over in Auto: of what it would have handed over on the cards kept for scoring, fewer than 4 in 5 went to the right agent, at the level its other cards found.",
              "row E's Auto sentence for a measured model, with a level and without: \(autoLevel)")
        let changedRecord = DecisionModelText.rowE(ResolvedBands(identity: decider, bands: DecisionBands.unmeasured, golden: nil, source: .unmeasured, changed: true))
        check(changedRecord?.line == "Its measure was changed outside Binders: Measure Again. Until then it names agents on Give to, starts none on its own and hands nothing over in Auto."
              && changedRecord?.button == "Measure Again", "row E for a measure changed outside Binders: \(changedRecord?.line ?? "none")")
        shown += [changedRecord?.line].compactMap { $0 }
        let formerMeasure = DecisionMeasure(key: "jev1-000000000000000000000000 jev.1", at: at)
        let changedServer = DecisionModelText.rowE(ResolvedBands(identity: decider, bands: DecisionBands.unmeasured, golden: nil, source: .unmeasured), former: formerMeasure)
        check(changedServer == .init(line: "Its answers differ from when it was measured on \(day), so Binders takes it for another model: it names agents and starts none on its own until you measure it again.",
                                     button: "Measure"),
              "row E for a server whose answers changed since its measure: \(changedServer?.line ?? "none")")
        let tooSlow = DecisionModelText.rowE(ResolvedBands(identity: decider, bands: DecisionBands.unmeasured, golden: nil, source: .unmeasured),
                                             stopped: DecisionMeasureRun.Stop.tooSlow.words)
        let cancelled = DecisionModelText.rowE(ResolvedBands(identity: decider, bands: DecisionBands.unmeasured, golden: nil, source: .unmeasured),
                                               stopped: DecisionMeasureRun.cancelled)
        check(tooSlow?.stopped == DecisionMeasureRun.Stop.tooSlow.words && tooSlow?.stoppedIsProblem == true
              && cancelled?.stopped == "Cancelled. Nothing was kept." && cancelled?.stoppedIsProblem == false,
              "row E says why a measure stopped, in the problem style, and a Cancel plainly")
        shown += [unmeasured?.line, builtIn?.line, changedServer?.line, tooSlow?.stopped, cancelled?.stopped].compactMap { $0 }
        let progress = DecisionModelText.measuring(MeasureProgress(done: 140, of: 389, started: now.addingTimeInterval(-14)), now: now)
        let early = DecisionModelText.measuring(MeasureProgress(done: 9, of: 389, started: now.addingTimeInterval(-1)), now: now)
        let slow = DecisionModelText.measuring(MeasureProgress(done: 140, of: 389, started: now.addingTimeInterval(-140)), now: now)
        shown += [progress.line, progress.left ?? "", slow.left ?? ""]
        check(progress.line == "Sorting made-up cards: 140 of 389…" && progress.left == "about 25 s left" && early.left == nil && slow.left == "about 4 min left",
              "while a measure runs: \(progress.line) \(progress.left ?? "")")
        let differMeasured = DecisionModelText.rowF(nil, differ: true), differBuiltIn = DecisionModelText.rowF(ResolvedBands(identity: DecisionBands.tev1BF16,
            bands: DecisionBands.unmeasured, golden: nil, source: .builtIn), differ: true)
        shown += [differMeasured ?? "", differBuiltIn ?? ""]
        check(differMeasured == "Its numbers on this Mac differ from the ones it was measured with, so it names agents but starts none on its own. Measure it on this Mac to start agents again."
              && differBuiltIn == "Its numbers on this Mac differ from the ones Binders measured it with, so it names agents but starts none on its own. Measure it on this Mac to start agents again."
              && DecisionModelText.rowF(nil, differ: false) == nil,
              "row F, numbers that differ, for a measure and for Binders' own numbers")

        // MARK: Settings → Agents → Sorting new cards, and the start switch
        let sorting = [
            DecisionModelText.sortingModel(.tev1, state: .ready(bytes: tev1Bytes)),
            DecisionModelText.sortingModel(server, state: .answering(names: ["kev-latest"])),
            DecisionModelText.sortingModel(.off, state: nil),
            DecisionModelText.sortingModel(.tev1, state: .unavailable(.noFolder)),
            DecisionModelText.sortingModel(.tev1, state: .checking),
        ]
        shown += sorting
        check(sorting == ["Tev1 0.8B sorts new cards, on this Mac.", "Server at 127.0.0.1:18708 sorts new cards.",
                          "No decision model: Binders sorts new cards without one.",
                          "Tev1 0.8B can't sort cards now, so Binders sorts them without it. Settings → AI → Decision model says why.",
                          "Checking Tev1 0.8B's folder, once, before Binders uses it…"],
              "Sorting new cards names the decision model in one line, a server without \"on this Mac\": \(sorting[1])")
        let canStart = DecisionModelText.sortingStarts(canStart: true, why: nil, differ: false)
        let offStarts = DecisionModelText.sortingStarts(canStart: false, why: "the decision model is off", differ: false)
        let waiting = DecisionModelText.routerWaiting("Tev1 0.8B can't sort cards now")
        shown += [canStart.line, offStarts.line, waiting, DecisionModelText.sortingFooter]
        check(canStart == ("An agent you let start on cards Binders sends it can start now.", false)
              && offStarts == ("No agent starts on its own now: the decision model is off.", false)
              && DecisionModelText.sortingStarts(canStart: false, why: "x", differ: true).needsYou
              && waiting == "For now, Binders names it on Give to and waits for your tap: Tev1 0.8B can't sort cards now. Settings → AI → Decision model says more."
              && DecisionModelText.sortingFooter == "For a card or a to-do that doesn't say where it goes, Binders picks the binder, and the agent whose work it is, which Give to then names.",
              "Sorting new cards says whether an agent can start, needing you only when numbers differ, and the start switch says why not: \(waiting)")

        // MARK: The menu, and Also on this Mac
        let items = [DecisionModelText.tev1Item(here: true, enoughMemory: true), DecisionModelText.tev1Item(here: false, enoughMemory: true),
                     DecisionModelText.tev1Item(here: true, enoughMemory: false), DecisionModelText.alsoItem(.huggingFace("local/tev1-0.8b-mlx-4bit"), measured: false),
                     DecisionModelText.alsoItem(server, measured: true), DecisionModelText.alsoItem(chosenFolder, measured: false)]
        shown += items + [DecisionModelText.anotherModel, DecisionModelText.modelFolder, DecisionModelText.useServer, DecisionModelText.off, DecisionModelText.intelOnly]
        check(items == ["Tev1 0.8B · on this Mac", "Tev1 0.8B · add it from its folder", "Tev1 0.8B · needs 16 GB of memory", "local/tev1-0.8b-mlx-4bit",
                        "Server at 127.0.0.1:18708 · measured", "Pocketfold Decider"]
              && [DecisionModelText.anotherModel, DecisionModelText.modelFolder, DecisionModelText.useServer] == ["Another Hugging Face Model…", "Use a Model Folder…", "Use a Decision Server on This Mac…"],
              "the menu names each choice by what people recognise: \(items.joined(separator: "; "))")
        let eightBit = AppPaths.support.appendingPathComponent("Models/tev1-0.8b-mlx-8bit").path
        let also = DecisionModelSection.alsoHere(used: ["/Users/sam/Models/Pocketfold Decider", "http://127.0.0.1:18708", "mlx-community/m", "tev1", "off"],
                                                 installed: ["mlx-community/m", "local/tev1-0.8b-mlx-4bit"], tev1Copies: [eightBit],
                                                 current: .folder("/Users/sam/Models/Pocketfold Decider"), appleSilicon: true)
        let alsoIntel = DecisionModelSection.alsoHere(used: ["/Users/sam/Models/Pocketfold Decider", "http://127.0.0.1:18708"], installed: ["mlx-community/m"],
                                                      tev1Copies: [eightBit], current: .off, appleSilicon: false)
        check(also == [.folder("/Users/sam/Models/Pocketfold Decider"), .server("http://127.0.0.1:18708"), .huggingFace("mlx-community/m"),
                       .huggingFace("local/tev1-0.8b-mlx-4bit"), .folder(eightBit)]
              && alsoIntel == [.server("http://127.0.0.1:18708")],
              "Also on this Mac: the one chosen, the ones chosen before, the downloads and the other Tev1 conversions, each once, never Tev1 or Off; servers only on an Intel Mac")

        // MARK: A choice kept, and a Tev1 name refused
        let settings = AppSettings.shared
        let storedBefore = settings.decisionModel, usedBefore = settings.decisionModelsUsed, endpointBefore = settings.mlxEndpoint
        let chooser = DecisionModels(choice: .tev1, measures: DecisionMeasureStore(url: folder.appendingPathComponent("router-test-settings-measures.json")),
                                     fingerprints: FolderFingerprints(url: folder.appendingPathComponent("router-test-settings-fingerprints.json")),
                                     makeBackend: { _ in nil })
        for index in 0..<8 { chooser.use(.huggingFace("local/decider-\(index)")) }
        chooser.use(.off)
        check(settings.decisionModel == "off" && chooser.choice == .off
              && settings.decisionModelsUsed == (2...7).reversed().map { "local/decider-\($0)" },
              "a choice is kept in the preferences and first among the recent ones, 6 at most, and Off isn't kept there: \(settings.decisionModelsUsed.first ?? "none")")
        let tev1Names = ["togethercomputer/Tev1-0.8B-experimental", "someone/TEV1-0.8b-mlx", "tev1fan/model",
                         "togethercomputer/Tev%31-0.8B-experimental", "togethercomputer/%54ev1-0.8B-experimental"]
        let refusals = tev1Names.map { chooser.useHuggingFace($0) }
        check(refusals.allSatisfy { $0 == MLXModels.tev1Refused } && settings.decisionModel == "off" && chooser.choice == .off
              && !settings.decisionModelsUsed.contains { ModelNames.isTev1($0) },
              "Another Hugging Face Model… with a Tev1 name stores nothing, and row A has the Tev1 line until the next choice")
        let ownerless = chooser.useHuggingFace("Qwen3.5-4B-MLX-4bit")
        check(ownerless == DecisionModels.needsOwner && settings.decisionModel == "off", "a name without its owner isn't stored either: \(ownerless ?? "stored")")
        let malformed = ["mlx-community/Qwen3.5-4B?x=1", "mlx-community/Qwen3.5 4B", "mlx-community/Qwen3.5/4B", "mlx-community/%51wen3.5-4B"]
        check(malformed.allSatisfy { chooser.useHuggingFace($0) == DecisionModels.needsOwner } && settings.decisionModel == "off",
              "a name with anything but a model's letters, digits, \".\", \"_\" and \"-\" isn't stored, as it goes into the download's address")
        check(chooser.useHuggingFace("  mlx-community/Qwen3.5-4B-MLX-4bit ") == nil && settings.decisionModel == "mlx-community/Qwen3.5-4B-MLX-4bit"
              && chooser.choice == .huggingFace("mlx-community/Qwen3.5-4B-MLX-4bit"), "a model's whole name is chosen, trimmed")
        // Nothing reaches the network whatever the refusal does: the downloads' address is this Mac's discard port.
        settings.mlxEndpoint = "http://127.0.0.1:9"
        let downloads = MLXModels.shared
        for name in tev1Names { downloads.download(name) }
        check(tev1Names.allSatisfy { downloads.progress[$0] == nil && downloads.failures[$0] == MLXModels.tev1Refused },
              "MLXModels' download of a Tev1 name, from either menu, starts nothing, and its failure is the Tev1 line")
        for name in malformed { downloads.download(name) }
        check(malformed.allSatisfy { downloads.progress[$0] == nil && downloads.failures[$0] == MLXModels.notAName },
              "MLXModels' download of anything but a model's name starts nothing, and says what to type")
        // The fetcher itself refuses them, before any address is made: --selftest-mlx and every other path go through it.
        var fetcherRefusals: [String] = []
        for name in ["togethercomputer/Tev1-0.8B-experimental", "togethercomputer/Tev%31-0.8B-experimental", "mlx-community/x?y"] {
            do {
                try await MLXDownload(id: name, endpoint: "http://127.0.0.1:9", token: nil) { _ in }.run()
                fetcherRefusals.append("fetched")
            } catch {
                fetcherRefusals.append(error.localizedDescription)
            }
        }
        check(fetcherRefusals == [MLXModels.tev1Refused, MLXModels.tev1Refused, MLXModels.notAName],
              "MLXDownload refuses a Tev1 name, escaped or not, and a name that isn't a model's, before it asks anything: \(fetcherRefusals)")
        settings.mlxEndpoint = endpointBefore
        settings.decisionModel = storedBefore
        settings.decisionModelsUsed = usedBefore
        shown += [MLXModels.tev1Refused, MLXModels.notAName, DecisionModels.needsOwner, DecisionModelText.otherMessage, DecisionModelText.folderMessage, DecisionModelText.serverAbout,
                  DecisionModelText.footer, DecisionModelText.deleteMessage, DecisionModelText.deleteTitle("Qwen3.5-4B-MLX-4bit")]

        // MARK: The copy
        let loud = shown.filter { $0.contains("!") || $0.lowercased().contains("successfully") }
        check(loud.isEmpty && shown.count > 60, "none of Settings' \(shown.count) decision model lines exclaims or says \"successfully\"\(loud.isEmpty ? "" : ": \(loud)")")
    }
}
