import Foundation
import Observation
import SwiftData
import BindersKit

/// Conversations the iPhone heard during the day, as they come in over the phone link. Each becomes a record of its own
/// kind: notes written the way a meeting's are, its promises as to-dos, filed in the binder it belongs to, and searchable
/// and askable like a meeting. Only text ever arrives; the audio stayed on the phone. Conversations are never shared
/// with the team, whatever binder they land in.
@MainActor
@Observable
final class ConversationService {
    /// Conversations being written up right now.
    private(set) var processing: Set<UUID> = []

    @ObservationIgnored private let meetings: MeetingService
    /// For the knowledge base and the boards, which suggestions draw on.
    @ObservationIgnored weak var controller: DictationController?
    private var settings: AppSettings { AppSettings.shared }

    init(meetings: MeetingService) {
        self.meetings = meetings
    }

    enum Received: Equatable {
        case kept(UUID)
        /// Sent before (its answer was lost on the way): nothing changes.
        case known(UUID)
    }

    /// Keeps a conversation: the record and its transcript at once, then its notes and its binder. One sent again is kept once.
    @discardableResult
    func receive(_ payload: ConversationPayload) -> Received {
        let id = payload.id
        if record(id) != nil { return .known(id) }
        let device = payload.device.trimmed
        let record = MeetingRecord(title: MeetingService.conversationPlaceholderPrefix + payload.started.formatted(date: .omitted, time: .shortened),
                                   appName: device.isEmpty ? "iPhone" : device, templateID: MeetingTemplate.conversation.id)
        record.id = id
        record.kind = MeetingRecord.conversationKind
        record.createdAt = payload.started
        record.endedAt = payload.ended
        record.duration = payload.duration
        record.status = "processing"
        record.speakerNames = payload.speakers
        // Filed where new things go until it's been read; never shared.
        record.binderID = (Store.shared.binder(settings.currentBinderID) ?? Store.shared.defaultBinder()).id
        record.sharedWithTeam = false
        Store.shared.insert(record)
        // Fresh ids: a segment's id is unique across every transcript here, and one a client reused would move another
        // conversation's line into this one.
        Store.shared.replaceSegments(for: id, with: payload.segments.sorted { $0.start < $1.start }.map {
            TranscriptSegment(channel: $0.channel, start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker)
        })
        Log.meeting.info("Conversation \(id) from \(record.appName ?? "iPhone"): \(payload.segments.count) segments, \(Int(payload.duration)) s, \(payload.engine)")
        Task { await process(record) }
        return .kept(id)
    }

    /// Writes its notes and files it. A conversation too slight to keep is marked trivial: out of sight, deleted after a week.
    func process(_ record: MeetingRecord) async {
        let id = record.id
        guard !processing.contains(id) else { return }
        processing.insert(id)
        defer { processing.remove(id) }
        let segments = Store.shared.segments(for: id)
        let words = segments.reduce(0) { $0 + $1.text.wordCount }
        if words < ConversationPrompts.minimumWords {
            record.status = "trivial"
            Store.shared.save()
            return
        }
        await meetings.summarize(record, segments: segments, templateID: MeetingTemplate.conversation.id)
        guard exists(record), record.status != "trivial" else { return }
        await route(record)
        guard exists(record) else { return }
        record.status = "ready"
        Store.shared.save()
        await suggest(record)
    }

    // MARK: Suggestions

