import Foundation
import Testing
@testable import VibeCore

/// What the lead's tools read on 2026-10-17, 16:13–16:20 local, about the worker on evaluate-ux-and-visual (window
/// session DCF162BD…, Claude session 3dcd0848…): its hooks' state file kept vanishing (the app's scan didn't take
/// its terminal for an agent's and deleted the file 15 s after each write), so `sessions` said "running", the lead
/// strip "idle", read_session "No conversation yet", and message typed a prompt into it mid-turn.
enum Recorded {
    static let windowSession = "DCF162BD-6957-4E59-929E-DCFA81409F03"
    static let claudeSession = "3dcd0848-1dc1-40e2-8974-791de5921ffd"
    static let cwd = "/Users/albert/dev/vibeswitcher/.vibeswitcher/worktrees/evaluate-ux-and-visual"
    static let startedAt = date("2026-10-17T14:13:05Z")

    /// Its transcript as it stood at 14:20:02–14:20:28 (lines trimmed): the last step is a tool's result at
    /// 14:19:22; the model's next step (a 90 s Write) was still being written. The rest is Claude's bookkeeping.
    static let uxTranscript = """
    {"type":"last-prompt","leafUuid":"b6a452bc-7e24-46cb-b54b-9cb1624c4e49","sessionId":"3dcd0848-1dc1-40e2-8974-791de5921ffd"}
    {"type":"custom-title","customTitle":"worker-evaluate-ux-and-visual","sessionId":"3dcd0848-1dc1-40e2-8974-791de5921ffd"}
    {"type":"agent-name","agentName":"worker-evaluate-ux-and-visual","sessionId":"3dcd0848-1dc1-40e2-8974-791de5921ffd"}
    {"parentUuid":"6a08ca11-aeb4-4a81-9ab7-7cc79d81505e","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_011Cg7xMZct8efyNU1fhDqyH","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_018YmZnXovjA4CTWNaM8EqBn","name":"Bash","input":{"command":"sed -n 1,80p Sources/VibeCore/WindowGroups.swift | cut -c1-200","description":"Read WindowGroups row title/state"}}],"stop_reason":"tool_use","stop_sequence":null},"type":"assistant","uuid":"2ebd397f-b65f-4f56-a170-c4d52b095025","timestamp":"2026-10-17T14:19:22.651Z","sessionId":"3dcd0848-1dc1-40e2-8974-791de5921ffd","version":"2.1.302"}
    {"parentUuid":"2ebd397f-b65f-4f56-a170-c4d52b095025","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_018YmZnXovjA4CTWNaM8EqBn","type":"tool_result","content":"import Foundation\\n\\n/// How the window's session list is grouped.","is_error":false}]},"uuid":"7f466767-538c-40f9-875f-efebea4bfdea","timestamp":"2026-10-17T14:19:22.944Z","sessionId":"3dcd0848-1dc1-40e2-8974-791de5921ffd"}
    {"type":"api-request-blob","sessionId":"3dcd0848-1dc1-40e2-8974-791de5921ffd","hash":"ea049e21","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_018YmZnXovjA4CTWNaM8EqBn","name":"Bash","input":{}}]}}
    {"type":"custom-title","customTitle":"worker-evaluate-ux-and-visual","sessionId":"3dcd0848-1dc1-40e2-8974-791de5921ffd"}
    {"type":"agent-name","agentName":"worker-evaluate-ux-and-visual","sessionId":"3dcd0848-1dc1-40e2-8974-791de5921ffd"}
    {"parentUuid":"7f466767-538c-40f9-875f-efebea4bfdea","isSidechain":false,"attachment":{"type":"total_tokens_reminder","text":"<total_tokens>14708748 tokens left</total_tokens>"},"type":"attachment","uuid":"5030d92a-2f24-47e4-b4dc-1ec62b4fe997","timestamp":"2026-10-17T14:19:22.990Z","sessionId":"3dcd0848-1dc1-40e2-8974-791de5921ffd"}
    {"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-17T14:20:08.931Z","sessionId":"3dcd0848-1dc1-40e2-8974-791de5921ffd","content":"[VibeSwitcher · from lead of vibeswitcher, not the user] Start your task now"}

    """

