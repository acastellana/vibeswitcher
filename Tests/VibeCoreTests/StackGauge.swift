import Darwin
import Foundation
import Testing
@testable import VibeCore

// One file, two test targets: VibeHostTests has it by a symlink of the same name (the session host's vault calls,
// HostVaultStackTests), so the gauge is the same code wherever a stack is measured.

/// How much stack a thread uses: the work runs on a fresh thread, whose stack pages are untouched until something
/// reads or writes them, and afterwards the lowest page it touched (`mincore`) is how deep it reached. The touch counts,
/// not what was written: a debug build's big frames are probed (read) a page at a time and mostly never written, and
/// it's a probe reaching the guard page that ends the process. Exact to the page (16 KB), no crash needed, and every
/// call can be measured (a run on stacks of shrinking size until one overflows would end the process).
enum StackGauge {
    /// `body` on a thread of `size` (`ToolThread.stackSize`, as the tool server and auto_advance give theirs); `used`
    /// is called on it afterwards with the bytes of stack it touched at its deepest, counted from the stack's top (the
    /// thread's own start frames included, as a real one's are).
    static func start(size: Int = ToolThread.stackSize, _ body: @escaping @Sendable () -> Void,
                      used: @escaping @Sendable (Int) -> Void) {
        let thread = Thread {
            body()
            used(touched())
        }
        thread.stackSize = size
        thread.start()
    }

    /// The bytes `body` took at its deepest, run on a thread of `size`; waits for it.
    static func used(size: Int = ToolThread.stackSize, _ body: @escaping @Sendable () -> Void) -> Int {
        // Written before the signal, read after the wait: the semaphore orders them.
        final class Deepest: @unchecked Sendable { var bytes = 0 }
        let deepest = Deepest(), done = DispatchSemaphore(value: 0)
        start(size: size, body) { bytes in
            deepest.bytes = bytes
            done.signal()
        }
        done.wait()
        return deepest.bytes
    }

    /// From the current thread's stack top to the lowest page of it ever read or written.
    private static func touched() -> Int {
        let me = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(me))
        let page = UInt(getpagesize())
        let bottom = (top - UInt(pthread_get_stacksize_np(me))) & ~(page - 1)
        let pages = Int((top - bottom + page - 1) / page)
        var states = [CChar](repeating: 0, count: pages)
        guard mincore(UnsafeMutableRawPointer(bitPattern: bottom), Int(top - bottom), &states) == 0 else { return Int(top - bottom) }
        // Untouched: anonymous memory and nothing else (MINCORE_ANONYMOUS); touched: resident, referenced, modified or
        // paged out since.
        guard let lowest = states.firstIndex(where: { UInt8(bitPattern: $0) & 0x7F != 0 }) else { return 0 }
        return Int(top - (bottom + UInt(lowest) * page))
    }

    /// What `bytes` is, for a message.
    static func kb(_ bytes: Int) -> String { "\(bytes >> 10) KB" }

    /// The tool server's threads have 4× what was used: `ToolThread.stackSize` says why.
    static func fits(_ bytes: Int, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(bytes * 4 <= ToolThread.stackSize,
                """
                \(what) used \(kb(bytes)) of stack, more than a quarter of the \(kb(ToolThread.stackSize)) the tool \
                server's and auto_advance's threads get (ToolThread.stackSize). Growth like this ends in a SIGBUS that \
                takes the lead's tool server down: move a large value the board holds to the heap (indirect, or `@Boxed` as \
                LeadTask.receipt is), or raise ToolThread.stackSize.
                """, sourceLocation: sourceLocation)
    }
}
