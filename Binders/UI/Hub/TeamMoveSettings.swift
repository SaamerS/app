import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BindersKit

/// Settings → Team → Move This Team to a Database… (lane DB3): this Mac joins the team's database (or sets one up), then
/// everything the team folder shares comes in once, and folder sync stops here, leaving the folder as it is.
struct TeamMoveSheet: View {
    @Environment(DictationController.self) private var controller
    @Environment(TeamSyncService.self) private var team
    @Environment(\.dismiss) private var dismiss
    @State private var settingUp = false
    @State private var pastingLink = false
    @State private var working = false
    @State private var said: String?
    @State private var problem: String?

    var body: some View {
        let board = controller.teamBoard
        VStack(alignment: .leading, spacing: 12) {
            Text("Move this team to a database").font(.headline)
            Text("Everything the team folder shares comes into the team database once: its binders, folders, notes (with who wrote them) and meetings (with their transcripts; audio stays on the Mac that recorded it). Binders made on this Mac take their boards with them, as sharing a binder does. Then this Mac stops syncing the folder and leaves it as it is, a Markdown copy that still opens in Obsidian.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Teammates still on the folder keep working there. When they move too, what they changed in the folder since comes in, merged with what changed in the database, and nothing comes in twice.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if board.server == nil {
                Text("First, this Mac joins the team's database.").font(.callout.weight(.semibold))
                if let invite = board.pendingInvite {
                    HStack {
                        Text("Join \(invite.teamName.isEmpty ? "the team" : "“\(invite.teamName)”") as \(invite.server.login)?")
                        Button("Join") { act { try await controller.teamBoard.join(invite) } }.buttonStyle(.borderedProminent)
                    }
                }
                HStack {
                    Button("Set Up a Team Database…") { settingUp = true }
                    Button("Open Invite…") { openInvite() }
                    Button("Paste Invite Link…") { pastingLink = true }
                }
            } else {
                StatusLabel(board.status.summary(now: Date()), board.isConnected ? .ready : .waiting).font(.callout)
                if !board.isConnected {
                    Text("Moving waits until this Mac is connected to the team database.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let said { StatusLabel(said, .done).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if let problem { StatusLabel(problem, .problem).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(said == nil ? "Cancel" : "Done") { dismiss() }
                if said == nil {
                    Button(working ? "Moving…" : "Move") { move() }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || !board.isConnected || !team.isConfigured)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { controller.teamBoard.movingFolderTeam = true }
        .onDisappear { controller.teamBoard.movingFolderTeam = false }
        .sheet(isPresented: $settingUp) { TeamDatabaseSetUpSheet { said = nil; problem = nil; _ = $0 } }
        .sheet(isPresented: $pastingLink) { TeamInviteLinkSheet { controller.teamBoard.pendingInvite = $0 } }
    }

    private func move() {
        working = true
        problem = nil
        Task { @MainActor in
            do {
                let summary = try await controller.teamBoard.notes.moveFolderTeam(from: team)
                said = summary.line + " This Mac no longer syncs the team folder."
            } catch {
                problem = error.localizedDescription
            }
            working = false
        }
    }

    private func openInvite() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: TeamInvite.fileExtension) ?? .json, .json]
        panel.message = "Choose the invite a teammate sent you privately."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let invite = TeamInvite(fileData: data) else {
            problem = "That file isn't a Binders invite."
            return
        }
        problem = nil
        controller.teamBoard.pendingInvite = invite
    }

    private func act(_ work: @escaping @MainActor () async throws -> String) {
        Task { @MainActor in
            do {
                _ = try await work()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
