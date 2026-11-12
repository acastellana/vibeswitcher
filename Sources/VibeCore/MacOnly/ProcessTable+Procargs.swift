#if canImport(Darwin)
extension ProcessTable {
    /// What the Mac's `KERN_PROCARGS2` gives of a process, taken apart: `Platform.Processes.parse(procargs:)`, which
    /// only the Mac has (Linux reads /proc/<pid>/cmdline and environ).
    static func parse(procargs buffer: [UInt8]) -> (arguments: [String], environment: [String]) {
        Platform.Processes.parse(procargs: buffer)
    }
}
#endif
