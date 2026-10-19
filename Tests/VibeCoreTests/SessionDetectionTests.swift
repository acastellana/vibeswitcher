import Foundation
import Testing
@testable import VibeCore

/// A process whose argv changes when it execs, as `vibeswitcher-host --pty-exec claude …` does.
private final class FakeProcess: @unchecked Sendable {
    var comm: String
    var argv: [String]
    var reads = 0
    init(comm: String, argv: [String]) { self.comm = comm; self.argv = argv }
}

struct ArgumentCacheTests {
    private let launcher = ["/Applications/VibeSwitcher.app/Contents/MacOS/vibeswitcher-host", "--pty-exec",
                            "/Users/me/.local/bin/claude", "--resume"]
    private let claude = ["claude", "--resume"]

    @Test func aScanBeforeExecDoesNotHideTheSessionForItsLife() {
        // ttys006: the first scan caught the host launcher before it exec'd Claude (same pid, same start time).
        let process = FakeProcess(comm: "vibeswitcher-hos", argv: launcher)
        let cache = ArgumentCache { _ in process.reads += 1; return process.argv }
        let first = ProcessTable.agent(pid: 46336, start: 1000, comm: process.comm, tty: "ttys006", arguments: cache)
        #expect(first == nil)

        process.comm = "2.1.302"
        process.argv = claude
        for _ in 0..<3 {
            #expect(ProcessTable.agent(pid: 46336, start: 1000, comm: process.comm, tty: "ttys006", arguments: cache) == .claude)
        }
        // Read again once after the exec, then cached.
        #expect(process.reads == 2)
    }

    @Test func argvIsReadOncePerProcess() {
        let process = FakeProcess(comm: "2.1.302", argv: claude)
        let cache = ArgumentCache { _ in process.reads += 1; return process.argv }
        for _ in 0..<5 { _ = ProcessTable.agent(pid: 7, start: 1, comm: process.comm, tty: "ttys001", arguments: cache) }
        #expect(process.reads == 1)
    }

    @Test func anUnreadableArgvIsTriedAgain() {
        // KERN_PROCARGS2 fails for a moment while a process is being set up; don't remember "no argv".
        let process = FakeProcess(comm: "2.1.302", argv: [])
        let cache = ArgumentCache { _ in process.reads += 1; return process.argv }
        #expect(ProcessTable.agent(pid: 7, start: 1, comm: process.comm, tty: "ttys001", arguments: cache) == nil)
        process.argv = claude
        #expect(ProcessTable.agent(pid: 7, start: 1, comm: process.comm, tty: "ttys001", arguments: cache) == .claude)
    }

    @Test func aReusedPidIsReadAfresh() {
        let process = FakeProcess(comm: "zsh", argv: ["-zsh"])
        let cache = ArgumentCache { _ in process.reads += 1; return process.argv }
        #expect(ProcessTable.agent(pid: 7, start: 1, comm: "2.1.302", tty: "ttys001", arguments: cache) == nil)
        process.argv = claude
        #expect(ProcessTable.agent(pid: 7, start: 2, comm: "2.1.302", tty: "ttys001", arguments: cache) == .claude)
    }

    @Test func processesWithoutATerminalAreNotRead() {
        let process = FakeProcess(comm: "2.1.302", argv: claude)
        let cache = ArgumentCache { _ in process.reads += 1; return process.argv }
        #expect(ProcessTable.agent(pid: 7, start: 1, comm: process.comm, tty: nil, arguments: cache) == nil)
        #expect(process.reads == 0)
    }

