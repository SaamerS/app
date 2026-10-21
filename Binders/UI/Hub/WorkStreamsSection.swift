import SwiftData
import SwiftUI
import BindersKit

extension View {
    /// Keeps the work-streams digest up to date while this page shows (Home, Today, Work).
    func followingWorkStreams() -> some View {
        onAppear { WorkStreamsFeed.shared.show() }
            .onDisappear { WorkStreamsFeed.shared.hide() }
            // What runs say they're doing comes in between board changes: the digest is built again when it does.
            .followingAgentDoing()
    }
}

/// What's happening on the boards, first on Today: what waits on you, who is working on what, and each binder's count,
/// from the boards alone. Nothing when the boards are quiet. The digest comes from `WorkStreamsFeed`, built off the main
/// thread once per board change, so drawing this reads no cards. The page it's on follows the feed.
struct WorkStreamsSection: View {
    @Environment(HubNavigation.self) private var navigation
    private var feed: WorkStreamsFeed { .shared }

    var body: some View {
        let digest = feed.digest.flatMap { $0.isQuiet ? nil : $0 }
        // Someone starting on something files in, and the counts roll.
        Group {
            if let digest {
                card(digest)
                    .transition(.filed)
            }
        }
        .filing((digest?.streams.prefix(5).map(\.who) ?? []) + (digest?.byBinder.prefix(6).map(\.binder) ?? []))
    }

    private func card(_ digest: WorkStreams.Digest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's happening").font(BindersTheme.columnTitle)
            Text(digest.headline).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !digest.streams.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(digest.streams.prefix(5), id: \.who) { stream in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // An agent at work wears its sparkle, in lavender.
                            Image(systemName: stream.isAgent ? BindersTheme.agentSymbol : "person")
                                .foregroundStyle(stream.isAgent ? AnyShapeStyle(BindersTheme.agent) : AnyShapeStyle(.secondary))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(stream.who).font(.callout.weight(.medium)).lineLimit(1)
                                Text(stream.working.prefix(2).map { "“\($0)”" }.joined(separator: ", ")
                                     + (stream.working.count > 2 ? " and \(stream.working.count - 2) more" : ""))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                // What its run says it's doing, in its words, under whose they are.
                                if let doing = stream.doing.first {
                                    DoingLine(agent: stream.who, line: stream.working.count > 1 ? "“\(doing.card)”: \(doing.line)" : doing.line, named: false)
                                }
                            }
                        }
                        .transition(.filed)
                    }
                }
            }
            if digest.byBinder.count > 1 || !digest.streams.isEmpty {
                Divider()
                ForEach(digest.byBinder.prefix(6), id: \.binder) { counts in
                    Button { open(binder: counts.binder) } label: {
                        HStack {
                            Text(counts.binder).lineLimit(1)
                            Spacer()
                            Text(line(counts)).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                                .rollingCount(line(counts))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .transition(.filed)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(padding: 16)
    }

    /// "2 working · 1 to check".
    private func line(_ counts: WorkStreams.BinderCounts) -> String {
        var parts: [String] = []
        if counts.questions > 0 { parts.append(counts.questions == 1 ? "1 question" : "\(counts.questions) questions") }
        if counts.reviews > 0 { parts.append("\(counts.reviews) to check") }
        if counts.working > 0 { parts.append("\(counts.working) working") }
        if counts.waitingToStart > 0 { parts.append("\(counts.waitingToStart) up next") }
        if counts.doneToday > 0 { parts.append("\(counts.doneToday) done") }
        return parts.joined(separator: " · ")
    }

    private func open(binder name: String) {
        guard let binder = Store.shared.binders().first(where: { $0.name == name }) else { return }
        navigation.binderID = binder.id
        navigation.pendingBinderTab = .board
        navigation.selection = .binder
    }
}
