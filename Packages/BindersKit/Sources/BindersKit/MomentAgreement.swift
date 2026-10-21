import Foundation

/// Which moments carry the iPhone's yes to the agents it has said yes to (MomentPayload.agreed), so the Mac may start one
/// of them without a tap: a "Binders, …" said on its own near the iPhone or, while the iPhone is in Auto, something heard
/// on its own, in your voice at the start bar Calibrate set or closer, with nothing else playing on the iPhone, to a Mac
/// that lists `MomentPayload.agreedFeature` (and, heard on its own, `MomentPayload.autoFeature`). Never one said in a
/// conversation, found in a transcript, told to Siri or a Shortcut, or heard on its own outside Auto. Pure, so `swift test`
/// holds every source; the iPhone only fills in `Heard` and sends what this returns.
public enum MomentAgreement {
    /// How a moment was heard.
    public struct Heard: Equatable, Sendable {
        /// It opened with "Binders," as it was said (the gate's wake).
        public var wake: Bool
        /// The speech engine that wrote it down; "siri" and "test" never carry the yes.
        public var engine: String
        /// Found in a capture's transcript later.
        public var fromTranscript: Bool
        /// Said while a conversation was being captured. Nil too for a moment said on its own that took the words of the
        /// conversation that opened at its first word (MomentPayload.alone), to a Mac that lists `autoFeature`.
        public var conversation: UUID?
        /// Its first second and a half was checked for "Binders,", as for something said in a conversation.
        public var checkedFirst: Bool
        /// The voice print's score, nil when it wasn't scored.
        public var voice: Double?
        /// The start bar (VoicePrint.startThreshold): nil until Calibrate set it.
        public var startBar: Double?
        /// The iPhone was playing other audio when it was heard.
        public var otherAudioPlaying: Bool
        /// The iPhone's mode when it was heard (MomentMode); nil for Siri, a transcript, and every caller before it.
        public var mode: MomentMode?

        public init(wake: Bool, engine: String, fromTranscript: Bool = false, conversation: UUID? = nil, checkedFirst: Bool = false,
                    voice: Double? = nil, startBar: Double? = nil, otherAudioPlaying: Bool = false, mode: MomentMode? = nil) {
            self.wake = wake
            self.engine = engine
            self.fromTranscript = fromTranscript
            self.conversation = conversation
            self.checkedFirst = checkedFirst
            self.voice = voice
            self.startBar = startBar
            self.otherAudioPlaying = otherAudioPlaying
            self.mode = mode
        }
    }

    /// The yes to send, or nil: the consents (by name as the iPhone keys them, with the fingerprint each had) whose
    /// fingerprint isn't empty, when every condition holds. A "Binders, …" as before; heard on its own, only in Auto, to a
    /// Mac that hands over in Auto. Nil when none are left.
    public static func agreed(_ heard: Heard, macFeatures: Set<String>, consents: [String: String]) -> [String: String]? {
        guard !["siri", "test"].contains(heard.engine.lowercased()), !heard.fromTranscript, heard.conversation == nil,
              !heard.checkedFirst, !heard.otherAudioPlaying, let voice = heard.voice, let bar = heard.startBar, voice >= bar,
              macFeatures.contains(MomentPayload.agreedFeature) else { return nil }
        if !heard.wake {
            guard heard.mode == .auto, macFeatures.contains(MomentPayload.autoFeature) else { return nil }
        }
        let kept = consents.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty && !$0.value.isEmpty }
        return kept.isEmpty ? nil : kept
    }

    /// In Auto, why this iPhone won't send its yes with one it kept (MomentPayload.autoHold): "calibrate" (no start bar
    /// yet), "audio" (other audio was playing) or "voice" (not scored, or under the start bar). Nil when it would, and
    /// outside Auto or to a Mac that doesn't hand over in Auto. Where it came from (a conversation, Siri, a transcript)
    /// needs no word: the Mac sees that itself.
    public static func hold(_ heard: Heard, macFeatures: Set<String>) -> String? {
        guard heard.mode == .auto, macFeatures.contains(MomentPayload.autoFeature) else { return nil }
        guard let bar = heard.startBar else { return Hold.calibrate }
        if heard.otherAudioPlaying { return Hold.audio }
        guard let voice = heard.voice, voice >= bar else { return Hold.voice }
        return nil
    }

    /// The words `hold` gives, which MomentPayload.autoHold carries.
    public enum Hold {
        public static let calibrate = "calibrate"
        public static let audio = "audio"
        public static let voice = "voice"
    }
}
