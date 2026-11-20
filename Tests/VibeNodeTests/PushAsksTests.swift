import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// push_remote on a node (`PushAsks.swift`): nothing here offers the push, so the lead is told so once per request,
/// and `status` lists the request while it's open. On a scratch host, the request recorded as the lead's tool server
/// records it.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(10)))
struct PushAsksTests {
    private let scratch = Scratch()

    /// What reached the lead with `text` in it: waiting in its inbox, or typed in.
    private func heard(_ world: DeliveryWorld, _ lead: NodeHarness, _ text: String) -> Int {
        world.pending(lead).filter { $0.text.contains(text) }.count + world.prompts(lead).filter { $0.contains(text) }.count
    }

    private func refresh(_ world: DeliveryWorld) async {
        world.engine.refresh()
        await world.drained()
    }

    @Test func aPushRequestIsToldUnofferedOnceAndListedWhileOpen() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead(idle: false)
        let (book, folder, repo, leadID) = (world.host.book, world.host.folder, world.repo, lead.session.id.uuidString)
        let request = LeadPush.Request(commit: String(repeating: "a", count: 40), remote: "origin", branch: "main",
                                       url: "https://example.invalid/r.git", ahead: 2, subjects: ["aaaaaaa One", "bbbbbbb Two"])
        try await offPool {
            try book.vault(folder: folder, as: { .session(leadID) }).requestPush(request, root: repo)
        }
        let unoffered = "nothing here will push it"
        #expect(await eventually(timeout: 60) { world.engine.refresh(); return heard(world, lead, unoffered) == 1 },
                "\(world.pending(lead).map(\.text))")
        #expect(await eventually(timeout: 60) {
            world.queue.sync { world.engine.notices[repo]?.contains { $0.contains("asked you to push main at aaaaaaaa (2 commits)") } == true }
        }, "\(world.queue.sync { world.engine.notices })")
        // Told once, however many refreshes see it.
        for _ in 0..<3 { await refresh(world) }
        #expect(heard(world, lead, unoffered) == 1, "\(world.pending(lead).map(\.text))")
        // Settled (here, as the vault's own caller would): no longer listed.
        try await offPool { _ = try world.host.vault.settlePush(id: request.id, root: repo) }
        #expect(await eventually(timeout: 60) {
            world.engine.refresh()
            return world.queue.sync { world.engine.notices[repo]?.contains { $0.contains("asked you to push") } != true }
        }, "\(world.queue.sync { world.engine.notices })")
    }
}
