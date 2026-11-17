import Foundation
import Testing
@testable import VibePlatform

#if os(Linux)
// Linux only: these are Linux's kernel facts.

/// The kernel's facts the session sandbox plan rests on (its "Measured on this machine" and the inventory's "The
/// session sandbox, measured"), kept true here: each says what changed when the kernel changes. Plain children of the
/// test, `python3 -I` for the calls a shell can't make; nothing here confines the test process.
@Suite(.serialized) struct SandboxFactsTests {
    static let linux = !Platform.CodeIdentity.isAvailable
    static let python = ShimBox.python

    /// `source` in a plain child: its exit and output.
    static func plain(_ source: String, in folder: URL) throws -> SpawnTests.Ended {
        var child = Platform.Spawn(executable: "/usr/bin/python3", arguments: ["python3", "-I", "-c", source])
        child.directory = folder.path
        return try SpawnTests.output(of: child)
    }

    @Test(.enabled(if: linux, "Linux's"))
    func landlocksAbiIsReadFromTheKernel() {
        let abi = Platform.Sandbox.probe().landlockABI
        #expect(abi == Int(vibe_sandbox_landlock_abi()))
        #expect(abi >= 0)
        // SB-D1: on ABI 1 Landlock isn't the file lock. Where it says more, a later task adds it as a second one.
        print("SB1: Landlock's ABI here: \(abi)")
    }

    @Test(.enabled(if: linux && python && vibe_sandbox_landlock_abi() >= 1, "needs Landlock and python3"))
    func aLandlockedProcessCantRenameAcrossFoldersBeforeAbi2() throws {
        let folder = try ProcessesTests.scratch("landlock")
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a", "b"] { try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("a/file"))
        // Every ABI-1 right handled, all of them allowed beneath the folder; then a rename within a folder and one
        // across two.
        let source = """
            import ctypes, errno, os
            libc = ctypes.CDLL(None, use_errno=True)
            libc.syscall.restype = ctypes.c_long
            rights = (1 << 13) - 1
            class Attr(ctypes.Structure): _fields_ = [("handled", ctypes.c_uint64)]
            class Beneath(ctypes.Structure):
                _pack_ = 1
                _fields_ = [("allowed", ctypes.c_uint64), ("parent", ctypes.c_int32)]
            attr = Attr(rights)
            ruleset = libc.syscall(444, ctypes.byref(attr), ctypes.c_size_t(8), 0)
            parent = os.open(".", os.O_PATH)
            beneath = Beneath(rights, parent)
            assert libc.syscall(445, ruleset, 1, ctypes.byref(beneath), 0) == 0
            assert libc.prctl(38, 1, 0, 0, 0) == 0
            assert libc.syscall(446, ruleset, 0) == 0
            os.rename("a/file", "a/renamed"); print("within ok")
            try:
                os.rename("a/renamed", "b/renamed"); print("across ok")
            except OSError as error:
                print("across", errno.errorcode[error.errno])
            """
        let ended = try Self.plain(source, in: folder)
        #expect(ended.exit == 0)
        let lines = ShimBox.lines(ended.output)
        #expect(lines.first == "within ok", "\(ended.output)")
        if vibe_sandbox_landlock_abi() < 2 {
            #expect(lines.last == "across EXDEV", "\(ended.output)")
        } else {
            print("SB1: Landlock ABI \(vibe_sandbox_landlock_abi()) here: a rename across folders is \(lines.last ?? "")")
        }
    }

