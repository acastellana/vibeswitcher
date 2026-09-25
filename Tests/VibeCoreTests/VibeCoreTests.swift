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


struct MenuBarDotsTests {
    @Test func fewSessionsUseOneRow() {
        let layout = MenuBarDots.layout(count: 3)
        #expect(layout.rows == 1)
        let first = MenuBarDots.rect(at: 0, count: 3), second = MenuBarDots.rect(at: 1, count: 3)
        #expect(MenuBarDots.index(at: CGPoint(x: first.midX, y: 11), count: 3) == 0)
        #expect(MenuBarDots.index(at: CGPoint(x: second.midX, y: 3), count: 3) == 1)
        // The gap is split between neighbours.
        let boundary = (first.maxX + second.minX) / 2
        #expect(MenuBarDots.index(at: CGPoint(x: boundary - 0.1, y: 11), count: 3) == 0)
        #expect(MenuBarDots.index(at: CGPoint(x: boundary + 0.1, y: 11), count: 3) == 1)
        #expect(MenuBarDots.index(at: CGPoint(x: -10, y: 11), count: 3) == nil)
        #expect(MenuBarDots.index(at: CGPoint(x: layout.width + 10, y: 11), count: 3) == nil)
    }

    @Test func manySessionsWrapIntoTwoNarrowRows() {
        let layout = MenuBarDots.layout(count: 9)
        #expect(layout.rows == 2 && layout.columns == 5)
        #expect(layout.width < 60, "9 sessions must stay compact, was \(layout.width)")
        // Top row holds 1–5, bottom row 6–9; the empty 10th cell is not a session.
        #expect(MenuBarDots.index(at: CGPoint(x: MenuBarDots.rect(at: 0, count: 9).midX, y: 17), count: 9) == 0)
        #expect(MenuBarDots.index(at: CGPoint(x: MenuBarDots.rect(at: 5, count: 9).midX, y: 4), count: 9) == 5)
        #expect(MenuBarDots.index(at: CGPoint(x: layout.width - 1, y: 3), count: 9) == nil)
        #expect(MenuBarDots.rect(at: 0, count: 9).minY > MenuBarDots.rect(at: 5, count: 9).maxY)
        #expect(MenuBarDots.index(at: CGPoint(x: 5, y: 9), count: MenuBarDots.maxDots + 1) == nil)
    }

    @Test func hitRectsMatchHitTesting() {
        for count in [1, 4, 5, 9, 12] {
            for index in 0..<count {
                let hit = MenuBarDots.hitRect(at: index, count: count)
                let dot = MenuBarDots.rect(at: index, count: count)
                #expect(hit.contains(CGPoint(x: dot.midX, y: dot.midY)))
                #expect(MenuBarDots.index(at: CGPoint(x: hit.midX, y: hit.midY), count: count) == index)
                #expect(dot.minY >= 0 && dot.maxY <= MenuBarDots.height)
            }
        }
    }
}

struct SessionNamingTests {
    private let repos: Set<String> = ["/Users/me/dev/webshop/.git", "/Users/me/dev/site/.git"]

    @Test func projectIsTheRepoTheSessionStartedIn() {
        let exists: (String) -> Bool = { repos.contains($0) }
        #expect(SessionNaming.project(forLaunchDirectory: "/Users/me/dev/webshop", home: "/Users/me", fileExists: exists) == "webshop")
        #expect(SessionNaming.project(forLaunchDirectory: "/Users/me/dev/webshop/docs/reviews", home: "/Users/me", fileExists: exists) == "webshop")
        #expect(SessionNaming.project(forLaunchDirectory: "/Users/me/dev/scratch", home: "/Users/me", fileExists: exists) == "scratch")
        #expect(SessionNaming.project(forLaunchDirectory: "/Users/me", home: "/Users/me", fileExists: exists) == "~ (home)")
    }

    @Test func taskComesFromTheTabTitle() {
        #expect(SessionNaming.task(fromTitle: "Website redesign concepts", project: "site", firstPrompt: nil) == "Website redesign concepts")
        #expect(SessionNaming.task(fromTitle: "Explore the billing API | payments", project: "payments", firstPrompt: nil) == "Explore the billing API")
        #expect(SessionNaming.task(fromTitle: "Terminal", project: "site", firstPrompt: "fix the header") == "fix the header")
        #expect(SessionNaming.task(fromTitle: "SANDBOX", project: "SANDBOX", firstPrompt: nil) == nil)
        #expect(SessionNaming.task(fromTitle: nil, project: "x", firstPrompt: String(repeating: "a", count: 80))?.count == 61)
    }

    @Test func systemPromptsAreRecognised() {
        #expect(SessionNaming.isSystemPrompt("<task-notification> <task-id>abc</task-id>"))
        #expect(SessionNaming.isSystemPrompt("<system-reminder>x</system-reminder>"))
        #expect(!SessionNaming.isSystemPrompt("fix the <div> layout"))
        #expect(!SessionNaming.isSystemPrompt("<3 thanks"))
    }

