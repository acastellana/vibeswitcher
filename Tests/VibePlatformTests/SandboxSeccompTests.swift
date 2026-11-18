import Foundation
import Testing
@testable import VibePlatform

#if os(Linux)
// Linux only: the filter is Linux's.

/// The box's seccomp filter (shim_seccomp.c), seen from a program in a box, against the same probe in a plain child
/// where the kernel alone answers: a refusal counts only where the plain child got something else, so a probe that
/// proves nothing (the kernel refusing it anyway) is found. The probes are `python3 -I` with ctypes, by the system
/// call's number for this machine.
@Suite(.serialized) struct SandboxSeccompTests {
    static let skip = "needs a box and python3: \(ShimBox.unavailable ?? "no /usr/bin/python3")"
    static let can = ShimBox.unavailable == nil && ShimBox.python

    /// The numbers of the calls the probes make, for this machine's architecture.
    static let numbers: [String: Int] = {
        #if arch(x86_64)
        return ["bpf": 321, "perf_event_open": 298, "userfaultfd": 323, "add_key": 248, "request_key": 249, "keyctl": 250,
                "kexec_load": 246, "kexec_file_load": 320, "init_module": 175, "finit_module": 313, "delete_module": 176,
                "swapon": 167, "swapoff": 168, "open_by_handle_at": 304, "mount": 165, "umount2": 166, "pivot_root": 155,
                "unshare": 272, "setns": 308, "clone3": 435, "fsopen": 430, "open_tree": 428, "mount_setattr": 442,
                "io_uring_setup": 425, "io_uring_enter": 426, "io_uring_register": 427, "fanotify_init": 300]
        #else
        return ["bpf": 280, "perf_event_open": 241, "userfaultfd": 282, "add_key": 217, "request_key": 218, "keyctl": 219,
                "kexec_load": 104, "kexec_file_load": 294, "init_module": 105, "finit_module": 273, "delete_module": 106,
                "swapon": 224, "swapoff": 225, "open_by_handle_at": 265, "mount": 40, "umount2": 39, "pivot_root": 41,
                "unshare": 97, "setns": 268, "clone3": 435, "fsopen": 430, "open_tree": 428, "mount_setattr": 442,
                "io_uring_setup": 425, "io_uring_enter": 426, "io_uring_register": 427, "fanotify_init": 262]
        #endif
    }()

    /// Python that defines `call(name, *args)`: prints "name ok" or "name ERRNO".
    static var prelude: String {
        let table = numbers.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ")
        return """
            import ctypes, errno, os, socket, sys
            libc = ctypes.CDLL(None, use_errno=True)
            libc.syscall.restype = ctypes.c_long
            numbers = {\(table)}
            def call(label, name, *args):
                result = libc.syscall(ctypes.c_long(numbers[name]), *[ctypes.c_long(a) if isinstance(a, int) else a for a in args])
                print(label, "ok" if result >= 0 else errno.errorcode.get(ctypes.get_errno(), str(ctypes.get_errno())), flush=True)
                if result >= 0 and label.startswith("fd "):
                    os.close(result)

            """
    }

