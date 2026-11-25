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

/// `offPool` for a `work` that throws: what it throws, the caller's await throws.
func offPool<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
        let thread = Thread { done.resume(with: Result { try work() }) }
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

/// This checkout's folder, for a test that reads the working copy's files (`InstallTests.Script` commits the working
/// copy's install script into a scratch repository). Here, apart from the tests that run git: AgentExportLintTests reads
/// a test file that both locates the checkout and clones as one that may write a tree into it.
let packageFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

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

/// Where scratch sockets and the folders holding them go: `scratchRoot` when its path is short (scripts/test.sh's and
/// scripts/test-under-load.sh's short runs' are), else a short folder of this run's own (`ShortScratch`), since a
/// Unix socket's path is limited in length.
let shortScratchRoot: String = scratchRoot.path.utf8.count <= 40 ? scratchRoot.path : ShortScratch.forThisRun()

/// The short folder of a run whose `scratchRoot` is too long for sockets (test-under-load.sh's first run's): never the
/// shared /tmp itself, where what a run leaves is nobody's to find. `/tmp/vst-<pid>-XXXXXX`, made once, with a link to
/// it in `scratchRoot` (`short-scratch-<pid>-XXXXXX`, the run's own folder, the one its leftover check lists). At exit both
/// go when the folder is empty; when a test left something there (a node's root, a socket's folder), both stay, and
/// the link is what the check finds.
enum ShortScratch {
    /// The system's temporary folder, which every run on the machine shares: only this run's own folder in it is used.
    static let shared = "/tmp"
    nonisolated(unsafe) private static var made: (folder: String, link: String)?

    /// This run's folder, made once, removed at exit when empty; `shared` itself only when none can be made.
    static func forThisRun() -> String {
        guard let pair = make(linkedFrom: scratchRoot) else { return shared }
        made = pair
        atexit {
            guard let made = ShortScratch.made else { return }
            if !ShortScratch.removeIfEmpty(made) {
                FileHandle.standardError.write(Data("tests left files in \(made.folder) (linked from \(made.link))\n".utf8))
            }
        }
        return pair.folder
    }

    /// A new folder `/tmp/vst-<pid>-XXXXXX` (0700), and a link to it in `scratch` (made when missing).
    static func make(linkedFrom scratch: URL) -> (folder: String, link: String)? {
        var template = Array("\(shared)/vst-\(getpid())-XXXXXX".utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else { return nil }
        let folder = String(cString: made)
        let link = scratch.appendingPathComponent("short-scratch-\(getpid())-\(folder.suffix(6))").path
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        guard (try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: folder)) != nil else {
            rmdir(folder)
            return nil
        }
        return (folder, link)
    }

    /// Removes `made`'s folder and its link when the folder is empty: whether it did.
    @discardableResult
    static func removeIfEmpty(_ made: (folder: String, link: String)) -> Bool {
        guard rmdir(made.folder) == 0 || errno == ENOENT else { return false }
        unlink(made.link)
        return true
    }
}

