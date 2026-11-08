import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// Each connection numbers its requests from 1, so a reply's timer armed on one connection names another request on the
/// next. Its timer belongs to the connection it was armed on: firing after a reconnect it says nothing about the
/// request now holding that number (a false "didn't answer"), and doesn't make a paced piece look refused and go twice.
@MainActor
@Suite(.serialized)
struct HostClientReplyTimerTests {
    /// A client on a scratch host with its reply timers in the test's hand, which had `asking` requests in flight when
    /// its connection dropped and is connected again. Their timers, by the number each request had.
    static func reconnected(asking: Int = 64) async throws -> (scratch: PasteDeliveryTests.Scratch, timers: [Int: () -> Void]) {
        let scratch = try PasteDeliveryTests.Scratch()
        var armed: [() -> Void] = []
        scratch.host.replyLater = { _, fire in armed.append(fire) }
        scratch.host.connectIfRunning()
        #expect(await until { scratch.host.state == .connected })
        var timers: [Int: () -> Void] = [:]
        var dropped = 0
        for _ in 0..<asking {
            let before = Set(scratch.host.replies.keys)
            scratch.host.screen(UUID()) { screen in
                #expect(screen == nil)
                dropped += 1
            }
            let seq = try #require(Set(scratch.host.replies.keys).subtracting(before).first)
            timers[seq] = try #require(armed.last)
        }
        // No reply can come first: replies arrive on this (the main) actor, and this runs through without yielding.
        scratch.host.connectAgain()
        #expect(dropped == asking)
        #expect(await until { scratch.host.state == .connected })
        return (scratch, timers)
    }

    @Test func anOldTimerDoesntErrorTheRequestHoldingItsNumberOnTheNewConnection() async throws {
        let (scratch, timers) = try await Self.reconnected()
        let (session, _, _) = try await scratch.spawnReader()
        var answers: [String?] = []
        let before = Set(scratch.host.replies.keys)
        scratch.host.screen(session.id) { answers.append($0) }
        let seq = try #require(Set(scratch.host.replies.keys).subtracting(before).first)
        let oldTimer = try #require(timers[seq], "seq \(seq) wasn't used on the dropped connection")
        oldTimer()
        #expect(answers.isEmpty, "the dropped connection's timer answered this request")
        #expect(await until { !answers.isEmpty })
        #expect(answers.first.flatMap { $0 } != nil)
    }

    @Test func anOldTimerDoesntMakeAPacedPieceGoTwice() async throws {
        let (scratch, timers) = try await Self.reconnected()
        let (session, out, go) = try await scratch.spawnReader()
        #expect(FileManager.default.createFile(atPath: go, contents: nil))
        let piece = Data((0..<4_096).map { UInt8(ascii: "a") + UInt8($0 % 26) })
        var done: Bool?
        let before = Set(scratch.host.replies.keys)
        scratch.host.send(session.id, bytes: piece, reply: false) { done = $0 }
        // The piece, then the screen read that is its receipt.
        let sent = Set(scratch.host.replies.keys).subtracting(before).sorted()
        #expect(sent.count == 2, "\(sent)")
        let pieceSeq = try #require(sent.first)
        let oldTimer = try #require(timers[pieceSeq], "the piece's seq wasn't used on the dropped connection")
        oldTimer()
        #expect(await until { done != nil })
        #expect(done == true)
        // The end mark comes after whatever the host took: a piece sent twice shows before it.
        let end = Data("END".utf8)
        scratch.host.send(session.id, bytes: end, reply: false)
        #expect(await PasteDeliveryTests.received(out, piece + end) == piece + end)
    }
}
