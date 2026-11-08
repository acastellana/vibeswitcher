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

    /// Another message of the lead's left unsubmitted in the box isn't this one, though both start with the same
    /// marker (`[VibeSwitcher · from lead of …, not the user]`, longer than what `holds` compares): this one waits in
    /// the inbox for the turn's end, and isn't said to be in the box.
    @Test func anotherLeadMessageInAWorkingCodexsBoxDoesntSwallowThisOne() throws {
        let root = temp.url("inbox")
        let agent = codex("ttys959")
        let earlier = LeadDelivery.typed("Run the lints before you report.", from: .lead("lead of wallet-manager"))
        let held = try working(composer: ["› " + earlier])
        var typed: [String] = []
        let delivered = try LeadDelivery.deliver("Yes: merge it into main.", from: .lead("lead of wallet-manager"), to: agent,
                                                 activity: .working("Bash"), styledScreen: { held },
                                                 typeInto: { typed.append($0); return true }, clearDraft: true, pause: {}, root: root)
        #expect(delivered == .atTurnEnd(draft: earlier))
        #expect(typed.isEmpty)
        #expect(SteerInbox.pending(tty: agent.tty, root: root).map(\.text) == ["Yes: merge it into main."])
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

/// The lead's message to a working Codex, end to end through a session host (F1 of this fix's audit): a fake Codex
/// on the host's pty draws Codex CLI 0.160's working screen (its status row, its composer with the faint
/// placeholder, its footer; see `codex-0.160-idle-120x40.json`) and takes keys as Codex does mid-turn: a bracketed
/// paste goes into its composer, and Enter hands the composer's text to the running turn (logged), which goes on. Its
/// hooks' last event is PreToolUse, folded as `vibeswitcher-hook` folds it. The message goes through what the tool server
/// does (`HostRuntime.steer`): the agent found on the terminal, its activity read from its hooks, the styled screen
/// and the typing through the host. A scratch host and a fake program only, never a real session.
struct CodexMidTurnHostRunTests {
    let temp = Scratch()

    /// A stand-in for Codex mid-turn, in bash (run under the name `codex`, so the process scan takes it for Codex).
    /// Logs in its folder: `composer.log` (its composer's text as each paste ends), `taken.log` (what Enter handed to
    /// its turn), `interrupts.log` (a ^C or a bare Esc: either stops a real Codex's turn). bash's `read -n1` turns the
    /// terminal's CR into LF, so Enter is either.
    static let fakeCodex = #"""
    dir="$1"
    stty raw -echo 2>/dev/null
    box=""; taken=""; paste=0
    draw() {
      printf '\033[H\033[2J'
      printf '\342\200\272 Start on your task.\r\n\r\n'
      printf '\342\200\242 Ran git status --short\r\n  \342\224\224 (no output)\r\n\r\n'
      [ -n "$taken" ] && printf '%s' "$taken"
      printf '\342\200\242 Working (41s \342\200\242 esc to interrupt)\r\n\r\n'
      if [ -z "$box" ]; then printf '\342\200\272 \033[2mAsk Codex to do anything\033[22m\r\n'; else printf '\342\200\272 %s\r\n' "$box"; fi
      printf '\r\n  gpt-5.1 medium \302\267 ~/repo\r\n  ? for shortcuts'
    }
    draw
    while IFS= read -r -s -n1 -d '' c; do
      case "$c" in
        $'\033')
          IFS= read -r -s -n1 -d '' n
          if [ "$n" = "[" ]; then
            seq=""
            while IFS= read -r -s -n1 -d '' k; do seq="$seq$k"; case "$k" in [@-~]) break;; esac; done
            case "$seq" in
              200~) paste=1 ;;
              201~) paste=0; printf '%s\n' "$box" >> "$dir/composer.log"; draw ;;
            esac
          else
            echo esc >> "$dir/interrupts.log"
          fi ;;
        $'\r'|$'\n')
          if [ "$paste" = 1 ]; then box="$box "
          elif [ -n "$box" ]; then
            taken="$taken$(printf '\342\200\272') $box"$'\r\n\r\n'
            printf '%s\n' "$box" >> "$dir/taken.log"; box=""; draw
          fi ;;
        $'\003') echo ctrl-c >> "$dir/interrupts.log"; box=""; draw ;;
        *) box="$box$c"; [ "$paste" = 0 ] && draw ;;
      esac
    done
    """#

    @Test func aWorkingFakeCodexGetsTheLeadsMessageInItsComposerAndTakesItIntoItsTurn() async throws {
        let dir = temp.url("codex-midturn")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("codex.sh").path
        try Self.fakeCodex.write(toFile: script, atomically: true, encoding: .utf8)
        let log = { (name: String) in (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }

        let host = try TestHost()
        let client = try TestClient(host)
        let session = try await client.spawn("exec /bin/bash -c \"exec -a codex /bin/bash '\(script)' '\(dir.path)'\"", cwd: dir.path)
        let id = session.id
        defer { _ = client.send(.kill(id: id)) }
        let screen = { HostCall.styledScreen(id, socket: host.socket, appKey: host.appKey) }
        // Drawn: working, its composer empty (its placeholder faint, so not typed text).
        #expect(await eventually { screen().map { $0.text.contains("Working") && LeadDelivery.box(in: $0) == .empty } ?? false },
                "screen:\n\(screen()?.text ?? "none")")

        // The agent on its terminal, as the tool server finds it: Codex.
        var found: LeadAgent?
        #expect(await eventually {
            found = ProcessTable.trySnapshot().flatMap { LeadAgent.running(on: session.tty, session: id.uuidString, in: $0) }
            return found?.agent == .codex
        }, "found \(String(describing: found)) on \(session.tty)")
        let agent = try #require(found)

        // Its hooks' last event: PreToolUse, folded as the hook folds it, in a scratch state file.
        let stateFile = dir.appendingPathComponent("state.json")
        let payload: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "Bash", "session_id": "s", "cwd": dir.path,
                                      "tool_input": ["command": "swift build"]]
        guard case .write(let state) = HookState.reduce(current: nil, payload: payload, agent: .codex, tty: session.tty,
                                                         agentPid: agent.pid, now: Date().timeIntervalSince1970) else {
            Issue.record("PreToolUse wasn't folded into a state"); return
        }
        try state.save(to: stateFile)
        let observer = LeadObserver(home: dir.path, stateFile: { _ in stateFile })
        let activity = observer.activity(session, agentPid: agent.pid)
        guard case .working = activity else { Issue.record("not working: \(activity.text)"); return }

        // Delivered as `HostRuntime.steer` delivers it.
        let text = "Yes: merge it into main."
        let prompt = LeadDelivery.typed(text, from: .lead("lead of wallet-manager"))
        var cleared = 0
        var waited = false
        // The delivery blocks (its pauses, its host calls): on a thread of its own, not the cooperative pool.
        let delivered = try await offPool { try LeadDelivery.deliver(
            text, from: .lead("lead of wallet-manager"), to: agent, activity: activity, styledScreen: screen,
            typeInto: { (try? HostCall.type(ComposerText.writes($0, bracketed: true), into: id, socket: host.socket, appKey: host.appKey)) != nil },
            clearDraft: true, clear: { cleared += 1; return true },
            enter: { (try? HostCall.type([HostInput.Write(bytes: [13], delay: 0)], into: id, socket: host.socket, appKey: host.appKey)) != nil },
            turnStarted: { observer.activity(session, agentPid: agent.pid).betweenTurns == false },
            // Before its first read of the box: until the fake has taken it (the event this checks), at most one hang
            // guard; its later reads follow at once.
            pause: {
                guard !waited else { return }
                waited = true
                let deadline = Date().addingTimeInterval(hangGuard)
                while !log("taken.log").contains(prompt), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            },
            root: dir.appendingPathComponent("inbox")) }
        try #require(delivered == .typedWhileWorking)
        // It arrived in its composer, and Enter handed it to the running turn: once, nothing left in the inbox, and
        // its turn never interrupted (no ^C, no Esc).
        #expect(await eventually { log("taken.log") == prompt + "\n" }, "taken: \(log("taken.log"))")
        #expect(log("composer.log") == prompt + "\n")
        #expect(log("interrupts.log").isEmpty && cleared == 0)
        #expect(SteerInbox.pending(tty: agent.tty, root: dir.appendingPathComponent("inbox")).isEmpty)
        // Still working, its composer empty again, the message in its transcript (wrapped at 80 columns).
        #expect(await eventually { screen().map { $0.text.contains("Working") && LeadDelivery.box(in: $0) == .empty && $0.text.contains("Yes: merge it into") } ?? false },
                "screen:\n\(screen()?.text ?? "none")")
    }
}
