import Foundation
import Testing
import VibeCore

/// scripts/test.sh gives Swift Testing its width (SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH) on the slot vs-heavy
/// gives the run: at most VS_HEAVY_CORES, its width (the cores free when it starts, at least the slot's share), as the
/// build is; without one, a test a core of the whole Mac (a caller's own width kept) as before. With the whole Mac's width, 3 boosted slots each ran up to 12 tests
/// at once on 12 cores (2026-11-08: load 100–225, the app froze about 40 times). Driven through `scripts/test.sh
/// --width` (no slot), and through a whole run with a fake `swift` and `node` first on PATH and its slot in a scratch
/// lock folder: no build, no real slot taken.
struct TestScriptWidthTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let widthKey = "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"
    let temp = Scratch()

    /// This process's environment without what a run of scripts/test.sh and vs-heavy gave it (its width, its slot and
    /// share), then `extra`.
    static func environment(_ extra: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in [widthKey, "VS_HEAVY_CORES", "VIBESWITCHER_TEST_LOCK", "VIBESWITCHER_TEST_LOCK_DIR",
                    "VIBESWITCHER_HEAVY_SLOTS", "VIBESWITCHER_HEAVY_NCPU",
                    "VIBESWITCHER_HEAVY_CORES_FOR", "VIBESWITCHER_HEAVY_LOAD"] {
            environment[key] = nil
        }
        return environment.merging(extra) { $1 }
    }

    /// `bash scripts/test.sh ARGS` with `environment`: its exit status and all of its output.
    static func run(_ arguments: [String], environment: [String: String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repo.appendingPathComponent("scripts/test.sh").path] + arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read to its end and waited for on a thread of its own, not the cooperative pool.
        let output = await offPool { () -> String in
            let read = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            waitForEnd(process)
            return read
        }
        return (process.terminationStatus, output)
    }

    /// `scripts/test.sh --width` with `extra` in the environment: the width it prints.
    static func width(_ extra: [String: String]) async throws -> String {
        let (status, output) = try await run(["--width"], environment: environment(extra))
        #expect(status == 0, "\(output)")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var macCores: String {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &cores, &size, nil, 0)
        return String(cores)
    }

    @Test func withoutASlotTheWidthIsATestACoreOrTheCallersOwn() async throws {
        #expect(try await Self.width([:]) == Self.macCores)
        #expect(try await Self.width([Self.widthKey: "5"]) == "5")
        // No whole number above 0: no slot's share, the width as it was.
        #expect(try await Self.width(["VS_HEAVY_CORES": "0"]) == Self.macCores)
        #expect(try await Self.width(["VS_HEAVY_CORES": "four"]) == Self.macCores)
    }

    @Test func onASlotTheWidthIsItsShareOrACallersNarrowerOne() async throws {
        #expect(try await Self.width(["VS_HEAVY_CORES": "3"]) == "3")
        #expect(try await Self.width(["VS_HEAVY_CORES": "3", Self.widthKey: "1"]) == "1")
        #expect(try await Self.width(["VS_HEAVY_CORES": "3", Self.widthKey: "8"]) == "3")
        #expect(try await Self.width(["VS_HEAVY_CORES": "3", Self.widthKey: "lots"]) == "3")
    }

    /// The whole run, its slot taken by the repository's vs-heavy in a scratch lock folder (12 cores, 3 slots: a share
    /// of 4), the load injected: on a Mac as loaded as it has cores swift test gets a width of 4, its share, not 12; on a
    /// calm one (load 2.5, no other slot held), the 9 cores free when it started (2026-11-08 to 11-12 a merge on a calm
    /// Mac ran at the share alone: 15 min instead of 8). The run's output says the width.
    @Test(arguments: [("12", 4), ("2.5", 9)]) func aRunsSwiftTestGetsTheCoresFreeAtLeastItsSlotsShare(load: String, width: Int) async throws {
        let root = temp.url("width-run")
        let bin = root.appendingPathComponent("bin"), locks = root.appendingPathComponent("locks")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fakes = [
            // build passes; test says what it was given.
            "swift": """
                #!/bin/bash
                [[ $1 == test ]] && echo "swift test: width=${\(Self.widthKey)-unset} cores=${VS_HEAVY_CORES-unset}"
                exit 0
                """,
            "node": "#!/bin/bash\nexit 0\n",
        ]
        for (name, text) in fakes {
            let file = bin.appendingPathComponent(name)
            try text.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let environment = Self.environment([
            "PATH": bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "VIBESWITCHER_TEST_LOCK_DIR": locks.path,
            "VIBESWITCHER_HEAVY_NCPU": "12",
            "VIBESWITCHER_HEAVY_SLOTS": "3",
            "VIBESWITCHER_HEAVY_LOAD": load,
            // A test a core of these 12, whatever this Mac has.
            Self.widthKey: "12",
        ])
        let (_, output) = try await Self.run(["--filter", "Nothing"], environment: environment)
        // Only what swift test was given is judged: the rest of the run (the security tests' host) depends on a build.
        let lines = output.components(separatedBy: "\n").filter { $0.hasPrefix("swift test:") }
        #expect(lines == ["swift test: width=\(width) cores=\(width)"], "\(output)")
        #expect(output.contains("vs-heavy: VS_HEAVY_CORES \(width) of 12 cores: "), "\(output)")
        #expect(MergeSample.cores(in: output) == width, "\(output)")
    }
}
