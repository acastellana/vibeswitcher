import Foundation
import Testing
@testable import VibeCore

struct ActivityFeedTests {
    func feed(_ text: String, _ format: TranscriptReader.Format, startsMidFile: Bool = false, limit: Int = 80) -> ActivityFeed {
        ActivityFeed.read(Data((text.hasSuffix("\n") ? text : text + "\n").utf8), format: format, startsMidFile: startsMidFile, limit: limit)
    }

    func files(_ feed: ActivityFeed) -> [ActivityFeed.FileChange] { feed.rows.compactMap { if case .file(let f) = $0 { f } else { nil } } }
    func commands(_ feed: ActivityFeed) -> [ActivityFeed.Command] { feed.rows.compactMap { if case .command(let c) = $0 { c } else { nil } } }
    func turns(_ feed: ActivityFeed) -> [ActivityFeed.Turn] { feed.rows.compactMap { if case .turn(let t) = $0 { t } else { nil } } }

    /// Claude Code 2.1.302 lines (ClaudeFixtures' shape): a prompt, a described Bash that passes, one that fails, an Edit
    /// whose `toolUseResult` patch says what it did, a MultiEdit without one, a new file, an Edit that failed; usage on
    /// every assistant line (repeated for each block of a message), `costUSD` as older versions wrote it; a second turn.
    static let claude = #"""
{"type":"user","uuid":"u1","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:00:00.000Z","message":{"role":"user","content":"Fix the parser and run the tests"},"sessionId":"s"}
{"type":"assistant","uuid":"a1","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:00:02.000Z","costUSD":0.25,"message":{"role":"assistant","id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"toolu_bash1","name":"Bash","input":{"command":"swift test --filter Parser\necho done","description":"Run **the** `Parser` tests"}}],"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"output_tokens":50}},"sessionId":"s"}
{"type":"user","uuid":"r1","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:00:14.000Z","message":{"role":"user","content":[{"tool_use_id":"toolu_bash1","type":"tool_result","content":"Test run with 3 tests passed","is_error":false}]},"toolUseResult":{"stdout":"Test run with 3 tests passed","stderr":"","interrupted":false,"isImage":false},"sessionId":"s"}
{"type":"assistant","uuid":"a2","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:00:15.000Z","costUSD":0.25,"message":{"role":"assistant","id":"msg_2","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"toolu_bash2","name":"Bash","input":{"command":"make lint"}}],"usage":{"input_tokens":5,"cache_read_input_tokens":1200,"cache_creation_input_tokens":0,"output_tokens":20}},"sessionId":"s"}
{"type":"user","uuid":"r2","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:00:15.500Z","message":{"role":"user","content":[{"type":"tool_result","content":"Exit code 2\nmake: *** No rule to make target 'lint'.","is_error":true,"tool_use_id":"toolu_bash2"}]},"toolUseResult":"Error: Exit code 2\nmake: *** No rule to make target 'lint'.","sessionId":"s"}
{"type":"assistant","uuid":"a3","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:00:16.000Z","message":{"role":"assistant","id":"msg_3","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"toolu_edit1","name":"Edit","input":{"file_path":"/Users/me/proj/Sources/Parser.swift","old_string":"let a = 1","new_string":"let a = 2","replace_all":true}}],"usage":{"input_tokens":5,"cache_read_input_tokens":1300,"cache_creation_input_tokens":0,"output_tokens":30}},"sessionId":"s"}
{"type":"user","uuid":"r3","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:00:16.100Z","message":{"role":"user","content":[{"tool_use_id":"toolu_edit1","type":"tool_result","content":"The file /Users/me/proj/Sources/Parser.swift has been updated. All occurrences were replaced."}]},"toolUseResult":{"filePath":"/Users/me/proj/Sources/Parser.swift","oldString":"let a = 1","newString":"let a = 2","replaceAll":true,"structuredPatch":[{"oldStart":3,"oldLines":1,"newStart":3,"newLines":1,"lines":["-let a = 1","+let a = 2"]},{"oldStart":9,"oldLines":2,"newStart":9,"newLines":3,"lines":[" x","-let a = 1","+let a = 2","+// two"]}],"userModified":false},"sessionId":"s"}
{"type":"assistant","uuid":"a4","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:00:17.000Z","message":{"role":"assistant","id":"msg_3","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"toolu_multi","name":"MultiEdit","input":{"file_path":"/Users/me/proj/Sources/Parser.swift","edits":[{"old_string":"a\nb","new_string":"a\nc\nd"}]}}],"usage":{"input_tokens":5,"cache_read_input_tokens":1300,"cache_creation_input_tokens":0,"output_tokens":30}},"sessionId":"s"}
{"type":"user","uuid":"r4","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:00:17.100Z","message":{"role":"user","content":[{"tool_use_id":"toolu_multi","type":"tool_result","content":"Applied 1 edit"}]},"sessionId":"s"}
{"type":"assistant","uuid":"a5","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:00:18.000Z","message":{"role":"assistant","id":"msg_4","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"toolu_write","name":"Write","input":{"file_path":"/Users/me/proj/Tests/ParserTests.swift","content":"import Testing\n\n@Test func parses() {}\n"}}],"usage":{"input_tokens":5,"cache_read_input_tokens":1400,"cache_creation_input_tokens":0,"output_tokens":40}},"sessionId":"s"}
{"type":"user","uuid":"r5","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:00:18.100Z","message":{"role":"user","content":[{"tool_use_id":"toolu_write","type":"tool_result","content":"File created successfully at: /Users/me/proj/Tests/ParserTests.swift"}]},"toolUseResult":{"type":"create","filePath":"/Users/me/proj/Tests/ParserTests.swift","content":"import Testing\n\n@Test func parses() {}\n","structuredPatch":[],"originalFile":null},"sessionId":"s"}
{"type":"assistant","uuid":"a6","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:00:19.000Z","message":{"role":"assistant","id":"msg_5","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"toolu_bad","name":"Edit","input":{"file_path":"/Users/me/proj/README.md","old_string":"nope","new_string":"yes"}}],"usage":{"input_tokens":5,"cache_read_input_tokens":1500,"cache_creation_input_tokens":0,"output_tokens":10}},"sessionId":"s"}
{"type":"user","uuid":"r6","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:00:19.100Z","message":{"role":"user","content":[{"type":"tool_result","content":"<tool_use_error>String to replace not found in file.</tool_use_error>","is_error":true,"tool_use_id":"toolu_bad"}]},"toolUseResult":"Error: String to replace not found in file.","sessionId":"s"}
{"type":"assistant","uuid":"a7","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:00:20.000Z","message":{"role":"assistant","id":"msg_6","model":"claude-opus-5-5","content":[{"type":"text","text":"Fixed **the parser**; `make lint` doesn't exist."}],"usage":{"input_tokens":5,"cache_read_input_tokens":1600,"cache_creation_input_tokens":0,"output_tokens":25}},"sessionId":"s"}
{"type":"user","uuid":"u2","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:05:00.000Z","message":{"role":"user","content":"thanks, start the server"},"sessionId":"s"}
{"type":"assistant","uuid":"b1","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:05:02.000Z","message":{"role":"assistant","id":"msg_7","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"toolu_bg","name":"Bash","input":{"command":"npm run dev","run_in_background":true}}],"usage":{"input_tokens":5,"cache_read_input_tokens":1700,"cache_creation_input_tokens":0,"output_tokens":15}},"sessionId":"s"}
{"type":"user","uuid":"r7","isSidechain":false,"cwd":"/Users/me/proj","timestamp":"2026-10-18T09:05:02.200Z","message":{"role":"user","content":[{"tool_use_id":"toolu_bg","type":"tool_result","content":"Command running in background with ID: bash_1"}]},"toolUseResult":{"stdout":"","stderr":"","interrupted":false,"isImage":false,"backgroundTaskId":"bash_1"},"sessionId":"s"}
"""#

    @Test func claudeFilesCommandsAndTurns() throws {
        let feed = feed(Self.claude, .claude)
        // Files: relative to the cwd, one row per file per turn; the patch's counts over the input's; a failed edit left out.
        let changed = files(feed)
        #expect(changed.map(\.path) == ["Sources/Parser.swift", "Tests/ParserTests.swift"])
        // The patch: +2 −2 (replace_all hit two places, one hunk adds a line: +3 −2); the MultiEdit's input: +2 −1.
        #expect(changed[0].added == 3 + 2 && changed[0].removed == 2 + 1 && changed[0].edits == 2 && changed[0].action == .edited)
        #expect(changed[1].added == 3 && changed[1].removed == 0 && changed[1].action == .created)
        #expect(changed[0].tool.name == "MultiEdit")

        let ran = commands(feed)
        #expect(ran.map(\.command) == ["swift test --filter Parser", "make lint", "npm run dev"])
        #expect(ran[0].moreLines && !ran[1].moreLines)
        #expect(ran[0].title == "Run the Parser tests")   // the description, markdown gone
        #expect(ran[1].title == nil)                       // no description: the command is the title
        #expect(ran.map(\.exitCode) == [0, 2, nil])
        #expect(ran[0].duration == 12 && ran[1].duration == 0.5)
        #expect(!ran[0].failed && ran[1].failed && ran[2].background && !ran[2].failed)

        let summary = turns(feed)
        #expect(summary.count == 2)
        // msg_3's two lines are one message: counted once.
        #expect(summary[0].tokens == ActivityFeed.Tokens(input: 1210 + 1205 + 1305 + 1405 + 1505 + 1605, cached: 1000 + 1200 + 1300 + 1400 + 1500 + 1600,
                                                        output: 50 + 20 + 30 + 40 + 10 + 25))
        #expect(summary[0].cost == 0.5)
        #expect(summary[0].files == 2 && summary[0].commands == 2 && !summary[0].partial)
        #expect(summary[1].cost == nil && summary[1].commands == 1 && summary[1].tokens?.output == 15)
        #expect(summary[1].at == ChatReader.date("2026-10-18T09:05:00.000Z"))

        // Rows in order: the turn's files and commands as they happened, then its total.
        #expect(feed.rows.map(\.id) == ["command|toolu_bash1", "command|toolu_bash2", "file|u1|Sources/Parser.swift",
                                        "file|u1|Tests/ParserTests.swift", "turn|u1", "command|toolu_bg", "turn|u2"])
    }

    /// The recorded Claude fixtures: task tools and a plan have no files or commands, only each turn's usage.
    @Test func claudeFixturesGiveTurnTotals() throws {
        let tasks = feed(ClaudeFixtures.taskTools, .claude)
        #expect(files(tasks).isEmpty && commands(tasks).isEmpty)
        let turn = try #require(turns(tasks).first)
        #expect(turns(tasks).count == 1)
        #expect(turn.tokens == ActivityFeed.Tokens(input: 29029 + 36967 + 37369 + 37622, cached: 10719 + 29027 + 36965 + 37367,
                                                   output: 93 + 240 + 149 + 4))
        #expect(turn.cost == nil)

        // The plan is written to ~/.claude/plans: the chat shows it as a plan, and it isn't one of the project's files.
        let plan = feed(ClaudeFixtures.planFile, .claude)
        #expect(files(plan).isEmpty)
        #expect(turns(plan).first?.tokens?.output == 463 + 176)

        // Starts with the assistant (no prompt in the part read): partial when read from inside the file.
        let mid = feed("{\"partial line\n" + ClaudeFixtures.thinkingBetweenTools, .claude, startsMidFile: true)
        #expect(turns(mid).map(\.partial) == [true])
        #expect(turns(mid).first?.tokens?.output == 690 + 557 + 379)
    }

    @Test func codexRecordedRolloutHasItsCommand() throws {
        let rollout = try Zstd.decompress(CompressedRolloutTests.rollout)
        let feed = ActivityFeed.read(rollout, format: .codex, startsMidFile: false)
        let ran = commands(feed)
        #expect(ran.map(\.command) == ["echo scratch-hi"])
        #expect(ran.first?.exitCode == 0)
        #expect(ran.first?.duration == 0)      // its "Wall time: 0.0000 seconds"
        #expect(ran.first?.title == nil)
        let turn = try #require(turns(feed).first)
        #expect(turn.tokens == nil && turn.cost == nil && turn.commands == 1)
    }

    /// Codex: a patch's files with their counts, an exit code and time from `exec_command_end`, the older wrapped output,
    /// and tokens from `token_count` (the same count written twice is counted once).
    static let codex = #"""
{"timestamp":"2026-10-18T10:00:00.000Z","type":"turn_context","payload":{"cwd":"/Users/me/proj","model":"gpt-5.5-codex"}}
{"timestamp":"2026-10-18T10:00:00.100Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"rename the helper"}]}}
{"timestamp":"2026-10-18T10:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"call_p","input":"*** Begin Patch\n*** Update File: /Users/me/proj/src/a.rs\n@@\n-fn old() {}\n+fn new() {}\n+// renamed\n*** Add File: src/b.rs\n+pub fn b() {}\n*** Delete File: src/c.rs\n*** End Patch"}}
{"timestamp":"2026-10-18T10:00:01.200Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_p","output":"Success. Updated the following files:\nM src/a.rs\nA src/b.rs\nD src/c.rs"}}
{"timestamp":"2026-10-18T10:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"cargo\",\"test\"]}","call_id":"call_t"}}
{"timestamp":"2026-10-18T10:00:30.000Z","type":"event_msg","payload":{"type":"exec_command_end","call_id":"call_t","exit_code":101,"duration":{"secs":27,"nanos":500000000}}}
{"timestamp":"2026-10-18T10:00:30.100Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_t","output":"test result: FAILED"}}
{"timestamp":"2026-10-18T10:00:31.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"ls\"]}","call_id":"call_l"}}
{"timestamp":"2026-10-18T10:00:31.500Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_l","output":"{\"output\":\"a.rs\\n\",\"metadata\":{\"exit_code\":0,\"duration_seconds\":0.2}}"}}
{"timestamp":"2026-10-18T10:00:32.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":9000,"cached_input_tokens":8000,"output_tokens":300},"total_token_usage":{"input_tokens":9000,"cached_input_tokens":8000,"output_tokens":300}}}}
{"timestamp":"2026-10-18T10:00:32.100Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":9000,"cached_input_tokens":8000,"output_tokens":300},"total_token_usage":{"input_tokens":9000,"cached_input_tokens":8000,"output_tokens":300}},"rate_limits":{"primary":{"used_percent":3.0}}}}
{"timestamp":"2026-10-18T10:00:33.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":9500,"cached_input_tokens":9000,"output_tokens":120},"total_token_usage":{"input_tokens":18500,"cached_input_tokens":17000,"output_tokens":420}}}}
{"timestamp":"2026-10-18T10:00:34.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Renamed; **cargo test** fails."}]}}
"""#

    @Test func codexPatchesCommandsAndTokens() throws {
        let feed = feed(Self.codex, .codex)
        let changed = files(feed)
        #expect(changed.map(\.path) == ["src/a.rs", "src/b.rs", "src/c.rs"])
        #expect(changed.map(\.action) == [.edited, .created, .deleted])
        #expect(changed.map(\.added) == [2, 1, 0] && changed.map(\.removed) == [1, 0, 0])
        let ran = commands(feed)
        #expect(ran.map(\.command) == ["cargo test", "ls"])
        #expect(ran.map(\.exitCode) == [101, 0])
        #expect(ran.map(\.duration) == [27.5, 0.2])
        #expect(ran[0].failed && !ran[1].failed)
        let turn = try #require(turns(feed).first)
        #expect(turns(feed).count == 1)
        #expect(turn.tokens == ActivityFeed.Tokens(input: 18500, cached: 17000, output: 420))
        #expect(turn.cost == nil && turn.files == 3 && turn.commands == 2)
    }

    /// A transcript with only prompts and replies (a recorded Codex rollout of an async question): nothing to list,
    /// and the tab says so in one line.
    @Test func noneOfThoseIsAnEmptyFeed() {
        let feed = feed(AsyncQuestionTests.rolloutAsked, .codex)
        #expect(feed.isEmpty)
        #expect(!ActivityFeed.emptyExplanation.contains("\n") && !ActivityFeed.emptyExplanation.isEmpty)
        #expect(self.feed("", .claude).isEmpty)
    }

    @Test func aResultWhoseCallWasBeforeTheTailAddsNothing() {
        let lines = Self.claude.split(separator: "\n").map(String.init)
        // From the failed lint's result on: its call isn't in the part read.
        let feed = feed(lines[4...].joined(separator: "\n"), .claude)
        #expect(!commands(feed).contains { $0.id == "toolu_bash2" })
        #expect(commands(feed).map(\.id) == ["toolu_bg"])
    }

    @Test func keepsTheNewest() {
        let feed = feed(Self.claude, .claude, limit: 2)
        #expect(feed.rows.map(\.id) == ["command|toolu_bg", "turn|u2"])
    }

    @Test func plainTextHasNoMarkdown() {
        #expect(ActivityFeed.plain("Run **the** `Parser` tests") == "Run the Parser tests")
        #expect(ActivityFeed.plain("## See [the docs](https://example.com) and _this_") == "See the docs and this")
        #expect(ActivityFeed.plain("- one\ntwo") == "one two")
        #expect(ActivityFeed.plain("Edit App.swift") == "Edit App.swift")
    }
}
