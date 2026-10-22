import Foundation

/// A model's reply with its thinking set apart: the reasoning some models write before they answer, in the markers their
/// chat format uses. A model running in Binders (MLX) sends it inside the reply, markers and all, unless its library knows
/// the format; a server usually sends it apart. What Binders reads of a reply is the answer: the thinking is never taken
/// for one.
public enum ModelThinking {
    /// A thinking block's opening marker and the markers that end it.
    struct Block {
        var open: String
        var close: [String]
        /// Whether a reply may start inside it, its opening written by the chat template: only for markers nothing else
        /// uses.
        var startsInside: Bool
    }

    /// `<think>` (Qwen, DeepSeek and most others), Gemma 4's thought channel, gpt-oss's analysis channel, Mistral's
    /// `[THINK]`, and the plain tags some models write.
    static let blocks: [Block] = [
        Block(open: "<think>", close: ["</think>"], startsInside: true),
        Block(open: "<thinking>", close: ["</thinking>"], startsInside: true),
        Block(open: "<reasoning>", close: ["</reasoning>"], startsInside: false),
        Block(open: "<|channel>", close: ["<channel|>"], startsInside: true),
        Block(open: "<|channel|>analysis<|message|>", close: ["<|end|>", "<|channel|>final<|message|>"], startsInside: false),
        Block(open: "[THINK]", close: ["[/THINK]"], startsInside: true),
    ]

    public struct Split: Equatable, Sendable {
        /// The reply without its thinking.
        public var answer: String
        /// What it thought, every block together.
        public var thought: String
        /// The reply ended inside a thinking block: it ran out, or was stopped, before it answered.
        public var stillThinking: Bool

        /// It thought, and wrote nothing else.
        public var onlyThinking: Bool {
            (!thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || stillThinking)
                && ModelThinking.plain(answer).isEmpty
        }
    }

    /// The reply's answer and thinking. A block still open at the end takes everything after its marker; a closing marker
    /// with no opening before it (the chat template opened it) makes everything before it thinking.
    public static func split(_ reply: String) -> Split {
        var rest = Substring(reply)
        var answer = ""
        var thought = ""
        // Started inside its thinking: the earliest closing marker, when no opening marker of its kind comes before it.
        var earliest: Range<Substring.Index>?
        for block in blocks where block.startsInside {
            for close in block.close {
                guard let found = rest.range(of: close) else { continue }
                if let open = rest.range(of: block.open), open.lowerBound < found.lowerBound { continue }
                if earliest == nil || found.lowerBound < earliest!.lowerBound { earliest = found }
            }
        }
        if let earliest {
            thought += rest[..<earliest.lowerBound]
            rest = rest[earliest.upperBound...]
        }
        while true {
            var next: (range: Range<Substring.Index>, block: Block)?
            for block in blocks {
                guard let found = rest.range(of: block.open) else { continue }
                if next == nil || found.lowerBound < next!.range.lowerBound { next = (found, block) }
            }
            guard let next else {
                answer += rest
                break
            }
            answer += rest[..<next.range.lowerBound]
            let after = rest[next.range.upperBound...]
            let close = next.block.close.compactMap { after.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
            guard let close else {
                thought += after
                return Split(answer: answer, thought: thought, stillThinking: true)
            }
            thought += after[..<close.lowerBound]
            rest = after[close.upperBound...]
        }
        return Split(answer: answer, thought: thought, stillThinking: false)
    }

    /// The reply without its thinking.
    public static func answer(_ reply: String) -> String { split(reply).answer }

    /// Text without the special tokens a chat format leaves in it (`<|im_end|>`, `<turn|>`, `<end_of_turn>`, `<eos>`…),
    /// trimmed.
    public static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^<>\s]{0,40}\|>|<\|[^<>\s]{0,40}>|<[^<>\s]{0,40}\|>|<(?:end_of_turn|start_of_turn|eos|bos|/s|pad)>"#,
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
