import Foundation
import Testing

/// scripts/test.sh and scripts/test-under-load.sh give a run the same umask and none of a team session's variables,
/// whoever starts it (scripts/lib/test-environment.sh, which says what each cost the Linux node's merge gate on
/// 2026-11-19: 271 issues in 16 suites the branch under test didn't touch). Each is started here as the lead's tool
/// server starts a merge's run under the node's unit (umask 002, a session's and the lead's variables) and runs a
/// command that says what it was given: `scripts/test.sh --preferences DIR -- COMMAND` (no swift build), and the load
/// script's `-- COMMAND` with the fake burner, on slots of this test's own.
struct TestEnvironmentTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temp = Scratch()

    /// What a team's session carries and a run must not: as scripts/lib/test-environment.sh lists them.
    static let carried = ["VIBESWITCHER_SESSION": "97537832-73DD-4392-A0F0-B4A06DA15DD1", "VIBESWITCHER_ROLE": "worker",
                          "VIBESWITCHER_CODEX_WORKERS": "0", "VIBESWITCHER_CLAUDE": "/x/claude", "VIBESWITCHER_LEAD_MODEL": "a-model",
                          "VIBESWITCHER_DOOR": "/x/door"]
    /// What sizes the run and says nothing to a test: kept.
    static let kept = ["VIBESWITCHER_HEAVY_TIMEOUT": "3600s", "VIBESWITCHER_TESTS_PER_CORE": "1"]

    /// What a command started by `script arguments… COMMAND` says of itself (its umask, then its environment), the
    /// script started with umask 002 and `carried` and `kept` in its environment (and `more`).
    func given(_ script: String, _ arguments: [String], more: [String: String] = [:]) async throws -> (umask: String, environment: [String: String], output: String) {
        let said = temp.url("said-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "umask 002; exec /bin/bash \"$0\" \"$@\"", Self.repo.appendingPathComponent(script).path] + arguments
            + ["/bin/bash", "-c", "{ umask; env; } > \"$0\"", said.path]
        // As LoadHarnessTests starts the load script: none of its own test knobs, no session to look for an owner in,
        // and no slot of the run this test is in.
        var started = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("TEST_UNDER_LOAD_") }
        started["CLAUDECODE"] = nil
        started["VIBESWITCHER_TEST_LOCK"] = nil
        process.environment = started.merging(Self.carried) { $1 }.merging(Self.kept) { $1 }.merging(more) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // The script's run read to its end and waited for on a thread of its own, not the cooperative pool.
        let output = await offPool { () -> String in
            let read = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            waitForEnd(process)
            return read
        }
        #expect(process.terminationStatus == 0, "\(output)")
        let lines = ((try? String(contentsOf: said, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        var environment: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let equals = line.firstIndex(of: "=") else { continue }
            environment[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return (lines.first ?? "", environment, output)
    }

    func expectClean(_ run: (umask: String, environment: [String: String], output: String)) {
        #expect(run.umask == "0022", "\(run.output)")
        for name in Self.carried.keys.sorted() { #expect(run.environment[name] == nil, "\(name)=\(run.environment[name] ?? "")") }
        for (name, value) in Self.kept { #expect(run.environment[name] == value, "\(name): \(run.environment[name] ?? "unset")") }
    }

    @Test func theTestScriptsRunHasAKnownUmaskAndNoTeamSessionsVariables() async throws {
        let preferences = temp.url("preferences")
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        expectClean(try await given("scripts/test.sh", ["--preferences", preferences.path, "--"]))
    }

    @Test func theLoadScriptsRunHasAKnownUmaskAndNoTeamSessionsVariables() async throws {
        let locks = temp.url("load-locks"), load = temp.url("load")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try "0".write(to: load, atomically: true, encoding: .utf8)
        // The fake burner (loops that sleep) and a fake load: nothing burns, and the slots are this test's own.
        let fake = ["VIBESWITCHER_TEST_LOCK_DIR": locks.path, "TEST_UNDER_LOAD_FAKE_BURNER": "1", "TEST_UNDER_LOAD_FAKE_LOAD": load.path,
                    "TEST_UNDER_LOAD_FAKE_MEMORY": "90", "TEST_UNDER_LOAD_FAKE_DISK_GB": "100", "TEST_UNDER_LOAD_TICK": "0.1"]
        expectClean(try await given("scripts/test-under-load.sh", ["--load", "1", "--max-time", "300", "--"], more: fake))
    }

    /// The list is the one place that names them, and both scripts call it before anything of a run starts: before the
    /// first command either runs for the tests.
    @Test func bothScriptsCleanTheEnvironmentFirst() throws {
        for script in ["scripts/test.sh", "scripts/test-under-load.sh"] {
            let lines = try String(contentsOf: Self.repo.appendingPathComponent(script), encoding: .utf8).components(separatedBy: "\n")
            let source = try #require(lines.firstIndex(of: "source scripts/lib/test-environment.sh"), "\(script)")
            let clean = try #require(lines.firstIndex(of: "clean_test_environment"), "\(script)")
            #expect(source < clean)
            // Nothing but comments, `set`, `cd` and other `source` lines comes before the call.
            let before = lines[..<clean].filter { !$0.isEmpty && !$0.hasPrefix("#") }
            #expect(before.allSatisfy { $0.hasPrefix("set ") || $0.hasPrefix("cd ") || $0.hasPrefix("source ") }, "\(script): \(before)")
        }
    }
}
