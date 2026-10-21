import AVFoundation

/// Says Command Mode's answers to spoken questions out loud, in the system's voice, when Read answers aloud is on
/// (Settings → AI, next to Command Mode). Questions typed on the Knowledge page are never read aloud.
@MainActor
final class AnswerSpeaker {
    static let shared = AnswerSpeaker()

    private let synthesizer = AVSpeechSynthesizer()
    /// Whether answers are read aloud: the setting, or a self-test's stand-in for it.
    var isOn: () -> Bool = { AppSettings.shared.readAnswersAloud }
    /// For self-tests: told what would be said, instead of saying it.
    var onSpeak: ((String) -> Void)?

    /// Says it, once anything still being said has stopped. Nothing while the setting is off.
    func speak(_ text: String) {
        let words = text.trimmed
        guard isOn(), !words.isEmpty else { return }
        stop()
        if let onSpeak { return onSpeak(words) }
        synthesizer.speak(AVSpeechUtterance(string: words))
    }

    /// Stops what's being said: the answer's panel closed, or you're about to speak.
    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }
}
