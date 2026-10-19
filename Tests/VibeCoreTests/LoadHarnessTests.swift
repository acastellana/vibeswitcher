import Foundation
import Testing
@testable import VibeCore

/// scripts/test-under-load.sh's refusals, through `--check-only` (it starts nothing) with fake readings, and the
/// workers' and verifiers' prompts sending every load test through it. Its cleanup (the busy loops gone after Ctrl-C,
/// a failing command, a dead owner, SIGKILL) is scripts/test-under-load-selfcheck.sh's: that one puts real load on
/// the Mac for a few seconds, which a suite run on every change shouldn't.
@Suite struct LoadHarnessTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let cores = ProcessInfo.processInfo.processorCount
    let temp = Scratch()

    /// Runs the harness with `arguments`; `fake` readings (load, memory, disk, owner name) go in its environment.
    func harness(_ arguments: [String], fake: [String: String] = [:], claudeCode: Bool = false) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repo.appendingPathComponent("scripts/test-under-load.sh").path] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("TEST_UNDER_LOAD_") }
        environment["CLAUDECODE"] = claudeCode ? "1" : nil
        for (name, value) in fake { environment["TEST_UNDER_LOAD_\(name)"] = value }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// Readings under every threshold.
    let idle = ["FAKE_LOAD": "0.5", "FAKE_MEMORY": "80", "FAKE_DISK_GB": "100"]

    @Test func anIdleMacIsOkUpToTwoLoadProcessesPerCore() throws {
        let run = try harness(["--load", "\(2 * cores)", "--check-only"], fake: idle)
        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("ok to start"))
    }

    @Test func moreThanTwoLoadProcessesPerCoreAreRefused() throws {
        let run = try harness(["--load", "\(2 * cores + 1)", "--check-only"], fake: idle)
        #expect(run.status != 0)
        #expect(run.output.contains("at most \(2 * cores) load processes"), "\(run.output)")
    }

    @Test func theThresholdCanOnlyBeLowered() throws {
        let run = try harness(["--max-load", "\(2 * cores + 1)", "--check-only"], fake: idle)
        #expect(run.status != 0)
        #expect(run.output.contains("can only lower"), "\(run.output)")
    }

    @Test func aMacAlreadyLoadedIsRefusedSayingWhatToWaitFor() throws {
        let run = try harness(["--load", "2", "--check-only"], fake: idle.merging(["FAKE_LOAD": "\(2 * cores).5"]) { $1 })
        #expect(run.status != 0)
        #expect(run.output.contains("already loaded"), "\(run.output)")
        #expect(run.output.contains("Wait until the first of `uptime`'s load averages is under \(2 * cores)"), "\(run.output)")
    }

    @Test func memoryUnderTheFloorIsRefused() throws {
        let low = idle.merging(["FAKE_MEMORY": "24"]) { $1 }
        let run = try harness(["--check-only"], fake: low)
        #expect(run.status != 0)
        #expect(run.output.contains("under the floor of 25 %"), "\(run.output)")
        #expect(try harness(["--memory-floor", "20", "--check-only"], fake: low).status == 0)
    }

    @Test func aSessionWithNoLiveClaudeIsRefused() throws {
        let run = try harness(["--check-only"], fake: idle.merging(["OWNER_NAME": "no-such-process"]) { $1 }, claudeCode: true)
        #expect(run.status != 0)
        #expect(run.output.contains("no live owner"), "\(run.output)")
    }

    /// Without --check-only the fake load (0) is ignored: the real one, never 0.01 or less on a Mac running a
    /// suite, is over --max-load 0.01, so nothing starts.
    @Test func fakeReadingsNeverStartLoad() throws {
        let pids = temp.url("load-pids")
        let run = try harness(["--load", "1", "--max-load", "0.01", "--pid-file", pids.path, "--", "true"], fake: ["FAKE_LOAD": "0"])
        #expect(run.status != 0)
        #expect(run.output.contains("already loaded"), "\(run.output)")
        #expect(!FileManager.default.fileExists(atPath: pids.path))
    }

    @Test func workersAndVerifiersRunLoadTestsOnlyThroughTheHarness() {
        let task = LeadTask(slug: "t", title: "T", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        for prompt in [LeadPrompts.worker(task: task, root: "/r", workflow: LeadWorkflow()),
                       LeadPrompts.verifier(task: task, root: "/r", workflow: LeadWorkflow())] {
            #expect(prompt.contains(LeadPrompts.loadTests))
        }
        for words in ["only through scripts/test-under-load.sh", "never more than 2×ncpu load processes",
                      "never when the Mac is already loaded"] {
            #expect(LeadPrompts.loadTests.contains(words), "\(words)")
        }
    }
}
