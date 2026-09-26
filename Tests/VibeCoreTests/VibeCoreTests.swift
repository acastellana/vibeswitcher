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

struct ScreenOrderTests {
    private func session(_ tty: String, _ frame: CGRect?, tab: Int = 1, started: Double = 0) -> Session {
        var s = Session(tty: tty, agent: .claude, pid: 1, startedAt: Date(timeIntervalSince1970: started), cwd: nil,
                        project: tty, task: nil, status: .idle, statusSince: .distantPast, detail: nil,
                        hasHooks: true, inTerminalApp: frame != nil)
        s.screenPosition = frame.map { ScreenPosition(frame: $0, tabIndex: tab) }
        return s
    }

    @Test func readsLikeTheScreen() {
        let sessions = [
            session("bottomRight", CGRect(x: 900, y: 600, width: 800, height: 400), started: 1),
            session("right", CGRect(x: 916, y: 37, width: 800, height: 500), started: 2),
            session("left", CGRect(x: 0, y: 40, width: 900, height: 500), started: 3),     // tiled: tops differ by 3pt
            session("bottomLeft", CGRect(x: 0, y: 620, width: 800, height: 400), started: 4),
            session("elsewhere", nil, started: 0),                                           // not in Terminal
        ]
        #expect(SessionOrdering.sort(sessions).map(\.tty) == ["left", "right", "bottomLeft", "bottomRight", "elsewhere"])
        #expect(SessionOrdering.sort(sessions, by: .started).map(\.tty).first == "elsewhere")
    }

    @Test func tabsOfOneWindowKeepTabOrder() {
        let frame = CGRect(x: 0, y: 40, width: 800, height: 600)
        let sessions = [session("tab3", frame, tab: 3), session("tab1", frame, tab: 1), session("tab2", frame, tab: 2)]
        #expect(SessionOrdering.sort(sessions).map(\.tty) == ["tab1", "tab2", "tab3"])
    }
}

struct ToolActivityTests {
    @Test func describesCommonTools() {
        #expect(ToolActivity.describe(toolName: "Bash", input: ["command": "npm test", "description": "Run unit tests"]) == "Run unit tests")
        #expect(ToolActivity.describe(toolName: "Bash", input: ["command": "npm test\nnpm run lint"]) == "npm test")
        #expect(ToolActivity.describe(toolName: "shell", input: ["command": ["bash", "-lc", "cargo build"]]) == "bash -lc cargo build")
        #expect(ToolActivity.describe(toolName: "Edit", input: ["file_path": "/repo/Sources/App.swift"]) == "Edit App.swift")
        #expect(ToolActivity.describe(toolName: "Grep", input: ["pattern": "TODO"]) == "Search “TODO”")
        #expect(ToolActivity.describe(toolName: "WebFetch", input: ["url": "https://example.com/docs"]) == "Fetch example.com")
        #expect(ToolActivity.describe(toolName: "mcp__linear__list_issues", input: [:]) == "list issues (linear)")
        #expect(ToolActivity.describe(toolName: "SomethingNew", input: [:]) == "SomethingNew")
        #expect(ToolActivity.describe(toolName: "Bash", input: ["command": String(repeating: "x", count: 200)]).count == 71)
    }

