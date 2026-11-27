#if canImport(Darwin)
import Darwin
import Darwin.Mach
import Foundation
import MachO
import Testing

// The SIGPIPE probe, in every test run: when a write to a pipe or socket whose reader has gone raises the run's
// SIGPIPE (`brokenPipesFailTheRun`, TestSupport.swift, fails the run on it), the failure names the writer. A pipe's
// SIGPIPE goes to the process, not to the thread that wrote, and the dispatch source that hears it runs after the
// writer has returned: on 2026-11-18 a probe that looked from there saw only bystanders (scripts/dev/sigpipe-hunt).
// So the stack is taken where the writer still is, two ways:
//
// 1. The write hook. The test bundle's own pointers to write, writev, send, sendto and sendmsg (its code: the tests,
//    and VibeCore, VibeHost and the rest, linked into it) are rebound to wrappers that call the real one. On an EPIPE
//    whose descriptor raises SIGPIPE (no F_SETNOSIGPIPE, SO_NOSIGPIPE or MSG_NOSIGNAL), the wrapper records an issue
//    from the writer's own thread: the call, the descriptor and its kind, and the writer's stack. In the writer's test,
//    when the write is in its task; else outside any test, as the SIGPIPE issue is.
// 2. The snapshot. SIGPIPE's handler (the run catches it: `catchBrokenPipes`) takes every thread's stack inside the
//    handler, microseconds after the write: the thread it interrupted from the signal's own context, the others
//    suspended in turn (this process's own threads, through its own task; never another process's). The SIGPIPE
//    issue then names the threads it found in a write or a send, or in the hook. The signal needn't land on the
//    writer's thread (in the self-test it doesn't: the writer is found suspended, still in the hook), so a writer
//    outside the bundle (Foundation, libdispatch), which the hook doesn't see, is named only if it's still in its
//    write when the handler runs: untested.
//
// Both write symbols demangled and few lines, so a merge's flake log (which keeps a test's issue lines, at most 20 of
// them, secrets masked) keeps the writer. With VS_EPIPE_DUMP=<file>, every thread's stack goes to <file> as well.
// VS_EPIPE_PROBE=0 leaves it out (the plain handler, nothing rebound): to time a run without it.
enum EPipeProbe {
    /// Whether the probe is in this run (VS_EPIPE_PROBE isn't "0").
    static let enabled = ProcessInfo.processInfo.environment["VS_EPIPE_PROBE"] != "0"
    /// Set once `install` has run (`BrokenPipeTests` checks it did, and that SIGPIPE's handler is the probe's).
    nonisolated(unsafe) static var installed = false
    /// What the rebinding did, as "write, writev, …" (a symbol the bundle doesn't call isn't there to rebind).
    nonisolated(unsafe) static var rebound: [String] = []
    /// The most stack lines an issue gives: a flake log keeps at most 20 lines a test, its issue lines included, and
    /// the hook's issue and the SIGPIPE issue can both be under one name («unknown», outside any test).
    static let frameLines = 6

    // MARK: Install

    /// SIGPIPE's handler and the write hook, once, as the test bundle loads (`catchBrokenPipes`). Without the probe,
    /// the plain handler alone.
    static func install() {
        guard !installed else { return }
        installed = true
        var action = sigaction()
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_RESTART
        guard enabled else {
            action.__sigaction_u.__sa_handler = { _ in }
            sigaction(SIGPIPE, &action, nil)
            return
        }
        Snapshot.prepare()
        armHandler()
        Hook.install()
    }

    /// SIGPIPE's handler, the probe's, with its signal's context (SA_SIGINFO).
    static func armHandler() {
        var action = sigaction()
        sigemptyset(&action.sa_mask)
        action.__sigaction_u.__sa_sigaction = Snapshot.handler
        action.sa_flags = SA_RESTART | SA_SIGINFO
        sigaction(SIGPIPE, &action, nil)
    }

