import Combine
import Foundation
import Testing
@testable import VibeSwitcher

/// While the main run loop is out of its default mode (an alert running modal, a menu tracking), what's received on it
/// waits; only the newest value waits. `receive(on: RunLoop.main)` kept every one: End Session…'s alert, left open
/// overnight (2026-10-27), kept each version of the leads' boards (990 MB by morning), and main froze 8.9 s freeing
/// them once it closed (hang-20261028-070849).
@MainActor
@Suite(.serialized) struct ReceiveLatestTests {
    /// A value that counts how many of its kind are alive.
    final class Token {
        nonisolated(unsafe) static var alive = 0
        let id: Int
        init(_ id: Int) {
            self.id = id
            Token.alive += 1
        }
        deinit { Token.alive -= 1 }
    }

    /// Runs the main run loop in its default mode until `done` (a guard of 10 s, for a test that would hang).
    func runDefault(until done: () -> Bool) {
        let limit = Date().addingTimeInterval(10)
        while !done(), Date() < limit { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    @Test func onlyTheNewestValueWaitsForTheDefaultMode() {
        Token.alive = 0
        let subject = PassthroughSubject<Token, Never>()
        var received: [Int] = []
        var finished = false
        let subscription = subject.receiveLatest(on: RunLoop.main)
            .sink(receiveCompletion: { _ in finished = true }, receiveValue: { received.append($0.id) })
        for id in 0..<100 { subject.send(Token(id)) }
        #expect(Token.alive == 1, "\(Token.alive) values waiting")
        #expect(received.isEmpty)

        runDefault { !received.isEmpty }
        #expect(received == [99])
        #expect(Token.alive == 0)
        // Values that come later are delivered as they come; the completion after the last.
        subject.send(Token(100))
        subject.send(completion: .finished)
        runDefault { finished }
        #expect(received == [99, 100] && finished)
        #expect(Token.alive == 0)
        subscription.cancel()
    }

    @Test func cancellingDropsWhatWaits() {
        Token.alive = 0
        let subject = PassthroughSubject<Token, Never>()
        var received: [Int] = []
        let subscription = subject.receiveLatest(on: RunLoop.main).sink { received.append($0.id) }
        subject.send(Token(1))
        #expect(Token.alive == 1)
        subscription.cancel()
        #expect(Token.alive == 0)
        subject.send(Token(2))
        #expect(Token.alive == 0)
        // The delivery scheduled before the cancel finds nothing to deliver.
        var turned = false
        RunLoop.main.perform(inModes: [.default]) { turned = true }
        runDefault { turned }
        #expect(received.isEmpty)
    }

    /// The app's subscriptions to its models on the main run loop hold only the newest value while it's elsewhere.
    @Test func theAppReceivesOnTheMainRunLoopOnlyTheNewestValue() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent("Sources/VibeSwitcher")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        let swift = files.filter { $0.pathExtension == "swift" }
        #expect(swift.count > 50)
        var queuing: [String] = []
        for file in swift {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && line.contains(#/\.receive\(on: *RunLoop\.(main|current)/#) {
                queuing.append("\(file.path.dropFirst(repo.path.count + 1)):\(index + 1)")
            }
        }
        #expect(queuing.isEmpty, "receive(on: RunLoop.main) keeps every value while the run loop is elsewhere: use receiveLatest(on:) at \(queuing)")
    }
}
