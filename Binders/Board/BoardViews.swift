import SwiftData
import SwiftUI
import BindersKit

/// A binder's board: its cards in six columns, dragged between them by you, picked up by agents over MCP.
struct BoardView: View {
    @Environment(DictationController.self) private var controller
    @Environment(HubNavigation.self) private var navigation
    @Bindable var binder: BinderRecord
    @Query private var cards: [TaskCard]
    @State private var drafting: BoardColumn?
    @State private var draft = ""
    @State private var target: BoardColumn?
    @State private var problem: String?
    /// Folded columns you opened: they stay open until you fold them again.
    @State private var opened: Set<BoardColumn> = []
    /// For self-tests: the layout the board last drew, and the width it had for it.
    nonisolated(unsafe) static var lastLayout: (layout: BoardLayout, width: Double)?

    init(binder: BinderRecord) {
        self.binder = binder
        let id = binder.id
        _cards = Query(filter: #Predicate<TaskCard> { $0.binderID == id }, sort: [SortDescriptor(\TaskCard.position, order: .reverse)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // On one row while it fits; short of room, the switches go under the words, then under each other.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    hint
                    Spacer()
                    AddTodosButton(binder: binder)
                    switches
                }
                VStack(alignment: .leading, spacing: 8) {
                    hint
                    HStack(spacing: 12) {
                        AddTodosButton(binder: binder)
                        Spacer(minLength: 0)
                        switches
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    hint
                    AddTodosButton(binder: binder)
                    switches
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            if binder.agentsMayPlace {
                // What the switch gives up, said where it's on (lane DS1).
                Label("Agents place their work items from Distill straight onto this board, in Ready, without your review: their words are the briefs, and the agents they pick start on them as those agents' switches allow.",
                      systemImage: BindersTheme.agentSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
            // Shared through a team database that's off or out of reach: what waits, what's kept, and what to do (lane DB8).
            TeamReachLine(binderID: binder.id)
            // Columns narrow to fit the window, down to a width a card still reads at. Short of that, Done and then Backlog
            // fold to strips with their counts, so Ready, In progress, and Blocked and Review, the ones waiting on you,
            // show without scrolling sideways.
            GeometryReader { geometry in
                let width = geometry.size.width
                let layout = BoardLayout.fit(width: width, opened: opened)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: layout.spacing) {
                        ForEach(BoardColumn.allCases, id: \.self) { column in
                            if layout.folded.contains(column) {
                                strip(column)
                            } else {
                                // One you opened shows how to fold it again while there's no room for it.
                                let foldable = opened.contains(column)
                                    && BoardLayout.fit(width: width, opened: opened.subtracting([column])).folded.contains(column)
                                self.column(column, width: layout.columnWidth, foldable: foldable)
                            }
                        }
                    }
                    .padding(.horizontal, layout.margin)
                    .padding(.bottom, 20)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .onAppear { Self.lastLayout = (layout, width) }
                .onChange(of: layout) { Self.lastLayout = (layout, width) }
            }
        }
        // Fill the space the binder gives the board, and no more, so the header above stays put.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Couldn't do that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
        // Column counts roll once the board has drawn what it first read.
        .settlesAfterAppearing()
        // What the runs Binders started say they're doing, on their cards.
        .followingAgentDoing()
    }

    private var hint: some View {
        Text("Drag cards between columns. Agents such as Claude pick up Ready cards through Binders' MCP server.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var switches: some View {
        Toggle("Agents can finish cards", isOn: $binder.agentsMayFinish)
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("When this is off, an agent's finished card goes to Review for you to check.")
        Toggle("Agents may place work items", isOn: $binder.agentsMayPlace)
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Off: an agent's work items from Distill wait for you to review and place them. On: it places them itself, in Ready, meant for the agents it picked, which start on them as their own switches allow, without you reading them first.")
            .fitProbe("board.header.last")
    }

    private func column(_ column: BoardColumn, width: CGFloat, foldable: Bool) -> some View {
        var items = cards.filter { $0.column == column }
        let count = items.count
        if column == .done { items = Array(items.prefix(30)) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(column.title).font(BindersTheme.cardTitle)
                Text("\(count)").font(BindersTheme.count(13)).foregroundStyle(.secondary).rollingCount(count)
                Spacer()
                if foldable {
                    Button { opened.remove(column) } label: { Image(systemName: "arrow.right.and.line.vertical.and.arrow.left") }
                        .buttonStyle(.borderless)
                        .quietControl()
                        .help("Fold \(column.title)")
                }
                if column != .done {
                    Button {
                        drafting = column
                        draft = ""
                    } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .quietControl()
                        .help("Add a card to \(column.title)")
                }
            }
            if drafting == column {
                TextField("What needs doing?", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { create(in: column) }
                    .onExitCommand { drafting = nil }
            }
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    ForEach(items) { card in
                        CardTile(card: card)
                            // Its own window, over the board, which stays as it is.
                            .onTapGesture { navigation.open(card: card) }
                            .draggable(card.id.uuidString)
                            .contextMenu {
                                Menu("Move to") {
                                    MoveToBinderItems(current: card.binderID) { target in
                                        do { try controller.router.move(card, to: target) } catch { problem = error.localizedDescription }
                                    }
                                }
                            }
                    }
                    if items.isEmpty && drafting != column {
                        Text(Self.hint(column))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(columnFill(column)))
        .dropDestination(for: String.self) { ids, _ in
            move(ids, to: column)
            return true
        } isTargeted: { hovering in
            target = hovering ? column : (target == column ? nil : target)
        }
    }

    /// A folded column: its count and its name on its side. A click opens it, and a card dropped on it moves there.
    private func strip(_ column: BoardColumn) -> some View {
        let count = cards.filter { $0.column == column }.count
        return Button { opened.insert(column) } label: {
            VStack(spacing: 10) {
                Image(systemName: "arrow.left.and.line.vertical.and.arrow.right").font(.caption).foregroundStyle(.secondary)
                Text("\(count)").font(BindersTheme.count(14)).foregroundStyle(.secondary).rollingCount(count)
                Sideways { Text(column.title).font(BindersTheme.cardTitle).lineLimit(1).fixedSize().rotationEffect(.degrees(90)) }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .frame(width: BoardLayout.stripWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(columnFill(column)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(column.title)")
        .accessibilityLabel("\(column.title), \(count) \(count == 1 ? "card" : "cards")")
        .accessibilityHint("Opens the column")
        .dropDestination(for: String.self) { ids, _ in
            move(ids, to: column)
            return true
        } isTargeted: { hovering in
            target = hovering ? column : (target == column ? nil : target)
        }
    }

    /// A column's well: a faint shade of ink over the binder's ground, and its colour while a card is dragged over it.
    private func columnFill(_ column: BoardColumn) -> AnyShapeStyle {
        target == column ? AnyShapeStyle(TintFill().opacity(0.16)) : AnyShapeStyle(BindersTheme.ink.opacity(0.04))
    }

    private static func hint(_ column: BoardColumn) -> String {
        switch column {
        case .backlog: "Ideas and work for later"
        case .ready: "Ready for someone, or some agent, to pick up"
        case .inProgress: "Being worked on"
        case .blocked: "Waiting for an answer"
        case .review: "Finished, waiting for you to check"
        case .done: "Nothing finished yet"
        }
    }

    private func create(in column: BoardColumn) {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        drafting = nil
        guard !title.isEmpty, Store.shared.allowsSave() else { return }
        // Made at once; the agent whose work it is follows a moment later (CardRouter).
        controller.router.typedCard(title: title, binder: binder, column: column)
        draft = ""
    }

    private func move(_ ids: [String], to column: BoardColumn) {
        for id in ids.compactMap(UUID.init(uuidString:)) {
            guard let card = controller.board.card(id) else { continue }
            do { try controller.board.move(card, to: column, by: .you) } catch { problem = error.localizedDescription }
        }
    }
}

/// Its content turned on its side, in the space it takes that way: a folded column's name.
private struct Sideways: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: size.height, height: size.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(subview.sizeThatFits(.unspecified)))
    }
}

/// A card on the board: its title, who has it, when it's due, and anything that needs you.
struct CardTile: View {
    let card: TaskCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            // What a run Binders started says it's doing between its reports, in its words.
            if card.column == .inProgress, let line = AgentDoingFeed.shared.lines[card.id] {
                DoingLine(agent: card.assignee ?? "The agent", line: line)
            }
            if card.column == .blocked {
                // A question or a request for your approval waits on you: amber. Blocked with a reason, such as a run that
                // stopped before it finished, is a problem: the problem style.
                let approving = card.waitingApproval() != nil
                let asking = approving || card.taskState() == .inputRequired
                if asking {
                    StatusLabel(approving ? "Waiting for your approval" : "Waiting for your answer", .needsYou,
                                symbol: approving ? "checkmark.shield" : "questionmark.bubble")
                        .font(.caption.weight(.medium))
                } else {
                    StatusLabel("Blocked: open it to see why", .problem)
                        .font(.caption.weight(.medium))
                }
            } else if card.column == .review {
                // Finished work waits on you to check it: amber, as a question does.
                StatusLabel("Ready for you to check", .needsYou, symbol: "eye")
                    .font(.caption.weight(.medium))
            }
            HStack(spacing: 6) {
                if let assignee = card.assignee, BoardRules.isClaimed(card.state, at: .now) || card.column == .review || card.column == .done {
                    AssigneeChip(name: assignee, isAgent: card.assigneeIsAgent, expires: card.column == .inProgress ? card.claimExpiresAt : nil)
                }
                if let meantFor = card.meantFor, !BoardRules.isClaimed(card.state, at: .now), card.column != .done {
                    // An agent's suggestion asks, and waits on you; your own choice says.
                    if card.meantForByAgent {
                        Badge(text: "Give to \(meantFor)?", symbol: "questionmark.circle", color: BindersTheme.needsYou)
                    } else {
                        Badge(text: "For \(meantFor)")
                    }
                }
                if let due = card.dueAt, card.column != .done {
                    DueBadge(due: due)
                }
                // Lane DS1: it waits for other cards; an agent can't take it until they're done.
                if !card.waitsFor.isEmpty, card.column != .done, let waiting = CardWaitsBadge.count(card), waiting > 0 {
                    Badge(text: "Waits for \(waiting)", symbol: "hourglass")
                        .help(CardWaitsBadge.line(card) ?? "")
                }
                Spacer(minLength: 0)
                if !card.links.isEmpty {
                    Label("\(card.links.count)", systemImage: "link").font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(BindersTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(BindersTheme.line))
        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
        .contentShape(Rectangle())
    }
}

/// Who has a card: a person, or an agent, in lavender with its sparkle, with how long its claim has left.
struct AssigneeChip: View {
    let name: String
    let isAgent: Bool
    var expires: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let minutes = expires.flatMap { $0 > context.date && isAgent ? max(1, Int($0.timeIntervalSince(context.date) / 60)) : nil }
            // In a narrow column: the agent without its repository ("Claude Code · harbor-web"), then without the time
            // left, before its name is cut short.
            let short = name.components(separatedBy: " · ").first ?? name
            ViewThatFits(in: .horizontal) {
                chip(name, minutes: minutes)
                if short != name { chip(short, minutes: minutes) }
                if minutes != nil { chip(short, minutes: nil) }
                chip(name, minutes: nil)
            }
        }
    }

    private func chip(_ shown: String, minutes: Int?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isAgent ? BindersTheme.agentSymbol : "person.fill").imageScale(.small)
            Text(shown).lineLimit(1)
            if let minutes {
                Text("· \(minutes) min").monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(isAgent ? BindersTheme.agent.opacity(0.16) : BindersTheme.ink.opacity(0.07)))
        .foregroundStyle(isAgent ? BindersTheme.agent : BindersTheme.ink)
    }
}

/// What an agent working on a card says it's doing, in its own words (`AgentDoing`): in lavender with its sparkle, and
/// whose words they are. They're shown, never acted on.
struct DoingLine: View {
    let agent: String
    let line: String
    /// Its name before its words, where nothing beside them says whose they are.
    var named = true
    var lines = 2
    /// The words' colour: lavender, as on the board; the card's own page draws them muted beside the lavender sparkle.
    var words: Color = BindersTheme.agent

    var body: some View {
        let short = agent.components(separatedBy: " · ").first ?? agent
        let spoken = "\(short) says: \(line)"
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: BindersTheme.agentSymbol).imageScale(.small).foregroundStyle(BindersTheme.agent)
            (named ? Text(short + ": ").fontWeight(.semibold) + Text(line) : Text(line))
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(words)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("What \(short) says it's doing, in its words, from its own task list. Binders looks every 30 seconds while the card is in progress, and keeps nothing but this line.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }
}

/// One line of a card's timeline.
struct EventRow: View {
    let event: TaskEvent
    /// Where the card is now: finished work is amber only while the card still waits in Review for you to check it.
    var cardColumn: BoardColumn?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.author).font(.caption.weight(.semibold))
                    if event.authorIsAgent { Image(systemName: BindersTheme.agentSymbol).font(.caption2).foregroundStyle(BindersTheme.agent) }
                    Text(headline).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(event.createdAt.formatted(.relative(presentation: .named))).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                }
                if !event.text.isEmpty {
                    Text(event.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(event.kind == .question || event.kind == .approval ? 8 : 0)
                        .background(event.kind == .question || event.kind == .approval ? RoundedRectangle(cornerRadius: 8).fill(BindersTheme.needsYou.opacity(0.1)) : nil)
                }
            }
        }
    }

