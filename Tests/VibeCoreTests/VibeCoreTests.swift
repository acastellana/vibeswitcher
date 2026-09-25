import Foundation
import Testing
@testable import VibeCore

struct HookReduceTests {
    private func apply(_ events: [[String: Any]], agent: Agent = .claude, pid: Int32? = 42) -> HookState? {
        var state: HookState?
        var clock = 1000.0
        for event in events {
            clock += 1
            switch HookState.reduce(current: state, payload: event, agent: agent, tty: "ttys001", agentPid: pid, now: clock) {
            case .write(let next): state = next
            case .delete: state = nil
            case .ignore: break
            }
        }
        return state
    }

    private func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = ["hook_event_name": name, "session_id": "s1", "cwd": "/tmp/project"]
        payload.merge(extra) { $1 }
        return payload
    }

    @Test func testTurnLifecycle() throws {
        var state = try #require(apply([event("SessionStart")]))
        #expect(StatusRules.status(for: state) == .idle)

        state = try #require(apply([event("SessionStart"), event("UserPromptSubmit", ["prompt": "fix\nthe bug"])]))
        #expect(StatusRules.status(for: state) == .working)
        #expect(state.lastPrompt == "fix the bug")

        state = try #require(apply([event("UserPromptSubmit", ["prompt": "x"]),
                                     event("PreToolUse", ["tool_name": "Bash"]),
                                     event("PermissionRequest", ["tool_name": "Bash"])]))
        #expect(StatusRules.status(for: state) == .needsInput)
        #expect(state.notice == "Wants permission to use Bash")

        state = try #require(apply([event("UserPromptSubmit", ["prompt": "x"]),
                                     event("PermissionRequest", ["tool_name": "Bash"]),
                                     event("PostToolUse", ["tool_name": "Bash"]),
                                     event("Stop", ["last_assistant_message": "All done."])]))
        #expect(StatusRules.status(for: state) == .done)
        #expect(state.lastMessage == "All done.")
    }

    @Test func testQuestionToolNeedsInput() throws {
        let state = try #require(apply([event("UserPromptSubmit"), event("PreToolUse", ["tool_name": "AskUserQuestion"])]))
        #expect(StatusRules.status(for: state) == .needsInput)
    }

    @Test func testIdlePromptAfterStopIsIgnored() throws {
        let state = try #require(apply([event("Stop"), event("Notification", ["notification_type": "idle_prompt"])]))
        #expect(state.lastEvent == "Stop")
        #expect(state.lastEventAt == 1001)
    }

    @Test func testIrrelevantNotificationIgnored() throws {
        let state = try #require(apply([event("UserPromptSubmit"), event("Notification", ["notification_type": "auth_success"])]))
        #expect(StatusRules.status(for: state) == .working)
    }

    @Test func testLegacyPermissionNotificationWithoutType() throws {
        let state = try #require(apply([event("UserPromptSubmit"),
                                         event("Notification", ["message": "Claude needs your permission to use Bash"])]))
        #expect(StatusRules.status(for: state) == .needsInput)
    }

    @Test func testSessionEndDeletesAndNewSessionResets() throws {
        #expect(apply([event("UserPromptSubmit"), event("SessionEnd")]) == nil)
        var cleared = event("SessionStart")
        cleared["session_id"] = "s2"
        let state = try #require(apply([event("UserPromptSubmit", ["prompt": "old"]), cleared]))
        #expect(state.lastPrompt == nil)
        #expect(state.sessionId == "s2")
    }

    @Test func testCodexInterruptIsDone() throws {
        let state = try #require(apply([event("UserPromptSubmit"), event("Interrupt")], agent: .codex))
        #expect(StatusRules.status(for: state) == .done)
    }
}

struct StatusRulesTests {
    @Test func testTitleParsing() {
        #expect(StatusRules.parseTitle("✳ Update OG images").activity == .idle)
        #expect(StatusRules.parseTitle("✳ Update OG images").text == "Update OG images")
        #expect(StatusRules.parseTitle("◐ Connect to staging").activity == .busy)
        #expect(StatusRules.parseTitle("⠂ Thinking").activity == .busy)
        #expect(StatusRules.parseTitle("Explore the billing API | payments").activity == .none)
        #expect(StatusRules.parseTitle("*nix tips").activity == .none)
        #expect(StatusRules.parseTitle("").activity == .none)
    }

    @Test func testTitleOverridesStaleHook() {
        var hook = HookState(agent: .claude, tty: "ttys001", lastEvent: "PostToolUse", lastEventAt: 100)
        // Esc interrupt: hooks still say working, title went idle.
        #expect(StatusRules.resolve(hook: hook, title: .idle, now: 110) == .done)
        // ...but a fresh hook event wins over a lagging title.
        #expect(StatusRules.resolve(hook: hook, title: .idle, now: 102) == .working)
        hook.lastEvent = "PermissionRequest"
        #expect(StatusRules.resolve(hook: hook, title: .idle, now: 200) == .needsInput)
        hook.lastEvent = "Stop"
        #expect(StatusRules.resolve(hook: hook, title: .busy, now: 200) == .working)
    }

    @Test func testNoHookFallsBackToTitle() {
        #expect(StatusRules.resolve(hook: nil, title: .busy, now: 0) == .working)
        #expect(StatusRules.resolve(hook: nil, title: .idle, now: 0) == .done)
        #expect(StatusRules.resolve(hook: nil, title: .none, now: 0) == .unknown)
    }
}

struct HookInstallerTests {
    @Test func testInstallPreservesForeignHooksAndIsIdempotent() throws {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/guard"]]]]],
        ]
        let once = HookInstaller.addingOurs(to: existing, agent: .claude, hookBinary: "/h/vibeswitcher-hook")
        let twice = HookInstaller.addingOurs(to: once, agent: .claude, hookBinary: "/h/vibeswitcher-hook")
        #expect(once["model"] as? String == "opus")
        let pre = try #require((twice["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 2)
        #expect(pre.last?["matcher"] as? String == "*")
        #expect(HookInstaller.isInstalled(in: twice))

        let removed = HookInstaller.removingOurs(from: twice)
        #expect(!HookInstaller.isInstalled(in: removed))
        let remaining = try #require((removed["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(remaining.count == 1)
        #expect((removed["hooks"] as? [String: Any])?["Stop"] == nil)
    }

    @Test func testCodexHasNoMatchers() throws {
        let config = HookInstaller.addingOurs(to: [:], agent: .codex, hookBinary: "/h/vibeswitcher-hook")
        let hooks = try #require(config["hooks"] as? [String: Any])
        #expect(hooks["Interrupt"] != nil)
        for case let groups as [[String: Any]] in hooks.values {
            #expect(groups.first?["matcher"] == nil)
            let handler = try #require((groups.first?["hooks"] as? [[String: Any]])?.first)
            #expect(handler["command"] as? String == "/h/vibeswitcher-hook codex")
        }
    }
}
