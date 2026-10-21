import BindersKit
import Foundation

/// Ask's answer as the Mac writes it: the Mac's `binders/ask-progress` notifications, each handed to the question it's
/// for by its token. An update for a question no screen is asking any more is let go.
@MainActor
final class AskStreams {
    static let shared = AskStreams()
    private var listeners: [String: (LinkAskProgress.Update) -> Void] = [:]

    func listen(_ token: String, _ listener: @escaping (LinkAskProgress.Update) -> Void) {
        listeners[token] = listener
    }

    func stop(_ token: String) {
        listeners[token] = nil
    }

    /// From the link (MacConnection).
    func received(_ update: LinkAskProgress.Update) {
        listeners[update.token]?(update)
    }
}

extension MacConnection {
    /// Ask, answered by the Mac. A Mac that streams (`LinkFeatures.askProgress`) tells `progress` what it has found and
    /// the answer so far as it writes it; an older one sends only the answer, as before.
    func ask(_ question: String, timeout: TimeInterval = LinkTimeouts.ask, progress: @escaping (LinkAskProgress.Update) -> Void) async throws -> Answer {
        var arguments: [String: Any] = ["question": question]
        var token: String?
        if streamsAsk {
            let id = UUID().uuidString
            token = id
            arguments[LinkAskProgress.tokenKey] = id
            AskStreams.shared.listen(id, progress)
        }
        defer { if let token { AskStreams.shared.stop(token) } }
        return try Self.decode(Answer.self, from: try await call("ask_knowledge", arguments, timeout: timeout))
    }

    /// The Mac shows Ask's passages and writes its answer as it goes.
    var streamsAsk: Bool { macFeatures.contains(LinkFeatures.askProgress) }

    /// The passages in an update, in ask_knowledge's reply shape.
    static func passages(in update: LinkAskProgress.Update) -> [Passage]? {
        guard let data = update.sources else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode([Passage].self, from: data)
    }
}
