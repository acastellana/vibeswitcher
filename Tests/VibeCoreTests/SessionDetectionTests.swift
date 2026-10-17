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
            poll.poll(now: Date(timeIntervalSince1970: Double(tick * 4)), interval: 4, quiet: [], force: false,
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
        poll.poll(now: Date(timeIntervalSince1970: 0), interval: 4, quiet: [], force: false, bridge: terminal.bridge)
        poll.poll(now: Date(timeIntervalSince1970: 4), interval: 4, quiet: [], force: true, bridge: terminal.bridge)
        #expect(poll.tabs.mapValues(\.title) == titles)
    }

    @Test func refusedOrQuitEmptiesTheTabs() {
        for gone in [TerminalRead<FakeTerminal.Tab>.denied, .notRunning] {
            let terminal = FakeTerminal()
            terminal.tabReads = [.tabs(FakeTerminal.tabs(titles)), gone]
            var poll = TerminalPoll<FakeTerminal.Tab>()
            poll.poll(now: Date(timeIntervalSince1970: 0), interval: 4, quiet: [], force: false, bridge: terminal.bridge)
            poll.poll(now: Date(timeIntervalSince1970: 4), interval: 4, quiet: [], force: false, bridge: terminal.bridge)
            #expect(poll.tabs.isEmpty)
        }
    }

    @Test func aFailedScreenReadKeepsTheBackgroundWork() {
        let terminal = FakeTerminal()
        terminal.tabReads = [.tabs(FakeTerminal.tabs(titles)), .tabs(FakeTerminal.tabs(titles))]
        terminal.screenReads = [["ttys001": "✳ done\n\n⏵⏵ bypass permissions on · 1 shell"], nil]
        var poll = TerminalPoll<FakeTerminal.Tab>()
        poll.poll(now: Date(timeIntervalSince1970: 0), interval: 4, quiet: ["ttys001"], force: false, bridge: terminal.bridge)
        #expect(poll.backgroundWork == ["ttys001": "1 shell"])
        poll.poll(now: Date(timeIntervalSince1970: 8), interval: 4, quiet: ["ttys001"], force: false, bridge: terminal.bridge)
        #expect(terminal.screenCalls == 2)
        #expect(poll.backgroundWork == ["ttys001": "1 shell"])
    }

    @Test func readsAreSpacedOut() {
        let terminal = FakeTerminal()
        var poll = TerminalPoll<FakeTerminal.Tab>()
        for tick in 0..<10 {   // 2 s scans for 20 s
            poll.poll(now: Date(timeIntervalSince1970: Double(tick * 2)), interval: 4, quiet: ["ttys001"], force: false,
                      bridge: terminal.bridge)
        }
        #expect(terminal.tabCalls == 5)
        #expect(terminal.screenCalls == 3)
    }
}
