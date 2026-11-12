import Foundation
import Testing

/// Set when `refuseTheAccountRoot` has run (`TestHomeGuardTests` checks it did).
var homeGuardRan = false

/// One test at a time, of those in any test target that change what SIGURG, SIGWINCH or SIGUSR2 do in the test
/// process or send one to it (SignalsTests, PipeCommandTests, MCPLogTests): a signal one test sends the process lands
/// in whatever handler another has installed, and a handler one test puts back takes away another's. On Linux every
/// target runs in one process; on the Mac every target a run names. `SignalsTests.everyTestThatHandlesTheseSignalsHoldsTheLock`
/// holds each such test to it.
///
/// A flock on `signal-tests.lock` in the run's VibeSwitcher folder, opened anew for each use: a flock belongs to the
/// open file description, so two opens in one process exclude each other, and VibeCoreTests' `SignalTestLock` (its
/// TestSupport.swift), on the same file, needs no module in common with this one.
enum SignalTestLock {
    /// The lock's file: VibeCore's `VibePaths.root`, as `TestHome.root` reads it, then `signal-tests.lock`.
    static var path: String {
        TestHome.root(variable: { name in getenv(name).map { String(cString: $0) } }, fallbackHome: NSHomeDirectory())
            .appendingPathComponent("signal-tests.lock").path
    }

    /// Runs `body` holding the lock. The wait is on a thread of its own, never on Swift's cooperative pool: tests
    /// waiting there would hold its few threads while the holder's body needs one.
    static func held<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        let fd = await taken(path)
        if fd < 0 { Issue.record("SignalTestLock: \(path) couldn't be opened (errno \(-fd)): the test runs without the lock") }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        return try await body()
    }

    /// The descriptor of `path`, flocked; minus errno when it can't be opened.
    static func taken(_ path: String) async -> Int32 {
        await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
            let thread = Thread {
                try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                         withIntermediateDirectories: true)
                let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
                guard fd >= 0 else { return done.resume(returning: -errno) }
                while flock(fd, LOCK_EX) != 0, errno == EINTR {}
                done.resume(returning: fd)
            }
            thread.name = "SignalTestLock"
            thread.start()
        }
    }
}

/// Where VibeSwitcher's folder resolves for this run, and whether the tests may run on it: VibeCore's `VibePaths.root`,
/// `accountHome`, `isAccountRoot` and `testRefusal`, kept in step with them by hand. This target can't import VibeCore
/// (the platform layer is below it), and its bundle is loaded in the same run as the other targets' tests.
enum TestHome {
    /// First of: `VIBESWITCHER_HOME` (the folder itself), `.vibeswitcher` under `CFFIXED_USER_HOME`, under `HOME`,
    /// under `fallbackHome`. A variable counts only when it's an absolute path.
    static func root(variable: (String) -> String?, fallbackHome: String) -> URL {
        func absolute(_ name: String) -> String? {
            guard let path = variable(name), path.hasPrefix("/") else { return nil }
            return path
        }
        if let own = absolute("VIBESWITCHER_HOME") { return URL(fileURLWithPath: own, isDirectory: true) }
        let home = absolute("CFFIXED_USER_HOME") ?? absolute("HOME") ?? fallbackHome
        return URL(fileURLWithPath: home).appendingPathComponent(".vibeswitcher")
    }

    /// The account's own home, from the user database: what neither HOME nor CFFIXED_USER_HOME moves.
    static var accountHome: String {
        getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }

    /// Whether `root` is the account's own `~/.vibeswitcher`, however it's spelled (`..`, a trailing slash, a symlink).
    static func isAccountRoot(_ root: URL, accountHome: String) -> Bool {
        let own = URL(fileURLWithPath: accountHome, isDirectory: true).appendingPathComponent(".vibeswitcher")
        return root.standardizedFileURL.path == own.standardizedFileURL.path
            || root.resolvingSymlinksInPath().path == own.resolvingSymlinksInPath().path
    }

    /// Why the tests won't run with `root` as VibeSwitcher's folder, or nil when they may.
    static func refusal(root: URL, accountHome: String) -> String? {
        guard isAccountRoot(root, accountHome: accountHome) else { return nil }
        return "Refusing to run the tests: VibeSwitcher's folder resolves to your own \(root.path), which they would "
            + "write into. Run scripts/test.sh (a scratch HOME, CFFIXED_USER_HOME, VIBESWITCHER_HOME and TMPDIR), or set "
            + "VIBESWITCHER_HOME, or HOME and CFFIXED_USER_HOME, to a scratch folder."
    }
}

/// What `refuseTheAccountRoot` does: a run whose VibeSwitcher folder is the user's own ~/.vibeswitcher stops here, with
/// one message and no test run (see VibeCoreTests' TestSupport.swift). On Linux a write to a pipe or socket whose
/// reader has gone is then an error (EPIPE) for the test that made it, not the end of the whole run: the Mac's code
/// asks that of each descriptor (SO_NOSIGPIPE, F_SETNOSIGPIPE), which Linux doesn't have.
private func guardTheHome() {
    homeGuardRan = true
    #if os(Linux)
    signal(SIGPIPE, SIG_IGN)
    #endif
    let root = TestHome.root(variable: { name in getenv(name).map { String(cString: $0) } }, fallbackHome: NSHomeDirectory())
    guard let refusal = TestHome.refusal(root: root, accountHome: TestHome.accountHome) else { return }
    FileHandle.standardError.write(Data((refusal + "\n").utf8))
    exit(78)
}

// Runs as the test bundle loads, before any test (an initializer, like a C constructor). The section that holds
// initializers is named by the object format: Mach-O's name is accepted on Linux and never run there, and ELF's
// doesn't compile on the Mac.
#if os(Linux)
@_used @_section(".init_array")
private let refuseTheAccountRoot: @convention(c) () -> Void = { guardTheHome() }
#else
@_used @_section("__DATA,__mod_init_func")
private let refuseTheAccountRoot: @convention(c) () -> Void = { guardTheHome() }
#endif
