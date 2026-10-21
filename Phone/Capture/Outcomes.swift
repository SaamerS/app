import BindersKit
import Foundation
import Observation

/// What became of each capture once it reached the Mac: filed in a binder with its to-dos, not kept, or not written up,
/// asked after whenever the Mac's meetings change. Only while connected, only for the last three days' sent captures
/// that haven't settled, so it costs nothing once everything has an outcome.
@MainActor
final class OutcomeCenter {
    static let shared = OutcomeCenter()

    weak var connection: MacConnection?
    private var refreshing = false
    private var refreshAgain = false

    /// Asks the Mac about the sent captures still waiting for an outcome, and keeps what it says on each.
    func refresh() async {
        guard let connection, connection.isConnected, connection.hasOutcomes else { return }
        guard !refreshing else { return refreshAgain = true }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            await refreshOnce(connection)
        } while refreshAgain
    }

    private func refreshOnce(_ connection: MacConnection) async {
        let since = Date().addingTimeInterval(-3 * 86_400)
        let waiting = CaptureStore.shared.conversations
            .filter { $0.state == .sent && $0.ended > since && !Self.settled($0.outcomeState) }
            .map(\.id.uuidString)
        // And moments the Mac was still working on, or acted on since (Undo, Assign).
        let moments = MomentCenter.shared.moments.filter { $0.state == "sent" && $0.heard > since && $0.outcomeState != "undone"
            && $0.outcomeState != "dismissed" && $0.outcomeState != "nothing" }.map(\.id)
        let ids = waiting + moments.map(\.uuidString)
        guard !ids.isEmpty,
              let reply = try? await connection.request(CaptureOutcome.listMethod, ["ids": ids]) as? [String: Any],
              let items = reply["outcomes"] as? [Any] else { return }
        let decoded = CaptureOutcome.decodeEach(items)
        // A decision that came after the reply rings; what you did yourself doesn't (MomentCenter.apply).
        for outcome in decoded where moments.contains(outcome.id) {
            MomentCenter.shared.apply(outcome, notify: true)
        }
        defer { CaptureActivity.update() }
        for outcome in decoded where !moments.contains(outcome.id) {
            // Lane Y2: what it read from what you said, and why it didn't read it: its items become moments here, asked
            // after at once, then one notification for the capture.
            if let current = CaptureStore.shared.conversation(outcome.id),
               current.found != outcome.found || current.soloLine != outcome.soloLine {
                CaptureStore.shared.update(outcome.id) {
                    $0.found = outcome.found
                    $0.soloLine = outcome.soloLine
                }
                if let found = outcome.found, !found.isEmpty {
                    await foundIn(outcome, found: found, connection: connection)
                }
            }
            guard let current = CaptureStore.shared.conversations.first(where: { $0.id == outcome.id }),
                  current.outcome != outcome.line || current.outcomeState != outcome.state else { continue }
            // Filed in a binder now: by touch, with Binders in front (several at once are one).
            if outcome.state == CaptureOutcome.States.filed, current.outcomeState != outcome.state { Haptics.shared.success() }
            CaptureStore.shared.update(outcome.id) {
                $0.outcome = outcome.line
                $0.outcomeState = outcome.state
                // Its timeline says where it went, with no words from it.
                let todos = (outcome.todos ?? 0) == 0 ? nil : outcome.todos == 1 ? "1 to-do" : "\(outcome.todos ?? 0) to-dos"
                switch outcome.state {
                case CaptureOutcome.States.filed: $0.note(CaptureStep.filed, [outcome.binder.map { "in \($0)" }, todos].compactMap { $0 }.joined(separator: " · "))
                case CaptureOutcome.States.notKept: $0.note(CaptureStep.notKept, outcome.title)
                case CaptureOutcome.States.failed: $0.note(CaptureStep.failed, outcome.title)
                default: break
                }
            }
        }
    }

    /// A capture's items, as moments of their own (`capture` set, so their outcomes never ring), and the moments said in
    /// it that went with it; their outcomes asked for now; then the capture's one notification, once.
    private func foundIn(_ outcome: CaptureOutcome, found: [CaptureOutcome.Found], connection: MacConnection) async {
        guard let record = CaptureStore.shared.conversation(outcome.id) else { return }
        let center = MomentCenter.shared
        center.foundIn(record, found: found)
        let ids = found.map(\.id.uuidString)
        if let reply = try? await connection.request(CaptureOutcome.listMethod, ["ids": ids]) as? [String: Any], let items = reply["outcomes"] as? [Any] {
            for item in CaptureOutcome.decodeEach(items) { center.apply(item, notify: true) }
        }
        guard CaptureStore.shared.conversation(outcome.id)?.noticed == nil else { return }
        CaptureStore.shared.update(outcome.id) { $0.noticed = Date() }
        await center.noticeCapture(outcome.id, found: found, line: outcome.line)
    }

    /// Filed, or not kept: the Mac won't change its mind, so the phone stops asking.
    static func settled(_ state: String?) -> Bool {
        state == CaptureOutcome.States.filed || state == CaptureOutcome.States.notKept
    }
}
