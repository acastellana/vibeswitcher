import Foundation
import Testing
@testable import VibePlatform

// Whether this is Linux, for the trait below: /proc and its lines are Linux's alone, and so is the code that reads them.
#if os(Linux)
private let onLinux = true
#else
private let onLinux = false
#endif

/// A line of /proc/<pid>/stat taken apart (`Platform.Processes.StatLine`), on lines written out here: no process is
/// read. The line's second field is the process's name in parentheses, and the name is whatever a file was called
/// or a thread called itself, so the fields after it can only be counted from the line's last ")".
@Suite(.enabled(if: onLinux, "Linux's /proc; the Mac reads its table through libproc"))
struct ProcStatParseTests {
    #if os(Linux)
    typealias StatLine = Platform.Processes.StatLine

    /// `cat /proc/self/stat` on Ubuntu 24.04 (Linux 5.15, WSL2), as it was printed.
    static let cat = "140844 (cat) R 140820 140844 140820 0 -1 4194304 103 0 0 0 0 0 0 0 20 0 1 0 2187837 3354624 257 "
        + "18446744073709551615 94003492122624 94003492140209 140733473749216 0 0 0 0 0 0 0 0 0 17 18 0 0 0 0 0 "
        + "94003492154000 94003492155496 94003704168448 140733473755198 140733473755218 140733473755218 140733473763307 0\n"

    /// A line with these fields and the rest as `cat`'s.
    static func line(pid: Int32 = 1234, name: String, state: String = "S", ppid: Int32 = 1, pgrp: Int32 = 1234, terminal: Int32 = 0,
                     foreground: Int32 = -1, flags: UInt32 = 4_194_304, user: UInt64 = 0, system: UInt64 = 0, start: UInt64 = 2_187_837,
                     exitSignal: Int32 = 17) -> String {
        "\(pid) (\(name)) \(state) \(ppid) \(pgrp) \(pgrp) \(terminal) \(foreground) \(flags) 103 0 0 0 \(user) \(system) 0 0 20 0 1 0 "
            + "\(start) 3354624 257 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 0 \(exitSignal) 18 0 0 0 0 0 0 0 0 0 0 0 0 0\n"
    }

