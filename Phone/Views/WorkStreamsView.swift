import BindersKit
import SwiftUI

/// What's happening on the boards: what waits on you, who is working on what, what's up next, and what was finished
/// today. From the Mac's digest; from this iPhone's copy of the boards when the Mac is away or too old to give one.
struct WorkStreamsView: View {
    @Environment(MacConnection.self) private var connection
    @State private var digest: Digest?
    /// Nothing from the Mac yet, and no copy of the boards to make it from.
    @State private var unreached = false
    let openBoard: () -> Void

    /// The Mac's work_streams, as JSON.
    struct Digest: Codable, Equatable {
        /// Who, their cards, and what a run Binders started says it's doing on some (nil from a Mac before 0.8.1).
        typealias Stream = WorkStreams.Working
        struct Question: Codable, Equatable { let card: String; let who: String; let question: String }
        struct Review: Codable, Equatable { let card: String; let who: String }
        struct Waiting: Codable, Equatable { let card: String; let `for`: String }
        let headline: String
        let working: [Stream]
        let questions: [Question]
        let reviews: [Review]
        let waitingToStart: [Waiting]
        let doneToday: [String]
    }

    var body: some View {
        List {
            if let digest {
                Section { Text(digest.headline).foregroundStyle(Palette.ink) }
                    .surfaceRows()
                if !digest.questions.isEmpty || !digest.reviews.isEmpty {
                    Section {
                        ForEach(Array(digest.questions.enumerated()), id: \.offset) { _, question in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(question.card).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                                Label("\(question.who) asks: \(question.question)", systemImage: "questionmark.bubble")
                                    .font(.footnote).foregroundStyle(Palette.needsYou)
                            }
                        }
                        ForEach(Array(digest.reviews.enumerated()), id: \.offset) { _, review in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(review.card).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                                Label("Ready for you to check, from \(review.who)", systemImage: "eye")
                                    .font(.footnote).foregroundStyle(Palette.needsYou)
                            }
                        }
                    } header: {
                        // It all waits on you: amber.
                        NeedsYouTitle("Waiting on you")
                    }
                    .surfaceRows()
                }
                if !digest.working.isEmpty {
                    Section("Working") {
                        ForEach(digest.working, id: \.who) { stream in
                            VStack(alignment: .leading, spacing: 3) {
                                // An agent's stream: lavender, with the sparkle.
                                Label {
                                    Text(stream.who).foregroundStyle(stream.agent ? Palette.agent : Palette.ink)
                                } icon: {
                                    Image(systemName: stream.agent ? "sparkles" : "person").foregroundStyle(stream.agent ? Palette.agent : Palette.muted)
                                }
                                .font(.body.weight(.medium))
                                Text(stream.cards.prefix(3).map { "“\($0)”" }.joined(separator: ", ")).font(.footnote).foregroundStyle(Palette.muted)
                                // What its run says it's doing between its reports: its words, in lavender with the sparkle.
                                ForEach(Array((stream.doing ?? []).prefix(2).enumerated()), id: \.offset) { _, doing in
                                    let spoken = "\(stream.who) says: \(doing.line)"
                                    Label {
                                        Text(stream.cards.count > 1 ? "“\(doing.card)”: \(doing.line)" : doing.line)
                                    } icon: {
                                        Image(systemName: "sparkles")
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(Palette.agent)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel(spoken)
                                }
                            }
                        }
                    }
                    .surfaceRows()
                }
                if !digest.waitingToStart.isEmpty {
                    Section("Up next") {
                        ForEach(Array(digest.waitingToStart.enumerated()), id: \.offset) { _, waiting in
                            LabeledContent(waiting.card, value: "for \(waiting.for)")
                        }
                    }
                    .surfaceRows()
                }
                if !digest.doneToday.isEmpty {
                    Section("Finished today") {
                        // Done: green, with its check.
                        ForEach(Array(digest.doneToday.enumerated()), id: \.offset) { _, title in
                            Label {
                                Text(title).foregroundStyle(Palette.ink)
                            } icon: {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.done)
                            }
                        }
                    }
                    .surfaceRows()
                }
                Section { Button("Open the Board", action: openBoard) }
                    .surfaceRows()
            } else if !unreached {
                ProgressView().surfaceRows()
            }
        }
        .listGround()
        .overlay {
            if digest == nil, unreached { WaitingForMac(what: "What's happening shows here") { await load() } }
        }
        .navigationTitle("What's happening")
        .task(id: connection.revision("tasks")) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        // What runs say they're doing shows only fresh: it isn't kept with the rest, nor read from a copy kept whole.
        if digest == nil { digest = connection.cached("work-streams", as: Digest.self, keeping: WorkStreams.keepable) ?? local() }
        if let fresh = await connection.fetch("work_streams", cache: "work-streams", as: Digest.self, keeping: WorkStreams.keepable).value {
            digest = fresh
            // The Today widget's done today counts the cards finished.
            CaptureActivity.update(finished: fresh.doneToday.count)
        } else if digest == nil {
            digest = local()
        }
        unreached = digest == nil
    }

    /// From this iPhone's copy of the boards (list_tasks leaves Done out, so nothing finished today shows).
    private func local() -> Digest? {
        guard let cards = connection.cached("tasks-all", as: [Card].self) else { return nil }
        let digest = WorkStreams.digest(cards.map { card in
            WorkStreams.Card(title: card.title, binder: card.binder, column: card.board, assignee: card.assignee.isEmpty ? nil : card.assignee,
                             assigneeIsAgent: card.assigneeIsAgent, meantFor: card.meantFor, updated: Date(iso: card.updated) ?? .now)
        })
        return Digest(headline: digest.headline,
                      working: digest.streams.map { .init(who: $0.who, agent: $0.isAgent, cards: $0.working) },
                      questions: digest.questions.map { .init(card: $0.card, who: $0.who, question: $0.question) },
                      reviews: digest.reviews.map { .init(card: $0.card, who: $0.who) },
                      waitingToStart: digest.queued.map { .init(card: $0.card, for: $0.who) },
                      doneToday: digest.doneToday)
    }
}
