import Darwin
import Foundation

/// The Mac's memory as start_worker, audit and auto_advance's starts weigh it beside the load: the kernel's memory
/// pressure level and how fast it swaps out. On 2026-11-08 from 03:40 to 06:00 the load reached 100–225 on 12 cores
/// while the CPU stayed 27–40 % idle: 504 MB free, the compressor at 7 GB, swap at 7.8 of 9.2 GB. The holds looked at
/// the load alone, so with Boost new sessions kept starting into a Mac that was already paging, and the app froze
/// dozens of times. Swap used against its total is shown, not held on: macOS keeps swap used long after the paging
/// ends (an idle Mac sat at 7.8 of 9.2 GB at pressure normal), so the hold is on swapping now (`swapOutRate`).
/// Everything is read in process (sysctl and a Mach call): no tool, nothing that prompts.
public struct MacMemory: Equatable, Sendable {
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    public enum Pressure: Int, Comparable, Sendable, CaseIterable {
        case normal = 1, warning = 2, critical = 4

        public static func < (a: Pressure, b: Pressure) -> Bool { a.rawValue < b.rawValue }

        public var name: String {
            switch self {
            case .normal: "normal"
            case .warning: "warning"
            case .critical: "critical"
            }
        }

        public init?(name: String) {
            guard let level = Self.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
            self = level
        }
    }

    /// The kernel's memory pressure level; nil when it can't be read.
    public var pressure: Pressure?
    /// Swap used and its total, in bytes (`vm.swapusage`); nil when it can't be read.
    public var swapUsed: UInt64?
    public var swapTotal: UInt64?
    /// Pages swapped out per second over about the last minute (`SwapSamples`); nil while not known (no earlier
    /// reading to compare with yet).
    public var swapOutRate: Double?

    public init(pressure: Pressure? = nil, swapUsed: UInt64? = nil, swapTotal: UInt64? = nil, swapOutRate: Double? = nil) {
        self.pressure = pressure
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.swapOutRate = swapOutRate
    }

    /// Why the Mac is short of memory under `limits` (the pressure level at or above memory_pressure, or swapping out
    /// faster than swap_out_rate); nil when it isn't, or when what would say so can't be read.
    public func shortage(_ limits: MacLimits) -> String? {
        var why: [String] = []
        if let pressure, let limit = limits.pressureLimit, pressure >= limit {
            why.append("its memory pressure is \(pressure.name) (memory_pressure \(limit.name))")
        }
        if let rate = swapOutRate, let limit = limits.swapOutRateLimit, rate > limit {
            why.append("it swaps out \(Self.rateText(rate)) pages/s over the last minute (swap_out_rate \(MacLoad.number(limit)))")
        }
        return why.isEmpty ? nil : why.joined(separator: " and ")
    }

    /// "memory pressure normal, swap 7.6/9 GB, swap-out 0 pages/s": what status and the refusals say, short (status
    /// stays under its bound on a big board; the limits are in configure's listing and the refusal's reason).
    public var text: String {
        var parts = ["memory pressure \(pressure?.name ?? "unknown")"]
        if let used = swapUsed, let total = swapTotal {
            parts.append(total == 0 ? "no swap" : "swap \(Self.gb(used))/\(Self.gb(total)) GB")
        }
        parts.append("swap-out " + (swapOutRate.map { "\(Self.rateText($0)) pages/s" } ?? "not known yet"))
        return parts.joined(separator: ", ")
    }

    /// The holds as said beside `text`: "(holds at memory_pressure warning or swap_out_rate 50 pages/s)".
    public static func limitsText(_ limits: MacLimits) -> String {
        var holds: [String] = []
        if let pressure = limits.pressureLimit { holds.append("memory_pressure \(pressure.name)") }
        if let rate = limits.swapOutRateLimit { holds.append("swap_out_rate \(MacLoad.number(rate)) pages/s") }
        return holds.isEmpty ? "(no memory hold)" : "(holds at " + holds.joined(separator: " or ") + ")"
    }

