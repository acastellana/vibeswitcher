import Foundation
import Testing
import VibePlatform

/// The test binary's helper mode, for a launcher's terminal: started again with `TerminalsTests.launcherVariable` set,
/// on a new terminal as its stdin, stdout and stderr and in a session of its own, it does before any test of its own
/// what the host's launcher does (`PTYSpawn.execIfLaunched`): it takes the terminal as its controlling terminal
/// (`Platform.Terminals.makeControlling(0)`). Each step is said in one line on the terminal, where the test reads it:
///
/// - "control": takes the terminal, says "controlled CODE SESSION" (`makeControlling`'s answer, then
///   `controllingSession(0)`'s, "none" for nil) and waits.
/// - "wait": says "before SESSION", waits for a line from the test, then does as "control".
///
/// It waits by reading its terminal, and ends when a read gives no line: the test closed the terminal.
private func actAsALauncherIfAsked() {
    guard let mode = getenv(TerminalsTests.launcherVariable).map({ String(cString: $0) }) else { return }
    func say(_ text: String) {
        let line = text + "\n"
        _ = write(STDOUT_FILENO, line, line.utf8.count)
    }
    func session() -> String { Platform.Terminals.controllingSession(STDIN_FILENO).map { String($0) } ?? "none" }
    func readLine() -> Bool {
        var byte: UInt8 = 0
        while true {
            let count = read(STDIN_FILENO, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return false }
            if byte == UInt8(ascii: "\n") { return true }
        }
    }
    if mode == "wait" {
        say("before \(session())")
        guard readLine() else { _exit(2) }
    }
    let code = Platform.Terminals.makeControlling(STDIN_FILENO)
    say("controlled \(code) \(session())")
    while readLine() {}
    _exit(0)
}

