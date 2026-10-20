import Foundation
import IOKit.ps
import VibeCore

extension SystemPower {
    /// The internal battery as the system reports it now, for the lead's witness (see `LeadWitness.Power`); nil on a
    /// Mac without one (nothing to tell), or when the system doesn't say.
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
}
