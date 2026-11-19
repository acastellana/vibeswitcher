import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The security architecture document's S3 for answers: an answer from a session's process, from a process carrying a
/// session's marker, or from branch code is not the user's voice, whatever code it types. Each sender is a real process
/// read from `/proc` (`PeerFacts.read`), as the server reads every request's sender; nothing is recorded or answered.
///
/// And a web page's draft (the live plan's F3, LW-D6): only `vibeswitcher answer CARD` on a terminal, the card and the
/// draft shown whole before the card's code is typed, makes it the user's answer. Those cases run the built command
/// line on a pty against a `ScratchNode` whose server's web is on, a lead asking through its tool server
/// (`askingLead`), and a page's WebSocket leaving the draft.
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

    // MARK: A draft taken on the command line (F3)

    /// A scratch node with its web on, a lead asking "Name the parser?", and a page paired with it following `cards`.
    private func drafting() async throws -> (node: ScratchNode, lead: ScratchNode.AskingLead, page: LivePage) {
        let node = try await ScratchNode(scratch, hostArguments: LiveScratch.webArguments)
        do {
            let lead = try await node.askingLead("Name the parser?", options: ["Parser", "Reader"])
            let opened = try LiveScratch.open(node)
            let page = try LivePage(port: opened.port)
            _ = try page.send("auth", ["pair": .string(opened.code), "client": .string("test")])
            let hello = try #require(try page.next())
            #expect(hello["kinds"]?.array?.contains(.string("draft")) == true, "\(hello)")
            _ = try page.send("subscribe", ["sub": .string("s3"), "collection": .string("cards")])
            _ = try #require(try page.until { $0["kind"]?.string == "snapshot" }, "no snapshot: \(node.said)")
            return (node, lead, page)
        } catch {
            node.stop()
            throw error
        }
    }

    /// The page leaves `text` as the draft on `card` (the question's first version): the ack.
    private func draft(_ page: LivePage, card: String, _ text: String) throws -> NodeWire.Value {
        let id = try page.send("draft", ["card": .string(card), "text": .string(text), "version": .int(1)], action: UUID().uuidString.lowercased())
        return try #require(try page.until { $0["re"]?.string == id }?.last, "no reply to the draft")
    }

    /// The vault's record of the user's actions on `node`'s host.
    private func actions(_ node: ScratchNode) async throws -> [LeadVaultV2.UserAction] {
        let vault = LeadVaultV2Client { [socket = node.socket] request in
            guard case .vaultV2(let reply) = try HostCall.request(.vaultV2(request), socket: socket, appKey: nil, timeout: 10) else {
                throw LeadVaultV2Client.Refused("the host answered something else")
            }
            return reply
        }
        return try await offPool { try vault.userActions() }
    }

    /// `vibeswitcher answer CARD` with no text takes the page's draft: the code typed, `answer` is sent with the
    /// draft's words, recorded in the vault as the user's, the lead's board answered with them, and the card closes
    /// on the page with its draft off.
    @Test func anAnswerWithNoTextTakesTheDraft() async throws {
        let (node, lead, page) = try await drafting()
        defer { node.stop() }
        let ack = try draft(page, card: lead.card, "Reader, as the docs call it")
        #expect(ack["ok"]?.bool == true, "\(ack)")
        let answered = try await node.runOnTerminal(["answer", String(lead.card.dropFirst("local:card:".count).prefix(8))])
        #expect(answered.status == 0 && answered.output.contains("answered: the lead is told"), "\(answered.output)\n\(node.said)")
        #expect(BoardStore(root: lead.repo.path).load().questions.first?.answer == "Reader, as the docs call it")
        let recorded = try await actions(node)
        #expect(recorded.contains { $0.kind == "answer" && $0.subject == lead.card }, "\(recorded)")
        let closed = try page.until { frame in
            frame["changes"]?.array?.contains { $0["id"]?.string == lead.card && $0["value"]?["open"]?.bool == false } == true
        }
        let change = try #require(closed?.last?["changes"]?.array?.first { $0["id"]?.string == lead.card }, "the card never closed on the page")
        #expect(change["value"]?["draft"] == .null && change["value"]?["question"]?["answer"]?.string == "Reader, as the docs call it", "\(change)")
        #expect(page.unsound.isEmpty, "\(page.unsound)")
    }

    /// The card as the engine built it and the draft are printed whole and inert before the code is asked: a draft
    /// longer than any shortened line, with an escape sequence in it, is there to its last word, the sequence not
    /// raw; and with the code not typed nothing is sent: the card stays open with its draft, the vault records nothing.
    @Test func theDraftIsShownWholeBeforeTheCode() async throws {
        let (node, lead, page) = try await drafting()
        defer { node.stop() }
        let text = "Reader \u{1B}]0;owned\u{07}" + String(repeating: "and keep the lexer apart ", count: 30) + "THE END"
        #expect(try draft(page, card: lead.card, text)["ok"]?.bool == true)
        let run = try await node.runOnTerminal(["answer", lead.card]) { _ in "NOPE" }
        #expect(run.status != 0, "\(run.output)")
        let asked = try #require(run.output.range(of: "Type "), "the code was never asked: \(run.output)")
        let shown = String(run.output[..<asked.lowerBound])
        #expect(shown.contains("Name the parser?"), "the card wasn't shown first: \(run.output)")
        #expect(shown.contains("THE END") && shown.contains(String(repeating: "and keep the lexer apart ", count: 30)), "the draft wasn't shown whole: \(run.output)")
        #expect(!run.output.contains("\u{1B}]0;owned"), "the draft reached the terminal raw: \(run.output)")
        let status = try WireClient.reply(WireClient(node).request("questions", args: ["all": .bool(true)]))
        let card = try #require(status?.result?["cards"]?.array?.first { $0["id"]?.string == lead.card })
        #expect(card["open"]?.bool == true && card["draft"]?["text"]?.string == text, "\(card)")
        let recorded = try await actions(node)
        #expect(!recorded.contains { $0.kind == "answer" }, "\(recorded)")
    }

    /// No draft on the card and no text given: a usage error that names what's missing, before any code is asked.
    @Test func noDraftAndNoTextIsAUsageError() async throws {
        let (node, lead, _) = try await drafting()
        defer { node.stop() }
        let run = try await node.runOnTerminal(["answer", lead.card])
        #expect(run.status == 64, "\(run.output)")
        #expect(run.output.contains("has no draft") && run.output.contains("usage: vibeswitcher answer CARD [TEXT]"), "\(run.output)")
        #expect(!run.output.contains("Type "), "a code was asked: \(run.output)")
        let bare = try await node.runOnTerminal(["answer"])
        #expect(bare.status == 64 && bare.output.contains("usage: vibeswitcher answer CARD [TEXT]"), "\(bare.output)")
    }
}
