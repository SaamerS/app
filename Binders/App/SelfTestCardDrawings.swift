import AppKit
import SwiftData
import SwiftUI
import BindersKit

/// The card window's states, on the demo data, for `--selftest-draw card:<state>` and `--selftest-draw cards`: each state's
/// card set up in the throwaway data folder on top of `DemoData.seed`. Events go in as DemoData puts its own (a TaskEvent
/// with its time set), and cards' fields are set directly, so no drawing posts a notification or wakes anyone. Agents are
/// registered as `--selftest-draw agents` registers them; nothing calls them, and a throwaway folder never runs a web hook.
@MainActor
struct CardDrawings {
    /// Every state the design draws, in the order they're drawn.
    /// `tabs` is two of them as tabs of one card window, drawn with the window's title bar and tab bar.
    static let states = ["backlog", "meant", "ready", "progress", "progress-hook", "yours-meant", "blocked-running", "approval-long",
                         "long-title", "long", "scrolled-up", "failed", "no-binder", "blocked", "approval", "review", "done", "quiet", "yours",
                         "blocked-reason", "details-hidden", "details-over", "composer6", "tabs"]

    let controller: DictationController
    let harbor: BinderRecord
    private(set) var cards: [String: UUID] = [:]
    let grok = BoardActor(name: "Grok Bot", kind: .agent)
    let claude = BoardActor(name: "Claude Code · harbor-web", kind: .agent)
    let emails = BoardActor(name: "Claude Code · harbor-emails", kind: .agent)
    let cursor = BoardActor(name: "Cursor · harbor-web", kind: .agent)

    init(controller: DictationController, harbor: BinderRecord) {
        self.controller = controller
        self.harbor = harbor
    }

    func card(_ state: String) -> TaskCard? { cards[state].flatMap(controller.board.card) }

    // MARK: Setting the states up

    /// Registers the agents and makes or changes each state's card.
    mutating func prepare() {
        let registry = AgentRegistry.shared
        if registry.paused { registry.setPaused(false) }
        func repository(_ name: String) -> String {
            let folder = AppPaths.support.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
            return folder.path
        }
        registry.upsert(AgentProfile(name: grok.name, wake: .webhook(url: "https://hooks.example.com/binders"), preset: "grok-bot"))
        registry.upsert(AgentProfile(name: claude.name, wake: .claudeCode(ClaudeCodeWake(repository: repository("harbor-web"))), preset: "claude-code"))
        registry.upsert(AgentProfile(name: emails.name, wake: .claudeCode(ClaudeCodeWake(repository: repository("harbor-emails"))), preset: "claude-code"))

        let seeded = controller.board.cards(in: harbor.id)
        func seededCard(_ title: String) -> TaskCard? { seeded.first { $0.title == title } }
        cards["backlog"] = seededCard("Rewrite the status page wording")?.id
        cards["blocked"] = seededCard("Update the pricing comparison table")?.id
        cards["done"] = seededCard("Migrate billing to the new provider")?.id

        // Review: Claude Code finished it, meant for it by you, so Send Back wakes it.
        if let review = seededCard("Write onboarding email 5") {
            review.meantFor = emails.name
            event(review, .assigned, .you, "Meant for \(emails.name).", minutesAgo: 6 * 60 + 5)
            cards["review"] = review.id
        }
        cards["meant"] = meant(binder: harbor.id).id
        cards["no-binder"] = meant(binder: UUID()).id
        cards["ready"] = ready().id
        cards["progress"] = progress().id
        cards["progress-hook"] = progressHook("Update the pricing comparison table").id
        cards["long-title"] = progressHook("Update the pricing comparison table and the annual plan footnote on the marketing site before the beta email goes out").id
        cards["failed"] = failed().id
        cards["details-hidden"] = cards["progress-hook"]
        cards["details-over"] = cards["progress-hook"]
        cards["composer6"] = progressHook("Update the pricing comparison table").id
        cards["yours-meant"] = yoursMeant().id
        cards["blocked-running"] = blockedRunning().id
        cards["approval"] = approval(long: false).id
        cards["approval-long"] = approval(long: true).id
        cards["quiet"] = quiet().id
        cards["yours"] = yours().id
        cards["blocked-reason"] = blockedReason().id
        cards["long"] = long().id
        cards["scrolled-up"] = long().id
        Store.shared.save()
    }

