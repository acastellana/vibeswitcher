import Foundation
import Testing
@testable import VibeCore

/// The app's footprint stays flat over a working day's churn (app-memory-grows-17): scripts/sandbox-soak-bench.sh runs
/// the sandbox's soak (fake sessions started, chatted with and ended, wallet requests filed and sent or discarded with
/// the desk's clock moving, the lead's Team tab and board updates) for 5 simulated hours (about 14 real minutes; fewer
/// if the soak's own minutes run out first) in a sandboxed copy of this build, and the line through each simulated
/// hour's least footprint after the first (hours 2-5) may rise at most `limit` MB an hour. Its RESULT line is always
/// printed. Judged only
/// while the Mac's 1-minute load is under load_threshold, as FootprintBenchTests; over it the numbers are printed. A
/// bench, run only by `scripts/test.sh --perf`.
struct SandboxSoakBenchTests {
    private let scratch = Scratch()
    /// MB per simulated hour (20 cycles): the soak's least footprint wanders by up to ~8 MB between hours (its window
    /// and layers redrawn: 7.9 over hours 2-3 on 11-01 with nothing growing), so only a growth well over the noise
    /// fails it. The user's 11-01 install grew ~15 MB a real hour, about 5 MB per 20 sessions churned.
    static let limit = 30.0

    @Test(.tags(.perf), .enabled(if: perfRun, perfOnly)) func theFootprintIsFlatOverFiveSimulatedHours() throws {
        let app = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VibeSwitcher")
        #expect(FileManager.default.isExecutableFile(atPath: app.path))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let limitLoad = FootprintBenchTests.loadLimit
        let loadBefore = MacLoad.oneMinute()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repo.appendingPathComponent("scripts/sandbox-soak-bench.sh").path, "--binary", app.path,
                             "--dir", repo.appendingPathComponent(".build/sandbox-soak-bench").path, "5"]
        process.currentDirectoryURL = repo
        // To a file, not a pipe: reading a pipe to its end would wait out a script that never ends, before the guard.
        let output = scratch.url("sandbox-soak-bench-output")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        // The script bounds its own run (the soak's minutes); this only guards a script that never ends.
        if ended.wait(timeout: .now() + 3 * hangGuard) == .timedOut {
            process.terminate()
            Issue.record("the soak bench hung")
            return
        }
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        print(text)
        let loads = [loadBefore, MacLoad.oneMinute()].compactMap { $0 }
        guard let highest = loads.max(), highest < limitLoad else {
            print("soak not judged: the Mac's 1-minute load was \(loads.map { MacLoad.number($0) }), load_threshold \(MacLoad.number(limitLoad))")
            return
        }
        #expect(process.terminationStatus == 0, "\(text)")
        let line = text.split(separator: "\n").first { $0.contains("RESULT soak-simulated-hour-growth-mb") }
        let growth = line.flatMap { $0.components(separatedBy: "RESULT soak-simulated-hour-growth-mb ").last?.split(separator: " ").first }
            .flatMap { Double($0) }
        #expect(line != nil, "no RESULT soak-simulated-hour-growth-mb in:\n\(text)")
        // "n/a": fewer than 3 simulated hours fit in the script's minutes (a slow Mac): printed, not judged.
        if growth == nil, line != nil { print("soak not judged: \(line!)") }
        if let growth { #expect(growth < Self.limit, "the footprint rose \(growth) MB a simulated hour, the limit \(Self.limit)") }
    }
}

private final class Anchor {}
