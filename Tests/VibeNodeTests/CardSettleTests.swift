import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// Each card says the one command that settles it (`CardStore.Card.settle`, read alike by `status`, `approve`'s
/// set-aside lines and the page), and whether it holds the team's work (`blocking`) as the engine really refuses it
/// (team-lead, 2026-11-25: the page told users to run `approve` for cards it leaves out, and a rules-only card was said
/// not to hold work while start_worker refused on its changed rule). On a scratch node, running each card's own
/// `settle` closes it.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct CardSettleTests {
    private let scratch = Scratch()

    /// The open card `match` finds (by kind and folder, or a question's words), as the page gets it.
    private func card(_ node: ScratchNode, _ match: @escaping ([String: Any]) -> Bool) async throws -> [String: Any] {
        var found: [String: Any]?
        let deadline = MacTime.real.awake() + 60
        while found == nil, MacTime.real.awake() < deadline {
            found = try await NodeAcceptanceTests.cards(node)?.values.first(where: match)
            if found == nil { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        return try #require(found, "\(node.said)")
    }

    /// `settle` run as the user would type it (its placeholder, if any, given), then the card closed.
    private func settles(_ node: ScratchNode, _ card: [String: Any], answer: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let id = try #require(card["id"] as? String, sourceLocation: sourceLocation)
        let settle = try #require(card["settle"] as? String, "\(card)", sourceLocation: sourceLocation)
        var words = settle.split(separator: " ").map(String.init)
        #expect(words.first == "vibeswitcher", "\(settle)", sourceLocation: sourceLocation)
        words.removeFirst()
        if let answer, words.last == "TEXT" { words[words.count - 1] = answer }
        // A scratch node's hooks can't be installed (its build's programs are links): the batch is the cards' alone here.
        if words == ["approve"] { words += ["--only", "config,base"] }
        let ran = try await node.runOnTerminal(words)
        #expect(ran.status == 0, "\(settle): \(ran.output)\(ran.errors)\n\(node.said)", sourceLocation: sourceLocation)
        var open = true
        let deadline = MacTime.real.awake() + 60
        while open, MacTime.real.awake() < deadline {
            open = try await NodeAcceptanceTests.cards(node)?[id] != nil
            if open { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        #expect(!open, "\(settle) left \(id) open\n\(node.said)", sourceLocation: sourceLocation)
    }

    /// Each card's settle command closes it, and blocking says what the engine refuses.
    @Test(NodeTraits.linuxOnly) func eachCardsSettleClosesIt() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let repo = try await NodeAcceptanceTests.repository(node)
        let lead = try await NodeAcceptanceTests.startLead(node, repo, goal: "write the parser")
        let root = repo.path

        // Held config approve takes: the project's settings changed (nothing to record): `vibeswitcher approve`, blocking.
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try #"{"env":{"SETTLE":"1"}}"#.write(to: repo.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        _ = try await node.run(["config", "held", root])
        let held = try await card(node) { $0["kind"] as? String == "config" && $0["root"] as? String == root }
        #expect(held["settle"] as? String == "vibeswitcher approve" && held["blocking"] as? Bool == true, "\(held)")
        try await settles(node, held)

        // A rule changed in workflow.md (start_worker and merge refuse on it), nothing held: its own accept, blocking.
        let workflow = ConfigHoldStore.workflowPath(root: root)
        let text = try String(contentsOfFile: workflow, encoding: .utf8)
        try LeadWorkflow.write(LeadWorkflow.updating(Data(text.utf8), with: [("max_workers", "2")]), to: workflow)
        _ = try await node.run(["config", "held", root])
        let rules = try await card(node) { $0["kind"] as? String == "config" && $0["root"] as? String == root }
        let id = try #require(rules["id"] as? String)
        #expect(rules["settle"] as? String == "vibeswitcher config accept \(id)" && rules["blocking"] as? Bool == true, "\(rules)")
        // `status` names it with the same command, never "approve".
        let status = try await node.run(["status"])
        #expect(status.output.contains("`vibeswitcher config accept \(id)`") && !status.output.contains("to accept: `vibeswitcher approve`"), "\(status.output)")
        try await settles(node, rules)
        // Then nothing is held and the rules are the same: no card kept, nothing waits.
        let after = try await node.run(["config", "held", root])
        #expect(after.output.contains("nothing to accept"), "\(after.output)")

        // A base move from the recorded head: `vibeswitcher approve`, blocking.
        try "moved\n".write(to: repo.appendingPathComponent("moved.txt"), atomically: true, encoding: .utf8)
        _ = Git.run(["add", "moved.txt"], in: root)
        _ = Git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "moved outside a team session"], in: root)
        _ = try await node.run(["base", "show", root])
        let base = try await card(node) { $0["kind"] as? String == "base" && $0["root"] as? String == root }
        #expect(base["settle"] as? String == "vibeswitcher approve", "\(base)")
        try await settles(node, base)

        // A question and an approval: answered.
        try lead.tools.call("ask_user", ["question": "Which name for the parser?", "options": ["Parser", "Reader"]])
        let question = try await card(node) { ($0["question"] as? [String: Any])?["text"] as? String == "Which name for the parser?" }
        let questionID = try #require(question["id"] as? String)
        #expect(question["settle"] as? String == "vibeswitcher answer \(questionID) TEXT", "\(question)")
        try await settles(node, question, answer: "Parser")
        let head = Git.run(["rev-parse", "main"], in: root).output.trimmingCharacters(in: .whitespacesAndNewlines)
        try lead.tools.call("ask_user", ["question": "Merge the parser?", "options": ["Approve \(head)", "Not yet"]])
        let approval = try await card(node) { ($0["question"] as? [String: Any])?["text"] as? String == "Merge the parser?" }
        try await settles(node, approval, answer: "Not yet")
    }

    /// `blocking` as the engine refuses: something held, a changed rule or a first look owed hold the team's work; a
    /// card that only records rules doesn't; a closed one says no command.
    @Test func blockingFollowsWhatHoldsTheWork() {
        var card = CardStore.Card(root: scratch.url("repo").path, kind: .configHeld)
        card.config = .init()
        #expect(!card.isBlocking, "nothing held, from a server before `holdsWork`")
        card.config?.holdsWork = true
        #expect(card.isBlocking, "a changed rule or a first look owed")
        card.config?.holdsWork = false
        card.config?.recordsRules = true
        #expect(!card.isBlocking && card.settle == "vibeswitcher config accept \(card.id)")
        card.closed = "accepted"
        #expect(card.settle == nil)
    }
}