    /// A card on the Harbor board (or `binder`), set up directly, as DemoData sets up its own.
    private func newCard(_ title: String, _ column: BoardColumn, binder: UUID? = nil, details: String = "", meant: String? = nil, holder: BoardActor? = nil,
                         minutesLeft: Double = 24, due: Date? = nil, links: [String] = [], fromReview: Bool = false) -> TaskCard {
        let card = TaskCard(title: title, binderID: binder ?? harbor.id, column: column)
        card.details = details
        card.links = links
        card.meantFor = meant
        card.dueAt = due
        if fromReview {
            card.sourceTitle = DemoData.meetingTitle
            card.sourceKind = "meeting"
        }
        if let holder {
            card.assignee = holder.name
            card.assigneeIsAgent = holder.isAgent
            card.claimExpiresAt = holder.isAgent && column == .inProgress ? Date().addingTimeInterval(minutesLeft * 60) : nil
        }
        Store.shared.context.insert(card)
        return card
    }

    @discardableResult
    private func event(_ card: TaskCard, _ kind: TaskEvent.Kind, _ author: BoardActor, _ text: String = "", from: BoardColumn? = nil, to: BoardColumn? = nil,
                       minutesAgo: Double) -> TaskEvent {
        let event = TaskEvent(taskID: card.id, kind: kind, author: author, text: text, from: from, to: to)
        event.createdAt = Date().addingTimeInterval(-minutesAgo * 60)
        Store.shared.context.insert(event)
        return event
    }

    /// The receipt a web hook's wake leaves, as the dispatcher writes it.
    private func receipt(_ card: TaskCard, _ why: String, minutesAgo: Double) {
        event(card, .woke, grok, "Sent Grok Bot the card at hooks.example.com (\(why)).", minutesAgo: minutesAgo)
    }

