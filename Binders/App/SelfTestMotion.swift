import AppKit
import SwiftUI
import BindersKit

extension SelfTest {
    /// How Binders moves, checked from the numbers and from drawn frames: a new item files in with the spring once its
    /// page has settled, only fades under Reduce Motion, and just appears before the page settles, its binder's chip
    /// sliding in beside it; counts roll once settled; the recording dot moves only while speech is heard and never under
    /// Reduce Motion; the processing dots hold still under Reduce Motion; the waveform lies flat below the speech floor.
    /// Draws the Flow bar's states, the meeting pill among them, to `directory`. Nothing is read or written.
    @MainActor
    static func motionSelfTest(directory: URL) async -> Int32 {
        let failures = FailureCount()
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures.count += 1 }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The numbers behind the moving glyphs.
        let moments = stride(from: 0.0, to: 3.0, by: 0.05).map { 1_000_000 + $0 }
        let dotHeard = moments.map { PulsingDot.opacity(at: $0, hearing: true, reduceMotion: false) }
        check(moments.allSatisfy { PulsingDot.opacity(at: $0, hearing: false, reduceMotion: false) == 1 }, "the recording dot holds still while no speech is heard")
        check((dotHeard.min() ?? 1) < 0.65 && (dotHeard.max() ?? 0) > 0.95, "it breathes while speech is heard")
        check(moments.allSatisfy { PulsingDot.opacity(at: $0, hearing: true, reduceMotion: true) == 1 }, "under Reduce Motion it never moves, speech or not")
        let wave = moments.map { ProcessingDots.opacity(index: 1, at: $0, reduceMotion: false) }
        check((wave.max() ?? 0) - (wave.min() ?? 0) > 0.5, "the processing dots run a wave")
        check(moments.allSatisfy { ProcessingDots.opacity(index: 1, at: $0, reduceMotion: true) == ProcessingDots.opacity(index: 0, at: 0, reduceMotion: true) },
              "under Reduce Motion the processing dots hold still")
        let quiet = [Float](repeating: 0.0005, count: 30)   // about -66 dB: a quiet room
        let hum = [Float](repeating: 0.002, count: 30)      // about -54 dB: a fan, under the speech floor
        var spoken = quiet
        spoken[25] = 0.05                                     // about -26 dB: a word
        check(quiet.allSatisfy { WaveformView.height($0) == 3 } && hum.allSatisfy { WaveformView.height($0) == 3 },
              "the waveform lies flat below the speech floor, a hum included")
        check(WaveformView.height(0.05) > 12, "a spoken word raises its bar")
        check(!WaveformView.hearsSpeech(quiet) && !WaveformView.hearsSpeech(hum) && WaveformView.hearsSpeech(spoken), "speech is heard only when a level is over the floor")
        let afterPause = Array(spoken.dropFirst(26)) + [Float](repeating: 0.0005, count: 20)
        check(!WaveformView.hearsSpeech(afterPause), "a moment after the last word, speech is no longer heard")
        check(BindersTheme.motion(BindersTheme.filing, reduced: true) == BindersTheme.crossfade
              && BindersTheme.motion(BindersTheme.filing, reduced: false) == BindersTheme.filing, "every spring becomes the crossfade under Reduce Motion")
        let controller = DictationController()
        check(!controller.meetings.hearsSpeech, "no meeting recording, no speech heard")
        let flowBar = FlowBarController()
        flowBar.meetingStarted(at: Date(), hearsSpeech: { true })
        let heardWhileRecording = flowBar.model.meetingHearsSpeech()
        flowBar.meetingEnded()
        check(heardWhileRecording && !flowBar.model.meetingHearsSpeech(), "the Flow bar's meeting pill asks the meeting while it records, and stops when it ends")

