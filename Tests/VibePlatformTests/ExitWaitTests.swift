import Foundation
import Testing
@testable import VibePlatform

/// `Platform.ExitWait`: a pause over at a process's exit, once; every other pause its whole time, so a caller that
/// hasn't collected the process never spins. The process is `cat` held on a pipe the test has the other end of
/// (`ProcessExitTests.Held`).
struct ExitWaitTests {
    /// How long `body` took, awake.
    static func timed(_ body: () -> Void) -> TimeInterval {
        let began = Platform.Clock.awakeSeconds()
        body()
        return Platform.Clock.awakeSeconds() - began
    }

    /// A short pause, and what a whole one of it is at the least (a sleep is never shorter than asked).
    static let pause: TimeInterval = 0.05
    static let atLeast: TimeInterval = 0.045

    @Test func aPauseEndsAtTheExitAndOnlyOnce() throws {
        let child = try ProcessExitTests.Held()
        defer { child.finish() }
        let exit = Platform.ExitWait(child.pid)
        // Running: a pause is its whole time.
        #expect(Self.timed { exit.wait(upTo: Self.pause) } >= Self.atLeast)
        child.end()
        // Its exit ends the pause: well before the hang guard, which only bounds a failure.
        let waited = Self.timed { exit.wait(upTo: ProcessExitTests.hangGuard) }
        #expect(waited < ProcessExitTests.hangGuard, "the exit of pid \(child.pid) didn't end the pause")
        // Exited and not collected (the wait reaps nothing): the next pause is its whole time again, never a spin.
        #expect(Self.timed { exit.wait(upTo: Self.pause) } >= Self.atLeast)
        #expect(child.collect(), "the wait collected the child")
    }

    @Test func aProcessThatIsntThereIsAPlainSleep() throws {
        let child = try ProcessExitTests.Held()
        child.end()
        #expect(child.collect())
        // Its number may be another's by now only after many more processes; either way it's a whole pause.
        let exit = Platform.ExitWait(child.pid)
        #expect(Self.timed { exit.wait(upTo: Self.pause) } >= Self.atLeast)
        let none = Platform.ExitWait(0)
        #expect(Self.timed { none.wait(upTo: Self.pause) } >= Self.atLeast)
    }
}