    private func meant(binder: UUID) -> TaskCard {
        let friday = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 17, weekday: 6), matchingPolicy: .nextTime)
        let card = newCard("Draft the launch email to beta customers", .backlog, binder: binder,
                           details: "One email to the beta list about annual pricing and the import fix.", meant: grok.name, due: friday)
        event(card, .created, .you, to: .backlog, minutesAgo: 70)
        event(card, .assigned, .you, "Meant for Grok Bot.", minutesAgo: 69)
        event(card, .comment, .you, "Keep it under 150 words. Link the new pricing page.", minutesAgo: 68)
        return card
    }

    /// Handed to Grok Bot, which hasn't taken it, and a comment of yours after the hand-off.
    private func ready() -> TaskCard {
        guard let card = controller.board.cards(in: harbor.id).first(where: { $0.title == "Fix the import timeout above 20,000 rows" }) else {
            return newCard("Fix the import timeout above 20,000 rows", .ready)
        }
        card.meantFor = grok.name
        event(card, .assigned, .you, "Meant for Grok Bot.", minutesAgo: 19)
        receipt(card, "made ready for it", minutesAgo: 18)
        event(card, .comment, .you, "The 50k-row file for the staging test is in the shared drive, under Imports.", minutesAgo: 2)
        controller.agents.drawing(working: [], outcomes: [card.id: .init(at: Date().addingTimeInterval(-18 * 60), ok: true, message: "Sent to Grok Bot")],
                                  unsent: [card.id: "Not sent: Grok Bot hasn't taken the card."])
        return card
    }

    /// A Claude Code run Binders started, saying what it's doing.
    private func progress() -> TaskCard {
        guard let card = controller.board.cards(in: harbor.id).first(where: { $0.title == "Draft the changelog post" }) else {
            return newCard("Draft the changelog post", .inProgress)
        }
        card.meantFor = claude.name
        card.links.append("file://\(AgentDispatcher.logs.path)/\(card.id.uuidString.prefix(8).lowercased())-20261019T110600.jsonl")
        event(card, .woke, claude, "Started Claude Code in ~/code/harbor-web/.claude/worktrees/binders-\(card.id.uuidString.prefix(8).lowercased()) (auto, made ready for it). To look in: claude --resume 6ba7b810-9dad-11d1-80b4-00c04fd430c8 there.",
              minutesAgo: 2 * 60 + 1)
        return card
    }

    /// The founder's case: Grok Bot, a web hook agent, holds the card; your comment woke it, and it answered with progress.
    private func progressHook(_ title: String) -> TaskCard {
        let card = newCard(title, .inProgress, details: "The comparison table on the pricing page still shows last year's plans.", meant: grok.name,
                           holder: grok, links: ["https://github.com/example/harbor-web/pull/221"], fromReview: true)
        event(card, .created, .you, "From \(DemoData.meetingTitle)", to: .ready, minutesAgo: 75)
        receipt(card, "made ready for it", minutesAgo: 74)
        event(card, .claimed, grok, from: .ready, to: .inProgress, minutesAgo: 73)
        event(card, .progress, grok, "Rebuilt the table with the three current plans. The annual column still shows last year's discount.", minutesAgo: 45)
        event(card, .comment, .you, "Use the 15% from the new price sheet, and keep the footnote to one line.", minutesAgo: 12)
        receipt(card, "you commented", minutesAgo: 11.9)
        event(card, .progress, grok, "Switched to 15% and shortened the footnote. Checking the phone layout next.", minutesAgo: 9)
        controller.agents.drawing(working: [], outcomes: [card.id: .init(at: Date().addingTimeInterval(-11.9 * 60), ok: true, message: "Sent to Grok Bot")])
        return card
    }

    /// The same, with the newest wake's web hook answering an error.
    private func failed() -> TaskCard {
        let card = progressHook("Update the pricing comparison table")
        event(card, .comment, .you, "And link the price sheet, not the old PDF.", minutesAgo: 3)
        receipt(card, "you commented", minutesAgo: 2.9)
        event(card, .woke, grok, "Its web hook didn't take the card: The server answered 500.", minutesAgo: 2.8)
        controller.agents.drawing(working: [], outcomes: [card.id: .init(at: Date().addingTimeInterval(-2.8 * 60), ok: false,
                                                                          message: "Grok Bot's web hook: The server answered 500.")])
        return card
    }

    /// Meant for Grok Bot and handed over, then dragged to In progress by you, so you hold it.
    private func yoursMeant() -> TaskCard {
        let friday = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 17, weekday: 6), matchingPolicy: .nextTime)
        let card = newCard("Draft the launch FAQ", .inProgress, details: "Ten questions for the launch page, from the support inbox.", meant: grok.name,
                           holder: .you, due: friday)
        event(card, .created, .you, to: .ready, minutesAgo: 40)
        event(card, .assigned, .you, "Meant for Grok Bot.", minutesAgo: 39)
        receipt(card, "made ready for it", minutesAgo: 35)
        event(card, .moved, .you, from: .ready, to: .inProgress, minutesAgo: 14)
        event(card, .comment, .you, "Ten questions at most, and link the pricing page from the first one.", minutesAgo: 12)
        controller.agents.drawing(working: [], outcomes: [card.id: .init(at: Date().addingTimeInterval(-35 * 60), ok: true, message: "Sent to Grok Bot")],
                                  unsent: [card.id: "Not sent: you have the card."])
        return card
    }

    /// Claude Code asked, and its run hasn't ended yet.
    private func blockedRunning() -> TaskCard {
        let card = newCard("Update the onboarding checklist", .blocked, details: "The checklist new workspaces see first, with the import steps first.",
                           meant: claude.name, holder: claude)
        event(card, .woke, claude, "Started Claude Code in ~/code/harbor-web/.claude/worktrees/binders-\(card.id.uuidString.prefix(8).lowercased()) (auto, made ready for it). To look in: claude --resume 7ba7b810-9dad-11d1-80b4-00c04fd430c8 there.",
              minutesAgo: 30)
        event(card, .claimed, claude, from: .ready, to: .inProgress, minutesAgo: 29.9)
        event(card, .progress, claude, "Moved the import steps to the top of the checklist.", minutesAgo: 12)
        event(card, .question, claude, "Should the checklist link the old import guide too, or only the new one?", from: .inProgress, to: .blocked, minutesAgo: 8)
        controller.agents.drawing(working: [card.id], outcomes: [:])
        return card
    }

    /// Grok Bot asks your approval to send an email; the long one has a twelve-line text.
    private func approval(long: Bool) -> TaskCard {
        let friday = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 17, weekday: 6), matchingPolicy: .nextTime)
        let card = newCard("Tell beta customers about annual pricing", .blocked, details: "Email the beta list about annual pricing. Draft only: I approve before it goes.",
                           meant: grok.name, holder: grok, due: friday)
        event(card, .claimed, grok, from: .ready, to: .inProgress, minutesAgo: 30)
        event(card, .progress, grok, "Drafted the announcement from the pricing table.", minutesAgo: 8)
        let short = "Hi, annual plans now come with 15% off, shown in the table on the pricing page. Imports over 20,000 rows no longer time out."
        let lines = [short, "", "What changes for you:", "- Annual plans are 15% off from the 28th.", "- The comparison table shows the yearly total under each plan.",
                     "- Large imports run in batches, so nothing times out.", "", "If you're on a monthly plan, nothing changes until you switch.",
                     "Questions? Reply to this email and the team will answer.", "", "Thanks for trying Harbor early,", "The Harbor team"]
        let asked = AgentApproval(action: "send an email", recipients: ["beta-list@example.com"], text: long ? lines.joined(separator: "\n") : short)
        event(card, .approval, grok, asked.timelineText, from: .inProgress, to: .blocked, minutesAgo: 5)
        return card
    }

    /// Grok Bot took it and stopped reporting; the board let it go back to Ready, still meant for Grok Bot.
    private func quiet() -> TaskCard {
        let card = newCard("Check the onboarding screenshots", .ready, meant: grok.name)
        event(card, .created, .you, to: .ready, minutesAgo: 62)
        receipt(card, "made ready for it", minutesAgo: 60)
        event(card, .claimed, grok, from: .ready, to: .inProgress, minutesAgo: 59)
        event(card, .progress, grok, "Comparing the light and dark sets.", minutesAgo: 52)
        event(card, .lapsed, grok, "Grok Bot went quiet for 30 minutes, so the card is free again.", from: .inProgress, to: .ready, minutesAgo: 21)
        controller.agents.drawing(working: [], outcomes: [card.id: .init(at: Date().addingTimeInterval(-60 * 60), ok: true, message: "Sent to Grok Bot")])
        return card
    }

    /// One you hold yourself, due today.
    private func yours() -> TaskCard {
        let today = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: .now) ?? .now
        let card = newCard("Book the venue for the launch party", .inProgress, details: "Forty people, the evening of the 28th, near the office.",
                           holder: .you, due: today)
        event(card, .created, .you, to: .ready, minutesAgo: 95)
        event(card, .claimed, .you, from: .ready, to: .inProgress, minutesAgo: 94)
        event(card, .comment, .you, "Two quotes in, both under budget. Waiting on the third.", minutesAgo: 20)
        return card
    }

    /// A run that stopped leaves its card in Blocked, with why.
    private func blockedReason() -> TaskCard {
        let card = newCard("Fix the footer link", .blocked, meant: claude.name, holder: claude)
        event(card, .claimed, claude, from: .ready, to: .inProgress, minutesAgo: 40)
        event(card, .progress, claude, "Found the broken link in the footer partial.", minutesAgo: 21)
        event(card, .moved, claude, "Its run stopped (exit 1) before it finished. It said: The test suite needs a database that isn't running.",
              from: .inProgress, to: .blocked, minutesAgo: 17)
        return card
    }

    /// A long conversation: 34 entries over two days, every kind the card shows.
    private func long() -> TaskCard {
        let card = newCard("Update the pricing comparison table", .inProgress, details: "The comparison table on the pricing page still shows last year's plans.",
                           meant: grok.name, holder: grok, links: ["https://github.com/example/harbor-web/pull/221", "https://example.com/pricing"],
                           fromReview: true)
        let day = 24.0 * 60
        event(card, .created, .you, "From \(DemoData.meetingTitle)", to: .ready, minutesAgo: day + 300)
        event(card, .comment, BoardService.binders, "Binders handed this to Grok Bot without asking: you typed it into Ready on this board, and it's clearly Grok Bot's work. Stop it here, or turn off Start on cards Binders sends it for Grok Bot in Settings → Agents.",
              minutesAgo: day + 299.5)
        event(card, .assigned, .you, "Meant for Grok Bot.", minutesAgo: day + 299)
        receipt(card, "made ready for it", minutesAgo: day + 298)
        event(card, .context, BoardService.binders, "Launch readiness review: “The comparison table is too dense on phones.”\nPricing notes: “Annual plans get 15% off from the 28th.”",
              minutesAgo: day + 297.9)
        event(card, .claimed, grok, from: .ready, to: .inProgress, minutesAgo: day + 297)
        event(card, .progress, grok, "Read the card and the review notes. Starting with the plan names.", minutesAgo: day + 280)
        event(card, .progress, grok, "Renamed the plans to Starter, Team and Business.", minutesAgo: day + 250)
        event(card, .comment, .you, "Keep Business last, it's the one we push.", minutesAgo: day + 240)
        receipt(card, "you commented", minutesAgo: day + 239.9)
        event(card, .progress, grok, "Business is last now.", minutesAgo: day + 230)
        event(card, .question, grok, "Should the annual column show the price per month or per year?", from: .inProgress, to: .blocked, minutesAgo: day + 220)
        event(card, .answer, .you, "Per month, with the yearly total under it.", from: .blocked, to: .inProgress, minutesAgo: day + 200)
        receipt(card, "you answered", minutesAgo: day + 199.9)
        event(card, .progress, grok, "Annual prices per month now, with the yearly total under each.", minutesAgo: day + 180)
        event(card, .lapsed, grok, "Grok Bot went quiet for 30 minutes, so the card is free again.", from: .inProgress, to: .ready, minutesAgo: day + 140)
        event(card, .comment, .you, "Are you still on this?", minutesAgo: day + 120)
        receipt(card, "Wake Now", minutesAgo: day + 119)
        event(card, .claimed, grok, from: .ready, to: .inProgress, minutesAgo: day + 118)
        event(card, .progress, grok, "Back on it. The phone layout is next.", minutesAgo: 300)
        let asked = AgentApproval(action: "send an email", recipients: ["design@example.com"],
                                  text: "Here are the new comparison table screenshots for the phone and the desktop. Can you check the spacing?")
        event(card, .approval, grok, asked.timelineText, from: .inProgress, to: .blocked, minutesAgo: 280)
        event(card, .decision, BoardService.binders, asked.receipt(approved: true, on: "MacBook Air", at: Date().addingTimeInterval(-270 * 60)), minutesAgo: 270)
        event(card, .answer, .you, AgentApproval.answer(approved: true), from: .blocked, to: .inProgress, minutesAgo: 269.9)
        receipt(card, "you answered", minutesAgo: 269.8)
        event(card, .progress, grok, "Sent the screenshots to the design list.", minutesAgo: 250)
        event(card, .comment, .you, "Use the 15% from the new price sheet, and keep the footnote to one line.", minutesAgo: 120)
        event(card, .comment, .you, "And link the price sheet, not the old PDF.", minutesAgo: 119.5)
        receipt(card, "you commented", minutesAgo: 117.5)
        event(card, .progress, grok, "Switched to 15%, shortened the footnote and linked the price sheet.", minutesAgo: 90)
        event(card, .edited, .you, minutesAgo: 60)
        event(card, .comment, grok, "The phone layout needs one more pass: the footnote wraps under the Business column.", minutesAgo: 40)
        event(card, .comment, .you, "Thanks. Put a screenshot of each on the card.", minutesAgo: 20)
        receipt(card, "you commented", minutesAgo: 19.9)
        event(card, .progress, grok, "Screenshots are on the card.", minutesAgo: 6)
        return card
    }

    /// Two entries more, for the conversation scrolled up when they come: the pill's "2 new".
    func addTwoNew(to card: TaskCard) -> [TaskEvent] {
        let first = event(card, .progress, grok, "Checked the table at 375 pt wide: the footnote fits on one line now.", minutesAgo: 0.5)
        let second = event(card, .progress, grok, "Pushed the change to the pull request.", minutesAgo: 0.2)
        Store.shared.save()
        return [first, second]
    }

    // MARK: What each state should say

    /// The composer's buttons and the header's primary each state should have (the design's parts 5, 6.1 and 7).
    func expected(_ state: String) -> (buttons: [String], primary: CardPrimary?, stop: Bool) {
        switch state {
        case "backlog": return (["Comment"], .takeIt, false)
        case "meant", "no-binder": return (["Comment"], .giveTo(grok.name), false)
        case "ready", "quiet": return (["Send to Grok Bot", "Comment"], .wakeNow(prominent: false), false)
        case "progress": return (["Comment"], nil, true)
        case "progress-hook", "long-title", "long", "scrolled-up", "failed", "details-hidden", "details-over", "composer6":
            return (["Send to Grok Bot"], .wakeNow(prominent: false), false)
        case "yours-meant": return (["Send to Grok Bot", "Comment"], .wakeNow(prominent: false), false)
        case "blocked-running": return (["Answer"], nil, true)
        case "approval", "approval-long": return (["Send to Grok Bot"], nil, false)
        case "blocked": return (["Answer"], nil, false)
        case "review", "done", "yours": return (["Comment"], nil, false)
        case "blocked-reason": return (["Send to Claude Code"], nil, false)
        default: return ([], nil, false)
        }
    }
}

