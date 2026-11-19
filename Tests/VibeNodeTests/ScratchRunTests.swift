import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The bootstrap path's step 9 (the start plan's S10, ST-D21): a whole team on a `ScratchNode`, never the user's node,
/// driven through the built command line on a pty of its own (`script`) as the user drives it. A scratch repository with
/// `src/`, a committed `check.sh` (the test command, which notes where it ran) and its `workflow.md` (`merge_policy:
/// ask_sensitive` over `src/**`, one finder, the verifier on sonnet); the host holds its fresh vault's first look, so the
/// lead starts only once the user accepted the config and recorded the base. The lead asks the user one question, starts
/// two workers at once in their worktrees, audits one of them and merges it, the merge held for the user's approval of
/// exactly the audited commit (`LeadWorkflow.approval(of:)`) and landing with `check.sh` run.
///
/// `aScratchTeamOfFakesBuildsAuditsAndMerges` rehearses it with `FakeClaude` as every session (the test commits for the
/// workers, and the verifier gives its verdict through its own tool server); `aScratchTeamPlansBuildsAuditsAndMerges`
/// does it with a real Claude Code lead on haiku (the cheapest model; the verifier on sonnet, another model as the
/// review floor wants) and the team it starts, gated on the user's throwaway config folder
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
        // Run under a test and build slot of the node's own (`<root>/tmp`), never one of the account's: this suite holds
        // one of those itself (scripts/test.sh), the only one on a machine under 12 cores, where the merge waited for
        // it until its call gave up (the `v2 linux` run of 2026-11-17, 4 cores: "no reply to request 2" after 300 s).
        #expect(FileManager.default.fileExists(atPath: node.root.appendingPathComponent("tmp/test-build.lock").path),
                "the merge's slot: \((try? FileManager.default.contentsOfDirectory(atPath: node.root.appendingPathComponent("tmp").path)) ?? [])")
        cli.assertEveryCallInScratchForm()
    }

    /// The real-claude script the gated case runs as the node's `claude`: the config folder given, and `--model haiku`
    /// (the cheapest) only when its arguments name no model (the verifier's `--model sonnet` stays sonnet, ST-D21 with
    /// the models swapped, 2026-11-19).
    @Test func theRealClaudeScriptAddsHaikuOnlyWhenNoModelIsGiven() async throws {
        let folder = scratch.url("real-claude")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let standIn = folder.appendingPathComponent("stand-in-claude")
        try ScratchNode.script("#!/bin/sh\nprintf '%s\\n' \"$CLAUDE_CONFIG_DIR\" \"$@\"\n", at: standIn)
        let config = folder.appendingPathComponent("config dir")
        let script = try Self.realClaudeScript(root: folder, config: config, claude: standIn.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("claude").path) == script.path)
        let environment = ["PATH": "/usr/bin:/bin"]
        let plain = try await run(script, ["-p", "say --model here"], environment: environment)
        #expect(plain.output.split(separator: "\n").map(String.init) == [config.path, "--model", "haiku", "-p", "say --model here"], "\(plain.output)\(plain.errors)")
        for given in [["--model", "sonnet", "-p", "hi"], ["--model=sonnet", "-p", "hi"]] {
            let ran = try await run(script, given, environment: environment)
            #expect(ran.output.split(separator: "\n").map(String.init) == [config.path] + given, "\(ran.output)\(ran.errors)")
        }
    }

    /// The gated run's model check (ST-D21 with the models swapped: workers on haiku, the cheapest, the verifier on sonnet)
    /// reads what each role really ran on, from the config folder's transcripts by the session's name, and holds the
    /// verifier's trailer to sonnet: a model
    /// the run notes as "unknown", an alias beside a full id, or workers on Claude's default each fail it.
    @Test func theRunsModelsAreReadByRoleFromTheConfigFoldersTranscripts() throws {
        let config = scratch.url("config")
        let root = scratch.url("project").path
        let slug = "add-the-greeting"
        let folder = config.appendingPathComponent("projects").appendingPathComponent(RecentProjects.claudeSlug(for: Worktrees.path(root: root, slug: slug)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func transcript(_ name: String?, _ file: String, model: String, id: String) throws {
            var lines: [[String: Any]] = []
            if let name { lines.append(["type": "custom-title", "customTitle": name]) }
            lines.append(["type": "assistant", "timestamp": "2026-11-16T10:00:00.000Z",
                          "message": ["id": id, "model": model, "usage": ["input_tokens": 10, "output_tokens": 5]]])
            let data = try lines.map { try JSONSerialization.data(withJSONObject: $0) }.reduce(Data()) { $0 + $1 + Data("\n".utf8) }
            try data.write(to: folder.appendingPathComponent(file))
        }
        try transcript("worker-\(slug)", "a.jsonl", model: "claude-haiku-4-5-20251001", id: "m1")
        try transcript("verify-\(slug)", "b.jsonl", model: "claude-sonnet-4-5-20250929", id: "m2")
        try transcript(nil, "c.jsonl", model: "claude-opus-4-1", id: "m3")
        let ran = Self.sessionModels(config: config, root: root, slug: slug)
        #expect(ran.workers == ["claude-haiku-4-5-20251001"] && ran.verifiers == ["claude-sonnet-4-5-20250929"], "\(ran)")

        let sonnet = ["claude-sonnet-4-5-20250929"], haiku = ["claude-haiku-4-5-20251001"]
        #expect(Self.modelProblem(workers: haiku, verifiers: sonnet, verifierTrailer: "sonnet") == nil)
        // Workers on Claude's default (the script never added --model haiku), or on sonnet.
        #expect(Self.modelProblem(workers: ["claude-opus-4-1"], verifiers: sonnet, verifierTrailer: "sonnet") != nil)
        #expect(Self.modelProblem(workers: sonnet, verifiers: sonnet, verifierTrailer: "sonnet") != nil)
        // No worker's transcript read (the trailer's "unknown"), or no verifier's.
        #expect(Self.modelProblem(workers: [], verifiers: sonnet, verifierTrailer: "sonnet") != nil)
        #expect(Self.modelProblem(workers: haiku, verifiers: [], verifierTrailer: "sonnet") != nil)
        // A verifier on the workers' family under an alias beside their full id; a trailer that says nothing.
        #expect(Self.modelProblem(workers: haiku, verifiers: ["claude-haiku-4-5-20251001"], verifierTrailer: "haiku") != nil)
        for trailer in [nil, "unknown", "none", "haiku"] {
            #expect(Self.modelProblem(workers: haiku, verifiers: sonnet, verifierTrailer: trailer) != nil, "\(trailer ?? "nil")")
        }
    }

    /// The gated run types an approval only of exactly the audited commit, whatever else a card offers.
    @Test func anApprovalIsTypedOnlyForTheAuditedCommit() {
        let audited = String(repeating: "ab", count: 20), other = String(repeating: "cd", count: 20)
        #expect(Self.approvalOption(["Approve \(audited)", "Not yet"], audited: nil) == nil)
        #expect(Self.approvalOption(["Approve \(other)", "Not yet"], audited: audited) == nil)
        #expect(Self.approvalOption(["Not yet", "Approve \(audited.uppercased())"], audited: audited) == "Approve \(audited.uppercased())")
        #expect(Self.approvalOption(["Approve \(other)", "Approve \(audited)"], audited: audited) == "Approve \(audited)")
    }

    /// The gated run stops, saying so, when a session's screen shows the account's usage limit, and not for the status
    /// line's own count of it.
    @Test func theUsageLimitsNoticeIsToldOnAScreen() {
        #expect(Self.showsUsageLimit("● Working\n  You've hit your weekly limit · resets Nov 18, 6pm (Europe/Madrid)\n❯ 1. Stop and wait"))
        #expect(Self.showsUsageLimit("You've hit your limit · resets 3am") && Self.showsUsageLimit("You've hit your 5-hour limit"))
        #expect(!Self.showsUsageLimit("❯ \n  weekly 29%\n  ⏵⏵ auto mode on (shift+tab to cycle)"))
        #expect(!Self.showsUsageLimit("● The greeting is within the limit of one word."))
    }

    /// A worker's commit is one on its `agent/` branch that touches `src/`: a commit on the base before the branch was
    /// cut (the lead's records, every 5 minutes) isn't one.
    @Test func aWorkersCommitIsOneOnItsBranchThatTouchesSrc() async throws {
        let repo = scratch.url("records-repo")
        let first = try await Self.scratchRepository(in: repo, marker: try Self.markerFile(scratch))
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("records"), withIntermediateDirectories: true)
        try "progress\n".write(to: repo.appendingPathComponent("records/progress.md"), atomically: true, encoding: .utf8)
        try await scratchGit(repo.path, ["add", "--", "records/progress.md"])
        try await scratchGit(repo.path, ["commit", "-q", "-m", "records"])
        try await scratchGit(repo.path, ["branch", "agent/idle", "main"])
        try await scratchGit(repo.path, ["checkout", "-q", "-b", "agent/busy", "main"])
        try "busy\n".write(to: repo.appendingPathComponent("src/busy.txt"), atomically: true, encoding: .utf8)
        try await scratchGit(repo.path, ["add", "--", "src/busy.txt"])
        try await scratchGit(repo.path, ["commit", "-q", "-m", "busy"])
        try await scratchGit(repo.path, ["checkout", "-q", "main"])
        let found = Self.workerBranches(repo, since: first)
        #expect(found.branches == ["agent/busy", "agent/idle"] && found.withoutCommit == ["agent/idle"], "\(found)")
    }

    // MARK: The gated run, a real lead on haiku

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
                   "starts a real Claude Code team on haiku (the verifier on sonnet) and spends the account's usage: set VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR to a Claude Code config folder you logged in once to run it"))
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
        // Room for the team's 4 sessions, and no load or memory hold: the machine's own load isn't the run's (ST-D21).
        try node.noLoadHold(maxSessions: 4)
        step("1, config and base accepted")
        let started = try await cli.run(["lead", repo.path, "--goal", Self.realGoal], typed: true)
        try #require(started.status == 0 && started.output.contains("the lead started"), "\(started.output)\n\(node.said)")
        #expect(started.output.contains(script.resolvingSymlinksInPath().path), "\(started.output)")
        step("2, the lead started")

        // What the run is at, for the record and for a run that stops: each session's screen (empty cells as spaces),
        // the board, the open cards, the node's own log.
        func screen(_ session: HostSession, last: Int = 45) -> String {
            Platform.lines((node.screen(session.id) ?? "no screen").replacingOccurrences(of: "\u{0}", with: " "))
                .map { String($0.reversed().drop { $0 == " " }.reversed()) }.filter { !$0.isEmpty }.suffix(last).joined(separator: "\n")
        }
        func look(_ when: String) async {
            let sessions = ((try? node.sessions()) ?? []).filter(\.isLive)
            let cards = await Self.openCards(node).map { "\($0.text) \($0.options)" }
            print("S10: \(when): the board \(Self.tasks(repo)); cards \(cards)")
            for session in sessions { print("S10: \(when): the screen of \(session.label) (\(session.tty)):\n\(screen(session))") }
            print("S10: \(when): the node said:\n\(node.said.replacingOccurrences(of: "\u{0}", with: " "))")
        }

        // The cards as they come: the lead's question answered with its first option, an approval only of exactly the
        // greeting's audited commit (the vault's verdict), as a user would; until the greeting's task is merged. Each
        // change of what the run is at (the board's tasks, the live sessions, the vault's verdict) is printed with its
        // time. It stops early, saying where, when the account's usage limit shows on a session's screen, when nothing
        // at all moved for `Self.stallLimit` (the board, git's branches, the cards, the sessions and their hooks'
        // last events), and at the suite's limit.
        let expected = slugs[0]
        var greeting = expected
        var question: String?, approvalCard: String?, answeredCards: Set<String> = []
        var merged = false, stopped: String?
        var shown = "", moved = "", movedAt = began
        // The `agent/*` branches seen with a worker's commit (a cleanup takes a merged task's branch away).
        var committed: Set<String> = []
        func noteCommits() {
            let found = Self.workerBranches(repo, since: first)
            committed.formUnion(found.branches.filter { !found.withoutCommit.contains($0) })
        }
        let deadline = began + 55 * 60
        while !merged, stopped == nil, MacTime.real.awake() < deadline {
            let board = BoardStore(root: repo.path).load()
            // The greeting's task as the lead named it (the goal gives its title: the worktree trusted beforehand is its slug's).
            if let named = board.tasks.first(where: { $0.slug == expected })?.slug ?? board.tasks.first(where: { $0.title.lowercased().contains("greeting") })?.slug {
                greeting = named
            }
            for card in await Self.openCards(node) where !answeredCards.contains(card.id) {
                if card.options.contains(where: { LeadVault.approvedCommit(in: $0) != nil }) {
                    // No verdict yet: looked at again on the next round. One on another commit: left unanswered.
                    guard let audited = try await Self.verdict(node, repo, task: greeting)?.commit else { continue }
                    if let offered = Self.approvalOption(card.options, audited: audited) {
                        let ran = try await cli.run(["answer", card.id, offered], typed: true)
                        #expect(ran.status == 0, "\(ran.output)\n\(node.said)")
                        approvalCard = card.id
                        step("the approval answered (\(offered))")
                    } else {
                        Issue.record("an approval card not of the audited \(audited), left unanswered: \(card.text) \(card.options)")
                    }
                } else {
                    let listed = try await cli.run(["questions"])
                    #expect(listed.output.contains(card.id), "\(listed.output)")
                    let ran = try await cli.run(["answer", card.id, card.options.first ?? "Hello"], typed: true)
                    #expect(ran.status == 0 && ran.output.contains("answered: the lead is told"), "\(ran.output)\n\(node.said)")
                    if question == nil { question = card.id }
                    step("the lead's question answered (\(card.text): \(card.options.first ?? "Hello"))")
                }
                answeredCards.insert(card.id)
            }
            merged = board.task(greeting)?.status == .done
            noteCommits()
            let sessions = ((try? node.sessions()) ?? []).filter(\.isLive)
            let verdict = try await Self.verdict(node, repo, task: greeting)
            let state = "tasks \(Self.tasks(repo)); sessions \(sessions.map(\.label).sorted()); committed \(committed.sorted()); "
                + "verdict \(verdict.map { "\($0.passes ? "passes" : "fails") at \($0.commit.prefix(8))" } ?? "none")"
            if state != shown {
                shown = state
                step(state)
            }
            // Anything at all moving: what's shown, git's branches, the cards answered, each session's hooks' last event.
            let hooks = sessions.map { "\($0.tty) \(HookState.load(from: node.root.appendingPathComponent("state/\($0.tty).json"))?.lastEventAt ?? 0)" }
            let now = "\(state) \(Git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: repo.path).output) \(answeredCards.count) \(hooks)"
            if now != moved { (moved, movedAt) = (now, MacTime.real.awake()) }
            if let limited = sessions.first(where: { Self.showsUsageLimit(screen($0)) }) {
                stopped = "the account's usage limit shows on the screen of \(limited.label)"
            } else if MacTime.real.awake() - movedAt > Self.stallLimit {
                stopped = "nothing moved for \(Int(Self.stallLimit / 60)) min"
            }
            if !merged, stopped == nil { try await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        step(merged ? "3, \(greeting) merged" : "3, \(greeting) not merged: \(stopped ?? "the suite's limit")")
        if !merged { await look("stopped (\(stopped ?? "the suite's limit"))") }
        try #require(merged, "\(greeting) never merged: \(stopped ?? "the suite's limit")")

        // Two agent/* branches, each with a worker's commit: the other task's worker may still be at it (waited for,
        // its commit the event).
        let committing = MacTime.real.awake() + 10 * 60
        while committed.count < 2, MacTime.real.awake() < committing {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            noteCommits()
        }
        if committed.count < 2 { await look("the second worker's commit never came") }
        #expect(committed.count == 2, "the agent/* branches with a worker's commit: \(committed.sorted()); now \(Self.workerBranches(repo, since: first))")
        step("both workers committed (\(committed.sorted()))")
        // A verdict in the vault, from a verifier on a model other than the workers': the workers on haiku and the
        // verifier on sonnet, as their transcripts in the config folder say and the landed commit's verifier trailer.
        let verdict = try #require(try await Self.verdict(node, repo, task: greeting), "the vault holds no verdict for \(greeting)")
        #expect(verdict.passes, "\(verdict)")
        let landed = try await Self.landed(repo, since: first).first { Self.trailer("VS-Task", in: $0) == greeting } ?? ""
        let workerModel = Self.trailer("VS-Worker-Model", in: landed), verifierModel = Self.trailer("VS-Verifier-Model", in: landed)
        let ran = [greeting, slugs[1]].map { Self.sessionModels(config: config, root: project, slug: $0) }
        let workers = ran.flatMap(\.workers), verifiers = ran[0].verifiers
        print("S10: the workers ran on \(workers), the verifier on \(verifiers); the trailers say \(workerModel ?? "none") and \(verifierModel ?? "none")")
        #expect(ran.allSatisfy { !$0.workers.isEmpty }, "a worker's transcript missing: \(ran)")
        let problem = Self.modelProblem(workers: workers, verifiers: verifiers, verifierTrailer: verifierModel)
        #expect(problem == nil, "\(problem ?? "")\n\(landed)")
        // The user's approval, of exactly the audited commit, recorded for the greeting's task; and the landed commit's
        // review names that commit.
        #expect(try await Self.approved(node, repo, task: greeting, commit: verdict.commit), "the vault has no approval of \(verdict.commit)")
        #expect(Self.trailer("VS-Review", in: landed)?.contains(String(verdict.commit.prefix(12))) == true, "\(landed)")
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
            verifier_model: sonnet
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
    /// with the config folder given and the node's own update and traffic switches, and `--model haiku` only when its
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
            exec \(quote(claude)) --model haiku "$@"

            """, at: script)
        let link = root.appendingPathComponent("claude")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil || FileManager.default.fileExists(atPath: link.path) {
            try FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: script.path)
        return script
    }

    /// The `agent/*` branches, `count` of them, each with a worker's commit (`workerBranches`).
    static func assertWorkersCommitted(_ repo: URL, since first: String, count: Int, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let found = workerBranches(repo, since: first)
        #expect(found.branches.count == count, "\(found.branches)", sourceLocation: sourceLocation)
        #expect(found.withoutCommit.isEmpty, "no worker's commit on \(found.withoutCommit)", sourceLocation: sourceLocation)
    }

    /// The `agent/*` branches, and those of them with no worker's commit: none past `first` touching `src/` (a commit
    /// on the base before the branch was cut, the lead's records every 5 minutes, isn't one).
    static func workerBranches(_ repo: URL, since first: String) -> (branches: [String], withoutCommit: [String]) {
        let branches = Platform.lines(Git.run(["for-each-ref", "--format=%(refname:short)", "refs/heads/agent/"], in: repo.path).output)
        return (branches, branches.filter { (Int(Git.run(["rev-list", "--count", "\(first)..\($0)", "--", "src/"], in: repo.path).output) ?? 0) < 1 })
    }

    /// The board's tasks, each with its status, in a line.
    static func tasks(_ repo: URL) -> [String] { BoardStore(root: repo.path).load().tasks.map { "\($0.slug) \($0.status.rawValue)" } }

    /// How long the gated run waits with nothing at all moving before it stops and says where it is.
    static let stallLimit: TimeInterval = 12 * 60

    /// Whether a session's screen shows Claude Code's notice of the account's usage limit ("You've hit your weekly
    /// limit · resets …", 2.1.325).
    static func showsUsageLimit(_ screen: String) -> Bool {
        screen.range(of: #"hit your [a-z0-9\- ]*limit"#, options: [.regularExpression, .caseInsensitive]) != nil
            || screen.range(of: "usage limit reached", options: .caseInsensitive) != nil
    }

    /// The models `slug`'s worker and verifier sessions ran on, from their transcripts in the Claude Code config folder
    /// `config` (`$CLAUDE_CONFIG_DIR/projects`, where the real-claude script's sessions write; the node's own
    /// `receiptUsage` reads its scratch home's), each session told by its name (`LeadReceipts.role`).
    static func sessionModels(config: URL, root: String, slug: String) -> (workers: [String], verifiers: [String]) {
        let projects = config.appendingPathComponent("projects")
        var files: [(role: LeadReceipts.Role, url: URL)] = []
        for folder in LeadReceipts.folders(root: root, slug: slug, home: "/").map({ projects.appendingPathComponent($0.lastPathComponent) }) {
            let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in found where file.pathExtension == "jsonl" {
                if let role = LeadReceipts.role(named: LeadReceipts.names(in: file), slug: slug) { files.append((role, file)) }
            }
        }
        let usage = LeadReceipts.usage(files, since: 0)
        return (usage.worker?.models ?? [], usage.verifier?.models ?? [])
    }

    /// What's wrong with the run's models against ST-D21 with the models swapped (workers on haiku, the verifier on
    /// sonnet, and the landed commit's `VS-Verifier-Model` saying sonnet); nil when nothing is.
    static func modelProblem(workers: [String], verifiers: [String], verifierTrailer: String?) -> String? {
        if workers.isEmpty { return "no worker's transcript was read" }
        if let off = workers.first(where: { !LeadReviewFloor.sameModel($0, "haiku") }) { return "a worker ran on \(off), not haiku" }
        if verifiers.isEmpty { return "no verifier's transcript was read" }
        if let off = verifiers.first(where: { !LeadReviewFloor.sameModel($0, "sonnet") }) { return "the verifier ran on \(off), not sonnet" }
        guard let trailer = verifierTrailer, LeadReviewFloor.knownModel(trailer), LeadReviewFloor.sameModel(trailer, "sonnet") else {
            return "the landed commit's verifier model is \(verifierTrailer ?? "missing"), not sonnet"
        }
        return nil
    }

    /// The option of `options` approving exactly `audited` (the verdict's commit); nil while there's no verdict, or when
    /// none approves it.
    static func approvalOption(_ options: [String], audited: String?) -> String? {
        guard let audited = audited?.lowercased() else { return nil }
        return options.first { LeadVault.approvedCommit(in: $0) == audited }
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
