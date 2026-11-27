import Foundation
import Testing
@testable import VibeCore

/// scripts/test.sh and scripts/test-under-load.sh start every test process from the same umask and with none of a team
/// session's variables, whoever starts the run (scripts/lib/test-environment.sh, which says what each cost the Linux
/// node's merge gate on 2026-11-19: 271 issues in 16 suites the branch under test didn't touch). The scripts
/// themselves, and the vs-heavy a run is under, keep the session's marker: a session's end finds its run by it.
///
/// Three ways in, one each: this test process, which only those scripts start (a plain `swift test` refuses to run);
/// the web tests' node, through `scripts/test.sh --web DIR` with a fake node; and the load script's `-- COMMAND`, with
/// the fake burner on slots of this test's own. Each script is started as the lead's tool server starts a merge's run
/// under the node's unit: umask 002, a session's and the lead's variables.
struct TestEnvironmentTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temp = Scratch()

    /// What a team's session carries and a test process must not: as scripts/lib/test-environment.sh lists them. The
    /// session's id is made up: no session's end looks for it.
    static let carried = ["VIBESWITCHER_SESSION": "0E57E5E5-0000-4000-8000-00000E57E5E5", "VIBESWITCHER_ROLE": "worker",
                          "VIBESWITCHER_CODEX_WORKERS": "0", "VIBESWITCHER_CLAUDE": "/x/claude", "VIBESWITCHER_LEAD_MODEL": "a-model",
                          "VIBESWITCHER_DOOR": "/x/door"]
    /// What sizes the run and says nothing to a test: kept.
    static let kept = ["VIBESWITCHER_HEAVY_TIMEOUT": "3600s", "VIBESWITCHER_TESTS_PER_CORE": "1"]

    /// The script's list is this one.
    @Test func theListIsTheScripts() async throws {
        let listed = try await said(["-c", "source \"$0\"; team_session_variables; team_session_unsets",
                                     Self.repo.appendingPathComponent("scripts/lib/test-environment.sh").path], environment: [:])
        let lines = listed.output.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        #expect(listed.status == 0 && lines.count == 2, "\(listed.output)")
        #expect(lines.first?.sorted() == Self.carried.keys.sorted(), "\(listed.output)")
        #expect(lines.last == lines.first?.flatMap { ["-u", $0] }, "\(listed.output)")
    }

    /// `/bin/bash arguments…` to its end, with `environment` over this process's own: its status and output.
    func said(_ arguments: [String], environment more: [String: String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        // As LoadHarnessTests starts the load script: none of its own test knobs, no session to look for an owner in,
        // and no slot of the run this test is in.
        var started = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("TEST_UNDER_LOAD_") }
        started["CLAUDECODE"] = nil
        started["VIBESWITCHER_TEST_LOCK"] = nil
        process.environment = started.merging(more) { $1 }
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
        return (process.terminationStatus, output)
    }

    /// `script arguments…` started with umask 002 and `carried` and `kept` in its environment (and `more`).
    func started(_ script: String, _ arguments: [String], more: [String: String] = [:]) async throws -> (status: Int32, output: String) {
        try await said(["-c", "umask 002; exec /bin/bash \"$0\" \"$@\"", Self.repo.appendingPathComponent(script).path] + arguments,
                       environment: Self.carried.merging(Self.kept) { $1 }.merging(more) { $1 })
    }

    /// A program that writes its umask, then its environment, to `file`: what a script's test process is given.
    static func reporter(to file: URL) -> String { "#!/bin/bash\n{ umask; env; } > '\(file.path)'\n" }

    /// What `reporter` wrote: no team session's variable, the run's own kept, umask 022.
    func expectClean(_ file: URL, _ run: (status: Int32, output: String)) {
        #expect(run.status == 0, "\(run.output)")
        let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        #expect(lines.first == "0022", "\(lines.first ?? "nothing written"): \(run.output)")
        var environment: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let equals = line.firstIndex(of: "=") else { continue }
            environment[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        for name in Self.carried.keys.sorted() { #expect(environment[name] == nil, "\(name)=\(environment[name] ?? "")") }
        for (name, value) in Self.kept { #expect(environment[name] == value, "\(name): \(environment[name] ?? "unset")") }
    }

    /// This test process, as either script started it: none of the variables, and (where the system says a process's
    /// umask, Linux's `/proc/self/status`) umask 022.
    @Test func aTestProcessCarriesNoTeamSessionsVariable() throws {
        let environment = ProcessInfo.processInfo.environment
        for name in Self.carried.keys.sorted() {
            #expect(environment[name] == nil, "\(name) is in this test process's environment: scripts/lib/test-environment.sh drops it")
        }
        if let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
           let line = status.split(separator: "\n").first(where: { $0.hasPrefix("Umask:") }) {
            #expect(line.split(whereSeparator: \.isWhitespace).last == "0022", "\(line)")
        }
    }

    /// A run a session started is still that session's to end: the script that started this test process and each
    /// vs-heavy between them (its supervisor too) carry the session's marker when the script was started with one.
    /// With the marker dropped at the script's first line they had none, and a session's end (`SessionStrays`) found
    /// only the script. Where a process's environment can't be read (the Mac's own bash and perl hide theirs), or the
    /// run came from no session (a terminal, CI), there is nothing to tell by.
    @Test func theScriptAndItsVsHeavyKeepTheSessionsMarker() throws {
        var ancestors: [(pid: pid_t, arguments: [String], marked: Bool?)] = []
        var next = Platform.Processes.link(getpid())?.parent ?? 0
        while next > 1, ancestors.count < 64, let link = Platform.Processes.link(next) {
            let environment = Platform.Processes.environment(next)
            ancestors.append((next, Platform.Processes.arguments(next), environment.map { $0.contains { $0.hasPrefix("VIBESWITCHER_SESSION=") } }))
            next = link.parent
        }
        // The script itself, `bash scripts/test.sh …`: not the bash vs-heavy runs for it, which only bears its name
        // (`bash -c '…' scripts/test.sh`), nor a vs-heavy that was given it to run.
        func runs(_ arguments: [String], _ name: String) -> Bool {
            arguments.count > 1 && (arguments[1] == name || arguments[1].hasSuffix("/" + name))
        }
        // The nearest script of the two above this process: the one that started it.
        guard let script = ancestors.firstIndex(where: { runs($0.arguments, "scripts/test.sh") || runs($0.arguments, "scripts/test-under-load.sh") }),
              ancestors[script].marked == true else { return }
        for ancestor in ancestors[...script] where ancestor.arguments.contains(where: { $0.hasSuffix("/vs-heavy") }) {
            #expect(ancestor.marked != false, "pid \(ancestor.pid) (\(ancestor.arguments.prefix(4).joined(separator: " "))) lost VIBESWITCHER_SESSION")
        }
    }

    /// The web tests' node (`scripts/test.sh --web DIR`, a fake node first on PATH).
    @Test func theWebTestsNodeIsStartedClean() async throws {
        let root = temp.url("web-run"), bin = root.appendingPathComponent("bin"), web = root.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let report = root.appendingPathComponent("report")
        try installScript(Self.reporter(to: report), at: bin.appendingPathComponent("node"))
        try "".write(to: web.appendingPathComponent("a.test.mjs"), atomically: true, encoding: .utf8)
        expectClean(report, try await started("scripts/test.sh", ["--web", web.path], more: ["PATH": "\(bin.path):/usr/bin:/bin"]))
    }

    /// The load script's COMMAND (the fake burner and a fake load: nothing burns, and the slots are this test's own).
    @Test func theLoadScriptsCommandIsStartedClean() async throws {
        let locks = temp.url("load-locks"), load = temp.url("load"), report = temp.url("report"), reporter = temp.url("reporter")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try "0".write(to: load, atomically: true, encoding: .utf8)
        try installScript(Self.reporter(to: report), at: reporter)
        let fake = ["VIBESWITCHER_TEST_LOCK_DIR": locks.path, "TEST_UNDER_LOAD_FAKE_BURNER": "1", "TEST_UNDER_LOAD_FAKE_LOAD": load.path,
                    "TEST_UNDER_LOAD_FAKE_MEMORY": "80", "TEST_UNDER_LOAD_FAKE_DISK_GB": "100", "TEST_UNDER_LOAD_TICK": "0.1"]
        expectClean(report, try await started("scripts/test-under-load.sh", ["--load", "1", "--max-time", "300", "--", reporter.path], more: fake))
    }

    /// Where each script drops the variables: test.sh in the bashes vs-heavy runs (the tests, and their retry) and around each web test's node; the
    /// load script in each run's subshell and at its COMMAND. Never in the script's own shell, whose vs-heavy would
    /// lose the session's marker with it.
    @Test func eachScriptDropsThemWhereItStartsTestsAndNowhereElse() throws {
        func lines(_ script: String) throws -> [String] {
            try String(contentsOf: Self.repo.appendingPathComponent(script), encoding: .utf8).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        }
        let test = try lines("scripts/test.sh"), load = try lines("scripts/test-under-load.sh")
        for script in [test, load] {
            let source = try #require(script.firstIndex(of: "source scripts/lib/test-environment.sh"))
            #expect(script.firstIndex(of: "known_umask") == source + 1)
        }
        let drops = test.filter { $0.contains("clean_test_environment") }.map { $0.trimmingCharacters(in: .whitespaces) }
        // The build and the tests (`swift_tests`), and --retry-failed's retry of the tests that failed.
        #expect(drops.count == 3 && drops.first == #"if (clean_test_environment; node "$file"); then"#, "\(drops)")
        #expect(drops.dropFirst().first?.hasPrefix("VIBESWITCHER_HEAVY_ROOT=$heavy_root Resources/bin/vs-heavy --as scripts/test.sh bash -c 'clean_test_environment; slot_width; heavy_swift build ") == true, "\(drops)")
        #expect(drops.last?.hasPrefix(#"with_tmpdir "$retry/tmp/" Resources/bin/vs-heavy --as scripts/test.sh bash -c 'clean_test_environment; slot_width; heavy_swift test --skip-build "$@"'"#) == true, "\(drops)")
        #expect(load.filter { $0.contains("clean_test_environment") || $0.contains("team_session_unsets") } == [
            #"    env $(team_session_unsets) "${command[@]}" 8>&- &"#,
            "        clean_test_environment",
        ])
        // No script unsets the marker by hand either.
        for script in [test, load] { #expect(!script.contains { $0.contains("unset") && $0.contains("VIBESWITCHER_SESSION") }) }
    }
}
