import Foundation

extension Platform {
    /// The machine as a whole: its memory, its swap, a volume's free room, this process's limit on open files. Each
    /// system's readings are in a file of its own (Host+Darwin.swift, Host+Linux.swift), under the same names:
    ///
    /// - `memoryPressureLevel() -> Int32?`: 1 normal, 2 warning, 4 critical, the Mac's numbers; nil when not known.
    /// - `memoryFreePercent() -> Int?`: how much of the memory is still to be had, 0 to 100.
    /// - `swapUsage() -> (used: UInt64, total: UInt64)?`: in bytes; both 0 on a machine with no swap.
    /// - `swapOuts() -> UInt64?`: pages swapped out since the machine started.
    /// - `volumeFree(at:) -> Int64?`: the bytes free to this user on the volume holding a path that exists.
    /// - `descriptorLimit() -> Int`: how many files this process may have open at once.
    ///
    /// Everything is read in process: no tool is run, nothing prompts.
    public enum Host {}
}
