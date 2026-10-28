import AppKit
import Combine
import Darwin
import SwiftUI
import VibeCore

/// Debug aid (`CFFIXED_USER_HOME=<scratch> VibeSwitcher --ui-bench --team-churn [SECONDS] [--onscreen]`, or
/// `scripts/ui-bench.sh --team-churn`): what the window's main thread spends on a lead's chat with its Team tab beside it
/// while the host's sessions change, as when the window froze for seconds at a time (10-24, 10-25). The window (the real
/// one, off screen unless `--onscreen`) shows a project lead's chat (a made-up agent in a session of a private session
/// host, its transcript of ~70 items) with the inspector on the Team tab, its board the size of the real ones (220
/// tasks, ~3 MB), its team (6 workers on the board) and 4 sessions of another project, each session retitling itself
/// every 2 s (OSC 0: an upsert from the host each time, ~5 a second). The phases, SECONDS (default 20) each but the second:
/// 1. quiet: nothing changes; the main thread's CPU a second, the floor.
/// 2. slow ticks: the Team tab's timeline ticking every 10 s on the clock: the main thread's CPU in the second around each
///    of 4 ticks, over the floor.
/// 3. ticks: a decision fading, so the timeline ticks every second (and the fade animates): the main thread's CPU a tick.
/// 4. churn: the sessions retitling: the main thread's CPU per upsert (over the quiet floor).
/// With `--ax`, an accessibility client is attached as the user's was when the window froze for 3–25 s (10-27): SwiftUI's
/// accessibility turned on in every hosting view of the window, the window's tree walked after each upsert (each
/// element's role and children, as a client reads them), and the lead's transcript 75 turns (300 entries, the project-b
/// lead's 290-odd); the elements reached are printed with the phases.
/// Each phase prints the main thread's longest block (its own CPU time while a post from another thread waited, and the
/// wall clock's), and `RESULT team-churn …` lines. Nothing is checked: it's for comparing builds.
///
/// `--modal SECONDS` (memory, 2026-10-28): instead of the phases, the main run loop held in the modal panel mode for
/// SECONDS, as End Session…'s alert holds it while it's up (left open overnight, 2026-10-27: 990 MB by morning), while
/// another thread writes the board every second (a checkpoint each time, as a lead's tools do) and the sessions retitle
/// themselves. The footprint (the process's own task_info) every 5 s, then how long main takes to catch up once the
/// modal ends: `RESULT team-churn modal-…` lines. `--modal-without boards,churn` leaves that traffic out.
enum TeamChurnBench {
    /// The made-up board: as big as the real ones (vibeswitcher's 3.3 MB, 200-odd tasks), most of it merged.
    static func board(seed: Int) -> LeadBoard {
        var board = UIBench.board(tasks: 220, seed: seed)
        let words = ["the", "worker", "ran", "the", "suite", "twice", "on", "a", "scratch", "home", "and", "every", "check",
                     "passed;", "the", "verifier", "read", "the", "diff", "line", "by", "line", "before", "the", "merge."]
        func prose(_ count: Int, _ salt: Int) -> String {
            (0..<count).map { words[($0 * 11 + salt * 5) % words.count] }.joined(separator: " ")
        }
        let active: [LeadTask.Status] = [.running, .review, .planned, .failed, .blocked]
        for index in board.tasks.indices {
            board.tasks[index].report = prose(420, index)
            board.tasks[index].checkpoints = (board.tasks[index].checkpoints ?? []) + (0..<10).map {
                LeadCheckpoint(text: prose(45, index + $0), at: board.tasks[index].createdAt + 300 + Double($0) * 30)
            }
            // The newest 20 at work or waiting, the rest merged.
            let status = index < 200 ? LeadTask.Status.done : active[index % active.count]
            board.tasks[index].status = status
            if status == .done {
                board.tasks[index].evidence = LeadEvidence(completion: .complete, integrity: .clean, summary: prose(80, index), commit: "abc\(index)")
                board.tasks[index].merged = LeadMergeRecord(commit: "def\(index)", tested: true, at: board.tasks[index].createdAt + 500)
            } else {
                board.tasks[index].evidence = nil
                board.tasks[index].merged = nil
            }
        }
        return board
    }

