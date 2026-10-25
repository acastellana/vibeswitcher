import AppKit
import Combine
import Darwin
import SwiftUI
import VibeCore

/// Debug aid (`CFFIXED_USER_HOME=<scratch> VibeSwitcher --idle-bench [SECONDS] [--transcript PATH] [--sidebar]
/// [--views N [--views-lines L]] [--churn MINUTES [--churn-speed X] [--churn-warmup N] [--dump FOLDER]]`): what the app costs while nothing changes. In this process, on
/// a scratch home: the session store scanning made-up agent sessions (one with a background shell, whose age is in its
/// detail), a private session host running a few quiet shells, the hang watchdog and the lead controller's timer, and
/// the main window off screen. Each phase settles, then runs SECONDS (default 20) and prints its CPU, wakeups, how often
/// the session list was published, memory (resident and phys_footprint, from task_vm_info) and, in debug builds, the
/// terminal views and chat models alive: the window on the chat (with `--transcript`, copied into the scratch home), on
/// a terminal, then closed, then closed with the sidebar docked on screen, drawing the popover's rows (`--sidebar`).
///
/// `--views N` (memory audit 2026-10-22, finding 2): after the window-on-a-terminal phase, N sessions that each print L
/// (`--views-lines`, 20,000) coloured lines of agent-shaped output, shown one after another as you click through them,
/// each until its output is on screen. Then the window open on the last one is measured twice: at once, and after the
/// time a view off screen stays attached (`TerminalPaneController.parkedLifetime`). Each print gives the views attached.
///
/// `--churn MINUTES` (R8, docs/eval/open-2026-10-19.md): after the window-closed phase, MINUTES of a working day's
/// churn, one cycle per 15 s: a shell and an agent session start, the oldest of each ends (at most 3 live), the window
/// opens on the new shell, the chat opens on the last agent and closes, the window closes. `--churn-speed X` (10)
/// compresses it: a cycle takes 15/X s, so 10 minutes run in 60 s. First a warm-up of `--churn-warmup N` cycles (4),
/// everything it started ended and the window-closed phase measured again: what's paid once (the first terminal that
/// redraws often is drawn on the GPU, and CoreAnimation's accelerated renderer keeps ~12 MB from then on, a second
/// ~4.2 MB of textures when draws overlap on a loaded Mac) is in that baseline, not in the growth. Then the churn, everything it started ended, and the window-closed phase measured once
/// more and compared with the warm baseline (`RESULT` lines: the first, cold, closed footprint, the warm baseline, after
/// churn, the growth from the warm baseline, and the live views and chats, cold and after; the growth by vmmap's region
/// categories, the top growers first; then what malloc gives back when asked, which the phases after it start from).
/// Without `--transcript` it writes a made-up one. Every 10 cycles a line gives the footprint and malloc's bytes in use
/// and held so far. `--dump FOLDER` also writes vmmap, heap and leaks in full (and a memgraph) at the closed snapshots,
/// as FOLDER/cold-*, FOLDER/before-* (the warm baseline) and FOLDER/after-*, to diff what grew.
///
/// `--power`: the battery's measure instead, CPU per minute and wakeups with no window, idle and while a lead's team
/// works (see `PowerBench`; SECONDS per phase, default 60).
enum IdleBench {
    static func run(arguments: [String]) -> Never {
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? ""
        guard NSHomeDirectory() != realHome, !VibePaths.isAccountRoot(VibePaths.root, accountHome: realHome) else {
            print("--idle-bench runs on a scratch home only: set CFFIXED_USER_HOME to an empty folder (and VIBESWITCHER_HOME, if set, "
                  + "to one other than your ~/.vibeswitcher).")
            exit(1)
        }
        // `--power`: CPU per minute and wakeups, idle and under a lead's work (see `PowerBench`).
        if arguments.contains("--power") { PowerBench.run(seconds: arguments.first.flatMap(TimeInterval.init) ?? 60) }
        let seconds = arguments.first.flatMap(TimeInterval.init) ?? 20
        let value = { (name: String) in arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        let transcript = value("--transcript")
        let churn = value("--churn").flatMap(Double.init).map {
            Churn(minutes: $0, speed: value("--churn-speed").flatMap(Double.init) ?? 10, warmup: value("--churn-warmup").flatMap(Int.init) ?? 4)
        }
        let views = value("--views").flatMap(Int.init).map { (count: $0, lines: value("--views-lines").flatMap(Int.init) ?? 20_000) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        VibePaths.ensurePrivateDirectories()
        let bench = Bench(seconds: seconds, transcript: transcript, sidebar: arguments.contains("--sidebar"), churn: churn,
                          views: views, dump: value("--dump"))
        bench.start()
        app.run()
        exit(0)
    }

    /// Made-up agents under a made-up session host process; they're not in Terminal, so nothing asks Terminal.
    private static func processes(started: Date) -> [Int32: ProcInfo] {
        // Started before their hook events (or the events would be taken for an earlier agent's on the same tty).
        let launched = started.addingTimeInterval(-7200)
        var procs = [ProcInfo(pid: 50_000, ppid: 1, tty: nil, comm: "vibeswitcher-hos", startTime: launched, agent: nil)]
        for (index, agent) in agents.enumerated() {
            let pid = Int32(50_100 + index)
            procs.append(ProcInfo(pid: pid, ppid: 50_000, tty: agent.tty, comm: "claude", startTime: launched, agent: agent.agent))
        }
        // The background session's shell, started a little before the bench: its age is in the session's detail.
        procs.append(ProcInfo(pid: 50_900, ppid: 50_104, tty: "ttys904", comm: "zsh", startTime: started.addingTimeInterval(-20), agent: nil))
        return Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
    }

    /// `--churn`: how long (synthetic minutes) and how much faster than a working day.
    struct Churn {
        /// A working day's pace: a session starting and one ending, and the chat opened and closed, every 15 s.
        static let cycle: TimeInterval = 15
        let minutes: Double
        let speed: Double
        /// Cycles before the baseline: what the first ones pay once isn't growth.
        let warmup: Int
        var cycles: Int { max(1, Int((minutes * 60 / Self.cycle).rounded())) }
        var interval: TimeInterval { Self.cycle / max(speed, 0.01) }
    }

    /// The made-up agents churn starts and ends, beside the fixed ones; the scanner reads them off the main thread.
    final class ChurnedAgents: @unchecked Sendable {
        private let lock = NSLock()
        private var table: [Int32: ProcInfo] = [:]

        func add(_ process: ProcInfo) { lock.withLock { table[process.pid] = process } }
        func remove(_ pid: Int32) { lock.withLock { table[pid] = nil } }
        var processes: [Int32: ProcInfo] { lock.withLock { table } }
    }

    private struct MockAgent {
        let tty: String
        let agent: Agent
        let event: String?
        let ago: TimeInterval
    }

    private static let agents = [
        MockAgent(tty: "ttys900", agent: .claude, event: "PreToolUse", ago: 42),
        MockAgent(tty: "ttys901", agent: .claude, event: "Notification", ago: 90),
        MockAgent(tty: "ttys902", agent: .claude, event: "Stop", ago: 30),
        MockAgent(tty: "ttys903", agent: .claude, event: "Stop", ago: 4000),
        MockAgent(tty: "ttys904", agent: .claude, event: "Stop", ago: 600),
        MockAgent(tty: "ttys905", agent: .codex, event: "UserPromptSubmit", ago: 15),
        MockAgent(tty: "ttys906", agent: .claude, event: nil, ago: 0),
    ]

    private static func writeHooks(started: Date, transcript: String?) {
        for (index, mock) in agents.enumerated() {
            guard let event = mock.event else { continue }
            writeHook(index: index, agent: mock.agent, tty: mock.tty, pid: Int32(50_100 + index), event: event, ago: mock.ago,
                      transcript: index == 0 ? transcript : nil)
        }
    }

    private static func writeHook(index: Int, agent: Agent, tty: String, pid: Int32, event: String, ago: TimeInterval, transcript: String?) {
        let now = Date().timeIntervalSince1970
        do {
            var state = HookState(agent: agent, tty: tty, lastEvent: event, lastEventAt: now - ago)
            state.agentPid = pid
            state.sessionId = UUID().uuidString
            state.cwd = (NSHomeDirectory() as NSString).appendingPathComponent("bench-\(index % 3)")
            state.firstPrompt = "Bench session \(index)"
            state.lastPrompt = "Make the build faster"
            state.lastMessage = "Done: the build is faster now."
            if event == "PreToolUse" {
                state.toolName = "Bash"
                state.toolDetail = "npm test"
                state.toolStartedAt = now - ago
            }
            if event == "Notification" {
                state.notificationType = "permission_prompt"
                state.request = "Run rm -rf build?"
            }
            state.transcriptPath = transcript
            try? state.save(to: VibePaths.stateFile(tty: tty))
        }
    }

    /// A made-up Claude transcript of `turns` exchanges (a prompt, a tool call and its result, an answer), for the chat
    /// when no `--transcript` is given.
    static func writeTranscript(to path: String, turns: Int = 150) {
        let start = Date().addingTimeInterval(-Double(turns) * 60)
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        var number = 0
        func line(_ type: String, _ content: Any, at turn: Int) {
            number += 1
            let entry: [String: Any] = ["type": type, "uuid": "bench-\(number)", "timestamp": format.string(from: start.addingTimeInterval(Double(turn) * 60)),
                                        "message": ["role": type, "content": content]]
            if let data = try? JSONSerialization.data(withJSONObject: entry) { lines.append(String(decoding: data, as: UTF8.self)) }
        }
        let paragraph = String(repeating: "The build spends most of its time linking; caching the object files would help. ", count: 4)
        for turn in 0..<turns {
            line("user", "Turn \(turn): make the build faster, and tell me what you changed.", at: turn)
            line("assistant", [["type": "text", "text": "Looking at the build."],
                               ["type": "tool_use", "id": "tool-\(turn)", "name": "Bash", "input": ["command": "swift build -c release"]]], at: turn)
            line("user", [["type": "tool_result", "tool_use_id": "tool-\(turn)",
                           "content": (0..<12).map { "Compiling Module\($0) (\(turn))" }.joined(separator: "\n")]], at: turn)
            line("assistant", [["type": "text", "text": "## Turn \(turn)\n\n\(paragraph)\n\n- one\n- two\n- `three`"]], at: turn)
        }
        try? VibePaths.writePrivate(Data((lines.joined(separator: "\n") + "\n").utf8), to: URL(fileURLWithPath: path))
    }

    private final class Bench {
        let seconds: TimeInterval
        let transcriptSource: String?
        let sidebarPhase: Bool
        let churn: Churn?
        /// `--views N`: sessions that print, shown one after another.
        let views: (count: Int, lines: Int)?
        var viewSessions: [UUID] = []
        /// `--dump FOLDER`: vmmap, heap and leaks in full at the snapshots before and after churn.
        let dumpFolder: String?
        let churned: ChurnedAgents
        let started = Date()
        let store: SessionStore
        let host = HostClient()
        let model = WindowModel()
        lazy var leads = LeadController(host: host, store: store) { _ in "claude" }
        var window: MainWindowController?
        var sidebar: SidebarController?
        var cancellables: Set<AnyCancellable> = []
        var sessionPublishes = 0
        var sectionPublishes = 0
        var shells: [UUID] = []
        /// The copy the fixed agent's chat reads (nil: no chat phase).
        var transcript: String?
        /// Churn's live shells and agents, oldest first, and the ones ended last cycle (removed this one).
        var churnShells: [UUID] = []
        var endedShell: UUID?
        var churnAgents: [(tty: String, pid: Int32, transcript: String)] = []
        var endedAgent: (tty: String, pid: Int32, transcript: String)?
        /// The first window-closed phase, before any churn, and the one after the warm-up (the baseline).
        var cold: Snapshot?
        var baseline: Snapshot?

        init(seconds: TimeInterval, transcript: String?, sidebar: Bool, churn: Churn?, views: (count: Int, lines: Int)?, dump: String?) {
            self.seconds = seconds
            self.views = views
            dumpFolder = dump
            transcriptSource = transcript
            sidebarPhase = sidebar
            self.churn = churn
            let churned = ChurnedAgents()
            self.churned = churned
            let started = self.started
            for folder in 0..<3 {
                try? FileManager.default.createDirectory(atPath: (NSHomeDirectory() as NSString).appendingPathComponent("bench-\(folder)"),
                                                         withIntermediateDirectories: true)
            }
            store = SessionStore(scanner: SessionScanner(
                processes: { IdleBench.processes(started: started).merging(churned.processes) { fixed, _ in fixed } },
                cwd: { _ in (NSHomeDirectory() as NSString).appendingPathComponent("bench-0") },
                arguments: { process in
                    process.pid == 50_900
                        ? ["/bin/zsh", "-c", "source /tmp/claude/shell-snapshots/snapshot-zsh.sh && eval 'npm run dev' < /dev/null"] : []
                }))
            host.hostArguments = HostClient.endsWithThisProcess
        }

        static var transcriptFolder: String { (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects/-bench") }

        func start() {
            let folder = Self.transcriptFolder
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            if let source = transcriptSource {
                let copy = (folder as NSString).appendingPathComponent((source as NSString).lastPathComponent)
                try? FileManager.default.removeItem(atPath: copy)
                try? FileManager.default.copyItem(atPath: source, toPath: copy)
                transcript = copy
            } else if churn != nil {
                let made = (folder as NSString).appendingPathComponent("bench-made-up.jsonl")
                IdleBench.writeTranscript(to: made)
                transcript = made
            }
            IdleBench.writeHooks(started: started, transcript: transcript)
            // Wired as the app delegate wires them.
            host.$sessions.receive(on: RunLoop.main).sink { [weak self] in self?.store.updateHosted($0) }.store(in: &cancellables)
            store.$sessions.combineLatest(host.$sessions, host.$state, store.$tableRead).receive(on: RunLoop.main)
                .sink { [weak self] sessions, hosted, state, table in
                    self?.model.update(sessions: sessions, hosted: hosted, table: table, hostAnswered: state != .connecting)
                }
                .store(in: &cancellables)
            store.$sessions.dropFirst().sink { [weak self] _ in self?.sessionPublishes += 1 }.store(in: &cancellables)
            model.$sections.dropFirst().sink { [weak self] _ in self?.sectionPublishes += 1 }.store(in: &cancellables)
            store.hostScreens = { [weak self] in self?.host.screens ?? [:] }
            store.requestHostScreens = { [weak self] in self?.host.refreshScreens(ttys: $0) }
            HangWatchdog.shared.describeState = { [weak self] in
                guard let self else { return "" }
                return "host state=\(self.host.state) sessions=\(self.host.sessions.count)\nscanned sessions=\(self.store.sessions.count)\n"
                    + (self.window?.debugState() ?? "window never opened")
            }
            HangWatchdog.shared.start()
            _ = leads
            store.start()
            spawnShells(5) { [weak self] in self?.phases() }
        }

        private func spawnShells(_ count: Int, then done: @escaping () -> Void) {
            guard count > 0 else { return done() }
            // The first one stands in for an agent working in another session: its title's spinner turns ten times a
            // second, as Claude's does; nothing else on its screen changes.
            let command = shells.isEmpty
                ? "while :; do for c in ⠋ ⠙ ⠹ ⠸; do printf '\\033]0;%s Working on the bench\\007' $c; sleep 0.1; done; done"
                : "/bin/ls -la /usr/bin | /usr/bin/head -60; exec /bin/cat"
            host.spawn(SpawnRequest(cwd: NSHomeDirectory(), command: command, env: [:], cols: 120, rows: 40, keepShell: false,
                                    label: "Bench shell \(count)", agent: nil)) { [weak self] result in
                if case .success(let session) = result { self?.shells.append(session.id) }
                if case .failure(let error) = result { print("couldn't start a shell: \(error.message)") }
                self?.spawnShells(count - 1, then: done)
            }
        }

        private func phases() {
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
            var steps: [Step] = []
            // Every shell attached once, as after switching between them; the last one stays on screen.
            let attach = { [weak self] in
                guard let self else { return }
                self.model.showsChat = false
                for id in self.shells {
                    self.model.selectedID = "host:\(id)"
                    self.window?.pane.show(hostID: id, focus: false)
                    self.window?.window?.displayIfNeeded()
                }
            }
            if transcript != nil {
                steps.append(.phase("window open, chat", { [weak self] in
                    controller.presentOffscreen()
                    attach()
                    self?.model.showsChat = true
                    self?.model.selectedID = "tty:ttys900"
                }))
            }
            steps.append(.phase("window open, terminal", { [weak self] in
                controller.presentOffscreen()
                attach()
                if let last = self?.shells.last { self?.model.selectedID = "host:\(last)" }
            }))
            if let views {
                steps.append(.views)
                steps.append(.phase("window open, \(views.count) busy shown", {}))
                steps.append(.pause(TerminalPaneController.parkedLifetime))
                steps.append(.phase("window open, \(views.count) busy, later", {}))
            }
            steps.append(.phase("window closed", { controller.window?.close() }))
            if let churn {
                if churn.warmup > 0 {
                    steps.append(.warmup)
                    steps.append(.phase("window closed, warmed up", { controller.window?.close() }))
                }
                steps.append(.churn)
                steps.append(.phase(Self.afterChurn, { controller.window?.close() }))
            }
            if sidebarPhase {
                steps.append(.phase("sidebar (popover drawn)", { [weak self] in
                    guard let self else { return }
                    let content = AnyView(PopoverView(
                        store: self.store, state: PopoverState(), preferences: Preferences(), onOpen: { _ in }, onInstallHooks: {},
                        onQuit: {}, onRename: { _ in }, onResetName: { _ in }, onNewSession: { _, _ in }, presetsFor: { _ in [] },
                        onEditCommands: {}, onPause: { _, _ in }, onResume: { _ in }, isSidebar: true, onOpenWindow: {},
                        onSettings: {}, onAllowNotifications: {}))
                    let sidebar = SidebarController(content: content)
                    sidebar.autoHide = false   // docked, so its PopoverView (the popover's rows and their clocks) is drawn
                    sidebar.setEnabled(true)
                    self.sidebar = sidebar
                }))
            }
            print(String(format: "idle bench: %d agent sessions, %d shells, %.0f s per phase", IdleBench.agents.count, shells.count, seconds))
            run(steps[...])
        }

        enum Step {
            case phase(String, () -> Void)
            /// The window-closed phase just measured is the cold one; then `--churn-warmup`'s cycles.
            case warmup
            /// The window-closed phase just measured is the baseline; then `--churn`'s cycles.
            case churn
            /// `--views`' sessions, each shown until what it printed is on screen.
            case views
            case pause(TimeInterval)
        }

        static let afterChurn = "window closed, after churn"

        private func run(_ steps: ArraySlice<Step>) {
            guard let step = steps.first else { return finish() }
            if case .views = step, let views {
                let began = Date()
                return showBusy(views.count, lines: views.lines) { [weak self] in
                    print(String(format: "views: %d sessions of %d lines shown in %.0f s", views.count, views.lines, Date().timeIntervalSince(began)))
                    fflush(stdout)
                    self?.run(steps.dropFirst())
                }
            }
            if case .pause(let seconds) = step {
                return DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.run(steps.dropFirst()) }
            }
            guard case .phase(let name, let setUp) = step else {
                let warmup: Bool
                if case .warmup = step { warmup = true } else { warmup = false }
                return snapshot(warmup ? "cold" : "before") { [weak self] snapshot in
                    guard let self, let churn = self.churn else { return }
                    if warmup { self.cold = snapshot } else { self.baseline = snapshot }
                    print(warmup ? String(format: "churn: warm-up, %d cycle(s)", churn.warmup)
                                 : String(format: "churn: %.0f minutes at %.0f× (%d cycles of %.0f s, each %.2f s here)", churn.minutes,
                                          churn.speed, churn.cycles, Churn.cycle, churn.interval))
                    fflush(stdout)
                    let began = Date()
                    // The warm-up's cycles come first; the churn's go on from them (its sessions' ttys and pids).
                    let first = warmup ? 0 : churn.warmup
                    self.churnCycle(first, of: first + (warmup ? churn.warmup : churn.cycles), interval: churn.interval) { [weak self] in
                        print(String(format: "churn: %@ in %.0f s", warmup ? "warmed up" : "done", Date().timeIntervalSince(began)))
                        self?.run(steps.dropFirst())
                    }
                }
            }
            setUp()
            // Settle (opening, first layouts, the first transcript read), then measure.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                let before = Usage.now()
                let publishes = (self.sessionPublishes, self.sectionPublishes)
                DispatchQueue.main.asyncAfter(deadline: .now() + self.seconds) { [weak self] in
                    guard let self else { return }
                    let after = Usage.now()
                    let wall = after.wall - before.wall
                    print(String(format: "%-26@  cpu %5.2f %%  wakeups %6.1f/s  sessions published %d  sections published %d  rss %4.0f MB  footprint %4.0f MB  live views %@ chats %@",
                                 name as NSString, (after.cpu - before.cpu) / wall * 100, Double(after.wakeups - before.wakeups) / wall,
                                 self.sessionPublishes - publishes.0, self.sectionPublishes - publishes.1,
                                 Double(after.rss) / 1_048_576, Double(after.footprint) / 1_048_576,
                                 Live.views.map(String.init) ?? "n/a", Live.chats.map(String.init) ?? "n/a"))
                    if let window = self.window?.window, window.isVisible {
                        self.printTerminals(window)
                    }
                    fflush(stdout)
                    guard name == Self.afterChurn, let baseline = self.baseline else { return self.run(steps.dropFirst()) }
                    self.snapshot("after") { [weak self] now in
                        Self.compare(cold: self?.cold, baseline, now)
                        self?.run(steps.dropFirst())
                    }
                }
            }
        }

        private func printTerminals(_ window: NSWindow) {
            guard let pane = self.window?.pane else { return }
            let stores: (views: Int, bytes: Int) = pane.backingStores
            let drawn = window.occlusionState.contains(.visible) ? "yes" : "no (occluded)"
            print("  window drawn: \(drawn), terminals attached \(pane.attachedIDs.count), holding a drawing \(stores.views)"
                  + String(format: " (%.1f MB)", Double(stores.bytes) / 1_048_576))
        }

        // MARK: Views

        /// `count` sessions printing `lines` coloured lines each, each shown (and its view attached) while it prints, until
        /// its last line is on screen.
        private func showBusy(_ count: Int, lines: Int, then done: @escaping () -> Void) {
            guard count > 0, let controller = window else { return done() }
            let marker = "bench views: printed"
            let awk = "BEGIN { for (i = 1; i <= \(lines); i++) printf \"\\033[3%dm%06d\\033[0m agent output: Compiling Module%d, "
                + "reading Sources/VibeSwitcher/File%d.swift, 42 tests passed\\n\", i % 7 + 1, i, i % 50, i % 300; print \"\(marker)\" }"
            host.spawn(SpawnRequest(cwd: NSHomeDirectory(), command: "/usr/bin/awk '\(awk)'; exec /bin/cat", env: [:], cols: 120, rows: 40,
                                    keepShell: false, label: "Printing \(count)", agent: nil)) { [weak self] result in
                guard let self else { return }
                guard case .success(let session) = result else {
                    if case .failure(let error) = result { print("couldn't start a busy session: \(error.message)") }
                    return self.showBusy(count - 1, lines: lines, then: done)
                }
                self.viewSessions.append(session.id)
                self.model.showsChat = false
                self.model.selectedID = "host:\(session.id)"
                controller.pane.show(hostID: session.id, focus: false)
                controller.window?.displayIfNeeded()
                let deadline = Date().addingTimeInterval(60)
                func check() {
                    let shown = controller.pane.screenLines(session.id).contains { $0.contains(marker) }
                    guard shown || Date() > deadline else {
                        return DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: check)
                    }
                    if !shown { print("busy session \(count): its output never reached the screen") }
                    controller.window?.displayIfNeeded()
                    self.showBusy(count - 1, lines: lines, then: done)
                }
                check()
            }
        }

        // MARK: Churn

        /// One cycle of churn: sessions start and end, the window opens on the new shell, the chat opens on the agent
        /// started last cycle (scanned by now) and closes, the window closes.
        private func churnCycle(_ index: Int, of count: Int, interval: TimeInterval, done: @escaping () -> Void) {
            guard index < count, let controller = window else {
                return endChurned { DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: done) }
            }
            if index % 10 == 0 { Self.printCurve(index) }
            let chatTTY = churnAgents.last?.tty ?? IdleBench.agents[0].tty
            startAgent(index)
            startShell(index) { [weak self] id in
                guard let self else { return }
                controller.presentOffscreen()
                self.model.showsChat = false
                if let id {
                    self.model.selectedID = "host:\(id)"
                    controller.pane.show(hostID: id, focus: false)
                }
                controller.window?.displayIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + interval / 3) { [weak self] in
                    self?.model.showsChat = true
                    self?.model.selectedID = "tty:\(chatTTY)"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + interval * 2 / 3) { [weak self] in
                    self?.model.showsChat = false
                    controller.window?.close()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                    self?.churnCycle(index + 1, of: count, interval: interval, done: done)
                }
            }
        }

