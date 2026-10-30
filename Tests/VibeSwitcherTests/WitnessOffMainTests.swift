import Darwin
import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// What a refresh does on the main thread (`LeadController.refreshed`) stays small with a team waiting on you: the
/// witness tells the lead what each waiting worker waits for, quoted in full with its credentials masked
/// (`PendingPrompt.quoted`, `Redaction.secrets`), and that text is built where it's posted, on the boards' queue, once
/// per event. Built on the main thread for every waiting worker at every refresh, told or not, it took up to a second a
/// refresh on a loaded Mac (hang-20261027-201145) and held End Session…'s alert for tens of seconds (10-27, 21:09).
/// Here 30 workers wait on prompts of 2,000 characters; no session host runs (the controller's client has none).
@MainActor
@Suite(.serialized)
struct WitnessOffMainTests {
    let temp = Scratch()
    static let workers = 30

    /// The quotes built, and on which thread.
    final class Quotes: @unchecked Sendable {
        private let lock = NSLock()
        private var built: [(text: String, main: Bool)] = []

        func add(_ text: String, main: Bool) {
            lock.lock()
            built.append((text, main))
            lock.unlock()
        }

        /// Of this test's prompts (other tests in the process quote theirs).
        func count(main: Bool) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return built.filter { $0.main == main && $0.text.contains(WitnessOffMainTests.marker) }.count
        }
    }

    nonisolated static let marker = "witness-off-main-\(UUID().uuidString.prefix(8))"

    @Test func aRefreshBuildsNoWaitingWorkersQuoteOnTheMainThread() async throws {
        AppStatus.enabled = false
        let folder = temp.url("witness-off-main")
        let root = folder.appendingPathComponent("project").path
        let inbox = folder.appendingPathComponent("inbox")
        let stateDir = folder.appendingPathComponent("state")
        for dir in [root, inbox.path, stateDir.path] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let host = HostClient(socketPath: folder.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { stateDir }, cwd: { _ in nil }, arguments: { _ in [] }))
        let vault = LeadVault(folder: folder.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") })
        let controller = LeadController(host: host, store: store, vault: vault, inbox: inbox, home: folder.path) { _ in "true" }
        controller.answersTrust = false
        controller.leadRuns = { _ in true }

        // The board names its lead (who's told) and the workers, each on a running task.
        let now = Date()
        let leadTTY = "ttys\(Int.random(in: 600..<700))"
        var team = TeamReading()
        let credential = "Authorization: Bearer " + String(repeating: "q1w2e3r4", count: 4)
        try BoardStore(root: root).update { board in
            board.leadPid = 61_000
            board.leadTTY = leadTTY
            board.leadSession = UUID().uuidString
            for index in 0..<Self.workers {
                let id = UUID()
                var task = LeadTask(slug: "task-\(index)", title: "Task \(index)", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""),
                                    status: .running)
                task.worker = id.uuidString
                board.tasks.append(task)
                let tty = "ttys\(700 + index)"
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
        PendingPrompt.quoting = { text, main in quotes.add(text, main: main) }
        defer { PendingPrompt.quoting = nil }

        // Three refreshes, as the heartbeat's: the first tells each waiting worker once, the next tell nothing new.
        var cpu: [Double] = []
        for _ in 0..<3 {
            let before = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            controller.refreshed(roots: [root], fired: [:], loaded: [root: board], decisions: [:], teams: [root: team], refusals: [:])
            cpu.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - before) / 1_000_000)
        }
        print(String(format: "witness: %d workers waiting; main thread per refresh %.1f, %.1f, %.1f ms; quotes built on it: %d, off it: %d",
                     Self.workers, cpu[0], cpu[1], cpu[2], quotes.count(main: true), quotes.count(main: false)))

        // Each reaches the lead's inbox once, built off the main thread, its credential masked.
        func told() -> [SteerMessage] { SteerInbox.pending(tty: leadTTY, root: inbox).filter { $0.text.contains(Self.marker) } }
        #expect(await until { told().count == Self.workers })
        #expect(quotes.count(main: true) == 0)
        #expect(quotes.count(main: false) == Self.workers)
        #expect(told().allSatisfy { $0.text.contains("is waiting for input") && !$0.text.contains("q1w2e3r4") })
    }

    /// Which of the witness's computations ran, and on which thread (`LeadController.witnessStep`).
    final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var ran: [(step: String, main: Bool)] = []

        func add(_ step: String, main: Bool) {
            lock.lock()
            ran.append((step, main))
            lock.unlock()
        }

        var all: [(step: String, main: Bool)] {
            lock.lock()
            defer { lock.unlock() }
            return ran
        }
    }

    /// The witness's events, working time and stalls are worked out on the boards' queue (`WitnessWork`): with its
    /// stall computation taking 5 s (a loaded Mac took 7.1 s on the main thread, hang-20261028-195651), a refresh
    /// holds the main thread under 50 ms, and the stall is still noted on the board and told to the lead, once.
    @Test func aRefreshWorksOutNoneOfTheWitnessesEventsOrStallsOnTheMainThread() async throws {
        AppStatus.enabled = false
        let folder = temp.url("witness-stalls-off-main")
        let root = folder.appendingPathComponent("project").path
        let inbox = folder.appendingPathComponent("inbox")
        let stateDir = folder.appendingPathComponent("state")
        for dir in [root, inbox.path, stateDir.path] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let host = HostClient(socketPath: folder.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { stateDir }, cwd: { _ in nil }, arguments: { _ in [] }))
        let vault = LeadVault(folder: folder.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") })
        let controller = LeadController(host: host, store: store, vault: vault, inbox: inbox, home: folder.path) { _ in "true" }
        controller.answersTrust = false
        controller.leadRuns = { _ in true }
        let steps = Steps()
        controller.witnessStep = { step in
            steps.add(step, main: Thread.isMainThread)
            // The stall computation, slowed as on a loaded Mac.
            if step == "stalls" { Thread.sleep(forTimeInterval: 5) }
        }

        // One worker on a running task, between turns for an hour without having reported: idle, a stall.
        let now = Date()
        let leadTTY = "ttys\(Int.random(in: 600..<700))"
        let slug = "slow-\(UUID().uuidString.prefix(8).lowercased())"
        let id = UUID()
        var team = TeamReading()
        team.advancing = true
        try BoardStore(root: root).update { board in
            board.leadPid = 61_000
            board.leadTTY = leadTTY
            board.leadSession = UUID().uuidString
            var task = LeadTask(slug: slug, title: "Stalled", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""),
                                status: .running)
            task.worker = id.uuidString
            board.tasks.append(task)
        }
        let tty = "ttys\(Int.random(in: 700..<800))"
        let cwd = (root as NSString).appendingPathComponent(".vibeswitcher/worktrees/\(slug)")
        team.hosted[id.uuidString] = HostSession(id: id, tty: tty, childPID: 63_000, cwd: cwd, command: "claude", label: "Worker: Stalled",
                                                 agent: "claude", title: "Claude", startedAt: now - 7_200, cols: 120, rows: 40, exit: nil)
        team.sessions[id.uuidString] = Session(tty: tty, agent: .claude, pid: 63_000, startedAt: now - 7_200, cwd: cwd, project: "project",
                                               task: nil, status: .idle, statusSince: now - 3_600, detail: nil, hasHooks: true,
                                               inTerminalApp: false)
        let board = BoardStore(root: root).load()

        // Three refreshes, as the heartbeat's, the third once the first two are applied: the main thread waits on none
        // of the witness's work.
        var wall: [Double] = []
        func refresh() {
            let before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            controller.refreshed(roots: [root], fired: [:], loaded: [root: board], decisions: [:], teams: [root: team], refusals: [:])
            wall.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - before) / 1_000_000)
        }
        func applied() -> Int { steps.all.filter { $0.step == "applied" }.count }
        refresh()
        refresh()
        #expect(await until { applied() == 2 })
        // The boards' queue runs one thing at a time: once the third look is applied, what the first two posted is in.
        refresh()
        #expect(await until { applied() == 3 })
        print(String(format: "witness: a 5 s stall computation; main thread per refresh %.1f, %.1f, %.1f ms", wall[0], wall[1], wall[2]))
        #expect(wall.allSatisfy { $0 < 50 })

        // Every computation ran, off the main thread; the looks are applied on it.
        let look = ["withoutTools", "endedForAdvance", "leftToAdvance", "unbuiltMessages", "working", "stalls"]
        #expect(steps.all.filter { $0.step != "applied" }.map(\.step) == look + look + look)
        #expect(steps.all.allSatisfy { $0.main == ($0.step == "applied") })
        // The stall is on the board, and told to the lead once.
        func told() -> [SteerMessage] { SteerInbox.pending(tty: leadTTY, root: inbox).filter { $0.text.contains("The worker on \(slug) is stalled:") } }
        #expect(await until { BoardStore(root: root).load().tasks.first?.stall?.reason == .idle })
        #expect(told().count == 1)
        // As is that it stopped without calling report: two events, each told once.
        #expect(SteerInbox.pending(tty: leadTTY, root: inbox).filter { $0.text.contains(slug) }.count == 2)
    }
}