    /// What to offer once a conversation is written up: a card for each thing you said you'd do that isn't on a board,
    /// and an answer, from your binders, to each question you asked that the conversation didn't answer. Heard by this
    /// Mac, they're notifications here; heard by the iPhone, the iPhone asks for them and shows them there.
    func suggest(_ record: MeetingRecord) async {
        guard record.isConversation, record.status == "ready", settings.suggestCards || settings.suggestAnswers else { return }
        let binder = Store.shared.binder(record.binderID)?.name ?? "General"
        var offered: [ConversationSuggestion] = []
        let names = record.speakerNames
        let segments = Store.shared.segments(for: record.id)
        let youKnown = segments.contains { $0.speaker == TranscriptSegment.you || names[$0.speaker] == TranscriptSegment.you }
        if settings.suggestCards {
            for candidate in SuggestionPrompts.cardCandidates(summary: record.summary, conversation: record.id, youKnown: youKnown)
                where controller?.board.card(forTodo: candidate.todo) == nil {
                offered.append(ConversationSuggestion(conversation: record.id, kind: .card, text: candidate.text, binder: binder, todo: candidate.todo))
            }
        }
        if settings.suggestAnswers, let client = settings.makeLLMClient(), let knowledge = controller?.knowledge {
            let transcript = TranscriptFormatter.plainText(segments, names: names)
            let questions = (try? await client.complete(system: SuggestionPrompts.questionsSystemPrompt(youKnown: youKnown),
                                                        user: SuggestionPrompts.questionsUserPrompt(transcript: transcript),
                                                        maxTokens: 200, temperature: 0.1, timeout: 180))
                .map { SuggestionPrompts.parseQuestions($0) } ?? []
            for question in questions {
                // The conversation itself didn't answer it, so it isn't a source.
                let hits = await knowledge.search(question, limit: 8).filter { $0.sourceID != record.id.uuidString }
                guard !hits.isEmpty else { continue }
                let contexts = hits.map { KnowledgeContext(label: "\($0.kind.singularName) “\($0.title)” · \($0.metaLine)", text: $0.text) }
                guard let output = try? await client.complete(system: SuggestionPrompts.answerSystemPrompt(today: Date().formatted(date: .complete, time: .omitted)),
                                                              user: KnowledgePrompts.answerUserPrompt(question: question, contexts: contexts),
                                                              maxTokens: 250, temperature: 0.1, timeout: 180),
                      let answer = SuggestionPrompts.parseAnswer(output) else { continue }
                var titles: [String] = []
                for hit in hits where !titles.contains(hit.title) { titles.append(hit.title) }
                offered.append(ConversationSuggestion(conversation: record.id, kind: .answer, text: question, binder: binder, answer: answer,
                                                      sources: Array(titles.prefix(3))))
            }
        }
        guard exists(record), !offered.isEmpty else { return }
        // Offered before (written up again): keep what you already said yes or no to.
        let earlier = Dictionary(record.suggestions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        record.suggestions = offered.map { earlier[$0.id] ?? $0 }
        Store.shared.save()
        if record.appName == "Mac" {
            for suggestion in record.suggestions where suggestion.status == .offered && earlier[suggestion.id] == nil {
                MacNotifications.shared.post(suggestion)
            }
        }
    }

    /// Yes to a suggestion: the card goes on its binder's board, linked to the to-do; an answer is just marked seen.
    @discardableResult
    func accept(_ suggestionID: String) -> (ok: Bool, message: String) {
        guard let (record, index) = suggestion(suggestionID) else { return (false, "That suggestion is gone.") }
        var list = record.suggestions
        let suggestion = list[index]
        var message = "Done."
        if suggestion.kind == .card {
            guard let todo = suggestion.todo.flatMap(Todos.find), let board = controller?.board else {
                return (false, "That to-do has changed or is gone.")
            }
            let made = board.create(from: todo, column: .ready, binderID: record.binderID, by: .you)
            message = made.existed ? "Already on the \(suggestion.binder) board." : "On the \(suggestion.binder) board."
        }
        list[index].status = .accepted
        record.suggestions = list
        Store.shared.save()
        return (true, message)
    }

    func dismiss(_ suggestionID: String) {
        guard let (record, index) = suggestion(suggestionID) else { return }
        var list = record.suggestions
        list[index].status = .dismissed
        record.suggestions = list
        Store.shared.save()
    }

    /// Suggestions on recent conversations the iPhone heard, for the iPhone to show.
    func suggestionsForPhone(since: Date = Date().addingTimeInterval(-3 * 86_400)) -> [ConversationSuggestion] {
        let kind = MeetingRecord.conversationKind
        let records = (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate {
            $0.kind == kind && $0.createdAt > since
        }))) ?? []
        return records.filter { $0.appName != "Mac" }.flatMap(\.suggestions)
    }

    private func suggestion(_ id: String) -> (MeetingRecord, Int)? {
        let kind = MeetingRecord.conversationKind
        let records = (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.kind == kind }))) ?? []
        for record in records where record.suggestionsJSON.contains(id) {
            if let index = record.suggestions.firstIndex(where: { $0.id == id }) { return (record, index) }
        }
        return nil
    }

    /// Picks the binder it belongs to with the language model, from your binders' names and what's in them. When the model
    /// can't tell, it stays where new things go.
    func route(_ record: MeetingRecord) async {
        let binders = Store.shared.binders().filter { !$0.isTeamCopy }
        guard binders.count > 1, let client = settings.makeLLMClient() else { return }
        let hints = binders.map { ConversationPrompts.BinderHint(name: $0.name, titles: recentTitles(in: $0.id, excluding: record.id)) }
        let prompt = ConversationPrompts.routingUserPrompt(binders: hints, title: record.title, summary: String(record.summary.prefix(2_000)))
        guard let output = try? await client.complete(system: ConversationPrompts.routingSystemPrompt(), user: prompt,
                                                      maxTokens: 80, temperature: 0.1, timeout: 180),
              exists(record) else { return }
        let picked = ConversationPrompts.parseRouting(output, names: hints.map(\.name))
        if let name = picked.binder, let binder = binders.first(where: { $0.name == name }) {
            Store.shared.move(record, to: binder)
            record.routingReason = picked.reason
        } else {
            record.routingReason = picked.reason.map { "No binder clearly fit: \($0)" } ?? "No binder clearly fit"
        }
        Store.shared.save()
    }

    /// Picks up conversations a quit or crash left half-written, and lets go of trivial ones older than a week.
    func recover() {
        Store.shared.purgeTrivialConversations()
        let kind = MeetingRecord.conversationKind
        let stuck = (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate {
            $0.kind == kind && $0.status == "processing"
        }))) ?? []
        guard !stuck.isEmpty else { return }
        Task {
            for record in stuck { await process(record) }
        }
    }

    /// A conversation that was trivial, kept after all.
    func keep(_ record: MeetingRecord) async {
        guard record.isConversation, record.status == "trivial" else { return }
        record.status = "processing"
        Store.shared.save()
        let segments = Store.shared.segments(for: record.id)
        await meetings.summarize(record, segments: segments, templateID: MeetingTemplate.conversation.id)
        guard exists(record) else { return }
        // Asked to keep it, so the model's "nothing here" doesn't throw it out again.
        if record.status == "trivial" { record.status = "processing" }
        await route(record)
        guard exists(record) else { return }
        record.status = "ready"
        Store.shared.save()
    }

    private func record(_ id: UUID) -> MeetingRecord? {
        var descriptor = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? Store.shared.context.fetch(descriptor))?.first
    }

    private func recentTitles(in binderID: UUID, excluding id: UUID) -> [String] {
        let context = Store.shared.context
        var meetings = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binderID && $0.status == "ready" && $0.id != id },
                                                      sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        meetings.fetchLimit = 3
        var notes = FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        notes.fetchLimit = 3
        let titles = ((try? context.fetch(meetings)) ?? []).map(\.title) + ((try? context.fetch(notes)) ?? []).map(\.title)
        return titles.map { String($0.prefix(80)) }.filter { !$0.isEmpty }
    }

    private func exists(_ record: MeetingRecord) -> Bool {
        record.modelContext != nil && !record.isDeleted
    }
}
