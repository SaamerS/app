import Foundation
import BindersKit

/// The writes done for requests that carried a `request_id`, so one sent again (its reply lost on the way, even across a
/// restart) gets the first answer and isn't done twice: the iPhone's outbox sends each note, to-do, answer and hand-off
/// with its id to a Mac that lists `LinkFeatures.dedupe`. Kept a week, at most 5,000 (RequestLedger), in
/// handled-requests.json in the data folder, written whole each time.
@MainActor
final class HandledRequests {
    static let shared = HandledRequests()

    private let url: URL
    private var ledger: RequestLedger

    init(url: URL = AppPaths.support.appendingPathComponent("handled-requests.json")) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // One that can't be read starts over: at worst a resend is done again, as before there was a file.
        ledger = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(RequestLedger.self, from: $0) } ?? RequestLedger()
    }

    /// What a request is known by, when it carries a request_id: its action, who sent it (an agent by its name; the
    /// iPhone and the app are you) and the id. Nil without one.
    static func key(for request: InboxRequest) -> String? {
        let fields = request.fields
        let sender = fields["actor_kind"] == BoardActor.Kind.agent.rawValue ? "agent:\(fields["actor"] ?? "")" : "you"
        return RequestLedger.key(action: request.action, requestID: fields["request_id"] ?? "", sender: sender)
    }

    /// The first answer to a request done within the week, if it was.
    func answer(for key: String) -> InboxResult? {
        ledger.answer(for: key).map { InboxResult(ok: true, id: $0.id, message: $0.message) }
    }

    /// Keeps what a request that worked answered.
    func remember(_ result: InboxResult, for key: String) {
        ledger.remember(key, id: result.id, message: result.message)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(ledger).write(to: url, options: .atomic)
        } catch {
            Log.app.error("Couldn't keep the handled requests: \(error.localizedDescription)")
        }
    }
}
