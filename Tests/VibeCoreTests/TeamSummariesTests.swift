import Foundation
import Testing
@testable import VibeCore

/// The Team view's plain-language lines: when one is asked for, what's shown meanwhile, and the headless Claude run.
struct TeamSummariesTests {
    @Test func theCacheAsksOnceThenOnlyForChangedInputEveryThreeMinutes() {
        var cache = SummaryCache()
        #expect(cache.isDue("a", fingerprint: "1", now: 0))
        cache.begin("a", fingerprint: "1", now: 0)
        // Running: never a second request, whatever changed.
        #expect(!cache.isDue("a", fingerprint: "2", now: 500))
        #expect(cache.line("a") == nil)
        cache.end("a", text: "Fixing the parser")
        #expect(cache.line("a") == "Fixing the parser")
        // Same input: never again; changed input: only once three minutes have passed since the last request.
        #expect(!cache.isDue("a", fingerprint: "1", now: 10_000))
        #expect(!cache.isDue("a", fingerprint: "2", now: 179))
        #expect(cache.isDue("a", fingerprint: "2", now: 180))
        // Other keys have their own clock.
        #expect(cache.isDue("b", fingerprint: "1", now: 1))
    }

    @Test func aFailedRequestShowsTheFallbackUntilOneSucceeds() {
        var cache = SummaryCache()
        cache.begin("a", fingerprint: "1", now: 0)
        cache.end("a", text: "Fixing the parser")
        cache.begin("a", fingerprint: "2", now: 200)
        // While the new one is written, the last one stands.
        #expect(cache.line("a") == "Fixing the parser")
        cache.end("a", text: nil)
        #expect(cache.line("a") == nil)
        cache.begin("a", fingerprint: "3", now: 400)
        cache.end("a", text: "Testing the parser")
        #expect(cache.line("a") == "Testing the parser")
    }

    final class Calls: @unchecked Sendable {
        var prompts: [String] = []
        var answer: String? = "Making the masker fast"
        var now: Double = 0
        var delivered = 0
    }

    @Test func theSummarizerRunsOffTheCallerAndSaysWhenALineArrives() {
        let calls = Calls()
        var queued: [@Sendable () -> Void] = []
        let summarizer = Summarizer(generate: { prompt in calls.prompts.append(prompt); return calls.answer }, now: { calls.now },
                                    run: { queued.append($0) }, deliver: { $0() })
        summarizer.changed = { calls.delivered += 1 }
        #expect(summarizer.line("t", fingerprint: "1", prompt: { "p1" }) == nil)
        // Not written yet: it runs where `run` puts it, not in the call.
        #expect(calls.prompts.isEmpty)
        #expect(summarizer.line("t", fingerprint: "1", prompt: { "p1" }) == nil)
        #expect(queued.count == 1)
        queued.removeFirst()()
        #expect(calls.prompts == ["p1"])
        #expect(calls.delivered == 1)
        #expect(summarizer.cached("t") == "Making the masker fast")
        // Changed input within three minutes: the cached line, no request.
        calls.now = 100
        #expect(summarizer.line("t", fingerprint: "2", prompt: { "p2" }) == "Making the masker fast")
        #expect(queued.isEmpty)
        calls.now = 181
        calls.answer = nil
        summarizer.line("t", fingerprint: "2", prompt: { "p2" })
        queued.removeFirst()()
        #expect(calls.prompts == ["p1", "p2"])
        #expect(summarizer.cached("t") == nil)
    }

    @Test func aPromptThatCantBeBuiltIsAFailureNotACall() {
        let calls = Calls()
        let summarizer = Summarizer(generate: { calls.prompts.append($0); return "x" }, run: { $0() }, deliver: { $0() })
        summarizer.line("t", fingerprint: "1", prompt: { nil })
        #expect(calls.prompts.isEmpty)
        #expect(summarizer.cached("t") == nil)
    }

    @Test func theModelsAnswerBecomesOneShortLine() {
        #expect(Summarizer.clean("\n  \"Fixing the login bug\"  \nmore") == "Fixing the login bug")
        #expect(Summarizer.clean("   \n") == nil)
        let long = Summarizer.clean(String(repeating: "word ", count: 40))
        #expect(long.map { $0.count <= Summarizer.limit } == true)
        #expect(long?.hasSuffix("…") == true)
        #expect(Summarizer.clip("short", 90) == "short")
    }

    @Test func thePromptsCarryTheTaskCheckpointsAndSteps() {
        let steps = [TranscriptEntry(kind: .tool, id: "1", text: "Run the tests", tool: "Bash"),
                     TranscriptEntry(kind: .reply, id: "2", text: "The 40 KB case\nnow takes 3 ms")]
        let prompt = SummaryPrompts.task(title: "Fast masker", role: "software agent",
                                         checkpoints: (1...5).map { LeadCheckpoint(text: "cp\($0)", at: 0) }, steps: steps)
        #expect(prompt.contains("Task: Fast masker"))
        #expect(prompt.contains("- cp5") && prompt.contains("- cp3") && !prompt.contains("- cp2"))
        #expect(prompt.contains("- Bash: Run the tests"))
        #expect(prompt.contains("- Said: The 40 KB case now takes 3 ms"))
        #expect(SummaryPrompts.decision("Use all slots", why: "Idle slots").contains("Why: Idle slots"))
    }

