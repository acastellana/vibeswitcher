import Foundation
import Testing
@testable import VibePlatform

#if os(Linux)
/// What the helpers below need of the kernel that the platform doesn't give the tests: `prctl(PR_SET_DUMPABLE)`, which
/// makes a helper as private as the host is from its first statement, and `pidfd_getfd`, which takes a descriptor
/// of another process as a worker would. Both are C functions Swift can't call by name (`prctl` is variadic, and
/// `pidfd_getfd` is in a header Swift's Glibc doesn't import), so they are looked up by name in the C library.
/// `Platform.ProcessSelf.harden()` (Task 3a) replaces `undumpable()` once both are in one branch.
enum KernelCalls {
    private static let library = dlopen(nil, RTLD_NOW)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(library, name).map { unsafeBitCast($0, to: type) }
    }

    /// 0 when this process is now non-dumpable, else the errno.
    static func undumpable() -> Int32 {
        typealias Prctl = @convention(c) (Int32, UInt, UInt, UInt, UInt) -> Int32
        // PR_SET_DUMPABLE.
        guard let prctl = symbol("prctl", as: Prctl.self) else { return ENOSYS }
        return prctl(4, 0, 0, 0, 0) == 0 ? 0 : errno
    }

    /// A copy, in this process, of descriptor `target` of the process `pidfd` names: the copy, or minus the errno.
    static func takeDescriptor(_ pidfd: Int32, _ target: Int32) -> Int32 {
        typealias PidfdGetfd = @convention(c) (Int32, Int32, UInt32) -> Int32
        typealias Syscall = @convention(c) (Int, Int, Int, Int) -> Int
        let taken: Int32
        if let pidfdGetfd = symbol("pidfd_getfd", as: PidfdGetfd.self) {
            taken = pidfdGetfd(pidfd, target, 0)
        } else if let syscall = symbol("syscall", as: Syscall.self) {
            // SYS_pidfd_getfd, 438 on every architecture.
            taken = Int32(truncatingIfNeeded: syscall(438, Int(pidfd), Int(target), 0))
        } else {
            return -ENOSYS
        }
        return taken >= 0 ? taken : -errno
    }
}

