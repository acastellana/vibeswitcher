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

    /// The binfmt probe says `.none` only when the kernel answered no (mount(8)'s exit 32, its mount refused); a probe
    /// that failed before the kernel answered is `.unknown`, never `.none`, since a box plans no binfmt_misc of its own
    /// only for `.none` and then tries the machine's entries (the-node-s-gate:F2: every failure read as "no need to
    /// hide"). Commands stand in for unshare(1) and mount(8), each ending one way.
    @Test(.enabled(if: linux)) func aBinfmtProbeThatFailsIsUnknownNotNone() throws {
        let scratch = try ProcessesTests.scratch("facts-binfmt-probe")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let missing = scratch.appendingPathComponent("not-here").path
        typealias System = Platform.Sandbox.System
        #expect(System.binfmt(["/bin/sh", "-c", "exit 0"]) == .own)
        // mount(8)'s exit 32: the kernel refused the mount.
        #expect(System.binfmt(["/bin/sh", "-c", "exit 32"]) == .none)
        // unshare(1) failing to make the namespaces (1), unable to run mount(8) (126, 127), mount(8) itself refusing its
        // arguments (1): no answer from the kernel.
        for code in [1, 2, 126, 127] { #expect(System.binfmt(["/bin/sh", "-c", "exit \(code)"]) == .unknown, "exit \(code)") }
        #expect(System.binfmt(["/bin/sh", "-c", "kill -KILL $$"]) == .unknown, "killed")
        #expect(System.binfmt([missing]) == .unknown, "no unshare(1)")
        #expect(System.binfmt(["/bin/sh", "-c", "exit 0"], mount: missing) == .unknown, "no mount(8)")
        // A child that never ends: killed at its bound (here 50 ms; 10 s in the probe), and no answer.
        #expect(System.binfmt(["/bin/sleep", "600"], bound: 50_000) == .unknown, "hung")
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
            echo "binfmt_misc:" $(ls /proc/sys/fs/binfmt_misc)
            ./stub.exe; echo "stub status $?"
            """
        let (ended, errors) = try ShimBox.shell(script, ShimBox.plan(box.path), in: box)
        #expect(ended.exit == 0, "\(errors)")
        let lines = ShimBox.lines(ended.output)
        #expect(lines.prefix(3) == ["absent /init", "absent /run/WSL", "absent /mnt/c"], "\(ended.output)")
        // The kernel's interop entries, and whether one carries F (its interpreter, /init, opened when it was
        // registered, so a box's missing /init doesn't stop it).
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/sys/fs/binfmt_misc"))?.filter { $0.hasPrefix("WSLInterop") } ?? []
        let held = entries.filter { entry in
            ShimBox.procText("/proc/sys/fs/binfmt_misc/" + entry).split(separator: "\n").contains { $0.hasPrefix("flags:") && $0.contains("F") }
        }
        let kept = Platform.Sandbox.probe().binfmt != .none ? "" : " (this kernel gives a box no binfmt_misc of its own, so the machine's entries are tried; with F: \(held))"
        // The promise, on every kernel: /init never runs in a box on an MZ file, so nothing reaches the Windows side.
        // The shell couldn't run it: 126 (not executable as it is) or 127 (no interpreter, or "MZ" run as a script, a
        // command not found). /init, where it ran, would say so ("WSL (…) ERROR: UtilGetPpid … /proc/1/stat") and end 1.
        #expect(lines.last == "stub status 127" || lines.last == "stub status 126", "\(ended.output) \(errors)\(kept)")
        #expect(!(ended.output + errors).contains("WSL ("), "\(ended.output) \(errors)\(kept)")
        if Platform.Sandbox.probe().binfmt != .none {
            // The box's own binfmt_misc, with no entry: the machine's go untried.
            #expect(lines.contains("binfmt_misc: register status"), "\(ended.output)")
        } else {
            // The kernel gives a box no binfmt_misc of its own, so the box tries the machine's entries: the facts say
            // so, and only the order of the entries (5.15's first has no F, and names /init by path), the missing
            // /run/WSL and the filter's refusal of AF_VSOCK keep the promise above.
            #expect(lines.contains("binfmt_misc:"), "\(ended.output)")
            print("SB: this kernel gives a box no binfmt_misc of its own: the machine's interop entries are tried in a box"
                  + (held.isEmpty ? "" : "; \(held.joined(separator: ", ")) carries F, so /init would start there were it tried first"))
        }
        print("SB: interop entries \(entries) (with F: \(held)); a box's own binfmt_misc: \(Platform.Sandbox.probe().binfmt)")
    }

    /// The promise `aWindowsStubDoesntStartWithoutInit` checks against WSL's own entry, kept where that entry can't be
    /// seen: in a branch run's box (the merge gate, an audit's run, a done check) the box's own empty binfmt_misc hides
    /// WSLInterop, so that test is skipped there (the-node-s-gate:F6). Here the launcher starts in a user namespace of
    /// its own (unshare(1), as root of it) whose own binfmt_misc, mounted over a scratch folder, holds a made-up entry
    /// for the `MZ` magic with F, its interpreter a copy of echo(1) outside the box, as WSL's `/init` is. The kernel
    /// tries a program's entries in the nearest user namespace with an instance: a box that plans one of its own
    /// (`ShimBox.plan`'s default, as `SandboxPlanner` plans it) never tries the made-up entry, and a two-byte `MZ` file
    /// doesn't start there (126/127); a box without one (the control) runs the interpreter the kernel holds open,
    /// though its path isn't in the box. Only where a user namespace gets a binfmt_misc of its own (6.18 here); the
    /// machine's binfmt_misc is never written.
    @Test(.enabled(if: linux && ShimBox.unavailable == nil && Platform.Sandbox.probe().binfmt == .own,
                   "a user namespace's own binfmt_misc"))
    func aBoxDoesntTryAnEntryWithFOfTheNamespaceItStartsIn() throws {
        let (root, box) = try ShimBox.scratch("facts-nested-binfmt")
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = root.appendingPathComponent("binfmt")
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: false)
        // The interpreter: a copy of echo(1) outside the box, so only the kernel's open file can run it inside.
        let interpreter = root.appendingPathComponent("interpreter")
        try FileManager.default.copyItem(atPath: "/usr/bin/echo", toPath: interpreter.path)
        let stub = box.appendingPathComponent("stub.exe")
        try Data("MZ".utf8).write(to: stub)
        chmod(stub.path, 0o755)
        // In the outer namespace: its own binfmt_misc, the entry, the stub run there (echo prints its path), then the
        // launcher as a child, never exec'd, so the namespace and its instance stay while the box runs.
        let outer = """
            set -e
            \(Platform.Sandbox.System.mount) -t binfmt_misc binfmt_misc "$1"
            printf ':vibe-test:M::MZ::%s:F' "$2" > "$1/register"
            echo "outer flags: $(grep '^flags:' "$1/vibe-test")"
            echo "outer stub: $("$3")"
            shift 3
            set +e
            "$@"
            status=$?
            exit $status
            """
        let prefix = [Platform.Sandbox.System.unshare, "--user", "--map-root-user", "--mount", "/bin/sh", "-c", outer, "sh",
                      instance.path, interpreter.path, stub.path]
        let script = """
            [ -e '\(interpreter.path)' ] && echo "interpreter present" || echo "interpreter absent"
            ./stub.exe; echo "stub status $?"
            """
        // The control: a box with no binfmt_misc of its own tries the outer namespace's entry, and the interpreter runs.
        let control = try ShimBox.shell(script, ShimBox.plan(box.path, binfmt: false), in: box, prefix: prefix)
        let seen = ShimBox.lines(control.ended.output)
        try #require(seen.prefix(2) == ["outer flags: flags: F", "outer stub: \(stub.path)"], "\(control.ended.output) \(control.errors)")
        try #require(seen.dropFirst(2) == ["interpreter absent", "./stub.exe", "stub status 0"], "\(control.ended.output) \(control.errors)")
        // The promise: a box with its own binfmt_misc doesn't try it, and the stub doesn't start.
        let (ended, errors) = try ShimBox.shell(script, ShimBox.plan(box.path), in: box, prefix: prefix)
        let lines = ShimBox.lines(ended.output)
        #expect(ended.exit == 0, "\(ended.output) \(errors)")
        #expect(lines.prefix(3) == ["outer flags: flags: F", "outer stub: \(stub.path)", "interpreter absent"], "\(ended.output) \(errors)")
        #expect(lines.last == "stub status 127" || lines.last == "stub status 126", "\(ended.output) \(errors)")
        #expect(!lines.contains("./stub.exe"), "\(ended.output) \(errors)")
        print("SB: a made-up F entry of the namespace a box starts in: the control box ran it, a box with its own binfmt_misc said \(lines.last ?? "nothing")")
    }

    /// Where the gate runs `aBoxDoesntTryAnEntryWithFOfTheNamespaceItStartsIn`: a branch run's box nests (the project's
    /// `sandbox_nesting`), and there the probe's own command (`System.binfmtProbe`) still gets a binfmt_misc of a user
    /// namespace's own, so the probe answers `.own` and that test runs there, where `aWindowsStubDoesntStartWithoutInit`
    /// is skipped (the-node-s-gate:F6). A box without nesting can make no user namespace (the filter refuses it): its
    /// probe fails, which is `.unknown` (a box plans its own binfmt_misc for it), never `.own` or `.none`.
    @Test(.enabled(if: linux && ShimBox.unavailable == nil && Platform.Sandbox.probe().binfmt == .own,
                   "a user namespace's own binfmt_misc"))
    func theBinfmtProbeAnswersOwnInANestingBox() throws {
        let (root, box) = try ShimBox.scratch("facts-binfmt-in-box")
        defer { try? FileManager.default.removeItem(at: root) }
        let command = Platform.Sandbox.System.binfmtProbe.map { "'\($0)'" }.joined(separator: " ")
        let script = "\(command); echo \"probe status $?\""
        let (nested, nestedErrors) = try ShimBox.shell(script, ShimBox.plan(box.path, nesting: true), in: box)
        #expect(ShimBox.lines(nested.output).last == "probe status 0", "\(nested.output) \(nestedErrors)")
        let (plain, plainErrors) = try ShimBox.shell(script, ShimBox.plan(box.path), in: box)
        let last = ShimBox.lines(plain.output).last
        #expect(last != nil && last != "probe status 0" && last != "probe status 32", "\(plain.output) \(plainErrors)")
    }
}
#endif
