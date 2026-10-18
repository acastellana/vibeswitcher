import Foundation
import Testing
@testable import VibeCore

/// Compressed rollouts: Codex 0.157+ can write `rollout-*.jsonl.zst` (zstd), and its app server compresses cold ones.
struct CompressedRolloutTests {
    let temp = Scratch()
    /// A scratch Codex 0.163.0 rollout (paths shortened; its developer prompt dropped), compressed by `zstd -19`
    /// (one frame, XXH64 checksum, Huffman literals and FSE sequences).
    static let rollout = Data(base64Encoded: [
        "KLUv/WT0BhUXADZpdiIwa/VBXW+xUNGoUEQNt4w+/3RGy4df8Hy/IQZwcw0MdJwDbABqAG4A/A7+8CkGnQqPn/rTGq1fSqqWD2bc",
        "YU+TjnGcgkSxiRAm3SGMZBbERb20bgwmrpx8sCf6Nh7LrtJDM/jgyX9Cv7Qyrlt+7IyH58M9lppOaSsfnNAcJcAtb1Fe0w5cQ1hD",
        "moQl/Jgx9V+f5nMjMFIK8TwAVVWx00r58aW+/3LjqWja/4aMOPHBHluHh1+pEY+l26p4quFTn1LllP3H/i4xJhklTC6LW/oxrfNO",
        "BrcNcy5qnMiWjo0kCOYQ5lBLPZweLVUvlE6n7W/Z7xMf1ULFU7Ee+vLjI3EpfjYs6T8dfN3rsVoDCl1Ja/S7WABbbyFQKEqGOWa9",
        "AYK1oJRCgB8frl06Ii79NIM8TzuIorRDoqWpT1WYtOdZGjc+uGJoKhBF/LbxrqqIztB6DMkpMtR46hOVsE17gtEdfGrKBzcYEfJg",
        "SeoYAFWlPH/tRMD68GiLpaRznIVJkse1x99Q+tv+m2j4tyX4FS5uP4M7j5Io3kx5nGhBtIMgGqYl07SF218pbVrletp/573dmIUx",
        "jDHlsctprTNU+HOaEoSL2JFEKfSU9Z5S1Bf1V2LaAgqx5bIGZqAhtVLIkMiQBCVpU2gMMIQQgwqvAyADlHaw8xYeAHEAsEGXbWKg",
        "tNAAXlpH6/i1tEiUKebHBpHF4fluGFBrQSga+eXxoa8lDw0IqYFg0YGZia4i0eCMSPhAC2jk99CIDm5RIjjBsiW/4ne1QVqliPm/",
        "ZHTIK8X8ZPRKBFqPco6Kuy0ED0B0cGTOgSKAlkF6AOZp9nkXhUVRi8NLINAliVN/bOSnRwEZCdIvx1kcEXf2dzQtsew54I0hGZC6",
        "rKxd/28gwBQy50JkOqjQ78ApmeOlK6XBcdiVb5gPmqAAlHrvZ6ExDj9UqOjIpEpCNhXwhCQiIhXv8XoRDXeJDSUK6gYwqxC4Cm6H",
        "o1E=",
    ].joined())!

    @Test func decompressesARollout() throws {
        let plain = try Zstd.decompress(Self.rollout)
        let (entries, consumed) = TranscriptReader.read(plain, format: .codex)
        #expect(consumed == plain.count)
        #expect(entries.map(\.kind) == [.prompt, .tool, .reply])
        #expect(entries.first?.text == "say hi")
        #expect(entries[1].text == "echo scratch-hi")
        #expect(entries[1].output?.contains("scratch-hi") == true)
        #expect(entries.last?.text == "scratch done")
    }