extension SelfTest {
    /// `--selftest-draw card:<state> <out.png> [--size 880x600]`: one state, in the app's appearance (`--appearance`).
    /// `--selftest-draw cards <folder>/cards.png`: every state, dark and light, at the default size and the smallest, into
    /// that folder (`card-<state>-dark.png`, `card-<state>-smallest-light.png`…), with a PASS or FAIL line for what each
    /// state's composer and header say. In a throwaway folder only.
    @MainActor
    static func drawCards(page: String, to url: URL, size: NSSize?, controller: DictationController, harbor: BinderRecord) async -> Int32 {
        var failures = 0
        var drawings = CardDrawings(controller: controller, harbor: harbor)
        drawings.prepare()
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaultSize = NSSize(width: CardLayout.defaultWidth, height: CardLayout.defaultHeight)
        let smallest = NSSize(width: CardLayout.smallestWidth, height: CardLayout.smallestHeight)
        if page == "cards" {
            let appearances: [(String, NSAppearance)] = [("dark", NSAppearance(named: .darkAqua)!), ("light", NSAppearance(named: .aqua)!)]
            for state in CardDrawings.states {
                for (sizeName, size) in [("", defaultSize), ("-smallest", smallest)] {
                    for (look, appearance) in appearances {
                        let name = "card-\(state)\(sizeName)-\(look)"
                        if state == "tabs" {
                            failures += await drawTabs(drawings: drawings, size: size, appearance: appearance, name: name, folder: folder)
                            continue
                        }
                        failures += await drawCard(state, drawings: drawings, size: size, appearance: appearance, name: name, folder: folder,
                                                   wholeScroll: state == "long" && sizeName.isEmpty && look == "dark")
                    }
                }
            }
            // A wide window with Details hidden: the conversation keeps to its reading width, centred.
            for (look, appearance) in appearances {
                failures += await drawCard("details-hidden", drawings: drawings, size: NSSize(width: 1600, height: 900), appearance: appearance,
                                           name: "card-wide-\(look)", folder: folder, wholeScroll: false)
            }
        } else {
            let state = String(page.dropFirst("card:".count))
            guard CardDrawings.states.contains(state) else {
                print("ERROR: no card state \(state). They are: \(CardDrawings.states.joined(separator: ", "))")
                return 1
            }
            if state == "tabs" {
                failures += await drawTabs(drawings: drawings, size: size ?? defaultSize, appearance: nil, name: url.deletingPathExtension().lastPathComponent,
                                           folder: folder)
            } else {
                failures += await drawCard(state, drawings: drawings, size: size ?? defaultSize, appearance: nil, name: url.deletingPathExtension().lastPathComponent,
                                           folder: folder, wholeScroll: false)
            }
        }
        print(failures == 0 ? "CARD_DRAWINGS_OK" : "CARD_DRAWINGS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// One state, hosted as its window hosts it: the card with the controller, the Binders window's navigation, the model
    /// container, the throwaway defaults and a no-op close, in a window of the drawing's size.
    @MainActor
    private static func drawCard(_ state: String, drawings: CardDrawings, size: NSSize, appearance: NSAppearance?, name: String, folder: URL,
                                 wholeScroll: Bool) async -> Int {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        guard let card = drawings.card(state) else {
            check(false, "\(state): its card is there")
            return failures
        }
        let controller = drawings.controller
        // What the state needs while it's drawn.
        if state == "progress" { AgentDoingFeed.shared.pin([card.id: "Writing the summary of the batching fix"]) }
        if state == "progress" { controller.agents.drawing(working: [card.id], outcomes: [:]) }
        NeedsYouTray.drawingDeclines = state == "approval-long"
        CardWindows.shared.setDraft(draft(for: state), for: card.id)
        let detailsWere = AppDefaults.store.object(forKey: CardWindows.detailsKey)
        if state == "details-hidden" { AppDefaults.store.set(false, forKey: CardWindows.detailsKey) }
        defer {
            NeedsYouTray.drawingDeclines = false
            CardWindows.shared.setDraft("", for: card.id)
            if state == "details-hidden" { AppDefaults.store.set(detailsWere, forKey: CardWindows.detailsKey) }
        }

        let root = CardDetailView(card: card, detailsOver: state == "details-over")
            .environment(controller)
            .environment(HubWindowController.shared.navigation)
            .environment(\.closeCard, {})
            // Drawn as the window you're working in: its primary buttons in their colour.
            .environment(\.controlActiveState, .key)
            .modelContainer(Store.shared.container)
            .defaultAppStorage(throwawayDefaults)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.alphaValue = 0
        if let appearance { window.appearance = appearance }
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1600))
        var added: [TaskEvent] = []
        if state == "scrolled-up", let scroll = findScroll(in: hosting) {
            // Scrolled to the top to read, then two entries come: nothing moves, and the pill says so.
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            try? await Task.sleep(for: .milliseconds(400))
            added = drawings.addTwoNew(to: card)
            try? await Task.sleep(for: .milliseconds(1200))
            check(scroll.contentView.bounds.minY < 1, "\(name): scrolled up, the entries that came didn't move what you were reading")
        }
        let draw = { capture(hosting, name: name, directory: folder) }
        if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
        if wholeScroll, let scroll = findScroll(in: hosting) { captureConversation(scroll, appearance: appearance, name: "\(name)-conversation", folder: folder) }
        check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).png").path), "\(name).png is drawn")