    @Test(.enabled(if: linux && python && ShimBox.unavailable == nil && Platform.Sandbox.probe().vsock,
                   "needs Hyper-V sockets, a box and python3"))
    func hyperVSocketsIgnoreTheNetworkNamespace() throws {
        // A Hyper-V socket opens in this network namespace, and in a new one of a box's (the filter off: no box, just
        // unshare(1)'s namespaces), so only the filter keeps a box from one.
        let source = "import socket\nsocket.socket(40, socket.SOCK_STREAM).close()\nprint('vsock ok')"
        let folder = try ProcessesTests.scratch("vsock")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try Self.plain(source, in: folder).output == "vsock ok\n")
        let unshared = Platform.Spawn(executable: "/usr/bin/unshare",
                                      arguments: ["unshare", "--user", "--map-current-user", "--net", "/usr/bin/python3", "-I", "-c",
                                                  source + "\nprint(open('/proc/net/dev').read().count(':'))"])
        let inside = try SpawnTests.output(of: unshared)
        #expect(inside.output == "vsock ok\n1\n", "\(inside)")
    }

    @Test(.enabled(if: linux && python && ShimBox.unavailable == nil, "needs a user namespace and python3"))
    func aNonDumpableProcessCantWriteItsOwnUidMap() throws {
        let folder = try ProcessesTests.scratch("uid-map")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = """
            import ctypes, errno, os
            libc = ctypes.CDLL(None, use_errno=True)
            uid = os.getuid()
            for dumpable in [0, 1]:
                child = os.fork()
                if child == 0:
                    libc.prctl(4, dumpable, 0, 0, 0)
                    os.unshare(os.CLONE_NEWUSER)
                    try:
                        with open("/proc/self/uid_map", "w") as map:
                            map.write(f"{uid} {uid} 1\\n")
                        os._exit(0)
                    except OSError as error:
                        os._exit(error.errno)
                _, status = os.waitpid(child, 0)
                code = os.waitstatus_to_exitcode(status)
                print("dumpable" if dumpable else "non-dumpable", "written" if code == 0 else errno.errorcode[code])
            """
        let ended = try Self.plain(source, in: folder)
        #expect(ShimBox.lines(ended.output) == ["non-dumpable EACCES", "dumpable written"], "\(ended)")
    }

    @Test(.enabled(if: linux && python && ShimBox.unavailable == nil, "needs a box and python3"))
    func aTerminalMadeOutsideHasNoNameInsideButStaysATerminal() throws {
        let (root, box) = try ShimBox.scratch("facts-terminal")
        defer { try? FileManager.default.removeItem(at: root) }
        let master = vibe_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)
        try #require(master >= 0)
        defer { close(master) }
        var name = [CChar](repeating: 0, count: 128)
        try #require(vibe_ptsname_r(master, &name, name.count) == 0)
        let slave = String(cString: name)
        var info = stat()
        try #require(stat(slave, &info) == 0)
        let probe = """
            import os
            fields = open("/proc/self/stat").read().rsplit(")", 1)[1].split()
            try:
                name = os.ttyname(0)
            except OSError as error:
                name = "error %d" % error.errno
            print("isatty", os.isatty(0), "ttyname", name, "tty_nr", fields[4], "own pts", os.listdir("/dev/pts"), flush=True)
            """
        let launched = try ShimBox.launch(ShimBox.plan(box.path, terminal: .foreground), ["/usr/bin/python3", "-I", "-c", probe],
                                          in: box, terminal: slave)
        var drawn = Data()
        _ = ShimBox.eventually {
            var chunk = [UInt8](repeating: 0, count: 4096)
            var watched = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&watched, 1, 10) > 0 {
                let count = read(master, &chunk, chunk.count)
                if count > 0 { drawn.append(contentsOf: chunk[0..<count]) }
            }
            return String(decoding: drawn, as: UTF8.self).contains("own pts")
        }
        let ended = launched.ended()
        let text = String(decoding: drawn, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        #expect(ended.exit == 0, "\(text)")
        // The terminal's number outside (the kernel's encoding: major 136 and up, then the minor) stays the session's.
        let number = Int(info.st_rdev)
        let major = (number >> 8) & 0xfff, minor = (number & 0xff) | ((number >> 12) & 0xfff00)
        let ttyNumber = (minor & 0xff) | (major << 8) | ((minor & ~0xff) << 12)
        #expect(text.contains("isatty True ttyname error \(ENODEV) tty_nr \(ttyNumber) own pts ['ptmx']"), "\(text)")
    }

    @Test(.enabled(if: linux && ShimBox.unavailable == nil && FileManager.default.fileExists(atPath: "/proc/sys/fs/binfmt_misc/WSLInterop"),
                   "WSL's interop"))
    func aWindowsStubDoesntStartWithoutInit() throws {
        let (root, box) = try ShimBox.scratch("facts-interop")
        defer { try? FileManager.default.removeItem(at: root) }
        // A two-byte "MZ" file, the magic interop's entries match: no real Windows program, and only ever run inside a
        // box, where neither /init nor /run/WSL is.
        let stub = box.appendingPathComponent("stub.exe")
        try Data("MZ".utf8).write(to: stub)
        chmod(stub.path, 0o755)
        let script = """
            for path in /init /run/WSL /mnt/c; do [ -e "$path" ] && echo "present $path" || echo "absent $path"; done
            ./stub.exe; echo "stub status $?"
            """
        let (ended, errors) = try ShimBox.shell(script, ShimBox.plan(box.path), in: box)
        #expect(ended.exit == 0, "\(errors)")
        let lines = ShimBox.lines(ended.output)
        #expect(lines.prefix(3) == ["absent /init", "absent /run/WSL", "absent /mnt/c"], "\(ended.output)")
        // The shell couldn't run it: 126 (not executable as it is) or 127 (its interpreter, /init, isn't there).
        #expect(lines.last == "stub status 127" || lines.last == "stub status 126", "\(ended.output) \(errors)")
    }
}
#endif
