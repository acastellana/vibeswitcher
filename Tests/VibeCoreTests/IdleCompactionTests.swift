import Foundation
import Testing
@testable import VibeCore

/// Claude Code 2.1.299+ compacts a 200K+ token conversation left idle for about 54 minutes. In 2.1.302 that runs the
/// precomputed compaction: PreCompact and PostCompact with trigger "auto", then SessionStart with source "compact".
struct IdleCompactionTests {
    private func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["hook_event_name": name, "session_id": "5f0c2a8e-1b7d-4c3e-9a51-2d8e6f4b7c90", "cwd": "/Users/me/project",
         "transcript_path": "/Users/me/.claude/projects/-Users-me-project/5f0c2a8e-1b7d-4c3e-9a51-2d8e6f4b7c90.jsonl"]
            .merging(extra) { $1 }
    }

    private let compaction: [[String: Any]] = [
        ["hook_event_name": "PreCompact", "trigger": "auto", "custom_instructions": NSNull()],
        ["hook_event_name": "PostCompact", "trigger": "auto", "compact_summary": "This session is being continued…"],
        ["hook_event_name": "SessionStart", "source": "compact", "model": "claude-opus-5-5"],
    ]

    /// Every state the hooks pass through, from the first event on (one second apart, from 100).
    private func states(_ events: [[String: Any]]) -> [HookState] {
        var state: HookState?
        var seen: [HookState] = []
        for (index, payload) in events.enumerated() {
            let full = event(payload["hook_event_name"] as! String, payload)
            if case .write(let next) = HookState.reduce(current: state, payload: full, agent: .claude, tty: "ttys004", agentPid: 4242,
                                                         now: 100 + Double(index)) { state = next }
            if let state { seen.append(state) }
        }
        return seen
    }

    @Test func anIdleCompactionLeavesADoneSessionDone() throws {
        let turn: [[String: Any]] = [["hook_event_name": "UserPromptSubmit", "prompt": "fix it"],
                                     ["hook_event_name": "Stop", "last_assistant_message": "Fixed."],
                                     ["hook_event_name": "Notification", "notification_type": "idle_prompt", "message": "Claude is waiting"]]
        let all = states(turn + compaction)
        let done = try #require(all.dropFirst(1).first)
        for state in all.dropFirst(1) {
            #expect(StatusRules.status(for: state) == .done)
            #expect(StatusRules.resolve(hook: state, title: .idle, now: 3_000) == .done)
        }
        // Not a new "done" either: it's still the Stop's.
        #expect(all.last == done)
    }

    @Test func anIdleCompactionLeavesAFreshSessionIdle() {
        let all = states([["hook_event_name": "SessionStart", "source": "startup"]] + compaction)
        #expect(all.map { StatusRules.status(for: $0) } == [.idle, .idle, .idle, .idle])
        #expect(all.last?.lastEventAt == 100)
    }

    /// Compacting mid-turn (the context filled up) is still work, and the SessionStart after it doesn't end the turn.
    @Test func aCompactionMidTurnStaysWorking() {
        let all = states([["hook_event_name": "UserPromptSubmit", "prompt": "refactor"],
                          ["hook_event_name": "PostToolUse", "tool_name": "Bash"]] + compaction)
        #expect(all.map { StatusRules.status(for: $0) } == [.working, .working, .working, .working, .working])
    }

    /// `/compact` you typed between turns shows as work while it runs and ends where it started.
    @Test func aManualCompactStillShowsWhileItRuns() throws {
        let all = states([["hook_event_name": "Stop"],
                          ["hook_event_name": "PreCompact", "trigger": "manual"],
                          ["hook_event_name": "PostCompact", "trigger": "manual"],
                          ["hook_event_name": "SessionStart", "source": "compact"]])
        #expect(all.map { StatusRules.status(for: $0) } == [.done, .working, .done, .done])
        #expect(all.last?.lastEventAt == 100)
    }
}