    private var column: String { event.toColumn.flatMap(BoardColumn.init(rawValue:))?.title ?? "" }

    private var headline: String {
        switch event.kind {
        case .created: "added it\(column.isEmpty ? "" : " to \(column)")"
        case .moved: "moved it to \(column)"
        case .claimed: "picked it up"
        case .released: "let it go"
        case .lapsed: "went quiet"
        case .progress: "reported progress"
        case .question: "asked"
        case .answer: "answered"
        case .comment: "commented"
        case .completed: column == "Done" ? "finished it" : "finished it, for review"
        case .edited: "edited it"
        case .assigned: "said who it's for"
        case .woke: "was woken"
        case .context: "found this in the binder"
        case .approval: "asks your approval"
        case .decision: "kept the receipt"
        }
    }

    private var symbol: String {
        switch event.kind {
        case .created: "plus.circle"
        case .moved: "arrow.right.circle"
        case .claimed: "hand.raised"
        case .released, .lapsed: "arrow.uturn.backward.circle"
        case .progress: "chart.line.uptrend.xyaxis"
        case .question: "questionmark.bubble"
        case .answer: "text.bubble"
        case .comment: "bubble.left"
        case .completed: "checkmark.circle"
        case .edited: "pencil"
        case .assigned: "person.crop.circle.badge.checkmark"
        case .woke: "bell"
        case .context: "books.vertical"
        case .approval: "checkmark.shield"
        case .decision: "signature"
        }
    }