    static func run(arguments: [String]) -> Never {
        let seconds = arguments.prefix { !$0.hasPrefix("--modal") }.lazy.compactMap(Double.init).first ?? 20
        let app = NSApplication.shared
        app.setActivationPolicy(arguments.contains("--onscreen") ? .accessory : .prohibited)
        VibePaths.ensurePrivateDirectories()
        let modal = arguments.firstIndex(of: "--modal").flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil }
        let without = arguments.firstIndex(of: "--modal-without").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let bench = Bench(seconds: seconds, onscreen: arguments.contains("--onscreen"), ax: arguments.contains("--ax"), modal: modal,
                          modalWithout: Set((without ?? "").split(separator: ",").map(String.init)))
        bench.start()
        app.run()
        exit(0)
    }

    /// A lead's conversation, `turns` of it: your prompt, its reply in prose, a command it ran; each line stamped, the
    /// last a minute before `now` (as the project-b lead's 69 items).
    static func transcript(turns: Int, now: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let reply = "The worker reported; I read its evidence and the diff, and the checks pass. Merging it now, then the next "
            + "task starts on its own. **Two** are still at work and one waits on the audit."
        var lines: [[String: Any]] = []
        for turn in 0..<turns {
            lines.append(["type": "user", "isSidechain": false, "uuid": UUID().uuidString,
                          "message": ["role": "user", "content": "Turn \(turn): how is the team doing, and what's next?"]])
            lines.append(["type": "assistant", "isSidechain": false, "uuid": UUID().uuidString,
                          "message": ["role": "assistant", "content": [["type": "text", "text": "\(reply) (\(turn))"]]]])
            lines.append(["type": "assistant", "isSidechain": false, "uuid": UUID().uuidString,
                          "message": ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_\(turn)", "name": "Bash",
                                                                        "input": ["command": "git log --oneline -5", "description": "Look at the base"]]]]])
            lines.append(["type": "user", "isSidechain": false, "uuid": UUID().uuidString,
                          "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_\(turn)", "content": "abc123 Merge task \(turn)"]]]])
        }
        var data = Data()
        for (index, line) in lines.enumerated() {
            var line = line
            line["timestamp"] = formatter.string(from: now.addingTimeInterval(Double(index - lines.count) * 20 - 60))
            data += (try? JSONSerialization.data(withJSONObject: line)) ?? Data()
            data.append(0x0A)
        }
        return data
    }

    /// The main thread's CPU time so far, user and system (`thread` is the main thread's port).
    static func cpu(of thread: thread_act_t) -> TimeInterval {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return TimeInterval(info.user_time.seconds + info.system_time.seconds)
            + TimeInterval(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }

    /// Retitles its session every `period` s while `$HOME/churn-on` is there: an upsert from the host each time.
    static let churnScript = """
    sleep "$3"
    i=0
    while :; do
      if [ -f "$HOME/churn-on" ]; then i=$((i + 1)); printf '\\033]0;%s, step %d\\007' "$1" "$i"; fi
      sleep "$2"
    done
    """

    private final class Bench {
        let seconds: Double
        let onscreen: Bool
        /// An accessibility client walks the window after each upsert (`AXClient`).
        let ax: Bool
        var walked = 0
        /// The main thread's CPU in the client's walks (its requests are served there).
        var walking: TimeInterval = 0
        /// `--modal`'s seconds: that phase alone.
        let modal: Double?
        /// `--modal-without boards,churn`: traffic left out of it, to narrow a growth down.
        let modalWithout: Set<String>
        let started = Date()
        let store: SessionStore
        let host = HostClient(appKey: HostClient.ownKey())
        let model = WindowModel()
        lazy var leads = LeadController(host: host, store: store) { _ in "claude" }
        var window: MainWindowController?
        var cancellables: Set<AnyCancellable> = []
        var watchdog: BoardBench.Watchdog?
        let main = mach_thread_self()
        /// The made-up agent (the lead's), by the tty of the window session it runs in (read on the scanner's queue).
        private let lock = NSLock()
        private var agentTTYs: [String: (pid: Int32, root: String)] = [:]
        /// Upserts from the host: each publishes its sessions.
        var upserts = 0
        let root = (NSHomeDirectory() as NSString).appendingPathComponent("lead-gamma")
        let other = (NSHomeDirectory() as NSString).appendingPathComponent("other-project")
        var transcript = ""
        static let workers = 6, others = 4, period = 2.0
        var leadID: UUID?

        init(seconds: Double, onscreen: Bool, ax: Bool, modal: Double?, modalWithout: Set<String>) {
            self.seconds = seconds
            self.onscreen = onscreen
            self.ax = ax
            self.modal = modal
            self.modalWithout = modalWithout
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

        private var awake: NSObjectProtocol?

        func start() {
            awake = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "--team-churn measures")
            let boards = BoardStore(root: root)
            try? boards.update { $0 = TeamChurnBench.board(seed: 0) }
            try? boards.replaceRecord("decisions.md", with: UIBench.decisions(count: 30, newest: started.addingTimeInterval(-3600)))
            try? FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
            let folder = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects/\(RecentProjects.claudeSlug(for: root))")
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            transcript = (folder as NSString).appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl")
            FileManager.default.createFile(atPath: transcript, contents: TeamChurnBench.transcript(turns: ax ? 75 : 23, now: started))
            try? TeamChurnBench.churnScript.write(toFile: (NSHomeDirectory() as NSString).appendingPathComponent("churn.sh"),
                                                 atomically: true, encoding: .utf8)
            // Wired as the app delegate wires them.
            host.$sessions.receiveLatest(on: RunLoop.main).sink { [weak self] in self?.store.updateHosted($0) }.store(in: &cancellables)
            host.$sessions.dropFirst().sink { [weak self] _ in
                self?.upserts += 1
                // The client reads the window again once the change is drawn, as a client told of it does.
                guard let self, self.ax, let window = self.window?.window else { return }
                DispatchQueue.main.async {
                    let before = TeamChurnBench.cpu(of: self.main)
                    self.walked = AXClient.walk(window)
                    self.walking += TeamChurnBench.cpu(of: self.main) - before
                }
            }.store(in: &cancellables)
            store.$sessions.combineLatest(host.$sessions, host.$state, store.$tableRead).receiveLatest(on: RunLoop.main)
                .sink { [weak self] sessions, hosted, state, table in
                    self?.model.update(sessions: sessions, hosted: hosted, table: table, hostAnswered: state != .connecting)
                }
                .store(in: &cancellables)
            store.hostScreens = { [weak self] in self?.host.screens ?? [:] }
            store.requestHostScreens = { [weak self] in self?.host.refreshScreens(ttys: $0) }
            UserDefaults.standard.set("team", forKey: "inspectorTab")
            // No headless Claude from a bench.
            leads.summaries.enabled = false
            store.start()
            spawnLead()
        }

        private func spawn(_ request: SpawnRequest, then done: @escaping (HostSession) -> Void) {
            host.spawn(request) { result in
                switch result {
                case .success(let session): done(session)
                case .failure(let error): self.finish("couldn't start a session: \(error.message)")
                }
            }
        }

        private func spawnLead() {
            spawn(SpawnRequest(cwd: root, command: "exec /bin/cat", env: [:], cols: 120, rows: 40, keepShell: false,
                               label: "Lead · lead-gamma", agent: "claude")) { session in
                self.leadID = session.id
                var state = HookState(agent: .claude, tty: session.tty, lastEvent: "Stop", lastEventAt: Date().timeIntervalSince1970 - 600)
                state.agentPid = 60_101
                state.sessionId = UUID().uuidString
                state.cwd = self.root
                state.firstPrompt = "Lead the work in lead-gamma"
                state.lastMessage = "Waiting for reports."
                state.transcriptPath = self.transcript
                try? state.save(to: VibePaths.stateFile(tty: session.tty))
                self.lock.lock()
                self.agentTTYs[session.tty] = (60_101, self.root)
                self.lock.unlock()
                self.spawnTeam(0, ids: [])
            }
        }

        /// The workers (in their worktrees, named by the board) and the other project's sessions, each retitling itself.
        private func spawnTeam(_ index: Int, ids: [String]) {
            guard index < Self.workers + Self.others else { return teamStarted(ids) }
            let board = BoardStore(root: root).load()
            let worker = index < Self.workers
            let task = board.tasks.filter { $0.status == .running || $0.status == .review }[index % Self.workers]
            let cwd = worker ? (root as NSString).appendingPathComponent(".vibeswitcher/worktrees/\(task.id)") : other
            try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
            let name = worker ? "Worker: \(task.title)" : "Claude"
            let offset = String(format: "%.2f", Self.period * Double(index) / Double(Self.workers + Self.others))
            spawn(SpawnRequest(cwd: cwd, command: "/bin/sh \(NSHomeDirectory())/churn.sh 'session \(index)' \(Self.period) \(offset)", env: [:],
                               cols: 120, rows: 40, keepShell: false, label: name, agent: "claude")) { session in
                self.spawnTeam(index + 1, ids: ids + (worker ? [session.id.uuidString] : []))
            }
        }

        private func teamStarted(_ ids: [String]) {
            try? BoardStore(root: root).update { board in
                let working = board.tasks.indices.filter { [.running, .review].contains(board.tasks[$0].status) }
                for (index, id) in ids.enumerated() {
                    let task = working[index % working.count]
                    if board.tasks[task].status == .review { board.tasks[task].verifier = id } else { board.tasks[task].worker = id }
                }
            }
            store.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.openWindow() }
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
            if onscreen { controller.presentWithoutFocus() } else { controller.presentOffscreen() }
            if let leadID { model.select(hostID: leadID) }
            model.showsChat = true
            let file = (BoardStore(root: root).folder as NSString).appendingPathComponent("board.json")
            let size = ((try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int) ?? 0
            print(String(format: "team churn: a lead's chat and its Team tab, a board of %.1f MB (%d tasks), %d workers and %d other sessions "
                         + "retitling every %.0f s; window %@; %.0f s a phase", Double(size) / 1_048_576, 220, Self.workers, Self.others,
                         Self.period, onscreen ? "on screen" : "off screen", seconds))
            fflush(stdout)
            wait(until: { [self] in
                model.selectedRow.flatMap(leads.lead(for:)) != nil && leads.boards[root]?.tasks.count == 220
            }, then: {
                // Everything drawn once and settled before anything is measured.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    print("selected \(self.model.selectedRow?.project ?? "none"), its Team tab \(self.model.selectedRow.flatMap(self.leads.lead(for:)) != nil ? "shown" : "missing")")
                    print(self.window?.debugState() ?? "")
                    if self.ax, let window = self.window?.window {
                        let hosts = AXClient.attach(window)
                        self.walked = AXClient.walk(window)
                        print("accessibility client attached: \(hosts) hosting views, \(self.walked) elements")
                    }
                    // From the run loop as an event's handler is (End Session…'s alert ran from a menu's action), not
                    // from a block of the main queue: inside one the main queue would wait for it, as it never did there.
                    if let modal = self.modal { return RunLoop.main.perform(inModes: [.default]) { self.modalPhase(modal) } }
                    self.watchdog = BoardBench.Watchdog()
                    self.quiet()
                }
            }, else: "the lead's Team tab never showed")
        }

        /// One phase: `seconds` of it, the main thread's CPU over it, its longest block and the upserts seen.
        private func measure(_ name: String, then done: @escaping (_ cpu: TimeInterval, _ upserts: Int, _ block: (cpu: TimeInterval, wall: TimeInterval)) -> Void) {
            _ = watchdog?.take()
            let cpu = TeamChurnBench.cpu(of: main)
            let upserts = upserts
            let walking = walking
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
                let used = TeamChurnBench.cpu(of: main) - cpu
                let block: (cpu: TimeInterval, wall: TimeInterval) = watchdog?.take() ?? (cpu: 0, wall: 0)
                print(String(format: "  %@: main thread %.0f ms of CPU in %.0f s, %d upserts, longest block %.0f ms (wall %.0f ms)%@",
                             name as NSString, used * 1000, seconds, self.upserts - upserts, block.cpu * 1000, block.wall * 1000,
                             (ax ? String(format: ", %d accessibility elements, %.0f ms of it the client's walks", walked,
                                          (self.walking - walking) * 1000) : "") as NSString))
                fflush(stdout)
                done(used, self.upserts - upserts, block)
            }
        }

        var floor: TimeInterval = 0
        var worst: (cpu: TimeInterval, wall: TimeInterval) = (0, 0)

        private func keep(_ block: (cpu: TimeInterval, wall: TimeInterval)) {
            worst = (max(worst.cpu, block.cpu), max(worst.wall, block.wall))
        }

        private func quiet() {
            print("quiet: nothing changes")
            measure("quiet") { [self] cpu, _, block in
                floor = cpu / seconds
                keep(block)
                print(String(format: "RESULT team-churn quiet-ms-per-second %.2f", floor * 1000))
                slowTicks(4, costs: [])
            }
        }

        /// The Team tab's timeline as it ticks with no decision fading, every 10 s on the clock (with the sidebar's,
        /// every 30 s): the main thread's CPU from 0.3 s before each tick to 0.7 s after, over the quiet floor.
        private func slowTicks(_ count: Int, costs: [TimeInterval]) {
            if costs.isEmpty { print("slow ticks: no decision fading, the Team tab's timeline ticking every 10 s"); fflush(stdout) }
            guard count > 0 else {
                let each = costs.reduce(0, +) / Double(costs.count)
                print(String(format: "RESULT team-churn slow-tick-ms %.2f (over the quiet floor; %@)", each * 1000,
                             costs.map { String(format: "%.1f", $0 * 1000) }.joined(separator: ", ") as NSString))
                return ticks()
            }
            let now = Date().timeIntervalSince1970
            var tick = (now / 10).rounded(.up) * 10
            if tick - now < 0.5 { tick += 10 }
            DispatchQueue.main.asyncAfter(deadline: .now() + (tick - now - 0.3)) { [self] in
                _ = watchdog?.take()
                let before = TeamChurnBench.cpu(of: main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                    let used = TeamChurnBench.cpu(of: main) - before
                    keep(watchdog?.take() ?? (cpu: 0, wall: 0))
                    slowTicks(count - 1, costs: costs + [max(0, used - floor)])
                }
            }
        }

        /// A decision fading: the Team tab's timeline ticks every second.
        private func ticks() {
            print("ticks: a decision fading, the Team tab's timeline ticking every second")
            fflush(stdout)
            // The newest decision began fading 5 s ago: it fades for a minute.
            try? BoardStore(root: root).replaceRecord("decisions.md", with: UIBench.decisions(count: 30, newest: Date().addingTimeInterval(-DecisionFeed.shown - 5)))
            let newest = Date().addingTimeInterval(-DecisionFeed.shown - 5).timeIntervalSince1970
            wait(until: { [self] in (leads.decisions[root]?.map(\.at).max() ?? 0) > newest - 2 }, then: { [self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                    measure("ticks") { [self] cpu, _, block in
                        keep(block)
                        print(String(format: "RESULT team-churn tick-ms %.2f (%.2f over the quiet floor)", cpu / seconds * 1000,
                                     max(0, cpu / seconds - floor) * 1000))
                        try? BoardStore(root: root).replaceRecord("decisions.md", with: UIBench.decisions(count: 30, newest: Date().addingTimeInterval(-3600)))
                        wait(until: { [self] in (leads.decisions[root]?.map(\.at).max() ?? .infinity) < newest - 1000 }, then: {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.churn() }
                        }, else: "the old decisions never came back")
                    }
                }
            }, else: "the fading decision never showed")
        }

        /// The sessions retitling themselves: an upsert from the host each time.
        private func churn() {
            print(String(format: "churn: %d sessions retitling every %.0f s", Self.workers + Self.others, Self.period))
            fflush(stdout)
            let flag = (NSHomeDirectory() as NSString).appendingPathComponent("churn-on")
            FileManager.default.createFile(atPath: flag, contents: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.period + 1) { [self] in
                measure("churn") { [self] cpu, upserts, block in
                    try? FileManager.default.removeItem(atPath: flag)
                    keep(block)
                    let each = upserts > 0 ? max(0, cpu - floor * seconds) / Double(upserts) : 0
                    print(String(format: "RESULT team-churn upsert-ms %.2f (%d upserts, %.1f a second)", each * 1000, upserts, Double(upserts) / seconds))
                    print(String(format: "RESULT team-churn worst-block-ms %.0f (wall %.0f)", worst.cpu * 1000, worst.wall * 1000))
                    finish(nil)
                }
            }
        }

        /// A modal session for `duration` s (as `NSAlert.runModal`'s, on a panel off screen), the board written every
        /// second from another thread and the sessions retitling; the footprint and malloc's blocks in use every 5 s,
        /// what grew by class over the modal, then main's catching up, timed.
        private func modalPhase(_ duration: Double) {
            let flag = (NSHomeDirectory() as NSString).appendingPathComponent("churn-on")
            if !modalWithout.contains("churn") { FileManager.default.createFile(atPath: flag, contents: nil) }
            let writes = !modalWithout.contains("boards")
            let upserts = upserts
            var publishes = 0, listed = 0
            store.$sessions.dropFirst().sink { _ in listed += 1 }.store(in: &cancellables)
            leads.$boards.dropFirst().sink { _ in publishes += 1 }.store(in: &cancellables)
            let footprint = { (UIBench.memoryKinds()["footprint"] ?? 0) / 1_048_576 }
            let before = footprint()
            print(String(format: "modal: the main run loop modal for %.0f s, the board written every second, %d sessions retitling; footprint %.0f MB",
                         duration, Self.workers + Self.others, before))
            fflush(stdout)
            let done = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var peak = before
            /// Malloc's blocks in use (MB) by seconds into the modal.
            var samples: [(at: Double, inUse: Double)] = []
            let root = root
            let census = HeapCensus.take()
            Thread.detachNewThread {
                var round = 0
                let began = Date()
                while done.wait(timeout: .now() + 1) == .timedOut {
                    round += 1
                    // A pool a write: this thread's own would keep what each autoreleased until the thread ends.
                    if writes { autoreleasepool { try? BoardStore(root: root).update { board in
                        let index = round % board.tasks.count
                        board.tasks[index].checkpoints = (board.tasks[index].checkpoints ?? [])
                            + [LeadCheckpoint(text: "checkpoint \(round): read the diff and ran the suite again")]
                    } } }
                    guard round % 5 == 0 else { continue }
                    let kinds = UIBench.memoryKinds()
                    let now = (kinds["footprint"] ?? 0) / 1_048_576
                    let inUse = kinds.filter { $0.key.hasSuffix(" in use") }.values.reduce(0, +) / 1_048_576
                    let at = Date().timeIntervalSince(began)
                    lock.lock()
                    peak = max(peak, now)
                    samples.append((at, inUse))
                    lock.unlock()
                    print(String(format: "  %3.0f s: footprint %.0f MB, malloc's blocks in use %.0f MB", at, now, inUse))
                    fflush(stdout)
                }
            }
            // A modal session on a panel off screen, as `NSAlert.runModal` runs one (its events, its autorelease pools),
            // stopped by a timer of the modal mode's.
            let panel = NSPanel(contentRect: NSRect(x: -12_000, y: -12_000, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
            let stop = Timer(timeInterval: duration, repeats: false) { _ in NSApp.stopModal() }
            RunLoop.main.add(stop, forMode: .modalPanel)
            let began = Date()
            _ = NSApp.runModal(for: panel)
            panel.orderOut(nil)
            print(String(format: "  the modal ran %.0f s", Date().timeIntervalSince(began)))
            done.signal()
            let grown = HeapCensus.take()
            print("  grew in the modal, by class (malloc blocks), then blocks of no class by size:")
            var classed = census, unclassed = census, after = grown, afterRaw = grown
            classed.unclassed = [:]; after.unclassed = [:]; unclassed.classes = [:]; afterRaw.classes = [:]
            for row in HeapCensus.growth(from: classed, to: after, top: 15) + HeapCensus.growth(from: unclassed, to: afterRaw, top: 5) {
                print(String(format: "    %-60@ %+8.2f MB %+8ld blocks", String(row.name.prefix(60)) as NSString,
                             Double(row.after.bytes - row.before.bytes) / 1_048_576, row.after.blocks - row.before.blocks))
            }
            try? FileManager.default.removeItem(atPath: flag)
            let held = footprint()
            lock.lock()
            peak = max(peak, held)
            // Over the modal's second half: the first's warm-up (fonts, the first boards' rows) left out.
            let half = samples.first { $0.at >= duration / 2 }, last = samples.last
            lock.unlock()
            let slope = half.flatMap { half in last.map { ($0.inUse - half.inUse) / max(1, $0.at - half.at) * 60 } } ?? 0
            // What waited for the default mode runs once main is back in it: its longest block then.
            let watchdog = BoardBench.Watchdog()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                let block = watchdog.take()
                watchdog.stop()
                let after = footprint()
                print(String(format: "RESULT team-churn modal-footprint-mb %.0f %.0f %.0f %.0f (before, at the modal's end, peak, 3 s after)",
                             before, held, peak, after))
                print(String(format: "RESULT team-churn modal-growth-mb-per-minute %.1f (malloc's blocks in use over the modal's second half; "
                             + "%d boards published, %d host upserts, %d session lists)", slope, publishes, self.upserts - upserts, listed))
                print(String(format: "RESULT team-churn modal-catch-up-ms %.0f (main's longest block after the modal; wall %.0f)",
                             block.cpu * 1000, block.wall * 1000))
                finish(nil)
            }
        }

        private func wait(until condition: @escaping () -> Bool, then: @escaping () -> Void, else failure: String, tries: Int = 1500) {
            if condition() { return then() }
            guard tries > 0 else { return finish(failure) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self.wait(until: condition, then: then, else: failure, tries: tries - 1) }
        }

        private func finish(_ failure: String?) {
            watchdog?.stop()
            if let failure { print("FAIL  \(failure)") }
            // The private host runs from this build's folder, under the scratch home: it ends, sessions and all, as this
            // process exits (`HostClient.endsWithThisProcess`).
            print(failure == nil ? "team churn: done" : "team churn: failed")
            fflush(stdout)
            exit(failure == nil ? 0 : 1)
        }
    }
}

