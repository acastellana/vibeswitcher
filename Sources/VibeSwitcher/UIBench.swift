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
///    "Publishing changes from within view updates" and "occurs multiple times" faults are counted from the log.
/// 2. busy leads: their boards rewritten every few seconds and a decision added, as leads at work do. The main thread's
///    longest stall is measured.
/// 3. idle: MINUTES (default 5) of nothing happening: CPU each minute and on average, and memory after the first minute.
/// It exits 1 when a check fails. The window is off screen unless `--onscreen` (then it shows, without taking focus).
/// `--ticking` has the busy screen redraw a line each second. For narrowing a cost down: VIBESWITCHER_BENCH_INSPECTOR
/// (team, overview or activity: the inspector's tab, team by default) and VIBESWITCHER_BENCH_RESULTS (the results on
/// each board, 32 by default).
enum UIBench {
    static func run(arguments: [String]) -> Never {
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? ""
        guard NSHomeDirectory() != realHome else {
            print("--ui-bench runs on a scratch home only: set CFFIXED_USER_HOME to an empty folder.")
            exit(1)
        }
        let minutes = arguments.first.flatMap(Double.init) ?? 5
        let transcript = arguments.firstIndex(of: "--transcript").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let app = NSApplication.shared
        app.setActivationPolicy(arguments.contains("--onscreen") ? .accessory : .prohibited)
        VibePaths.ensurePrivateDirectories()
        let bench = Bench(minutes: minutes, onscreen: arguments.contains("--onscreen"), ticking: arguments.contains("--ticking"),
                          transcript: transcript)
        bench.start()
        app.run()
        exit(0)
    }

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
        private var running = true