/// Scratch paths under `scratchRoot` that are removed, with everything in them, when this goes. A suite keeps one as
/// a stored property: Swift Testing makes a suite instance for each test, so what a test made goes away after it.
final class Scratch: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [URL] = []

    /// A new path `scratchRoot/<prefix>-<uuid>` (not created), removed with this.
    func url(_ prefix: String) -> URL {
        adopt(scratchRoot.appendingPathComponent("\(prefix)-\(UUID().uuidString)"))
    }

    /// A new folder (made, 0700) with a short path, for sockets (a Unix socket's path is limited to 108 bytes on Linux,
    /// 104 on the Mac): `shortScratchRoot/<prefix>-<8 hex>`, removed with this.
    func shortFolder(_ prefix: String) throws -> URL {
        let folder = adopt(URL(fileURLWithPath: shortScratchRoot).appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    @discardableResult
    private func adopt(_ url: URL) -> URL {
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

/// Runs `executable` with `arguments` in `environment`, to its end (a hang guard of `limit`, 120 s by default), off the
/// pool: its exit status (the signal's number when one ended it, as Foundation's `terminationStatus`) and what it wrote.
///
/// Past the guard the child is killed (SIGKILL). With `ownGroup` it starts in a process group of its own, and the guard
/// ends that group instead: SIGTERM (a script's traps run, and a `vs-heavy` in it ends its COMMAND's group, as its
/// supervisor does on a stop), then SIGKILL to what's left after 15 s; so what the child started doesn't run on.
///
/// Started by `Platform.Spawn` (posix_spawn; stdin /dev/null, no other descriptor of this process, no signal blocked)
/// and collected here by its pid, each wait bounded, on a thread of its own: not Foundation's `Process`, whose `run()`
/// crashed the test process (SIGSEGV) under load while a test started one every 200 ms, and whose waits the repo
/// doesn't trust unbounded (VibePlatformTests' `ProcessesTests.Child`).
func run(_ executable: URL, _ arguments: [String], environment: [String: String], limit: TimeInterval = 120,
         ownGroup: Bool = false) async throws -> CommandRun {
    let command = "\(executable.lastPathComponent) \(arguments.joined(separator: " "))"
    // Close-on-exec from the call that makes them: no child another test starts meanwhile holds a writing end, which
    // would keep the reads below from ending when this child goes.
    var output: [Int32] = [-1, -1], errors: [Int32] = [-1, -1]
    guard Sys.pipeClosedOnExec(&output) == 0 else { throw Platform.Errno(code: errno) }
    guard Sys.pipeClosedOnExec(&errors) == 0 else {
        let code = errno
        output.forEach { Sys.close($0) }
        throw Platform.Errno(code: code)
    }
    var spawn = Platform.Spawn(executable: executable.path, arguments: [executable.path] + arguments)
    spawn.environment = environment.map { "\($0.key)=\($0.value)" }
    spawn.stdin = .path("/dev/null", flags: O_RDONLY)
    spawn.stdout = .descriptor(output[1])
    spawn.stderr = .descriptor(errors[1])
    if ownGroup { spawn.group = .ownGroup }
    let pid: pid_t
    do { pid = try await startRetrying(spawn) } catch {
        (output + errors).forEach { Sys.close($0) }
        throw error
    }
    // The child's ends are its own now.
    Sys.close(output[1])
    Sys.close(errors[1])
    let (reading, readingErrors) = (output[0], errors[0])
    let ran = await offPool { () -> (out: Data, err: Data, status: Int32?) in
        defer {
            Sys.close(reading)
            Sys.close(readingErrors)
        }
        // Both read at once, as they come: a child that fills one pipe while this waits on the other would never end.
        // Past the guard the child is killed (its group: asked first, then killed), and what it wrote is read for 10 s
        // more at most.
        let guardEnd = MacTime.real.awake() + limit
        var deadline = guardEnd, killed = false, asked = false
        var out = Data(), err = Data(), open: [Int32] = [reading, readingErrors]
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !open.isEmpty {
            let now = MacTime.real.awake()
            if now >= deadline {
                guard !killed else { break }
                if ownGroup, !asked {
                    Sys.kill(-pid, SIGTERM)
                    asked = true
                    deadline = now + 15
                    continue
                }
                Sys.kill(ownGroup ? -pid : pid, SIGKILL)
                killed = true
                deadline = now + 10
            }
            var watched = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            guard poll(&watched, nfds_t(watched.count), 100) > 0 else { continue }
            for entry in watched where entry.revents != 0 {
                let count = Sys.read(entry.fd, &chunk, chunk.count)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                if count <= 0 {
                    open.removeAll { $0 == entry.fd }
                } else if entry.fd == reading {
                    out.append(contentsOf: chunk[0..<count])
                } else {
                    err.append(contentsOf: chunk[0..<count])
                }
            }
        }
        // Asked to end, its pipes closed: what its group left (one that ignored SIGTERM) is killed before the child is
        // collected, while its pid, a zombie's at worst, still names that group.
        if asked, !killed {
            Sys.kill(-pid, SIGKILL)
            killed = true
        }
        return (out, err, collected(pid, by: killed ? MacTime.real.awake() : guardEnd))
    }
    #expect(ran.status != nil, "\(command) never ended")
    let raw = ran.status ?? 0
    let status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : raw & 0x7f
    return CommandRun(status: ran.status == nil ? -1 : status, output: String(decoding: ran.out, as: UTF8.self),
                      errors: String(decoding: ran.err, as: UTF8.self))
}

/// Starts `spawn`: its pid. "Text file busy" (a program a test has just copied, while a child another test forked
/// during the copy still holds it open until its exec) lasts a moment and no event says when it's over, so the start
/// is tried again, for at most 10 s.
func startRetrying(_ spawn: Platform.Spawn) async throws -> pid_t {
    let giveUp = MacTime.real.awake() + 10
    while true {
        switch spawn.start() {
        case .success(let pid): return pid
        case .failure(let failure) where failure.code == ETXTBSY && MacTime.real.awake() < giveUp:
            try await Task.sleep(nanoseconds: 20_000_000)
        case .failure(let failure): throw failure
        }
    }
}

/// Runs `executable` with `arguments` to its end, on the calling thread (a blocking call: for a helper that isn't
/// async, or off the pool): its exit status (the signal's number when one ended it). Started by `Platform.Spawn` (stdin
/// /dev/null, no other descriptor of this process) and collected by its pid with bounded waits, killed past `limit`:
/// never Foundation's `Process` and its unbounded `waitUntilExit` (`run(_:_:environment:)`'s note; on the Mac's CI it
/// hung). Throws what its start throws (ETXTBSY too, not tried again), and when it was never collected.
@discardableResult
func runToEnd(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
              output: Platform.Spawn.Stdio = .inherit, limit: TimeInterval = 120) throws -> Int32 {
    var spawn = Platform.Spawn(executable: executable, arguments: [executable] + arguments)
    spawn.environment = environment.map { $0.map { "\($0.key)=\($0.value)" } }
    spawn.stdin = .path("/dev/null", flags: O_RDONLY)
    spawn.stdout = output
    spawn.stderr = output
    let pid: pid_t
    switch spawn.start() {
    case .failure(let failure): throw failure
    case .success(let started): pid = started
    }
    guard let raw = collected(pid, by: MacTime.real.awake() + limit) else {
        throw CocoaError(.executableLoad, userInfo: [NSFilePathErrorKey: executable, NSLocalizedDescriptionKey: "\(executable) never ended"])
    }
    return raw & 0x7f == 0 ? (raw >> 8) & 0xff : raw & 0x7f
}

/// Collects child `pid`, asking every few milliseconds (a blocking call: off the pool) until `deadline`; still there
/// then, it's killed and asked for 10 s more. Its wait status, or nil when it was never collected (nor by anyone else:
/// one no child of this process any more is nil too).
func collected(_ pid: pid_t, by deadline: TimeInterval) -> Int32? {
    var raw: Int32 = 0
    var pause: useconds_t = 500
    var limit = deadline, killed = false
    while true {
        let found = waitpid(pid, &raw, WNOHANG)
        if found == pid { return raw }
        if found < 0, errno != EINTR { return nil }
        if MacTime.real.awake() >= limit {
            guard !killed else { return nil }
            Sys.kill(pid, SIGKILL)
            killed = true
            limit = MacTime.real.awake() + 10
        }
        if found == 0 {
            usleep(pause)
            pause = min(pause * 2, 20_000)
        }
    }
}

/// `source` copied to `target` (made, mode 0755) through a descriptor that is close-on-exec, so that no program another
/// test starts meanwhile holds it open for writing, which would refuse the copy's exec ("Text file busy"): how a test
/// makes a fake agent from `/bin/sleep` (`FakeAgent`, `ServerTests`), never `FileManager.copyItem`, whose descriptor a
/// child forked during the copy inherits.
func copyClosedOnExec(_ source: String, to target: String) throws {
    try writeClosedOnExec([UInt8](try Data(contentsOf: URL(fileURLWithPath: source))), to: target)
}

/// A program's `text` (a script) written to `url` (made, `mode`), as `copyClosedOnExec` writes: never Foundation's
/// `write(to:)`, whose descriptor a child forked during the write inherits ("Text file busy" at its exec;
/// `ShebangWriteLintTests`). An existing file is replaced (removed first).
func writeClosedOnExec(_ text: String, to url: URL, mode: mode_t = 0o755) throws {
    try? FileManager.default.removeItem(at: url)
    try writeClosedOnExec(Array(text.utf8), to: url.path, mode: mode)
}

/// `bytes` written to a new file at `target`, `mode`, through a close-on-exec descriptor.
func writeClosedOnExec(_ bytes: [UInt8], to target: String, mode: mode_t = 0o755) throws {
    let fd = open(target, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
    guard fd >= 0 else { throw Platform.Errno(code: errno) }
    defer { Sys.close(fd) }
    _ = fchmod(fd, mode)
    var done = 0
    while done < bytes.count {
        let wrote = bytes.withUnsafeBytes { Sys.write(fd, $0.baseAddress! + done, bytes.count - done) }
        if wrote < 0, errno == EINTR { continue }
        guard wrote > 0 else { throw Platform.Errno(code: errno) }
        done += wrote
    }
}

/// Lets the Mac run `path`: a copy a test made of one of the Mac's own programs (`/bin/sleep`, `/bin/cat`, `/bin/bash`),
/// to run it under a name or from a folder of its own. macOS 27 kills such a copy as it starts (SIGKILL, exit 137; its
/// crash report says "Launch Constraint Violation": an Apple platform binary's signature holds it to its own path), so
/// the copy is signed again, ad hoc (`codesign --force --sign -`), as a program of its own. It then runs, a copy of it
/// runs too, and this process may read its environment, as macOS lets no process read a platform binary's. Linux has
/// no such signature: nothing is done there. `codesign` is started with `Platform.Spawn` and reaped by a bounded
/// `waitpid(WNOHANG)`, never Foundation's `waitUntilExit` (as VibeHostTests' `installProgram` reaps its `cp`).
/// One helper, the same in each test target's TestSupport.swift.
func signedAsItsOwn(_ path: String) throws {
    #if os(macOS)
    var sign = Platform.Spawn(executable: "/usr/bin/codesign", arguments: ["/usr/bin/codesign", "--force", "--sign", "-", path])
    sign.stdin = .path("/dev/null", flags: O_RDONLY)
    sign.stdout = .path("/dev/null", flags: O_WRONLY)
    sign.stderr = .path("/dev/null", flags: O_WRONLY)
    let failed = { (why: String) in
        CocoaError(.executableLoad, userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: "codesign --sign - \(path): \(why)"])
    }
    let pid: pid_t
    switch sign.start() {
    case .success(let started): pid = started
    case .failure(let failure): throw failed("not started (errno \(failure.code))")
    }
    var status: Int32 = 0
    var reaped: pid_t = 0
    let deadline = DispatchTime.now() + .seconds(120)
    repeat {
        reaped = waitpid(pid, &status, WNOHANG)
        if reaped == 0 { usleep(1_000) }
    } while (reaped == 0 || (reaped < 0 && errno == EINTR)) && DispatchTime.now() < deadline
    if reaped == 0 {
        kill(pid, SIGKILL)
        _ = waitpid(pid, &status, 0)
        throw failed("still running after 120 s")
    }
    // Exited 0: no signal, no status.
    guard reaped == pid, status == 0 else { throw failed("wait status \(status)") }
    #endif
}
