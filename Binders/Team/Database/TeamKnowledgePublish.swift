import Foundation
import SwiftData
import BindersKit

/// This Mac's items' index to the team (lane DB4): after each knowledge pass, each of this member's shared items whose
/// index changed is published whole, in one `replace_knowledge`: as a teammate's Mac will index it (the team view), with
/// the vectors this Mac's index already has for the same passages and the few it makes for those that differ, the people
/// and topics found in it, and a note's correction. Sent as a call while connected, never through the outbox: vectors are
/// large, and what didn't go goes at the next pass.
extension TeamKnowledge {
    /// An item this Mac publishes: where its index is here, where it goes, and how it reads to the team.
    struct Candidate {
        var document: String
        var binder: UUID
        var kind: String
        var source: UUID
        /// The item as a teammate's Mac indexes it: its title and chunks.
        var view: () -> (title: String, chunks: [KnowledgeChunk])?
        /// A note's correction, as its note keeps it; nil for a meeting or capture.
        var corrections: [String]?
    }

    func indexed() async {
        guard !publishing else {
            publishAgain = true
            return
        }
        publishing = true
        defer { publishing = false }
        repeat {
            publishAgain = false
            await publishAll()
        } while publishAgain
    }

    /// The outbox has an answer: once it's empty, the items whose rows just went can be published.
    func outboxSettled() {
        guard waitingForOutbox, content.database?.waiting == 0 else { return }
        waitingForOutbox = false
        Task { await indexed() }
    }

    private func publishAll() async {
        guard let database = content.database, content.team.isConnected, let knowledge, let cache, let pin,
              let myName = content.directory.myName else { return }
        // An item's row has to be in the database before its index: while the outbox still sends, later.
        guard database.waiting == 0 else {
            waitingForOutbox = true
            return
        }
        let model = knowledge.passageModel
        let vectorsGo = model.map { TeamEmbedding.isPin($0, pin: pin.model) } ?? false
        let states = await knowledge.store.documentStates()
        var seen = Set<String>()
        var unsent = 0
        for candidate in candidates(maker: myName) {
            seen.insert(candidate.document)
            guard let state = states[candidate.document] else { continue }
            let last = await cache.published(candidate.document)
            let marker = [state.hash, String(state.extracted), String(pin.epoch), candidate.binder.uuidString, String(vectorsGo), model ?? "", myName]
                .joined(separator: "|")
            if last?.marker == marker { continue }
            guard let view = candidate.view() else { continue }
            var chunks: [TeamKnowledgeItem.Chunk] = view.chunks.map { TeamKnowledgeItem.Chunk(text: $0.text, startTime: $0.startTime, speaker: $0.speaker) }
            if vectorsGo {
                // The vectors this Mac's index has for the same passages; the rest (the maker's own lines, as the team reads
                // them) made now, once.
                let local = await knowledge.store.passages(of: candidate.document)
                let byText = Dictionary(local.compactMap { passage in passage.vector.map { (passage.text, $0) } }, uniquingKeysWith: { first, _ in first })
                for index in chunks.indices { chunks[index].vector = byText[chunks[index].text] }
                let missing = chunks.indices.filter { chunks[$0].vector == nil }
                if !missing.isEmpty, let made = try? await knowledge.embedPassages(missing.map { TeamEmbedding.input(title: view.title, text: chunks[$0].text) }),
                   made.count == missing.count {
                    for (index, vector) in zip(missing, made) { chunks[index].vector = VectorMath.normalized(vector) }
                    embeddedForTeam += missing.count
                }
                // A vector of another length isn't the team's: none of this item's go, and teammates make their own.
                if chunks.contains(where: { ($0.vector?.count ?? pin.dimension) != pin.dimension }) {
                    for index in chunks.indices { chunks[index].vector = nil }
                }
            }
            let extraction = state.extracted ? await knowledge.store.extraction(of: candidate.document) : nil
            let item = TeamKnowledgeItem(binder: candidate.binder, kind: candidate.kind, source: candidate.source, title: view.title, chunks: chunks,
                                         model: vectorsGo ? pin.model : nil, entities: extraction?.entities ?? [],
                                         relations: extraction?.relations ?? [], corrections: candidate.corrections)
            let print = KnowledgeContentHash.of([item.fingerprint])
            // Vectors this Mac couldn't make now (its model didn't answer): looked at again at the next pass.
            let made = !vectorsGo || chunks.allSatisfy({ $0.vector != nil }) ? marker : ""
            // A note moved to another shared binder leaves the old one's index (a meeting's moves with it).
            if let last, last.binder != candidate.binder, candidate.kind == KnowledgeKind.note.rawValue {
                _ = try? await database.call(.replaceKnowledge(TeamKnowledgeItem(binder: last.binder, kind: candidate.kind, source: candidate.source,
                                                                                 title: view.title, chunks: [], corrections: [])))
            }
            if last?.print == print {
                await cache.setPublished(candidate.document, .init(binder: candidate.binder, print: print, marker: made))
                continue
            }
            do {
                let result = try await database.call(.replaceKnowledge(item))
                if result.ok {
                    await cache.setPublished(candidate.document, .init(binder: candidate.binder, print: print, marker: made))
                    publishedItems += 1
                    publishedVectors += chunks.filter { $0.vector != nil }.count
                } else {
                    unsent += 1
                    Log.app.notice("Team knowledge: \(candidate.document, privacy: .public) not published: \(result.refusal?.message ?? "", privacy: .public)")
                }
            } catch {
                unsent += 1
                Log.app.error("Team knowledge: \(candidate.document, privacy: .public) not published: \(error.localizedDescription, privacy: .public)")
                if !content.team.isConnected { return }
            }
        }
        // Notes published before that aren't any more (moved out, deleted, said to yourself): their index leaves the team.
        // A meeting's or capture's left with it (withdraw_item).
        for (document, last) in await cache.allPublished() where !seen.contains(document) {
            if document.hasPrefix(KnowledgeKind.note.rawValue + ":"), let id = UUID(uuidString: String(document.dropFirst(5))) {
                _ = try? await database.call(.replaceKnowledge(TeamKnowledgeItem(binder: last.binder, kind: KnowledgeKind.note.rawValue, source: id,
                                                                                 title: "", chunks: [], corrections: [])))
            }
            await cache.forgetPublished(document)
        }
        if unsent == 0 { resending = false }
    }

