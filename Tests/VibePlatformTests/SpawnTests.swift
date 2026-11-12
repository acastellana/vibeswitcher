import Foundation
import Testing
@testable import VibePlatform

/// The test binary's helper mode, for `replaceProcessKeepsOnlyWhatItWasTold`: a test can't replace its own process, so
/// it starts this binary again with `SpawnTests.replaceVariable` set ("kept:extra:only" or "kept:extra:all", two
/// descriptors it handed down), and that process, before any test of its own, replaces itself here.
///
/// First with a program that isn't there, which must fail and change nothing: it says what it found in one line on
/// its stdout. Then with `/bin/sh`, which lists its descriptors there and sends itself SIGUSR1: ignored and blocked
/// in this process, and neither in a new image.
private func replaceTheProcessIfAsked() {
    guard let asked = getenv(SpawnTests.replaceVariable).map({ String(cString: $0) }) else { return }
    func say(_ text: String) {
        let line = text + "\n"
        _ = write(STDOUT_FILENO, line, line.utf8.count)
    }
    let words = asked.split(separator: ":").map(String.init)
    guard words.count == 3, let kept = Int32(words[0]), let extra = Int32(words[1]) else {
        say("couldn't read \(SpawnTests.replaceVariable)=\(asked)")
        _exit(2)
    }
    // The kept one is marked close-on-exec and must reach the new image all the same; the extra one isn't.
    _ = fcntl(kept, F_SETFD, FD_CLOEXEC)
    signal(SIGUSR1, SIG_IGN)
    var blocked = sigset_t()
    sigemptyset(&blocked)
    sigaddset(&blocked, SIGUSR1)
    pthread_sigmask(SIG_BLOCK, &blocked, nil)

    var spawn = Platform.Spawn(executable: "/no/such/program", arguments: ["program"])
    spawn.keep = words[2] == "all" ? nil : [kept]
    let code = spawn.replaceProcess()
    var mask = sigset_t()
    pthread_sigmask(SIG_SETMASK, nil, &mask)
    let ignored = unsafeBitCast(signal(SIGUSR1, SIG_IGN), to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
    say([code == ENOENT ? "ENOENT" : "error \(code)",
         fcntl(kept, F_GETFD) & FD_CLOEXEC != 0 ? "kept-marked" : "kept-unmarked",
         fcntl(extra, F_GETFD) & FD_CLOEXEC != 0 ? "extra-marked" : "extra-unmarked",
         ignored ? "ignored" : "not-ignored",
         sigismember(&mask, SIGUSR1) == 1 ? "blocked" : "not-blocked"].joined(separator: " "))

    spawn.executable = "/bin/sh"
    spawn.arguments = ["sh", "-c", "\(SpawnTests.listing) | tr '\\n' ' '; echo; kill -USR1 $$; echo survived"]
    say("replaceProcess returned \(spawn.replaceProcess())")
    _exit(3)
}

// Runs as the test bundle loads, as `refuseTheAccountRoot` does (TestSupport.swift).
#if os(Linux)
@_used @_section(".init_array")
private let replaceTheProcess: @convention(c) () -> Void = { replaceTheProcessIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let replaceTheProcess: @convention(c) () -> Void = { replaceTheProcessIfAsked() }
#endif

/// `Platform.Spawn`: what a child is started with, on each system. The children are `/bin/sh -c` with a short script,
/// or `cat` held on a pipe; each is read to the end of its output and reaped.
///
/// One at a time: two of them change what the whole process has (SIGUSR1 ignored, descriptor 2 close-on-exec) for
/// the length of a spawn.
@Suite(.serialized)
struct SpawnTests {
    static let replaceVariable = "VIBE_SPAWN_TEST_REPLACE"

    /// The command that lists the descriptors of the process that runs it, one a line. The listing has one of its
    /// own, on the folder it reads.
    #if os(Linux)
    static let listing = "ls /proc/self/fd"
    #else
    static let listing = "ls /dev/fd"
    #endif

    /// The extra descriptors a test opens are numbered from here: far above a listing's own.
    static let firstExtra: Int32 = 100

    /// How a child ended, and what it wrote to its stdout.
    struct Ended {
        var exit: Int32?
        var signal: Int32?
        var output = ""

        var descriptors: [Int32] { output.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }.sorted() }
    }

    struct Failure: Error { var what: String }

    /// Shared with a thread a test starts.
    final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// A pipe, both ends close-on-exec: only the end a spawn names reaches its child.
    static func newPipe() throws -> (reading: Int32, writing: Int32) {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw Failure(what: "no pipe: \(errno)") }
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        return (ends[0], ends[1])
    }

    /// `count` descriptors on /dev/null, numbered from `firstExtra`, none close-on-exec. The test closes them.
    static func extraDescriptors(_ count: Int) throws -> [Int32] {
        let source = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard source >= 0 else { throw Failure(what: "/dev/null: \(errno)") }
        defer { close(source) }
        return try (0..<count).map { _ in
            let copy = fcntl(source, F_DUPFD, firstExtra)
            guard copy >= firstExtra else { throw Failure(what: "no descriptor from \(firstExtra): \(errno)") }
            return copy
        }
    }

    /// What `descriptor` gives until its end.
    static func everything(from descriptor: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads `output` (a child's stdout, when the test has it) to its end and reaps `pid`. A child still there after
    /// `hangGuard` is killed: a test of a child that hangs fails, and doesn't hold the run.
    static func ended(_ pid: pid_t, output: Int32? = nil) -> Ended {
        let guardian = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + TestScriptLinuxTests.hangGuard, execute: guardian)
        defer { guardian.cancel() }
        var ended = Ended()
        if let output { ended.output = everything(from: output) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        if status & 0x7f == 0 { ended.exit = (status >> 8) & 0xff } else { ended.signal = status & 0x7f }
        return ended
    }

    /// Starts `configured` (by `start`) with its stdout on a new pipe, and waits for its end.
    static func output(of configured: Platform.Spawn,
                       by start: (Platform.Spawn) -> Result<pid_t, Platform.Errno> = { $0.start() }) throws -> Ended {
        var spawn = configured
        let pipe = try Self.newPipe()
        defer { close(pipe.reading) }
        spawn.stdout = .descriptor(pipe.writing)
        let started = start(spawn)
        close(pipe.writing)
        return ended(try started.get(), output: pipe.reading)
    }

    static func shell(_ script: String) -> Platform.Spawn {
        Platform.Spawn(executable: "/bin/sh", arguments: ["sh", "-c", script])
    }

    /// A child that stays until `release` is closed: `cat` on a pipe the test holds the other end of.
    static func held(_ group: Platform.Spawn.Group) throws -> (pid: pid_t, release: Int32) {
        let pipe = try Self.newPipe()
        var spawn = Platform.Spawn(executable: "/bin/cat", arguments: ["cat"])
        spawn.stdin = .descriptor(pipe.reading)
        spawn.stdout = .path("/dev/null", flags: O_WRONLY)
        spawn.group = group
        let started = spawn.start()
        close(pipe.reading)
        guard case .success(let pid) = started else {
            close(pipe.writing)
            throw Failure(what: "cat didn't start: \(started)")
        }
        return (pid, pipe.writing)
    }

    static func contents(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The child's listing holds 0, 1, 2, the listing's own and `kept`, nothing else.
    static func expectOnly(_ ended: Ended, kept: [Int32], sourceLocation: SourceLocation = #_sourceLocation) {
        let listed = ended.descriptors
        #expect(ended.exit == 0, "\(ended)", sourceLocation: sourceLocation)
        #if os(Linux)
        // 3: ls's own, on the folder it lists.
        #expect(listed == [0, 1, 2, 3] + kept.sorted(), sourceLocation: sourceLocation)
        #else
        #expect(listed.filter { $0 < 3 } == [0, 1, 2], "\(listed)", sourceLocation: sourceLocation)
        #expect(listed.filter { $0 >= Self.firstExtra } == kept.sorted(), "\(listed)", sourceLocation: sourceLocation)
        // The listing's own: one, or two where ls also keeps the folder it started in.
        #expect(listed.filter { (3..<Self.firstExtra).contains($0) }.count <= 2, "\(listed)", sourceLocation: sourceLocation)
        #endif
    }

    // MARK: Descriptors

    @Test func aChildSeesOnlyTheDescriptorsItWasGiven() throws {
        let extras = try Self.extraDescriptors(5)
        defer { extras.forEach { close($0) } }
        var spawn = Self.shell(Self.listing)
        Self.expectOnly(try Self.output(of: spawn), kept: [])
        spawn.keep = [extras[2]]
        Self.expectOnly(try Self.output(of: spawn), kept: [extras[2]])
        // One marked close-on-exec here reaches the child that was told to keep it, and stays marked here.
        _ = fcntl(extras[4], F_SETFD, FD_CLOEXEC)
        spawn.keep = [extras[4], extras[1]]
        Self.expectOnly(try Self.output(of: spawn), kept: [extras[1], extras[4]])
        #expect(fcntl(extras[4], F_GETFD) & FD_CLOEXEC != 0)
        // nil: whatever isn't close-on-exec.
        spawn.keep = nil
        let all = try Self.output(of: spawn)
        #expect(all.exit == 0)
        #expect(all.descriptors.filter { extras.contains($0) } == Array(extras[0..<4]), "\(all.descriptors)")
        #expect(all.descriptors.prefix(3) == [0, 1, 2], "\(all.descriptors)")
    }

    #if os(Linux)
    /// Where the C library has no "close from" action (musl), the descriptors open at the spawn are listed and each
    /// closed. One that another thread opens between the listing and the spawn isn't in the list (another test's,
    /// here), so this looks only for the test's own.
    @Test func aChildSeesOnlyTheDescriptorsItWasGivenWhereTheyAreListedToClose() throws {
        let extras = try Self.extraDescriptors(5)
        defer { extras.forEach { close($0) } }
        // The last one kept though marked close-on-exec here.
        _ = fcntl(extras[4], F_SETFD, FD_CLOEXEC)
        var spawn = Self.shell(Self.listing)
        for kept in [[], [extras[2]], [extras[4], extras[1]]] {
            spawn.keep = kept
            let ended = try Self.output(of: spawn) { $0.start(closingByListing: true) }
            #expect(ended.exit == 0, "\(ended)")
            #expect(ended.descriptors.prefix(3) == [0, 1, 2], "\(ended.descriptors)")
            #expect(ended.descriptors.filter { $0 >= Self.firstExtra } == kept.sorted(), "\(ended.descriptors)")
        }
        var missing = Platform.Spawn(executable: "/no/such/program", arguments: ["program"])
        missing.stdin = .path("/dev/null", flags: O_RDONLY)
        #expect(missing.start(closingByListing: true) == .failure(Platform.Errno(code: ENOENT)))
    }
    #endif

    /// `.inherit` hands on the parent's descriptor of that number even when it's marked close-on-exec here.
    @Test func anInheritedDescriptorMarkedCloseOnExecStillReachesTheChild() throws {
        let flags = fcntl(STDERR_FILENO, F_GETFD)
        try #require(flags >= 0)
        _ = fcntl(STDERR_FILENO, F_SETFD, flags | FD_CLOEXEC)
        defer { _ = fcntl(STDERR_FILENO, F_SETFD, flags) }
        // Nothing is written: with no descriptor 2 the redirection itself fails, and "open" isn't said.
        var spawn = Self.shell("printf '' >&2 && echo open")
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        let ended = try Self.output(of: spawn)
        #expect(ended.output == "open\n", "\(ended)")
    }

    @Test func stdoutAndStderrGoWhereTheyWereSent() throws {
        let folder = try TestScriptLinuxTests.scratch("spawn-stdio")
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = "echo out; echo err >&2"

        // Each to a pipe of its own.
        let errors = try Self.newPipe()
        defer { close(errors.reading) }
        var piped = Self.shell(script)
        piped.stderr = .descriptor(errors.writing)
        let toPipes = try Self.output(of: piped)
        close(errors.writing)
        #expect(toPipes.exit == 0)
        #expect(toPipes.output == "out\n")
        #expect(Self.everything(from: errors.reading) == "err\n")

        // To a file, made with the mode given.
        let file = folder.appendingPathComponent("err.txt").path
        var filed = Self.shell(script)
        filed.stderr = .path(file, flags: O_WRONLY | O_CREAT | O_TRUNC, mode: 0o600)
        #expect(try Self.output(of: filed).output == "out\n")
        #expect(Self.contents(file) == "err\n")
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)

        // stdout to a file and stderr to /dev/null: a character device that is no terminal.
        let out = folder.appendingPathComponent("out.txt").path
        var quiet = Self.shell(script + "; if [ -c /dev/fd/2 ] && ! [ -t 2 ]; then echo null; fi")
        quiet.stdout = .path(out, flags: O_WRONLY | O_CREAT | O_TRUNC, mode: 0o600)
        quiet.stderr = .path("/dev/null", flags: O_WRONLY)
        #expect(Self.ended(try quiet.start().get()).exit == 0)
        #expect(Self.contents(out) == "out\nnull\n")

        // stdin from /dev/null: at its end at once.
        var empty = Self.shell("cat; echo end")
        empty.stdin = .path("/dev/null", flags: O_RDONLY)
        #expect(try Self.output(of: empty).output == "end\n")

        // Both the same as stdin, one open file: the second line lands after the first, not over it.
        let shared = folder.appendingPathComponent("shared.txt").path
        var same = Self.shell(script)
        same.stdin = .path(shared, flags: O_RDWR | O_CREAT | O_TRUNC, mode: 0o600)
        same.stdout = .sameAsStdin
        same.stderr = .sameAsStdin
        #expect(Self.ended(try same.start().get()).exit == 0)
        #expect(Self.contents(shared) == "out\nerr\n")
    }

    // MARK: Session, group, directory, environment

    @Test func ownSessionMakesTheChildItsOwnSessionLeader() throws {
        let child = try Self.held(.ownSession)
        #expect(getsid(child.pid) == child.pid)
        #expect(getpgid(child.pid) == child.pid)
        close(child.release)
        #expect(Self.ended(child.pid).exit == 0)
    }

    @Test func ownGroupMakesItsOwnGroup() throws {
        let own = try Self.held(.ownGroup)
        #expect(getpgid(own.pid) == own.pid)
        #expect(getsid(own.pid) == getsid(0))
        close(own.release)
        #expect(Self.ended(own.pid).exit == 0)

        let inherited = try Self.held(.inherit)
        #expect(getpgid(inherited.pid) == getpgrp())
        #expect(getsid(inherited.pid) == getsid(0))
        close(inherited.release)
        #expect(Self.ended(inherited.pid).exit == 0)
    }

    @Test func theDirectoryIsTheChilds() throws {
        let folder = try TestScriptLinuxTests.scratch("spawn-directory")
        defer { try? FileManager.default.removeItem(at: folder) }
        let resolved = try #require(realpath(folder.path, nil))
        defer { free(resolved) }
        var spawn = Self.shell("pwd -P")
        spawn.directory = folder.path
        let ended = try Self.output(of: spawn)
        #expect(ended.exit == 0)
        #expect(ended.output == String(cString: resolved) + "\n")
    }

    @Test func theEnvironmentIsExactlyTheOneGiven() throws {
        var spawn = Platform.Spawn(executable: "/usr/bin/env", arguments: ["env"])
        spawn.environment = ["SPAWN_B=2", "SPAWN_A=one and one"]
        let given = try Self.output(of: spawn)
        #expect(given.exit == 0)
        #expect(given.output.split(separator: "\n").sorted() == ["SPAWN_A=one and one", "SPAWN_B=2"])
        // nil: this process's.
        let home = try #require(getenv("HOME").map { String(cString: $0) })
        #expect(try Self.output(of: Self.shell("printf %s \"$HOME\"")).output == home)
    }

    @Test func aMissingExecutableIsENOENT() {
        let spawn = Platform.Spawn(executable: "/no/such/program", arguments: ["program"])
        #expect(spawn.start() == .failure(Platform.Errno(code: ENOENT)))
    }

    // MARK: Signals

    @Test func signalDefaultsOnlyLeavesTheOthersAsInherited() throws {
        let before = signal(SIGUSR1, SIG_IGN)
        defer { signal(SIGUSR1, before) }
        var spawn = Self.shell("kill -USR1 $$; echo survived")
        spawn.defaults = .only([SIGTERM])
        let ignoring = try Self.output(of: spawn)
        #expect(ignoring.exit == 0 && ignoring.output == "survived\n", "\(ignoring)")
        spawn.defaults = .all
        let defaulted = try Self.output(of: spawn)
        #expect(defaulted.signal == SIGUSR1 && defaulted.output.isEmpty, "\(defaulted)")
    }

    /// A thread's blocked signals are its children's too (libdispatch's threads block most): a child started as it is
    /// would never hear SIGTERM. `cat` on a pipe stands for the program that runs on: its stdin ends only after the
    /// signal was sent, so one deaf to it ends by itself, with status 0, and the test says so at once.
    @Test func aChildStartedFromAThreadWithBlockedSignalsStillDiesOfSIGTERM() throws {
        let pipe = try Self.newPipe()
        var spawn = Platform.Spawn(executable: "/bin/cat", arguments: ["cat"])
        spawn.stdin = .descriptor(pipe.reading)
        spawn.stdout = .path("/dev/null", flags: O_WRONLY)
        let started = Box<Result<pid_t, Platform.Errno>>(.failure(Platform.Errno(code: EINVAL)))
        let configured = Box(spawn)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            var every = sigset_t()
            sigfillset(&every)
            pthread_sigmask(SIG_SETMASK, &every, nil)
            started.value = configured.value.start()
            done.signal()
        }
        thread.name = "every signal blocked"
        thread.start()
        done.wait()
        close(pipe.reading)
        guard case .success(let pid) = started.value else {
            close(pipe.writing)
            throw Failure(what: "cat didn't start: \(started.value)")
        }
        kill(pid, SIGTERM)
        close(pipe.writing)
        let ended = Self.ended(pid)
        #expect(ended.signal == SIGTERM, "\(ended)")
    }

    // MARK: Replacing the process

    /// The test binary, started again in its helper mode (`replaceTheProcessIfAsked`), replaces itself with `/bin/sh`.
    @Test(arguments: [true, false]) func replaceProcessKeepsOnlyWhatItWasTold(only: Bool) throws {
        // The helper never gets as far as a test; one that did would not start another.
        try #require(getenv(Self.replaceVariable) == nil)
        let binary = try #require(Bundle.main.executablePath)
        let extras = try Self.extraDescriptors(2)
        defer { extras.forEach { close($0) } }
        let (kept, extra) = (extras[0], extras[1])
        var spawn = Platform.Spawn(executable: binary, arguments: ProcessInfo.processInfo.arguments)
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
            + ["\(Self.replaceVariable)=\(kept):\(extra):\(only ? "only" : "all")"]
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.keep = [kept, extra]
        let ended = try Self.output(of: spawn)
        let lines = ended.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        try #require(lines.count == 3 && lines[2].isEmpty, "\(ended)")
        // The program that isn't there: its error, and nothing changed.
        #expect(lines[0] == "ENOENT kept-marked extra-unmarked ignored blocked")
        // The new image: what it was told to keep (marked close-on-exec or not), or with nil what wasn't marked.
        let listed = lines[1].split(separator: " ").compactMap { Int32($0) }.sorted()
        #expect(listed.prefix(3) == [0, 1, 2], "\(listed)")
        #expect(listed.filter { $0 >= Self.firstExtra } == [only ? kept : extra], "\(listed)")
        #if os(Linux)
        #expect(listed == [0, 1, 2, 3, only ? kept : extra])
        #endif
        // SIGUSR1, ignored and blocked before the exec, ends the new image.
        #expect(ended.signal == SIGUSR1, "\(ended)")
    }
}