    /// Codex 0.163's background daemon and its updater loop, as `ps` showed them on this Mac (no tty under launchd):
    /// even if one ever ran on a terminal, it's the same `codex` binary but no session.
    @Test func codexAppServerIsNeverASession() {
        let binary = "/Users/me/.codex/packages/app-server-daemon/releases/0.163.0-aarch64-apple-darwin/bin/codex"
        let daemons = [[binary, "app-server", "--listen", "unix://", "--analytics-default-enabled", "--managed-daemon"],
                       [binary, "app-server", "daemon", "pid-update-loop"],
                       ["codex", "app-server"],
                       ["codex", "-c", "model=\"o3\"", "app-server", "--listen", "unix://"]]
        for (index, argv) in daemons.enumerated() {
            let cache = ArgumentCache { _ in argv }
            #expect(ProcessTable.agent(pid: Int32(100 + index), start: 1, comm: "codex", tty: "ttys009", arguments: cache) == nil)
            #expect(ProcessTable.agent(pid: Int32(100 + index), start: 1, comm: "codex", tty: nil, arguments: cache) == nil)
        }
        for argv in [["codex"], ["codex", "resume", "--last"], ["codex", "explain the app-server"]] {
            let cache = ArgumentCache { _ in argv }
            #expect(ProcessTable.agent(pid: 200, start: 1, comm: "codex", tty: "ttys009", arguments: cache) == .codex)
        }
    }
}

/// Hook-less sessions, status read off the tab title alone.
struct TitleOnlyStatusTests {
    /// One title per scan for one terminal: (pid, title) → the status the app shows.
    private func statuses(_ fixture: [(pid: Int32, title: String)], tty: String = "ttys000") -> [SessionStatus] {
        var witness = TurnWitness()
        return fixture.map { scan in
            let activity = StatusRules.parseTitle(scan.title).activity
            let seenBusy = witness.observe(tty: tty, pid: scan.pid, title: activity)
            return StatusRules.resolve(hook: nil, title: activity, now: 0, seenBusy: seenBusy)
        }
    }

    @Test func aSessionThatNeverRanATurnIsNotDone() {
        // ttys000: started by the host, no hooks, no transcript, ✳ in the title for 4 h 45 min.
        let fixture = Array(repeating: (pid: Int32(85757), title: "✳ Claude Code"), count: 8550)
        #expect(Set(statuses(fixture)) == [.idle])
    }

    @Test func aTurnSeenEndingIsDone() {
        let fixture: [(pid: Int32, title: String)] = [
            (85757, "✳ Claude Code"), (85757, "◐ Fix login bug"), (85757, "◓ Fix login bug"),
            (85757, "✳ Fix login bug"), (85757, "✳ Fix login bug"),
        ]
        #expect(statuses(fixture) == [.idle, .working, .working, .done, .done])
    }

    @Test func aNewProcessOnTheSameTerminalStartsOver() {
        let fixture: [(pid: Int32, title: String)] = [
            (100, "◐ Old task"), (100, "✳ Old task"),
            (200, "✳ Claude Code"), (200, "⠂ New task"), (200, "✳ New task"),
        ]
        #expect(statuses(fixture) == [.working, .done, .idle, .working, .done])
    }

    @Test func aPlainTitleStaysUnknown() {
        #expect(statuses([(1, "zsh"), (1, "◐ Working"), (1, "zsh")]) == [.unknown, .working, .unknown])
    }

    @Test func prunedTerminalsAreForgotten() {
        var witness = TurnWitness()
        _ = witness.observe(tty: "ttys001", pid: 1, title: .busy)
        witness.prune(liveTTYs: [])
        let seenBusy = witness.observe(tty: "ttys001", pid: 1, title: .idle)
        #expect(!seenBusy)
    }

    @Test func hooksStillDecideWhenTheyExist() {
        // A Stop hook is a finished turn whether or not a spinner was seen.
        let stop = HookState(agent: .claude, tty: "ttys001", lastEvent: "Stop", lastEventAt: 100)
        #expect(StatusRules.resolve(hook: stop, title: .idle, now: 200, seenBusy: false) == .done)
    }
}

/// Stands in for Terminal.app: answers each read from a script, and counts the `osascript` runs it would cost.
private final class FakeTerminal: @unchecked Sendable {
    struct Tab { let title: String; let position: ScreenPosition }
    var tabReads: [TerminalRead<Tab>] = []
    var screenReads: [[String: String]?] = []
    var tabCalls = 0
    var screenCalls = 0

    var bridge: TerminalPoll<Tab>.Bridge {
        .init(tabs: { [self] in
            tabCalls += 1
            return tabReads.isEmpty ? .failed : tabReads.removeFirst()
        }, screens: { [self] ttys in
            // Like TerminalBridge.readScreens: nothing asked, nothing run.
            guard !ttys.isEmpty else { return [:] }
            screenCalls += 1
            return screenReads.isEmpty ? nil : screenReads.removeFirst()
        })
    }

