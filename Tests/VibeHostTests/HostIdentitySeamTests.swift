import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Who the host takes a peer for, now that its reads go through the platform (the stage 2 plan's Task 4b1): on the
/// Mac the app is still the app's code (`Platform.CodeIdentity`'s cdhash check, moved) that proves its key; on Linux,
/// where an orphan is given to the subreaper above the host and not to pid 1, the orphan sweep looks at that parent's
/// children too (`HostProcesses.orphanParents`), and never at a tool server whose agent still runs.
@Suite(hostTestLimit) struct HostIdentitySeamTests {
    /// A stand-in for the tool server in `folder`: `sleep`'s program under the tool server's name, so it waits as a
    /// tool server does and ends on SIGTERM.
    static func toolServerStandIn(in folder: String) throws -> String {
        let path = folder + "/vibeswitcher-mcp"
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: path)
        return path
    }

    /// Starts `executable 600` with its starter (a shell) ended at once, as a tool server is once its agent ends: its
    /// pid. Its parent is then whatever the kernel gives an orphan of this process.
    static func orphan(_ executable: String) async throws -> pid_t {
        let starter = Process()
        starter.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Its output elsewhere: the pipe ends with the shell.
        starter.arguments = ["-c", "\"$0\" 600 < /dev/null > /dev/null 2>&1 & echo $!", executable]
        let pipe = Pipe()
        starter.standardOutput = pipe
        try starter.run()
        let output = await offPool { pipe.fileHandleForReading.readDataToEndOfFile() }
        _ = await offPool { waitForEnd(starter) }
        return try #require(pid_t(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    static func parent(of pid: pid_t) -> pid_t? {
        guard case .brief(let brief) = Platform.Processes.brief(pid) else { return nil }
        return brief.ppid
    }

    /// A folder of its own, short (a scratch host's socket is under it).
    static func folder() throws -> String {
        let dir = "\(shortScratchRoot)/vsid-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A `Config` with only `appExecutable` set, as before the platform: the app's code answering the challenge with
    /// the key is the app; another process answering it with the same key is refused.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's cdhash check; Linux has no code identity"))
    func theMacsAppIsStillTheCdhashCheck() async throws {
        let calls = LeadVaultHostTests()
        // nc's code is the app's here; this test's runner is another program.
        let host = try TestHost(appExecutable: "/usr/bin/nc")
        let proven = try await calls.viaNC(host.socket, proof: host.appKey, [.screen(id: UUID())])
        #expect(proven[0] == .ok, "\(proven)")

        let other = try TestClient(socket: host.socket)
        var challenge: Data?
        #expect(await eventually {
            other.with { client in
                for case .challenge(let sent, _) in client.allEvents { challenge = sent }
            }
            return challenge != nil
        })
        let seq = other.send(.proveApp(answer: AppProof.answer(try #require(challenge), key: host.appKey)))
        #expect(await eventually { other.reply(to: seq) != nil })
        guard case .error(let reason)? = other.reply(to: seq) else {
            Issue.record("another program proved it's the app: \(String(describing: other.reply(to: seq)))")
            return
        }
        #expect(reason.contains("isn't VibeSwitcher's"), "\(reason)")
    }

    /// A tool server whose agent ended is the child of the parent an orphan of this process gets (the user's
    /// systemd here, pid 1 elsewhere): the sweep lists it, and that parent is among `orphanParents`. Asserted so, not
    /// by naming the parent: the subreaper depends on where the tests run.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's subreaper; the Mac's orphans are launchd's"))
    func anOrphanedToolServerIsFoundOnLinux() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let toolServer = try Self.toolServerStandIn(in: dir)
        let orphaned = try await Self.orphan(toolServer)
        defer { kill(orphaned, SIGKILL) }

        #expect(await eventually { HostProcesses.orphans(running: toolServer).contains(orphaned) },
                "parent \(String(describing: Self.parent(of: orphaned))), orphans' parents \(HostProcesses.orphanParents)")
        let parent = try #require(Self.parent(of: orphaned))
        #expect(HostProcesses.orphanParents.contains(parent), "parent \(parent), orphans' parents \(HostProcesses.orphanParents)")
        #expect(HostProcesses.orphans(running: toolServer) == [orphaned])
    }

    /// A tool server whose agent (this test) runs is its agent's child, and this test is among the scratch host's
    /// ancestors: a host that ends orphaned tool servers leaves it, while it ends one beside it whose agent ended.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's subreaper; the Mac's orphans are launchd's"))
    func aLiveToolServerWhoseParentIsTheTestIsNotAnOrphan() async throws {
        let host = try await ScratchHostProcess(arguments: ["--housekeeping", "0.5", "--end-orphaned-tool-servers"])
        defer { host.stop() }
        #expect(ProcessTable.ancestry(of: host.pid)?.contains { $0.pid == getpid() } == true)
        // The tool server beside the scratch host's binary is the one it sweeps for.
        let toolServer = try Self.toolServerStandIn(in: host.dir + "/old")
        let served = Process()
        served.executableURL = URL(fileURLWithPath: toolServer)
        served.arguments = ["600"]
        served.standardInput = FileHandle.nullDevice
        served.standardOutput = FileHandle.nullDevice
        served.standardError = FileHandle.nullDevice
        try served.run()
        defer { if served.isRunning { kill(served.processIdentifier, SIGKILL) } }
        // One whose agent ended: once the host has ended it, it has swept with the test's child there.
        let orphaned = try await Self.orphan(toolServer)
        defer { kill(orphaned, SIGKILL) }

        let notes = { (try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? "" }
        #expect(await eventually(timeout: 60) { notes().contains("ended tool server pid \(orphaned), whose agent ended") }, "\(notes())")
        #expect(served.isRunning && Self.parent(of: served.processIdentifier) == getpid())
        #expect(!notes().contains("pid \(served.processIdentifier)"), "\(notes())")
        #expect(!HostProcesses.orphans(running: toolServer).contains(served.processIdentifier))
    }
}
