import BindersKit
import SwiftUI

/// Capture → Calibrate: the bench for things said to yourself. Four runs (your phrases, someone else's, TV or a podcast,
/// the 40 lines), the voice threshold they suggest with a button to use it, and the results: what each run got through,
/// as a report, a CSV, or deleted.
struct CalibrationView: View {
    /// The phrases said in a run: lane Y2's group without a cue, and its chatter, only in Auto.
    static var phrases: [MomentBench.Phrase] { MomentBench.phrases(inAuto: MomentCenter.shared.mode == .auto) }

    @State private var bench = CalibrationBench.shared
    @State private var sharing: SharedFile?
    @State private var confirmingDelete = false
    @State private var using: MomentBench.Threshold?

    var body: some View {
        let report = bench.report
        List {
            Section {
                Text("Say phrases one at a time, and Binders runs each through the checks All-day capture uses: the quiet around it, a cue in the words, your voice, and Apple Intelligence where this iPhone has it. It keeps the scores and timings on this iPhone. It never keeps the audio or what was said.")
                    .font(.subheadline).foregroundStyle(Palette.muted)
                    .benchRow()
                if bench.voicePrint == nil {
                    TeachVoiceFirst { bench.refresh() }
                        .benchRow()
                }
                if !OnDeviceModel.isAvailable {
                    Label("Apple Intelligence isn't on this iPhone, so the fourth check is left out, as it is in capture.", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(Palette.muted)
                        .benchRow()
                }
            }

            Section {
                NavigationLink { BenchRunView(run: .phrases) } label: {
                    BenchRunRow(title: "Your phrases", detail: "\(Self.phrases.count) phrases in \(Set(Self.phrases.map(\.group)).count) groups",
                                count: said(.phrases), of: Self.phrases.count)
                }
                .benchRow()
                NavigationLink { BenchRunView(run: .otherVoices) } label: {
                    BenchRunRow(title: "Someone else reading", detail: "The same phrases, in another voice", count: said(.otherVoices),
                                of: Self.phrases.count)
                }
                .benchRow()
                NavigationLink { TimedRunView() } label: {
                    BenchRunRow(title: "TV or a podcast", detail: bench.isTimedRunGoing ? "Listening now" : "A timed run, the screen can lock",
                                minutes: report.mediaSeconds)
                }
                .benchRow()
                NavigationLink { BenchRunView(run: .script) } label: {
                    BenchRunRow(title: "The 40 lines", detail: "Automatic mode, line by line", count: report.scriptPassed, of: MomentBench.script.count,
                                unit: "passed")
                }
                .benchRow()
            } header: {
                Text("Runs")
            }

            Section {
                LabeledContent("Now") {
                    Text(thresholdNow).font(Typeface.time(.body))
                }
                .benchRow()
                if let suggestion = report.voice.suggestion {
                    LabeledContent {
                        Text(String(format: "%.2f", suggestion.value)).font(Typeface.count(.body))
                    } label: {
                        Text(verbatim: "For about 1% of other voices")
                    }
                    .benchRow()
                    Text(suggestionLine(suggestion, report.voice))
                        .font(.footnote).foregroundStyle(Palette.muted)
                        .benchRow()
                    if abs(suggestion.value - Double(bench.threshold)) >= 0.005 {
                        Button {
                            using = suggestion
                        } label: {
                            Label("Use \(String(format: "%.2f", suggestion.value))", systemImage: "checkmark.circle")
                        }
                        .foregroundStyle(Palette.accentText)
                        .accessibilityIdentifier("benchUseThreshold")
                        .benchRow()
                    }
                } else {
                    Text("No clips of other voices yet. Run Someone else reading, or TV or a podcast, and the threshold for about 1% of them shows here.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                        .benchRow()
                }
                if bench.thresholdSet != nil {
                    Button {
                        bench.resetThreshold()
                    } label: {
                        Label("Reset to \(String(format: "%.2f", VoicePrint.defaultMomentThreshold))", systemImage: "arrow.uturn.backward")
                    }
                    .foregroundStyle(Palette.accentText)
                    .accessibilityIdentifier("benchResetThreshold")
                    .benchRow()
                }
                Text(startBarLine(report.voice))
                    .font(.footnote).foregroundStyle(Palette.muted)
                    .benchRow()
                // The start bar on its own: when the voice threshold is already the one suggested, Use isn't offered.
                if let bar = MomentBench.startBarOffer(current: bench.startBar.map(Double.init), others: report.voice.others,
                                                       notMe: report.voice.notMe, momentThreshold: Double(bench.threshold)) {
                    Button {
                        bench.setStartBar(bar)
                    } label: {
                        Label("Set Start Bar to \(String(format: "%.2f", bar))", systemImage: "checkmark.circle")
                    }
                    .foregroundStyle(Palette.accentText)
                    .accessibilityIdentifier("benchSetStartBar")
                    .benchRow()
                }
            } header: {
                Text("Voice threshold")
            } footer: {
                Text("How alike a voice must sound to yours before something said on its own can get through, set from clips of 2 to 5 seconds. Teaching your voice again goes back to \(String(format: "%.2f", VoicePrint.defaultMomentThreshold)).")
            }

            Section {
                NavigationLink { BenchResultsView() } label: {
                    Label("What the bench found", systemImage: "list.bullet.rectangle")
                }
                .benchRow()
                Button {
                    sharing = bench.csvFile().map(SharedFile.init)
                } label: {
                    Label("Export as CSV", systemImage: "square.and.arrow.up")
                }
                .foregroundStyle(Palette.accentText)
                .disabled(bench.store.results.isEmpty)
                .benchRow()
                Button {
                    confirmingDelete = true
                } label: {
                    Label("Delete All Results", systemImage: "trash")
                }
                .foregroundStyle(Palette.ink)
                .disabled(bench.store.results.isEmpty || bench.isTimedRunGoing)
                .benchRow()
            } header: {
                Text("Results")
            } footer: {
                Text("\(resultsCount). They stay on this iPhone until you delete them. The CSV has each clip's scores, timings and labels, and the phrase as it was shown.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("Calibrate")
        .onAppear {
            bench.refresh()
        }
        .confirmationDialog("Delete all calibration results?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete All Results", role: .destructive) { bench.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every score, timing and pass goes. The voice threshold stays as it is.")
        }
        .confirmationDialog(using.map { "Set the voice threshold to \(String(format: "%.2f", $0.value))?" } ?? "",
                            isPresented: Binding(get: { using != nil }, set: { if !$0 { using = nil } }), titleVisibility: .visible) {
            if let using {
                Button("Use \(String(format: "%.2f", using.value))") { bench.useThreshold(using.value) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let using { Text(useMessage(using, report.voice)) }
        }
        .sheet(item: $sharing) { file in
            ShareSheet(url: file.url) { _, _ in
                bench.shared(file.url)
                sharing = nil
            }
        }
    }

    private func said(_ run: MomentBench.Run) -> Int { bench.results(run).count }

    private var thresholdNow: String {
        let value = String(format: "%.2f", bench.threshold)
        guard let set = bench.thresholdSet else { return "\(value), the default" }
        return "\(value), set \(set.formatted(date: .abbreviated, time: .omitted))"
    }

    private var resultsCount: String {
        let count = bench.store.results.count
        return count == 1 ? "1 clip scored" : "\(count) clips scored"
    }

    private func suggestionLine(_ suggestion: MomentBench.Threshold, _ voice: MomentBench.Voice) -> String {
        let through = suggestion.through == 1 ? "1 of \(suggestion.others) clips of other voices gets through"
            : "\(suggestion.through) of \(suggestion.others) clips of other voices get through"
        let bound = "at most \(percent(suggestion.upperBound)) of them, 95% sure"
        let yours = voice.yours.isEmpty ? "" : ", and \(percent(Double(voice.yoursPassing(at: suggestion.value)) / Double(voice.yours.count))) of your \(voice.yours.count) pass"
        let enough = suggestion.isEnough ? "" : " Fewer than \(MomentBench.enoughOthers) clips of other voices can't tell 1% well yet."
        return "At \(String(format: "%.2f", suggestion.value)), \(through) (\(bound))\(yours).\(enough)"
    }

    /// The start bar, in the words the voice threshold uses: the score a "Binders, …" said on its own needs to start an
    /// agent you let start on its own; else what Calibrate still needs, or that it can set one now.
    private func startBarLine(_ voice: MomentBench.Voice) -> String {
        if let bar = bench.startBar {
            return "Starts an agent you let start on its own at a voice score of \(String(format: "%.2f", bar)) or more."
        }
        guard voice.others.count >= MomentBench.enoughOthers else {
            return "To start agents from what you say, Calibrate needs \(MomentBench.enoughOthers) clips of other voices or TV; it has \(voice.others.count)."
        }
        return "No start bar yet: set one from these clips to let a “Binders, …” in your voice start an agent you let start on its own."
    }

    private func useMessage(_ suggestion: MomentBench.Threshold, _ voice: MomentBench.Voice) -> String {
        let base = "Things said on their own then need a voice score of \(String(format: "%.2f", suggestion.value)) or more to get through."
        guard !suggestion.isEnough else { return base }
        return base + " It's from \(suggestion.others) clips of other voices; \(MomentBench.enoughOthers) or more tell 1% better."
    }
}

/// No voice print yet: what Calibrate needs first, and the way to it. Until there's a print nothing said on its own gets
/// through, and no voice can be scored, so every phrase would come back not taken.
private struct TeachVoiceFirst: View {
    /// The sheet closed: a print may be there now.
    let taught: () -> Void
    @State private var teaching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Teach Binders your voice first: twenty seconds of reading a passage. Until then nothing said on its own gets through, and no phrase can be scored. It's also under Capture → Settings → Your voice.",
                  systemImage: "person.wave.2")
                .font(.subheadline).foregroundStyle(Palette.needsYou)
            Button { teaching = true } label: { Label("Teach Binders Your Voice", systemImage: "mic.fill") }
                .foregroundStyle(Palette.accentText)
                .accessibilityIdentifier("benchTeachVoice")
        }
        .sheet(isPresented: $teaching, onDismiss: taught) { VoiceTeachingSheet() }
    }
}

/// One run on the bench's first screen: what it is, and how far it has come.
private struct BenchRunRow: View {
    let title: String
    let detail: String
    var count: Int?
    var of: Int?
    var unit = "said"
    var minutes: TimeInterval?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Palette.ink)
                Text(detail).font(.footnote).foregroundStyle(Palette.muted)
            }
            Spacer()
            if let count, let of, count > 0 {
                Text("\(count) of \(of) \(unit)")
                    .font(Typeface.count(.subheadline)).foregroundStyle(Palette.muted)
                    .contentTransition(reduceMotion ? .opacity : .numericText())
            } else if let minutes, minutes > 0 {
                Text(BenchFormat.duration(minutes)).font(Typeface.time(.subheadline)).foregroundStyle(Palette.muted)
            }
        }
    }
}