    static func tabs(_ titles: [String: String]) -> [String: Tab] {
        var tabs: [String: Tab] = [:]
        for (index, tty) in titles.keys.sorted().enumerated() {
            tabs[tty] = Tab(title: titles[tty]!, position: ScreenPosition(
                frame: CGRect(x: 0, y: Double(index) * 400, width: 800, height: 380), tabIndex: 1))
        }
        return tabs
    }
}

struct TerminalPollTests {
    private let titles = ["ttys001": "✳ Fix login bug", "ttys002": "◐ Write docs", "ttys003": "✳ Review"]
    private let inTerminal: Set<String> = ["ttys001", "ttys002", "ttys003"]

    /// The ⌃1–9 order: what the list would show for these tabs.
    private func order(_ tabs: [String: FakeTerminal.Tab]) -> [String] {
        let sessions = ["ttys003", "ttys001", "ttys002"].enumerated().map { index, tty in
            var session = Session(tty: tty, agent: .claude, pid: Int32(index + 1), startedAt: Date(timeIntervalSince1970: Double(index)),
                                  cwd: nil, project: "p", task: nil, status: .idle, statusSince: .distantPast, detail: nil,
                                  hasHooks: false, inTerminalApp: tabs[tty] != nil)
            session.screenPosition = tabs[tty]?.position
            return session
        }
        return SessionOrdering.sort(sessions).map(\.tty)
    }

    @Test func aFailedReadKeepsTheTabs() {
        let terminal = FakeTerminal()
        terminal.tabReads = [.tabs(FakeTerminal.tabs(titles)), .failed, .tabs(FakeTerminal.tabs(titles))]
        var poll = TerminalPoll<FakeTerminal.Tab>()
        var orders: [[String]] = []
        var statuses: [SessionStatus] = []
        var witness = TurnWitness()
        _ = witness.observe(tty: "ttys001", pid: 1, title: .busy)   // ttys001 was seen finishing a turn
        for tick in 0..<3 {
            poll.poll(now: Date(timeIntervalSince1970: Double(tick * 4)), interval: 4, terminalTTYs: inTerminal, quiet: [], force: false,
                      bridge: terminal.bridge)
            orders.append(order(poll.tabs))
            let title = poll.tabs["ttys001"].map { StatusRules.parseTitle($0.title).activity } ?? .none
            let seenBusy = witness.observe(tty: "ttys001", pid: 1, title: title)
            statuses.append(StatusRules.resolve(hook: nil, title: title, now: 0, seenBusy: seenBusy))
        }
        #expect(terminal.tabCalls == 3)
        // Same list order (and so the same ⌃N targets) through the failed read.
        #expect(Set(orders.map { $0.joined(separator: ",") }).count == 1)
        #expect(orders[0] == ["ttys001", "ttys002", "ttys003"])
        // No done → unknown → done flip, which would reset `since` and announce "done" again.
        #expect(statuses == [.done, .done, .done])
    }

    @Test func aTimedOutReadKeepsEveryTabsTitle() {
        let terminal = FakeTerminal()
        terminal.tabReads = [.tabs(FakeTerminal.tabs(titles)), .failed]
        var poll = TerminalPoll<FakeTerminal.Tab>()
        poll.poll(now: Date(timeIntervalSince1970: 0), interval: 4, terminalTTYs: inTerminal, quiet: [], force: false, bridge: terminal.bridge)
        poll.poll(now: Date(timeIntervalSince1970: 4), interval: 4, terminalTTYs: inTerminal, quiet: [], force: true, bridge: terminal.bridge)
        #expect(poll.tabs.mapValues(\.title) == titles)
    }

