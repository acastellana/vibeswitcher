import AppKit
import Combine
import Darwin
import SwiftUI
import VibeCore

/// Debug aid and test (`CFFIXED_USER_HOME=<scratch> VibeSwitcher --board-bench [ROUNDS]`): what refreshing a big
/// board costs the window's main thread. One project lead (a made-up agent in a session of a private session host, on
/// its own socket and lock) with a board like a long day leaves (50 tasks, each with a report of several KB, and the
/// lead's 50 reports: 900 KB), and the lead controller. Each round the lead's tools rewrite the board and add a
/// decision from another thread, and the controller refreshes as its heartbeat does. A watchdog posts to the main
/// thread every 5 ms: the longest wait is the main thread's longest block.
/// 1. another session shown (as when the window stalled: the lead's views off screen): the refresh's longest block
///    must be under 50 ms, and no board read on the main thread.
/// 2. the lead shown: its views (the team strip over its chat, the Team tab with its decisions feed and task list) in
///    an off-screen window must show each round's board; what drawing them costs is shown (that's SwiftUI drawing 50
///    tasks, not a board read), then SwiftUI's "Publishing changes from background threads" faults are counted from
///    the log: none.
/// Prints `longest main-thread block: N ms` and exits 1 when a check fails.
enum BoardBench {
    /// The most a refresh of a big board may block the main thread.
    static let budget: TimeInterval = 0.05

