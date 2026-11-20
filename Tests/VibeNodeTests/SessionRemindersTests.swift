import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The app's reminders about sessions left alone, as `status` notices (`NodeSessions.reminderNotices`, `Nudges`,
/// `AlertRules.nudge`): waiting on you 10 minutes, working with no hook event for 15; a look (`acknowledge`) restarts
/// the waiting clock. The store's clock is the test's.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct SessionRemindersTests {
    private let scratch = Scratch()

    @Test func aSessionWaitingOrStalledIsRemindedOfAndALookRestartsTheWait() async throws {
        let home = scratch.url("reminders").appendingPathComponent("home", isDirectory: true)
        let root = home.appendingPathComponent(".vibeswitcher", isDirectory: true)
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let real = Date().timeIntervalSince1970
        var asking = HookState(agent: .claude, tty: "ttypts980", lastEvent: "PermissionRequest", lastEventAt: real - 30)
        asking.agentPid = 980
        try asking.save(to: state.appendingPathComponent("ttypts980.json"))
        var working = HookState(agent: .claude, tty: "ttypts981", lastEvent: "PreToolUse", lastEventAt: real - 30)
        working.agentPid = 981
        working.toolName = "Bash"
        working.toolDetail = "make \u{1B}[2Jcheck"
        working.toolStartedAt = real - 30
        try working.save(to: state.appendingPathComponent("ttypts981.json"))
        let started = Date(timeIntervalSince1970: real)
        let procs = [
            ProcInfo(pid: 980, ppid: 1, tty: "ttypts980", comm: "claude", startTime: started - 3600, agent: .claude),
            ProcInfo(pid: 981, ppid: 1, tty: "ttypts981", comm: "claude", startTime: started - 3600, agent: .claude),
        ]
        let table = Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
        let scanner = SessionScanner(processes: { table }, stateDir: { state }, cwd: { _ in "/r/reminders" }, arguments: { _ in [] })
        let clock = Locked(started)
        let nodes = NodeSessions(root: root, home: home.path, queue: DispatchQueue(label: "engine"), scanner: scanner, now: { clock.value })
        func settle() async throws {
            let before = nodes.queue.sync { nodes.scansApplied }
            nodes.refresh()
            try #require(await eventually { nodes.queue.sync { nodes.scansApplied > before } })
        }
        func notices() -> [String] { nodes.queue.sync { nodes.reminderNotices() } }

        try await settle()
        let statuses: Set<SessionStatus> = Set(nodes.queue.sync { nodes.sessions.map(\.status) })
        #expect(statuses == [.needsInput, .working], "\(statuses)")
        #expect(notices().isEmpty)

        clock.value = started + 11 * 60
        try await settle()
        let waiting = notices()
        let first = waiting.first ?? ""
        #expect(waiting.count == 1, "\(waiting)")
        #expect(first.contains("is still waiting for you (For 11 min") && first.contains("on ttypts980"), "\(waiting)")

        // Looked at: the wait counts from the look.
        let id = try #require(nodes.queue.sync { nodes.sessions.first { $0.tty == "ttypts980" }.map(NodeSessions.id(of:)) })
        nodes.acknowledge(id)
        #expect(notices().isEmpty, "\(notices())")

        // The working one's last hook event 16 minutes back: its one command, inert.
        clock.value = started + 16 * 60
        try await settle()
        let stalled = notices().filter { $0.contains("ttypts981") }
        let line = stalled.first ?? ""
        #expect(stalled.count == 1, "\(notices())")
        #expect(line.contains("one command running for 16 min"), "\(line)")
        #expect(!line.contains("\u{1B}"), "\(line)")

        // Paused (`vibeswitcher pause`): nothing reminds you of it.
        let marks = SessionMarks(root: root)
        nodes.queue.sync { nodes.marks = marks }
        let stuck = try #require(nodes.queue.sync { nodes.sessions.first { $0.tty == "ttypts981" } })
        try marks.pause(SessionMarks.keys(of: stuck), until: .distantFuture)
        try await settle()
        #expect(notices().allSatisfy { !$0.contains("ttypts981") }, "\(notices())")
    }
}
