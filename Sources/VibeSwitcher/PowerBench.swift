import AppKit
import Combine
import Darwin
import VibeCore

/// Debug aid (`CFFIXED_USER_HOME=<scratch> VibeSwitcher --idle-bench [SECONDS] --power`): what the app costs the
/// battery with no window open, as CPU per minute and wakeups a second, in two phases of SECONDS (default 60) each:
/// 1. idle: the session store scanning (the Mac's real process table, read whole as the app reads it, its processes
///    shown to the scan as no one's sessions, so nothing of yours is looked at; and made-up agents in a private session
///    host's quiet shells), the lead controller with no lead, the hang watchdog, the menu bar's checks.
/// 2. lead work: a project lead and a team of 10 workers in that host, each with a transcript its hooks name (1 MB) and
///    a task on a long day's board (50 tasks, 900 KB: the user's were 0.5 to 2.1 MB on 2026-10-20); two of them write a
///    step to their transcripts every 2 s and a hook event every 6 s, as Claude does while it works, the rest wait.
/// Each phase settles 10 s, then is measured: `RESULT power-<phase> CPU_PERCENT WAKEUPS_PER_S CPU_S_PER_MIN
/// HOST_CPU_PERCENT HOST_WAKEUPS_PER_S` (the app's, then the host's: the session host is another process). The 2026-10-20
/// target: idle under 1 % of a core, lead work under 3 % (PowerBenchTests, on a calm Mac).
enum PowerBench {
    static let teamSize = 10
    /// Of the team, these write as they work.
    static let working = 2