        init() {
            Thread.detachNewThread { [weak self] in
                while let self, self.isRunning {
                    let posted = Date()
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async {
                        let waited = Date().timeIntervalSince(posted)
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

        private var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return running
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

    private final class Bench {
        let minutes: Double
        let onscreen: Bool
        let ticking: Bool
        let transcriptSource: String?
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
        var roots: [String] { ["alpha", "beta"].map { (NSHomeDirectory() as NSString).appendingPathComponent("lead-\($0)") } }
        var transcripts: [String: String] = [:]

        init(minutes: Double, onscreen: Bool, ticking: Bool, transcript: String?) {
            self.minutes = minutes
            self.onscreen = onscreen
            self.ticking = ticking
            transcriptSource = transcript
            weak var weakSelf: Bench?
            store = SessionStore(scanner: SessionScanner(
                processes: { weakSelf?.processes() ?? [:] },
                cwd: { pid in weakSelf?.cwd(pid) },
                arguments: { _ in [] }))
            weakSelf = self
        }

        private func processes() -> [Int32: ProcInfo] {
            lock.lock()
            let agents = agentTTYs
            lock.unlock()
            let launched = started.addingTimeInterval(-7200)
            var procs = [ProcInfo(pid: 60_000, ppid: 1, tty: nil, comm: "vibeswitcher-hos", startTime: launched, agent: nil)]
            for (tty, agent) in agents {
                procs.append(ProcInfo(pid: agent.pid, ppid: 60_000, tty: tty, comm: "claude", startTime: launched, agent: .claude))
            }
            return Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
        }

        private func cwd(_ pid: Int32) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return agentTTYs.values.first { $0.pid == pid }?.root
        }

        func start() {
            for (index, root) in roots.enumerated() {
                let store = BoardStore(root: root)
                try? store.update { $0 = UIBench.board(tasks: 50, seed: index) }
                try? UIBench.decisions(count: 30, newest: started.addingTimeInterval(-3600))
                    .write(toFile: (store.folder as NSString).appendingPathComponent("decisions.md"), atomically: true, encoding: .utf8)
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
            }
            try? UIBench.screenScript.write(toFile: (NSHomeDirectory() as NSString).appendingPathComponent("screen.sh"),
                                            atomically: true, encoding: .utf8)
            // Wired as the app delegate wires them.
            host.$sessions.receive(on: RunLoop.main).sink { [weak self] in self?.store.updateHosted($0) }.store(in: &cancellables)
            store.$sessions.combineLatest(host.$sessions, host.$state).receive(on: RunLoop.main)
                .sink { [weak self] sessions, hosted, state in
                    self?.model.update(sessions: sessions, hosted: hosted, hostAnswered: state != .connecting)
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
                        let pid = Int32(60_100 + index + Int.random(in: 0..<50) * 2)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.clicks() }
        }

        private func boardSize() -> Int {
            let file = (BoardStore(root: roots[0]).folder as NSString).appendingPathComponent("board.json")
            return ((try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int) ?? 0
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
                // The median: one switch can wait on a busy Mac; switching that's slow every time is the app.
                let sorted = self.switchStalls.sorted()
                let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
                UIBench.check(sorted.count >= 10, "clicks: \(sorted.count) switches between the sessions")
                UIBench.check(median < 0.15, String(format: "clicks: a switch stalls the main thread %.0f ms (median, under 150 ms; longest %.0f ms)",
                                                    median * 1000, (sorted.last ?? 0) * 1000))
                self.countFaults(since: from) { self.busyLeads() }
            }
        }

        /// The main thread's longest stall in each step that changed the selection.
        private var switchStalls: [TimeInterval] = []

        private func run(_ steps: ArraySlice<(String, () -> Void)>, then done: @escaping () -> Void) {
            guard let (name, step) = steps.first else { return done() }
            let selected = model.selectedID
            step()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let stall = self.stalls.take()
                if self.model.selectedID != selected { self.switchStalls.append(stall) }
                print(String(format: "  %-22@ stall %4.0f ms  selected %@", name as NSString, stall * 1000,
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
            var rounds = 0
            let writer = Heartbeat.shared.every(3) { [weak self] in
                guard let self else { return }
                rounds += 1
                let roots = self.roots
                let round = rounds
                // The lead's tools write the board from another process: here, another thread.
                DispatchQueue.global(qos: .utility).async {
                    for root in roots {
                        let store = BoardStore(root: root)
                        try? store.update { board in
                            board.tasks[round % board.tasks.count].checkpoints?.append(LeadCheckpoint(text: "checkpoint \(round)"))
                        }
                        try? store.appendDecision("Decision at round \(round): keep going", why: "The bench's lead decided.")
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                writer.cancel()
                let after = IdleBench.Usage.now()
                let stall = self.stalls.take()
                let cpu = (after.cpu - before.cpu) / (after.wall - before.wall) * 100
                print(String(format: "busy leads: cpu %.1f %%, longest main-thread stall %.0f ms", cpu, stall * 1000))
                UIBench.check(stall < 0.25, String(format: "busy leads: longest main-thread stall %.0f ms (under 250 ms)", stall * 1000))
                UIBench.check(cpu < 2, String(format: "busy leads: cpu %.1f %% (under 2 %%)", cpu))
                fflush(stdout)
                // The decisions just added fade for three minutes: let them go before measuring idle.
                for root in self.roots {
                    try? UIBench.decisions(count: 30, newest: Date().addingTimeInterval(-3600))
                        .write(toFile: (BoardStore(root: root).folder as NSString).appendingPathComponent("decisions.md"), atomically: true, encoding: .utf8)
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
            let count = max(1, Int(minutes.rounded(.up)))
            func minute(_ index: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + minutes * 60 / Double(count)) { [weak self] in
                    guard let self else { return }
                    let now = IdleBench.Usage.now()
                    let previous = samples.last!
                    samples.append(now)
                    print(String(format: "  minute %d: cpu %5.2f %%  wakeups %6.1f/s  rss %4.0f MB  footprint %4.0f MB  longest stall %.0f ms",
                                 index + 1, (now.cpu - previous.cpu) / (now.wall - previous.wall) * 100,
                                 Double(now.wakeups - previous.wakeups) / (now.wall - previous.wall),
                                 Double(now.rss) / 1_048_576, Double(now.footprint) / 1_048_576, self.stalls.take() * 1000))
                    fflush(stdout)
                    if index + 1 < count { return minute(index + 1) }
                    let cpu = (now.cpu - start.cpu) / (now.wall - start.wall) * 100
                    UIBench.check(cpu < 2, String(format: "idle: cpu %.2f %% on average (under 2 %%)", cpu))
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
            // The private host runs from this build's folder, under the scratch home: end it with the bench.
            let stop = Process()
            stop.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            stop.arguments = ["-f", HostClient.hostExecutable.path]
            try? stop.run()
            stop.waitUntilExit()
            print(UIBench.failures.isEmpty ? "ui bench: all checks passed" : "ui bench: \(UIBench.failures.count) check(s) failed")
            fflush(stdout)
            exit(UIBench.failures.isEmpty ? 0 : 1)
        }
    }
}