    @Test func refusedOrQuitEmptiesTheTabs() {
        for gone in [TerminalRead<FakeTerminal.Tab>.denied, .notRunning] {
            let terminal = FakeTerminal()
            terminal.tabReads = [.tabs(FakeTerminal.tabs(titles)), gone]
            var poll = TerminalPoll<FakeTerminal.Tab>()
            poll.poll(now: Date(timeIntervalSince1970: 0), interval: 4, terminalTTYs: inTerminal, quiet: [], force: false, bridge: terminal.bridge)
            poll.poll(now: Date(timeIntervalSince1970: 4), interval: 4, terminalTTYs: inTerminal, quiet: [], force: false, bridge: terminal.bridge)
            #expect(poll.tabs.isEmpty)
        }
    }

    @Test func aFailedScreenReadKeepsTheBackgroundWork() {
        let terminal = FakeTerminal()
        terminal.tabReads = [.tabs(FakeTerminal.tabs(titles)), .tabs(FakeTerminal.tabs(titles))]
        terminal.screenReads = [["ttys001": "✳ done\n\n⏵⏵ bypass permissions on · 1 shell"], nil]
        var poll = TerminalPoll<FakeTerminal.Tab>()
        poll.poll(now: Date(timeIntervalSince1970: 0), interval: 4, terminalTTYs: inTerminal, quiet: ["ttys001"], force: false, bridge: terminal.bridge)
        #expect(poll.backgroundWork == ["ttys001": "1 shell"])
        poll.poll(now: Date(timeIntervalSince1970: TerminalPoll<FakeTerminal.Tab>.screensInterval), interval: 4, terminalTTYs: inTerminal,
                  quiet: ["ttys001"], force: false, bridge: terminal.bridge)
        #expect(terminal.screenCalls == 2)
        #expect(poll.backgroundWork == ["ttys001": "1 shell"])
    }

    @Test func readsAreSpacedOut() {
        let terminal = FakeTerminal()
        var poll = TerminalPoll<FakeTerminal.Tab>()
        for tick in 0..<30 {   // 2 s scans for a minute, nothing changing
            poll.poll(now: Date(timeIntervalSince1970: Double(tick * 2)), terminalTTYs: inTerminal, quiet: ["ttys001"], force: false,
                      bridge: terminal.bridge)
        }
        #expect(terminal.tabCalls == 3)   // 0, 20, 40 s
        #expect(terminal.screenCalls == 1)
    }

    @Test func theQuietSessionsChangingReadsTheirScreens() {
        let terminal = FakeTerminal()
        var poll = TerminalPoll<FakeTerminal.Tab>()
        poll.poll(now: Date(timeIntervalSince1970: 0), terminalTTYs: inTerminal, quiet: [], force: false, bridge: terminal.bridge)
        // ttys001's turn ended: its footer is read at the next scan, not a minute later.
        poll.poll(now: Date(timeIntervalSince1970: 2), terminalTTYs: inTerminal, quiet: ["ttys001"], force: false, bridge: terminal.bridge)
        #expect(terminal.screenCalls == 1)
        #expect(terminal.tabCalls == 1)
    }
}

struct TerminalPollingCostTests {
    private typealias Poll = TerminalPoll<FakeTerminal.Tab>

    /// A Claude session in a Terminal.app tab (Terminal → login → zsh → claude), with what its hook last said.
    private static func session(_ tty: String, pid: Int32 = 500, event: String? = "Stop", inTerminal: Bool = true) -> RawSession {
        RawSession(tty: tty, agent: .claude, pid: pid, startedAt: Date(timeIntervalSince1970: 0), cwd: nil, project: "p",
                   projectRoot: nil, hook: event.map { HookState(agent: .claude, tty: tty, lastEvent: $0, lastEventAt: 1) },
                   backgroundJobs: [], inTerminalApp: inTerminal)
    }

    /// `osascript` runs over two minutes of 2 s scans with three quiet Claude sessions.
    private func spawns(terminalTTYs: Set<String>, interval: TimeInterval = Poll.fallback) -> Int {
        let terminal = FakeTerminal()
        var poll = Poll()
        let signal = TerminalSignal(sessions: terminalTTYs.map { Self.session($0) }, terminalActive: false, frontWindow: nil)
        for tick in 0..<60 {
            terminal.tabReads.append(.tabs([:]))
            terminal.screenReads.append([:])
            poll.poll(now: Date(timeIntervalSince1970: Double(tick * 2)), interval: interval, terminalTTYs: terminalTTYs,
                      quiet: ["ttys010", "ttys011", "ttys012"], signal: signal, force: false, bridge: terminal.bridge)
        }
        return terminal.tabCalls + terminal.screenCalls
    }