        private static let churnLive = 3

        /// Growth so far, without vmmap: a rise that levels off is malloc's high water, one that keeps climbing a leak.
        private static func printCurve(_ cycle: Int) {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            print(String(format: "  cycle %3d  footprint %5.1f MB  malloc in use %5.1f MB, held %5.1f MB  live views %@ chats %@", cycle,
                         Double(Usage.now().footprint) / 1_048_576, Double(stats.size_in_use) / 1_048_576,
                         Double(stats.size_allocated) / 1_048_576, Live.views.map(String.init) ?? "n/a", Live.chats.map(String.init) ?? "n/a"))
            fflush(stdout)
        }

        /// A new shell, and the oldest past `churnLive` ended (its row stays a cycle, then is removed, as when you close it).
        private func startShell(_ index: Int, then shown: @escaping (UUID?) -> Void) {
            if let ended = endedShell { host.remove(ended) }
            endedShell = nil
            if churnShells.count >= Self.churnLive {
                let oldest = churnShells.removeFirst()
                host.kill(oldest)
                endedShell = oldest
            }
            host.spawn(SpawnRequest(cwd: NSHomeDirectory(), command: "/bin/ls -la /usr/bin | /usr/bin/head -60; exec /bin/cat", env: [:],
                                    cols: 120, rows: 40, keepShell: false, label: "Churn shell \(index)", agent: nil)) { [weak self] result in
                guard let self else { return }
                if case .success(let session) = result {
                    self.churnShells.append(session.id)
                    return shown(session.id)
                }
                if case .failure(let error) = result { print("couldn't start a churn shell: \(error.message)") }
                shown(nil)
            }
        }

