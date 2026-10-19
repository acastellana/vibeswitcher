import Darwin
import Foundation
import Testing
@testable import VibeCore

/// The process table is read a process at a time (`proc_listallpids`), within a time limit, whole or not at all: on a
/// Mac running several test suites the whole-table sysctl (KERN_PROC_ALL) stalled for 10 to 80 s, and the app's scan,
/// the lead's witness and the lead tools all waited on it.
struct ProcessTableTests {
    /// Each process as the kernel's own record of it says (sysctl KERN_PROC_PID): parent, name, terminal, start time.
    @Test func aSnapshotSaysWhatTheKernelsRecordSays() throws {
        let table = try #require(ProcessTable.trySnapshot())
        let me = try #require(table[getpid()])
        #expect(table[me.ppid] != nil)
        var compared = 0
        for process in table.values {
            // Ended meanwhile, or its pid reused.
            guard let record = ProcessTable.info(pid: process.pid), record.startTime == process.startTime else { continue }
            compared += 1
            if same(process, record) { continue }
            // Changed between the two reads (a process losing its terminal as its pty closes): read both again at once.
            let again = ProcessTable.record(process.pid, arguments: ProcessTable.argumentCache)
            guard case .found(let now) = again, let kernel = ProcessTable.info(pid: process.pid), kernel.startTime == now.startTime else { continue }
            #expect(same(now, kernel), "\(now.pid): \(now.ppid) \(now.comm) \(now.tty ?? "-") vs \(kernel.ppid) \(kernel.comm) \(kernel.tty ?? "-")")
        }
        #expect(compared > table.count / 2)
        // Another user's processes too (launchd's children run as root and as daemons' users).
        #expect(table[1]?.comm == "launchd")
    }

    private func same(_ a: ProcInfo, _ b: ProcInfo) -> Bool {
        a.ppid == b.ppid && a.comm == b.comm && a.tty == b.tty && a.startTime == b.startTime
    }