    /// `source` run by python3 in a box of `plan`, and in a plain child of this test: each one's lines, by label.
    static func both(_ source: String, nesting: Bool = false, _ name: String) throws -> (box: [String: String], plain: [String: String]) {
        let (root, box) = try ShimBox.scratch(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let program = prelude + source
        let (ended, errors) = try ShimBox.python(program, ShimBox.plan(box.path, nesting: nesting), in: box)
        #expect(ended.exit == 0, "\(errors)")
        var plain = Platform.Spawn(executable: "/usr/bin/python3", arguments: ["python3", "-I", "-c", program])
        plain.directory = box.path
        let outside = try SpawnTests.output(of: plain)
        #expect(outside.exit == 0)
        func labelled(_ text: String) -> [String: String] {
            Dictionary(ShimBox.lines(text).compactMap { line in
                guard let space = line.lastIndex(of: " ") else { return nil }
                return (String(line[..<space]), String(line[line.index(after: space)...]))
            }, uniquingKeysWith: { $1 })
        }
        return (labelled(ended.output), labelled(outside.output))
    }

    @Test(.enabled(if: can, "\(skip)"))
    func hyperVPacketAndNetfilterSocketsAreRefused() throws {
        let source = """
            for label, family, kind, protocol in [("vsock", 40, 1, 0), ("packet", 17, 2, 0), ("alg", 38, 5, 0),
                                                  ("netfilter netlink", 16, 3, 12), ("route netlink", 16, 3, 0),
                                                  ("unix", 1, 1, 0), ("inet", 2, 1, 0), ("inet6", 10, 1, 0)]:
                try:
                    socket.socket(family, kind, protocol).close(); print(label, "ok")
                except OSError as error:
                    print(label, errno.errorcode[error.errno])
            try:
                socket.socketpair(40, 1, 0); print("vsock pair ok")
            except OSError as error:
                print("vsock pair", errno.errorcode[error.errno])
            """
        let (box, plain) = try Self.both(source, "seccomp-sockets")
        for refused in ["vsock", "alg", "netfilter netlink", "vsock pair"] { #expect(box[refused] == "EPERM", "\(refused): \(box)") }
        // AF_PACKET needs CAP_NET_RAW, which nothing in a box holds: refused by the filter before the kernel asks.
        #expect(box["packet"] == "EPERM", "\(box)")
        for allowed in ["route netlink", "unix", "inet", "inet6"] { #expect(box[allowed] == "ok", "\(allowed): \(box)") }
        // The plain child shows each refusal is the filter's: the kernel alone lets these open here.
        for proven in ["alg", "netfilter netlink"] { #expect(plain[proven] == "ok", "\(proven): \(plain)") }
        if Platform.Sandbox.probe().vsock { #expect(plain["vsock"] == "ok", "\(plain)") }
    }

    @Test(.enabled(if: can, "\(skip)"))
    func bpfPerfUserfaultfdAndTheKeyringsAreRefused() throws {
        // The keyring probes work on a session keyring of the probe's own, joined first (refused in the box), never the
        // test run's.
        let source = """
            call("join", "keyctl", 1, 0)
            call("fd bpf", "bpf", 0, 0, 0)
            call("fd perf_event_open", "perf_event_open", 0, 0, -1, -1, 0)
            call("fd userfaultfd", "userfaultfd", 1 | 0o2000000)
            call("keyctl", "keyctl", 0, -3, 0)
            call("add_key", "add_key", ctypes.c_char_p(b"user"), ctypes.c_char_p(b"vibe-probe"), ctypes.c_char_p(b"x"), 1, -3)
            call("request_key", "request_key", ctypes.c_char_p(b"user"), ctypes.c_char_p(b"vibe-probe"), 0, 0)
            for name in ["kexec_load", "kexec_file_load", "init_module", "finit_module", "delete_module", "swapon", "swapoff", "open_by_handle_at"]:
                call(name, name, -1, 0, 0, 0)
            """
        let (box, plain) = try Self.both(source, "seccomp-calls")
        for name in ["fd bpf", "fd perf_event_open", "fd userfaultfd", "keyctl", "add_key", "request_key", "kexec_load",
                     "kexec_file_load", "init_module", "finit_module", "delete_module", "swapon", "swapoff", "open_by_handle_at"] {
            #expect(box[name] == "EPERM", "\(name): \(box)")
        }
        // Where the kernel alone answers otherwise, the refusal is the filter's. (bpf, the modules, kexec, swap and
        // open_by_handle_at are refused by the kernel too here, for want of a capability: the filter is a second lock.)
        #expect(plain["keyctl"] == "ok", "\(plain)")
        #expect(plain["add_key"] == "ok", "\(plain)")
        #expect(plain["fd perf_event_open"] == "EFAULT", "\(plain)")
        #expect(plain["fd userfaultfd"] == "ok", "\(plain)")
    }

    /// io_uring runs its operations in the kernel past the filter's checks (sockets of any family, from 5.19): its three
    /// calls are refused. In a plain child the kernel sets a ring up, and answers the other two by their arguments.
    @Test(.enabled(if: can, "\(skip)"))
    func ioUringIsRefused() throws {
        let source = """
            parameters = ctypes.create_string_buffer(120)
            call("fd io_uring_setup", "io_uring_setup", 1, parameters)
            call("io_uring_enter", "io_uring_enter", -1, 0, 0, 0, 0, 0)
            call("io_uring_register", "io_uring_register", -1, 0, 0, 0)
            """
        let (box, plain) = try Self.both(source, "seccomp-io-uring")
        for name in ["fd io_uring_setup", "io_uring_enter", "io_uring_register"] { #expect(box[name] == "EPERM", "\(name): \(box)") }
        // The kernel alone answers otherwise: a ring, where io_uring is on; else its own refusal, never the filter's.
        #expect(plain["fd io_uring_setup"] == "ok" || plain["fd io_uring_setup"] == "ENOSYS", "\(plain)")
        #expect(plain["io_uring_enter"] == "EBADF" && plain["io_uring_register"] == "EBADF", "\(plain)")
    }

    /// fanotify_init is refused (the lead's decision of 2026-11-18). The probe asks for what the kernel gives a process
    /// with no capability since 5.13: a group that reports file ids (`FAN_CLASS_NOTIF | FAN_REPORT_FID`). In a plain
    /// child the kernel makes one; in a box without the filter's entry it would too, the program being as
    /// unprivileged there.
    @Test(.enabled(if: can, "\(skip)"))
    func fanotifyIsRefused() throws {
        let (box, plain) = try Self.both(#"call("fd fanotify_init", "fanotify_init", 0x200, 0)"# + "\n", "seccomp-fanotify")
        #expect(box["fd fanotify_init"] == "EPERM", "\(box)")
        // The kernel alone gives a group (5.13 and later), or has no fanotify at all: never the filter's refusal.
        #expect(plain["fd fanotify_init"] == "ok" || plain["fd fanotify_init"] == "ENOSYS", "\(plain)")
    }

    @Test(.enabled(if: can, "\(skip)"))
    func typingIntoTheTerminalByIoctlIsRefused() throws {
        // A pty made where the probe runs, made its controlling terminal by a child in a session of its own; then
        // TIOCSTI and TIOCLINUX on it.
        let source = """
            import fcntl, termios
            master, slave = os.openpty()
            name = os.ttyname(slave)
            read_end, write_end = os.pipe()
            child = os.fork()
            if child == 0:
                os.setsid()
                own = os.open(name, os.O_RDWR)
                results = []
                for label, request in [("TIOCSTI", termios.TIOCSTI), ("TIOCLINUX", 0x541C)]:
                    try:
                        fcntl.ioctl(own, request, b"x"); results.append(label + " ok")
                    except OSError as error:
                        results.append(label + " " + errno.errorcode[error.errno])
                os.write(write_end, ("\\n".join(results) + "\\n").encode())
                os._exit(0)
            os.close(write_end)
            os.waitpid(child, 0)
            print(os.read(read_end, 1000).decode(), end="")
            """
        let (box, plain) = try Self.both(source, "seccomp-tiocsti")
        #expect(box["TIOCSTI"] == "EPERM" && box["TIOCLINUX"] == "EPERM", "\(box)")
        #expect(plain["TIOCSTI"] == "ok", "\(plain)")
    }

    @Test(.enabled(if: can, "\(skip)"))
    func aNestedUserNamespaceIsRefusedUnlessThePlanAllowsIt() throws {
        let source = """
            for label, flags in [("unshare user", 0x10000000), ("unshare user and mount", 0x10020000)]:
                child = os.fork()
                if child == 0:
                    result = libc.syscall(ctypes.c_long(numbers["unshare"]), ctypes.c_long(flags))
                    os._exit(0 if result == 0 else ctypes.get_errno())
                _, status = os.waitpid(child, 0)
                code = os.waitstatus_to_exitcode(status)
                print(label, "ok" if code == 0 else errno.errorcode.get(code, str(code)), flush=True)
            call("clone3", "clone3", 0, 0)
            call("mount", "mount", 0, 0, 0, 0, 0)
            call("umount2", "umount2", 0, 0)
            call("pivot_root", "pivot_root", 0, 0)
            call("setns", "setns", -1, 0)
            call("fd fsopen", "fsopen", 0, 0)
            call("fd open_tree", "open_tree", -1, 0, 0)
            call("mount_setattr", "mount_setattr", -1, 0, 0, 0, 0)
            """
        let (refused, _) = try Self.both(source, "seccomp-nesting")
        for name in ["unshare user", "unshare user and mount", "mount", "umount2", "pivot_root", "setns", "fd fsopen", "fd open_tree", "mount_setattr"] {
            #expect(refused[name] == "EPERM", "\(name): \(refused)")
        }
        #expect(refused["clone3"] == "ENOSYS", "\(refused)")
        let (allowed, _) = try Self.both(source, nesting: true, "seccomp-nested")
        #expect(allowed["unshare user"] == "ok" && allowed["unshare user and mount"] == "ok", "\(allowed)")
        // Let through to the kernel, which answers its own way to these arguments (the mount calls it refuses itself:
        // the program holds no capability over the box's mounts).
        #expect(allowed["clone3"] == "EINVAL" && allowed["setns"] == "EBADF", "\(allowed)")
    }

    @Test(.enabled(if: can, "\(skip)"))
    func aThreadedProgramAndAShellPipelineStillRun() throws {
        let (root, box) = try ShimBox.scratch("seccomp-runs")
        defer { try? FileManager.default.removeItem(at: root) }
        let threads = """
            import threading, subprocess
            done = []
            workers = [threading.Thread(target=lambda: done.append(1)) for _ in range(8)]
            [worker.start() for worker in workers]; [worker.join() for worker in workers]
            print("threads", len(done))
            print(subprocess.run(["/bin/sh", "-c", "printf 'b\\\\na\\\\n' | sort | tr a-z A-Z | head -1"], capture_output=True, text=True).stdout.strip())
            """
        let (ended, errors) = try ShimBox.python(threads, ShimBox.plan(box.path), in: box)
        #expect(ended.exit == 0, "\(errors)")
        #expect(ShimBox.lines(ended.output) == ["threads 8", "A"], "\(ended.output)")
    }

    @Test(.enabled(if: can, "\(skip)"))
    func tracingAProcessOfTheBoxIsAllowed() throws {
        let source = """
            import time
            child = os.fork()
            if child == 0:
                time.sleep(10); os._exit(0)
            result = libc.ptrace(16, child, 0, 0)
            print("ptrace own child", "ok" if result == 0 else errno.errorcode[ctypes.get_errno()])
            os.kill(child, 9); os.waitpid(child, 0)
            """
        let (box, _) = try Self.both(source, "seccomp-ptrace")
        #expect(box["ptrace own child"] == "ok", "\(box)")
    }
}
#endif