    @Test func decompressesConcatenatedAndSkippableFrames() throws {
        // `zstd -3` of "two frames " then `zstd --no-check -1` of 118 z's and " end\n" (an RLE-friendly run).
        let frames = Data(base64Encoded: "KLUv/SQLWQAAdHdvIGZyYW1lcyBalyYcKLUv/SB7bQAAOHp6IGVuZAoBADEFWA==")!
        let expected = "two frames " + String(repeating: "z", count: 118) + " end\n"
        #expect(String(decoding: try Zstd.decompress(frames), as: UTF8.self) == expected)
        let skippable = Data([0x50, 0x2A, 0x4D, 0x18, 3, 0, 0, 0, 1, 2, 3])
        #expect(String(decoding: try Zstd.decompress(skippable + frames), as: UTF8.self) == expected)
    }

    @Test func rejectsWhatIsNotZstd() {
        #expect(throws: Zstd.Failure.self) { try Zstd.decompress(Data("{\"type\":\"session_meta\"}\n".utf8)) }
        #expect(throws: Zstd.Failure.self) { try Zstd.decompress(Self.rollout.prefix(200)) }
        #expect(throws: Zstd.Failure.tooLarge) { try Zstd.decompress(Self.rollout, limit: 100) }
    }

    /// A temp home with Codex's sessions folder.
    private func home() throws -> (URL, URL) {
        let home = temp.url("rollout")
        let sessions = home.appendingPathComponent(".codex/sessions/2026/10/17")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        return (home, sessions)
    }

    @Test func aCompressedRolloutIsReadThroughAPrivateCopy() throws {
        let (home, sessions) = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "rollout-2026-10-17T18-34-39-01a14ab7-255f-77e2-8353-03f47862724d.jsonl"
        let compressed = sessions.appendingPathComponent(name + ".zst")
        try Self.rollout.write(to: compressed)

        // The hook recorded the .jsonl name before Codex compressed it; the .zst name works as well.
        for path in [sessions.appendingPathComponent(name).path, compressed.path] {
            let (url, format) = try #require(TranscriptReader.checkedURL(path, home: home.path))
            #expect(format == .codex)
            #expect(url.path.hasPrefix(home.resolvingSymlinksInPath().path + "/.vibeswitcher/transcripts/"))
            #expect(try Data(contentsOf: url) == Zstd.decompress(Self.rollout))
            #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            // What callers keep and hand back (the inspector, the lead's tools) is checked again.
            #expect(TranscriptReader.checkedURL(url.path, home: home.path)?.1 == .codex)
        }

        // Resumed: Codex writes the plain file again, and that is what's read.
        let plain = sessions.appendingPathComponent(name)
        try Data("{}\n".utf8).write(to: plain)
        try FileManager.default.removeItem(at: compressed)
        #expect(TranscriptReader.checkedURL(compressed.path, home: home.path)?.0.path == plain.resolvingSymlinksInPath().path)
    }

    @Test func compressedFilesOutsideCodexSessionsAreRefused() throws {
        let (home, _) = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent(".claude/projects/p")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let elsewhere = home.appendingPathComponent("secret.jsonl.zst")
        try Self.rollout.write(to: elsewhere)
        try Self.rollout.write(to: claude.appendingPathComponent("s.jsonl.zst"))
        #expect(TranscriptReader.checkedURL(elsewhere.path, home: home.path) == nil)
        #expect(TranscriptReader.checkedURL(claude.appendingPathComponent("s.jsonl.zst").path, home: home.path) == nil)
        // Something that isn't zstd under the right name is refused too, not copied.
        let (_, sessions) = try self.home()
        let bogus = sessions.appendingPathComponent("rollout-x.jsonl.zst")
        try Data("not zstd".utf8).write(to: bogus)
        #expect(TranscriptReader.checkedURL(bogus.path, home: sessions.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path) == nil)
    }
}

