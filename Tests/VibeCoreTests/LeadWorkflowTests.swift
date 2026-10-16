import Foundation
import Testing
@testable import VibeCore

struct LeadWorkflowTests {
    @Test func frontMatterSetsTheLimitsAndTheRestIsNotes() {
        let workflow = LeadWorkflow.parse("---\nmax_workers: 2\ntest_command: swift test\ninit_command: \"swift build\"\nverifier_model: sonnet\n---\nPrefer small PRs.")
        #expect(workflow.maxWorkers == 2)
        #expect(workflow.testCommand == "swift test")
        #expect(workflow.initCommand == "swift build")
        #expect(workflow.verifierModel == "sonnet")
        #expect(workflow.notes == "Prefer small PRs.")
    }

    @Test func defaultsAndTheTemplate() {
        let empty = LeadWorkflow.parse("")
        #expect(empty.maxWorkers == 3)
        #expect(empty.testCommand == nil)
        #expect(LeadWorkflow.parse(LeadWorkflow.template).maxWorkers == 3)
        #expect(LeadWorkflow.parse("---\nmax_workers: 0\n---").maxWorkers == 1)
    }

    let task = LeadTask(slug: "add-login", title: "Add login",
                        contract: LeadContract(goal: "Users can log in with email", acceptance: ["swift test passes", "LoginTests cover bad passwords"],
                                               boundaries: ["only Sources/Auth"], context: "We use Keychain."))

    @Test func theLeadsPromptCarriesThePlaybook() {
        let prompt = LeadPrompts.lead(project: "acme", root: "/r", workflow: LeadWorkflow.parse("---\nmax_workers: 2\n---"))
        for needle in ["acme", "never write code", "at most 2 workers", "audit", "merge", "ask_user", "board", "Don't wait"] {
            #expect(prompt.localizedCaseInsensitiveContains(needle), "missing \(needle)")
        }
    }

    @Test func workerAndVerifierPromptsCarryTheContract() {
        let worker = LeadPrompts.worker(task: task, root: "/r", workflow: LeadWorkflow.parse("---\ninit_command: make\ntest_command: make test\n---"))
        for needle in ["Users can log in with email", "LoginTests cover bad passwords", "only Sources/Auth", "agent/add-login", "make test", "Keychain"] {
            #expect(worker.contains(needle), "missing \(needle)")
        }
        let verifier = LeadPrompts.verifier(task: task, root: "/r", workflow: LeadWorkflow.parse(""))
        for needle in ["read-only", "submit_audit", "Users can log in with email", "violation"] {
            #expect(verifier.localizedCaseInsensitiveContains(needle), "missing \(needle)")
        }
    }
}
