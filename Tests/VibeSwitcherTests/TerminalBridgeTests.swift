import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The runner the Terminal reads go through, on stand-in scripts: nothing here talks to Terminal.app. One test at a time:
/// runners share one queue, and these time it.
@Suite(.serialized)
struct AppleScriptRunnerTests {
    private let standIn = """
    on slow(secs)
        delay secs
        return {"late"}
    end slow

    on quick(a, n)
        return {a, (n as text)}
    end quick

    on spin(secs)
        repeat
        end repeat
    end spin

    on aNumber()
        return 1
    end aNumber

    on fails()
        error "no" number -1743
    end fails
    """

    private func seconds(since start: Date) -> TimeInterval { Date().timeIntervalSince(start) }

    @Test func handlersGetTheirArgumentsAndGiveTheirStrings() {
        let runner = AppleScriptRunner(source: standIn)
        #expect(runner.run("quick", [.string("a \"quoted\"\nline"), .seconds(4)], timeout: 10) == .strings(["a \"quoted\"\nline", "4"]))
        #expect(runner.run("aNumber", timeout: 10) == .unexpected)
        guard case .failed(let code, _) = runner.run("fails", timeout: 10) else { Issue.record("not a failure"); return }
        #expect(code == -1743)
    }

    @Test func theScriptIsCompiledOnceForEveryRun() {
        let runner = AppleScriptRunner(source: standIn)
        for index in 0..<5 { #expect(runner.run("quick", [.string("\(index)"), .seconds(1)], timeout: 10) == .strings(["\(index)", "1"])) }
        #expect(runner.runs == 5)
        #expect(runner.compiles == 1)
    }

    @Test func aScriptThatDoesntCompileFails() {
        let runner = AppleScriptRunner(source: "on broken(\n")
        guard case .failed = runner.run("broken", timeout: 10) else { Issue.record("compiled"); return }
    }

    /// A script that hangs (here: sleeps, or loops, for good) is cancelled at its timeout, and the next read runs at once,
    /// not after it.
    @Test func aHungScriptDoesntHoldUpTheNextRead() {
        let runner = AppleScriptRunner(source: standIn)
        #expect(runner.run("quick", [.string("warm"), .seconds(0)], timeout: 10) == .strings(["warm", "0"]))
        for hang in ["slow", "spin"] {
            var start = Date()
            #expect(runner.run(hang, [.seconds(30)], timeout: 0.5) == .timedOut)
            #expect(seconds(since: start) < 0.5 + AppleScriptRunner.cancelGrace)
            start = Date()
            #expect(runner.run("quick", [.string("next"), .seconds(1)], timeout: 2) == .strings(["next", "1"]))
            // At once: the hung one would have gone on for 30 s.
            #expect(seconds(since: start) < 2)
        }
        // Cancelled, not failed: the script stays compiled.
        #expect(runner.compiles == 1)
    }

    /// A read asked for while another hangs waits at most its own timeout, and isn't run once that's passed.
    @Test func aReadBehindAHungOneWaitsNoLongerThanItsTimeout() async {
        let runner = AppleScriptRunner(source: standIn)
        let hung = Task.detached { runner.run("slow", [.seconds(30)], timeout: 3) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        let behind = await Task.detached { runner.run("quick", [.string("behind"), .seconds(1)], timeout: 0.5) }.value
        #expect(behind == .timedOut)
        #expect(seconds(since: start) < 0.5 + AppleScriptRunner.cancelGrace + 1)
        #expect(await hung.value == .timedOut)
        let after = Date()
        #expect(runner.run("quick", [.string("after"), .seconds(1)], timeout: 2) == .strings(["after", "1"]))
        #expect(seconds(since: after) < 2)
    }

    /// The real reads compile. Only a handler they don't have is called, so nothing runs and Terminal is never asked.
    @Test func terminalsReadsCompile() {
        let runner = AppleScriptRunner(source: TerminalBridge.readScript)
        let outcome = runner.run("notOneOfTheReads", timeout: 10)
        guard case .failed(let code, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(code == -1708, "\(outcome)")   // doesn't understand the message: compiled, and nothing ran
        #expect(runner.compiles == 1)
    }
}

/// The store reads Terminal through a stand-in bridge here: when a session in Terminal changes, and otherwise rarely.
@MainActor
struct TerminalReadsTests {
    private let stateDir = scratchRoot.appendingPathComponent("terminal-reads-\(UUID().uuidString)")

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private func proc(_ pid: Int32, _ ppid: Int32, _ comm: String, tty: String? = nil, agent: Agent? = nil, start: Date) -> ProcInfo {
        ProcInfo(pid: pid, ppid: ppid, tty: tty, comm: comm, startTime: start, agent: agent)
    }

    /// Terminal → login → zsh → claude on `tty`.
    private func terminalSession(_ tty: String, base: Int32, start: Date) -> [ProcInfo] {
        [proc(base, 730, "login", tty: tty, start: start), proc(base + 1, base, "zsh", tty: tty, start: start),
         proc(base + 2, base + 1, "claude", tty: tty, agent: .claude, start: start)]
    }

    private func saveHook(_ event: String, tty: String, pid: Int32, at time: Date) throws {
        var state = HookState(agent: .claude, tty: tty, lastEvent: event, lastEventAt: time.timeIntervalSince1970)
        state.agentPid = pid
        try state.save(to: stateDir.appendingPathComponent("\(tty).json"))
    }

    private func refreshAndSettle(_ store: SessionStore) async {
        let before = store.scansApplied
        store.refresh()
        #expect(await until { store.scansApplied > before })
    }

    @Test func aQuietTerminalSessionIsReadRarelyAndAChangeAtOnce() async throws {
        AppStatus.enabled = false
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let time = Box(Date())
        let start = time.value.addingTimeInterval(-3600)
        let table = Box([proc(730, 1, "Terminal", start: start)] + terminalSession("ttys980", base: 840, start: start))
        try saveHook("Stop", tty: "ttys980", pid: 842, at: start.addingTimeInterval(60))
        let reads = Box(0)
        let bridge = TerminalPoll<TerminalTab>.Bridge(tabs: {
            reads.value += 1
            return .tabs(["ttys980": TerminalTab(windowID: 1, title: "✳ Fix it", position: nil, isSelected: true, windowOrder: 1)])
        }, screens: { ttys in
            guard !ttys.isEmpty else { return [:] }
            reads.value += 1
            return [:]
        })
        let dir = stateDir
        let store = SessionStore(scanner: SessionScanner(processes: { Dictionary(uniqueKeysWithValues: table.value.map { ($0.pid, $0) }) },
                                                         stateDir: { dir }, cwd: { _ in "/tmp/terminal-reads" }, arguments: { _ in [] }),
                                 bridge: bridge)
        store.clock = { time.value }
        store.terminalFront = { (false, nil) }

        // Two minutes of 2 s scans with nothing changing. Before: 45 reads, an osascript each.
        for _ in 0..<60 {
            await refreshAndSettle(store)
            time.value += 2
        }
        #expect(store.sessions.map(\.tty) == ["ttys980"])
        #expect(store.sessions.first?.task == "Fix it")
        #expect(reads.value <= 8)

        // Its hook says something new (a new turn): read at the next scan.
        var before = reads.value
        try saveHook("UserPromptSubmit", tty: "ttys980", pid: 842, at: time.value)
        await refreshAndSettle(store)
        #expect(reads.value > before)

        // Another session starts in Terminal (the process table): read at the next 2 s scan.
        time.value += 2
        await refreshAndSettle(store)
        before = reads.value
        table.value += terminalSession("ttys981", base: 850, start: time.value)
        time.value += 2
        await refreshAndSettle(store)
        #expect(reads.value > before)
        #expect(Set(store.sessions.map(\.tty)) == ["ttys980", "ttys981"])
    }
}
