import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Incident, wallet-manager's lead, 2026-11-03: five message() calls to its working Codex worker (merge-the-other-computer)
/// over about 40 min each said "Sent to … while it works; it gets it at its next step", and none reached it. The worker
/// kept running commands, the witness twice said a message had waited 5 and 7 min in its inbox, and the worker reported
/// blocked ("no answer received" to its ask_lead) with the answer in its inbox. A working agent's messages went to the
/// steer inbox, which only Claude's hooks hand over (`vibeswitcher-hook`); Codex's hooks hand it nothing, and Codex
/// takes a message typed into its box during a turn as steering. So a working Codex worker's message is typed into
/// its box, as the chat's composer does (`MainWindowController.steerSelected`); when its box can't take it, the lead
/// is told it waits for the turn's end, not that it gets it at its next step.
///
/// The screens are a real Codex CLI 0.160 one (`codex-0.160-idle-120x40.json`, see `CodexComposerTests`), with the
/// status row a working Codex draws above its composer. Fake ttys and scratch inboxes only.
struct CodexMidTurnMessageTests {
    let temp = Scratch()

    struct Captured: Decodable {
        var text: String
        var runs: [ScreenRun]?
    }

    /// The captured screen as a working Codex draws it: "Working (…)" where its finished turn said "Worked for 12s".
    func working(composer rows: [String]? = nil) throws -> LeadDelivery.Screen {
        let url = try #require(Bundle.module.url(forResource: "codex-0.160-idle-120x40", withExtension: "json", subdirectory: "Fixtures"))
        let captured = try JSONDecoder().decode(Captured.self, from: Data(contentsOf: url))
        var lines = captured.text.components(separatedBy: "\n")
        let status = try #require(lines.firstIndex { $0.contains("Worked for 12s") })
        lines[status] = "• Working (41s • esc to interrupt)"
        var runs = captured.runs
        if let rows {
            // Its composer's rows, typed text (none of it faint), going upward from the `›` row.
            let composer = try #require(lines.lastIndex { $0.hasPrefix("›") })
            let first = composer - (rows.count - 1)
            lines.replaceSubrange(first...composer, with: rows)
            runs = runs?.filter { !(first...composer).contains($0.row) }
        }
        return LeadDelivery.Screen(text: lines.joined(separator: "\n"), runs: runs)
    }

    func codex(_ tty: String) -> LeadAgent { LeadAgent(pid: 4242, tty: tty, session: UUID().uuidString, agent: .codex) }

    @Test func aWorkingCodexWorkerHasTheLeadsMessageTypedIntoItsBoxNotLeftInItsInbox() throws {
        let root = temp.url("inbox")
        let agent = codex("ttys951")
        let empty = try working()
        #expect(LeadDelivery.box(in: empty) == .empty)
        var typed: [String] = []
        var cleared = 0
        let delivered = try LeadDelivery.deliver(
            "Yes: merge it into main.", from: .lead("lead of wallet-manager"), to: agent, activity: .working("Bash"),
            styledScreen: { empty }, typeInto: { typed.append($0); return true }, clearDraft: false,
            clear: { cleared += 1; return true }, enter: { true }, turnStarted: { true }, pause: {}, root: root)
        // Typed in, marked as the lead's, once; nothing left waiting for a hook that never hands it over.
        #expect(typed == [LeadDelivery.typed("Yes: merge it into main.", from: .lead("lead of wallet-manager"))])
        #expect(SteerInbox.pending(tty: agent.tty, root: root).isEmpty)
        #expect(delivered == .typedWhileWorking)
        #expect(cleared == 0)
    }

    /// Its box holds a draft: not cleared (a ^C mid-turn stops Codex's turn), not typed over. It waits in the inbox,
    /// the lead is told so, and it's typed in when the turn ends (the app's flush, `LeadController.flush`).
    @Test func aDraftInAWorkingCodexsBoxWaitsForTheTurnsEndAndSaysSo() throws {
        let root = temp.url("inbox")
        let agent = codex("ttys952")
        let draft = try working(composer: ["› half-written note"])
        #expect(LeadDelivery.box(in: draft) == .draft("half-written note"))
        var typed: [String] = []
        var cleared = 0
        let delivered = try LeadDelivery.deliver(
            "go on", from: .lead("lead"), to: agent, activity: .working("Bash"), styledScreen: { draft },
            typeInto: { typed.append($0); return true }, clearDraft: true, clear: { cleared += 1; return true },
            enter: { true }, turnStarted: { true }, pause: {}, root: root)
        #expect(delivered == .atTurnEnd(draft: "half-written note"))
        #expect(typed.isEmpty && cleared == 0)
        #expect(SteerInbox.pending(tty: agent.tty, root: root).map(\.text) == ["go on"])
        // Its turn over and its box empty: typed in.
        #expect(LeadDelivery.flush(agent, betweenTurns: true, inputIsEmpty: { true }, typeInto: { typed.append($0); return true }, root: root))
        #expect(typed == [LeadDelivery.typed("go on", from: .lead("lead"))])
        #expect(SteerInbox.pending(tty: agent.tty, root: root).isEmpty)
    }

