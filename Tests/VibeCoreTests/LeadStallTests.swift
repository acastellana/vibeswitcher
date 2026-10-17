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
    /// lines. The summary reads as a prompt, so it read as "working" for about four hours.
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

    @Test func theRealCaseReadsAsWorkingButEndsAtACompaction() throws {
        let tail = try #require(TranscriptTail.read(Self.compactedWhileIdle))
        #expect(LeadActivity.resolve(hook: nil, transcript: tail) == .working(nil))
        let progress = TranscriptProgress.read(Self.compactedWhileIdle)
        #expect(abs((progress.lastWritten ?? 0) - Self.compactedAt) < 0.01)
        #expect(abs((progress.compactedAt ?? 0) - 1_792_257_528.314) < 0.01)
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

    @Test func theChatLayoutWorkerIsStalledAfterItsCompaction() throws {
        // 5 min after the compaction, and four hours on (the hour the user pointed at it): told once.
        let seen = Self.seen(Self.compactedWhileIdle)
        let early = Date(timeIntervalSince1970: Self.compactedAt + 5 * 60 + 1)
        let late = Date(timeIntervalSince1970: Self.compactedAt + 4 * 3600)
        let first = LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: early)
        let event = try #require(first.first)
        #expect(first.count == 1)
        #expect(event.text.contains("fix is stalled: its transcript ends at a context-compaction summary and nothing followed, last activity 5 min ago"))
        #expect(event.text.contains("message(fix"))
        let again = LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: late)
        #expect(again.map(\.key) == first.map(\.key))
        #expect(again[0].text.contains("last activity 4 h ago"))
        // Not before 5 min.
        #expect(LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: Date(timeIntervalSince1970: Self.compactedAt + 4 * 60)).isEmpty)
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
        // Beside the compaction: both told, each once.
        let compacted = Self.seen(Self.compactedWhileIdle, heldSince: Self.compactedAt + 60)
        let both = LeadStall.detect(compacted, task: Self.task(), now: Date(timeIntervalSince1970: Self.compactedAt + 3600))
        #expect(both.map(\.reason) == [.compacted, .undelivered])
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