        /// A new agent session with a transcript of its own, and the oldest past `churnLive` ended (its process gone; a
        /// cycle later its hook state and transcript too).
        private func startAgent(_ index: Int) {
            if let ended = endedAgent { forgetAgent(ended) }
            endedAgent = nil
            if churnAgents.count >= Self.churnLive {
                let oldest = churnAgents.removeFirst()
                churned.remove(oldest.pid)
                endedAgent = oldest
            }
            let tty = String(format: "ttys%03d", 700 + index % 100)
            let pid = Int32(51_000 + index)
            let copy = (Self.transcriptFolder as NSString).appendingPathComponent("churn-\(index).jsonl")
            if let transcript { try? FileManager.default.copyItem(atPath: transcript, toPath: copy) }
            churned.add(ProcInfo(pid: pid, ppid: 50_000, tty: tty, comm: "claude", startTime: Date().addingTimeInterval(-60), agent: .claude))
            IdleBench.writeHook(index: index, agent: .claude, tty: tty, pid: pid, event: "Stop", ago: 1, transcript: copy)
            churnAgents.append((tty, pid, copy))
        }

        private func forgetAgent(_ agent: (tty: String, pid: Int32, transcript: String)) {
            try? FileManager.default.removeItem(at: VibePaths.stateFile(tty: agent.tty))
            try? FileManager.default.removeItem(atPath: agent.transcript)
        }

