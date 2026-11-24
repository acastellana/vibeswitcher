#if canImport(Darwin)
import Darwin
import Foundation

/// The Mac's: `pthread_get_stackaddr_np`, `pthread_get_stacksize_np`, and `mincore`'s states (`MINCORE_ANONYMOUS` alone
/// is untouched anonymous memory).
extension Platform.ThreadStack {
    public static func bounds() -> (top: UInt, size: Int)? {
        let me = pthread_self()
        return (UInt(bitPattern: pthread_get_stackaddr_np(me)), pthread_get_stacksize_np(me))
    }

    public static func touchedPages(from start: UInt, count: Int) -> [Bool]? {
        var states = [CChar](repeating: 0, count: count)
        let page = Int(getpagesize())
        guard mincore(UnsafeMutableRawPointer(bitPattern: start), count * page, &states) == 0 else { return nil }
        return states.map { UInt8(bitPattern: $0) & 0x7F != 0 }
    }
}
#endif
