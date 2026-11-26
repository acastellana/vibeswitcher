import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The last changes before v2-mac-checked-start is offered (the re-check's round 2): the node's lock known by the
/// descriptor a host opened (note 1), every descriptor a checked node was given closed at its start (note 2), the
/// keeper's limit while it holds the state (N6 after the park), and the new image's wait for its keeper (the nit).
@Suite(.serialized, hostTestLimit)
struct MacCheckedLastTests {
    let scratch = Scratch()

    // MARK: Note 1: the node's lock by the descriptor opened

    /// A host that isn't a checked node, given a lock that opens the node's own `host.lock` before it exists, by another
    /// letter case (the Mac's volume ignores case) or through a dangling link to it: its start is refused once the lock
    /// is open, by the descriptor's device and inode, and it holds no lock. A scratch lock elsewhere starts. Red before:
    /// only the path was asked, before the open made the node's lock.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's node root"))
    func aHostOpeningTheNodesLockByAnotherNameIsRefused() throws {
        let home = scratch.url("vslt").path
        let data = Platform.Service.nodeRoot(accountHome: home)
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        let lock = data + "/host.lock"
        let links = scratch.url("vslt-links").path
        try FileManager.default.createDirectory(atPath: links, withIntermediateDirectories: true)
        #expect(symlink(lock, links + "/a.lock") == 0)
        func start(_ lockPath: String) -> Bool {
            var config = HostServer.Config(socketPath: scratchSocketPath(), lockPath: lockPath, shell: "/bin/sh", launcher: hostLauncher,
                                           baseEnvironment: ["PATH": "/usr/bin:/bin"], hostBuild: 1)
            config.idleExit = nil
            config.heldLockIsAllowed = { HostImages.heldLockAllowed($0, accountHome: home) }
            let server = HostServer(config: config)
            do {
                try server.start()
                server.stop(terminateSessions: true)
                return true
            } catch {
                return false
            }
        }
        for (name, path) in [("another case", data + "/HOST.LOCK"), ("a dangling link", links + "/a.lock")] {
            unlink(lock)
            let started = start(path)
            var opened = stat(), node = stat()
            // Only where the path opened the node's own lock (a volume that tells case apart makes another file).
            guard stat(path, &opened) == 0, stat(lock, &node) == 0, opened.st_ino == node.st_ino else { continue }
            #expect(!started, "a host that isn't a checked node started on the node's lock by \(name)")
            let fresh = open(lock, O_RDONLY | O_CLOEXEC)
            #expect(fresh >= 0 && flock(fresh, LOCK_EX | LOCK_NB) == 0, "the refused host still holds the node's lock (\(name))")
            Sys.close(fresh)
        }
        #expect(start(scratch.url("vslt-scratch.lock").path), "a scratch lock refused")
    }

    // MARK: Note 2: every descriptor given closed

    /// A checked node's reset at its start (`Platform.NodeReset.processState`) run in a child of this test binary (its
    /// helper mode, `NodeResetHelper`), started by `sh` with its soft descriptor limit lowered to 200 and descriptor 300
    /// open above it: 300 is closed, the umask is 077, the working folder `/`, the core limit 0 soft and hard. Red before: the
    /// loop stopped at the lowered limit and 300 stayed open.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's checked node reset"))
    func theResetClosesWhatItWasGivenAboveALoweredLimit() throws {
        let results = scratch.url("vsnr").path
        let null = open("/dev/null", O_RDONLY)
        #expect(null >= 0 && dup2(null, 300) == 300)
        Sys.close(null)
        defer { Sys.close(300) }
        let binary = try #require(Bundle.main.executablePath)
        // `sh` is the system's, so the loader drops `DYLD_*` from its environment: the test bundle's own (its framework
        // paths) are given back to the helper inside the command.
        let loader = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("DYLD_") && !$0.value.contains("'") }
            .map { "export \($0.key)='\($0.value)'; " }.joined()
        var spawn = Platform.Spawn(executable: "/bin/sh", arguments: ["sh", "-c", loader + "ulimit -Sn 200; exec \"$0\" \"$@\"", binary]
                                   + Array(ProcessInfo.processInfo.arguments.dropFirst()))
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + ["\(NodeResetHelper.variable)=\(results)"]
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.keep = [300]
        guard case .success(let pid) = spawn.start() else { Issue.record("the helper didn't start"); return }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        let said = (try? String(contentsOfFile: results, encoding: .utf8)) ?? "(nothing)"
        #expect(said.contains("why=nil") && said.contains("limit=200"), "\(said)")
        #expect(said.contains("open300=false"), "descriptor 300 survived the reset: \(said)")
        #expect(said.contains("umask=77 ") && said.contains("cwd=/ ") && said.contains("core=0,0"), "\(said)")
    }

    // MARK: N6 after the park

    /// The review's PROBE5: the target swapped just before the exec for a script that holds the keeper's channel and
    /// never asks. The keeper, holding the parked state, exits at its limit (a scratch host's short one,
    /// `--handover-test-keeper-limit 3`) with everything it held closed, and the session ends with its terminal. Red
    /// before: the limit couldn't be shortened, and the keeper held the state its full 180 s.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's switch through a keeper: code identity"))
    func aKeeperHoldingTheStateWithNoNewImageExitsByItsLimit() async throws {
        let images = MacKeeperHandoverTests.Images()
        var extra: [String] = []
        var dir = ""
        let host = try await ScratchHostProcess(prepare: { folder in
            dir = folder
            _ = try MacKeeperHandoverTests.sign(folder + "/old/vibeswitcher-host", "dev.vibeswitcher.test.last.old")
            images.new = try MacKeeperHandoverTests.sign(folder + "/new/vibeswitcher-host", "dev.vibeswitcher.test.last.new")
            try installScript("#!/bin/sh\necho ran >> \"\(folder)/holder.ran\"\nexec /bin/sleep 400\n", atPath: folder + "/holder")
            extra = ["--handover-test-keeper", NodePins.hex(images.new), "--handover-test-swap-before-exec", folder + "/holder",
                     "--handover-test-keeper-limit", "3"]
        }, late: { extra })
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let counter = try await client.spawn(HostHandoverTests.counter)
        await client.attach(counter.id)
        #expect(await eventually { counted(client.text(counter.id)).last ?? 0 >= 3 })
        _ = client.send(.handover(executable: host.newBinary))
        #expect(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: dir + "/holder.ran") }, "\(host.log)")
        #expect(await eventually(timeout: 60) { host.log.contains("handover keeper: no new image came within its limit: everything held closed") },
                "\(host.log)")
        // The session's program, its terminal's last holder gone: ended (a zombie of the holder, which reaps nothing).
        func state() -> String {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-o", "stat=", "-p", String(counter.childPID)]
            let out = Pipe()
            ps.standardOutput = out
            try? ps.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ps.waitUntilExit()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(await eventually(timeout: 30) { state().isEmpty || state().hasPrefix("Z") }, "the session runs on: \(state())")
    }

    // MARK: The nit: the new image's wait for its keeper

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        var value: Bool { lock.withLock { set } }
        func raise() { lock.withLock { set = true } }
    }

    /// The new image reaps its keeper within the keeper's limit: a keeper that never exits (here `/bin/sleep`) is ended
    /// and reaped then, rather than waited on for ever. Red before: the wait had no limit.
    @Test func aKeeperIsReapedWithinALimit() async throws {
        var spawn = Platform.Spawn(executable: "/bin/sleep", arguments: ["sleep", "100000"])
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        guard case .success(let pid) = spawn.start() else { Issue.record("sleep didn't start"); return }
        let done = Flag()
        Thread { MacHandoverKeeper.reap(pid, within: 2); done.raise() }.start()
        let reaped = await eventually(timeout: 60) { done.value }
        if !reaped {
            kill(pid, SIGKILL)
            _ = await eventually { done.value }
        }
        #expect(reaped, "the keeper was waited on past its limit")
        #expect(kill(pid, 0) != 0, "the keeper runs on")
    }
}

