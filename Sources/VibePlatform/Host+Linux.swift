#if os(Linux)
import Foundation

/// Linux's readings: /proc's text, statvfs and getrlimit. What reads a /proc file's text is apart from what reads
/// the file, so each is tested on text of a known shape (`HostTests`).
extension Platform.Host {
    /// From /proc/pressure/memory (`pressureLevel(pressure:)` has the thresholds); nil where the kernel doesn't keep
    /// it: built without pressure stall information, or started with `psi=0` (WSL2's 5.15 kernel has no such file).
    public static func memoryPressureLevel() -> Int32? {
        text(of: "/proc/pressure/memory").flatMap(pressureLevel(pressure:))
    }

    /// /proc/meminfo's MemAvailable (what a new program could have without swapping) as a percentage of MemTotal.
    public static func memoryFreePercent() -> Int? {
        text(of: "/proc/meminfo").flatMap(freePercent(meminfo:))
    }

    /// /proc/meminfo's SwapTotal less SwapFree, and SwapTotal, in bytes.
    public static func swapUsage() -> (used: UInt64, total: UInt64)? {
        text(of: "/proc/meminfo").flatMap(swap(meminfo:))
    }

    /// /proc/vmstat's `pswpout`: pages swapped out since boot.
    public static func swapOuts() -> UInt64? {
        text(of: "/proc/vmstat").flatMap(swapOuts(vmstat:))
    }

    /// The bytes free to this user on the volume holding `path`, as `df` counts them (`statvfs`: glibc's and musl's
    /// modules show Swift no `statfs`); nil when it can't be read, as for a path that isn't there.
    public static func volumeFree(at path: String) -> Int64? {
        var info = statvfs()
        guard statvfs(path, &info) == 0 else { return nil }
        let (bytes, over) = Int64(clamping: info.f_bavail).multipliedReportingOverflow(by: Int64(clamping: info.f_frsize))
        return over ? Int64.max : bytes
    }

    /// The soft limit on open files (`RLIMIT_NOFILE`); 1,024, the kernel's own default, should it not be read.
    public static func descriptorLimit() -> Int {
        var limit = rlimit()
        #if canImport(Glibc)
        let read = getrlimit(__rlimit_resource_t(RLIMIT_NOFILE.rawValue), &limit) == 0
        #else
        let read = getrlimit(RLIMIT_NOFILE, &limit) == 0
        #endif
        return read ? Int(clamping: limit.rlim_cur) : 1024
    }

    // MARK: /proc's text

    /// The whole of a /proc file (which says it is 0 bytes long, so it is read to its end); nil when it can't be
    /// opened or read.
    static func text(of path: String) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while bytes.count < 4 << 20 {
            let got = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if got < 0, errno == EINTR { continue }
            guard got >= 0 else { return nil }
            if got == 0 { break }
            bytes.append(contentsOf: chunk[0..<got])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A field of /proc/meminfo in bytes: "MemTotal:       98500052 kB" is 98500052 × 1,024. nil when the field
    /// isn't there or isn't a number.
    static func bytes(_ field: String, meminfo: String) -> UInt64? {
        for line in meminfo.split(separator: "\n") where line.hasPrefix(field + ":") {
            let words = line.dropFirst(field.count + 1).split(separator: " ")
            guard let number = words.first.flatMap({ UInt64($0) }) else { return nil }
            // Every size is in kB; a count (HugePages_Total) has no unit.
            return words.count > 1 && words[1] == "kB" ? number.multipliedReportingOverflow(by: 1024).partialValue : number
        }
        return nil
    }

    /// MemAvailable as a percentage of MemTotal, rounded down; nil when either is missing (MemAvailable is, before
    /// Linux 3.14) or the total is 0.
    static func freePercent(meminfo: String) -> Int? {
        guard let total = bytes("MemTotal", meminfo: meminfo), total > 0,
              let available = bytes("MemAvailable", meminfo: meminfo) else { return nil }
        return Int(Double(min(available, total)) / Double(total) * 100)
    }

    /// Swap used and its total, in bytes; (0, 0) on a machine with no swap, nil when either line is missing.
    static func swap(meminfo: String) -> (used: UInt64, total: UInt64)? {
        guard let total = bytes("SwapTotal", meminfo: meminfo), let free = bytes("SwapFree", meminfo: meminfo) else { return nil }
        return (total - min(free, total), total)
    }

    /// /proc/vmstat's "pswpout 1234"; nil when the kernel was built without swap and has no such line.
    static func swapOuts(vmstat: String) -> UInt64? {
        for line in vmstat.split(separator: "\n") where line.hasPrefix("pswpout ") {
            return UInt64(line.dropFirst("pswpout ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// The share of the last 10 seconds, in percent, from which a pressure level is warning (some task waited for
    /// memory that long) or critical (every task that wasn't idle waited at once).
    static let pressureShare = 10.0

    /// The Mac's levels from /proc/pressure/memory's two lines:
    ///
    ///     some avg10=0.00 avg60=0.00 avg300=0.00 total=0
    ///     full avg10=0.00 avg60=0.00 avg300=0.00 total=0
    ///
    /// `some` is the share of time in which at least one task waited for memory (reclaim, swap-in, a refault);
    /// `full` the share in which all tasks that weren't idle did, so nothing got done. Over the last 10 seconds
    /// (`avg10`, the shortest the kernel keeps, as the Mac's level is of now): 4, critical, at `full` ≥ 10 %; 2,
    /// warning, at `some` ≥ 10 %; else 1, normal. The Mac says warning when it compresses and swaps to keep going
    /// and critical when it is about to end programs; a tenth of the time lost to waiting for memory is where a
    /// Linux machine is doing the first, and a tenth of it lost by everything at once where it thrashes (systemd-oomd
    /// starts ending programs at `full` 60 %, far later). The thresholds are a judgment, not a measurement.
    /// nil when there is no `some` line with an `avg10`.
    static func pressureLevel(pressure: String) -> Int32? {
        func share(_ kind: String) -> Double? {
            for line in pressure.split(separator: "\n") where line.hasPrefix(kind + " ") {
                for word in line.split(separator: " ") where word.hasPrefix("avg10=") {
                    return Double(word.dropFirst("avg10=".count))
                }
            }
            return nil
        }
        guard let some = share("some") else { return nil }
        if let full = share("full"), full >= pressureShare { return 4 }
        return some >= pressureShare ? 2 : 1
    }
}
#endif