    /// Whether SIGPIPE's handler now is the probe's.
    static var handlerIsTheProbes: Bool {
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        guard let handler = current.__sigaction_u.__sa_sigaction else { return false }
        return unsafeBitCast(handler, to: UInt.self) == unsafeBitCast(Snapshot.handler, to: UInt.self)
    }

    // MARK: Symbols

    @_silgen_name("swift_demangle")
    private static func swiftDemangle(_ mangled: UnsafePointer<CChar>?, _ length: Int, _ output: UnsafeMutablePointer<CChar>?,
                                      _ outputSize: UnsafeMutablePointer<Int>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

    @_silgen_name("__cxa_demangle")
    private static func cxxDemangle(_ mangled: UnsafePointer<CChar>?, _ output: UnsafeMutablePointer<CChar>?,
                                    _ length: UnsafeMutablePointer<Int>?, _ status: UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>?

    /// A mangled Swift name the demangler left inside a demangled one (a macro's local function).
    private static let mangledLeft = try! NSRegularExpression(pattern: #"\$s[0-9A-Za-z_]+"#)

    /// The function at `pc`, demangled (Swift's and C++'s names), or its address in hex when no symbol covers it. No
    /// mangled name is left: a merge's flake log masks what looks like a secret, and a long mangled name can.
    static func symbol(_ pc: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: pc), &info) != 0, let name = info.dli_sname else { return "0x" + String(pc, radix: 16) }
        var text = String(cString: name)
        if let demangled = swiftDemangle(name, strlen(name), nil, nil, 0) {
            text = String(cString: demangled)
            free(demangled)
        } else if text.hasPrefix("_Z"), let demangled = cxxDemangle(name, nil, nil, nil) {
            text = String(cString: demangled)
            free(demangled)
        }
        return mangledLeft.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "…")
    }

    /// The probe's own frames and the system's write and signal plumbing, left out of a writer's stack.
    static func isPlumbing(_ name: String) -> Bool {
        name.contains("EPipeProbe") || syscalls.contains(name) || name == "_sigtramp"
    }

    /// Frames that say nothing of who wrote (a thread's start, a closure's reabstraction), left out of a short stack.
    static func isNoise(_ name: String) -> Bool {
        name.hasPrefix("reabstraction thunk") || name.hasPrefix("thunk for") || name.hasPrefix("partial apply")
            || ["thread_start", "_pthread_start", "start_wqthread", "_pthread_wqthread", "__NSThread__block_start__"].contains(name)
    }

    /// The functions a thread is in while it writes.
    static let syscalls: Set<String> = ["write", "writev", "send", "sendto", "sendmsg", "__write_nocancel", "__writev_nocancel",
                                        "__sendto_nocancel", "__sendmsg_nocancel", "pwrite", "__pwrite_nocancel"]

    /// `pcs`, symbolized, from the frame below the probe's own (a signal can land while the hook is still noting the
    /// write) or else the first that isn't plumbing, the noise left out; at most `limit` frames, each cut at 200
    /// characters.
    static func stack(_ pcs: [UInt], limit: Int) -> [String] {
        let names = pcs.map(symbol)
        let start = names.lastIndex { $0.contains("EPipeProbe.Hook") }.map { $0 + 1 } ?? names.firstIndex { !isPlumbing($0) } ?? names.count
        return names[start...].filter { !isNoise($0) }.prefix(limit).map { $0.count > 200 ? String($0.prefix(199)) + "…" : $0 }
    }