    static func run(arguments: [String]) -> Never {
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? ""
        guard NSHomeDirectory() != realHome else {
            print("--board-bench runs on a scratch home only: set CFFIXED_USER_HOME to an empty folder.")
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        VibePaths.ensurePrivateDirectories()
        let bench = Bench(rounds: arguments.first.flatMap(Int.init) ?? 8)
        bench.start()
        app.run()
        exit(0)
    }

    /// A long day's board: UIBench's, every task with a report of several KB, and the lead's reports.
    static func board(seed: Int) -> LeadBoard {
        var board = UIBench.board(tasks: 50, seed: seed)
        let words = ["the", "worker", "ran", "the", "suite", "twice", "on", "a", "scratch", "home", "and", "every", "check",
                     "passed;", "the", "verifier", "read", "the", "diff", "line", "by", "line", "before", "the", "merge."]
        func prose(_ count: Int, _ salt: Int) -> String {
            (0..<count).map { words[($0 * 11 + salt * 5) % words.count] }.joined(separator: " ")
        }
        for index in board.tasks.indices { board.tasks[index].report = prose(1300, index) }
        board.reports = (0..<LeadBoard.keptReports).map { LeadReport(about: "worker task-\($0)", text: prose(400, $0)) }
        return board
    }

    /// The main thread's longest block: a thread posts to it every 5 ms and measures how long each post waits to run,
    /// as the main thread's own CPU time while it waited (on a loaded Mac the wall clock mostly measures the
    /// scheduler; the wall clock's longest wait is kept too, for reading). Made on the main thread.
    final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var longest: (cpu: TimeInterval, wall: TimeInterval) = (0, 0)
        private var running = true
        private let main = mach_thread_self()

        /// The main thread's CPU time so far, user and system.
        private func mainCPU() -> TimeInterval {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(main, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
            }
            guard result == KERN_SUCCESS else { return 0 }
            return TimeInterval(info.user_time.seconds + info.system_time.seconds)
                + TimeInterval(info.user_time.microseconds + info.system_time.microseconds) / 1e6
        }

        init() {
            dispatchPrecondition(condition: .onQueue(.main))
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock()
                    let go = running
                    lock.unlock()
                    guard go else { return }
                    let cpu = mainCPU()
                    let posted = DispatchTime.now().uptimeNanoseconds
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async {
                        let waited = TimeInterval(DispatchTime.now().uptimeNanoseconds - posted) / 1e9
                        let busy = self.mainCPU() - cpu
                        self.lock.lock()
                        self.longest = (max(self.longest.cpu, busy), max(self.longest.wall, waited))
                        self.lock.unlock()
                        done.signal()
                    }
                    done.wait()
                    usleep(5000)
                }
            }
        }

        /// The longest block since the last call, and the longest wait on the wall clock.
        func take() -> (cpu: TimeInterval, wall: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            let value = longest
            longest = (0, 0)
            return value
        }

        func stop() {
            lock.lock()
            running = false
            lock.unlock()
        }
    }

    /// The lead's views as the window shows them: the team strip over its chat, and the Team tab.
    struct LeadPanes: View {
        @ObservedObject var leads: LeadController
        let root: String

        var body: some View {
            if let board = leads.boards[root] {
                VStack(spacing: 0) {
                    TeamStrip(board: board) { _ in }
                    LeadTeamPane(root: root, board: board, decisions: leads.decisions[root] ?? [], seen: [:], open: { _ in },
                                 answer: { question, text in leads.answer(question, root: root, with: text) }, notices: leads.answerNotices,
                                 summaries: leads.summaries)
                }
            } else {
                Text("No lead")
            }
        }
    }

    private final class Bench {
        let rounds: Int
        let root = (NSHomeDirectory() as NSString).appendingPathComponent("lead-bench")
        let socket = "/tmp/vsb-\(UUID().uuidString.prefix(8)).sock"
        let hostPath = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
        var hostProcess: Process?
        let host: HostClient
        let store: SessionStore
        lazy var leads = LeadController(host: host, store: store) { _ in "claude" }
        var window: NSWindow?
        var watchdog: Watchdog?
        var failures: [String] = []
        var longest: TimeInterval = 0
        var wall: TimeInterval = 0
        var readsBefore = 0
        let started = Date()

        init(rounds: Int) {
            self.rounds = rounds
            host = HostClient(socketPath: socket, appKey: { nil }, bundledBuild: { [hostPath] in HostBuild.id(ofExecutableAt: hostPath) })
            store = SessionStore(scanner: SessionScanner(processes: { [:] }, cwd: { _ in nil }, arguments: { _ in [] }))
        }

        func check(_ ok: Bool, _ text: String) {
            print("\(ok ? "PASS" : "FAIL")  \(text)")
            fflush(stdout)
            if !ok { failures.append(text) }
        }

        func start() {
            let store = BoardStore(root: root)
            try? store.update { $0 = BoardBench.board(seed: 0) }
            try? UIBench.decisions(count: 30, newest: started.addingTimeInterval(-3600))
                .write(toFile: (store.folder as NSString).appendingPathComponent("decisions.md"), atomically: true, encoding: .utf8)
            let size = ((try? FileManager.default.attributesOfItem(atPath: (store.folder as NSString).appendingPathComponent("board.json")))?[.size] as? Int) ?? 0
            print(String(format: "board bench: a board of %.0f KB, %d rounds", Double(size) / 1024, rounds))
            fflush(stdout)
            // A private host: its own socket and lock, the scratch home's files, gone with the bench.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: hostPath)
            process.arguments = ["--socket", socket, "--lock", socket + ".lock", "--idle-exit", "60"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return finish("the host didn't start: \(error)") }
            hostProcess = process
            connect(attempts: 100)
        }

        private func connect(attempts: Int) {
            host.connectIfRunning()
            if host.state == .connected { return spawnLead() }
            guard attempts > 0 else { return finish("the host never answered") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.connect(attempts: attempts - 1) }
        }

        private func spawnLead() {
            _ = leads
            // The session ends with the bench, however it ends: the host then quits on its idle exit.
            host.spawn(SpawnRequest(cwd: root, command: "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 1; done", env: [:], cols: 120, rows: 40, keepShell: false,
                                    label: "Lead · lead-bench", agent: "claude")) { result in
                guard case .success = result else { return self.finish("the lead's session didn't start") }
                self.openWindow()
            }
        }

        private func openWindow() {
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 420, height: 900), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.orderFrontRegardless()
            self.window = window
            // The first look, before anything is measured.
            leads.refresh()
            wait(until: { self.leads.boards[self.root]?.tasks.count == 50 }, then: {
                print("another session shown (the lead's views off screen):")
                self.watchdog = Watchdog()
                self.readsBefore = BoardStore.readsOnMainThread
                self.round(0, then: self.measured)
            }, else: "the board never showed")
        }

        /// Phase 1 measured: the refresh's longest block, and no board read on the main thread.
        private func measured() {
            let reads = BoardStore.readsOnMainThread - readsBefore
            print(String(format: "longest main-thread block: %.0f ms (the longest wait on the wall clock: %.0f ms)", longest * 1000, wall * 1000))
            print("boards read on the main thread: \(reads)")
            check(longest < BoardBench.budget, String(format: "a refresh of the board blocks the main thread %.0f ms (under %.0f ms)",
                                                     longest * 1000, BoardBench.budget * 1000))
            check(reads == 0, "\(reads) board(s) read on the main thread (none)")
            showLead()
        }

        /// Phase 2: the lead's views on screen, drawn whole once (switching to the lead isn't what's measured), then
        /// the same rounds; each must show its board.
        private func showLead() {
            window?.contentView = NSHostingView(rootView: LeadPanes(leads: leads, root: root))
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.contentView?.display()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("the lead shown (its views drawn each round; not checked: SwiftUI drawing 50 tasks):")
                _ = self.watchdog?.take()
                self.readsBefore = BoardStore.readsOnMainThread
                self.round(0, drawn: true) {
                    let reads = BoardStore.readsOnMainThread - self.readsBefore
                    print("boards read on the main thread: \(reads)")
                    self.check(reads == 0, "\(reads) board(s) read on the main thread with the lead shown (none)")
                    self.watchdog?.stop()
                    self.countFaults()
                }
            }
        }

        /// The lead's tools write the board and a decision (another thread, as another process does); the controller
        /// refreshes as its heartbeat does; it must have the new board and decisions (what the views show).
        private func round(_ index: Int, drawn: Bool = false, then done: @escaping () -> Void) {
            guard index < rounds else { return done() }
            let root = root
            DispatchQueue.global(qos: .utility).async {
                let store = BoardStore(root: root)
                try? store.update { board in
                    board.tasks[0].title = "Round \(index)\(drawn ? " drawn" : "")"
                    board.tasks[index % board.tasks.count].checkpoints?.append(LeadCheckpoint(text: "checkpoint \(index)"))
                    board.reports = ((board.reports ?? []) + [LeadReport(about: "worker task-\(index)", text: "round \(index)")])
                        .suffix(LeadBoard.keptReports)
                }
                try? store.appendDecision("Decision at round \(index)\(drawn ? " drawn" : "")", why: "The bench's lead decided.")
                DispatchQueue.main.async {
                    self.leads.refresh()
                    self.wait(until: {
                        self.leads.boards[root]?.tasks.first?.title == "Round \(index)\(drawn ? " drawn" : "")"
                            && self.leads.decisions[root]?.last?.text == "Decision at round \(index)\(drawn ? " drawn" : "")"
                    }, then: {
                        if drawn {
                            self.window?.contentView?.layoutSubtreeIfNeeded()
                            self.window?.contentView?.display()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.fold("round \(index)", keep: !drawn)
                            self.round(index + 1, drawn: drawn, then: done)
                        }
                    }, else: "round \(index)'s board never showed\(drawn ? " with the lead shown" : "")")
                }
            }
        }

        /// The longest block since the last look, printed for the round; kept for the check when `keep`.
        private func fold(_ what: String, keep: Bool) {
            guard let taken = watchdog?.take() else { return }
            if keep {
                longest = max(longest, taken.cpu)
                wall = max(wall, taken.wall)
            }
            print(String(format: "  %@: longest block %.0f ms (wall %.0f ms)", what, taken.cpu * 1000, taken.wall * 1000))
            fflush(stdout)
        }

        private func wait(until condition: @escaping () -> Bool, then: @escaping () -> Void, else failure: String, tries: Int = 1500) {
            if condition() { return then() }
            guard tries > 0 else { return finish(failure) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self.wait(until: condition, then: then, else: failure, tries: tries - 1) }
        }

        /// SwiftUI's faults in this process since it started, from the unified log (it takes a moment to be written).
        private func countFaults() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let log = Process()
                log.executableURL = URL(fileURLWithPath: "/usr/bin/log")
                log.arguments = ["show", "--style", "compact", "--start", formatter.string(from: self.started.addingTimeInterval(-1)),
                                 "--predicate", "processID == \(getpid()) AND eventMessage CONTAINS \"Publishing changes from background threads\""]
                let pipe = Pipe()
                log.standardOutput = pipe
                log.standardError = FileHandle.nullDevice
                DispatchQueue.global().async {
                    try? log.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    log.waitUntilExit()
                    let faults = String(decoding: data, as: UTF8.self).split(separator: "\n")
                        .filter { $0.contains("Publishing changes from background threads") }.count
                    DispatchQueue.main.async {
                        print("publishing faults: \(faults)")
                        self.check(faults == 0, "\(faults) 'Publishing changes from background threads' faults")
                        self.finish(nil)
                    }
                }
            }
        }

        private func finish(_ failure: String?) {
            if let failure { check(false, failure) }
            hostProcess?.terminate()
            hostProcess?.waitUntilExit()
            unlink(socket)
            unlink(socket + ".lock")
            print(failures.isEmpty ? "board bench: all checks passed" : "board bench: \(failures.count) check(s) failed")
            fflush(stdout)
            exit(failures.isEmpty ? 0 : 1)
        }
    }
}
