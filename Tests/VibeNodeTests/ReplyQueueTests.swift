import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// `Requests` answers on its queue (the CI flake of 2026-11-22): `settings` read off it and answered from the reading
/// queue, racing the server's own write of another reply on the connection, and the server crashed under load
/// ("Can't remove more items from a collection than it contains", `NodeServer.flush`); the command line then found no
/// server. Its answer now comes on the queue; and the server takes any reply given elsewhere onto its queue before it
/// writes it.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct ReplyQueueTests {
    private let scratch = Scratch()
    private static let mark = DispatchSpecificKey<Bool>()

    @Test func settingsAnswersOnTheRequestsQueue() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let requests = world.requests
        requests.queue.setSpecific(key: Self.mark, value: true)
        let onQueue = Locked<Bool?>(nil)
        requests.queue.async {
            requests.settings(NodeWire.Request(id: "s", kind: "settings")) { _ in onQueue.value = DispatchQueue.getSpecific(key: Self.mark) == true }
        }
        try #require(await eventually(timeout: 60) { onQueue.value != nil })
        #expect(onQueue.value == true)
        // A folder no lead has worked in: its refusal too.
        let refusalOnQueue = Locked<Bool?>(nil)
        requests.queue.async {
            requests.settings(NodeWire.Request(id: "f", kind: "settings", args: ["folder": .string(world.repo)])) { _ in
                refusalOnQueue.value = DispatchQueue.getSpecific(key: Self.mark) == true
            }
        }
        try #require(await eventually(timeout: 60) { refusalOnQueue.value != nil })
        #expect(refusalOnQueue.value == true)
    }
}
