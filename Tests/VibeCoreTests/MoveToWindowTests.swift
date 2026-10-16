import Foundation
import Testing
@testable import VibeCore

struct MoveToWindowTests {
    func session(status: SessionStatus, id: String? = "abc", terminal: Bool = true, host: UUID? = nil) -> Session {
        var session = Session(tty: "ttys001", agent: .claude, pid: 1, startedAt: Date(), cwd: "/dev/p", project: "p", task: nil,
                              status: status, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: terminal)
        session.agentSessionID = id
        session.hostID = host
        session.transcriptPath = "/t.jsonl"
        return session
    }

    @Test func onlyResumableTerminalSessionsBetweenTurnsCanMove() {
        let yes = { (_: String) in true }
        #expect(MoveToWindow.canMove(session(status: .idle), transcriptExists: yes))
        #expect(MoveToWindow.canMove(session(status: .done), transcriptExists: yes))
        #expect(!MoveToWindow.canMove(session(status: .working), transcriptExists: yes))
        #expect(!MoveToWindow.canMove(session(status: .needsInput), transcriptExists: yes))
        #expect(!MoveToWindow.canMove(session(status: .background), transcriptExists: yes))
        #expect(!MoveToWindow.canMove(session(status: .idle, id: nil), transcriptExists: yes))
        #expect(!MoveToWindow.canMove(session(status: .idle, terminal: false), transcriptExists: yes))
        #expect(!MoveToWindow.canMove(session(status: .idle, host: UUID()), transcriptExists: yes))
    }

    /// Before its first prompt an agent has no conversation on disk, and --resume would fail.
    @Test func aConversationWithoutATranscriptCantMove() {
        var fresh = session(status: .idle)
        fresh.transcriptPath = nil
        #expect(!MoveToWindow.canMove(fresh, transcriptExists: { _ in true }))   // no path known
        fresh.transcriptPath = "/x/s.jsonl"
        #expect(!MoveToWindow.canMove(fresh, transcriptExists: { _ in false }))
        #expect(MoveToWindow.canMove(fresh, transcriptExists: { $0 == "/x/s.jsonl" }))
    }

    @Test func resumesWithTheFoldersWindowPresetForThatAgent() {
        let presets = [LaunchPreset(name: "Codex", kind: .codex, command: "codex --full-auto"),
                       LaunchPreset(name: "In Terminal", kind: .claude, command: "claude --x", place: .terminal),
                       LaunchPreset(name: "Opus", kind: .claude, command: "claude --model opus", env: ["A": "1"])]
        let plan = MoveToWindow.plan(agent: .claude, sessionID: "abc", presets: presets)
        #expect(plan.command == "claude --model opus --resume 'abc'")
        #expect(plan.env == ["A": "1"])
        #expect(plan.label == "Opus")
    }

    @Test func withoutAPresetItUsesTheAgentItself() {
        let plan = MoveToWindow.plan(agent: .codex, sessionID: "xyz", presets: [])
        #expect(plan.command == "codex resume 'xyz'")
        #expect(plan.env.isEmpty)
        #expect(plan.label == "Codex")
    }
}