    /// Reads (tabs and screens) made by 0.5 s scans until `end`, the signal given by `signal(t)`; the times they were made at.
    private func reads(until end: Double, quiet: Set<String> = ["ttys010"], signal: (Double) -> TerminalSignal) -> [Double] {
        let terminal = FakeTerminal()
        var poll = Poll()
        var times: [Double] = []
        for tick in 0..<Int(end * 2) {
            let t = Double(tick) / 2
            let before = terminal.tabCalls + terminal.screenCalls
            terminal.tabReads.append(.tabs([:]))
            terminal.screenReads.append([:])
            poll.poll(now: Date(timeIntervalSince1970: t), terminalTTYs: ["ttys010"], quiet: quiet, signal: signal(t), force: false,
                      bridge: terminal.bridge)
            if terminal.tabCalls + terminal.screenCalls > before { times.append(t) }
        }
        return times
    }

    @Test func onlyWindowSessionsNeverAskTerminal() {
        // Before the gate: 45 with Terminal in the background, 80 with it in front.
        #expect(spawns(terminalTTYs: [], interval: 4) == 0)
        #expect(spawns(terminalTTYs: [], interval: 1.5) == 0)
    }

    @Test func switchingAppsDoesNotAskTerminalEither() {
        // Activating any app forces a read.
        let terminal = FakeTerminal()
        var poll = Poll()
        poll.poll(now: Date(), interval: 4, terminalTTYs: [], quiet: ["ttys010"], force: true, bridge: terminal.bridge)
        #expect(terminal.tabCalls + terminal.screenCalls == 0)
    }

    @Test func aQuietTerminalSessionIsReadAtMostEightTimesInTwoMinutes() {
        // Before (a read every 4 s, its screen every 8): 45, one osascript each.
        #expect(Poll.fallback >= 15)
        #expect(spawns(terminalTTYs: ["ttys010"]) <= 8)
    }

    @Test func aBusySessionsHookEventsAloneDontAskTerminal() {
        // Tool after tool: the hook changes several times a second, its status (working) doesn't.
        let events = ["PreToolUse", "PostToolUse", "UserPromptSubmit"]
        let times = reads(until: 120) { t in
            TerminalSignal(sessions: [Self.session("ttys010", event: events[Int(t * 2) % 3])], terminalActive: false, frontWindow: nil)
        }
        #expect(times.count <= 8)
    }

    @Test func aChangeIsReadWithinTwoSeconds() {
        let quiet = TerminalSignal(sessions: [Self.session("ttys010", event: "PreToolUse")], terminalActive: false, frontWindow: nil)
        let changes: [(String, TerminalSignal)] = [
            ("its turn ended", TerminalSignal(sessions: [Self.session("ttys010", event: "Stop")], terminalActive: false, frontWindow: nil)),
            ("another agent on it", TerminalSignal(sessions: [Self.session("ttys010", pid: 501, event: "PreToolUse")],
                                                   terminalActive: false, frontWindow: nil)),
            ("a new session in Terminal", TerminalSignal(sessions: [Self.session("ttys010", event: "PreToolUse"), Self.session("ttys011")],
                                                         terminalActive: false, frontWindow: nil)),
            ("Terminal activated", TerminalSignal(sessions: [Self.session("ttys010", event: "PreToolUse")], terminalActive: true, frontWindow: 7)),
        ]
        // A change long after the last read, and one just after a read (20 s: the fallback's).
        for (what, changed) in changes {
            for at in [31.0, 20.5] {
                let times = reads(until: 40) { $0 >= at ? changed : quiet }
                #expect(times.contains { $0 >= at && $0 <= at + 2 }, "\(what) at \(at) s: read at \(times)")
            }
        }
        // While Terminal is active, a tab picked there (another window in front).
        let front = { (window: Int) in
            TerminalSignal(sessions: [Self.session("ttys010", event: "PreToolUse")], terminalActive: true, frontWindow: window)
        }
        let times = reads(until: 40) { front($0 >= 31 ? 8 : 7) }
        #expect(times.contains { $0 >= 31 && $0 <= 33 }, "read at \(times)")
        // A window session's hooks, or a Terminal window moving while Terminal isn't active, say nothing about its tabs.
        let unrelated = reads(until: 40) { t in
            TerminalSignal(sessions: [Self.session("ttys010", event: "PreToolUse"),
                                      Self.session("ttys020", event: t >= 31 ? "Stop" : "PreToolUse", inTerminal: false)],
                           terminalActive: false, frontWindow: t >= 31 ? 8 : 7)
        }
        #expect(unrelated == [0, 20])
    }

