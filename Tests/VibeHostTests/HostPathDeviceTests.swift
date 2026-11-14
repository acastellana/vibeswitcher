import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The test binary binding the host's socket on a file system whose `stat` device isn't its own: started again, under
/// `unshare --user --map-root-user --mount`, inside an overlay whose lower and upper layers are two tmpfs mounts
/// (`OverlaySocketHelper.script`), with `OverlaySocketHelper.variable` set to a path in that overlay. There `stat`
/// gives a file the upper layer's device, while the kernel's unix_diag gives the overlay's own (its superblock's), as
/// on btrfs, where `stat` gives a subvolume's device. Before any test of its own it listens at the path as the host
/// does (`UnixSocket.listen`), checks the path as the host's watch does (`HostPathWatch.verifiedIdentity`), then
/// renames a second listener's file over the path and checks it again for both listeners, prints one line of
/// "name value" pairs on its stdout, and exits 0 (1: no listener).
enum OverlaySocketHelper {
    static let variable = "VIBE_OVERLAY_SOCKET_HELPER"
    static let unshare = "/usr/bin/unshare"
    static let mount = "/usr/bin/mount"

    /// Run by `/bin/sh` in a new user and mount namespace, with the folder to work in and then the command: two tmpfs
    /// mounts at `a` and `b`, an overlay of `a/l` (lower) and `b/u` (upper) at `o`, and the command run there.
    static let script = """
        set -e
        cd "$1"
        shift
        \(mount) -t tmpfs lower a
        \(mount) -t tmpfs upper b
        mkdir a/l b/u b/w
        \(mount) -t overlay over -o lowerdir=a/l,upperdir=b/u,workdir=b/w o
        exec "$@"
        """

    static func checkIfAsked() {
        guard let value = getenv(variable) else { return }
        let path = String(cString: value)
        func described(_ identity: HostPathWatch.FileIdentity?) -> String {
            identity.map { "\($0.device):\($0.inode)" } ?? "none"
        }
        guard let listener = try? UnixSocket.listen(path: path) else { _exit(1) }
        let kernel = Platform.Sockets.boundFile(of: listener)
        let named = HostPathWatch.identity(atPath: path)
        let verified = HostPathWatch.verifiedIdentity(of: path, listener: listener)
        let otherPath = path + ".o"
        guard let other = try? UnixSocket.listen(path: otherPath) else { _exit(1) }
        let renamed = rename(otherPath, path) == 0
        let otherNamed = HostPathWatch.identity(atPath: path)
        let renamedOver = HostPathWatch.verifiedIdentity(of: path, listener: listener)
        let otherVerified = HostPathWatch.verifiedIdentity(of: path, listener: other)
        let line = "kernel-device \(kernel.map { String($0.device) } ?? "none") stat \(described(named)) verified \(described(verified))"
            + " renamed \(renamed) other-stat \(described(otherNamed)) renamed-over \(described(renamedOver))"
            + " other-verified \(described(otherVerified))\n"
        _ = write(STDOUT_FILENO, line, line.utf8.count)
        _exit(0)
    }

    /// The command `arguments` run in the namespace and overlay `script` makes in `folder` (which holds `a`, `b` and
    /// `o`): its exit status and what it wrote on its stdout.
    static func run(in folder: String, _ arguments: [String], environment: [String] = []) throws -> (exit: Int32, output: String) {
        var output: [Int32] = [-1, -1]
        guard Sys.pipeClosedOnExec(&output) == 0 else { throw Failure(what: "no pipe: errno \(errno)") }
        var spawn = Platform.Spawn(executable: unshare, arguments: ["unshare", "--user", "--map-root-user", "--mount",
                                                                  "/bin/sh", "-c", script, "sh", folder] + arguments)
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + environment
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .descriptor(output[1])
        spawn.stderr = .path("/dev/null", flags: O_WRONLY)
        spawn.keep = []
        let started = spawn.start()
        Sys.close(output[1])
        defer { Sys.close(output[0]) }
        guard case .success(let pid) = started else { throw Failure(what: "\(unshare) didn't start: \(started)") }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            var waiting = pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)
            var ready: Int32
            repeat { ready = poll(&waiting, 1, 60_000) } while ready < 0 && errno == EINTR
            guard ready > 0 else {
                if ready == 0 { kill(pid, SIGKILL) }
                break
            }
            let count = read(output[0], &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            bytes += chunk[0..<count]
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let exit: Int32 = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return (exit, String(decoding: bytes, as: UTF8.self))
    }