    /// A process started just before is in it, and gone just after it ended (a zombie isn't a process that runs).
    @Test func aSnapshotIsCurrent() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        defer { if child.isRunning { kill(pid, SIGKILL) } }
        #expect(ProcessTable.trySnapshot()?[pid]?.comm == "sleep")
        kill(pid, SIGKILL)
        child.waitUntilExit()
        #expect(ProcessTable.trySnapshot().map { $0[pid] == nil } == true)
    }

    /// Every core busy twice over, a snapshot stays about as quick as on this Mac without them: each one whole, the
    /// median of five within 20 times the fastest of three taken before, and none near a hang (the whole-table sysctl it
    /// replaced stalled 10 to 80 s). Relative, not a bare bound: a loaded Mac stalls any one read now and then (0.741 s
    /// once at load 49), while a regression makes every one slow.
    ///
    /// On a Mac already over scripts/test-under-load.sh's threshold (2 × ncpu: a merge's run beside other leads' teams,
    /// 1.2 to 2.1 s a read at load 81.6) its speed is the other sessions', not this code's: no burners, and only what
    /// holds at any load is checked, that a read that came back is whole. The numbers are printed with the load.
    @Test func aSnapshotIsQuickOnABusyMac() throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let ambient = AmbientLoad()
        var unread = 0
        let timed = { () -> TimeInterval in
            let started = Date()
            let table = ProcessTable.trySnapshot()
            let took = Date().timeIntervalSince(started)
            if let table { expectWhole(table) } else { unread += 1 }
            return took
        }
        let quiet = (0..<3).map { _ in timed() }
        var burners: [Process] = []
        defer {
            for burner in burners where burner.isRunning { kill(burner.processIdentifier, SIGKILL) }
            for burner in burners { burner.waitUntilExit() }
        }
        // As scripts/test-under-load.sh would: 2 × ncpu at most, only on a Mac not already that loaded, killed by pid.
        if ambient.allows {
            for _ in 0..<(2 * cores) {
                let burner = Process()
                burner.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
                burner.standardOutput = FileHandle.nullDevice
                try burner.run()
                burners.append(burner)
            }
        }
        let times = (0..<5).map { _ in timed() }
        let fastest = try #require(quiet.min())
        let median = times.sorted()[times.count / 2]
        let shown = { (times: [TimeInterval]) in times.map { String(format: "%.3f s", $0) } }
        print("ProcessTableTests: \(ambient) on \(cores) cores, \(burners.count) burners added; snapshots took \(shown(quiet)) before, \(shown(times)) with them; \(unread) of 8 not read within \(ProcessTable.snapshotLimit) s")
        // No read waits past its limit, whatever the load (a caller is told nil then).
        #expect(times.allSatisfy { $0 < ProcessTable.snapshotLimit + 1 }, "snapshots took \(shown(times))")
        guard ambient.allows else { return }
        #expect(unread == 0, "\(unread) of 8 snapshots not read at \(ambient)")
        #expect(median <= 20 * fastest, "median \(shown([median])[0]), fastest before the burners \(shown([fastest])[0])")
    }

    /// The 1-minute load when a test started and whether it's under scripts/test-under-load.sh's threshold (2 × ncpu),
    /// so that a test's own load can be judged: over it, the Mac's speed is other sessions' (a merge's run beside other
    /// leads' teams), and a test checks only what holds at any load.
    private struct AmbientLoad: CustomStringConvertible {
        let load: Double
        let threshold = Double(2 * ProcessInfo.processInfo.processorCount)
        init() {
            var load = [Double](repeating: 0, count: 3)
            getloadavg(&load, 3)
            self.load = load[0]
        }
        var allows: Bool { load < threshold }
        var description: String {
            String(format: "load %.1f (%@ the threshold %.0f)", load, allows ? "under" : "over", threshold)
        }
    }

    /// A table read is whole: this process, its parent and launchd in it, and more processes than cores twice over.
    private func expectWhole(_ table: [Int32: ProcInfo]) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        #expect(table.count > 2 * cores, "a table of \(table.count) processes")
        #expect(table[getpid()] != nil && table[getppid()] != nil && table[1] != nil, "this process, its parent or launchd missing")
    }

    /// A pseudo-terminal is named as devname() names it (without its scan of /dev). One closed before it was named
    /// (some process still has it as its own) has no name, and that isn't kept: the next one opened on its number is
    /// named.
    @Test func aTerminalIsNamedByItsNumber() throws {
        let open = try openPty()
        defer { close(open.master) }
        #expect(ProcessTable.ttyName(open.device) == open.name)
        #expect(devname(open.device, S_IFCHR).map { String(cString: $0) } == open.name)
        let (master, device, name) = try openPty()
        close(master)
        var node = stat()
        #expect(eventually { stat("/dev/" + name, &node) != 0 })
        #expect(ProcessTable.ttyName(device) == nil)
        // Pseudo-terminals are numbered lowest free first: the next ones opened take its number again, unless another
        // session on this Mac took it meanwhile.
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        for _ in 0..<4 {
            let again = try openPty()
            opened.append(again.master)
            #expect(ProcessTable.ttyName(again.device) == again.name)
            if again.device == device { return }
        }
        print("ProcessTableTests: no pseudo-terminal opened on \(name) again (another session took it)")
    }

    /// A new pseudo-terminal: its master, and its terminal's device and name ("ttys012").
    private func openPty() throws -> (master: Int32, device: dev_t, name: String) {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(master >= 0 && grantpt(master) == 0 && unlockpt(master) == 0)
        let path = try #require(ptsname(master).map { String(cString: $0) })
        var node = stat()
        try #require(stat(path, &node) == 0)
        return (master, node.st_rdev, (path as NSString).lastPathComponent)
    }

    /// A read past its time limit leaves its caller at the limit, told nil; while it's still stuck in the kernel the
    /// next caller is told nil at once; once it's done, reads go on.
    @Test func aCallerWaitsTheTimeLimitAtMost() {
        let reads = BoundedReads()
        let release = DispatchSemaphore(value: 0)
        let started = Date()
        let stuck: Int? = reads.read(within: 0.3) { _ in release.wait(); return 1 }
        #expect(stuck == nil)
        #expect(Date().timeIntervalSince(started) < 2)
        let behind = Date()
        #expect(reads.read(within: 5) { _ in 2 } == nil)
        #expect(Date().timeIntervalSince(behind) < 1)
        release.signal()
        #expect(eventually { reads.read(within: 5) { _ in 3 } == 3 })
        // A read that gives up at its own deadline is told as such: nil, not a value.
        #expect(reads.read(within: 5) { (_: Date) -> Int? in nil } == nil)
        #expect(reads.read(within: 5) { _ in 4 } == 4)
    }

    /// The deadline is the read's own too: one past it stops and says nil, not part of the table.
    @Test func aReadPastItsDeadlineIsNoTable() {
        #expect(ProcessTable.readTable(until: Date()) == nil)
        #expect(ProcessTable.readTable(until: Date().addingTimeInterval(5)) != nil)
    }

    /// The pid list unread is no table, as past the deadline: the two ways a read is nil.
    @Test func anUnreadPidListIsNoTable() {
        #expect(ProcessTable.readTable(until: Date().addingTimeInterval(5), pids: { nil }) == nil)
    }

    /// One of the user's terminal processes whose argv can't be read (so whether it's an agent is unknown) is in the
    /// table as unknown: no agent, not a session's end, not the table's loss. Told once more after a pause, not more.
    @Test func aProcessThatCantBeToldIsUnknown() throws {
        let (terminal, pid) = try sleeperOnATerminal()
        defer { stop(terminal) }
        let reads = Reads()
        let blind = ArgumentCache { $0 == pid ? (reads.next(), []).1 : ProcessTable.readArguments(pid: $0) }
        let table = try #require(ProcessTable.readTable(until: Date().addingTimeInterval(5), arguments: blind))
        let sleeper = try #require(table[pid])
        #expect(sleeper.identityUnknown)
        #expect(sleeper.agent == nil)
        #expect(sleeper.comm == "sleep" && sleeper.tty != nil)
        #expect(reads.made == 2)
        // No argv readable at all: the user's terminal processes are unknown, the rest (no terminal) known.
        let none = try #require(ProcessTable.readTable(until: Date().addingTimeInterval(5), arguments: ArgumentCache { _ in [] }))
        #expect(none[pid]?.identityUnknown == true)
        #expect(none[1]?.identityUnknown == false)
        #expect(none[getpid()].map { $0.tty != nil || !$0.identityUnknown } == true)
    }

    /// One whose argv can be read after a moment is told: an agent, or not one, never unknown.
    @Test func aProcessToldOnTheRetryIsKnown() throws {
        let (terminal, pid) = try sleeperOnATerminal()
        defer { stop(terminal) }
        let reads = Reads()
        let late = ArgumentCache { $0 == pid ? (reads.next() == 1 ? [] : ["/Users/me/.local/bin/claude"]) : ProcessTable.readArguments(pid: $0) }
        let table = try #require(ProcessTable.readTable(until: Date().addingTimeInterval(5), arguments: late))
        #expect(table[pid]?.agent == .claude)
        #expect(table[pid]?.identityUnknown == false)
        #expect(reads.made == 2)
    }

    /// A read that has its undecided processes to tell again and no time left for the pause is past its deadline: nil.
    @Test func noTimeForThePauseIsNoTable() throws {
        let (terminal, pid) = try sleeperOnATerminal()
        defer { stop(terminal) }
        let blind = ArgumentCache { $0 == pid ? [] : ProcessTable.readArguments(pid: $0) }
        #expect(ProcessTable.readTable(until: Date().addingTimeInterval(5), arguments: blind, pause: 60) == nil)
    }

    /// Processes are mid-exec all the time on a Mac running builds and tests: a terminal's process whose argv can't be
    /// read yet doesn't cost the table. Fifty snapshots in a row while shells on a terminal fork and exec as fast as
    /// they can are all read, and each has a process that runs throughout.
    @Test func execsOnATerminalDontCostTheTable() throws {
        let ambient = AmbientLoad()
        let one = "i=0; while [ $i -lt 100000 ] && kill -0 $PPID 2>/dev/null; do /bin/date >/dev/null; i=$((i+1)); done"
        let loop = try onATerminal((0..<4).map { _ in "(\(one)) &" }.joined(separator: " ") + " wait")
        defer { stop(loop) }
        try snapshotsStayWhole(while: loop, pause: 0.01, ambient: ambient)
    }

    /// The same while a `swift build` of a tiny package runs on a terminal (its compilers and linkers exec there).
    @Test func aBuildOnATerminalDoesntCostTheTable() throws {
        let ambient = AmbientLoad()
        let package = scratch.url("tiny-package")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Sources/Tiny"), withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Tiny", targets: [.executableTarget(name: "Tiny")])
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "print(\"tiny\")\n".write(to: package.appendingPathComponent("Sources/Tiny/main.swift"), atomically: true, encoding: .utf8)
        let build = try onATerminal("swift build --package-path '\(package.path)'")
        defer { stop(build) }
        try snapshotsStayWhole(while: build, pause: 0.1, ambient: ambient)
    }

    /// An exec'd process on a terminal whose argv can't be read twice in a row (an exec in progress on a loaded Mac)
    /// doesn't cost the table: it's in it.
    @Test func aProcessMidExecIsInTheTable() throws {
        let (terminal, pid) = try sleeperOnATerminal()
        defer { stop(terminal) }
        let reads = Reads()
        let midExec = ArgumentCache { $0 == pid && reads.next() <= 2 ? [] : ProcessTable.readArguments(pid: $0) }
        let table = ProcessTable.readTable(until: Date().addingTimeInterval(5), arguments: midExec)
        #expect(table?[pid]?.comm == "sleep")
    }

    /// `/bin/sleep 60` on a terminal of its own (exec'd by the terminal's shell), and its pid.
    private func sleeperOnATerminal() throws -> (terminal: Process, pid: pid_t) {
        let terminal = try onATerminal("exec /bin/sleep 60")
        var pid: pid_t = 0
        let started = eventually(timeout: 30) {
            var children = [pid_t](repeating: 0, count: 4)
            let count = children.withUnsafeMutableBytes { proc_listchildpids(terminal.processIdentifier, $0.baseAddress, Int32($0.count)) }
            guard count > 0, let info = ProcessTable.info(pid: children[0]), info.comm == "sleep", info.tty != nil else { return false }
            pid = children[0]
            return true
        }
        if !started { stop(terminal) }
        try #require(started)
        return (terminal, pid)
    }

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var made: Int { lock.lock(); defer { lock.unlock() }; return count }
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    private let scratch = Scratch()

    /// 50 snapshots in a row, `pause` apart: every one read, with a `sleep` started before them in it. A read that came
    /// back never lacks it (never part of the table), at any load; every one comes back only when the Mac was under
    /// scripts/test-under-load.sh's threshold when the test started (`ambient`, taken before its load): over it, those
    /// not read in time are counted and printed, not failed.
    private func snapshotsStayWhole(while load: Process, pause: TimeInterval, ambient: AmbientLoad) throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["120"]
        try sleeper.run()
        defer { stop(sleeper) }
        var unread = 0
        var partial = 0
        var onATerminal = false
        for _ in 0..<50 {
            guard let table = ProcessTable.trySnapshot() else {
                unread += 1
                Thread.sleep(forTimeInterval: pause)
                continue
            }
            if table[sleeper.processIdentifier]?.comm != "sleep" { partial += 1 }
            // The load's shell is on its terminal (else its processes would never be in question).
            if table.values.contains(where: { $0.ppid == load.processIdentifier && $0.tty != nil }) { onATerminal = true }
            Thread.sleep(forTimeInterval: pause)
        }
        var load1 = [Double](repeating: 0, count: 3)
        getloadavg(&load1, 3)
        print("ProcessTableTests: \(unread) of 50 snapshots not read, \(partial) without the sleeper, started at \(ambient), load \(load1[0]) at the end; load still running: \(load.isRunning)")
        #expect(partial == 0, "\(partial) of 50 snapshots without a process that ran throughout")
        // Seen in at least one table read (all 50 unread is only possible over the threshold, checked below).
        #expect(onATerminal || unread == 50)
        guard ambient.allows else { return }
        #expect(unread == 0, "\(unread) of 50 snapshots not read at \(ambient)")
    }

    /// `command` run by /bin/sh on a terminal of its own that is its controlling terminal, as a session's processes are
    /// (`script` makes one; this test process may have none). It stops when `script` does (`$PPID`, or SIGHUP).
    private func onATerminal(_ command: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", command]
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Stops `process` and, when it's a terminal's `script`, everything on that terminal (its shell's process group).
    private func stop(_ process: Process) {
        let pid = process.processIdentifier
        var children = [pid_t](repeating: 0, count: 16)
        let count = children.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        for child in children.prefix(Int(max(0, count))) where child > 0 && getpgid(child) == child { kill(-child, SIGKILL) }
        if process.isRunning { kill(pid, SIGKILL) }
        process.waitUntilExit()
    }

    @Test func identity() {
        let claude = ArgumentCache { _ in ["/Users/me/.local/bin/claude"] }
        let blind = ArgumentCache { _ in [] }
        #expect(ProcessTable.identify(pid: 7, start: 1, comm: "2.1.302", tty: "ttys001", arguments: claude) == .agent(.claude))
        #expect(ProcessTable.identify(pid: 7, start: 1, comm: "2.1.302", tty: "ttys001", arguments: blind) == .unknown)
        #expect(ProcessTable.identify(pid: 7, start: 1, comm: "codex", tty: "ttys001", arguments: blind) == .unknown)
        #expect(ProcessTable.identify(pid: 7, start: 1, comm: "claude", tty: "ttys001", arguments: blind) == .agent(.claude))
        #expect(ProcessTable.identify(pid: 7, start: 1, comm: "2.1.302", tty: nil, arguments: blind) == ProcessTable.Identity.none)
        // Another user's process: by its name alone.
        #expect(ProcessTable.identify(pid: 7, start: 1, comm: "login", tty: "ttys001", arguments: nil) == ProcessTable.Identity.none)
        #expect(ProcessTable.identify(pid: 7, start: 1, comm: "codex", tty: "ttys001", arguments: nil) == .agent(.codex))
    }
}
