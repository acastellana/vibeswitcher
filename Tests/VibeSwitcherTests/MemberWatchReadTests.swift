import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The app's witness watches each live member of a team task, not only its integrator: what it reads of the team off
/// the main thread (`TeamReading.read`, on scratch host sessions with fake hook states and transcripts) takes each
/// member's session, and its shells, held messages and test-lock waits are read for it as for the task's worker
/// (`TeamReading.workerSessions`). A member left out was never stall-checked, so one stuck went unnoticed.
struct MemberWatchReadTests {
    let scratch = Scratch()

    @Test func theWitnessReadsEachLiveMembersSession() throws {
        let home = scratch.url("member-watch").path
        let states = (home as NSString).appendingPathComponent("state")
        let projects = (home as NSString).appendingPathComponent(".claude/projects/-r")
        try FileManager.default.createDirectory(atPath: states, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        let observer = LeadObserver(home: home, stateFile: { URL(fileURLWithPath: (states as NSString).appendingPathComponent("\($0).json")) })
        let started = Date().addingTimeInterval(-600)
        let finished = """
            {"type":"assistant","timestamp":"2026-10-19T09:00:00.250Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}
            {"type":"system","subtype":"turn_duration","timestamp":"2026-10-19T09:00:01Z"}

            """
        var hosted: [String: HostSession] = [:]
        var sessions: [String: Session] = [:]
        func session(_ index: Int, live: Bool = true) throws -> String {
            let id = UUID()
            let tty = "ttys\(950 + index)"
            hosted[id.uuidString] = HostSession(id: id, tty: tty, childPID: 1, cwd: "/r", command: "claude", label: "member-\(index)", agent: "claude",
                                                title: "", startedAt: started, cols: 120, rows: 40,
                                                exit: live ? nil : HostSession.Exit(status: 0, at: Date()))
            let transcript = (projects as NSString).appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
            try finished.write(toFile: transcript, atomically: true, encoding: .utf8)
            var hook = HookState(agent: .claude, tty: tty, lastEvent: "Stop", lastEventAt: Date().timeIntervalSince1970)
            hook.agentPid = Int32(7100 + index)
            hook.transcriptPath = transcript
            try hook.save(to: observer.stateFile(tty))
            var scanned = Session(tty: tty, agent: .claude, pid: Int32(7100 + index), startedAt: started, cwd: "/r", project: "r", task: nil,
                                  status: .done, statusSince: started, detail: nil, hasHooks: true, inTerminalApp: false)
            scanned.hostID = id
            sessions[id.uuidString] = scanned
            return id.uuidString
        }
        let integrator = try session(0)
        let ui = try session(1)
        let docs = try session(2)
        let ended = try session(3, live: false)
        var task = LeadTask(slug: "build-it", title: "Build it", contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""), status: .running)
        task.worker = integrator
        task.team = try LeadTeam.make(slug: "build-it", root: home, parts: [("core", "types"), ("ui", "views"), ("docs", "docs"), ("api", "tools")])
        for (index, worker) in [integrator, ui, docs, ended].enumerated() { task.team?[index].worker = worker }
        var board = LeadBoard()
        board.tasks = [task]

        #expect(board.tasks[0].watched == [integrator, ui, docs, ended])
        #expect(TeamReading.workerSessions(board) == [integrator, ui, docs, ended])
        let team = TeamReading.read(root: home, board: board, hosted: hosted, sessions: sessions, observer: observer)
        // Every live member's transcript is read, as the integrator's; the ended one's isn't (`endedMembers` tells it).
        #expect(Set(team.watched.keys) == [integrator, ui, docs])
        for id in [ui, docs] {
            let reading = observer.watching(try #require(hosted[id]), agentPid: try #require(sessions[id]).pid)
            #expect(team.watched[id]?.activity == reading.activity)
            #expect(team.watched[id]?.progress == reading.progress)
        }
        // A plain task's reading is as before: its worker alone.
        var plain = board
        plain.tasks[0].team = nil
        #expect(Set(TeamReading.read(root: home, board: plain, hosted: hosted, sessions: sessions, observer: observer).watched.keys) == [integrator])
        #expect(TeamReading.workerSessions(plain) == [integrator])
    }
}
