import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The bootstrap path's step 9 (the start plan's S10, ST-D21): a whole team on a `ScratchNode`, never the user's node,
/// driven through the built command line on a pty of its own (`script`) as the user drives it. A scratch repository with
/// `src/`, a committed `check.sh` (the test command, which notes where it ran) and its `workflow.md` (`merge_policy:
/// ask_sensitive` over `src/**`, one finder, the verifier on haiku); the host holds its fresh vault's first look, so the
/// lead starts only once the user accepted the config and recorded the base. The lead asks the user one question, starts
/// two workers at once in their worktrees, audits one of them and merges it, the merge held for the user's approval of
/// exactly the audited commit (`LeadWorkflow.approval(of:)`) and landing with `check.sh` run.
///
/// `aScratchTeamOfFakesBuildsAuditsAndMerges` rehearses it with `FakeClaude` as every session (the test commits for the
/// workers, and the verifier gives its verdict through its own tool server); `aScratchTeamPlansBuildsAuditsAndMerges`
/// does it with a real Claude Code lead on Sonnet and the team it starts, gated on the user's throwaway config folder
/// (the security document's decision 16), each run on the user's go-ahead.
@Suite(NodeTraits.linuxOnly, .serialized, .timeLimit(.minutes(60)))
struct ScratchRunTests {
    private let scratch = Scratch()

    // MARK: The rehearsal, with fakes

    @Test func aScratchTeamOfFakesBuildsAuditsAndMerges() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let marker = try Self.markerFile(scratch)
        let repo = node.root.appendingPathComponent("repo")
        let first = try await Self.scratchRepository(in: repo, marker: marker)
        let cli = Self.CommandLine(node: node)

        // 1. The accepts: the config the first look holds, then the base, each card's code typed.
        try await cli.accept(repo, from: first)

        // 2. The lead, its code typed; between turns, as its Stop hook would say.
        let started = try await cli.run(["lead", repo.path, "--goal", "two tasks in src, one audit, one merge"], typed: true)
        try #require(started.status == 0 && started.output.contains("the lead started"), "\(started.output)\n\(node.said)")
        let lead = try #require(try node.sessions().first { $0.isLive && $0.label.hasPrefix("Lead · ") }, "\(node.said)")
        let tools = node.fake.files(terminal: lead.tty)
        try #require(await eventually(timeout: 60) { EngineEndToEndTests.state(tools)["pid"] != nil }, "\(node.said)")
        let pid = try #require((EngineEndToEndTests.state(tools)["pid"] as? Int).map(Int32.init))
        try hook(node, ["hook_event_name": "Stop"], tty: lead.tty, pid: pid)

        // 3. Its question: `questions` lists it, the answer typed, recorded in the vault and typed into the lead as the
        // user's.
        let question = "Which name for the parser?"
        _ = try await Self.reply(tools, try Self.send(tools, "ask_user", ["question": question, "options": ["Parser", "Reader"]]))
        let card = try #require(try await EngineEndToEndTests.listedCard(node, question: question, timeout: 60), "\(node.said)")
        let listed = try await cli.run(["questions"])
        #expect(listed.status == 0 && listed.output.contains(question) && listed.output.contains(card), "\(listed.output)")
        let answered = try await cli.run(["answer", card, "Reader"], typed: true)
        #expect(answered.status == 0 && answered.output.contains("answered: the lead is told"), "\(answered.output)\n\(node.said)")
        let typed = try await EngineEndToEndTests.prompt(tools) { $0.hasSuffix("Reader") }
        let actions = try await Self.userActions(node)
        let answer = try #require(actions.first { $0.kind == "answer" && $0.subject == card }, "\(actions)")
        let message = try #require(actions.first { $0.kind == "message" && $0.action == answer.action }, "\(actions)")
        #expect(message.digest == LeadVaultV2.digest(typed), "\(typed)")