    /// The phone-and-remote worker's turn at 17:56 (bc2907f2…, trimmed): it ended on an API error mid-task.
    static let apiErrorTranscript = """
    {"parentUuid":"0b4bd8f2-0a86-4ab5-b6a1-d1c1b8f0c4a0","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01","type":"tool_result","content":"ok","is_error":false}]},"uuid":"ed4d6cb5-a927-4914-98cc-f37700b3bfcb","timestamp":"2026-10-17T17:55:58.120Z"}
    {"parentUuid":"ed4d6cb5-a927-4914-98cc-f37700b3bfcb","isSidechain":false,"type":"assistant","uuid":"ea09153c-5b98-460d-8f38-2a4f47f0c716","timestamp":"2026-10-17T17:56:41.012Z","message":{"id":"9f46103d-5162-4fbe-b6ea-d3ecc325554e","model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","content":[{"type":"text","text":"API Error: Connection lost mid-response. The response above may be incomplete."}]},"error":"server_error","isApiErrorMessage":true,"sessionId":"bc2907f2-1cd3-4359-8117-91c97aca7079"}
    {"parentUuid":"ea09153c-5b98-460d-8f38-2a4f47f0c716","isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":2843117,"timestamp":"2026-10-17T17:56:41.034Z","uuid":"3c1b9a1e-6c43-4f0e-9a51-5d0d4a5e7f11","isMeta":false}

    """

    /// A turn that ended normally: the reply, then Claude's end-of-turn lines.
    static let finishedTranscript = """
    {"isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"2026-10-17T15:02:10.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done: committed and reported."}]}}
    {"isSidechain":false,"type":"system","subtype":"stop_hook_summary","timestamp":"2026-10-17T15:02:10.050Z","uuid":"a2"}
    {"isSidechain":false,"type":"system","subtype":"turn_duration","timestamp":"2026-10-17T15:02:10.060Z","uuid":"a3"}
    {"isSidechain":false,"type":"system","subtype":"away_summary","timestamp":"2026-10-17T15:12:10.000Z","uuid":"a4"}

    """

    static func date(_ text: String) -> Date { ChatReader.date(text)! }

    /// The hooks' state as `vibeswitcher-hook` folds these payloads into it, in order, at those times.
    static func hook(_ events: [(at: String, payload: [String: Any])], pid: Int32 = 46336) -> HookState? {
        var state: HookState?
        for event in events {
            switch HookState.reduce(current: state, payload: event.payload, agent: .claude, tty: "ttys006", agentPid: pid,
                                    now: date(event.at).timeIntervalSince1970) {
            case .write(let next): state = next
            case .delete: state = nil
            case .ignore: break
            }
        }
        return state
    }

    static func payload(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["hook_event_name": event, "session_id": claudeSession, "cwd": cwd,
         "transcript_path": "/Users/albert/.claude/projects/x/\(claudeSession).jsonl"].merging(extra) { $1 }
    }
}

struct TranscriptTailTests {
    @Test func midTurnWhileAToolsResultIsBeingWorkedOn() throws {
        let tail = try #require(TranscriptTail.read(Data(Recorded.uxTranscript.utf8)))
        #expect(tail.state == .thinking)
        #expect(tail.midTurn)
        #expect(tail.at == Recorded.date("2026-10-17T14:19:22.944Z").timeIntervalSince1970)
    }

    @Test func aTurnThatEndedOnAnAPIErrorSaysSo() throws {
        let tail = try #require(TranscriptTail.read(Data(Recorded.apiErrorTranscript.utf8)))
        #expect(tail.state == .turnOver(apiError: "API Error: Connection lost mid-response. The response above may be incomplete."))
        #expect(tail.at == Recorded.date("2026-10-17T17:56:41.034Z").timeIntervalSince1970)
    }

    @Test func aFinishedTurnIsOverWhateverNoticesFollow() throws {
        let tail = try #require(TranscriptTail.read(Data(Recorded.finishedTranscript.utf8)))
        #expect(tail.state == .turnOver(apiError: nil))
        #expect(!tail.midTurn)
    }

