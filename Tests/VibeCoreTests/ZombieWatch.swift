import Darwin
import Foundation
import Testing
import VibeCore

/// The test run's children that ended and that nobody reaped (zombies). Every process a test starts, it, or what it
/// starts it with, waits for: a zombie holds a slot of the Mac-wide process table (kern.maxprocperuid, shared by every
/// project's sessions) for as long as the run lasts. On 2026-11-01 a full suite's runner had 431 of them, 21 min in: a
/// scratch host's teardown (`HostServer.stop(terminateSessions: true)`) killed its sessions' programs and stopped
/// watching them, so none was reaped.
///
/// The three test targets build into one bundle, which one runner process loads: the watch starts once, as it loads
/// (`watchTheRunsZombies` below), and looks at the runner's children every `ZombieWatch.interval`. A zombie that's
/// still there `ZombieWatch.grace` after it was first seen is one nobody will reap (Foundation's `Process` reaps as
/// the exit is posted, a host's or client's reaper within a few seconds even under load); more than
/// `ZombieWatch.bound` of them at once fails the run, naming how many.
struct ZombieWatch {
    /// How long a zombie may wait for its reaper: a reaper that only runs late (a loaded Mac, a backoff of a few
    /// seconds, see `HostClient.hostReapDelays`) is no leak.
    static let grace: TimeInterval = 10
    /// How many lingering zombies the run tolerates at once: a test that ends a process and its reaper both, at the
    /// very moment of a look, isn't worth failing for; hundreds are.
    static let bound = 5
    /// How often the run's children are looked at.
    static let interval: TimeInterval = 2

    /// When each zombie child was first seen.
    private(set) var firstSeen: [pid_t: Date] = [:]
    /// Whether the last look was over `bound` (one issue per time it goes over, not one per look).
    private var over = false

    /// One look: `zombies`, the zombie children now, at `now`. The ones that lingered past `grace`, when there are
    /// more than `bound` of them and the look before wasn't over already (nil otherwise).
    mutating func look(zombies: [pid_t], now: Date) -> [pid_t]? {
        firstSeen = Dictionary(uniqueKeysWithValues: zombies.map { ($0, firstSeen[$0] ?? now) })
        let lingering = firstSeen.filter { now.timeIntervalSince($0.value) >= Self.grace }.keys.sorted()
        defer { over = lingering.count > Self.bound }
        return lingering.count > Self.bound && !over ? lingering : nil
    }

    /// The children of `pid` that ended and haven't been reaped.
    static func zombies(of pid: pid_t = getpid()) -> [pid_t] {
        SessionStrays.children(of: pid).filter { child in
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, child]
            return sysctl(&mib, 4, &info, &size, nil, 0) == 0 && size > 0 && info.kp_proc.p_stat == SZOMB
        }
    }

    /// The run's watch: started as the bundle loads, it looks until the runner exits.
    static func start() {
        let queue = DispatchQueue(label: "test-zombie-watch", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var watch = ZombieWatch()
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        timer.setEventHandler {
            guard let lingering = watch.look(zombies: zombies(), now: Date()) else { return }
            Issue.record(Comment(rawValue: "The test run has \(lingering.count) zombie children (processes that ended over "
                                 + "\(Int(grace)) s ago, never reaped; pids \(lingering.prefix(20).map(String.init).joined(separator: " "))). "
                                 + "Whatever starts a process waits for it: waitpid, Process.waitUntilExit, or a reaper "
                                 + "(see ZombieWatch)."))
        }
        timer.resume()
        running = timer
    }

    /// The watch's timer, kept for the run's life.
    private nonisolated(unsafe) static var running: DispatchSourceTimer?
}

/// Runs as the test bundle loads: the run's zombie watch (see `ZombieWatch`).
@_used @_section("__DATA,__mod_init_func")
private let watchTheRunsZombies: @convention(c) () -> Void = { ZombieWatch.start() }
