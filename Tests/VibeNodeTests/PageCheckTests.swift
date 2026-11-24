import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The page's DOM code against real server data, in headless Chrome (the architecture review's row 12): a scratch node
/// made to hold what each main view draws (a hooked agent with a conversation, a lead asking a question with a made-up
/// board, a session's shell request through the shell plugin), serving WebApp/ as it is, paired with a fresh code
/// (`web.open`, the scratch form), and scripts/e2e/page-check.cjs must find each view of the redesigned page drawn from
/// it with no console error: the projects and own sessions, a chat, the question card in the waiting block, the lead
/// conversation and its side sheet, the Team tab's task in place, the replaced lead, the shell card, the roadmap and the
/// old address, deep links, This node's Health and Plugins, the settings, Spanish, and a phone's width. With
/// PAGE_SHOTS=DIR in the environment it leaves the main states' screenshots there (WebApp/shots/ is made that way).
/// It runs in the Linux CI's core job, whose runner has Google Chrome; where there is no Chrome or no node it is
/// skipped, saying so.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)),
       .enabled(if: PageCheckBrowser.runs, "no Chrome (google-chrome, or $CHROME) or no node here: the page check runs where both are (the Linux CI)"))
struct PageCheckTests {
    private let scratch = Scratch()

    /// A session the node lists as an agent's (the fake `claude`, hooked: its turn done) that files a shell request for
    /// `command` first (`vibeswitcher-mcp --shell-request`, as Resources/bin/vs-shell runs it), then waits.
    static func askShell(_ node: ScratchNode, command: String) async throws -> HostSession {
        let folder = node.home.appendingPathComponent("example-asker")
        let bin = node.root.appendingPathComponent("fake-bin")
        for made in [folder, bin] { try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true) }
        let claude = bin.appendingPathComponent("claude")
        if !FileManager.default.fileExists(atPath: claude.path) {
            try copyClosedOnExec(URL(fileURLWithPath: "/bin/sleep").resolvingSymlinksInPath().path, to: claude.path)
        }
        let out = node.root.appendingPathComponent("asker.out")
        let mcp = builtProducts.appendingPathComponent("vibeswitcher-mcp").path
        let session = try await node.spawn("env VIBESWITCHER_HOME='\(node.root.path)' '\(mcp)' --shell-request run --label page-check -- \(command) "
                                           + "> '\(out.path).part' 2>&1; echo \"status $?\" >> '\(out.path).part'; mv '\(out.path).part' '\(out.path)'; "
                                           + "exec '\(claude.path)' 600", cwd: folder.path, label: "Asker", agent: "claude")
        try #require(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: out.path) }, "\(node.screen(session.id) ?? "")\n\(node.said)")
        let said = try String(contentsOf: out, encoding: .utf8)
        try #require(said.contains("status 0"), "\(said)")
        try #require(await eventually(timeout: 60) { ProcessTable.info(pid: session.childPID)?.comm == "claude" }, "the asker never became the agent")
        try HookedAgent(session: session, pid: session.childPID, folder: folder).hook(node, "Stop")
        return session
    }

    @Test func eachMainViewDrawsTheNodesDataWithNoConsoleError() async throws {
        let chrome = try #require(PageCheckBrowser.chrome, "no Chrome on the CI's runner: the page check needs the image's google-chrome")
        // The page's files from WebApp/ itself (a scratch server's folder, served with the embedded files' policy): the
        // DOM code of this commit, whether or not its embed was regenerated.
        let webApp = ServerLintTests.repo.appendingPathComponent("WebApp").path
        let node = try await ScratchNode(scratch, holdFirstLook: true,
                                         hostArguments: LiveScratch.webArguments + ["--server-arg", ServerArguments.testWebRootFlag + webApp])
        defer { node.stop() }

        // A session with a conversation in its transcript.
        let site = try await HookedAgent.start(node, project: "example-site")
        let transcript = node.home.appendingPathComponent(".claude/projects/-example-site/5c1e7a20-3b4d-4e8f-9a6b-1c2d3e4f5a6b.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(SandboxChat(folder: site.folder.path).opening.map { $0 + "\n" }.joined().utf8).write(to: transcript)
        try site.hook(node, "UserPromptSubmit", transcript: transcript)

        // A lead on a scratch repository, started as the user starts one, asking one question; a made-up board for it.
        let repo = node.root.appendingPathComponent("example-app")
        try await scratchRepository(repo)
        try EngineEndToEndTests.workflow(repo)
        let head = Git.run(["rev-parse", "main"], in: repo.path).output
        try await node.acceptConfig(repo)
        try await node.acceptBase(repo, from: head)
        let started = try await node.runOnTerminal(["lead", repo.path, "--goal", "Ship the onboarding page"])
        try #require(started.status == 0, "the lead didn't start: \(started.output)\n\(node.said)")
        let lead = try #require(try node.sessions().first { $0.isLive && $0.label.hasPrefix("Lead · ") }, "\(node.said)")
        let tools = node.fake.files(terminal: lead.tty)
        try #require(await eventually(timeout: 60) { EngineEndToEndTests.state(tools)["pid"] != nil }, "\(node.said)")
        let leadPID = try #require((EngineEndToEndTests.state(tools)["pid"] as? Int).map(Int32.init))
        try hook(node, ["hook_event_name": "Stop"], tty: lead.tty, pid: leadPID)
        let question = "Launch the onboarding page to the testers on Thursday, or wait for the copy review?"
        try tools.call("ask_user", ["question": question, "options": ["Thursday", "Wait for the review"]])
        try #require(await eventually(timeout: 120) { tools.calls().count == 1 }, "\(node.said)")
        // The sample board with its two goals (the launch, open, with the first two tasks; the uploads, done), the rest unsorted.
        let made = WireVectors.goaled(WireVectors.sampleBoard(now: Date().timeIntervalSince1970, worker: site.session.id), now: Date().timeIntervalSince1970)
        // A result the lead posted, its body markdown with a table: the conversation's line and the side sheet's.
        let result = "The pricing page has its new copy"
        let goals = WireVectors.sampleGoals(now: Date().timeIntervalSince1970)
        try GoalStore(root: repo.path).update { $0 = goals }
        try BoardStore(root: repo.path).update {
            $0.tasks = made.tasks
            $0.updates = [LeadUpdate(id: "page-check-result", title: result, body: "What changed:\n\n| Plan | Price |\n|---|---|\n| Starter | $9 |\n| Team | $29 |")]
        }
        // A second project, with no goals and no estimates: its roadmap draws the plain form (in motion, blocked, the
        // queue as a band), no time axis.
        let docs = node.root.appendingPathComponent("example-docs")
        try await scratchRepository(docs)
        try EngineEndToEndTests.workflow(docs)
        let docsHead = Git.run(["rev-parse", "main"], in: docs.path).output
        try await node.acceptConfig(docs)
        try await node.acceptBase(docs, from: docsHead)
        let docsStarted = try await node.runOnTerminal(["lead", docs.path, "--goal", "Write the setup guide"])
        try #require(docsStarted.status == 0, "the second lead didn't start: \(docsStarted.output)\n\(node.said)")
        let plain = WireVectors.sampleBoard(now: Date().timeIntervalSince1970, worker: site.session.id)
        try BoardStore(root: docs.path).update { $0.tasks = plain.tasks }

        // The lead's latest statement (a decision in its records), which a short conversation shows at its top.
        let statement = "Ship the copy first and the pricing table after"
        try BoardStore(root: repo.path).appendDecision(statement, why: "The table waits on the plan names")

        // A second lead session of the project that its board doesn't name: a lead it replaced, still running, as four
        // were on the real node on 2026-11-23 while a merge held the rotation gate (the engine ends a replaced lead only
        // under it, exclusively). The gate held here the same way, shared, until the page has looked: the project's
        // lead keeps its Team tab, and the replaced one's row says replaced and has none.
        let gate = try #require(FileLock.attempt(LeadRotation.gate(repo.path), shared: true))
        defer { gate.release() }
        let former = try await HookedAgent.start(node, folder: repo, label: "Lead · example-app")
        let formerID = NodeIds.session(host: former.session.id)
        var leads: [[String: Any]] = []
        var marked = false
        let until = MacTime.real.awake() + 60
        while !marked, MacTime.real.awake() < until {
            leads = ((try? await node.statusJSON())?["leads"] as? [[String: Any]]) ?? []
            marked = leads.contains { ($0["replaced"] as? [String])?.contains(formerID) == true && $0["session"] as? String == NodeIds.session(host: lead.id) }
            if !marked { try await Task.sleep(nanoseconds: 300_000_000) }
        }
        try #require(marked, "the second lead session never read as replaced: \(leads)\n\(node.said)")

        // A listed session's shell request through the shell plugin (`vs-shell`, filed as its tool server files one): an
        // agent's session (the fake `claude`, hooked) whose first act is the request, so its card shows under its chat.
        let asker = try await Self.askShell(node, command: "echo page-check-ran")

        // Both cards open on the node before the page looks (the shell plugin's look is the node's every 15 s).
        let deadline = MacTime.real.awake() + 120
        var kinds: Set<String> = []
        while MacTime.real.awake() < deadline {
            let listed = try await node.run(["questions", "--json"])
            let cards = ((try? JSONSerialization.jsonObject(with: Data(listed.output.utf8)) as? [String: Any])?["cards"] as? [[String: Any]]) ?? []
            kinds = Set(cards.compactMap { $0["kind"] as? String })
            if kinds.isSuperset(of: ["question", "plugin"]) { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        try #require(kinds.isSuperset(of: ["question", "plugin"]), "cards: \(kinds)\n\(node.said)")

        let launch = try #require(goals.goals.first, "the sample board's goals")
        let opened = try LiveScratch.open(node)
        let expect: [String: String] = [
            "session": "example-site", "chatHref": "#/s/" + NodeIds.session(host: site.session.id),
            "chat": "The headline never wraps",
            "projectHref": "#/p/" + NodeIds.project(root: repo.path).addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "/lead",
            "question": "Launch the onboarding page to the testers", "result": result, "task": made.tasks[0].slug, "statement": statement,
            "shellHref": "#/s/" + NodeIds.session(host: asker.id), "shell": "echo page-check-ran",
            "board": made.tasks[0].title, "goal": launch.title, "goalID": launch.id, "estimated": made.tasks[1].slug,
            "plainHref": "#/p/" + NodeIds.project(root: docs.path).addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "/roadmap",
            "plainTask": plain.tasks[1].title,
            "replacedHref": "#/s/" + formerID,
            "plugin": "Shell requests", "setting": "Boost",
        ]
        let expectFile = scratch.url("page-check-expect.json")
        try JSONSerialization.data(withJSONObject: expect).write(to: expectFile)
        let out = scratch.url("page-check")
        let said = scratch.url("page-check.out")
        _ = FileManager.default.createFile(atPath: said.path, contents: nil)
        let script = ServerLintTests.repo.appendingPathComponent("scripts/e2e/page-check.cjs").path
        let status = try await offPool {
            try runToEnd("/usr/bin/env", ["node", script, opened.url, expectFile.path, out.path, chrome],
                         environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": node.home.path]
                            .merging(ProcessInfo.processInfo.environment["PAGE_SHOTS"].map { ["PAGE_SHOTS": $0] } ?? [:]) { $1 },
                         output: .path(said.path, flags: O_WRONLY | O_TRUNC), limit: 240)
        }
        let table = (try? String(contentsOf: said, encoding: .utf8)) ?? ""
        for row in ["Projects and own sessions", "Chat", "Question card", "Lead conversation", "Latest statement", "What waits elsewhere", "Side sheet", "Team tab",
                    "Replaced lead", "Shell card", "Roadmap", "Roadmap dates", "Task estimate", "Estimates in Stats", "Plain roadmap",
                    "Deep links", "This node", "Settings", "Language", "Phone", "Console"] {
            #expect(table.split(separator: "\n").contains { $0.hasPrefix(row + " ") && $0.contains(" pass ") }, "\(row):\n\(table)")
        }
        #expect(status == 0, "\(table)\n\(node.said)")
        // Read-only: nothing that acts reached the node from the page (the accepted are the test's own: the accepts and the lead).
        let accepted = ((try await node.statusJSON())["accepted"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
        #expect(Set(accepted).isSubset(of: ["config.accept", "base.accept", "lead"]), "\(accepted)")
        // No Chrome profile left behind.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        #expect(files.contains("report.json") && !files.contains { $0.hasPrefix("chrome-profile-") }, "\(files)")
    }
}

/// What the page check needs on this machine.
enum PageCheckBrowser {
    /// Chrome, as scripts/e2e/chrome-cdp.cjs's `findChrome` looks for it: `$CHROME`, else Google Chrome's or Chromium's usual paths.
    static let chrome: String? = {
        let candidates = [ProcessInfo.processInfo.environment["CHROME"], "/opt/google/chrome/chrome", "/usr/bin/google-chrome",
                          "/usr/bin/google-chrome-stable", "/usr/bin/chromium", "/usr/bin/chromium-browser"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()
    static let hasNode = (try? runToEnd("/usr/bin/env", ["node", "--version"], output: .path("/dev/null", flags: O_WRONLY), limit: 30)) == 0
    /// Whether the check runs: where Chrome and node are, and always on GitHub's runners (`GITHUB_ACTIONS`), where a
    /// missing Chrome is a failure, not a skip that passes unseen.
    static var runs: Bool { (chrome != nil && hasNode) || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" }
}
