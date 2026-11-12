import Foundation
import Testing

/// The run's zombie watch (`ZombieWatch`): what it counts, and when it fails the run.
struct ZombieWatchTests {
    /// A child that ended and that nobody waited for is counted, and is no longer once it's reaped.
    @Test func aChildNobodyReapedIsCountedUntilItIs() async throws {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        try #require(posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, environ) == 0)
        var status: Int32 = 0
        defer { _ = waitpid(pid, &status, WNOHANG) }
        #expect(await eventually { ZombieWatch.zombies().contains(pid) })
        #expect(ZombieWatch.names([pid]) == "true ×1")
        #expect(waitpid(pid, &status, 0) == pid)
        #expect(!ZombieWatch.zombies().contains(pid))
    }

    /// A child that runs isn't a zombie.
    @Test func aRunningChildIsntCounted() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "read line"]
        let input = Pipe()
        child.standardInput = input
        try child.run()
        defer { try? input.fileHandleForWriting.close(); waitForEnd(child) }
        #expect(!ZombieWatch.zombies().contains(child.processIdentifier))
    }

    /// Zombies that a reaper takes within `grace` never count; more than `bound` lingering past it fail the run once,
    /// and again only after they went back under it.
    @Test func lingeringZombiesOverTheBoundFailTheRunOnce() {
        var watch = ZombieWatch()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let many = (1...pid_t(ZombieWatch.bound + 1)).map { 1000 + $0 }
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

        #expect(watch.look(zombies: many, now: at(0)) == nil)
        #expect(watch.look(zombies: many, now: at(ZombieWatch.grace - 1)) == nil, "within its grace")
        #expect(watch.look(zombies: many, now: at(ZombieWatch.grace)) == many)
        #expect(watch.look(zombies: many, now: at(ZombieWatch.grace + 2)) == nil, "said once")
        // One reaped: at the bound, not over it.
        #expect(watch.look(zombies: Array(many.dropFirst()), now: at(ZombieWatch.grace + 4)) == nil)
        #expect(watch.look(zombies: Array(many.dropFirst()) + [2000], now: at(ZombieWatch.grace + 6)) == nil, "the new one's grace")
        #expect(watch.look(zombies: Array(many.dropFirst()) + [2000], now: at(2 * ZombieWatch.grace + 6))
                == Array(many.dropFirst()) + [2000])
    }

    /// Short-lived zombies that come and go (each reaped within its grace) never add up, however many there are.
    @Test func zombiesReapedInTimeNeverCount() {
        var watch = ZombieWatch()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for look in 0..<100 {
            let now = start.addingTimeInterval(TimeInterval(look) * ZombieWatch.interval)
            let fresh = (0..<pid_t(3 * ZombieWatch.bound)).map { pid_t(look) * 100 + $0 }
            #expect(watch.look(zombies: fresh, now: now) == nil)
        }
    }
}
