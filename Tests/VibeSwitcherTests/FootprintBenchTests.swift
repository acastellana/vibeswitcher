import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// R8 (docs/eval/open-2026-10-19.md): the app's memory footprint has a target. The app's `--idle-bench` with
/// `--churn 10 --churn-speed 10` (ten minutes of a working day's churn, a cycle per 15 s, run in 60 s: sessions starting
/// and ending, the window and the chat opening and closing), in a process of its own on a scratch home: with the window
/// closed its phys_footprint is under 150 MB, after churn it's at most 10 % more than after a warm-up cycle of churn, and
/// the terminal views and chat models alive are what they were before any. Judged only while the Mac's 1-minute load is
/// under load_threshold (workflow.md, else twice the cores); over it the numbers are printed, not judged. A bench, run
/// only by `scripts/test.sh --perf` (`Tag.perf`); the vmmap parser's test runs in every run.
struct FootprintBenchTests {
    private let scratch = Scratch()

    /// The bench's `RESULT name values...` lines.
    static func results(_ text: String) -> [String: [String]] {
        var results: [String: [String]] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("RESULT ") {
            let fields = line.split(separator: " ").dropFirst().map(String.init)
            if let name = fields.first { results[name] = Array(fields.dropFirst()) }
        }
        return results
    }

