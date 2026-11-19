#if canImport(Darwin)
import Darwin
import Foundation
import Testing
@testable import VibeCore

/// The SIGPIPE probe (`EPipeProbe`) names a writer: a child run of this bundle writes once to a dead pipe, and what it
/// prints names the writing function, in its SIGPIPE issue and in the write hook's, and a merge's flake log
/// (`MergeRerun.evidence`, `evidenceLog`) keeps those lines. A child, so the SIGPIPE fails its run and not this one.
struct BrokenPipeProbeTests {
    @Test func theProbeIsInstalledOnceAndItsHandlerIsTheOneLeft() async {
        guard EPipeProbe.enabled else { return }
        #expect(EPipeProbe.installed)
        // Waits out a test's moment of ignoring SIGPIPE (HostedSessionTests), which puts the probe's handler back.
        #expect(await eventually { EPipeProbe.handlerIsTheProbes })
        // The bundle calls write (and pwrite, which a pipe refuses with ESPIPE); send and the rest go through Foundation.
        #expect(EPipeProbe.rebound.contains("write"), "\(EPipeProbe.rebound)")
    }

    @Test(.enabled(if: EPipeProbe.enabled)) func aChildRunsSIGPIPENamesItsWriterAndTheFlakeLogKeepsIt() async throws {
        // The child: this bundle, its own runner, the child's tests alone.
        let arguments = CommandLine.arguments
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = BrokenPipeProbeChild.arguments(from: Array(arguments.dropFirst()))
        var environment = ProcessInfo.processInfo.environment
        environment["VS_EPIPE_PROBE_CHILD"] = "1"
        environment.removeValue(forKey: "VS_EPIPE_DUMP")
        process.environment = environment
        process.standardOutput = out
        process.standardError = out
        try process.run()
        // A guard: a child that never ends (its writers wait at most `hangGuard` each) is ended, its output read.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2 * hangGuard) { if process.isRunning { process.terminate() } }
        let data = await offPool { out.fileHandleForReading.readDataToEndOfFile() }
        _ = await offPool { waitForEnd(process) }
        let output = String(decoding: data, as: UTF8.self)
        let issues = output.components(separatedBy: "\n").filter { $0.contains("recorded an issue") || $0.contains("EPIPE probe") || $0.contains("SIGPIPE") }
        let said = "child's exit \(process.terminationStatus), args \(process.arguments ?? []); its issue lines:\n" + quoted(issues)
        // It ran both writers, and its run failed on their SIGPIPEs.
        // Each check of the child's output a Bool of its own: a failed #expect prints its subexpressions, and the
        // child's lines ("✘ Test … recorded an issue") must never reach this run's output unquoted.
        let ranThreadWriter = output.contains("Test aWriterOnAThreadOfItsOwn() passed") || output.contains("aWriterOnAThreadOfItsOwn() recorded")
        #expect(ranThreadWriter, "\(said)")
        #expect(process.terminationStatus != 0, "\(said)")
        let writer = "BrokenPipeProbeChild.deadPipesWriter"
        // The SIGPIPE issue, from the handler's snapshot: the writer's thread, at the writer, in the issue's own lines.
        let lines = output.components(separatedBy: "\n")
        // Each signal's (one a writer), the last with no signal context (`aWriterAfterTheHandlerWasPutBackWithSignal`).
        let blocks = lines.indices.filter { lines[$0].contains("↳ SIGPIPE: a write to a pipe") }
            .map { Array(lines[$0..<min(lines.count, $0 + 2 + EPipeProbe.frameLines)]) }
        let sigpipeLines = blocks.first ?? []
        #expect(blocks.count >= 3, "\(said)")
        for block in blocks {
            let snapshot = block.contains { $0.contains("Writer in the probe's snapshot") }, named = block.contains { $0.contains(writer) }
            #expect(snapshot, "\(quoted(block))")
            #expect(named, "\(quoted(block))")
        }
        let noContext = blocks.contains { $0.contains { $0.contains("aWriterAfterTheHandlerWasPutBackWithSignal") } }
        #expect(noContext, "\(said)")
        // The hook's issue, from the writer's own thread: the call, the descriptor and the writer.
        let hooked = output.contains("EPIPE probe: write(fd "), onAPipe = output.contains("a pipe) failed with EPIPE")
        #expect(hooked, "\(said)")
        #expect(onAPipe, "\(said)")
        // The writer in a test's task: its issue is that test's.
        let inItsTest = output.contains("in test aWriterInTheTestsOwnTask()")
        #expect(inItsTest, "\(said)")
        // A merge's flake log keeps the writer: the tests its failing run names, each one's lines.
        let flakes = MergeRerun.flakes(in: output)
        let evidence = MergeRerun.evidence(in: output, tests: flakes)
        let log = MergeRerun.evidenceLog(task: "probe", commit: "0123456789abcdef", evidence: evidence, tests: flakes)
        let logLines = log.components(separatedBy: "\n")
        let logSnapshot = logLines.contains { $0.contains("Writer in the probe's snapshot") }
        let logNames = logLines.filter { $0.contains(writer) }.count
        let testNames = evidence["aWriterInTheTestsOwnTask()"]?.contains { $0.contains(writer) } == true
        // Demangled: no mangled Swift or C++ name ($s…, _ZN…) left for a secret's mask to cut.
        let mangled = logLines.contains { $0.contains("$s") || $0.contains("_ZN") || $0.contains("_ZL") }
        #expect(logSnapshot, "\(quoted(logLines))")
        #expect(logNames >= 3, "flakes \(flakes):\n\(quoted(logLines))\n\n\(said)")
        #expect(testNames, "\(quoted(logLines))")
        #expect(!mangled, "\(quoted(logLines))")
        // Only when asked (VS_EPIPE_SHOW=1): quoted, but a passing run's output stays free of the child's lines.
        if ProcessInfo.processInfo.environment["VS_EPIPE_SHOW"] == "1" {
            print("BrokenPipeProbeTests: the child's SIGPIPE issue:\n" + quoted(sigpipeLines)
                  + "\nand its flake log, as a merge would write it:\n" + quoted(logLines))
        }
    }

