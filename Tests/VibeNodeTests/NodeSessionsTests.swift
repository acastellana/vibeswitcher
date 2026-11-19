import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The node's one session list (`NodeSessions`, the engine plan's E3): the app's `SessionStoreTests` cases that aren't
/// about Terminal.app, Spaces, presence or the ledger, and `AgentQuitTests`' case, their assertions kept (the port map's
/// test table says how each is restated: on the store's list and change stream instead of a published array, on
/// `agentQuit` instead of the window's rows), then the node's own: the join by terminal, the state folder's watch, the
/// quiet Claude sessions' screens, the details, the hooks. What a case reads of the store it reads on the store's queue
/// (`on`), where the engine reads it.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(10)))
struct NodeSessionsTests {
    private let scratch = Scratch()

    /// `body` on the store's queue, where its state is read.
    private func on<T>(_ nodes: NodeSessions, _ body: () throws -> T) rethrows -> T { try nodes.queue.sync(execute: body) }

    /// A node's root of the test's own (`<folder>/home/.vibeswitcher`), its state folder made, and that home.
    private func node() throws -> (root: URL, home: URL) {
        let home = scratch.url("node-sessions").appendingPathComponent("home", isDirectory: true)
        let root = home.appendingPathComponent(".vibeswitcher", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state"), withIntermediateDirectories: true)
        return (root, home)
    }

    /// The fixture of the app's store tests: a working agent (ttypts970, running `npm test`) and one whose turn is over
    /// with a background shell still running (ttypts971, `npm run dev`). `readable`: whether the process table can be
    /// read at the time. `now`: the store's time (it moves only when the test says, however long the scans take).
    private func store(started: Date, readable: @escaping @Sendable () -> Bool = { true },
                       now: @escaping @Sendable () -> Date) throws -> (nodes: NodeSessions, state: URL) {
        let (root, home) = try node()
        let state = root.appendingPathComponent("state")
        let real = Date().timeIntervalSince1970
        var working = HookState(agent: .claude, tty: "ttypts970", lastEvent: "PreToolUse", lastEventAt: real - 30)
        working.agentPid = 970
        working.toolName = "Bash"
        working.toolDetail = "npm test"
        working.toolStartedAt = real - 30
        try working.save(to: state.appendingPathComponent("ttypts970.json"))
        var finished = HookState(agent: .claude, tty: "ttypts971", lastEvent: "Stop", lastEventAt: real - 600)
        finished.agentPid = 971
        try finished.save(to: state.appendingPathComponent("ttypts971.json"))
        let launched = started.addingTimeInterval(-3600)
        let procs = [
            ProcInfo(pid: 960, ppid: 1, tty: nil, comm: "vibeswitcher-hos", startTime: launched, agent: nil),
            ProcInfo(pid: 970, ppid: 960, tty: "ttypts970", comm: "claude", startTime: launched, agent: .claude),
            ProcInfo(pid: 971, ppid: 960, tty: "ttypts971", comm: "claude", startTime: launched, agent: .claude),
            ProcInfo(pid: 972, ppid: 971, tty: "ttypts971", comm: "bash", startTime: started.addingTimeInterval(-5), agent: nil),
        ]
        let table = Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
        let scanner = SessionScanner(
            processes: { readable() ? table : nil }, stateDir: { state }, cwd: { _ in "/r/store-tests" },
            arguments: { $0.pid == 972 ? ["/bin/bash", "-c", "source /h/.claude/shell-snapshots/a.sh && eval 'npm run dev' < /dev/null"] : [] })
        let nodes = NodeSessions(root: root, home: home.path, queue: DispatchQueue(label: "engine"), scanner: scanner, now: now)
        return (nodes, state)
    }

    /// Refreshes, and waits for that scan to land: it runs on the store's scan queue and lands back on its queue.
    private func refreshAndSettle(_ nodes: NodeSessions, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let before = on(nodes) { nodes.scansApplied }
        nodes.refresh()
        try #require(await eventually { on(nodes) { nodes.scansApplied > before } }, "the scan never landed", sourceLocation: sourceLocation)
    }

    /// Scans until `condition` holds (a scan already under way may have read what changed before it did); false when
    /// it never does.
    private func scanned(_ nodes: NodeSessions, timeout: TimeInterval = NodeHarness.wait, _ condition: () -> Bool) async throws -> Bool {
        let deadline = MacTime.real.awake() + timeout
        while MacTime.real.awake() < deadline {
            try await refreshAndSettle(nodes)
            if on(nodes, condition) { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return on(nodes, condition)
    }

    private func session(_ nodes: NodeSessions, _ tty: String) -> Session? {
        on(nodes) { nodes.sessions.first { $0.tty == tty } }
    }

    // MARK: SessionStoreTests

    /// Whether a lead's message is steered into an agent or typed (`LeadDelivery.way`) is told from the hook event the
    /// scan read off it, not its state file: its files gone after the scan, the sessions still say which agent works
    /// and which is idle.
    @Test func sessionsCarryTheirHookEventSoSteeringNeedsNoFileRead() async throws {
        let (nodes, state) = try store(started: Date(), now: { Date() })
        try await refreshAndSettle(nodes)
        try FileManager.default.removeItem(at: state)
        let working = try #require(session(nodes, "ttypts970"))
        let finished = try #require(session(nodes, "ttypts971"))
        #expect(working.hookEvent == "PreToolUse")
        #expect(finished.hookEvent == "Stop")
        #expect(LeadDelivery.way(for: working) == .steer)
        #expect(LeadDelivery.way(for: finished) == .type)
    }

    /// The app's `scansThatFindNothingNewDontRepublish`, on the change stream: the first scan sends each session once,
    /// and scans seconds later (the background shell older, the working agent's tool run longer) send nothing.
    @Test func scansThatFindNothingNewSendNoChange() async throws {
        let clock = Locked(Date())
        let (nodes, _) = try store(started: clock.value, now: { clock.value })
        let delivered = DispatchQueue(label: "subscriber")
        let deltas = Locked<[Changes<Session>.Delta]>([])
        let subscription = nodes.changes.subscribe(on: delivered) { batch in deltas.mutate { $0 += batch } }
        defer { subscription.cancel() }
        try await refreshAndSettle(nodes)
        #expect(on(nodes) { nodes.sessions.map(\.status) } == [.working, .background])
        #expect(session(nodes, "ttypts971")?.detail == "Waiting on npm run dev · <1m")
        // What the scan sent is on the subscriber's queue by now.
        delivered.sync {}
        #expect(deltas.value.map(\.id).sorted() == [NodeIds.session(terminal: "ttypts970"), NodeIds.session(terminal: "ttypts971")])
        for _ in 0..<3 {
            clock.mutate { $0 += 2 }
            try await refreshAndSettle(nodes)
        }
        delivered.sync {}
        #expect(deltas.value.count == 2)
    }

    /// Whether a quiet worker still has a shell running is answered by the scan (off the engine queue), so each session
    /// carries its background shells: the witness reads them there instead of the process table.
    @Test func sessionsCarryTheirBackgroundShells() async throws {
        let (nodes, _) = try store(started: Date(), now: { Date() })
        try await refreshAndSettle(nodes)
        #expect(session(nodes, "ttypts971")?.backgroundJobs.map(\.command) == ["npm run dev"])
        #expect(session(nodes, "ttypts970")?.backgroundJobs == [])
    }

    /// A scan whose process table couldn't be read keeps the sessions found before, and the time that table was read:
    /// the witness tells a session's agent as quit only from a table read since.
    @Test func anUnreadTableKeepsTheTimeOfTheLastOneRead() async throws {
        let clock = Locked(Date())
        let read = clock.value
        let readable = Locked(true)
        let (nodes, _) = try store(started: read, readable: { readable.value }, now: { clock.value })
        #expect(on(nodes) { nodes.tableRead.at } == nil)
        try await refreshAndSettle(nodes)
        #expect(on(nodes) { nodes.tableRead.at } == read)
        readable.value = false
        clock.mutate { $0 += 120 }
        try await refreshAndSettle(nodes)
        #expect(on(nodes) { nodes.tableRead.at } == read)
        #expect(Set(on(nodes) { nodes.sessions.map(\.tty) }) == ["ttypts970", "ttypts971"])
        readable.value = true
        try await refreshAndSettle(nodes)
        #expect(on(nodes) { nodes.tableRead.at } == read + 120)
    }

    /// The app's `rowsTellAnAgentQuitOnlyFromATableReadAMinuteAfterItStarted`, on `agentQuit` instead of a row: a hosted
    /// session's agent is quit only by a table read a minute after the session started. Never read, or read before it
    /// started (the table unreadable since): not quit (the row's "unknown", live). And a session whose agent the scan
    /// has is never quit.
    @Test func anAgentQuitIsToldOnlyFromATableReadAMinuteAfterItStarted() async throws {
        let clock = Locked(Date())
        let read = clock.value
        let readable = Locked(true)
        let (nodes, _) = try store(started: read, readable: { readable.value }, now: { clock.value })
        // A worker's hosted session whose agent the store's table doesn't show, started just after the first read.
        let worker = HostSession(id: UUID(), tty: "ttypts980", childPID: 980, cwd: "/r/acme/.vibeswitcher/worktrees/k", command: nil,
                                 label: "Worker: K", agent: "claude", title: "", startedAt: read + 10, cols: 80, rows: 24, exit: nil)
        // The working agent's own hosted session, started an hour before.
        let busy = HostSession(id: UUID(), tty: "ttypts970", childPID: 970, cwd: "/r/store-tests", command: "claude",
                               label: "w", agent: "claude", title: "", startedAt: read - 3600, cols: 80, rows: 24, exit: nil)
        let later = read + 600

        #expect(on(nodes) { nodes.tableRead.at } == nil)
        #expect(!on(nodes) { nodes.agentQuit(worker) })

        try await refreshAndSettle(nodes)
        readable.value = false
        clock.mutate { $0 += 600 }
        try await refreshAndSettle(nodes)
        #expect(on(nodes) { nodes.tableRead.at } == read)
        #expect(!on(nodes) { nodes.agentQuit(worker) })

        readable.value = true
        try await refreshAndSettle(nodes)
        #expect(on(nodes) { nodes.tableRead.at } == later)
        #expect(on(nodes) { nodes.agentQuit(worker) })
        #expect(!on(nodes) { nodes.agentQuit(busy) })
    }

    /// An agent is told quit only from a table read that could tell what runs on its terminal: while its process there
    /// can't be told (mid-exec on a busy machine), it's unknown, not quit.
    @Test func anAgentQuitNeedsATableThatToldItsTerminal() async throws {
        let (root, home) = try node()
        let clock = Locked(Date())
        let started = clock.value
        let readable = Locked(true)
        let shell = ProcInfo(pid: 980, ppid: 1, tty: "ttypts980", comm: "bash", startTime: started, agent: nil)
        let midExec = ProcInfo(pid: 981, ppid: 980, tty: "ttypts980", comm: "2.1.302", startTime: started, agent: nil, identityUnknown: true)
        let state = root.appendingPathComponent("state")
        let nodes = NodeSessions(root: root, home: home.path, queue: DispatchQueue(label: "engine"), scanner: SessionScanner(
            processes: { [980: shell].merging(readable.value ? [:] : [981: midExec]) { a, _ in a } }, stateDir: { state },
            cwd: { _ in "/r/store-tests" }, arguments: { _ in [] }), now: { clock.value })
        let window = HostSession(id: UUID(), tty: "ttypts980", childPID: 980, cwd: "/r/store-tests", command: "claude", label: "w",
                                 agent: "claude", title: "w", startedAt: started, cols: 80, rows: 24, exit: nil)
        #expect(!on(nodes) { nodes.agentQuit(window) })
        readable.value = false
        clock.mutate { $0 += 120 }
        try await refreshAndSettle(nodes)
        #expect(on(nodes) { nodes.tableRead.undecided.contains("ttypts980") })
        #expect(!on(nodes) { nodes.agentQuit(window) })
        // Only that terminal is in question.
        var elsewhere = window
        elsewhere.tty = "ttypts981"
        #expect(on(nodes) { nodes.agentQuit(elsewhere) })
        readable.value = true
        try await refreshAndSettle(nodes)
        #expect(on(nodes) { nodes.tableRead.undecided } == Undecided())
        #expect(on(nodes) { nodes.agentQuit(window) })
    }

    /// The app's `workersAndVerifiersArentCountedAsYourSessions`: a lead's workers and verifiers are the lead's team,
    /// not your sessions. With a lead, three workers, a verifier and two sessions of your own (one the host doesn't
    /// run), three are yours and the four others its team, each hosted one joined to the host's session by its
    /// terminal. A worker finishing its turn is done and one asking is waiting (who is told is a notification's, stage
    /// 5, and isn't ported).
    @Test func workersAndVerifiersAreTheirLeadsNotYours() async throws {
        let (root, home) = try node()
        let state = root.appendingPathComponent("state")
        let started = Date().addingTimeInterval(-3600)
        let worktrees = "/r/acme/.vibeswitcher/worktrees"
        // tty, label (nil: not the host's), cwd
        let sessions: [(String, String?, String)] = [
            ("ttypts990", "Lead · acme", "/r/acme"), ("ttypts991", "Worker: A", "\(worktrees)/a"),
            ("ttypts992", "Worker: B", "\(worktrees)/b"), ("ttypts993", "Worker: C", "\(worktrees)/c"),
            ("ttypts994", "Verifier: A", "\(worktrees)/a"), ("ttypts995", nil, "/r/notes"), ("ttypts996", "w", "/r/site"),
        ]
        var procs = [Int32(960): ProcInfo(pid: 960, ppid: 1, tty: nil, comm: "vibeswitcher-hos", startTime: started, agent: nil)]
        var cwds: [Int32: String] = [:]
        for (tty, _, cwd) in sessions {
            let pid = Int32(tty.dropFirst(6))!
            procs[pid] = ProcInfo(pid: pid, ppid: 960, tty: tty, comm: "claude", startTime: started, agent: .claude)
            cwds[pid] = cwd
        }
        let hosted = sessions.compactMap { tty, label, cwd in
            label.map { HostSession(id: UUID(), tty: tty, childPID: Int32(tty.dropFirst(6))!, cwd: cwd, command: "claude", label: $0,
                                    agent: "claude", title: "", startedAt: started, cols: 80, rows: 24, exit: nil) }
        }
        let stub = try StubHost(scratch, sessions: hosted)
        defer { stub.quit() }
        let link = HostLink(dialer: stub.dialer, root: scratch.url("link-root"), queue: DispatchQueue(label: "engine"), sweep: { _ in })
        link.start()
        try #require(await eventually { link.queue.sync { link.state == .connected } })
        let clock = Locked(Date())
        let table = procs, fixed = cwds
        let nodes = NodeSessions(root: root, home: home.path, queue: link.queue, link: link,
                                 scanner: SessionScanner(processes: { table }, stateDir: { state }, cwd: { fixed[$0] }, arguments: { _ in [] }),
                                 now: { clock.value })
        nodes.start()
        defer { nodes.stop() }
        func hook(_ tty: String, _ event: String) throws {
            var hook = HookState(agent: .claude, tty: tty, lastEvent: event, lastEventAt: clock.value.timeIntervalSince1970)
            hook.agentPid = Int32(tty.dropFirst(6))!
            try hook.save(to: state.appendingPathComponent("\(tty).json"))
        }
        for (tty, _, _) in sessions { try hook(tty, "PreToolUse") }
        func status(_ tty: String) -> SessionStatus? { nodes.sessions.first { $0.tty == tty }?.status }
        #expect(try await scanned(nodes) { nodes.sessions.count == 7 && nodes.sessions.allSatisfy { $0.status == .working } })
        #expect(session(nodes, "ttypts990")?.teamRole == .lead)
        #expect(session(nodes, "ttypts994")?.teamRole == .verifier)
        #expect(session(nodes, "ttypts995")?.teamRole == nil)
        let lead = try #require(hosted.first)
        #expect(session(nodes, "ttypts990")?.hostID == lead.id)
        #expect(session(nodes, "ttypts995")?.hostID == nil)
        // Keyed by the node's ids: a hosted session by its host id, the other by its terminal.
        #expect(nodes.changes.values[NodeIds.session(host: lead.id)]?.tty == "ttypts990")
        #expect(nodes.changes.values[NodeIds.session(terminal: "ttypts995")]?.tty == "ttypts995")
        let split = SessionTeams.split(on(nodes) { nodes.sessions })
        #expect(Set(split.own.map(\.tty)) == ["ttypts990", "ttypts995", "ttypts996"])
        #expect(split.teams.map(\.project) == ["acme"])
        #expect(Set(split.teams.flatMap(\.members).map(\.tty)) == ["ttypts991", "ttypts992", "ttypts993", "ttypts994"])
        #expect(split.listed.map(\.tty) == split.own.map(\.tty) + split.teams.flatMap(\.members).map(\.tty))

        // A worker finishes its turn, another asks something.
        clock.mutate { $0 += 5 }
        try hook("ttypts991", "Stop")
        try hook("ttypts992", "PermissionRequest")
        #expect(try await scanned(nodes) { status("ttypts991") == .done && status("ttypts992") == .needsInput })
        #expect(session(nodes, "ttypts992")?.waitsOnLead == true)
    }

    /// One finished session (ttypts975, its turn over at `endedAt`) on a store of its own, and its hooks' state file.
    private func finishedStore(endedAt: Date, now: @escaping @Sendable () -> Date = { Date() }) throws -> (nodes: NodeSessions, state: URL, hook: HookState) {
        let (root, home) = try node()
        let state = root.appendingPathComponent("state")
        let started = endedAt.addingTimeInterval(-3600)
        var hook = HookState(agent: .claude, tty: "ttypts975", lastEvent: "Stop", lastEventAt: endedAt.timeIntervalSince1970)
        hook.agentPid = 975
        hook.lastMessage = "All done."
        try hook.save(to: state.appendingPathComponent("ttypts975.json"))
        let table = [Int32(975): ProcInfo(pid: 975, ppid: 1, tty: "ttypts975", comm: "claude", startTime: started, agent: .claude)]
        let nodes = NodeSessions(root: root, home: home.path, queue: DispatchQueue(label: "engine"),
                                 scanner: SessionScanner(processes: { table }, stateDir: { state }, cwd: { _ in "/r/x" }, arguments: { _ in [] }),
                                 now: now)
        return (nodes, state, hook)
    }

    /// The app's rule: a turn that ended before the store started counts as seen, `idle`, not `done`, its detail and
    /// since kept.
    @Test func aSessionDoneBeforeTheNodeStartedCountsAsSeen() async throws {
        let (nodes, _, hook) = try finishedStore(endedAt: Date().addingTimeInterval(-3600))
        nodes.start()
        defer { nodes.stop() }
        try await refreshAndSettle(nodes)
        #expect(session(nodes, "ttypts975")?.status == .idle)
        #expect(session(nodes, "ttypts975")?.detail == "All done.")
        #expect(session(nodes, "ttypts975")?.statusSince == Date(timeIntervalSince1970: hook.lastEventAt))
    }

    /// The app's `acknowledge`: a turn that ended while the node ran is `done` until someone looks (`seen`), then
    /// `idle` at once (on the change stream, before the next scan) and at every scan; the next turn's end is `done`
    /// again. An id the store doesn't have is said so.
    @Test func aFinishedSessionLookedAtCountsAsSeen() async throws {
        let clock = Locked(Date())
        let (nodes, state, _) = try finishedStore(endedAt: clock.value.addingTimeInterval(60), now: { clock.value })
        nodes.start()
        defer { nodes.stop() }
        try await refreshAndSettle(nodes)
        let found = try #require(session(nodes, "ttypts975"))
        #expect(found.status == .done)
        let id = NodeSessions.id(of: found)
        let sent = Locked<[Session?]>([])
        let subscription = nodes.changes.subscribe(on: nodes.queue) { change in sent.mutate { $0.append(contentsOf: change.map(\.value)) } }
        defer { subscription.cancel() }
        clock.value = clock.value.addingTimeInterval(120)
        let answered = Locked<Bool?>(nil)
        nodes.acknowledge(id) { answered.value = $0 }
        #expect(await eventually { answered.value != nil })
        #expect(answered.value == true)
        #expect(session(nodes, "ttypts975")?.status == .idle)
        #expect(await eventually { sent.value.contains { $0?.status == .idle } }, "\(sent.value)")
        try await refreshAndSettle(nodes)
        #expect(session(nodes, "ttypts975")?.status == .idle)
        // The next turn: working, then over after the look: done again.
        var next = HookState(agent: .claude, tty: "ttypts975", lastEvent: "UserPromptSubmit", lastEventAt: clock.value.timeIntervalSince1970)
        next.agentPid = 975
        try next.save(to: state.appendingPathComponent("ttypts975.json"))
        clock.value = clock.value.addingTimeInterval(30)
        #expect(try await scanned(nodes) { nodes.sessions.first { $0.tty == "ttypts975" }?.status == .working })
        next.lastEvent = "Stop"
        next.lastEventAt = clock.value.timeIntervalSince1970
        try next.save(to: state.appendingPathComponent("ttypts975.json"))
        clock.value = clock.value.addingTimeInterval(30)
        #expect(try await scanned(nodes) { nodes.sessions.first { $0.tty == "ttypts975" }?.status == .done })
        let missing = Locked<Bool?>(nil)
        nodes.acknowledge("no-such-session") { missing.value = $0 }
        #expect(await eventually { missing.value != nil })
        #expect(missing.value == false)
    }

    // MARK: AgentQuitTests

    /// The witness's look at the verifier on a task in review, with what the node's scan says of its agent (`quit`):
    /// its events, what auto_advance takes as ended, and auto_advance's ending from `table`.
    private func witness(_ hosted: HostSession, quit: Bool, table: [Int32: ProcInfo], now: Date)
        -> (quit: Bool, events: [String], ended: [String], ending: String?) {
        var task = LeadTask(slug: "audit-me", title: "audit-me", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = .review
        task.worker = "w1"
        task.verifier = hosted.id.uuidString
        var board = LeadBoard()
        board.tasks = [task]
        let seen = [hosted.id.uuidString: LeadWitness.Seen(live: hosted.isLive, status: .background, agentQuit: quit,
                                                           started: hosted.startedAt.timeIntervalSince1970)]
        return (quit, LeadWitness.events(board: board, seen: seen, now: now).map(\.text),
                LeadWitness.endedForAdvance(board: board, seen: seen, now: now),
                LeadWitness.agentQuitEnding(hosted, table: table, now: now))
    }

    /// A table read whole in which `holds` (one read may come back nil on a loaded machine: read again).
    private func table(where holds: ([Int32: ProcInfo]) -> Bool) async throws -> [Int32: ProcInfo] {
        var read: [Int32: ProcInfo]?
        #expect(await eventually(timeout: NodeHarness.wait) {
            read = ProcessTable.trySnapshot()
            return read.map(holds) ?? false
        })
        return try #require(read)
    }

    /// The process table, cut to the processes on `host`'s terminals: the node's scan of the test's sessions, never of
    /// the user's own agents.
    private func scanner(of host: NodeTestHost) -> SessionScanner {
        let state = host.root.appendingPathComponent("state")
        return SessionScanner(processes: {
            guard let table = ProcessTable.trySnapshot(), let ttys = try? Set(host.sessions().map(\.tty)) else { return nil }
            return table.filter { $0.value.tty.map(ttys.contains) == true }
        }, stateDir: { state })
    }

    /// The app's `AgentQuitTests` case, its three setups: a worker's or verifier's agent has quit only once its own
    /// process has exited; one that ended its turn to wait on a background command runs on, whatever its terminal's
    /// foreground is. The fake Claude Code on a scratch host's session, the process table as it is. The node's scan
    /// sees the fake (as Claude, `FakeClaude`'s launcher), so the witness's rule is the store's `agentQuit` (the app's
    /// `TeamReading.agentQuit`: no agent in the scan a minute on) with the agent's process gone from a table read whole.
    @Test(arguments: [(keepShell: true, foreground: false), (keepShell: true, foreground: true), (keepShell: false, foreground: false)])
    func anAgentWaitingOnABackgroundCommandHasNotQuit(_ setup: (keepShell: Bool, foreground: Bool)) async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let h = try await NodeHarness.start(on: host, keepShell: setup.keepShell)
        let agent = try #require(h.agentPid)
        // Its turn ends on a long command it runs in the background (or one that takes the terminal's foreground).
        h.tell(["op": "done", "reply": "I'll finish the audit when it reports."])
        h.tell(["op": "child", "foreground": setup.foreground])
        try await h.waitFor { (h.agent["children"] as? [Int])?.count == 1 }
        let child = try #require((h.agent["children"] as? [Int])?.first.map(Int32.init))
        defer { kill(child, SIGKILL) }
        let hosted = try #require(try host.sessions().first { $0.id == h.session.id })
        // As the witness looks a minute on and more.
        let later = hosted.startedAt.addingTimeInterval(120)
        let nodes = NodeSessions(root: host.root, home: host.home.path, queue: DispatchQueue(label: "engine"), scanner: scanner(of: host),
                                 now: { later })

        let waiting = try await table { $0[child] != nil && $0[agent] != nil }
        #expect(hosted.isLive && hosted.agentRuns(in: waiting))
        #expect(try await scanned(nodes) { nodes.sessions.contains { $0.tty == hosted.tty && $0.pid == agent } })
        let alive = witness(hosted, quit: on(nodes) { nodes.agentQuit(hosted) } && !hosted.agentRuns(in: waiting), table: waiting, now: later)
        #expect(!alive.quit)
        #expect(!alive.events.contains { $0.contains("ended without a verdict") }, "\(alive.events)")
        #expect(alive.ended.isEmpty && alive.ending == nil, "\(alive)")

        // It exits, its child left running: its agent quit (its kept shell open), or its session ended.
        h.tell(["op": "exit"])
        guard setup.keepShell else {
            try await h.waitFor { (try? host.sessions().first { $0.id == h.session.id }?.isLive) == false }
            let ended = try #require(try host.sessions().first { $0.id == h.session.id })
            #expect(try await scanned(nodes) { !nodes.sessions.contains { $0.tty == hosted.tty } })
            #expect(!on(nodes) { nodes.agentQuit(ended) })
            return
        }
        let shell = try #require(try host.sessions().first { $0.id == h.session.id })
        let exited = try await table { table in
            table[agent] == nil && table[child].map { $0.ppid != agent } == true && !table.values.contains { $0.ppid == shell.childPID }
        }
        #expect(shell.isLive && !shell.agentRuns(in: exited))
        #expect(try await scanned(nodes) { nodes.agentQuit(shell) })
        let quit = witness(shell, quit: on(nodes) { nodes.agentQuit(shell) } && !shell.agentRuns(in: exited), table: exited, now: later)
        #expect(quit.quit)
        #expect(quit.events.contains { $0.contains("ended without a verdict (\(LeadWitness.agentQuitEnding))") }, "\(quit.events)")
        #expect(quit.ended == [shell.id.uuidString] && quit.ending == LeadWitness.agentQuitEnding, "\(quit)")
    }

    // MARK: The node's own

    /// A hosted session's `hostID`, `startFolder` and team role come from the host's list, joined by terminal: the fake
    /// Claude Code on a scratch host's session, started as a worker in a worktree, the process table as it is.
    @Test func aHostedSessionIsJoinedByItsTerminal() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let worktree = host.folder.appendingPathComponent("acme/.vibeswitcher/worktrees/k")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let link = HostLink(dialer: host.dialer, root: host.root, queue: DispatchQueue(label: "engine"), sweep: { _ in })
        link.start()
        try #require(await eventually { link.queue.sync { link.state == .connected } })
        let nodes = NodeSessions(root: host.root, home: host.home.path, queue: link.queue, link: link, scanner: scanner(of: host))
        nodes.start()
        defer { nodes.stop() }
        let h = try await NodeHarness.start(on: host, cwd: worktree.path, label: "Worker: K")
        let pid = try #require(h.agentPid)
        #expect(try await scanned(nodes) { nodes.sessions.contains { $0.tty == h.session.tty && $0.hostID != nil } })
        let joined = try #require(session(nodes, h.session.tty))
        #expect(joined.hostID == h.session.id)
        #expect(joined.startFolder == h.session.cwd)
        #expect(joined.teamRole == .worker)
        #expect(joined.pid == pid && joined.agent == .claude)
        #expect(nodes.changes.values[NodeIds.session(host: h.session.id)]?.tty == h.session.tty)
        #expect(nodes.changes.values[NodeIds.session(terminal: h.session.tty)] == nil)
    }

