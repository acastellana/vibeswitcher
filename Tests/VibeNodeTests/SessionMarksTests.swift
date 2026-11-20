import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// Your names for sessions and your pauses (`SessionMarks`, `session.rename`, `session.pause`; the app's Rename… and
/// Pause): kept by the session's keys, so a name survives `--resume`; shown in `status` and on the wire; a paused session
/// reminds you of nothing; each change the user's voice. The store on its own, then the command line on a `ScratchNode`.
@Suite(NodeTraits.linuxOnly, .serialized, .timeLimit(.minutes(10)))
struct SessionMarksTests {
    private let scratch = Scratch()

    @Test func aNameAndAPauseAreKeptByTheSessionsKeys() throws {
        let root = scratch.url("marks")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marks = SessionMarks(root: root)
        let now = Date()
        let keys = SessionKeys.keys(pid: 41, startedAt: now, sessionId: "conv-1")
        #expect(try marks.rename(keys, to: "  Fix the\nbuild  ") == "Fix the build")
        try marks.pause(keys, until: now + 3600)
        // Read again from the file: by any one of its keys (a resumed session keeps only the conversation's).
        let again = SessionMarks(root: root)
        #expect(again.name(for: ["session:conv-1"]) == "Fix the build")
        #expect(again.pausedUntil(for: ["session:conv-1"], now: now) != nil)
        #expect(again.pausedUntil(for: keys, now: now + 3601) == nil, "an ended pause is no pause")
        try again.pause(keys, until: .distantFuture)
        #expect(again.pausedUntil(for: keys, now: now + 86_400 * 365) == .distantFuture)
        // The process gone: its key's marks go, the conversation's stay; a scan that found nothing drops nothing.
        again.prune(liveKeys: [], now: now)
        #expect(again.name(for: [keys[0]]) == "Fix the build")
        again.prune(liveKeys: ["proc:99-1"], now: now)
        #expect(again.name(for: [keys[0]]) == nil && again.name(for: ["session:conv-1"]) == "Fix the build")
        #expect(try again.rename(keys, to: " ") == nil)
        #expect(again.name(for: keys) == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: again.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func aSessionIsRenamedAndPausedInTheUsersVoice() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let folder = node.root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let started = try await node.runOnTerminal(["new", folder.path])
        try #require(started.status == 0, "\(started.output)\n\(node.said)")
        let hosted = try #require(try node.sessions().first { $0.isLive && $0.label == "Claude" })
        let short = String(hosted.id.uuidString.lowercased().prefix(8))
        let id = NodeIds.session(host: hosted.id)
        func listed(_ status: [String: Any]) -> [String: Any]? {
            (status["sessions"] as? [[String: Any]])?.first { $0["id"] as? String == id }
        }
        try #require(await node.eventuallyStatus { listed($0) != nil }, "\(node.said)")

        let renamed = try await node.runOnTerminal(["rename", short, "Release notes"])
        #expect(renamed.status == 0 && renamed.output.contains("names session \(short)") && renamed.output.contains("is “Release notes”"),
                "\(renamed.output)")
        #expect(await node.eventuallyStatus { listed($0)?["name"] as? String == "Release notes" })
        let shown = try await node.run(["status"])
        #expect(shown.output.contains("“Release notes”"), "\(shown.output)")

        let paused = try await node.runOnTerminal(["pause", short, "--hours", "2"])
        #expect(paused.status == 0 && paused.output.contains("paused: session \(short), until"), "\(paused.output)")
        #expect(await node.eventuallyStatus { listed($0)?["pausedUntil"] is String })
        let off = try await node.runOnTerminal(["pause", short, "--off"])
        #expect(off.status == 0 && off.output.contains("resumed: session \(short)"), "\(off.output)")
        #expect(await node.eventuallyStatus { listed($0)?["pausedUntil"] is NSNull })

        let reset = try await node.runOnTerminal(["rename", short])
        #expect(reset.status == 0 && reset.output.contains("has its own name again"), "\(reset.output)")
        #expect(await node.eventuallyStatus { listed($0)?["name"] is NSNull })

        // Not from a session's process: a peer with no terminal is refused before anything changes.
        let noTerminal = try await node.run(["rename", short, "x"])
        #expect(noTerminal.status == 77, "\(noTerminal.output)\(noTerminal.errors)")
        let usage = try await node.run(["pause", short, "--hours", "0"])
        #expect(usage.status == 64, "\(usage.errors)")
    }
}