        // What the composer and the header say.
        let events = controller.board.timeline(card.id)
        let reach = controller.agents.commentReach(for: card, events: events)
        let answering = CardAnswering.of(card, events: events)
        let buttons = reach.buttons(answering: answering).map(\.title)
        let expected = drawings.expected(state)
        check(buttons == expected.buttons, "\(name): the composer's buttons are \(expected.buttons): \(buttons) (\(reach))")
        let stop = CardHeader.showsStop(card, controller: controller)
        let primary = CardHeader.primary(card, registry: AgentRegistry.shared, showsStop: stop, reach: reach)
        check(primary == expected.primary && stop == expected.stop,
              "\(name): the header's primary is \(String(describing: expected.primary)) and Stop \(expected.stop ? "shows" : "doesn't"): \(String(describing: primary)), \(stop)")
        if size.width < CGFloat(CardLayout.detailsDockedFrom) {
            let conversation = findScroll(in: hosting)?.frame.height ?? 0
            check(conversation >= CGFloat(CardLayout.conversationMinHeight) - 1, "\(name): the conversation keeps 160 pt: \(Int(conversation))")
            let docked = findDescription(in: hosting) != nil
            check(docked == (state == "details-over"), "\(name): Details \(state == "details-over" ? "lie over the conversation" : "aren't docked")")
        }
        window.close()
        for event in added { Store.shared.context.delete(event) }
        if !added.isEmpty { Store.shared.save() }
        return failures
    }

    /// Two cards open as tabs of one card window, as `CardWindows` opens them (never shown in a throwaway folder): drawn with
    /// the window's title bar and tab bar, its frame view, and checked that the selected card's title row is below them.
    @MainActor
    private static func drawTabs(drawings: CardDrawings, size: NSSize, appearance: NSAppearance?, name: String, folder: URL) async -> Int {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        guard let first = drawings.card("approval"), let second = drawings.card("progress-hook") else {
            check(false, "\(name): its cards are there")
            return failures
        }
        let controller = drawings.controller
        let windows = CardWindows.shared
        windows.controller = controller
        let sizeWas = AppDefaults.store.string(forKey: CardWindows.sizeKey)
        AppDefaults.store.set(CardLayout.sizeString(width: Double(size.width), height: Double(size.height)), forKey: CardWindows.sizeKey)
        defer {
            if let sizeWas { AppDefaults.store.set(sizeWas, forKey: CardWindows.sizeKey) } else { AppDefaults.store.removeObject(forKey: CardWindows.sizeKey) }
        }
        windows.open(first, controller: controller)
        windows.open(second, controller: controller)
        guard let window = windows.window(for: second.id), let other = windows.window(for: first.id) else {
            check(false, "\(name): both cards open")
            return failures
        }
        if let appearance {
            window.appearance = appearance
            other.appearance = appearance
        }
        try? await Task.sleep(for: .milliseconds(1600))
        let top = window.frame.height - window.contentLayoutRect.maxY
        let title = CardHeader.titleTops[second.id] ?? -1
        check(window.tabbedWindows?.count == 2 && top > 40 && title >= top,
              "\(name): two cards as tabs, the title row \(Int(title)) pt from the top, below the title and tab bars' \(Int(top)) pt")
        if let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            let draw = { frame.cacheDisplay(in: frame.bounds, to: rep) }
            if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
            print("SNAPSHOT: \(name).png (\(Int(frame.bounds.width))x\(Int(frame.bounds.height)))")
        }
        check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).png").path), "\(name).png is drawn")
        windows.close(second.id)
        windows.close(first.id)
        try? await Task.sleep(for: .milliseconds(300))
        return failures
    }

    /// The whole conversation, every entry, on the page's ground: to read a long one top to bottom.
    @MainActor
    private static func captureConversation(_ scroll: NSScrollView, appearance: NSAppearance?, name: String, folder: URL) {
        guard let document = scroll.documentView, let rep = document.bitmapImageRepForCachingDisplay(in: document.bounds) else { return }
        let area = document.bounds
        let draw = {
            document.cacheDisplay(in: area, to: rep)
            let image = NSImage(size: area.size)
            image.lockFocus()
            BindersTheme.NS.ground.setFill()
            area.fill()
            rep.draw(in: area, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            image.unlockFocus()
            guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: folder.appendingPathComponent("\(name).png"))
            print("SNAPSHOT: \(name).png (\(Int(area.width))x\(Int(area.height)))")
        }
        if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
    }

    /// What's typed in the composer: three lines for the long approval, six for the grown composer.
    private static func draft(for state: String) -> String {
        switch state {
        case "approval-long": "Shorter, please: two sentences,\nand say the 15% is for annual plans\nonly. Leave out the onboarding emails."
        case "composer6": "Two more things before you push:\n\n- the footnote links to the price sheet, not the old PDF\n- on phones, annual and monthly sit one above the other\n\nThen put a screenshot of each on the card. Thanks."
        default: ""
        }
    }

    /// The conversation's own scroll view.
    @MainActor
    static func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.identifier == ScrollProbe.identifier { return scroll }
        return view.subviews.lazy.compactMap(findScroll).first
    }

    /// The description's editor, where Details show.
    @MainActor
    private static func findDescription(in view: NSView) -> MarkdownTextView? {
        (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(findDescription).first
    }
}
