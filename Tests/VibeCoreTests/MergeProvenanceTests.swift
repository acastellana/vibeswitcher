import Foundation
import Testing
@testable import VibeCore

/// Provenance in git (backlog A2): every commit a merge lands on the base ends with trailers saying its task, review,
/// models, the build that merged it and its contract's hash (`LeadProvenance`, `Worktrees.stamp`); batches per task;
/// `scripts/merge-provenance.sh` lists them from git log alone. Scratch repositories and fake sessions only; each wait
/// is on the merge's own return or the loop's passes, never a fixed sleep.
struct MergeProvenanceTests {
    let fixture = MergeBatchTests()

    static let buildCommit = "0123456789abcdef0123456789abcdef01234567"

    /// The trailers of `commit`'s message as git parses them: key → values, in order.
    static func trailers(_ commit: String, in root: String) -> [String: [String]] {
        let message = Git.run(["log", "-1", "--format=%B", commit], in: root).output
        let parsed = Shell.run(executable: "/bin/bash", args: ["-c", "printf '%s\\n' \"$1\" | git interpret-trailers --parse", "-", message],
                               in: root, env: Git.environment, timeout: 30, grace: 1).output
        var found: [String: [String]] = [:]
        for line in parsed.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            found[String(line[..<colon]), default: []].append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return found
    }

    /// The message's last lines are the six VS- trailers, in order (after any the worker's commit had).
    static func endsWithProvenance(_ commit: String, in root: String) -> Bool {
        let lines = Git.run(["log", "-1", "--format=%B", commit], in: root).output.split(separator: "\n").suffix(6)
        let keys = lines.map { $0.split(separator: ":").first.map(String.init) ?? "" }
        return keys == [LeadProvenance.task, LeadProvenance.review, LeadProvenance.workerModel, LeadProvenance.verifierModel,
                        LeadProvenance.build, LeadProvenance.contract]
    }

