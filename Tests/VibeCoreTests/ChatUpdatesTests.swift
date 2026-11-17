import Foundation
import Testing
@testable import VibeCore

/// The lead's chat folds each burst of VibeSwitcher's cards for it into one line (the user, 2026-11-17: "we have too
/// much noise.... i dont even read 80%").
struct ChatUpdatesTests {
    static func card(_ id: String, _ about: String, _ body: String) -> ChatEntry {
        let message = TeamMessage(sender: .vibeSwitcher(about), body: body)
        return ChatEntry(id: id, at: nil, kind: .steered(text: message.text, fromLead: true), team: message)
    }
    static func from(_ id: String, _ sender: TeamMessage.Sender, _ body: String) -> ChatEntry {
        let message = TeamMessage(sender: sender, body: body)
        return ChatEntry(id: id, at: nil, kind: .steered(text: message.text, fromLead: message.fromLead), team: message)
    }
    static func tool(_ id: String, _ name: String, command: String? = nil) -> ChatEntry {
        let detail: ToolDetail = command.map { .command($0) } ?? .fields([])
        return ChatEntry(id: id, at: nil, kind: .tool(ChatTool(id: id, name: name, title: command ?? name, detail: detail, at: nil, result: nil)))
    }
    static func prompt(_ id: String, _ text: String) -> ChatEntry { ChatEntry(id: id, at: nil, kind: .prompt(text: text, images: [])) }
    static func reply(_ id: String, _ text: String) -> ChatEntry { ChatEntry(id: id, at: nil, kind: .reply(text)) }

    static let wake = card("w", "reports", "3 new reports (worker a done; verifier b failed; app health: Crashes). Call status.")
    static let advance = card("adv", LeadAdvance.sender, """
        VibeSwitcher moved finished work on by itself (auto_advance):
        - Started the audit of git-guard
        The judgement calls stay yours: holds (update_task kept or blocked), re-plans, questions to the user, and post_update for a merge the user would notice.
        """)
    static let note = card("note", "worker a", "The worker on a says it's done: the chat folds its cards.")
    static let failed = card("audit", "verifier b", "The audit of b did not pass: F1 the sheet never closes.")
    static let passed = card("pass", "verifier c", "The audit of c passed.")
    static let crash = card("health", AppHealth.sender, "Crashes (reports in ~/Library/Logs/DiagnosticReports):\n- VibeSwitcher-2026-11-17.ips")
    static let stopped = card("stop", "witness", "The worker on d stopped mid-task: its turn ended on an API error (overloaded). Tell it to go on with message(d, …).")

    func shape(_ items: [ChatItem]) -> [String] {
        items.map { item in
            switch item {
            case .updates(let updates): return "updates[" + updates.items.map(\.id).joined(separator: ",") + "]"
            default: return item.id
            }
        }
    }

    func fold(_ entries: [ChatEntry]) -> [ChatItem] { ChatTimeline.foldUpdates(ChatTimeline.items(entries, newAfter: nil)) }

    func updates(_ item: ChatItem?) throws -> ChatUpdates {
        guard case .updates(let updates) = item else { throw Fail(item: item) }
        return updates
    }
    struct Fail: Error { let item: ChatItem? }

    /// A wake-up, its reports and the lead's tool rows between them: one item. Your words and the lead's reply stay.
    @Test func aBurstOfCardsAndTheToolsBetweenThemIsOneItem() throws {
        let entries = [Self.prompt("p", "how's it going?"), Self.reply("r0", "On it."), Self.wake, Self.advance, Self.tool("t1", "mcp__vibeswitcher__status"),
                       Self.note, Self.failed, Self.tool("t2", "mcp__vibeswitcher__board"), Self.crash, Self.stopped,
                       Self.tool("t3", "Bash", command: "git log -1"), Self.reply("r", "Two need you.")]
        let folded = fold(entries)
        #expect(shape(folded) == ["p", "r0", "updates[w,adv,tools:t1,note,audit,tools:t2,health,stop]", "tools:t3", "r"])
        let burst = try updates(folded[2])
        #expect(burst.id == "updates:w")
        // The wake-up only names the cards after it: not shown, not counted.
        #expect(burst.shown.map(\.id) == ["adv", "tools:t1", "note", "audit", "tools:t2", "health", "stop"])
        #expect(burst.cards.map(\.entry.id) == ["adv", "note", "audit", "health", "stop"])
        #expect(burst.alarming)
    }

    /// Never folded: the user's words relayed, the lead's, a teammate's post, a shell card's or a wallet's outcome, a
    /// full disk, an app update. Each ends a burst and stays a card.
    @Test func whatNeedsTheUserNeverFolds() throws {
        let kept = [
            Self.from("you", .user, "Ship it."),
            Self.from("lead", .lead("lead of vibeswitcher"), "Take the next task."),
            Self.from("post", .teammate(member: "api", task: "team-wall"), "Does the card take a title?"),
            Self.card("shell", "VibeSwitcher, from your vs-shell card the user ran", "Exit 0."),
            Self.card("wallet", "from the Wallet Manager", "Signed."),
            Self.card("disk", "disk full", "The disk is full."),
            Self.card("update", AppUpdateWatch.sender, "VibeSwitcher 2.3 is out."),
        ]
        for entry in kept {
            #expect(entry.team?.foldsIntoUpdates == false, "\(entry.id) folds")
            #expect(shape(fold([Self.note, entry, Self.passed])) == ["updates[note]", entry.id, "updates[pass]"])
        }
        for entry in [Self.wake, Self.advance, Self.note, Self.failed, Self.passed, Self.crash, Self.stopped,
                      Self.card("timer", "timer", "Your timer: check the merge."), Self.card("budget", "time budget", "Over budget.")] {
            #expect(entry.team?.foldsIntoUpdates == true, "\(entry.id) doesn't fold")
        }
    }

