import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// Check for Updates now (`update.check`, `vibeswitcher status --check-updates`): the update watch's look asked at once,
/// its answer the reply and kept in its record; a check asked during the watch's own look waits for that look (one
/// question to GitHub, not two); the user's voice with no typed word, never a session's or a page's; a scratch server's
/// test answers, refused on the user's node. GitHub is a stand-in.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct UpdateCheckTests {
    private let scratch = Scratch()
    private static func sha(_ c: Character) -> String { String(repeating: c, count: 40) }
    private let running = sha("a"), newer = sha("b")

    private func green(_ sha: String) -> [UpdateWatch.Run] {
        [UpdateWatch.Run(databaseId: 1, workflowName: "v2 linux", headSha: sha, status: "completed", conclusion: "success"),
         UpdateWatch.Run(databaseId: 2, workflowName: "v2 macos", headSha: sha, status: "completed", conclusion: "success")]
    }

    @Test func aCheckDuringTheWatchsLookWaitsForItAndAsksGitHubOnce() async throws {
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let calls = Locked(0)
        let (running, newer, runs) = (running, newer, green(newer))
        let looker = UpdateWatch.Looker(runs: {
            calls.value += 1
            entered.signal()
            gate.wait()
            return .success(runs)
        }, compare: { base, head in
            .success(.init(status: base == running && head == newer ? "ahead" : "identical", aheadBy: 1))
        })
        let queue = DispatchQueue(label: "update-check-test")
        let watch = UpdateWatch(file: scratch.url("update-check.json"), running: running, looker: looker, queue: queue, note: { _ in })
        let told = Locked<[NodeWire.Value]>([])
        queue.async { watch.look() }
        try #require(await offPool { entered.wait(timeout: .now() + 60) == .success }, "the watch's look never asked")
        // `update.check` while it asks: no second question; told once the first lands.
        queue.async { watch.look { told.value.append(watch.checked) } }
        queue.sync {}
        #expect(told.value.isEmpty)
        gate.signal()
        try #require(await eventually(timeout: 60) { told.value.count == 1 })
        #expect(calls.value == 1)
        let checked = try #require(told.value.first)
        #expect(checked["commit"]?.string == newer && checked["running"]?.string == running, "\(checked)")
        #expect(UpdateWatch.lines(checked) == ["updates: " + UpdateWatch.notice(watch.record, running: running)!], "\(UpdateWatch.lines(checked))")
        // Kept: the record says it, and the timed watch's next look is 6 h away.
        #expect(UpdateWatch.load(watch.file).offer?.commit == newer)
        #expect(queue.sync { watch.due(at: Date().addingTimeInterval(UpdateWatch.interval - 60)) } == false)
        // The page's Updates section (the feature review of 2026-11-22): the `node` stream carries the look as
        // `node.update`, which the schema checks strictly.
        let update = queue.sync { watch.value }
        #expect(update["commit"]?.string == newer && update["install"]?.string == UpdateWatch.installLine(newer))
        #expect(WireSchema.check(update, as: "node.update", strict: true) == nil, "\(String(describing: WireSchema.check(update, as: "node.update", strict: true)))")
        let node = NodeStatusStore.value(status: .object(["update": update]), web: NodeStatusStore.webOff)
        #expect(node["update"] == update)
    }

    @Test func itSaysNoneOrWhyItCouldntLook() {
        let none: NodeWire.Value = .object(["checkedAt": .string("2026-11-21T12:00:00Z"), "commit": .null, "problem": .null, "notice": .null])
        #expect(UpdateWatch.lines(none) == ["updates: no newer build on v2 that both CI runs (v2 linux, v2 macos) passed (checked 2026-11-21T12:00:00Z)"])
        let failed: NodeWire.Value = .object(["checkedAt": .null, "commit": .null, "problem": .string("gh has no token for github.com (gh auth login)"), "notice": .null])
        #expect(UpdateWatch.lines(failed) == ["updates: couldn't check v2 for a newer build (gh has no token for github.com (gh auth login))"])
        // A failed check after a found one: why, then the last answer, said as the last.
        let kept: NodeWire.Value = .object(["problem": .string("offline"), "notice": .string("a newer build is on v2: x")])
        #expect(UpdateWatch.lines(kept) == ["updates: couldn't check v2 for a newer build (offline)", "updates: a newer build is on v2: x (the last check's answer)"])
    }

    @Test func theUserAsksWithNoCodeNeitherASessionNorAPage() async throws {
        #expect(NodeWire.kinds["update.check"] == .user && NodeWire.changesNothing.contains("update.check") && !NodeWire.changesState("update.check"))
        #expect(WebAccess.refusal(for: NodeWire.Request(id: "1", kind: "update.check"), rights: [.read, .draft])?.error?.code == NodeWire.Code.voice.rawValue)
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        var session = CardWorld.user
        session.sessionMarker = true
        let refused = try #require(await world.ask("update.check", action: nil, from: session))
        #expect(refused.error?.code == NodeWire.Code.voice.rawValue, "\(refused)")
        // The user's, with no typed code: this world's server keeps no update watch (a scratch one without test answers).
        let mine = try #require(await world.ask("update.check", action: nil))
        #expect(mine.error?.code == NodeWire.Code.refused.rawValue && mine.error?.message.contains("doesn't check for updates") == true, "\(mine)")
    }

    @Test func theTestAnswersAreAScratchServersOnly() throws {
        let base = ["vibeswitcher-server", "--host-connector", "3", "--host-socket", "/x/host.sock"]
        let flag = ServerArguments.testUpdateAnswersFlag + "/x/answers.json"
        let user = try ServerArguments.parse(base + ["--node", "--node-root", "/x/b", flag]).get()
        #expect(user.refused == [flag] && user.testUpdateAnswers == nil)
        let scratchServer = try ServerArguments.parse(base + ["--root", "/x", "--node-root", "/x/b", flag]).get()
        #expect(scratchServer.testUpdateAnswers == "/x/answers.json")
        #expect(throws: (any Error).self) { try ServerArguments.parse(base + ["--root", "/x", ServerArguments.testUpdateAnswersFlag + "answers.json"]).get() }
    }
}
