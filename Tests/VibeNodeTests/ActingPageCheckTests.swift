import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// Acting from the page, end to end (the redesign's "Acting from the page"): a scratch node with `web_acts trust` set
/// from a terminal, a lead asking two questions and a long approval, the page (WebApp/ as it is) paired with a fresh
/// code and confirmed the way the user does it: the three words the page shows, typed into the terminal's side
/// (`web.confirm`, the scratch form). Then scripts/e2e/acting-page-check.cjs, in headless Chrome, must:
/// - Pair: show the phrase until the terminal confirms the page, then act, the pairing's secret nowhere but in memory;
/// - Answer by click: a question answered by clicking its option;
/// - Approve: the long approval approved by clicking its "Approve <commit>";
/// - Changed: a question the lead reworded after the page drew it (its frames held back meanwhile) is refused as
///   `changed`, "look again", and nothing is done;
/// - Send now: the message box's second button sends to the lead's session at once, saying what became of it;
/// - Older build: the served page changed under the acting tab: at its next hello it says it is from an older build,
///   with Reload and what reloading costs, and still acts;
/// - Level off: the page's own Turn off lowers `web_acts`, and the page reads and drafts again, saying so at the top;
/// - Reloaded: reloaded, the tab says it no longer acts (its pairing lived in its memory) and to pair again;
/// - Two tabs: a second tab opened by hand acts with the first one's pairing, held in memory only;
/// - Can't act yet: acting on again with no tab paired: one plain banner with the command, a pick one line, not sent;
/// - Console: no error.
/// The node's record must then hold the two answers and the setting, each the page's.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)),
       .enabled(if: PageCheckBrowser.runs, "no Chrome (google-chrome, or $CHROME) or no node here: the page check runs where both are (the Linux CI)"))
struct ActingPageCheckTests {
    private let scratch = Scratch()