    @Test func aNameWithSpacesAndParenthesesIsParsedFromTheLastParenthesis() throws {
        // A program whose file is named "a b) c)", on /dev/pts/3 and in its foreground.
        let line = try #require(StatLine("1234 (a b) c)) S 1 1234 1234 34819 1234 4194560 150 0 0 0 7 3 0 0 20 0 1 0 2187837 3354624 257 "
            + "18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 0 17 3 0 0 0 0 0 0 0 0 0 0 0 0 0\n"))
        #expect(line.pid == 1234)
        #expect(line.name == "a b) c)")
        #expect(line.processState == .sleeping)
        #expect(line.ppid == 1)
        #expect(line.pgrp == 1234)
        #expect(Platform.Terminals.name(device: dev_t(line.terminal)) == "ttypts3")
        #expect(line.foregroundGroup == 1234)
        #expect(line.userTicks == 7 && line.systemTicks == 3)
        #expect(line.startTicks == 2_187_837)
        #expect(line.exitSignal == 17)
    }

    /// A name that looks like the fields after it, one with a line end in it, and one that is only parentheses.
    @Test func aNameIsNeverTakenForFields() throws {
        let disguised = try #require(StatLine(Self.line(pid: 77, name: "x) Z 999 999 999", state: "R", ppid: 42)))
        #expect(disguised.name == "x) Z 999 999 999")
        #expect(disguised.processState == .running)
        #expect(disguised.ppid == 42)
        let broken = try #require(StatLine(Self.line(name: "two\nlines", ppid: 42)))
        #expect(broken.name == "two\nlines")
        #expect(broken.ppid == 42)
        let brackets = try #require(StatLine(Self.line(name: "(()", ppid: 42)))
        #expect(brackets.name == "(()")
        #expect(brackets.ppid == 42)
        let empty = try #require(StatLine(Self.line(name: "", ppid: 42)))
        #expect(empty.name == "")
        #expect(empty.ppid == 42)
    }

    @Test func aRealLineIsReadFieldByField() throws {
        let line = try #require(StatLine(Self.cat))
        #expect(line.pid == 140_844)
        #expect(line.name == "cat")
        #expect(line.processState == .running)
        #expect(line.ppid == 140_820)
        #expect(line.pgrp == 140_844)
        // No terminal: no foreground group either, whatever the field holds.
        #expect(line.terminal == 0)
        #expect(line.foregroundGroup == nil)
        #expect(Platform.Terminals.name(device: dev_t(line.terminal)) == nil)
        #expect(line.flags == 4_194_304)
        #expect(!line.exiting)
        #expect(line.execd)
        #expect(line.userTicks == 0 && line.systemTicks == 0)
        #expect(line.startTicks == 2_187_837)
        #expect(line.exitSignal == 17)
        #expect(!line.isThread)
    }

    @Test func aZombieIsAZombie() throws {
        // As the kernel prints one: PF_EXITING (4) still among its flags, its terminal still named.
        let line = try #require(StatLine("4321 (sh) Z 1234 4321 1234 34816 4321 4227076 0 0 0 0 1 2 0 0 20 0 1 0 2190000 0 0 "
            + "18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 17 5 0 0 0 0 0 0 0 0 0 0 0 0 0\n"))
        #expect(line.processState == .zombie)
        #expect(line.isZombie)
        #expect(line.exiting)
        #expect(line.name == "sh")
        #expect(line.ppid == 1234)
        // What it used while it ran is still told.
        #expect(line.cpuSeconds(ticksPerSecond: 100) == 0.03)
    }

    @Test func startIsBootPlusTicks() throws {
        let line = try #require(StatLine(Self.line(name: "sleep", start: 2_187_837)))
        // 21,878.37 s after a boot at 1,700,000,000, at 100 ticks a second.
        let start = line.start(boot: 1_700_000_000, ticksPerSecond: 100)
        #expect(start.tv_sec == 1_700_021_878)
        #expect(start.tv_usec == 370_000)
        // Another rate: the ticks are counted in it.
        let fine = line.start(boot: 1_700_000_000, ticksPerSecond: 1000)
        #expect(fine.tv_sec == 1_700_002_187)
        #expect(fine.tv_usec == 837_000)
        // The same line and boot time: the same start, to the microsecond.
        let again = line.start(boot: 1_700_000_000, ticksPerSecond: 100)
        #expect(again.tv_sec == start.tv_sec && again.tv_usec == start.tv_usec)
    }

    @Test func theBootTimeIsItsLineOfProcStat() {
        let stat = "cpu  1 2 3 4\ncpu0 1 2 3 4\nintr 5 6\nctxt 7\nbtime 1731400000\nprocesses 99\n"
        #expect(Platform.Processes.System.bootTime(in: Array(stat.utf8)) == 1_731_400_000)
        #expect(Platform.Processes.System.bootTime(in: Array("cpu  1 2 3 4\n".utf8)) == nil)
        #expect(Platform.Processes.System.bootTime(in: []) == nil)
    }

    @Test func cpuTimeIsItsTicksOverTheRate() throws {
        let line = try #require(StatLine(Self.line(name: "busy", user: 250, system: 50)))
        #expect(line.cpuSeconds(ticksPerSecond: 100) == 3)
        #expect(line.cpuSeconds(ticksPerSecond: 1000) == 0.3)
    }

    @Test func everyStateLetterHasAState() throws {
        let states: [(String, Platform.Processes.State)] = [
            ("R", .running), ("S", .sleeping), ("D", .sleeping), ("I", .sleeping), ("T", .stopped), ("t", .stopped), ("Z", .zombie),
            ("X", .zombie), ("P", .unknown),
        ]
        for (letter, state) in states {
            let line = try #require(StatLine(Self.line(name: "any", state: letter)))
            #expect(line.processState == state, "state \(letter)")
        }
        // Dead is on its way out whatever its flags say; nothing else is by its letter alone.
        let dead = try #require(StatLine(Self.line(name: "any", state: "X")))
        let asleep = try #require(StatLine(Self.line(name: "any", state: "S")))
        #expect(dead.exiting)
        #expect(!asleep.exiting)
    }

    @Test func theFlagsSayExitingAndForked() throws {
        // PF_EXITING is 0x4 and PF_FORKNOEXEC 0x40, among others (PF_RANDOMIZE, 0x400000, here).
        let exiting = try #require(StatLine(Self.line(name: "any", flags: 0x400004)))
        #expect(exiting.exiting && exiting.execd)
        let forked = try #require(StatLine(Self.line(name: "any", flags: 0x400040)))
        #expect(!forked.exiting && !forked.execd)
    }

    /// A terminal's number: none, a pseudo-terminal, and one whose minor is past 255 (its high bits are the number's
    /// top ones, so it prints as a negative number).
    @Test func theTerminalIsItsDeviceNumber() throws {
        let none = try #require(StatLine(Self.line(name: "any", terminal: 0, foreground: 1234)))
        #expect(none.foregroundGroup == nil)
        let third = try #require(StatLine(Self.line(name: "any", terminal: 136 << 8 | 3, foreground: 55)))
        #expect(Platform.Terminals.name(device: dev_t(third.terminal)) == "ttypts3")
        #expect(third.foregroundGroup == 55)
        // /dev/pts/300: minor 300 is 0x12c, its low byte in bits 0 to 7 and the rest from bit 20.
        let far = try #require(StatLine(Self.line(name: "any", terminal: 0x1 << 20 | 136 << 8 | 0x2c)))
        #expect(Platform.Terminals.name(device: dev_t(far.terminal)) == "ttypts300")
        let farthest = try #require(StatLine(Self.line(name: "any", terminal: Int32(bitPattern: 0xfff0_88ff))))
        #expect(Platform.Terminals.name(device: dev_t(farthest.terminal)) == "ttypts1048575")
        // On a terminal with no foreground group.
        let alone = try #require(StatLine(Self.line(name: "any", terminal: 136 << 8 | 3, foreground: -1)))
        #expect(alone.foregroundGroup == nil)
    }

    /// A thread that isn't its process's first has a folder in /proc under its own number, with the process's line
    /// but for its own name and an exit signal of -1.
    @Test func aThreadsLineIsToldFromAProcesss() throws {
        let worker = try #require(StatLine(Self.line(name: "worker", exitSignal: -1)))
        let first = try #require(StatLine(Self.line(name: "main", exitSignal: 17)))
        // A process made to end without a signal to its parent.
        let quiet = try #require(StatLine(Self.line(name: "quiet", exitSignal: 0)))
        #expect(worker.isThread)
        #expect(!first.isThread)
        #expect(!quiet.isThread)
    }

    @Test func whatIsntALineIsNone() throws {
        #expect(StatLine("") == nil)
        #expect(StatLine("\n") == nil)
        #expect(StatLine("no parentheses at all") == nil)
        #expect(StatLine("1234 (cut") == nil)
        #expect(StatLine("1234 (cut) S 1 1234") == nil)
        #expect(StatLine("x (name) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5 0 0") == nil)
        // A field that isn't a number, and one too large for what it is.
        #expect(StatLine(Self.line(name: "any").replacingOccurrences(of: " 2187837 ", with: " soon ")) == nil)
        #expect(StatLine(Self.line(name: "any", ppid: 1).replacingOccurrences(of: ") S 1 ", with: ") S 99999999999 ")) == nil)
        // Cut after the start time: all that is read here but the exit signal.
        let short = try #require(StatLine("1234 (short) S 1 1234 1234 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 2187837"))
        #expect(short.startTicks == 2_187_837)
        #expect(short.exitSignal == nil)
        #expect(!short.isThread)
    }

    @Test func stringsEndedByNULsAreToldApart() {
        let strings = Platform.Processes.System.strings
        #expect(strings(Array("sleep\0300\0".utf8), true) == ["sleep", "300"])
        // An empty argument is one; an environment has none.
        #expect(strings(Array("sh\0-c\0\0x\0".utf8), true) == ["sh", "-c", "", "x"])
        #expect(strings(Array("A=1\0\0B=2\0".utf8), false) == ["A=1", "B=2"])
        // A title a program wrote over its arguments, with no NUL at its end.
        #expect(strings(Array("postgres: writer".utf8), true) == ["postgres: writer"])
        #expect(strings([], true) == [])
        #expect(strings([0], true) == [])
    }
    #endif
}
