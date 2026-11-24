import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// scripts/e2e/real-page-check.sh, the real node's page rows in one step (docs/process/v2-acceptance.md), run here against
/// a scratch node's page: the scratch form's `web.open` gives the pairing URL the user's `vibeswitcher web` would, a
/// hooked fake agent is its listed session, its terminal watched as the user's node watches one, and the script's table must say pass for what a scratch node shows (A3's
/// pairing, chat, inspector, settings and console, statistics, health, between leads, A10, A19, A23), skip for what it
/// doesn't hold (no project, so no lead conversation, side sheet or roadmap; no ports, no shell card), and fail for nothing. Only where Chrome and node are (not the CI).
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/google/chrome/chrome")
                && (try? runToEnd("/usr/bin/env", ["node", "--version"], output: .path("/dev/null", flags: O_WRONLY), limit: 30)) == 0,
                "needs Chrome at /opt/google/chrome/chrome and node"))
struct RealPageCheckTests {
    private let scratch = Scratch()

    @Test func theScriptChecksAScratchNodesPageReadOnly() async throws {
        let node = try await ScratchNode(scratch, hostArguments: TerminalRelayTests.watchArguments)
        defer { node.stop() }
        let agent = try await HookedAgent.start(node)
        try agent.hook(node, "Stop")
        let opened = try LiveScratch.open(node)
        let out = scratch.url("real-page")
        let said = scratch.url("real-page.out")
        FileManager.default.createFile(atPath: said.path, contents: nil)
        let script = ServerLintTests.repo.appendingPathComponent("scripts/e2e/real-page-check.sh").path
        // The terminal's side of the pairing (the acting review's fix A): once the script's page takes the code, it is
        // confirmed as `vibeswitcher web` does (the scratch form), so the page watches the terminals (fix C).
        let confirming = Task {
            _ = await eventually(timeout: 120) {
                guard let client = try? WireClient(node),
                      let pairing = try? WireClient.reply(client.request("web.pairing", args: ["code": .string(PagePairing.codeID(digest: WebTokens.digest(opened.code)))], action: nil)),
                      pairing.result?["state"]?.string == "taken" else { return false }
                try? LiveScratch.confirm(node, code: opened.code)
                return true
            }
        }
        defer { confirming.cancel() }
        let status = try await offPool {
            try runToEnd("/bin/bash", [script, opened.url, out.path], environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": node.home.path],
                         output: .path(said.path, flags: O_WRONLY | O_TRUNC), limit: 240)
        }
        let table = (try? String(contentsOf: said, encoding: .utf8)) ?? ""
        func outcome(_ row: String) -> String? {
            table.split(separator: "\n").first { $0.hasPrefix(row + " ") }?.dropFirst(row.count).split(separator: " ").first.map(String.init)
        }
        for row in ["A3 pair", "A3 chat", "A3 inspector", "A3 settings", "A3 console", "Health", "Stats", "Mail", "A19 notifications", "A23 page token"] {
            #expect(outcome(row) == "pass", "\(row): \(table)")
        }
        // A10 needs the page's side of a confirmed pairing (its `paired` message: the page agent's, to follow); until the
        // page takes it, a page that only reads watches no terminal (the acting review's fix C), and the row is a skip.
        #expect(["pass", "skip"].contains(outcome("A10 terminal")), "A10 terminal: \(table)")
        for row in ["Team tab", "Side sheet", "A3 roadmap", "Dev servers", "Shell card"] { #expect(outcome(row) == "skip", "\(row): \(table)") }
        #expect(status == 0 && !table.contains(" fail "), "\(table)\n\(node.said)")
        // Its screenshots and report, and no Chrome profile left behind.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        #expect(files.contains("a3-start.png") && files.contains("report.json") && files.contains("stats.png"), "\(files)")
        #expect(!files.contains { $0.hasPrefix("chrome-profile-") }, "\(files)")
        // Read-only: the node saw no request that acts from the page (its accepted list has nothing).
        let accepted = try await node.statusJSON()["accepted"] as? [Any] ?? []
        #expect(accepted.isEmpty, "\(accepted)")
    }
}
