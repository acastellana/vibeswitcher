import Foundation
import Testing
import VibeCore
import VibeNode

/// The scratch node's own clean-up (the engine sweep's test findings): what it leaves running, and where its short
/// folders go.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct ScratchNodeTests {
    private let scratch = Scratch()

    /// A runner killed outright (or crashed) leaves no node running: its host ends with its owner (`--exit-with`), its
    /// session's program too, though the session is live and the host's idle exit never comes.
    @Test func theHostEndsWithItsOwner() async throws {
        var stand = Platform.Spawn(executable: "/bin/sleep", arguments: ["/bin/sleep", "600"])
        stand.stdin = .path("/dev/null", flags: O_RDONLY)
        let owner = SpawnedHost(pid: try await startRetrying(stand))
        defer { if owner.isRunning { kill(owner.processIdentifier, SIGKILL); _ = owner.isRunning } }
        let node = try await ScratchNode(scratch, owner: owner.processIdentifier)
        let session = try await node.spawn("exec sleep 600")
        try #require(session.isLive && session.childPID > 0, "\(session)")
        let program = try #require(Platform.Processes.link(session.childPID))

        kill(owner.processIdentifier, SIGKILL)
        #expect(await exited(owner, within: 30))
        #expect(await exited(node.process, within: 60), "the host outlived its owner: \(node.said)")
        #expect(await eventually(timeout: 30) { !ScratchNode.runs(program) }, "its session's program outlived its owner")
    }

    /// `stop()` ends what left the host's tree (here a program its session started in a session of its own, whose
    /// parent ended: init's now, as a tool server whose keeper was killed is) before the root is removed.
    @Test func aStopEndsWhatLeftTheHostsTree() async throws {
        let node = try await ScratchNode(scratch)
        let mark = node.root.appendingPathComponent("stray.pid")
        let line = "/usr/bin/setsid -f /bin/sh -c 'echo $$ > \(mark.path).part && mv \(mark.path).part \(mark.path) && exec sleep 600'; exec sleep 600"
        _ = try await node.spawn(line)
        try #require(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: mark.path) }, "\(node.said)")
        let written = try String(contentsOf: mark, encoding: .utf8)
        let pid = try #require(pid_t(written.trimmingCharacters(in: .whitespacesAndNewlines)), "\(written)")
        let stray = try #require(Platform.Processes.link(pid))
        defer { if ScratchNode.runs(stray) { kill(stray.pid, SIGKILL) } }
        // Out of the host's tree before the stop lists it.
        try #require(await eventually(timeout: 30) { !ScratchNode.descendants(of: node.hostPID).contains { $0.pid == pid } })

        await offPool { node.stop() }
        #expect(!ScratchNode.runs(stray), "pid \(pid), out of the host's tree, outlived the stop")
    }

    /// The host says its pid, its build (the `build-info` its start checked) and `SWIFT_BACKTRACE` on its stderr at its
    /// start (the start plan's S5), the line the command line reads from the journal as the start's detail (ST-D24).
    @Test func theHostSaysItsBuildAndBacktraceAtItsStart() async throws {
        let node = try await ScratchNode(scratch)
        let line = "vibeswitcher-host: started pid \(node.hostPID) build \(ScratchNode.commit) SWIFT_BACKTRACE=enable=no"
        #expect(await eventually(timeout: 30) { node.said.contains(line + "\n") }, "\(node.said)")
        // As journald would record it from the unit's main process: the start's detail.
        let entries = NodeJournal.entries(json: [
            #"{"__REALTIME_TIMESTAMP":"1800000000000000","USER_UNIT":"vibeswitcher-node.service","JOB_TYPE":"start","JOB_RESULT":"done"}"#,
            String(decoding: try JSONSerialization.data(withJSONObject: ["__REALTIME_TIMESTAMP": "1800000001000000", "MESSAGE": line,
                                                                          "_PID": String(node.hostPID), "_TRANSPORT": "stdout"]), as: UTF8.self),
        ].joined(separator: "\n"))
        let start = try #require(NodeJournal.events(entries, mainPID: node.hostPID).first)
        #expect(start.detail == "pid \(node.hostPID) build \(ScratchNode.commit) SWIFT_BACKTRACE=enable=no")
    }

    /// A scratch root too long for sockets gives a short folder of the run's own, linked from it, not the shared /tmp:
    /// removed with its link when empty, both kept (the link for the run's leftover check to find) when not.
    @Test func aLongScratchRootGivesAShortFolderOfTheRunsOwn() throws {
        let long = scratch.url("long-" + String(repeating: "x", count: 60))
        let empty = try #require(ShortScratch.make(linkedFrom: long))
        #expect(empty.folder.hasPrefix(ShortScratch.shared + "/vst-") && empty.folder.utf8.count <= 40, "\(empty.folder)")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: empty.link)) == empty.folder)
        #expect(URL(fileURLWithPath: empty.link).deletingLastPathComponent().standardizedFileURL.path == long.standardizedFileURL.path)
        #expect(ShortScratch.removeIfEmpty(empty))
        #expect(!FileManager.default.fileExists(atPath: empty.folder) && (try? FileManager.default.destinationOfSymbolicLink(atPath: empty.link)) == nil)

        let used = try #require(ShortScratch.make(linkedFrom: long))
        defer { try? FileManager.default.removeItem(atPath: used.folder) }
        try FileManager.default.createDirectory(atPath: used.folder + "/vsn-left", withIntermediateDirectories: false)
        #expect(!ShortScratch.removeIfEmpty(used))
        #expect(FileManager.default.fileExists(atPath: used.folder + "/vsn-left"))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: used.link)) == used.folder)
    }
}