    /// The hook writes each event as a rename in the state folder, which the store watches: with the scan's period
    /// 60 s on a clock the test wakes, a state file written for a session's terminal changes its status (the watch's
    /// scan, coalesced 0.4 s) while the clock never woke; woken at 60 s, its client scans.
    @Test func aHookWriteIsSeenBeforeTheNextScan() async throws {
        let (root, home) = try node()
        let state = root.appendingPathComponent("state")
        let started = Date().addingTimeInterval(-600)
        let table = [Int32(970): ProcInfo(pid: 970, ppid: 1, tty: "ttypts970", comm: "claude", startTime: started, agent: .claude)]
        func hook(_ event: String) throws {
            var hook = HookState(agent: .claude, tty: "ttypts970", lastEvent: event, lastEventAt: Date().timeIntervalSince1970)
            hook.agentPid = 970
            try hook.save(to: state.appendingPathComponent("ttypts970.json"))
        }
        try hook("PreToolUse")
        let queue = DispatchQueue(label: "engine")
        // A clock that arms its wakes and fires one only when the test does.
        let time = Locked<TimeInterval>(0)
        let armed = Locked<(() -> Void)?>(nil)
        let clock = NodeClock(queue: queue, now: { time.value }, schedule: { _, fire in
            armed.value = fire
            return {}
        })
        var timing = NodeSessions.Timing()
        timing.scanEvery = 60
        let nodes = NodeSessions(root: root, home: home.path, queue: queue, clock: clock, timing: timing,
                                 scanner: SessionScanner(processes: { table }, stateDir: { state }, cwd: { _ in "/r/x" }, arguments: { _ in [] }))
        nodes.start()
        defer { nodes.stop() }
        // The start's own scan.
        #expect(await eventually { session(nodes, "ttypts970")?.status == .working })
        let scans = on(nodes) { nodes.scansApplied }
        try hook("PermissionRequest")
        #expect(await eventually { session(nodes, "ttypts970")?.status == .needsInput })
        #expect(on(nodes) { nodes.scansApplied } > scans)
        #expect(clock.wakes == 0)
        #expect(clock.clientCount == 1)
        let watched = on(nodes) { nodes.scansApplied }
        time.value = 60
        let wake = try #require(armed.value)
        queue.async { wake() }
        #expect(await eventually { on(nodes) { nodes.scansApplied } > watched })
        #expect(clock.wakes == 1)
    }

