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
/// 2. the team at work: 30 workers, each a session with a transcript of a few MB (its hooks name it), as the witness
///    reads them each refresh (see `LeadController.witness`): the refresh's longest block must be under 50 ms, and no
///    transcript read on the main thread.
/// 3. the lead shown: its views (the team strip over its chat, the Team tab with its decisions feed and task list) in
///    an off-screen window must show each round's board; what drawing them costs is shown (that's SwiftUI drawing 50
///    tasks, not a board read), then SwiftUI's "Publishing changes from background threads" faults are counted from
///    the log: none.
/// Prints `longest main-thread block: N ms` and exits 1 when a check fails.
enum BoardBench {
    /// The most a refresh of a big board may block the main thread.
    static let budget: TimeInterval = 0.05
    /// The team of phase 2, and how big each of its transcripts is.
    static let teamSize = 30
    static let transcriptBytes = 3 * 1024 * 1024

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

    /// A long session's transcript, `bytes` of it: tool calls and their results (a few KB each), every line stamped,
    /// the last a few seconds before `now`.
    static func transcript(bytes: Int, now: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let output = String(repeating: "Test Case passed (0.012 seconds); ", count: 140)
        var lines: [[String: Any]] = []
        var size = 0
        while size < bytes {
            let index = lines.count / 2
            let call: [String: Any] = ["type": "assistant", "isSidechain": false, "uuid": UUID().uuidString,
                                       "message": ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_\(index)", "name": "Bash",
                                                                                     "input": ["command": "swift test --filter Case\(index)", "description": "Run the tests"]]]]]
            let result: [String: Any] = ["type": "user", "isSidechain": false, "uuid": UUID().uuidString,
                                         "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_\(index)", "content": output]]]]
            lines += [call, result]
            size += output.utf8.count + 400
        }
        var data = Data()
        for (index, line) in lines.enumerated() {
            var line = line
            line["timestamp"] = formatter.string(from: now.addingTimeInterval(Double(index - lines.count) * 2))
            data += (try? JSONSerialization.data(withJSONObject: line)) ?? Data()
            data.append(0x0A)
        }
        return data
    }

    /// The team's agents, made up: one `claude` process per terminal, as the scan sees them.
    final class Agents: @unchecked Sendable {
        private let lock = NSLock()
        private var ttys: [String: Int32] = [:]
        private let started = Date()

        func add(tty: String, pid: Int32) {
            lock.lock()
            ttys[tty] = pid
            lock.unlock()
        }

        func table() -> [Int32: ProcInfo] {
            lock.lock()
            defer { lock.unlock() }
            var procs = [ProcInfo(pid: 59999, ppid: 1, tty: nil, comm: "vibeswitcher-hos", startTime: started, agent: nil)]
            for (tty, pid) in ttys {
                procs.append(ProcInfo(pid: pid, ppid: 59999, tty: tty, comm: "claude", startTime: started, agent: .claude))
            }
            return Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
        }
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
        @ObservedObject var host: HostClient
        let root: String

        var body: some View {
            if let board = leads.boards[root] {
                VStack(spacing: 0) {
                    TeamStrip(board: board) { _ in }
                    LeadTeamPane(root: root, board: board, decisions: leads.decisions[root] ?? [], seen: [:], open: { _ in },
                                 answer: { question, text in leads.answer(question, root: root, with: text) }, notices: leads.answerNotices,
                                 summaries: leads.summaries, keepAwake: leads.keepAwake, hosted: host.sessions)
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
        let agents = Agents()
        var wiring: AnyCancellable?
        /// The team's sessions (phase 2).
        var team: [HostSession] = []
        var transcriptsBefore = TranscriptTail.reads
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
            store = SessionStore(scanner: SessionScanner(processes: { [agents] in agents.table() }, cwd: { [root] _ in root }, arguments: { _ in [] }))
            wiring = host.$sessions.receive(on: DispatchQueue.main).sink { [store] in store.updateHosted($0) }
        }

        func check(_ ok: Bool, _ text: String) {
            print("\(ok ? "PASS" : "FAIL")  \(text)")
            fflush(stdout)
            if !ok { failures.append(text) }
        }

        func start() {
            let store = BoardStore(root: root)
            try? store.update { $0 = BoardBench.board(seed: 0) }
            try? store.replaceRecord("decisions.md", with: UIBench.decisions(count: 30, newest: started.addingTimeInterval(-3600)))
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
            startTeam()
        }

        /// Phase 2: the team's sessions, their transcripts (named by their hooks), and the board naming them workers.
        private func startTeam() {
            print(String(format: "the team at work (%d workers, a transcript of %.0f MB each; the lead's views off screen):",
                         BoardBench.teamSize, Double(BoardBench.transcriptBytes) / 1048576))
            fflush(stdout)
            spawnTeam(0)
        }

        private func spawnTeam(_ index: Int) {
            guard index < BoardBench.teamSize else { return teamStarted() }
            host.spawn(SpawnRequest(cwd: root, command: "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 1; done", env: [:], cols: 120, rows: 40,
                                    keepShell: false, label: "task-\(index)", agent: "claude")) { result in
                guard case .success(let session) = result else { return self.finish("team session \(index) didn't start") }
                self.team.append(session)
                self.spawnTeam(index + 1)
            }
        }

        private func teamStarted() {
            let now = Date()
            let folder = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects/\(RecentProjects.claudeSlug(for: root))")
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let transcript = BoardBench.transcript(bytes: BoardBench.transcriptBytes, now: now)
            for (index, session) in team.enumerated() {
                let pid = Int32(60000 + index)
                let path = (folder as NSString).appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl")
                FileManager.default.createFile(atPath: path, contents: transcript)
                var hook = HookState(agent: .claude, tty: session.tty, lastEvent: "PostToolUse", lastEventAt: now.timeIntervalSince1970)
                hook.agentPid = pid
                hook.transcriptPath = path
                try? hook.save(to: VibePaths.stateFile(tty: session.tty))
                agents.add(tty: session.tty, pid: pid)
            }
            let ids = team.map(\.id.uuidString)
            try? BoardStore(root: root).update { board in
                for (index, id) in ids.enumerated() {
                    board.tasks[index].status = .running
                    board.tasks[index].worker = id
                    board.tasks[index].verifier = nil
                }
            }
            store.refresh()
            leads.refresh()
            wait(until: {
                Set(self.store.sessions.compactMap { $0.hostID?.uuidString }).isSuperset(of: ids)
                    && self.leads.boards[self.root]?.tasks.prefix(ids.count).compactMap(\.worker) == ids
            }, then: {
                // A look with the team in it, before anything is measured.
                self.leads.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    _ = self.watchdog?.take()
                    self.longest = 0
                    self.wall = 0
                    self.transcriptsBefore = TranscriptTail.reads
                    self.round(0, team: true, then: self.teamMeasured)
                }
            }, else: "the team never showed on the board and in the scan")
        }

        /// Phase 2 measured: the refresh's longest block with the witness reading the team, and no transcript read on
        /// the main thread.
        private func teamMeasured() {
            let now = TranscriptTail.reads
            let all = now.all - transcriptsBefore.all
            let onMain = now.onMainThread - transcriptsBefore.onMainThread
            print(String(format: "with the team: longest main-thread block: %.0f ms (the longest wait on the wall clock: %.0f ms)", longest * 1000, wall * 1000))
            print("transcripts read: \(all), on the main thread: \(onMain)")
            check(longest < BoardBench.budget, String(format: "a refresh with the team blocks the main thread %.0f ms (under %.0f ms)",
                                                     longest * 1000, BoardBench.budget * 1000))
            check(all >= BoardBench.teamSize * rounds, "the witness read the team's transcripts each round (\(all) reads)")
            check(onMain == 0, "\(onMain) transcript(s) read on the main thread (none)")
            showLead()
        }

        /// Phase 2: the lead's views on screen, drawn whole once (switching to the lead isn't what's measured), then
        /// the same rounds; each must show its board.
        private func showLead() {
            window?.contentView = NSHostingView(rootView: LeadPanes(leads: leads, host: host, root: root))
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
        private func round(_ index: Int, drawn: Bool = false, team: Bool = false, then done: @escaping () -> Void) {
            guard index < rounds else { return done() }
            let title = "Round \(index)\(drawn ? " drawn" : team ? " with the team" : "")"
            let root = root
            DispatchQueue.global(qos: .utility).async {
                let store = BoardStore(root: root)
                try? store.update { board in
                    board.tasks[0].title = title
                    board.tasks[index % board.tasks.count].checkpoints?.append(LeadCheckpoint(text: "checkpoint \(index)"))
                    board.reports = ((board.reports ?? []) + [LeadReport(about: "worker task-\(index)", text: "round \(index)")])
                        .suffix(LeadBoard.keptReports)
                }
                try? store.appendDecision("Decision at round \(index)\(drawn ? " drawn" : team ? " with the team" : "")", why: "The bench's lead decided.")
                DispatchQueue.main.async {
                    self.leads.refresh()
                    self.wait(until: {
                        self.leads.boards[root]?.tasks.first?.title == title
                            && self.leads.decisions[root]?.last?.text == "Decision at round \(index)\(drawn ? " drawn" : team ? " with the team" : "")"
                    }, then: {
                        if drawn {
                            self.window?.contentView?.layoutSubtreeIfNeeded()
                            self.window?.contentView?.display()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.fold("round \(index)", keep: !drawn)
                            self.round(index + 1, drawn: drawn, team: team, then: done)
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
