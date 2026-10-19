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

    /// Every core busy twice over (unless the Mac already is), a snapshot takes well under a second.
    @Test func aSnapshotIsQuickOnABusyMac() throws {
        var burners: [Process] = []
        defer {
            for burner in burners where burner.isRunning { kill(burner.processIdentifier, SIGKILL) }
            for burner in burners { burner.waitUntilExit() }
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        if load[0] < Double(2 * cores) {
            for _ in 0..<(2 * cores) {
                let burner = Process()
                burner.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
                burner.standardOutput = FileHandle.nullDevice
                try burner.run()
                burners.append(burner)
            }
        }
        var times: [TimeInterval] = []
        for _ in 0..<5 {
            let started = Date()
            let table = ProcessTable.trySnapshot()
            times.append(Date().timeIntervalSince(started))
            #expect(table.map { $0.count > 2 * cores } == true)
        }
        let took = times.map { String(format: "%.3f s", $0) }
        print("ProcessTableTests: load \(load[0]) on \(cores) cores, \(burners.count) burners added; snapshots took \(took)")
        #expect(times.allSatisfy { $0 < 0.5 }, "snapshots took \(took)")
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

    /// One of the user's terminal processes whose argv can't be read (so whether it's an agent is unknown) makes the
    /// whole table unread, not a table without that session.
    @Test func aProcessThatCantBeToldIsNoTable() throws {
        let table = try #require(ProcessTable.trySnapshot())
        let uid = getuid()
        let undecided = table.values.contains { process in
            guard process.tty != nil, Agent(comm: process.comm) != .claude else { return false }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            return proc_pidinfo(process.pid, PROC_PIDT_SHORTBSDINFO, 1, &info, size) == size && info.pbsi_uid == uid
        }
        let blind = ArgumentCache { _ in [] }
        let read = ProcessTable.readTable(until: Date().addingTimeInterval(5), arguments: blind)
        // A Mac with none of the user's processes on a terminal has nothing to be unsure of.
        #expect(undecided ? read == nil : read != nil)
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