    /// A new folder holding `a`, `b` and `o`, under the run's short scratch root.
    static func folder() throws -> String {
        let dir = "\(shortScratchRoot)/vsov-\(UUID().uuidString.prefix(8))"
        for name in ["a", "b", "o"] {
            try FileManager.default.createDirectory(atPath: "\(dir)/\(name)", withIntermediateDirectories: true)
        }
        return dir
    }

    /// Why this machine can't make such an overlay without privileges (no unprivileged user namespaces, a kernel
    /// before 5.11, which mounts no overlay in one); nil when it can.
    static let noOverlay: String? = {
        guard FileManager.default.isExecutableFile(atPath: unshare) else { return "no \(unshare)" }
        guard FileManager.default.isExecutableFile(atPath: mount) else { return "no \(mount)" }
        guard let dir = try? folder() else { return "no scratch folder" }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        guard let ran = try? run(in: dir, ["/bin/true"]) else { return "\(unshare) didn't start" }
        return ran.exit == 0 ? nil : "no overlay in an unprivileged user namespace here (exit \(ran.exit))"
    }()

    struct Failure: Error { var what: String }
}

@Suite struct HostPathDeviceTests {
    /// The host's socket on a file system whose `stat` device is not the one the kernel's unix_diag reports (an overlay
    /// over two file systems here; btrfs, whose `stat` gives a subvolume's device, likewise) is still the host's: the
    /// watch's check compares the kernel's answer with the device of the file system the path is on, as the kernel
    /// holds it, not with `st_dev`. Checked against `st_dev`, the host's fresh listener was never its own, the path was
    /// bound again and again, and no client reached the host by its path. Another socket renamed over the path is
    /// still not the host's, and is its own listener's.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable && geteuid() != 0 && OverlaySocketHelper.noOverlay == nil,
                   "needs an overlay in an unprivileged user namespace, on Linux: \(OverlaySocketHelper.noOverlay ?? "")"))
    func aSocketOnAFileSystemWhoseStatDeviceIsNotItsOwnIsTheHosts() throws {
        try #require(getenv(OverlaySocketHelper.variable) == nil)
        let dir = try OverlaySocketHelper.folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let binary = try #require(Bundle.main.executablePath)
        let ran = try OverlaySocketHelper.run(in: dir, [binary] + ProcessInfo.processInfo.arguments.dropFirst(),
                                             environment: ["\(OverlaySocketHelper.variable)=\(dir)/o/h.sock"])
        try #require(ran.exit == 0, "the helper: \(ran)")
        let words = ran.output.split(whereSeparator: \.isWhitespace).map(String.init)
        try #require(words.count % 2 == 0, "\(ran.output)")
        var report: [String: String] = [:]
        for index in stride(from: 0, to: words.count, by: 2) { report[words[index]] = words[index + 1] }
        let stat = try #require(report["stat"], "\(ran.output)")
        let statDevice = try #require(stat.split(separator: ":").first.map(String.init))
        try #require(report["kernel-device"] != "none", "this kernel has no unix_diag: \(ran.output)")
        try #require(report["kernel-device"] != statDevice, "stat gives the overlay's own device here: nothing to show. \(ran.output)")
        #expect(report["verified"] == stat, "\(ran.output)")
        #expect(report["renamed"] == "true", "\(ran.output)")
        #expect(report["renamed-over"] == "none", "\(ran.output)")
        #expect(report["other-verified"] == report["other-stat"] && report["other-stat"] != stat, "\(ran.output)")
    }
}

// Runs as the test bundle loads, as the home guard does (TestSupport.swift).
#if os(Linux)
@_used @_section(".init_array")
private let checkOnAnOverlay: @convention(c) () -> Void = { OverlaySocketHelper.checkIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let checkOnAnOverlay: @convention(c) () -> Void = { OverlaySocketHelper.checkIfAsked() }
#endif