    @Test func aPendingToolCallAndAnInterruptedTurn() throws {
        let call = """
        {"isSidechain":false,"type":"assistant","timestamp":"2026-10-17T15:00:00Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}
        {"isSidechain":true,"type":"assistant","timestamp":"2026-10-17T15:00:05Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"a subagent's reply"}]}}

        """
        #expect(TranscriptTail.read(Data(call.utf8))?.state == .toolCall)
        let interrupted = call + """
        {"isSidechain":false,"type":"user","timestamp":"2026-10-17T15:00:09Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}

        """
        #expect(TranscriptTail.read(Data(interrupted.utf8))?.state == .turnOver(apiError: nil))
        #expect(TranscriptTail.read(Data()) == nil)
    }
}

struct LeadActivityTests {
    /// Between hook events a tool runs and nothing fires. With the state file gone (as it was), or holding an
    /// event older than the transcript's last step, the transcript says it's mid-turn: working, not idle.
    @Test func workingWhileToolsRunBetweenHookEvents() throws {
        let tail = TranscriptTail.read(Data(Recorded.uxTranscript.utf8))
        #expect(LeadActivity.resolve(hook: nil, transcript: tail) == .working(nil))
        let preTool = Recorded.hook([("2026-10-17T14:13:12Z", Recorded.payload("SessionStart")),
                                     ("2026-10-17T14:13:13Z", Recorded.payload("UserPromptSubmit", ["prompt": "Start on your task"])),
                                     ("2026-10-17T14:19:22.600Z", Recorded.payload("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "sed -n 1,80p Sources/VibeCore/WindowGroups.swift"]]))])
        #expect(LeadActivity.resolve(hook: preTool, transcript: tail).betweenTurns == false)
        #expect(LeadActivity.resolve(hook: preTool, transcript: tail).text.hasPrefix("working"))
        // A state file left from a turn that's long over doesn't make it idle either.
        let stale = Recorded.hook([("2026-10-17T14:13:12Z", Recorded.payload("SessionStart"))])
        #expect(LeadActivity.resolve(hook: stale, transcript: tail) == .working(nil))
        // The old reading of the same facts: no state is "type it in".
        #expect(LeadDelivery.way(for: nil) == .type)
    }

    @Test func aPromptOnScreenStandsOverTheCallThatRaisedIt() {
        let call = TranscriptTail(state: .toolCall, at: 100.2)
        var asking = HookState(agent: .claude, tty: "ttys006", lastEvent: "PermissionRequest", lastEventAt: 100)
        asking.request = "Run: rm -rf build"
        #expect(LeadActivity.resolve(hook: asking, transcript: call) == .needsInput("Run: rm -rf build"))
        // Its answer comes back as the tool's result: working again.
        #expect(LeadActivity.resolve(hook: asking, transcript: TranscriptTail(state: .thinking, at: 130)) == .working(nil))
    }

    /// (i) The turn ended on "API Error", no Stop hook fired, and a minute later Claude's "waiting for your input"
    /// notice came: the lead was told "needs input". It's an API error, between turns.
    @Test func aTurnThatEndedOnAnAPIErrorIsReportedAsThat() {
        let tail = TranscriptTail.read(Data(Recorded.apiErrorTranscript.utf8))
        let hook = Recorded.hook([("2026-10-17T17:55:58Z", Recorded.payload("PostToolUse", ["tool_name": "Bash"])),
                                  ("2026-10-17T17:57:41Z", Recorded.payload("Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"]))])
        let activity = LeadActivity.resolve(hook: hook, transcript: tail)
        #expect(activity == .apiError("API Error: Connection lost mid-response. The response above may be incomplete."))
        #expect(activity.betweenTurns)
        #expect(activity.text.contains("API error") && !activity.text.contains("needs input"))
        #expect(LeadActivity.resolve(hook: nil, transcript: tail) == activity)
    }

    /// (h) Idle while its own background work runs: Claude's idle notice isn't a question, and the work shows.
    @Test func backgroundWorkReadsAsBackgroundNotNeedsInput() {
        let hook = Recorded.hook([("2026-10-17T15:02:09Z", Recorded.payload("Stop")),
                                  ("2026-10-17T15:02:30Z", Recorded.payload("UserPromptSubmit", ["prompt": "<task-notification>verification started</task-notification>"])),
                                  ("2026-10-17T15:03:30Z", Recorded.payload("Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"]))])
        let activity = LeadActivity.resolve(hook: hook, transcript: TranscriptTail.read(Data(Recorded.finishedTranscript.utf8)),
                                            background: "1 shell: swift test")
        #expect(activity == .idle(background: "1 shell: swift test"))
        #expect(activity.text.contains("background") && !activity.text.contains("needs input"))
    }

    @Test func nothingKnownIsUnknownNotIdle() {
        #expect(LeadActivity.resolve(hook: nil, transcript: nil) == .unknown)
        #expect(!LeadActivity.unknown.betweenTurns)
    }
}

struct LeadObserverTests {
    let temp = Scratch()
    func scratch() -> URL {
        let url = temp.url("observer")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    func write(_ text: String, to url: URL, modified: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    var worker: HostSession {
        HostSession(id: UUID(uuidString: Recorded.windowSession)!, tty: "ttys006", childPID: 46336, cwd: Recorded.cwd,
                    command: "claude --dangerously-skip-permissions --append-system-prompt-file '/Users/albert/.vibeswitcher/lead/run/x/worker-evaluate-ux-and-visual/prompt.md' --mcp-config '/m.json' --settings '/s.json' --name 'worker-evaluate-ux-and-visual' -- 'Start on your task (it'\\''s in your instructions). When done, call report.'",
                    label: "Worker: Evaluate UX and visual", agent: "claude", title: "", startedAt: Recorded.startedAt, cols: 120, rows: 40, exit: nil)
    }

    /// read_session found no conversation while the state file was gone. The transcript is named by Claude's own
    /// session id (3dcd0848…), not the window session's (DCF162BD…): it's found by the session's folder and name.
    @Test func transcriptFoundForAWorkerWhoseClaudeSessionIDDiffersFromTheWindowSessions() throws {
        let home = scratch()
        let folder = home.appendingPathComponent(".claude/projects/-Users-albert-dev-vibeswitcher--vibeswitcher-worktrees-evaluate-ux-and-visual")
        let mine = folder.appendingPathComponent("\(Recorded.claudeSession).jsonl")
        try write(Recorded.uxTranscript, to: mine, modified: Recorded.date("2026-10-17T14:20:02Z"))
        // An earlier worker on the same task (same name, before this session started), and its verifier, written later.
        try write(Recorded.uxTranscript, to: folder.appendingPathComponent("0f6c1b8e-2b40-4d43-9d55-1f2a1d1e0001.jsonl"),
                  modified: Recorded.date("2026-10-17T11:02:00Z"))
        try write(Recorded.finishedTranscript.replacingOccurrences(of: "\"a1\"", with: "\"a1\",\"agentName\":\"verify-evaluate-ux-and-visual\""),
                  to: folder.appendingPathComponent("7d1e5a2c-8f0b-4c5e-a0e4-9b3c2d1f0002.jsonl"), modified: Recorded.date("2026-10-17T14:20:05Z"))
        let observer = LeadObserver(home: home.path, stateFile: { home.appendingPathComponent("state/\($0).json") })

        #expect(observer.hook(worker, agentPid: 46336) == nil)
        let found = try #require(observer.transcript(worker, hook: nil))
        #expect(URL(fileURLWithPath: found).resolvingSymlinksInPath() == mine.resolvingSymlinksInPath())
        #expect(!found.contains(Recorded.windowSession))
        #expect(observer.activity(worker, agentPid: 46336) == .working(nil))
    }

    @Test func aStateFileFromAnotherAgentOnTheTerminalIsNotThisSessions() throws {
        let home = scratch()
        let stateFile = home.appendingPathComponent("state/ttys006.json")
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        var other = HookState(agent: .claude, tty: "ttys006", lastEvent: "Stop", lastEventAt: Recorded.date("2026-10-17T14:15:00Z").timeIntervalSince1970)
        other.agentPid = 999
        try other.save(to: stateFile)
        let observer = LeadObserver(home: home.path, stateFile: { _ in stateFile })
        #expect(observer.hook(worker, agentPid: 46336) == nil)
        #expect(observer.hook(worker, agentPid: 999) == other)
        // Written before this session started: an earlier agent's.
        other.lastEventAt = Recorded.date("2026-10-17T14:00:00Z").timeIntervalSince1970
        try other.save(to: stateFile)
        #expect(observer.hook(worker, agentPid: 999) == nil)
    }

    @Test func theLaunchNameIsReadBackFromTheCommand() throws {
        let prepared = try LeadLaunch.prepare(role: .worker, root: "/tmp/r", task: "t", base: "claude", prompt: "p", start: "go",
                                              server: "/s", name: "worker-t",
                                              folder: temp.url("launch"))
        #expect(LeadLaunch.name(inCommand: prepared.command) == "worker-t")
        #expect(LeadLaunch.name(inCommand: "claude") == nil)
    }
}

struct LeadDeliveryByActivityTests {
    let temp = Scratch()
    func scratch() -> URL { temp.url("deliver") }

    let empty = """
    ✻ Cogitated for 10s · done 1:17 AM
    ──────────────────────────────────────────── worker-one ─
    ❯
    ────────────────────────────────────────────────────────────
      [Opus 5.5] ███░░░░░░░ 30% | one git:(agent/one)
    """

    func screen(_ box: String) -> String { empty.replacingOccurrences(of: "❯", with: "❯ \(box)") }

    /// (d) message() to the busy worker typed it in (Claude queued it as a prompt). Mid-turn, its box looks empty,
    /// but the message is steered: it gets it at its next step, and nothing is typed.
    @Test func aMidTurnWorkerIsSteeredNeverTyped() throws {
        let root = scratch()
        let agent = LeadAgent(pid: 46336, tty: "ttys006", session: Recorded.windowSession)
        var typed: [String] = []
        let activity = LeadActivity.resolve(hook: nil, transcript: TranscriptTail.read(Data(Recorded.uxTranscript.utf8)))
        let delivered = try LeadDelivery.deliver("Start your task now", from: .lead("lead of vibeswitcher"), to: agent, activity: activity,
                                                 screen: { self.empty }, typeInto: { typed.append($0); return true }, root: root)
        #expect(delivered == .steered)
        #expect(typed.isEmpty)
        #expect(SteerInbox.pending(tty: "ttys006", root: root).map(\.text) == ["Start your task now"])
        // Nothing known about it: steered too.
        #expect(try LeadDelivery.deliver("x", from: .user, to: agent, activity: .unknown, screen: { self.empty },
                                         typeInto: { typed.append($0); return true }, root: root) == .steered)
        #expect(typed.isEmpty)
    }

    @Test func betweenTurnsItsTypedIntoAnEmptyBox() throws {
        let root = scratch()
        let agent = LeadAgent(pid: 7, tty: "ttys903", session: "s")
        var typed: [String] = []
        #expect(try LeadDelivery.deliver("go on", from: .lead("lead"), to: agent, activity: .apiError("API Error: x"), screen: { self.empty },
                                         typeInto: { typed.append($0); return true }, root: root) == .typed)
        // Claude's dim placeholder is an empty box.
        #expect(try LeadDelivery.deliver("next", from: .lead("lead"), to: agent, activity: .idle(background: nil),
                                         screen: { self.screen("Try \"refactor <filepath>\"") }, typeInto: { typed.append($0); return true }, root: root) == .typed)
        #expect(typed.count == 2 && typed[0].hasSuffix("go on"))
        #expect(SteerInbox.pending(tty: agent.tty, root: root).isEmpty)
    }

    /// (f) The box wasn't free and the message never got in. It says what's in the box; a draft can be cleared
    /// (when asked) and the message typed; a prompt on screen gets it at its next step once answered.
    @Test func whatHoldsTheBoxIsSaid() throws {
        let root = scratch()
        let agent = LeadAgent(pid: 7, tty: "ttys904", session: "s")
        var typed: [String] = []
        let type: (String) -> Bool = { typed.append($0); return true }
        let draft = screen("half-written note")
        #expect(try LeadDelivery.deliver("a", from: .lead("lead"), to: agent, activity: .idle(background: nil), screen: { draft },
                                         typeInto: type, root: root) == .behindDraft("half-written note"))
        var shown = draft
        var cleared = 0
        #expect(try LeadDelivery.deliver("b", from: .lead("lead"), to: agent, activity: .idle(background: nil), screen: { shown },
                                         typeInto: type, clearDraft: true, clear: { cleared += 1; shown = self.empty; return true }, root: root) == .typed)
        #expect(cleared == 1 && typed.count == 1 && typed[0].hasSuffix("b"))
        // A draft that doesn't clear stays, and the message waits behind it.
        #expect(try LeadDelivery.deliver("c", from: .lead("lead"), to: agent, activity: .idle(background: nil), screen: { draft },
                                         typeInto: type, clearDraft: true, clear: { false }, root: root) == .draftStayed(before: "half-written note", after: nil))
        // genswap, 10-18: a host too old to say what's dim showed Claude's suggestion as text; ^C emptied the box and
        // Claude drew the same suggestion again. The same text back after the ^C is that suggestion: typed over.
        let suggestion = screen("open rotate.html so I can try it")
        var clears = 0
        #expect(try LeadDelivery.deliver("c1", from: .lead("lead"), to: agent, activity: .idle(background: nil), screen: { suggestion },
                                         typeInto: type, clearDraft: true, clear: { clears += 1; return true }, root: root) == .typed)
        #expect(clears == 1 && typed.count == 2 && typed[1].hasSuffix("c1"))
        typed.removeLast()
        // Something else in the box after the ^C: said, not typed over.
        shown = draft
        #expect(try LeadDelivery.deliver("c2", from: .lead("lead"), to: agent, activity: .idle(background: nil), screen: { shown },
                                         typeInto: type, clearDraft: true, clear: { shown = self.screen("another note"); return true }, root: root)
                == .draftStayed(before: "half-written note", after: "another note"))
        #expect(typed.count == 1)
        let dialog = """
         Bash command
           rm -rf build
         Do you want to proceed?
         ❯ 1. Yes
           2. No, and tell Claude what to do differently (esc)
        """
        if case .awaitingAnswer(let lines)? = try? LeadDelivery.deliver("d", from: .lead("lead"), to: agent, activity: .idle(background: nil),
                                                                       screen: { dialog }, typeInto: type, root: root) {
            #expect(lines?.contains("Do you want to proceed?") == true)
        } else {
            Issue.record("a dialog on screen should hold the message for its answer")
        }
        #expect(try LeadDelivery.deliver("e", from: .lead("lead"), to: agent, activity: .needsInput("Run: rm -rf build"), screen: { dialog },
                                         typeInto: type, root: root) == .awaitingAnswer("Run: rm -rf build"))
        #expect(typed.count == 1)
        #expect(SteerInbox.pending(tty: agent.tty, root: root).map(\.text) == ["a", "c", "c2", "d", "e"])
    }

    /// launch-video, 2026-10-27 (worker session 8D1B0D7B, between turns since 2026-10-26 16:27): message() typed the
    /// lead's prompt into its empty box and said "Typed into launch-video's worker as its next prompt", but the Enter
    /// didn't submit it: the prompt sat in the box as a draft, and sessions still said "finished its turn". The resend
    /// with clear_draft cleared it, typed it again, and said the same while it sat there again. A prompt the box keeps
    /// isn't said to be typed.
    @Test func aPromptLeftInTheBoxIsntSaidToBeTyped() throws {
        let root = scratch()
        let agent = LeadAgent(pid: 7, tty: "ttys905", session: "8D1B0D7B-0000-0000-0000-000000000000")
        var shown = empty
        var typed: [String] = []
        // The keys go out, and the text stays in the box: its Enter wasn't taken.
        let type: (String) -> Bool = { typed.append($0); shown = self.screen($0); return true }
        let first = try LeadDelivery.deliver("Re-render the narrated cut", from: .lead("lead of vibeswitcher"), to: agent,
                                             activity: .idle(background: nil), screen: { shown }, typeInto: type, root: root)
        #expect(typed.count == 1)
        #expect(first != .typed)
        let again = try LeadDelivery.deliver("Re-render the narrated cut", from: .lead("lead of vibeswitcher"), to: agent,
                                             activity: .idle(background: nil), screen: { shown }, typeInto: type, clearDraft: true,
                                             clear: { shown = self.empty; return true }, root: root)
        #expect(typed.count == 2)
        #expect(again != .typed)
    }

    @Test func theBoxIsRead() {
        #expect(LeadDelivery.box(in: empty) == .empty)
        #expect(LeadDelivery.box(in: screen("fix the\nlogin")) == .draft("fix the\nlogin"))
        if case .dialog = LeadDelivery.box(in: "Do you want to proceed?\n❯ 1. Yes") {} else { Issue.record("no box is a dialog") }
    }

    /// With how the screen is drawn, what's dim in the box isn't typed (see StyledScreenTests for Claude's own bytes).
    @Test func whatsDrawnDimInTheBoxIsntTyped() {
        let shown = screen("delete the old lane renders")   // the box is row 2, the text from column 2
        let row = 2
        #expect(LeadDelivery.box(in: shown) == .draft("delete the old lane renders"))
        #expect(LeadDelivery.box(in: shown, runs: []) == .draft("delete the old lane renders"))
        #expect(LeadDelivery.box(in: shown, runs: [ScreenRun(row: row, column: 2, length: 27, faint: true)]) == .empty)
        // Grey instead of faint, in each colour form; a caret painted on the first character.
        for color in [ScreenRun.Color.rgb(153, 153, 153), .palette(8), .palette(244)] {
            #expect(LeadDelivery.box(in: shown, runs: [ScreenRun(row: row, column: 2, length: 1, inverse: true),
                                                         ScreenRun(row: row, column: 3, length: 26, color: color)]) == .empty)
        }
        // Coloured, not grey: typed (a highlighted @file, say).
        #expect(LeadDelivery.box(in: shown, runs: [ScreenRun(row: row, column: 2, length: 27, color: .rgb(153, 204, 255))])
                == .draft("delete the old lane renders"))
        // A caret on typed text is typed text.
        #expect(LeadDelivery.box(in: shown, runs: [ScreenRun(row: row, column: 2, length: 1, inverse: true)]) == .draft("delete the old lane renders"))
        // A command's dim argument hint follows what's typed.
        let command = screen("/review <pr>")
        #expect(LeadDelivery.box(in: command, runs: [ScreenRun(row: row, column: 9, length: 5, faint: true)]) == .draft("/review"))
        // Knowing how it's drawn, words that look like the placeholder but aren't dim are typed.
        #expect(LeadDelivery.box(in: screen("Try \"x\""), runs: []) == .draft("Try \"x\""))
        #expect(LeadDelivery.box(in: screen("Try \"x\"")) == .empty)
    }
}

