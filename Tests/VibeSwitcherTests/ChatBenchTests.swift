import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// R12: the chat bench (`--chat-bench`, see `ChatBench`) in a process of its own on a scratch home, so no other test's
/// work on this process's main thread is counted, on a small made-up transcript (Fixtures/chat-bench.jsonl: 80
/// exchanges, 240 items, 4 pages). Opened, left and opened again at the end, with and without paging back (Show earlier
/// twice), at the chat pane's width with the inspector showing and hidden, while the model
/// publishes every 20 ms and the window's chat timer ticks. On a Mac whose 1-minute load is not over load_threshold
/// each run must settle with no tick over 0.25 s, its pages filling in below the fold without moving what's on screen;
/// over it a run is only recorded (its stalls say how busy the Mac is).
/// One run at a time: five at once made each other's load. The runs judged on their ticks and settle (the stall and
/// reopen cases) are benches, run only by `scripts/test.sh --perf` (`Tag.perf`); the rule's own tests run in every run.
@Suite(.serialized)
struct ChatBenchTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/chat-bench.jsonl")
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// The Mac-wide limits (their load_threshold) as Settings › Project lead keeps them for the account, when set.
    static let limits: String? = {
        let file = URL(fileURLWithPath: VibePaths.accountHome).appendingPathComponent(".vibeswitcher/mac-limits.json")
        return FileManager.default.fileExists(atPath: file.path) ? file.path : nil
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
        environment["VIBESWITCHER_BENCH_LIMITS"] = Self.limits
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

    @Test(.tags(.perf), .enabled(if: perfRun, perfOnly), arguments: [0, 2], ["inspector", "no inspector"])
    func theChatSettlesWithoutAStall(earlier: Int, pane: String) throws {
        var settings = Self.settle
        settings["VIBESWITCHER_BENCH_SIZE"] = Self.panes[pane]
        if earlier > 0 { settings["VIBESWITCHER_BENCH_EARLIER"] = "\(earlier)" }
        var run = try bench(settings)
        print("chat bench, \(earlier) pages back, \(pane): status \(run.status)\n\(run.output)")
        #expect(run.output.contains("stall rule: "), "\(run.output)")
        // Over load_threshold at the start or the end: recorded only.
        guard !run.output.contains("is over load_threshold") else { return }
        // Under it the Mac can still keep the bench off a core for a while (2026-10-19 at load 17 on 12 cores: a 0.94 s
        // tick, 0.25 s of it on the CPU): one more run, and if the Mac starves that one too it's recorded only.
        if Self.starved(run) {
            run = try bench(settings)
            print("chat bench again, the first run starved: status \(run.status)\n\(run.output)")
            guard !run.output.contains("is over load_threshold"), !Self.starved(run) else { return }
        }
        let verdict = run.output.split(separator: "\n").last { $0.hasPrefix("settled ") }.map(String.init) ?? ""
        #expect(!verdict.isEmpty, "\(run.output)")
        #expect(run.status == 0, "\(run.output)")
        let tick = verdict.firstMatch(of: #/longest tick=([\d.]+)s/#).flatMap { Double($0.1) }
        #expect(tick != nil && tick! <= ChatBench.StallRule.limit, "longest tick: \(tick.map { "\($0)" } ?? "none") s")
        #expect(run.output.contains("\nticks: longest "), "\(run.output)")
        // And the tick the main thread worked the most in, which a longer one it waited through mustn't hide: one at least
        // carried a CPU reading (it has a place).
        let cpu = run.output.firstMatch(of: #/\nticks: longest .*, most CPU ([\d.]+)s \(t=\d+s, /#).flatMap { Double($0.1) }
        #expect(cpu != nil && cpu! <= ChatBench.StallRule.limit, "most CPU in a tick: \(cpu.map { "\($0)" } ?? "none") s\n\(run.output)")
        // Opened out of sight a staging batch of rows a turn, then shown (twice: opened, left, opened again).
        #expect(run.output.matches(of: #/laid out out of sight in (\d+) turns, then shown/#).compactMap { Int($0.1) } == [Self.turns, Self.turns],
                "\(run.output)")
        guard earlier > 0 else { return }
        let settles = verdict.firstMatch(of: #/earlier=(\d+) settled=\[([^\]]*)\]/#)
        #expect(settles?.1 == "\(earlier)", "\(verdict)")
        #expect(settles.map { $0.2.split(separator: ",").count } == earlier, "\(verdict)")
        // Each page laid out 60 more rows: the content grew.
        let shown = run.output.matches(of: #/page \d settled in [\d.]+s: shown=(\d+) of (\d+)/#).compactMap { Int($0.1) }
        #expect(shown == [120, 180], "\(run.output)")
        for page in Self.pages(run.output) {
            #expect(page.turns == Self.turns, "page \(page.number): \(page.turns) turns\n\(run.output)")
            // Filling in below the fold: what's at the top of the view and where the view is don't move.
            #expect(!page.fillingIn.isEmpty, "page \(page.number)\n\(run.output)")
            #expect(Set(page.fillingIn.map(\.first)) == [page.first], "page \(page.number) moved\n\(run.output)")
            #expect(Set(page.fillingIn.map(\.top)).count == 1, "page \(page.number) moved\n\(run.output)")
            #expect(page.fillingIn.map(\.height) == page.fillingIn.map(\.height).sorted(), "page \(page.number)\n\(run.output)")
        }
    }

    /// The turns a page (or an open) takes to lay out: a batch of rows a turn (`ChatStaging.batch`), the first at once.
    static let turns = Int((Double(ChatWindow.page) / Double(ChatStaging.batch)).rounded(.up))

    /// As scripts/chat-bench-settle.sh's top and middle scenarios: read there once opened, left, opened again where it
    /// was read and scrolled there. The bench reads only once the open is laid out and the view has put it where it
    /// opens: scrolled while the open was still out of sight, the view's initial scroll moved it back to the end, the
    /// reopen restored a place never read at and the runs settled at two heights (2026-10-20, middle at 1200: 15716 and
    /// 15558). Whatever the Mac's load, the rows the first open showed take the same height opened again: from the first
    /// one's top to the end. Read at the top, the reopen shows 5 rows more above it (`ChatWindow.shown`'s context); in
    /// the middle the same rows, so the same height.
    @Test(.tags(.perf), .enabled(if: perfRun, perfOnly), arguments: ["top", "middle"])
    func aReopenSettlesAtTheFirstOpensHeight(position: String) throws {
        var settings = Self.settle
        settings["VIBESWITCHER_BENCH_OPEN"] = position
        settings["VIBESWITCHER_BENCH_AT"] = position
        settings["VIBESWITCHER_BENCH_SIZE"] = Self.panes["no inspector"]
        let run = try bench(settings)
        print("chat bench, read at the \(position): status \(run.status)\n\(run.output)")
        let lines = run.output.split(separator: "\n").map(String.init)
        // Read once shown, not before.
        let shown = lines.firstIndex { $0.contains("laid out out of sight in ") }
        let read = lines.firstIndex { $0.hasPrefix("  read at t=") }
        #expect(shown != nil && read != nil && shown! < read!, "\(run.output)")
        #expect(lines.last { $0.hasPrefix("settled ") } != nil, "\(run.output)")
        let left = run.output.firstMatch(of: #/left at height=(\d+) below (\S+)=(\d+)/#)
        let again = run.output.firstMatch(of: #/opened again at height=(\d+) below (\S+)=(\d+)/#)
        #expect(left != nil && left?.2 == again?.2 && left?.3 == again?.3, "\(run.output)")
        if position == "middle" { #expect(left != nil && left?.1 == again?.1, "\(run.output)") }
    }

    /// Each page of a run: the bench's "filling in" lines between Show earlier and its settle, the row at the top once
    /// it had (the bench's position notes), and how many turns it took.
    static func pages(_ output: String) -> [(number: Int, fillingIn: [(height: Int, top: Int, first: String)], first: String, turns: Int)] {
        var pages: [(number: Int, fillingIn: [(height: Int, top: Int, first: String)], first: String, turns: Int)] = []
        var fillingIn: [(height: Int, top: Int, first: String)] = []
        for line in output.split(separator: "\n") {
            if line.contains(": Show "), line.contains(" earlier at t=") { fillingIn = [] }
            if let fill = line.firstMatch(of: #/filling in: height=(\d+) top=(-?\d+) first=(\S+)/#) {
                fillingIn.append((Int(fill.1) ?? 0, Int(fill.2) ?? 0, String(fill.3)))
            }
            if let settled = line.firstMatch(of: #/page (\d) settled in .* filled in over (\d+) turns/#) {
                pages.append((Int(settled.1) ?? 0, fillingIn, fillingIn.last?.first ?? "-", Int(settled.2) ?? 0))
            }
        }
        return pages
    }

    @Test func aPageFillingInIsReadFromTheBenchsLines() {
        let output = """
          page 1: Show 60 earlier at t=7s
          filling in: height=6025 top=-16 first=u40 cpu=0.05s
          filling in: height=6870 top=-16 first=u40 cpu=0.04s
          page 1 settled in 0.22s: shown=120 of 240 height=10347, longest tick 0.05s (cpu 0.05s), most CPU in a tick 0.05s, filled in over 3 turns
          page 2: Show 60 earlier at t=11s
          filling in: height=11223 top=-16 first=u20 cpu=0.05s
          filling in: height=12087 top=-40 first=u19 cpu=0.05s
          page 2 settled in 0.25s: shown=180 of 240 height=15526, longest tick 0.05s (cpu 0.05s), most CPU in a tick 0.05s, filled in over 1 turns
        """
        let pages = Self.pages(output)
        #expect(pages.map(\.number) == [1, 2])
        #expect(pages[0].fillingIn.map(\.height) == [6025, 6870] && pages[0].first == "u40" && pages[0].turns == 3)
        #expect(Set(pages[0].fillingIn.map(\.first)) == ["u40"])
        // A page whose top moved as it filled in: two rows and two places.
        #expect(Set(pages[1].fillingIn.map(\.first)).count == 2 && Set(pages[1].fillingIn.map(\.top)).count == 2 && pages[1].turns == 1)
    }

    /// A run failed on a stall whose tick the main thread spent mostly waiting for a core (under half of it on the
    /// CPU): the Mac's load, however low its 1-minute average, rather than the layout, which works on the CPU. Not when a
    /// tick also worked over the limit on the CPU (the bench's "a tick worked" line): the starved one doesn't hide it.
    static func starved(_ run: (status: Int32, output: String)) -> Bool {
        guard run.status == 4, !run.output.contains("FAIL: a tick worked "), !run.output.contains("FAIL: no tick carried a CPU reading"),
              let tick = run.output.firstMatch(of: #/FAIL: a tick stalled ([\d.]+)s \(.*, ([\d.]+)s of it on the CPU\)/#),
              let wall = Double(tick.1), let cpu = Double(tick.2) else { return false }
        return cpu < wall / 2
    }

    @Test func aStallTheMainThreadSpentWaitingForACoreIsStarvation() {
        let fail = "FAIL: a tick stalled 0.94s (t=12s, page 2, 0.25s of it on the CPU), over 0.25s; rule: the Mac's 1-minute load 17.2 is not over"
        #expect(Self.starved((4, "settled 13 s after opening\n\(fail)")))
        #expect(!Self.starved((4, fail.replacingOccurrences(of: "0.25s of it", with: "0.90s of it"))))
        #expect(!Self.starved((0, "ticks: longest 0.20s (t=1s, opening, 0.02s of it on the CPU), not over 0.25s")))
        #expect(!Self.starved((3, "FAIL: the content height still changes")))
        // The layout working through the tick, or most of it, is not starvation (2026-10-19, load 17.9: the first open's
        // 0.50 s, half of it on the CPU): it fails.
        #expect(!Self.starved((4, "FAIL: a tick stalled 0.50s (t=1s, opening, 0.25s of it on the CPU), over 0.25s")))
        #expect(!Self.starved((4, "FAIL: a tick stalled 0.33s (t=12s, page 2, 0.31s of it on the CPU), over 0.25s")))
        // A starved long tick beside one the layout worked through for 0.30 s: the layout fails.
        #expect(!Self.starved((4, """
            FAIL: a tick stalled 1.00s (t=12s, page 2, 0.10s of it on the CPU), over 0.25s; rule: the Mac's 1-minute load 9 is not over
            FAIL: a tick worked 0.30s on the CPU (t=8s, page 1, a tick of 0.40s), over 0.25s; rule: the Mac's 1-minute load 9 is not over
            """)))
    }

    /// A reopen is judged once its height could have kept still for the settle's quiet seconds since it loaded: on time,
    /// as before (8 s run, reopened at 3, loaded at 4: judged at 8); late (reopened at 5 behind a starved first open,
    /// loaded at 6), judged at 10, not at 8 with only 2 s to show it. Never waiting past 30 s more.
    @Test func aLateReopenIsGivenItsQuietSecondsBeforeItsSettleIsJudged() {
        func judgedAt(reopenedAt: Int, readyAt: Int?) -> Int? {
            (0...40).first { $0 >= 8 && !ChatBench.waitsAfterReopen(second: $0, seconds: 8, reopenedAt: reopenedAt, readyAt: readyAt) }
        }
        #expect(judgedAt(reopenedAt: 3, readyAt: 4) == 8)
        #expect(judgedAt(reopenedAt: 3, readyAt: 6) == 10)
        #expect(judgedAt(reopenedAt: 5, readyAt: 6) == 10)
        #expect(judgedAt(reopenedAt: 5, readyAt: 6).map { $0 - 6 } == ChatBench.settleQuiet + 1)
        #expect(judgedAt(reopenedAt: 3, readyAt: nil) == 38)
        #expect(!ChatBench.waitsAfterReopen(second: 7, seconds: 8, reopenedAt: 3, readyAt: nil))
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
        ticks.note(0.4, cpu: 0.05)
        ticks.endFirstOpen()
        ticks.second = 6
        ticks.startPage(1)
        ticks.note(1.2, cpu: 0.1)
        #expect(ticks.overall == 1.2 && ticks.firstOpen == 0.4)
        let quiet = rule.verdict(ticks, load: 3)
        #expect(quiet.failed)
        #expect(quiet.text == "FAIL: a tick stalled 1.20s (t=7s, page 1, 0.10s of it on the CPU), over 0.25s; rule: the Mac's 1-minute load 3 is not over "
            + "load_threshold 24 (twice the 12 cores): any tick over 0.25s fails")
        let loaded = rule.verdict(ticks, load: 30.25)
        #expect(!loaded.failed, "\(loaded.text)")
        #expect(loaded.text.hasSuffix("rule: the Mac's 1-minute load 30.3 is over load_threshold 24 (twice the 12 cores): the first "
            + "open's ticks are only recorded, later ones fail over 4 × its longest (0.40s), never under 0.25s = 1.60s"), "\(loaded.text)")
        // How much of it the main thread was on the CPU tells a layout from a wait for a core.
        ticks.note(1.7, cpu: 0.3)
        let starved = rule.verdict(ticks, load: 30)
        #expect(starved.failed)
        #expect(starved.text.hasPrefix("FAIL: a tick stalled 1.70s (t=7s, page 1, 0.30s of it on the CPU), over 1.60s;"), "\(starved.text)")
        #expect(ChatBench.LongestTicks.text(ticks.page, cpu: ticks.pageCPU) == "1.70s (cpu 0.30s)")
        // The longest tick isn't the only one judged: one the main thread worked through for longer than the limit fails
        // beside a longer one it mostly waited through, on its own line.
        let cpuHeavy = ChatBench.LongestTicks()
        cpuHeavy.note(0)
        cpuHeavy.second = 7
        cpuHeavy.note(0.4, cpu: 0.3)
        cpuHeavy.note(1.0, cpu: 0.1)
        #expect(cpuHeavy.overall == 1.0 && cpuHeavy.mostCPU == 0.3)
        let both = rule.verdict(cpuHeavy, load: 3).text.split(separator: "\n").map(String.init)
        #expect(both.count == 2, "\(both)")
        #expect(both.first?.hasPrefix("FAIL: a tick stalled 1.00s (t=8s, opening, 0.10s of it on the CPU), over 0.25s;") == true, "\(both)")
        #expect(both.last?.hasPrefix("FAIL: a tick worked 0.30s on the CPU (t=8s, opening, a tick of 0.40s), over 0.25s;") == true, "\(both)")
        #expect(!Self.starved((4, both.joined(separator: "\n"))))
        // One tick both the longest and the most worked: both lines. Under the limit it's in the ticks line.
        let worked = ChatBench.LongestTicks()
        worked.note(0)
        worked.note(0.26, cpu: 0.26)
        #expect(rule.verdict(worked, load: 3).text.split(separator: "\n").map { String($0.prefix(26)) }
            == ["FAIL: a tick stalled 0.26s", "FAIL: a tick worked 0.26s "])
        let fine = ChatBench.LongestTicks()
        fine.note(0)
        fine.note(0.24, cpu: 0.2)
        let passed = rule.verdict(fine, load: 3)
        #expect(!passed.failed && passed.text.hasPrefix("ticks: longest 0.24s (t=1s, opening, 0.20s of it on the CPU), most CPU 0.20s (t=1s, opening, a tick of 0.24s), not over 0.25s;"),
                "\(passed.text)")
        // No tick carried a CPU reading (none at all, or the main thread's CPU time unread): nothing was judged on the CPU,
        // so the run fails on its own line, quiet or loaded, and isn't starved. A first reading of 0 is a reading.
        let none = ChatBench.LongestTicks()
        let empty = rule.verdict(none, load: 3)
        #expect(empty.failed && empty.text.hasPrefix("FAIL: no tick carried a CPU reading, so none was judged on the CPU;"), "\(empty.text)")
        let unread = ChatBench.LongestTicks()
        unread.note(0)
        unread.note(0.1)
        unread.endFirstOpen()
        unread.note(0.2, cpu: nil)
        #expect(unread.mostCPUPlace.isEmpty)
        for load in [3.0, 30] {
            let verdict = rule.verdict(unread, load: load)
            #expect(verdict.failed && verdict.text.hasPrefix("FAIL: no tick carried a CPU reading, so none was judged on the CPU;")
                && !verdict.text.contains("\n"), "\(verdict.text)")
            #expect(!Self.starved((4, "FAIL: a tick stalled 1.00s (t=12s, page 2, 0.10s of it on the CPU), over 0.25s\n\(verdict.text)")))
        }
        let idle = ChatBench.LongestTicks()
        idle.note(0)
        idle.note(0.02, cpu: 0)
        #expect(!rule.verdict(idle, load: 3).failed && idle.mostCPUPlace == "t=1s, opening, a tick of 0.02s")
        // A first open quicker than 0.25 s doesn't make a loaded Mac stricter than a quiet one.
        #expect(ChatBench.StallRule.limit(loaded: true, firstOpen: 0.05) == 0.25)
        #expect(rule.describe(load: nil) == "the Mac's 1-minute load is unknown: any tick over 0.25s fails")
    }
}

private final class Anchor {}

/// scripts/chat-bench-settle.sh's verdict, on a fake build that prints what `--chat-bench` prints when a tick stalls: a
/// starved longest tick is run once more and passes as starved when that one starves too, but never beside a tick the
/// main thread worked through over the limit on the CPU. The runs start staggered, and each starved attempt is recorded
/// with why the main thread was off the CPU. Run with the benches, by `scripts/test.sh --perf` (`Tag.perf`).
@Suite(.tags(.perf), .enabled(if: perfRun, perfOnly))
struct ChatBenchSettleScriptTests {
    let scratch = Scratch()
    /// Where the script puts what the runs printed (`-o`).
    let outputs: URL

    init() { outputs = scratch.url("outputs") }

    /// The bench's clock lines (`ChatBench.clock`): "  clock 1761000000.12: page 2", in the fake builds' bash.
    static func clock(_ what: String) -> String {
        "echo \"  clock $(/usr/bin/perl -MTime::HiRes=time -e 'printf q(%.2f), time'): \(what)\""
    }

    /// A fake build: counts its runs in `runs`, opens, pages back for `paging` seconds, prints a settle and a longest tick
    /// of 1 s that ended then, `cpu` of it on the CPU (starved: under half), and after it `also` (another of the verdict's
    /// FAIL lines); exits 4 as the bench does.
    func fakeBuild(also: String? = nil, paging: Double = 0, cpu: String = "0.10", runs: URL) throws -> URL {
        let rule = "rule: the Mac's 1-minute load 3 is not over load_threshold 24 (Settings): any tick over 0.25s fails"
        return try script("""
        echo run >> '\(runs.path)'
        echo "  stall \(rule)"
        \(Self.clock("opening"))
        \(Self.clock("page 2"))
        sleep \(paging)
        echo 'settled 9 s after opening (loaded after 1 s): height=15526 heights=3 range=- layouts=1 last 3 s: 0 layouts longest tick=1.00s (cpu 0.10s)'
        \(Self.clock("the longest tick's end"))
        echo "FAIL: a tick stalled 1.00s (t=12s, page 2, \(cpu)s of it on the CPU), over 0.25s; \(rule)"
        \(also.map { "echo \"\($0); \(rule)\"" } ?? "")
        \(Self.clock("done"))
        exit 4
        """)
    }

    /// A fake build that takes `launch` seconds to open, settles and passes.
    func passingBuild(launch: Double) throws -> URL {
        try script("""
        sleep \(launch)
        \(Self.clock("opening"))
        echo 'settled 9 s after opening (loaded after 1 s): height=15526 heights=3 range=- layouts=1 last 3 s: 0 layouts longest tick=0.10s (cpu 0.08s)'
        \(Self.clock("done"))
        """)
    }

    func script(_ body: String) throws -> URL {
        let url = scratch.url("fake-chat-bench")
        try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func settle(_ build: URL, _ options: [String] = ["-n", "1", "-j", "1"]) throws -> (status: Int32, output: String) {
        let transcript = scratch.url("t.jsonl")
        FileManager.default.createFile(atPath: transcript.path, contents: Data("{}\n".utf8))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [ChatBenchTests.repo.appendingPathComponent("scripts/chat-bench-settle.sh").path] + options + ["-b", build.path,
                             "-o", outputs.path, "-w", "700", "-s", "top", "-v", "plain", transcript.path, transcript.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    func runs(_ url: URL) -> Int { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").count }

    /// When each run (every attempt) began `phase`, from their outputs' clock lines, in order: the script's launching,
    /// the bench's opening.
    func clocks(_ phase: String) throws -> [Double] {
        let out = outputs.appendingPathComponent("out")
        return try FileManager.default.contentsOfDirectory(atPath: out.path).flatMap { name in
            try String(contentsOf: out.appendingPathComponent(name), encoding: .utf8).split(separator: "\n")
                .compactMap { $0.wholeMatch(of: #/  clock ([\d.]+): (.+)/#).flatMap { $0.2 == phase ? Double($0.1) : nil } }
        }.sorted()
    }

    func gaps(_ clocks: [Double]) -> [Double] { zip(clocks.dropFirst(), clocks).map { $0 - $1 } }

    /// Started together, six runs reached the first open and page 2 in the same instant and starved six at a time
    /// (2026-10-20): each run starts STAGGER seconds after the last one did, and each line says when it opened.
    @Test func theRunsStartStaggered() throws {
        let run = try settle(try passingBuild(launch: 0), ["-n", "4", "-j", "4", "-S", "1"])
        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.matches(of: #/#\d +open at \d\d:\d\d:\d\d\.\d\d +status=0 settled/#).count == 4, "\(run.output)")
        #expect(run.output.contains("openings: 4, the closest two "), "\(run.output)")
        // The starts are the stagger apart, and a start is half of it after the last one's opening: the launch varies from
        // one run to the next (the fake's first: 0.6 s with the other tests running, the others' 0.03 s).
        let starts = try clocks("launching"), openings = try clocks("opening")
        #expect(starts.count == 4 && openings.count == 4)
        #expect(gaps(starts).allSatisfy { $0 >= 0.99 }, "\(gaps(starts))")
        #expect(gaps(openings).allSatisfy { $0 >= 0.5 }, "\(gaps(openings))")
    }

    /// And half the stagger after the last one started has opened: a launch slower than the stagger doesn't put two
    /// openings together.
    @Test func aRunStartsOnceTheLastOneOpened() throws {
        let run = try settle(try passingBuild(launch: 1.2), ["-n", "3", "-j", "3", "-S", "0.3"])
        #expect(run.status == 0, "\(run.output)")
        let openings = try clocks("opening")
        #expect(openings.count == 3)
        #expect(gaps(openings).allSatisfy { $0 >= 1.2 }, "\(gaps(openings))")
    }

    /// A starved attempt's record: its tick's wall and CPU time and its clock, the load and the threads runnable then, and
    /// how many of the other runs were opening or paging back (two runs paging for 2 s, 0.5 s apart, overlap).
    @Test func aStarvedAttemptIsRecordedWithWhyItWasOffTheCPU() throws {
        let runs = scratch.url("runs")
        let run = try settle(try fakeBuild(paging: 2, runs: runs), ["-n", "2", "-j", "2", "-S", "0.5"])
        #expect(run.status == 0, "\(run.output)")
        #expect(self.runs(runs) == 4)
        #expect(run.output.contains("starved: 2 first attempts run again, 2 recorded starved (status=starved); 0 failed on a stalled tick"), "\(run.output)")
        let record = #/top/700/plain #[12], (first attempt|second attempt too \(recorded\)), starved on page 2 at t=12 s \(\d\d:\d\d:\d\d\.\d\d\): 1\.00 s with 0\.10 s CPU, at load [\d.]+, \d+ threads runnable; (\d) other runs? opening or paging/#
        let records = run.output.matches(of: record)
        #expect(records.count == 4, "\(run.output)")
        #expect(run.output.contains("1 other run opening or paging (page 2 ×1)"), "\(run.output)")
        let file = try String(contentsOf: outputs.appendingPathComponent("starved.txt"), encoding: .utf8)
        #expect(file.matches(of: record).count == 4, "\(file)")
        // The sampler's lines: the clock, the 1-minute load and the threads runnable.
        let load = try String(contentsOf: outputs.appendingPathComponent("load.txt"), encoding: .utf8)
        #expect(load.split(separator: "\n").first?.wholeMatch(of: #/[\d.]+ [\d.]+ \d+/#) != nil, "\(load)")
    }

    @Test func aStarvedLongestTickIsRunAgainAndPassesStarved() throws {
        let runs = scratch.url("runs")
        let run = try settle(try fakeBuild(runs: runs))
        #expect(run.status == 0, "\(run.output)")
        #expect(self.runs(runs) == 2)
        #expect(run.output.contains("status=starved"), "\(run.output)")
        #expect(run.output.contains(" 1/1 "), "\(run.output)")
    }

    @Test func aTickWorkedOverTheLimitFailsBesideAStarvedLongestOne() throws {
        let runs = scratch.url("runs")
        let run = try settle(try fakeBuild(also: "FAIL: a tick worked 0.30s on the CPU (t=8s, page 1, a tick of 0.40s), over 0.25s", runs: runs))
        #expect(run.status == 1, "\(run.output)")
        // Not run again: nothing starved hides it.
        #expect(self.runs(runs) == 1)
        #expect(run.output.contains("status=4 FAIL: a tick worked 0.30s on the CPU"), "\(run.output)")
        #expect(run.output.contains(" 0/1 "), "\(run.output)")
        #expect(run.output.contains("longest tick 1.00s, most CPU 0.30s"), "\(run.output)")
    }

    /// A stall the main thread worked through more than half of fails, not run again, and is recorded beside the starved
    /// ones the same way: told apart by its CPU time.
    @Test func aStallThatFailsIsRecordedTheSameWay() throws {
        let runs = scratch.url("runs")
        let run = try settle(try fakeBuild(cpu: "0.60", runs: runs))
        #expect(run.status == 1, "\(run.output)")
        #expect(self.runs(runs) == 1)
        #expect(run.output.contains("starved: 0 first attempts run again, 0 recorded starved (status=starved); 1 failed on a stalled tick"), "\(run.output)")
        let record = #/top/700/plain #1, failed, stalled on page 2 at t=12 s \(\d\d:\d\d:\d\d\.\d\d\): 1\.00 s with 0\.60 s CPU, at load [\d.]+, \d+ threads runnable; 0 other runs opening or paging, 0 settled/#
        #expect(run.output.contains(record), "\(run.output)")
    }

    @Test func aRunNoTickOfWhichCarriedACPUReadingFails() throws {
        let runs = scratch.url("runs")
        let run = try settle(try fakeBuild(also: "FAIL: no tick carried a CPU reading, so none was judged on the CPU", runs: runs))
        #expect(run.status == 1, "\(run.output)")
        // Not run again as starved: nothing was judged on the CPU.
        #expect(self.runs(runs) == 1)
        #expect(run.output.contains("status=4 FAIL: no tick carried a CPU reading"), "\(run.output)")
        #expect(run.output.contains(" 0/1 "), "\(run.output)")
    }
}