    static func run(seconds: TimeInterval) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        VibePaths.ensurePrivateDirectories()
        let bench = Bench(seconds: seconds)
        bench.start()
        app.run()
        exit(0)
    }

    /// CPU time and wakeups of a process so far (`proc_pid_rusage`).
    struct Usage {
        let wall: TimeInterval
        let cpu: TimeInterval
        let wakeups: UInt64

        static func of(_ pid: pid_t) -> Usage {
            var info = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } == 0
            var base = mach_timebase_info_data_t()
            mach_timebase_info(&base)
            // In mach time units.
            let ticks = read ? Double(info.ri_user_time + info.ri_system_time) : 0
            return Usage(wall: Date().timeIntervalSinceReferenceDate, cpu: ticks * Double(base.numer) / Double(base.denom) / 1e9,
                         wakeups: read ? info.ri_pkg_idle_wkups + info.ri_interrupt_wkups : 0)
        }

        /// CPU as a percentage of one core, and wakeups a second, from `before` to this.
        func since(_ before: Usage) -> (cpu: Double, wakeups: Double) {
            let wall = max(0.001, self.wall - before.wall)
            return ((cpu - before.cpu) / wall * 100, Double(wakeups - before.wakeups) / wall)
        }
    }

    private final class Bench {
        let seconds: TimeInterval
        let root = (NSHomeDirectory() as NSString).appendingPathComponent("power-bench")
        let socket = "/tmp/vspb-\(UUID().uuidString.prefix(8)).sock"
        let hostPath = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
        var hostProcess: Process?
        let host: HostClient
        let store: SessionStore
        let agents = BoardBench.Agents()
        var cancellables: Set<AnyCancellable> = []
        lazy var leads = LeadController(host: host, store: store) { _ in "claude" }
        /// What the app runs beside the scan and the lead controller: the menu bar icon's check every 2 s, the
        /// notifications' every 15 s (stand-ins of the same period).
        var appTimers: [Heartbeat.Subscription] = []
        var writer: Heartbeat.Subscription?
        var team: [HostSession] = []
        var transcripts: [String] = []
        var beat = 0

        init(seconds: TimeInterval) {
            self.seconds = seconds
            host = HostClient(socketPath: socket, appKey: HostClient.ownKey(), bundledBuild: { [hostPath] in HostBuild.id(ofExecutableAt: hostPath) })
            // The Mac's own processes, read as the app reads them, as no one's sessions; with the bench's agents.
            store = SessionStore(scanner: SessionScanner(processes: { [agents] in
                var table = (ProcessTable.trySnapshot() ?? [:]).mapValues {
                    ProcInfo(pid: $0.pid, ppid: $0.ppid, tty: nil, comm: $0.comm, startTime: $0.startTime, agent: nil)
                }
                table.merge(agents.table()) { _, agent in agent }
                return table
            }, cwd: { [root] _ in root }, arguments: { _ in [] }))
        }

        func start() {
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: hostPath)
            process.arguments = ["--socket", socket, "--lock", socket + ".lock", "--idle-exit", "60"] + HostClient.endsWithThisProcess
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return finish("the host didn't start: \(error)") }
            hostProcess = process
            host.$sessions.receive(on: RunLoop.main).sink { [weak self] in self?.store.updateHosted($0) }.store(in: &cancellables)
            HangWatchdog.shared.start()
            _ = leads
            store.start()
            appTimers = [Heartbeat.shared.every(2) { _ = NSStatusBar.system.thickness }, Heartbeat.shared.every(15) {}]
            connect(attempts: 100)
        }

        private func connect(attempts: Int) {
            host.connectIfRunning()
            if host.state == .connected { return spawnShells(3) }
            guard attempts > 0 else { return finish("the host never answered") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.connect(attempts: attempts - 1) }
        }

        /// A session that ends with the bench, however it ends: the host then quits on its idle exit.
        private var waits: String { "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 5; done" }

        private func spawnShells(_ count: Int) {
            guard count > 0 else {
                print(String(format: "power bench: %.0f s per phase, after 10 s settling", seconds))
                fflush(stdout)
                return measure("idle") { self.startLead() }
            }
            host.spawn(SpawnRequest(cwd: NSHomeDirectory(), command: waits, env: [:], cols: 120, rows: 40, keepShell: false,
                                    label: "Bench shell \(count)", agent: nil)) { result in
                guard case .success = result else { return self.finish("a shell didn't start") }
                self.spawnShells(count - 1)
            }
        }

        private func startLead() {
            host.spawn(SpawnRequest(cwd: root, command: waits, env: [:], cols: 120, rows: 40, keepShell: false,
                                    label: "Lead · power-bench", agent: "claude")) { result in
                guard case .success(let lead) = result else { return self.finish("the lead's session didn't start") }
                self.spawnTeam(0, lead: lead)
            }
        }

        private func spawnTeam(_ index: Int, lead: HostSession) {
            guard index < PowerBench.teamSize else { return teamStarted(lead: lead) }
            let worktree = (root as NSString).appendingPathComponent(".vibeswitcher/worktrees/task-\(index)")
            try? FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
            host.spawn(SpawnRequest(cwd: worktree, command: waits, env: [:], cols: 120, rows: 40, keepShell: false,
                                    label: "Worker: task-\(index)", agent: "claude")) { result in
                guard case .success(let session) = result else { return self.finish("worker \(index) didn't start") }
                self.team.append(session)
                self.spawnTeam(index + 1, lead: lead)
            }
        }

        private func teamStarted(lead: HostSession) {
            let now = Date()
            let folder = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects/\(RecentProjects.claudeSlug(for: root))")
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let transcript = BoardBench.transcript(bytes: 1 << 20, now: now)
            for (index, session) in ([lead] + team).enumerated() {
                let pid = Int32(61000 + index)
                let path = (folder as NSString).appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl")
                FileManager.default.createFile(atPath: path, contents: transcript)
                writeHook(tty: session.tty, pid: pid, transcript: path, at: now)
                agents.add(tty: session.tty, pid: pid)
                if index > 0 { transcripts.append(path) }
            }
            var board = BoardBench.board(seed: 0)
            board.leadSession = lead.id.uuidString
            board.leadTTY = lead.tty
            board.leadPid = 61000
            for (index, session) in team.enumerated() {
                board.tasks[index].status = .running
                board.tasks[index].worker = session.id.uuidString
                board.tasks[index].verifier = nil
            }
            try? BoardStore(root: root).update { $0 = board }
            store.refresh()
            leads.refresh()
            // Two of them work: a step in the transcript every 2 s, a hook event every 6 s.
            writer = Heartbeat.shared.every(2) { [weak self] in self?.work() }
            wait(until: { [self] in
                Set(store.sessions.compactMap { $0.hostID }).isSuperset(of: team.map(\.id)) && leads.boards[root]?.tasks.prefix(team.count).compactMap(\.worker) == team.map(\.id.uuidString)
            }, then: { self.measure("lead-work") { self.finish(nil) } }, else: "the team never showed in the scan and on the board")
        }

        private func work() {
            beat += 1
            let now = Date()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for (index, path) in transcripts.prefix(PowerBench.working).enumerated() {
                let step: [String: Any] = ["type": "assistant", "isSidechain": false, "uuid": UUID().uuidString, "timestamp": formatter.string(from: now),
                                           "message": ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_b\(beat)", "name": "Bash",
                                                                                         "input": ["command": "swift build", "description": "Build"]]]]]
                if let handle = FileHandle(forWritingAtPath: path), var line = try? JSONSerialization.data(withJSONObject: step) {
                    line.append(0x0A)
                    handle.seekToEndOfFile()
                    handle.write(line)
                    try? handle.close()
                }
                if beat % 3 == 0 { writeHook(tty: team[index].tty, pid: Int32(61001 + index), transcript: path, at: now) }
            }
        }

        private func writeHook(tty: String, pid: Int32, transcript: String, at now: Date) {
            var hook = HookState(agent: .claude, tty: tty, lastEvent: "PreToolUse", lastEventAt: now.timeIntervalSince1970)
            hook.agentPid = pid
            hook.transcriptPath = transcript
            hook.toolName = "Bash"
            hook.toolStartedAt = now.timeIntervalSince1970
            try? hook.save(to: VibePaths.stateFile(tty: tty))
        }

        /// Settles 10 s, then measures the app and the host for `seconds`.
        private func measure(_ phase: String, then next: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
                let hostPid = hostProcess?.processIdentifier ?? 0
                let app = Usage.of(getpid()), hostBefore = Usage.of(hostPid)
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
                    let (cpu, wakeups) = Usage.of(getpid()).since(app)
                    let (hostCPU, hostWakeups) = Usage.of(hostPid).since(hostBefore)
                    print(String(format: "%-10@ app: cpu %5.2f %% of a core (%.2f s a minute), wakeups %6.1f/s · host: cpu %5.2f %%, wakeups %5.1f/s",
                                 phase as NSString, cpu, cpu * 0.6, wakeups, hostCPU, hostWakeups))
                    print(String(format: "RESULT power-%@ %.3f %.1f %.3f %.3f %.1f", phase, cpu, wakeups, cpu * 0.6, hostCPU, hostWakeups))
                    fflush(stdout)
                    next()
                }
            }
        }

        private func wait(until condition: @escaping () -> Bool, then: @escaping () -> Void, else failure: String, tries: Int = 3000) {
            if condition() { return then() }
            guard tries > 0 else { return finish(failure) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self.wait(until: condition, then: then, else: failure, tries: tries - 1) }
        }

        private func finish(_ failure: String?) {
            if let failure { print("FAIL  \(failure)") }
            fflush(stdout)
            // The host is this process's child: ended by its pid (its sessions end when this process does).
            if let hostProcess, hostProcess.isRunning {
                kill(hostProcess.processIdentifier, SIGTERM)
                hostProcess.waitUntilExit()
            }
            exit(failure == nil ? 0 : 1)
        }
    }
}
