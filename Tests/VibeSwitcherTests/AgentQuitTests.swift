import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// A worker's or verifier's agent has quit only once its own process has exited: one that ended its turn to wait on a
/// background command runs on, whatever its terminal's foreground is (2026-10-27, land-pr-1-host: two verifiers alive
/// and waiting on a load run were said to have quit, and their audits started again). The fake Claude Code on a
/// scratch host's session, the process table as it is: the witness's rule (`HostSession.agentRuns`) and auto_advance's
/// (`LeadWitness.agentQuitEnding`, what `LeadRuntime.agentEnding` tells it).
@MainActor
struct AgentQuitTests {
    /// The verifier on a task in review, as the app's witness sees it with no agent of its in the scan (the fake is
    /// Python, never in it): its rule (`TeamReading.agentQuit`, from the table `TeamReading.read` reads), its events,
    /// and auto_advance's ending from `table`.
    func witness(root: URL, _ hosted: HostSession, table: [Int32: ProcInfo], now: Date) -> (quit: Bool, events: [String], ended: [String], ending: String?) {
        var task = LeadTask(slug: "audit-me", title: "audit-me", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = .review
        task.worker = "w1"
        task.verifier = hosted.id.uuidString
        var board = LeadBoard()
        board.tasks = [task]
        let observer = LeadObserver(home: root.path, stateFile: { root.appendingPathComponent("state/\($0).json") })
        let team = TeamReading.read(root: root.path, board: board, hosted: [hosted.id.uuidString: hosted], sessions: [:], observer: observer)
        let quit = team.agentQuit(hosted.id.uuidString, session: nil, scanSaysQuit: hosted.agentQuit(now: now))
        let seen = [hosted.id.uuidString: LeadWitness.Seen(live: hosted.isLive, status: .background, agentQuit: quit,
                                                           started: hosted.startedAt.timeIntervalSince1970)]
        return (quit, LeadWitness.events(board: board, seen: seen, now: now).map(\.text),
                LeadWitness.endedForAdvance(board: board, seen: seen, now: now),
                LeadWitness.agentQuitEnding(hosted, table: table, now: now))
    }

    /// A table read whole in which `holds` (one read may come back nil on a loaded Mac: read again).
    func table(where holds: ([Int32: ProcInfo]) -> Bool) async throws -> [Int32: ProcInfo] {
        var read: [Int32: ProcInfo]?
        #expect(await until(timeout: Harness.wait) {
            read = ProcessTable.trySnapshot()
            return read.map(holds) ?? false
        })
        return try #require(read)
    }

    /// `keepShell`: the session's shell runs the agent and stays once it exits (the agent's quit is told then);
    /// without, the shell exec'd it in its place, as a team session's `claude` is.
    @Test(arguments: [(keepShell: true, foreground: false), (keepShell: true, foreground: true), (keepShell: false, foreground: false)])
    func anAgentWaitingOnABackgroundCommandHasNotQuit(_ setup: (keepShell: Bool, foreground: Bool)) async throws {
        let temp = Scratch()
        let h = try await Harness.start(temp, keepShell: setup.keepShell)
        // The project the board is in (its folder takes the lead's loop's lock), removed with `temp`.
        let root = temp.url("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { h.stop() }
        let agent = try #require((h.agent["pid"] as? Int).map(Int32.init))
        // Its turn ends on a long command it runs in the background (or one that takes the terminal's foreground).
        h.tell(["op": "done", "reply": "I'll finish the audit when it reports."])
        h.tell(["op": "child", "foreground": setup.foreground])
        try await h.waitFor { (h.agent["children"] as? [Int])?.count == 1 }
        let child = try #require((h.agent["children"] as? [Int])?.first.map(Int32.init))
        defer { kill(child, SIGKILL) }
        let hosted = try #require(h.host.sessions.first { $0.id == h.session.id })
        // As the witness looks a minute on and more.
        let later = hosted.startedAt.addingTimeInterval(120)

        let waiting = try await table { $0[child] != nil && $0[agent] != nil }
        #expect(hosted.isLive && hosted.agentRuns(in: waiting))
        let alive = witness(root: root, hosted, table: waiting, now: later)
        #expect(!alive.quit)
        #expect(!alive.events.contains { $0.contains("ended without a verdict") }, "\(alive.events)")
        #expect(alive.ended.isEmpty && alive.ending == nil, "\(alive)")

        // It exits, its child left running: its agent quit (its kept shell open), or its session ended.
        h.tell(["op": "exit"])
        guard setup.keepShell else {
            try await h.waitFor { h.host.sessions.first { $0.id == h.session.id }?.isLive == false }
            return
        }
        // The kept shell started (its profile's commands, path_helper, run under it as it does: they'd count as its
        // agent's work), its child left to launchd.
        let shell = try #require(h.host.sessions.first { $0.id == h.session.id })
        let exited = try await table { table in
            table[agent] == nil && table[child]?.ppid == 1 && !table.values.contains { $0.ppid == shell.childPID }
        }
        #expect(shell.isLive && !shell.agentRuns(in: exited))
        // The witness reads a table of its own (none on a loaded Mac, read again: not known isn't quit).
        var quit = witness(root: root, shell, table: exited, now: later)
        #expect(await until(timeout: Harness.wait) {
            quit = witness(root: root, shell, table: exited, now: later)
            return quit.quit
        })
        #expect(quit.events.contains { $0.contains("ended without a verdict (\(LeadWitness.agentQuitEnding))") }, "\(quit.events)")
        #expect(quit.ended == [shell.id.uuidString] && quit.ending == LeadWitness.agentQuitEnding, "\(quit)")
    }
}