    /// A session starting or ending on the host scans at once (`HostLink.changes`), with no clock and no refresh: the
    /// agent the scan has on its terminal is joined to it, and no longer once it ended.
    @Test func aSessionStartingOrEndingOnTheHostScansAtOnce() async throws {
        let (root, home) = try node()
        let state = root.appendingPathComponent("state")
        let stub = try StubHost(scratch)
        defer { stub.quit() }
        let link = HostLink(dialer: stub.dialer, root: scratch.url("link-root"), queue: DispatchQueue(label: "engine"), sweep: { _ in })
        link.start()
        try #require(await eventually { link.queue.sync { link.state == .connected } })
        let table = [Int32(970): ProcInfo(pid: 970, ppid: 1, tty: "ttypts970", comm: "claude", startTime: Date().addingTimeInterval(-600),
                                          agent: .claude)]
        let nodes = NodeSessions(root: root, home: home.path, queue: link.queue, link: link,
                                 scanner: SessionScanner(processes: { table }, stateDir: { state }, cwd: { _ in "/r/acme" }, arguments: { _ in [] }))
        nodes.start()
        defer { nodes.stop() }
        #expect(await eventually { session(nodes, "ttypts970") != nil })
        #expect(session(nodes, "ttypts970")?.hostID == nil)
        var started = StubHost.session(tty: "ttypts970")
        started.label = "Lead · acme"
        stub.push(.spawned(started))
        #expect(await eventually { session(nodes, "ttypts970")?.hostID == started.id })
        #expect(session(nodes, "ttypts970")?.teamRole == .lead)
        var ended = started
        ended.exit = HostSession.Exit(status: 0, at: Date())
        stub.push(.sessionChanged(ended))
        #expect(await eventually { session(nodes, "ttypts970")?.hostID == nil })
    }

