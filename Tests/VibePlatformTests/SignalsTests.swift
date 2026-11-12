import Foundation
import Testing
import VibePlatform

// Where a test's handlers write what they were called with: a C function holds nothing, so they are globals, each
// set before its handler is installed and read only by it.
nonisolated(unsafe) private var fatalWriter: Int32 = -1
nonisolated(unsafe) private var informedWriter: Int32 = -1

/// Handlers installed through the platform, each test on a signal of its own (the tests run side by side in one
/// process) and each putting back what the signal had before. The two that deliver a signal use ones whose default
/// is to be ignored (SIGURG, SIGWINCH): were a handler not there, nothing would happen to the test run.
struct SignalsTests {
    /// What a signal does now.
    static func disposition(_ number: Int32) -> sigaction {
        var action = sigaction()
        #expect(sigaction(number, nil, &action) == 0)
        return action
    }

    /// The handler's address in `action` (the one-argument and the three-argument form share the field); nil for
    /// the default.
    static func handler(_ action: sigaction) -> UnsafeRawPointer? {
        #if canImport(Darwin)
        unsafeBitCast(action.__sigaction_u.__sa_handler, to: UnsafeRawPointer?.self)
        #elseif canImport(Glibc)
        unsafeBitCast(action.__sigaction_handler.sa_handler, to: UnsafeRawPointer?.self)
        #else
        unsafeBitCast(action.__sa_handler.sa_handler, to: UnsafeRawPointer?.self)
        #endif
    }

    static func has(_ action: sigaction, _ flag: Int32) -> Bool { action.sa_flags & flag != 0 }
    static let resetHand = Int32(truncatingIfNeeded: SA_RESETHAND), sigInfo = Int32(truncatingIfNeeded: SA_SIGINFO)

    /// A pipe whose reading end doesn't wait.
    static func pipeEnds() throws -> (read: Int32, write: Int32) {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        _ = fcntl(ends[0], F_SETFL, fcntl(ends[0], F_GETFL) | O_NONBLOCK)
        return (ends[0], ends[1])
    }

    /// Sends `number` to the calling thread with the signal let in (a test's thread is one of Dispatch's, which
    /// keeps signals out), so its handler has run when this returns. The thread's mask is put back.
    static func deliverHere(_ number: Int32) {
        var one = sigset_t(), before = sigset_t()
        sigemptyset(&one)
        sigaddset(&one, number)
        pthread_sigmask(SIG_UNBLOCK, &one, &before)
        pthread_kill(pthread_self(), number)
        pthread_sigmask(SIG_SETMASK, &before, nil)
    }

    /// The Int32s waiting in the pipe.
    static func numbers(in fd: Int32) -> [Int32] {
        var found: [Int32] = []
        var number: Int32 = 0
        while read(fd, &number, MemoryLayout<Int32>.size) == MemoryLayout<Int32>.size { found.append(number) }
        return found
    }

    @Test func aFatalHandlerIsInstalledToRunOnce() {
        var before = Self.disposition(SIGUSR2)
        defer { sigaction(SIGUSR2, &before, nil) }
        let handler: @convention(c) (Int32) -> Void = { _ in }
        Platform.Signals.onFatal([SIGUSR2], handler)

        let now = Self.disposition(SIGUSR2)
        #expect(Self.handler(now) == unsafeBitCast(handler, to: UnsafeRawPointer?.self))
        #expect(Self.handler(now) != nil)
        #expect(Self.has(now, Self.resetHand))
        #expect(!Self.has(now, Self.sigInfo))
        // The handler runs with no other signal held back for it.
        var mask = now.sa_mask
        for other in [SIGINT, SIGTERM, SIGHUP, SIGUSR1] { #expect(sigismember(&mask, other) == 0) }
    }

    @Test func aFatalHandlerRunsAndTheDefaultIsBack() throws {
        let pipe = try Self.pipeEnds()
        defer { [pipe.read, pipe.write].forEach { close($0) } }
        var before = Self.disposition(SIGURG)
        defer { sigaction(SIGURG, &before, nil) }
        fatalWriter = pipe.write
        Platform.Signals.onFatal([SIGURG]) { number in
            var said = number
            _ = write(fatalWriter, &said, MemoryLayout<Int32>.size)
        }
        #expect(Self.handler(Self.disposition(SIGURG)) != nil)

        Self.deliverHere(SIGURG)
        #expect(Self.numbers(in: pipe.read) == [SIGURG])
        #expect(Self.handler(Self.disposition(SIGURG)) == nil, "SA_RESETHAND: the default is back once the handler has started")
        // The default, for this signal, is nothing: no second call.
        Self.deliverHere(SIGURG)
        #expect(Self.numbers(in: pipe.read) == [])
    }

    @Test func anInformedHandlerStaysAndIsToldTheSender() throws {
        let pipe = try Self.pipeEnds()
        defer { [pipe.read, pipe.write].forEach { close($0) } }
        var before = Self.disposition(SIGWINCH)
        defer { sigaction(SIGWINCH, &before, nil) }
        informedWriter = pipe.write
        Platform.Signals.onSignal([SIGWINCH]) { number, info, _ in
            var said: (Int32, Int32) = (number, Platform.Signals.sender(info))
            _ = withUnsafeBytes(of: &said) { write(informedWriter, $0.baseAddress, $0.count) }
        }
        let installed = Self.disposition(SIGWINCH)
        #expect(Self.handler(installed) != nil)
        #expect(Self.has(installed, Self.sigInfo))
        #expect(!Self.has(installed, Self.resetHand))

        Self.deliverHere(SIGWINCH)
        Self.deliverHere(SIGWINCH)
        let said = Self.numbers(in: pipe.read)
        #expect(said.count == 4)
        #expect(said.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) == [SIGWINCH, SIGWINCH])
        #if os(Linux)
        // The sender is this process. Only Linux is asked: whether the Mac names a sender for a signal a thread
        // sends itself isn't known here (the host's signals come from other processes, by kill).
        #expect(said.enumerated().filter { $0.offset % 2 == 1 }.map(\.element) == [getpid(), getpid()])
        #endif
        #expect(Self.handler(Self.disposition(SIGWINCH)) == Self.handler(installed), "it stays installed")
    }

    @Test func noSignalInfoIsNoSender() {
        #expect(Platform.Signals.sender(nil) == 0)
    }

    #if canImport(Darwin)
    /// The handler is installed and passes the exception's name on. It is called here as the system would call it:
    /// an exception really thrown and not caught ends the process.
    @Test func anUncaughtExceptionsNameIsPassedOn() {
        let before = NSGetUncaughtExceptionHandler()
        defer { NSSetUncaughtExceptionHandler(before) }
        let names = Names()
        Platform.Signals.onUncaughtException { names.add($0) }
        let installed = NSGetUncaughtExceptionHandler()
        #expect(installed != nil)
        installed?(NSException(name: NSExceptionName("VibePlatformTestException"), reason: nil, userInfo: nil))
        #expect(names.all == ["VibePlatformTestException"])
    }
    #else
    /// Linux has no such exceptions: nothing is installed and the note is never called.
    @Test func thereAreNoUncaughtExceptionsToNote() {
        let names = Names()
        Platform.Signals.onUncaughtException { names.add($0) }
        #expect(names.all == [])
    }
    #endif

    final class Names: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func add(_ name: String) { lock.withLock { names.append(name) } }
        var all: [String] { lock.withLock { names } }
    }
}
