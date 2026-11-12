import Foundation
import Testing
import VibeCore

/// Set when `refuseTheAccountRoot` has run (`TestHomeGuardTests` checks it did).
var homeGuardRan = false

/// Runs as the test bundle loads (an initializer, like a C constructor), before any test: a run whose VibeSwitcher
/// folder is the user's own ~/.vibeswitcher stops here, with one message and no test run, as in the other test targets
/// (VibeCoreTests' TestSupport.swift). On Linux a write to a pipe or socket whose reader has gone is then an error
/// (EPIPE) for the test that made it, not the end of the whole run.
private func guardTheHome() {
    homeGuardRan = true
    #if os(Linux)
    signal(SIGPIPE, SIG_IGN)
    #endif
    guard let refusal = VibePaths.testRefusal() else { return }
    FileHandle.standardError.write(Data((refusal + "\n").utf8))
    exit(78)
}

// The section that holds initializers is named by the object format: Mach-O's name is accepted on Linux and never run
// there, and ELF's doesn't compile on the Mac.
#if os(Linux)
@_used @_section(".init_array")
private let refuseTheAccountRoot: @convention(c) () -> Void = { guardTheHome() }
#else
@_used @_section("__DATA,__mod_init_func")
private let refuseTheAccountRoot: @convention(c) () -> Void = { guardTheHome() }
#endif

/// This target's load-time guard ran, and let the run go on.
struct TestHomeGuardTests {
    @Test func theGuardRan() {
        #expect(homeGuardRan == true)
    }
}

#if os(Linux)
/// Every `Process()` in this target, on Linux: Foundation's, started with no signal blocked (see VibeCoreTests'
/// TestSupport.swift: a child started from a libdispatch thread inherits its blocked signals, and TERM never reaches it).
final class Process: Foundation.Process, @unchecked Sendable {
    override func run() throws {
        var none = sigset_t(), before = sigset_t()
        sigemptyset(&none)
        pthread_sigmask(SIG_SETMASK, &none, &before)
        defer { pthread_sigmask(SIG_SETMASK, &before, nil) }
        try super.run()
    }
}
#endif

/// How long a wait may go on before the test calls it hung: only a guard, never a measure of speed.
let hangGuard: TimeInterval = 300

/// Polls `condition` every 20 ms until it holds, or until `timeout` passes; at once when the test is cancelled.
/// Awaited, so the test gives back its pool thread between looks.
func eventually(timeout: TimeInterval = hangGuard, isolation: isolated (any Actor)? = #isolation,
                _ condition: () -> Bool) async -> Bool {
    let deadline = MacTime.real.awake() + timeout
    while MacTime.real.awake() < deadline, !Task.isCancelled {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Runs `work`, a blocking call, on a thread of its own and awaits what it returns.
func offPool<T>(_ work: @escaping () -> T) async -> T {
    await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
        let thread = Thread { done.resume(returning: work()) }
        thread.name = "offPool"
        thread.start()
    }
}

/// Whether `process` (the test's own child) ended within `timeout`; past it, it's killed and waited for (10 s more),
/// so that what the caller reads of it next (`terminationStatus`) is there.
func exited(_ process: Process, within timeout: TimeInterval = hangGuard) async -> Bool {
    await offPool {
        let deadline = MacTime.real.awake() + timeout
        while process.isRunning, MacTime.real.awake() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard process.isRunning else { return true }
        kill(process.processIdentifier, SIGKILL)
        let killed = MacTime.real.awake() + 10
        while process.isRunning, MacTime.real.awake() < killed { Thread.sleep(forTimeInterval: 0.01) }
        return false
    }
}

/// The folder the build's products are in (the command line, the hook, the tool server), beside the test bundle. The
/// Mac's bundle is a folder there; Linux's is one executable, and Foundation calls the folder that is in its bundle.
let builtProducts: URL = {
    #if os(Linux)
    return Bundle(for: Scratch.self).bundleURL
    #else
    return Bundle(for: Scratch.self).bundleURL.deletingLastPathComponent()
    #endif
}()

/// Where tests put their scratch files: `$TMPDIR` when it's an absolute path (scripts/test.sh's scratch folder), else
/// the package's .build (as VibePlatformTests' `scratch`).
let scratchRoot: URL = {
    let given = ProcessInfo.processInfo.environment["TMPDIR"] ?? ""
    guard given.hasPrefix("/") else {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent(".build/test-scratch", isDirectory: true)
    }
    return URL(fileURLWithPath: given, isDirectory: true)
}()

/// Scratch paths under `scratchRoot` that are removed, with everything in them, when this goes. A suite keeps one as
/// a stored property: Swift Testing makes a suite instance for each test, so what a test made goes away after it.
final class Scratch: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [URL] = []

    /// A new path `scratchRoot/<prefix>-<uuid>` (not created), removed with this.
    func url(_ prefix: String) -> URL {
        let url = scratchRoot.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        lock.lock()
        paths.append(url)
        lock.unlock()
        return url
    }

    deinit {
        for url in paths { try? FileManager.default.removeItem(at: url) }
    }
}

/// A run of the built command line (`vibeswitcher-cli`, installed as `vibeswitcher`): its status and what it printed.
struct CommandRun {
    var status: Int32
    var output: String
    var errors: String
}

/// The command line as built, beside this test bundle.
let commandLine = builtProducts.appendingPathComponent("vibeswitcher-cli")

/// A home of a test's own for a child: HOME, CFFIXED_USER_HOME, VIBESWITCHER_HOME and TMPDIR in `folder`, and none of
/// the agents' own config variables (CLAUDE_CONFIG_DIR, CODEX_HOME) from this process, which could name the user's
/// own; then `extra`.
func scratchEnvironment(_ folder: URL, _ extra: [String: String] = [:]) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    for key in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "VIBESWITCHER_HOME", "CFFIXED_USER_HOME"] { environment[key] = nil }
    let home = folder.appendingPathComponent("home")
    environment["HOME"] = home.path
    environment["CFFIXED_USER_HOME"] = home.path
    environment["VIBESWITCHER_HOME"] = folder.appendingPathComponent("vibeswitcher").path
    environment["TMPDIR"] = folder.path + "/"
    return environment.merging(extra) { $1 }
}

/// Runs `executable` with `arguments` in `environment`, to its end (a hang guard of 120 s), off the pool.
func run(_ executable: URL, _ arguments: [String], environment: [String: String]) async throws -> CommandRun {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let (out, err) = await offPool { () -> (Data, Data) in
        // Both read at once: a child that fills one pipe while this waits on the other would never end.
        let errorsRead = ErrorsRead()
        let done = DispatchSemaphore(value: 0)
        Thread {
            errorsRead.data = errors.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }.start()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        return (out, errorsRead.data)
    }
    #expect(await exited(process, within: 120), "\(executable.lastPathComponent) \(arguments.joined(separator: " ")) never ended")
    return CommandRun(status: process.terminationStatus, output: String(decoding: out, as: UTF8.self),
                      errors: String(decoding: err, as: UTF8.self))
}

/// What a child wrote to its stderr, read on a thread of its own (handed over through a semaphore).
private final class ErrorsRead: @unchecked Sendable {
    var data = Data()
}
