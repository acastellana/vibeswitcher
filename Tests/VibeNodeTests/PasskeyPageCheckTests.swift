import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The level `confirm`, end to end in a browser: a scratch node, a lead asking one question, the page (WebApp/ as it
/// is) opened at http://localhost:PORT with a fresh code and confirmed by its words; then scripts/e2e/passkey-page-check.cjs,
/// in headless Chrome with DevTools' virtual authenticator (CTAP2, internal, user verification on and given), must:
/// - Pair: show its three words until the terminal confirms them (the test types them into `web.confirm`);
/// - Register: show the passkey offer the terminal sent it by its words (`web.passkey`), make the key on a click, and,
///   once the terminal kept it (`web.passkey.add`) and set `web_acts confirm`, go on;
/// - Act: answer the question by clicking its option: a challenge, the authenticator's assertion, the act done and the
///   line the node recorded shown;
/// - Console: no error.
/// The node's record must then hold the answer, the page's, its mark naming what the passkey approved.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)),
       .enabled(if: PageCheckBrowser.runs, "no Chrome (google-chrome, or $CHROME) or no node here: the page check runs where both are (the Linux CI)"))
struct PasskeyPageCheckTests {
    private let scratch = Scratch()

    @Test func thePageActsWithAPasskeyAtConfirm() async throws {
        let chrome = try #require(PageCheckBrowser.chrome, "no Chrome on the CI's runner: the page check needs the image's google-chrome")
        let webApp = ServerLintTests.repo.appendingPathComponent("WebApp").path
        let node = try await ScratchNode(scratch, holdFirstLook: true,
                                         hostArguments: LiveScratch.webArguments + ["--server-arg", ServerArguments.testWebRootFlag + webApp])
        defer { node.stop() }

        // A lead asking one question.
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
        let first = "Launch the onboarding page to the testers on Thursday, or wait for the copy review?"
        try tools.call("ask_user", ["question": first, "options": ["Thursday", "Wait for the review"]])
        try #require(await eventually(timeout: 120) { tools.calls().count == 1 }, "\(node.said)")
        var asked = false
        let until = MacTime.real.awake() + 120
        while !asked, MacTime.real.awake() < until {
            asked = ((try? await node.run(["questions", "--json"]))?.output ?? "").contains("Launch the onboarding page")
            if !asked { try await Task.sleep(nanoseconds: 300_000_000) }
        }
        try #require(asked, "the question's card never came\n\(node.said)")

        let opened = try LiveScratch.open(node, localhost: true)
        try #require(opened.url.hasPrefix("http://localhost:"), "\(opened.url)")
        let out = scratch.url("passkey-page-check")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let codeID = PagePairing.codeID(digest: WebTokens.digest(opened.code))
        // The terminal's side, as the script asks for it through files in `out`: the page's words confirmed
        // (`web.confirm`); a passkey asked of that page by its words (`web.passkey`), kept once it made one
        // (`web.passkey.add`), and the level set to `confirm` from a terminal (the user's voice).
        let terminal = Task {
            var confirmed = false
            var kept = false
            let end = MacTime.real.awake() + 200
            while !(confirmed && kept), MacTime.real.awake() < end, !Task.isCancelled {
                if !confirmed, let phrase = try? String(contentsOf: out.appendingPathComponent("phrase"), encoding: .utf8) {
                    let client = try WireClient(node)
                    let reply = try #require(WireClient.reply(client.request("web.confirm", args: ["code": .string(codeID), "phrase": .string(phrase.trimmingCharacters(in: .whitespacesAndNewlines))])))
                    try #require(reply.ok, "web.confirm: \(reply)")
                    confirmed = true
                }
                if confirmed, !kept, let phrase = try? String(contentsOf: out.appendingPathComponent("passkey.want"), encoding: .utf8) {
                    let client = try WireClient(node)
                    let asked = try #require(WireClient.reply(client.request("web.passkey", args: ["phrase": .string(phrase)], action: nil)))
                    let register = try #require(asked.result?["register"]?.string, "web.passkey: \(asked)")
                    var received = false
                    let by = MacTime.real.awake() + 60
                    while !received, MacTime.real.awake() < by {
                        let state = try WireClient.reply(WireClient(node).request("web.passkey", args: ["register": .string(register)], action: nil))
                        received = state?.result?["state"]?.string == "received"
                        if !received { try await Task.sleep(nanoseconds: 200_000_000) }
                    }
                    try #require(received, "the page made no passkey\n\(node.said)")
                    let added = try #require(WireClient.reply(WireClient(node).request("web.passkey.add", args: ["register": .string(register)])))
                    try #require(added.ok, "web.passkey.add: \(added)")
                    let level = try await node.runOnTerminal(["set", "web_acts", "confirm"])
                    try #require(level.status == 0, "set web_acts confirm: \(level.output)")
                    try "done".write(to: out.appendingPathComponent("passkey.done"), atomically: true, encoding: .utf8)
                    kept = true
                }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { terminal.cancel() }

        let expect: [String: String] = [
            "projectHref": "#/p/" + NodeIds.project(root: repo.path).addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "/lead",
            "first": "Launch the onboarding page", "firstOption": "Thursday",
        ]
        let expectFile = scratch.url("passkey-page-check-expect.json")
        try JSONSerialization.data(withJSONObject: expect).write(to: expectFile)
        let said = scratch.url("passkey-page-check.out")
        _ = FileManager.default.createFile(atPath: said.path, contents: nil)
        let script = ServerLintTests.repo.appendingPathComponent("scripts/e2e/passkey-page-check.cjs").path
        let status = try await offPool {
            try runToEnd("/usr/bin/env", ["node", script, opened.url, expectFile.path, out.path, chrome],
                         environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": node.home.path],
                         output: .path(said.path, flags: O_WRONLY | O_TRUNC), limit: 240)
        }
        var table = (try? String(contentsOf: said, encoding: .utf8)) ?? ""
        if status != 0 { table += "\nframes:\n" + ((try? String(contentsOf: out.appendingPathComponent("frames.log"), encoding: .utf8)) ?? "").suffix(4_000) }
        for row in ["Pair", "Register", "Act", "Console"] {
            #expect(table.split(separator: "\n").contains { $0.hasPrefix(row + " ") && $0.contains(" pass ") }, "\(row):\n\(table)\n\(node.said)")
        }
        #expect(status == 0, "\(table)")
        let accepted = (try await node.statusJSON())["accepted"] as? [[String: Any]] ?? []
        let fromPage = accepted.filter { ($0["commandLine"] as? [Any])?.isEmpty == true }.compactMap { $0["kind"] as? String }
        #expect(fromPage == ["answer"], "\(accepted)")
    }
}
