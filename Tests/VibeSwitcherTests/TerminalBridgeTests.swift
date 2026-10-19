import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The runner the Terminal reads go through, on stand-in scripts: nothing here talks to Terminal.app. One test at a time:
/// runners share one queue, and these time it.
@Suite(.serialized)
struct AppleScriptRunnerTests {
    private let standIn = """
    on slow(started, secs)
        mark(started)
        delay secs
        return {"late"}
    end slow

    on quick(a, n)
        return {a, (n as text)}
    end quick

    on spin(started, secs)
        mark(started)
        repeat
        end repeat
    end spin

    on aNumber()
        return 1
    end aNumber

    on fails()
        error "no" number -1743
    end fails

    on mark(path)
        close access (open for access (POSIX file path) with write permission)
        return {"marked"}
    end mark

    on holdUntil(held, release)
        mark(held)
        repeat
            try
                POSIX file release as alias
                return {"released"}
            end try
            delay 0.02
        end repeat
    end holdUntil
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
    /// not after it. The deadline is counted from the call, on the caller's thread, so that's where it's timed from: a
    /// cancel at the deadline comes in under the timeout and the grace, a run left to the caller's guard at both. The
    /// hung one marks its start, so it's a running script that's cancelled, not one given up on in the queue.
    @Test func aHungScriptDoesntHoldUpTheNextRead() throws {
        let runner = AppleScriptRunner(source: standIn)
        let folder = scratchRoot.appendingPathComponent("applescript-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Untimed, first: the compile, and the first file a script writes in this process (StandardAdditions' file
        // commands load on first use, 1 s and more under load, and nothing cancels a run while they do).
        #expect(runner.run("mark", [.string(folder.appendingPathComponent("warm").path)], timeout: 10) == .strings(["marked"]))
        for hang in ["slow", "spin"] {
            let started = folder.appendingPathComponent(hang)
            var start = Date()
            #expect(runner.run(hang, [.string(started.path), .seconds(30)], timeout: 0.5) == .timedOut)
            let took = seconds(since: start)
            #expect(took < 0.5 + AppleScriptRunner.cancelGrace, "\(hang) came back in \(took) s")
            let startedAt = try #require(FileManager.default.attributesOfItem(atPath: started.path)[.modificationDate] as? Date)
            #expect(startedAt < start.addingTimeInterval(0.5), "\(hang) started \(startedAt.timeIntervalSince(start)) s in")
            start = Date()
            #expect(runner.run("quick", [.string("next"), .seconds(1)], timeout: 2) == .strings(["next", "1"]))
            // At once: the hung one would have gone on for 30 s.
            #expect(seconds(since: start) < 2)
        }
        // Cancelled, not failed: the script stays compiled.
        #expect(runner.compiles == 1)
    }

    /// A read asked for while another hangs waits at most its own timeout, and isn't run once that's passed. The order
    /// is set by events, not by how soon a loaded Mac starts each task: the hung one says when it has the queue (a mark
    /// file) and holds it until the test lets it go, which is after the read behind it has given up, so that read
    /// coming back at all means it didn't wait for the hung one. Its wait is timed on its own thread from its call, as
    /// its deadline is, so the task's start isn't counted.
    @Test func aReadBehindAHungOneWaitsNoLongerThanItsTimeout() async throws {
        let runner = AppleScriptRunner(source: standIn)
        let folder = scratchRoot.appendingPathComponent("applescript-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let held = folder.appendingPathComponent("held"), release = folder.appendingPathComponent("release")
        let ranBehind = folder.appendingPathComponent("ran-behind")
        let hung = Task.detached { runner.run("holdUntil", [.string(held.path), .string(release.path)], timeout: 30) }
        #expect(await until { FileManager.default.fileExists(atPath: held.path) })
        let (behind, waited) = await Task.detached { () -> (AppleScriptRunner.Outcome, TimeInterval) in
            let called = Date()
            let outcome = runner.run("mark", [.string(ranBehind.path)], timeout: 0.5)
            return (outcome, Date().timeIntervalSince(called))
        }.value
        #expect(behind == .timedOut)
        // Its own timeout and the grace, on its own clock, and the semaphore's wake-up on a loaded Mac.
        #expect(waited < 0.5 + AppleScriptRunner.cancelGrace + 0.5, "the read behind waited \(waited) s")
        FileManager.default.createFile(atPath: release.path, contents: nil)
        #expect(await hung.value == .strings(["released"]))
        let after = Date()
        #expect(runner.run("quick", [.string("after"), .seconds(1)], timeout: 2) == .strings(["after", "1"]))
        #expect(seconds(since: after) < 2)
        // Queued before this one, and given up, it wasn't run once the queue was free.
        #expect(!FileManager.default.fileExists(atPath: ranBehind.path))
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
