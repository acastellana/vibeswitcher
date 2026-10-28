import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Issue #2, end to end: Claude Code 2.1.311 asks no trust question in a worktree and starts its `--mcp-config` tool
/// server at once, before the lead's start of the worker got to bind the worker's role (that waited for the trust
/// answer). The worker's tool server gave up after 3 s and served no tools for good, so the worker couldn't report.
///
/// A scratch host (`TestHost(vault:)`), the real `vibeswitcher-mcp` as the lead in its session (as Claude Code starts
/// it there), and a fake claude as the project's Claude command: it prints the 2.1.311 banner, asks no trust question,
/// and starts its `--mcp-config` server at once, talking to it as Claude Code does (initialize, tools/list, and
/// tools/list again when told the tools changed). Its banner shows once its server answered initialize, so the trust
/// answer can't come before the server's first look at its role: the race at its worst.
@Suite(.serialized) struct WorkerToolsTests {
    let temp = Scratch()

    @Test func aWorkerStartedByTheLeadGetsItsTools() throws {
        let mcp = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        try #require(FileManager.default.isExecutableFile(atPath: mcp), "vibeswitcher-mcp isn't built beside the host: run swift build first")
        // Short: the host's socket is reached through a link under the scratch home, and a socket's path is limited.
        let made = temp.adopt(URL(fileURLWithPath: "\(shortScratchRoot)/vswt-\(UUID().uuidString.prefix(8))"))
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        let dir = made.resolvingSymlinksInPath().path
        let home = dir + "/home", vibe = home + "/.vibeswitcher", root = dir + "/repo", lead = dir + "/lead", worker = dir + "/worker"
        for folder in [vibe, root + "/.vibeswitcher", lead, worker] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }

        let book = LeadVault.Book()
        let host = try TestHost(vault: book)
        let app = try TestClient(host)
        // Every session's tools find the host where they always do: under its home (the scratch one, never the user's).
        try FileManager.default.createSymbolicLink(atPath: vibe + "/host.sock", withDestinationPath: host.socket)
        // No Mac-wide load refusal: the test runs on a loaded Mac too.
        try JSONEncoder().encode(MacLimits(maxSessions: 10, loadThreshold: 100_000)).write(to: URL(fileURLWithPath: vibe + "/mac-limits.json"))

        let env = "HOME='\(home)' CFFIXED_USER_HOME='\(home)' VIBESWITCHER_HOME='\(vibe)'"
        // The fake claude: the project's Claude command, so the lead starts its worker with it.
        let claude = dir + "/claude"
        let script = """
            #!/bin/sh
            config=""
            while [ $# -gt 0 ]; do [ "$1" = "--mcp-config" ] && config="$2"; shift; done
            server=$(plutil -extract mcpServers.vibeswitcher.command raw -o - "$config")
            i=0
            while arg=$(plutil -extract mcpServers.vibeswitcher.args.$i raw -o - "$config" 2>/dev/null); do set -- "$@" "$arg"; i=$((i + 1)); done
            export \(env)
            w='\(worker)'
            : > "$w/in"
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1.311"}}}' \\
                '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' >> "$w/in"
            tail -n +1 -f "$w/in" | "$server" "$@" > "$w/out" 2> "$w/err" &
            (until grep -q 'notifications/tools/list_changed' "$w/out" 2>/dev/null; do sleep 0.05; done
             printf '%s\\n' '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' >> "$w/in") &
            until grep -q '"id":1' "$w/out" 2>/dev/null; do sleep 0.05; done
            printf '\\n ✻ Welcome to Claude Code v2.1.311\\n\\n   /help for help, /status for your current setup\\n\\n   cwd: %s\\n\\n> ' "$PWD"
            wait
            """
        try script.write(toFile: claude, atomically: true, encoding: .utf8)
        chmod(claude, 0o755)
        try LaunchPresets(global: [], byProject: [root: [LaunchPreset(name: "Fake Claude", kind: .claude, command: claude)]])
            .save(to: URL(fileURLWithPath: vibe + "/presets.json"))

        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        // Nothing moves on by itself while the test looks.
        try "---\nauto_advance: false\n---\n".write(toFile: root + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)

        // The lead's session: its tool server starts once the app bound its role.
        FileManager.default.createFile(atPath: lead + "/a.in", contents: nil)
        let leadSession = try app.spawn("set +m; export \(env); cd '\(root)'; while [ ! -f '\(lead)/go' ]; do sleep 0.05; done; "
            + "tail -n +1 -f '\(lead)/a.in' | '\(mcp)' --root '\(root)' --role lead > '\(lead)/a.out' 2> '\(lead)/a.err' & wait", cwd: root)
        guard case .grant(let grant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            Issue.record("no lead grant"); return
        }
        #expect(book.answer(.bind(grant: grant, root: root, session: leadSession.id.uuidString), from: .app) == .ok)
        FileManager.default.createFile(atPath: lead + "/go", contents: nil)

        // The host ends every session as the test ends (the lead's and its worker's, their tool servers with them).
        let server = LeadToolServerHandoverTests.Server(folder: lead, name: "a")
        #expect(try server.ask(1, "initialize", ["protocolVersion": "2025-06-18"]) != nil, "stderr: \(server.errors)")
        #expect(try server.tools(2).contains("start_worker"), "stderr: \(server.errors)")
        guard let added = try server.call(3, "add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"],
                                                         "boundaries": ["only b.txt"]]) else {
            Issue.record("add_task didn't answer: \(server.errors)"); return
        }
        #expect(!added.isError, "\(added.text)")

        let asked = Date()
        let started = try server.call(4, "start_worker", ["task": "add-b"])
        #expect(started?.isError == false, "start_worker: \(started?.text ?? "no answer"); stderr: \(server.errors)")
        // Within 20 s of the lead asking, the worker's tools/list has its tools.
        let tools = { () -> Set<String> in
            let text = (try? String(contentsOfFile: worker + "/out", encoding: .utf8)) ?? ""
            return text.split(separator: "\n").reduce(into: Set<String>()) { names, line in
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let list = (object["result"] as? [String: Any])?["tools"] as? [[String: Any]] else { return }
                names.formUnion(list.compactMap { $0["name"] as? String })
            }
        }
        let got = eventually(timeout: max(0, 20 - Date().timeIntervalSince(asked))) { tools().isSuperset(of: ["progress", "report"]) }
        let workerErrors = (try? String(contentsOfFile: worker + "/err", encoding: .utf8)) ?? ""
        #expect(got, "the worker's tools: \(tools()); its server's stderr: \(workerErrors)")
    }
}

extension LeadToolServerHandoverTests.Server {
    /// A tool call with arguments: its text and whether it's an error.
    func call(_ id: Int, _ tool: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool)? {
        guard let result = try ask(id, "tools/call", ["name": tool, "arguments": arguments]) else { return nil }
        let text = ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, result["isError"] as? Bool ?? true)
    }
}
