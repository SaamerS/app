import BindersKit
import Foundation
import Observation

/// The iPhone's All-day capture records, as the screens show them. The files themselves are `CaptureFiles`.
@MainActor
@Observable
final class CaptureStore {
    static let shared = CaptureStore()

    private(set) var conversations: [CapturedConversation] = []

    private init() {
        reload()
    }

    func reload() {
        conversations = CaptureFiles.all()
    }

    func conversation(_ id: UUID) -> CapturedConversation? { conversations.first { $0.id == id } }

    /// Saves a conversation's record, adding it if it's new.
    func save(_ conversation: CapturedConversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
            conversations.sort { $0.started > $1.started }
        }
        CaptureFiles.write(conversation)
    }

    func update(_ id: UUID, _ change: (inout CapturedConversation) -> Void) {
        guard var conversation = conversation(id) else { return }
        change(&conversation)
        save(conversation)
    }

    /// The audio goes; the record and its transcript stay, to read here and to share again.
    func deleteAudio(_ id: UUID) {
        try? FileManager.default.removeItem(at: CaptureFiles.audioURL(id))
        update(id) {
            $0.audioDeleted = true
            $0.keepAudioUntil = nil
        }
    }

    /// Gone from this iPhone: its audio, its record and its transcript.
    func delete(_ id: UUID) {
        CaptureFiles.remove(id)
        conversations.removeAll { $0.id == id }
    }

    /// Lets go of audio kept for the developer setting once its day is up; of audio still here once its text is in the
    /// outbox (Binders stopped before it could go); of a failed conversation's audio three days after it was heard, once
    /// this version has counted its tries; and of records more than 30 days old once they were sent, or failed and lost
    /// their audio. Runs at launch and whenever the app comes to the front.
    func tidy(now: Date = Date()) {
        let month = now.addingTimeInterval(-30 * 86_400)
        for conversation in conversations {
            if let until = conversation.keepAudioUntil, until < now { deleteAudio(conversation.id) }
            if [.queued, .sent].contains(conversation.state), !conversation.audioDeleted, conversation.keepAudioUntil == nil,
               conversation.transcript != nil {
                deleteAudio(conversation.id)
            }
            if conversation.state == .failed, !conversation.audioDeleted, conversation.failures != nil,
               conversation.ended < now.addingTimeInterval(-3 * 86_400) {
                deleteAudio(conversation.id)
            }
            if conversation.state == .sent, conversation.started < month { delete(conversation.id) }
            if conversation.state == .failed, conversation.audioDeleted, conversation.started < month { delete(conversation.id) }
        }
    }

    /// Today's conversations, newest first.
    func today(calendar: Calendar = .current) -> [CapturedConversation] {
        conversations.filter { calendar.isDateInToday($0.started) }
    }

    /// Conversations from before today, newest first, grouped by day.
    func earlier(calendar: Calendar = .current) -> [(day: Date, conversations: [CapturedConversation])] {
        let older = conversations.filter { !calendar.isDateInToday($0.started) }
        let days = Dictionary(grouping: older) { calendar.startOfDay(for: $0.started) }
        return days.keys.sorted(by: >).map { ($0, days[$0]!.sorted { $0.started > $1.started }) }
    }
}