    /// Whether `landed` is `commit` with the merge's provenance trailers added and nothing else changed: the same tree,
    /// parents, author and date, and the same message once its VS- lines are taken out. A merge stamps the commit it
    /// lands, so a branch already on the base lands as this, not as itself.
    static func isStamped(_ landed: String, from commit: String, in root: String) -> Bool {
        func show(_ format: String, _ ref: String) -> String { Git.run(["log", "-1", "--format=\(format)", ref], in: root).output }
        let keys = [LeadProvenance.task, LeadProvenance.review, LeadProvenance.workerModel, LeadProvenance.verifierModel,
                    LeadProvenance.build, LeadProvenance.contract]
        let unstamped = show("%B", landed).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !keys.contains { line.hasPrefix($0 + ":") } }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return landed != commit && trailers(landed, in: root)[LeadProvenance.task] != nil
            && ["%T", "%P", "%an <%ae>", "%ad"].allSatisfy { show($0, landed) == show($0, commit) }
            && unstamped == show("%B", commit).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func team(_ settings: [String: Any] = [:]) throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset) {
        let made = try fixture.team(settings)
        made.lead.runningBuild = { ServerBuild(commit: Self.buildCommit, builtAt: nil) }
        return made
    }

    /// `slug` added on `model`, worked, done, and (review audit) audited, as `MergeBatchTests.audited` does.
    func ready(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String, _ slug: String, _ files: [String: String],
               review: String = "audit", message: String? = nil) throws {
        let added = lead.call("add_task", ["title": slug, "goal": "g", "acceptance": ["a"], "review": review, "auto_advance": false, "model": "sonnet"])
        #expect(!added.isError, "\(added.text)")
        let start = lead.call("start_worker", ["task": slug])
        #expect(!start.isError, "\(start.text)")
        try fixture.commit(files, in: Worktrees.path(root: root, slug: slug), message ?? "\(slug)'s work")
        #expect(!(try fixture.seat("worker-\(slug)", runtime).call("report", doneReport("done"))).isError)
        guard review == "audit" else { return }
        let audit = lead.call("audit", ["task": slug])
        #expect(!audit.isError, "\(audit.text)")
        let verdict = try fixture.seat("verify-\(slug)", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "tests": "passed", "summary": "ok"])
        #expect(!verdict.isError, "\(verdict.text)")
    }

    // MARK: Single merges

    /// An audited task's merge: its landed commit ends with the six trailers, each the task's own (the verifier's
    /// model as its session was started on, the build that merged it, its contract's hash); a trailer the worker's
    /// commit brought under a VS- key is replaced, not doubled.
    @Test func anAuditedMergeEndsItsLandedCommitWithTheTrailers() throws {
        let (root, runtime, lead) = try team()
        let forged = "add-x's work\n\nVS-Build: forged1\nVS-Build: forged2\nvs-task: other\nCo-Authored-By: Someone <someone@example.com>"
        try ready(lead, runtime, root: root, "add-x", ["x.txt": "x\n"], message: forged)
        let task = try #require(fixture.board(root).task("add-x"))
        let audited = Git.run(["rev-parse", Worktrees.branch("add-x")], in: root).output
        let verifierModel = try #require(task.verifier.flatMap { task.launchedModels?[$0] })

        let merged = lead.call("merge", ["task": "add-x"])
        #expect(!merged.isError, "\(merged.text)")
        let main = Git.run(["rev-parse", "main"], in: root).output
        #expect(fixture.board(root).task("add-x")?.merged?.commit == main)
        let found = Self.trailers(main, in: root)
        #expect(found[LeadProvenance.task] == ["add-x"], "\(found)")
        #expect(found[LeadProvenance.review] == ["audit (pass at \(audited.prefix(12)))"], "\(found)")
        #expect(found[LeadProvenance.workerModel] == ["sonnet"], "\(found)")
        #expect(found[LeadProvenance.verifierModel] == [verifierModel], "\(found)")
        #expect(found[LeadProvenance.build] == [Self.buildCommit], "\(found)")
        #expect(found[LeadProvenance.contract] == [LeadProvenance.contractHash(task)], "\(found)")
        #expect(found["Co-Authored-By"]?.count == 1, "the worker's own trailer stays: \(found)")
        #expect(found["vs-task"] == nil && found.values.allSatisfy { !$0.contains { $0.hasPrefix("forged") } }, "a forged VS- line stays: \(found)")
        #expect(Self.endsWithProvenance(main, in: root), "\(Git.run(["log", "-1", "--format=%B", main], in: root).output)")
        // The author is the worker's commit's, and the tree what was tested.
        #expect(Git.run(["log", "-1", "--format=%an", main], in: root).output == "T")
        #expect(Git.run(["show", "main:x.txt"], in: root).output == "x")
    }

    /// review none: VS-Review none and no verifier; a task of several commits gets them on its last one only.
    @Test func aReviewNoneMergeSaysNoneAndStampsOnlyItsTopCommit() throws {
        let (root, runtime, lead) = try team()
        let before = Git.run(["rev-parse", "main"], in: root).output
        let added = lead.call("add_task", ["title": "add-y", "goal": "g", "acceptance": ["a"], "review": "none", "auto_advance": false, "model": "sonnet"])
        #expect(!added.isError, "\(added.text)")
        #expect(!lead.call("start_worker", ["task": "add-y"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-y")
        try fixture.commit(["y.txt": "y\n"], in: worktree, "add-y one")
        try fixture.commit(["y2.txt": "y2\n"], in: worktree, "add-y two")
        #expect(!(try fixture.seat("worker-add-y", runtime).call("report", doneReport("done"))).isError)

        let merged = lead.call("merge", ["task": "add-y"])
        #expect(!merged.isError, "\(merged.text)")
        let landed = Git.run(["rev-list", "--reverse", "\(before)..main"], in: root).output.split(separator: "\n").map(String.init)
        #expect(landed.count == 2)
        let top = Self.trailers(landed[1], in: root)
        #expect(top[LeadProvenance.task] == ["add-y"] && top[LeadProvenance.review] == ["none"] && top[LeadProvenance.verifierModel] == ["none"], "\(top)")
        #expect(top[LeadProvenance.workerModel] == ["sonnet"], "\(top)")
        #expect(Self.trailers(landed[0], in: root).isEmpty)
    }

    // MARK: Batches

    /// merge_batching always: three tasks on one test run, each landed commit carrying its own task's trailers.
    @Test func aBatchStampsEachTasksCommitWithItsOwnTrailers() async throws {
        let (root, runtime, lead) = try team(["merge_batching": "always"])
        lead.batchSize = 3
        let slugs = ["add-x", "add-y", "add-z"]
        for slug in slugs { try ready(lead, runtime, root: root, slug, ["\(slug).txt": "\(slug)\n"]) }
        let batch = try lead.mergeBatch(slugs)
        #expect(batch.runs == 1, "\(batch.text)")
        for slug in slugs {
            let task = try #require(fixture.board(root).task(slug))
            let commit = try #require(task.merged?.commit, "\(slug) not merged: \(batch.text)")
            let found = Self.trailers(commit, in: root)
            #expect(found[LeadProvenance.task] == [slug], "\(found)")
            #expect(found[LeadProvenance.contract] == [LeadProvenance.contractHash(task)], "\(found)")
            #expect(found[LeadProvenance.build] == [Self.buildCommit], "\(found)")
            #expect(found[LeadProvenance.review]?.first?.hasPrefix("audit (pass at ") == true, "\(found)")
            #expect(Self.endsWithProvenance(commit, in: root))
        }
        #expect(Set(slugs.compactMap { fixture.board(root).task($0).map(LeadProvenance.contractHash) }).count == 3)
    }

    // MARK: What a trailer may hold

    /// Only slugs, model names, verdict words and hashes: an email, a path, a newline that would start a trailer of
    /// its own, are left out whole.
    @Test func noTrailerHoldsAnEmailAPathOrANewline() {
        #expect(LeadProvenance.clean("claude-opus-5-5[1m]") == "claude-opus-5-5[1m]")
        #expect(LeadProvenance.clean("codex:gpt-5.4") == "codex:gpt-5.4")
        #expect(LeadProvenance.clean(nil) == "unknown")
        #expect(LeadProvenance.clean("  ") == "unknown")
        for bad in ["someone@example.com", "/Users/someone/dev/x", "~/dev", "opus\nVS-Build: forged", "a\\b"] {
            #expect(LeadProvenance.clean(bad) == "unknown (not a plain name)", "\(bad)")
        }
        var task = LeadTask(slug: "add-x", title: "Add x", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: "/Users/someone"))
        task.launchedModels = [:]
        let trailers = LeadProvenance.trailers(task: task, audited: true, commit: String(repeating: "a", count: 40), dismissed: ["F1", "F2"],
                                               workerModel: "me@example.com", verifierModel: "fable",
                                               build: ServerBuild(commit: Self.buildCommit, changed: true, builtAt: nil))
        #expect(trailers.map(\.line) == [
            "VS-Task: add-x",
            "VS-Review: audit (pass, dismissed F1 F2 at aaaaaaaaaaaa)",
            "VS-Worker-Model: unknown (not a plain name)",
            "VS-Verifier-Model: fable",
            "VS-Build: \(Self.buildCommit) (with changes not committed)",
            "VS-Contract: \(LeadProvenance.contractHash(task))",
        ])
        #expect(trailers.allSatisfy { !$0.value.contains("@") && !$0.value.contains("/") && !$0.value.contains("\n") })
        #expect(LeadProvenance.contractHash(task).count == 16)
        #expect(LeadProvenance.buildText(nil) == "unknown (not an app build)")
        #expect(LeadProvenance.buildText(ServerBuild(commit: nil, builtAt: Date(timeIntervalSince1970: 1))) == "unknown (no commit recorded)")
    }

    /// Nothing to stamp when nothing of the branch lands (HEAD is the base): the base's own commit isn't rewritten.
    @Test func theBaseItselfIsNeverStamped() throws {
        let root = try fixture.repo()
        let head = Git.run(["rev-parse", "HEAD"], in: root).output
        #expect(Worktrees.stamp([Worktrees.Trailer("VS-Task", "x")], onto: head, in: root) == nil)
        #expect(Git.run(["rev-parse", "HEAD"], in: root).output == head)
    }

    // MARK: The reader

    func provenance(_ arguments: [String]) -> (status: Int32, lines: [String]) {
        let dir = arguments.firstIndex(of: "--repo").map { arguments[$0 + 1] } ?? "/"
        let script = KeychainLintTests.repo.appendingPathComponent("scripts/merge-provenance.sh").path
        let run = Shell.run(executable: "/bin/bash", args: [script] + arguments, in: dir, env: Git.environment, timeout: 60, grace: 1)
        return (run.status, run.output.split(separator: "\n").map(String.init))
    }

    /// On a scratch repository with stamped and plain commits (one a true merge carrying another Mac's stamped merge):
    /// the last N merges, newest first, with task, review, models, build and contract; filtered by build or model.
    @Test func theScriptListsTheLastMergesFromGitLogAlone() throws {
        let root = try fixture.repo()
        func stamped(_ slug: String, worker: String, build: String, in dir: String) throws {
            try fixture.commit(["\(slug).txt": "\(slug)\n"], in: dir, "\(slug)'s work")
            let trailers = [Worktrees.Trailer("VS-Task", slug), Worktrees.Trailer("VS-Review", "audit (pass at 0123456789ab)"),
                            Worktrees.Trailer("VS-Worker-Model", worker), Worktrees.Trailer("VS-Verifier-Model", "fable"),
                            Worktrees.Trailer("VS-Build", build), Worktrees.Trailer("VS-Contract", "00112233aabbccdd")]
            let parent = Git.run(["rev-parse", "HEAD~1"], in: dir).output
            #expect(Worktrees.stamp(trailers, onto: parent, in: dir) == nil)
        }
        let (a, b) = (String(repeating: "a", count: 40), String(repeating: "b", count: 40))
        try stamped("one", worker: "sonnet", build: a, in: root)
        try fixture.commit(["plain.txt": "p\n"], in: root, "a plain commit")
        // The other Mac's line: a merge stamped there, carried in by a true merge.
        Git.run(["checkout", "-q", "-b", "other", "HEAD~1"], in: root)
        try stamped("two", worker: "opus", build: b, in: root)
        Git.run(["checkout", "-q", "main"], in: root)
        #expect(Git.run(["merge", "-q", "--no-ff", "--no-edit", "other"], in: root).ok)
        try stamped("three", worker: "sonnet", build: b, in: root)

        let all = provenance(["--repo", root])
        #expect(all.status == 0, "\(all.lines)")
        #expect(all.lines.first == "commit\tdate\ttask\treview\tworker\tverifier\tbuild\tcontract")
        let rows = all.lines.dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        #expect(rows.map { $0[2] } == ["three", "two", "one"], "\(all.lines)")
        #expect(rows.allSatisfy { $0.count == 8 && $0[0].count == 12 && $0[3] == "audit (pass at 0123456789ab)" && $0[5] == "fable" && $0[7] == "00112233aabbccdd" })
        #expect(rows.first?[4] == "sonnet" && rows.first?[6] == b)

        #expect(provenance(["--repo", root, "-n", "1"]).lines.dropFirst().map { $0.split(separator: "\t")[2] } == ["three"])
        #expect(provenance(["--repo", root, "--build", "aaaa"]).lines.dropFirst().map { $0.split(separator: "\t")[2] } == ["one"])
        #expect(provenance(["--repo", root, "--model", "opus"]).lines.dropFirst().map { $0.split(separator: "\t")[2] } == ["two"])
        #expect(provenance(["--repo", root, "-n", "x"]).status == 2)
        #expect(provenance(["--repo", root, "no-such-rev"]).status == 2)
    }
}
