import Foundation
import Testing
import VibeCore

/// The fake Claude Code (`FakeClaude`) on a session of a scratch host (`NodeTestHost`): the non-view parts of the app's
/// chat sync `Harness` (`Tests/VibeSwitcherTests/ChatSyncTests.swift` 636-853, the port map's "Copied from the app"):
/// the launch, `tell`, the agent's state, the screen, and the hook's step (`hookTakes`). Not the app's pane, chat or
/// sync: the engine has no view. Started here (`start`), or found by its terminal on a session the engine started
/// (`init(found:on:fake:)`).
final class NodeHarness: @unchecked Sendable {
    let host: NodeTestHost
    let fake: FakeClaude.Install
    let session: HostSession
    /// Its transcript, control and state files, by its terminal.
    let files: FakeClaude.Files

    /// The fake on `session`, which the engine (or the test) started with `fake`'s launcher.
    init(found session: HostSession, on host: NodeTestHost, fake: FakeClaude.Install) {
        self.host = host
        self.fake = fake
        self.session = session
        files = fake.files(terminal: session.tty)
    }

    /// Installs the fake in the host's folder (once per host: `fake` given, it is reused), starts it in a new session
    /// with `arguments` (Claude's, as the engine would pass them), and waits until it has drawn its prompt box and
    /// written its state.
    static func start(on host: NodeTestHost, fake: FakeClaude.Install? = nil, arguments: [String] = [], cwd: String? = nil,
                      label: String = "Fake Claude") async throws -> NodeHarness {
        let fake = try fake ?? FakeClaude.install(in: host.folder)
        let command = "exec " + ([fake.launcher.path] + arguments).map(FakeClaude.quoted).joined(separator: " ")
        let session = try await host.spawn(command, cwd: cwd, label: label, agent: "claude")
        let h = NodeHarness(found: session, on: host, fake: fake)
        try await h.screenShows { $0.contains("? for shortcuts") }
        // It draws before it writes its state: its first screen can be up while `agent` is still empty.
        try await h.waitFor { h.agent["pid"] != nil }
        return h
    }

    /// What the fake agent says it's at (see `FakeClaude`): its state file, read now.
    var agent: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: files.state))) as? [String: Any] ?? [:]
    }

    /// The fake's own pid, as it wrote it.
    var agentPid: Int32? { (agent["pid"] as? Int).map(Int32.init) }

    /// Appends `command` to the fake's control file (see `FakeClaude`'s ops).
    func tell(_ command: [String: Any]) {
        let line = try! JSONSerialization.data(withJSONObject: command) + Data("\n".utf8)
        let handle = try! FileHandle(forWritingTo: files.control)
        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.close()
    }

    /// The session's screen as the host draws it now (`HostCall.styledScreen`, through the connector); "" when the
    /// host didn't answer.
    var screen: String { host.screen(session.id) ?? "" }

    /// The transcript's lines, each a JSON object.
    var transcript: [[String: Any]] {
        let text = (try? String(contentsOf: files.transcript, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    /// What the terminal or the agent must get to (one that never does fails there, after a minute and a half).
    static let wait: TimeInterval = 90

    /// Waits until the screen satisfies `condition`; fails the test, saying what it shows, when it never does.
    func screenShows(sourceLocation: SourceLocation = #_sourceLocation, _ condition: (String) -> Bool) async throws {
        let shown = await eventually(timeout: Self.wait) { condition(self.screen) }
        if !shown {
            Issue.record("the terminal never showed it:\n\(screen)", sourceLocation: sourceLocation)
            throw HarnessError.timedOut
        }
    }

    /// Waits until `condition` holds; fails the test, saying what the terminal, the agent and the transcript show, when
    /// it never does.
    func waitFor(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let met = await eventually(timeout: Self.wait) { condition() }
        if !met {
            let tail = ((try? String(contentsOf: files.transcript, encoding: .utf8)) ?? "").split(separator: "\n").suffix(3).joined(separator: "\n")
            Issue.record("never happened; the terminal shows:\n\(screen)\nthe agent: \(agent)\nthe transcript ends: \(tail)",
                         sourceLocation: sourceLocation)
            throw HarnessError.timedOut
        }
    }

    /// The agent's hook at its next step (`vibeswitcher-hook` on PostToolUse): it takes the steered messages from the
    /// host's inbox (`SteerReply.answer` against the host's root, never this process's `VibePaths.root`), and Claude
    /// records the hook's added context in its transcript. True when it took any.
    @discardableResult
    func hookTakes() -> Bool {
        guard let pid = agentPid else { return false }
        let transcript = files.transcript
        let written = SteerReply.answer(["hook_event_name": "PostToolUse"], tty: session.tty, agentPid: pid, root: host.root) { data in
            guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let output = reply["hookSpecificOutput"] as? [String: Any], let context = output["additionalContext"] as? String
            else { return false }
            let line: [String: Any] = ["type": "attachment", "uuid": UUID().uuidString, "isSidechain": false,
                                       "timestamp": ISO8601DateFormatter().string(from: Date()),
                                       "attachment": ["type": "hook_additional_context", "content": [context], "hookEvent": "PostToolUse"]]
            guard let encoded = try? JSONSerialization.data(withJSONObject: line), let handle = try? FileHandle(forWritingTo: transcript)
            else { return false }
            handle.seekToEndOfFile()
            handle.write(encoded + Data("\n".utf8))
            try? handle.close()
            return true
        }
        return written != nil
    }
}

enum HarnessError: Error {
    case timedOut
}