/// Codex's `request_user_input_async`: asks without blocking, so the question outlives the call and the turn.
///
/// SYNTHETIC: no Codex build here offers the tool to a TUI thread (0.160 and 0.163 both listed only
/// `request_user_input` in scratch runs), so no real payload or rollout line exists. These follow Codex's own shapes:
/// the hook payload of a recorded PreToolUse for `request_user_input` (same handler family) with the async tool's
/// arguments as `codex app-server generate-json-schema` (0.163.0) defines them: `AsyncUserInputQuestion { title,
/// options }`, from core/src/tools/handlers/request_user_input_async.rs (which answers `{"accepted":true}` at once).
struct AsyncQuestionTests {
    private func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["hook_event_name": name, "session_id": "01a14ab6-1022-7e81-9d4f-8a8470a11b3a", "cwd": "/Users/me/scratch/proj",
         "turn_id": "01a14ab6-2ed6-7601-a921-53e2be8ac46b"].merging(extra) { $1 }
    }
    private let asked: [String: Any] = ["tool_name": "request_user_input_async", "tool_use_id": "call_1",
                                        "tool_input": ["questions": [["title": "Pick a color?", "options": ["red", "blue"]]]]]

    private func run(_ events: [([String: Any], String?)]) -> HookState? {
        var state: HookState?
        var clock = 100.0
        for (payload, rollout) in events {
            clock += 1
            if case .write(let next) = HookState.reduce(current: state, payload: payload, agent: .codex, tty: "ttys000",
                                                       agentPid: 87489, now: clock, rolloutQuestion: rollout) {
                state = next
            }
        }
        return state
    }

    @Test func anAsyncQuestionNeedsYouAfterTheTurnEnds() throws {
        var state = try #require(run([(event("UserPromptSubmit", ["prompt": "pick for me"]), nil), (event("PreToolUse", asked), nil)]))
        #expect(StatusRules.status(for: state) == .needsInput)
        state = try #require(run([(event("UserPromptSubmit"), nil), (event("PreToolUse", asked), nil), (event("PostToolUse", asked), nil)]))
        #expect(StatusRules.status(for: state) == .needsInput)
        #expect(state.request == "Pick a color?")
        // The turn goes on (working), then ends: still waiting for your answer.
        let working = run([(event("UserPromptSubmit"), nil), (event("PreToolUse", asked), nil), (event("PostToolUse", asked), nil),
                           (event("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "ls"]]), nil)])
        #expect(working.map(StatusRules.status(for:)) == .working)
        state = try #require(run([(event("UserPromptSubmit"), nil), (event("PreToolUse", asked), nil), (event("PostToolUse", asked), nil),
                                  (event("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "ls"]]), nil),
                                  (event("PostToolUse", ["tool_name": "Bash"]), nil),
                                  (event("Stop", ["last_assistant_message": "Asked which color."]), nil)]))
        #expect(StatusRules.status(for: state) == .needsInput)
        #expect(state.request == "Pick a color?")
        #expect(state.lastMessage == "Asked which color.")
    }

    @Test func answeringClearsIt() throws {
        let answered = try #require(run([(event("PreToolUse", asked), nil), (event("Stop"), nil),
                                         (event("UserPromptSubmit", ["prompt": "blue"]), nil), (event("Stop"), nil)]))
        #expect(answered.openQuestion == nil)
        #expect(StatusRules.status(for: answered) == .done)
        // A new session doesn't inherit it either.
        let fresh = try #require(run([(event("PreToolUse", asked), nil), (event("Stop"), nil), (event("SessionStart", ["source": "startup"]), nil)]))
        #expect(fresh.openQuestion == nil)
        // Plain turns are unchanged: done, and a PostToolUse of any other tool is work.
        #expect(run([(event("UserPromptSubmit"), nil), (event("Stop"), nil)]).map(StatusRules.status(for:)) == .done)
        #expect(run([(event("PostToolUse", ["tool_name": "Bash"]), nil)]).map(StatusRules.status(for:)) == .working)
    }

    /// The rollout lines Codex writes for it (shape of every recorded `function_call` line; arguments per the schema).
    static let rolloutAsked = """
    {"timestamp":"2026-10-17T16:33:36.071Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"pick for me"}]}}
    {"timestamp":"2026-10-17T16:33:36.090Z","type":"response_item","payload":{"type":"function_call","status":"completed","id":"fc_1","name":"request_user_input_async","arguments":"{\\"questions\\": [{\\"title\\": \\"Pick a color?\\", \\"options\\": [\\"red\\", \\"blue\\"]}]}","call_id":"call_1"}}
    {"timestamp":"2026-10-17T16:33:36.100Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"{\\"accepted\\":true}"}}
    {"timestamp":"2026-10-17T16:33:36.300Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Asked which color."}]}}

    """

    @Test func theRolloutTellsAnOpenQuestion() throws {
        #expect(TranscriptReader.openAsyncQuestion(in: Data(Self.rolloutAsked.utf8)) == "Pick a color?")
        let answer = #"{"timestamp":"2026-10-17T16:34:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"blue"}]}}"#
        #expect(TranscriptReader.openAsyncQuestion(in: Data((Self.rolloutAsked + answer + "\n").utf8)) == nil)
        // An agent message that carries the questions (the app server's `AgentMessageThreadItem.questions`).
        let item = #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"msg_2","questions":[{"title":"Which branch?"},{"title":"Squash?"}]}}}"#
        #expect(TranscriptReader.openAsyncQuestion(in: Data((item + "\n").utf8)) == "Which branch? (+1 more)")
        // A recorded rollout without one.
        #expect(TranscriptReader.openAsyncQuestion(in: try Zstd.decompress(CompressedRolloutTests.rollout)) == nil)

        // Missed by the hooks (no PreToolUse for it): the Stop still finds it in the rollout.
        let state = try #require(run([(event("UserPromptSubmit"), nil), (event("Stop"), "Pick a color?")]))
        #expect(StatusRules.status(for: state) == .needsInput)
        #expect(state.request == "Pick a color?")
    }
}

