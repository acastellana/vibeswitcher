import Foundation
import Testing
@testable import VibeCore

/// The app's footprint stays flat over a working day's churn (app-memory-grows-17): scripts/sandbox-soak-bench.sh runs
/// the sandbox's soak (fake sessions started, chatted with and ended, wallet requests filed and sent or discarded with
/// the desk's clock moving, the lead's Team tab and board updates) for 3 simulated hours in a sandboxed copy of this
/// build, and each simulated hour's least footprint after the first may rise at most `limit` MB an hour. Judged only
/// while the Mac's 1-minute load is under load_threshold, as FootprintBenchTests; over it the numbers are printed. A
/// bench, run only by `scripts/test.sh --perf`.
struct SandboxSoakBenchTests {
    /// MB per simulated hour (20 cycles): the soak's least footprint wanders a few MB between hours (its window and
    /// layers redrawn), and a leak of a few hundred KB a session churned reads well over this.
    static let limit = 8.0

    @Test(.tags(.perf), .enabled(if: perfRun, perfOnly)) func theFootprintIsFlatOverThreeSimulatedHours() throws {
        let app = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VibeSwitcher")
        #expect(FileManager.default.isExecutableFile(atPath: app.path))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let limitLoad = FootprintBenchTests.loadLimit
        let loadBefore = MacLoad.oneMinute()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repo.appendingPathComponent("scripts/sandbox-soak-bench.sh").path, "--binary", app.path,
                             "--dir", repo.appendingPathComponent(".build/sandbox-soak-bench").path, "3"]
        process.currentDirectoryURL = repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        // The script bounds its own run (the soak's minutes); this only guards a script that never ends.
        if ended.wait(timeout: .now() + 3 * hangGuard) == .timedOut {
            process.terminate()
            Issue.record("the soak bench hung")
            return
        }
        let text = String(decoding: output, as: UTF8.self)
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
        #expect(growth != nil, "no RESULT soak-simulated-hour-growth-mb in:\n\(text)")
        if let growth { #expect(growth < Self.limit, "the footprint rose \(growth) MB a simulated hour, the limit \(Self.limit)") }
    }
}

private final class Anchor {}
