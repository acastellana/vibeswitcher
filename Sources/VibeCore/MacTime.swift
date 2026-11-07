import Foundation

/// The Mac's two clocks: the wall clock (`Date`), which goes on while the Mac sleeps, and the time it has been awake
/// (`CLOCK_UPTIME_RAW`, mach_absolute_time: what Swift Testing times a test on, and Dispatch's timers), which doesn't.
public struct MacTime {
    public var wall: () -> Date
    /// Seconds awake, from any start.
    public var awake: () -> TimeInterval
    public init(wall: @escaping () -> Date, awake: @escaping () -> TimeInterval) {
        self.wall = wall
        self.awake = awake
    }
    public static let real = MacTime(wall: Date.init, awake: { TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 })
}

