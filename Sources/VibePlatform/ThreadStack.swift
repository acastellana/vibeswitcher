import Foundation

extension Platform {
    /// The calling thread's stack, as the tests' stack gauge reads it (main's `StackGauge`, `HostVaultStackTests`). Each
    /// system's reading is in a file of its own (ThreadStack+Darwin.swift, ThreadStack+Linux.swift), under the same names:
    ///
    /// - `bounds() -> (top: UInt, size: Int)?`: the address its stack starts at (the highest: stacks grow down) and its size.
    /// - `touchedPages(from:count:) -> [Bool]?`: for each of `count` pages from `from` (a page's address), whether it
    ///   was ever read or written (resident, or paged out since; untouched anonymous memory is neither), by `mincore`.
    public enum ThreadStack {}
}