        // 4. Two tasks touching src/, and a worker on each, both live at once (room for 4 team sessions).
        try node.noLoadHold(maxSessions: 4)
        let tasks = [("write-the-parser", "Write the parser", "src/parser.txt"), ("write-the-lexer", "Write the lexer", "src/lexer.txt")]
        for (_, title, file) in tasks {
            let added = try await Self.reply(tools, try Self.send(tools, "add_task", ["title": title, "goal": "\(file) says what it is.",
                                                                                       "acceptance": ["\(file) exists"], "auto_advance": false]))
            #expect(added.contains(title), "\(added)")
        }
        for (slug, title, _) in tasks {
            let sent = try Self.send(tools, "start_worker", ["task": slug])
            _ = try await EngineEndToEndTests.connected(node, label: "Worker: \(title)", calling: "progress", ["task": slug, "text": "starting"])
            let reply = try await Self.reply(tools, sent)
            #expect(reply.contains("Worker started on \(slug)"), "\(reply)")
        }
        let workers = try node.sessions().filter { $0.isLive && $0.label.hasPrefix("Worker: ") }
        #expect(workers.count == 2, "both workers live at once: \(workers.map(\.label))")

        // 5. Each worker's commit in its own worktree, on its own branch.
        var commits: [String: String] = [:]
        for (slug, title, file) in tasks {
            let worktree = Worktrees.path(root: repo.path, slug: slug)
            try "\(title)\n".write(toFile: (worktree as NSString).appendingPathComponent(file), atomically: true, encoding: .utf8)
            try await scratchGit(worktree, ["add", "--", file])
            try await scratchGit(worktree, ["commit", "-q", "-m", title])
            commits[slug] = try await scratchGit(worktree, ["rev-parse", "HEAD"])
        }
        try Self.assertWorkersCommitted(repo, since: first, count: 2)
        let parser = "write-the-parser"
        let commit = try #require(commits[parser])

        // 6. No merge without a verdict: the vault has none yet.
        let unaudited = try await Self.reply(tools, try Self.send(tools, "merge", ["task": parser]))
        #expect(unaudited.contains("no passing audit"), "\(unaudited)")
        #expect(try await Self.verdict(node, repo, task: parser) == nil)

        // 7. The audit: its verifier gives its verdict through its own tool server, and the vault holds it, on the
        // worker's commit.
        let auditSent = try Self.send(tools, "audit", ["task": parser])
        let verifier = try await EngineEndToEndTests.connected(node, label: "Verifier: Write the parser", calling: "board", ["task": parser])
        let audit = try await Self.reply(tools, auditSent)
        #expect(!audit.isEmpty, "\(audit)")
        let verifierTools = node.fake.files(terminal: verifier.tty)
        let verdictSent = try Self.send(verifierTools, "submit_audit", ["task": parser, "completion": "complete", "integrity": "clean",
                                                                         "summary": "src/parser.txt is there; sh ./check.sh passed", "tests": "passed"])
        let given = try await Self.reply(verifierTools, verdictSent)
        #expect(given.contains("passed") || given.contains("done"), "\(given)")
        let verdict = try #require(try await Self.verdict(node, repo, task: parser), "the vault holds no verdict: \(node.said)")
        #expect(verdict.commit == commit && verdict.passes && verdict.tests == .passed, "\(verdict)")

        // 8. Held for the user's approval (src/** is sensitive), which the lead asks for; `answer` gives exactly the
        // audited commit's approval, its code typed, and the vault records it for the task at that commit.
        let held = try await Self.reply(tools, try Self.send(tools, "merge", ["task": parser]))
        #expect(held.contains("Not merged yet") && held.contains(LeadWorkflow.approval(of: commit)), "\(held)")
        let approval = LeadWorkflow.approval(of: commit)
        let asking = "Merge \(parser) at \(commit.prefix(8))?"
        _ = try await Self.reply(tools, try Self.send(tools, "ask_user", ["question": asking, "options": [approval, "Not yet"],
                                                                          "priority": "blocking", "task": parser]))
        let approvalCard = try #require(try await EngineEndToEndTests.listedCard(node, question: asking, timeout: 60), "\(node.said)")
        let cards = try await cli.run(["questions"])
        #expect(cards.status == 0 && cards.output.contains(approvalCard), "\(cards.output)")
        let approved = try await cli.run(["answer", approvalCard, approval], typed: true)
        #expect(approved.status == 0, "\(approved.output)\n\(node.said)")
        #expect(try await Self.approved(node, repo, task: parser, commit: commit), "the vault has no approval of \(commit): \(approved.output)")
        // Bound to that task and that commit: not the other worker's.
        let lexer = try #require(commits["write-the-lexer"])
        #expect(try await !Self.approved(node, repo, task: parser, commit: lexer))
        #expect(try await !Self.approved(node, repo, task: "write-the-lexer", commit: commit))

