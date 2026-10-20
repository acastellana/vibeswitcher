import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The battery's target (2026-10-20, "the battery usage of VibeSwitcher ... looks way too much": the installed app
/// averaged 9 % of a core over a day): with no window open, the app's own CPU is under 1 % of a core idle and under 3 %
/// while a lead's team works, its wakeups a few a second, and the session host's under 0.1 %. The app's
/// `--idle-bench 20 --power` (see `PowerBench`), in a process of its own on a scratch home. Judged only while the Mac's
/// 1-minute load is under its cores before and after, like the footprint (`FootprintBenchTests`); over it the numbers
/// are printed, not judged.
struct PowerBenchTests {
    private let scratch = Scratch()

    /// The bench's `RESULT power-<phase> ...` numbers by phase.
    static func phases(_ text: String) -> [String: [Double]] {
        var phases: [String: [Double]] = [:]
        for (name, values) in FootprintBenchTests.results(text) where name.hasPrefix("power-") {
            phases[String(name.dropFirst("power-".count))] = values.compactMap(Double.init)
        }
        return phases
    }

    @Test func idleUnder1PercentAndLeadWorkUnder3() throws {
        let app = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VibeSwitcher")
        #expect(FileManager.default.isExecutableFile(atPath: app.path))
        let home = URL(fileURLWithPath: try scratch.shortFolder("vspw"))
        let output = scratch.url("power-bench-output")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let loadBefore = MacLoad.oneMinute()
        let process = Process()
        process.executableURL = app
        process.arguments = ["--idle-bench", "20", "--power"]
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
        #expect(process.terminationStatus == 0, "\(text)")
        let phases = Self.phases(text)
        #expect(phases["idle"]?.count == 5 && phases["lead-work"]?.count == 5, "the bench's phases: \(text)")
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let loads = [loadBefore, loadAfter].compactMap { $0 }
        guard let highest = loads.max(), highest < cores else {
            print("power not judged: the Mac's 1-minute load was \(loads.map { MacLoad.number($0) }), not under its \(Int(cores)) cores")
            return
        }
        for (phase, target) in [("idle", 1.0), ("lead-work", 3.0)] {
            guard let values = phases[phase], values.count == 5 else { continue }
            #expect(values[0] < target, "\(phase): the app at \(values[0]) % of a core, the target under \(target) %")
            // The hang watchdog's beat (4 a second, its thread's look as often, its snapshot each second) and the
            // clock's: a few a second, not one per session or per timer.
            #expect(values[1] < 15, "\(phase): \(values[1]) wakeups a second")
            #expect(values[3] < 0.1, "\(phase): the session host at \(values[3]) % of a core")
        }
    }
}

private final class Anchor {}