/// The test binary's helper modes, for the sealed copies that must stay private: each copy is made in a helper that
/// first makes itself non-dumpable, as the host is from its first statement, never in the test process (the plan's
/// Global Constraints). The test starts this binary again with `SealedCopyTests.helperVariable` set, and the helper
/// acts before any test of its own, writing one line for each thing it did on its stdout:
///
/// - `child:sealed:PATH` and `child:plain:PATH`: starts PATH (`sleep 30`) as a child, from a sealed copy or from the
///   file itself; "child PID". Ends the child and itself when its stdin ends.
/// - `private:hardened:PATH` and `private:dumpable:PATH`: makes a copy and holds it; "copy PID FD write ERRNO
///   truncate ERRNO", its own write and truncation of the copy. Ends when its stdin ends.
/// - `rewritten:PATH:MARK`: makes a copy of PATH (the test binary, copied); "copied FD"; waits for a line on its stdin
///   (the test rewrites PATH meanwhile), then starts the copy as a child in the mode below; "child exit N".
/// - `taken`: takes the copy it was started with, as an image that adopts its copy does; "taken FD closed-on-exec
///   adopted" (or "inheritable", "refused").
/// - `mark:MARK`: the child the last one starts, run from the copy: closes its inherited image first, as every image a
///   sealed copy starts does; "mark MARK closed FD shut" (or "open", if the descriptor stayed).
private func actAsSealedCopyHelperIfAsked() {
    guard let asked = getenv(SealedCopyTests.helperVariable).map({ String(cString: $0) }) else { return }
    func say(_ text: String) {
        let line = text + "\n"
        _ = write(STDOUT_FILENO, line, line.utf8.count)
    }
    func waitForTheTest() {
        var byte: UInt8 = 0
        while true {
            let count = read(STDIN_FILENO, &byte, 1)
            if count < 0, errno == EINTR { continue }
            if count <= 0 || byte == UInt8(ascii: "\n") { return }
        }
    }
    func harden() {
        let code = KernelCalls.undumpable()
        guard code == 0 else {
            say("couldn't harden: \(code)")
            _exit(2)
        }
    }
    func makeCopy(_ path: String) -> Platform.ProcessSelf.SealedCopy {
        switch Platform.ProcessSelf.sealedCopy(of: path, name: "helper") {
        case .success(let copy): return copy
        case .failure(let error):
            say("no copy of \(path): \(error.code)")
            _exit(2)
        }
    }
    // This process's environment, without the helper's own setting.
    var environment: [String] = []
    var entry = environ
    while let pointer = entry.pointee {
        let text = String(cString: pointer)
        if !text.hasPrefix(SealedCopyTests.helperVariable + "=") { environment.append(text) }
        entry += 1
    }

    let words = asked.split(separator: ":", maxSplits: 2).map(String.init)
    switch (words.first, words.count) {
    case ("child", 3):
        harden()
        var spawn = Platform.Spawn(executable: words[2], arguments: ["sleep", "30"])
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .path("/dev/null", flags: O_WRONLY)
        spawn.stderr = .sameAsStdin
        if words[1] == "sealed" {
            let copy = makeCopy(words[2])
            spawn.executable = copy.path
            spawn.keep = [copy.fd]
            spawn.environment = environment + ["\(Platform.ProcessSelf.imageVariable)=\(copy.fd)"]
        }
        guard case .success(let child) = spawn.start() else {
            say("the child didn't start")
            _exit(2)
        }
        say("child \(child)")
        waitForTheTest()
        kill(child, SIGKILL)
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0, errno == EINTR {}
        _exit(0)
    case ("private", 3):
        if words[1] == "hardened" { harden() }
        let copy = makeCopy(words[2])
        let byte: UInt8 = 0
        let wrote = pwrite(copy.fd, [byte], 1, 0) < 0 ? errno : 0
        let truncated = ftruncate(copy.fd, 0) < 0 ? errno : 0
        say("copy \(getpid()) \(copy.fd) write \(wrote) truncate \(truncated)")
        waitForTheTest()
        _exit(0)
    case ("rewritten", 3):
        harden()
        let copy = makeCopy(words[1])
        say("copied \(copy.fd)")
        waitForTheTest()
        var spawn = Platform.Spawn(executable: copy.path, arguments: ["copy"])
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.keep = [copy.fd]
        spawn.environment = environment + ["\(SealedCopyTests.helperVariable)=mark:\(words[2])",
                                           "\(Platform.ProcessSelf.imageVariable)=\(copy.fd)"]
        guard case .success(let child) = spawn.start() else {
            say("the copy didn't start")
            _exit(2)
        }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0, errno == EINTR {}
        say("child exit \(status & 0x7f == 0 ? (status >> 8) & 0xff : -(status & 0x7f))")
        _exit(0)
    case ("taken", 1):
        // Arrived as a kept descriptor does, not close-on-exec: taking it marks it so, and adopting it keeps it so.
        let taken = Platform.ProcessSelf.takeInheritedImage()
        let marked = taken.map { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 } ?? false
        let adopted = taken.flatMap { Platform.ProcessSelf.adopt($0) } != nil
        say("taken \(taken.map(String.init) ?? "none") \(marked ? "closed-on-exec" : "inheritable")"
            + " \(adopted ? "adopted" : "refused")")
        _exit(0)
    case ("mark", 2):
        let closed = Platform.ProcessSelf.closeInheritedImage()
        let still = closed.map { fcntl($0, F_GETFD) >= 0 } ?? false
        say("mark \(words[1]) closed \(closed.map(String.init) ?? "none") \(still ? "open" : "shut")"
            + (getenv(Platform.ProcessSelf.imageVariable) == nil ? "" : " variable-left"))
        _exit(0)
    default:
        say("couldn't read \(SealedCopyTests.helperVariable)=\(asked)")
        _exit(2)
    }
}

