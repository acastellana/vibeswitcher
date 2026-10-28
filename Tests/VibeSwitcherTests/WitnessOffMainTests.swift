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
}
