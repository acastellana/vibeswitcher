import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// Incident 2026-10-31, the app's half: a verifier whose session hit the account's usage limit kept saying "working"
/// (Claude Code fires no Stop hook on it), and the witness read a verifier's transcript only while it didn't say
/// working, so the stop was never seen (found only with read_session). Now every live member's transcript is read,
/// and the witness, from what it read, tells the lead the verifier stopped at the limit.
struct UsageLimitReadTests {
    let temp = Scratch()

    static let transcript = """
    {"isSidechain":false,"type":"assistant","timestamp":"2026-10-31T15:41:20Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git diff main...HEAD --stat"}}]}}
    {"isSidechain":false,"type":"user","timestamp":"2026-10-31T15:41:21Z","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":" 3 files changed","is_error":false}]}}
    {"isSidechain":false,"type":"assistant","timestamp":"2026-10-31T15:41:55.401Z","message":{"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","content":[{"type":"text","text":"You've hit your weekly limit · resets Nov 3 at 1am (Europe/Madrid)"}]},"apiError":"usage_limit_reached","quotaLimits":{"status":"rejected","resetsAt":1793664000,"rateLimitType":"seven_day"},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}
    {"isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":35000,"timestamp":"2026-10-31T15:41:55.407Z","isMeta":false}

    """

    @Test func aVerifierThatSaysWorkingAtTheUsageLimitIsReadAndToldAsStopped() throws {
        let home = temp.url("usage-limit").path
        let states = (home as NSString).appendingPathComponent("state")
        let projects = (home as NSString).appendingPathComponent(".claude/projects/-r")
        try FileManager.default.createDirectory(atPath: states, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        let observer = LeadObserver(home: home, stateFile: { URL(fileURLWithPath: (states as NSString).appendingPathComponent("\($0).json")) })
        let started = ISO8601DateFormatter().date(from: "2026-10-31T15:40:00Z")!
        let id = UUID()
        let tty = "ttys950"
        let hosted = HostSession(id: id, tty: tty, childPID: 1, cwd: "/r", command: "claude", label: "Verifier: re-audit", agent: "claude",
                                 title: "", startedAt: started, cols: 120, rows: 40, exit: nil)
        let transcript = (projects as NSString).appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
        try Self.transcript.write(toFile: transcript, atomically: true, encoding: .utf8)
        // Its hooks as they were left: the tool call's PostToolUse, before the limit; no Stop.
        var hook = HookState(agent: .claude, tty: tty, lastEvent: "PostToolUse", lastEventAt: ISO8601DateFormatter().date(from: "2026-10-31T15:41:21Z")!.timeIntervalSince1970)
        hook.agentPid = 7100
        hook.transcriptPath = transcript
        try hook.save(to: observer.stateFile(tty))
        var session = Session(tty: tty, agent: .claude, pid: 7100, startedAt: started, cwd: "/r", project: "r", task: nil,
                              status: .working, statusSince: started, detail: nil, hasHooks: true, inTerminalApp: false)
        session.hostID = id
        var task = LeadTask(slug: "re-audit", title: "Re-audit", contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""),
                            status: .review)
        task.verifier = id.uuidString
        var board = LeadBoard()
        board.tasks = [task]

        let team = TeamReading.read(root: home, board: board, hosted: [id.uuidString: hosted], sessions: [id.uuidString: session], observer: observer)
        let watched = try #require(team.watched[id.uuidString], "the verifier saying working wasn't read")
        #expect(watched.activity.text.contains("usage limit"), "\(watched.activity.text)")
        // As the witness builds its view: status working, so no API error passed; what it read is the activity.
        let now = Date(timeIntervalSince1970: 1_793_461_315 + 300)
        let seen = LeadWitness.Seen(live: true, status: .working, since: started, activity: watched.activity,
                                    lastActivity: watched.progress?.lastWritten, started: started.timeIntervalSince1970)
        let events = LeadWitness.events(board: board, seen: [id.uuidString: seen], now: now)
        #expect(events.count == 1 && events.first?.text.contains("The verifier on re-audit") == true
                && events.first?.text.contains("usage limit") == true, "\(events)")
    }
}