// Runs as the test bundle loads, as `refuseTheAccountRoot` does (TestSupport.swift).
@_used @_section(".init_array")
private let actAsSealedCopyHelper: @convention(c) () -> Void = { actAsSealedCopyHelperIfAsked() }
#endif

/// `Platform.ProcessSelf.sealedCopy(of:name:)`: an image read once into sealed memory, unreadable, and what runs from
/// it. The first test is the measurement the security document's S6, S8 and S11 rest on (and decision 6): a child
/// started from a sealed `0111` copy can't be reached by the user's other processes from its exec on.
struct SealedCopyTests {
    static let helperVariable = "VIBE_SEALED_COPY_TEST_HELPER"

    struct Failure: Error { var what: String }

    #if os(Linux)
    /// A helper mode of this binary, its stdin and stdout on pipes the test holds. Killed if it is still there after
    /// `TestScriptLinuxTests.hangGuard`, so a test of a helper that hangs fails and doesn't hold the run.
    final class Helper {
        let pid: pid_t
        private var reaped = false
        private(set) var toHelper: Int32
        let fromHelper: Int32
        private let guardian: DispatchWorkItem

        init(_ mode: String) throws {
            try #require(getenv(SealedCopyTests.helperVariable) == nil)
            let binary = try #require(Bundle.main.executablePath)
            let input = try SpawnTests.newPipe(), output = try SpawnTests.newPipe()
            var spawn = Platform.Spawn(executable: binary, arguments: [binary])
            spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
                + ["\(SealedCopyTests.helperVariable)=\(mode)"]
            spawn.stdin = .descriptor(input.reading)
            spawn.stdout = .descriptor(output.writing)
            let started = spawn.start()
            close(input.reading)
            close(output.writing)
            guard case .success(let pid) = started else {
                close(input.writing)
                close(output.reading)
                throw Failure(what: "the helper didn't start: \(started)")
            }
            self.pid = pid
            toHelper = input.writing
            fromHelper = output.reading
            guardian = DispatchWorkItem { kill(pid, SIGKILL) }
            DispatchQueue.global().asyncAfter(deadline: .now() + TestScriptLinuxTests.hangGuard, execute: guardian)
        }

        /// The helper's next line, without its end; nil at the end of its output.
        func line() -> String? {
            var bytes: [UInt8] = []
            var byte: UInt8 = 0
            while true {
                let count = read(fromHelper, &byte, 1)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
                if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
                bytes.append(byte)
            }
        }

        /// Its next line's words after `word`, which must open it.
        func words(after word: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
            let said = line() ?? ""
            let words = said.split(separator: " ").map(String.init)
            try #require(words.first == word, "the helper said \"\(said)\"", sourceLocation: sourceLocation)
            return Array(words.dropFirst())
        }

        func tell(_ text: String) {
            _ = write(toHelper, text + "\n", text.utf8.count + 1)
        }

        /// Ends its stdin, reads the rest of what it says, and reaps it: its exit status and those lines.
        func finish() -> (exit: Int32?, rest: String) {
            if toHelper >= 0 {
                close(toHelper)
                toHelper = -1
            }
            let ended = SpawnTests.ended(pid, output: fromHelper)
            reaped = true
            return (ended.exit, ended.output)
        }

        deinit {
            if toHelper >= 0 { close(toHelper) }
            // Never a pid already reaped: it may be another process's by now.
            if !reaped {
                kill(pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            }
            close(fromHelper)
            guardian.cancel()
        }
    }

    /// How tries on a process went: the ones that got through, and each refusal's errno.
    struct Tries: Equatable {
        var taken = 0
        var refused: [Int32] = []
    }

