import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The security architecture document's S3 for answers: an answer from a session's process, from a process carrying a
/// session's marker, or from branch code is not the user's voice, whatever code it types. Each sender is a real process
/// read from `/proc` (`PeerFacts.read`), as the server reads every request's sender; nothing is recorded or answered.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct AnswerVoiceTests {
    private let scratch = Scratch()

    /// A card to answer, from the lead's tool server's post.
    private func card(_ world: CardWorld) async throws -> CardStore.Card {
        let lead = try await world.sleepingLead()
        return try await world.asked("Approve the merge?", options: ["Yes", "No"], lead: lead).card
    }

    /// `body` with a process started from `arguments` (its environment this process's plus `environment`), ended after.
    private func withProcess<T>(_ arguments: [String], environment: [String: String] = [:], _ body: (pid_t) async throws -> T) async throws -> T {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        defer {
            for child in Platform.Processes.children(process.processIdentifier) { kill(child, SIGKILL) }
            process.terminate()
        }
        return try await body(process.processIdentifier)
    }

    /// `facts` with its ancestry cut to the peer itself: here the test process is the server (`Requests` runs in it),
    /// and a peer it started runs under the server, which the rule refuses first; cut, the line under test decides.
    private func alone(_ facts: PeerFacts) -> PeerFacts {
        var facts = facts
        facts.ancestry = facts.ancestry.map { Array($0.prefix(1)) }
        return facts
    }

    private func refused(_ world: CardWorld, _ card: CardStore.Card, from facts: PeerFacts, saying words: String) async throws {
        let action = UUID().uuidString.lowercased()
        let reply = try #require(await world.answer(card, "Yes", action: action, from: facts))
        #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(reply)")
        #expect(reply.error?.message.contains(words) == true, "\(reply)")
        #expect(world.board().questions.first?.answer == nil)
        #expect(await world.actions().filter { $0.action == action }.isEmpty)
        #expect(world.card(card.id)?.isOpen == true)
    }

    @Test func anAnswerFromASessionsProcessIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let card = try await card(world)
        let session = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Worker · parser")
        try #require(await eventually(timeout: 60) { world.queue.sync { world.world.link.sessions.contains { $0.id == session.id && $0.isLive } } })
        try await refused(world, card, from: PeerFacts.read(pid: session.childPID), saying: "live session")
    }

    @Test func anAnswerFromAProcessCarryingASessionMarkerIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let card = try await card(world)
        try await withProcess(["/bin/sleep", "60"], environment: [PeerFacts.sessionMarkerName: "1"]) { pid in
            // Read once it runs `sleep` (before its exec it is this process's copy).
            #expect(await eventually(timeout: 30) { Platform.Processes.arguments(pid) == ["/bin/sleep", "60"] })
            let facts = PeerFacts.read(pid: pid)
            #expect(facts.sessionMarker == true)
            try await refused(world, card, from: alone(facts), saying: PeerFacts.sessionMarkerName)
        }
    }

    @Test func anAnswerFromBranchCodeIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let card = try await card(world)
        // A command under the branch code runner, as merge and an audit run a branch's tests.
        let runner = Platform.Tools.branchShell + ["-c", "\"$@\"; exit $?", "vibeswitcher-branch-code", "/bin/sleep", "60"]
        try await withProcess(runner) { pid in
            // Its command, once the runner started it and it runs `sleep`.
            #expect(await eventually(timeout: 30) {
                Platform.Processes.children(pid).contains { Platform.Processes.arguments($0) == ["/bin/sleep", "60"] }
            })
            let child = try #require(Platform.Processes.children(pid).first { Platform.Processes.arguments($0) == ["/bin/sleep", "60"] })
            let facts = PeerFacts.read(pid: child)
            #expect(facts.underRunner == true)
            try await refused(world, card, from: alone(facts), saying: "branch code")
        }
    }
}
