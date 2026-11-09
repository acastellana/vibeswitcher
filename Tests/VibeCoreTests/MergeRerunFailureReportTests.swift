import Foundation
import Testing
@testable import VibeCore

/// A merge's failed or stopped test run, told so the worker it goes back to and the lead can act on it. On 2026-11-09
/// two merges said only "Tests fail rebased onto main: web tests: 2 of 2 passed" and pointed at the vault's
/// merge-test.log, which no session may read; one failure was never explained.
struct MergeRerunFailureReportTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let secret = "abc123def456"
    static let passing = "web tests: 2 of 2 passed"

    func repo() throws -> String {
        let url = temp.url("report")
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

    /// A lead on `root`, `suite` committed as scripts/test.sh and set as the test command.
    func team(_ root: String, suite: String, _ settings: [String: Any] = [:]) throws -> (runtime: FakeRuntime, lead: LeadToolset) {
        try commit(["scripts/test.sh": suite], in: root, "the suite")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.power = { nil }
        lead.macLimits = { MacLimits(maxSessions: 12) }
        var all: [String: Any] = ["test_command": "bash scripts/test.sh", "merge_policy": "auto", "records_dir": ""]
        all.merge(settings) { $1 }
        let set = lead.call("configure", all)
        #expect(!set.isError, "\(set.text)")
        return (runtime, lead)
    }

    /// `slug`'s worker with `files` committed on its branch, reported done, its audit passed.
    func audited(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String, _ slug: String = "add-b", files: [String: String] = ["b.txt": "bee\n"]) throws {
        #expect(!lead.call("add_task", ["title": slug, "goal": "g", "acceptance": ["a"]]).isError)
        #expect(!lead.call("start_worker", ["task": slug]).isError)
        try commit(files, in: Worktrees.path(root: root, slug: slug), "\(slug)'s work")
        #expect(!(try seat("worker-\(slug)", runtime).call("report", doneReport("done"))).isError)
        #expect(!lead.call("audit", ["task": slug]).isError)
        let verdict = try seat("verify-\(slug)", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "tests": "passed", "summary": "ok"])
        #expect(!verdict.isError, "\(verdict.text)")
    }

    func setback(_ root: String, _ slug: String = "add-b") throws -> LeadSetback {
        try #require(BoardStore(root: root).load().task(slug)?.setback)
    }

    func copy(_ root: String, _ slug: String = "add-b", name: String = "merge-test.log") -> String {
        Worktrees.path(root: root, slug: slug) + "/.vibeswitcher/merge-failure/" + name
    }

    /// Whether Claude Code's `tool` rules among `rules` cover `path`, as it reads them: `~/` from home, `//` absolute,
    /// anything else from the session's folder; `**` and `*` over any characters.
    static func fileRuleDenies(_ path: String, tool: String = "Read", rules: [String], cwd: String) -> Bool {
        rules.contains { rule in
            guard rule.hasPrefix("\(tool)("), rule.hasSuffix(")") else { return false }
            var pattern = String(rule.dropFirst(tool.count + 1).dropLast())
            if pattern.hasPrefix("~/") {
                pattern = NSHomeDirectory() + pattern.dropFirst(1)
            } else if pattern.hasPrefix("//") {
                pattern = String(pattern.dropFirst())
            } else if !pattern.hasPrefix("/") {
                pattern = cwd + "/" + pattern
            }
            return fnmatch(pattern, path, 0) == 0
        }
    }

    /// The copy at `path` is the whole output, masked, somewhere `role`'s real rules let it read, and git ignores it.
    func expectReadable(_ path: String, role: LeadLaunch.Role, cwd: String, holding lines: [String], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for line in lines { #expect(text.contains(line), "\(line) in \(text.prefix(400))", sourceLocation: sourceLocation) }
        #expect(!text.contains(Self.secret), sourceLocation: sourceLocation)
        let rules = LeadLaunch.deny(role, base: "main")
        // The rule the incident hit does deny the vault's folder, so a pass below means something.
        let denied = NSHomeDirectory() + "/.vibeswitcher/lead/scratch/x/add-b/merge-test.log"
        #expect(Self.fileRuleDenies(denied, rules: rules, cwd: cwd), sourceLocation: sourceLocation)
        #expect(!Self.fileRuleDenies(path, rules: rules, cwd: cwd), "\(path)", sourceLocation: sourceLocation)
        #expect(!LeadGuardRailsTests.denied("cat \(RecentProjects.shellQuote(path))", by: rules), sourceLocation: sourceLocation)
        #expect(path.hasPrefix(cwd + "/"), "\(path) is outside \(cwd)", sourceLocation: sourceLocation)
    }

    /// `text` says nothing a session can't use: no path into the vault, no secret.
    func expectUsable(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!text.contains(vault.folder.path), "a vault path: \(text)", sourceLocation: sourceLocation)
        #expect(!text.contains(Self.secret), "\(text)", sourceLocation: sourceLocation)
    }

    /// The incident's run: tests started and never finished, a secret-shaped line, then the phone's web tests passing.
    static func incident(_ extra: String = "") -> String {
        """
        #!/bin/bash
        echo "◇ Test run started."
        echo "◇ Test stuckOne() started."
        echo "◇ Test stuckTwo() started."
        echo "◇ Test stuckThree() started."
        echo "the job used X-Auth: Bearer \(secret)"
        \(extra)
        echo "\(passing)"
        exit 1
        """
    }

    // MARK: The reason

    /// The incident itself, on a single merge: the reason is that the run stopped, never the passing line, and what
    /// happened reaches the worker as text and as a copy its own rules let it read.
    @Test func aMergeThatStoppedWithOnlyAPassingLineSaysItStopped() throws {
        let root = try repo()
        let why = "Why it stopped: a live process with no output for 22 min of awake time"
        let (runtime, lead) = try team(root, suite: Self.incident("echo '\(why)'"))
        try audited(lead, runtime, root: root)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError, "\(merged.text)")

        let reason = try setback(root).reason
        #expect(reason.hasPrefix("Tests fail rebased onto main: the run stopped partway"), "\(reason)")
        #expect(reason.contains("3 tests printed their start and never finished") && reason.contains(why), "\(reason)")
        #expect(!reason.contains("web tests") && !reason.contains(" passed"), "\(reason)")

        // The message and board(task) both carry the end of the log and how it stopped.
        for text in [merged.text, lead.call("board", ["task": "add-b"]).text] {
            #expect(text.contains(Self.passing), "the log's end: \(text)")
            #expect(text.contains(why), "\(text)")
            #expect(text.contains("X-Auth: Bearer •••"), "\(text)")
            expectUsable(text)
        }

        // The whole log, in the worker's own worktree, where its real rules let it read.
        let path = copy(root)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        #expect(merged.text.contains("Full output: \(path)"), "\(merged.text)")
        try expectReadable(path, role: .worker, cwd: worktree, holding: ["◇ Test stuckOne() started.", Self.passing, "X-Auth: Bearer •••"])

        // Nothing the audit or the merge would take for the worker's own: ignored, not untracked, not a leftover.
        #expect(Git.run(["check-ignore", "-q", path], in: worktree).ok)
        #expect(Git.run(["status", "--porcelain"], in: worktree).output.isEmpty)
        #expect(Worktrees.leftovers(root: root, slug: "add-b").isEmpty)

        #expect(!lead.call("cleanup", ["task": "add-b", "force": true]).isError)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// The first failing test, or the first error line, is the reason whatever the output ends with; a run that names
    /// neither says so rather than quoting its last line.
    @Test(arguments: [
        ("echo '✘ Test firstBad() recorded an issue at A.swift:3:5: nope'; echo '✘ Test firstBad() failed after 0.01 seconds with 1 issue.'", "firstBad()"),
        ("echo 'src/main.c:3: error: boom happened'", "src/main.c:3: error: boom happened"),
        ("echo 'just a line'", "it exited non-zero and its output names no failing test or error"),
        ("echo 'WEB TEST FAILED: Tests/Web/x.test.mjs (exit 1)'", "WEB TEST FAILED: Tests/Web/x.test.mjs (exit 1)"),
    ])
    func theReasonNamesWhatFailedNotTheLastLine(failure: String, expected: String) throws {
        let root = try repo()
        let (runtime, lead) = try team(root, suite: "#!/bin/bash\n\(failure)\necho '\(Self.passing)'\nexit 1\n")
        try audited(lead, runtime, root: root)

        #expect(lead.call("merge", ["task": "add-b"]).isError)
        let reason = try setback(root).reason
        #expect(reason.contains(expected), "\(reason)")
        #expect(!reason.contains("web tests"), "\(reason)")
    }

    /// A run's own "Why it stopped" line can be any length: what's told stays capped.
    @Test func aVeryLongWhyLineIsCapped() throws {
        let root = try repo()
        let (runtime, lead) = try team(root, suite: """
            #!/bin/bash
            printf 'Why it stopped: %s\\n' "$(head -c 200000 /dev/zero | tr '\\0' y)"
            exit 1
            """)
        try audited(lead, runtime, root: root)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(merged.text.utf8.count < 20_000, "capped: \(merged.text.utf8.count)")
        #expect(merged.text.contains("Why it stopped: yyy"), "\(merged.text.prefix(300))")
    }

    // MARK: A failed copy

    /// A copy no worktree holds is the repository's to keep: only the newest stay, and what else is in the folder does.
    @Test func wholeLogCopiesOutsideAWorktreeDontPileUp() throws {
        let root = try repo()
        let (_, lead) = try team(root, suite: Self.incident())
        let flakes = root + "/.vibeswitcher/flakes"
        try VibePaths.ensurePrivate(URL(fileURLWithPath: flakes))
        let fm = FileManager.default
        let old = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<25 {
            let file = "\(flakes)/2026-01-01-task\(index)-aaaaaaaa-merge-test.log"
            try "old".write(toFile: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: old.addingTimeInterval(Double(index))], ofItemAtPath: file)
        }
        // The flake ledger's own evidence, and its ledger: not copies, and old.
        for name in ["2026-01-01-task-aaaaaaaa.log", "2026-01-01-task-aaaaaaaa-hung.log", "ledger.jsonl"] {
            try "kept".write(toFile: "\(flakes)/\(name)", atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: "\(flakes)/\(name)")
        }

        let made = lead.copyMergeLog("the log", slug: "merge-remote", commit: "bbbbbbbb", inWorktree: false)
        let path = try #require(made.path)

        let files = try fm.contentsOfDirectory(atPath: flakes)
        #expect(fm.fileExists(atPath: path))
        #expect(files.filter { $0.hasSuffix("-merge-test.log") }.count == 20, "\(files.sorted())")
        #expect(!files.contains("2026-01-01-task0-aaaaaaaa-merge-test.log") && files.contains("2026-01-01-task24-aaaaaaaa-merge-test.log"), "\(files.sorted())")
        for name in ["2026-01-01-task-aaaaaaaa.log", "2026-01-01-task-aaaaaaaa-hung.log", "ledger.jsonl"] { #expect(files.contains(name), "\(name)") }
    }

    /// A log too large to copy: the merge still reports, with the reason and the log's end inline.
    @Test func aLogTooLargeToCopyStillReports() throws {
        let root = try repo()
        let (runtime, lead) = try team(root, suite: """
            #!/bin/bash
            head -c 17000000 /dev/zero | tr '\\0' x
            echo
            echo "◇ Test big() started."
            echo "◇ Test other() started."
            echo "\(Self.passing)"
            exit 1
            """)
        try audited(lead, runtime, root: root)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(BoardStore(root: root).load().task("add-b")?.status == .failed)
        let reason = try setback(root).reason
        #expect(reason.contains("the run stopped partway"), "\(reason)")
        #expect(merged.text.contains(Self.passing), "the log's end: \(merged.text.prefix(600))")
        #expect(merged.text.contains("couldn't be copied"), "\(merged.text.suffix(400))")
        #expect(merged.text.utf8.count < 20_000, "capped: \(merged.text.utf8.count)")
        #expect(!merged.text.contains(vault.folder.path))
        #expect(!FileManager.default.fileExists(atPath: copy(root)))
    }

    /// Its worktree is the branch's to fill: a link planted where the copy goes isn't followed, and the merge still
    /// reports, with the copy where the lead can read it.
    @Test func aLinkPlantedInTheWorktreeIsntFollowed() throws {
        let root = try repo()
        let (runtime, lead) = try team(root, suite: Self.incident())
        try audited(lead, runtime, root: root)
        let outside = temp.url("outside").path
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try FileManager.default.createSymbolicLink(atPath: worktree + "/.vibeswitcher", withDestinationPath: outside)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
        expectUsable(merged.text)
        let flakes = root + "/.vibeswitcher/flakes"
        let files = try FileManager.default.contentsOfDirectory(atPath: flakes).filter { $0.hasSuffix("-merge-test.log") }
        #expect(files.count == 1, "\(files)")
        #expect(merged.text.contains("Full output: \(flakes)/\(files.first ?? "")"), "\(merged.text)")
    }

    // MARK: A hung run

    @Test func aHungMergeNamesNoVaultPathAndCarriesItsEnd() throws {
        let root = try repo()
        let (runtime, lead) = try team(root, suite: """
            #!/bin/bash
            echo "\(vault.scratch(root: root, "merge-add-b").path)/Sources/A.swift:1:1: warning: slow"
            echo "◇ Test hangs() started."
            echo "it holds X-Auth: Bearer \(Self.secret)"
            exec sleep \(ShellTests.childRuns)
            """, ["test_timeout_min": "0.1"])
        try audited(lead, runtime, root: root)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError)
        expectUsable(merged.text)
        #expect(merged.text.contains("X-Auth: Bearer •••"), "the log's end: \(merged.text)")
        let path = copy(root, name: "merge-hung.log")
        #expect(merged.text.contains("The output so far: \(path)"), "\(merged.text)")
        // The hung file a worker is pointed at says the file by the repository's path, not the merge's vault folder.
        let flakes = root + "/.vibeswitcher/flakes"
        let hung = try #require(try FileManager.default.contentsOfDirectory(atPath: flakes).first { $0.hasSuffix("-hung.log") })
        let file = try String(contentsOfFile: "\(flakes)/\(hung)", encoding: .utf8)
        #expect(!file.contains(vault.folder.path) && file.contains("Sources/A.swift:1:1: warning: slow"), "\(file)")
        try expectReadable(path, role: .worker, cwd: Worktrees.path(root: root, slug: "add-b"), holding: ["◇ Test hangs() started."])
        #expect(BoardStore(root: root).load().task("add-b")?.status == .review)
    }

    // MARK: A batch

    /// Two tasks that each break the stack: each goes back with its own run's log, not the other's or one shared.
    @Test func aBatchTellsEachTaskItBrokeWhatItsOwnRunSaid() throws {
        let root = try repo()
        let (runtime, lead) = try team(root, suite: """
            #!/bin/bash
            if [[ -e break.txt || -e other.txt ]]; then
              echo "◇ Test onStack() started."
              echo "the stack has: $(ls break.txt other.txt 2>/dev/null | tr '\\n' ' ')"
              echo "it holds X-Auth: Bearer \(Self.secret)"
              echo "\(Self.passing)"
              exit 1
            fi
            echo "✔ Test run with 1 test passed after 0.01 seconds."
            """)
        try audited(lead, runtime, root: root, "add-break", files: ["break.txt": "b\n"])
        try audited(lead, runtime, root: root, "add-other", files: ["other.txt": "o\n"])

        let merged = lead.call("merge", ["tasks": ["add-break", "add-other"]])
        #expect(merged.isError, "\(merged.text)")
        expectUsable(merged.text)

        for (slug, own) in [("add-break", "the stack has: break.txt "), ("add-other", "the stack has: other.txt ")] {
            let reason = try setback(root, slug).reason
            #expect(reason.contains("the run stopped partway") && !reason.contains("web tests"), "\(slug): \(reason)")
            let board = lead.call("board", ["task": slug]).text
            #expect(board.contains(own.trimmingCharacters(in: .whitespaces)), "\(slug): \(board)")
            expectUsable(board)
            let path = copy(root, slug)
            #expect(merged.text.contains("Full output: \(path)"), "\(merged.text)")
            try expectReadable(path, role: .worker, cwd: Worktrees.path(root: root, slug: slug), holding: [own, Self.passing])
        }
    }

    /// A batch that hangs reaches no worker: the lead gets the end of its output, once, and a copy it can read.
    @Test func aHungBatchNamesNoVaultPath() throws {
        let root = try repo()
        let (runtime, lead) = try team(root, suite: """
            #!/bin/bash
            echo "◇ Test hangs() started."
            echo "it holds X-Auth: Bearer \(Self.secret)"
            exec sleep \(ShellTests.childRuns)
            """, ["test_timeout_min": "0.1"])
        try audited(lead, runtime, root: root, "add-c", files: ["c.txt": "c\n"])
        try audited(lead, runtime, root: root, "add-d", files: ["d.txt": "d\n"])

        let merged = lead.call("merge", ["tasks": ["add-c", "add-d"]])
        #expect(merged.isError)
        expectUsable(merged.text)
        #expect(merged.text.components(separatedBy: "it holds X-Auth: Bearer •••").count == 2, "once: \(merged.text)")
        let flakes = root + "/.vibeswitcher/flakes"
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: flakes).first { $0.hasSuffix("-hung.log") })
        #expect(merged.text.contains("\(flakes)/\(file)"), "\(merged.text)")
        try expectReadable("\(flakes)/\(file)", role: .lead, cwd: root, holding: ["◇ Test hangs() started."])
    }
}