        // Filing, from drawn frames: a red row added to the bottom of a list of white ones, with a blue chip.
        func filing(settled: Bool, reduceMotion: Bool) async -> (early: FilingFrame, middle: FilingFrame, settledFrame: FilingFrame) {
            let model = FilingProbeModel()
            model.settled = settled
            model.reduceMotion = reduceMotion
            let stage = await Stage(FilingProbe(model: model), size: NSSize(width: 260, height: 220))
            model.items.append(99)
            try? await Task.sleep(for: .milliseconds(45))
            let early = FilingFrame(stage.snapshot())
            try? await Task.sleep(for: .milliseconds(70))
            let middle = FilingFrame(stage.snapshot())
            try? await Task.sleep(for: .milliseconds(700))
            let done = FilingFrame(stage.snapshot())
            stage.close()
            return (early, middle, done)
        }
        let sprung = await filing(settled: true, reduceMotion: false)
        let faded = await filing(settled: true, reduceMotion: true)
        let unsettled = await filing(settled: false, reduceMotion: false)
        print("INFO: filing frames, spring \(sprung.early) → \(sprung.middle) → \(sprung.settledFrame); Reduce Motion \(faded.early) → \(faded.middle) → \(faded.settledFrame); not settled \(unsettled.early)")
        check(sprung.settledFrame.rowTop != nil && sprung.settledFrame.redness > 0.7, "the new row ends where it belongs, fully drawn")
        check([sprung.early, sprung.middle].contains { ($0.rowTop ?? 999) < (sprung.settledFrame.rowTop ?? 0) - 1 },
              "once the page has settled, the new row drops in (\(sprung.early.rowTop.map { "\($0)" } ?? "-"), \(sprung.middle.rowTop.map { "\($0)" } ?? "-") then \(sprung.settledFrame.rowTop.map { "\($0)" } ?? "-"))")
        check((sprung.middle.chipLeft ?? 0) > (sprung.settledFrame.chipLeft ?? 0) + 1,
              "its chip slides in from the side as it drops (\(sprung.middle.chipLeft.map { "\($0)" } ?? "-") then \(sprung.settledFrame.chipLeft.map { "\($0)" } ?? "-"))")
        check(faded.early.redness < faded.settledFrame.redness - 0.1 && [faded.early, faded.middle].allSatisfy { frame in
                  (frame.rowTop == nil || frame.rowTop == faded.settledFrame.rowTop) && (frame.chipLeft == nil || frame.chipLeft == faded.settledFrame.chipLeft) },
              "under Reduce Motion it fades in where it belongs, without moving")
        check(unsettled.early.redness > unsettled.settledFrame.redness - 0.05 && unsettled.early.rowTop == unsettled.settledFrame.rowTop,
              "before the page has settled, a new row just appears")

        // Rolling counts: a frame just after the count changes differs from the last one only once the page has settled.
        func rolling(settled: Bool) async -> Bool {
            let model = FilingProbeModel()
            model.settled = settled
            let stage = await Stage(CountProbe(model: model), size: NSSize(width: 160, height: 60))
            model.count = 19
            try? await Task.sleep(for: .milliseconds(40))
            let early = stage.snapshot()
            try? await Task.sleep(for: .milliseconds(700))
            let done = stage.snapshot()
            stage.close()
            return early != done
        }
        check(await rolling(settled: true), "once the page has settled, a count rolls to its new value")
        check(!(await rolling(settled: false)), "before the page has settled, a count just changes")

        // The recording dot, drawn three times over half a second: does it change?
        func dotMoves(hearing: Bool, reduceMotion: Bool) async -> Bool {
            let stage = await Stage(PulsingDot(hearing: hearing).padding(8).background(Color.black).environment(\.reduceMotionOverride, reduceMotion),
                                    size: NSSize(width: 30, height: 30))
            var frames: [Data] = []
            for _ in 0..<3 {
                frames.append(stage.snapshot())
                try? await Task.sleep(for: .milliseconds(270))
            }
            stage.close()
            return Set(frames).count > 1
        }
        check(!(await dotMoves(hearing: false, reduceMotion: false)), "drawn, the dot holds still in silence")
        check(await dotMoves(hearing: true, reduceMotion: false), "drawn, the dot moves while speech is heard")
        check(!(await dotMoves(hearing: true, reduceMotion: true)), "drawn under Reduce Motion, it holds still while speech is heard")