    /// A hook-less session's program reporting a new status (OSC 7501, the host's `sessionChanged`) scans at once, with
    /// no clock and no refresh: its status and detail follow each report.
    @Test func aProgramReportingANewStatusScansAtOnce() async throws {
        let (root, home) = try node()
        let state = root.appendingPathComponent("state")
        var hosted = StubHost.session(tty: "ttypts970")
        hosted.agent = "claude"
        let stub = try StubHost(scratch, sessions: [hosted])
        defer { stub.quit() }
        let link = HostLink(dialer: stub.dialer, root: scratch.url("link-root"), queue: DispatchQueue(label: "engine"), sweep: { _ in })
        link.start()
        try #require(await eventually { link.queue.sync { link.state == .connected } })
        let table = [Int32(970): ProcInfo(pid: 970, ppid: 1, tty: "ttypts970", comm: "claude", startTime: Date().addingTimeInterval(-600),
                                          agent: .claude)]
        let nodes = NodeSessions(root: root, home: home.path, queue: link.queue, link: link,
                                 scanner: SessionScanner(processes: { table }, stateDir: { state }, cwd: { _ in "/r/acme" }, arguments: { _ in [] }))
        nodes.start()
        defer { nodes.stop() }
        #expect(await eventually { session(nodes, "ttypts970")?.hostID == hosted.id })
        #expect(session(nodes, "ttypts970")?.status == .unknown)
        var working = hosted
        working.programStatus = ProgramStatus(state: .working, app: "claude-code", title: "Fixing the login", since: Date())
        stub.push(.sessionChanged(working))
        #expect(await eventually { session(nodes, "ttypts970")?.status == .working })
        #expect(session(nodes, "ttypts970")?.detail == "Fixing the login")
        var blocked = hosted
        blocked.programStatus = ProgramStatus(state: .blocked, kind: "permission", app: "claude-code", message: "Bash(rm -rf build)", since: Date())
        stub.push(.sessionChanged(blocked))
        #expect(await eventually { session(nodes, "ttypts970")?.status == .needsInput })
        #expect(session(nodes, "ttypts970")?.detail == "Asks permission: Bash(rm -rf build)")
    }

