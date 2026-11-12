import Foundation
import Testing
@testable import VibePlatform

#if os(Linux)
/// For `aWriteToABrokenPipeUnderTheShieldRaisesNothing`: the SIGPIPEs that land on the test's own thread. The run
/// ignores SIGPIPE (TestSupport.swift), and other tests write to broken pipes on their threads meanwhile: for them
/// the handler does what ignoring did.
private var brokenPipeThread = pthread_self()
private var brokenPipeSignals: Int32 = 0
private let countBrokenPipe: @convention(c) (Int32) -> Void = { _ in
    if pthread_equal(pthread_self(), brokenPipeThread) != 0 { brokenPipeSignals += 1 }
}
#endif

/// `Platform.pipeCommand`: a shell command fed its input and read to its end, stopped when it takes too long or a
/// stop signal comes. A command that should end by itself is given the hang guard as its patience and must come
/// back well inside it.
///
/// One at a time: one test sends this process a signal, and one changes what SIGPIPE does for its length.
@Suite(.serialized)
struct PipeCommandTests {
    static let hangGuard = TestScriptLinuxTests.hangGuard

    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// A FIFO in `folder`, open for reading: a process that holds its writing end is alive, and when the last of
    /// them has gone the reading end says so. Opened without blocking, so before any writer.
    static func lifeline(in folder: URL) throws -> (path: String, reading: Int32) {
        let path = folder.appendingPathComponent("lifeline").path
        try #require(mkfifo(path, 0o600) == 0, "mkfifo: errno \(errno)")
        let reading = open(path, O_RDONLY | O_NONBLOCK)
        try #require(reading >= 0, "\(path): errno \(errno)")
        return (path, reading)
    }

