#if os(Linux)
import Foundation
import Glibc

/// Linux's: `pthread_getattr_np` and `pthread_attr_getstack` through the shim (`vibe_thread_stack`: the lowest address
/// and the size, the top their sum),
/// and `mincore`'s low bit (resident: a thread stack's untouched pages aren't, as nothing mapped them in).
extension Platform.ThreadStack {
    public static func bounds() -> (top: UInt, size: Int)? {
        var low: UnsafeMutableRawPointer?
        var size = 0
        guard vibe_thread_stack(&low, &size) == 0, let low else { return nil }
        return (UInt(bitPattern: low) + UInt(size), size)
    }

    public static func touchedPages(from start: UInt, count: Int) -> [Bool]? {
        var states = [UInt8](repeating: 0, count: count)
        let page = Int(getpagesize())
        guard mincore(UnsafeMutableRawPointer(bitPattern: start), count * page, &states) == 0 else { return nil }
        return states.map { $0 & 1 != 0 }
    }
}
#endif
