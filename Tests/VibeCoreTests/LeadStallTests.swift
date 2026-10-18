import Foundation
import Testing
@testable import VibeCore

/// Stalled workers are noticed without the user pointing at them: from what their transcripts, shells and inboxes
/// say, whatever their screens show.
struct LeadStallTests {
    static func task(_ slug: String = "fix", _ status: LeadTask.Status = .running) -> LeadTask {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = status
        task.worker = "w1"
        return task
    }

    static func board(_ task: LeadTask = task()) -> LeadBoard {
        var board = LeadBoard()
        board.tasks = [task]
        return board
    }

    static func stamp(_ at: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: at))
    }

    static func lines(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    /// What the witness reads from a transcript fixture: the activity (no hooks), and its progress.
    static func seen(_ data: Data, shellRunning: Bool = false, heldSince: Double? = nil) -> LeadWitness.Seen {
        let tail = TranscriptTail.read(data)
        let progress = TranscriptProgress.read(data)
        let activity = LeadActivity.resolve(hook: nil, transcript: tail)
        return LeadWitness.Seen(live: true, status: activity.betweenTurns ? .done : .working, activity: activity,
                                lastActivity: progress.lastWritten, compactedAt: progress.compactedAt,
                                shellRunning: shellRunning, heldSince: heldSince, heldFrom: heldSince == nil ? nil : "lead of vibeswitcher")
    }

    // MARK: Fixtures

    /// fix-the-chat-layout's worker on 2026-10-17, its transcript's tail as Claude Code wrote it (texts cut short):
    /// its turn ended at 16:23:58, Claude compacted it while idle at 17:18:48, and nothing followed but bookkeeping
    /// lines. The summary was read as a prompt, so it read as "working" for about four hours and the lead's message
    /// waited, never typed in.
    static let compactedWhileIdle = lines([
        #"{"type":"user","timestamp":"2026-10-17T16:23:44.071Z","isSidechain":false,"message":{"role":"user","content":[{"tool_use_id":"toolu_01NHsRcZWVthBQhsbikNjTQG","type":"tool_result","content":"…"}]}}"#,
        #"{"type":"api-request","timestamp":"2026-10-17T16:23:44.129Z"}"#,
        #"{"type":"last-prompt"}"#, #"{"type":"custom-title"}"#, #"{"type":"agent-name"}"#, #"{"type":"mode"}"#,
        #"{"type":"permission-mode"}"#, #"{"type":"atis-latch"}"#,
        #"{"type":"attachment","timestamp":"2026-10-17T16:23:44.077Z","isSidechain":false}"#,
        #"{"type":"assistant","timestamp":"2026-10-17T16:23:58.228Z","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"I found and fixed the cause of the chat hangs, wit"}],"stop_reason":"end_turn"}}"#,
        #"{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-10-17T16:23:58.375Z","isSidechain":false}"#,
        #"{"type":"system","subtype":"turn_duration","timestamp":"2026-10-17T16:23:58.377Z","isSidechain":false,"isMeta":false}"#,
        #"{"type":"last-prompt"}"#, #"{"type":"custom-title"}"#, #"{"type":"agent-name"}"#, #"{"type":"mode"}"#,
        #"{"type":"permission-mode"}"#, #"{"type":"atis-latch"}"#,
        #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-17T17:18:48.316Z","isSidechain":false,"isMeta":false,"content":"Conversation compacted"}"#,
        #"{"type":"user","timestamp":"2026-10-17T17:18:48.314Z","isSidechain":false,"isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"This session is being continued from a previous conversation that ran "}}"#,
        #"{"type":"attachment","timestamp":"2026-10-17T17:18:48.722Z","isSidechain":false}"#,
        #"{"type":"attachment","timestamp":"2026-10-17T17:18:48.725Z","isSidechain":false}"#,
        #"{"type":"attachment","timestamp":"2026-10-17T17:18:48.801Z","isSidechain":false}"#,
        #"{"type":"system","subtype":"informational","timestamp":"2026-10-17T17:18:48.815Z","isSidechain":false,"isMeta":false,"content":"Compacted while idle, before the prompt cache expired · turn"}"#,
        #"{"type":"last-prompt"}"#, #"{"type":"custom-title"}"#, #"{"type":"agent-name"}"#, #"{"type":"mode"}"#,
        #"{"type":"permission-mode"}"#, #"{"type":"atis-latch"}"#, #"{"type":"cost-state"}"#, #"{"type":"cost-state"}"#,
    ])
    static let compactedAt = 1_792_257_528.801  // 17:18:48.801Z, the last attachment after the summary
    static let chatLayoutTurnEnded = 1_792_254_238.377  // 16:23:58.377Z, its turn_duration

    /// A turn that compacted mid-turn (a tool's result back, then Claude's boundary and summary), and nothing followed.
    static func compactedMidTurn(at: Double) -> Data {
        lines([
            #"{"type":"assistant","timestamp":"\#(stamp(at - 30))","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#,
            #"{"type":"user","timestamp":"\#(stamp(at - 20))","isSidechain":false,"message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"…"}]}}"#,
            #"{"type":"system","subtype":"compact_boundary","timestamp":"\#(stamp(at))","isSidechain":false,"isMeta":false,"content":"Conversation compacted"}"#,
            #"{"type":"user","timestamp":"\#(stamp(at))","isSidechain":false,"isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"This session is being continued from a previous conversation that ran "}}"#,
            #"{"type":"attachment","timestamp":"\#(stamp(at + 1))","isSidechain":false}"#,
        ])
    }

    /// tests-stay-green-under's worker on 2026-10-18, its transcript's tail as Claude Code wrote it (texts cut short,
    /// bookkeeping lines kept): at 14:17:03 it started its final checks with `run_in_background` (swift test, then two
    /// load runs), and ended its turn to wait for them at 14:17:09. They reported back at 14:28:09, 11 min on: the
    /// witness had flagged it as stalled by then.
    static let waitingOnItsLoadRuns = lines([
        #"{"type":"assistant","timestamp":"2026-10-18T14:17:00.552Z","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Final checks: `swift build && swift test` saved to a file, then two full acceptance runs of the load script."}],"stop_reason":"tool_use"}}"#,
        #"{"type":"assistant","timestamp":"2026-10-18T14:17:03.085Z","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_016wtKQRpguL5SFW7bA62ogM","name":"Bash","input":{"command":"swift build > .build/tmpcheck/final-build.log 2>&1 && swift test > .build/tmpcheck/final-test.log 2>&1; echo rc=$?; …","description":"Final swift test and two load runs","timeout":3600000,"run_in_background":true}}],"stop_reason":"tool_use"}}"#,
        #"{"type":"user","timestamp":"2026-10-18T14:17:05.990Z","isSidechain":false,"message":{"role":"user","content":[{"tool_use_id":"toolu_016wtKQRpguL5SFW7bA62ogM","type":"tool_result","content":"Command running in background with ID: bgxxr7jwu. Output is being written to: /private/tmp/claude-501/…/tasks/bgxxr7jwu.output. You will be notified when it completes …","is_error":false}]},"toolUseResult":{"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"backgroundTaskId":"bgxxr7jwu"}}"#,
        #"{"type":"api-request","timestamp":"2026-10-18T14:17:07.215Z"}"#,
        #"{"type":"last-prompt"}"#, #"{"type":"custom-title"}"#, #"{"type":"agent-name"}"#, #"{"type":"mode"}"#,
        #"{"type":"permission-mode"}"#, #"{"type":"atis-latch"}"#,
        #"{"type":"attachment","timestamp":"2026-10-18T14:17:06.838Z","isSidechain":false,"attachment":{"type":"total_tokens_reminder","text":"<total_tokens>14987648 tokens left</total_tokens>"}}"#,
        #"{"type":"assistant","timestamp":"2026-10-18T14:17:08.688Z","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"The final checks are running; I'll report once they finish."}],"stop_reason":"end_turn"}}"#,
        #"{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-10-18T14:17:09.441Z","isSidechain":false}"#,
        #"{"type":"system","subtype":"turn_duration","timestamp":"2026-10-18T14:17:09.461Z","isSidechain":false,"isMeta":false}"#,
    ])
    static let loadRunsStarted = 1_792_333_025.990  // 14:17:05.990Z, the call's result
    static let loadRunsTurnEnded = 1_792_333_029.461  // 14:17:09.461Z

    /// What followed at 14:28:09: the completion queued, then typed in as the prompt of a new turn.
    static let loadRunsReported = lines([
        #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-18T14:28:09.438Z","sessionId":"c54fac30-36f7-4ca8-abfd-de20186189e9","content":"<task-notification>\n<task-id>bgxxr7jwu</task-id>\n<tool-use-id>toolu_016wtKQRpguL5SFW7bA62ogM</tool-use-id>\n<output-file>/private/tmp/claude-501/…/tasks/bgxxr7jwu.output</output-file>\n<status>completed</status>\n<summary>Background command \"Final swift test and two load runs\" completed (exit code 0)</summary>\n</task-notification>"}"#,
        #"{"type":"queue-operation","operation":"dequeue","timestamp":"2026-10-18T14:28:09.476Z","sessionId":"c54fac30-36f7-4ca8-abfd-de20186189e9"}"#,
        #"{"type":"user","timestamp":"2026-10-18T14:28:09.526Z","isSidechain":false,"message":{"role":"user","content":"<task-notification>\n<task-id>bgxxr7jwu</task-id>\n<tool-use-id>toolu_016wtKQRpguL5SFW7bA62ogM</tool-use-id>\n<output-file>/private/tmp/claude-501/…/tasks/bgxxr7jwu.output</output-file>\n<status>completed</status>\n<summary>Background command \"Final swift test and two load runs\" completed (exit code 0)</summary>\n</task-notification>"},"origin":{"kind":"task-notification","producer":"session-task"},"promptSource":"system","turnOrigin":"task_notification"}"#,
    ])
    static let loadRunsReportedAt = 1_792_333_689.526  // 14:28:09.526Z

    /// Mid-turn: a tool call, its result back, the model on it (or a tool that never returns).
    static func midTurn(at: Double) -> Data {
        lines([
            #"{"type":"user","timestamp":"\#(stamp(at - 60))","isSidechain":false,"message":{"role":"user","content":"go on"}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp(at))","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#,
        ])
    }

    /// A turn that ended in a reply: between turns.
    static func turnOver(at: Double) -> Data {
        lines([
            #"{"type":"user","timestamp":"\#(stamp(at - 60))","isSidechain":false,"message":{"role":"user","content":"go on"}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp(at - 1))","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Done with the parser."}],"stop_reason":"end_turn"}}"#,
            #"{"type":"system","subtype":"turn_duration","timestamp":"\#(stamp(at))","isSidechain":false}"#,
            // Written while it idles: not the agent doing anything.
            #"{"type":"system","subtype":"away_summary","timestamp":"\#(stamp(at + 300))","isSidechain":false,"content":"…"}"#,
        ])
    }

    // MARK: Reading transcripts

    @Test func theRealCaseReadsBetweenTurnsAfterItsIdleCompaction() throws {
        // The summary starts no turn: it's between turns since its turn ended, at 16:23:58.
        let tail = try #require(TranscriptTail.read(Self.compactedWhileIdle))
        #expect(tail.state == .turnOver(apiError: nil))
        #expect(abs((tail.at ?? 0) - Self.chatLayoutTurnEnded) < 0.01)
        #expect(LeadActivity.resolve(hook: nil, transcript: tail) == .idle(background: nil))
        // Nor is the compaction activity, or a compaction to tell: its last activity is its turn's end.
        let progress = TranscriptProgress.read(Self.compactedWhileIdle)
        #expect(abs((progress.lastWritten ?? 0) - Self.chatLayoutTurnEnded) < 0.01)
        #expect(progress.compactedAt == nil)
    }

    @Test func aTranscriptEndingAtACompactionSummaryReadsAsWhatCameBefore() throws {
        // Boundary and summary skipped: mid-turn when the turn was open, the time of its last step.
        let mid = try #require(TranscriptTail.read(Self.compactedMidTurn(at: 1_800_000_000)))
        #expect(mid.state == .thinking && mid.at == 1_800_000_000 - 20)
        let progress = TranscriptProgress.read(Self.compactedMidTurn(at: 1_800_000_000))
        #expect(progress.compactedAt == 1_800_000_000)
        #expect(progress.lastWritten == 1_800_000_001)
        // A summary alone after a finished turn (no boundary line in the window), and a /compact typed between turns.
        var summary = Self.turnOver(at: 1_800_000_000)
        summary.append(Self.lines([
            #"{"type":"user","timestamp":"\#(Self.stamp(1_800_000_600))","isSidechain":false,"message":{"role":"user","content":"<command-name>/compact</command-name>"}}"#,
            #"{"type":"user","timestamp":"\#(Self.stamp(1_800_000_660))","isSidechain":false,"isCompactSummary":true,"message":{"role":"user","content":"This session is being continued…"}}"#,
        ]))
        let idle = try #require(TranscriptTail.read(summary))
        #expect(idle.state == .turnOver(apiError: nil) && idle.at == 1_800_000_000)
        let quiet = TranscriptProgress.read(summary)
        #expect(quiet.compactedAt == nil)
        #expect(quiet.lastWritten == 1_800_000_600)
    }

    @Test func aCompactionTheConversationWentOnFromIsNone() {
        var data = Self.compactedWhileIdle
        data.append(Data((#"{"type":"assistant","timestamp":"2026-10-17T17:19:30.000Z","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}]}}"# + "\n").utf8))
        let progress = TranscriptProgress.read(data)
        #expect(progress.compactedAt == nil)
        #expect(abs((progress.lastWritten ?? 0) - 1_792_257_570) < 0.01)
    }

    @Test func noticesWrittenWhileIdleArentActivity() {
        let progress = TranscriptProgress.read(Self.turnOver(at: 1_800_000_000))
        #expect(progress.lastWritten == 1_800_000_000)
        #expect(progress.compactedAt == nil)
    }

    @Test func subagentsWritingCountsAsActivity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stall-\(UUID().uuidString)")
        let file = folder.appendingPathComponent("abc.jsonl")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("abc/subagents"), withIntermediateDirectories: true)
        let then = Date().timeIntervalSince1970 - 3_600
        try Self.midTurn(at: then).write(to: file)
        #expect(abs((TranscriptProgress.read(url: file)?.lastWritten ?? 0) - then) < 0.01)
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent("abc/subagents/agent-1.jsonl"))
        #expect((TranscriptProgress.read(url: file)?.lastWritten ?? 0) > then + 3_000)
    }

    // MARK: (a) silent while it reads as working

    @Test func aWorkerThatReadsAsWorkingButWroteNothingFor15MinIsStalled() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let last = now.timeIntervalSince1970 - 16 * 60
        let events = LeadWitness.events(board: Self.board(), seen: ["w1": Self.seen(Self.midTurn(at: last))], now: now)
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.text.contains("stalled: it reads as working, but its transcript hasn't grown and no shell of its runs, last activity 16 min ago"))
        #expect(event.key == "w1|stalled-\(Int(last))")
        // Under 15 min, or a shell of its runs (a long build, a background job): not a stall.
        let recent = Self.seen(Self.midTurn(at: now.timeIntervalSince1970 - 14 * 60))
        #expect(LeadWitness.events(board: Self.board(), seen: ["w1": recent], now: now).isEmpty)
        let building = Self.seen(Self.midTurn(at: last), shellRunning: true)
        #expect(LeadWitness.events(board: Self.board(), seen: ["w1": building], now: now).isEmpty)
    }

    // MARK: (b) between turns without reporting

    @Test func aWorkerIdleFor10MinWithoutReportingIsStalled() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ended = now.timeIntervalSince1970 - 11 * 60
        let seen = Self.seen(Self.turnOver(at: ended))
        #expect(seen.activity?.betweenTurns == true)
        let stalls = LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: now).filter { $0.key.contains("|stalled-") }
        let event = try #require(stalls.first)
        #expect(stalls.count == 1)
        #expect(event.text.contains("stalled: it's between turns without having reported, and has no question to the lead pending, last activity 11 min ago"))
        // Under 10 min it's only the earlier "stopped without calling report".
        let soon = Self.seen(Self.turnOver(at: now.timeIntervalSince1970 - 9 * 60))
        #expect(LeadWitness.events(board: Self.board(), seen: ["w1": soon], now: now).allSatisfy { !$0.key.contains("|stalled-") })
        // Waiting on the lead's answer isn't a stall; nor is a task it reported on.
        var asked = Self.task()
        asked.leadQuestionAt = ended - 30
        #expect(LeadStall.detect(seen, task: asked, now: now).isEmpty)
        #expect(LeadStall.detect(seen, task: Self.task("fix", .review), now: now).isEmpty)
        #expect(LeadStall.detect(seen, task: Self.task("fix", .blocked), now: now).isEmpty)
    }

    // MARK: (c) stuck after a compaction

    @Test func anIdleCompactionIsNeitherWorkNorACompactionStall() throws {
        // The chat-layout worker: idle since 16:23:58, and the compaction at 17:18 changes nothing. Its idle stall
        // was told 10 min after its turn; after the compaction it's the same episode, not a new one or "compacted".
        let ended = Self.chatLayoutTurnEnded
        let beforeCompaction = Self.lines(String(decoding: Self.compactedWhileIdle, as: UTF8.self)
            .components(separatedBy: "\n").prefix { !$0.contains("compact_boundary") })
        let before = LeadStall.detect(Self.seen(beforeCompaction), task: Self.task(), now: Date(timeIntervalSince1970: ended + 11 * 60))
        let seen = Self.seen(Self.compactedWhileIdle)
        #expect(seen.activity == .idle(background: nil) && seen.compactedAt == nil)
        for now in [Self.compactedAt + 5 * 60 + 1, Self.compactedAt + 4 * 3600] {
            let stalls = LeadStall.detect(seen, task: Self.task(), now: Date(timeIntervalSince1970: now))
            #expect(stalls.map(\.reason) == [.idle])
            #expect(stalls.map { $0.key(session: "w1") } == before.map { $0.key(session: "w1") })
            #expect(stalls.first?.lastActivity == before.first?.lastActivity)
        }
        let events = LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: Date(timeIntervalSince1970: Self.compactedAt + 4 * 3600))
        #expect(events.allSatisfy { !$0.text.contains("compaction") })
        // Even when the hooks' "done" stands for its activity and a compaction time is passed in, idle isn't "compacted".
        var told = seen
        told.compactedAt = Self.compactedAt
        #expect(LeadStall.detect(told, task: Self.task(), now: Date(timeIntervalSince1970: Self.compactedAt + 3600)).map(\.reason) == [.idle])
    }

    @Test func aWorkerStuckAfterACompactionMidTurnIsStalled() throws {
        // Compacted mid-turn and nothing followed: 5 min on, and four hours on, told once.
        let compacted = 1_800_000_000.0
        let seen = Self.seen(Self.compactedMidTurn(at: compacted))
        #expect(seen.activity == .working(nil))
        let early = Date(timeIntervalSince1970: compacted + 1 + 5 * 60 + 1)
        let late = Date(timeIntervalSince1970: compacted + 1 + 4 * 3600)
        let first = LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: early)
        let event = try #require(first.first)
        #expect(first.count == 1)
        #expect(event.text.contains("fix is stalled: its transcript ends at a context-compaction summary and nothing followed, last activity 5 min ago"))
        #expect(event.text.contains("message(fix"))
        let again = LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: late)
        #expect(again.map(\.key) == first.map(\.key))
        #expect(again[0].text.contains("last activity 4 h ago"))
        // Not before 5 min.
        #expect(LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: Date(timeIntervalSince1970: compacted + 4 * 60)).isEmpty)
    }

    /// The lead's message to the chat-layout worker waited about four hours: the flush types only into a worker
    /// between turns, and the compaction made it read as working. Read as the app's flush reads it (its hooks' Stop
    /// a moment before the turn's last line, its transcript where the hooks say), it's between turns, and typed in.
    @Test func theChatLayoutWorkersWaitingMessageIsTypedByTheIdleFlush() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("stall-\(UUID().uuidString)").resolvingSymlinksInPath()
        let transcript = home.appendingPathComponent(".claude/projects/-Users-albert-dev-vibeswitcher--vibeswitcher-worktrees-fix-the-chat-layout/5f0c9a1e.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.compactedWhileIdle.write(to: transcript)
        var hook = HookState(agent: .claude, tty: "ttys031", lastEvent: "Stop", lastEventAt: Self.chatLayoutTurnEnded - 0.1)
        hook.agentPid = 51200
        hook.transcriptPath = transcript.path
        let stateFile = home.appendingPathComponent("state/ttys031.json")
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try hook.save(to: stateFile)
        let session = HostSession(id: UUID(), tty: "ttys031", childPID: 51200, cwd: "/Users/albert/dev/vibeswitcher/.vibeswitcher/worktrees/fix-the-chat-layout",
                                  command: "claude --name 'worker-fix-the-chat-layout'", label: "Worker: Fix the chat layout", agent: "claude", title: "",
                                  startedAt: Date(timeIntervalSince1970: Self.chatLayoutTurnEnded - 3600), cols: 120, rows: 40, exit: nil)
        let observer = LeadObserver(home: home.path, stateFile: { _ in stateFile })
        let activity = observer.activity(session, agentPid: 51200)
        #expect(activity == .idle(background: nil))

        let root = home.appendingPathComponent("vibe")
        let agent = LeadAgent(pid: 51200, tty: "ttys031", session: session.id.uuidString)
        try SteerInbox.post(SteerMessage(text: "Merge project-lead and report", from: .lead("lead of vibeswitcher"), agentPid: 51200), tty: agent.tty, root: root)
        var typed: [String] = []
        #expect(LeadDelivery.flush(agent, betweenTurns: activity.betweenTurns, inputIsEmpty: { true }, typeInto: { typed.append($0); return true }, root: root))
        #expect(typed.count == 1 && typed[0].hasSuffix("Merge project-lead and report"))
        #expect(SteerInbox.pending(tty: agent.tty, root: root).isEmpty)
    }

    // MARK: Waiting on its own background task

    static func clock(_ at: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: at))
    }

    @Test func aWorkerWaitingOnItsLoadRunsReadsSoAndIsntStalled() throws {
        let tail = try #require(TranscriptTail.read(Self.waitingOnItsLoadRuns))
        #expect(tail.state == .turnOver(apiError: nil))
        #expect(tail.background == [TranscriptTail.Background(id: "bgxxr7jwu", what: "Final swift test and two load runs", startedAt: Self.loadRunsStarted)])
        let activity = LeadActivity.resolve(hook: nil, transcript: tail)
        #expect(activity.betweenTurns)
        #expect(activity.text == "waiting on its background task (Final swift test and two load runs, started \(Self.clock(Self.loadRunsStarted)))")
        // The task's own description wins over the shells the process table shows.
        #expect(LeadActivity.resolve(hook: nil, transcript: tail, background: "1 shell: swift build") == activity)

        // 11 min on, when the witness flagged it, and up to the ceiling: not stalled, nor "stopped without calling report".
        var seen = Self.seen(Self.waitingOnItsLoadRuns)
        seen.since = Date(timeIntervalSince1970: Self.loadRunsTurnEnded)
        for minutes in [11.0, 30, 44] {
            let now = Date(timeIntervalSince1970: Self.loadRunsTurnEnded + minutes * 60)
            #expect(LeadStall.detect(seen, task: Self.task(), now: now).isEmpty)
            #expect(LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: now).isEmpty)
        }
        // Past the ceiling with no word from it: stalled, saying what it waits on.
        let late = Date(timeIntervalSince1970: Self.loadRunsTurnEnded + 46 * 60)
        let stalls = LeadStall.detect(seen, task: Self.task(), now: late)
        let stall = try #require(stalls.first)
        #expect(stalls.count == 1 && stall.reason == .idle)
        #expect(stall.text(now: late) == "stalled: it has waited on its background task (Final swift test and two load runs, started \(Self.clock(Self.loadRunsStarted))) for over 45 min without having reported, last activity 46 min ago")
        // Messages still go in between turns: a held one is a stall of its own.
        let held = Self.seen(Self.waitingOnItsLoadRuns, heldSince: Self.loadRunsTurnEnded + 60)
        #expect(LeadStall.detect(held, task: Self.task(), now: Date(timeIntervalSince1970: Self.loadRunsTurnEnded + 11 * 60)).map(\.reason) == [.undelivered])
    }

    @Test func onceItsBackgroundTaskReportedTenMinutesCount() throws {
        // Its completion notice came at 14:28:09 and (say) it didn't go on: idle from then, stalled 10 min on.
        var data = Self.waitingOnItsLoadRuns
        data.append(Self.loadRunsReported)
        let tail = try #require(TranscriptTail.read(data))
        #expect(tail.background.isEmpty)
        // A turn the notification starts is mid-turn; with its own end written, it's over and nothing is waited on.
        #expect(tail.state == .thinking)
        data.append(Self.lines([
            #"{"type":"assistant","timestamp":"2026-10-18T14:28:20.000Z","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Checks pass."}],"stop_reason":"end_turn"}}"#,
            #"{"type":"system","subtype":"turn_duration","timestamp":"2026-10-18T14:28:20.100Z","isSidechain":false}"#,
        ]))
        let over = Self.seen(data)
        #expect(over.activity == .idle(background: nil))
        let ended = 1_792_333_700.100
        #expect(LeadStall.detect(over, task: Self.task(), now: Date(timeIntervalSince1970: ended + 9 * 60)).isEmpty)
        #expect(LeadStall.detect(over, task: Self.task(), now: Date(timeIntervalSince1970: ended + 11 * 60)).map(\.reason) == [.idle])
        // Queued but not yet typed in (only the queue's line): reported all the same, so 10 min count from it.
        var queued = Self.waitingOnItsLoadRuns
        queued.append(Self.lines([String(decoding: Self.loadRunsReported, as: UTF8.self).components(separatedBy: "\n")[0]]))
        let waiting = Self.seen(queued)
        #expect(waiting.activity == .idle(background: nil))
        #expect(LeadStall.detect(waiting, task: Self.task(), now: Date(timeIntervalSince1970: Self.loadRunsReportedAt + 9 * 60)).isEmpty)
        #expect(LeadStall.detect(waiting, task: Self.task(), now: Date(timeIntervalSince1970: Self.loadRunsReportedAt + 11 * 60)).map(\.reason) == [.idle])
    }

    @Test func backgroundAgentsAndNoticesMidTurnAreReadToo() throws {
        let at = 1_800_000_000.0
        // A background agent (its description in the result) and a shell (its command, having no description).
        let started = Self.lines([
            #"{"type":"assistant","timestamp":"\#(Self.stamp(at))","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_A","name":"Agent","input":{"description":"Review Korean batch D","prompt":"…","run_in_background":true}},{"type":"tool_use","id":"toolu_B","name":"Bash","input":{"command":"scripts/test-under-load.sh -r 6","run_in_background":true}}]}}"#,
            #"{"type":"user","timestamp":"\#(Self.stamp(at + 1))","isSidechain":false,"message":{"role":"user","content":[{"tool_use_id":"toolu_A","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully."}]}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"adb60b8ca8b3372f4","description":"Review Korean batch D"}}"#,
            #"{"type":"user","timestamp":"\#(Self.stamp(at + 2))","isSidechain":false,"message":{"role":"user","content":[{"tool_use_id":"toolu_B","type":"tool_result","content":"Command running in background with ID: b7kjfi7c9."}]},"toolUseResult":{"backgroundTaskId":"b7kjfi7c9"}}"#,
            // A subagent's own background work isn't the worker's.
            #"{"type":"user","timestamp":"\#(Self.stamp(at + 3))","isSidechain":true,"message":{"role":"user","content":[{"tool_use_id":"toolu_C","type":"tool_result","content":"…"}]},"toolUseResult":{"backgroundTaskId":"bside"}}"#,
            #"{"type":"assistant","timestamp":"\#(Self.stamp(at + 4))","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Waiting on both."}],"stop_reason":"end_turn"}}"#,
        ])
        let tail = try #require(TranscriptTail.read(started))
        #expect(tail.background.map(\.id) == ["adb60b8ca8b3372f4", "b7kjfi7c9"])
        #expect(tail.background.map(\.what) == ["Review Korean batch D", "scripts/test-under-load.sh -r 6"])
        #expect(tail.waitingOn == "Review Korean batch D, started \(Self.clock(at + 1)), and 1 more")
        // The shell's notice came as an attachment while a turn ran: one left, the agent.
        var data = started
        data.append(Self.lines([
            #"{"type":"attachment","timestamp":"\#(Self.stamp(at + 60))","isSidechain":false,"attachment":{"type":"queued_command","prompt":"<task-notification>\n<task-id>b7kjfi7c9</task-id>\n<tool-use-id>toolu_B</tool-use-id>\n<status>completed</status>\n</task-notification>","commandMode":"task-notification"}}"#,
        ]))
        #expect(TranscriptTail.read(data)?.background.map(\.id) == ["adb60b8ca8b3372f4"])
        // Text that only quotes a notice (a file it wrote, say) isn't one.
        data.append(Self.lines([
            #"{"type":"assistant","timestamp":"\#(Self.stamp(at + 70))","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_D","name":"Write","input":{"content":"<task-notification><task-id>adb60b8ca8b3372f4</task-id>"}}]}}"#,
        ]))
        #expect(TranscriptTail.read(data)?.background.map(\.id) == ["adb60b8ca8b3372f4"])
    }

    // MARK: (d) a message held in its inbox

    @Test func aLeadMessageHeldFor5MinIsAStall() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Between turns (a grey suggestion read as a draft held it), its last turn 3 min ago.
        let held = now.timeIntervalSince1970 - 6 * 60
        let seen = Self.seen(Self.turnOver(at: now.timeIntervalSince1970 - 3 * 60), heldSince: held)
        let events = LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: now).filter { $0.key.contains("|held-") }
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.key == "w1|held-\(Int(held))")
        #expect(event.text.contains("stalled: a message from lead of vibeswitcher has waited 6 min in its inbox, undelivered, last activity 3 min ago"))
        // Under 5 min, it's still on its way.
        let fresh = Self.seen(Self.turnOver(at: now.timeIntervalSince1970 - 3 * 60), heldSince: now.timeIntervalSince1970 - 4 * 60)
        #expect(LeadStall.detect(fresh, task: Self.task(), now: now).isEmpty)
        // Beside a compaction mid-turn, or an idle stall: both told, each once.
        let compacted = Self.seen(Self.compactedMidTurn(at: 1_800_000_000), heldSince: 1_800_000_060)
        let both = LeadStall.detect(compacted, task: Self.task(), now: Date(timeIntervalSince1970: 1_800_003_600))
        #expect(both.map(\.reason) == [.compacted, .undelivered])
        let idle = Self.seen(Self.compactedWhileIdle, heldSince: Self.compactedAt + 60)
        let idleBoth = LeadStall.detect(idle, task: Self.task(), now: Date(timeIntervalSince1970: Self.compactedAt + 3600))
        #expect(idleBoth.map(\.reason) == [.idle, .undelivered])
    }

    // MARK: Once per episode

    @Test func eachStallIsToldOncePerEpisode() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let last = now.timeIntervalSince1970 - 20 * 60
        let seen = Self.seen(Self.midTurn(at: last))
        // Told at 20 min, the same key an hour on: the witness tells a key once.
        let keys = [now, now + 3_600].map { LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: $0).map(\.key) }
        #expect(keys[0] == keys[1] && keys[0].count == 1)
        // A compaction stall and a later silent one in the same quiet are one episode.
        let compacted = LeadStall(reason: .compacted, lastActivity: last, at: now.timeIntervalSince1970)
        let silent = LeadStall(reason: .silent, lastActivity: last, at: now.timeIntervalSince1970 + 600)
        #expect(compacted.key(session: "w1") == silent.key(session: "w1"))
        // Once it moves again, a new quiet is a new episode.
        let moved = Self.seen(Self.midTurn(at: last + 600))
        #expect(LeadWitness.events(board: Self.board(), seen: ["w1": moved], now: now + 3_600).map(\.key) != keys[0])
        // A worker that ended, quit, or waits on a prompt is told its own way, not as stalled.
        var gone = seen
        gone.agentQuit = true
        #expect(LeadStall.detect(gone, task: Self.task(), now: now).isEmpty)
        var asking = seen
        asking.status = .needsInput
        #expect(LeadStall.detect(asking, task: Self.task(), now: now).isEmpty)
    }

    @Test func theBoardKeepsAStallUntilTheWorkerMoves() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var board = Self.board()
        let seen = ["w1": Self.seen(Self.midTurn(at: now.timeIntervalSince1970 - 20 * 60))]
        let first = board.noteStalls(LeadWitness.stalls(board: board, seen: seen, now: now))
        #expect(first)
        let noted = try #require(board.tasks[0].stall)
        #expect(noted.reason == .silent && noted.at == now.timeIntervalSince1970)
        // The same episode later: unchanged (when it was first noticed stays).
        let again = board.noteStalls(LeadWitness.stalls(board: board, seen: seen, now: now + 600))
        #expect(!again)
        #expect(board.stalled.map(\.slug) == ["fix"])
        // It moved: cleared.
        let moved = ["w1": Self.seen(Self.midTurn(at: now.timeIntervalSince1970 + 590))]
        let cleared = board.noteStalls(LeadWitness.stalls(board: board, seen: moved, now: now + 600))
        #expect(cleared)
        #expect(board.tasks[0].stall == nil && board.stalled.isEmpty)
    }
}

