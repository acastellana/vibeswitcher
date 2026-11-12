#if canImport(Darwin)
import Foundation

/// The Mac's readings: sysctl, one Mach call, statfs and getrlimit, as VibeCore read them before they moved here
/// (MacMemory, LoadRecorder, DiskSpace, MCPLog).
extension Platform.Host {
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical; nil when it can't be read.
    public static func memoryPressureLevel() -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// `kern.memorystatus_level`: the percentage of memory still to be had; nil when it can't be read.
    public static func memoryFreePercent() -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// Swap used and its total, in bytes (`vm.swapusage`); nil when it can't be read.
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

    /// The bytes free to this user on the volume holding `path`, as `df` counts them (`statfs`); nil when it can't be
    /// read, as for a path that isn't there.
    public static func volumeFree(at path: String) -> Int64? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// The soft limit on open files, as the kernel applies it (never over kern.maxfilesperproc).
    public static func descriptorLimit() -> Int {
        var limit = rlimit()
        let soft = getrlimit(RLIMIT_NOFILE, &limit) == 0 ? limit.rlim_cur : rlim_t(OPEN_MAX)
        var perProcess: Int32 = 0
        var length = MemoryLayout<Int32>.size
        let cap = sysctlbyname("kern.maxfilesperproc", &perProcess, &length, nil, 0) == 0 && perProcess > 0 ? rlim_t(perProcess) : soft
        return Int(min(soft, cap))
    }
}
#endif