    /// A scan asked while one runs follows it (`refresh`'s "after the one under way"), with no clock, no watch and no
    /// refresh more: an agent that started on another terminal while the first scan was held is in the second.
    @Test func aScanAskedWhileOneRunsFollowsIt() async throws {
        let (root, home) = try node()
        let state = root.appendingPathComponent("state")
        let started = Date().addingTimeInterval(-600)
        let table = Locked([Int32(970): ProcInfo(pid: 970, ppid: 1, tty: "ttypts970", comm: "claude", startTime: started, agent: .claude)])
        let reads = Locked(0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        // The first read holds its scan until the test lets it go, with the table as it was when it was read.
        let scanner = SessionScanner(processes: {
            let read = table.value
            var first = false
            reads.mutate { $0 += 1; first = $0 == 1 }
            if first { release.wait() }
            return read
        }, stateDir: { state }, cwd: { _ in "/r/x" }, arguments: { _ in [] })
        let nodes = NodeSessions(root: root, home: home.path, queue: DispatchQueue(label: "engine"), scanner: scanner)
        nodes.refresh()
        try #require(await eventually { reads.value == 1 })
        table.mutate { $0[971] = ProcInfo(pid: 971, ppid: 1, tty: "ttypts971", comm: "claude", startTime: started, agent: .claude) }
        nodes.refresh()
        // That refresh is on the store's queue, the first scan still held.
        on(nodes) {}
        release.signal()
        #expect(await eventually { session(nodes, "ttypts971") != nil })
        #expect(on(nodes) { nodes.scansApplied } == 2)
        #expect(reads.value == 2)
    }

    /// A lead whose board has a question open (`leadsAsking`, set by the engine) needs the user at once: its session is
    /// `leadAsks`, on the list and the change stream, with no scan; the others aren't, and it's turned back as the
    /// question closes.
    @Test func aLeadAskingIsToldAtOnce() async throws {
        let (root, home) = try node()
        let state = root.appendingPathComponent("state")
        let started = Date().addingTimeInterval(-3600)
        func hosted(_ tty: String, _ label: String, _ cwd: String) -> HostSession {
            HostSession(id: UUID(), tty: tty, childPID: Int32(tty.dropFirst(6))!, cwd: cwd, command: "claude", label: label, agent: "claude",
                        title: "", startedAt: started, cols: 80, rows: 24, exit: nil)
        }
        let lead = hosted("ttypts990", "Lead · acme", "/r/acme")
        let other = hosted("ttypts996", "w", "/r/acme")
        let stub = try StubHost(scratch, sessions: [lead, other])
        defer { stub.quit() }
        let link = HostLink(dialer: stub.dialer, root: scratch.url("link-root"), queue: DispatchQueue(label: "engine"), sweep: { _ in })
        link.start()
        try #require(await eventually { link.queue.sync { link.state == .connected } })
        let table = Dictionary(uniqueKeysWithValues: [Int32(990), 996].map {
            ($0, ProcInfo(pid: $0, ppid: 1, tty: "ttypts\($0)", comm: "claude", startTime: started, agent: .claude))
        })
        let nodes = NodeSessions(root: root, home: home.path, queue: link.queue, link: link,
                                 scanner: SessionScanner(processes: { table }, stateDir: { state }, cwd: { _ in "/r/acme" }, arguments: { _ in [] }))
        nodes.start()
        defer { nodes.stop() }
        #expect(await eventually { on(nodes) { nodes.sessions.filter { $0.hostID != nil }.count == 2 } })
        let scans = on(nodes) { nodes.scansApplied }
        func asks() -> [String: Bool] {
            on(nodes) { Dictionary(uniqueKeysWithValues: nodes.sessions.map { ($0.tty, $0.leadAsks) }) }
        }
        func streamed(_ id: UUID) -> Bool? { nodes.changes.values[NodeIds.session(host: id)]?.leadAsks }
        #expect(asks() == ["ttypts990": false, "ttypts996": false])
        on(nodes) { nodes.leadsAsking = ["/r/acme"] }
        #expect(asks() == ["ttypts990": true, "ttypts996": false])
        #expect(streamed(lead.id) == true && streamed(other.id) == false)
        on(nodes) { nodes.leadsAsking = [] }
        #expect(asks() == ["ttypts990": false, "ttypts996": false])
        #expect(streamed(lead.id) == false)
        #expect(on(nodes) { nodes.scansApplied } == scans)
    }

    /// A state folder that was removed is watched again at the next scan (made again, 0700): a hook write in it is then
    /// seen with no clock and no refresh.
    @Test func aRemovedStateFolderIsWatchedAgain() async throws {
        let (root, home) = try node()
        let state = root.appendingPathComponent("state")
        let table = [Int32(970): ProcInfo(pid: 970, ppid: 1, tty: "ttypts970", comm: "claude", startTime: Date().addingTimeInterval(-600),
                                          agent: .claude)]
        func hook(_ event: String) throws {
            var hook = HookState(agent: .claude, tty: "ttypts970", lastEvent: event, lastEventAt: Date().timeIntervalSince1970)
            hook.agentPid = 970
            try hook.save(to: state.appendingPathComponent("ttypts970.json"))
        }
        try hook("PreToolUse")
        let nodes = NodeSessions(root: root, home: home.path, queue: DispatchQueue(label: "engine"),
                                 scanner: SessionScanner(processes: { table }, stateDir: { state }, cwd: { _ in "/r/x" }, arguments: { _ in [] }))
        nodes.start()
        defer { nodes.stop() }
        #expect(await eventually { session(nodes, "ttypts970")?.status == .working })
        try FileManager.default.removeItem(at: state)
        // The watch's scan finds the folder gone, makes it again and watches it.
        #expect(await eventually { FileManager.default.fileExists(atPath: state.path) && session(nodes, "ttypts970")?.status == .unknown })
        try hook("PermissionRequest")
        #expect(await eventually { session(nodes, "ttypts970")?.status == .needsInput })
    }

    /// A state folder that can't be watched is said once, and tried again once a minute (by the store's `now`), not at
    /// every scan: once it can be, a hook write in it is seen with no refresh.
    @Test func anUnwatchableStateFolderIsSaidOnceAndTriedEveryMinute() async throws {
        let (root, home) = try node()
        let state = root.appendingPathComponent("state")
        // A file where the folder should be: nothing to watch.
        try FileManager.default.removeItem(at: state)
        try Data().write(to: state)
        let table = [Int32(970): ProcInfo(pid: 970, ppid: 1, tty: "ttypts970", comm: "claude", startTime: Date().addingTimeInterval(-600),
                                          agent: .claude)]
        let clock = Locked(Date())
        let notes = Locked<[String]>([])
        let nodes = NodeSessions(root: root, home: home.path, queue: DispatchQueue(label: "engine"),
                                 scanner: SessionScanner(processes: { table }, stateDir: { state }, cwd: { _ in "/r/x" }, arguments: { _ in [] }),
                                 now: { clock.value }, note: { line in notes.mutate { $0.append(line) } })
        nodes.start()
        defer { nodes.stop() }
        #expect(await eventually { session(nodes, "ttypts970") != nil })
        for _ in 0..<3 {
            clock.mutate { $0 += 10 }
            try await refreshAndSettle(nodes)
        }
        #expect(notes.value.filter { $0.contains("can't be watched") }.count == 1, "\(notes.value)")
        // A minute on, the folder there: watched again.
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        clock.mutate { $0 += 30 }
        try await refreshAndSettle(nodes)
        #expect(session(nodes, "ttypts970")?.status == .unknown)
        var hook = HookState(agent: .claude, tty: "ttypts970", lastEvent: "PermissionRequest", lastEventAt: Date().timeIntervalSince1970)
        hook.agentPid = 970
        try hook.save(to: state.appendingPathComponent("ttypts970.json"))
        #expect(await eventually { session(nodes, "ttypts970")?.status == .needsInput })
        #expect(notes.value.filter { $0.contains("can't be watched") }.count == 1, "\(notes.value)")
    }

    /// Once stopped, nothing scans: a refresh starts no scan (no process table read, no screen asked of the host).
    @Test func nothingScansOnceStopped() async throws {
        let (root, home) = try node()
        let state = root.appendingPathComponent("state")
        let reads = Locked(0)
        let nodes = NodeSessions(root: root, home: home.path, queue: DispatchQueue(label: "engine"),
                                 scanner: SessionScanner(processes: { reads.mutate { $0 += 1 }; return [:] }, stateDir: { state },
                                                         cwd: { _ in nil }, arguments: { _ in [] }))
        nodes.start()
        #expect(await eventually { on(nodes) { nodes.scansApplied } == 1 && !nodes.hooksInstalled.isEmpty })
        nodes.stop()
        nodes.refresh()
        // The refresh has run on the store's queue; a scan it started would read the table on the scan queue before
        // the hooks' status read after it lands.
        on(nodes) {}
        try HookInstaller.install(agent: .claude, at: HookInstaller.configURL(for: .claude, home: home.path),
                                  hookBinary: root.appendingPathComponent("bin/vibeswitcher-hook").path)
        nodes.refreshHookStatus()
        #expect(await eventually { on(nodes) { nodes.hooksInstalled[.claude] == true } })
        #expect(reads.value == 1)
        #expect(on(nodes) { nodes.scansApplied } == 1)
    }

    /// A stand-in host listing one idle Claude session (its title's ✳) on `tty`, whose screen's footer shows a
    /// background shell; a link to it, welcomed; a store on it, started, whose table has the agent on that terminal.
    private func quietSession(now: @escaping @Sendable () -> Date = { Date() }) async throws
        -> (stub: StubHost, link: HostLink, nodes: NodeSessions, hosted: HostSession) {
        let (root, home) = try node()
        let state = root.appendingPathComponent("state")
        var hosted = StubHost.session(title: "✳ Claude Code", tty: "ttypts970")
        hosted.agent = "claude"
        let stub = try StubHost(scratch, sessions: [hosted])
        stub.screenText = "❯ \n\n  ⏵⏵ bypass permissions on · 1 shell\n"
        let link = HostLink(dialer: stub.dialer, root: scratch.url("link-root"), queue: DispatchQueue(label: "engine"), sweep: { _ in })
        link.start()
        try #require(await eventually { link.queue.sync { link.state == .connected } })
        let table = [Int32(970): ProcInfo(pid: 970, ppid: 1, tty: "ttypts970", comm: "claude", startTime: Date().addingTimeInterval(-600),
                                          agent: .claude)]
        let nodes = NodeSessions(root: root, home: home.path, queue: link.queue, link: link,
                                 scanner: SessionScanner(processes: { table }, stateDir: { state }, cwd: { _ in "/r/x" }, arguments: { _ in [] }),
                                 now: now)
        nodes.start()
        return (stub, link, nodes, hosted)
    }

    /// A quiet Claude session (its turn over) with background work its footer shows and no process holds (an agent, a
    /// task) is `background`, waiting on what the footer says: the store reads the hosted session's screen through the
    /// link.
    @Test func aQuietClaudeSessionsFooterGivesItsBackgroundWork() async throws {
        // The stand-in kept to the end: let go, it quits, and the link with it.
        let (stub, _, nodes, hosted) = try await quietSession()
        defer { nodes.stop(); stub.quit() }
        #expect(try await scanned(nodes) { nodes.sessions.first?.status == .background })
        let quiet = try #require(session(nodes, "ttypts970"))
        #expect(quiet.detail == "Waiting on 1 shell")
        #expect(quiet.hostID == hosted.id)
    }

    /// A quiet session's screen read with something new in its footer scans at once: after the scan that asked it, no
    /// refresh and no clock, it's `background`.
    @Test func aScreenWithANewFooterScansAtOnce() async throws {
        let (stub, _, nodes, _) = try await quietSession()
        defer { nodes.stop(); stub.quit() }
        // The start's scan finds it quiet (idle: ✳, never seen busy); the next asks its screen.
        #expect(await eventually { session(nodes, "ttypts970")?.status == .idle })
        try await refreshAndSettle(nodes)
        #expect(await eventually { session(nodes, "ttypts970")?.status == .background })
        #expect(session(nodes, "ttypts970")?.detail == "Waiting on 1 shell")
    }

    /// How many `screen` requests the stand-in has had once every request the store sent before now reached it (a
    /// history read through the link, answered after them on the one connection).
    private func screensAsked(_ stub: StubHost, _ link: HostLink, _ id: UUID) async throws -> Int {
        let answered = Locked(false)
        link.history(id, lines: 1) { _ in answered.value = true }
        try #require(await eventually { answered.value })
        return stub.requests.filter { if case .screen = $0 { return true } else { return false } }.count
    }

    /// The quiet sessions' screens are asked at most every 6 s, however often the store scans.
    @Test func itsScreenIsAskedAtMostEverySixSeconds() async throws {
        let clock = Locked(Date())
        let (stub, link, nodes, hosted) = try await quietSession(now: { clock.value })
        defer { nodes.stop(); stub.quit() }
        // The first scan finds it quiet; the next asks its screen, whose footer then lands with a scan of its own.
        #expect(try await scanned(nodes) { nodes.sessions.first?.status == .background })
        #expect(try await screensAsked(stub, link, hosted.id) == 1)
        for _ in 0..<4 {
            clock.mutate { $0 += 1 }
            try await refreshAndSettle(nodes)
        }
        #expect(try await screensAsked(stub, link, hosted.id) == 1)
        clock.mutate { $0 += 2 }
        try await refreshAndSettle(nodes)
        #expect(try await screensAsked(stub, link, hosted.id) == 2)
        for _ in 0..<3 {
            clock.mutate { $0 += 1 }
            try await refreshAndSettle(nodes)
        }
        #expect(try await screensAsked(stub, link, hosted.id) == 2)
        #expect(session(nodes, "ttypts970")?.status == .background)
    }

    /// What a session waits on, by its status and hook (the app's `SessionStore.detail(for:hook:agent:)`, copied).
    @Test func theDetailSaysWhatASessionWaitsOn() throws {
        func hook(_ event: String, _ change: (inout HookState) -> Void = { _ in }) -> HookState {
            var hook = HookState(agent: .claude, tty: "ttypts1", lastEvent: event, lastEventAt: 0)
            change(&hook)
            return hook
        }
        let detail = NodeSessions.detail(for:hook:agent:)
        #expect(detail(.needsInput, hook("PermissionRequest") { $0.request = "Bash(rm -rf build)" }, .claude) == "Bash(rm -rf build)")
        #expect(detail(.needsInput, hook("Notification") { $0.notice = "Claude needs your permission" }, .claude) == "Claude needs your permission")
        #expect(detail(.needsInput, hook("PreToolUse") { $0.toolName = "AskUserQuestion" }, .claude) == "Asking you a question")
        #expect(detail(.needsInput, hook("PreToolUse") { $0.toolName = "request_user_input" }, .codex) == "Asking you a question")
        #expect(detail(.needsInput, hook("PreToolUse") { $0.toolName = "ExitPlanMode" }, .claude) == "Plan ready for review")
        #expect(detail(.needsInput, hook("PermissionRequest"), .claude) == "Waiting for you")
        #expect(detail(.working, hook("UserPromptSubmit") { $0.lastPrompt = "fix the login" }, .claude) == "› fix the login")
        let system = "<command-name>/model</command-name>"
        try #require(SessionNaming.isSystemPrompt(system))
        #expect(detail(.working, hook("PreToolUse") { $0.lastPrompt = system; $0.toolName = "Bash" }, .claude) == "Running Bash")
        #expect(detail(.working, hook("PreToolUse") { $0.toolName = "Edit" }, .claude) == "Running Edit")
        #expect(detail(.working, hook("UserPromptSubmit"), .claude) == nil)
        #expect(detail(.done, hook("Stop") { $0.lastMessage = "Fixed it." }, .claude) == "Fixed it.")
        #expect(detail(.idle, hook("SessionStart") { $0.lastMessage = "Hi." }, .claude) == "Hi.")
        #expect(detail(.unknown, nil, .claude) == "No live status yet: waiting for this session's first hook event")
        #expect(detail(.unknown, nil, .codex) == "No live status: this Codex session started before the hooks; restart it")
        #expect(detail(.unknown, hook("Stop"), .claude) == nil)
    }

    /// Whether each agent's hooks are installed is read from the node's home (the agents' own config there), never this
    /// process's.
    @Test func hooksInstalledAreReadFromTheNodesHome() async throws {
        let (root, home) = try node()
        try HookInstaller.install(agent: .claude, at: HookInstaller.configURL(for: .claude, home: home.path),
                                  hookBinary: root.appendingPathComponent("bin/vibeswitcher-hook").path)
        let nodes = NodeSessions(root: root, home: home.path, queue: DispatchQueue(label: "engine"),
                                 scanner: SessionScanner(processes: { [:] }, stateDir: { root.appendingPathComponent("state") },
                                                         cwd: { _ in nil }, arguments: { _ in [] }))
        nodes.start()
        defer { nodes.stop() }
        #expect(await eventually { on(nodes) { nodes.hooksInstalled } == [.claude: true, .codex: false] })
        try HookInstaller.uninstall(agent: .claude, at: HookInstaller.configURL(for: .claude, home: home.path))
        nodes.refreshHookStatus()
        #expect(await eventually { on(nodes) { nodes.hooksInstalled } == [.claude: false, .codex: false] })
    }
}
