import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The `--ui-bench` harness's own made-up process table.
struct UIBenchTests {
    /// 2026-10-19: a lead started again drew the pid its old session's agent still held, and the table crashed
    /// ("Duplicate values for key: '60176'"). Two agents on one pid make one process, not a crash.
    @Test func agentsOnTheSamePidMakeOneProcess() {
        let launched = Date(timeIntervalSince1970: 1_000)
        let table = UIBench.processTable(agents: ["ttys010": 60_176, "ttys011": 60_176, "ttys012": 60_177], launched: launched)
        #expect(table.count == 3)
        #expect(table[60_000]?.comm == "vibeswitcher-hos")
        #expect(table[60_176]?.tty == "ttys010")
        #expect(table[60_176]?.ppid == 60_000)
        #expect(table[60_177]?.tty == "ttys012")
        #expect(table[60_177]?.agent == .claude)
    }
}

/// scripts/ui-bench.sh's verdict, on fake builds that print what `--ui-bench` prints and a fake load: the branch's idle
/// instructions/s judged against the base's from the same invocation, and no verdict on a loaded Mac. 2026-10-19 at
/// load 30-90 the fixed 50 M budget failed project-lead itself (77-79 M) as well as the branch (73-78 M).
struct UIBenchScriptTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let cores = ProcessInfo.processInfo.processorCount
    let scratch = Scratch()

    /// A fake build: notes its name in `order`, prints a check and its idle rate, exits with `status`.
    func fakeBuild(_ name: String, rate: Double?, status: Int32 = 0, order: URL) throws -> URL {
        let url = scratch.url("fake-\(name)")
        let result = rate.map { "echo 'RESULT idle-instructions-per-second \(Int($0))'" } ?? ""
        try """
        #!/bin/bash
        echo \(name) >> '\(order.path)'
        echo 'PASS  idle: cpu 0.20 % on average (under 2 %)'
        \(result)
        exit \(status)
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func bench(_ arguments: [String], load: String = "0.5") throws -> (status: Int32, output: String) {
        let logs = scratch.url("ui-bench-logs")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repo.appendingPathComponent("scripts/ui-bench.sh").path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["UI_BENCH_FAKE_LOAD"] = load
        environment["UI_BENCH_LOGS"] = logs.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    func order(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test func theBranchIsJudgedAgainstTheBaseRunAlternately() throws {
        let order = scratch.url("order")
        let base = try fakeBuild("base", rate: 78e6, order: order)
        let branch = try fakeBuild("branch", rate: 76e6, order: order)
        let run = try bench(["-b", branch.path, "-B", base.path, "-r", "2", "1"])
        #expect(run.status == 0, "\(run.output)")
        #expect(self.order(order) == ["base", "branch", "base", "branch"])
        #expect(run.output.contains("PASS  idle: 76.0 M instructions/s, the base 78.0 M"), "\(run.output)")
    }

    @Test func aBranchWorkingMoreThanTheToleranceOverTheBaseFails() throws {
        let order = scratch.url("order")
        let base = try fakeBuild("base", rate: 30e6, order: order)
        let branch = try fakeBuild("branch", rate: 40e6, order: order)
        let run = try bench(["-b", branch.path, "-B", base.path, "-r", "1", "-t", "20", "1"])
        #expect(run.status == 1, "\(run.output)")
        #expect(run.output.contains("FAIL  idle: 40.0 M instructions/s, the base 30.0 M (+33 %; at most +20 %"), "\(run.output)")
    }

    @Test func theBaseFailingTooIsANoteNotTheBranchsFailure() throws {
        let order = scratch.url("order")
        let base = try fakeBuild("base", rate: nil, status: 1, order: order)
        let branch = try fakeBuild("branch", rate: 40e6, order: order)
        let run = try bench(["-b", branch.path, "-B", base.path, "-r", "1", "1"])
        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("1 of the base's runs failed"), "\(run.output)")
        #expect(run.output.contains("not judging instructions/s: no base run got that far"), "\(run.output)")
    }

    @Test func aBranchThatCrashesFails() throws {
        let order = scratch.url("order")
        let base = try fakeBuild("base", rate: 30e6, order: order)
        let branch = try fakeBuild("branch", rate: nil, status: 134, order: order)
        let run = try bench(["-b", branch.path, "-B", base.path, "-r", "1", "1"])
        #expect(run.status == 134, "\(run.output)")
        #expect(run.output.contains("FAIL  idle: no instructions/s from the branch's runs"), "\(run.output)")
    }

    @Test func aLoadedMacIsNotJudgedAndNothingRuns() throws {
        let order = scratch.url("order")
        let base = try fakeBuild("base", rate: 30e6, order: order)
        let branch = try fakeBuild("branch", rate: 90e6, order: order)
        let run = try bench(["-b", branch.path, "-B", base.path, "1"], load: "\(2 * cores).5")
        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("not judging: the Mac's 1-minute load is \(2 * cores).5, over \(2 * cores)"), "\(run.output)")
        #expect(self.order(order).isEmpty)
    }

    @Test func aLoadRisingDuringTheRunsLeavesInstructionsUnjudged() throws {
        let order = scratch.url("order")
        let load = scratch.url("load")
        try "0.5".write(to: load, atomically: true, encoding: .utf8)
        let base = try fakeBuild("base", rate: 30e6, order: order)
        let branch = try fakeBuild("branch", rate: 90e6, order: order)
        // The base's run leaves the Mac loaded.
        try String(contentsOf: base, encoding: .utf8).replacingOccurrences(of: "exit 0", with: "echo \(2 * cores + 1) > '\(load.path)'\nexit 0")
            .write(to: base, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.path)
        let run = try bench(["-b", branch.path, "-B", base.path, "-r", "1", "1"], load: load.path)
        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("not judging instructions/s: the 1-minute load went over \(2 * cores)"), "\(run.output)")
        #expect(self.order(order) == ["base", "branch"])
    }

    @Test func withoutABaseInstructionsAreShownOnly() throws {
        let order = scratch.url("order")
        let branch = try fakeBuild("branch", rate: 90e6, order: order)
        let run = try bench(["-b", branch.path, "1"])
        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("instructions/s not judged: give -B project-lead"), "\(run.output)")
    }
}