/// An accessibility client, for benches and tests: what a window manager or a screen tool attached to the app does. The
/// process running it isn't trusted to be a real one (`AXIsProcessTrusted`), so it asks AppKit's entry point for a
/// client's request in process, after turning on SwiftUI's accessibility as a client's first request does.
enum AXClient {
    private typealias EntryPoint = @convention(c) (AnyObject, NSString) -> Unmanaged<AnyObject>?
    /// AppKit's entry point for a client's request (the hang stacks' `_NSAccessibilityEntryPointValueForAttribute`).
    private static let entryPoint: EntryPoint? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "NSAccessibilityEntryPointValueForAttribute")
        .map { unsafeBitCast($0, to: EntryPoint.self) }

    /// Turns on SwiftUI's accessibility in every hosting view of the window (`NSHostingView.accessibilityEnabled`'s
    /// setter, called with the view as its self: a closure's context goes where a method's self does). How many.
    @discardableResult
    static func attach(_ window: NSWindow) -> Int {
        guard let setter = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s7SwiftUI13NSHostingViewC20accessibilityEnabledSbvsTj"),
              let content = window.contentView else { return 0 }
        func hosts(_ view: NSView) -> [NSView] {
            (String(describing: type(of: view)).hasPrefix("NSHostingView<") ? [view] : []) + view.subviews.flatMap(hosts)
        }
        let found = hosts(content)
        for host in found {
            let enable = unsafeBitCast((setter, Unmanaged.passRetained(host).toOpaque()), to: ((Bool) -> Void).self)
            enable(true)
        }
        return found.count
    }

    /// Walks the element's tree as a client reads it (each element's role and children); the elements reached.
    static func walk(_ element: AnyObject) -> Int {
        guard let entryPoint else { return 0 }
        _ = entryPoint(element, "AXRole")
        let children = entryPoint(element, "AXChildren")?.takeUnretainedValue() as? [AnyObject] ?? []
        return 1 + children.reduce(0) { $0 + walk($1) }
    }

    /// What every element of the tree says (its value, title, description and label), as a client reads it.
    static func texts(_ element: AnyObject) -> [String] {
        guard let entryPoint else { return [] }
        let own = ["AXValue", "AXTitle", "AXDescription", "AXLabel"].compactMap { attribute -> String? in
            let value = entryPoint(element, attribute as NSString)?.takeUnretainedValue()
            return (value as? String) ?? (value as? NSAttributedString)?.string
        }
        let children = entryPoint(element, "AXChildren")?.takeUnretainedValue() as? [AnyObject] ?? []
        return own + children.flatMap(texts)
    }
}
