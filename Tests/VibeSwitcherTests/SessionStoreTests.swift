import Combine
import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The session list is published only when something it shows changed: every publish redraws the menu bar icon, the
/// popover or sidebar, and recomputes the window's sections.
@MainActor
struct SessionStoreTests {
    private let stateDir = scratchRoot.appendingPathComponent("store-tests-\(UUID().uuidString)")

    /// A working agent and one whose turn is over with a background shell still running (its age is in the detail).
    /// `readable`: whether the process table can be read at the time. `inTerminal`: a third agent, in Terminal.app (a
    /// stand-in that has no tabs). `ledgers`: writes the activity ledgers.
    private func store(started: Date, readable: @escaping () -> Bool = { true }, inTerminal: Bool = false,
                       ledgers: LedgerWriter = LedgerWriter { _ in }) throws -> SessionStore {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        var working = HookState(agent: .claude, tty: "ttys970", lastEvent: "PreToolUse", lastEventAt: now - 30)
        working.agentPid = 970
        working.toolName = "Bash"
        working.toolDetail = "npm test"
        working.toolStartedAt = now - 30
        try working.save(to: stateDir.appendingPathComponent("ttys970.json"))
        var finished = HookState(agent: .claude, tty: "ttys971", lastEvent: "Stop", lastEventAt: now - 600)
        finished.agentPid = 971
        try finished.save(to: stateDir.appendingPathComponent("ttys971.json"))
        let launched = started.addingTimeInterval(-3600)
        var procs = [
            ProcInfo(pid: 960, ppid: 1, tty: nil, comm: "vibeswitcher-hos", startTime: launched, agent: nil),
            ProcInfo(pid: 970, ppid: 960, tty: "ttys970", comm: "claude", startTime: launched, agent: .claude),
            ProcInfo(pid: 971, ppid: 960, tty: "ttys971", comm: "claude", startTime: launched, agent: .claude),
            ProcInfo(pid: 972, ppid: 971, tty: "ttys971", comm: "zsh", startTime: started.addingTimeInterval(-5), agent: nil),
        ]
        if inTerminal {
            procs += [ProcInfo(pid: 950, ppid: 1, tty: nil, comm: "Terminal", startTime: launched, agent: nil),
                      ProcInfo(pid: 973, ppid: 950, tty: "ttys973", comm: "claude", startTime: launched, agent: .claude)]
        }
        let table = Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
        let dir = stateDir
        return SessionStore(scanner: SessionScanner(
            processes: { readable() ? table : nil }, stateDir: { dir }, cwd: { _ in "/tmp/store-tests" },
            arguments: { $0.pid == 972 ? ["/bin/zsh", "-c", "source /h/.claude/shell-snapshots/a.sh && eval 'npm run dev' < /dev/null"] : [] }),
            bridge: .init(tabs: { .tabs([:]) }, screens: { _ in [:] }), ledgers: ledgers)
    }