// MARK: - A run of phrases

/// A phrase or a line, as the run shows it.
private struct BenchItem: Identifiable {
    let id: String
    let text: String
    let hint: String?
    /// "To-dos", or "Line 7 of 40".
    let heading: String
    let group: MomentBench.Group?
    let line: MomentBench.Line?
}

/// One run of phrases or lines, one at a time: the phrase on screen, Record, say it, and its result with every score.
/// Skip and Say It Again are a tap away, and the menu jumps to a group or starts a new pass.
struct BenchRunView: View {
    let run: MomentBench.Run
    @State private var bench = CalibrationBench.shared
    @State private var index = 0
    @State private var placed = false
    @State private var confirmingNewPass = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var items: [BenchItem] {
        if run == .script {
            return MomentBench.script.enumerated().map { place, line in
                BenchItem(id: line.id, text: line.text, hint: line.hint, heading: "Line \(place + 1) of \(MomentBench.script.count)", group: nil,
                          line: line)
            }
        }
        // Lane Y2: the phrases said without a cue, and the chatter after the fifteenth, only in Auto.
        return MomentBench.phrases(inAuto: MomentCenter.shared.mode == .auto)
            .map { BenchItem(id: $0.id, text: $0.text, hint: $0.hint, heading: $0.group.title, group: $0.group, line: nil) }
    }