    /// A question to the user or a shell or wallet card asked for stays in sight, and a tool run after a burst's last
    /// card isn't between cards: neither folds.
    @Test func toolsThatAskTheUserOrComeAfterStayOut() {
        let ask = Self.tool("ask", "mcp__vibeswitcher__ask_user")
        let shell = Self.tool("shell", "Bash", command: "vs-shell run --label Install -- brew install jq")
        let wallet = Self.tool("wallet", "Bash", command: "vs-wallet sign --tx draft.json")
        for tool in [ask, shell, wallet] {
            #expect(shape(fold([Self.note, tool, Self.passed])) == ["updates[note]", "tools:\(tool.id)", "updates[pass]"])
        }
        #expect(shape(fold([Self.note, Self.tool("t", "Read")])) == ["updates[note]", "tools:t"])
        // A run of tools before any card is the lead's own work.
        #expect(shape(fold([Self.tool("t", "Read"), Self.note])) == ["tools:t", "updates[note]"])
    }

    /// "New since you looked", a closed question and an all-done card each end a burst.
    @Test func markersEndABurst() {
        let entries = [Self.note, Self.failed, Self.passed]
        #expect(shape(ChatTimeline.foldUpdates(ChatTimeline.items(entries, newAfter: "audit"))) == ["updates[note,audit]", "new-marker", "updates[pass]"])
        let mark = LeadAllDone(id: "m", at: 5, since: 0, tasks: [])
        let items = ChatTimeline.items(entries, newAfter: nil)
        #expect(shape(ChatTimeline.foldUpdates([items[0], .allDone(mark), items[1], items[2]])) == ["updates[note]", "all-done:m", "updates[audit,pass]"])
    }

    /// The line: the count, then each card's AI summary or else its label; auto_advance's boilerplate never.
    @Test func theLineSaysEachCardInAFewWords() throws {
        let burst = try updates(fold([Self.wake, Self.advance, Self.note, Self.failed, Self.passed]).first)
        #expect(burst.line() == "4 updates · started the audit of git-guard · report from the worker on a · audit of b didn't pass · audit of c passed")
        #expect(!burst.line().contains("moved finished work on by itself"))
        let summaries = ["adv": "Git guard audit started.", "note": "Worker freed\nafter its report", "audit": "  "]
        #expect(burst.line { summaries[$1] } == "4 updates · git guard audit started. · worker freed after its report · audit of b didn't pass · audit of c passed")
        // The same words twice in a row once; one card, one update.
        let twice = try updates(fold([Self.advance, Self.card("adv2", LeadAdvance.sender, Self.advance.team!.body)]).first)
        #expect(twice.line() == "2 updates · started the audit of git-guard")
        #expect(try updates(fold([Self.passed]).first).line() == "1 update · audit of c passed")
        // A step that isn't alone says how many more.
        let several = Self.card("adv3", LeadAdvance.sender, "VibeSwitcher moved finished work on by itself (auto_advance):\n- Released x\n- Cleaned up y\n- Started a worker on z")
        #expect(several.team?.foldLabel == "Released x (+2 more)")
        // A wake-up alone is all there is to show.
        let alone = try updates(fold([Self.wake]).first)
        #expect(alone.shown.map(\.id) == ["w"])
        // Each card's words cut at 80 characters.
        #expect(alone.line() == "1 update · " + Summarizer.clip("3 new reports (worker a done; verifier b failed; app health: Crashes). Call status.", 80))
        #expect(alone.line().hasPrefix("1 update · 3 new reports (worker a done;"))
        #expect(ChatUpdates.lowercasedStart("VibeSwitcher: x") == "VibeSwitcher: x")
        #expect(ChatUpdates.lowercasedStart("API error") == "API error")
    }

    /// A failure the user may care about marks the line; the rest don't.
    @Test func failuresMarkTheLine() throws {
        for entry in [Self.failed, Self.crash, Self.stopped, Self.card("blocked", "worker e", "The worker on e is blocked: no network"),
                      Self.card("quit", "witness", "The worker on f stopped without calling report. read_session to see where it is, then message it.")] {
            #expect(entry.team?.alarming == true, "\(entry.id) isn't marked")
            #expect(try updates(fold([Self.passed, entry]).first).alarming)
        }
        let health = Self.card("health2", AppHealth.sender, "Error lines in app.log within the last hour: 3")
        for entry in [Self.wake, Self.advance, Self.note, Self.passed, health] {
            #expect(entry.team?.alarming == false, "\(entry.id) is marked")
        }
        #expect(try !updates(fold([Self.advance, Self.note, Self.passed]).first).alarming)
        // A failure only the wake-up names isn't one of its cards.
        #expect(try !updates(fold([Self.wake, Self.passed]).first).alarming)
    }

    /// Search finds a card inside a folded burst, at the burst; the text the agent got is unchanged.
    @Test func searchFindsACardInsideABurst() throws {
        let folded = fold([Self.prompt("p", "go"), Self.note, Self.failed])
        #expect(ChatSearch.matches(folded, query: "sheet never closes") == ["updates:note"])
        let burst = try updates(folded[1])
        guard case .team(let entry, _) = burst.items[1] else { Issue.record("not a card"); return }
        #expect(entry == Self.failed)
    }
}