        /// Everything churn started ends, and a moment later is removed.
        private func endChurned(then done: @escaping () -> Void) {
            churnShells.forEach(host.kill)
            churnAgents.forEach { churned.remove($0.pid) }
            let shells = churnShells + [endedShell].compactMap { $0 }
            let agents = churnAgents + [endedAgent].compactMap { $0 }
            churnShells = []
            churnAgents = []
            endedShell = nil
            endedAgent = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                shells.forEach(self.host.remove)
                agents.forEach(self.forgetAgent)
                done()
            }
        }

        // MARK: Footprint

        struct Snapshot {
            let footprint: UInt64
            let views: Int?
            let chats: Int?
            /// vmmap's region categories: dirty + swapped bytes (what phys_footprint counts), and malloc's bytes in use.
            let regions: [String: Double]
            let mallocAllocated: Double?
        }

        /// The footprint and live counts now, and vmmap's categories (read off the main thread; vmmap suspends this
        /// process while it looks).
        private func snapshot(_ label: String, _ done: @escaping (Snapshot) -> Void) {
            let footprint = Usage.now().footprint
            let (views, chats) = (Live.views, Live.chats)
            let pid = getpid()
            let dump = dumpFolder.map { ($0 as NSString).appendingPathComponent(label) }
            DispatchQueue.global().async {
                if let dump { VMMap.dump(pid: pid, to: dump) }
                let (regions, allocated) = VMMap.summary(pid: pid)
                DispatchQueue.main.async {
                    done(Snapshot(footprint: footprint, views: views, chats: chats, regions: regions, mallocAllocated: allocated))
                }
            }
        }

        /// R8's target: under 150 MB with the window closed (cold), at most 10 % more after churn than after the warm-up,
        /// no views or chats left behind.
        private static func compare(cold: Snapshot?, _ before: Snapshot, _ after: Snapshot) {
            let mb = { (bytes: Double) in bytes / 1_048_576 }
            let first = cold ?? before
            let growth = (Double(after.footprint) / Double(max(before.footprint, 1)) - 1) * 100
            print(String(format: "RESULT footprint-window-closed-mb %.1f", mb(Double(first.footprint))))
            print(String(format: "RESULT footprint-warm-baseline-mb %.1f", mb(Double(before.footprint))))
            print(String(format: "RESULT footprint-after-churn-mb %.1f", mb(Double(after.footprint))))
            print(String(format: "RESULT churn-growth-percent %.1f", growth))
            print("RESULT live-terminal-views \(first.views.map(String.init) ?? "n/a") \(after.views.map(String.init) ?? "n/a")")
            print("RESULT live-chat-models \(first.chats.map(String.init) ?? "n/a") \(after.chats.map(String.init) ?? "n/a")")
            print(String(format: "target: window closed under 150 MB: %@; growth after churn (from the warm baseline) at most 10 %%: %@",
                         mb(Double(first.footprint)) < 150 ? "met" : "MISSED", growth <= 10 ? "met" : "MISSED"))
            if before.regions.isEmpty || after.regions.isEmpty {
                print("top growers: vmmap gave nothing")
            } else {
                print("top growers (vmmap dirty + swapped, after churn minus the warm baseline):")
                let names = Set(before.regions.keys).union(after.regions.keys)
                let grown = names.map { ($0, (after.regions[$0] ?? 0) - (before.regions[$0] ?? 0)) }.sorted { $0.1 > $1.1 }
                for (name, delta) in grown.prefix(6) {
                    print(String(format: "  %-30@ %+7.1f MB  (%.1f → %.1f MB)", name as NSString, mb(delta),
                                 mb(before.regions[name] ?? 0), mb(after.regions[name] ?? 0)))
                }
                print("largest after churn: " + after.regions.sorted { $0.value > $1.value }.prefix(6)
                    .map { String(format: "%@ %.1f MB", $0.key, mb($0.value)) }.joined(separator: ", "))
            }
            if let was = before.mallocAllocated, let now = after.mallocAllocated {
                print(String(format: "malloc: %.1f → %.1f MB allocated", mb(was), mb(now)))
            }
            // Not judged, a diagnosis: how much of the growth is pages malloc holds free (given back under memory
            // pressure, or here when asked) rather than memory in use. The phases after this one start from it.
            let held = Usage.now().footprint
            malloc_zone_pressure_relief(nil, 0)
            let relieved = Usage.now().footprint
            print(String(format: "diagnosis: with malloc's free pages given back (malloc_zone_pressure_relief) the footprint goes %.1f → %.1f MB, %+.1f %% on the warm baseline",
                         mb(Double(held)), mb(Double(relieved)), (Double(relieved) / Double(max(before.footprint, 1)) - 1) * 100))
            fflush(stdout)
        }

        private func finish() {
            // The private host runs from this build's folder, under the scratch home: its sessions and then it end with
            // the bench. By pid (this process's child): other benches and tests run hosts from the same build. A bench
            // that doesn't get here (killed, hung) has its host end all the same (`HostClient.endsWithThisProcess`).
            (shells + viewSessions).forEach(host.kill)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                for process in ProcessTable.snapshot().values where process.ppid == getpid() && process.comm.hasPrefix("vibeswitcher-hos") {
                    kill(process.pid, SIGTERM)
                }
                exit(0)
            }
        }
    }

    /// Debug builds' live instance counts (nil in release, which doesn't count).
    enum Live {
        static var views: Int? {
            #if DEBUG
            HostTerminalView.live
            #else
            nil
            #endif
        }

        static var chats: Int? {
            #if DEBUG
            ChatModel.live
            #else
            nil
            #endif
        }
    }

    /// `vmmap -summary` of a process: its region categories' dirty + swapped bytes, and the malloc zones' bytes allocated.
    enum VMMap {
        /// `--dump FOLDER`: vmmap, heap and leaks of the process in full, as PREFIX-vmmap.txt and so on, to diff the
        /// two snapshots (run with MallocStackLogging=lite for leaks' stacks).
        static func dump(pid: Int32, to prefix: String) {
            for (tool, arguments) in [("vmmap", [String(pid)]), ("heap", ["-s", String(pid)]), ("leaks", [String(pid), "--outputGraph=\(prefix).memgraph"])] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/\(tool)")
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { continue }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                try? VibePaths.writePrivate(data, to: URL(fileURLWithPath: "\(prefix)-\(tool).txt"))
            }
        }

        static func summary(pid: Int32) -> (regions: [String: Double], mallocAllocated: Double?) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
            process.arguments = ["-summary", String(pid)]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return ([:], nil) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parse(String(decoding: data, as: UTF8.self))
        }

        /// The region table (between its `===` rules) and the malloc zones' TOTAL line.
        static func parse(_ text: String) -> (regions: [String: Double], mallocAllocated: Double?) {
            var regions: [String: Double] = [:]
            var table = 0
            var inRegions = false
            var allocated: Double?
            let size = #/([\d.]+)([KMG]?)/#
            func bytes(_ field: Substring) -> Double? {
                guard let match = field.wholeMatch(of: size), let value = Double(match.1) else { return nil }
                let unit: [Substring: Double] = ["K": 1024, "M": 1_048_576, "G": 1_073_741_824]
                return value * unit[match.2, default: 1]
            }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("REGION TYPE") { table = 1 } else if line.hasPrefix("MALLOC ZONE") { table = 2 }
                if line.hasPrefix("===") {
                    inRegions = table == 1 && !inRegions
                    continue
                }
                let fields = line.split(separator: " ")
                if table == 1, inRegions, fields.count >= 9 {
                    // NAME... VIRTUAL RESIDENT DIRTY SWAPPED VOLATILE NONVOL EMPTY COUNT [note]
                    let sizes = fields.indices.first { start in start + 7 < fields.count && (start..<start + 7).allSatisfy { bytes(fields[$0]) != nil } }
                    guard let first = sizes, first > 0, let dirty = bytes(fields[first + 2]), let swapped = bytes(fields[first + 3]) else { continue }
                    regions[fields[..<first].joined(separator: " "), default: 0] += dirty + swapped
                } else if table == 2, fields.first == "TOTAL", fields.count >= 7 {
                    allocated = bytes(fields[6])
                }
            }
            return (regions, allocated)
        }
    }

    /// The process's CPU time, wakeups, instructions and memory now (also for `--ui-bench`).
    struct Usage {
        let wall: TimeInterval
        let cpu: TimeInterval
        let wakeups: UInt64
        /// Instructions retired: the work done, whichever cores did it and however busy the Mac is.
        var instructions: UInt64 = 0
        let rss: UInt64
        let footprint: UInt64

        static func now() -> Usage {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let cpu = TimeInterval(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + TimeInterval(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            var info = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
            } == 0
            let wakeups: UInt64 = read ? info.ri_pkg_idle_wkups + info.ri_interrupt_wkups : 0
            var vm = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let ok = withUnsafeMutablePointer(to: &vm) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            } == KERN_SUCCESS
            return Usage(wall: Date().timeIntervalSinceReferenceDate, cpu: cpu, wakeups: wakeups, instructions: read ? info.ri_instructions : 0,
                         rss: ok ? vm.resident_size : 0, footprint: ok ? vm.phys_footprint : 0)
        }
    }
}