    /// `pidfd_getfd` of `pid`'s descriptor 0, and `open` of its memory, tried for `duration` seconds, every few
    /// milliseconds: what a worker would try in a child's first instants. With `untilTaken`, it stops at the first
    /// try that gets through.
    static func reach(_ pid: pid_t, for duration: TimeInterval, untilTaken: Bool = false) throws -> (descriptor: Tries, memory: Tries) {
        let pidfd = vibe_pidfd_open(pid, 0)
        guard pidfd >= 0 else { throw Failure(what: "pidfd_open(\(pid)): \(errno)") }
        defer { close(pidfd) }
        var descriptor = Tries(), memory = Tries()
        let end = Date().addingTimeInterval(duration)
        repeat {
            let taken = KernelCalls.takeDescriptor(pidfd, 0)
            if taken >= 0 {
                close(taken)
                descriptor.taken += 1
            } else {
                descriptor.refused.append(-taken)
            }
            let opened = open("/proc/\(pid)/mem", O_RDONLY | O_CLOEXEC)
            if opened >= 0 {
                close(opened)
                memory.taken += 1
            } else {
                memory.refused.append(errno)
            }
            if untilTaken, descriptor.taken > 0 || memory.taken > 0 { break }
            usleep(2_000)
        } while Date() < end
        return (descriptor, memory)
    }

    /// A scratch copy of the file at `path`, in a folder of the run's, for a test that rewrites it.
    static func scratchCopy(of path: String, named name: String) throws -> URL {
        let file = try TestScriptLinuxTests.scratch("sealed").appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: file)
        return file
    }

    /// Rewrites the file at `url` in place, as a worker would: the same inode, truncated and written.
    static func rewriteInPlace(_ url: URL, with text: String) throws {
        let fd = open(url.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(what: "open \(url.path) to rewrite: \(errno)") }
        defer { close(fd) }
        guard write(fd, text, text.utf8.count) == text.utf8.count else { throw Failure(what: "rewrite: \(errno)") }
    }

    static func bytes(of copy: Platform.ProcessSelf.SealedCopy) -> [UInt8] {
        copy.withBytes { Array($0) }
    }

    /// What `copy`, started as a child with `arguments`, writes to its stdout, and how it ended.
    static func run(_ copy: Platform.ProcessSelf.SealedCopy, _ arguments: [String]) throws -> SpawnTests.Ended {
        var spawn = Platform.Spawn(executable: copy.path, arguments: arguments)
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stderr = .path("/dev/null", flags: O_WRONLY)
        spawn.keep = [copy.fd]
        return try SpawnTests.output(of: spawn)
    }

    static func mode(of fd: Int32) -> mode_t {
        var info = stat()
        return fstat(fd, &info) == 0 ? info.st_mode & 0o7777 : 0
    }

    // MARK: The measurement

    /// The measurement (S6): a hardened helper starts `/bin/sleep` from its sealed copy, and for 2 s from the moment
    /// its pid is known, every `pidfd_getfd` of its descriptor and every open of its memory is refused. The same
    /// child started from the readable file is taken at once, which is the failing form. Recorded in
    /// docs/process/v2-linux-inventory.md.
    @Test func aChildStartedFromASealedCopyIsNotDumpableFromItsExec() throws {
        let sealed = try Helper("child:sealed:/bin/sleep")
        let child = try #require(pid_t(try sealed.words(after: "child").first ?? ""))
        let tries = try Self.reach(child, for: 2)
        #expect(tries.descriptor.taken == 0 && tries.memory.taken == 0, "\(tries)")
        #expect(tries.descriptor.refused.count > 10 && Set(tries.descriptor.refused) == [EPERM], "\(tries.descriptor)")
        #expect(tries.memory.refused.count > 10 && Set(tries.memory.refused) == [EACCES], "\(tries.memory)")
        #expect(sealed.finish().exit == 0)
        // For the record (v2-linux-inventory.md): how many tries the window held.
        print("SealedCopyMeasurement: \(tries.descriptor.refused.count) pidfd_getfd and \(tries.memory.refused.count) "
              + "opens of /proc/<pid>/mem over 2 s, \(tries.descriptor.taken + tries.memory.taken) let through")

        let plain = try Helper("child:plain:/bin/sleep")
        let readable = try #require(pid_t(try plain.words(after: "child").first ?? ""))
        let taken = try Self.reach(readable, for: 2, untilTaken: true)
        #expect(taken.descriptor.taken == 1 && taken.descriptor.refused.isEmpty, "\(taken.descriptor)")
        #expect(taken.memory.taken == 1 && taken.memory.refused.isEmpty, "\(taken.memory)")
        #expect(plain.finish().exit == 0)
    }