    @Test func screensAreOnlyReadForTerminalSessions() {
        let terminal = FakeTerminal()
        var asked: [Set<String>] = []
        let counting = TerminalPoll<FakeTerminal.Tab>.Bridge(tabs: { .tabs([:]) }, screens: { ttys in
            asked.append(ttys)
            return terminal.bridge.screens(ttys)
        })
        var poll = Poll()
        poll.poll(now: Date(), interval: 4, terminalTTYs: ["ttys001"], quiet: ["ttys001", "ttys010"], force: true,
                  bridge: counting)
        #expect(asked == [["ttys001"]])
    }

    @Test func aTerminalTabThatChangedHandsIsDroppedOnAFailedRead() {
        // ttys002 was a Terminal tab; it closed and the host reused the tty for a window session.
        let terminal = FakeTerminal()
        terminal.tabReads = [.tabs(FakeTerminal.tabs(["ttys001": "✳ a", "ttys002": "✳ b"])), .failed]
        var poll = TerminalPoll<FakeTerminal.Tab>()
        poll.poll(now: Date(timeIntervalSince1970: 0), interval: 4, terminalTTYs: ["ttys001", "ttys002"], quiet: [],
                  force: false, bridge: terminal.bridge)
        poll.poll(now: Date(timeIntervalSince1970: 4), interval: 4, terminalTTYs: ["ttys001"], quiet: [],
                  force: false, bridge: terminal.bridge)
        #expect(Set(poll.tabs.keys) == ["ttys001"])
    }
}

/// The scanner over a fake process table and a temporary state folder (never `~/.vibeswitcher`).
final class SessionScannerTests {
    let temp = Scratch()
    private let stateDir: URL

