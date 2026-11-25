import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// What a refresh does on the engine's queue (`LeadEngine.refreshed`) stays small with a team waiting on the user: the
/// witness tells the lead what each waiting worker waits for, quoted in full with its credentials masked
/// (`PendingPrompt.quoted`, `Redaction.secrets`), and that text is built where it's posted, on the engine's reads queue,
/// once per event; its events, working time and stalls are worked out there too (`WitnessWork`). The app's
/// `WitnessOffMainTests`, both cases, "the main thread" restated as the engine's queue (EN-D1), and
/// `ReplacedLeadRoutingTests`' refresh case. The lead is a `FakeClaude` on a scratch host (`DeliveryWorld`), mid-turn so
/// nothing is typed into it; the team the witness reads is the app's case's (fabricated sessions), handed to
/// `refreshed` as the refresh's reads would.
@Suite(NodeTraits.linuxOnly, .serialized, .timeLimit(.minutes(5)))
struct WitnessOffEngineQueueTests {
    private let scratch = Scratch()
    static let workers = 30

    /// The quotes built, and whether on the engine's queue.
    final class Quotes: @unchecked Sendable {
        private let lock = NSLock()
        private var built: [(text: String, onEngine: Bool)] = []

        func add(_ text: String, onEngine: Bool) {
            lock.lock()
            built.append((text, onEngine))
            lock.unlock()
        }

