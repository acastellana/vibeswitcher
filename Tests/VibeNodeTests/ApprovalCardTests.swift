import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The user's answer approving a held merge (the app's `LeadApprovalAnswerTests`, ported to the engine's cards; the
/// engine plan's E6): recorded on the board and in the vault for the task whose branch is at that commit, where merge
/// looks for it, and the approval card's facts built from git and the vault, never the board (the security architecture
/// document's S3). A scratch host, its repository with a task branch, and the lead's tool server's post of the question.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct ApprovalCardTests {
    private let scratch = Scratch()

    @Test func yourApprovalIsRecordedInTheVaultForTheTaskAtThatCommit() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let commit = try await taskBranch(world.repo, task: "change")
        let lead = try await world.sleepingLead()
        let approval = LeadWorkflow.approval(of: commit)
        let vault = world.host.vault

        let notYet = try await world.asked("Merge change?", options: [approval, "Not yet"], priority: .blocking, lead: lead)
        #expect(notYet.card.kind == .approval)
        let first = try #require(await world.answer(notYet.card, "Not yet"))
        #expect(first.ok, "\(first)")
        #expect(world.board().questions.first { $0.id == notYet.question.id }?.answer == "Not yet")
        #expect(try await offPool { try vault.approved(root: world.repo, task: "change", commit: commit) } == false)

        let asked = try await world.asked("Merge change?", options: [approval, "Not yet"], priority: .blocking, lead: lead)
        let reply = try #require(await world.answer(asked.card, approval))
        #expect(reply.ok, "\(reply)")
        #expect(try await offPool { try vault.approved(root: world.repo, task: "change", commit: commit) })
        #expect(reply.result?["notice"] == .null, "\(reply)")
        #expect(world.card(asked.card.id)?.notice == nil)
        // Bound to the task and the commit.
        #expect(try await offPool { try vault.approved(root: world.repo, task: "other", commit: commit) } == false)
        #expect(try await offPool { try vault.approved(root: world.repo, task: "change", commit: String(repeating: "0", count: 40)) } == false)
    }

    @Test func anApprovalOfACommitNoTaskIsAtSaysItWasntRecorded() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        try await taskBranch(world.repo, task: "change")
        let lead = try await world.sleepingLead()
        let nowhere = LeadWorkflow.approval(of: String(repeating: "0", count: 40))
        let asked = try await world.asked("Merge change?", options: [nowhere, "Not yet"], priority: .blocking, lead: lead)
        let reply = try #require(await world.answer(asked.card, nowhere))
        #expect(reply.result?["notice"]?.string?.contains("wasn't recorded") == true, "\(reply)")
        #expect(world.card(asked.card.id)?.notice?.contains("wasn't recorded") == true)
        #expect(world.board().questions.first { $0.id == asked.question.id }?.answer == nowhere)
    }

    @Test func aVaultThatRefusesTheApprovalSaysSo() async throws {
        // The vault as it answers anything but the app.
        let refusing = LeadVault.Book().vault(folder: scratch.url("vault"), as: { .unknown })
        let world = try await CardWorld.make(scratch, vault: { _ in refusing })
        defer { world.stop() }
        let commit = try await taskBranch(world.repo, task: "change")
        let lead = try await world.sleepingLead()
        let approval = LeadWorkflow.approval(of: commit)
        let asked = try await world.asked("Merge change?", options: [approval, "Not yet"], priority: .blocking, lead: lead)
        let reply = try #require(await world.answer(asked.card, approval))
        #expect(reply.result?["notice"]?.string?.contains("Your approval wasn't recorded") == true, "\(reply)")
        #expect(try await offPool { try refusing.approved(root: world.repo, task: "change", commit: commit) } == false)
        #expect(try await offPool { try world.host.vault.approved(root: world.repo, task: "change", commit: commit) } == false)
    }

    /// S3: a board whose task title, commit and files were rewritten after the post shows git's and the vault's facts,
    /// never the board's.
    @Test func anApprovalCardIsBuiltFromGitAndTheVault() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let commit = try await taskBranch(world.repo, task: "change", file: "parser.swift", subject: "Add the parser")
        let lead = try await world.sleepingLead()
        // The vault records workflow.md's sensitive paths (as the lead's configure does): the card names what it touches.
        let workflow = ConfigHoldStore.workflowPath(root: world.repo)
        try "---\nsensitive_paths: parser.swift\n---\n".write(toFile: workflow, atomically: true, encoding: .utf8)
        let value = LeadVault.guardedValue("sensitive_paths", in: LeadWorkflow.load(from: workflow))
        let vault = world.host.vault
        try await offPool { try vault.setGuardedSettings(["sensitive_paths": LeadVault.hash(value)], root: world.repo) }
        try BoardStore(root: world.repo).update { board in
            board.tasks.append(LeadTask(slug: "change", title: "Add the parser", contract: LeadContract(goal: "A parser.", acceptance: [], boundaries: [], context: "")))
        }
        let asked = try await world.asked("Merge change?", options: [LeadWorkflow.approval(of: commit), "Not yet"], priority: .blocking, lead: lead)
        #expect(await eventually(timeout: 60) { world.card(asked.card.id)?.approval?.tasks == ["change"] })

        // A session rewrites the board: the task's title, a commit and files of its own.
        try BoardStore(root: world.repo).update { board in
            board.tasks = board.tasks.map { task in
                var task = task
                task.title = "Harmless typo fix"
                return task
            }
            board.questions = board.questions.map { question in
                var question = question
                question.text = "Merge the typo fix (README only)?"
                return question
            }
        }
        let facts = try #require(world.card(asked.card.id)?.approval)
        #expect(facts.commit == commit)
        #expect(facts.tasks == ["change"])
        #expect(facts.subject == "Add the parser")
        #expect(facts.files == ["parser.swift"])
        #expect(facts.diffstat.contains("1 file changed"), "\(facts.diffstat)")
        #expect(facts.base == "main")
        #expect(facts.sensitive == ["parser.swift"])
        let listed = try #require(await world.ask("questions"))
        let shown = CardText.lines(try #require(listed.result?["cards"]?.array?.first)).joined(separator: "\n")
        #expect(!shown.contains("typo") && !shown.contains("README only"), "\(shown)")
        #expect(shown.contains("Add the parser") && shown.contains("parser.swift") && shown.contains(commit), "\(shown)")
        #expect(shown.contains("the lead asks (its words, not VibeSwitcher's): Merge change?"), "\(shown)")
    }
}
