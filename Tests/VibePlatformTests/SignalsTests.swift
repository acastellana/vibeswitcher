import Foundation
import Testing
import VibePlatform

// Where a test's handlers write what they were called with: a C function holds nothing, so they are globals, each
// set before its handler is installed and read only by it.
nonisolated(unsafe) private var fatalWriter: Int32 = -1
nonisolated(unsafe) private var informedWriter: Int32 = -1

/// Handlers installed through the platform, each test on a signal of its own and each putting back what the signal
/// had before. The two that deliver a signal use ones whose default is to be ignored (SIGURG, SIGWINCH): were a
/// handler not there, nothing would happen to the test run.
///
/// One at a time, and each holding `SignalTestLock`: other suites in the same process change and send these signals
/// too (PipeCommandTests' stop signals, MCPLogTests' SIGUSR2), and a signal one test sends lands in whatever handler
/// another has installed.
@Suite(.serialized)
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

    /// Sends `number` to a thread of the test's own, which lets the signal in, so its handler has run (there) when
    /// this returns: pthread_kill's result, 0 when it was sent. Not to the test's own thread: that is one of the
    /// system's work-queue threads (Swift's cooperative pool), which the Mac refuses a pthread_kill (ENOTSUP, xnu's
    /// `__pthread_kill`), so on the hosted runner the signal never came and the handler never ran (2026-11-12).
    static func deliver(_ number: Int32) async -> Int32 {
        await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
            let thread = Thread {
                // Its mask is its starter's, and a Dispatch thread's keeps signals out.
                var one = sigset_t()
                sigemptyset(&one)
                sigaddset(&one, number)
                pthread_sigmask(SIG_UNBLOCK, &one, nil)
                done.resume(returning: pthread_kill(pthread_self(), number))
            }
            thread.name = "SignalsTests.deliver"
            thread.start()
        }
    }

    /// The Int32s waiting in the pipe.
    static func numbers(in fd: Int32) -> [Int32] {
        var found: [Int32] = []
        var number: Int32 = 0
        while read(fd, &number, MemoryLayout<Int32>.size) == MemoryLayout<Int32>.size { found.append(number) }
        return found
    }

    @Test func aFatalHandlerIsInstalledToRunOnce() async {
        await SignalTestLock.held {
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
    }

    @Test func aFatalHandlerRunsAndTheDefaultIsBack() async throws {
        try await SignalTestLock.held {
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

            #expect(await Self.deliver(SIGURG) == 0, "pthread_kill")
            #expect(Self.numbers(in: pipe.read) == [SIGURG])
            #expect(Self.handler(Self.disposition(SIGURG)) == nil, "SA_RESETHAND: the default is back once the handler has started")
            // The default, for this signal, is nothing: no second call.
            #expect(await Self.deliver(SIGURG) == 0, "pthread_kill")
            #expect(Self.numbers(in: pipe.read) == [])
        }
    }

    @Test func anInformedHandlerStaysAndIsToldTheSender() async throws {
        try await SignalTestLock.held {
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

            #expect(await Self.deliver(SIGWINCH) == 0, "pthread_kill")
            #expect(await Self.deliver(SIGWINCH) == 0, "pthread_kill")
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

    // MARK: The lock

    /// Two opens of the lock's file in one process exclude each other: what lets two test targets, one process on
    /// Linux, share the lock with no module in common.
    @Test func theLocksSecondOpenInThisProcessWaits() throws {
        let folder = try TestScriptLinuxTests.scratch("signal-lock")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("signal-tests.lock").path
        let first = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600), second = open(path, O_RDWR | O_CLOEXEC)
        defer { [first, second].forEach { close($0) } }
        try #require(first >= 0 && second >= 0)
        #expect(flock(first, LOCK_EX) == 0)
        #expect(flock(second, LOCK_EX | LOCK_NB) == -1 && errno == EWOULDBLOCK)
        #expect(flock(first, LOCK_UN) == 0)
        #expect(flock(second, LOCK_EX | LOCK_NB) == 0)
    }

    /// What makes a test one that must hold `SignalTestLock`, in its body: one of the three signals named (a
    /// disposition changed, a handler installed, a signal sent, through whatever helper), a stop signal given to a
    /// command (Linux catches it in this process for the command's length), or a signal sent to this process by a
    /// command (`kill -… $PPID`) or by the test (`kill(getpid(), …)`), which lands in any handler installed. Signal 0
    /// sends nothing (`kill -0`: whether the process is there).
    static let needsTheLock = try! Regex(#"SIGURG|SIGWINCH|SIGUSR2|stopSignals:\s*\[[^\]\s]|kill -(?!0 )[A-Z0-9]+ \$PPID|kill\(getpid\(\),\s*[^0\s]"#)

    /// Each test in `Tests/**/*.swift` that `needsTheLock`, by "File.swift: name", and whether its body holds the lock.
    /// A test's body is its lines after its declaration (`@Test`, `func`) up to the brace that closes it, at the
    /// declaration's indentation, full-line comments left out; this test leaves itself out.
    static func signalTests() -> [(name: String, holds: Bool)] {
        let tests = PlatformLintTests.repo.appendingPathComponent("Tests")
        var found: [(name: String, holds: Bool)] = []
        for file in (FileManager.default.subpaths(atPath: tests.path) ?? []).sorted() where file.hasSuffix(".swift") {
            guard let text = try? String(contentsOf: tests.appendingPathComponent(file), encoding: .utf8) else { continue }
            var test: (name: String?, end: String, body: [String])?
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let declared = trimmed.firstMatch(of: #/func\s+(\w+)/#).map { String($0.1) }
                if trimmed.hasPrefix("@Test") {
                    test = (declared, String(line.prefix { $0 == " " }) + "}", [])
                } else if test != nil, test?.name == nil, let declared {
                    test?.name = declared
                } else if let open = test, line.hasPrefix(open.end), line.trimmingCharacters(in: .whitespaces) == "}",
                          line.count == open.end.count {
                    let code = open.body.joined(separator: "\n")
                    if let name = open.name, name != "everyTestThatHandlesTheseSignalsHoldsTheLock", code.contains(Self.needsTheLock) {
                        found.append(("\((file as NSString).lastPathComponent): \(name)", code.contains("SignalTestLock.held")))
                    }
                    test = nil
                } else if test != nil, !trimmed.hasPrefix("//") {
                    test?.body.append(line)
                }
            }
        }
        return found
    }

    @Test func everyTestThatHandlesTheseSignalsHoldsTheLock() {
        let found = Self.signalTests()
        // The rule reads what it should: the suites it was written for.
        for known in ["SignalsTests.swift: aFatalHandlerRunsAndTheDefaultIsBack", "PipeCommandTests.swift: aStopSignalStopsTheCommandAndItsGroup",
                      "MCPLogTests.swift: itSaysWhyServingEndedAndAToolsErrnoButNoneOfItsText"] {
            #expect(found.contains { $0.name == known }, "\(known) wasn't found among the tests that handle SIGURG, SIGWINCH or SIGUSR2")
        }
        let unlocked = found.filter { !$0.holds }.map(\.name)
        #expect(unlocked == [], """
            these tests change what SIGURG, SIGWINCH or SIGUSR2 do in the test process, or send one to it, without \
            holding the lock: wrap the body in `SignalTestLock.held` (and make the suite .serialized):
            \(unlocked.joined(separator: "\n"))
            """)
    }

    final class Names: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func add(_ name: String) { lock.withLock { names.append(name) } }
        var all: [String] { lock.withLock { names } }
    }
}