    /// What this Mac publishes: this member's meetings and captures the team has (sent, not taken off it, written up),
    /// and its notes in the shared binders (not a teammate's, not one made from what you said to yourself).
    private func candidates(maker: String) -> [Candidate] {
        let shared = content.team.sharedBinders
        guard !shared.isEmpty else { return [] }
        var found: [Candidate] = []
        let sent = content.state.meetings.merging(content.state.captures) { first, _ in first }
        for (id, item) in sent.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where !item.withdrawn && shared.contains(item.binder) {
            guard let record = content.meeting(id), !record.isTeamCopy, record.binderID == item.binder,
                  record.status == "ready" || record.status == "failed" else { continue }
            let kind = record.isConversation ? KnowledgeKind.conversation : KnowledgeKind.meeting
            found.append(Candidate(document: "\(kind.rawValue):\(id.uuidString)", binder: item.binder, kind: kind.rawValue, source: id,
                                   view: { Self.teamView(of: record, maker: maker) }, corrections: nil))
        }
        // This member's own: not a teammate's copy. A note that came back from the team folder carries this member's own
        // name there (teamAuthorName), and is theirs as much as one made here (lane DB6).
        let notes = (try? content.store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate {
            $0.binderID != nil && !$0.isTeamCopy && !$0.staysUnshared
        }))) ?? []
        for note in notes {
            guard let binder = note.binderID, shared.contains(binder) else { continue }
            // A correction steers teammates' answers only when it's yours: no agent's words in its note.
            let correction = note.agentMark.isEmpty ? KnowledgeCorrection.parse(note.text).map { [$0.markdown] } ?? [] : []
            found.append(Candidate(document: "note:\(note.id.uuidString)", binder: binder, kind: KnowledgeKind.note.rawValue, source: note.id,
                                   view: { KnowledgeService.document(for: note).map { ($0.0.title, $0.1) } }, corrections: correction))
        }
        return found
    }

    /// A meeting or capture as a teammate's Mac indexes its copy: its maker's "You" is the maker, by name. A copy that's
    /// never kept anywhere, for its document only.
    static func teamView(of record: MeetingRecord, maker: String) -> (title: String, chunks: [KnowledgeChunk])? {
        let view = MeetingRecord(title: record.title, appName: record.appName, templateID: record.templateID)
        view.id = record.id
        view.kind = record.kind
        view.createdAt = record.createdAt
        view.status = record.status
        view.summary = record.summary
        view.userNotes = record.userNotes
        view.speakerNames = TeamSpeakers.shown(record.speakerNames, maker: maker)
        view.binderID = record.binderID
        view.isTeamCopy = true
        view.teamAuthorName = maker
        return KnowledgeService.document(for: view, segments: Store.shared.segments(for: record.id)).map { ($0.0.title, $0.1) }
    }
}