// Runs as the test bundle loads, as `refuseTheAccountRoot` does (TestSupport.swift).
#if os(Linux)
@_used @_section(".init_array")
private let actAsALauncher: @convention(c) () -> Void = { actAsALauncherIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let actAsALauncher: @convention(c) () -> Void = { actAsALauncherIfAsked() }
#endif

/// The test binary's helper mode for a terminal opened by a session leader that has none, as the Linux host is (a
/// systemd service leads a session of its own with no controlling terminal): started again with
/// `TerminalsTests.openerVariable` set, in a session of its own, it opens a terminal (`Platform.Terminals.open`)
/// before any test of its own and says on its stdout, in one line, whose controlling terminal the new one is and
/// whether it has one now: "master SESSION slave SESSION own ANSWER" (`session(ofMaster:)`'s and
/// `controllingSession(slave)`'s answers, "none" for nil; "none" when /dev/tty opens nothing, ENXIO, else "some" or
/// "errno N"). Opening the slave without O_NOCTTY would make it this process's controlling terminal.
private func openATerminalIfAsked() {
    guard getenv(TerminalsTests.openerVariable) != nil else { return }
    func say(_ text: String) {
        let line = text + "\n"
        _ = write(STDOUT_FILENO, line, line.utf8.count)
    }
    guard case .success(let terminal) = Platform.Terminals.open(rows: 24, cols: 80) else {
        say("no terminal: errno \(errno)")
        _exit(1)
    }
    let master = Platform.Terminals.session(ofMaster: terminal.master).map { String($0) } ?? "none"
    let slave = Platform.Terminals.controllingSession(terminal.slave).map { String($0) } ?? "none"
    let own: String
    let tty = Sys.open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
    if tty >= 0 {
        own = "some"
        Sys.close(tty)
    } else {
        own = errno == ENXIO ? "none" : "errno \(errno)"
    }
    say("master \(master) slave \(slave) own \(own)")
    _exit(0)
}

#if os(Linux)
@_used @_section(".init_array")
private let openATerminal: @convention(c) () -> Void = { openATerminalIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let openATerminal: @convention(c) () -> Void = { openATerminalIfAsked() }
#endif

/// A terminal's name, from its path and from its device number: one word with no slash, the same from both. And a
/// new terminal: both its ends close-on-exec from the start, its size, and whose controlling terminal it is.
struct TerminalsTests {
    static let launcherVariable = "VIBE_TERMINALS_TEST_LAUNCHER"
    static let openerVariable = "VIBE_TERMINALS_TEST_OPENER"

    struct Failure: Error { var what: String }

    @Test func aMacTerminalIsNamedAsItIs() {
        #expect(Platform.Terminals.name(devicePath: "/dev/ttys009") == "ttys009")
    }

    @Test func aLinuxPseudoTerminalIsNamedWithoutItsSlash() {
        #expect(Platform.Terminals.name(devicePath: "/dev/pts/3") == "ttypts3")
        #expect(Platform.Terminals.name(devicePath: "/dev/pts/1048575") == "ttypts1048575")
    }

    @Test func theProcesssOwnTerminalIsNamedTty() {
        #expect(Platform.Terminals.name(devicePath: "/dev/tty") == "tty")
    }

    /// Only a path inside a folder of /dev is changed: every other name stays what the system calls it, as the Mac's
    /// were before there was a rule (the path without "/dev/").
    @Test func otherNamesStayAsTheSystemGivesThem() {
        #expect(Platform.Terminals.name(devicePath: "/dev/console") == "console")
        #expect(Platform.Terminals.name(devicePath: "/dev/ttyS0") == "ttyS0")
        #expect(Platform.Terminals.name(devicePath: "/dev/tty1") == "tty1")
        // Not a path under /dev: as given.
        #expect(Platform.Terminals.name(devicePath: "ttys012") == "ttys012")
        #expect(Platform.Terminals.name(devicePath: "") == "")
        // In a folder whose name starts "tty" already: no second one.
        #expect(Platform.Terminals.name(devicePath: "/dev/ttyfolder/4") == "ttyfolder4")
        #expect(Platform.Terminals.name(devicePath: "/dev/a/b/c") == "ttyabc")
    }

    /// A pseudo-terminal opened here has one name, from its path and from its device number (what a process's record
    /// holds of its terminal), and the name is fit for a file's: "tty", then letters and digits, 16 at most (the
    /// steer inbox's rule).
    @Test func aTerminalsPathAndNumberGiveOneName() throws {
        var buffer = [CChar](repeating: 0, count: 128)
        // Its file is there from the moment it is opened; it is never opened here, so needn't be unlocked.
        #if os(Linux)
        let primary = open("/dev/ptmx", O_RDWR | O_NOCTTY)
        try #require(primary >= 0)
        defer { close(primary) }
        try #require(vibe_ptsname_r(primary, &buffer, buffer.count) == 0)
        #else
        let primary = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(primary >= 0)
        defer { close(primary) }
        try #require(grantpt(primary) == 0 && unlockpt(primary) == 0)
        try #require(ptsname_r(primary, &buffer, buffer.count) == 0)
        #endif
        let path = String(cString: buffer)
        var node = stat()
        try #require(stat(path, &node) == 0)

        let name = Platform.Terminals.name(devicePath: path)
        #expect(Platform.Terminals.name(device: node.st_rdev) == name)
        #expect(name.hasPrefix("tty") && name.count <= 16 && name.allSatisfy { $0.isLetter || $0.isNumber }, "\(name)")
        #if os(Linux)
        #expect(name == "ttypts" + path.dropFirst("/dev/pts/".count))
        #endif
    }

    #if os(Linux)
    /// No terminal is 0. A device that isn't a pseudo-terminal is named as the kernel names its file under /dev,
    /// where the kernel says (/sys/dev/char); one it doesn't know has no name.
    @Test func otherDevicesAreNamedByTheKernelOrNotAtAll() {
        #expect(Platform.Terminals.name(device: 0) == nil)
        // The console, 5:1, where this system shows it (a container may not).
        if FileManager.default.fileExists(atPath: "/sys/dev/char/5:1/uevent") {
            #expect(Platform.Terminals.name(device: 5 << 8 | 1) == "console")
        }
        // /dev/tty itself, 5:0.
        if FileManager.default.fileExists(atPath: "/sys/dev/char/5:0/uevent") {
            #expect(Platform.Terminals.name(device: 5 << 8) == "tty")
        }
        #expect(!FileManager.default.fileExists(atPath: "/sys/dev/char/4000:77"))
        #expect(Platform.Terminals.name(device: 4000 << 8 | 77) == nil)
    }
    #else
    @Test func noTerminalHasNoName() {
        #expect(Platform.Terminals.name(device: -1) == nil)
    }
    #endif

    // MARK: A new terminal

    /// A new terminal of `rows` × `cols`; the test closes it (`shut(_:)`).
    static func opened(rows: UInt16 = 24, cols: UInt16 = 80) throws -> Platform.Terminals.PseudoTerminal {
        switch Platform.Terminals.open(rows: rows, cols: cols) {
        case .success(let terminal): return terminal
        case .failure(let error): throw Failure(what: "no terminal: errno \(error.code)")
        }
    }

    static func shut(_ terminal: Platform.Terminals.PseudoTerminal) {
        Sys.close(terminal.slave)
        Sys.close(terminal.master)
    }

    /// Starts this binary again as a launcher (`actAsALauncherIfAsked`) on `terminal`, as the host starts its launcher:
    /// the terminal opened as its stdin with `launcherOpenFlags`, its stdout and stderr the same, a session of its own.
    static func launcher(on terminal: Platform.Terminals.PseudoTerminal, mode: String) throws -> pid_t {
        // The helper never gets as far as a test; one that did would not start another.
        try #require(getenv(launcherVariable) == nil)
        let binary = try #require(Bundle.main.executablePath)
        var spawn = Platform.Spawn(executable: binary, arguments: ProcessInfo.processInfo.arguments)
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + ["\(launcherVariable)=\(mode)"]
        spawn.stdin = .path(terminal.devicePath, flags: Platform.Terminals.launcherOpenFlags)
        spawn.stdout = .sameAsStdin
        spawn.stderr = .sameAsStdin
        spawn.group = .ownSession
        return try spawn.start().get()
    }

    /// What a terminal's program has written, read from its master as it comes.
    struct Screen {
        var master: Int32
        var text = ""

        /// The first whole line written since the start that begins with `prefix`, without its line end; it waits for
        /// one, up to `hangGuard`.
        mutating func line(startingWith prefix: String) throws -> String {
            let deadline = Date().addingTimeInterval(TestScriptLinuxTests.hangGuard)
            while true {
                // A line is whole once its end has come: the terminal ends each with "\r\n".
                let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
                if let found = lines.dropLast().first(where: { $0.hasPrefix(prefix) }) { return String(found) }
                let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1_000)
                guard left > 0 else { throw Failure(what: "no line starting \"\(prefix)\" in \(text.debugDescription)") }
                var waiting = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                let ready = poll(&waiting, 1, left)
                if ready < 0, errno == EINTR { continue }
                guard ready == 1 else { continue }
                var buffer = [UInt8](repeating: 0, count: 1_024)
                let count = Sys.read(master, &buffer, buffer.count)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { throw Failure(what: "the terminal ended (\(count), errno \(errno)) in \(text.debugDescription)") }
                text += String(decoding: buffer.prefix(count), as: UTF8.self)
            }
        }
    }

    /// Ends the helper `pid` (closing its terminal hangs it up; SIGKILL in case) and reaps it.
    static func end(_ pid: pid_t, on terminal: Platform.Terminals.PseudoTerminal) {
        shut(terminal)
        kill(pid, SIGKILL)
        _ = SpawnTests.ended(pid)
    }

    /// The host's launcher is started on its session's new terminal and takes it: the process table then names its
    /// terminal as the terminal names itself, "ttypts<N>" on Linux.
    @Test func aNewTerminalIsNamedAsTheTableNamesIt() throws {
        let terminal = try Self.opened()
        let helper: pid_t
        do { helper = try Self.launcher(on: terminal, mode: "control") } catch {
            Self.shut(terminal)
            throw error
        }
        defer { Self.end(helper, on: terminal) }
        var screen = Screen(master: terminal.master)
        #expect(try screen.line(startingWith: "controlled ") == "controlled 0 \(helper)")
        #expect(terminal.name == Platform.Terminals.name(devicePath: terminal.devicePath))
        guard case .record(let record) = Platform.Processes.record(helper) else {
            Issue.record("no record of \(helper)")
            return
        }
        #expect(record.terminal == terminal.name)
        #if os(Linux)
        #expect(terminal.name.hasPrefix("ttypts"), "\(terminal.name)")
        #expect(terminal.devicePath.hasPrefix("/dev/pts/"), "\(terminal.devicePath)")
        #endif
    }

    #if os(Linux)
    /// A launcher's terminal is nobody's controlling terminal until the launcher itself takes it: glibc's posix_spawn
    /// starts the new session before it opens the child's files, so a terminal opened without O_NOCTTY would be the
    /// child's before its first statement. The master says whose it is.
    @Test func theMastersSessionIsTheLaunchers() throws {
        let terminal = try Self.opened()
        let helper: pid_t
        do { helper = try Self.launcher(on: terminal, mode: "wait") } catch {
            Self.shut(terminal)
            throw error
        }
        defer { Self.end(helper, on: terminal) }
        var screen = Screen(master: terminal.master)
        #expect(try screen.line(startingWith: "before ") == "before none")
        #expect(Platform.Terminals.session(ofMaster: terminal.master) == nil)
        #expect(Sys.write(terminal.master, "go\n", 3) == 3)
        #expect(try screen.line(startingWith: "controlled ") == "controlled 0 \(helper)")
        #expect(Platform.Terminals.session(ofMaster: terminal.master) == helper)
    }
    #endif

    /// A terminal this process opens is never its controlling terminal, even when it leads a session that has none,
    /// as the Linux host does (a systemd service): opened so, the launcher's `makeControlling` would fail (EPERM, the
    /// terminal another session's), and closing the master would hang the host up. In a helper (`openATerminalIfAsked`)
    /// started in a session of its own with /dev/null as its stdin.
    @Test func aTerminalOpenedByASessionLeaderIsNotItsControllingTerminal() throws {
        // The helper never gets as far as a test; one that did would not start another.
        try #require(getenv(Self.openerVariable) == nil)
        let binary = try #require(Bundle.main.executablePath)
        var spawn = Platform.Spawn(executable: binary, arguments: ProcessInfo.processInfo.arguments)
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + ["\(Self.openerVariable)=1"]
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.group = .ownSession
        let ended = try SpawnTests.output(of: spawn)
        #expect(ended.output == "master none slave none own none\n", "\(ended)")
        #expect(ended.signal == nil && ended.exit == 0, "\(ended)")
    }

    /// Neither end reaches a program this process starts: each is close-on-exec from the call that made it (the Mac:
    /// right after it), and the two are one terminal, the one its path names.
    @Test func bothEndsAreClosedOnExecFromTheStart() throws {
        let terminal = try Self.opened()
        defer { Self.shut(terminal) }
        #expect(fcntl(terminal.master, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(terminal.slave, F_GETFD) & FD_CLOEXEC != 0)
        #expect(Platform.Terminals.devicePath(master: terminal.master) == terminal.devicePath)
        var master = stat(), slave = stat(), path = stat()
        try #require(fstat(terminal.slave, &slave) == 0 && stat(terminal.devicePath, &path) == 0 && fstat(terminal.master, &master) == 0)
        #expect(slave.st_rdev == path.st_rdev)
        #expect(slave.st_mode & S_IFMT == S_IFCHR)
        #expect(isatty(terminal.master) == 1 && isatty(terminal.slave) == 1)
    }

    @Test func theSizeGivenIsTheTerminals() throws {
        let terminal = try Self.opened(rows: 40, cols: 120)
        defer { Self.shut(terminal) }
        let size = try #require(Platform.Terminals.size(terminal.slave))
        #expect(size.rows == 40 && size.cols == 120)
        let fromTheMaster = try #require(Platform.Terminals.size(terminal.master))
        #expect(fromTheMaster.rows == 40 && fromTheMaster.cols == 120)
    }

    /// Asked of what is no terminal, or of a terminal that is nobody's: no answer, and the error.
    @Test func noTerminalHasNoSessionAndCantBeTaken() throws {
        #expect(Platform.Terminals.controllingSession(-1) == nil)
        #expect(Platform.Terminals.session(ofMaster: -1) == nil)
        #expect(Platform.Terminals.devicePath(master: -1) == nil)
        #expect(Platform.Terminals.size(-1) == nil)
        #expect(Platform.Terminals.makeControlling(-1) == EBADF)
        let file = Sys.open("/dev/null", O_RDONLY | O_CLOEXEC)
        try #require(file >= 0)
        defer { Sys.close(file) }
        // Linux: ENOTTY. The Mac's /dev/null (its memory device's driver) answers ENODEV to any ioctl of a terminal's.
        let taken = Platform.Terminals.makeControlling(file)
        #if os(Linux)
        #expect(taken == ENOTTY)
        #else
        #expect(taken == ENOTTY || taken == ENODEV, "errno \(taken)")
        #endif
        #expect(Platform.Terminals.controllingSession(file) == nil)
        // A new terminal is no process's controlling terminal, and this process's own (if it has one) isn't it.
        let terminal = try Self.opened()
        defer { Self.shut(terminal) }
        #expect(Platform.Terminals.controllingSession(terminal.slave) == nil)
    }
}