    var body: some View {
        let items = items
        let results = bench.results(run)
        let item = items[min(index, items.count - 1)]
        let result = results[item.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                progress(item, said: results.count, of: items.count)
                phraseCard(item)
                controls(item, result: result, count: items.count)
                // Saying it again, the last time's result makes way until the new one is in.
                if let result, !isSayingIt {
                    BenchResultCard(result: result, line: item.line, heard: bench.heard?.result == result.id ? bench.heard?.words : nil,
                                    threshold: Double(bench.threshold))
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                Text(footnote)
                    .font(.footnote).foregroundStyle(Palette.faint)
                    .padding(.top, 4)
            }
            .padding(16)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.85), value: result?.id)
        }
        .background(Palette.ground)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if run != .script {
                        ForEach(MomentBench.Group.allCases, id: \.self) { group in
                            Button(group.title) {
                                if let first = items.firstIndex(where: { $0.group == group }) { go(to: first) }
                            }
                        }
                        Divider()
                    }
                    Button(run == .otherVoices ? "Next Reader" : "Start Again") { confirmingNewPass = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(bench.phase == .listening || bench.phase == .checking)
            }
        }
        .confirmationDialog(run == .otherVoices ? "Start with the next reader?" : "Start a new pass?", isPresented: $confirmingNewPass,
                            titleVisibility: .visible) {
            Button(run == .otherVoices ? "Next Reader" : "Start Again") {
                bench.startPass(run)
                go(to: 0)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This pass's results are kept, and count with the rest.")
        }
        .task { await bench.askForMicrophone() }
        .onAppear {
            bench.open()
            bench.startOverIfScoredOtherwise(run)
            guard !placed else { return }
            placed = true
            // As they are now: a pass started over just above has none.
            let said = bench.results(run)
            index = items.firstIndex { said[$0.id] == nil } ?? 0
        }
        .onDisappear { bench.close() }
        .onChange(of: scenePhase) { _, phase in
            // Away from Binders, capture has the microphone back.
            if phase == .active { bench.open() } else { bench.close() }
        }
    }

    /// A phrase is being listened for, or checked.
    private var isSayingIt: Bool {
        bench.phase == .checking || (bench.phase == .listening && !bench.isTimedRunGoing)
    }

    private var title: String {
        switch run {
        case .phrases: "Your phrases"
        case .otherVoices: "Someone else reading"
        case .script: "The 40 lines"
        case .media: "TV or a podcast"
        }
    }

    private var footnote: String {
        "All-day capture is paused while this screen is open, and carries on when you leave it. Only the scores and timings are kept."
    }

    private func progress(_ item: BenchItem, said: Int, of total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.heading).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted)
                Spacer()
                Text("\(said) of \(total)")
                    .font(Typeface.count(.subheadline)).foregroundStyle(Palette.muted)
                    .contentTransition(reduceMotion ? .opacity : .numericText())
            }
            ProgressView(value: Double(said), total: Double(max(1, total))).tint(Palette.accent)
        }
    }

    private func phraseCard(_ item: BenchItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if run == .otherVoices {
                Label(readerLine, systemImage: "person.2").font(.footnote).foregroundStyle(Palette.muted)
            }
            Text("“\(item.text)”")
                .font(Typeface.quote(.title2))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("benchPhrase")
            if let hint = item.hint {
                Text(hint).font(.subheadline).foregroundStyle(Palette.muted)
            }
            if let line = item.line {
                Text("Should be \(line.expected.summary.lowercasedFirst)").font(.footnote).foregroundStyle(Palette.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard()
    }

    private var readerLine: String {
        let reader = bench.store.latest(.otherVoices)?.reader ?? 1
        return "Not me · reader \(reader). Someone else reads each phrase, as it's written."
    }

    @ViewBuilder
    private func controls(_ item: BenchItem, result: MomentBench.Result?, count: Int) -> some View {
        switch bench.phase {
        case .listening where !bench.isTimedRunGoing:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(Palette.live).frame(width: 9, height: 9)
                    Text("Listening. Say it, then stay quiet for a few seconds.").foregroundStyle(Palette.ink)
                }
                LevelMeter(level: bench.level)
                if bench.byLoudness {
                    Text("By loudness until the voice detector is on this iPhone.").font(.footnote).foregroundStyle(Palette.muted)
                }
                Button {
                    bench.cancelRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Palette.ink)
                .accessibilityIdentifier("benchStop")
            }
            .benchCard()
        case .checking:
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking it as capture would…").foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        default:
            VStack(spacing: 10) {
                if case .problem(let message) = bench.phase {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if bench.isTimedRunGoing {
                    Label("The TV run is listening. Stop it first, under TV or a podcast.", systemImage: "clock")
                        .font(.subheadline).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if bench.voicePrint == nil {
                    // No print: every phrase would fail the voice check, so it's taught first.
                    TeachVoiceFirst {
                        bench.refresh()
                        bench.startOverIfScoredOtherwise(run)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    secondaryButton("Skip") { go(to: index + 1, count: count) }
                } else if result == nil {
                    primaryButton("Record", systemImage: "mic.fill") { Task { await bench.record(item.id, in: run) } }
                        .accessibilityIdentifier("benchRecord")
                    secondaryButton("Skip") { go(to: index + 1, count: count) }
                        .accessibilityIdentifier("benchSkip")
                } else {
                    primaryButton(index + 1 < count ? "Next" : "Done", systemImage: index + 1 < count ? "arrow.right" : "checkmark") {
                        if index + 1 < count { go(to: index + 1, count: count) } else { dismiss() }
                    }
                    .accessibilityIdentifier("benchNext")
                    secondaryButton("Say It Again") { Task { await bench.record(item.id, in: run) } }
                        .accessibilityIdentifier("benchAgain")
                }
                if index > 0 {
                    secondaryButton("Previous") { go(to: index - 1, count: count) }
                }
            }
            .disabled(bench.isTimedRunGoing)
        }
    }

    private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(Palette.accent)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(Palette.accentText)
    }

    private func go(to place: Int, count: Int? = nil) {
        let last = (count ?? items.count) - 1
        bench.moveOn()
        index = max(0, min(last, place))
    }
}

/// How loud it is while the microphone listens: red, as the microphone is live, moving with the audio and still in the
/// quiet. Under Reduce Motion it holds its length and brightens with your voice instead (LevelMeterLook), as the
/// dictation meter does.
private struct LevelMeter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let level: Double

    var body: some View {
        let look = LevelMeterLook(level: level, reduceMotion: reduceMotion)
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(Palette.live.opacity(look.brightness)).frame(width: max(6, geometry.size.width * look.fill))
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? .easeInOut(duration: 0.1) : .linear(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

// MARK: - A result

/// One clip's result: taken or not and why, and every check's score and time. What was heard shows with it once, and is
/// never kept.
private struct BenchResultCard: View {
    let result: MomentBench.Result
    /// The line it's for, in the 40 lines.
    let line: MomentBench.Line?
    /// What it was written down as, while it's on screen.
    let heard: String?
    let threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            verdict
            if let heard {
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(heard)”").font(Typeface.quote()).foregroundStyle(Palette.ink)
                    Text("How it was written down\(BenchFormat.accuracy(result.accuracy).map { ", with \($0)" } ?? ""). Shown once, never kept.")
                        .font(.footnote).foregroundStyle(Palette.faint)
                }
            } else if let accuracy = BenchFormat.accuracy(result.accuracy) {
                Text("Written down with \(accuracy).").font(.footnote).foregroundStyle(Palette.faint)
            }
            Divider().overlay(Palette.line)
            BenchFacts(result: result, threshold: threshold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("benchResult")
    }

    @ViewBuilder
    private var verdict: some View {
        let taken = result.taken(at: threshold)
        if let line {
            let outcome = MomentBench.verdict(result, for: line, threshold: threshold)
            Label(BenchFormat.verdict(outcome), systemImage: outcome == .passed ? "checkmark.circle" : "exclamationmark.circle")
                .font(.headline).foregroundStyle(outcome == .passed ? Palette.accentText : Palette.ink)
            Text("Should be \(line.expected.summary.lowercasedFirst). It was \(BenchFormat.outcome(result, threshold: threshold).lowercasedFirst).")
                .font(.subheadline).foregroundStyle(Palette.muted)
        } else {
            Label(BenchFormat.outcome(result, threshold: threshold), systemImage: taken ? "checkmark.circle" : "xmark.circle")
                .font(.headline).foregroundStyle(taken ? Palette.accentText : Palette.ink)
        }
    }
}

/// Every check's finding for a clip, a row each.
private struct BenchFacts: View {
    let result: MomentBench.Result
    let threshold: Double

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            fact("Heard", BenchFormat.detector(result))
            if result.detector != .letGo {
                fact("Cue", result.wake == true ? "Said with “Binders”" : result.cue.map { "“\($0)”" } ?? "None")
                fact("Voice", BenchFormat.voice(result, threshold: threshold))
                fact("Apple Intelligence", BenchFormat.model(result))
                fact("Rules", BenchFormat.rules(result))
                if let binder = BenchFormat.binder(result) { fact("Binder", binder) }
                if let due = BenchFormat.due(result) { fact("Due", due) }
                if let timings = BenchFormat.timings(result) { fact("Times", timings) }
            }
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).font(.footnote).foregroundStyle(Palette.muted)
            Text(value).font(.footnote.monospacedDigit()).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - The timed run

/// TV or a podcast, timed: the microphone listens, with the screen locked too, and everything the gate would have taken
/// counts as a false accept.
struct TimedRunView: View {
    @State private var bench = CalibrationBench.shared
    @AppStorage("benchTimedMinutes") private var minutes = 30
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Play TV or a podcast near this iPhone and leave it to listen. Stay quiet yourself: everything it hears counts as the TV. Anything the checks would have taken is a false accept. The screen can lock; clips that can't be written down then wait until you open Binders.")
                    .font(.subheadline).foregroundStyle(Palette.muted)
                if let session = bench.timedRun {
                    running(session)
                } else {
                    setup
                }
                pastRuns
            }
            .padding(16)
        }
        .background(Palette.ground)
        .navigationTitle("TV or a podcast")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // What went wrong with a phrase isn't this run's.
            if !bench.isTimedRunGoing { bench.moveOn() }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Listen for", selection: $minutes) {
                Text("15 min").tag(15)
                Text("30 min").tag(30)
                Text("60 min").tag(60)
            }
            .pickerStyle(.segmented)
            Toggle("Keep the screen on", isOn: Binding(get: { bench.keepsScreenOn }, set: { bench.keepsScreenOn = $0 }))
                .tint(Palette.accent)
            if case .problem(let message) = bench.phase {
                Label(message, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(Palette.ink)
            }
            Button {
                Task { await bench.startTimedRun(minutes: minutes) }
            } label: {
                Label("Start Listening", systemImage: "mic.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .disabled(bench.phase == .listening || bench.phase == .checking)
            .accessibilityIdentifier("benchTimedStart")
            Text("All-day capture is paused while it listens, and carries on when it's done.")
                .font(.footnote).foregroundStyle(Palette.faint)
        }
        .benchCard()
    }

    private func running(_ session: MomentBench.Session) -> some View {
        let clips = bench.store.results.filter { $0.session == session.id }
        let taken = clips.filter { $0.taken(at: Double(bench.threshold)) }.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(bench.interrupted ? Palette.muted : Palette.live).frame(width: 9, height: 9)
                Text(bench.interrupted ? "Paused" : "Listening").foregroundStyle(Palette.ink)
                Spacer()
                if let ends = bench.timedRunEnds {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(BenchFormat.clock(max(0, ends.timeIntervalSince(context.date))) + " left")
                            .font(Typeface.time(.headline)).foregroundStyle(Palette.muted)
                    }
                }
            }
            if bench.interrupted {
                Label("A call or another app has the microphone. It listens again once that's over.", systemImage: "pause.circle")
                    .font(.subheadline).foregroundStyle(Palette.muted)
            } else {
                LevelMeter(level: bench.level)
            }
            HStack(alignment: .top, spacing: 12) {
                count(clips.count, clips.count == 1 ? "clip heard" : "clips heard")
                count(taken, "would have been taken")
            }
            if bench.checking > 0 {
                Text(bench.checking == 1 ? "Checking 1 clip…" : "Checking \(bench.checking) clips…").font(.footnote).foregroundStyle(Palette.muted)
            }
            if bench.held > 0 {
                Text(bench.held == 1 ? "1 clip waits to be scored until you open Binders." : "\(bench.held) clips wait to be scored until you open Binders.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            if bench.unscored > 0 {
                Text("\(bench.unscored) more couldn't be held while locked, so they weren't scored.").font(.footnote).foregroundStyle(Palette.muted)
            }
            Button {
                bench.stopTimedRun()
            } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(Palette.ink)
            .accessibilityIdentifier("benchTimedStop")
        }
        .benchCard()
    }

    private func count(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(Typeface.count(.title))
                .foregroundStyle(Palette.ink)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(.default, value: value)
            Text(label).font(.footnote).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var pastRuns: some View {
        let sessions = bench.store.sessions.filter { $0.run == .media && $0.ended != nil }.sorted { $0.started > $1.started }
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Earlier runs").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted)
                ForEach(sessions) { session in
                    let clips = bench.store.results.filter { $0.session == session.id }
                    let taken = clips.filter { $0.taken(at: Double(bench.threshold)) }.count
                    HStack {
                        Text(session.started.formatted(date: .abbreviated, time: .shortened)).monospacedDigit().foregroundStyle(Palette.ink)
                        Spacer()
                        Text("\(BenchFormat.duration((session.ended ?? session.started).timeIntervalSince(session.started))) · \(clips.count) heard · \(taken) taken")
                            .font(Typeface.time(.footnote)).foregroundStyle(Palette.muted)
                    }
                }
            }
            .benchCard()
        }
    }
}