    @Test func thePageActsOnceConfirmedInTheTerminal() async throws {
        let chrome = try #require(PageCheckBrowser.chrome, "no Chrome on the CI's runner: the page check needs the image's google-chrome")
        // The page's files from a copy of WebApp/ (a scratch server's folder, read at each request), so the test can change
        // the served page under an open tab.
        let webApp = scratch.url("WebApp").path
        try FileManager.default.copyItem(atPath: ServerLintTests.repo.appendingPathComponent("WebApp").path, toPath: webApp)
        try? FileManager.default.removeItem(atPath: webApp + "/shots")
        let node = try await ScratchNode(scratch, holdFirstLook: true,
                                         hostArguments: LiveScratch.webArguments + ["--server-arg", ServerArguments.testWebRootFlag + webApp])
        defer { node.stop() }

        // Acting from the page, turned on from a terminal (the user's voice).
        let trust = try await node.runOnTerminal(["set", "web_acts", "trust"])
        try #require(trust.status == 0, "set web_acts trust: \(trust.output)\n\(node.said)")

        // A lead on a scratch repository whose upload code is sensitive, asking: a question, an approval of a commit
        // touching ten sensitive files, and a second question the test rewords while the page holds its frames.
        let repo = node.root.appendingPathComponent("example-app")
        try await scratchRepository(repo)
        try EngineEndToEndTests.workflow(repo)
        try "---\ntest_command: true\nmerge_policy: ask_all\naudit_finders: 1\nsensitive_paths: Sources/Upload/**\n---\n"
            .write(toFile: ConfigHoldStore.workflowPath(root: repo.path), atomically: true, encoding: .utf8)
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

        let first = "Launch the onboarding page to the testers on Thursday, or wait for the copy review?"
        try tools.call("ask_user", ["question": first, "options": ["Thursday", "Wait for the review"]])
        try #require(await eventually(timeout: 120) { tools.calls().count == 1 }, "\(node.said)")
        _ = try await scratchGit(repo.path, ["checkout", "-q", "-b", "agent/upload-retry"])
        for index in 1...10 {
            let file = repo.appendingPathComponent("Sources/Upload/Part\(index).swift")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "// part \(index) of the upload retry\nlet part\(index) = \(index)\n".write(to: file, atomically: true, encoding: .utf8)
        }
        _ = try await scratchGit(repo.path, ["add", "-A"])
        _ = try await scratchGit(repo.path, ["commit", "-q", "-m", "upload: retry a failed upload once"])
        let approved = try await scratchGit(repo.path, ["rev-parse", "HEAD"])
        _ = try await scratchGit(repo.path, ["checkout", "-q", "main"])
        let approval = "Merge the upload retry task (`upload-retry`) at `\(approved.prefix(8))`? Its audit passed.\n\n**What it changes:**\n"
            + "- **A failed upload is retried once.** The retry waits a second.\n- Ten files, all upload code."
        try tools.call("ask_user", ["question": approval, "options": ["Approve \(approved)", "Not yet"]])
        try #require(await eventually(timeout: 120) { tools.calls().count == 2 }, "\(node.said)")
        let second = "Keep the old pricing table until Friday, or drop it today?"
        try tools.call("ask_user", ["question": second, "options": ["Keep it until Friday", "Drop it today"]])
        try #require(await eventually(timeout: 120) { tools.calls().count == 3 }, "\(node.said)")
        let secondID = try #require(try BoardStore(root: repo.path).read().questions.first { $0.text == second }?.id, "the second question on the board")

        // The three cards open on the node before the page looks.
        var open = 0
        let until = MacTime.real.awake() + 120
        while open < 3, MacTime.real.awake() < until {
            let listed = try await node.run(["questions", "--json"])
            let cards = ((try? JSONSerialization.jsonObject(with: Data(listed.output.utf8)) as? [String: Any])?["cards"] as? [[String: Any]]) ?? []
            open = cards.filter { ["question", "approval"].contains($0["kind"] as? String) }.count
            if open < 3 { try await Task.sleep(nanoseconds: 300_000_000) }
        }
        try #require(open == 3, "\(open) cards open\n\(node.said)")

        let opened = try LiveScratch.open(node)
        let out = scratch.url("acting-page-check")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let codeID = PagePairing.codeID(digest: WebTokens.digest(opened.code))
        // The terminal's side, as the script asks for it through files in `out`: the phrase the page shows, typed into
        // `web.confirm` (`phrase`); the second question reworded by its lead while the page holds its frames
        // (`revise.want`, answered with `revise.done` once the node shows the new wording).
        let terminal = Task {
            var confirmed = false
            var revised = false
            var switched = false
            var trusted = false
            let end = MacTime.real.awake() + 200
            while !(confirmed && revised && switched && trusted), MacTime.real.awake() < end, !Task.isCancelled {
                if !trusted, FileManager.default.fileExists(atPath: out.appendingPathComponent("trust.want").path) {
                    let again = try await node.runOnTerminal(["set", "web_acts", "trust"])
                    try #require(again.status == 0, "set web_acts trust again: \(again.output)")
                    try "done".write(to: out.appendingPathComponent("trust.done"), atomically: true, encoding: .utf8)
                    trusted = true
                }
                if !switched, FileManager.default.fileExists(atPath: out.appendingPathComponent("switch.want").path) {
                    // Build B: one byte more in one file changes the build the node names in its hello.
                    let words = URL(fileURLWithPath: webApp).appendingPathComponent("js/words.js")
                    try (try String(contentsOf: words, encoding: .utf8) + "\n// build B\n").write(to: words, atomically: true, encoding: .utf8)
                    try "done".write(to: out.appendingPathComponent("switch.done"), atomically: true, encoding: .utf8)
                    switched = true
                }
                if !confirmed, let phrase = try? String(contentsOf: out.appendingPathComponent("phrase"), encoding: .utf8) {
                    let client = try WireClient(node)
                    let reply = try #require(WireClient.reply(client.request("web.confirm", args: ["code": .string(codeID), "phrase": .string(phrase.trimmingCharacters(in: .whitespacesAndNewlines))])),
                                             "no reply to web.confirm: \(node.said)")
                    try #require(reply.ok, "web.confirm with the page's phrase: \(reply)")
                    confirmed = true
                }
                if !revised, FileManager.default.fileExists(atPath: out.appendingPathComponent("revise.want").path) {
                    try tools.call("revise_question", ["id": secondID, "text": second.replacingOccurrences(of: "Friday", with: "Monday"),
                                                       "note": "The pricing review moved to Monday"])
                    var shown = false
                    let by = MacTime.real.awake() + 60
                    while !shown, MacTime.real.awake() < by {
                        shown = ((try? await node.run(["questions", "--json"]))?.output ?? "").contains("until Monday")
                        if !shown { try await Task.sleep(nanoseconds: 300_000_000) }
                    }
                    try #require(shown, "the reworded question never reached the node's cards\n\(node.said)")
                    try "done".write(to: out.appendingPathComponent("revise.done"), atomically: true, encoding: .utf8)
                    revised = true
                }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { terminal.cancel() }

        let expect: [String: String] = [
            "projectHref": "#/p/" + NodeIds.project(root: repo.path).addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "/lead",
            "first": "Launch the onboarding page", "firstOption": "Thursday", "approval": "Merge the upload retry task", "approve": "Approve \(approved)",
            "second": "Keep the old pricing table", "secondOption": "Keep it until Friday",
        ]
        let expectFile = scratch.url("acting-page-check-expect.json")
        try JSONSerialization.data(withJSONObject: expect).write(to: expectFile)
        let said = scratch.url("acting-page-check.out")
        _ = FileManager.default.createFile(atPath: said.path, contents: nil)
        let script = ServerLintTests.repo.appendingPathComponent("scripts/e2e/acting-page-check.cjs").path
        let status = try await offPool {
            try runToEnd("/usr/bin/env", ["node", script, opened.url, expectFile.path, out.path, chrome],
                         environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": node.home.path]
                            .merging(ProcessInfo.processInfo.environment["PAGE_SHOTS"].map { ["PAGE_SHOTS": $0] } ?? [:]) { $1 },
                         output: .path(said.path, flags: O_WRONLY | O_TRUNC), limit: 240)
        }
        let table = (try? String(contentsOf: said, encoding: .utf8)) ?? ""
        for row in ["Pair", "Two tabs", "Answer by click", "Approve", "Changed", "Send now", "Older build", "Level off", "Reloaded", "Can’t act yet", "Console"] {
            #expect(table.split(separator: "\n").contains { $0.hasPrefix(row + " ") && $0.contains(" pass ") }, "\(row):\n\(table)")
        }
        #expect(status == 0, "\(table)\n\(node.said)")
        // The node's record: the two answers and the setting made from the page (no command line: the page's), besides
        // the test's own from a terminal (the level, the accepts, the lead).
        let accepted = (try await node.statusJSON())["accepted"] as? [[String: Any]] ?? []
        let fromPage = accepted.filter { ($0["commandLine"] as? [Any])?.isEmpty == true }.compactMap { $0["kind"] as? String }
        #expect(fromPage == ["answer", "answer", "send", "set"], "\(accepted)")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        // With PAGE_SHOTS=DIR, its screenshots there too, named acting-*.png (WebApp/shots/ is made that way).
        if let shots = ProcessInfo.processInfo.environment["PAGE_SHOTS"] {
            for file in files where file.hasSuffix(".png") {
                let to = URL(fileURLWithPath: shots).appendingPathComponent("acting-" + file)
                try? FileManager.default.removeItem(at: to)
                try? FileManager.default.copyItem(at: out.appendingPathComponent(file), to: to)
            }
        }
        #expect(files.contains("report.json") && !files.contains { $0.hasPrefix("chrome-profile-") }, "\(files)")
    }
}
