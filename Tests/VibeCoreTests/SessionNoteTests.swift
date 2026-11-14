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

    /// 2026-11-08: a lead sent the user to Terminal.app and `!` for a locked signing keychain. The note never reached it (a
    /// lead's session gets none), and Claude Code's own system prompt says to suggest `! <command>`.
    static func saysToUseAShellCard(_ text: String, _ who: String) {
        #expect(text.contains("vs-shell run"), "\(who)")
        for need in ["needs a real terminal", "a password or other prompt", "an install", "interactive program"] {
            #expect(text.contains(need), "\(who): \(need)")
        }
        #expect(text.contains("one Run click"), "\(who)")
        #expect(text.contains("replaces Claude Code's advice to suggest `! <command>`"), "\(who)")
        #expect(text.contains("don't ask the user to open Terminal.app"), "\(who)")
        #expect(text.contains("or to type `! <command>` for it"), "\(who)")
        #expect(text.contains("A password is typed only into that shell, never into chat"), "\(who)")
    }

    @Test func theNoteAndTheLeadSayToFileAShellForARealTerminal() {
        let workflow = LeadWorkflow()
        let lead = LeadPrompts.lead(project: "p", root: "/r/p", workflow: workflow, policy: "policy")
        for (who, text) in [("note", SessionNote.text), ("lead", lead)] {
            Self.saysToUseAShellCard(text, who)
            // One wording, so they can't drift apart.
            #expect(text.contains(SessionNote.realTerminal), "\(who)")
        }
    }

    /// A lead reads its prompt from the file `--append-system-prompt-file` names (on Linux, from its command line while
    /// it fits there: `LaunchArguments`): the rule has to be in it.
    @Test func theShellRuleIsInWhatALeadStartsFrom() throws {
        let root = temp.url("lead-start")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prompt = LeadPrompts.lead(project: "p", root: root.path, workflow: LeadWorkflow(), policy: "policy")
        let launch = try LeadLaunch.prepare(role: .lead, root: root.path, task: nil, base: "claude", prompt: prompt, start: "Go.",
                                            server: "/s", name: "lead-x", folder: root.appendingPathComponent("run"), cwd: root.path,
                                            temporary: root.appendingPathComponent("tmp"))
        #expect(launch.command.contains("--append-system-prompt"))
        Self.saysToUseAShellCard(try LaunchArguments.prompt(in: launch.command), "lead's prompt")
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