struct LeadWitnessStopsAndErrorsTests {
    func task(_ slug: String, _ status: LeadTask.Status, worker: String?) -> LeadTask {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = status
        task.worker = worker
        return task
    }

    /// (g) stop_worker on a task whose audit failed, then start_worker: the stopped worker's hangup (exit 129) was
    /// reported as a death. The lead stopped it; that's no news.
    @Test func aWorkerTheLeadStoppedIsntReportedAsDead() {
        var board = LeadBoard()
        var stopped = task("phone-and-remote", .failed, worker: "w1")
        stopped.stopped = "w1"
        board.tasks = [stopped, task("other", .failed, worker: "w2")]
        let events = LeadWitness.events(board: board, seen: ["w1": .init(live: false, exit: 129), "w2": .init(live: false, exit: 129)])
        #expect(events.map(\.key) == ["w2|ended"])
        // Started again: the new worker is watched as any.
        board.tasks[0].worker = "w3"
        #expect(LeadWitness.events(board: board, seen: ["w3": .init(live: false, exit: 1)]).map(\.key).contains("w3|ended"))
    }

    /// 2026-10-17: a stray pkill ended 3 workers and 2 verifiers at once, and the lead got 5 messages that each said
    /// "exit 143". Now: one message naming every ended task and how it ended, and how to start each again.
    @Test func sessionsThatEndTogetherAreToldInOneMessage() {
        var board = LeadBoard()
        let a = task("a", .running, worker: "w-a"), b = task("b", .running, worker: "w-b"), c = task("c", .failed, worker: "w-c")
        var d = task("d", .review, worker: "w-d"), e = task("e", .review, worker: "w-e")
        d.verifier = "v-d"
        e.verifier = "v-e"
        board.tasks = [a, b, c, d, e]
        let at = Date()
        let seen: [String: LeadWitness.Seen] = [
            "w-a": .init(live: false, exit: 143, cause: HostSession.Exit(status: 143, at: at, signal: 15).cause),
            "w-b": .init(live: false, exit: 143, cause: HostSession.Exit(status: 143, at: at).cause),
            "w-c": .init(live: true, agentQuit: true),
            "v-d": .init(live: false, exit: 143, cause: HostSession.Exit(status: 143, at: at, signal: 15).cause),
            "v-e": .init(live: false, exit: 129, cause: HostSession.Exit(status: 129, at: at, signal: 1, killedBy: 77, killedByName: "zsh").cause),
            "w-d": .init(live: false, exit: 0), "w-e": .init(live: false, exit: 0),   // reported: their tasks are in review
        ]
        var told: Set<String> = []
        let messages = LeadWitness.messages(board: board, seen: seen, told: { told.contains($0) })
        #expect(messages.count == 1)
        let message = messages[0]
        #expect(Set(message.keys) == ["w-a|ended", "w-b|ended", "w-c|ended", "v-d|ended", "v-e|ended"])
        for line in ["worker on a: killed by SIGTERM", "worker on b: exited 143", "worker on c: its agent quit",
                     "verifier on d: killed by SIGTERM", "verifier on e: killed by SIGHUP from pid 77 (zsh)"] {
            #expect(message.text.contains(line), "\(line)")
        }
        #expect(message.text.hasPrefix("5 sessions ended without reporting"))
        #expect(message.text.contains("start_worker") && message.text.contains("audit"))
        // Told: not again; one more ending later is told on its own, the way one always was.
        told.formUnion(message.keys)
        #expect(LeadWitness.messages(board: board, seen: seen, told: { told.contains($0) }).isEmpty)
        board.tasks.append(task("f", .running, worker: "w-f"))
        var later = seen
        later["w-f"] = .init(live: false, exit: 143, cause: HostSession.Exit(status: 143, at: at, signal: 15).cause)
        let alone = LeadWitness.messages(board: board, seen: later, told: { told.contains($0) })
        #expect(alone.map(\.keys) == [["w-f|ended"]])
        #expect(alone.first?.text.hasPrefix("The worker on f ended (killed by SIGTERM) without reporting.") == true)
        #expect(alone.first?.text.contains("start_worker") == true)
    }

