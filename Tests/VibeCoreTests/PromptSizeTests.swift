import Testing
@testable import VibeCore

/// Every rule added to a role's prompt is paid for in every session that role starts, and nothing limited these prompts
/// (the repository reviews, idea 6: docs/process/reviews/google-elephant-goldfish-model.md). Each role's rendered prompt
/// has a ceiling here, set at its size on 2026-11-12 plus 10%, so growing one past it is a decision someone makes in this
/// file, which the audit of the change sees, rather than drift.
struct PromptSizeTests {
    /// The ceilings, in UTF-8 bytes of the rendered prompt. Raising one is a deliberate one-line change: say why in the
    /// commit, and trim before raising where a rule can go.
    static let ceilings: [Role: Int] = [
        .lead: 18_572,  // 16_884 on 2026-11-12, plus 10%
        .worker: 11_255,  // 10_232 on 2026-11-12, plus 10%
        .verifier: 11_602,  // 10_548 on 2026-11-12, plus 10%
    ]

    enum Role: String, CaseIterable {
        case lead, worker, verifier
    }

    /// A workflow like this repository's own `.vibeswitcher/workflow.md` (2026-11-12), so the sizes are a real project's.
    static let workflow = LeadWorkflow.parse("""
        ---
        max_workers: 4
        test_command: bash scripts/test.sh
        init_command: bash scripts/worktree-init.sh
        worker_agent: claude
        verifier_model: opus
        merge_policy: auto
        mac_max_sessions: 10
        sensitive_paths: .claude/, .mcp.json, CLAUDE.md, AGENTS.md, .github/, .env, *.entitlements, Sources/VibeHost/, Sources/VibeCore/LeadWorkflow.swift
        watch_app_logs: true
        base_branch: main
        merge_batching: always
        agent_default: auto
        auto_advance: false
        ---
        Notes for the lead: conventions, priorities, what not to touch. The lead reads this at the start of every session.
        """)

    /// A task with a contract of an ordinary size.
    static let task = LeadTask(slug: "split-layer", title: "Split the session layer", contract: LeadContract(
        goal: "The session layer is split into a reader and a writer, so a slow reader no longer holds up the writer.",
        acceptance: ["A test writes while a reader is blocked and the write lands within one tick.",
                     "bash scripts/test.sh --filter 'SessionLayer' passes."],
        boundaries: ["Sources/VibeCore/SessionLayer*.swift and its tests only.", "Don't change the wire format."],
        context: "Reported by the user on 2026-11-10: the chat froze for seconds while a long transcript loaded."))

    /// The root is a path with no repository behind it, and every input a prompt would otherwise read from this Mac (the
    /// user's policy, the Mac's limits, the repository's lint tests and sandbox script) is given, so the sizes don't
    /// depend on where the test runs. The worker gets the lints and the sandbox's screenshot rule a Swift app has.
    static let root = "/r/project"
    static let lints = ["AccessibilityLint", "AgentExportLint", "DebugAidsLint", "DocLinksLint", "ElapsedTimeLint",
                        "HomePathLint", "KeychainLint", "PreferencesLint", "PrivateNamesLint", "PrivateWriteLint",
                        "ScriptScratchLint", "SecretShapeLint", "TemporaryFolderLint"]

    static func render(_ role: Role) -> String {
        let policy = WorkingPolicy.defaultText
        switch role {
        case .lead:
            return LeadPrompts.lead(project: "project", root: root, workflow: workflow, policy: policy, limits: MacLimits())
        case .worker:
            return LeadPrompts.worker(task: task, root: root, workflow: workflow, policy: policy, lints: lints,
                                      screenshots: .some(LeadPrompts.Policy.workerScreenshots))
        case .verifier:
            return LeadPrompts.verifier(task: task, root: root, workflow: workflow, policy: policy)
        }
    }

    static func failure(_ role: Role, size: Int, ceiling: Int) -> String {
        "The \(role.rawValue)'s prompt is \(size) bytes, over its ceiling of \(ceiling) (PromptSizeTests.ceilings). Every "
            + "session of this role pays for each byte. Trim it, or raise the ceiling: a deliberate one-line change in "
            + "Tests/VibeCoreTests/PromptSizeTests.swift, with the reason in its commit."
    }

    @Test(arguments: Role.allCases)
    func eachRolesPromptStaysUnderItsCeiling(_ role: Role) throws {
        let ceiling = try #require(Self.ceilings[role], "no ceiling for the \(role.rawValue)")
        let size = Self.render(role).utf8.count
        #expect(size <= ceiling, Comment(rawValue: Self.failure(role, size: size, ceiling: ceiling)))
    }

    /// The message names the role, its size and its ceiling, and how to raise it.
    @Test func theFailureSaysWhatGrewAndHowToRaiseIt() {
        let message = Self.failure(.worker, size: 30_001, ceiling: 30_000)
        for part in ["worker", "30001 bytes", "ceiling of 30000", "deliberate one-line change", "PromptSizeTests.swift"] {
            #expect(message.contains(part), "missing \(part)")
        }
    }
}