        // 9. The merge lands on the base, its tests (check.sh) run.
        let merged = try await Self.reply(tools, try Self.send(tools, "merge", ["task": parser], seconds: 300), timeout: 360)
        #expect(merged.contains("Merged \(parser) into main"), "\(merged)\n\(node.said)")
        let landed = try await Self.landed(repo, since: first)
        #expect(landed.compactMap { Self.trailer("VS-Task", in: $0) } == [parser], "one merge on the base: \(landed)")
        #expect(try await scratchGit(repo.path, ["show", "main:src/parser.txt"]) == "Write the parser", "the worker's change on the base")
        #expect(Self.ranForMerge(marker, task: parser), "check.sh's marker: \((try? String(contentsOf: marker, encoding: .utf8)) ?? "none")")
        #expect(BoardStore(root: repo.path).load().task(parser)?.status == .done)
        cli.assertEveryCallInScratchForm()
    }

    /// The real-claude script the gated case runs as the node's `claude`: the config folder given, and `--model sonnet`
    /// only when its arguments name no model (the verifier's `--model haiku` stays haiku, ST-D21).
    @Test func theRealClaudeScriptAddsSonnetOnlyWhenNoModelIsGiven() async throws {
        let folder = scratch.url("real-claude")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let standIn = folder.appendingPathComponent("stand-in-claude")
        try ScratchNode.script("#!/bin/sh\nprintf '%s\\n' \"$CLAUDE_CONFIG_DIR\" \"$@\"\n", at: standIn)
        let config = folder.appendingPathComponent("config dir")
        let script = try Self.realClaudeScript(root: folder, config: config, claude: standIn.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("claude").path) == script.path)
        let environment = ["PATH": "/usr/bin:/bin"]
        let plain = try await run(script, ["-p", "say --model here"], environment: environment)
        #expect(plain.output.split(separator: "\n").map(String.init) == [config.path, "--model", "sonnet", "-p", "say --model here"], "\(plain.output)\(plain.errors)")
        for given in [["--model", "haiku", "-p", "hi"], ["--model=haiku", "-p", "hi"]] {
            let ran = try await run(script, given, environment: environment)
            #expect(ran.output.split(separator: "\n").map(String.init) == [config.path] + given, "\(ran.output)\(ran.errors)")
        }
    }

    // MARK: The gated run, a real lead on Sonnet

    /// The user's throwaway Claude Code config folder, named on the run's command line only.
    static let configFolder = ProcessInfo.processInfo.environment["VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR"]

    /// The two tasks the real lead is told to add, by title (their slugs are what the harness trusts beforehand).
    static let realTasks = [("Add the greeting", "src/greeting.txt"), ("Add the farewell", "src/farewell.txt")]

    /// What the real lead is asked: one question, exactly two tasks touching `src/`, both workers, one audit, one merge.
    static let realGoal = """
        A scripted run; do exactly this and nothing more. \
        1. Ask the user one question with ask_user: which greeting word to use, with exactly two options, Hello and Hi, and wait for the answer. \
        2. Add exactly two tasks with add_task, auto_advance false: "\(realTasks[0].0)" (create \(realTasks[0].1) holding the word the user chose), \
        and "\(realTasks[1].0)" (create \(realTasks[1].1) holding the word Goodbye). Each one's acceptance: the file holds that word, and sh ./check.sh passes. \
        3. Start a worker on each with start_worker; both run at once. \
        4. When the worker on \(Slug.make(realTasks[0].0, taken: [])) reports done, audit it once; when its audit passes, merge it, asking the user's \
        approval as merge tells you, and merge again once approved. Don't audit or merge the other task, and don't call cleanup. Then stop.
        """

    @Test(.enabled(if: configFolder != nil,
                   "starts a real Claude Code team on Sonnet and spends the account's usage: set VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR to a Claude Code config folder you logged in once to run it"))
    func aScratchTeamPlansBuildsAuditsAndMerges() async throws {
        let config = URL(fileURLWithPath: try #require(Self.configFolder))
        try #require(FileManager.default.fileExists(atPath: config.appendingPathComponent(".claude.json").path),
                     "\(config.path) has no .claude.json: log in there once first")
        let claude = try #require(RealClaudeStatusTests.claudeExecutable(), "no claude on PATH")
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        let repo = node.root.appendingPathComponent("repo")
        let marker = try Self.markerFile(scratch)
        // Registered before anything is written into the user's folder, undone on every way out once begun: the hooks,
        // then each trust entry (the repository's, each worktree's), and the node stopped.
        var hooksWritten = false
        var trusted: [String] = []
        defer {
            node.stop()
            if hooksWritten {
                do { try HookInstaller.uninstall(agent: .claude, at: config.appendingPathComponent("settings.json")) } catch {
                    Issue.record("the hooks stayed in \(config.path)/settings.json: \(error)")
                }
            }
            for path in trusted {
                do { try RealClaudeStatusTests.trust(path, in: config, false) } catch { Issue.record("the trust entry for \(path) stayed: \(error)") }
            }
        }
        let first = try await Self.scratchRepository(in: repo, marker: marker)
        let project = repo.resolvingSymlinksInPath().path
        let version = try await run(URL(fileURLWithPath: claude), ["--version"],
                                    environment: RealClaudeStatusTests.agentEnvironment(node.root, config: config))
        print("S10: \(claude) --version: \(version.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        let script = try Self.realClaudeScript(root: node.testFolder, config: config, claude: claude)
        hooksWritten = true
        try HookInstaller.install(agent: .claude, at: config.appendingPathComponent("settings.json"),
                                  hookBinary: node.nodeRoot.appendingPathComponent("bin/vibeswitcher-hook").path)
        let slugs = Self.realTasks.map { Slug.make($0.0, taken: []) }
        for path in [project] + slugs.map({ Worktrees.path(root: project, slug: $0) }) {
            trusted.append(path)
            try RealClaudeStatusTests.trust(path, in: config, true)
        }

        let began = MacTime.real.awake()
        var mark = began
        func step(_ what: String) {
            let now = MacTime.real.awake()
            print(String(format: "S10: %@: %.1f s (%.1f s in all)", what, now - mark, now - began))
            mark = now
        }
        let cli = Self.CommandLine(node: node)
        try await cli.accept(repo, from: first)
        step("1, config and base accepted")
        let started = try await cli.run(["lead", repo.path, "--goal", Self.realGoal], typed: true)
        try #require(started.status == 0 && started.output.contains("the lead started"), "\(started.output)\n\(node.said)")
        #expect(started.output.contains(script.resolvingSymlinksInPath().path), "\(started.output)")
        step("2, the lead started")

        // The cards as they come: the lead's question answered with its first option, the approval with exactly what it
        // offers; until the greeting's task is merged, up to the suite's limit.
        let greeting = slugs[0]
        var question: String?, approvalCard: String?, answeredCards: Set<String> = []
        var merged = false
        let deadline = began + 55 * 60
        while !merged, MacTime.real.awake() < deadline {
            for card in await Self.openCards(node) where !answeredCards.contains(card.id) {
                if let offered = card.options.first(where: { LeadVault.approvedCommit(in: $0) != nil }) {
                    let ran = try await cli.run(["answer", card.id, offered], typed: true)
                    #expect(ran.status == 0, "\(ran.output)\n\(node.said)")
                    approvalCard = card.id
                    step("the approval answered (\(offered))")
                } else {
                    let listed = try await cli.run(["questions"])
                    #expect(listed.output.contains(card.id), "\(listed.output)")
                    let ran = try await cli.run(["answer", card.id, card.options.first ?? "Hello"], typed: true)
                    #expect(ran.status == 0 && ran.output.contains("answered: the lead is told"), "\(ran.output)\n\(node.said)")
                    if question == nil { question = card.id }
                    step("the lead's question answered (\(card.text))")
                }
                answeredCards.insert(card.id)
            }
            merged = BoardStore(root: repo.path).load().task(greeting)?.status == .done
            if !merged { try await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        step(merged ? "3, \(greeting) merged" : "3, \(greeting) not merged within the limit")
        print("S10: the board: \(BoardStore(root: repo.path).load().tasks.map { "\($0.slug) \($0.status)" })")
        try #require(merged, "\(greeting) never merged: \(node.said.replacingOccurrences(of: "\u{0}", with: " "))")

        // Two agent/* branches, each with a worker's commit.
        try Self.assertWorkersCommitted(repo, since: first, count: 2)
        // A verdict in the vault, from a verifier on a model other than the workers' (the landed commit's trailers say
        // which each ran on).
        let verdict = try #require(try await Self.verdict(node, repo, task: greeting), "the vault holds no verdict for \(greeting)")
        #expect(verdict.passes, "\(verdict)")
        let landed = try await Self.landed(repo, since: first).first { Self.trailer("VS-Task", in: $0) == greeting } ?? ""
        let workerModel = Self.trailer("VS-Worker-Model", in: landed), verifierModel = Self.trailer("VS-Verifier-Model", in: landed)
        print("S10: the worker's model \(workerModel ?? "none"), the verifier's \(verifierModel ?? "none")")
        #expect(verifierModel != nil && verifierModel != workerModel, "\(landed)")
        // One merge on the base, its tests run.
        let onBase = try await Self.landed(repo, since: first)
        #expect(onBase.compactMap { Self.trailer("VS-Task", in: $0) } == [greeting], "\(onBase)")
        #expect(Self.ranForMerge(marker, task: greeting), "check.sh's marker: \((try? String(contentsOf: marker, encoding: .utf8)) ?? "none")")
        // The lead's question answered as the user's: its action, and the message's digest under it, in the vault.
        let card = try #require(question, "the lead asked no question")
        #expect(approvalCard != nil, "no approval card was answered")
        let actions = try await Self.userActions(node)
        let answer = try #require(actions.first { $0.kind == "answer" && $0.subject == card }, "\(actions)")
        #expect(actions.contains { $0.kind == "message" && $0.action == answer.action }, "\(actions)")
        cli.assertEveryCallInScratchForm()
        step("4, checked")
    }

    // MARK: Helpers

    /// A scratch repository at `folder` whose commit on `main` holds `src/`, `check.sh` (the test command: it notes
    /// the folder it ran in, in `marker`, and passes) and nothing else; its `workflow.md` (ST-D21) written beside, in the
    /// board's folder, as the lead's is (not committed: the board's folder isn't the repository's). The commit.
    static func scratchRepository(in folder: URL, marker: URL) async throws -> String {
        try await VibeNodeTests.scratchRepository(folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "The scratch run's sources.\n".write(to: folder.appendingPathComponent("src/README"), atomically: true, encoding: .utf8)
        try ScratchNode.script("#!/bin/sh\n# The scratch run's test command: where it ran, noted; it passes.\npwd >> \(FakeClaude.quoted(marker.path))\nexit 0\n",
                               at: folder.appendingPathComponent("check.sh"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("check.sh.txt"))
        // Its own committer, as the user's repository has one (the merge stamps its landed commit).
        try await scratchGit(folder.path, ["config", "user.name", "Test"])
        try await scratchGit(folder.path, ["config", "user.email", "test@example.invalid"])
        try await scratchGit(folder.path, ["add", "--", "src/README", "check.sh"])
        try await scratchGit(folder.path, ["commit", "-q", "-m", "src and check.sh"])
        let path = ConfigHoldStore.workflowPath(root: folder.path)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try """
            ---
            test_command: sh ./check.sh
            merge_policy: ask_sensitive
            sensitive_paths: src/**
            verifier_model: haiku
            audit_finders: 1
            ---

            """.write(toFile: path, atomically: true, encoding: .utf8)
        return try await scratchGit(folder.path, ["rev-parse", "main"])
    }

    /// `check.sh`'s marker: a file in a scratch folder of its own, outside the node's root and home.
    static func markerFile(_ scratch: Scratch) throws -> URL {
        let folder = scratch.url("check")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("ran")
    }

    /// Whether `check.sh` ran in `task`'s merge (`Worktrees.rebaseAndTest`'s worktree, `merge-<task>`).
    static func ranForMerge(_ marker: URL, task: String) -> Bool {
        Platform.lines((try? String(contentsOf: marker, encoding: .utf8)) ?? "").contains { $0.contains("merge-\(task)") }
    }

    /// Writes the real-claude script into `root` (`real-claude`) and points `root/claude` at it: the account's `claude`
    /// with the config folder given and the node's own update and traffic switches, and `--model sonnet` only when its
    /// arguments carry no `--model` (ST-D21). Its argv[0] stays a path ending in `claude`.
    static func realClaudeScript(root: URL, config: URL, claude: String) throws -> URL {
        let quote = FakeClaude.quoted
        let script = root.appendingPathComponent("real-claude")
        try ScratchNode.script("""
            #!/bin/sh
            export CLAUDE_CONFIG_DIR=\(quote(config.path)) DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
            for argument in "$@"; do
                case "$argument" in
                    --model|--model=*) exec \(quote(claude)) "$@" ;;
                esac
            done
            exec \(quote(claude)) --model sonnet "$@"

            """, at: script)
        let link = root.appendingPathComponent("claude")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil || FileManager.default.fileExists(atPath: link.path) {
            try FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: script.path)
        return script
    }

    /// The `agent/*` branches, `count` of them, each with a commit past `first` (a worker's).
    static func assertWorkersCommitted(_ repo: URL, since first: String, count: Int, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let branches = Platform.lines(Git.run(["for-each-ref", "--format=%(refname:short)", "refs/heads/agent/"], in: repo.path).output)
        #expect(branches.count == count, "\(branches)", sourceLocation: sourceLocation)
        for branch in branches {
            let ahead = Int(Git.run(["rev-list", "--count", "\(first)..\(branch)"], in: repo.path).output) ?? 0
            #expect(ahead >= 1, "\(branch) has no worker's commit", sourceLocation: sourceLocation)
        }
    }

    /// The messages of the commits on `main` since `first`, newest first (a merge's landed commit, and the records the
    /// lead commits after it).
    static func landed(_ repo: URL, since first: String) async throws -> [String] {
        try await scratchGit(repo.path, ["log", "--format=%B%x00", "\(first)..main"]).components(separatedBy: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The value of the last `key:` trailer in a commit's message.
    static func trailer(_ key: String, in message: String) -> String? {
        Platform.lines(message).last { $0.hasPrefix("\(key): ") }.map { String($0.dropFirst(key.count + 2)).trimmingCharacters(in: .whitespaces) }
    }

    /// Has `files`' fake call `tool` (its `mcp` op, the call's deadline `seconds`): the count of its calls before, which
    /// `reply` waits past.
    static func send(_ files: FakeClaude.Files, _ tool: String, _ arguments: [String: Any], seconds: Int = 120) throws -> Int {
        let before = files.calls().count
        let line = try JSONSerialization.data(withJSONObject: ["op": "mcp", "tool": tool, "arguments": arguments, "seconds": seconds] as [String: Any])
        let handle = try FileHandle(forWritingTo: files.control)
        handle.seekToEndOfFile()
        handle.write(line + Data("\n".utf8))
        try handle.close()
        return before
    }

    /// The text of the call `send` made (the one after `before`), once it came back.
    static func reply(_ files: FakeClaude.Files, _ before: Int, timeout: TimeInterval = 180,
                      sourceLocation: SourceLocation = #_sourceLocation) async throws -> String {
        try #require(await eventually(timeout: timeout) { files.calls().count > before }, "no reply: \(files.calls())", sourceLocation: sourceLocation)
        return files.text(of: files.calls()[before])
    }

    /// The host's lead vault asked by this process (`appKey` nil: never the user's app key).
    static func vault(_ node: ScratchNode, _ request: LeadVault.Request) async throws -> LeadVault.Reply {
        try await offPool { () throws -> LeadVault.Reply in
            guard case .vault(let reply) = try HostCall.request(.vault(request), socket: node.socket, appKey: nil, timeout: 10) else {
                throw HostCall.Failure(description: "the host answered something else")
            }
            return reply
        }
    }

    /// The verdict the vault holds for `task`.
    static func verdict(_ node: ScratchNode, _ repo: URL, task: String) async throws -> LeadVault.Verdict? {
        for root in Set([repo.path, repo.resolvingSymlinksInPath().path]) {
            if case .verdict(let verdict?) = try await vault(node, .verdict(root: root, task: task)) { return verdict }
        }
        return nil
    }

    /// Whether the vault holds the user's approval of `task` at `commit`.
    static func approved(_ node: ScratchNode, _ repo: URL, task: String, commit: String) async throws -> Bool {
        for root in Set([repo.path, repo.resolvingSymlinksInPath().path]) {
            if case .approved(true) = try await vault(node, .approved(root: root, task: task, commit: commit)) { return true }
        }
        return false
    }

    /// The user's actions the vault recorded (`answer`, `message`, …).
    static func userActions(_ node: ScratchNode) async throws -> [LeadVaultV2.UserAction] {
        try await offPool { () throws -> [LeadVaultV2.UserAction] in
            guard case .vaultV2(.actions(let actions)) = try HostCall.request(.vaultV2(.userActions(since: 0)), socket: node.socket, appKey: nil,
                                                                              timeout: 10) else { return [] }
            return actions
        }
    }

    /// The open cards the server's `questions` lists now, asked over the wire (no child process each look).
    static func openCards(_ node: ScratchNode) async -> [(id: String, text: String, options: [String])] {
        await offPool { () -> [(id: String, text: String, options: [String])] in
            guard let client = try? WireClient(node), let reply = WireClient.reply(client.request("questions", action: nil, timeout: 10)),
                  let cards = reply.result?["cards"]?.array else { return [] }
            return cards.compactMap { card in
                guard let id = card["id"]?.string, let question = card["question"] else { return nil }
                return (id, question["text"]?.string ?? "", question["options"]?.array?.compactMap(\.string) ?? [])
            }
        }
    }

    /// The built command line on the node, each run kept to be checked in scratch form.
    final class CommandLine: @unchecked Sendable {
        let node: ScratchNode
        private let lock = NSLock()
        private var runs: [(arguments: [String], typed: Bool, ran: CommandRun)] = []

        init(node: ScratchNode) { self.node = node }

        /// `arguments` on a pty of its own with the card's code typed (`typed`, a state change), else with stdin /dev/null.
        func run(_ arguments: [String], typed: Bool = false) async throws -> CommandRun {
            let ran = typed ? try await node.runOnTerminal(arguments) : try await node.run(arguments)
            lock.withLock { runs.append((arguments, typed, ran)) }
            return ran
        }

        /// `config held`, `config accept CARD`, `base show --from FIRST` and `base accept CARD`: the first look's two accepts.
        func accept(_ repo: URL, from first: String) async throws {
            let held = try await run(["config", "held", repo.path])
            let configCard = try #require(ScratchNode.card(held.output, "config accept"), "\(held.output)\(held.errors)\n\(node.said)")
            let accepted = try await run(["config", "accept", configCard], typed: true)
            try #require(accepted.status == 0 && accepted.output.contains("accepted"), "\(accepted.output)\n\(node.said)")
            let shown = try await run(["base", "show", repo.path, "--from", first])
            let baseCard = try #require(ScratchNode.card(shown.output, "base accept"), "\(shown.output)\(shown.errors)")
            let recorded = try await run(["base", "accept", baseCard], typed: true)
            try #require(recorded.status == 0, "\(recorded.output)\n\(node.said)")
        }

        /// Every run so far in scratch form.
        func assertEveryCallInScratchForm(sourceLocation: SourceLocation = #_sourceLocation) {
            let all = lock.withLock { runs }
            #expect(!all.isEmpty, sourceLocation: sourceLocation)
            for run in all {
                ScratchRunTests.assertScratchForm(run.ran, root: node.root, typed: run.typed, run.arguments, sourceLocation: sourceLocation)
            }
        }
    }

    /// A command line's run in scratch form (EN-D8): it names "scratch node at <root>" on stderr (the pty's output for a
    /// run on a terminal, where stderr is the terminal too) and never on stdout otherwise; and a state change (`typed`)
    /// showed its code prompt.
    static func assertScratchForm(_ ran: CommandRun, root: URL, typed: Bool, _ arguments: [String],
                                  sourceLocation: SourceLocation = #_sourceLocation) {
        let named = "scratch node at \(root.standardizedFileURL.path)"
        let what = arguments.joined(separator: " ")
        if typed {
            #expect(ran.output.contains(named), "\(what): \(ran.output)", sourceLocation: sourceLocation)
            #expect(ran.output.range(of: #"Type [A-Z]{4} and Enter"#, options: .regularExpression) != nil, "\(what): \(ran.output)",
                    sourceLocation: sourceLocation)
        } else {
            #expect(ran.errors.contains(named), "\(what): \(ran.errors)", sourceLocation: sourceLocation)
            #expect(!ran.output.contains("scratch node at"), "\(what): \(ran.output)", sourceLocation: sourceLocation)
        }
    }
}
