import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The rest of the Team tab (`BoardDetails`, 2026-11-21): the lead's Results in the board's value, a task's details as
/// its row opens (`board.task`), and a result's screenshot (`board.image`), served only from that result's kept folder,
/// with no link followed, as an image its bytes agree with. Each test has a scratch root.
struct BoardDetailsTests {
    private let scratch = Scratch()

    static func png(_ count: Int) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data((0..<count).map { UInt8($0 % 251) })
    }

    @Test func theResultsAreNewestFirstAndTheBoardSaysThemAsTheSchemaDoes() throws {
        var board = WireVectors.sampleBoard(now: WireVectors.boardNow.timeIntervalSince1970)
        var first = LeadUpdate(id: "u1", title: "Onboarding shipped", body: "**Three steps**, each tested.")
        first.at = 1_000
        var second = LeadUpdate(id: "u2", title: "Upload retry", body: String(repeating: "line\n", count: 400), images: ["/r/.vibeswitcher/updates/u2/a.png"])
        second.at = 2_000
        board.updates = [first, second]
        let results = try #require(BoardDetails.results(board).array)
        #expect(results.map { $0["id"]?.string ?? "" } == ["u2", "u1"])
        #expect(results[0]["images"] == .int(1) && results[1]["body"] == .string("**Three steps**, each tested."))
        #expect((results[0]["body"]?.string?.split(separator: "\n").count ?? 0) <= BoardDetails.bodyLines)
        let value = BoardValue.value(project: "p", root: "/r", board: board, now: WireVectors.boardNow)
        #expect(value["results"]?.array?.count == 2)
        #expect(WireSchema.check(value, as: "board", strict: true) == nil, "\(WireSchema.check(value, as: "board", strict: true) ?? "")")
        // `vibeswitcher board` names them under the scorecard, newest first.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let printed = BoardText.records(value, now: WireVectors.boardNow, calendar: utc)
        let at = try #require(printed.firstIndex(of: "Results"))
        #expect(printed[at + 1].hasSuffix("Upload retry (1 screenshot)") && printed[at + 2].hasSuffix("Onboarding shipped"), "\(printed)")
    }

    @Test func aTasksDetailsAreTheMacsRowDetails() throws {
        let board = WireVectors.sampleBoard(now: WireVectors.boardNow.timeIntervalSince1970, verifier: UUID())
        for task in board.tasks {
            let value = BoardDetails.task(task)
            #expect(WireSchema.check(value, as: "board.task.result", strict: true) == nil, "\(task.slug): \(WireSchema.check(value, as: "board.task.result", strict: true) ?? "")")
        }
        let review = try #require(board.tasks.first { $0.slug == "upload-retry" })
        let details = BoardDetails.task(review)
        #expect(details["findings"]?.array?.first?["text"]?.string?.hasPrefix("F1 upload.js:42 — ") == true, "\(details)")
        #expect(details["findings"]?.array?.first?["blocks"] == .bool(true) && details["round"] == .int(1))
        let blocked = try #require(board.tasks.first { $0.status == .blocked })
        #expect(BoardDetails.task(blocked)["failure"]?.string?.isEmpty == false)
        let merged = try #require(board.tasks.first { $0.merged != nil })
        #expect(BoardDetails.task(merged)["merged"]?.string?.hasPrefix("Merged 8a3f1e2c at ") == true)
    }

    /// Only a file the board's own result names, in its kept folder, read with no link followed, as an image its bytes
    /// agree with.
    @Test func aResultsImageIsServedOnlyFromItsKeptFolder() throws {
        let root = scratch.url("repo")
        let kept = root.appendingPathComponent(".vibeswitcher/updates/u1")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        let bytes = Self.png(500)
        try bytes.write(to: kept.appendingPathComponent("shot.png"))
        let outside = scratch.url("secret.png")
        try Self.png(64).write(to: outside)
        try FileManager.default.createSymbolicLink(at: kept.appendingPathComponent("linked.png"), withDestinationURL: outside)
        try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(to: kept.appendingPathComponent("drawing.png"))
        var board = LeadBoard()
        board.updates = [LeadUpdate(id: "u1", title: "Shot", body: "", images: [
            kept.appendingPathComponent("shot.png").path, outside.path, kept.appendingPathComponent("linked.png").path,
            kept.appendingPathComponent("drawing.png").path, kept.path + "/../u1/shot.png", root.appendingPathComponent(".vibeswitcher/board.json").path,
        ])]
        let served = try #require(BoardDetails.image(root: root.path, board: board, update: "u1", index: 0))
        #expect(served.data == bytes && served.mediaType == "image/png")
        // A path outside the folder, a link in it, an SVG called a PNG, an index out of range, a result the board
        // doesn't have: nothing.
        for index in [1, 2, 3, 5, 6, -1] {
            #expect(BoardDetails.image(root: root.path, board: board, update: "u1", index: index) == nil, "\(index)")
        }
        #expect(BoardDetails.image(root: root.path, board: board, update: "u2", index: 0) == nil)
        // `..` that comes back to the folder is the same file: still in it.
        #expect(BoardDetails.image(root: root.path, board: board, update: "u1", index: 4)?.data == bytes)
    }

    @Test func aProjectWithNoLeadIsGone() async throws {
        let queue = DispatchQueue(label: "engine")
        let link = HostLink(dialer: NoHost(), root: scratch.url("link-root"), queue: queue)
        let requests = Requests(link: link, sessions: nil, rule: VoiceRule(mode: .weaker, scopes: [], uid: getuid(), says: "a test's"),
                                root: scratch.url("node-root"), hostSocket: "/nonexistent/host.sock", commit: "abc123", hostPID: 1)
        func ask(_ kind: String, _ args: [String: NodeWire.Value]) async -> NodeWire.Reply {
            await withCheckedContinuation { continuation in
                queue.async {
                    let request = NodeWire.Request(id: "1", kind: kind, args: args)
                    if kind == "board.task" { requests.boardTask(request) { continuation.resume(returning: $0) } }
                    else { requests.boardImage(request) { continuation.resume(returning: $0) } }
                }
            }
        }
        #expect(await ask("board.task", ["project": .string("p"), "task": .string("t")]).error?.code == NodeWire.Code.gone.rawValue)
        #expect(await ask("board.task", ["project": .string("p")]).error?.code == NodeWire.Code.badArgs.rawValue)
        #expect(await ask("board.image", ["project": .string("p"), "update": .string("u"), "index": .int(0)]).error?.code == NodeWire.Code.gone.rawValue)
        #expect(await ask("board.image", ["project": .string("p"), "update": .string("u")]).error?.code == NodeWire.Code.badArgs.rawValue)
    }

    private struct NoHost: HostDialer {
        func connect(queue: DispatchQueue, patience: TimeInterval) throws -> HostConnection { throw HostLink.Failure("no host in this test") }
    }
}
