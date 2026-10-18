import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The lead's tool server through an install, end to end: a real host process on a scratch home, socket and lock hands
/// its sessions over to a new build, and the real `vibeswitcher-mcp` runs in the lead's session (as Claude Code starts
/// it there). The server that was running keeps its grant, and a server started again in the same session (what
/// /mcp does, with the new build's tools) gets the same grant.
@Suite(.serialized) struct LeadToolServerHandoverTests {
    /// One tool server in the session, talked to over files: requests appended to `<name>.in` (which it reads as
    /// Claude Code's pipe, `tail -f`), replies read from `<name>.out`.
    struct Server {
        let folder: String
        let name: String

        func send(_ id: Int, _ method: String, _ params: [String: Any] = [:]) throws {
            let line = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: "\(folder)/\(name).in"))
            handle.seekToEndOfFile()
            handle.write(line + Data([0x0A]))
            try handle.close()
        }

        func reply(_ id: Int) -> [String: Any]? {
            let text = (try? String(contentsOfFile: "\(folder)/\(name).out", encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      (object["id"] as? Int) == id else { continue }
                return object["result"] as? [String: Any]
            }
            return nil
        }

        /// Asks and waits for the answer.
        func ask(_ id: Int, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any]? {
            try send(id, method, params)
            _ = eventually { reply(id) != nil }
            return reply(id)
        }

        func tools(_ id: Int) throws -> [String] {
            ((try ask(id, "tools/list")?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        }

        /// A tool call's text and whether it's an error.
        func call(_ id: Int, _ tool: String) throws -> (text: String, isError: Bool)? {
            guard let result = try ask(id, "tools/call", ["name": tool, "arguments": [String: Any]()]) else { return nil }
            let text = ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            return (text, result["isError"] as? Bool ?? true)
        }

        var errors: String { (try? String(contentsOfFile: "\(folder)/\(name).err", encoding: .utf8)) ?? "" }
    }

    @Test func theLeadsToolServerKeepsItsGrantThroughAHandoverAndWhenStartedAgain() throws {
        let mcp = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        try #require(FileManager.default.isExecutableFile(atPath: mcp), "vibeswitcher-mcp isn't built beside the host: run swift build first")
        let host = try ScratchHostProcess()
        var sessions: [HostSession] = []
        defer {
            for session in sessions where kill(session.childPID, 0) == 0 { kill(-session.childPID, SIGKILL) }
            host.stop()
        }
        // The session's tools find the host where they always do: under its home.
        try FileManager.default.createDirectory(atPath: host.home + "/.vibeswitcher", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: host.home + "/.vibeswitcher/host.sock", withDestinationPath: host.socket)
        let root = host.dir + "/repo"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        let folder = host.dir + "/mcp"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for name in ["a", "b"] { FileManager.default.createFile(atPath: "\(folder)/\(name).in", contents: nil) }

        // The lead's session: a tool server once the app bound its role (a), another later in the same session (b).
        func server(_ name: String) -> String {
            "while [ ! -f '\(folder)/go-\(name)' ]; do sleep 0.05; done; "
                + "tail -n +1 -f '\(folder)/\(name).in' | '\(mcp)' --root '\(root)' --role lead > '\(folder)/\(name).out' 2> '\(folder)/\(name).err' &"
        }
        let (app, _, _, _, _, _, _) = try TestClient.welcomed(host.socket, appKey: host.appKey)
        // Its home is the scratch one, for Foundation too (which reads CFFIXED_USER_HOME, not HOME): never the user's host.
        // No job control (the session's shell is interactive): the servers stay in its process group, which the end kills.
        let lead = try app.spawn("set +m; export HOME='\(host.home)' CFFIXED_USER_HOME='\(host.home)'; cd '\(root)'; \(server("a")) \(server("b")) wait", cwd: root)
        sessions = [lead]
        guard case .grant(let grant)? = app.vault(.issue(role: .lead, root: root, task: nil, auditing: nil)) else {
            Issue.record("the app got no lead grant: \(host.log)"); return
        }
        #expect(app.vault(.bind(grant: grant, root: root, session: lead.id.uuidString)) == .ok)
        FileManager.default.createFile(atPath: "\(folder)/go-a", contents: nil)

        let a = Server(folder: folder, name: "a")
        let initialized = try a.ask(1, "initialize", ["protocolVersion": "2025-06-18"]) != nil
        #expect(initialized, "stderr: \(a.errors)")
        let toolsA = try a.tools(2)
        #expect(toolsA.contains("merge"), "tools: \(toolsA)")
        let before = try a.call(3, "status")
        #expect(before?.isError == false, "status: \(before?.text ?? "no answer")")

        // The install: the app hands the host over to the new build, which carries the vault in memory.
        let seq = app.send(.handover(executable: host.newBinary))
        #expect(eventually { app.reply(to: seq) != nil })
        #expect(eventually { host.log.contains("took over") }, "host log: \(host.log)")
        #expect(host.log.contains("bytes of secrets"))
        let (again, _, build, _, _, _, _) = try TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(build == host.newBuild)

        // The server that was running still serves the lead.
        let through = try a.call(4, "status")
        #expect(through?.isError == false, "status: \(through?.text ?? "no answer")")
        // Started again in the same session (the new build's server, as /mcp starts it): the lead's tools, same grant.
        FileManager.default.createFile(atPath: "\(folder)/go-b", contents: nil)
        let b = Server(folder: folder, name: "b")
        let restarted = try b.ask(1, "initialize", ["protocolVersion": "2025-06-18"]) != nil
        #expect(restarted, "stderr: \(b.errors)")
        let toolsB = try b.tools(2)
        #expect(toolsB.contains("merge"), "tools: \(toolsB)")
        let after = try b.call(3, "status")
        #expect(after?.isError == false, "status: \(after?.text ?? "no answer")")
        guard case .member(let current?)? = again.vault(.current(role: .lead, root: root, task: nil)) else {
            Issue.record("the lead's role is gone after the handover"); return
        }
        #expect(current.id == grant && current.session == lead.id.uuidString)
        // And the app, relaunched, binds it to its session again: the same grant, nothing new issued.
        let vault = LeadVault(folder: URL(fileURLWithPath: host.dir + "/vault")) { request in
            guard let reply = again.vault(request) else { throw LeadVault.Refused("no answer") }
            return reply
        }
        #expect(try vault.rebindLead(root: root, session: lead.id.uuidString)?.id == grant)
        #expect(try b.call(4, "status")?.isError == false)
    }
}
