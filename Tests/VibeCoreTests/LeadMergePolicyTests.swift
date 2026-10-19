import Foundation
import Testing
@testable import VibeCore

/// The owner's merge policy: set once in workflow.md, followed by the lead's prompt, enforced by merge with the user's
/// approval bound to one commit.
struct LeadMergePolicyTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func commit(_ file: String, _ text: String, in dir: String) throws {
        let path = dir + "/" + file
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: dir)
        Git.run(["commit", "-q", "-m", "change \(file)"], in: dir)
    }

    /// A task whose worker committed `file` and whose audit passed; returns the audited commit.
    @discardableResult
    func audited(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String, file: String) throws -> String {
        if BoardStore(root: root).load().task("change") == nil {
            _ = lead.call("add_task", ["title": "Change", "goal": "it changes", "acceptance": ["it's there"]])
            _ = lead.call("start_worker", ["task": "change"])
        }
        try commit(file, "\(UUID())\n", in: Worktrees.path(root: root, slug: "change"))
        _ = try seat("worker-change", runtime).call("report", ["status": "done", "summary": "changed"])
        #expect(!lead.call("audit", ["task": "change"]).isError)
        #expect(!(try seat("verify-change", runtime)).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "ok"]).isError)
        return Git.run(["rev-parse", "agent/change"], in: root).output
    }

    /// The user answers a question in the app.
    func answer(_ root: String, _ text: String, asked: String = "Merge change?", options: [String]? = nil) throws {
        try BoardStore(root: root).update { board in
            let question = board.ask(asked, options: options ?? [text, "Not yet"], priority: .blocking, whyNow: nil, proposal: nil, decideIn: nil)
            _ = board.answer(question.id, with: text, saw: question.version)
        }
    }

    // MARK: workflow.md

    @Test func theMergePolicyIsReadFromWorkflow() {
        #expect(LeadWorkflow.parse(LeadWorkflow.template).mergePolicy == nil)
        #expect(LeadWorkflow.parse(LeadWorkflow.template).sensitivePaths == nil)
        #expect(LeadWorkflow.parse(LeadWorkflow.template).problem == nil)
        #expect(LeadWorkflow.parse("").mergePolicy == nil)
        let cases: [(String, LeadWorkflow.MergePolicy?)] = [("auto", .auto), ("ask_sensitive", .askSensitive), ("ask_all", .askAll),
                                                            ("ASK-ALL", .askAll), ("\"auto\"", .auto), ("", nil),
                                                            // One it can't read asks for everything.
                                                            ("sometimes", .askAll)]
        for (value, expected) in cases {
            #expect(LeadWorkflow.parse("---\nmerge_policy: \(value)\n---").mergePolicy == expected, "\(value)")
        }
        let workflow = LeadWorkflow.parse("---\nsensitive_paths: Sources/Auth/, *.entitlements ,, secrets\n---")
        #expect(workflow.sensitivePaths == ["Sources/Auth/", "*.entitlements", "secrets"])
        #expect(workflow.sensitiveGlobs == ["Sources/Auth/", "*.entitlements", "secrets"])
        #expect(LeadWorkflow.parse("---\nsensitive_paths:\n---").sensitiveGlobs == LeadWorkflow.defaultSensitivePaths)
    }

    @Test func sensitivePathsMatchLikeGitignore() {
        let cases: [(String, String, Bool)] = [
            (".github/workflows/ci.yml", ".github/", true),
            ("docs/.github", ".github/", false),
            ("a/b/.claude/settings.json", ".claude/", true),
            ("CLAUDE.md", "CLAUDE.md", true),
            ("docs/CLAUDE.md", "CLAUDE.md", true),
            ("CLAUDE.mdx", "CLAUDE.md", false),
            ("App/App.entitlements", "*.entitlements", true),
            (".env.local", ".env.*", true),
            ("Sources/Auth/Login.swift", "Sources/Auth", true),
            ("Sources/Authority.swift", "Sources/Auth", false),
            ("lib/Sources/Auth/x", "Sources/Auth", false),
            ("Sources/VibeCore/LeadVault.swift", "Sources/*/LeadVault*.swift", true),
            ("Sources/VibeCore/Deep/LeadVault.swift", "Sources/*/LeadVault*.swift", false),
            ("Sources/VibeCore/Deep/LeadVault.swift", "Sources/**/LeadVault.swift", true),
            ("Sources/LeadVault.swift", "Sources/**/LeadVault.swift", true),
            ("a.txt", "/a.txt", true),
            ("x/a.txt", "/a.txt", false),
            ("a+b.txt", "a+b.txt", true),
            ("aab.txt", "a+b.txt", false),
            ("anything", "", false),
        ]
        for (path, glob, expected) in cases {
            #expect(LeadWorkflow.matches(path, glob: glob) == expected, "\(path) ~ \(glob)")
        }
    }

    @Test func eachPolicySaysWhichFilesNeedTheUsersApproval() {
        let changed = ["README.md", ".github/workflows/ci.yml"]
        #expect(LeadWorkflow.parse("---\nmerge_policy: auto\n---").filesNeedingApproval(changed) == nil)
        #expect(LeadWorkflow.parse("---\nmerge_policy: ask_all\n---").filesNeedingApproval(["README.md"]) == ["README.md"])
        #expect(LeadWorkflow.parse("---\nmerge_policy: ask_sensitive\n---").filesNeedingApproval(changed) == [".github/workflows/ci.yml"])
        #expect(LeadWorkflow.parse("---\nmerge_policy: ask_sensitive\n---").filesNeedingApproval(["README.md"]) == nil)
        // Unset: handled as ask_sensitive.
        #expect(LeadWorkflow.parse("").filesNeedingApproval(changed) == [".github/workflows/ci.yml"])
        #expect(LeadWorkflow.parse("---\nmerge_policy: ask_sensitive\nsensitive_paths: README.md\n---").filesNeedingApproval(changed) == ["README.md"])
    }

    @Test func anApprovalNamesTheWholeCommitAndComesFromTheUser() {
        let commit = String(repeating: "ab", count: 20)
        var question = LeadQuestion(text: "Merge?", options: [LeadWorkflow.approval(of: commit), "Not yet"])
        #expect(!LeadWorkflow.approves(question, commit: commit))
        question.answer = "approve \(commit) "
        #expect(LeadWorkflow.approves(question, commit: commit))
        #expect(!LeadWorkflow.approves(question, commit: String(repeating: "cd", count: 20)))
        // A prefix of a commit is no approval of it.
        #expect(!LeadWorkflow.approves(question, commit: String(commit.prefix(12))))
        var other = question
        other.answer = "Approve \(commit.prefix(12))"
        #expect(!LeadWorkflow.approves(other, commit: commit))
        other.answer = "Not yet"
        #expect(!LeadWorkflow.approves(other, commit: commit))
        // Withdrawn, or its timer ran out: not the user's say.
        var withdrawn = question
        withdrawn.withdrawnAt = 1
        #expect(!LeadWorkflow.approves(withdrawn, commit: commit))
        var timedOut = question
        timedOut.autoDecidedAt = 1
        #expect(!LeadWorkflow.approves(timedOut, commit: commit))
    }

    // MARK: configure

    @Test func configureSetsTheMergePolicy() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let path = root + "/.vibeswitcher/workflow.md"
        #expect(lead.call("configure", [:]).text.contains("merge_policy: not set"))
        let set = lead.call("configure", ["merge_policy": "Ask-Sensitive", "sensitive_paths": ["Sources/Auth/", " *.pem "]])
        #expect(!set.isError, "\(set.text)")
        #expect(set.text.contains("merge_policy = `ask_sensitive`"))
        #expect(LeadWorkflow.load(from: path).mergePolicy == .askSensitive)
        #expect(LeadWorkflow.load(from: path).sensitivePaths == ["Sources/Auth/", "*.pem"])
        #expect(!lead.call("configure", ["merge_policy": "auto", "sensitive_paths": "a/, b"]).isError)
        #expect(LeadWorkflow.load(from: path).mergePolicy == .auto)
        #expect(LeadWorkflow.load(from: path).sensitivePaths == ["a/", "b"])
        let before = try String(contentsOfFile: path, encoding: .utf8)
        #expect(lead.call("configure", ["merge_policy": "sometimes"]).isError)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == before)
        // Cleared: back to unset, and the default globs.
        #expect(!lead.call("configure", ["merge_policy": "", "sensitive_paths": ""]).isError)
        #expect(LeadWorkflow.load(from: path).mergePolicy == nil)
        #expect(LeadWorkflow.load(from: path).sensitivePaths == nil)
    }

    // MARK: merge

    @Test func askSensitiveHoldsASensitiveCommitUntilTheUserApprovesThatCommit() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "ask_sensitive", "sensitive_paths": ".github/"]).isError)
        let first = try audited(lead, runtime, root: root, file: ".github/workflows/ci.yml")
        let refused = lead.call("merge", ["task": "change"])
        #expect(refused.isError)
        #expect(refused.text.contains(LeadWorkflow.approval(of: first)))
        #expect(refused.text.contains(".github/workflows/ci.yml"))
        #expect(BoardStore(root: root).load().task("change")?.status != .done)
        // Not yet, or an approval of another commit, doesn't merge it.
        try answer(root, "Not yet", options: [LeadWorkflow.approval(of: first), "Not yet"])
        try answer(root, LeadWorkflow.approval(of: String(repeating: "0", count: 40)))
        #expect(lead.call("merge", ["task": "change"]).isError)

        // The user approves that commit; then the worker commits once more: the approval doesn't cover the new one.
        try answer(root, LeadWorkflow.approval(of: first))
        let second = try audited(lead, runtime, root: root, file: ".github/workflows/ci.yml")
        #expect(second != first)
        let again = lead.call("merge", ["task": "change"])
        #expect(again.isError)
        #expect(again.text.contains(LeadWorkflow.approval(of: second)))

        try answer(root, LeadWorkflow.approval(of: second))
        let merged = lead.call("merge", ["task": "change"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(BoardStore(root: root).load().task("change")?.status == .done)
    }

    @Test func askSensitiveMergesOtherCommitsWithoutAsking() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "ask_sensitive"]).isError)
        try audited(lead, runtime, root: root, file: "b.txt")
        let merged = lead.call("merge", ["task": "change"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(BoardStore(root: root).load().questions.isEmpty)
    }

    @Test func anUnsetPolicyHoldsSensitiveCommitsAndSaysToAskTheOwner() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try audited(lead, runtime, root: root, file: "CLAUDE.md")
        let refused = lead.call("merge", ["task": "change"])
        #expect(refused.isError)
        #expect(refused.text.contains("no merge_policy is set"))
    }

    @Test func askAllHoldsEveryCommit() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "ask_all"]).isError)
        let commit = try audited(lead, runtime, root: root, file: "b.txt")
        #expect(lead.call("merge", ["task": "change"]).isError)
        try answer(root, LeadWorkflow.approval(of: commit))
        let merged = lead.call("merge", ["task": "change"])
        #expect(!merged.isError, "\(merged.text)")
    }

    @Test func autoNeverAsks() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto"]).isError)
        try audited(lead, runtime, root: root, file: ".claude/settings.json")
        let merged = lead.call("merge", ["task": "change"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(BoardStore(root: root).load().task("change")?.status == .done)
        #expect(BoardStore(root: root).load().questions.isEmpty)
    }

    // MARK: post_update

    @Test func updatesGoIntoTheProgressLog() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(!lead.call("post_update", ["title": "Retrospective: merges", "body": "Went well: audits.\nWent wrong: two conflicts."]).isError)
        let log = try String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)
        #expect(log.contains("Update: Retrospective: merges — Went well: audits."))
        #expect(!log.contains("two conflicts"))
    }

    // MARK: The lead's prompt

    @Test func theLeadAsksForThePolicyOnceThenFollowsIt() {
        let unset = LeadPrompts.lead(project: "acme", root: "/r", workflow: LeadWorkflow.parse(""))
        for needle in ["hasn't chosen", "once, early", "ask_user", "auto", "ask_sensitive", "ask_all", "proposal",
                       "configure (merge_policy)", "record_decision", "never ask it again"] {
            #expect(unset.contains(needle), "unset: missing \(needle)")
        }
        let auto = LeadPrompts.lead(project: "acme", root: "/r", workflow: LeadWorkflow.parse("---\nmerge_policy: auto\n---"))
        #expect(!auto.contains("hasn't chosen"))
        for needle in ["follow it and don't ask the user about each merge", "auto", "post_update", "how it was checked", "the risk", "revert"] {
            #expect(auto.contains(needle), "auto: missing \(needle)")
        }
        let sensitive = LeadPrompts.lead(project: "acme", root: "/r", workflow: LeadWorkflow.parse("---\nmerge_policy: ask_sensitive\nsensitive_paths: Sources/Auth/\n---"))
        for needle in ["don't ask the user about each merge", "ask_sensitive", "Sources/Auth/", "Approve <the full commit>", "that commit only"] {
            #expect(sensitive.contains(needle), "ask_sensitive: missing \(needle)")
        }
    }

    @Test func theLeadChecksInAndRunsRetrospectives() {
        let prompt = LeadPrompts.lead(project: "acme", root: "/r", workflow: LeadWorkflow.parse("---\nmerge_policy: auto\n---"))
        for needle in ["Check in", "every few merges", "couple of hours", "what landed", "what's stuck", "what you plan next",
                       "one open question", "retrospective", "same kind of setback happens twice", "what went well", "what went wrong",
                       "failed audits", "reverted merges", "stranded workers", "the user's complaints", "add_task", "a check",
                       "Retrospective:", "progress log", "record_decision"] {
            #expect(prompt.localizedCaseInsensitiveContains(needle), "missing \(needle)")
        }
    }
}
