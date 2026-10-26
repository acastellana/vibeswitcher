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
    /// Names by address, kept across catches: a stall's stacks share most frames.
    private var names: [UInt: AppHealth.StackFrame] = [:]

    /// The calling thread's (call it on the thread to watch).
    init() {
        thread = mach_thread_self()
        buffer = .allocate(capacity: capacity)
    }

    deinit {
        buffer.deallocate()
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

    /// Reads the suspended thread's pc and frame chain into `buffer`; the count read.
    private func walk() -> Int {
        var pc: UInt = 0, fp: UInt = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(thread, ARM_THREAD_STATE64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__pc)
        fp = UInt(state.__fp)
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(thread, x86_THREAD_STATE64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__rip)
        fp = UInt(state.__rbp)
        #endif
        var read = 0
        buffer[read] = Self.strip(pc)
        read += 1
        // Each frame: the caller's frame pointer, then the return address. Read through the kernel, so a bad pointer
        // is an error, not a crash.
        var pair: (UInt, UInt) = (0, 0)
        while fp != 0, fp % 8 == 0, read < capacity {
            var got: vm_size_t = 0
            let ok = withUnsafeMutablePointer(to: &pair) {
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                                  vm_address_t(UInt(bitPattern: $0)), &got) == KERN_SUCCESS
            }
            guard ok, got == MemoryLayout<(UInt, UInt)>.size else { break }
            // An async frame's saved frame pointer is flagged in its top bits.
            let (next, back) = (Self.strip(pair.0), pair.1)
            guard back != 0 else { break }
            buffer[read] = Self.strip(back)
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
