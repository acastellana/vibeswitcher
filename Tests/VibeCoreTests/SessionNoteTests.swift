import Foundation
import Testing
@testable import VibeCore

/// A session VibeSwitcher started hears at its start that it can ask for a transaction with vs-wallet (the hook's
/// SessionStart reply); a lead's, worker's or verifier's doesn't, nor a session VibeSwitcher didn't start.
struct SessionNoteTests {
    let temp = Scratch()
    static let session = ["VIBESWITCHER_SESSION": "11111111-2222-4333-8444-555555555555"]

    static func start(_ source: String = "startup", agentID: Any? = nil) -> [String: Any] {
        var payload: [String: Any] = ["hook_event_name": "SessionStart", "source": source, "session_id": "s"]
        if let agentID { payload["agent_id"] = agentID }
        return payload
    }

    /// The added context the hook's reply hands Claude Code, if any.
    static func context(_ data: Data?) throws -> String? {
        guard let data else { return nil }
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try #require(object["hookSpecificOutput"] as? [String: String])
        #expect(output["hookEventName"] == "SessionStart")
        return output["additionalContext"]
    }

    @Test func aNewSessionsContextCarriesTheWalletNote() throws {
        for source in ["startup", "resume", "clear"] {
            let context = try #require(try Self.context(SessionNote.output(payload: Self.start(source), environment: Self.session)))
            #expect(context == SessionNote.text)
            #expect(context.contains("vs-wallet request"))
            #expect(context.contains("Send to Wallet Manager"))
            #expect(context.contains("never holds or takes keys"))
        }
        // The main thread's start, as Claude Code marks it (no agent id, or an empty one).
        #expect(SessionNote.output(payload: Self.start(agentID: ""), environment: Self.session) != nil)
        #expect(SessionNote.output(payload: Self.start(agentID: NSNull()), environment: Self.session) != nil)
    }

    @Test func aLeadsWorkersOrVerifiersSessionGetsNoNote() throws {
        let root = temp.url("launch")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for role in [LeadLaunch.Role.lead, .worker, .verifier] {
            let launch = try LeadLaunch.prepare(role: role, root: root.path, task: role == .lead ? nil : "x", base: "claude", prompt: "p",
                                                start: "Go.", server: "/s", name: "\(role.rawValue)-x",
                                                folder: root.appendingPathComponent("run-\(role.rawValue)"), cwd: root.path,
                                                temporary: root.appendingPathComponent("tmp"))
            #expect(launch.environment[SessionNote.roleVariable] == role.rawValue)
            let environment = Self.session.merging(launch.environment) { $1 }
            #expect(SessionNote.output(payload: Self.start(), environment: environment) == nil)
        }
    }

    @Test func noNoteOutsideASessionsStart() {
        // Not a session VibeSwitcher started.
        #expect(SessionNote.output(payload: Self.start(), environment: [:]) == nil)
        #expect(SessionNote.output(payload: Self.start(), environment: ["VIBESWITCHER_SESSION": "not-a-uuid"]) == nil)
        // The restart after a compaction (its context kept the note), a subagent's start, other events.
        #expect(SessionNote.output(payload: Self.start("compact"), environment: Self.session) == nil)
        #expect(SessionNote.output(payload: Self.start(agentID: "agent-1"), environment: Self.session) == nil)
        for event in ["UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"] {
            #expect(SessionNote.output(payload: ["hook_event_name": event], environment: Self.session) == nil)
        }
    }
}