    /// No screen to read (not a window session, or the host didn't answer), or one that shows no composer (a dialog):
    /// nothing typed, and the lead isn't told it gets it at its next step.
    @Test func aWorkingCodexWhoseBoxCantBeReadWaitsForTheTurnsEnd() throws {
        let root = temp.url("inbox")
        let agent = codex("ttys953")
        var typed: [String] = []
        #expect(try LeadDelivery.deliver("a", from: .lead("lead"), to: agent, activity: .working(nil), styledScreen: nil,
                                         typeInto: { typed.append($0); return true }, root: root) == .atTurnEnd(draft: nil))
        #expect(try LeadDelivery.deliver("b", from: .lead("lead"), to: agent, activity: .working(nil), styledScreen: { nil },
                                         typeInto: { typed.append($0); return true }, root: root) == .atTurnEnd(draft: nil))
        let dialog = LeadDelivery.Screen(text: "Allow command?\n\n› 1. Yes, proceed\n  2. No\n\n  Press enter to confirm")
        #expect(try LeadDelivery.deliver("c", from: .lead("lead"), to: agent, activity: .working(nil), styledScreen: { dialog },
                                         typeInto: { typed.append($0); return true }, root: root) == .atTurnEnd(draft: nil))
        #expect(typed.isEmpty)
        #expect(SteerInbox.pending(tty: agent.tty, root: root).map(\.text) == ["a", "b", "c"])
    }

    /// The tool server finds the session's agent in the process table (`HostRuntime.steer`, through
    /// `LeadAgent.running`): a Codex there is said to be Codex, so its message is typed in, not left in its inbox.
    @Test func theAgentFoundOnAWorkersTerminalSaysItsCodexAndGetsTheMessageTyped() throws {
        let root = temp.url("inbox")
        let started = Date(timeIntervalSince1970: 1_793_690_000)
        let processes: [Int32: ProcInfo] = [
            900: ProcInfo(pid: 900, ppid: 1, tty: "ttys955", comm: "zsh", startTime: started, agent: nil),
            901: ProcInfo(pid: 901, ppid: 900, tty: "ttys955", comm: "codex", startTime: started + 1, agent: .codex),
            // A Codex it runs as a tool is not the session's agent.
            902: ProcInfo(pid: 902, ppid: 901, tty: "ttys955", comm: "codex", startTime: started + 30, agent: .codex),
            903: ProcInfo(pid: 903, ppid: 1, tty: "ttys956", comm: "claude", startTime: started, agent: .claude),
        ]
        let agent = try #require(LeadAgent.running(on: "ttys955", session: "s", in: processes))
        #expect(agent == LeadAgent(pid: 901, tty: "ttys955", session: "s", agent: .codex))
        #expect(LeadAgent.running(on: "ttys956", session: nil, in: processes)?.agent == .claude)
        #expect(LeadAgent.running(on: "ttys957", session: nil, in: processes) == nil)
        let empty = try working()
        var typed: [String] = []
        #expect(try LeadDelivery.deliver("go on", from: .lead("lead"), to: agent, activity: .working("Bash"), styledScreen: { empty },
                                         typeInto: { typed.append($0); return true }, pause: {}, root: root) == .typedWhileWorking)
        #expect(typed.count == 1 && SteerInbox.pending(tty: agent.tty, root: root).isEmpty)
    }

    /// Typed mid-turn but not submitted, it stays in the box; sent again (auto_advance retries with clear_draft), it
    /// isn't put in the inbox too, where it would go in a second time: still not submitted, and said so.
    @Test func aMessageLeftUnsubmittedInAWorkingCodexsBoxIsntQueuedASecondTime() throws {
        let root = temp.url("inbox")
        let agent = codex("ttys958")
        let prompt = LeadDelivery.typed("go on", from: .lead("lead"))
        let held = try working(composer: ["› " + prompt])
        var typed: [String] = []
        var cleared = 0
        let delivered = try LeadDelivery.deliver("go on", from: .lead("lead"), to: agent, activity: .working("Bash"), styledScreen: { held },
                                                 typeInto: { typed.append($0); return true }, clearDraft: true,
                                                 clear: { cleared += 1; return true }, pause: {}, root: root)
        #expect(delivered == .notSubmitted(prompt))
        #expect(typed.isEmpty && cleared == 0 && SteerInbox.pending(tty: agent.tty, root: root).isEmpty)
    }

    /// A working Claude still gets it through its hook at its next step: steered, never typed.
    @Test func aWorkingClaudeIsStillSteered() throws {
        let root = temp.url("inbox")
        let agent = LeadAgent(pid: 4243, tty: "ttys954", session: UUID().uuidString, agent: .claude)
        var typed: [String] = []
        #expect(try LeadDelivery.deliver("x", from: .lead("lead"), to: agent, activity: .working("Bash"), styledScreen: { try? self.working() },
                                         typeInto: { typed.append($0); return true }, root: root) == .steered)
        #expect(typed.isEmpty && SteerInbox.pending(tty: agent.tty, root: root).count == 1)
    }
}