        /// Of this test's prompts (other tests in the process quote theirs).
        func count(onEngine: Bool) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return built.filter { $0.onEngine == onEngine && $0.text.contains(WitnessOffEngineQueueTests.marker) }.count
        }
    }

    static let marker = "witness-off-engine-\(UUID().uuidString.prefix(8))"

    @Test func aRefreshBuildsNoWaitingWorkersQuoteOnTheEngineQueue() async throws {
        // The engine's notes, for a failure's message: a post that found no lead says so (`lead: holding a message…`).
        let notes = Locked<[String]>([])
        let world = try await DeliveryWorld.make(scratch, note: { line in notes.mutate { $0.append(line) } })
        defer { world.stop() }
        let lead = try await world.lead(idle: false)
        let root = world.repo

        // The board names its lead (who's told) and the workers, each on a running task.
        let now = Date()
        var team = TeamReading()
        let credential = "Authorization: Bearer " + String(repeating: "q1w2e3r4", count: 4)
        try BoardStore(root: root).update { board in
            for index in 0..<Self.workers {
                let id = UUID()
                var task = LeadTask(slug: "task-\(index)", title: "Task \(index)", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""),
                                    status: .running)
                task.worker = id.uuidString
                board.tasks.append(task)
                let tty = "ttypts\(700 + index)"
                let cwd = (root as NSString).appendingPathComponent(".vibeswitcher/worktrees/task-\(index)")
                team.hosted[id.uuidString] = HostSession(id: id, tty: tty, childPID: 62_000 + Int32(index), cwd: cwd, command: "claude",
                                                         label: "Worker: Task \(index)", agent: "claude", title: "Claude", startedAt: now - 1_800,
                                                         cols: 120, rows: 40, exit: nil)
                let prompt = "Run: \(credential) \(Self.marker) \(index) " + String(repeating: "the worker waits on this long command ", count: 55)
                team.sessions[id.uuidString] = Session(tty: tty, agent: .claude, pid: 62_000 + Int32(index), startedAt: now - 1_800, cwd: cwd,
                                                       project: "project", task: nil, status: .needsInput, statusSince: now - 600,
                                                       detail: prompt, hasHooks: true, inTerminalApp: false)
            }
        }
        let board = BoardStore(root: root).load()

        let quotes = Quotes()
        PendingPrompt.quoting = { text, _ in quotes.add(text, onEngine: world.onEngine) }
        defer { PendingPrompt.quoting = nil }

        // Three refreshes, as the clock's: the first tells each waiting worker once, the next tell nothing new.
        var wall: [Double] = []
        for _ in 0..<3 {
            let before = MacTime.real.awake()
            world.queue.sync { world.engine.refreshed(roots: [root], loaded: [root: board], teams: [root: team], refusals: [:]) }
            wall.append((MacTime.real.awake() - before) * 1000)
        }
        print(String(format: "witness: %d workers waiting; engine queue per refresh %.1f, %.1f, %.1f ms; quotes built on it: %d, off it: %d",
                     Self.workers, wall[0], wall[1], wall[2], quotes.count(onEngine: true), quotes.count(onEngine: false)))

        // Each reaches the lead's inbox once, built off the engine's queue, its credential masked.
        func told() -> [SteerMessage] { world.pending(lead).filter { $0.text.contains(Self.marker) } }
        // Refreshed every 2 s meanwhile, as the node's clock does (on a starved CI runner, 2026-11-24, 14 of 30 were told
        // in 120 s with nothing to try the rest again: HeldDeliveryStallTests). The witness tells each worker once.
        let started = MacTime.real.awake()
        while told().count < Self.workers, MacTime.real.awake() - started < 120 {
            if await eventually(timeout: 2, { told().count == Self.workers }) { break }
            world.queue.sync { world.engine.refreshed(roots: [root], loaded: [root: board], teams: [root: team], refusals: [:]) }
        }
        let leadNotes = notes.value.filter { $0.hasPrefix("lead:") }.suffix(12)
        #expect(told().count == Self.workers, "\(told().count) told; the engine's last lead notes: \(Array(leadNotes))")
        await world.drained()
        #expect(told().count == Self.workers)
        #expect(quotes.count(onEngine: true) == 0)
        #expect(quotes.count(onEngine: false) == Self.workers)
        #expect(told().allSatisfy { $0.text.contains("is waiting for input") && !$0.text.contains("q1w2e3r4") })
    }

    /// Which of the witness's computations ran, and whether on the engine's queue (`LeadEngine.witnessStep`).
    final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var ran: [(step: String, onEngine: Bool)] = []

        func add(_ step: String, onEngine: Bool) {
            lock.lock()
            ran.append((step, onEngine))
            lock.unlock()
        }

        var all: [(step: String, onEngine: Bool)] {
            lock.lock()
            defer { lock.unlock() }
            return ran
        }
    }

    /// The witness's events, working time and stalls are worked out on the reads queue (`WitnessWork`): with its stall
    /// computation taking 5 s (a loaded Mac took 7.1 s on the app's main thread, hang-20261028-195651), a refresh holds
    /// the engine's queue under 50 ms, and the stall is still noted on the board and told to the lead, once.
    @Test func aRefreshWorksOutNoneOfTheWitnessesEventsOrStallsOnTheEngineQueue() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead(idle: false)
        let root = world.repo
        let steps = Steps()
        world.queue.sync {
            world.engine.witnessStep = { step in
                steps.add(step, onEngine: world.onEngine)
                // The stall computation, slowed as on a loaded machine.
                if step == "stalls" { Thread.sleep(forTimeInterval: 5) }
            }
        }

        // One worker on a running task, between turns for an hour without having reported: idle, a stall.
        let now = Date()
        let slug = "slow-\(UUID().uuidString.prefix(8).lowercased())"
        let id = UUID()
        var team = TeamReading()
        team.advancing = true
        try BoardStore(root: root).update { board in
            var task = LeadTask(slug: slug, title: "Stalled", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""),
                                status: .running)
            task.worker = id.uuidString
            board.tasks.append(task)
        }
        let tty = "ttypts\(Int.random(in: 700..<800))"
        let cwd = (root as NSString).appendingPathComponent(".vibeswitcher/worktrees/\(slug)")
        team.hosted[id.uuidString] = HostSession(id: id, tty: tty, childPID: 63_000, cwd: cwd, command: "claude", label: "Worker: Stalled",
                                                 agent: "claude", title: "Claude", startedAt: now - 7_200, cols: 120, rows: 40, exit: nil)
        team.sessions[id.uuidString] = Session(tty: tty, agent: .claude, pid: 63_000, startedAt: now - 7_200, cwd: cwd, project: "project",
                                               task: nil, status: .idle, statusSince: now - 3_600, detail: nil, hasHooks: true,
                                               inTerminalApp: false)
        let board = BoardStore(root: root).load()

        // Three refreshes, as the clock's, the third once the first two are applied: the engine's queue waits on none of
        // the witness's work.
        var wall: [Double] = []
        func refresh() {
            let before = MacTime.real.awake()
            world.queue.sync { world.engine.refreshed(roots: [root], loaded: [root: board], teams: [root: team], refusals: [:]) }
            wall.append((MacTime.real.awake() - before) * 1000)
        }
        func applied() -> Int { steps.all.filter { $0.step == "applied" }.count }
        refresh()
        refresh()
        #expect(await eventually(timeout: 120) { applied() == 2 })
        // The reads queue runs one thing at a time: once the third look is applied, what the first two posted is in.
        refresh()
        #expect(await eventually(timeout: 120) { applied() == 3 })
        print(String(format: "witness: a 5 s stall computation; engine queue per refresh %.1f, %.1f, %.1f ms", wall[0], wall[1], wall[2]))
        #expect(wall.allSatisfy { $0 < 50 }, "\(wall)")

        // Every computation ran, off the engine's queue; the looks are applied on it.
        let look = ["withoutTools", "endedForAdvance", "leftToAdvance", "releasableForAdvance", "stopsForAdvance", "unbuiltMessages", "stuckPrompts", "working", "stalls"]
        #expect(steps.all.filter { $0.step != "applied" }.map(\.step) == look + look + look)
        #expect(steps.all.allSatisfy { $0.onEngine == ($0.step == "applied") })
        // The stall is on the board, and told to the lead once.
        func told() -> [SteerMessage] { world.pending(lead).filter { $0.text.contains("The worker on \(slug) is stalled:") } }
        #expect(await eventually(timeout: 60) { BoardStore(root: root).load().task(slug)?.stall?.reason == .idle })
        #expect(await eventually(timeout: 60) { told().count == 1 })
        await world.drained()
        #expect(told().count == 1)
        // That it stopped without calling report goes to auto_advance, its loop running: recorded on the board for it to
        // nudge the worker once (`LeadStopNudge`), and not told to the lead (main's 3516b53c).
        #expect(await eventually(timeout: 60) { BoardStore(root: root).load().task(slug)?.stopNudge?.worker == id.uuidString })
        #expect(world.pending(lead).filter { $0.text.contains(slug) }.count == 1, "\(world.pending(lead).map(\.text))")
    }

    /// ReplacedLeadRoutingTests' refresh case (hang-20261027-175604: the 3 s refresh marked the replaced leads with a
    /// stat of each board on the app's main thread): of two leads sharing the root, which one the board names is read
    /// on the reads queue, and the engine's store marks the other replaced with what it says.
    @Test func theRefreshReadsWhichLeadHoldsTheRoleOffTheEngineQueue() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let old = try await world.lead(idle: false)
        // A second lead session for the same root, which the board names: the first is replaced by it.
        let new = try await NodeHarness.start(on: world.host, fake: world.fake, cwd: world.repo, label: "Lead · \(world.name)")
        func name(_ lead: NodeHarness) throws {
            let pid = try #require(lead.agentPid)
            try BoardStore(root: world.repo).update { board in
                board.leadSession = lead.session.id.uuidString
                board.leadPid = pid
                board.leadTTY = lead.session.tty
            }
        }
        try name(new)
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { world.stored?.replaced[old.session.id] == new.session.id }, "\(String(describing: world.stored))")
        let looks = Locked<[(root: String, onEngine: Bool)]>([])
        world.queue.sync { world.engine.boardLooked = { root in looks.mutate { $0.append((root, world.onEngine)) } } }
        // The role goes back to the old lead: only a read of the board marks the new one replaced now.
        try name(old)
        world.engine.refresh()
        #expect(await eventually(timeout: 60) {
            world.stored?.replaced[new.session.id] == old.session.id && world.stored?.replaced[old.session.id] == nil
        }, "\(String(describing: world.stored))")
        #expect(!looks.value.contains { $0.onEngine }, "\(looks.value)")
        #expect(looks.value.contains { $0.root == world.repo && !$0.onEngine }, "\(looks.value)")
    }
}