    static func gb(_ bytes: UInt64) -> String { MacLoad.number((Double(bytes) / 1_073_741_824 * 10).rounded() / 10) }

    /// One decimal under 100 (49.9 isn't said as the 50 it doesn't reach), whole from there.
    static func rateText(_ rate: Double) -> String { MacLoad.number(rate >= 100 ? rate.rounded() : (rate * 10).rounded() / 10) }

    // MARK: Reading the Mac

    /// The Mac's memory now, its swap-out rate from the readings kept in `samples` (this one added).
    public static func read(samples: SwapSamples = SwapSamples(), now: Date = Date()) -> MacMemory {
        var memory = MacMemory(pressure: pressureLevel())
        if let swap = swapUsage() {
            memory.swapUsed = swap.used
            memory.swapTotal = swap.total
        }
        if let outs = swapOuts() { memory.swapOutRate = samples.rate(adding: outs, now: now) }
        return memory
    }

    public static func pressureLevel() -> Pressure? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return nil }
        return Pressure(rawValue: Int(value))
    }

    public static func swapUsage() -> (used: UInt64, total: UInt64)? {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return nil }
        return (swap.xsu_used, swap.xsu_total)
    }

    /// The host port, taken once: each `mach_host_self()` adds a send right.
    private static let host = mach_host_self()

    /// Pages swapped out since boot (`vm_statistics64.swapouts`).
    public static func swapOuts() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        return result == KERN_SUCCESS ? stats.swapouts : nil
    }

    /// The swap-out counter's readings of the last few minutes, Mac-wide in `~/.vibeswitcher/swap-samples.json`, so
    /// a tool server that just started compares with the app's reading of a minute ago (it reads once a minute for
    /// the room-again messages) instead of knowing nothing.
    public struct SwapSamples: Sendable {
        public struct Sample: Codable, Equatable, Sendable {
            public var at: TimeInterval
            public var outs: UInt64

            public init(at: TimeInterval, outs: UInt64) {
                self.at = at
                self.outs = outs
            }
        }

        public static var file: URL { VibePaths.root.appendingPathComponent("swap-samples.json") }
        /// Readings older than this are dropped.
        static let keep: TimeInterval = 300
        static let most = 64
        /// The window the rate is averaged over, at least `shortest` when nothing that old is kept.
        static let window: TimeInterval = 60
        static let shortest: TimeInterval = 15

        let file: URL

        public init(file: URL = SwapSamples.file) { self.file = file }

        /// The pages swapped out per second since a kept reading about a minute old (`rate(_:outs:now:)`), and this
        /// reading kept for the next.
        public func rate(adding outs: UInt64, now: Date = Date()) -> Double? {
            let kept = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Sample].self, from: $0) } ?? []
            let rate = Self.rate(kept, outs: outs, now: now)
            var samples = kept.filter { now.timeIntervalSince1970 - $0.at <= Self.keep && $0.at <= now.timeIntervalSince1970 }
            samples.append(Sample(at: now.timeIntervalSince1970, outs: outs))
            if let data = try? JSONEncoder().encode(Array(samples.suffix(Self.most))) {
                try? VibePaths.ensurePrivate(file.deletingLastPathComponent())
                try? VibePaths.writePrivate(data, to: file)
            }
            return rate
        }

        /// The rate from `samples` to `outs` now: against the newest reading at least a minute old, else the oldest
        /// at least 15 s old; nil with none, or when the counter went back (a restart).
        static func rate(_ samples: [Sample], outs: UInt64, now: Date) -> Double? {
            let at = now.timeIntervalSince1970
            let recent = samples.filter { at - $0.at <= keep }
            let base = recent.filter { at - $0.at >= window }.max { $0.at < $1.at }
                ?? recent.filter { at - $0.at >= shortest }.min { $0.at < $1.at }
            guard let base, outs >= base.outs else { return nil }
            return Double(outs - base.outs) / (at - base.at)
        }
    }
}
