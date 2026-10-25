import AppKit
import Combine
import Darwin
import SwiftUI
import VibeCore

/// Debug aid (`CFFIXED_USER_HOME=<scratch> VibeSwitcher --ui-bench [MINUTES] [--onscreen] [--ticking] [--transcript PATH]`):
/// the window as you use it, on a scratch home. Two project leads (made-up agents in two sessions of a private session
/// host, each with a big board like a day's work leaves), one session's screen full of styled text. Three phases:
/// 1. clicks: the sidebar's rows clicked (as the mouse does), chat and terminal switched, then the host restarted the
///    way an outdated one is (its sessions ended one by one, then replaced) and the leads started again. SwiftUI's
///    "Publishing changes from within view updates" and "occurs multiple times" faults are counted from the log, and
///    what a switch between the leads costs, in instructions (time depends on how busy the Mac is; stalls are shown).
/// 2. busy leads: their boards rewritten every few seconds and a decision added (by another process), as leads at work
///    do: CPU, instructions and the main thread's longest stall, shown.
/// 3. idle: MINUTES (default 5) of nothing happening: CPU and instructions each minute and on average, and memory after
///    the first minute. The average instructions/s is printed as `RESULT idle-instructions-per-second N` for
///    scripts/ui-bench.sh, which judges it against a base build's.
/// It exits 1 when a check fails. The window is off screen unless `--onscreen` (then it shows, without taking focus).
/// `--ticking` has the busy screen redraw a line each second. For narrowing a cost down: VIBESWITCHER_BENCH_INSPECTOR
/// (team, overview or activity: the inspector's tab, team by default) and VIBESWITCHER_BENCH_RESULTS (the results on
/// each board, 32 by default).
///
/// `--soak MINUTES [--soak-workers N] [--soak-upserts PER_SECOND] [--soak-without hooks,boards,transcripts,switches]` (memory, 2026-10-25): instead of the three phases, a
/// working day's traffic for MINUTES, to see whether the footprint levels off. Beside the two leads, N (6) made-up
/// workers whose sessions retitle themselves (`sessionChanged` from the host, PER_SECOND (2) in all), their agents' hook events (one a second), the leads' boards written and a decision added every 10 s (by
/// another process), every transcript growing a turn every 5 s, and the window switching to the next session, on its
/// chat, every 30 s. Each minute: the footprint, malloc's bytes in use and the live views and chats; every 10 minutes
/// (and at the end) what grew since the second minute, by vmmap's region categories and by class (`HeapCensus`). At the
/// end, `RESULT soak-…` lines and a check: over the last 20 minutes each minute's least footprint (read every 5 s)
/// within ±50 MB of their median (a run of 25 minutes or more).
enum UIBench {
    static func run(arguments: [String]) -> Never {
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? ""
        guard NSHomeDirectory() != realHome, !VibePaths.isAccountRoot(VibePaths.root, accountHome: realHome) else {
            print("--ui-bench runs on a scratch home only: set CFFIXED_USER_HOME to an empty folder (and VIBESWITCHER_HOME, if set, "
                  + "to one other than your ~/.vibeswitcher).")
            exit(1)
        }
        // The lead's chat and Team tab while the host's sessions change (see `TeamChurnBench`).
        if arguments.contains("--team-churn") { TeamChurnBench.run(arguments: arguments) }
        let minutes = arguments.first.flatMap(Double.init) ?? 5
        let transcript = arguments.firstIndex(of: "--transcript").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let app = NSApplication.shared
        app.setActivationPolicy(arguments.contains("--onscreen") ? .accessory : .prohibited)
        VibePaths.ensurePrivateDirectories()
        let value = { (name: String) in arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        let soak = value("--soak").flatMap(Double.init).map {
            Soak(minutes: $0, workers: value("--soak-workers").flatMap(Int.init) ?? 6,
                 upserts: value("--soak-upserts").flatMap(Double.init) ?? 2,
                 without: Set((value("--soak-without") ?? "").split(separator: ",").map(String.init)))
        }
        let bench = Bench(minutes: minutes, onscreen: arguments.contains("--onscreen"), ticking: arguments.contains("--ticking"),
                          transcript: transcript, soak: soak)
        bench.start()
        app.run()
        exit(0)
    }

    /// `--ui-bench-write ROUND ROOT…`: what a lead's tools do to its board as it works, in a process of its own: a
    /// checkpoint on one task and a decision.
    static func write(arguments: [String]) -> Never {
        let round = arguments.first.flatMap(Int.init) ?? 0
        for root in arguments.dropFirst() {
            let store = BoardStore(root: root)
            try? store.update { board in
                guard !board.tasks.isEmpty else { return }
                board.tasks[round % board.tasks.count].checkpoints?.append(LeadCheckpoint(text: "checkpoint \(round)"))
            }
            try? store.appendDecision("Decision at round \(round): keep going", why: "The bench's lead decided.")
        }
        exit(0)
    }

    /// `--soak`: how long, how many workers, and how many session changes a second they make in all.
    struct Soak {
        let minutes: Double
        let workers: Int
        let upserts: Double
        /// Traffic left out, to narrow a growth down: hooks, boards, transcripts, switches (workers: `--soak-workers 0`).
        let without: Set<String>
        /// What a worker's session runs: it retitles itself every `$1` seconds (a change the host sends the app each
        /// time), printing a line of agent-shaped output.
        static let workerScript = """
        i=0
        while :; do
          i=$((i + 1))
          printf '\\033]0;✳ Worker step %d: run the tests\\007' $i
          printf '\\033[1;38;5;%dm● Step %d\\033[0m \\033[38;5;245mread Sources/File%d.swift and ran the tests\\033[0m\\n' $((i % 7 + 31)) $i $i
          sleep "$1"
        done
        """
    }

    /// One more exchange at the end of a made-up transcript (a prompt, a tool call and its result, an answer).
    static func appendTurn(to path: String, turn: Int) {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = stamp.string(from: Date())
        let id = UUID().uuidString
        func line(_ type: String, _ content: Any) -> String {
            let entry: [String: Any] = ["type": type, "uuid": UUID().uuidString, "timestamp": now, "message": ["role": type, "content": content]]
            return (try? JSONSerialization.data(withJSONObject: entry)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        let text = [line("user", "Turn \(turn): run the tests and tell me what failed."),
                    line("assistant", [["type": "text", "text": "Running them."],
                                       ["type": "tool_use", "id": id, "name": "Bash", "input": ["command": "swift test"]]]),
                    line("user", [["type": "tool_result", "tool_use_id": id, "content": (0..<12).map { "Test Case \($0) passed (\(turn))" }.joined(separator: "\n")]]),
                    line("assistant", [["type": "text", "text": "## Turn \(turn)\n\nAll the tests pass; the build is green.\n\n- one\n- `two`"]])]
            .joined(separator: "\n") + "\n"
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// What switching between the two leads may cost (the median, in instructions; a debug build). Measured: 5.8 G
    /// when the Team pane drew every result, 1.0-1.4 G since (0.85 G of it the terminal's).
    static let switchBudget: Double = 2.5e9
    /// What two idle leads may cost, in instructions a second, on an idle Mac: shown, not checked (the rate rises with
    /// the Mac's load; scripts/ui-bench.sh -B compares it with a base build's). Measured: 80 M while the lead controller
    /// decoded the boards every 3 s, 30 M since.
    static let idleBudget: Double = 50e6

    /// Checks that passed or failed, printed as they're decided.
    private static var failures: [String] = []
    private static func check(_ ok: Bool, _ text: String) {
        print("\(ok ? "PASS" : "FAIL")  \(text)")
        if !ok { failures.append(text) }
        fflush(stdout)
    }

    /// The main thread's longest wait to run a block posted from another thread (sampled four times a second).
    final class StallMeter: @unchecked Sendable {
        private let lock = NSLock()
        private var longest: TimeInterval = 0

        init() {
            Thread.detachNewThread { [weak self] in
                while let self {
                    // The system's uptime: the wall clock can be set while it runs.
                    let posted = DispatchTime.now().uptimeNanoseconds
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async {
                        let waited = TimeInterval(DispatchTime.now().uptimeNanoseconds - posted) / 1e9
                        self.lock.lock()
                        self.longest = max(self.longest, waited)
                        self.lock.unlock()
                        done.signal()
                    }
                    done.wait()
                    usleep(250_000)
                }
            }
        }

        /// The longest stall since the last call.
        func take() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            let value = longest
            longest = 0
            return value
        }
    }

    /// A day's board: tasks with contracts, checkpoints and reports, the reports for the lead, and results with prose.
    static func board(tasks: Int, seed: Int) -> LeadBoard {
        var board = LeadBoard()
        board.baseBranch = "main"
        let now = Date().timeIntervalSince1970
        func prose(_ words: Int, _ salt: Int) -> String {
            let vocabulary = ["the", "worker", "branch", "merge", "test", "passes", "window", "session", "lead", "board",
                              "status", "report", "verifier", "checks", "build", "SwiftUI", "terminal", "host", "fix", "stall",
                              "renders", "list", "row", "selection", "memory", "timer", "file", "commit", "review", "scratch"]
            return (0..<words).map { vocabulary[($0 * 7 + salt * 13 + seed) % vocabulary.count] }.joined(separator: " ")
        }
        let statuses: [LeadTask.Status] = [.done, .done, .done, .running, .review, .planned, .failed, .blocked]
        for index in 0..<tasks {
            var task = LeadTask(slug: "task-\(index)", title: "Task \(index): " + prose(8, index),
                                contract: LeadContract(goal: prose(150, index), acceptance: (0..<6).map { prose(45, index + $0) },
                                                       boundaries: (0..<4).map { prose(30, index * 2 + $0) }, context: prose(220, index * 3)),
                                status: statuses[index % statuses.count])
            task.createdAt = now - Double(tasks - index) * 600
            task.since = task.createdAt + 300
            task.startedAt = task.createdAt + 60
            task.worker = UUID().uuidString
            task.verifier = index % 2 == 0 ? UUID().uuidString : nil
            task.branch = "agent/task-\(index)"
            task.checkpoints = (0..<10).map { LeadCheckpoint(text: prose(30, index + $0), at: task.createdAt + Double($0) * 30) }
            task.report = prose(160, index * 5)
            if task.status == .done {
                task.evidence = LeadEvidence(completion: .complete, integrity: .clean, summary: prose(80, index), commit: "abc\(index)")
                task.merged = LeadMergeRecord(commit: "def\(index)", tested: true, at: task.createdAt + 500)
            }
            board.tasks.append(task)
        }
        board.reports = (0..<LeadBoard.keptReports).map { LeadReport(about: "worker task-\($0)", text: prose(450, $0), at: now - Double($0) * 60) }
        board.updates = (0..<(Int(ProcessInfo.processInfo.environment["VIBESWITCHER_BENCH_RESULTS"] ?? "") ?? 32)).map { index in
            LeadUpdate(title: "Result \(index)", body: "**\(prose(6, index))**\n\n- " + (0..<6).map { prose(25, index + $0) }.joined(separator: "\n- ")
                       + "\n\n`code \(index)` and " + prose(40, index))
        }
        return board
    }

    static func decisions(count: Int, newest: Date) -> String {
        var text = "# Decisions\n\n"
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for index in (0..<count).reversed() {
            let at = newest.addingTimeInterval(-Double(index) * 900)
            text += "## \(stamp.string(from: at)) Decision \(count - index): run the slower checks only before merging, and keep each worker on its own branch\n\n"
            text += "Because the checks take minutes and workers run in parallel; merging one at a time keeps the base green.\n\n"
        }
        return text
    }

    /// A full screen of the kind an agent leaves: colored headers, dim text, a box at the bottom.
    static let screenScript = """
    clear
    i=1
    while [ $i -le 30 ]; do
      printf '\\033[1;38;5;%dm● Step %d\\033[0m \\033[38;5;245mread Sources/VibeSwitcher/File%d.swift (%d lines) and ran the tests\\033[0m \\033[48;5;236m ok \\033[0m\\n' $((i % 7 + 31)) $i $i $((i * 37))
      i=$((i + 1))
    done
    printf '\\033[38;5;240m╭──────────────────────────────────────────────────────────────────────────────╮\\033[0m\\n'
    printf '\\033[38;5;240m│\\033[0m > \\033[2mTry "fix the failing test"\\033[0m                                                \\033[38;5;240m│\\033[0m\\n'
    printf '\\033[38;5;240m╰──────────────────────────────────────────────────────────────────────────────╯\\033[0m\\n'
    printf '  \\033[38;5;245m⏵⏵ accept edits on (shift+tab to cycle)\\033[0m'
    if [ "$1" = ticking ]; then
      while :; do printf '\\0337\\033[1;60H\\033[38;5;214m%s\\033[0m\\0338' "$(date +%H:%M:%S)"; sleep 1; done
    fi
    exec /bin/cat
    """

    /// The made-up process table: a session host, and the agents (pid by the tty they run in) under it. Two agents on
    /// one pid (a lead's old session not yet let go when the new one starts) make one process, the first tty's.
    static func processTable(agents: [String: Int32], launched: Date) -> [Int32: ProcInfo] {
        var procs = [ProcInfo(pid: 60_000, ppid: 1, tty: nil, comm: "vibeswitcher-hos", startTime: launched, agent: nil)]
        for (tty, pid) in agents.sorted(by: { $0.key < $1.key }) {
            procs.append(ProcInfo(pid: pid, ppid: 60_000, tty: tty, comm: "claude", startTime: launched, agent: .claude))
        }
        return Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private final class Bench {
        let minutes: Double
        let onscreen: Bool
        let ticking: Bool
        let transcriptSource: String?
        let soak: Soak?
        let started = Date()
        let store: SessionStore
        let host = HostClient()
        let model = WindowModel()
        lazy var leads = LeadController(host: host, store: store) { _ in "claude" }
        var window: MainWindowController?
        var cancellables: Set<AnyCancellable> = []
        let stalls = StallMeter()
        /// The made-up agents, by the tty of the window session they run in (read on the scanner's queue).
        private let lock = NSLock()
        private var agentTTYs: [String: (pid: Int32, root: String)] = [:]
        /// The made-up agents started so far (on the main thread).
        private var agentsStarted = 0
        var roots: [String] { ["alpha", "beta"].map { (NSHomeDirectory() as NSString).appendingPathComponent("lead-\($0)") } }
        var transcripts: [String: String] = [:]

        init(minutes: Double, onscreen: Bool, ticking: Bool, transcript: String?, soak: Soak?) {
            self.minutes = minutes
            self.soak = soak
            self.onscreen = onscreen
            self.ticking = ticking
            transcriptSource = transcript
            weak var weakSelf: Bench?
            store = SessionStore(scanner: SessionScanner(
                processes: { weakSelf?.processes() ?? [:] },
                cwd: { pid in weakSelf?.cwd(pid) },
                arguments: { _ in [] }))
            weakSelf = self
            host.hostArguments = HostClient.endsWithThisProcess
        }

        private func processes() -> [Int32: ProcInfo] {
            lock.lock()
            let agents = agentTTYs
            lock.unlock()
            return UIBench.processTable(agents: agents.mapValues(\.pid), launched: started.addingTimeInterval(-7200))
        }

        private func cwd(_ pid: Int32) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return agentTTYs.values.first { $0.pid == pid }?.root
        }

        /// Keeps App Nap off: the app's window is on screen when you use it, which keeps it awake; the bench's off-screen
        /// one wouldn't, and napping would measure a sleeping app.
        private var awake: NSObjectProtocol?

        func start() {
            awake = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "--ui-bench measures")
            for (index, root) in roots.enumerated() {
                let store = BoardStore(root: root)
                try? store.update { $0 = UIBench.board(tasks: 50, seed: index) }
                try? store.replaceRecord("decisions.md", with: UIBench.decisions(count: 30, newest: started.addingTimeInterval(-3600)))
            }
            if let source = transcriptSource {
                let folder = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects/-bench")
                try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                for root in roots {
                    let copy = (folder as NSString).appendingPathComponent((root as NSString).lastPathComponent + ".jsonl")
                    try? FileManager.default.removeItem(atPath: copy)
                    try? FileManager.default.copyItem(atPath: source, toPath: copy)
                    transcripts[root] = copy
                }
            } else if soak != nil {
                for root in roots { transcripts[root] = madeUpTranscript((root as NSString).lastPathComponent) }
            }
            try? UIBench.screenScript.write(toFile: (NSHomeDirectory() as NSString).appendingPathComponent("screen.sh"),
                                            atomically: true, encoding: .utf8)
            // Wired as the app delegate wires them.
            host.$sessions.receive(on: RunLoop.main).sink { [weak self] in self?.store.updateHosted($0) }.store(in: &cancellables)
            store.$sessions.combineLatest(host.$sessions, host.$state, store.$tableRead).receive(on: RunLoop.main)
                .sink { [weak self] sessions, hosted, state, table in
                    self?.model.update(sessions: sessions, hosted: hosted, table: table, hostAnswered: state != .connecting)
                }
                .store(in: &cancellables)
            // A made-up agent leaves with its session, as a real one does.
            host.$sessions.receive(on: RunLoop.main).sink { [weak self] sessions in
                guard let self else { return }
                let live = Set(sessions.filter(\.isLive).map(\.tty))
                self.lock.lock()
                self.agentTTYs = self.agentTTYs.filter { live.contains($0.key) }
                self.lock.unlock()
            }.store(in: &cancellables)
            store.hostScreens = { [weak self] in self?.host.screens ?? [:] }
            store.requestHostScreens = { [weak self] in self?.host.refreshScreens(ttys: $0) }
            HangWatchdog.shared.describeState = { [weak self] in
                guard let self else { return "" }
                return "host state=\(self.host.state) sessions=\(self.host.sessions.count)\nscanned sessions=\(self.store.sessions.count)\n"
                    + (self.window?.debugState() ?? "window never opened")
            }
            HangWatchdog.shared.start()
            UserDefaults.standard.set(ProcessInfo.processInfo.environment["VIBESWITCHER_BENCH_INSPECTOR"] ?? "team", forKey: "inspectorTab")
            _ = leads
            store.start()
            spawnLeads { [weak self] in self?.openWindow() }
        }

        /// The two leads' sessions, each with a made-up Claude in it.
        private func spawnLeads(_ done: @escaping () -> Void) {
            var pending = roots.count
            for (index, root) in roots.enumerated() {
                let command = index == 0 ? "/bin/sh \(NSHomeDirectory())/screen.sh \(ticking ? "ticking" : "")"
                    : "/bin/ls -la /usr/bin | /usr/bin/head -60; exec /bin/cat"
                host.spawn(SpawnRequest(cwd: root, command: command, env: [:], cols: 120, rows: 40, keepShell: false,
                                        label: "Lead · \((root as NSString).lastPathComponent)", agent: "claude")) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let session):
                        // A new pid for each agent started, as a real one gets.
                        self.agentsStarted += 1
                        let pid = Int32(60_100 + self.agentsStarted)
                        var state = HookState(agent: .claude, tty: session.tty, lastEvent: "Stop", lastEventAt: Date().timeIntervalSince1970 - 600)
                        state.agentPid = pid
                        state.sessionId = UUID().uuidString
                        state.cwd = root
                        state.firstPrompt = "Lead the work in \((root as NSString).lastPathComponent)"
                        state.lastMessage = "Waiting for reports."
                        state.transcriptPath = self.transcripts[root]
                        try? state.save(to: VibePaths.stateFile(tty: session.tty))
                        self.lock.lock()
                        self.agentTTYs[session.tty] = (pid, root)
                        self.lock.unlock()
                    case .failure(let error):
                        print("couldn't start a session: \(error.message)")
                    }
                    pending -= 1
                    if pending == 0 { self.store.refresh(); DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: done) }
                }
            }
        }

        private func openWindow() {
            let actions = WindowActions(
                newSession: { _, _ in }, endSession: { _ in }, resume: { _ in }, remove: { _ in }, rename: { _ in },
                pause: { _, _ in }, resumePaused: { _ in }, openInTerminal: { _ in }, presets: { _ in [] },
                isLive: { [weak self] row in
                    guard let id = row.hostID else { return row.session != nil }
                    return self?.host.sessions.first { $0.id == id }?.isLive ?? false
                },
                canResume: { _ in false }, resumeCommand: { _ in nil }, settings: {}, moveToWindow: { _ in }, startLead: { _ in })
            let controller = MainWindowController(store: store, host: host, model: model, actions: actions, leads: leads)
            window = controller
            if onscreen {
                controller.presentWithoutFocus()
            } else {
                controller.presentOffscreen()
            }
            print(String(format: "ui bench: 2 lead sessions, boards of %.0f KB, window %@", Double(boardSize()) / 1024,
                         onscreen ? "on screen" : "off screen"))
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                if let soak = self.soak { self.soakPhase(soak) } else { self.clicks() }
            }
        }

        private func boardSize() -> Int {
            let file = (BoardStore(root: roots[0]).folder as NSString).appendingPathComponent("board.json")
            return ((try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int) ?? 0
        }

        // MARK: Soak

        /// A made-up transcript for the chat, in the scratch home's Claude projects.
        private func madeUpTranscript(_ name: String) -> String {
            let folder = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects/-bench")
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let path = (folder as NSString).appendingPathComponent(name + ".jsonl")
            IdleBench.writeTranscript(to: path, turns: 60)
            return path
        }

        /// The workers' sessions, by the host's id, with their transcripts and turns so far.
        private var workers: [(id: UUID, tty: String, transcript: String)] = []
        private var soakTimers: [Heartbeat.Subscription] = []

        func soakPhase(_ soak: Soak) {
            let script = (NSHomeDirectory() as NSString).appendingPathComponent("worker.sh")
            try? Soak.workerScript.write(toFile: script, atomically: true, encoding: .utf8)
            // Each worker retitles itself this often, so the host sends `upserts` changes a second in all.
            let period = max(0.2, Double(soak.workers) / max(soak.upserts, 0.01))
            var pending = soak.workers
            print(String(format: "soak: %.0f minutes, 2 leads and %d workers (a session change every %.1f s each, %.1f a second in all)",
                         soak.minutes, soak.workers, period, Double(soak.workers) / period))
            fflush(stdout)
            if soak.workers == 0 { return soakRun(soak) }
            for index in 0..<soak.workers {
                let root = roots[index % roots.count]
                let cwd = (root as NSString).appendingPathComponent("worktree-\(index)")
                try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
                let transcript = madeUpTranscript("worker-\(index)")
                host.spawn(SpawnRequest(cwd: cwd, command: "/bin/sh \(script) \(period)", env: [:], cols: 120, rows: 40, keepShell: false,
                                        label: "Worker: task-\(index)", agent: "claude")) { [weak self] result in
                    guard let self else { return }
                    if case .success(let session) = result {
                        self.agentsStarted += 1
                        let pid = Int32(60_100 + self.agentsStarted)
                        var state = HookState(agent: .claude, tty: session.tty, lastEvent: "PreToolUse", lastEventAt: Date().timeIntervalSince1970)
                        state.agentPid = pid
                        state.sessionId = UUID().uuidString
                        state.cwd = cwd
                        state.firstPrompt = "Work on task-\(index)"
                        state.transcriptPath = transcript
                        try? state.save(to: VibePaths.stateFile(tty: session.tty))
                        self.lock.lock()
                        self.agentTTYs[session.tty] = (pid, cwd)
                        self.lock.unlock()
                        self.workers.append((session.id, session.tty, transcript))
                    }
                    pending -= 1
                    if pending == 0 { self.store.refresh(); DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.soakRun(soak) } }
                }
            }
        }

        private func soakRun(_ soak: Soak) {
            model.showsChat = true
            let off = soak.without
            if !off.isEmpty { print("soak: without \(off.sorted().joined(separator: ", "))") }
            var tick = 0, rounds = 0, switches = 0
            let events = ["PreToolUse", "PostToolUse", "PreToolUse", "PostToolUse", "Stop", "UserPromptSubmit"]
            // Hook events: one agent's state a second, round the workers and leads.
            soakTimers.append(Heartbeat.shared.every(1) { [weak self] in
                guard let self, !off.contains("hooks") else { return }
                tick += 1
                self.lock.lock()
                let agents = self.agentTTYs.sorted { $0.key < $1.key }
                self.lock.unlock()
                guard !agents.isEmpty else { return }
                let (tty, agent) = agents[tick % agents.count]
                let path = VibePaths.stateFile(tty: tty)
                guard var state = HookState.load(from: path) else { return }
                state.lastEvent = events[tick % events.count]
                state.lastEventAt = Date().timeIntervalSince1970
                state.lastPrompt = "Step \(tick)"
                state.toolName = state.lastEvent == "PreToolUse" ? "Bash" : nil
                state.toolDetail = state.lastEvent == "PreToolUse" ? "swift test --filter Step\(tick)" : nil
                state.agentPid = agent.pid
                try? state.save(to: path)
            })
            // The chat follows its transcript each second, as the window does while it's in sight: the bench's window
            // is off screen, and once the display has slept macOS may call it hidden for good (`chatInSight`).
            soakTimers.append(Heartbeat.shared.every(1) { [weak self] in
                guard let self, self.model.showsChat else { return }
                self.window?.chat.poll()
            })
            // The leads' boards: a checkpoint and a decision every 10 s, from another process.
            soakTimers.append(Heartbeat.shared.every(10) { [weak self] in
                guard let self, !off.contains("boards") else { return }
                rounds += 1
                let write = Process()
                write.executableURL = Bundle.main.executableURL
                write.arguments = ["--ui-bench-write", "\(rounds)"] + self.roots
                try? write.run()
            })
            // Every transcript a turn longer every 5 s.
            soakTimers.append(Heartbeat.shared.every(5) { [weak self] in
                guard let self, !off.contains("transcripts") else { return }
                for path in Array(self.transcripts.values) + self.workers.map(\.transcript) { UIBench.appendTurn(to: path, turn: tick) }
            })
            // The window on the next session, on its chat, every 30 s.
            soakTimers.append(Heartbeat.shared.every(30) { [weak self] in
                guard let self, !off.contains("switches") else { return }
                let live = self.host.sessions.filter(\.isLive)
                guard !live.isEmpty else { return }
                switches += 1
                self.model.select(hostID: live[switches % live.count].id)
                self.model.showsChat = true
            })
            soakMinutes(soak)
        }

        private struct Sample {
            let minute: Int
            let footprint: Double
            let inUse: Double
            /// The least footprint read in the minute (every 5 s): a terminal shown draws on the GPU, ~110 MB of
            /// IOAccelerator memory that goes again within the minute, and a minute's reading can land on it. Growth
            /// raises the floor; that doesn't.
            let floor: Double
        }

        private func soakMinutes(_ soak: Soak) {
            let count = max(1, Int(soak.minutes.rounded(.up)))
            var samples: [Sample] = []
            var least = UInt64.max
            soakTimers.append(Heartbeat.shared.every(5) { least = min(least, IdleBench.Usage.now().footprint) })
            var baseline: (census: HeapCensus.Result, regions: [String: Double])?
            let mb = { (bytes: Double) in bytes / 1_048_576 }
            func census(_ label: String, then done: @escaping (HeapCensus.Result, [String: Double]) -> Void) {
                let pid = getpid()
                DispatchQueue.global().async {
                    let regions = IdleBench.VMMap.summary(pid: pid).regions
                    let census = HeapCensus.take()
                    DispatchQueue.main.async {
                        print(String(format: "  census %@: %ld blocks, %.1f MB in malloc blocks", label as NSString, census.total.blocks,
                                     mb(Double(census.total.bytes))))
                        if let baseline {
                            print("  grew since minute 2, by vmmap's region categories (dirty + swapped):")
                            let names = Set(baseline.regions.keys).union(regions.keys)
                            for (name, delta) in names.map({ ($0, (regions[$0] ?? 0) - (baseline.regions[$0] ?? 0)) }).sorted(by: { $0.1 > $1.1 }).prefix(6) {
                                print(String(format: "    %-32@ %+7.1f MB  (%.1f → %.1f MB)", name as NSString, mb(delta),
                                             mb(baseline.regions[name] ?? 0), mb(regions[name] ?? 0)))
                            }
                            print("  grew since minute 2, by class (malloc blocks), then blocks of no class by size:")
                            var classed = baseline.census, unclassed = baseline.census, after = census, afterRaw = census
                            classed.unclassed = [:]; after.unclassed = [:]; unclassed.classes = [:]; afterRaw.classes = [:]
                            for row in HeapCensus.growth(from: classed, to: after, top: 16) + HeapCensus.growth(from: unclassed, to: afterRaw, top: 5) {
                                print(String(format: "    %-60@ %+8.2f MB %+8ld blocks  (%ld → %ld)", row.name as NSString,
                                             mb(Double(row.after.bytes - row.before.bytes)), row.after.blocks - row.before.blocks,
                                             row.before.blocks, row.after.blocks))
                            }
                        }
                        fflush(stdout)
                        done(census, regions)
                    }
                }
            }
            func minute(_ index: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + soak.minutes * 60 / Double(count)) { [weak self] in
                    guard let self else { return }
                    var stats = malloc_statistics_t()
                    malloc_zone_statistics(nil, &stats)
                    let usage = IdleBench.Usage.now()
                    let sample = Sample(minute: index + 1, footprint: mb(Double(usage.footprint)), inUse: mb(Double(stats.size_in_use)),
                                        floor: mb(Double(min(least, usage.footprint))))
                    least = .max
                    samples.append(sample)
                    print(String(format: "  minute %3d  footprint %6.1f MB (least %6.1f)  malloc in use %6.1f MB  live views %@ chats %@  sessions %d  rows %d",
                                 sample.minute, sample.footprint, sample.floor, sample.inUse, IdleBench.Live.views.map(String.init) ?? "n/a",
                                 IdleBench.Live.chats.map(String.init) ?? "n/a", self.host.sessions.count, self.store.sessions.count))
                    // The chat's own counts (entries, items, how many laid out).
                    if let chat = self.window?.debugState().split(separator: "\n").first(where: { $0.hasPrefix("chat ") }) {
                        print("              " + (chat.split(separator: " ").filter { !$0.hasPrefix("path=") && !$0.hasPrefix("draft=") && $0 != "chars" }
                            .joined(separator: " ")))
                    }
                    fflush(stdout)
                    let next = { if index + 1 < count { minute(index + 1) } else { self.soakFinish(soak, samples) } }
                    if index + 1 == 2 {
                        census("minute 2") { result, regions in baseline = (result, regions); next() }
                    } else if (index + 1) % 10 == 0 || index + 1 == count {
                        census("minute \(index + 1)") { _, _ in next() }
                    } else {
                        next()
                    }
                }
            }
            minute(0)
        }

        private func soakFinish(_ soak: Soak, _ samples: [Sample]) {
            soakTimers.forEach { $0.cancel() }
            soakTimers = []
            guard let first = samples.first, let last = samples.last else { return finish() }
            let window = samples.filter { $0.minute > last.minute - 20 }
            let sorted = window.map(\.footprint).sorted()
            let median = sorted[sorted.count / 2]
            let spread = window.map { abs($0.footprint - median) }.max() ?? 0
            let hours = Double(last.minute - first.minute) / 60
            print(String(format: "RESULT soak-footprint-first-mb %.1f", first.footprint))
            print(String(format: "RESULT soak-footprint-last-mb %.1f", last.footprint))
            print(String(format: "RESULT soak-growth-mb-per-hour %.1f", hours > 0 ? (last.footprint - first.footprint) / hours : 0))
            print(String(format: "RESULT soak-last-20-min %.1f-%.1f MB (median %.1f, at most %.1f MB from it)", sorted.first ?? 0,
                         sorted.last ?? 0, median, spread))
            let floors = window.map(\.floor).sorted()
            let floorMedian = floors[floors.count / 2]
            let floorSpread = window.map { abs($0.floor - floorMedian) }.max() ?? 0
            print(String(format: "RESULT soak-last-20-min-least %.1f-%.1f MB (median %.1f, at most %.1f MB from it)", floors.first ?? 0,
                         floors.last ?? 0, floorMedian, floorSpread))
            if last.minute >= 25 {
                // Judged on each minute's least footprint: a terminal's GPU memory comes and goes within a minute.
                UIBench.check(floorSpread <= 50, String(format: "soak: the least footprint of each of the last 20 minutes within ±50 MB of their median (%.1f MB)",
                                                         floorSpread))
            } else {
                print("soak: under 25 minutes, the last 20 minutes' spread is shown, not checked")
            }
            finish()
        }

        // MARK: Phase 1: clicks

        private var sidebarTable: NSTableView? {
            guard let split = window?.window?.contentViewController as? NSSplitViewController else { return nil }
            func find(_ view: NSView) -> NSTableView? {
                if let table = view as? NSTableView { return table }
                for subview in view.subviews { if let found = find(subview) { return found } }
                return nil
            }
            return find(split.splitViewItems[0].viewController.view)
        }

        /// A click on the sidebar's row, as the mouse's: the table tracks it until the button comes up. (Handed to the
        /// table: the bench's window is never the key window, which would take a click only to become key.)
        private func click(row: Int) {
            guard let window = window?.window, let table = sidebarTable, row < table.numberOfRows else { return }
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                   pressure: type == .leftMouseDown ? 1 : 0)
            }
            guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
            NSApp.postEvent(up, atStart: false)
            table.mouseDown(with: down)
            // A window that isn't key takes the click to become key only: select the row as the click would.
            guard table.selectedRow != row, selectable(row) else { return }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        /// Not a section's header: the list's outline view says which rows a click selects.
        private func selectable(_ row: Int) -> Bool {
            guard let outline = sidebarTable as? NSOutlineView, let delegate = outline.delegate else { return true }
            let item = outline.item(atRow: row)
            return delegate.outlineView?(outline, isGroupItem: item as Any) != true
                && delegate.outlineView?(outline, shouldSelectItem: item as Any) ?? true
        }

        private func clicks() {
            let from = Date()
            var steps: [(String, () -> Void)] = []
            let rows = sidebarTable?.numberOfRows ?? 0
            for round in 0..<3 {
                for row in 0..<rows { steps.append(("click row \(row)", { [weak self] in self?.click(row: row) })) }
                steps.append(("chat \(round % 2 == 0 ? "off" : "on")", { [weak self] in self?.model.showsChat = round % 2 != 0 }))
            }
            // Selecting from the keyboard and the palette (⌘1, ⌘2) goes through the model.
            for index in [0, 1, 0, 1] { steps.append(("select \(index + 1)", { [weak self] in self?.model.select(index: index) })) }
            // The host restarted as an outdated one is: its sessions end one by one, then it's replaced; the leads start again.
            steps.append(("end the sessions", { [weak self] in
                guard let self else { return }
                self.host.sessions.filter(\.isLive).forEach { self.host.kill($0.id) }
            }))
            steps.append(("restart the host", { [weak self] in self?.host.restartHost() }))
            steps.append(("start the leads again", { [weak self] in self?.spawnLeads {} }))
            for _ in 0..<2 {
                steps.append(("click row 0", { [weak self] in self?.click(row: 0) }))
                steps.append(("click row 1", { [weak self] in self?.click(row: 1) }))
                steps.append(("click row 2", { [weak self] in self?.click(row: 2) }))
            }
            print("clicks: \(rows) sidebar rows, \(steps.count) steps")
            fflush(stdout)
            run(steps[...]) { [weak self] in
                guard let self else { return }
                // What a switch costs, in instructions: time depends on how busy the Mac is (its stalls show that too).
                func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
                let work = self.switches.map(\.instructions), stalls = self.switches.map(\.stall)
                UIBench.check(work.count >= 10, "clicks: \(work.count) switches between the sessions")
                UIBench.check(median(work) < UIBench.switchBudget,
                              String(format: "clicks: a switch takes %.0f M instructions (median, under %.0f M; most %.0f M)",
                                     median(work) / 1e6, UIBench.switchBudget / 1e6, (work.max() ?? 0) / 1e6))
                print(String(format: "clicks: a switch stalls the main thread %.0f ms (median; longest %.0f ms)", median(stalls) * 1000,
                             (stalls.max() ?? 0) * 1000))
                // The rest is measured on the first lead (its busy screen, its Team tab).
                if let lead = self.host.sessions.first(where: { $0.isLive && $0.cwd == self.roots[0] }) { self.model.select(hostID: lead.id) }
                self.countFaults(since: from) {
                    let row = self.model.selectedRow
                    print("selected \(row?.project ?? "none") (\(row.flatMap { self.leads.lead(for: $0) } != nil ? "its Team tab" : "no Team tab"))")
                    self.busyLeads()
                }
            }
        }

        /// The instructions run and the main thread's longest stall in each step that changed the selection.
        private var switches: [(instructions: Double, stall: TimeInterval)] = []

        private func run(_ steps: ArraySlice<(String, () -> Void)>, then done: @escaping () -> Void) {
            guard let (name, step) = steps.first else { return done() }
            let selected = model.selectedID
            let before = IdleBench.Usage.now()
            step()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let after = IdleBench.Usage.now()
                let stall = self.stalls.take(), work = Double(after.instructions - before.instructions)
                if self.model.selectedID != selected { self.switches.append((work, stall)) }
                print(String(format: "  %-22@ %5.0f M instructions, cpu %4.0f ms, stall %4.0f ms  selected %@", name as NSString, work / 1e6,
                             (after.cpu - before.cpu) * 1000, stall * 1000,
                             (self.model.selectedRow.map { "\($0.project) \($0.id.prefix(13))" } ?? "none") as NSString))
                self.run(steps.dropFirst(), then: done)
            }
        }

        /// SwiftUI's faults in this process since `date`, from the unified log (it takes a moment to be written).
        private func countFaults(since date: Date, then done: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let log = Process()
                log.executableURL = URL(fileURLWithPath: "/usr/bin/log")
                log.arguments = ["show", "--style", "compact", "--start", formatter.string(from: date.addingTimeInterval(-1)),
                                 "--predicate", "processID == \(getpid()) AND (eventMessage CONTAINS \"Publishing changes from within view updates\" "
                                    + "OR eventMessage CONTAINS \"occurs multiple times\")"]
                let pipe = Pipe()
                log.standardOutput = pipe
                log.standardError = FileHandle.nullDevice
                DispatchQueue.global().async {
                    try? log.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    log.waitUntilExit()
                    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
                    let publishing = lines.filter { $0.contains("Publishing changes from within view updates") }.count
                    let duplicates = lines.filter { $0.contains("occurs multiple times") }.count
                    DispatchQueue.main.async {
                        UIBench.check(publishing == 0, "clicks: \(publishing) 'Publishing changes from within view updates' faults")
                        UIBench.check(duplicates == 0, "clicks: \(duplicates) 'occurs multiple times' warnings")
                        done()
                    }
                }
            }
        }

        // MARK: Phase 2: busy leads

        private func busyLeads() {
            let seconds: TimeInterval = 30
            print("busy leads: boards rewritten every 3 s, a decision added each time, for \(Int(seconds)) s")
            fflush(stdout)
            _ = stalls.take()
            let before = IdleBench.Usage.now()
            let scans = store.scansApplied
            var rounds = 0
            let writer = Heartbeat.shared.every(3) { [weak self] in
                guard let self else { return }
                rounds += 1
                // The lead's tools write the board from another process (this binary's `--ui-bench-write`): what
                // they cost isn't the app's.
                let write = Process()
                write.executableURL = Bundle.main.executableURL
                write.arguments = ["--ui-bench-write", "\(rounds)"] + self.roots
                try? write.run()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                writer.cancel()
                let after = IdleBench.Usage.now()
                let stall = self.stalls.take()
                let cpu = (after.cpu - before.cpu) / (after.wall - before.wall) * 100
                print(String(format: "busy leads: cpu %.1f %%, %.0f M instructions/s, longest main-thread stall %.0f ms, %d scans", cpu,
                             Double(after.instructions - before.instructions) / (after.wall - before.wall) / 1e6, stall * 1000,
                             self.store.scansApplied - scans))
                fflush(stdout)
                // The decisions just added fade for three minutes: let them go before measuring idle.
                for root in self.roots {
                    try? BoardStore(root: root).replaceRecord("decisions.md", with: UIBench.decisions(count: 30, newest: Date().addingTimeInterval(-3600)))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.idle() }
            }
            _ = writer
        }

        // MARK: Phase 3: idle

        private func idle() {
            print(String(format: "idle: %.0f minutes, nothing happening", minutes))
            fflush(stdout)
            _ = stalls.take()
            let start = IdleBench.Usage.now()
            var samples: [IdleBench.Usage] = [start]
            var scans = store.scansApplied
            let count = max(1, Int(minutes.rounded(.up)))
            func minute(_ index: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + minutes * 60 / Double(count)) { [weak self] in
                    guard let self else { return }
                    let now = IdleBench.Usage.now()
                    let previous = samples.last!
                    samples.append(now)
                    print(String(format: "  minute %d: cpu %5.2f %%  %5.1f M instructions/s  wakeups %6.1f/s  rss %4.0f MB  footprint %4.0f MB  longest stall %.0f ms  %d scans",
                                 index + 1, (now.cpu - previous.cpu) / (now.wall - previous.wall) * 100,
                                 Double(now.instructions - previous.instructions) / (now.wall - previous.wall) / 1e6,
                                 Double(now.wakeups - previous.wakeups) / (now.wall - previous.wall),
                                 Double(now.rss) / 1_048_576, Double(now.footprint) / 1_048_576, self.stalls.take() * 1000,
                                 self.store.scansApplied - scans))
                    scans = self.store.scansApplied
                    fflush(stdout)
                    if index + 1 < count { return minute(index + 1) }
                    let cpu = (now.cpu - start.cpu) / (now.wall - start.wall) * 100
                    UIBench.check(cpu < 2, String(format: "idle: cpu %.2f %% on average (under 2 %%)", cpu))
                    let rate = Double(now.instructions - start.instructions) / (now.wall - start.wall)
                    // Not a check here: the rate moves with the Mac's load (30 M idle, 73-79 M at load 30-90 on one
                    // build), so scripts/ui-bench.sh -B judges it against a base build's in the same run.
                    print(String(format: "INFO  idle: %.1f M instructions/s (%.0f M on an idle Mac's budget)", rate / 1e6,
                                 UIBench.idleBudget / 1e6))
                    print(String(format: "RESULT idle-instructions-per-second %.0f", rate))
                    let first = samples[min(1, samples.count - 1)]
                    let growth = (Double(now.rss) - Double(first.rss)) / Double(first.rss) * 100
                    UIBench.check(growth <= 10, String(format: "idle: rss %.0f → %.0f MB after the first minute (%+.1f %%, at most +10 %%)",
                                                       Double(first.rss) / 1_048_576, Double(now.rss) / 1_048_576, growth))
                    self.finish()
                }
            }
            minute(0)
        }

        private func finish() {
            // The private host runs from this build's folder, under the scratch home: it ends, sessions and all, as this
            // process exits (`HostClient.endsWithThisProcess`), and no other run's host from the same build is touched.
            print(UIBench.failures.isEmpty ? "ui bench: all checks passed" : "ui bench: \(UIBench.failures.count) check(s) failed")
            fflush(stdout)
            exit(UIBench.failures.isEmpty ? 0 : 1)
        }
    }
}