// MARK: - What the bench found

/// The report: what each group got through, the false accepts, the voice on 2-5 s clips, and the 40 lines one by one.
struct BenchResultsView: View {
    @State private var bench = CalibrationBench.shared

    var body: some View {
        let report = bench.report
        let threshold = String(format: "%.2f", report.threshold)
        List {
            Section {
                ForEach(MomentBench.Group.allCases, id: \.self) { group in
                    tally(group.title, report.yours[group])
                }
            } header: {
                Text("Your phrases")
            } footer: {
                Text("The first five groups should be taken; the last two shouldn't. Counted at the voice threshold now, \(threshold).")
            }

            // Lane Y2: what Auto would keep without a cue, and how often Apple's model didn't answer.
            if report.auto.taken.total > 0 || report.auto.unanswered > 0 {
                Section {
                    Text(report.auto.summary).font(.subheadline).monospacedDigit().foregroundStyle(Palette.ink).benchRow()
                } header: {
                    Text(MomentBench.Group.uncued.title)
                } footer: {
                    Text(AutoPhoneText.calibrateUncuedFooter)
                }
            }

            Section {
                ForEach(MomentBench.Group.allCases, id: \.self) { group in
                    tally(group.title, report.others[group])
                }
            } header: {
                Text("Someone else reading")
            } footer: {
                Text("Anything taken here got past your voice print: a false accept.")
            }

            Section {
                LabeledContent("Listened") { Text(BenchFormat.duration(report.mediaSeconds)).font(Typeface.time(.body)) }
                    .benchRow()
                tally("Clips heard", report.media)
                if report.mediaSeconds >= 60 {
                    LabeledContent("Taken an hour") {
                        Text(String(format: "%.1f", Double(report.media.taken) / (report.mediaSeconds / 3600))).font(Typeface.time(.body))
                    }
                    .benchRow()
                }
            } header: {
                Text("TV and podcasts")
            } footer: {
                Text("Every clip taken here is a false accept. Counted clip by clip: capture also rests for ten minutes after writing down 20 in ten minutes, which these numbers leave out.")
            }

            Section {
                score("Kind", report.kinds)
                score("Binder named", report.binders, unasked: "binder read where none was named", unaskedMany: "binders read where none was named")
                score("Due date", report.dues, unasked: "day read where none was said", unaskedMany: "days read where none was said")
            } header: {
                Text("What the rules read")
            } footer: {
                Text("From your phrases and the 40 lines that should be taken, as written down on this iPhone. Binders are read against the bench's own (\(MomentBench.binders.joined(separator: ", "))), so every iPhone scores alike; notes aren't counted for the kind, as Apple's model tells those. Your Mac's model isn't on the bench: clips never go to your Mac.")
            }

            Section {
                tally("Yours, not meant for Binders", report.yourFalseAccepts)
                tally("Someone else's", report.otherFalseAccepts)
                tally("TV and podcasts", report.media)
            } header: {
                Text("False accepts")
            } footer: {
                Text("Taken out of all said: your phrases not meant for Binders and your chatter, everything someone else read, and everything the TV said.")
            }

            Section {
                voiceRow("Yours", report.voice.yours, passing: report.voice.yoursPassing(at: report.threshold), verb: "pass")
                voiceRow("Other voices", report.voice.others, passing: report.voice.othersThrough(at: report.threshold), verb: "get through")
                if !report.voice.notMe.isEmpty {
                    voiceRow("Marked Not Me", report.voice.notMe, passing: report.voice.notMeThrough(at: report.threshold), verb: "get through")
                }
                if report.earlierPrint > 0 {
                    Text(report.earlierPrint == 1 ? "1 clip scored against an earlier voice print, or before voices were scored as now, isn't counted."
                         : "\(report.earlierPrint) clips scored against an earlier voice print, or before voices were scored as now, aren't counted.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                        .benchRow()
                }
            } header: {
                Text("Voice, on 2 to 5 second clips")
            } footer: {
                Text("At \(threshold) or more. Not Me taps are things capture let through that you said weren't you or weren't for Binders; they're shown, not used for the threshold.")
            }

            Section {
                if report.scriptSaid == 0 {
                    Text("None said yet.").foregroundStyle(Palette.muted).benchRow()
                } else {
                    LabeledContent("Passed") {
                        Text("\(report.scriptPassed) of \(report.scriptSaid) said").font(Typeface.count(.body))
                    }
                    .benchRow()
                    let needModel = report.script.values.filter { $0 == .needsModel }.count
                    if needModel > 0 {
                        Text(needModel == 1 ? "1 line needs Apple Intelligence to be let go." : "\(needModel) lines need Apple Intelligence to be let go.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                            .benchRow()
                    }
                }
                ForEach(Array(MomentBench.script.enumerated()), id: \.element.id) { place, line in
                    scriptRow(place + 1, line, report.script[line.id])
                }
            } header: {
                Text("The 40 lines")
            } footer: {
                Text("Each line from the last time it was said.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("What the bench found")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tally(_ title: String, _ tally: MomentBench.Tally?) -> some View {
        LabeledContent(title) {
            if let tally, tally.total > 0 {
                Text("\(tally.taken) taken, \(tally.total - tally.taken) let go").font(Typeface.count(.subheadline))
            } else {
                Text("None yet").foregroundStyle(Palette.faint)
            }
        }
        .benchRow()
    }

    /// "8 of 10 right · 1 binder read where none was named".
    private func score(_ title: String, _ score: MomentBench.Score, unasked: String = "", unaskedMany: String = "") -> some View {
        LabeledContent(title) {
            if score.total > 0 || score.unasked > 0 {
                let extra = score.unasked == 0 ? "" : score.unasked == 1 ? " · 1 \(unasked)" : " · \(score.unasked) \(unaskedMany)"
                Text("\(score.right) of \(score.total) right" + extra).font(Typeface.count(.subheadline))
            } else {
                Text("None yet").foregroundStyle(Palette.faint)
            }
        }
        .benchRow()
    }

    private func voiceRow(_ title: String, _ scores: [Double], passing: Int, verb: String) -> some View {
        LabeledContent(title) {
            if scores.isEmpty {
                Text("No clips").foregroundStyle(Palette.faint)
            } else {
                Text("\(passing) of \(scores.count) \(verb)").font(Typeface.count(.subheadline))
            }
        }
        .benchRow()
    }

    private func scriptRow(_ number: Int, _ line: MomentBench.Line, _ verdict: MomentBench.Verdict?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: BenchFormat.glyph(verdict))
                .foregroundStyle(verdict == .passed ? Palette.accentText : verdict == nil ? Palette.faint : Palette.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(number). “\(line.text)”").font(Typeface.quote(.subheadline)).foregroundStyle(Palette.ink).lineLimit(3)
                Text("\(line.expected.summary) · \(verdict.map(BenchFormat.verdict) ?? "Not said yet")")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
        }
        .benchRow()
    }
}

// MARK: - Words

/// How the bench says what it found.
private enum BenchFormat {
    /// "Taken, as a to-do", "Not taken: no cue in the words", at the voice threshold `threshold`.
    static func outcome(_ result: MomentBench.Result, threshold: Double) -> String {
        if result.detector == .letGo { return "Let go by the detector" }
        if result.taken(at: threshold) {
            guard let kind = result.kindRead, kind != .none else { return "Taken" }
            return "Taken, as \(MomentBench.named(kind))"
        }
        return "Not taken: " + (result.failures(at: threshold).first.map { $0.reason.lowercasedFirst } ?? "nothing was checked")
    }

    static func verdict(_ verdict: MomentBench.Verdict) -> String {
        switch verdict {
        case .passed: "Passed"
        case .failed: "Didn't pass"
        case .needsModel: "Needs Apple Intelligence to tell"
        }
    }

    static func glyph(_ verdict: MomentBench.Verdict?) -> String {
        switch verdict {
        case .passed?: "checkmark.circle"
        case .failed?: "exclamationmark.circle"
        case .needsModel?: "questionmark.circle"
        case nil: "circle"
        }
    }

    static func detector(_ result: MomentBench.Result) -> String {
        switch result.detector {
        case .letGo?: return "Let go: too short, too long, or answered"
        case .inConversation?: return "In a conversation: too little quiet before, or answered"
        case .onItsOwn?, nil:
            var parts = ["On its own"]
            if let seconds = result.seconds { parts.append(String(format: "%.1f s", seconds)) }
            if let endpoint = result.endpointMillis { parts.append(String(format: "handed on %.1f s after the last word", Double(endpoint) / 1000)) }
            return parts.joined(separator: " · ")
        }
    }

    static func voice(_ result: MomentBench.Result, threshold: Double) -> String {
        if let voice = result.voice {
            let needs = String(format: "%.2f", threshold)
            return String(format: "%.2f", voice) + (result.wake == true ? " (not needed with “Binders”)" : voice >= threshold ? ", at least \(needs)" : ", under \(needs)")
        }
        let failures = result.failures ?? []
        if failures.contains(.noVoicePrint) { return "No voice print yet" }
        if failures.contains(.voiceUnclear) { return "Couldn't tell: two voices, or too little of one" }
        return "Not scored"
    }

    static func model(_ result: MomentBench.Result) -> String {
        switch result.model {
        case nil: return "Not asked"
        case "unavailable"?: return "Not on this iPhone"
        case "noAnswer"?: return "Didn't answer in time"
        case let raw?:
            guard let kind = MomentKind(rawValue: raw) else { return raw }
            let agrees = !(result.failures ?? []).contains(.modelDisagreed)
            return MomentGate.described(kind).capitalizedFirst + (agrees ? ", agrees" : ", disagrees")
        }
    }

    static func rules(_ result: MomentBench.Result) -> String {
        switch result.rules {
        case nil: return "Not read"
        case "unsure"?: return "Can't tell, so your Mac's model would"
        case let raw?: return MomentKind(rawValue: raw).map { MomentGate.described($0).capitalizedFirst } ?? raw
        }
    }

    /// "Events, right", "None read; should be Events", "Home, though none was named"; nil with nothing to say.
    static func binder(_ result: MomentBench.Result) -> String? {
        let expected = MomentBench.expectations[result.phrase ?? ""]?.binder
        guard let read = result.binder else { return expected.map { "Not read; should be \($0)" } }
        switch MomentBench.binderRead(result) {
        case .right?: return "\(read), right"
        case .wrong?: return (read.isEmpty ? "None read" : "Read as \(read)") + "; should be \(expected ?? "none")"
        case .unasked?: return "\(read), though none was named"
        case nil: return nil
        }
    }

    /// "Friday 25 September, right" or "None read; should be by Friday", as for the binder.
    static func due(_ result: MomentBench.Result) -> String? {
        let expected = MomentBench.expectations[result.phrase ?? ""]?.due?.summary
        guard let read = result.due else { return expected.map { "Not read; should be \($0)" } }
        let day = MomentBench.date(read).map { $0.formatted(.dateTime.weekday(.wide).day().month(.wide)) } ?? read
        switch MomentBench.dueRead(result) {
        case .right?: return "\(day), right"
        case .wrong?: return (read.isEmpty ? "None read" : day) + "; should be \(expected ?? "none")"
        case .unasked?: return "\(day), though no day was said"
        case nil: return nil
        }
    }

    static func timings(_ result: MomentBench.Result) -> String? {
        var parts: [String] = []
        if let asr = result.asrMillis { parts.append("written down \(asr) ms") }
        if let voice = result.voiceMillis { parts.append("voice \(voice) ms") }
        if let model = result.modelMillis, result.model != "unavailable" { parts.append("model \(model) ms") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ").capitalizedFirst
    }

    /// "92% of the phrase's words right"; nil with nothing to compare.
    static func accuracy(_ accuracy: Double?) -> String? {
        accuracy.map { "\(Int(($0 * 100).rounded()))% of the phrase's words right" }
    }

    /// "1 h 20 min", "45 min", "under a minute".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes > 0 else { return "under a minute" }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// "23:41".
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

}

private func percent(_ share: Double) -> String {
    let value = share * 100
    return value < 10 && value > 0 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

private extension View {
    /// A row on surface, on the ground.
    func benchRow() -> some View { listRowBackground(Palette.surface) }

    /// An opaque card on surface, with a hairline.
    func benchCard() -> some View {
        padding(14)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.line))
    }
}