    // MARK: Private, sealed, unreadable

    /// Against a hardened helper holding a copy, another process of the user can't open it for writing, `chmod` it
    /// back to readable, or take its descriptor; and its holder can't write or truncate it (the seals). A helper left
    /// dumpable is the failing form: its copy is `chmod`ded and taken.
    @Test func aSealedCopyCantBeWrittenOrChmoddedByAnotherProcess() throws {
        let hardened = try Helper("private:hardened:/bin/true")
        let said = try hardened.words(after: "copy")
        try #require(said.count == 6, "\(said)")
        let (pid, fd) = (try #require(pid_t(said[0])), try #require(Int32(said[1])))
        #expect(said[2...] == ["write", "\(EPERM)", "truncate", "\(EPERM)"])
        let link = "/proc/\(pid)/fd/\(fd)"
        let written = open(link, O_WRONLY | O_CLOEXEC)
        let writeError = errno
        if written >= 0 { close(written) }
        #expect(written < 0 && writeError == EACCES, "open for writing: \(written), errno \(writeError)")
        let chmodded = chmod(link, 0o755)
        let chmodError = errno
        #expect(chmodded < 0 && chmodError == EACCES, "chmod: \(chmodded), errno \(chmodError)")
        let pidfd = vibe_pidfd_open(pid, 0)
        try #require(pidfd >= 0)
        defer { close(pidfd) }
        let taken = KernelCalls.takeDescriptor(pidfd, fd)
        if taken >= 0 { close(taken) }
        #expect(taken == -EPERM, "pidfd_getfd: \(taken)")
        #expect(hardened.finish().exit == 0)

        let dumpable = try Helper("private:dumpable:/bin/true")
        let other = try dumpable.words(after: "copy")
        try #require(other.count == 6, "\(other)")
        let reachable = "/proc/\(other[0])/fd/\(other[1])"
        #expect(chmod(reachable, 0o755) == 0, "errno \(errno)")
        let otherPidfd = vibe_pidfd_open(try #require(pid_t(other[0])), 0)
        try #require(otherPidfd >= 0)
        defer { close(otherPidfd) }
        let otherTaken = KernelCalls.takeDescriptor(otherPidfd, try #require(Int32(other[1])))
        #expect(otherTaken >= 0, "pidfd_getfd: \(otherTaken)")
        if otherTaken >= 0 { close(otherTaken) }
        #expect(dumpable.finish().exit == 0)
    }

    /// A copy carries every seal, is close-on-exec, and is `0111`: its own holder can't read it by its path either.
    /// A path that isn't there, and one that isn't a file, give no copy.
    @Test func aSealedCopyIsSealedClosedOnExecAndUnreadable() throws {
        let copy = try Platform.ProcessSelf.sealedCopy(of: "/bin/true", name: "true").get()
        defer { close(copy.fd) }
        #expect(vibe_get_seals(copy.fd) == Platform.ProcessSelf.allSeals)
        #expect(fcntl(copy.fd, F_GETFD) & FD_CLOEXEC != 0)
        #expect(Self.mode(of: copy.fd) == 0o111)
        #expect(!copy.isScript)
        #expect(copy.path == "/proc/self/fd/\(copy.fd)")
        var info = stat()
        #expect(stat("/bin/true", &info) == 0 && copy.size == Int(info.st_size))
        let reopened = open(copy.path, O_RDONLY | O_CLOEXEC)
        let reopenError = errno
        #expect(reopened < 0 && reopenError == EACCES)
        if reopened >= 0 { close(reopened) }

        #expect(Platform.ProcessSelf.sealedCopy(of: "/no/such/file", name: "none") == .failure(Platform.Errno(code: ENOENT)))
        #expect(Platform.ProcessSelf.sealedCopy(of: "/bin", name: "folder") == .failure(Platform.Errno(code: EINVAL)))
    }

    // MARK: What runs is what was read

    /// The test binary, copied to a scratch path, is loaded into a helper's sealed copy; the file is then rewritten in
    /// place with a script (no process runs the file, so there is no ETXTBSY: where held `O_PATH` images failed).
    /// The copy, started as a child, is still the test binary: it prints the helper's mark, having closed the
    /// descriptor it was started from as its first act.
    @Test func aSealedCopyRunsAfterItsFileIsRewrittenInPlace() throws {
        let binary = try #require(Bundle.main.executablePath)
        let file = try Self.scratchCopy(of: binary, named: "binary")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let mark = "m\(UUID().uuidString.prefix(8))"
        let helper = try Helper("rewritten:\(file.path):\(mark)")
        let fd = try #require(try helper.words(after: "copied").first)
        try Self.rewriteInPlace(file, with: "#!/bin/sh\necho replaced\n")
        helper.tell("go")
        let ended = helper.finish()
        #expect(ended.exit == 0)
        #expect(ended.rest == "mark \(mark) closed \(fd) shut\nchild exit 0\n")
    }

    /// The bytes `withBytes` gives are the file's as it was read, still are after the file is rewritten in place,
    /// and are what runs: a copy of `echo` prints what it's given, the rewritten file prints "replaced".
    @Test func aSealedCopysHashIsOfTheBytesItRuns() throws {
        let file = try Self.scratchCopy(of: "/bin/echo", named: "echo")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = [UInt8](try Data(contentsOf: file))
        let copy = try Platform.ProcessSelf.sealedCopy(of: file.path, name: "echo").get()
        defer { close(copy.fd) }
        #expect(copy.size == original.count)
        #expect(Self.bytes(of: copy) == original)

        try Self.rewriteInPlace(file, with: "#!/bin/sh\necho replaced\n")
        #expect([UInt8](try Data(contentsOf: file)) != original)
        #expect(Self.bytes(of: copy) == original)
        let mark = "m\(UUID().uuidString.prefix(8))"
        let ran = try Self.run(copy, ["echo", mark])
        #expect(ran.exit == 0 && ran.output == mark + "\n", "\(ran)")
        let rewritten = try SpawnTests.output(of: Platform.Spawn(executable: "/bin/sh", arguments: ["sh", file.path]))
        #expect(rewritten.output == "replaced\n")
    }

    // MARK: Adopting, scripts

    /// `adopt` takes a copy `sealedCopy` made, and nothing else: a plain memfd, one made `0111` but unsealed, one
    /// sealed but left readable, one short of a seal, a script's copy, a file on disk, a descriptor not open.
    @Test func anAdoptedDescriptorMustBeSealedAndUnreadable() throws {
        let copy = try Platform.ProcessSelf.sealedCopy(of: "/bin/true", name: "true").get()
        defer { close(copy.fd) }
        #expect(Platform.ProcessSelf.adopt(copy.fd) == copy)

        func memfd(seals: Int32, mode: mode_t) throws -> Int32 {
            let fd = vibe_memfd_create("test", VIBE_MFD_CLOEXEC | VIBE_MFD_ALLOW_SEALING)
            try #require(fd >= 0, "memfd_create: \(errno)")
            _ = write(fd, "\u{7f}ELF", 4)
            if seals != 0 { try #require(vibe_add_seals(fd, UInt32(seals)) == 0, "seals: \(errno)") }
            try #require(fchmod(fd, mode) == 0)
            return fd
        }
        let all = Platform.ProcessSelf.allSeals
        let refused = [try memfd(seals: 0, mode: 0o700), try memfd(seals: 0, mode: 0o111),
                       try memfd(seals: all, mode: 0o555), try memfd(seals: all, mode: 0o511),
                       try memfd(seals: all & ~VIBE_F_SEAL_SEAL, mode: 0o111),
                       try memfd(seals: all & ~VIBE_F_SEAL_WRITE, mode: 0o111)]
        defer { refused.forEach { close($0) } }
        for fd in refused { #expect(Platform.ProcessSelf.adopt(fd) == nil, "seals \(vibe_get_seals(fd)), mode \(Self.mode(of: fd))") }
        let control = try memfd(seals: all, mode: 0o111)
        defer { close(control) }
        #expect(Platform.ProcessSelf.adopt(control) != nil, "the control: one made as a copy is taken")
        // As a kept descriptor arrives after an exec, not close-on-exec: adopted, it is close-on-exec again, so the
        // children the adopter starts don't inherit it.
        try #require(fcntl(control, F_SETFD, 0) == 0)
        #expect(Platform.ProcessSelf.adopt(control) != nil)
        #expect(fcntl(control, F_GETFD) & FD_CLOEXEC != 0, "an adopted copy is close-on-exec")

        let script = try TestScriptLinuxTests.scratch("sealed").appendingPathComponent("script")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        try "#!/bin/sh\necho script\n".write(to: script, atomically: false, encoding: .utf8)
        let scriptCopy = try Platform.ProcessSelf.sealedCopy(of: script.path, name: "script").get()
        defer { close(scriptCopy.fd) }
        #expect(Platform.ProcessSelf.adopt(scriptCopy.fd) == nil)
        let onDisk = open("/bin/true", O_RDONLY | O_CLOEXEC)
        defer { close(onDisk) }
        #expect(Platform.ProcessSelf.adopt(onDisk) == nil)
        #expect(Platform.ProcessSelf.adopt(-1) == nil)
    }

    /// An image started from a copy takes it from the environment close-on-exec, as it arrives otherwise not, so a
    /// copy it then refuses to adopt doesn't leak to its children either; and it adopts it.
    @Test func anInheritedImageIsTakenCloseOnExec() throws {
        let copy = try Platform.ProcessSelf.sealedCopy(of: "/bin/true", name: "true").get()
        defer { close(copy.fd) }
        let binary = try #require(Bundle.main.executablePath)
        var spawn = Platform.Spawn(executable: binary, arguments: [binary])
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
            + ["\(Self.helperVariable)=taken", "\(Platform.ProcessSelf.imageVariable)=\(copy.fd)"]
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.keep = [copy.fd]
        let ended = try SpawnTests.output(of: spawn)
        #expect(ended.exit == 0 && ended.output == "taken \(copy.fd) closed-on-exec adopted\n", "\(ended)")
    }

    /// A FIFO gives no copy, at once: opening it for reading would otherwise wait for a writer, and a worker that
    /// puts one where an image is to be copied from would hold the host's start or its handover. If the copy waits,
    /// the guard opens the FIFO for writing after `fifoGuard`, which lets it go on, and the test fails.
    @Test func aFIFOGivesNoCopyAndDoesntWait() throws {
        let folder = try TestScriptLinuxTests.scratch("sealed")
        defer { try? FileManager.default.removeItem(at: folder) }
        let fifo = folder.appendingPathComponent("fifo").path
        try #require(mkfifo(fifo, 0o600) == 0, "mkfifo: \(errno)")
        let waited = Flag()
        let guardian = DispatchWorkItem {
            // Never blocking: once the copy is refused there is no reader, and this open fails with ENXIO.
            let writer = open(fifo, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if writer >= 0 {
                waited.set()
                close(writer)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.fifoGuard, execute: guardian)
        let made = Platform.ProcessSelf.sealedCopy(of: fifo, name: "fifo")
        guardian.cancel()
        #expect(made == .failure(Platform.Errno(code: EINVAL)))
        #expect(!waited.isSet, "the copy waited for a writer")
    }

    /// How long a FIFO's copy may wait before `aFIFOGivesNoCopyAndDoesntWait` lets it go on: refused at once with
    /// the fix, it otherwise waits forever.
    static let fifoGuard: TimeInterval = 10

    /// A flag one thread sets and another reads.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// A script's copy is `0555` and `isScript`, and runs as a child, printing its mark. Made `0111` it can't run:
    /// its interpreter is refused the read (the failing form).
    @Test func aScriptsSealedCopyRuns() throws {
        let mark = "m\(UUID().uuidString.prefix(8))"
        let script = try TestScriptLinuxTests.scratch("sealed").appendingPathComponent("script")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        try "#!/bin/sh\necho \(mark)\n".write(to: script, atomically: false, encoding: .utf8)
        let copy = try Platform.ProcessSelf.sealedCopy(of: script.path, name: "script").get()
        defer { close(copy.fd) }
        #expect(copy.isScript)
        #expect(Self.mode(of: copy.fd) == 0o555)
        #expect(vibe_get_seals(copy.fd) == Platform.ProcessSelf.allSeals)
        let ran = try Self.run(copy, ["script"])
        #expect(ran.exit == 0 && ran.output == mark + "\n", "\(ran)")

        try #require(fchmod(copy.fd, 0o111) == 0)
        let refused = try Self.run(copy, ["script"])
        #expect(refused.exit != 0 && !refused.output.contains(mark), "\(refused)")
    }

    // MARK: What copies cost

    /// The time and shared memory (`Shmem` in /proc/meminfo) a copy takes, of the tool server and of the test binary,
    /// and of ten copies of the test binary made at once: recorded in docs/process/v2-linux-inventory.md. A
    /// measurement, not a check: it runs only with `VIBE_SEALED_COPY_COST=1` in the environment, and prints.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBE_SEALED_COPY_COST"] == "1", "a measurement, run on demand"))
    func whatCopiesCost() throws {
        func shmemKB() -> Int {
            let text = (try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8)) ?? ""
            let line = text.split(separator: "\n").first { $0.hasPrefix("Shmem:") } ?? ""
            return Int(line.split(separator: " ").dropFirst().first ?? "") ?? -1
        }
        let binary = try #require(Bundle.main.executablePath)
        let folder = URL(fileURLWithPath: binary).deletingLastPathComponent()
        var lines: [String] = []
        for path in [folder.appendingPathComponent("vibeswitcher-host").path,
                     folder.appendingPathComponent("vibeswitcher-mcp").path, binary] {
            guard FileManager.default.fileExists(atPath: path) else {
                lines.append("\((path as NSString).lastPathComponent): not built")
                continue
            }
            let before = shmemKB()
            let start = Date()
            let copy = try Platform.ProcessSelf.sealedCopy(of: path, name: "cost").get()
            let took = Date().timeIntervalSince(start)
            let grew = shmemKB() - before
            close(copy.fd)
            lines.append("\((path as NSString).lastPathComponent): "
                + String(format: "%.1f MB, %.0f ms, Shmem +%.1f MB", Double(copy.size) / 1e6, took * 1000, Double(grew) / 1024))
        }
        let before = shmemKB()
        let start = Date()
        final class Made: @unchecked Sendable {
            var fds = [Int32](repeating: -1, count: 10)
            let lock = NSLock()
        }
        let made = Made()
        DispatchQueue.concurrentPerform(iterations: 10) { index in
            let fd = (try? Platform.ProcessSelf.sealedCopy(of: binary, name: "cost").get())?.fd ?? -1
            made.lock.withLock { made.fds[index] = fd }
        }
        let took = Date().timeIntervalSince(start)
        let grew = shmemKB() - before
        made.fds.forEach { close($0) }
        #expect(!made.fds.contains(-1))
        lines.append(String(format: "ten of the test binary at once: %.0f ms, Shmem +%.1f MB", took * 1000, Double(grew) / 1024))
        print("SealedCopyCost\n" + lines.joined(separator: "\n"))
    }
    #else
    @Test func thereAreNoSealedCopiesOnTheMac() {
        #expect(Platform.ProcessSelf.sealedCopy(of: "/bin/sleep", name: "sleep") == .failure(Platform.Errno(code: ENOTSUP)))
        #expect(Platform.ProcessSelf.adopt(STDIN_FILENO) == nil)
        #expect(Platform.ProcessSelf.closeInheritedImage() == nil)
    }
    #endif
}