    /// (i) A turn that ended on an API error reaches the lead as that, with what to do.
    @Test func anAPIErrorIsToldAsOne() {
        let now = Date()
        var board = LeadBoard()
        board.tasks = [task("phone-and-remote", .running, worker: "w1")]
        let error = "API Error: The response stopped arriving"
        let events = LeadWitness.events(board: board, seen: ["w1": .init(live: true, status: .needsInput, since: now - 60,
                                                                         apiError: error, apiErrorAt: 1_792_259_801)], now: now)
        #expect(events.count == 1)
        // Its status flipping later (Claude's idle notice) is the same error, told once.
        let later = LeadWitness.events(board: board, seen: ["w1": .init(live: true, status: .done, since: now, apiError: error,
                                                                        apiErrorAt: 1_792_259_801)], now: now)
        #expect(later.map(\.key) == events.map(\.key))
        #expect(events[0].text.contains("API error") && events[0].text.contains("The response stopped arriving"))
        #expect(events[0].text.contains("message(phone-and-remote"))
        #expect(!events[0].text.contains("waiting for input"))
    }
}

struct LeadMessageToolTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    @Test func messageSaysWhatHoldsTheBoxAndCanClearADraft() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "one"])
        runtime.delivery = .behindDraft("half-written note")
        let held = lead.call("message", ["task": "one", "text": "go on"]).text
        #expect(held.contains("half-written note") && held.contains("clear_draft"))
        runtime.delivery = .awaitingAnswer("Run: make clean")
        let prompt = lead.call("message", ["task": "one", "text": "go on"]).text
        #expect(prompt.contains("Run: make clean") && prompt.contains("next step"))
        runtime.delivery = .typed
        #expect(!lead.call("message", ["task": "one", "text": "go on", "clear_draft": true]).isError)
        #expect(runtime.clearedDrafts == 1)
        // Typed only when it's between turns; mid-turn it's steered.
        runtime.delivery = .steered
        #expect(lead.call("message", ["task": "one", "text": "go on"]).text.contains("while it works"))
    }

    @Test func stopWorkerMarksTheStopAndStatusSaysSo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "one"])
        let worker = try #require(BoardStore(root: root).load().task("one")?.worker)
        _ = lead.call("stop_worker", ["task": "one"])
        #expect(BoardStore(root: root).load().task("one")?.stopped == worker)
        #expect(lead.call("status", [:]).text.contains("worker stopped"))
        _ = lead.call("start_worker", ["task": "one"])
        let board = BoardStore(root: root).load()
        #expect(board.task("one")?.stopped == nil && board.task("one")?.worker != worker)
    }
}
