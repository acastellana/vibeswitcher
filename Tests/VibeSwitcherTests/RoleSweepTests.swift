import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The app ends the role sessions of finished tasks on its own, from the vault's roster and the boards (`RoleSweep`),
/// whatever the lead's tool server does; and what it couldn't end is told once an hour at most. On fakes: no host, no
/// session started.
struct RoleSweepTests {
    static let now = Date(timeIntervalSince1970: 1_792_480_000)
    let root = LeadVault.canonical("/Users/you/dev/project-c")
    let other = LeadVault.canonical("/Users/you/dev/acme")

    func hosted(_ label: String, cwd: String, live: Bool = true) -> HostSession {
        HostSession(id: UUID(), tty: "ttys001", childPID: 4321, cwd: cwd, command: "claude", label: label, agent: "claude", title: "",
                    startedAt: Self.now - 90_000, cols: 80, rows: 24, exit: live ? nil : HostSession.Exit(status: 129, at: Self.now - 60))
    }

    func task(_ slug: String, _ status: LeadTask.Status) -> LeadTask {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""), status: status)
        task.since = Self.now.timeIntervalSince1970 - 80_000
        return task
    }

    final class World {
        var roster: [LeadVault.RosterEntry] = []
        var boards: [String: LeadBoard] = [:]
        var down = false
        var ended: [UUID] = []
        var told: [String] = []
        var submitted: [String: Double] = [:]
    }

    func sweep(_ world: World) -> RoleSweep {
        let sweep = RoleSweep(roster: {
            if world.down { throw LeadVault.Refused("This session host doesn't know that request; it may be older than the app.") }
            return world.roster
        }, board: { world.boards[$0] ?? LeadBoard() }, end: { world.ended.append($0.id) }, tell: { world.told.append($0) })
        sweep.submitted = { world.submitted = $0 }
        return sweep
    }

    @Test func everyRoleSessionOfAFinishedTaskEndsOnItsOwnAndWhatLingersIsToldHourly() throws {
        let tree = { (slug: String) in "/Users/you/dev/project-c/.vibeswitcher/worktrees/\(slug)" }
        let lead = hosted("Lead · project-c", cwd: "/Users/you/dev/project-c")
        let mine = hosted("Shell", cwd: tree("contract-plan-task-8"))
        let worker = hosted("Worker: Contract plan 8", cwd: tree("contract-plan-task-8"))
        let first = hosted("Verifier: Contract plan 8", cwd: tree("contract-plan-task-8"))
        let second = hosted("Verifier: Contract plan 8", cwd: tree("contract-plan-task-8"))
        let running = hosted("Worker: Publish", cwd: tree("publish"))
        let otherLead = hosted("Lead · acme", cwd: "/Users/you/dev/acme")
        let sessions = [lead, mine, worker, first, second, running, otherLead]
        let world = World()
        world.roster = [
            LeadVault.RosterEntry(root: root, session: worker.id.uuidString, role: .worker, task: "contract-plan-task-8", holds: false),
            LeadVault.RosterEntry(root: root, session: first.id.uuidString, role: .verifier, task: "contract-plan-task-8", holds: false),
            LeadVault.RosterEntry(root: root, session: second.id.uuidString, role: .verifier, task: "contract-plan-task-8", holds: true,
                                  submittedAt: Self.now.timeIntervalSince1970 - 79_000),
            LeadVault.RosterEntry(root: root, session: running.id.uuidString, role: .worker, task: "publish", holds: true),
        ]
        var board = LeadBoard()
        board.leadSession = lead.id.uuidString
        board.tasks = [task("contract-plan-task-8", .done), task("publish", .running)]
        world.boards = [root: board, other: LeadBoard()]
        let sweep = sweep(world)
        let idle = { (_: HostSession) -> Double? in Self.now.timeIntervalSince1970 - 52_920 }
        let agent = { (session: HostSession) -> (pid: Int32?, memory: Int64?) in (session.childPID, 300_000_000) }

        // The worker and both verifiers, not only the newest; never the lead, the user's shell, a running task's
        // worker or another project's lead. Not told yet: they were just asked to end.
        sweep.look(hosted: sessions, idleSince: idle, agent: agent, now: Self.now)
        #expect(Set(world.ended) == [worker.id, first.id, second.id])
        #expect(world.told.isEmpty)
        #expect(world.submitted == [second.id.uuidString: Self.now.timeIntervalSince1970 - 79_000])

        // Still running a little later: not asked again yet; a minute on, asked again, and told, a line each.
        sweep.look(hosted: sessions, idleSince: idle, agent: agent, now: Self.now + 30)
        #expect(world.ended.count == 3 && world.told.isEmpty)
        sweep.look(hosted: sessions, idleSince: idle, agent: agent, now: Self.now + 61)
        #expect(world.ended.count == 6)
        #expect(world.told.count == 1)
        let lines = try #require(world.told.first).split(separator: "\n")
        #expect(lines.count == 5, "\(world.told)")
        #expect(lines.dropFirst().prefix(3).allSatisfy { $0.hasPrefix("- The ") && $0.contains("on contract-plan-task-8 (project-c): idle 14.7 h, pid 4321, 300 MB") })
        // Once an hour at most.
        sweep.look(hosted: sessions, idleSince: idle, agent: agent, now: Self.now + 1_800)
        #expect(world.told.count == 1)
        sweep.look(hosted: sessions, idleSince: idle, agent: agent, now: Self.now + 61 + 3_600)
        #expect(world.told.count == 2)

        // Ended at last: nothing more to end or tell.
        let gone = sessions.map { session in [worker.id, first.id, second.id].contains(session.id)
            ? HostSession(id: session.id, tty: session.tty, childPID: session.childPID, cwd: session.cwd, command: session.command, label: session.label,
                          agent: session.agent, title: "", startedAt: session.startedAt, cols: 80, rows: 24, exit: HostSession.Exit(status: 129, at: Self.now))
            : session }
        let before = world.ended.count
        sweep.look(hosted: gone, idleSince: idle, agent: agent, now: Self.now + 61 + 7_300)
        #expect(world.ended.count == before && world.told.count == 2)
    }

    /// A host that can't be asked, or doesn't know the roster (older than the app): nothing is ended.
    @Test func noRosterEndsNothing() {
        let session = hosted("Worker: Done", cwd: "/Users/you/dev/project-c/.vibeswitcher/worktrees/done")
        let world = World()
        world.roster = [LeadVault.RosterEntry(root: root, session: session.id.uuidString, role: .worker, task: "done", holds: true)]
        var board = LeadBoard()
        board.tasks = [task("done", .done)]
        world.boards = [root: board]
        world.down = true
        let sweep = sweep(world)
        sweep.look(hosted: [session], idleSince: { _ in 0 }, agent: { _ in (nil, nil) }, now: Self.now)
        #expect(world.ended.isEmpty && world.told.isEmpty)
        world.down = false
        sweep.look(hosted: [session], idleSince: { _ in 0 }, agent: { _ in (nil, nil) }, now: Self.now)
        #expect(world.ended == [session.id])
    }

    /// The roster's bind and tools times reach the witness (see `LeadWitness.Seen.boundAt`): a role holder's only, one
    /// bound by a host that keeps the time.
    @Test func theRostersToolTimesReachTheWitness() {
        let world = World()
        let bound = Self.now.timeIntervalSince1970 - 600
        world.roster = [
            LeadVault.RosterEntry(root: root, session: "never", role: .verifier, task: "t", holds: true, boundAt: bound),
            LeadVault.RosterEntry(root: root, session: "connected", role: .worker, task: "t", holds: true, boundAt: bound, toolsAt: bound + 3),
            LeadVault.RosterEntry(root: root, session: "older-host", role: .worker, task: "u", holds: true),
            LeadVault.RosterEntry(root: root, session: "former", role: .verifier, task: "t", holds: false, boundAt: bound),
        ]
        let sweep = sweep(world)
        var tools: [String: (bound: Double, tools: Double?)] = [:]
        sweep.tools = { tools = $0 }
        sweep.look(hosted: [], idleSince: { _ in nil }, agent: { _ in (nil, nil) }, now: Self.now)
        #expect(Set(tools.keys) == ["never", "connected"])
        #expect(tools["never"]?.bound == bound && tools["never"]?.tools == nil)
        #expect(tools["connected"]?.tools == bound + 3)
    }
}
