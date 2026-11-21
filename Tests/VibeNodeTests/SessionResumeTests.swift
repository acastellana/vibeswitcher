import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The user's sessions that ended lately (`EngineState.Ended`, `session.resume`; the app's ended sessions and their
/// Resume): a session of the user's that ends goes on the list once past the reopen record's grace; `status` lists it with
/// its conversation; `session.resume` starts it again with `--resume`, checked as `reopen` checks a session, and one that
/// can't be (no conversation known) stays on the list. Only fake sessions start (AGENTS.md).
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct SessionResumeTests {
    private let scratch = Scratch()

    @Test func anEndedSessionIsListedAndResumedInItsConversation() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        // The node's `claude` linked to the world's fake (`NodePreflight.claudeLink` on a scratch root).
        let claudeLink = world.host.root.appendingPathComponent("v2/test/claude")
        try FileManager.default.createDirectory(at: claudeLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: claudeLink.path, withDestinationPath: world.world.fake.launcher.path)
        let repo = URL(fileURLWithPath: world.repo).resolvingSymlinksInPath().path
        let harness = try await NodeHarness.start(on: world.host, fake: world.world.fake, cwd: repo, label: "Claude")
        let id = harness.session.id
        let live = { world.queue.sync { world.world.link.sessions.contains { $0.id == id && $0.isLive } } }
        try #require(await eventually(timeout: 60) { live() })
        world.queue.sync { world.engine.noteOpenSessions() }
        #expect(world.queue.sync { world.engine.openSessions?.entries.map(\.id) } == [id])

        // It ends; past the grace it's on the ended list.
        world.queue.sync { world.world.link.kill(id) }
        try #require(await eventually(timeout: 60) { !live() })
        // Within the grace: not listed yet, but `status`'s `ending` says it ended and when it will be listed, and
        // `resume`'s words say so rather than "none ended" (the acceptance run's A8).
        let endedAt = Date()
        world.queue.sync {
            world.engine.openNow = { endedAt }
            world.engine.noteOpenSessions()
        }
        #expect(world.queue.sync { world.engine.endedSessions.isEmpty })
        let ending = try #require(world.queue.sync { world.engine.endingValue.array })
        #expect(ending.count == 1 && ending[0]["session"]?.string == NodeIds.session(host: id), "\(ending)")
        #expect(WireSchema.check(ending[0], as: "node.ending") == nil)
        let said = ResumeText.endingLines(ending, now: endedAt.addingTimeInterval(4))
        #expect(said == ["a session ended 4 s ago (\(ConfigSeal.inert(ending[0]["name"]?.string ?? "", limit: 80)) in \(repo)); it is listed in 26 s: run `vibeswitcher resume` again then"],
                "\(said)")
        #expect(world.requests.queue.sync { world.requests.statusValue()["ending"]?.array?.count } == 1)
        world.queue.sync {
            world.engine.openNow = Date.init
            world.engine.openGrace = 0
            world.engine.noteOpenSessions()
        }
        #expect(world.queue.sync { world.engine.endingValue.array?.isEmpty } == true, "listed now, no longer ending")
        #expect(world.queue.sync { world.engine.endedSessions.map(\.entry.id) } == [id])
        let listed = world.queue.sync { world.engine.endedValue.array?.first }
        #expect(listed?["session"]?.string == NodeIds.session(host: id) && listed?["conversation"] == .null, "\(String(describing: listed))")
        // How it ended, as the host recorded it (the inspector's Exit).
        let exit = try #require(listed?["exit"]?.object, "\(String(describing: listed))")
        #expect(exit["status"]?.int != nil && exit["cause"]?.string?.isEmpty == false && exit["at"] != nil, "\(exit)")

        // No conversation known: refused, and still listed.
        let short = String(id.uuidString.lowercased().prefix(8))
        let unknown = try #require(await world.ask("session.resume", ["session": .string(short)]))
        #expect(unknown.error?.code == NodeWire.Code.refused.rawValue && unknown.error?.message.contains("conversation id wasn't known") == true, "\(unknown)")
        #expect(world.queue.sync { world.engine.endedSessions.count } == 1)

        // Its conversation known, with Claude's transcript for the folder: resumed with --resume, off the list.
        let conversation = UUID().uuidString.lowercased()
        let transcript = URL(fileURLWithPath: LeadLaunch.claudeProjectFolder(repo, home: world.host.home.path)).appendingPathComponent("\(conversation).jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (#"{"type":"user","cwd":"\#(repo)","sessionId":"\#(conversation)"}"# + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        world.queue.sync { world.engine.endedSessions[0].entry.agentSessionID = conversation }
        let action = UUID().uuidString.lowercased()
        let resumed = try #require(await world.ask("session.resume", ["session": .string(NodeIds.session(host: id))], action: action))
        let started = try #require(resumed.result?["reopened"]?.array?.first, "\(resumed)")
        #expect(started["conversation"]?.string == conversation && started["folder"]?.string == repo, "\(started)")
        let new = try #require(started["session"]?.string.flatMap { UUID(uuidString: String($0.dropFirst(NodeIds.node.count + 1))) })
        let session = try #require(world.queue.sync { world.world.link.sessions.first { $0.id == new } })
        #expect(session.label == "Claude" && session.cwd == repo && session.command?.hasSuffix("--resume '\(conversation)'") == true, "\(session)")
        #expect(world.queue.sync { world.engine.endedSessions.isEmpty })
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["session.resume"])
        let gone = try #require(await world.ask("session.resume", ["session": .string(short)]))
        #expect(gone.error?.code == NodeWire.Code.gone.rawValue, "\(gone)")
    }
}