    /// load_threshold from the workflow.md of the repository this file is in (a worktree's is its project's).
    static var loadLimit: Double {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let workflow = folder.appendingPathComponent(".vibeswitcher/workflow.md")
            if FileManager.default.fileExists(atPath: workflow.path) { return LeadWorkflow.load(from: workflow.path).loadLimit }
            folder.deleteLastPathComponent()
        }
        return LeadWorkflow().loadLimit
    }

    @Test(.tags(.perf), .enabled(if: perfRun, perfOnly)) func theWindowClosedIsUnder150MBAndChurnGrowsItAtMost10Percent() throws {
        let app = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VibeSwitcher")
        #expect(FileManager.default.isExecutableFile(atPath: app.path))
        // Short: the bench's private session host puts its socket in this home, and a socket's path is limited to 104 bytes.
        let home = URL(fileURLWithPath: try scratch.shortFolder("vsfp"))
        let output = scratch.url("footprint-bench-output")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let limit = Self.loadLimit
        let loadBefore = MacLoad.oneMinute()
        let process = Process()
        process.executableURL = app
        process.arguments = ["--idle-bench", "5", "--churn", "10", "--churn-speed", "10", "--churn-warmup", "4"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["VIBESWITCHER_HOME"] = nil  // the run's own (scripts/test.sh) would come before this home
        process.environment = environment
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if ended.wait(timeout: .now() + hangGuard) == .timedOut {
            process.terminate()
            Issue.record("the bench hung")
            return
        }
        let loadAfter = MacLoad.oneMinute()
        let text = try String(contentsOf: output, encoding: .utf8)
        print(text)
        let results = Self.results(text)
        let number = { (name: String, index: Int) in results[name].flatMap { $0.indices.contains(index) ? Double($0[index]) : nil } }
        let loads = [loadBefore, loadAfter].compactMap { $0 }
        guard let highest = loads.max(), highest < limit else {
            print("footprint not judged: the Mac's 1-minute load was \(loads.map { MacLoad.number($0) }), load_threshold \(MacLoad.number(limit))")
            return
        }
        #expect(process.terminationStatus == 0, "\(text)")
        let closed = number("footprint-window-closed-mb", 0)
        #expect(closed != nil && closed! < 150, "window closed: \(closed.map { "\($0)" } ?? "no number") MB, the target under 150")
        // A debug build counts them: none left behind by sessions ending or the window and chat closing.
        let views = results["live-terminal-views"] ?? []
        #expect(views.count == 2 && views[0] == views[1] && Int(views[0]) != nil, "live terminal views before and after churn: \(views)")
        let chats = results["live-chat-models"] ?? []
        #expect(chats.count == 2 && chats[0] == chats[1] && Int(chats[0]) != nil, "live chat models before and after churn: \(chats)")
        let growth = number("churn-growth-percent", 0)
        #expect(growth != nil, "no growth after churn in the bench's output")
        // From the warm baseline (the window-closed phase after 4 cycles of churn), not the cold one: ~12 MB is paid
        // once, not grown. Once a terminal has redrawn often (every churn shell; none of the phases before), AppKit draws
        // it into a content sublayer of its own on the GPU, and CoreAnimation's accelerated renderer keeps the last
        // surface it drew into (8 MB) and ~4.2 MB of its textures (vmmap's "owned unmapped memory"): the same after 1, 2,
        // 10 and 30 minutes of churn, and still there after the terminal and the window are deallocated, since the
        // renderer, not the window, holds it. From the cold baseline that alone was 12 points of a 70 MB footprint. On a
        // loaded Mac the renderer can take a second set of textures (owned unmapped 4.5 -> 8.7 MB, +11.6-11.7 % at load
        // 23-38 with malloc +1.2 MB): the warm-up is 4 cycles so a slow run is likelier to take it before the baseline,
        // and the growth is judged only with the 1-minute load under the cores before and after, recorded otherwise.
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        guard highest < cores else {
            print("growth not judged: the Mac's 1-minute load was \(loads.map { MacLoad.number($0) }), not under its \(Int(cores)) cores")
            return
        }
        #expect(growth.map { $0 <= 10 } == true, "after churn: \(growth.map { "\($0)" } ?? "no number") % over the warm baseline, the target at most 10 %")
    }

    @Test func vmmapsRegionTableIsReadByCategory() {
        let text = """
                                        VIRTUAL RESIDENT    DIRTY  SWAPPED VOLATILE   NONVOL    EMPTY   REGION
        REGION TYPE                        SIZE     SIZE     SIZE     SIZE     SIZE     SIZE     SIZE    COUNT (non-coalesced)
        ===========                     ======= ========    =====  ======= ========   ======    =====  =======
        MALLOC_MEDIUM (empty)            256.0M     256K     256K       0K       0K       0K       0K        2         see MALLOC ZONE table below
        MALLOC_SMALL                      64.0M     704K     704K       1M       0K       0K       0K        8         see MALLOC ZONE table below
        unused but dirty shlib __DATA      115K     115K     115K       0K       0K       0K       0K       45
        __FONT_DATA                        2352       0K       0K       0K       0K       0K       0K        1
        ===========                     ======= ========    =====  ======= ========   ======    =====  =======
        TOTAL                              2.1G   223.9M    6290K       0K       0K       0K       0K     1527

                                         VIRTUAL   RESIDENT      DIRTY    SWAPPED ALLOCATION      BYTES DIRTY+SWAP          REGION
        MALLOC ZONE                         SIZE       SIZE       SIZE       SIZE      COUNT  ALLOCATED  FRAG SIZE  % FRAG   COUNT
        ===========                      =======  =========  =========  =========  =========  =========  =========  ======  ======
        DefaultMallocZone_0x10210c000     512.0M      1168K      1168K         0K        746        45K      1123K     97%       1
        ===========                      =======  =========  =========  =========  =========  =========  =========  ======  ======
        TOTAL                               1.2G      2944K      2944K         0K       1156       915K      2029K     69%      23
        """
        let (regions, allocated) = IdleBench.VMMap.parse(text)
        #expect(regions["MALLOC_MEDIUM (empty)"] == 262_144.0)
        #expect(regions["MALLOC_SMALL"] == 1_769_472.0)
        #expect(regions["unused but dirty shlib __DATA"] == 117_760.0)
        #expect(regions["__FONT_DATA"] == 0.0)
        #expect(regions["TOTAL"] == nil && regions.count == 4)
        #expect(allocated == 936_960.0)
    }
}

private final class Anchor {}