/// status lists stalled workers first, with why; ask_lead and the lead's answer say whether one waits on the lead.
struct LeadStallStatusTests: LeadTeamFixture {
    let vault = Self.newVault()

    func repo() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    @Test func statusListsStalledWorkersAtTheTop() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["One", "Two"] {
            _ = lead.call("add_task", ["title": title, "goal": "g", "acceptance": ["a"]])
            _ = lead.call("start_worker", ["task": title.lowercased()])
        }
        let now = Date().timeIntervalSince1970
        try BoardStore(root: root).update { board in
            board.noteStalls([board.task("two")!.id: LeadStall(reason: .compacted, lastActivity: now - 2 * 3600 - 60, at: now - 3600)])
        }
        let text = lead.call("status", [:]).text
        let stalled = try #require(text.range(of: "Stalled (1):"))
        let running = try #require(text.range(of: "\nrunning:"))
        #expect(stalled.lowerBound < running.lowerBound)
        #expect(text.contains("- two: stalled: its transcript ends at a context-compaction summary and nothing followed, last activity 2 h 1 min ago"))
        #expect(!text[stalled.upperBound..<running.lowerBound].contains("- one:"))
    }

    @Test func aQuestionToTheLeadIsPendingUntilItAnswers() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "one"])
        let worker = try seat("worker-one", runtime)
        #expect(!worker.call("ask_lead", ["question": "Which file?"]).isError)
        #expect(BoardStore(root: root).load().task("one")?.leadQuestionAt != nil)
        _ = lead.call("message", ["task": "one", "text": "a.txt"])
        #expect(BoardStore(root: root).load().task("one")?.leadQuestionAt == nil)
    }
}
