import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The start page's recent projects (`RecentRequest.swift`, the app's `Launcher.recentProjects`): the folders a scratch
/// home's Claude Code (`.claude.json`'s `projects`) and Codex (`.codex/config.toml`) know, newest first by their
/// transcripts folder, the home itself and folders gone left out, each with its lead's project; a read of the user's or a
/// page's (never a session's process). Every file is a scratch home's: never the real ~/.claude.json.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct RecentRequestTests {
    private let scratch = Scratch()

    /// A scratch home whose Claude Code knows `older` and `newer` (their transcripts folders that old), the home and a
    /// folder gone; and whose Codex trusts `trusted`.
    private func home(older: String, newer: String, trusted: String) throws -> URL {
        let home = scratch.url("recent-home")
        let files = FileManager.default
        for folder in [older, newer, trusted] { try files.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        let projects: [String: Any] = [older: ["allowedTools": []], newer: [:], home.path: [:], "/nowhere/gone": [:], "relative": [:]]
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["projects": projects, "oauthAccount": ["emailAddress": "a@example.invalid"]])
            .write(to: home.appendingPathComponent(".claude.json"))
        for (folder, age) in [(older, 7200.0), (newer, 60.0)] {
            let transcripts = home.appendingPathComponent(".claude/projects/\(RecentProjects.claudeSlug(for: folder))")
            try files.createDirectory(at: transcripts, withIntermediateDirectories: true)
            try files.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: transcripts.path)
        }
        try files.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try Data("[projects.\"\(trusted)\"]\ntrust_level = \"trusted\"\n".utf8).write(to: home.appendingPathComponent(".codex/config.toml"))
        return home
    }

    @Test func theFoldersComeNewestFirstTheHomeAndGoneOnesLeftOut() throws {
        let (older, newer, trusted) = (scratch.url("older").path, scratch.url("newer").path, scratch.url("trusted").path)
        let home = try home(older: older, newer: newer, trusted: trusted)
        let projects = NodeRecent.projects(home: home.path)
        #expect(projects.map(\.path) == [newer, older, trusted], "\(projects)")
        #expect(NodeRecent.projects(home: home.path, limit: 1).map(\.path) == [newer])
        #expect(NodeRecent.projects(home: scratch.url("empty-home").path).isEmpty)
    }

    /// Through the node: each folder with the project of the lead that runs there; a page's token that reads may ask.
    @Test func theNodeSaysEachFolderAndItsLead() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.world.lead()
        let (older, trusted) = (scratch.url("older").path, scratch.url("trusted").path)
        let home = try home(older: older, newer: world.repo, trusted: trusted)
        world.requests.home = home.path
        #expect(NodeWire.kinds["recent"] == .webRead && !NodeWire.changesState("recent"))
        #expect(WebAccess.refusal(for: NodeWire.Request(id: "1", kind: "recent"), rights: [.read]) == nil)
        let reply = try #require(await world.ask("recent", action: nil))
        let projects = try #require(reply.result?["projects"]?.array, "\(reply)")
        #expect(projects.map { $0["folder"]?.string } == [world.repo, older, trusted], "\(projects)")
        #expect(projects.map { $0["lead"] } == [.string(world.project), .null, .null])
        #expect(projects[2]["lastUsed"] == .null, "Codex's trusted folders say no time")
        #expect(WireSchema.check(try #require(reply.result), as: "recent.result") == nil)
        #expect(!String(decoding: NodeWire.message(try #require(reply.result)), as: UTF8.self).contains("example.invalid"), "nothing else of .claude.json")

        // A session's process (an agent) is refused: the user's other projects aren't its to list. A page's read goes
        // through `webRead`, which gives it.
        var session = CardWorld.user
        session.sessionMarker = true
        let refused = try #require(await world.ask("recent", action: nil, from: session))
        #expect(refused.error?.code == NodeWire.Code.voice.rawValue, "\(refused)")
        #expect(WebAccess.refusal(for: NodeWire.Request(id: "2", kind: "recent"), rights: [])?.error?.code == NodeWire.Code.voice.rawValue)
        let paged = await withCheckedContinuation { done in
            world.requests.queue.async { world.requests.webRead(NodeWire.Request(id: "p", kind: "recent")) { done.resume(returning: $0) } }
        }
        #expect(paged.result?["projects"]?.array?.count == 3, "\(paged)")
    }
}
