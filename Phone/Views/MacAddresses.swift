import BindersKit
import SwiftUI
import UIKit

/// Your Mac's addresses: every one this iPhone knows, in the order they're tried, with the one in use and what became of
/// each at the last try. Tap one to test it; add the name or address your VPN gives the Mac; remove one you added.
struct MacAddressesSection: View {
    @Environment(MacConnection.self) private var connection
    /// Each address tested here, by id: nil while its test runs.
    @State private var tests: [String: LinkDial.Outcome?] = [:]
    @State private var adding = false
    /// What's typed in Add an Address, and why it was refused: both kept for the next try, so it can be put right.
    @State private var typed = ""
    @State private var addProblem: String?

    var body: some View {
        let rows = connection.addressRows
        let name = connection.mac?.name ?? "your Mac"
        Section {
            if rows.isEmpty {
                Text("This iPhone has no address for \(name) yet. Add one, or pair again.")
                    .foregroundStyle(Palette.muted)
            }
            ForEach(rows) { row in
                Button { test(row) } label: { AddressRow(row: row, detail: detail(row), status: status(of: row)) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Tests this address.")
                    .swipeActions {
                        if row.addedHere || row.workedOnly {
                            Button("Remove", role: .destructive) { remove(row) }
                        }
                    }
                    .contextMenu {
                        Button { test(row) } label: { Label("Test", systemImage: "antenna.radiowaves.left.and.right") }
                        if row.host != nil {
                            Button { UIPasteboard.general.string = row.text } label: { Label("Copy Address", systemImage: "doc.on.doc") }
                        }
                        if row.host != nil, !row.addedHere {
                            Button { keep(row) } label: { Label("Keep on This iPhone", systemImage: "pin") }
                        }
                        if row.addedHere || row.workedOnly {
                            Button(role: .destructive) { remove(row) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
            }
            Button("Add an Address…") { adding = true }
            if let addProblem {
                ProblemLabel(addProblem).font(.footnote)
            }
        } header: {
            Text("Addresses")
        } footer: {
            Text("Your iPhone tries these at once and uses the first that answers. Your Mac tells it its addresses each time it connects, and an address that worked is kept for a month. Tap one to test it. Away from home, use your VPN (Covee, Tailscale or another) on both, or add the name your VPN gives your Mac.")
        }
        .surfaceRows()
        .onChange(of: connection.inUse) { _, now in
            // A test from before doesn't hide that this address is the one in use now.
            if let now, let finished = tests[now], finished != nil { tests[now] = nil }
        }
        .alert("Add an Address", isPresented: $adding) {
            TextField("Name or IP address", text: $typed)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { add() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // After a refusal, why, with what was typed still in the field.
            if let addProblem {
                Text(addProblem)
            } else {
                Text("A name or IP address your Mac can be reached at, such as one your VPN (Covee, Tailscale or another) gives it. Add :port at the end only if it isn't \(String(connection.mac?.port ?? Link.port)). An IPv6 address with a port goes in brackets: [fd7a::2]:7450.")
            }
        }
    }

    private func add() {
        switch connection.addAddress(typed) {
        case .added(let id):
            typed = ""
            addProblem = nil
            // Tested at once, so you know straight away whether it answers.
            if let row = connection.addressRows.first(where: { $0.id == id }) { test(row) }
        case .refused(let words):
            addProblem = words
            announce(words, later: true)
        }
    }

    /// Keep on This iPhone: refused like Add once eight are added, and said the same way.
    private func keep(_ row: LinkCandidate) {
        switch connection.keep(row.id) {
        case .added?:
            addProblem = nil
        case .refused(let words)?:
            addProblem = words
            announce(words, later: true)
        case nil:
            break
        }
    }

    /// Remove: an old refusal goes with it, so the alert is back to its guidance.
    private func remove(_ row: LinkCandidate) {
        connection.removeAddress(row.id)
        addProblem = nil
    }

    private func test(_ row: LinkCandidate) {
        let id = row.id, name = row.name
        // Already being tested.
        if let running = tests[id], running == nil { return }
        tests[id] = .some(nil)
        Task {
            let outcome = await connection.test(id)
            tests[id] = .some(outcome)
            // Said, as the row's new status isn't heard until it's next reached.
            announce("\(name) \(outcome.words)")
        }
    }

    /// For VoiceOver: what just happened. A refusal comes as the alert or menu closes, and VoiceOver often drops what's
    /// said during that change, so it's said half a second later.
    private func announce(_ words: String, later: Bool = false) {
        guard later else {
            UIAccessibility.post(notification: .announcement, argument: words)
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            UIAccessibility.post(notification: .announcement, argument: words)
        }
    }

    /// What it is, and for Bonjour in use, what it reached.
    private func detail(_ row: LinkCandidate) -> String {
        if row.id == LinkCandidate.bonjourID, connection.inUse == row.id, let reached = connection.reachedHost {
            return "\(row.label) · \(reached)"
        }
        return row.label
    }

    private func status(of row: LinkCandidate) -> AddressRow.Status {
        let inUse = connection.isConnected && connection.inUse == row.id
        // A test shows while it runs and what it found after, on the address in use too, where answering is In use.
        if let test = tests[row.id] {
            guard let outcome = test else { return .testing }
            if outcome != .answered { return .problem(outcome.words) }
            return inUse ? .inUse : .answered
        }
        if inUse { return .inUse }
        guard !connection.isConnected else { return .none }
        if let attempt = connection.lastAttempts.first(where: { $0.id == row.id }), attempt.outcome.isFailure {
            return .problem(attempt.outcome.words)
        }
        return row.id == connection.mac?.lastID ? .lastUsed : .none
    }
}

/// One address: its name, what it is, and how it's doing.
private struct AddressRow: View {
    enum Status: Equatable {
        case inUse, testing, answered, problem(String), lastUsed, none
    }

    let row: LinkCandidate
    let detail: String
    let status: Status

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).monospacedDigit().foregroundStyle(Palette.ink)
                Text(detail).font(.footnote).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            statusView.font(.caption)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.name, detail, spoken].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .inUse:
            // Connected is a checkmark, never green: green is only for done.
            Label("In use", systemImage: "checkmark").foregroundStyle(Palette.accentText)
        case .testing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini).tint(Palette.muted)
                Text("Testing…").foregroundStyle(Palette.muted)
            }
        case .answered:
            Label("Answered", systemImage: "checkmark").foregroundStyle(Palette.ink)
        case .problem(let words):
            ProblemLabel(words.prefix(1).uppercased() + words.dropFirst())
        case .lastUsed:
            Text("last used").foregroundStyle(Palette.muted)
        case .none:
            EmptyView()
        }
    }

    private var spoken: String {
        switch status {
        case .inUse: "in use"
        case .testing: "testing"
        case .answered: "answered"
        case .problem(let words): words
        case .lastUsed: "last used"
        case .none: ""
        }
    }
}