    init() throws {
        stateDir = temp.url("scanner")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: stateDir) }

    private func proc(_ pid: Int32, _ ppid: Int32, _ comm: String, tty: String? = nil, agent: Agent? = nil,
                      start: Double = 1000) -> ProcInfo {
        ProcInfo(pid: pid, ppid: ppid, tty: tty, comm: comm, startTime: Date(timeIntervalSince1970: start), agent: agent)
    }

    /// Terminal → login → zsh → claude on ttys001; the session host → claude on ttys010.
    private var table: [Int32: ProcInfo] {
        let procs = [
            proc(730, 1, "Terminal"), proc(836, 730, "login", tty: "ttys001"), proc(840, 836, "zsh", tty: "ttys001"),
            proc(900, 840, "2.1.302", tty: "ttys001", agent: .claude),
            proc(4086, 1, "vibeswitcher-hos"), proc(950, 4086, "2.1.302", tty: "ttys010", agent: .claude),
            proc(960, 1, "iTermServer-3.5"), proc(961, 960, "zsh", tty: "ttys020"),
            proc(962, 961, "codex", tty: "ttys020", agent: .codex),
        ]
        return Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
    }

    private func scanner(_ procs: @escaping () -> [Int32: ProcInfo]?) -> SessionScanner {
        SessionScanner(processes: procs, stateDir: { [stateDir] in stateDir }, cwd: { _ in "/tmp/project" },
                       arguments: { _ in [] })
    }

    @Test func knowsWhichSessionsRunInTerminal() {
        let sessions = scanner { self.table }.scan(now: Date(timeIntervalSince1970: 2000))
        let inTerminal = Dictionary(uniqueKeysWithValues: sessions.map { ($0.tty, $0.inTerminalApp) })
        #expect(inTerminal == ["ttys001": true, "ttys010": false, "ttys020": false])
    }

    @Test func joinsHookStateAndDropsStaleFiles() throws {
        var state = HookState(agent: .claude, tty: "ttys001", lastEvent: "Stop", lastEventAt: 1500)
        state.agentPid = 900
        try state.save(to: stateDir.appendingPathComponent("ttys001.json"))
        let stale = HookState(agent: .claude, tty: "ttys009", lastEvent: "Stop", lastEventAt: 10)
        let staleURL = stateDir.appendingPathComponent("ttys009.json")
        try stale.save(to: staleURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: staleURL.path)

        let sessions = scanner { self.table }.scan()
        #expect(sessions.first { $0.tty == "ttys001" }?.hook?.lastEvent == "Stop")
        #expect(sessions.first { $0.tty == "ttys010" }?.hook == nil)
        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
    }

    @Test func aStateFileFromAnOlderProcessIsIgnored() throws {
        // Written before this Claude started on the terminal.
        try HookState(agent: .claude, tty: "ttys001", lastEvent: "Stop", lastEventAt: 500)
            .save(to: stateDir.appendingPathComponent("ttys001.json"))
        let sessions = scanner { self.table }.scan()
        #expect(sessions.first { $0.tty == "ttys001" }?.hook == nil)
    }

    @Test func theFirstAgentOnATerminalIsTheSession() {
        var procs = table
        procs[901] = proc(901, 900, "codex", tty: "ttys001", agent: .codex, start: 1200)   // `codex exec` as a tool
        let session = scanner { procs }.scan().first { $0.tty == "ttys001" }
        #expect(session?.pid == 900)
        #expect(session?.agent == .claude)
    }

    /// Kept with the time its table was read: a session missing from it had no agent then, not now (the lead's
    /// witness tells an agent that quit only from a table read a minute after the session started).
    @Test func anUnreadableProcessTableKeepsTheLastScan() {
        var readable = true
        let scanner = scanner { readable ? self.table : nil }
        #expect(scanner.readAt == nil)
        #expect(scanner.scan(now: Date(timeIntervalSince1970: 2000)).count == 3)
        #expect(scanner.readAt == Date(timeIntervalSince1970: 2000))
        readable = false
        #expect(scanner.scan(now: Date(timeIntervalSince1970: 2090)).count == 3)
        #expect(scanner.readAt == Date(timeIntervalSince1970: 2000))
    }

    /// A session whose agent's process couldn't be told in a table (mid-exec on a busy Mac) is as it was, hook state
    /// and all: unknown, not ended. Once the process is gone from a table, the session has ended.
    @Test func aSessionWhoseProcessCantBeToldIsKept() throws {
        var state = HookState(agent: .claude, tty: "ttys001", lastEvent: "Stop", lastEventAt: 1500)
        state.agentPid = 900
        let stateURL = stateDir.appendingPathComponent("ttys001.json")
        try state.save(to: stateURL)
        var procs = table
        let scanner = scanner { procs }
        let before = scanner.scan(now: Date(timeIntervalSince1970: 2000)).first { $0.tty == "ttys001" }
        #expect(before?.hook?.lastEvent == "Stop")
        #expect(scanner.undecided == Undecided())
        procs[900] = ProcInfo(pid: 900, ppid: 840, tty: "ttys001", comm: "2.1.302", startTime: Date(timeIntervalSince1970: 1000),
                              agent: nil, identityUnknown: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: stateURL.path)
        let unknown = scanner.scan(now: Date(timeIntervalSince1970: 2090))
        #expect(Set(unknown.map(\.tty)) == ["ttys001", "ttys010", "ttys020"])
        let kept = unknown.first { $0.tty == "ttys001" }
        #expect(kept?.pid == 900 && kept?.agent == .claude && kept?.hook?.lastEvent == "Stop")
        #expect(scanner.undecided.contains("ttys001") && !scanner.undecided.contains("ttys010"))
        #expect(scanner.readAt == Date(timeIntervalSince1970: 2090))
        #expect(FileManager.default.fileExists(atPath: stateURL.path))
        procs[900] = nil
        #expect(!scanner.scan().contains { $0.tty == "ttys001" })
        #expect(scanner.undecided == Undecided())
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
    }

    /// A process that couldn't be told is never a session of its own (no false agent); a terminal's hook state is
    /// kept while one is on it, and goes once that terminal is known to have no agent.
    @Test func aProcessThatCantBeToldIsNoSession() throws {
        let stateURL = stateDir.appendingPathComponent("ttys030.json")
        try HookState(agent: .codex, tty: "ttys030", lastEvent: "Stop", lastEventAt: 1500).save(to: stateURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: stateURL.path)
        var procs = table
        procs[970] = ProcInfo(pid: 970, ppid: 1, tty: "ttys030", comm: "codex", startTime: Date(timeIntervalSince1970: 1900),
                              agent: nil, identityUnknown: true)
        let scanner = scanner { procs }
        #expect(!scanner.scan().contains { $0.tty == "ttys030" })
        #expect(scanner.undecided.ttys == ["ttys030"])
        #expect(FileManager.default.fileExists(atPath: stateURL.path))
        procs[970] = proc(970, 1, "zsh", tty: "ttys030", start: 1900)
        #expect(!scanner.scan().contains { $0.tty == "ttys030" })
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
    }

    /// One whose terminal couldn't be read either could be on any terminal.
    @Test func anUnknownTerminalIsAnyTerminal() {
        var procs = table
        procs[980] = ProcInfo(pid: 980, ppid: 0, tty: nil, comm: "", startTime: .distantPast, agent: nil, identityUnknown: true)
        procs[981] = proc(981, 1, "launchd-helper")
        let undecided = Undecided(procs)
        #expect(undecided.anywhere && undecided.contains("ttys001"))
        #expect(Undecided(table) == Undecided())
    }

    /// 30 sessions, each with two background shells, among 1,500 processes (a loaded Mac's table): every session is
    /// found, with its own shells and no one else's.
    @Test func aFullTableHasEverySessionAndItsShells() {
        var procs: [Int32: ProcInfo] = [4086: proc(4086, 1, "vibeswitcher-hos")]
        var shells: [Int32: String] = [:]
        for index in 0..<30 {
            let agent = Int32(10_000 + index * 10), tty = "ttys\(100 + index)"
            procs[agent] = proc(agent, 4086, "2.1.302", tty: tty, agent: .claude, start: 1000 + Double(index))
            for job in 1...2 {
                let pid = agent + Int32(job)
                procs[pid] = proc(pid, agent, "zsh", tty: tty, start: 1500 + Double(job))
                shells[pid] = "npm run job\(index)-\(job)"
            }
            // A tool it runs, on its terminal too: not a session of its own.
            procs[agent + 5] = proc(agent + 5, agent, "git", tty: tty, start: 1600)
        }
        var filler = Int32(20_000)
        while procs.count < 1500 {
            // Shells under other programs: nobody's background jobs.
            procs[filler] = proc(filler, filler % 3 == 0 ? 4086 : 1, filler % 2 == 0 ? "zsh" : "mdworker_shared", start: 900)
            filler += 1
        }
        let scanner = SessionScanner(processes: { procs }, stateDir: { [stateDir] in stateDir }, cwd: { _ in "/tmp/project" },
                                     arguments: { process in
                                         shells[process.pid].map { ["/bin/zsh", "-c", "source /h/.claude/shell-snapshots/s.sh && eval '\($0)' < /dev/null"] }
                                             ?? (process.comm == "zsh" ? ["/bin/zsh", "-c", "source /h/.claude/shell-snapshots/s.sh && eval 'other' < /dev/null"] : [])
                                     })
        let sessions = scanner.scan(now: Date(timeIntervalSince1970: 2000))
        #expect(sessions.count == 30)
        for index in 0..<30 {
            let session = sessions.first { $0.tty == "ttys\(100 + index)" }
            #expect(session?.pid == Int32(10_000 + index * 10))
            #expect(session?.backgroundJobs.map(\.command) == ["npm run job\(index)-1", "npm run job\(index)-2"])
        }
    }
}
