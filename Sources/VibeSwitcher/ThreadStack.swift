import Darwin
import Foundation
import VibeCore

/// A thread of this process's stack, read from another thread: the thread is suspended only while its registers and
/// frame pointers are read into a buffer made beforehand (nothing allocated, no lock taken: what it holds could be
/// what that would wait for), then resumed, and the addresses named afterwards with `dladdr`. In-process only: no
/// other process is looked at, nothing is attached.
final class ThreadStack: @unchecked Sendable {
    private let thread: thread_act_t
    private let capacity = 256
    private let buffer: UnsafeMutablePointer<UInt>
    /// The thread's registers and one frame's two words, read into memory made here, through raw pointers: while the
    /// thread is suspended nothing typed is made (in a debug build a struct or tuple there would look its type up in
    /// the runtime's cache the first time, under its lock, with malloc).
    private let state: UnsafeMutableRawPointer
    private let stateWords: mach_msg_type_number_t
    private let pcAt: Int, fpAt: Int, lrAt: Int?
    private let pair: UnsafeMutableRawPointer
    /// Names by address, kept across catches: a stall's stacks share most frames.
    private var names: [UInt: AppHealth.StackFrame] = [:]

    /// The calling thread's (call it on the thread to watch).
    init() {
        thread = mach_thread_self()
        buffer = .allocate(capacity: capacity)
        #if arch(arm64)
        let size = MemoryLayout<arm_thread_state64_t>.size
        pcAt = MemoryLayout<arm_thread_state64_t>.offset(of: \.__pc)!
        fpAt = MemoryLayout<arm_thread_state64_t>.offset(of: \.__fp)!
        lrAt = MemoryLayout<arm_thread_state64_t>.offset(of: \.__lr)!
        #else
        let size = MemoryLayout<x86_thread_state64_t>.size
        pcAt = MemoryLayout<x86_thread_state64_t>.offset(of: \.__rip)!
        fpAt = MemoryLayout<x86_thread_state64_t>.offset(of: \.__rbp)!
        lrAt = nil
        #endif
        state = .allocate(byteCount: size, alignment: 16)
        stateWords = mach_msg_type_number_t(size / MemoryLayout<natural_t>.size)
        pair = .allocate(byteCount: 16, alignment: 16)
        // Once through the read the suspended walk makes, so nothing in it is a first time.
        _ = readPair(at: UInt(bitPattern: pair))
    }

    deinit {
        buffer.deallocate()
        state.deallocate()
        pair.deallocate()
        mach_port_deallocate(mach_task_self_, thread)
    }

    /// The return addresses on the thread's stack, innermost first (its pc first); empty if it can't be read.
    /// Not from the watched thread itself.
    func addresses() -> [UInt] {
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        let count = walk()
        thread_resume(thread)
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    /// The stack, outermost frame first, named.
    func frames() -> [AppHealth.StackFrame] {
        addresses().enumerated().map { index, address in name(address, isReturn: index > 0) }.reversed()
    }

    /// Pointer authentication bits off a code address (arm64e code signs its return addresses).
    private static func strip(_ address: UInt) -> UInt { address & 0x0000_7FFF_FFFF_FFFF }

    /// The two words at `address` into `pair`, through the kernel: a bad pointer is an error, not a crash.
    private func readPair(at address: UInt) -> Bool {
        var got: vm_size_t = 0
        return vm_read_overwrite(mach_task_self_, vm_address_t(address), 16, vm_address_t(UInt(bitPattern: pair)), &got) == KERN_SUCCESS
            && got == 16
    }

    /// Reads the suspended thread's pc and frame chain into `buffer`; the count read.
    private func walk() -> Int {
        var count = stateWords
        #if arch(arm64)
        let flavor = ARM_THREAD_STATE64
        #else
        let flavor = x86_THREAD_STATE64
        #endif
        guard thread_get_state(thread, flavor, state.assumingMemoryBound(to: natural_t.self), &count) == KERN_SUCCESS else { return 0 }
        var fp = state.load(fromByteOffset: fpAt, as: UInt.self)
        // A leaf function that made no frame of its own (a system call's stub) left its caller in lr alone.
        var leafCaller: UInt = 0
        if let lrAt { leafCaller = Self.strip(state.load(fromByteOffset: lrAt, as: UInt.self)) }
        var read = 0
        buffer[read] = Self.strip(state.load(fromByteOffset: pcAt, as: UInt.self))
        read += 1
        // Each frame: the caller's frame pointer, then the return address.
        while fp != 0, fp % 8 == 0, read < capacity, readPair(at: fp) {
            // An async frame's saved frame pointer is flagged in its top bits.
            let next = Self.strip(pair.load(as: UInt.self)), back = Self.strip(pair.load(fromByteOffset: 8, as: UInt.self))
            guard back != 0 else { break }
            // lr is stale when the function made a frame (a return into itself, named as it is: the health digest drops
            // the repeat).
            if leafCaller != 0, leafCaller != back, read < capacity - 1 {
                buffer[read] = leafCaller
                read += 1
            }
            leafCaller = 0
            buffer[read] = back
            read += 1
            // The stack grows down: callers' frames are higher.
            guard next > fp else { break }
            fp = next
        }
        return read
    }

    /// `address` named: a return address is looked up one byte back, inside the call that made it.
    private func name(_ address: UInt, isReturn: Bool) -> AppHealth.StackFrame {
        if let known = names[address] { return known }
        var info = Dl_info()
        var frame = AppHealth.StackFrame(name: "???", image: "???", offset: 0, address: address)
        if let pointer = UnsafeRawPointer(bitPattern: isReturn ? address - 1 : address), dladdr(pointer, &info) != 0 {
            if let file = info.dli_fname { frame.image = (String(cString: file) as NSString).lastPathComponent }
            if let symbol = info.dli_sname {
                frame.name = Self.demangle(symbol)
                let start = UInt(bitPattern: info.dli_saddr)
                frame.offset = start > 0 && start <= address ? address - start : 0
            }
        }
        names[address] = frame
        return frame
    }

    @_silgen_name("swift_demangle")
    private static func swiftDemangle(_ mangled: UnsafePointer<CChar>?, _ length: UInt, _ output: UnsafeMutablePointer<CChar>?,
                                      _ size: UnsafeMutablePointer<UInt>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

    /// A Swift symbol demangled ("$s12VibeSwitcher…" → "MainWindowController.followChat()"), the others as they are.
    static func demangle(_ symbol: UnsafePointer<CChar>) -> String {
        let raw = String(cString: symbol)
        guard raw.hasPrefix("$s") || raw.hasPrefix("_$s") || raw.hasPrefix("$S") || raw.hasPrefix("_T") else { return raw }
        guard let demangled = swiftDemangle(symbol, UInt(strlen(symbol)), nil, nil, 0) else { return raw }
        defer { free(demangled) }
        // Without the app's module name: as `sample` names them.
        return String(cString: demangled).replacingOccurrences(of: "VibeSwitcher.", with: "")
    }
}
