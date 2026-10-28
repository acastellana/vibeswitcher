import Foundation
import IOKit.ps
import notify
import VibeCore

extension SystemPower {
    /// The internal battery as the system reports it now, for the lead's witness (see `LeadWitness.Power`); nil on a
    /// Mac without one (nothing to tell), or when the system doesn't say. It asks the power daemon, which can take
    /// seconds: only `PowerSourceCache` calls it, off the main thread.
    static func state(now: Date = Date()) -> PowerState? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int, let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = info[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            // -1 while the system is still estimating (just unplugged).
            let minutes = (info[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            return PowerState(onBattery: onBattery, percent: Int((Double(current) * 100 / Double(max)).rounded()),
                              charging: info[kIOPSIsChargingKey] as? Bool ?? false, minutesLeft: onBattery ? minutes : nil,
                              at: now.timeIntervalSince1970)
        }
        return nil
    }

    /// Whether the Mac runs on AC power now, as the power daemon says (it can take seconds: only `PowerSourceCache`
    /// calls it, off the main thread). No power source information: taken as power (a desktop Mac says AC anyway).
    static func providingAC() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return true }
        return (type as String) != kIOPMBatteryPowerKey && (type as String) != kIOPMUPSPowerKey
    }
}

/// The power source as last read, off the main thread. On 2026-10-28 at 17:02 the window froze for 6.4 s, all of it in
/// `SystemPower.onACPower` under the keep-awake look of a lead refresh: asking IOKit for the power source waits on the
/// power daemon, which can take seconds around sleep, wake and charging changes. So the main thread only reads what
/// this kept: it reads on a queue of its own when the system says a power source changed, and again when its reading
/// is older than `maxAge` at a look. One read at a time and at most one more queued, however many looks ask while the
/// daemon is slow; until the first read ends, AC power and no battery.
final class PowerSourceCache: @unchecked Sendable {
    /// What a read finds: the source providing power, and the internal battery (nil without one).
    struct Reading: Equatable {
        var onACPower: Bool
        var state: PowerState?
    }

    /// The app's: read from the system, and again at each change it posts.
    static let shared = PowerSourceCache(notifications: true)

    /// The system's power source, now (it can take seconds).
    static func system() -> Reading {
        Reading(onACPower: SystemPower.providingAC(), state: SystemPower.state())
    }

    private let read: () -> Reading
    let maxAge: TimeInterval
    private let queue = DispatchQueue(label: "VibeSwitcher.power-source", qos: .utility)
    private let lock = NSLock()
    /// Under `lock`: the last reading and when it ended, and whether a read waits on the queue.
    private var last: Reading?
    private var readAt: Date?
    private var queued = false
    private var token = NOTIFY_TOKEN_INVALID

    /// `read` runs only on the cache's queue; with `notifications`, at each power source change the system posts.
    init(read: @escaping () -> Reading = PowerSourceCache.system, maxAge: TimeInterval = 30, notifications: Bool = false) {
        self.read = read
        self.maxAge = maxAge
        // Registering asks notifyd, which the frozen reads of 17:02 waited on too: on the queue as well.
        if notifications {
            queue.async {
                notify_register_dispatch(kIOPSNotifyAnyPowerSource, &self.token, self.queue) { [weak self] _ in self?.refresh() }
            }
        }
        refresh()
    }

    deinit {
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
    }

    /// AC power, as last read (true until the first read ends).
    var onACPower: Bool { current()?.onACPower ?? true }
    /// The internal battery as last read; nil without one, or until the first read ends.
    var state: PowerState? { current()?.state }

    /// The last reading, without waiting; a read is queued when it's older than `maxAge`.
    func current(now: Date = Date()) -> Reading? {
        lock.lock()
        let reading = last
        let stale = readAt.map { now.timeIntervalSince($0) > maxAge } ?? true
        lock.unlock()
        if stale { refresh() }
        return reading
    }

    /// Reads again on the queue, unless a read already waits there.
    func refresh() {
        lock.lock()
        guard !queued else { return lock.unlock() }
        queued = true
        lock.unlock()
        queue.async {
            self.lock.lock()
            self.queued = false
            self.lock.unlock()
            let reading = self.read()
            self.lock.lock()
            self.last = reading
            self.readAt = Date()
            self.lock.unlock()
        }
    }

    /// Runs `then` once every read asked for so far has ended (for tests).
    func settled(then: @escaping () -> Void) {
        queue.async(execute: then)
    }
}
