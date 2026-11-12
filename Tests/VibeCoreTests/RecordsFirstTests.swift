import Foundation
import Testing
@testable import VibeCore

/// A records fix lands first: when the last merge failed on a file under docs/lead/ and the lead's records have
/// changes not committed, the records are committed before the next merge starts (`LeadRecords.commitBeforeMerge`),
/// so it tests the fix. On 2026-11-12 the fix of a progress.md line waited behind every merge, each built on the line
/// it fixed.
@Suite(.serialized)
struct RecordsFirstTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("records-first")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["config", "commit.gpgsign", "false"]] {
            Git.run(args, in: root)
        }
        try commit(["a.txt": "one\n"], in: root, "first")
        return root
    }

    func commit(_ files: [String: String], in dir: String, _ message: String) throws {
        for (file, text) in files {
            let path = (dir as NSString).appendingPathComponent(file)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            Git.run(["add", file], in: dir)
        }
        #expect(Git.run(["commit", "-q", "-m", message], in: dir).ok)
    }

    /// `slug`'s task, adding `files` on its branch, taken to a passing audit.
    func audited(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String, slug: String, files: [String: String]) throws {
        #expect(!lead.call("add_task", ["title": slug, "goal": "g", "acceptance": ["a"]]).isError)
        let start = lead.call("start_worker", ["task": slug])
        #expect(!start.isError, "\(start.text)")
        try commit(files, in: Worktrees.path(root: root, slug: slug), "\(slug)'s work")
        #expect(!(try seat("worker-\(slug)", runtime).call("report", doneReport("done"))).isError)
        #expect(!lead.call("audit", ["task": slug]).isError)
        let verdict = try seat("verify-\(slug)", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "tests": "passed", "summary": "ok"])
        #expect(!verdict.isError, "\(verdict.text)")
    }

    /// A lint over the records, as the repository's suite runs one: it fails, naming docs/lead/progress.md, until
    /// progress.md says FIXED. Run through a script that takes no filter, so its rerun is whole and no base run pairs it.
    func lintSuite(_ root: String) throws {
        try commit(["scripts/test.sh": """
            #!/bin/bash
            if grep -q FIXED docs/lead/progress.md 2>/dev/null; then echo "✔ Test recordsLint() passed after 0.010 seconds."; echo "✔ Test run with 1 test passed"; exit 0; fi
            echo "✘ Test recordsLint() recorded an issue at RecordsLint.swift:3:5: Expectation failed: docs/lead/progress.md:1 isn't FIXED"
            echo "✘ Test recordsLint() failed after 0.010 seconds with 1 issue."
            echo "✘ Test run with 1 test failed after 0.020 seconds with 1 issue."
            exit 1
            """, "scripts/run.sh": "#!/bin/bash\nexec bash scripts/test.sh \"$@\"\n"], in: root, "the suite")
    }

    @Test func theRecordsFixIsCommittedBeforeTheNextMergeStarts() throws {
        let root = try repo()
        try lintSuite(root)
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["test_command": "bash scripts/run.sh"]).isError)
        try lead.store.appendProgress("Started")
        guard case .committed = lead.records.flush(base: "main") else { Issue.record("records not committed"); return }

        // A merge fails on the records: it names docs/lead/progress.md.
        try audited(lead, runtime, root: root, slug: "add-b", files: ["b.txt": "bee\n"])
        let failed = lead.call("merge", ["task": "add-b"])
        #expect(failed.isError, "\(failed.text)")
        #expect(lead.records.mergeFailedOn == ["docs/lead/progress.md"])

        // The fix goes into the records, not committed yet (the records commit every 5 min or after a merge).
        try audited(lead, runtime, root: root, slug: "add-c", files: ["c.txt": "sea\n"])
        try lead.store.appendProgress("FIXED the line the lint fails on")
        #expect(!Git.run(["show", "main:docs/lead/progress.md"], in: root).output.contains("FIXED"))
        let before = Git.run(["rev-parse", "main"], in: root).output

        // The next merge commits the records first, and tests (and lands) on them.
        let merged = lead.call("merge", ["task": "add-c"])
        #expect(!merged.isError, "\(merged.text)")
        let task = try #require(BoardStore(root: root).load().task("add-c"))
        #expect(task.status == .done)
        let onto = try #require(task.merged?.onto)
        #expect(onto != before)
        #expect(Git.run(["log", "-1", "--format=%s", onto], in: root).output == LeadRecords.subject)
        #expect(Git.run(["show", "\(onto):docs/lead/progress.md"], in: root).output.contains("FIXED"))
        #expect(Git.run(["rev-parse", "\(onto)~1"], in: root).output == before)
        let progress = try String(contentsOfFile: root + "/docs/lead/progress.md", encoding: .utf8)
        #expect(progress.contains("Committed the records at \(onto.prefix(8)) before merging add-c: the last merge failed on docs/lead/progress.md"), "\(progress)")
        // It passed on its first run: nothing is due before the next merge.
        #expect(lead.records.mergeFailedOn.isEmpty)
    }

    /// A records commit refused before a merge (here: a line main has, which fails a lint, fixed by hand with no
    /// redact_record yet) doesn't write the refusal, which quotes that line, back into progress.md: the lead hears it
    /// in its reports, and the log stays clean, so redact_record finds the one line main has.
    @Test func aRefusedRecordsCommitDoesntPutTheLintedLineBack() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.recordLints = { .all }
        let bad = "Dismissed: it was \(LeadRecordTextTests.privateName)'s"
        try lead.store.appendProgress(bad)
        guard case .committed = lead.records.flush(base: "main") else { Issue.record("records not committed"); return }
        lead.records.noteMergeRun(failing: ["PrivateNamesLint: docs/lead/progress.md:3"])
        #expect(lead.records.mergeFailedOn == ["docs/lead/progress.md"])
        // Fixed by hand, as the user did: the line main has is gone from the working file.
        let path = root + "/docs/lead/progress.md"
        let fixed = try String(contentsOfFile: path, encoding: .utf8).replacingOccurrences(of: LeadRecordTextTests.privateName, with: "project-b")
        try fixed.write(toFile: path, atomically: true, encoding: .utf8)

        lead.commitRecordsFirst(not: "add-x")
        let progress = try String(contentsOfFile: path, encoding: .utf8)
        #expect(progress.contains("The records couldn't be committed before merging add-x"), "\(progress)")
        #expect(RecordLint.problems(in: progress).isEmpty, "\(progress)")
        let told = (lead.store.load().reports ?? []).filter { $0.text.hasPrefix("The records couldn't be committed before merging add-x") }
        #expect(told.count == 1 && told.first?.text.contains("redact_record") == true, "\((lead.store.load().reports ?? []).map(\.text))")
    }

    /// Nothing is due when the last merge's failure named no record: the records wait for their usual commit.
    @Test func aFailureThatNamesNoRecordCommitsNothingEarly() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try lead.store.appendProgress("Started")
        guard case .committed = lead.records.flush(base: "main") else { Issue.record("records not committed"); return }
        lead.records.noteMergeRun(failing: ["✘ Test other() failed after 0.1 seconds with 1 issue. Sources/A.swift:3"])
        #expect(lead.records.mergeFailedOn.isEmpty)
        try lead.store.appendProgress("More")
        #expect(lead.records.commitBeforeMerge(base: "main") == nil)
        lead.records.noteMergeRun(failing: ["PrivateNamesLint: docs/lead/decisions.md:4"])
        #expect(lead.records.mergeFailedOn == ["docs/lead/decisions.md"])
        guard case .committed? = lead.records.commitBeforeMerge(base: "main") else { Issue.record("not committed first"); return }
        // Nothing left to commit: nothing to do.
        #expect(lead.records.commitBeforeMerge(base: "main") == nil)
        lead.records.noteMergeRun(failing: [])
        #expect(lead.records.mergeFailedOn.isEmpty)
    }
}
