import Foundation
import Testing
@testable import VibeSwitcher

/// R12: the chat bench (`--chat-bench`, see `ChatBench`) in a process of its own on a scratch home, so no other test's
/// work on this process's main thread is counted, on a small made-up transcript (Fixtures/chat-bench.jsonl: 80
/// exchanges, 240 items, 4 pages). Opened, left and opened again at the end, with and without paging back (Show earlier
/// twice), at the chat pane's width with the inspector showing and hidden, while the model
/// publishes every 20 ms and the window's chat timer ticks. On a Mac whose 1-minute load is not over load_threshold
/// each run must settle with no tick over 0.25 s; over it a run is only recorded (its stalls say how busy the Mac is).
struct ChatBenchTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/chat-bench.jsonl")
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// The lead's workflow.md (its load_threshold): this checkout's, or the one whose worktree this is.
    static let workflow: String? = {
        var candidates = [repo.appendingPathComponent(".vibeswitcher/workflow.md")]
        if repo.deletingLastPathComponent().lastPathComponent == "worktrees" {
            candidates.append(repo.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("workflow.md"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.path
    }()
    /// The chat pane in the window at its first size (1280x800, the toolbar taking 52) beside the session list (260),
    /// with the inspector (240) showing or hidden: the chat's column (at most 900) is narrower than 900, or not.
    static let panes = ["inspector": "780x748", "no inspector": "1020x748"]
    let scratch = Scratch()

    /// Runs the bench on a copy of the fixture in a scratch home with `settings`.
    func bench(_ settings: [String: String]) throws -> (status: Int32, output: String) {
        let app = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VibeSwitcher")
        #expect(FileManager.default.isExecutableFile(atPath: app.path))
        let home = scratch.url("chat-bench")
        let projects = home.appendingPathComponent(".claude/projects/bench")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let transcript = projects.appendingPathComponent("chat-bench.jsonl")
        try FileManager.default.copyItem(at: Self.fixture, to: transcript)
        let output = scratch.url("chat-bench-output")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let process = Process()
        process.executableURL = app
        process.arguments = ["--chat-bench", transcript.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["VIBESWITCHER_HOME"] = nil  // the run's own (scripts/test.sh) would come before this home
        environment["VIBESWITCHER_BENCH_WORKFLOW"] = Self.workflow
        for (key, value) in settings { environment[key] = value }
        process.environment = environment
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if ended.wait(timeout: .now() + hangGuard) == .timedOut {
            process.terminate()
            Issue.record("the bench hung")
            return (-1, (try? String(contentsOf: output, encoding: .utf8)) ?? "")
        }
        return (process.terminationStatus, try String(contentsOf: output, encoding: .utf8))
    }

    /// As scripts/chat-bench-settle.sh's bottom scenario: opened at the end, left, opened again and left alone.
    static let settle = ["VIBESWITCHER_BENCH_OPEN": "bottom", "VIBESWITCHER_BENCH_AT": "bottom", "VIBESWITCHER_BENCH_SECONDS": "8",
                         "VIBESWITCHER_BENCH_TICKS": "1", "VIBESWITCHER_BENCH_UPDATES": "1"]

    @Test(arguments: [0, 2], ["inspector", "no inspector"])
    func theChatSettlesWithoutAStall(earlier: Int, pane: String) throws {
        var settings = Self.settle
        settings["VIBESWITCHER_BENCH_SIZE"] = Self.panes[pane]
        if earlier > 0 { settings["VIBESWITCHER_BENCH_EARLIER"] = "\(earlier)" }
        let run = try bench(settings)
        print("chat bench, \(earlier) pages back, \(pane): status \(run.status)\n\(run.output)")
        #expect(run.output.contains("stall rule: "), "\(run.output)")
        // Over load_threshold at the start or the end: recorded only.
        guard !run.output.contains("is over load_threshold") else { return }
        #expect(run.status == 0, "\(run.output)")
        let verdict = run.output.split(separator: "\n").last { $0.hasPrefix("settled ") }.map(String.init) ?? ""
        #expect(!verdict.isEmpty, "\(run.output)")
        let tick = verdict.firstMatch(of: #/longest tick=([\d.]+)s/#).flatMap { Double($0.1) }
        #expect(tick != nil && tick! <= ChatBench.StallRule.limit, "longest tick: \(tick.map { "\($0)" } ?? "none") s")
        #expect(run.output.contains("\nticks: longest "), "\(run.output)")
        guard earlier > 0 else { return }
        let settles = verdict.firstMatch(of: #/earlier=(\d+) settled=\[([^\]]*)\]/#)
        #expect(settles?.1 == "\(earlier)", "\(verdict)")
        #expect(settles.map { $0.2.split(separator: ",").count } == earlier, "\(verdict)")
        // Each page laid out 60 more rows: the content grew.
        let shown = run.output.matches(of: #/page \d settled in [\d.]+s: shown=(\d+) of (\d+)/#).compactMap { Int($0.1) }
        #expect(shown == [120, 180], "\(run.output)")
    }

    @Test func aLoadedMacJudgesTicksAgainstTheFirstOpen() throws {
        var settings = Self.settle
        settings["VIBESWITCHER_BENCH_LOAD"] = "100000"
        settings["VIBESWITCHER_BENCH_EARLIER"] = "1"
        let run = try bench(settings)
        print("chat bench at a made-up load of 100000: status \(run.status)\n\(run.output)")
        #expect(run.output.contains("stall rule: the Mac's 1-minute load 100000 is over load_threshold "), "\(run.output)")
        #expect(run.output.contains("the first open's ticks are only recorded, later ones fail over 4 × its longest"), "\(run.output)")
        #expect(run.output.contains("never under 0.25s"), "\(run.output)")
    }

    @Test func aQuietMacIsStrictAndALoadedOneRelativeToTheFirstOpen() {
        let rule = ChatBench.StallRule(threshold: 24, source: "twice the 12 cores", fakeLoad: nil)
        let ticks = ChatBench.LongestTicks()
        ticks.note(5)  // up to the first beat: the app's launch, not a tick
        ticks.second = 1
        ticks.note(0.4)
        ticks.endFirstOpen()
        ticks.second = 6
        ticks.startPage(1)
        ticks.note(1.2)
        #expect(ticks.overall == 1.2 && ticks.firstOpen == 0.4)
        let quiet = rule.verdict(ticks, load: 3)
        #expect(quiet.failed)
        #expect(quiet.text == "FAIL: a tick stalled 1.20s (t=7s, page 1), over 0.25s; rule: the Mac's 1-minute load 3 is not over "
            + "load_threshold 24 (twice the 12 cores): any tick over 0.25s fails")
        let loaded = rule.verdict(ticks, load: 30.25)
        #expect(!loaded.failed, "\(loaded.text)")
        #expect(loaded.text.hasSuffix("rule: the Mac's 1-minute load 30.3 is over load_threshold 24 (twice the 12 cores): the first "
            + "open's ticks are only recorded, later ones fail over 4 × its longest (0.40s), never under 0.25s = 1.60s"), "\(loaded.text)")
        ticks.note(1.7)
        #expect(rule.verdict(ticks, load: 30).failed)
        // A first open quicker than 0.25 s doesn't make a loaded Mac stricter than a quiet one.
        #expect(ChatBench.StallRule.limit(loaded: true, firstOpen: 0.05) == 0.25)
        #expect(rule.describe(load: nil) == "the Mac's 1-minute load is unknown: any tick over 0.25s fails")
    }
}

private final class Anchor {}
