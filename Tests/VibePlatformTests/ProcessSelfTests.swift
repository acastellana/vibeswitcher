import Foundation
import Testing
@testable import VibePlatform

// Whether this is Linux, for the traits below: the Mac's forms do nothing, and their tests say so there.
#if os(Linux)
private let onLinux = true
#else
private let onLinux = false
#endif

/// The test binary's helper mode, for what a test may not do to its own process: the test process is never hardened
/// (other tests read its /proc entries, and a hardened test process would hide them). Started again with
/// `ProcessSelfTests.helperVariable` set, this binary takes commands on its stdin before any test of its own, one a
/// line, answers each in one line on its stdout, and ends (0) at its stdin's end.
///
/// - `harden`: `Platform.ProcessSelf.harden()`, "hardened true" or "hardened false".
/// - `undump`: `Platform.ProcessSelf.makeDumpable()`, "undumped true" or "undumped false".
/// - `dumpable`: `Platform.ProcessSelf.isDumpable()`, "dumpable true", "dumpable false" or "dumpable nil".
/// - `tracer`: `Platform.ProcessSelf.tracer()`, "tracer 0" (none), "tracer <pid>" or "tracer nil".
/// - `connect PATH`: a stream socket connected to the listener at PATH, one byte ("c") written on it and the socket
///   kept to the end, "connected" or "not connected <errno>".
private func serveTheTestIfAsked() {
    guard getenv(ProcessSelfTests.helperVariable) != nil else { return }
    func say(_ text: String) {
        let line = text + "\n"
        _ = write(STDOUT_FILENO, line, line.utf8.count)
    }
    func word(_ value: Bool?) -> String { value.map { $0 ? "true" : "false" } ?? "nil" }
    var kept: [Int32] = []
    var pending: [UInt8] = []
    var byte: UInt8 = 0
    while true {
        let count = read(STDIN_FILENO, &byte, 1)
        if count < 0, errno == EINTR { continue }
        guard count == 1 else { break }
        guard byte == UInt8(ascii: "\n") else {
            pending.append(byte)
            continue
        }
        let command = String(decoding: pending, as: UTF8.self)
        pending = []
        if command == "harden" {
            say("hardened \(word(Platform.ProcessSelf.harden()))")
        } else if command == "undump" {
            say("undumped \(word(Platform.ProcessSelf.makeDumpable()))")
        } else if command == "dumpable" {
            say("dumpable \(word(Platform.ProcessSelf.isDumpable()))")
        } else if command == "tracer" {
            say("tracer \(Platform.ProcessSelf.tracer().map { String($0) } ?? "nil")")
        } else if command.hasPrefix("connect ") {
            let path = String(command.dropFirst("connect ".count))
            let fd = socket(AF_UNIX, Platform.Sockets.stream, 0)
            guard fd >= 0, var address = Platform.Sockets.unixAddress(path) else {
                say("not connected \(errno)")
                continue
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0, write(fd, "c", 1) == 1 else {
                say("not connected \(errno)")
                close(fd)
                continue
            }
            kept.append(fd)
            say("connected")
        } else {
            say("unknown command \(command)")
        }
    }
    kept.forEach { close($0) }
    _exit(0)
}

// Runs as the test bundle loads, as `refuseTheAccountRoot` does (TestSupport.swift).
#if os(Linux)
@_used @_section(".init_array")
private let serveTheTest: @convention(c) () -> Void = { serveTheTestIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let serveTheTest: @convention(c) () -> Void = { serveTheTestIfAsked() }
#endif

/// `Platform.ProcessSelf`: a process makes itself non-dumpable and says whether it is, and who traces it. Each
/// process hardened is a helper (the test binary started again, `serveTheTestIfAsked`), ended and reaped before its
/// test returns; the test process only reads.
struct ProcessSelfTests {
    static let helperVariable = "VIBE_PROCESS_SELF_TEST_HELPER"

    struct Failure: Error { var what: String }

    /// A helper the test talks to: its commands go to its stdin, its answers come from its stdout.
    final class Helper {
        let pid: pid_t
        private var commands: Int32
        private let answers: Int32
        private var unread: [UInt8] = []
        private var ended: SpawnTests.Ended?

        private init(pid: pid_t, commands: Int32, answers: Int32) {
            self.pid = pid
            self.commands = commands
            self.answers = answers
        }

        /// The test binary, started again in its helper mode.
        static func start() throws -> Helper {
            // The helper never gets as far as a test; one that did would not start another.
            try #require(getenv(helperVariable) == nil)
            let binary = try #require(Bundle.main.executablePath)
            let input = try SpawnTests.newPipe()
            let output: (reading: Int32, writing: Int32)
            do { output = try SpawnTests.newPipe() } catch {
                close(input.reading)
                close(input.writing)
                throw error
            }
            var spawn = Platform.Spawn(executable: binary, arguments: ProcessInfo.processInfo.arguments)
            spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + ["\(helperVariable)=1"]
            spawn.stdin = .descriptor(input.reading)
            spawn.stdout = .descriptor(output.writing)
            let started = spawn.start()
            close(input.reading)
            close(output.writing)
            switch started {
            case .success(let pid): return Helper(pid: pid, commands: input.writing, answers: output.reading)
            case .failure(let failure):
                close(input.writing)
                close(output.reading)
                throw Failure(what: "the helper didn't start: errno \(failure.code)")
            }
        }

        /// Sends `command` and gives its answer, the helper's next line. One that doesn't come within the hang guard
        /// fails the test, and doesn't hold the run.
        func ask(_ command: String) throws -> String {
            let line = Array((command + "\n").utf8)
            guard commands >= 0, write(commands, line, line.count) == line.count else {
                throw Failure(what: "\(command): the helper takes no more commands (errno \(errno))")
            }
            while true {
                if let end = unread.firstIndex(of: UInt8(ascii: "\n")) {
                    defer { unread.removeFirst(end + 1) }
                    return String(decoding: unread[..<end], as: UTF8.self)
                }
                var waiting = pollfd(fd: answers, events: Int16(POLLIN), revents: 0)
                var ready: Int32 = -1
                repeat { ready = poll(&waiting, 1, Int32(TestScriptLinuxTests.hangGuard * 1_000)) } while ready < 0 && errno == EINTR
                guard ready == 1 else { throw Failure(what: "\(command): no answer (poll \(ready))") }
                var chunk = [UInt8](repeating: 0, count: 256)
                let count = read(answers, &chunk, chunk.count)
                guard count > 0 else { throw Failure(what: "\(command): the helper ended without an answer") }
                unread += chunk.prefix(count)
            }
        }

        /// Closes its stdin, which ends it, without reaping it: it stays a zombie until `end()`.
        func release() {
            if commands >= 0 {
                close(commands)
                commands = -1
            }
        }

        /// Closes its stdin, which ends it, and reaps it: how it ended.
        @discardableResult
        func end() -> SpawnTests.Ended {
            if let ended { return ended }
            release()
            let result = SpawnTests.ended(pid)
            close(answers)
            ended = result
            return result
        }

        deinit { end() }
    }

    /// `open("/proc/<pid>/mem")` by this process: 0 when it opened, else its errno.
    static func openMemory(of pid: pid_t) -> Int32 {
        let fd = open("/proc/\(pid)/mem", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        close(fd)
        return 0
    }

    // MARK: Hardening

    /// Its memory is closed to another process of the same user once it has hardened. Before, it opens: the failing
    /// form, which this machine (no Yama) allows any process of the user.
    @Test(.enabled(if: onLinux, "Linux's /proc; the Mac's harden() does nothing")) func aHardenedProcesssMemoryCantBeOpened() throws {
        let helper = try Helper.start()
        defer { helper.end() }
        #expect(try helper.ask("dumpable") == "dumpable true")
        #expect(Self.openMemory(of: helper.pid) == 0)
        #expect(try helper.ask("harden") == "hardened true")
        #expect(Self.openMemory(of: helper.pid) == EACCES)
        #expect(helper.end().exit == 0)
    }

    /// The core file size limit of the process `pid`, soft and hard, as its /proc/<pid>/limits writes them (a
    /// number, or "unlimited"); nil without that line. The file stays readable to anyone once the process hardens.
    static func coreLimits(of pid: pid_t) -> (soft: String, hard: String)? {
        guard let text = SpawnTests.contents("/proc/\(pid)/limits") else { return nil }
        let name = "Max core file size"
        for line in text.split(separator: "\n") where line.hasPrefix(name) {
            let fields = line.dropFirst(name.count).split(separator: " ")
            return fields.count >= 2 ? (String(fields[0]), String(fields[1])) : nil
        }
        return nil
    }

    /// Hardened, it may write no core file: its core file size limit is 0, soft and hard, so that nothing it runs
    /// may raise it again. Before, the hard one is the test process's (unlimited here).
    @Test(.enabled(if: onLinux, "Linux's /proc; the Mac's harden() does nothing")) func aHardenedProcessHasNoCoreFile() throws {
        let helper = try Helper.start()
        defer { helper.end() }
        let before = try #require(Self.coreLimits(of: helper.pid))
        #expect(try helper.ask("harden") == "hardened true")
        let after = try #require(Self.coreLimits(of: helper.pid), "limits before: \(before)")
        #expect(after.soft == "0" && after.hard == "0", "limits before \(before), after \(after)")
        #expect(helper.end().exit == 0)
    }

    #if os(Linux)
    /// Its descriptors can't be taken by `pidfd_getfd` once it has hardened; before, its stdin can be.
    @Test func aHardenedProcesssDescriptorsCantBeTaken() throws {
        let helper = try Helper.start()
        defer { helper.end() }
        let process = vibe_pidfd_open(helper.pid, 0)
        try #require(process >= 0, "pidfd_open: errno \(errno)")
        defer { close(process) }
        let taken = vibe_pidfd_getfd(process, 0, 0)
        #expect(taken >= 0, "pidfd_getfd before hardening: errno \(errno)")
        if taken >= 0 {
            #expect(fcntl(taken, F_GETFD) & FD_CLOEXEC != 0)
            close(taken)
        }
        #expect(try helper.ask("harden") == "hardened true")
        let refused = vibe_pidfd_getfd(process, 0, 0)
        let code = errno
        if refused >= 0 { close(refused) }
        #expect(refused == -1 && code == EPERM, "pidfd_getfd after hardening: \(refused), errno \(code)")
        #expect(helper.end().exit == 0)
    }
    #endif

    /// It reads as dumpable before it hardens and as not after, to itself and to another process; once gone, it
    /// reads as neither.
    @Test(.enabled(if: onLinux, "Linux's forms; the Mac's say nothing")) func aHardenedProcessReadsAsNotDumpable() throws {
        let helper = try Helper.start()
        defer { helper.end() }
        #expect(Platform.Processes.isDumpable(helper.pid) == true)
        #expect(try helper.ask("dumpable") == "dumpable true")
        #expect(try helper.ask("harden") == "hardened true")
        #expect(Platform.Processes.isDumpable(helper.pid) == false)
        #expect(try helper.ask("dumpable") == "dumpable false")
        // Hardening again is harmless, and changes nothing.
        #expect(try helper.ask("harden") == "hardened true")
        #expect(Platform.Processes.isDumpable(helper.pid) == false)
        let pid = helper.pid
        #expect(helper.end().exit == 0)
        #expect(Platform.Processes.isDumpable(pid) == nil)
    }

    /// This process, which no test hardens, is dumpable, to itself and as another process reads it; a number that is
    /// no process's reads as neither.
    @Test(.enabled(if: onLinux, "Linux's forms; the Mac's say nothing")) func theTestProcessIsDumpable() {
        #expect(Platform.ProcessSelf.isDumpable() == true)
        #expect(Platform.Processes.isDumpable(getpid()) == true)
        #expect(Platform.Processes.isDumpable(0) == nil)
        #expect(Platform.Processes.isDumpable(-1) == nil)
    }

    /// A hardened process's token is still its peer token: its owner is read from its status, which stays open to
    /// anyone (mode 0444) though it is root's once the process is non-dumpable.
    @Test(.enabled(if: onLinux, "Linux's tokens; the Mac has none for a pid")) func aHardenedProcesssTokenIsItsPeerToken() throws {
        let folder = try SocketsTests.socketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("s").path
        let listener = try SocketsTests.listener(at: path)
        defer { Sys.close(listener) }
        let helper = try Helper.start()
        defer { helper.end() }
        #expect(try helper.ask("harden") == "hardened true")
        #expect(try helper.ask("connect \(path)") == "connected")
        let served = try SocketsTests.accepted(from: listener)
        defer { Sys.close(served) }
        let peer = try #require(Platform.Sockets.peerToken(served))
        let token = try #require(Platform.Processes.token(helper.pid))
        // What both systems' tokens have, so that this compiles on the Mac too (an `audit_token_t` has no `==` and
        // no `uid`); the whole token below.
        #expect(token.sameImage(as: peer))
        #expect(token.pid == peer.pid)
        #if os(Linux)
        #expect(token == peer)
        #expect(token.uid == geteuid())
        #endif
        #expect(Platform.Processes.isDumpable(helper.pid) == false)
    }

    #if os(Linux)
    /// A zombie (ended, not reaped yet) reads as neither dumpable nor not: its /proc/<pid>/fd is root's whether or
    /// not it hardened, its memory being gone. Never hardened, it would read false without the zombie check.
    @Test func aZombieReadsAsNeitherDumpableNorNot() throws {
        let helper = try Helper.start()
        defer { helper.end() }
        #expect(Platform.Processes.isDumpable(helper.pid) == true)
        helper.release()
        // Waits for its end, and leaves it unreaped (WNOWAIT): a zombie until `end()` reaps it.
        var info = siginfo_t()
        var waited: Int32 = -1
        repeat { waited = waitid(P_PID, id_t(helper.pid), &info, WEXITED | WNOWAIT) } while waited < 0 && errno == EINTR
        try #require(waited == 0, "waitid: errno \(errno)")
        guard case .line(let line) = Platform.Processes.System.statLine(helper.pid) else {
            Issue.record("no stat line for the zombie \(helper.pid)")
            return
        }
        #expect(line.isZombie)
        #expect(Platform.Processes.isDumpable(helper.pid) == nil)
        #expect(helper.end().exit == 0)
    }

    /// A process that ends never reads as hardened. From when its memory goes (before it is a zombie) its /proc
    /// entries are root's, as a non-dumpable process's are: read then, it must read as neither, or a connector that
    /// asks whether a child is hardened before it hands it a descriptor (Task 4) could be told yes of one that never
    /// did. Children that end at once (`cat` on a stdin closed), each read again and again until it is a zombie.
    @Test func anEndingProcessNeverReadsAsHardened() throws {
        var answers: [Bool?: Int] = [:]
        for _ in 0..<300 {
            let child = try SpawnTests.held(.inherit)
            close(child.release)
            while true {
                answers[Platform.Processes.isDumpable(child.pid), default: 0] += 1
                guard case .line(let line) = Platform.Processes.System.statLine(child.pid), !line.isZombie else { break }
            }
            #expect(SpawnTests.ended(child.pid).exit == 0)
        }
        #expect(answers[false] == nil, "answers: \(answers)")
        #expect(answers[true] != nil, "answers: \(answers)")
    }

    /// Whether a process is dumpable, from its /proc/<pid>/fd's owner and its effective user: its own user's, it is;
    /// root's, it isn't; anyone else's, it can't be told. A process of root's can't be told either: its entries are
    /// root's whether or not it is dumpable.
    @Test func dumpableIsToldFromTheOwnerOfItsDescriptors() {
        typealias System = Platform.Processes.System
        #expect(System.dumpable(descriptorsOwner: 1000, effectiveUser: 1000) == true)
        #expect(System.dumpable(descriptorsOwner: 0, effectiveUser: 1000) == false)
        #expect(System.dumpable(descriptorsOwner: 1001, effectiveUser: 1000) == nil)
        #expect(System.dumpable(descriptorsOwner: 0, effectiveUser: 0) == nil)
        #expect(System.dumpable(descriptorsOwner: 1000, effectiveUser: 0) == nil)
    }
    #endif

    /// A hardened process made dumpable again is open again: its memory, and its descriptors' owner its own user.
    @Test(.enabled(if: onLinux, "Linux's /proc; the Mac's forms do nothing")) func aProcessMadeDumpableAgainIsOpenAgain() throws {
        let helper = try Helper.start()
        defer { helper.end() }
        #expect(try helper.ask("harden") == "hardened true")
        #expect(Self.openMemory(of: helper.pid) == EACCES)
        #expect(try helper.ask("undump") == "undumped true")
        #expect(try helper.ask("dumpable") == "dumpable true")
        #expect(Platform.Processes.isDumpable(helper.pid) == true)
        #expect(Self.openMemory(of: helper.pid) == 0)
        #expect(helper.end().exit == 0)
    }

    /// The Mac's hardening is nothing, and says so; it reads no tracer and no dumpable state. Asked of a helper, so
    /// that a Mac form that did harden wouldn't harden the test process.
    @Test(.enabled(if: !onLinux, "the Mac's forms; Linux's are tested above")) func hardeningIsNothingOnTheMac() throws {
        let helper = try Helper.start()
        defer { helper.end() }
        #expect(try helper.ask("harden") == "hardened false")
        #expect(try helper.ask("dumpable") == "dumpable nil")
        #expect(try helper.ask("tracer") == "tracer nil")
        #expect(try helper.ask("undump") == "undumped false")
        #expect(Platform.Processes.isDumpable(helper.pid) == nil)
        #expect(helper.end().exit == 0)
    }

    // MARK: Tracers

    /// The test process and a helper are traced by nobody: 0, read from their own status.
    @Test(.enabled(if: onLinux, "Linux's /proc; the Mac reads no tracer")) func noOneTracesTheTestOrItsHelper() throws {
        #expect(Platform.ProcessSelf.tracer() == 0)
        let helper = try Helper.start()
        defer { helper.end() }
        #expect(try helper.ask("tracer") == "tracer 0")
        #expect(try helper.ask("harden") == "hardened true")
        #expect(try helper.ask("tracer") == "tracer 0")
    }

    /// The fields of /proc/<pid>/status around TracerPid, as Linux 5.15 writes them, with the tracer given.
    static func status(tracer: String) -> String {
        """
        Name:\tvibeswitcher-ho
        Umask:\t0022
        State:\tS (sleeping)
        Tgid:\t4100
        Ngid:\t0
        Pid:\t4100
        PPid:\t1
        TracerPid:\t\(tracer)
        Uid:\t1000\t1000\t1000\t1000
        Gid:\t1000\t1000\t1000\t1000
        FDSize:\t64

        """
    }

    @Test func tracerPidIsReadFromStatus() {
        #expect(Platform.ProcessSelf.tracer(fromStatus: Self.status(tracer: "0")) == 0)
        #expect(Platform.ProcessSelf.tracer(fromStatus: Self.status(tracer: "4242")) == 4242)
        // Not a status: no answer, never "no tracer".
        #expect(Platform.ProcessSelf.tracer(fromStatus: "") == nil)
        #expect(Platform.ProcessSelf.tracer(fromStatus: "Name:\tsleep\nPid:\t12\n") == nil)
        #expect(Platform.ProcessSelf.tracer(fromStatus: Self.status(tracer: "")) == nil)
        #expect(Platform.ProcessSelf.tracer(fromStatus: Self.status(tracer: "42x")) == nil)
        #expect(Platform.ProcessSelf.tracer(fromStatus: Self.status(tracer: "-1")) == nil)
        // A field whose name only starts the same isn't it.
        #expect(Platform.ProcessSelf.tracer(fromStatus: "TracerPidx:\t7\nTracerPid:\t9\n") == 9)
    }

    /// The effective user is the second of the Uid line's four (real, effective, saved, file system).
    @Test func theEffectiveUserIsReadFromStatus() {
        #expect(Platform.ProcessSelf.effectiveUser(fromStatus: Self.status(tracer: "0")) == 1000)
        #expect(Platform.ProcessSelf.effectiveUser(fromStatus: "Uid:\t1000\t0\t1000\t1000\n") == 0)
        #expect(Platform.ProcessSelf.effectiveUser(fromStatus: "Uid:\t1000\n") == nil)
        #expect(Platform.ProcessSelf.effectiveUser(fromStatus: "Name:\tsleep\n") == nil)
    }
}
