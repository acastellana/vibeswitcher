import Darwin
import Foundation

/// Since macOS 27.2 (installed here 2026-10-31) malloc keeps the pages of what's freed, and
/// `malloc_zone_pressure_relief` gives none back (0 bytes, every time: `FootprintRelief`'s lines read "N → N MB" from the
/// first launch on it). Only a process idle for a minute or two gets them back, and the app is never idle, so each peak
/// (a chat opened, the boards decoded, a terminal drawn) stayed in its footprint. The footprint rose from 160 to 875 MB
/// over a 10-hour day (2026-11-16), +74 MB an hour. With `MallocLargeCache=0` in its environment from launch, malloc
/// gives the pages back as blocks are freed, at no cost measured (scripts/malloc-relief-repro.sh: 200 MB freed in
/// 40 KB blocks leaves 2 MB of footprint instead of 248 MB; an app-like churn runs as fast and works in 110 MB, not
/// 156). malloc reads it once, as the process starts, so the app starts itself again with it, first thing.
enum MallocMode {
    static let variable = "MallocLargeCache"

    /// Starts this executable again with `variable` set, the same arguments and the same pid (`execv`), unless it's set
    /// already. Then takes it out of the environment, so nothing the app starts (the session host, shells, agents)
    /// inherits it. Before anything else runs: exec drops every thread, file and window the process had.
    static func relaunchIfNeeded() {
        guard getenv(variable) == nil else {
            unsetenv(variable)
            return
        }
        setenv(variable, "0", 1)
        var size = UInt32(MAXPATHLEN)
        var path = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&path, &size) == 0 {
            execv(path, CommandLine.unsafeArgv)
        }
        // It couldn't start again: go on as it is, without the setting (nothing below should inherit it).
        unsetenv(variable)
    }

    /// `--malloc-check`: frees 200 MB of 40 KB blocks and prints the footprint (MB) with them in use and after, as a
    /// test of `relaunchIfNeeded` reads it ("malloc-check: in use 250.1 MB, freed 4.2 MB").
    static func check() -> Never {
        let count = 200 * 1_048_576 / 40_000
        var blocks: [UnsafeMutableRawPointer] = []
        blocks.reserveCapacity(count)
        for _ in 0..<count {
            guard let block = malloc(40_000) else { break }
            memset(block, 1, 40_000)
            blocks.append(block)
        }
        let inUse = AppHealthWatcher.ownFootprint()?.now ?? 0
        blocks.forEach { free($0) }
        let freed = AppHealthWatcher.ownFootprint()?.now ?? 0
        // What the app starts would inherit: nothing of the setting.
        let passed = getenv(variable) == nil ? "none" : "\(variable)"
        print(String(format: "malloc-check: in use %.1f MB, freed %.1f MB, passed on %@", inUse, freed, passed))
        exit(0)
    }
}