    private var tint: AnyShapeStyle {
        switch event.kind {
        case .question, .approval: AnyShapeStyle(BindersTheme.needsYou)
        // Green only once it's in Done. Finished for review is amber, as a question, while the card still waits in Review
        // for you to check it; once it's checked (or moved on), that event no longer needs you.
        case .completed:
            if column == BoardColumn.done.title {
                AnyShapeStyle(BindersTheme.done)
            } else if cardColumn == .review {
                AnyShapeStyle(BindersTheme.needsYou)
            } else {
                AnyShapeStyle(.infoText)
            }
        case .lapsed: AnyShapeStyle(.secondary)
        // The accent's; neutral in a binder's card, whose colour is for what you act on.
        default: AnyShapeStyle(.infoText)
        }
    }
}

/// What Binders wrote on a card from its binder ("From your binders"), to change before an agent reads it again, or empty
/// to delete it. Agents that read the card later see it as you leave it.
struct ContextEditor: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    let event: TaskEvent
    @State private var text: String

    init(event: TaskEvent) {
        self.event = event
        _text = State(initialValue: event.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("From your binders").font(BindersTheme.cardTitle)
            Text("Binders wrote this when the card first went to an agent: passages from notes and meetings in its binder that match it. Agents that read the card see it as you leave it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(BindersTheme.lineStrong))
            HStack {
                Button("Delete", role: .destructive) {
                    controller.board.editContext(event, text: "")
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    controller.board.editContext(event, text: text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// "Add To-dos": the binder's open to-dos that aren't on its board yet, to pick from and turn into cards.
struct AddTodosButton: View {
    @Environment(DictationController.self) private var controller
    let binder: BinderRecord
    @Query private var meetings: [MeetingRecord]
    @Query private var notes: [NoteItem]
    @Query private var commitments: [CommitmentRecord]
    @Query(filter: #Predicate<TaskCard> { $0.sourceRef != nil }) private var linkedCards: [TaskCard]
    @State private var picking = false

    init(binder: BinderRecord) {
        self.binder = binder
        let id = binder.id
        _meetings = Query(filter: #Predicate<MeetingRecord> { $0.binderID == id }, sort: [SortDescriptor(\MeetingRecord.createdAt, order: .reverse)])
        _notes = Query(filter: #Predicate<NoteItem> { $0.binderID == id }, sort: [SortDescriptor(\NoteItem.updatedAt, order: .reverse)])
        _commitments = Query(filter: #Predicate<CommitmentRecord> { $0.binderID == id }, sort: [SortDescriptor(\CommitmentRecord.createdAt, order: .reverse)])
    }

    /// Open to-dos from the binder's meetings, notes and promises, without the ones that already have a card.
    private var waiting: [TaskEntry] {
        let carded = Set(linkedCards.compactMap(\.sourceRef))
        return TaskCollector.collect(meetings: Array(meetings.prefix(60)), notes: Array(notes.prefix(120)), commitments: Array(commitments.prefix(100)),
                                     openMeeting: { _ in }, openNote: { _ in })
            .filter { !$0.done && !carded.contains($0.ref) }
    }

    var body: some View {
        let waiting = waiting
        Button { picking = true } label: {
            Label(waiting.isEmpty ? "Add To-dos" : "Add To-dos (\(waiting.count))", systemImage: "rectangle.stack.badge.plus")
        }
        .controlSize(.small)
        .disabled(waiting.isEmpty)
        .help(waiting.isEmpty ? "Every open to-do in this binder is on the board." : "Turn to-dos from this binder's meetings, notes and promises into cards")
        .sheet(isPresented: $picking) {
            TodoPickerSheet(binder: binder, todos: waiting).environment(controller)
        }
    }
}

/// Pick to-dos to put on the board. Each card stays linked to its to-do, which is ticked off when the card is done.
struct TodoPickerSheet: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    let binder: BinderRecord
    let todos: [TaskEntry]
    @State private var chosen: Set<String>
    @State private var column: BoardColumn = .ready

    init(binder: BinderRecord, todos: [TaskEntry], chosen: Set<String> = []) {
        self.binder = binder
        self.todos = todos
        _chosen = State(initialValue: chosen)
    }

    private struct Source: Identifiable {
        let id: UUID
        let kind: TaskEntry.Kind
        let title: String
        let date: Date
        var todos: [TaskEntry]
    }

    private var sources: [Source] {
        var ordered: [Source] = []
        var index: [UUID: Int] = [:]
        for todo in todos {
            if let at = index[todo.sourceID] {
                ordered[at].todos.append(todo)
            } else {
                index[todo.sourceID] = ordered.count
                ordered.append(Source(id: todo.sourceID, kind: todo.kind, title: todo.sourceTitle, date: todo.sourceDate, todos: [todo]))
            }
        }
        return ordered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add to-dos to the \(binder.name) board").font(BindersTheme.cardTitle)
                Text("Open to-dos from this binder's meetings, notes and promises. Each stays open where it is, marked as on the board, and is ticked off when its card is done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(chosen.count == todos.count ? "Select None" : "Select All") {
                    chosen = chosen.count == todos.count ? [] : Set(todos.map(\.ref))
                }
                Spacer()
                Picker("Add to", selection: $column) {
                    Text(BoardColumn.backlog.title).tag(BoardColumn.backlog)
                    Text(BoardColumn.ready.title).tag(BoardColumn.ready)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: source.kind == .meeting ? "person.2.wave.2" : (source.kind == .commitment ? "hand.raised" : "note.text"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(source.title).font(.callout.weight(.medium)).lineLimit(1)
                                Text(source.date, format: .relative(presentation: .named)).font(BindersTheme.time()).foregroundStyle(.secondary)
                            }
                            ForEach(source.todos) { todo in
                                Toggle(isOn: Binding(get: { chosen.contains(todo.ref) },
                                                     set: { if $0 { chosen.insert(todo.ref) } else { chosen.remove(todo.ref) } })) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        if let owner = todo.owner { OwnerChip(name: owner) }
                                        Text(todo.text).fixedSize(horizontal: false, vertical: true)
                                        if let due = todo.due {
                                            DueBadge(due: due)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 420)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count == 1 ? "Add 1 Card" : "Add \(chosen.count) Cards", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .pageGround()
        .binderTint(binder.colorIndex)
    }

    /// Newest on top, in the order they're listed.
    private func add() {
        for todo in todos.reversed() where chosen.contains(todo.ref) {
            let made = controller.board.create(from: todo.todo, column: column, binderID: binder.id, by: .you)
            if !made.existed { controller.router.suggestLater(for: made.card, origin: .toBoard) }
        }
        dismiss()
    }
}