/// Codex's newer hook events.
struct CodexHookEventTests {
    private func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["hook_event_name": name, "session_id": "01a14ab7-255f-77e2-8353-03f47862724d", "cwd": "/Users/me/scratch/proj",
         "transcript_path": "/Users/me/.codex/sessions/2026/10/17/rollout-2026-10-17T18-34-39-01a14ab7-255f-77e2-8353-03f47862724d.jsonl",
         "model": "gpt-5.4"].merging(extra) { $1 }
    }

    private func run(_ events: [[String: Any]]) -> HookState? {
        var state: HookState?
        var clock = 100.0
        for payload in events {
            clock += 1
            switch HookState.reduce(current: state, payload: payload, agent: .codex, tty: "ttys000", agentPid: 87489, now: clock) {
            case .write(let next): state = next
            case .delete: state = nil
            case .ignore: break
            }
        }
        return state
    }

    @Test func installAddsSubagentAndCompactEvents() throws {
        let config = HookInstaller.addingOurs(to: [:], agent: .codex, hookBinary: "/h/vibeswitcher-hook")
        let hooks = try #require(config["hooks"] as? [String: Any])
        for name in ["SubagentStart", "SubagentStop", "PostCompact", "PreCompact", "SessionStart"] { #expect(hooks[name] != nil) }
        #expect(HookInstaller.isComplete(in: config, agent: .codex))
        // An install from before them counts as missing, so the app offers to install again.
        var old = config
        var oldHooks = hooks
        for name in ["SubagentStart", "SubagentStop", "PostCompact"] { oldHooks[name] = nil }
        old["hooks"] = oldHooks
        #expect(HookInstaller.isInstalled(in: old))
        #expect(!HookInstaller.isComplete(in: old, agent: .codex))
        #expect(HookInstaller.isComplete(in: HookInstaller.addingOurs(to: old, agent: .codex, hookBinary: "/h/vibeswitcher-hook"), agent: .codex))
    }

    /// Recorded (0.160 TUI, 0.163 daemon): `/compact` sends PreCompact then PostCompact, trigger "manual", and no Stop.
    @Test func aManualCompactEndsWhereItStarted() throws {
        let compact = [event("UserPromptSubmit", ["prompt": "say hi"]), event("Stop", ["last_assistant_message": "scratch done"]),
                       event("PreCompact", ["trigger": "manual", "turn_id": "01a14ab7-6191-7f72-b3ba-c524dfa2d4ea"])]
        let during = try #require(run(compact))
        #expect(StatusRules.status(for: during) == .working)
        let after = try #require(run(compact + [event("PostCompact", ["trigger": "manual", "turn_id": "01a14ab7-6191-7f72-b3ba-c524dfa2d4ea"])]))
        #expect(StatusRules.status(for: after) == .done)
        #expect(after.lastEventAt == 102)   // the Stop's: not a new "done"
        // Compacting mid-turn (trigger "auto") is still work.
        let auto = try #require(run([event("UserPromptSubmit"), event("PreCompact", ["trigger": "auto"]), event("PostCompact", ["trigger": "auto"])]))
        #expect(StatusRules.status(for: auto) == .working)
    }

    @Test func subagentEventsBelongToTheMainSession() throws {
        let start = [event("UserPromptSubmit", ["prompt": "review it"]),
                     event("SubagentStart", ["agent_id": "01a14ab9-0000-7000-8000-00000000aaaa", "agent_type": "explorer"])]
        var state = try #require(run(start))
        #expect(StatusRules.status(for: state) == .working)
        // A subagent's own events carry its agent_id (and maybe its own thread): they don't replace the session.
        state = try #require(run(start + [event("PreToolUse", ["agent_id": "01a14ab9-0000-7000-8000-00000000aaaa",
                                                              "session_id": "01a14ab9-0000-7000-8000-00000000aaaa",
                                                              "transcript_path": "/Users/me/.codex/sessions/sub.jsonl",
                                                              "tool_name": "Bash", "tool_input": ["command": "git log"]]),
                                          event("Stop", ["agent_id": "01a14ab9-0000-7000-8000-00000000aaaa"])]))
        #expect(state.sessionId == "01a14ab7-255f-77e2-8353-03f47862724d")
        #expect(state.transcriptPath?.hasSuffix("01a14ab7-255f-77e2-8353-03f47862724d.jsonl") == true)
        #expect(state.lastPrompt == "review it")
        #expect(state.toolDetail == "git log")
        #expect(StatusRules.status(for: state) == .working)
        // A subagent that ends after the turn did doesn't bring it back to work.
        state = try #require(run(start + [event("Stop"), event("SubagentStop", ["agent_id": "01a14ab9-0000-7000-8000-00000000aaaa"])]))
        #expect(StatusRules.status(for: state) == .done)
    }

    /// Recorded: `codex fork --last` sends SessionStart with source "fork" and a new session id.
    @Test func aForkIsANewSessionWithTheSameLabel() throws {
        let fork = event("SessionStart", ["source": "fork", "session_id": "01a14ab7-970a-7681-b980-e9673fafb048",
                                          "transcript_path": "/Users/me/.codex/sessions/2026/10/17/rollout-2026-10-17T18-35-08-01a14ab7-970a-7681-b980-e9673fafb048.jsonl"])
        let state = try #require(run([event("UserPromptSubmit", ["prompt": "fix the login bug"]), event("Stop"), fork]))
        #expect(state.sessionId == "01a14ab7-970a-7681-b980-e9673fafb048")
        #expect(state.firstPrompt == "fix the login bug")
        #expect(state.lastPrompt == nil)
        #expect(state.transcriptPath?.hasSuffix("e9673fafb048.jsonl") == true)
        #expect(StatusRules.status(for: state) == .idle)
        // A plain new session starts over.
        let fresh = try #require(run([event("UserPromptSubmit", ["prompt": "fix the login bug"]),
                                      event("SessionStart", ["source": "startup", "session_id": "01a14ab7-aaaa-7000-8000-000000000000"])]))
        #expect(fresh.firstPrompt == nil)
    }
}
