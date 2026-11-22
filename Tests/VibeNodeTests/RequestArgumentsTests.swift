import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// An unknown argument on a state change in the user's voice is refused, not ignored (`RequestArguments`, the
/// architecture review's row 11), and the command line says when its server runs another build (`BuildMismatch`).
@Suite(.timeLimit(.minutes(5)))
struct RequestArgumentsTests {
    private let scratch = Scratch()

    @Test func anArgumentTheKindDoesntTakeIsBadArgs() throws {
        let refused = try #require(RequestArguments.refusal(.init(id: "1", kind: "lead", args: ["folder": .string("/p"), "gaol": .string("typo")], action: "a")))
        #expect(refused.re == "1" && refused.error?.code == "bad-args", "\(refused)")
        #expect(refused.error?.message.contains("gaol") == true && refused.error?.message.contains("goal") == true, "\(refused)")
        // Every argument it takes, one given as null among them, passes; so does none.
        #expect(RequestArguments.refusal(.init(id: "2", kind: "answer", args: ["card": .string("c"), "code": .string("ABCD"), "text": .string("t"),
                                                                             "version": .null], action: "a")) == nil)
        #expect(RequestArguments.refusal(.init(id: "3", kind: "stop", action: "a")) == nil)
        #expect(RequestArguments.refusal(.init(id: "4", kind: "stop", args: ["now": .bool(true)], action: "a"))?.error?.code == "bad-args")
        // A read's arguments aren't checked here.
        #expect(RequestArguments.refusal(.init(id: "5", kind: "questions", args: ["anything": .bool(true)])) == nil)
    }

    /// Through the server's path: refused before the vault records it, so nothing is done and nothing recorded.
    @Test(NodeTraits.linuxOnly) func anUnknownArgumentIsRefusedBeforeTheVaultRecordsIt() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let action = UUID().uuidString.lowercased()
        let reply = try #require(await world.ask("tell", ["folder": .string(world.repo), "text": .string("hello"), "urgent": .bool(true)], action: action))
        #expect(reply.error?.code == "bad-args" && reply.error?.message.contains("urgent") == true, "\(reply)")
        #expect(await world.actions().filter { $0.action == action }.isEmpty)
        #expect(world.queue.sync { world.requests.accepted.isEmpty })
    }

    @Test func aServerOnAnotherBuildIsSaid() throws {
        let (a, b) = (String(repeating: "a", count: 40), String(repeating: "b", count: 40))
        let said = try #require(BuildMismatch.warning(own: a, server: b))
        #expect(said.contains(String(b.prefix(12))) && said.contains("vibeswitcher switch \(a)"), "\(said)")
        #expect(BuildMismatch.warning(own: a, server: a) == nil)
        #expect(BuildMismatch.warning(own: nil, server: b) == nil)
        #expect(BuildMismatch.warning(own: a, server: "unknown") == nil)
    }

    /// The command line's own build: the commit its build folder's `build-info` names, read through its path's
    /// links; none for a program outside a build's `bin`.
    @Test func theCommandLinesOwnBuildIsItsFoldersCommit() throws {
        let commit = String(repeating: "c", count: 40)
        let root = scratch.url("own-build")
        let build = root.appendingPathComponent(commit)
        let bin = build.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let program = bin.appendingPathComponent("vibeswitcher")
        try Data().write(to: program)
        try Data(#"{"format":1,"commit":"\#(commit)","binaries":{},"swift":"6","resolved":"\#(String(repeating: "d", count: 64))"}"#.utf8).write(to: build.appendingPathComponent(BuildInfo.fileName))
        let link = root.appendingPathComponent("vs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: program)
        #expect(BuildMismatch.own(executable: link.path) == commit)
        let loose = root.appendingPathComponent("loose")
        try Data().write(to: loose)
        #expect(BuildMismatch.own(executable: loose.path) == nil)
    }
}
