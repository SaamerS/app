import SwiftData
import SwiftUI
import BindersKit

/// Work: every board at once, as the work-streams digest reads it. What waits on you, who is working on what, what's
/// up next, and each binder's count, from the boards alone. A card opens on its board.
struct WorkView: View {
    @Environment(HubNavigation.self) private var navigation
    /// The open cards: the page lists no finished ones.
    @Query(filter: #Predicate<TaskCard> { $0.columnRaw != "done" }, sort: \TaskCard.updatedAt, order: .reverse) private var cards: [TaskCard]
    /// The digest, built off the main thread once per board change.
    private var feed: WorkStreamsFeed { .shared }

    var body: some View {
        let digest = feed.digest
        let open = cards.filter { $0.column != .done }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Work").font(BindersTheme.title(32))
                    Text(digest?.headline ?? " ").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                NeedsYouStrip()
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        column("Working", open.filter { $0.column == .inProgress && BoardRules.isClaimed($0.state, at: .now) })
                        column("Up next", open.filter { $0.column == .ready })
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        column("Waiting for your answer", open.filter { $0.column == .blocked })
                        column("Ready for you to check", open.filter { $0.column == .review })
                        if let counts = digest?.byBinder, !counts.isEmpty { byBinder(counts) }
                    }
                    .frame(width: 360)
                }
            }
            .padding(28)
        }
        .followingWorkStreams()
        // Counts roll once the page has drawn what it first read.
        .settlesAfterAppearing()
    }

    @ViewBuilder
    private func column(_ title: String, _ cards: [TaskCard]) -> some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(BindersTheme.columnTitle)
                    Text("\(cards.count)").font(BindersTheme.count(17)).foregroundStyle(.secondary).rollingCount(cards.count)
                }
                ForEach(cards.prefix(30)) { card in
                    Button { navigation.open(card: card) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.title).font(.callout.weight(.medium)).lineLimit(2)
                                Text([Store.shared.binder(card.binderID)?.name, card.assignee ?? card.meantFor.map { "for \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                if card.column == .inProgress, let line = AgentDoingFeed.shared.lines[card.id] {
                                    DoingLine(agent: card.assignee ?? "The agent", line: line, named: false)
                                }
                            }
                            Spacer(minLength: 0)
                            if card.assigneeIsAgent { Image(systemName: BindersTheme.agentSymbol).foregroundStyle(BindersTheme.agent) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperCard(padding: 16)
        }
    }

    private func byBinder(_ counts: [WorkStreams.BinderCounts]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By binder").font(BindersTheme.columnTitle)
            ForEach(counts, id: \.binder) { binder in
                Button { open(binder: binder.binder) } label: {
                    HStack {
                        Text(binder.binder)
                        Spacer()
                        Text(Self.openCount(binder)).monospacedDigit().foregroundStyle(.secondary).rollingCount(Self.openCount(binder))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(padding: 16)
    }

    private static func openCount(_ counts: WorkStreams.BinderCounts) -> String {
        let open: Int = counts.working + counts.questions + counts.reviews + counts.waitingToStart
        return "\(open) open"
    }

    private func open(binder name: String) {
        guard let binder = Store.shared.binders().first(where: { $0.name == name }) else { return }
        navigation.binderID = binder.id
        navigation.pendingBinderTab = .board
        navigation.selection = .binder
    }
}

/// Agents: the ones you set up, what each holds and what's meant for it, what it's doing now and how its last wake went,
/// with the switch that pauses them all. Agents working on your boards from their own sessions show too.
struct AgentsView: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(DictationController.self) private var controller
    @State private var registry = AgentRegistry.shared
    @Query(sort: \TaskCard.updatedAt, order: .reverse) private var cards: [TaskCard]

    var body: some View {
        let open = cards.filter { $0.column != .done }
        let registered = registry.agents.map(\.name)
        let others = Array(Set(open.filter { $0.assigneeIsAgent }.compactMap(\.assignee)
            .filter { name in !registered.contains { BoardRules.isNamed(name, as: $0) || BoardRules.isNamed($0, as: name) } })).sorted()
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Agents").font(BindersTheme.title(32))
                        // Paused is waiting, not something that needs you: muted, with its glyph.
                        if registry.paused {
                            StatusLabel("Paused: Binders wakes no agent, and agents can't take cards.", .waiting)
                        } else {
                            Text("Binders wakes an agent when you give it a card, answer its question, comment on a card it's working on or send its work back.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("Pause All Agents", isOn: Binding(get: { registry.paused }, set: { registry.setPaused($0) }))
                        .toggleStyle(.switch)
                    Button("Settings…") {
                        navigation.pendingSettingsPage = .agents
                        navigation.selection = .settings
                    }
                }
                if registry.agents.isEmpty && others.isEmpty {
                    Text("No agents yet. Set one up in Settings → Agents: Claude Code in a repository, a script, a web hook, or one that checks the board itself.")
                        .foregroundStyle(.secondary)
                        .paperCard(padding: 16)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(registry.agents) { agent in
                        card(name: agent.name, kind: AgentsSections.describe(agent.wake), open: open, agent: agent)
                    }
                    ForEach(others, id: \.self) { name in
                        card(name: name, kind: "Works on your boards from its own session", open: open, agent: nil)
                    }
                }
            }
            .padding(28)
        }
    }

    private func card(name: String, kind: String, open: [TaskCard], agent: AgentProfile?) -> some View {
        let holding = open.filter { $0.assigneeIsAgent && $0.assignee.map { BoardRules.isNamed($0, as: name) } == true }
        let meant = open.filter { card in
            card.assignee == nil && !card.meantForByAgent && card.meantFor.map { BoardRules.isNamed($0, as: name) || BoardRules.isNamed(name, as: $0) } == true
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: BindersTheme.agentSymbol).foregroundStyle(BindersTheme.agent)
                Text(name).font(BindersTheme.cardTitle)
                Spacer()
                if let agent, registry.changedOutside.contains(agent.id) {
                    StatusLabel("Changed outside Binders", .needsYou, symbol: "exclamationmark.shield").font(.caption)
                } else if agent?.isEnabled == false {
                    StatusLabel("Off", .waiting).font(.caption)
                }
            }
            Text(kind).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if holding.isEmpty && meant.isEmpty {
                Text("Nothing for it right now.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(holding.prefix(6)) { card in row(card, note: controller.agents.isWorking(on: card.id) ? "Working on it" : card.column.title) }
            ForEach(meant.prefix(6)) { card in row(card, note: "Meant for it, \(card.column.title)") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(padding: 16)
    }

    private func row(_ card: TaskCard, note: String) -> some View {
        Button { navigation.open(card: card) } label: {
            HStack {
                Text(card.title).lineLimit(1)
                Spacer()
                // How its last wake went; one that failed in the problem style.
                if let outcome = controller.agents.outcomes[card.id], !outcome.ok {
                    StatusLabel(outcome.message, .problem).font(.caption).lineLimit(1)
                } else {
                    Text(controller.agents.outcomes[card.id]?.message ?? note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What was heard today: captures from the iPhone and this Mac, and things said to yourself, with what became of each.
struct HeardTodaySection: View {
    @Environment(HubNavigation.self) private var navigation
    @Query private var captures: [MeetingRecord]
    @Query private var moments: [TranscriptRecord]

    init() {
        let kind = MeetingRecord.conversationKind
        let today = Calendar.current.startOfDay(for: Date())
        _captures = Query(filter: #Predicate<MeetingRecord> { $0.kind == kind && $0.createdAt >= today }, sort: [SortDescriptor(\.createdAt, order: .reverse)])
        _moments = Query(filter: #Predicate<TranscriptRecord> { $0.mode == "moment" && $0.createdAt >= today }, sort: [SortDescriptor(\.createdAt, order: .reverse)])
    }

    var body: some View {
        let shownMoments = Array(moments.prefix(5)), shownCaptures = Array(captures.prefix(5))
        // What's heard files in, a capture's binder chip sliding in beside it.
        Group {
            if !shownCaptures.isEmpty || !shownMoments.isEmpty {
                card(moments: shownMoments, captures: shownCaptures)
                    .transition(.filed)
            }
        }
        .filing(shownMoments.map(\.id) + shownCaptures.map(\.id))
    }

    private func card(moments: [TranscriptRecord], captures: [MeetingRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Heard today").font(BindersTheme.columnTitle)
            ForEach(moments) { moment in
                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(moment.rawText)”").font(BindersTheme.quote(.callout)).lineLimit(2)
                    Text("\(moment.createdAt.formatted(date: .omitted, time: .shortened)) · \(moment.finalText)").font(BindersTheme.time()).foregroundStyle(.secondary).lineLimit(2)
                }
                .transition(.filed)
            }
            ForEach(captures) { capture in
                Button { navigation.open(meeting: capture) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capture.title).font(.callout.weight(.medium)).lineLimit(1)
                            Text([capture.createdAt.formatted(date: .omitted, time: .shortened), capture.status == "trivial" ? "not kept" : nil]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(BindersTheme.time()).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let binder = Store.shared.binder(capture.binderID)?.name { Badge(text: binder).filingChip() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.filed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(padding: 16)
    }
}