    /// The child's lines, each marked as its: never a line of this run's own ("✘ Test … recorded an issue" at its
    /// start would be read as this run's failure by whatever reads its output, a merge's flake check too).
    func quoted(_ lines: [String]) -> String {
        lines.map { "child| " + $0 }.joined(separator: "\n")
    }
}

/// The child's writers: each writes once to a pipe whose reader has gone, unguarded, and waits until the probe has
/// taken its snapshot (so the snapshot finds it in its function) and the run has recorded the SIGPIPE issue.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VS_EPIPE_PROBE_CHILD"] == "1"))
struct BrokenPipeProbeChild {
    /// The runner's arguments for a run of this suite alone: its `--filter`s replaced.
    static func arguments(from parent: [String]) -> [String] {
        var kept: [String] = [], skip = false
        for argument in parent {
            if skip { skip = false; continue }
            if argument == "--filter" || argument == "--skip" { skip = true; continue }
            if argument.hasPrefix("--filter=") || argument.hasPrefix("--skip=") { continue }
            kept.append(argument)
        }
        return kept + ["--filter", "BrokenPipeProbeChild"]
    }

    /// One write to a dead pipe, then waits (a guard, `hangGuard`) for the probe's snapshot of it and its SIGPIPE
    /// issue. Never inlined: its name is what the probe must print.
    @inline(never)
    static func deadPipesWriter(snapshots: Int, reports: Int) {
        var pair: [Int32] = [-1, -1]
        guard pipe(&pair) == 0 else { return }
        close(pair[0])
        _ = Darwin.write(pair[1], "x", 1)
        let deadline = MacTime.real.awake() + hangGuard
        while EPipeProbe.Snapshot.total <= snapshots || EPipeProbe.counts.withLock({ EPipeProbe.reported }) <= reports,
              MacTime.real.awake() < deadline {
            usleep(1_000)
        }
        close(pair[1])
    }

    static var before: (snapshots: Int, reports: Int) {
        (EPipeProbe.Snapshot.total, EPipeProbe.counts.withLock { EPipeProbe.reported })
    }

    @Test func aWriterOnAThreadOfItsOwn() async {
        let (snapshots, reports) = Self.before
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                Self.deadPipesWriter(snapshots: snapshots, reports: reports)
                done.resume()
            }
        }
    }

    @Test func aWriterInTheTestsOwnTask() {
        let (snapshots, reports) = Self.before
        Self.deadPipesWriter(snapshots: snapshots, reports: reports)
    }

    /// SIGPIPE's handler put back with signal(), which drops SA_SIGINFO: the handler then has no signal context (its
    /// own thread's frames are taken with backtrace instead), and doesn't crash reading one; the writer is still named.
    @Test func aWriterAfterTheHandlerWasPutBackWithSignal() async {
        let old = signal(SIGPIPE, SIG_IGN)
        signal(SIGPIPE, old)
        defer { EPipeProbe.armHandler() }
        let (snapshots, reports) = Self.before
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                Self.deadPipesWriter(snapshots: snapshots, reports: reports)
                done.resume()
            }
        }
    }
}
#endif
