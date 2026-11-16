import Foundation
import Testing
import VibeCore

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

    /// A scratch root too long for sockets gives a short folder of the run's own, linked from it, not the shared /tmp:
    /// removed with its link when empty, both kept (the link for the run's leftover check to find) when not.
    @Test func aLongScratchRootGivesAShortFolderOfTheRunsOwn() throws {
        let long = scratch.url("long-" + String(repeating: "x", count: 60))
        let empty = try #require(ShortScratch.make(linkedFrom: long))
        #expect(empty.folder != "/tmp" && empty.folder.hasPrefix("/tmp/vst-") && empty.folder.utf8.count <= 40, "\(empty.folder)")
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