    /// The store's time: it moves only when the test says, however long the scans take.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date()
        var now: Date { lock.lock(); defer { lock.unlock() }; return time }
        func advance(_ seconds: TimeInterval) { lock.lock(); time += seconds; lock.unlock() }
    }

    /// Refreshes, and waits for that scan to land: it runs on the store's queue and lands back on the main thread.
    private func refreshAndSettle(_ store: SessionStore) async throws {
        let before = store.scansApplied
        store.refresh()
        #expect(await until { store.scansApplied > before })
    }

    @Test func scansThatFindNothingNewDontRepublish() async throws {
        AppStatus.enabled = false
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let clock = Clock()
        let store = try store(started: clock.now)
        store.clock = { clock.now }
        var publishes = 0
        let watching = store.$sessions.dropFirst().sink { _ in publishes += 1 }
        defer { watching.cancel() }
        try await refreshAndSettle(store)
        #expect(store.sessions.map(\.status) == [.working, .background] || store.sessions.map(\.status) == [.background, .working])
        #expect(store.sessions.first { $0.tty == "ttys971" }?.detail == "Waiting on npm run dev · <1m")
        #expect(publishes == 1)
        // Seconds later: the background shell is older, the working agent's tool has run longer; nothing shown changed.
        for _ in 0..<3 {
            clock.advance(2)
            try await refreshAndSettle(store)
        }
        #expect(publishes == 1)
    }

    /// Whether a quiet worker still has a shell running is answered by the scan (off the main thread), so each
    /// session carries its background shells: the lead's witness reads them there instead of the process table.
    @Test func sessionsCarryTheirBackgroundShells() async throws {
        AppStatus.enabled = false
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let store = try store(started: Date())
        try await refreshAndSettle(store)
        #expect(store.sessions.first { $0.tty == "ttys971" }?.backgroundJobs.map(\.command) == ["npm run dev"])
        #expect(store.sessions.first { $0.tty == "ttys970" }?.backgroundJobs == [])
    }

    /// Whether you're at the Mac, and the desktops shown, are asked of the window server on the scan's queue, once a
    /// scan: asked on the main thread at each scan's landing, they held End Session…'s alert on a loaded Mac (10-27).
    @Test func presenceAndDesktopsAreReadOffTheMainThread() async throws {
        AppStatus.enabled = false
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let store = try store(started: Date())
        let reads = Reads()
        store.presence = { reads.add("presence"); return true }
        store.desktops = { reads.add("desktops"); return [] }
        for _ in 0..<2 { try await refreshAndSettle(store) }
        // A scan each (a scan asked for while one runs follows it).
        #expect(reads.names(main: false).filter { $0 == "presence" }.count >= 2)
        #expect(reads.names(main: false).filter { $0 == "desktops" }.count >= 2)
        #expect(reads.names(main: true) == [])
    }

    /// Terminal being the app in front is asked on the scan's queue (`TerminalBridge.front`, the frontmost app's bundle
    /// id: a synchronous XPC), and the ledger is written on its writer's queue: both were done on the main thread as
    /// each scan landed (hang-20261028-171900: 836 of 2366 samples). A lookup or a write that takes 5 s holds neither
    /// a refresh nor a scan's landing.
    @Test func slowAppLookupsAndLedgerWritesDontHoldTheMainThread() async throws {
        AppStatus.enabled = false
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let clock = Clock()
        let written = Written()
        let writes = Gate()
        let store = try store(started: clock.now, inTerminal: true, ledgers: LedgerWriter { ledger in
            written.add(ledger)
            writes.wait()
            written.finish()
        })
        store.clock = { clock.now }
        let reads = Reads()
        let lookups = Gate()
        store.terminalFront = { reads.add("front"); lookups.wait(); return (false, nil) }
        // A failed run lets the scan and the writer go too.
        defer { lookups.open(); writes.open() }

        // The scan waits on its lookup; the main thread doesn't. (Its clock is 10 s past the store's start: the
        // first save is a minute after that.)
        clock.advance(10)
        store.refresh()
        #expect(await until { reads.names(main: false) == ["front"] })
        #expect(store.scansApplied == 0)
        lookups.open()
        #expect(await until { store.scansApplied == 1 })
        #expect(reads.names(main: true) == [])

        // Scans every 20 s: at 70 s the ledger is saved, and that scan lands while its write still waits.
        for _ in 0..<3 {
            clock.advance(20)
            try await refreshAndSettle(store)
        }
        // Its write begins on the writer's queue, after the scan landed.
        #expect(await until { written.ledgers.count == 1 })
        #expect(written.finished == 0)
        // Saved again at 130 s and 190 s while it waits: the later takes the earlier's place, written after it.
        for _ in 0..<6 {
            clock.advance(20)
            try await refreshAndSettle(store)
        }
        #expect(written.ledgers.count == 1)
        writes.open()
        #expect(await until { written.finished == 2 })
        // At quit: written before it returns.
        store.saveLedger()
        let ledgers = written.ledgers
        #expect(ledgers.count == 3)
        #expect(ledgers.count == 3 && ledgers[1] == store.today && ledgers[2] == store.today)
        #expect(ledgers.first.map { $0.agentsWorking < store.today.agentsWorking } == true)
        #expect(written.onMain == 0)
        #expect(reads.names(main: true) == [])
    }

    /// Ledgers written, and whether on the main thread.
    final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [ActivityLedger] = []
        private var main = 0
        private var done = 0

        func add(_ ledger: ActivityLedger) {
            lock.lock()
            all.append(ledger)
            if Thread.isMainThread { main += 1 }
            lock.unlock()
        }

        func finish() { lock.lock(); done += 1; lock.unlock() }
        var ledgers: [ActivityLedger] { lock.lock(); defer { lock.unlock() }; return all }
        var onMain: Int { lock.lock(); defer { lock.unlock() }; return main }
        var finished: Int { lock.lock(); defer { lock.unlock() }; return done }
    }

    /// Holds whoever waits on it off the main thread until the test opens it (a slow writer or lookup: 5 s and more);
    /// open, it holds no one. It never opens by itself while the test still looks (a 60 s limit did, on a loaded Mac:
    /// the scan landed before the test checked it hadn't), only past the hang guard. Waited on on the main thread (a
    /// run without the fix) it fails the test and holds nothing, so that run ends.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let group = DispatchGroup()
        private var opened = false
        init() { group.enter() }

        func wait() {
            guard !Thread.isMainThread else {
                Issue.record("Waited on a slow lookup or write on the main thread")
                return
            }
            if group.wait(timeout: .now() + hangGuard) == .timedOut { Issue.record("The gate was never opened") }
        }

        func open() {
            lock.lock()
            defer { lock.unlock() }
            guard !opened else { return }
            opened = true
            group.leave()
        }
    }

    /// What was read, and on which thread.
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var reads: [(name: String, main: Bool)] = []

        func add(_ name: String) {
            lock.lock()
            reads.append((name, Thread.isMainThread))
            lock.unlock()
        }

        func names(main: Bool) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return reads.filter { $0.main == main }.map(\.name)
        }
    }

    /// A scan whose process table couldn't be read (in time, on a loaded Mac) keeps the sessions found before, and the
    /// time that table was read: the witness tells a session's agent as quit only from a table read since.
    @Test func anUnreadTableKeepsTheTimeOfTheLastOneRead() async throws {
        AppStatus.enabled = false
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let clock = Clock()
        let read = clock.now
        let readable = Readable()
        let store = try store(started: read, readable: { readable.value })
        store.clock = { clock.now }
        #expect(store.tableReadAt == nil)
        try await refreshAndSettle(store)
        #expect(store.tableReadAt == read)
        readable.value = false
        clock.advance(120)
        try await refreshAndSettle(store)
        #expect(store.tableReadAt == read)
        #expect(Set(store.sessions.map(\.tty)) == ["ttys970", "ttys971"])
        readable.value = true
        try await refreshAndSettle(store)
        #expect(store.tableReadAt == read + 120)
    }

    /// The window's row and a team row read a window session's agent as quit by the witness's rule: only from the
    /// store's table read a minute after the session started. Never read, or read before it started (the table
    /// unreadable since, on a loaded Mac): unknown and live, not "agent ended · shell".
    @Test func rowsTellAnAgentQuitOnlyFromATableReadAMinuteAfterItStarted() async throws {
        AppStatus.enabled = false
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let clock = Clock()
        let read = clock.now
        let readable = Readable()
        let store = try store(started: read, readable: { readable.value })
        store.clock = { clock.now }
        // A worker's window session whose agent the store's table doesn't show, started just after the first read.
        let worker = HostSession(id: UUID(), tty: "ttys980", childPID: 980, cwd: "/r/acme/.vibeswitcher/worktrees/k", command: nil,
                                 label: "Worker: K", agent: "claude", title: "", startedAt: read + 10, cols: 80, rows: 24, exit: nil)
        let model = WindowModel()
        func row() -> WindowRow? {
            model.update(sessions: store.sessions, hosted: [worker], table: store.tableRead)
            return model.allRows.first { $0.hostID == worker.id }
        }
        let later = read + 600

        #expect(store.tableReadAt == nil)
        #expect(row()?.state(now: later).text == "unknown")
        #expect(row().map(LeadTeams.isLive) == true)

        try await refreshAndSettle(store)
        readable.value = false
        clock.advance(600)
        try await refreshAndSettle(store)
        #expect(store.tableReadAt == read)
        #expect(row()?.state(now: later).text == "unknown")
        #expect(row().map { LeadTeams.state(of: $0, now: later).group } == .idle)
        #expect(row().map(LeadTeams.isLive) == true)

        readable.value = true
        try await refreshAndSettle(store)
        #expect(store.tableReadAt == later)
        #expect(row()?.state(now: later).text == "agent ended · shell")
        #expect(row().map(LeadTeams.isLive) == false)
    }

    /// The witness tells a window session's agent as quit only from a table read that could tell what runs on its
    /// terminal: while its process there can't be told (mid-exec on a busy Mac), it's unknown, not quit.
    @Test func anAgentQuitNeedsATableThatToldItsTerminal() async throws {
        AppStatus.enabled = false
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let clock = Clock()
        let started = clock.now
        let readable = Readable()
        let shell = ProcInfo(pid: 980, ppid: 1, tty: "ttys980", comm: "zsh", startTime: started, agent: nil)
        let midExec = ProcInfo(pid: 981, ppid: 980, tty: "ttys980", comm: "2.1.302", startTime: started, agent: nil,
                               identityUnknown: true)
        let dir = stateDir
        let store = SessionStore(scanner: SessionScanner(
            processes: { [980: shell] .merging(readable.value ? [:] : [981: midExec]) { a, _ in a } }, stateDir: { dir },
            cwd: { _ in "/tmp/store-tests" }, arguments: { _ in [] }))
        store.clock = { clock.now }
        let window = HostSession(id: UUID(), tty: "ttys980", childPID: 980, cwd: "/tmp/store-tests", command: "claude", label: "w",
                                 agent: "claude", title: "w", startedAt: started, cols: 80, rows: 24, exit: nil)
        #expect(!store.agentQuit(window))
        // The window's row and a team row read it as the witness does.
        let model = WindowModel()
        func row() -> WindowRow? {
            model.update(sessions: store.sessions, hosted: [window], table: store.tableRead)
            return model.allRows.first { $0.hostID == window.id }
        }
        readable.value = false
        clock.advance(120)
        try await refreshAndSettle(store)
        #expect(store.undecided.contains("ttys980"))
        #expect(!store.agentQuit(window))
        #expect(row()?.state(now: clock.now).text == "unknown")
        #expect(row().map(LeadTeams.isLive) == true)
        // Only that terminal is in question.
        var elsewhere = window
        elsewhere.tty = "ttys981"
        #expect(store.agentQuit(elsewhere))
        readable.value = true
        try await refreshAndSettle(store)
        #expect(store.undecided == Undecided())
        #expect(store.agentQuit(window))
        #expect(row()?.state(now: clock.now).text == "agent ended · shell")
        #expect(row().map(LeadTeams.isLive) == false)
    }

    /// A lead's workers and verifiers are the lead's team, not your sessions (UI audit 2026-10-22 #1): with a lead,
    /// three workers, a verifier and two sessions of your own, three are yours (the menu bar's dots, the pill and the
    /// counts), the four others its team. A worker turning done tells nobody (its lead reads its report); one needing
    /// you still does, as your own session turning done does.
    @Test func workersAndVerifiersArentCountedAsYourSessions() async throws {
        AppStatus.enabled = false
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let started = Date().addingTimeInterval(-3600)
        let worktrees = "/r/acme/.vibeswitcher/worktrees"
        // tty, label (nil: in Terminal), cwd
        let sessions: [(String, String?, String)] = [
            ("ttys990", "Lead · acme", "/r/acme"), ("ttys991", "Worker: A", "\(worktrees)/a"),
            ("ttys992", "Worker: B", "\(worktrees)/b"), ("ttys993", "Worker: C", "\(worktrees)/c"),
            ("ttys994", "Verifier: A", "\(worktrees)/a"), ("ttys995", nil, "/r/notes"), ("ttys996", "w", "/r/site"),
        ]
        var procs = [Int32(960): ProcInfo(pid: 960, ppid: 1, tty: nil, comm: "vibeswitcher-hos", startTime: started, agent: nil)]
        var cwds: [Int32: String] = [:]
        for (tty, _, cwd) in sessions {
            let pid = Int32(tty.dropFirst(4))!
            procs[pid] = ProcInfo(pid: pid, ppid: 960, tty: tty, comm: "claude", startTime: started, agent: .claude)
            cwds[pid] = cwd
        }
        let table = procs, dir = stateDir
        let store = SessionStore(scanner: SessionScanner(processes: { table }, stateDir: { dir }, cwd: { cwds[$0] },
                                                         arguments: { _ in [] }))
        // The test's clock starts once the store has launched: a "done" from before its launch (by the Mac's own
        // clock) counts as already seen, so a clock started earlier, on a Mac slow enough that setting up took longer
        // than the 5 s it's moved on below, made the worker's "done" read as idle and never shown.
        let clock = Clock()
        store.clock = { clock.now }
        func hook(_ tty: String, _ event: String) throws {
            var state = HookState(agent: .claude, tty: tty, lastEvent: event, lastEventAt: clock.now.timeIntervalSince1970)
            state.agentPid = Int32(tty.dropFirst(4))!
            try state.save(to: stateDir.appendingPathComponent("\(tty).json"))
        }
        for (tty, _, _) in sessions { try hook(tty, "PreToolUse") }
        var attention: [String] = []
        store.onAttention = { attention.append($0.tty) }
        store.updateHosted(sessions.compactMap { tty, label, cwd in
            label.map { HostSession(id: UUID(), tty: tty, childPID: Int32(tty.dropFirst(4))!, cwd: cwd, command: "claude", label: $0,
                                    agent: "claude", title: "", startedAt: started, cols: 80, rows: 24, exit: nil) }
        })
        // A scan already under way may have read the hook files before they changed: wait for one that reads them now.
        func scanned(_ condition: () -> Bool) async -> Bool {
            store.refresh()
            return await until(condition)
        }
        func status(_ tty: String) -> SessionStatus? { store.sessions.first { $0.tty == tty }?.status }
        #expect(await scanned { store.sessions.count == 7 && store.sessions.allSatisfy { $0.status == .working } })
        #expect(store.sessions.first { $0.tty == "ttys990" }?.teamRole == .lead)
        #expect(store.sessions.first { $0.tty == "ttys994" }?.teamRole == .verifier)
        #expect(store.sessions.first { $0.tty == "ttys995" }?.teamRole == nil)
        let split = store.split
        #expect(Set(split.own.map(\.tty)) == ["ttys990", "ttys995", "ttys996"])
        #expect(split.teams.map(\.project) == ["acme"])
        #expect(Set(split.teams.flatMap(\.members).map(\.tty)) == ["ttys991", "ttys992", "ttys993", "ttys994"])
        // The popover's numbers and keys: yours first, then the team.
        #expect(split.listed.map(\.tty) == split.own.map(\.tty) + split.teams.flatMap(\.members).map(\.tty))

        // A worker finishes its turn, another asks you something.
        clock.advance(5)
        try hook("ttys991", "Stop")
        try hook("ttys992", "PermissionRequest")
        #expect(await scanned { status("ttys991") == .done && status("ttys992") == .needsInput })
        #expect(attention == ["ttys992"])
        // Then your own session finishes: its "done" is told once it has stayed done a moment, later than the
        // worker's would have been.
        clock.advance(5)
        try hook("ttys995", "Stop")
        #expect(await scanned { status("ttys995") == .done })
        #expect(await until { attention.contains("ttys995") })
        #expect(attention == ["ttys992", "ttys995"])
    }

    private final class Readable: @unchecked Sendable {
        private let lock = NSLock()
        private var readable = true
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return readable }
            set { lock.lock(); readable = newValue; lock.unlock() }
        }
    }
}