    /// What was written to the lifeline, and whether every process that held its writing end is gone: read until
    /// the end, or for the length of the hang guard.
    static func untilLetGo(_ reading: Int32) -> (written: String, letGo: Bool) {
        var written = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        let deadline = Date().addingTimeInterval(hangGuard)
        while true {
            let count = read(reading, &buffer, buffer.count)
            if count > 0 {
                written.append(contentsOf: buffer[0..<count])
                continue
            }
            // The end: no writer left.
            if count == 0 { return (text(written), true) }
            // Nothing to read while one is (EAGAIN): until there is, or the last has gone.
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return (text(written), false) }
            var polled = pollfd(fd: reading, events: Int16(POLLIN), revents: 0)
            _ = poll(&polled, 1, Int32(min(left, 3600) * 1000) + 1)
        }
    }

    /// A command that leaves a `sleep` running in its group (it says its pid on the lifeline, and holds it) and
    /// then does `then`.
    static func leavingASleep(on lifeline: String, then: String) -> String {
        "sh -c 'echo $$; exec sleep 600' > '\(lifeline)' & \(then)"
    }

    /// After a command that left a sleep: the sleep has gone with it. One that hasn't is killed here.
    static func expectTheSleepGone(_ reading: Int32, sourceLocation: SourceLocation = #_sourceLocation) {
        let lifeline = untilLetGo(reading)
        let sleeper = pid_t(lifeline.written.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(sleeper != nil, "the command's sleep never started: \(lifeline.written)", sourceLocation: sourceLocation)
        #expect(lifeline.letGo, "the command's sleep (pid \(sleeper ?? 0)) outlived it", sourceLocation: sourceLocation)
        if !lifeline.letGo, let sleeper { kill(sleeper, SIGKILL) }
    }

    @Test func pipeCommandReturnsWhatTheCommandPrinted() {
        let input = Data("one\ntwo\n".utf8)
        #expect(Platform.pipeCommand("cat", input: input, patience: Self.hangGuard, stopSignals: []) == input)
        // More than a pipe holds (64 KB): written and read by turns.
        let long = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        #expect(Platform.pipeCommand("cat", input: long, patience: Self.hangGuard, stopSignals: [SIGTERM, SIGHUP, SIGINT]) == long)
        // Its stdout alone, and its input's end at once when there is none.
        #expect(Self.text(Platform.pipeCommand("cat; echo out; echo err >&2", input: Data(), patience: Self.hangGuard, stopSignals: [])) == "out\n")
        // A pipeline's every program.
        #expect(Self.text(Platform.pipeCommand("tr a-z A-Z | sed s/ONE/1/", input: input, patience: Self.hangGuard, stopSignals: [])) == "1\nTWO\n")
    }

    /// More input than the pipe takes, and a command that never reads it: back when the command has exited, not
    /// when patience runs out, and with what it printed.
    @Test func aCommandThatIgnoresItsInputAndExitsIsNotAHang() {
        let input = Data(repeating: 0x61, count: 4_000_000)
        let started = Date()
        #expect(Self.text(Platform.pipeCommand("echo done", input: input, patience: Self.hangGuard, stopSignals: [])) == "done\n")
        // Its stdin closed, and still running: the rest of the input isn't waited on either.
        #expect(Self.text(Platform.pipeCommand("exec <&-; echo closed; cat /dev/null", input: input, patience: Self.hangGuard, stopSignals: [])) == "closed\n")
        #expect(Date().timeIntervalSince(started) < Self.hangGuard / 2)
    }

    /// The command waits on a sleep it started: at the end of its patience (3 s: time for the shell to have started
    /// the sleep on a busy machine) both are killed, and nothing was printed.
    @Test func aCommandOverItsPatienceIsStoppedAndGivesNothing() throws {
        let folder = try TestScriptLinuxTests.scratch("pipe-command")
        defer { try? FileManager.default.removeItem(at: folder) }
        let lifeline = try Self.lifeline(in: folder)
        defer { close(lifeline.reading) }
        let started = Date()
        let output = Platform.pipeCommand(Self.leavingASleep(on: lifeline.path, then: "wait"), input: Data("unread".utf8), patience: 3, stopSignals: [])
        let took = Date().timeIntervalSince(started)
        #expect(output.isEmpty)
        #expect(took >= 3 && took < Self.hangGuard / 2, "\(took) s")
        Self.expectTheSleepGone(lifeline.reading)
    }

    /// What it printed before it was stopped is kept.
    @Test func whatACommandPrintedBeforeItsPatienceRanOutIsReturned() {
        let output = Platform.pipeCommand("echo so far; exec sleep 600", input: Data(), patience: 1, stopSignals: [])
        #expect(Self.text(output) == "so far\n")
    }

    /// The command sends the stop signal to this process itself, once its sleep has said its pid (the sleep's
    /// shell tells it so through a second FIFO) and it has printed a line: the call is back long before its
    /// patience, with the line, and the sleep is gone. The signal is SIGWINCH, which this process ignores by
    /// default: the case of a status line that ignores its stop signals, and nothing ends when it is let through
    /// again afterwards.
    @Test func aStopSignalStopsTheCommandAndItsGroup() throws {
        let folder = try TestScriptLinuxTests.scratch("pipe-command")
        defer { try? FileManager.default.removeItem(at: folder) }
        let lifeline = try Self.lifeline(in: folder)
        defer { close(lifeline.reading) }
        let ready = folder.appendingPathComponent("ready").path
        try #require(mkfifo(ready, 0o600) == 0, "mkfifo: errno \(errno)")
        let command = "sh -c 'echo $$; echo go > \"$0\"; exec sleep 600' '\(ready)' > '\(lifeline.path)' & "
            + "read go < '\(ready)'; echo started; kill -WINCH $PPID; wait"
        let started = Date()
        let output = Platform.pipeCommand(command, input: Data(), patience: Self.hangGuard, stopSignals: [SIGWINCH])
        #expect(Self.text(output) == "started\n")
        #expect(Date().timeIntervalSince(started) < Self.hangGuard / 2, "stopped by its patience, not by the signal")
        Self.expectTheSleepGone(lifeline.reading)
        // The signal does again what it did before the command.
        let handling = signal(SIGWINCH, SIG_DFL)
        #expect(unsafeBitCast(handling, to: Int.self) == unsafeBitCast(SIG_DFL, to: Int.self))
    }

    #if os(Linux)
    /// A signal that isn't one of the command's stop signals stops nothing, though it comes the same way.
    @Test func aSignalThatIsNotAStopSignalStopsNothing() {
        let output = Platform.pipeCommand("kill -WINCH $PPID; echo went on", input: Data(), patience: Self.hangGuard, stopSignals: [SIGURG])
        #expect(Self.text(output) == "went on\n")
    }

    /// Linux can't tell a pipe not to raise SIGPIPE: the signal is held back around the writes and the one a write
    /// raised taken off. Shown where SIGPIPE isn't ignored: a handler counts the ones that land on this thread.
    @Test func aWriteToABrokenPipeUnderTheShieldRaisesNothing() throws {
        brokenPipeThread = pthread_self()
        brokenPipeSignals = 0
        let before = signal(SIGPIPE, countBrokenPipe)
        defer { _ = signal(SIGPIPE, before) }
        let pipe = try SpawnTests.newPipe()
        defer { close(pipe.writing) }
        close(pipe.reading)

        var byte: UInt8 = 1
        let shielded = Platform.withoutBrokenPipeSignal { () -> (wrote: Int, error: Int32) in
            let wrote = write(pipe.writing, &byte, 1)
            return (wrote, errno)
        }
        #expect(shielded.wrote == -1)
        #expect(shielded.error == EPIPE)
        #expect(brokenPipeSignals == 0)
        var mask = sigset_t()
        pthread_sigmask(SIG_SETMASK, nil, &mask)
        #expect(sigismember(&mask, SIGPIPE) == 0, "SIGPIPE is still held back from this thread")

        // The same write without the shield does raise it: the count above could have been 1.
        #expect(write(pipe.writing, &byte, 1) == -1)
        #expect(brokenPipeSignals == 1)
    }

    /// A SIGPIPE that waited for this thread before the shield isn't the shield's to take.
    @Test func theShieldLeavesAnEarlierSignalWaiting() {
        brokenPipeThread = pthread_self()
        brokenPipeSignals = 0
        let before = signal(SIGPIPE, countBrokenPipe)
        defer { _ = signal(SIGPIPE, before) }
        var broken = sigset_t(), mask = sigset_t(), waiting = sigset_t()
        sigemptyset(&broken)
        sigaddset(&broken, SIGPIPE)
        pthread_sigmask(SIG_BLOCK, &broken, &mask)
        pthread_kill(pthread_self(), SIGPIPE)
        Platform.withoutBrokenPipeSignal {}
        sigemptyset(&waiting)
        sigpending(&waiting)
        #expect(sigismember(&waiting, SIGPIPE) == 1)
        #expect(brokenPipeSignals == 0)
        // Let through: it lands here, once.
        pthread_sigmask(SIG_SETMASK, &mask, nil)
        #expect(brokenPipeSignals == 1)
    }

    /// Where the command can't be opened as a process (a kernel before 5.3), its exit is asked for instead: the
    /// same answers.
    @Test func withoutADescriptorOfTheCommandItIsTheSame() throws {
        let refused: (pid_t) -> Int32 = { _ in
            errno = ENOSYS
            return -1
        }
        let input = Data("one\ntwo\n".utf8)
        #expect(Platform.runPiped("cat", input: input, patience: Self.hangGuard, stopSignals: [], opening: refused) == input)
        #expect(Self.text(Platform.runPiped("echo done", input: Data(repeating: 0x61, count: 4_000_000), patience: Self.hangGuard, stopSignals: [], opening: refused)) == "done\n")

        let folder = try TestScriptLinuxTests.scratch("pipe-command")
        defer { try? FileManager.default.removeItem(at: folder) }
        let lifeline = try Self.lifeline(in: folder)
        defer { close(lifeline.reading) }
        #expect(Platform.runPiped(Self.leavingASleep(on: lifeline.path, then: "wait"), input: Data(), patience: 3, stopSignals: [], opening: refused).isEmpty)
        Self.expectTheSleepGone(lifeline.reading)
    }

    /// Fifty commands leave this process no descriptor more: the pipes, the command's descriptor. (The count is
    /// shared with the tests running beside this one: held to less than one a command.)
    @Test func fiftyCommandsLeaveNoDescriptor() throws {
        // The first one with a stop signal makes the pipe the signals are noted in, kept for good.
        _ = Platform.pipeCommand("true", input: Data(), patience: Self.hangGuard, stopSignals: [SIGURG])
        let before = try FolderWatchTests.descriptors().all
        for index in 0..<50 {
            let output = Platform.pipeCommand("cat", input: Data("\(index)".utf8), patience: Self.hangGuard, stopSignals: [SIGURG])
            #expect(Self.text(output) == "\(index)")
        }
        let after = try FolderWatchTests.descriptors().all
        #expect(after - before < 50, "\(after - before) descriptors more than before")
    }
    #endif
}