        // Pictures to look at: the Flow bar while you talk, in silence, thinking, and the meeting pill.
        let actions = FlowBarActions(stop: {}, cancel: {}, openMeeting: {}, stopMeeting: {}, acceptPrompt: {}, dismissPrompt: {})
        let states: [(String, Bool, (FlowBarModel) -> Void)] = [
            ("flow-speaking", false, { $0.display = .recording; $0.levels = (0..<30).map { Float(0.01 + 0.08 * abs(sin(Double($0) * 0.6))) } }),
            ("flow-silence", false, { $0.display = .recording; $0.levels = [Float](repeating: 0.002, count: 30) }),
            ("flow-speaking-reduced", true, { $0.display = .recording; $0.levels = (0..<30).map { Float(0.01 + 0.08 * abs(sin(Double($0) * 0.6))) } }),
            ("flow-silence-reduced", true, { $0.display = .recording; $0.levels = [Float](repeating: 0.002, count: 30) }),
            ("flow-thinking-reduced", true, { $0.display = .processing; $0.mode = .command }),
            ("flow-meeting", false, { $0.display = .meeting; $0.meetingStartedAt = Date().addingTimeInterval(-754) }),
        ]
        for (name, reduce, configure) in states {
            let model = FlowBarModel()
            configure(model)
            let size = model.display == .meeting ? NSSize(width: 300, height: 50) : FlowBarController.size
            let stage = await Stage(FlowBarView(model: model, actions: actions).environment(\.reduceMotionOverride, reduce).background(Color(white: 0.55)),
                                    size: size)
            stage.save(name: name, directory: directory)
            stage.close()
        }
        print(failures.count == 0 ? "MOTION_OK" : "MOTION_FAILED: \(failures.count)")
        return failures.count == 0 ? 0 : 1
    }
}

/// The checks that failed, counted (a class, so the nested `check` can count them).
final class FailureCount {
    var count = 0
}

/// What a filing frame shows: the new (red) row's top edge and how red it is, and its blue chip's left edge.
private struct FilingFrame: CustomStringConvertible {
    var rowTop: Int?
    var redness: Double = 0
    var chipLeft: Int?

    init(_ png: Data) {
        guard let rep = NSBitmapImageRep(data: png) else { return }
        let width = rep.pixelsWide, height = rep.pixelsHigh
        func color(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (0, 0, 0) }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        // The row's column is at a fifth of the width; red is red well over green and blue.
        let column = width / 5
        for y in 0..<height {
            let (r, g, b) = color(column, y)
            if r - max(g, b) > 0.15 {
                rowTop = rowTop ?? y
                redness = max(redness, r - max(g, b))
            }
        }
        // The chip is blue, in the row's band.
        if let top = rowTop {
            let band = min(height - 1, top + 12)
            for x in 0..<width {
                let (r, g, b) = color(x, band)
                if b - max(r, g) > 0.25 { chipLeft = x; break }
            }
        }
    }

    var description: String { "top \(rowTop.map(String.init) ?? "-"), red \(String(format: "%.2f", redness)), chip \(chipLeft.map(String.init) ?? "-")" }
}

@MainActor
@Observable
private final class FilingProbeModel {
    var items = [1, 2, 3]
    var count = 18
    var settled = false
    var reduceMotion = false
}

/// White rows on black, a new one red with a blue chip, in a list that files in.
private struct FilingProbe: View {
    let model: FilingProbeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.items, id: \.self) { item in
                HStack {
                    Spacer()
                    Rectangle().fill(Color(red: 0, green: 0.3, blue: 1)).frame(width: 24, height: 18).filingChip()
                        .opacity(item == 99 ? 1 : 0)
                }
                .padding(.horizontal, 10)
                .frame(width: 220, height: 34)
                .background(item == 99 ? Color(red: 1, green: 0, blue: 0) : .white)
                .transition(.filed)
            }
        }
        .filing(model.items)
        .padding(10)
        .frame(width: 260, height: 220, alignment: .top)
        .background(Color.black)
        .environment(\.pageSettled, model.settled)
        .environment(\.reduceMotionOverride, model.reduceMotion)
    }
}

/// A count that rolls.
private struct CountProbe: View {
    let model: FilingProbeModel

    var body: some View {
        Text("\(model.count)")
            .font(BindersTheme.count(36))
            .foregroundStyle(.white)
            .rollingCount(model.count)
            .frame(width: 160, height: 60)
            .background(Color.black)
            .environment(\.pageSettled, model.settled)
    }
}

/// A view in an offscreen window, to change and draw frame by frame.
@MainActor
private final class Stage {
    private let window: NSWindow
    private let hosting: NSView

    init<Content: View>(_ view: Content, size: NSSize) async {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.wantsLayer = true
        self.hosting = hosting
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(500))
    }

    /// What it shows now, as a PNG.
    func snapshot() -> Data {
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let size = hosting.bounds.size
        guard let layer = hosting.layer, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        if layer.isGeometryFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }

    /// Writes what it shows now to `name`.png.
    func save(name: String, directory: URL) {
        try? snapshot().write(to: directory.appendingPathComponent("\(name).png"))
        print("SNAPSHOT: \(name).png")
    }

    func close() {
        window.close()
    }
}
