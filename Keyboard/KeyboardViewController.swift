import BindersKit
import SwiftUI
import UIKit

/// The Binders keyboard: a plain typing keyboard with a mic that dictates through the Binders app. The words are typed
/// where you are when you're done talking.
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var observer: DarwinObserver?
    private var poll: Timer?
    private var lastShift = Date.distantPast
    private var lastWasSpace = false
    private let checker = UITextChecker()
    private let language = KeyboardViewController.checkerLanguage()
    /// Your contacts' names and text replacements, from iOS: names aren't corrected, shortcuts expand.
    private var lexicon: [UILexiconEntry] = []
    /// The word just corrected, while one delete would put it back.
    private var lastCorrection: (typed: String, replaced: String)?
    /// Words put back after a correction, or kept from the suggestions: not corrected again while the keyboard is up. Not
    /// taught to iOS, whose dictionary the system keyboard shares.
    private var kept = Set<String>()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self
        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        let height = view.heightAnchor.constraint(equalToConstant: 272)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        observer = DarwinObserver(KeyboardBridge.stateChanged) { [weak self] in self?.refresh() }
        // The answer comes on another queue.
        requestSupplementaryLexicon { [weak self] lexicon in
            let entries = lexicon.entries
            DispatchQueue.main.async { self?.lexicon = entries }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.hasFullAccess = hasFullAccess
        model.showsGlobe = needsInputModeSwitchKey
        model.note = nil
        model.layer = .letters
        textChanged()
        refresh()
        // Darwin notifications can be missed while the keyboard is being set up; a slow look keeps it right.
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        poll?.invalidate()
        poll = nil
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        textChanged()
    }

    /// A new field, or the text moved under the keyboard: capitals, the return key and the suggestions follow it.
    private func textChanged() {
        model.returnTitle = Self.returnTitle(textDocumentProxy.returnKeyType)
        lastCorrection = nil
        autoShift()
        suggest()
    }

    private func refresh() {
        guard hasFullAccess else { return }
        let state = KeyboardBridge.read()
        if model.starting, state.phase == .listening || state.phase == .failed { model.starting = false }
        model.state = state
        if state.phase == .done, KeyboardBridge.lastTyped != state.dictation {
            type(state.text, dictation: state.dictation)
        }
    }

    // MARK: Keys

    func micTapped() {
        guard hasFullAccess else {
            model.note = "To dictate, allow Full Access: Settings → General → Keyboard → Keyboards → Binders."
            return
        }
        model.note = nil
        switch model.state.phase {
        case .listening:
            KeyboardBridge.send(.stop)
        case .cleaning:
            break
        case .ready, .done, .failed:
            model.starting = true
            KeyboardBridge.send(.start)
            // No answer: the app is gone after all, so open it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.model.starting else { return }
                self.model.starting = false
                self.openApp()
            }
        case .off:
            openApp()
        }
    }

    func cancelTapped() {
        KeyboardBridge.send(.cancel)
    }

    func type(_ text: String, dictation: UUID) {
        KeyboardBridge.lastTyped = dictation
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let spacer = before.isEmpty || before.last?.isWhitespace == true ? "" : " "
        let typed = spacer + text
        textDocumentProxy.insertText(typed)
        model.undoable = typed
        lastWasSpace = false
        lastCorrection = nil
        KeyboardBridge.send(.typed)
        autoShift()
        suggest()
    }

    func undoTapped() {
        guard let typed = model.undoable else { return }
        for _ in typed { textDocumentProxy.deleteBackward() }
        model.undoable = nil
        autoShift()
        suggest()
    }

    func typeKey(_ key: String) {
        model.undoable = nil
        lastWasSpace = false
        // A word ends at punctuation, corrected first if it needs to be.
        if [".", ",", "?", "!", ";", ":"].contains(key) { correctWord() } else { lastCorrection = nil }
        let shifted = model.layer == .letters && model.shift != .off
        textDocumentProxy.insertText(shifted ? key.uppercased() : key)
        if model.shift == .once { model.shift = .off }
        // After an apostrophe, back to letters, as the system keyboard does.
        if key == "'", model.layer != .letters { model.layer = .letters }
        suggest()
    }

    /// Two spaces after a word end the sentence. One corrects the word, if it needs it.
    func space() {
        model.undoable = nil
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        if lastWasSpace, before.hasSuffix(" "), let previous = before.dropLast().last, previous.isLetter || previous.isNumber {
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            lastWasSpace = false
            lastCorrection = nil
        } else {
            correctWord()
            textDocumentProxy.insertText(" ")
            lastWasSpace = true
        }
        if model.layer != .letters { model.layer = .letters }
        autoShift()
        suggest()
    }

    func returnTapped() {
        model.undoable = nil
        lastWasSpace = false
        correctWord()
        textDocumentProxy.insertText("\n")
        autoShift()
        suggest()
    }

    /// One character, or a whole word once the key has been held a while. Straight after a correction, it puts back
    /// what was typed instead.
    func deleteBackward(_ unit: KeyboardTyping.DeleteUnit = .character) {
        model.undoable = nil
        lastWasSpace = false
        if unit == .character, revertCorrection() { return }
        lastCorrection = nil
        let count = unit == .word ? max(1, KeyboardTyping.wordDeletionCount(before: textDocumentProxy.documentContextBeforeInput ?? "")) : 1
        for _ in 0..<count { textDocumentProxy.deleteBackward() }
        autoShift()
        suggest()
    }

    // MARK: Corrections and suggestions

    /// Puts the corrected word in place of the one just typed, before the space or punctuation that ends it.
    private func correctWord() {
        lastCorrection = nil
        guard let correction = model.suggestions.first(where: \.isCorrection) else { return }
        let typed = KeyboardTyping.currentWord(before: textDocumentProxy.documentContextBeforeInput ?? "")
        guard typed == model.typedWord, !typed.isEmpty else { return }
        replaceWord(typed, with: correction.text)
        lastCorrection = (typed, correction.text)
    }

    /// Delete right after a correction: the word as it was typed, and it's left alone from then on.
    private func revertCorrection() -> Bool {
        guard let correction = lastCorrection else { return false }
        lastCorrection = nil
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        // The correction, then the one space or mark that ended it.
        guard !before.isEmpty, before.dropLast().hasSuffix(correction.replaced) else { return false }
        for _ in 0..<(correction.replaced.count + 1) { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(correction.typed)
        kept.insert(correction.typed.lowercased())
        autoShift()
        suggest()
        return true
    }

    /// A suggestion tapped: in place of the word being typed, with a space after it.
    func choose(_ suggestion: KeyboardModel.Suggestion) {
        UIDevice.current.playInputClick()
        let typed = KeyboardTyping.currentWord(before: textDocumentProxy.documentContextBeforeInput ?? "")
        if suggestion.isTyped {
            kept.insert(typed.lowercased())
        } else {
            replaceWord(typed, with: suggestion.text)
        }
        lastCorrection = nil
        textDocumentProxy.insertText(" ")
        lastWasSpace = true
        autoShift()
        suggest()
    }

    private func replaceWord(_ typed: String, with replacement: String) {
        for _ in 0..<typed.count { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(replacement)
    }

    /// What to offer for the word being typed: the correction it'll get at the space (and the word as typed, to keep it),
    /// or ways to finish it. A text replacement's phrase comes first.
    private func suggest() {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let word = KeyboardTyping.currentWord(before: before)
        model.typedWord = word
        guard !word.isEmpty, wantsCorrections else {
            model.suggestions = []
            return
        }
        var suggestions: [KeyboardModel.Suggestion] = []
        if let shortcut = lexicon.first(where: { $0.userInput.caseInsensitiveCompare(word) == .orderedSame && $0.documentText != $0.userInput }) {
            suggestions.append(.init(text: shortcut.documentText, isCorrection: true))
        }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let isName = lexicon.contains { $0.userInput.caseInsensitiveCompare(word) == .orderedSame }
        // Words this could be the start of, likeliest first: half a word reads as a misspelling until it's finished.
        let completions = word.count < 2 ? [] : (checker.completions(forPartialWordRange: range, in: word, language: language) ?? [])
            .filter { $0.caseInsensitiveCompare(word) != .orderedSame }
            .map { KeyboardTyping.matchingCase($0, like: word) }
        let misspelled = KeyboardTyping.isCheckable(word) && !isName && !kept.contains(word.lowercased()) && !UITextChecker.hasLearnedWord(word)
            && checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language).location != NSNotFound
        if misspelled {
            let guesses = (checker.guesses(forWordRange: range, in: word, language: language) ?? []).map { KeyboardTyping.matchingCase($0, like: word) }
            // A capital in the middle of a sentence is likely a name: offered, never put in by itself.
            let sentenceStart = Self.startsSentence(String(before.dropLast(word.count)))
            let deliberateCapital = word.first?.isUppercase == true && !sentenceStart
            // The likeliest word it's the start of ("tomorr" is "tomorrow", not "tumor"), else the checker's best guess:
            // only when it's a near miss, never a lesser guess because it's close.
            let best = deliberateCapital || !suggestions.isEmpty ? nil
                : [completions.first, guesses.first].compactMap { $0 }.first { KeyboardTyping.isSafeCorrection(of: word, to: $0) }
            suggestions.insert(.init(text: word, isTyped: true), at: 0)
            if let best { suggestions.append(.init(text: best, isCorrection: true)) }
            for other in completions + guesses where !suggestions.contains(where: { $0.text == other }) {
                suggestions.append(.init(text: other))
            }
        } else if suggestions.isEmpty {
            suggestions = completions.prefix(3).map { .init(text: $0) }
        }
        model.suggestions = Array(suggestions.prefix(3))
    }

    /// Fields that want words as typed: addresses, passwords, codes, numbers.
    private var wantsCorrections: Bool {
        let proxy = textDocumentProxy
        if proxy.autocorrectionType == .no || proxy.spellCheckingType == .no || proxy.isSecureTextEntry == true { return false }
        if let type = proxy.keyboardType, [.URL, .emailAddress, .webSearch, .twitter, .numberPad, .phonePad, .decimalPad, .asciiCapableNumberPad,
                                           .namePhonePad].contains(type) { return false }
        if let content = proxy.textContentType, [.username, .password, .newPassword, .oneTimeCode, .emailAddress, .URL].contains(content) { return false }
        return true
    }

    private static func startsSentence(_ before: String) -> Bool {
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasSuffix("\n") || [".", "!", "?"].contains(trimmed.last)
    }

    /// The keyboard types English: the iPhone's English (British spelling, say) when it has one, American otherwise.
    private static func checkerLanguage() -> String {
        let available = UITextChecker.availableLanguages
        let english = Locale.preferredLanguages.map { $0.replacingOccurrences(of: "-", with: "_") }.first { $0.hasPrefix("en") }
        if let english, available.contains(english) { return english }
        return available.contains("en_US") ? "en_US" : available.first ?? "en_US"
    }

    /// Once for a capital, twice quickly to keep capitals on.
    func shiftTapped() {
        let now = Date()
        if model.shift == .once, now.timeIntervalSince(lastShift) < 0.35 {
            model.shift = .locked
        } else {
            model.shift = model.shift == .off ? .once : .off
        }
        lastShift = now
    }

    /// Capitals where the field wants them: at the start of a sentence, or of every word.
    private func autoShift() {
        guard model.shift != .locked else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let startsSomething: Bool
        switch textDocumentProxy.autocapitalizationType ?? .sentences {
        case .none: startsSomething = false
        case .allCharacters: startsSomething = true
        case .words: startsSomething = before.isEmpty || before.last?.isWhitespace == true
        default:
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            startsSomething = trimmed.isEmpty || before.hasSuffix("\n") || (before.last == " " && [".", "!", "?"].contains(trimmed.last))
        }
        model.shift = startsSomething ? .once : .off
    }

    private static func returnTitle(_ type: UIReturnKeyType?) -> String? {
        switch type {
        case .go: "go"
        case .search, .google, .yahoo: "search"
        case .send: "send"
        case .done: "done"
        case .next: "next"
        case .join: "join"
        case .route: "route"
        case .continue: "continue"
        case .emergencyCall: "call"
        default: nil
        }
    }

    func nextKeyboard() {
        advanceToNextInputMode()
    }

    /// Keyboards can't open apps through the documented API, so this goes through the app in the responder chain, as
    /// other dictation keyboards do; a scene takes the same message with options of its own.
    private func openApp() {
        let selector = sel_registerName("openURL:options:completionHandler:")
        let url = KeyboardBridge.listenURL as NSURL
        var chain: [UIResponder] = []
        var responder: UIResponder? = self
        while let current = responder {
            chain.append(current)
            responder = current.next
        }
        if let app = chain.first(where: { $0 is UIApplication }), app.responds(to: selector), let method = app.method(for: selector) {
            typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
            unsafeBitCast(method, to: Open.self)(app, selector, url, NSDictionary(), nil)
        } else if let scene = chain.first(where: { $0 is UIScene }), scene.responds(to: selector), let method = scene.method(for: selector) {
            typealias Open = @convention(c) (AnyObject, Selector, NSURL, AnyObject?, (@convention(block) (Bool) -> Void)?) -> Void
            unsafeBitCast(method, to: Open.self)(scene, selector, url, UIScene.OpenExternalURLOptions(), nil)
        } else {
            model.note = "Open Binders to start the microphone, then come back here."
        }
    }
}

@MainActor
@Observable
final class KeyboardModel {
    weak var controller: KeyboardViewController?
    var state = KeyboardBridge.State()
    var hasFullAccess = false
    var showsGlobe = true
    /// The mic key was tapped and the app hasn't started yet.
    var starting = false
    /// What was just typed, until something else is.
    var undoable: String?
    /// Above the keys while typing a word: ways to finish it, or the correction it gets at the space.
    var suggestions: [Suggestion] = []
    /// The word they're for.
    var typedWord = ""

    struct Suggestion: Hashable {
        let text: String
        /// Put in at the space or punctuation, unless another is tapped.
        var isCorrection = false
        /// The word as typed, to keep it.
        var isTyped = false
    }
    /// Something to say that isn't the app's state.
    var note: String?
    var layer = Layer.letters
    var shift = Shift.off
    /// The return key's word, when the field has one ("send", "search"); the symbol otherwise.
    var returnTitle: String?

    enum Layer { case letters, numbers, symbols }
    enum Shift { case off, once, locked }

    /// The keys make way for the dictation while it's on.
    var isDictating: Bool { starting || state.phase == .listening || state.phase == .cleaning }
}
