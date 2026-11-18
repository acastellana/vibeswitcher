import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// `scripts/sandbox-server.sh`'s node (the live plan's G1): a `ScratchNode` with the server's web on, two fake sessions
/// and a fake lead with a question open, for a person to look at in a browser. **Not a test:** it runs only when the
/// script names its folder (`VIBESWITCHER_SANDBOX_SERVER`), and it lives until it is told to quit, or until the 24 h
/// limit. Everything is the tests' own: the scratch host and server built from this worktree, `FakeClaude` as the
/// lead, stage 1's fake agent as the sessions; nothing reaches the user's `~/.vibeswitcher`, `~/.claude` or node.
///
/// The script talks to it through `<folder>/control`: it writes `req-<id>` (one word: `url`, `flip`, `quit`) and reads
/// `rep-<id>` (`ok` or `error` on the first line, then the answer). It writes `started` once the node is up.
///
/// - `url`: a fresh pairing code (`web.open` in a scratch server's form, `--test-web-pair`), the page's address.
/// - `flip`: the first session's turn ends, or starts again (`done` and `working` by turns), as its hook would say.
/// - Unless `VIBESWITCHER_SANDBOX_STILL` is set, the second session's status changes by itself every 20 s too, so an
///   open page shows the list living.
@Suite(NodeTraits.linuxOnly)
struct SandboxServerDriver {
    static let folderKey = "VIBESWITCHER_SANDBOX_SERVER"
    static var folder: URL? { ProcessInfo.processInfo.environment[folderKey].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    @Test(.enabled(if: SandboxServerDriver.folder != nil, "only scripts/sandbox-server.sh runs it"), .timeLimit(.minutes(24 * 60)))
    func sandbox() async throws {
        let folder = try #require(Self.folder)
        let control = folder.appendingPathComponent("control", isDirectory: true)
        let environment = ProcessInfo.processInfo.environment
        let port = environment["VIBESWITCHER_SANDBOX_PORT"].flatMap(UInt16.init) ?? 0
        var arguments = ["--server-arg", ServerArguments.testWebPortFlag + String(port), "--server-arg", ServerArguments.testWebPairFlag]
        if let root = environment["VIBESWITCHER_SANDBOX_WEB_ROOT"] { arguments += ["--server-arg", ServerArguments.testWebRootFlag + root] }
        let scratch = Scratch()
        let node = try await ScratchNode(scratch, holdFirstLook: true, hostArguments: arguments)
        defer { node.stop() }

        // Two sessions of the host: one working on the site, one asking for a permission in the API.
        let site = try await HookedAgent.start(node, project: "example-site")
        try site.hook(node, "UserPromptSubmit")
        let api = try await HookedAgent.start(node, project: "example-api")
        try api.hook(node, "PermissionRequest")

        // A lead on a scratch repository, started as the user starts one (the accepts, then `lead`, each code typed),
        // asking the user one question through its tool server.
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
        try tools.call("ask_user", ["question": "Launch the onboarding page to the testers on Thursday, or wait for the copy review?",
                                    "options": ["Thursday", "Wait for the review"]])
        try #require(await eventually(timeout: 120) { tools.calls().count == 1 }, "\(node.said)")

        try Data("\(getpid())\n\(node.root.path)\n".utf8).write(to: control.appendingPathComponent("started"))

        var siteWorking = true, apiAsking = true
        var lastLife = Date()
        let still = environment["VIBESWITCHER_SANDBOX_STILL"] != nil
        while true {
            let requests = ((try? FileManager.default.contentsOfDirectory(atPath: control.path)) ?? []).filter { $0.hasPrefix("req-") }.sorted()
            for name in requests {
                let request = control.appendingPathComponent(name)
                let word = ((try? String(contentsOf: request, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                try? FileManager.default.removeItem(at: request)
                var reply = "ok\n"
                switch word {
                case "url":
                    do { reply += try LiveScratch.open(node).url } catch { reply = "error\n\(error)" }
                case "flip":
                    siteWorking.toggle()
                    try site.hook(node, siteWorking ? "UserPromptSubmit" : "Stop")
                    reply += "example-site is \(siteWorking ? "working" : "done")"
                case "quit":
                    reply += "quitting"
                default:
                    reply = "error\nunknown command \(word): url, flip, quit"
                }
                let answer = control.appendingPathComponent("rep-" + name.dropFirst(4))
                try Data(reply.utf8).write(to: answer.appendingPathExtension("part"))
                try FileManager.default.moveItem(at: answer.appendingPathExtension("part"), to: answer)
                if word == "quit" { return }
            }
            if !still, Date().timeIntervalSince(lastLife) >= 20 {
                lastLife = Date()
                apiAsking.toggle()
                try api.hook(node, apiAsking ? "PermissionRequest" : "UserPromptSubmit")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
