import AppKit
import Combine
import Darwin
import SwiftUI
import VibeCore

/// Debug aid (`CFFIXED_USER_HOME=<scratch> VibeSwitcher --idle-bench [SECONDS] [--transcript PATH] [--sidebar]`): what
/// the app costs while nothing changes. In this process, on a scratch home: the session store scanning made-up agent
/// sessions (one with a background shell, whose age is in its detail), a private session host running a few quiet
/// shells, the hang watchdog and the lead controller's timer, and the main window off screen. Each phase settles,
/// then runs SECONDS (default 20) and prints its CPU, wakeups, how often the session list was published, and memory:
/// the window on the chat (with `--transcript`, copied into the scratch home), on a terminal, then closed, then
/// closed with the sidebar on (`--sidebar`).
enum IdleBench {
    static func run(arguments: [String]) -> Never {
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? ""
        guard NSHomeDirectory() != realHome else {
            print("--idle-bench runs on a scratch home only: set CFFIXED_USER_HOME to an empty folder.")
            exit(1)
        }
        let seconds = arguments.first.flatMap(TimeInterval.init) ?? 20
        let transcript = arguments.firstIndex(of: "--transcript").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        VibePaths.ensurePrivateDirectories()
        let bench = Bench(seconds: seconds, transcript: transcript, sidebar: arguments.contains("--sidebar"))
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
        let now = Date().timeIntervalSince1970
        for (index, mock) in agents.enumerated() {
            guard let event = mock.event else { continue }
            var state = HookState(agent: mock.agent, tty: mock.tty, lastEvent: event, lastEventAt: now - mock.ago)
            state.agentPid = Int32(50_100 + index)
            state.sessionId = UUID().uuidString
            state.cwd = (NSHomeDirectory() as NSString).appendingPathComponent("bench-\(index % 3)")
            state.firstPrompt = "Bench session \(index)"
            state.lastPrompt = "Make the build faster"
            state.lastMessage = "Done: the build is faster now."
            if event == "PreToolUse" {
                state.toolName = "Bash"
                state.toolDetail = "npm test"
                state.toolStartedAt = now - mock.ago
            }
            if event == "Notification" {
                state.notificationType = "permission_prompt"
                state.request = "Run rm -rf build?"
            }
            if index == 0 { state.transcriptPath = transcript }
            try? state.save(to: VibePaths.stateFile(tty: mock.tty))
        }
    }

    private final class Bench {
        let seconds: TimeInterval
        let transcriptSource: String?
        let sidebarPhase: Bool
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

        init(seconds: TimeInterval, transcript: String?, sidebar: Bool) {
            self.seconds = seconds
            transcriptSource = transcript
            sidebarPhase = sidebar
            let started = self.started
            for folder in 0..<3 {
                try? FileManager.default.createDirectory(atPath: (NSHomeDirectory() as NSString).appendingPathComponent("bench-\(folder)"),
                                                         withIntermediateDirectories: true)
            }
            store = SessionStore(scanner: SessionScanner(
                processes: { IdleBench.processes(started: started) },
                cwd: { _ in (NSHomeDirectory() as NSString).appendingPathComponent("bench-0") },
                arguments: { process in
                    process.pid == 50_900
                        ? ["/bin/zsh", "-c", "source /tmp/claude/shell-snapshots/snapshot-zsh.sh && eval 'npm run dev' < /dev/null"] : []
                }))
        }

        func start() {
            var transcript: String?
            if let source = transcriptSource {
                let folder = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects/-bench")
                try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                let copy = (folder as NSString).appendingPathComponent((source as NSString).lastPathComponent)
                try? FileManager.default.removeItem(atPath: copy)
                try? FileManager.default.copyItem(atPath: source, toPath: copy)
                transcript = copy
            }
            IdleBench.writeHooks(started: started, transcript: transcript)
            // Wired as the app delegate wires them.
            host.$sessions.receive(on: RunLoop.main).sink { [weak self] in self?.store.updateHosted($0) }.store(in: &cancellables)
            store.$sessions.combineLatest(host.$sessions, host.$state).receive(on: RunLoop.main)
                .sink { [weak self] sessions, hosted, state in
                    self?.model.update(sessions: sessions, hosted: hosted, hostAnswered: state != .connecting)
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
            var steps: [(String, () -> Void)] = []
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
            if transcriptSource != nil {
                steps.append(("window open, chat", { [weak self] in
                    controller.presentOffscreen()
                    attach()
                    self?.model.showsChat = true
                    self?.model.selectedID = "tty:ttys900"
                }))
            }
            steps.append(("window open, terminal", { [weak self] in
                controller.presentOffscreen()
                attach()
                if let last = self?.shells.last { self?.model.selectedID = "host:\(last)" }
            }))
            steps.append(("window closed", { controller.window?.close() }))
            if sidebarPhase {
                steps.append(("window closed, sidebar on", { [weak self] in
                    guard let self else { return }
                    let content = AnyView(PopoverView(
                        store: self.store, state: PopoverState(), preferences: Preferences(), onOpen: { _ in }, onInstallHooks: {},
                        onQuit: {}, onRename: { _ in }, onResetName: { _ in }, onNewSession: { _, _ in }, presetsFor: { _ in [] },
                        onEditCommands: {}, onPause: { _, _ in }, onResume: { _ in }, isSidebar: true, onOpenWindow: {},
                        onSettings: {}, onAllowNotifications: {}))
                    let sidebar = SidebarController(content: content)
                    sidebar.setEnabled(true)
                    self.sidebar = sidebar
                }))
            }
            print(String(format: "idle bench: %d agent sessions, %d shells, %.0f s per phase", IdleBench.agents.count, shells.count, seconds))
            run(steps[...])
        }

        private func run(_ steps: ArraySlice<(String, () -> Void)>) {
            guard let (name, setUp) = steps.first else { return finish() }
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
                    print(String(format: "%-26@  cpu %5.2f %%  wakeups %6.1f/s  sessions published %d  sections published %d  rss %4.0f MB  footprint %4.0f MB",
                                 name as NSString, (after.cpu - before.cpu) / wall * 100, Double(after.wakeups - before.wakeups) / wall,
                                 self.sessionPublishes - publishes.0, self.sectionPublishes - publishes.1,
                                 Double(after.rss) / 1_048_576, Double(after.footprint) / 1_048_576))
                    if let window = self.window?.window, window.isVisible {
                        self.printTerminals(window)
                    }
                    fflush(stdout)
                    self.run(steps.dropFirst())
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

        private func finish() {
            // The private host runs from this build's folder, under the scratch home: end it with the bench.
            let stop = Process()
            stop.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            stop.arguments = ["-f", HostClient.hostExecutable.path]
            try? stop.run()
            stop.waitUntilExit()
            exit(0)
        }
    }

    /// The process's CPU time, wakeups and memory now (also for `--ui-bench`).
    struct Usage {
        let wall: TimeInterval
        let cpu: TimeInterval
        let wakeups: UInt64
        let rss: UInt64
        let footprint: UInt64

        static func now() -> Usage {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let cpu = TimeInterval(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + TimeInterval(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            var info = rusage_info_v4()
            let wakeups: UInt64 = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
            } == 0 ? info.ri_pkg_idle_wkups + info.ri_interrupt_wkups : 0
            var vm = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let ok = withUnsafeMutablePointer(to: &vm) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            } == KERN_SUCCESS
            return Usage(wall: Date().timeIntervalSinceReferenceDate, cpu: cpu, wakeups: wakeups,
                         rss: ok ? vm.resident_size : 0, footprint: ok ? vm.phys_footprint : 0)
        }
    }
}
