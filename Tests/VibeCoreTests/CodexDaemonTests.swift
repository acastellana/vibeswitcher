import Foundation
import Testing
@testable import VibeCore

/// Codex 0.157+ runs threads in its background app server. Recorded on this Mac (Codex CLI 0.160.0 TUI, app-server
/// daemon 0.163.0, scratch CODEX_HOME, a local stand-in model), paths shortened to /Users/me/scratch:
///
///     88213 87102 ??       /bin/sh                                  ← the hook (no tty)
///     87102     1 ??       …/app-server-daemon/releases/0.163.0-aarch64-apple-darwin/bin/codex app-server --listen unix:// --managed-daemon
///     87489 87480 ttys000  …/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex   ← the TUI, not an ancestor
struct CodexDaemonHookTests {
    static let sessionStart: [String: Any] = [
        "session_id": "01a14abd-1fd4-7043-9608-91324844a09a",
        "transcript_path": "/Users/me/scratch/home/.codex/sessions/2026/10/17/rollout-2026-10-17T18-41-10-01a14abd-1fd4-7043-9608-91324844a09a.jsonl",
        "cwd": "/Users/me/scratch/proj", "hook_event_name": "SessionStart", "model": "gpt-5.4",
        "permission_mode": "bypassPermissions", "source": "startup",
    ]
    static func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var payload = sessionStart
        payload["hook_event_name"] = name
        payload["source"] = nil
        payload["turn_id"] = "01a14abd-3f12-7b20-a4c1-7d2b1e9c0a11"
        return payload.merging(extra) { $1 }
    }

    let daemonArgv = ["/Users/me/.codex/packages/app-server-daemon/releases/0.163.0-aarch64-apple-darwin/bin/codex",
                      "app-server", "--listen", "unix://", "--managed-daemon"]
    /// 18:41:10.0 (just before the thread id's 18:41:10.868).
    let tuiStart = Date(timeIntervalSince1970: 1_792_255_270)

    private func proc(_ pid: Int32, _ ppid: Int32, tty: String?, comm: String, agent: Agent?, start: Date? = nil) -> ProcInfo {
        ProcInfo(pid: pid, ppid: ppid, tty: tty, comm: comm, startTime: start ?? tuiStart, agent: agent)
    }

    private func terminal(_ pid: Int32, tty: String, dir: String? = "/Users/me/scratch/proj", argv: [String] = ["codex"],
                          start: Date? = nil, session: String? = nil, statePid: Int32? = nil) -> HookOwner.CodexTerminal {
        var state: HookState?
        if let session {
            state = HookState(agent: .codex, tty: tty, lastEvent: "Stop", lastEventAt: 1)
            state?.sessionId = session
            state?.agentPid = statePid ?? pid
        }
        return HookOwner.CodexTerminal(pid: pid, tty: tty, startTime: start ?? tuiStart, directory: dir, arguments: argv, state: state)
    }

    // MARK: Where the hook runs

    @Test func aHookRunByTheDaemonIsDetached() {
        let daemon = proc(87102, 1, tty: nil, comm: "codex", agent: nil)
        let argv: (ProcInfo) -> [String] = { $0.pid == 87102 ? daemonArgv : [] }
        #expect(HookOwner.lineage([daemon], arguments: argv) == .detached)
        // While the TUI that started the daemon lives, it is the daemon's parent: still not this hook's session.
        let firstTUI = proc(31465, 31464, tty: "ttys038", comm: "codex", agent: .codex)
        #expect(HookOwner.lineage([daemon, firstTUI], arguments: argv) == .detached)
    }

    @Test func aHookRunByItsAgentStillUsesThatAgent() {
        let tui = proc(500, 400, tty: "ttys004", comm: "codex", agent: .codex)
        #expect(HookOwner.lineage([tui], arguments: { _ in ["codex"] }) == .agent(pid: 500, tty: "ttys004"))
        // `codex exec` run by Claude: two agents up the chain.
        let exec = proc(600, 500, tty: "ttys005", comm: "codex", agent: .codex)
        let claude = proc(500, 400, tty: "ttys005", comm: "claude", agent: .claude)
        #expect(HookOwner.lineage([exec, claude], arguments: { _ in ["codex", "exec"] }) == .nested)
        #expect(HookOwner.lineage([proc(9, 1, tty: nil, comm: "zsh", agent: nil)], arguments: { _ in [] }) == .none)
    }

    // MARK: Which TUI it is for

    @Test func theOneTUIInThePayloadsFolderGetsTheRecordedSession() throws {
        let tui = terminal(87489, tty: "ttys000")
        let elsewhere = terminal(91000, tty: "ttys001", dir: "/Users/me/other")
        let found = HookOwner.codexTerminal(for: Self.sessionStart, among: [elsewhere, tui])
        #expect(found?.tty == "ttys000")
        #expect(found?.pid == 87489)

        // Folded into the state the app reads: status, transcript link and the TUI's pid (so the scan keeps it).
        var state: HookState?
        for payload in [Self.sessionStart, Self.event("UserPromptSubmit", ["prompt": "say hi"]),
                        Self.event("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "echo scratch-hi"], "tool_use_id": "call_1"]),
                        Self.event("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]])] {
            let owner = try #require(HookOwner.codexTerminal(for: payload, among: [elsewhere, terminal(87489, tty: "ttys000", session: state?.sessionId)]))
            guard case .write(let next) = HookState.reduce(current: state, payload: payload, agent: .codex, tty: owner.tty,
                                                           agentPid: owner.pid, now: 10) else { Issue.record("not written"); return }
            state = next
        }
        let final = try #require(state)
        #expect(final.agentPid == 87489)
        #expect(final.sessionId == "01a14abd-1fd4-7043-9608-91324844a09a")
        #expect(final.transcriptPath == Self.sessionStart["transcript_path"] as? String)
        #expect(final.lastPrompt == "say hi")
        #expect(StatusRules.status(for: final) == .needsInput)
        #expect(final.request == "Run: rm -rf build")
    }

    @Test func aKnownSessionStaysWithItsTUI() {
        let mine = terminal(87489, tty: "ttys000", dir: "/Users/me/elsewhere", session: "01a14abd-1fd4-7043-9608-91324844a09a")
        let other = terminal(90000, tty: "ttys002")
        #expect(HookOwner.codexTerminal(for: Self.event("Stop"), among: [other, mine])?.tty == "ttys000")
    }

    @Test func aResumedSessionIsFoundByItsArguments() {
        let resumed = terminal(87489, tty: "ttys000", dir: "/Users/me/elsewhere",
                               argv: ["codex", "resume", "01a14abd-1fd4-7043-9608-91324844a09a"])
        #expect(HookOwner.codexTerminal(for: Self.event("UserPromptSubmit"), among: [resumed])?.tty == "ttys000")
    }

    @Test func newInTheSameTUIStartsItsNextSession() {
        // `/new` (and `/fork`, `/resume`) in a TUI: SessionStart "startup" for another session id, same process.
        let tui = terminal(87489, tty: "ttys000", session: "01a14abc-0000-7000-8000-000000000000")
        #expect(HookOwner.codexTerminal(for: Self.sessionStart, among: [tui])?.tty == "ttys000")
        var fork = Self.sessionStart
        fork["source"] = "fork"
        #expect(HookOwner.codexTerminal(for: fork, among: [tui])?.tty == "ttys000")
    }

    @Test func anotherTUIsSessionIsNotStolen() {
        // A TUI that quits leaves its thread running in the daemon ("Disconnected from this task. Any running work
        // continues."): its events must not land on the TUI now working in that folder.
        let busy = terminal(87489, tty: "ttys000", session: "01a14abc-0000-7000-8000-000000000000")
        #expect(HookOwner.codexTerminal(for: Self.event("PreToolUse"), among: [busy]) == nil)
        // Two TUIs there, both on known sessions: a new one can't be told apart either.
        let second = terminal(87600, tty: "ttys003", session: "01a14abc-1111-7000-8000-000000000000")
        #expect(HookOwner.codexTerminal(for: Self.sessionStart, among: [busy, second]) == nil)
        // One of them not known yet: that's the one.
        let fresh = terminal(87601, tty: "ttys004")
        #expect(HookOwner.codexTerminal(for: Self.event("UserPromptSubmit"), among: [busy, fresh])?.tty == "ttys004")
        // No session id, no folder: nothing to go on.
        var bare = Self.event("Stop")
        bare["session_id"] = nil
        #expect(HookOwner.codexTerminal(for: bare, among: [fresh]) == nil)
    }

    @Test func twoFreshTUIsAreToldApartByWhenTheThreadWasMade() {
        // The thread id is a UUIDv7 made at 18:41:10.868: the TUI started last before then made it.
        let earlier = terminal(87400, tty: "ttys005", start: tuiStart.addingTimeInterval(-30))
        let launched = terminal(87489, tty: "ttys000", start: tuiStart)
        let later = terminal(87700, tty: "ttys006", start: tuiStart.addingTimeInterval(20))
        #expect(HookOwner.codexTerminal(for: Self.sessionStart, among: [earlier, later, launched])?.tty == "ttys000")
        #expect(HookOwner.uuidV7Date("01a14abd-1fd4-7043-9608-91324844a09a")?.timeIntervalSince1970 == 1_792_255_270.868)
        #expect(HookOwner.uuidV7Date("9f2c1a3e-1fd4-4043-9608-91324844a09a") == nil)
    }

    @Test func terminalsAreTheFirstCodexOnEachTTY() {
        let processes: [ProcInfo] = [
            proc(87102, 1, tty: nil, comm: "codex", agent: nil),                                   // the daemon
            proc(87489, 87480, tty: "ttys000", comm: "codex", agent: .codex),                      // a TUI
            proc(87495, 87489, tty: "ttys000", comm: "codex", agent: .codex, start: tuiStart.addingTimeInterval(5)),
            proc(70000, 1, tty: "ttys007", comm: "claude", agent: .claude, start: tuiStart.addingTimeInterval(-99)),
            proc(70100, 70000, tty: "ttys007", comm: "codex", agent: .codex),                      // Claude's `codex exec`
        ]
        let table = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let terminals = HookOwner.codexTerminals(processes: table, cwd: { _ in "/Users/me/scratch" },
                                                 arguments: { _ in ["codex", "-C", "proj"] }, state: { _ in nil })
        #expect(terminals.map(\.pid) == [87489])
        #expect(terminals.first?.directory == "/Users/me/scratch/proj")
    }

    @Test func directoryFollowsCd() {
        #expect(HookOwner.directory(arguments: ["codex"], cwd: "/a") == "/a")
        #expect(HookOwner.directory(arguments: ["codex", "--cd", "/b"], cwd: "/a") == "/b")
        #expect(HookOwner.directory(arguments: ["codex", "--cd=sub"], cwd: "/a") == "/a/sub")
        #expect(HookOwner.directory(arguments: ["codex", "-C", "sub"], cwd: nil) == nil)
    }
}
