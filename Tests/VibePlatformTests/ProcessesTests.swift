import Foundation
import Testing
import VibePlatform

/// `Platform.Processes` on the system the tests run on: this process, and children the tests start, each ended and
/// collected before its test returns. A test waits for what it checks (a child's end, a number that grows), asking
/// again every few milliseconds, never for a time.
struct ProcessesTests {
    typealias Processes = Platform.Processes

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// How long a test waits for what it checks before it calls it lost: only a guard, sized for a machine running
    /// several suites at once, never a measure of speed.
    static let hangGuard: TimeInterval = 300

    // MARK: Children

    /// A child of this process that stays until its test ends it.
    final class Child {
        let process: Process
        /// What it reads, when the test holds the other end.
        private let input: Pipe?

        init(_ process: Process, input: Pipe? = nil) {
            self.process = process
            self.input = input
        }

        var pid: pid_t { process.processIdentifier }

        /// Ends it (KILL, which a stopped one takes too) and collects it.
        func end() {
            try? input?.fileHandleForWriting.close()
            if process.isRunning { kill(pid, SIGKILL) }
            process.waitUntilExit()
        }
    }

    /// Runs `work`, a blocking call, on a thread of its own and awaits what it returns: the test's task gives back its
    /// thread of the cooperative pool meanwhile.
    static func offPool<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            let thread = Thread { done.resume(returning: work()) }
            thread.name = "offPool"
            thread.start()
        }
    }

    /// `process.run()` on a thread of its own with no signal blocked: a process started on Linux from a task's thread
    /// (libdispatch's, which blocks every signal it can) inherits that, and would end only by KILL.
    static func run(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let thread = Thread {
                var none = sigset_t()
                sigemptyset(&none)
                pthread_sigmask(SIG_SETMASK, &none, nil)
                done.resume(with: Result { try process.run() })
            }
            thread.name = "start"
            thread.start()
        }
    }

    static func process(_ executable: String, _ arguments: [String], in directory: URL? = nil, adding extra: [String: String] = [:]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// `executable arguments` as a child, started and no more: reading `input`, its outputs dropped. It is a process
    /// from here on, but not yet surely the program: on Linux a child is first a copy of its parent (its arguments
    /// and name the parent's) and then, while the kernel puts the program in its place, has no arguments at all.
    static func start(_ executable: String, _ arguments: [String] = [], input: FileHandle = .nullDevice) async throws -> Child {
        let process = process(executable, arguments)
        process.standardInput = input
        try await run(process)
        return Child(process)
    }

    /// A child that surely runs its program: one that repeats what it reads (/bin/cat by default), given a line and
    /// waited for until it has said it back. It then waits for more, until the test ends it.
    static func startEchoing(_ executable: String = "/bin/cat", _ arguments: [String] = [], in directory: URL? = nil,
                             adding extra: [String: String] = [:]) async throws -> Child {
        let process = process(executable, arguments, in: directory, adding: extra)
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try await run(process)
        let child = Child(process, input: input)
        // One that never answers is ended, which ends the read below.
        let lost = DispatchWorkItem { kill(process.processIdentifier, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + hangGuard, execute: lost)
        defer { lost.cancel() }
        let line = Data("ready\n".utf8)
        let answer = await offPool { () -> Data in
            try? input.fileHandleForWriting.write(contentsOf: line)
            var read = Data()
            while !read.contains(0x0a) {
                let more = output.fileHandleForReading.availableData
                if more.isEmpty { break }
                read.append(more)
            }
            return read
        }
        guard answer == line else {
            child.end()
            throw NotEchoing(executable: executable, answer: String(decoding: answer, as: UTF8.self))
        }
        return child
    }

    struct NotEchoing: Error {
        let executable: String
        let answer: String
    }

    /// `/bin/sh -c script` as a child nobody collects until the test does: Foundation's `Process` collects its own the
    /// moment they end, and a zombie is a child that ended and hasn't been.
    static func spawnUncollected(_ script: String) throws -> pid_t {
        let arguments: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", script].map { strdup($0) } + [nil]
        let environment: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
        }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, "/bin/sh", nil, nil, arguments, environment)
        guard code == 0 else { throw Platform.Errno(code: code) }
        return pid
    }

    /// Waits for a child to end and leaves it uncollected: a zombie from here on.
    static func waitUncollected(_ pid: pid_t) {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
    }

    /// Collects a child that ended (or waits for it to).
    static func collect(_ pid: pid_t) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }

    /// Waits until `condition` holds, asking every few milliseconds; false when it didn't within `hangGuard`.
    static func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(hangGuard)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    /// A new folder of one test's own: under the run's TMPDIR (scripts/test.sh's scratch), or the package's .build
    /// when the run was given none. The test removes it.
    static func scratch(_ name: String) throws -> URL {
        let given = ProcessInfo.processInfo.environment["TMPDIR"] ?? ""
        let root = given.hasPrefix("/") ? URL(fileURLWithPath: given, isDirectory: true)
            : repo.appendingPathComponent(".build/test-scratch", isDirectory: true)
        let folder = root.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A path with its symlinks resolved, as the kernel names a process's folder, program and files.
    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A copy of /bin/cat under `name` in `folder`: a program whose name is the test's to choose.
    static func cat(named name: String, in folder: URL) throws -> URL {
        let copy = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: real("/bin/cat")), to: copy)
        return copy
    }

    static func isGone(_ read: Processes.Read) -> Bool {
        if case .gone = read { return true }
        return false
    }

    static func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }

    // MARK: This process

    @Test func thisProcessIsInTheTable() throws {
        let pids = try #require(Processes.allPids())
        #expect(pids.contains(getpid()))
        #expect(pids.contains(getppid()))
        #expect(pids.contains(1))
        #expect(!pids.contains { $0 <= 0 })
        #expect(Set(pids).count == pids.count)
    }

    @Test func itsRecordNamesItsParentAndOwner() throws {
        guard case .record(let record) = Processes.record(getpid()) else {
            Issue.record("this process's record: \(Processes.record(getpid()))")
            return
        }
        #expect(record.pid == getpid())
        #expect(record.ppid == getppid())
        #expect(record.pgid == getpgrp())
        #expect(record.uid == geteuid())
        #expect(!record.name.isEmpty)
        #expect(record.longName.hasPrefix(record.name))
        // Its first thread's state, which waits while a test runs on another.
        #expect(record.state == .running || record.state == .sleeping)
        #expect(!record.exiting)
        #expect(record.execd)
        // Started before now, and not at a time that was never read (0).
        #expect(record.start.tv_sec > 1_500_000_000)
        #expect(Self.seconds(record.start) < Date().timeIntervalSince1970 + 2)

        // The short record and the kernel's own say the same of what they hold.
        guard case .brief(let brief) = Processes.brief(getpid()) else {
            Issue.record("this process's short record: \(Processes.brief(getpid()))")
            return
        }
        #expect(brief.pid == getpid() && brief.ppid == getppid() && brief.pgid == getpgrp() && brief.uid == geteuid())
        #expect(!brief.name.isEmpty && record.name.hasPrefix(brief.name))
        #expect(!brief.exiting && brief.execd)
        let kernel = try #require(Processes.kernelRecord(getpid()))
        #expect(kernel.pid == getpid() && kernel.ppid == getppid() && kernel.pgid == getpgrp())
        #expect(kernel.name == record.name)
        #expect(kernel.terminal == record.terminal)
        #expect(kernel.foregroundGroup == record.foregroundGroup)
        #expect(kernel.start.tv_sec == record.start.tv_sec && kernel.start.tv_usec == record.start.tv_usec)
    }

    @Test func itsArgumentsStartWithItsExecutable() throws {
        let arguments = Processes.arguments(getpid())
        #expect(arguments == CommandLine.arguments)
        let first = try #require(arguments.first)
        let executable = try #require(Processes.executable(getpid()))
        #expect(executable.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: executable))
        #expect(!Processes.executableWasReplaced(getpid()))
        // Started by its path: the same file. By its name alone: that name.
        if first.contains("/") {
            #expect(Self.real(first) == Self.real(executable))
        } else {
            #expect(first == URL(fileURLWithPath: executable).lastPathComponent)
        }
        #expect(Processes.cwd(getpid()) == Self.real(FileManager.default.currentDirectoryPath))
        let resident = try #require(Processes.residentBytes(getpid()))
        // More than a megabyte and less than a terabyte: bytes, not pages or kilobytes of them.
        #expect(resident > 1 << 20 && resident < 1 << 40)
        let environment = try #require(Processes.environment(getpid()))
        // What it was started with: its PATH is among it, whatever it set since.
        #expect(environment.contains { $0.hasPrefix("PATH=") })
    }

    // MARK: Children

    @Test func aChildsArgumentsAndProgramAreItsOwn() async throws {
        let child = try await Self.startEchoing("/bin/cat", ["-"])
        defer { child.end() }
        let pid = child.pid
        #expect(Processes.arguments(pid) == ["/bin/cat", "-"])
        #expect(Processes.executable(pid) == Self.real("/bin/cat"))
        #expect(!Processes.executableWasReplaced(pid))
        guard case .record(let record) = Processes.record(pid) else {
            Issue.record("a child's record: \(Processes.record(pid))")
            return
        }
        #expect(record.pid == pid && record.ppid == getpid() && record.uid == geteuid())
        #expect(record.name == "cat")
        #expect(record.execd && !record.exiting && record.state != .zombie)
        guard case .brief(let brief) = Processes.brief(pid) else {
            Issue.record("a child's short record: \(Processes.brief(pid))")
            return
        }
        #expect(brief.ppid == getpid() && brief.uid == geteuid() && brief.name == "cat")
    }

    /// Read the moment it was started, a child's arguments are its own, or (Linux) still its parent's, or none while
    /// its program is put in place: never anything else, and its own in the end.
    @Test func aChildJustStartedHasItsOwnArgumentsSoon() async throws {
        let own = ["/bin/sleep", "300"]
        let child = try await Self.start("/bin/sleep", ["300"])
        defer { child.end() }
        let early = Processes.arguments(child.pid)
        #expect(early == own || early.isEmpty || early == CommandLine.arguments, "\(early)")
        var latest = early
        let settled = await Self.eventually {
            latest = Processes.arguments(child.pid)
            return latest == own
        }
        #expect(settled, "\(latest)")
        guard case .record(let record) = Processes.record(child.pid) else { return }
        #expect(record.name == "sleep" && record.execd)
    }

    @Test func aChildsCwdIsWhereItWasStarted() async throws {
        let folder = try Self.scratch("cwd")
        defer { try? FileManager.default.removeItem(at: folder) }
        let child = try await Self.startEchoing(in: folder)
        defer { child.end() }
        #expect(Processes.cwd(child.pid) == Self.real(folder.path))
        #if os(Linux)
        // Removed under it, the folder is nowhere: not a path that ends " (deleted)".
        try FileManager.default.removeItem(at: folder)
        #expect(Processes.cwd(child.pid) == nil)
        #endif
    }

    @Test func aChildsEnvironmentIsReadable() async throws {
        let mark = "mark \(UUID().uuidString)"
        let child = try await Self.startEchoing(adding: ["VS_PROCESSES_TEST": mark, "VS_PROCESSES_EMPTY": ""])
        defer { child.end() }
        let environment = try #require(Processes.environment(child.pid))
        #expect(environment.contains("VS_PROCESSES_TEST=\(mark)"))
        #expect(environment.contains("VS_PROCESSES_EMPTY="))
        #expect(environment.allSatisfy { $0.contains("=") })
    }

    @Test func aChildIsAmongThisProcesssChildren() async throws {
        let child = try await Self.startEchoing()
        defer { child.end() }
        let children = Processes.children(getpid())
        #expect(children.contains(child.pid))
        #expect(!children.contains(getpid()))
        #expect(Processes.children(child.pid).isEmpty)
    }

    @Test func aProcessThatExitedIsGone() async throws {
        let child = try await Self.start("/bin/sh", ["-c", "exit 0"])
        let pid = child.pid
        // Its end, collected: Foundation's wait returns after it.
        await Self.offPool { child.process.waitUntilExit() }
        #expect(Self.isGone(Processes.record(pid)), "\(Processes.record(pid))")
        if case .gone = Processes.brief(pid) {} else { Issue.record("its short record: \(Processes.brief(pid))") }
        #expect(Processes.kernelRecord(pid) == nil)
        #expect(Processes.arguments(pid).isEmpty)
        #expect(Processes.environment(pid) == nil)
        #expect(Processes.cwd(pid) == nil)
        #expect(Processes.executable(pid) == nil)
        #expect(!Processes.executableWasReplaced(pid))
        #expect(Processes.openFiles(pid).isEmpty)
        #expect(Processes.openDescriptorCount(pid) == nil)
        #expect(Processes.children(pid).isEmpty)
        #expect(Processes.cpuSeconds(pid) == nil)
        #expect(Processes.residentBytes(pid) == nil)
    }

    /// Ended and not collected yet, a child is a zombie: there, with nothing left to read but its record.
    @Test func aChildThatEndedAndIsntCollectedIsAZombie() throws {
        let pid = try Self.spawnUncollected("exit 0")
        var collected = false
        defer { if !collected { Self.collect(pid) } }
        Self.waitUncollected(pid)

        let read = Processes.record(pid)
        #if os(Linux)
        guard case .record(let record) = read else {
            Issue.record("a zombie's record: \(read)")
            return
        }
        #expect(record.state == .zombie)
        #expect(record.exiting)
        #expect(record.pid == pid && record.ppid == getpid() && record.uid == geteuid())
        #expect(Processes.children(getpid()).contains(pid))
        #else
        // The Mac's full record doesn't find a zombie (gone); its other records say what it is.
        switch read {
        case .gone: break
        case .record(let record): #expect(record.state == .zombie)
        case .partial, .unreadable: Issue.record("a zombie's record: \(read)")
        }
        #endif
        guard case .brief(let brief) = Processes.brief(pid) else {
            Issue.record("a zombie's short record: \(Processes.brief(pid))")
            return
        }
        #expect(brief.state == .zombie)
        #expect(brief.ppid == getpid() && brief.uid == geteuid())
        #expect(Processes.kernelRecord(pid)?.state == .zombie)
        #expect(Processes.arguments(pid).isEmpty)
        #expect(Processes.environment(pid) == nil)
        #expect(Processes.cwd(pid) == nil)
        #expect(Processes.executable(pid) == nil)
        #expect(Processes.openFiles(pid).isEmpty)
        #expect(Processes.residentBytes(pid) == nil)

        Self.collect(pid)
        collected = true
        #expect(Self.isGone(Processes.record(pid)), "\(Processes.record(pid))")
    }

    /// A process read over and over while it starts, runs and ends is itself at every read, a zombie or gone: never
    /// another process's record, and never a failure.
    @Test func aChildReadWhileItEndsIsItselfOrGone() throws {
        for _ in 0..<20 {
            let pid = try Self.spawnUncollected("exit 0")
            var collected = false
            defer { if !collected { Self.collect(pid) } }
            var ended = false
            var reads = 0
            let deadline = Date().addingTimeInterval(Self.hangGuard)
            while !ended, Date() < deadline {
                reads += 1
                switch Processes.record(pid) {
                case .record(let record):
                    guard record.pid == pid, record.ppid == getpid(), record.uid == geteuid() else {
                        Issue.record("read \(reads) of child \(pid) is another's: \(record)")
                        return
                    }
                    ended = record.state == .zombie
                case .gone: ended = true
                case .partial, .unreadable: break
                }
                // Whatever each says of a process on its way out, it says without failing.
                _ = Processes.brief(pid)
                _ = Processes.kernelRecord(pid)
                _ = Processes.arguments(pid)
                _ = Processes.environment(pid)
                _ = Processes.cwd(pid)
                _ = Processes.executable(pid)
                _ = Processes.openFiles(pid)
                _ = Processes.openDescriptorCount(pid)
                _ = Processes.cpuSeconds(pid)
                _ = Processes.residentBytes(pid)
            }
            #expect(ended, "child \(pid) never read as ended in \(reads) reads")
            Self.collect(pid)
            collected = true
            #expect(Self.isGone(Processes.record(pid)), "\(Processes.record(pid))")
        }
    }

    @Test func twoReadsOfOneProcesssStartAreEqual() async throws {
        let before = Date().timeIntervalSince1970
        let child = try await Self.start("/bin/sleep", ["300"])
        defer { child.end() }
        let after = Date().timeIntervalSince1970
        for pid in [getpid(), child.pid] {
            guard case .record(let first) = Processes.record(pid), case .record(let second) = Processes.record(pid),
                  let kernel = Processes.kernelRecord(pid) else {
                Issue.record("the record of \(pid): \(Processes.record(pid))")
                return
            }
            #expect(first.start.tv_sec == second.start.tv_sec && first.start.tv_usec == second.start.tv_usec)
            #expect(first.start.tv_sec == kernel.start.tv_sec && first.start.tv_usec == kernel.start.tv_usec)
            #expect(first.start.tv_usec >= 0 && first.start.tv_usec < 1_000_000)
        }
        // The child's is when it was started: by the wall clock, to the second Linux's boot time is kept in.
        guard case .record(let record) = Processes.record(child.pid) else { return }
        let start = Self.seconds(record.start)
        #expect(start > before - 2 && start < after + 2, "started \(start), between \(before) and \(after)")
    }

    @Test func cpuSecondsGrowForABusyChild() async throws {
        let begun = Date()
        let child = try await Self.start("/bin/sh", ["-c", "while :; do :; done"])
        defer { child.end() }
        let pid = child.pid
        let first = try #require(Processes.cpuSeconds(pid))
        #expect(first >= 0)
        var latest = first
        let grew = await Self.eventually {
            latest = Processes.cpuSeconds(pid) ?? latest
            return latest >= first + 0.1
        }
        #expect(grew, "\(latest) s after \(first) s")
        // One thread: never more CPU time than time has passed. Seconds, not ticks.
        #expect(latest <= Date().timeIntervalSince(begun) + 0.5, "\(latest) s of CPU")
        let resident = try #require(Processes.residentBytes(pid))
        #expect(resident > 4096 && resident < 1 << 40)
    }

    @Test func openFilesNamesAFileTheChildHolds() async throws {
        let folder = try Self.scratch("open-files")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("held.txt")
        try Data("held\n".utf8).write(to: file)
        let path = Self.real(file.path)
        // A shell that opens the file as its descriptor 3, then says its first line back and waits for a second.
        let child = try await Self.startEchoing("/bin/sh", ["-c", "exec 3< held.txt; read line; echo \"$line\"; read rest"], in: folder)
        defer { child.end() }
        let pid = child.pid

        let open = Processes.openFiles(pid)
        #expect(open.contains(path), "\(open)")
        #expect(open.allSatisfy { $0.hasPrefix("/") }, "\(open)")
        // Its input and two outputs and the file at least; never fewer than the files among them.
        let count = try #require(Processes.openDescriptorCount(pid))
        #expect(count >= 4 && count >= open.count)

        // This process, with the file open too, isn't told of the descriptor its own list is read through.
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let own = Processes.openFiles(getpid())
        #expect(own.contains(path))
        #expect(!own.contains { $0.hasPrefix("/proc/") && $0.hasSuffix("/fd") })
        let ownCount = try #require(Processes.openDescriptorCount(getpid()))
        #expect(ownCount >= 4 && ownCount >= own.count)

        #if os(Linux)
        // Removed, a file still held open is at no path: not listed, under its old name or any other.
        try FileManager.default.removeItem(at: file)
        let after = Processes.openFiles(pid)
        #expect(!after.contains { $0.hasPrefix(path) }, "\(after)")
        #expect(Processes.openDescriptorCount(pid) == count)
        #endif
    }

    /// A program whose file name holds a space and parentheses is named whole, and read as itself: on Linux its
    /// name sits in parentheses in the middle of the line every other field is read from.
    @Test func aNameWithASpaceAndParenthesesIsReadWhole() async throws {
        let folder = try Self.scratch("odd-name")
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "a b) c)"
        let program = try Self.cat(named: name, in: folder)
        let child = try await Self.startEchoing(program.path)
        defer { child.end() }
        let pid = child.pid
        guard case .record(let record) = Processes.record(pid) else {
            Issue.record("its record: \(Processes.record(pid))")
            return
        }
        #expect(record.name == name)
        #expect(record.longName == name)
        #expect(record.pid == pid && record.ppid == getpid() && record.pgid == getpgid(pid) && record.uid == geteuid())
        #expect(record.state == .running || record.state == .sleeping)
        #expect(record.execd && !record.exiting)
        guard case .brief(let brief) = Processes.brief(pid) else {
            Issue.record("its short record: \(Processes.brief(pid))")
            return
        }
        #expect(brief.name == name && brief.ppid == getpid())
        #expect(Processes.kernelRecord(pid)?.name == name)
        #expect(Processes.children(getpid()).contains(pid))
        #expect(Processes.cpuSeconds(pid) != nil)
        #expect(Processes.executable(pid) == Self.real(program.path))
        #expect(Processes.arguments(pid) == [program.path])
    }

    @Test func aStoppedChildIsStopped() async throws {
        let child = try await Self.startEchoing()
        defer { child.end() }
        let pid = child.pid
        kill(pid, SIGSTOP)
        var state = Processes.State.unknown
        let stopped = await Self.eventually {
            if case .record(let record) = Processes.record(pid) { state = record.state }
            return state == .stopped
        }
        #expect(stopped, "\(state)")
        guard case .brief(let brief) = Processes.brief(pid) else { return }
        #expect(brief.state == .stopped)
    }

    /// Another user's process (the system's first, where the tests aren't run by its owner) is in the table with its
    /// owner, parent and name, and what only its owner may read comes back as "can't be read", never as a failure.
    @Test func anotherUsersProcessIsListedWithWhatMayBeRead() throws {
        guard case .record(let record) = Processes.record(1) else {
            Issue.record("the first process's record: \(Processes.record(1))")
            return
        }
        #expect(record.pid == 1)
        #expect(!record.name.isEmpty)
        #expect(record.state != .zombie && !record.exiting)
        guard case .brief(let brief) = Processes.brief(1) else {
            Issue.record("the first process's short record: \(Processes.brief(1))")
            return
        }
        #expect(brief.uid == record.uid)
        guard let owner = record.uid, owner != geteuid() else { return }
        #expect(Processes.environment(1) == nil)
        #expect(Processes.cwd(1) == nil)
        #expect(Processes.openFiles(1).isEmpty)
        #expect(!Processes.executableWasReplaced(1))
    }

    #if os(Linux)
    /// A program whose file was removed, or had a new build put in its place, is still named by where it was, and
    /// said to be replaced; one whose own name ends " (deleted)", the kernel's words for that, isn't.
    @Test func aReplacedProgramIsNamedByWhereItWasAndSaidSo() async throws {
        let folder = try Self.scratch("replaced")
        defer { try? FileManager.default.removeItem(at: folder) }
        let program = try Self.cat(named: "tool", in: folder)
        let path = Self.real(folder.path) + "/tool"
        let child = try await Self.startEchoing(program.path)
        defer { child.end() }
        #expect(Processes.executable(child.pid) == path)
        #expect(!Processes.executableWasReplaced(child.pid))

        // A new build: written beside it and moved over it, as an install does.
        let build = try Self.cat(named: "tool.new", in: folder)
        #expect(rename(build.path, program.path) == 0)
        #expect(Processes.executable(child.pid) == path)
        #expect(Processes.executableWasReplaced(child.pid))
        // The new one's own process runs what is there.
        let next = try await Self.startEchoing(program.path)
        defer { next.end() }
        #expect(Processes.executable(next.pid) == path)
        #expect(!Processes.executableWasReplaced(next.pid))

        let odd = try Self.cat(named: "tool (deleted)", in: folder)
        let named = try await Self.startEchoing(odd.path)
        defer { named.end() }
        #expect(Processes.executable(named.pid) == path + " (deleted)")
        #expect(!Processes.executableWasReplaced(named.pid))
        guard case .record(let record) = Processes.record(named.pid) else { return }
        #expect(record.name == "tool (deleted)")
        try FileManager.default.removeItem(at: odd)
        #expect(Processes.executable(named.pid) == path + " (deleted)")
        #expect(Processes.executableWasReplaced(named.pid))
    }

    /// A process whose controlling terminal is a pseudo-terminal names it as `Terminals` names its path, and its
    /// foreground group: what a session is found by. setsid(1) makes the child a session of its own on its input.
    @Test func aChildOnATerminalNamesItAndItsForegroundGroup() async throws {
        let primary = open("/dev/ptmx", O_RDWR | O_NOCTTY)
        try #require(primary >= 0)
        defer { close(primary) }
        // unlockpt(3), which glibc keeps from Swift: TIOCSPTLCK (_IOW('T', 0x31, int)) with 0.
        var locked: Int32 = 0
        try #require(ioctl(primary, 0x4004_5431, &locked) == 0)
        var buffer = [CChar](repeating: 0, count: 128)
        try #require(vibe_ptsname_r(primary, &buffer, buffer.count) == 0)
        let path = String(cString: buffer)
        // Never this process's own terminal: O_NOCTTY.
        let secondary = open(path, O_RDWR | O_NOCTTY)
        try #require(secondary >= 0)
        let terminal = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)

        let launcher = try await Self.start("/usr/bin/setsid", ["--ctty", "/bin/sleep", "300"], input: terminal)
        // The session's first process is the terminal's foreground group: the sleep itself, whether setsid ran it in
        // its own place or in a child's (it does when it leads a group).
        var session: pid_t = 0
        defer {
            if session > 0 { kill(session, SIGKILL) }
            launcher.end()
        }
        let taken = await Self.eventually {
            session = tcgetpgrp(primary)
            return session > 0
        }
        try #require(taken, "no process took \(path) for its terminal")
        guard case .record(let record) = Processes.record(session) else {
            Issue.record("its record: \(Processes.record(session))")
            return
        }
        #expect(record.terminal == Platform.Terminals.name(devicePath: path))
        #expect(record.terminal?.hasPrefix("ttypts") == true)
        #expect(record.pgid == session)
        #expect(record.foregroundGroup == session)
        #expect(Processes.kernelRecord(session)?.terminal == record.terminal)
        // This process isn't on it.
        guard case .record(let own) = Processes.record(getpid()) else { return }
        #expect(own.terminal != record.terminal)
    }

    /// A thread's number has a folder in /proc as a process's has, and is no process: not in the list, and gone.
    @Test func aThreadsNumberIsNoProcess() throws {
        // This process's threads, its first (whose number is the process's) aside.
        let threads = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/task").compactMap { pid_t($0) }.filter { $0 != getpid() }
        let listed = try #require(Processes.allPids())
        var checked = 0
        for thread in threads {
            let read = Processes.record(thread)
            let brief = Processes.brief(thread)
            let kernel = Processes.kernelRecord(thread)
            let cpu = Processes.cpuSeconds(thread)
            // Still running after the reads (the kernel answers for its number): it was there at each.
            guard FileManager.default.fileExists(atPath: "/proc/\(thread)/stat"),
                  FileManager.default.fileExists(atPath: "/proc/self/task/\(thread)") else { continue }
            checked += 1
            #expect(Self.isGone(read), "thread \(thread): \(read)")
            if case .gone = brief {} else { Issue.record("thread \(thread)'s short record: \(brief)") }
            #expect(kernel == nil)
            #expect(cpu == nil)
            #expect(!listed.contains(thread))
        }
        #expect(checked > 0, "none of \(threads.count) threads lasted")
    }
    #endif
}
