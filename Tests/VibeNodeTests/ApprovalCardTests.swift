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

    /// The E6 review: a revision that offers another commit's approval shows that commit's facts, never the first one's
    /// beside the new wording; a question revised to offer an approval becomes an approval card; and an answer approving a
    /// commit the card doesn't show is refused, recording nothing.
    @Test func aRevisedApprovalShowsTheNewCommitsFactsAndApprovesOnlyThat() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let first = try await taskBranch(world.repo, task: "first", file: "one.txt", subject: "First change")
        let second = try await taskBranch(world.repo, task: "second", file: "two.txt", subject: "Second change")
        let lead = try await world.sleepingLead()
        try await world.acceptBase()
        let vault = world.host.vault

        let asked = try await world.asked("Merge?", options: [LeadWorkflow.approval(of: first), "Not yet"], priority: .blocking, lead: lead)
        #expect(await eventually(timeout: 60) { world.card(asked.card.id)?.approval?.tasks == ["first"] })
        let revised = try await world.revise(asked.question.id, text: "Merge?", options: [LeadWorkflow.approval(of: second), "Not yet"], note: "the other one", lead: lead)
        #expect(try #require(revised.reply).ok)
        #expect(world.card(asked.card.id)?.approval?.commit == second)
        #expect(await eventually(timeout: 60) { world.card(asked.card.id)?.approval?.tasks == ["second"] }, "\(String(describing: world.card(asked.card.id)?.approval))")
        let facts = try #require(world.card(asked.card.id)?.approval)
        #expect(facts.subject == "Second change" && facts.files == ["two.txt"], "\(facts)")

        // The commit the card no longer shows: refused, nothing on the board or in the vault.
        let current = try #require(world.card(asked.card.id))
        let stale = try #require(await world.answer(current, LeadWorkflow.approval(of: first)))
        #expect(stale.error?.code == NodeWire.Code.refused.rawValue, "\(stale)")
        #expect(world.board().questions.first { $0.id == asked.question.id }?.state == .open)
        #expect(try await offPool { try vault.approved(root: world.repo, task: "first", commit: first) } == false)
        let reply = try #require(await world.answer(current, LeadWorkflow.approval(of: second)))
        #expect(reply.ok, "\(reply)")
        #expect(try await offPool { try vault.approved(root: world.repo, task: "second", commit: second) })

        // A question first posted with no approval, revised to offer one: an approval card with that commit's facts.
        let plain = try await world.asked("Anything else?", options: ["No"], lead: lead)
        #expect(plain.card.kind == .question)
        let offered = try await world.revise(plain.question.id, text: "Merge the first?", options: [LeadWorkflow.approval(of: first), "No"], note: "ready", lead: lead)
        #expect(try #require(offered.reply).ok)
        #expect(world.card(plain.card.id)?.kind == .approval)
        #expect(await eventually(timeout: 60) { world.card(plain.card.id)?.approval?.tasks == ["first"] })
        // An approval typed on a question card that shows no commit is refused too.
        let other = try await world.asked("Which name?", options: ["A", "B"], lead: lead)
        let typed = try #require(await world.answer(other.card, LeadWorkflow.approval(of: second)))
        #expect(typed.error?.code == NodeWire.Code.refused.rawValue, "\(typed)")
    }

    /// The engine sweep's review: a revision's post carries what the lead gave, never the board's question. A worker
    /// that writes an "Approve <its commit>" option, its own text and revisions into the open question in `board.json`
    /// before the lead's text-only (then options-only) revise gets none of it onto the card: the card keeps its own
    /// options (then text), its kind and its versions, and the user's approval of that commit is refused, recording
    /// nothing in the vault.
    @Test func aRevisionTakesNoOptionTextOrRevisionsFromTheBoard() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let commit = try await taskBranch(world.repo, task: "sneak", file: "hook.sh", subject: "Add a hook")
        let lead = try await world.sleepingLead()
        try await world.acceptBase()
        let vault = world.host.vault
        let asked = try await world.asked("Name it Parser?", options: ["Parser", "Reader"], lead: lead)
        let approve = LeadWorkflow.approval(of: commit)
        try BoardStore(root: world.repo).update { board in
            let index = try board.questionIndex(asked.question.id)
            board.questions[index].options.append(approve)
            board.questions[index].text = "Merge the hook now?"
            board.questions[index].revisions = Array(repeating: LeadQuestion.Revision(text: "x", options: [], note: "y"), count: 5)
        }
        let byText = try await world.revise(asked.question.id, text: "Name it Parser, or Reader?", options: nil, note: "clearer", lead: lead)
        #expect(byText.board.options.contains(approve), "the board keeps the worker's option: \(byText.board)")
        #expect(try #require(byText.reply).ok)
        var card = try #require(world.card(asked.card.id))
        #expect(card.kind == .question && card.approval == nil, "\(card)")
        #expect(card.question?.options == ["Parser", "Reader"] && card.question?.text == "Name it Parser, or Reader?", "\(String(describing: card.question))")
        #expect(card.question?.version == 2 && card.question?.revisions?.first?.text == "Name it Parser?", "\(String(describing: card.question))")

        // Options alone: the card's own text stays, whatever the board says.
        try BoardStore(root: world.repo).update { board in
            board.questions[try board.questionIndex(asked.question.id)].text = "Merge the hook now?"
        }
        let byOptions = try await world.revise(asked.question.id, text: nil, options: ["Parser", "Lexer"], note: "Reader is taken", lead: lead)
        #expect(try #require(byOptions.reply).ok)
        card = try #require(world.card(asked.card.id))
        #expect(card.kind == .question && card.question?.text == "Name it Parser, or Reader?" && card.question?.options == ["Parser", "Lexer"],
                "\(String(describing: card.question))")
        #expect(card.question?.version == 3)

        let typed = try #require(await world.answer(card, approve))
        #expect(typed.error?.code == NodeWire.Code.refused.rawValue, "\(typed)")
        #expect(try await offPool { try vault.approved(root: world.repo, task: "sneak", commit: commit) } == false)
    }

    /// The security follow-ups' item 14: the base an approval card's files and diffstat are taken against is workflow.md's
    /// `base_branch` only while the vault records it as the user's accept, never the board's: a worker that names the
    /// task's own branch as the base (so the card would show nothing changed) gets a problem on the card, not a shrunk
    /// diff; and a base named like an option, even one the vault records, is never read as one by git.
    @Test func anApprovalCardTakesOnlyTheBaseTheUserAccepted() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let commit = try await taskBranch(world.repo, task: "change", file: "parser.swift", subject: "Add the parser")
        let lead = try await world.sleepingLead()
        try await world.acceptBase()
        let workflow = ConfigHoldStore.workflowPath(root: world.repo)
        func facts(_ question: String) async throws -> CardStore.ApprovalFacts {
            let asked = try await world.asked(question, options: [LeadWorkflow.approval(of: commit), "Not yet"], priority: .blocking, lead: lead)
            try #require(await eventually(timeout: 60) { world.card(asked.card.id)?.approval?.subject != nil })
            return try #require(world.card(asked.card.id)?.approval)
        }
        // The board names the task's own branch as the base: not taken; the base the user accepted is the main branch.
        try BoardStore(root: world.repo).update { $0.baseBranch = "agent/change" }
        let fromBoard = try await facts("Merge change?")
        #expect(fromBoard.base == "main" && fromBoard.files == ["parser.swift"], "\(fromBoard)")
        // workflow.md names it, but the vault records the main branch as the user's: a problem on the card, no files.
        try "---\nbase_branch: agent/change\n---\n".write(toFile: workflow, atomically: true, encoding: .utf8)
        let rewritten = try await facts("Merge change now?")
        #expect(rewritten.base == nil && rewritten.files.isEmpty && rewritten.diffstat.isEmpty, "\(rewritten)")
        #expect(rewritten.problems.contains { $0.contains("isn't the one the user accepted") }, "\(rewritten.problems)")
        // An option for a name (git's --output writes a file), even recorded as accepted: no branch, and no file written.
        let out = scratch.url("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let injected = out.appendingPathComponent("injected").path
        let option = "--output=\(injected)"
        try "---\nbase_branch: \(option)\n---\n".write(toFile: workflow, atomically: true, encoding: .utf8)
        try #require(LeadWorkflow.load(from: workflow).baseBranch == option)
        try await world.acceptBase(option)
        let asOption = try await facts("Merge change at last?")
        #expect(asOption.files.isEmpty && asOption.problems.contains { $0.contains("isn't a branch") }, "\(asOption)")
        let written = try FileManager.default.contentsOfDirectory(atPath: out.path)
        #expect(written.isEmpty, "\(written)")
    }

    /// The close-out review of item 14: the card's files and diffstat are taken against the head the vault records for
    /// the base, never wherever `refs/heads/<base>` points now (any process of the user's can move it through the shared
    /// .git). A base moved onto the task's own commit still shows what the task changes, and the card says it moved.
    @Test func anApprovalCardDiffsAgainstTheHeadTheVaultRecords() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let commit = try await taskBranch(world.repo, task: "change", file: "parser.swift", subject: "Add the parser")
        let lead = try await world.sleepingLead()
        try await world.acceptBase()
        let recorded = try await scratchGit(world.repo, ["rev-parse", "refs/heads/main"])
        // A worker moves main onto the task's commit.
        try await scratchGit(world.repo, ["update-ref", "refs/heads/main", commit])
        let asked = try await world.asked("Merge change?", options: [LeadWorkflow.approval(of: commit), "Not yet"], priority: .blocking, lead: lead)
        #expect(await eventually(timeout: 60) { world.card(asked.card.id)?.approval?.subject != nil })
        let facts = try #require(world.card(asked.card.id)?.approval)
        #expect(facts.base == "main" && facts.files == ["parser.swift"] && facts.diffstat.contains("1 file changed"), "\(facts)")
        #expect(facts.problems.contains { $0.contains("moved") && $0.contains(String(recorded.prefix(8))) }, "\(facts.problems)")
    }

    /// The close-out review of item 14: with workflow.md naming no base (the template's), the card takes the branch the
    /// lead merges into, the one it started on, which the vault records a head for (here develop), not the main
    /// branch: develop's own commits aren't shown as part of this merge.
    @Test func anEmptyBaseBranchTakesTheBranchTheLeadStartedOn() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        try await scratchGit(world.repo, ["checkout", "-q", "-b", "develop"])
        try "develop's own\n".write(toFile: (world.repo as NSString).appendingPathComponent("develop.txt"), atomically: true, encoding: .utf8)
        try await scratchGit(world.repo, ["add", "--", "develop.txt"])
        try await scratchGit(world.repo, ["commit", "-q", "-m", "On develop"])
        // The task branches from develop (`taskBranch` goes back to main after).
        let commit = try await taskBranch(world.repo, task: "change", file: "parser.swift", subject: "Add the parser")
        let lead = try await world.sleepingLead(branch: "develop")
        try BoardStore(root: world.repo).update { $0.baseBranch = "develop" }
        try await world.acceptBase()
        let asked = try await world.asked("Merge change?", options: [LeadWorkflow.approval(of: commit), "Not yet"], priority: .blocking, lead: lead)
        #expect(await eventually(timeout: 60) { world.card(asked.card.id)?.approval?.subject != nil })
        let facts = try #require(world.card(asked.card.id)?.approval)
        #expect(facts.base == "develop" && facts.files == ["parser.swift"], "\(facts)")
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
        try await world.acceptBase()
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