    /// "a pipe", "a socket", "a file" or "mode 0o…": what `fd` is.
    static func kind(_ fd: Int32) -> String {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return "closed by now" }
        switch info.st_mode & S_IFMT {
        case S_IFIFO: return "a pipe"
        case S_IFSOCK: return "a socket"
        case S_IFREG: return "a file"
        case S_IFCHR: return "a character device"
        default: return "mode 0o" + String(info.st_mode, radix: 8)
        }
    }

    /// Appends `text` to $VS_EPIPE_DUMP, when it's set.
    static func dump(_ text: String) {
        guard let path = ProcessInfo.processInfo.environment["VS_EPIPE_DUMP"], let real = Hook.realWrite else { return }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let bytes = Array(text.utf8)
        _ = real(fd, bytes, bytes.count)
        close(fd)
    }

    // MARK: What the SIGPIPE issue says

    /// Counts the SIGPIPE issues recorded (`brokenPipesFailTheRun`), so a test can wait for one.
    nonisolated(unsafe) static var reported = 0
    /// Counts the issues the write hook recorded.
    nonisolated(unsafe) static var hooked = 0
    static let counts = NSLock()

    /// The lines the SIGPIPE issue adds, from the snapshot the handler took: the threads it found in a write or a send,
    /// each with its stack. Waits for the snapshot (the dispatch source can hear the signal before the handler runs),
    /// at most `guardTime`: a signal the handler never saw (a test ignoring SIGPIPE for a moment) has none.
    static func snapshotLines(guardTime: TimeInterval = 10) -> [String] {
        guard enabled, installed else { return [] }
        guard Snapshot.wait(guardTime) else {
            return ["The probe's snapshot: none (SIGPIPE's handler didn't run for this signal: ignored or replaced at the time)."]
        }
        defer { Snapshot.release() }
        let threads = Snapshot.threads()
        var full = "=== SIGPIPE snapshot at \(String(format: "%.3f", Date().timeIntervalSince1970)), \(threads.count) threads\n"
        for thread in threads {
            full += "--- thread \(thread.port)\(thread.interrupted ? " (the handler's)" : "")\n"
                + thread.pcs.map { "  " + symbol($0) }.joined(separator: "\n") + "\n"
        }
        dump(full)
        // The writer: a thread in a write or a send, or in the probe's hook; the one the signal interrupted first, when
        // it is so, else every other thread so.
        func writing(_ thread: Snapshot.Thread) -> Bool {
            let names = thread.pcs.prefix(16).map(symbol)
            let below = names.drop { $0.contains("EPipeProbe") || $0 == "_sigtramp" }
            return below.prefix(3).contains { syscalls.contains($0) } || names.contains { $0.contains("EPipeProbe.Hook") }
        }
        let interrupted = threads.first { $0.interrupted }
        let writers = interrupted.map(writing) == true ? [interrupted!] : threads.filter(writing)
        guard !writers.isEmpty else {
            guard let interrupted else {
                return ["The probe's snapshot (in the handler): no thread of \(threads.count) was in a write or a send."]
            }
            return ["The probe's snapshot (in the handler): no thread of \(threads.count) was in a write or a send; the one the "
                    + "signal interrupted (thread \(interrupted.port), not necessarily the writer) was at:"]
                + stack(interrupted.pcs, limit: frameLines).map { "  " + $0 }
        }
        var lines: [String] = []
        let each = max(2, frameLines / min(writers.count, 3))
        for writer in writers.prefix(3) {
            lines.append("Writer in the probe's snapshot (in the handler): thread \(writer.port)"
                         + (writer.interrupted ? ", the one the signal interrupted" : "") + ", at:")
            lines += stack(writer.pcs, limit: each).map { "  " + $0 }
        }
        return lines
    }

    // MARK: The snapshot, in the handler

    enum Snapshot {
        static let depth = 40, most = 512
        /// Each thread's row: `depth` return addresses, 0 past its last.
        nonisolated(unsafe) static var pcs = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        nonisolated(unsafe) static var ports = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        /// The handler's own thread's frames, when the signal's context isn't given (`backtrace`).
        nonisolated(unsafe) static var own = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 1)
        nonisolated(unsafe) static var count = 0
        nonisolated(unsafe) static var interrupted = -1
        /// Set by the handler once a snapshot is taken; cleared by `release`, ready for the next signal.
        nonisolated(unsafe) static var taken: Int32 = 0
        nonisolated(unsafe) static var ready = semaphore_t()
        /// How many snapshots the handler has taken (`BrokenPipeProbeTests` waits on it).
        nonisolated(unsafe) static var total = 0

        /// Everything the handler touches, made before it can run: it can't allocate, or start a lazy global.
        static func prepare() {
            pcs = UnsafeMutablePointer<UInt64>.allocate(capacity: most * depth)
            pcs.initialize(repeating: 0, count: most * depth)
            ports = UnsafeMutablePointer<UInt32>.allocate(capacity: most)
            ports.initialize(repeating: 0, count: most)
            semaphore_create(mach_task_self_, &ready, SYNC_POLICY_FIFO, 0)
            own = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: depth)
            own.initialize(repeating: nil, count: depth)
            _ = (count, interrupted, taken, total, depth, most)
            // Each path the handler takes, once here: the first call of a Swift type's metadata (a C struct's) takes
            // the runtime's lock and may allocate, which a handler with other threads suspended mustn't.
            let me = mach_thread_self()
            if let state = state(of: me) { walk(pcs, pc: state.pc, lr: state.lr, fp: state.fp) }
            mach_port_deallocate(mach_task_self_, me)
            var mcontext = __darwin_mcontext64()
            var context = ucontext_t()
            withUnsafeMutablePointer(to: &mcontext) { mine in
                context.uc_mcontext = mine
                withUnsafeMutablePointer(to: &context) { let state = contextState(UnsafeMutableRawPointer($0)); walk(pcs, pc: state.pc, lr: state.lr, fp: state.fp) }
            }
            var current = sigaction()
            sigaction(SIGPIPE, nil, &current)
            _ = backtrace(own, Int32(depth))
            pcs.update(repeating: 0, count: depth)
        }

        /// A suspended thread's pc, lr and fp.
        private static func state(of thread: thread_act_t) -> (pc: UInt64, lr: UInt64, fp: UInt64)? {
            var state = arm_thread_state64_t()
            var size = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
            let got = withUnsafeMutablePointer(to: &state) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(size)) { thread_get_state(thread, ARM_THREAD_STATE64, $0, &size) }
            }
            return got == KERN_SUCCESS ? (state.__pc, state.__lr, state.__fp) : nil
        }

        /// The interrupted thread's pc, lr and fp, from a signal's context.
        private static func contextState(_ context: UnsafeMutableRawPointer) -> (pc: UInt64, lr: UInt64, fp: UInt64) {
            let state = context.assumingMemoryBound(to: ucontext_t.self).pointee.uc_mcontext.pointee.__ss
            return (state.__pc, state.__lr, state.__fp)
        }

        /// Reads the 16 bytes of a frame record at `fp` (the caller's frame pointer, its return address), safely: a
        /// bad frame pointer fails the read instead of faulting the run.
        private static func frame(_ fp: UInt64) -> (next: UInt64, pc: UInt64)? {
            var record: (UInt64, UInt64) = (0, 0)
            var size: vm_size_t = 0
            let got = withUnsafeMutablePointer(to: &record) {
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), 16, vm_address_t(UInt(bitPattern: $0)), &size)
            }
            return got == KERN_SUCCESS && size == 16 ? record : nil
        }

        /// `row`'s return addresses, from a thread's pc, lr and fp.
        private static func walk(_ row: UnsafeMutablePointer<UInt64>, pc: UInt64, lr: UInt64, fp start: UInt64) {
            row.update(repeating: 0, count: depth)
            row[0] = pc; row[1] = lr
            var fp = start, n = 2
            while n < depth, fp != 0, fp & 7 == 0, let record = frame(fp) {
                if record.pc != 0 { row[n] = record.pc; n += 1 }
                if record.next <= fp { break }
                fp = record.next
            }
        }

        /// SIGPIPE's handler: every thread's stack, once until `release`. Async-signal-safe: Mach calls and the buffers
        /// `prepare` made, nothing allocated, no lock.
        static let handler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { _, _, context in
            guard OSAtomicCompareAndSwap32(0, 1, &taken) else { return }
            var list: thread_act_array_t?
            var listed: mach_msg_type_number_t = 0
            let me = mach_thread_self()
            var rows = 0
            interrupted = -1
            // The thread the signal interrupted: its state as the signal found it, from the signal's context. Only
            // while the handler is installed with SA_SIGINFO: a test that ignores SIGPIPE for a moment and puts it back
            // with signal() (HostedSessionTests) drops the flag, and the context argument is then no pointer at all.
            // Then its frames from here, the handler's and _sigtramp's above the interrupted ones.
            var current = sigaction()
            sigaction(SIGPIPE, nil, &current)
            if current.sa_flags & SA_SIGINFO != 0, let context {
                let state = contextState(context)
                walk(pcs, pc: state.pc, lr: state.lr, fp: state.fp)
            } else {
                let got = Int(backtrace(own, Int32(depth)))
                pcs.update(repeating: 0, count: depth)
                var n = 0
                while n < got { pcs[n] = UInt64(UInt(bitPattern: own[n])); n += 1 }
            }
            ports[0] = me
            interrupted = 0
            rows = 1
            if task_threads(mach_task_self_, &list, &listed) == KERN_SUCCESS, let threads = list {
                var i = 0
                while i < Int(listed) {
                    let thread = threads[i]
                    i += 1
                    if thread != me, rows < most, thread_suspend(thread) == KERN_SUCCESS {
                        if let state = state(of: thread) {
                            walk(pcs + rows * depth, pc: state.pc, lr: state.lr, fp: state.fp)
                            ports[rows] = thread
                            rows += 1
                        }
                        thread_resume(thread)
                    }
                    mach_port_deallocate(mach_task_self_, thread)
                }
                vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                              vm_size_t(Int(listed) * MemoryLayout<thread_act_t>.size))
            }
            mach_port_deallocate(mach_task_self_, me)
            count = rows
            total += 1
            semaphore_signal(ready)
        }

        /// Waits for the handler's snapshot, at most `seconds`.
        static func wait(_ seconds: TimeInterval) -> Bool {
            let whole = UInt32(seconds)
            let time = mach_timespec_t(tv_sec: whole, tv_nsec: clock_res_t((seconds - Double(whole)) * 1e9))
            return semaphore_timedwait(ready, time) == KERN_SUCCESS
        }

        /// Ready for the next signal's snapshot.
        static func release() {
            OSAtomicCompareAndSwap32(1, 0, &taken)
        }

        struct Thread {
            var port: UInt32
            var interrupted: Bool
            var pcs: [UInt]
        }

        /// The snapshot's threads (read between `wait` and `release`).
        static func threads() -> [Thread] {
            (0..<count).map { i in
                let row = pcs + i * depth
                let pcs = (0..<depth).map { UInt(row[$0] & 0x0000_7FFF_FFFF_FFFF) }.filter { $0 != 0 }
                return Thread(port: ports[i], interrupted: i == interrupted, pcs: pcs)
            }
        }
    }

    // MARK: The write hook

    enum Hook {
        typealias Write = @convention(c) (Int32, UnsafeRawPointer?, Int) -> Int
        typealias Writev = @convention(c) (Int32, UnsafePointer<iovec>?, Int32) -> Int
        typealias Send = @convention(c) (Int32, UnsafeRawPointer?, Int, Int32) -> Int
        typealias Sendto = @convention(c) (Int32, UnsafeRawPointer?, Int, Int32, UnsafePointer<sockaddr>?, socklen_t) -> Int
        typealias Sendmsg = @convention(c) (Int32, UnsafePointer<msghdr>?, Int32) -> Int

        nonisolated(unsafe) static var realWrite: Write?
        nonisolated(unsafe) static var realWritev: Writev?
        nonisolated(unsafe) static var realSend: Send?
        nonisolated(unsafe) static var realSendto: Sendto?
        nonisolated(unsafe) static var realSendmsg: Sendmsg?

        /// The most issues the hook records in a run: a loop writing to a dead pipe would print one a write.
        static let most = 5

        /// After a failed call: when it failed with EPIPE on a descriptor that raises SIGPIPE, records the writer.
        /// errno as the call left it.
        @inline(never)
        static func noted(_ call: String, _ fd: Int32, _ flags: Int32, _ result: Int, snapshots before: Int) -> Int {
            guard result < 0 else { return result }
            let saved = errno
            defer { errno = saved }
            // 0: no guard. 1 is a guard; -1, a descriptor closed meanwhile by another thread, can't be told: not noted.
            guard saved == EPIPE, flags & MSG_NOSIGNAL == 0, fcntl(fd, F_GETNOSIGPIPE) == 0 else { return result }
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
            let depth = Int(backtrace(&frames, Int32(frames.count)))
            let pcs = frames.prefix(depth).compactMap { $0.map { UInt(bitPattern: $0) } }
            let first = counts.withLock { hooked += 1; return hooked <= most }
            let test = Test.current.map { "in test \($0.name)" } ?? "outside any test"
            let head = "EPIPE probe: \(call)(fd \(fd), \(kind(fd))) failed with EPIPE and raised SIGPIPE (no F_SETNOSIGPIPE, "
                + "SO_NOSIGPIPE or MSG_NOSIGNAL), thread \(pthread_mach_thread_np(pthread_self())), \(test). The writer:"
            dump("=== " + head + "\n" + pcs.map(symbol).map { "  " + $0 }.joined(separator: "\n") + "\n")
            if first { Issue.record(Comment(rawValue: ([head] + stack(pcs, limit: frameLines - 1).map { "  " + $0 }).joined(separator: "\n"))) }
            // The writer stays in here until the handler has taken its snapshot (10 s at most, as `snapshotLines` waits),
            // so the snapshot finds it:
            // the kernel raises a write's SIGPIPE on the process, and any thread not blocking it may take it (the Mac
            // runs, 2026-11-22/23: the main thread, in its run loop, took it, and by the time its handler ran the
            // writer had left the write and this hook, so "no thread was in a write"). A snapshot taken before this
            // (the handler ran at once) already found the writer here or in the call. 1 s wasn't enough on the 3-core runner
            // under load: the thread that took the signal ran its handler later than that, and the snapshot found no
            // writer (v2 macos, core, 969fa2a6). Only while the probe's own handler is SIGPIPE's, which then runs.
            if handlerIsTheProbes {
                let deadline = Date().addingTimeInterval(10)
                while Snapshot.total == before, Date() < deadline { usleep(1_000) }
            }
            return result
        }

        // Each takes the snapshots' count before its call: one the call's SIGPIPE adds is told from one before it.
        static let write: Write = { fd, buffer, count in
            let before = Snapshot.total
            return noted("write", fd, 0, realWrite!(fd, buffer, count), snapshots: before)
        }
        static let writev: Writev = { fd, vectors, count in
            let before = Snapshot.total
            return noted("writev", fd, 0, realWritev!(fd, vectors, count), snapshots: before)
        }
        static let send: Send = { fd, buffer, count, flags in
            let before = Snapshot.total
            return noted("send", fd, flags, realSend!(fd, buffer, count, flags), snapshots: before)
        }
        static let sendto: Sendto = { fd, buffer, count, flags, to, length in
            let before = Snapshot.total
            return noted("sendto", fd, flags, realSendto!(fd, buffer, count, flags, to, length), snapshots: before)
        }
        static let sendmsg: Sendmsg = { fd, message, flags in
            let before = Snapshot.total
            return noted("sendmsg", fd, flags, realSendmsg!(fd, message, flags), snapshots: before)
        }

        static func install() {
            let everywhere = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
            func real<T>(_ name: String, _ type: T.Type) -> T? { dlsym(everywhere, name).map { unsafeBitCast($0, to: type) } }
            realWrite = real("write", Write.self)
            realWritev = real("writev", Writev.self)
            realSend = real("send", Send.self)
            realSendto = real("sendto", Sendto.self)
            realSendmsg = real("sendmsg", Sendmsg.self)
            guard realWrite != nil, realWritev != nil, realSend != nil, realSendto != nil, realSendmsg != nil else { return }
            _ = counts
            func address<T>(_ function: T) -> UInt64 { UInt64(UInt(bitPattern: unsafeBitCast(function, to: UnsafeRawPointer.self))) }
            let replacements: [String: UInt64] = [
                "_write": address(write), "_writev": address(writev), "_send": address(send),
                "_sendto": address(sendto), "_sendmsg": address(sendmsg),
            ]
            // This bundle's image: the one holding this function.
            var info = Dl_info()
            guard dladdr(unsafeBitCast(write, to: UnsafeRawPointer.self), &info) != 0, let base = info.dli_fbase else { return }
            for index in 0..<_dyld_image_count() {
                guard let header = _dyld_get_image_header(index), UnsafeRawPointer(header) == UnsafeRawPointer(base) else { continue }
                rebound = rebind(header, slide: _dyld_get_image_vmaddr_slide(index), replacements)
            }
        }

        /// Points the image's lazy and non-lazy symbol pointers for `replacements`' symbols at them. The names done.
        private static func rebind(_ header: UnsafePointer<mach_header>, slide: Int, _ replacements: [String: UInt64]) -> [String] {
            var command = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
            var linkedit: segment_command_64?, symtab: symtab_command?, dysymtab: dysymtab_command?
            var segments: [UnsafeRawPointer] = []
            for _ in 0..<header.pointee.ncmds {
                let load = command.load(as: load_command.self)
                switch Int32(bitPattern: load.cmd) {
                case LC_SEGMENT_64:
                    let segment = command.load(as: segment_command_64.self)
                    let name = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    if name == "__LINKEDIT" { linkedit = segment } else if name.hasPrefix("__DATA") || name == "__AUTH_CONST" { segments.append(command) }
                case LC_SYMTAB: symtab = command.load(as: symtab_command.self)
                case LC_DYSYMTAB: dysymtab = command.load(as: dysymtab_command.self)
                default: break
                }
                command += Int(load.cmdsize)
            }
            guard let linkedit, let symtab, let dysymtab else { return [] }
            let linkBase = UInt(bitPattern: slide) &+ UInt(linkedit.vmaddr) &- UInt(linkedit.fileoff)
            guard let symbols = UnsafePointer<nlist_64>(bitPattern: linkBase + UInt(symtab.symoff)),
                  let strings = UnsafePointer<CChar>(bitPattern: linkBase + UInt(symtab.stroff)),
                  let indirect = UnsafePointer<UInt32>(bitPattern: linkBase + UInt(dysymtab.indirectsymoff)) else { return [] }
            var done: [String] = []
            for segmentCommand in segments {
                let segment = segmentCommand.load(as: segment_command_64.self)
                var section = segmentCommand + MemoryLayout<segment_command_64>.size
                for _ in 0..<segment.nsects {
                    let info = section.load(as: section_64.self)
                    section += MemoryLayout<section_64>.size
                    let type = Int32(bitPattern: info.flags) & SECTION_TYPE
                    guard type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS,
                          let pointers = UnsafeMutablePointer<UInt64>(bitPattern: UInt(bitPattern: slide) &+ UInt(info.addr)) else { continue }
                    for slot in 0..<Int(info.size) / 8 {
                        let symbol = indirect[Int(info.reserved1) + slot]
                        if symbol & UInt32(INDIRECT_SYMBOL_ABS) != 0 || symbol & UInt32(INDIRECT_SYMBOL_LOCAL) != 0 { continue }
                        let name = String(cString: strings + Int(symbols[Int(symbol)].n_un.n_strx))
                        guard let replacement = replacements[name] else { continue }
                        let page = UInt(bitPattern: pointers + slot) & ~UInt(vm_page_size - 1)
                        guard vm_protect(mach_task_self_, vm_address_t(page), vm_size_t(vm_page_size), 0,
                                         VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS else { continue }
                        pointers[slot] = replacement
                        done.append(String(name.dropFirst()))
                    }
                }
            }
            return done
        }
    }
}
#endif