    @Test func taskNotificationDoesNotReplaceTheRealPrompt() throws {
        var state: HookState?
        for (index, prompt) in ["build the app", "<task-notification> <task-id>1</task-id>"].enumerated() {
            let payload: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": prompt]
            if case .write(let next) = HookState.reduce(current: state, payload: payload, agent: .claude, tty: "t",
                                                        agentPid: 1, now: Double(index)) { state = next }
        }
        let final = try #require(state)
        #expect(final.lastPrompt == "build the app")
        #expect(final.firstPrompt == "build the app")
        #expect(StatusRules.status(for: final) == .working)
    }
}

struct BackgroundWorkTests {
    @Test func readsClaudeFooter() {
        let screen = """
          The VM is stable, up 2 h 24 min. I'll report when Flows finishes.
        ────────────────────────────────
        ❯
        ────────────────────────────────
          [Opus] ███████░░░ 71% | webshop git:(main*)
          ⏵⏵ bypass permissions on · 1 shell · ← 2 agents
        """
        #expect(BackgroundWork.summary(fromScreen: screen) == "1 shell")
        #expect(BackgroundWork.summary(fromScreen: "❯ \n  ? for shortcuts · 3 background tasks") == "3 background tasks")
    }

    @Test func ignoresConversationTextAndIdleFooters() {
        #expect(BackgroundWork.summary(fromScreen: "❯\n  ⏵⏵ bypass permissions on (shift+tab to cycle)") == nil)
        // Prose above the footer mentioning shells must not count.
        let prose = (["I started 2 shells for the build"] + Array(repeating: "line", count: 8)).joined(separator: "\n")
        #expect(BackgroundWork.summary(fromScreen: prose) == nil)
        #expect(BackgroundWork.summary(fromScreen: "  ⏵⏵ accept edits on · 0 shells") == nil)
        // "← N agents" is a navigation hint, present even on long-idle sessions.
        #expect(BackgroundWork.summary(fromScreen: "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 2 agents") == nil)
        #expect(BackgroundWork.summary(fromScreen: "  ⏵⏵ bypass permissions on · 2 agents") == "2 agents")
    }
}

struct RecentProjectsTests {
    @Test func ranksNewestFirstAndDropsJunk() {
        let now = Date()
        let ranked = RecentProjects.rank([
            .init(path: "/Users/me/dev/old", lastUsed: now.addingTimeInterval(-500)),
            .init(path: "/Users/me/dev/new", lastUsed: now),
            .init(path: "/Users/me/dev/old/", lastUsed: now.addingTimeInterval(-10)),   // same folder, newer
            .init(path: "/Users/me", lastUsed: now),                                     // bare home
            .init(path: "/Users/me/dev/gone", lastUsed: now),                            // deleted
        ], home: "/Users/me", exists: { $0 != "/Users/me/dev/gone" })
        #expect(ranked.map(\.path) == ["/Users/me/dev/new", "/Users/me/dev/old"])
        #expect(ranked[1].lastUsed == now.addingTimeInterval(-10))
    }

    @Test func claudeSlugMatchesTranscriptFolders() {
        #expect(RecentProjects.claudeSlug(for: "/Users/me/dev/vibeswitcher") == "-Users-me-dev-vibeswitcher")
        #expect(RecentProjects.claudeSlug(for: "/Users/me/My Project.v2") == "-Users-me-My-Project-v2")
    }

    @Test func readsCodexProjects() {
        let toml = "model = \"x\"\n[projects.\"/Users/me/dev/a\"]\ntrust_level = \"trusted\"\n[hooks.state]\n"
        #expect(RecentProjects.codexProjects(fromConfig: toml) == ["/Users/me/dev/a"])
    }

    @Test func shellCommandQuotesAnyFolder() {
        #expect(RecentProjects.shellCommand(cd: "/Users/me/it's here", run: "claude")
                == "cd '/Users/me/it'\\''s here' && claude")
    }

    @Test func nameKeysCoverProcessAndResume() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(SessionKeys.keys(pid: 42, startedAt: start, sessionId: "abc") == ["proc:42-1000", "session:abc"])
        #expect(SessionKeys.keys(pid: 42, startedAt: start, sessionId: nil) == ["proc:42-1000"])
    }
}

struct ViewingRingTests {
    @Test func ringFitsAndNeverTouchesNeighbours() {
        let halo = MenuBarDots.ringOffset + 0.6 // ring offset plus half its stroke
        for count in 1...MenuBarDots.maxDots {
            let rings = (0..<count).map { MenuBarDots.rect(at: $0, count: count).insetBy(dx: -halo, dy: -halo) }
            for (index, ring) in rings.enumerated() {
                #expect(ring.minY >= 0 && ring.maxY <= MenuBarDots.height, "count \(count) index \(index)")
                #expect(ring.minX >= 0 && ring.maxX <= MenuBarDots.layout(count: count).width, "count \(count) index \(index)")
                for other in 0..<count where other != index {
                    #expect(!ring.intersects(MenuBarDots.rect(at: other, count: count)), "count \(count): \(index) vs \(other)")
                }
            }
        }
    }
}