    @Test func toolTimerRunsOnlyWhileTheToolDoes() throws {
        var state: HookState?
        func send(_ payload: [String: Any], at time: Double) {
            var full = payload
            full["session_id"] = "s"
            if case .write(let next) = HookState.reduce(current: state, payload: full, agent: .claude, tty: "t",
                                                        agentPid: 1, now: time) { state = next }
        }
        send(["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "sleep 600"]], at: 10)
        #expect(state?.toolDetail == "sleep 600")
        #expect(state?.toolStartedAt == 10)
        send(["hook_event_name": "PostToolUse", "tool_name": "Bash"], at: 610)
        #expect(state?.toolStartedAt == nil)
        send(["hook_event_name": "PreToolUse", "tool_name": "Read", "tool_input": ["file_path": "/a/b.md"]], at: 611)
        send(["hook_event_name": "Stop"], at: 612)
        #expect(state?.toolStartedAt == nil)
    }
}

struct DesktopOrderTests {
    @Test func desktopsComeFirstThenScreenPosition() {
        func s(_ tty: String, x: CGFloat, desktop: Int?) -> Session {
            var session = Session(tty: tty, agent: .claude, pid: 1, startedAt: .distantPast, cwd: nil, project: tty,
                                  task: nil, status: .idle, statusSince: .distantPast, detail: nil, hasHooks: true, inTerminalApp: true)
            session.screenPosition = ScreenPosition(frame: CGRect(x: x, y: 40, width: 800, height: 900), tabIndex: 1, desktop: desktop)
            return session
        }
        let sessions = [s("d7-right", x: 900, desktop: 7), s("d1", x: 500, desktop: 1), s("unknown", x: 0, desktop: nil),
                        s("d7-left", x: 0, desktop: 7), s("d3", x: 0, desktop: 3)]
        #expect(SessionOrdering.sort(sessions).map(\.tty) == ["d1", "d3", "d7-left", "d7-right", "unknown"])
    }
}

struct BackgroundJobsTests {
    @Test func extractsTheCommandFromClaudesShellWrapper() {
        let prove = "/bin/zsh -c source /Users/me/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && export X=1 && eval 'mkdir -p .logs && npm run prove > .logs/gate-$(date +%H%M).log 2>&1; echo \"EXIT $?\"' < /dev/null && pwd -P >| /tmp/cwd"
        #expect(BackgroundJobs.command(fromWrapper: prove) == "npm run prove")
        let loop = "/bin/zsh -c source /x/shell-snapshots/s.sh && eval 'until ! ps aux | grep -q \"Chrome\"; do sleep 3; done; echo done_waiting' < /dev/null"
        #expect(BackgroundJobs.command(fromWrapper: loop) == "until ! ps aux | grep -q \"Chrome\"")
        // A heredoc that writes a file, then the real work: show the work, not `cat`.
        let heredoc = "eval 'cat >> docs/NOTES.md <<'\"'\"'EOF'\"'\"'\n## Notes\n- see it'\"'\"'s table\nEOF\ngit add -A && npm run prove > logs/p.log 2>&1' < /dev/null"
        #expect(BackgroundJobs.command(fromWrapper: heredoc) == "npm run prove")
        #expect(BackgroundJobs.command(fromWrapper: "eval 'echo it'\\''s' < /dev/null") == "echo it's")
        #expect(BackgroundJobs.command(fromWrapper: "eval 'echo it'\"'\"'s' < /dev/null") == "echo it's")
        #expect(BackgroundJobs.command(fromWrapper: "/bin/zsh -c ls") == nil)
    }

    @Test func findsOnlyShellChildrenOfTheAgent() {
        func p(_ pid: Int32, _ ppid: Int32, _ comm: String, _ age: Double) -> ProcInfo {
            ProcInfo(pid: pid, ppid: ppid, tty: nil, comm: comm, startTime: Date(timeIntervalSince1970: 10_000 - age), agent: nil)
        }
        let processes: [Int32: ProcInfo] = [
            10: p(10, 10, "zsh", 100),     // wrapper, child of agent 1? no: ppid 10 (not agent) -> ignored
            11: p(11, 1, "zsh", 3600),     // background job
            12: p(12, 1, "node", 9999),    // MCP server, not a shell
            13: p(13, 1, "zsh", 60),       // shell without snapshot wrapper -> ignored
        ]
        let argv: [Int32: [String]] = [11: ["/bin/zsh", "-c", "source /h/.claude/shell-snapshots/a.sh && eval 'npm run prove' < /dev/null"],
                                       13: ["/bin/zsh", "-c", "ls"], 10: ["/bin/zsh"]]
        let jobs = BackgroundJobs.jobs(forAgent: 1, in: processes) { argv[$0.pid] ?? [] }
        #expect(jobs.map(\.command) == ["npm run prove"])
        #expect(BackgroundJobs.summary(jobs, now: Date(timeIntervalSince1970: 10_000)) == "npm run prove · 1h")
    }

    @Test func summarisesSeveralJobs() {
        let now = Date(timeIntervalSince1970: 100_000)
        let jobs = (0..<5).map { BackgroundJob(pid: Int32($0), command: "until ! pgrep Chrome",
                                                startedAt: now.addingTimeInterval(-25_200 + Double($0))) }
        #expect(BackgroundJobs.summary(jobs, now: now) == "5 shells · oldest 7h: until ! pgrep Chrome")
        #expect(Durations.short(45) == "45s" && Durations.short(3 * 3600 + 300) == "3h 5m" && Durations.short(2 * 86400 + 4 * 3600) == "2d 4h")
    }
}

struct SidebarHotZoneTests {
    @Test func onlyTheMiddleOfTheRightEdgeReveals() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        #expect(SidebarHotZone.contains(CGPoint(x: 1727, y: 558), screen: screen))          // middle of the edge
        #expect(!SidebarHotZone.contains(CGPoint(x: 1727, y: 1100), screen: screen))       // top corner
        #expect(!SidebarHotZone.contains(CGPoint(x: 1727, y: 20), screen: screen))         // bottom corner
        #expect(!SidebarHotZone.contains(CGPoint(x: 1727, y: 300), screen: screen))        // lower third: outside the band
        #expect(!SidebarHotZone.contains(CGPoint(x: 1700, y: 558), screen: screen))        // not at the edge
        // Second display to the right of the first.
        let right = CGRect(x: 1728, y: -200, width: 1920, height: 1080)
        #expect(SidebarHotZone.contains(CGPoint(x: 3647, y: 340), screen: right))
        #expect(!SidebarHotZone.contains(CGPoint(x: 3647, y: -150), screen: right))
    }
}

struct TabGroupTests {
    @Test func hiddenTabsInheritTheVisibleTabsDesktop() {
        let tabFrame = CGRect(x: 1, y: 38, width: 1722, height: 984)
        let frames: [Int: CGRect] = [
            1: tabFrame, 2: tabFrame, 3: tabFrame,               // one window with 3 tabs; tab 2 visible
            4: CGRect(x: 868, y: 44, width: 860, height: 1003),  // separate window
            5: CGRect(x: 0, y: 0, width: 500, height: 500),      // unplaced, no sibling
        ]
        let placed = [2: 1, 4: 1]
        let resolved = TabGroups.inheritDesktops(frames: frames, placed: placed)
        #expect(resolved[1] == 1 && resolved[2] == 1 && resolved[3] == 1 && resolved[4] == 1)
        #expect(resolved[5] == nil)
    }
}

struct TabOrderMatchingTests {
    @Test func matchesTabTitlesToWindowsDespiteGlyphsAndSize() {
        let names: [Int: String] = [
            10: "webshop — ✳ Plan review — node ◂ claude — 115×33",
            11: "acme-site — ◐ Redesign concepts — node ◂ claude — 115×33",
            12: "payments — Explore the billing API — codex — 115×33",
            13: "notes — -zsh — 80×24",
        ]
        // Tab bar as the user arranged it; glyphs changed between the reads.
        let bar = ["payments — Explore the billing API — codex",
                   "webshop — ◓ Plan review — node ◂ claude",
                   "acme-site — ✳ Redesign concepts — node ◂ claude"]
        let indices = TabGroups.tabIndices(windowNames: names, tabBars: [bar])
        #expect(indices == [12: 1, 10: 2, 11: 3])
    }

    @Test func identicalTitlesStillGetDistinctPositions() {
        let names: [Int: String] = [1: "shell — -zsh — 80×24", 2: "shell — -zsh — 80×24"]
        let indices = TabGroups.tabIndices(windowNames: names, tabBars: [["shell — -zsh", "shell — -zsh"]])
        #expect(Set(indices.values) == [1, 2])
    }
}
