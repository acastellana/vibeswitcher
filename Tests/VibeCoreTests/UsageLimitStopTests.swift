import Foundation
import Testing
@testable import VibeCore

/// Incident 2026-10-31 (agents-know-they-can, and a re-audit in another project): a worker's or verifier's session hit
/// the account's usage limit ("You've hit your weekly limit · resets Nov 3 at 1am (Europe/Madrid)") and sat there.
/// Claude Code fires no Stop hook on that, so its hooks kept saying "working" (the last event a PostToolUse) and the
/// witness, which took an API error only from a session that didn't say working, said nothing; status kept the task
/// running or in review, and the user had to ask whether it was stuck. Now: the transcript's usage-limit line is a stop,
/// told once with when the limit resets, whatever the hooks say, and status says the task waits on the limit.
struct UsageLimitStopTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    /// The end of the worker's transcript as it was (lines trimmed to what's read): a tool's result, the background
    /// agent's notification that started a turn, Claude's usage-limit line in the place of a reply, and the turn's end.
    static let transcript = """
    {"parentUuid":"a","isSidechain":false,"type":"assistant","uuid":"b","timestamp":"2026-10-31T15:41:54.147Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_01MYPKYYRD9DUww1jUiwUK3c","name":"Bash","input":{"command":"grep -n \\"func tell\\" -A25 Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift"}}]}}
    {"parentUuid":"b","isSidechain":false,"type":"user","uuid":"c","timestamp":"2026-10-31T15:41:55.119Z","message":{"role":"user","content":[{"tool_use_id":"toolu_01MYPKYYRD9DUww1jUiwUK3c","type":"tool_result","content":"937:    private func tell(timers fired: …","is_error":false}]}}
    {"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-31T15:41:55.129Z","content":"<task-notification>\\n<task-id>aa7b9fd8cc859b00b</task-id>\\n<status>completed</status>\\n</task-notification>"}
    {"parentUuid":"c89f4586-15b0-4ed7-ac5f-d45e696fda93","isSidechain":false,"type":"assistant","uuid":"16e4e7be-1e9b-4576-983b-20635e06364f","timestamp":"2026-10-31T15:41:55.401Z","message":{"id":"48c9dfff-b9f7-43e0-94c4-2c37280547ff","model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","content":[{"type":"text","text":"You've hit your weekly limit · resets Nov 3 at 1am (Europe/Madrid)"}]},"requestId":"req_011CgaZyaPgszD9FTjU6wXJs","apiError":"usage_limit_reached","apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1793664000,"rateLimitType":"seven_day","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false}},"quotaLimits":{"status":"rejected","resetsAt":1793664000,"unifiedRateLimitFallbackAvailable":false,"rateLimitType":"seven_day","overageStatus":"rejected","overageDisabledReason":"out_of_credits","upgradePaths":["overage"],"isUsingOverage":false},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}
    {"parentUuid":"16e4e7be-1e9b-4576-983b-20635e06364f","isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":842076,"messageCount":227,"timestamp":"2026-10-31T15:41:55.407Z","uuid":"118cfd79-42e8-4635-a69b-b78b4b747e7c","isMeta":false}

    """

    /// When the limit resets, as the line's `resetsAt` says: Nov 3, 00:00 UTC (1am in Madrid).
    static let resetsAt: Double = 1_793_664_000
    static let hitAt = Recorded.date("2026-10-31T15:41:55.407Z")

    /// Its hooks as they were: the last event the tool call's PostToolUse, a moment before the limit; no Stop came.
    static var hook: HookState? {
        Recorded.hook([("2026-10-31T15:27:53Z", Recorded.payload("SessionStart")),
                       ("2026-10-31T15:27:54Z", Recorded.payload("UserPromptSubmit", ["prompt": "Start on your task"])),
                       ("2026-10-31T15:41:55.100Z", Recorded.payload("PostToolUse", ["tool_name": "Bash"]))])
    }

    /// What the lead's tools and the witness read of it: its hooks and its transcript, put together.
    static var activity: LeadActivity {
        LeadActivity.resolve(hook: hook, transcript: TranscriptTail.read(Data(transcript.utf8)))
    }

    /// The witness's view of it a while later, as the app builds it: alive, its hooks (and so its status) saying
    /// working, so no API error is passed (the app passes one only from a session that doesn't say working).
    static func seen(_ now: Date) -> LeadWitness.Seen {
        LeadWitness.Seen(live: true, status: .working, since: Date(timeIntervalSince1970: hook!.lastEventAt), activity: activity,
                         lastActivity: hitAt.timeIntervalSince1970, started: Recorded.date("2026-10-31T15:27:50Z").timeIntervalSince1970,
                         boundAt: Recorded.date("2026-10-31T15:27:51Z").timeIntervalSince1970,
                         toolsAt: Recorded.date("2026-10-31T15:27:56Z").timeIntervalSince1970)
    }

    func task(_ slug: String, _ status: LeadTask.Status, worker: String?, verifier: String? = nil) -> LeadTask {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = status
        task.worker = worker
        task.verifier = verifier
        return task
    }

    /// The reset, as the lead is told it: "Nov 3, 01:00" in this Mac's time zone.
    static var resetText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: resetsAt))
    }

    /// What the lead's status and sessions say it's doing: stopped at the usage limit until its reset, not "message it
    /// to go on" (a message only hits the limit again).
    @Test func itsActivitySaysItWaitsOnTheUsageLimit() {
        let text = Self.activity.text
        #expect(text.contains("usage limit"), "activity: \(text)")
        #expect(text.contains(Self.resetText), "activity: \(text)")
        #expect(!text.contains("message it to go on"), "activity: \(text)")
    }

    /// The worker: told once, with the reset time, though its hooks still say working; no stall alarm beside it.
    @Test func aWorkerAtTheUsageLimitIsReportedAsStopped() {
        let now = Self.hitAt.addingTimeInterval(20 * 60)
        var board = LeadBoard()
        board.tasks = [task("agents-know-they-can", .running, worker: "w1")]
        let events = LeadWitness.events(board: board, seen: ["w1": Self.seen(now)], now: now)
        #expect(events.count == 1, "\(events)")
        let text = events.first?.text ?? ""
        #expect(text.contains("The worker on agents-know-they-can") && text.contains("usage limit"), "worker event: \(events)")
        #expect(text.contains(Self.resetText) && text.contains("You've hit your weekly limit"), "worker event: \(events)")
        // Told once: the same stop later is the same event.
        let later = LeadWitness.events(board: board, seen: ["w1": Self.seen(now.addingTimeInterval(3600))], now: now.addingTimeInterval(3600))
        #expect(later.map(\.key) == events.map(\.key))
    }

    /// The verifier (the other project's re-audit): told it stopped mid-audit at the limit, with the reset time.
    @Test func aVerifierAtTheUsageLimitIsReportedAsStopped() {
        let now = Self.hitAt.addingTimeInterval(5 * 60)
        var board = LeadBoard()
        board.tasks = [task("re-audit", .review, worker: "w1", verifier: "v1")]
        let events = LeadWitness.events(board: board, seen: ["w1": .init(live: false, exit: 0), "v1": Self.seen(now)], now: now)
        #expect(events.count == 1, "\(events)")
        let text = events.first?.text ?? ""
        #expect(text.contains("The verifier on re-audit") && text.contains("usage limit") && text.contains(Self.resetText), "verifier event: \(events)")
    }

    /// Status lists the tasks apart, as waiting on the limit, not as running or in review.
    @Test func statusSaysTheTaskWaitsOnTheUsageLimit() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try BoardStore(root: root).update { board in
            board.tasks = [task("agents-know-they-can", .running, worker: "w1"), task("re-audit", .review, worker: "w2", verifier: "v1")]
        }
        let usage = Self.activity.text
        runtime.others = [
            LeadSessionInfo(id: "w1", cwd: root + "/.vibeswitcher/worktrees/agents-know-they-can", label: "Worker: agents-know-they-can", live: true, status: usage, tty: nil),
            LeadSessionInfo(id: "w2", cwd: root + "/.vibeswitcher/worktrees/re-audit", label: "Worker: re-audit", live: false, status: nil, tty: nil),
            LeadSessionInfo(id: "v1", cwd: root + "/.vibeswitcher/worktrees/re-audit", label: "Verifier: re-audit", live: true, status: usage, tty: nil),
        ]
        let status = lead.call("status", [:]).text
        #expect(status.contains("usage limit (2)"), "\(status)")
        #expect(status.contains("- agents-know-they-can:") && status.contains("- re-audit:"), "\(status)")
        #expect(!status.contains("\nrunning:") && !status.contains("\nreview:"), "\(status)")
        #expect(status.contains(Self.resetText), "\(status)")
    }

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
}