    @Test func aTranscriptsStepsAndFingerprint() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("t.jsonl").path
        let line = #"{"type":"assistant","uuid":"u1","timestamp":"2026-10-17T18:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Checking the 1 MB case"}]}}"#
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        #expect(SummaryPrompts.steps(transcript: path).map(\.text) == ["Checking the 1 MB case"])
        let before = try #require(SummaryPrompts.fingerprint(transcript: path))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line.replacingOccurrences(of: "u1", with: "u2") + "\n").utf8))
        try handle.close()
        #expect(SummaryPrompts.fingerprint(transcript: path) != before)
        #expect(SummaryPrompts.fingerprint(transcript: folder.appendingPathComponent("none").path) == nil)
    }

    @Test func headlessClaudeIsASmallModelWithNoToolsSettingsOrSession() {
        let command = ClaudeHeadless.command(prompt: "the prompt")
        #expect(command.executable == "/bin/zsh")
        let args = command.args
        #expect(args.starts(with: ["-lc", "exec claude \"$@\"", "zsh", "-p"]))
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(value("--model") == "haiku")
        #expect(value("--tools") == "")
        #expect(value("--setting-sources") == "")
        #expect(args.contains("--no-session-persistence") && args.contains("--strict-mcp-config"))
        #expect(args.last == "the prompt")
        #expect(ClaudeHeadless.timeout == 30)
    }

    @Test func aSlowOrFailingRunGivesNothingInTime() {
        // Late: it would answer after twice the hang guard. Given up on, it returns long before that.
        let start = Date()
        #expect(ClaudeHeadless.run(executable: "/bin/sh", args: ["-c", "sleep \(Int(2 * hangGuard)); echo late"], timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(start) < hangGuard)
        // These end by themselves: the timeout is only a hang guard.
        #expect(ClaudeHeadless.run(executable: "/bin/sh", args: ["-c", "echo nope; exit 1"], timeout: hangGuard) == nil)
        #expect(ClaudeHeadless.run(executable: "/bin/sh", args: ["-c", "echo Fixing the parser"], timeout: hangGuard) == "Fixing the parser")
        #expect(ClaudeHeadless.run(executable: "/nonexistent/claude", args: [], timeout: hangGuard) == nil)
    }

    /// One real `claude -p` call on made-up text, only with `TEAM_SUMMARY_LIVE=1 swift test --filter TeamSummariesTests`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEAM_SUMMARY_LIVE"] != nil)) func aRealSummaryIsOneShortLine() throws {
        let prompt = SummaryPrompts.task(title: "Make the credential masker fast on huge inputs", role: "software agent",
                                         checkpoints: [LeadCheckpoint(text: "Rules rewritten without backtracking", at: 0)],
                                         steps: [TranscriptEntry(kind: .tool, id: "1", text: "swift test --filter Redaction", tool: "Bash"),
                                                 TranscriptEntry(kind: .reply, id: "2", text: "The 40 KB case now takes 3 ms; checking the 1 MB case")])
        let line = try #require(ClaudeHeadless.summarize(prompt).flatMap(Summarizer.clean))
        print("summary: \(line)")
        #expect(line.count <= Summarizer.limit && !line.contains("\n"))
    }

    // MARK: Decisions

    @Test func decisionsReadFromTheirFileOldAndNewStamps() throws {
        let markdown = """
            # Decisions

            ## 2026-10-17 19:41 Order for the planned tasks

            Shared files would conflict.
            Second line.

            ## 2026-10-17 21:27:05 Use all 5 worker slots

            Idle slots cost hours.

            """
        let decisions = LeadDecision.parse(markdown)
        #expect(decisions.map(\.text) == ["Order for the planned tasks", "Use all 5 worker slots"])
        #expect(decisions.map(\.why) == ["Shared files would conflict.\nSecond line.", "Idle slots cost hours."])
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 17; parts.hour = 21; parts.minute = 27; parts.second = 5
        #expect(decisions[1].at == Calendar.current.date(from: parts)?.timeIntervalSince1970)
        #expect(decisions[1].at - decisions[0].at == 106 * 60 + 5)
    }

    @Test func aRecordedDecisionReadsBackToTheSecond() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = BoardStore(root: root)
        #expect(store.decisions().isEmpty)
        let before = Date().timeIntervalSince1970.rounded(.down)
        try store.appendDecision("Run overlapping tasks\nin parallel", why: "Idle slots cost more than a rework round.")
        let decisions = store.decisions()
        #expect(decisions.count == 1)
        #expect(decisions.first?.text == "Run overlapping tasks in parallel")
        #expect(decisions.first?.why == "Idle slots cost more than a rework round.")
        let at = try #require(decisions.first?.at)
        #expect(at >= before && at <= Date().timeIntervalSince1970)
    }
}