/// The test binary as a checked node's reset (`MacCheckedLastTests.theResetClosesWhatItWasGivenAboveALoweredLimit`):
/// with `VIBE_NODE_RESET_TEST_HELPER=FILE` it runs `Platform.NodeReset.processState`, writes what it then sees to FILE
/// (whether descriptor 300 is open, its umask, folder and core limit, as `sh` reads them, and its descriptor limit), and
/// exits before any test.
enum NodeResetHelper {
    static let variable = "VIBE_NODE_RESET_TEST_HELPER"

    static func runIfAsked() {
        guard let value = getenv(variable) else { return }
        let results = String(cString: value)
        let limit = getdtablesize()
        let why = Platform.NodeReset.processState(keeping: [])
        let open300 = fcntl(300, F_GETFD) != -1
        let mask = umask(0)
        umask(mask)
        var folder = [CChar](repeating: 0, count: 1024)
        let cwd = getcwd(&folder, folder.count) != nil ? String(cString: folder) : "?"
        // The core limit as a child reads it (`ulimit -c`, `-Hc`): what this process's children inherit.
        let out = results + ".core"
        var shell = Platform.Spawn(executable: "/bin/sh", arguments: ["sh", "-c", "echo \"$(ulimit -c),$(ulimit -Hc)\""])
        shell.stdin = .path("/dev/null", flags: O_RDONLY)
        shell.stdout = .path(out, flags: O_WRONLY | O_CREAT | O_TRUNC, mode: 0o600)
        var core = "?"
        if case .success(let pid) = shell.start() {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            core = ((try? String(contentsOfFile: out, encoding: .utf8)) ?? "?").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        unlink(out)
        let text = "why=\(why ?? "nil") limit=\(limit) open300=\(open300) umask=\(String(mask, radix: 8)) cwd=\(cwd) core=\(core)\n"
        FileManager.default.createFile(atPath: results, contents: Data(text.utf8))
        _exit(0)
    }
}

// Runs as the test bundle loads, as the other helpers do (AppConnectorHelper.swift).
#if os(Linux)
@_used @_section(".init_array")
private let runTheNodeResetHelper: @convention(c) () -> Void = { NodeResetHelper.runIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let runTheNodeResetHelper: @convention(c) () -> Void = { NodeResetHelper.runIfAsked() }
#endif
