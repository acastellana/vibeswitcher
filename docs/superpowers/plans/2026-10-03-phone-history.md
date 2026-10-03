# Phone full history (part A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone's session view gets two tabs:
- **Terminal:** the live screen, plus the tab's whole scrollback, loaded as you scroll up.
- **Conversation:** a clean timeline read from the agent's transcript file.

**Architecture:**
- **Pure units in VibeCore:**
  - `HookState.transcriptPath`, captured from hook payloads;
  - `Scrollback`: overlap removal, cap and paging;
  - `TranscriptReader`: Claude Code and Codex JSONL to typed entries, path checks and tail reading.
- **App target:** `TerminalBridge.history(tty:)` and three Phone Access routes, `/api/history`,
  `/api/conversation` and `/api/conversation/tool`.
- **Phone:** the web app gets the two tabs.

**Tech Stack:** Swift 6 toolchain (Swift 5 mode), Swift Testing, AppleScript via `osascript`, plain JS/CSS.
No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-03-history-briefings-decisions-design.md`, section "A. Full history".

## Global Constraints

- **Platform and dependencies:** macOS 14+, Swift 5 language mode, no third-party packages.
- **Tests:** Swift Testing. **Never put a mutating call inside `#expect`/`#require`**: assign to a local first.
- **Masking:** every text sent to the phone goes through `Redaction.secrets(in:)`.
- **Scrollback:** at most the last **5,000** lines are reachable, in pages of up to **500**.
- **Conversation:**
  - The first load reads at most the last **2 MB** of the transcript.
  - Tool output preview is **4 KB**. "Show all" returns up to **64 KB**.
- **Transcript files:** used only if the path resolves, symlinks included, to a regular `.jsonl` file under
  `~/.claude/projects/` (Claude) or `~/.codex/sessions/` (Codex).
- **Access:** the new routes use the existing device-token auth. They're read-only and don't need **Allow
  replies**.
- **Test safety:**
  - Never type into or move the user's real sessions or windows. Reading a tab's text is read-only and
    allowed.
  - Integration checks use a scratch Claude session in a scratch folder and a temporary paired device,
    both removed afterwards.
  - Never print the Tailscale login or host into chat or commits.
- **Commits:** one per task, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Don't push.

## Review Focus

1. **A transcript path pointing outside the agent folders**, via a symlink or `..` (a hostile or corrupted
   hook payload): it must be refused, never read. Pinned in Task 3, `transcriptPathsMustStayInTheAgentFolders`.
2. **A transcript line cut in half by the reader**, when the agent is mid-write or the tail starts
   mid-line: no crash, no garbage entry, and it's re-read on the next poll. Pinned in Task 3,
   `incompleteLinesWaitForTheNextRead`.
3. **The terminal cleared or reset** (`clear`, scrollback reset), so the history is shorter than the phone
   thinks: the phone starts over rather than showing wrong lines. Pinned in Task 2,
   `pagesNeverGoPastWhatExists`, and the JS reset in Task 5.
4. **Huge single lines** (minified output, base64 images in tool results): previews stay bounded and the
   phone stays responsive. Pinned in Task 3, `toolOutputIsTruncatedAndImagesAreSummarized`.
5. **Secrets in transcripts** (tokens in commands, env dumps in tool output): masked in every entry kind.
   Pinned in Task 3, `everythingIsMasked`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/VibeCore/HookState.swift` (modify) | New `transcriptPath` field, set from `transcript_path` |
| `Sources/VibeCore/Scrollback.swift` (new) | Scrollback lines above the screen; paging by absolute line number |
| `Sources/VibeCore/TranscriptReader.swift` (new) | Path check, tail reading, Claude/Codex JSONL to `TranscriptEntry` |
| `Tests/VibeCoreTests/HistoryTests.swift` (new) | Tests for the three units above |
| `Sources/VibeSwitcher/TerminalBridge.swift` (modify) | `history(tty:)` returns `(history, screen)` in one AppleScript call |
| `Sources/VibeSwitcher/PhoneAccess.swift` (modify) | `/api/history`, `/api/conversation`, `/api/conversation/tool`; state rows gain `hasTranscript`, `eventAt` |
| `Web/index.html`, `Web/app.js`, `Web/style.css` (modify) | Tabs, scrollback prepend, conversation timeline |
| `README.md` (modify) | Phone section: Terminal and Conversation tabs |

---

### Task 1: Record the transcript path

**Files:**
- Modify: `Sources/VibeCore/HookState.swift`, adding the field after `request` and setting it after the
  `cwd` line in `reduce`.
- Test: `Tests/VibeCoreTests/HistoryTests.swift` (create).

**Interfaces:**
- Produces: `HookState.transcriptPath: String?`.

- [ ] **Step 1: Failing test.** Create `Tests/VibeCoreTests/HistoryTests.swift`:

```swift
import Foundation
import Testing
@testable import VibeCore

struct TranscriptPathCaptureTests {
    func reduce(_ payload: [String: Any], onto state: HookState? = nil) -> HookState? {
        let update = HookState.reduce(current: state, payload: payload, agent: .claude, tty: "ttys001", agentPid: 42, now: 1000)
        if case .write(let next) = update { return next }
        return state
    }

    @Test func hooksRecordWhereTheTranscriptIs() throws {
        let path = "/Users/me/.claude/projects/-Users-me-app/s1.jsonl"
        let started = try #require(reduce(["hook_event_name": "SessionStart", "session_id": "s1", "transcript_path": path]))
        #expect(started.transcriptPath == path)
        // Events without the field keep it; absurd values are ignored.
        let prompted = try #require(reduce(["hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": "hi"], onto: started))
        #expect(prompted.transcriptPath == path)
        let junk = try #require(reduce(["hook_event_name": "Stop", "session_id": "s1",
                                        "transcript_path": String(repeating: "x", count: 5000)], onto: prompted))
        #expect(junk.transcriptPath == path)
    }
}
```

- [ ] **Step 2: Run it.** `swift test --filter TranscriptPathCaptureTests 2>&1 | grep -E "error:|passed|failed" | head -3`
Expected: `value of type 'HookState' has no member 'transcriptPath'`.

- [ ] **Step 3: Implement.** In `HookState`, after `public var request: String?`:

```swift
    /// The agent's own transcript of this session (Claude Code and Codex pass it to every hook).
    /// Not trusted as-is: `TranscriptReader.checkedURL` validates it before anything reads it.
    public var transcriptPath: String?
```

In `reduce`, right after `if let cwd = payload["cwd"] …`:

```swift
        if let path = payload["transcript_path"] as? String, !path.isEmpty, path.utf8.count <= 1024 {
            state.transcriptPath = path
        }
```

- [ ] **Step 4: Run it.** Same command. Expected: `1 test passed`. Then `swift test 2>&1 | tail -1`: all pass.

- [ ] **Step 5: Commit.**
```bash
git add Sources/VibeCore/HookState.swift Tests/VibeCoreTests/HistoryTests.swift
git commit -m "Hooks: remember the session's transcript path

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Scrollback paging (`Scrollback`)

**Files:**
- Create: `Sources/VibeCore/Scrollback.swift`
- Test: `Tests/VibeCoreTests/HistoryTests.swift` (append)

**Interfaces:**
- Produces:
  - `Scrollback.maxLines` (5000), `Scrollback.pageLimit` (500);
  - `Scrollback.lines(history:screen:) -> [String]`;
  - `Scrollback.Page { lines: [String]; start: Int; total: Int; first: Int }`;
  - `Scrollback.page(_ lines: [String], before: Int?, limit: Int) -> Page`.
  - Line numbers are absolute, counted from the top of Terminal's history. `first` is the oldest line
    still reachable.

- [ ] **Step 1: Failing tests** (append):

```swift
struct ScrollbackTests {
    @Test func dropsTheVisibleScreenFromTheEnd() {
        #expect(Scrollback.lines(history: "a\nb\nc\nd\n", screen: "c\nd\n") == ["a", "b"])
        #expect(Scrollback.lines(history: "a\nb\nc  \nd   \n\n", screen: "c\nd") == ["a", "b"])
        // No overlap (e.g. the screen just redrew): keep everything rather than guess.
        #expect(Scrollback.lines(history: "a\nb", screen: "zzz") == ["a", "b"])
        #expect(Scrollback.lines(history: "", screen: "x") == [])
    }

    @Test func pagesBackwardsByAbsoluteLineNumber() {
        let lines = (0..<1200).map(String.init)
        let last = Scrollback.page(lines, before: nil, limit: 500)
        #expect(last == Scrollback.Page(lines: Array(lines[700..<1200]), start: 700, total: 1200, first: 0))
        let earlier = Scrollback.page(lines, before: 700, limit: 500)
        #expect(earlier.start == 200)
        #expect(earlier.lines.first == "200")
        let oldest = Scrollback.page(lines, before: 200, limit: 500)
        #expect(oldest.start == 0)
        #expect(oldest.lines.count == 200)
        #expect(Scrollback.page(lines, before: 1200, limit: 9999).lines.count == Scrollback.pageLimit)
    }

    @Test func pagesNeverGoPastWhatExists() {
        let lines = (0..<6000).map(String.init)
        let capped = Scrollback.page(lines, before: 1500, limit: 500)
        #expect(capped.first == 1000)                // only the last 5,000 lines are reachable
        #expect(capped.start == 1000)
        #expect(capped.lines.count == 500)
        #expect(Scrollback.page(lines, before: 900, limit: 500).lines.isEmpty)
        // After `clear`, the phone may ask past the (now shorter) end.
        let shrunk = Scrollback.page(["x", "y"], before: 700, limit: 500)
        #expect(shrunk == Scrollback.Page(lines: ["x", "y"], start: 0, total: 2, first: 0))
        #expect(Scrollback.page(["x"], before: -5, limit: 500).lines.isEmpty)
    }
}
```

- [ ] **Step 2: Run it.** `swift test --filter ScrollbackTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'Scrollback' in scope`.

- [ ] **Step 3: Implement** `Sources/VibeCore/Scrollback.swift`:

```swift
import Foundation

/// A Terminal tab's scrollback for the phone: everything above the visible screen (which the phone
/// already shows live), addressed by absolute line number from the top of Terminal's history, so pages
/// stay put while new output arrives below them.
public enum Scrollback {
    public static let maxLines = 5000
    public static let pageLimit = 500

    public struct Page: Equatable, Sendable {
        public var lines: [String]
        /// Absolute number of `lines[0]`.
        public var start: Int
        /// Lines above the screen in total.
        public var total: Int
        /// Oldest line still reachable (`total - maxLines`, at least 0).
        public var first: Int

        public init(lines: [String], start: Int, total: Int, first: Int) {
            self.lines = lines
            self.start = start
            self.total = total
            self.first = first
        }
    }

    /// `history` minus the visible `screen` at its end (Terminal's history includes the screen).
    /// Trailing spaces and blank lines are ignored when matching; with no overlap nothing is removed.
    public static func lines(history: String, screen: String) -> [String] {
        var all = history.components(separatedBy: "\n").map { trimmedEnd($0) }
        while let last = all.last, last.isEmpty { all.removeLast() }
        var tail = screen.components(separatedBy: "\n").map { trimmedEnd($0) }
        while let last = tail.last, last.isEmpty { tail.removeLast() }
        if !tail.isEmpty, all.count >= tail.count, Array(all.suffix(tail.count)) == tail {
            all.removeLast(tail.count)
        }
        return all
    }

    public static func page(_ lines: [String], before: Int?, limit: Int) -> Page {
        let total = lines.count
        let first = max(0, total - maxLines)
        let end = min(before ?? total, total)
        let start = max(first, end - min(max(limit, 0), pageLimit))
        guard end > start else { return Page(lines: [], start: max(first, min(end, total)), total: total, first: first) }
        return Page(lines: Array(lines[start..<end]), start: start, total: total, first: first)
    }

    private static func trimmedEnd(_ line: String) -> String {
        var line = Substring(line)
        while let last = line.last, last == " " || last == "\t" || last == "\r" { line.removeLast() }
        return String(line)
    }
}
```

- [ ] **Step 4: Run it.** `swift test --filter ScrollbackTests 2>&1 | grep -E "error:|✘|passed|failed" | head -6`
Expected: 3 tests pass.

- [ ] **Step 5: Commit.**
```bash
git add Sources/VibeCore/Scrollback.swift Tests/VibeCoreTests/HistoryTests.swift
git commit -m "History: scrollback above the screen, paged by absolute line

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Transcripts to timeline entries (`TranscriptReader`)

**Files:**
- Create: `Sources/VibeCore/TranscriptReader.swift`
- Test: `Tests/VibeCoreTests/HistoryTests.swift` (append)

**Interfaces:**
- Consumes: `ToolActivity.describe(toolName:input:)`, `Redaction.secrets(in:)`.
- Produces:
  - **`TranscriptEntry`** (`Equatable, Sendable`):
    - `kind: Kind`, where `Kind` is one of `prompt`, `reply`, `tool`, `toolResult`;
    - `id: String`, `text: String`, `tool: String?`, `output: String?`, `outputTruncated: Bool`,
      `failed: Bool`, `at: Double?`, `duration: Double?`;
    - `json: [String: Any]` for the API.
  - **`TranscriptReader`:**
    - `enum Format { claude, codex }`;
    - `checkedURL(_ path: String, home: String) -> (URL, Format)?`;
    - `tailStart(_ data: Data) -> Int`: where the first complete line begins;
    - `read(_ data: Data, format: Format, outputLimit: Int = 4096) -> (entries: [TranscriptEntry], consumed: Int)`.

- [ ] **Step 1: Failing tests** (append):

```swift
struct TranscriptReaderTests {
    func jsonl(_ objects: [[String: Any]]) -> Data {
        Data(objects.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n" }.joined().utf8)
    }

    let claudeLines: [[String: Any]] = [
        ["type": "user", "uuid": "u1", "timestamp": "2026-10-03T10:00:00.000Z", "message": ["role": "user", "content": "Fix the login bug"]],
        ["type": "user", "uuid": "u2", "timestamp": "2026-10-03T10:00:00.500Z", "isMeta": true, "message": ["role": "user", "content": "<local-command-caveat>x</local-command-caveat>"]],
        ["type": "user", "uuid": "u3", "timestamp": "2026-10-03T10:00:00.600Z", "message": ["role": "user", "content": "<task-notification>done</task-notification>"]],
        ["type": "assistant", "uuid": "a1", "timestamp": "2026-10-03T10:00:02.000Z", "message": ["role": "assistant", "content": [
            ["type": "thinking", "thinking": "secret plan"],
            ["type": "text", "text": "Looking at auth.ts first."],
            ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "npm test", "description": "Run unit tests"]],
        ]]],
        ["type": "user", "uuid": "u4", "timestamp": "2026-10-03T10:00:42.000Z", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "toolu_1", "content": "2 failed", "is_error": true],
        ]]],
        ["type": "assistant", "uuid": "a2", "isSidechain": true, "timestamp": "2026-10-03T10:00:43.000Z", "message": ["role": "assistant", "content": [["type": "text", "text": "subagent chatter"]]]],
        ["type": "system", "uuid": "s1", "timestamp": "2026-10-03T10:00:44.000Z", "content": "compacted"],
    ]

    @Test func readsClaudeTranscripts() {
        let result = TranscriptReader.read(jsonl(claudeLines), format: .claude)
        #expect(result.entries.map(\.kind) == [.prompt, .reply, .tool])
        #expect(result.entries[0].text == "Fix the login bug")
        #expect(result.entries[1].text == "Looking at auth.ts first.")
        let tool = result.entries[2]
        #expect(tool.id == "toolu_1")
        #expect(tool.tool == "Bash")
        #expect(tool.text == "Run unit tests")
        #expect(tool.output == "2 failed")
        #expect(tool.failed)
        #expect(tool.duration == 40)
        #expect(result.consumed == jsonl(claudeLines).count)
    }

    @Test func toolResultsArrivingLaterAreSeparateEntries() {
        let first = TranscriptReader.read(jsonl(Array(claudeLines[0...3])), format: .claude)
        #expect(first.entries.last?.kind == .tool)
        #expect(first.entries.last?.output == nil)
        let later = TranscriptReader.read(jsonl([claudeLines[4]]), format: .claude)
        #expect(later.entries.map(\.kind) == [.toolResult])
        #expect(later.entries[0].id == "toolu_1")
        #expect(later.entries[0].failed)
    }

    @Test func readsCodexTranscripts() {
        let lines: [[String: Any]] = [
            ["timestamp": "2026-10-03T10:00:00.000Z", "type": "session_meta", "payload": ["id": "x", "cwd": "/tmp"]],
            ["timestamp": "2026-10-03T10:00:00.100Z", "type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>x</environment_context>"]]]],
            ["timestamp": "2026-10-03T10:00:01.000Z", "type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "delete it"]]]],
            ["timestamp": "2026-10-03T10:00:02.000Z", "type": "response_item", "payload": ["type": "function_call", "name": "shell", "call_id": "c1", "arguments": "{\"command\":[\"rm\",\"old.ts\"]}"]],
            ["timestamp": "2026-10-03T10:00:03.000Z", "type": "response_item", "payload": ["type": "function_call_output", "call_id": "c1", "output": "ok"]],
            ["timestamp": "2026-10-03T10:00:04.000Z", "type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Removed it."]]]],
            ["timestamp": "2026-10-03T10:00:05.000Z", "type": "response_item", "payload": ["type": "reasoning", "summary": []]],
        ]
        let result = TranscriptReader.read(jsonl(lines), format: .codex)
        #expect(result.entries.map(\.kind) == [.prompt, .tool, .reply])
        #expect(result.entries[0].text == "delete it")
        #expect(result.entries[1].text == "rm old.ts")
        #expect(result.entries[1].output == "ok")
        #expect(result.entries[1].duration == 1)
        #expect(result.entries[2].text == "Removed it.")
    }

    @Test func incompleteLinesWaitForTheNextRead() {
        let full = jsonl(Array(claudeLines[0...1]))
        let cut = full + Data("{\"type\":\"user\",\"mess".utf8)
        let result = TranscriptReader.read(cut, format: .claude)
        #expect(result.entries.count == 1)
        #expect(result.consumed == full.count)
        let garbage = TranscriptReader.read(Data("not json\n".utf8) + full, format: .claude)
        #expect(garbage.entries.count == 1)
        // A tail read that starts mid-line skips to the first full line.
        let tail = Data("partial line}\n".utf8) + full
        #expect(TranscriptReader.tailStart(tail) == 14)
        #expect(TranscriptReader.tailStart(Data("no newline".utf8)) == 10)
    }

    @Test func toolOutputIsTruncatedAndImagesAreSummarized() {
        let long = String(repeating: "x", count: 10_000)
        let lines: [[String: Any]] = [
            ["type": "assistant", "uuid": "a", "message": ["content": [["type": "tool_use", "id": "t", "name": "Read", "input": ["file_path": "/a/b.png"]]]]],
            ["type": "user", "uuid": "u", "message": ["content": [["type": "tool_result", "tool_use_id": "t", "content": [
                ["type": "text", "text": long], ["type": "image", "source": ["type": "base64", "data": "AAAA"]],
            ]]]]],
        ]
        let result = TranscriptReader.read(jsonl(lines), format: .claude, outputLimit: 4096)
        let tool = result.entries[0]
        #expect(tool.output?.utf8.count ?? 0 <= 4096 + 40)
        #expect(tool.outputTruncated)
        #expect(!(tool.output ?? "").contains("AAAA"))
    }

    @Test func everythingIsMasked() {
        let token = "ghp_" + String(repeating: "a", count: 36)
        let lines: [[String: Any]] = [
            ["type": "user", "uuid": "u", "message": ["content": "use \(token) please"]],
            ["type": "assistant", "uuid": "a", "message": ["content": [
                ["type": "text", "text": "Using \(token)"],
                ["type": "tool_use", "id": "t", "name": "Bash", "input": ["command": "curl -H 'Authorization: Bearer \(token)' x"]],
            ]]],
            ["type": "user", "uuid": "r", "message": ["content": [["type": "tool_result", "tool_use_id": "t", "content": "token=\(token)"]]]],
        ]
        let result = TranscriptReader.read(jsonl(lines), format: .claude)
        for entry in result.entries {
            #expect(!entry.text.contains(token))
            #expect(!(entry.output ?? "").contains(token))
        }
    }

    @Test func transcriptPathsMustStayInTheAgentFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vs-home-\(UUID().uuidString)")
        let projects = home.appendingPathComponent(".claude/projects/p")
        let sessions = home.appendingPathComponent(".codex/sessions/2026/10/03")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let good = projects.appendingPathComponent("s.jsonl")
        try Data("{}\n".utf8).write(to: good)
        let codex = sessions.appendingPathComponent("rollout-x.jsonl")
        try Data("{}\n".utf8).write(to: codex)
        let outside = home.appendingPathComponent("secret.jsonl")
        try Data("{}\n".utf8).write(to: outside)
        let link = projects.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(TranscriptReader.checkedURL(good.path, home: home.path)?.1 == .claude)
        #expect(TranscriptReader.checkedURL(codex.path, home: home.path)?.1 == .codex)
        #expect(TranscriptReader.checkedURL(outside.path, home: home.path) == nil)
        #expect(TranscriptReader.checkedURL(link.path, home: home.path) == nil)
        #expect(TranscriptReader.checkedURL(projects.path + "/../../../secret.jsonl", home: home.path) == nil)
        #expect(TranscriptReader.checkedURL(projects.path, home: home.path) == nil)          // a directory
        #expect(TranscriptReader.checkedURL(projects.appendingPathComponent("none.jsonl").path, home: home.path) == nil)
    }
}
```

- [ ] **Step 2: Run them.** `swift test --filter TranscriptReaderTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'TranscriptReader' in scope`.

- [ ] **Step 3: Implement** `Sources/VibeCore/TranscriptReader.swift`:

```swift
import Foundation

/// One row of the phone's Conversation tab.
public struct TranscriptEntry: Equatable, Sendable {
    public enum Kind: String, Sendable { case prompt, reply, tool, toolResult }

    public var kind: Kind
    /// The tool call id for `tool`/`toolResult` (a later result updates the row with that id).
    public var id: String
    /// Prompt or reply text; for a tool, its one-line description.
    public var text: String
    public var tool: String?
    public var output: String?
    public var outputTruncated = false
    public var failed = false
    public var at: Double?
    public var duration: Double?

    public var json: [String: Any] {
        var object: [String: Any] = ["kind": kind.rawValue, "id": id, "text": text]
        if let tool { object["tool"] = tool }
        if let output { object["output"] = output }
        if outputTruncated { object["outputTruncated"] = true }
        if failed { object["failed"] = true }
        if let at { object["at"] = at }
        if let duration { object["duration"] = duration }
        return object
    }
}

/// Reads Claude Code (`~/.claude/projects/…/<session>.jsonl`) and Codex (`~/.codex/sessions/…/rollout-*.jsonl`)
/// transcripts into timeline entries. Thinking, meta lines, sidechains and system lines are skipped.
/// Everything is masked.
public enum TranscriptReader {
    public enum Format: Sendable { case claude, codex }

    /// The transcript file, if `path` really is a `.jsonl` file inside the agents' own folders (after
    /// resolving symlinks and `..`), and which format it is.
    public static func checkedURL(_ path: String, home: String) -> (URL, Format)? {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let homeURL = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.pathExtension == "jsonl" else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        let roots: [(String, Format)] = [(".claude/projects/", .claude), (".codex/sessions/", .codex)]
        for (folder, format) in roots where resolved.path.hasPrefix(homeURL.path + "/" + folder) {
            return (resolved, format)
        }
        return nil
    }

    /// For a read that starts in the middle of a file: the offset of the first complete line.
    public static func tailStart(_ data: Data) -> Int {
        guard let newline = data.firstIndex(of: 0x0A) else { return data.count }
        return newline - data.startIndex + 1
    }

    /// Entries from the complete lines in `data` (which starts at a line boundary), and how many bytes
    /// those lines took: a trailing partial line is left for the next read.
    public static func read(_ data: Data, format: Format, outputLimit: Int = 4096) -> (entries: [TranscriptEntry], consumed: Int) {
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], 0) }
        let consumed = lastNewline - data.startIndex + 1
        var entries: [TranscriptEntry] = []
        var toolIndex: [String: Int] = [:]
        for line in data[data.startIndex..<lastNewline].split(separator: 0x0A) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let parsed = format == .claude ? claude(object, outputLimit: outputLimit) : codex(object, outputLimit: outputLimit)
            for entry in parsed {
                // A result for a call in this same read completes that row.
                if entry.kind == .toolResult, let index = toolIndex[entry.id] {
                    entries[index].output = entry.output
                    entries[index].outputTruncated = entry.outputTruncated
                    entries[index].failed = entry.failed
                    if let start = entries[index].at, let end = entry.at { entries[index].duration = max(0, end - start) }
                    continue
                }
                if entry.kind == .tool { toolIndex[entry.id] = entries.count }
                entries.append(entry)
            }
        }
        return (entries, consumed)
    }

    // MARK: Claude Code

    private static func claude(_ line: [String: Any], outputLimit: Int) -> [TranscriptEntry] {
        if line["isSidechain"] as? Bool == true || line["isMeta"] as? Bool == true { return [] }
        let type = line["type"] as? String
        guard type == "user" || type == "assistant", let message = line["message"] as? [String: Any] else { return [] }
        let at = time(line["timestamp"])
        let uuid = line["uuid"] as? String ?? UUID().uuidString
        if let text = message["content"] as? String {
            guard type == "user", let prompt = humanText(text) else { return [] }
            return [TranscriptEntry(kind: .prompt, id: uuid, text: prompt, at: at)]
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var entries: [TranscriptEntry] = []
        for (index, block) in blocks.enumerated() {
            switch (type, block["type"] as? String) {
            case ("user", "text"):
                if let text = (block["text"] as? String).flatMap(humanText) {
                    entries.append(TranscriptEntry(kind: .prompt, id: "\(uuid).\(index)", text: text, at: at))
                }
            case ("assistant", "text"):
                if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    entries.append(TranscriptEntry(kind: .reply, id: "\(uuid).\(index)", text: Redaction.secrets(in: text), at: at))
                }
            case ("assistant", "tool_use"):
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                entries.append(TranscriptEntry(kind: .tool, id: block["id"] as? String ?? "\(uuid).\(index)",
                                               text: ToolActivity.describe(toolName: name, input: input), tool: name, at: at))
            case ("user", "tool_result"):
                let (output, truncated) = clipped(resultText(block["content"]), limit: outputLimit)
                entries.append(TranscriptEntry(kind: .toolResult, id: block["tool_use_id"] as? String ?? "", text: "",
                                               output: output, outputTruncated: truncated,
                                               failed: block["is_error"] as? Bool == true, at: at))
            default:
                break
            }
        }
        return entries
    }

    // MARK: Codex

    private static func codex(_ line: [String: Any], outputLimit: Int) -> [TranscriptEntry] {
        guard line["type"] as? String == "response_item", let payload = line["payload"] as? [String: Any] else { return [] }
        let at = time(line["timestamp"])
        let id = payload["id"] as? String ?? payload["call_id"] as? String ?? UUID().uuidString
        switch payload["type"] as? String {
        case "message":
            let parts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            let text = parts.joined(separator: "\n")
            switch payload["role"] as? String {
            case "user": return humanText(text).map { [TranscriptEntry(kind: .prompt, id: id, text: $0, at: at)] } ?? []
            case "assistant":
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
                return [TranscriptEntry(kind: .reply, id: id, text: Redaction.secrets(in: text), at: at)]
            default: return []
            }
        case "function_call", "custom_tool_call", "local_shell_call":
            let name = payload["name"] as? String ?? "shell"
            var input: [String: Any] = [:]
            if let arguments = payload["arguments"] as? String,
               let parsed = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] {
                input = parsed
            } else if let raw = payload["input"] as? String {
                input = ["command": raw]
            }
            let described = ToolActivity.describe(toolName: input["command"] != nil ? "shell" : name, input: input)
            return [TranscriptEntry(kind: .tool, id: payload["call_id"] as? String ?? id, text: described, tool: name, at: at)]
        case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
            let (output, truncated) = clipped(resultText(payload["output"]), limit: outputLimit)
            return [TranscriptEntry(kind: .toolResult, id: payload["call_id"] as? String ?? id, text: "",
                                    output: output, outputTruncated: truncated, at: at)]
        default:
            return []
        }
    }

    // MARK: Helpers

    /// Typed text only: injected context (`<task-notification>`, `<environment_context>`, command
    /// caveats) starts with a tag.
    private static func humanText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return Redaction.secrets(in: trimmed)
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.map { block -> String in
                if let text = block["text"] as? String { return text }
                return "[\(block["type"] as? String ?? "attachment")]"
            }.joined(separator: "\n")
        }
        if let object = content as? [String: Any], let output = object["output"] as? String { return output }
        return ""
    }

    private static func clipped(_ text: String, limit: Int) -> (String, Bool) {
        let masked = Redaction.secrets(in: text)
        guard masked.utf8.count > limit else { return (masked, false) }
        var cut = masked.utf8.prefix(limit)
        while String(cut) == nil { cut = cut.dropLast() }   // don't split a character
        return (String(cut)! + "\n…", true)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func time(_ value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        return (isoFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text))?.timeIntervalSince1970
    }
}
```

- [ ] **Step 4: Run them.** `swift test --filter TranscriptReaderTests 2>&1 | grep -E "error:|✘|passed|failed|Expectation failed" | head -12`
Expected: all 7 pass.
- If `everythingIsMasked` fails on the Bash summary, `ToolActivity.describe` doesn't mask. Wrap the
  `.tool` text in `Redaction.secrets(in:)` (ledger ruling).
- If `ISO8601DateFormatter` isn't `Sendable` under the Swift 6 toolchain, make the static
  `nonisolated(unsafe)` (ledger ruling).

- [ ] **Step 5: Whole suite.** `swift test 2>&1 | tail -1`. Expected: all pass.

- [ ] **Step 6: Commit.**
```bash
git add Sources/VibeCore/TranscriptReader.swift Tests/VibeCoreTests/HistoryTests.swift
git commit -m "History: read Claude Code and Codex transcripts into timeline entries

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Mac side: scrollback read and the three routes

**Files:**
- Modify: `Sources/VibeSwitcher/TerminalBridge.swift`, adding `history(tty:)` after `screens(for:)`.
- Modify: `Sources/VibeSwitcher/PhoneAccess.swift`:
  - in `route`, add the cases;
  - in `stateObject`, add the row fields;
  - add new functions after `screen(_:respond:)`;
  - add the property `historyCache`.

**Interfaces:**
- Consumes: `Scrollback`, `TranscriptReader`, `HookState.load`, `VibePaths.stateDir`.
- Produces:
  - **`GET /api/history?tty=&before=&limit=`** returns `{tty, lines, start, total, first}`.
  - **`GET /api/conversation?tty=&after=`** returns `{tty, entries, cursor, truncatedBefore, format}`:
    - `after` absent: the tail, at most 2 MB;
    - `cursor` is a byte offset;
    - `truncatedBefore` is true when the tail didn't start at byte 0.
  - **`GET /api/conversation/tool?tty=&id=`** returns `{tty, entry}`, with output up to 64 KB.
  - **State rows** gain `hasTranscript: Bool` and `eventAt: Double` (the hook's `lastEventAt`).

- [ ] **Step 1: Scrollback read.** Add to `TerminalBridge`:

```swift
    /// A tab's whole scrollback and its visible screen, in one read (for the phone's Terminal tab).
    static func history(tty: String) -> (history: String, screen: String)? {
        guard isRunning, isValidTTY(tty) else { return nil }
        let result = runAppleScript("""
        set target to "/dev/\(tty)"
        tell application "Terminal"
            repeat with w in windows
                try
                    repeat with ti from 1 to (count of tabs of w)
                        if ((tty of tab ti of w) as text) is target then
                            return ((history of tab ti of w) as text) & (character id 29) & ((contents of tab ti of w) as text)
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return ""
        """, timeout: 8)
        let parts = result.output.components(separatedBy: "\u{1D}")
        guard result.status == 0, parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
```

Run: `swift build 2>&1 | grep -E "error|Build complete"`. Expected: `Build complete!`.

- [ ] **Step 2: Routes.** In `PhoneAccess.route`, add before `default:`:

```swift
        case ("GET", "/api/history"): history(request, respond: respond)
        case ("GET", "/api/conversation"): conversation(request, respond: respond)
        case ("GET", "/api/conversation/tool"): conversationTool(request, respond: respond)
```

In `stateObject(for:)`, inside the per-session `row` building, before `return row`:

```swift
            if let hook = Self.hookState(for: session.tty) {
                row["eventAt"] = hook.lastEventAt
                row["hasTranscript"] = hook.transcriptPath.flatMap { TranscriptReader.checkedURL($0, home: NSHomeDirectory()) } != nil
            }
```

Add the property `private var historyCache: [String: (at: Date, lines: [String])] = [:]` next to
`screenCache`. Then add after `screen(_:respond:)`:

```swift
    private static func hookState(for tty: String) -> HookState? {
        guard TerminalBridge.isValidTTY(tty) else { return nil }
        return HookState.load(from: VibePaths.stateDir.appendingPathComponent("\(tty).json"))
    }

    /// The tab's scrollback above the visible screen, a page at a time (the phone prepends pages as you
    /// scroll up). Read once and kept for 2 s, so paging quickly doesn't re-read a huge scrollback.
    private func history(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let tty = request.query["tty"] ?? ""
        guard TerminalBridge.isValidTTY(tty), let session = store.sessions.first(where: { $0.tty == tty }) else {
            return respond(.error(404, "no such session"))
        }
        guard session.inTerminalApp else { return respond(.error(409, "This session isn't in a Terminal tab.")) }
        let before = request.query["before"].flatMap { Int($0) }
        let limit = request.query["limit"].flatMap { Int($0) } ?? Scrollback.pageLimit
        let send: ([String]) -> Void = { lines in
            let page = Scrollback.page(lines, before: before, limit: limit)
            respond(.json(["tty": tty, "lines": page.lines, "start": page.start, "total": page.total, "first": page.first]))
        }
        if let cached = historyCache[tty], cached.at.timeIntervalSinceNow > -2 { return send(cached.lines) }
        reads.async {
            let read = TerminalBridge.history(tty: tty)
            let lines = read.map { Scrollback.lines(history: Redaction.secrets(in: $0.history), screen: Redaction.secrets(in: $0.screen)) }
            DispatchQueue.main.async {
                guard let lines else { return respond(.error(503, "Couldn't read that tab right now.")) }
                let live = Set(self.store.sessions.map(\.tty))
                self.historyCache = self.historyCache.filter { live.contains($0.key) }
                self.historyCache[tty] = (Date(), lines)
                send(lines)
            }
        }
    }

    private static let conversationTailBytes = 2 * 1024 * 1024

    /// Conversation entries from the agent's transcript: the tail first, then what's new after `after`.
    private func conversation(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let tty = request.query["tty"] ?? ""
        guard store.sessions.contains(where: { $0.tty == tty }) else { return respond(.error(404, "no such session")) }
        guard let path = Self.hookState(for: tty)?.transcriptPath,
              let checked = TranscriptReader.checkedURL(path, home: NSHomeDirectory()) else {
            return respond(.error(404, "No transcript for this session. See the Terminal tab."))
        }
        let (url, format) = checked
        let after = request.query["after"].flatMap { Int($0) }
        reads.async {
            let response: HTTPResponse
            if let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() {
                defer { try? handle.close() }
                let fileSize = Int(size)
                var start = after.map { min(max(0, $0), fileSize) } ?? max(0, fileSize - Self.conversationTailBytes)
                if after != nil, start > fileSize { start = 0 }   // file was replaced: start over
                try? handle.seek(toOffset: UInt64(start))
                var data = (try? handle.readToEnd()) ?? Data()
                var skipped = 0
                if after == nil, start > 0 {
                    skipped = TranscriptReader.tailStart(data)
                    data = data.subdata(in: (data.startIndex + skipped)..<data.endIndex)
                }
                let result = TranscriptReader.read(data, format: format)
                response = .json(["tty": tty, "entries": result.entries.map(\.json),
                                  "cursor": start + skipped + result.consumed,
                                  "truncatedBefore": after == nil && start > 0,
                                  "format": format == .claude ? "claude" : "codex"])
            } else {
                response = .error(503, "Couldn't read the transcript right now.")
            }
            DispatchQueue.main.async { respond(response) }
        }
    }

    /// One tool call with its full output (up to 64 KB), for "Show all".
    private func conversationTool(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let tty = request.query["tty"] ?? "", id = request.query["id"] ?? ""
        guard !id.isEmpty, store.sessions.contains(where: { $0.tty == tty }),
              let path = Self.hookState(for: tty)?.transcriptPath,
              let checked = TranscriptReader.checkedURL(path, home: NSHomeDirectory()) else {
            return respond(.error(404, "not found"))
        }
        let (url, format) = checked
        reads.async {
            let data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
            let entry = TranscriptReader.read(data, format: format, outputLimit: 64 * 1024).entries
                .first { $0.id == id && $0.kind == .tool }
            DispatchQueue.main.async {
                guard let entry else { return respond(.error(404, "not found")) }
                respond(.json(["tty": tty, "entry": entry.json]))
            }
        }
    }
```

Run: `swift build 2>&1 | grep -E "error|Build complete"`. Expected: `Build complete!`.

- [ ] **Step 3: Install and check with a scratch session.**

```bash
swift test 2>&1 | tail -1
./scripts/build-app.sh --install 2>&1 | tail -1
```

Start a **scratch** Claude session for the checks:
1. Open a new Terminal window and run `cd <scratchpad>/vs-history && claude`, in a fresh empty folder.
2. Ask it: `Run "seq 1 3000" with Bash, then reply DONE`, and accept the Bash permission prompt **in that
   scratch window**.
3. Pair a temporary device named `History test (Claude)`, as in the dev-pages plan (Task 6, Step 5): read
   the pairing code from the Phone Access window and set `LOGIN`/`TOKEN` silently.
4. Then:

```bash
API() { curl -s -H "Tailscale-User-Login: $LOGIN" -H "Authorization: Bearer $TOKEN" "$@"; }
T=<scratch tty, from: .build/debug/VibeSwitcher --dump | grep vs-history>
API "http://127.0.0.1:47823/api/history?tty=$T" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["start"],d["total"],d["first"],len(d["lines"]),d["lines"][-1][:40])'
API "http://127.0.0.1:47823/api/history?tty=$T&before=100" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["start"],len(d["lines"]))'
API "http://127.0.0.1:47823/api/conversation?tty=$T" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["format"],d["truncatedBefore"],[e["kind"] for e in d["entries"]],d["cursor"])'
```

Expected:
- **History:** a 500-line page ending just above the screen, and `start` 0 for `before=100` with 100 lines.
- **Conversation:** `claude False ['prompt', 'tool', 'reply']` (or similar), with a positive cursor.

Then `API "…/api/conversation?tty=$T&after=<cursor>"` should return `entries: []`. A tool id from the
entries, sent to `/api/conversation/tool`, returns the entry with its output.

Leave the scratch session, its window and the temporary device in place for Task 5. They're removed in
Task 6.

- [ ] **Step 4: Commit.**
```bash
git add Sources/VibeSwitcher/TerminalBridge.swift Sources/VibeSwitcher/PhoneAccess.swift
git commit -m "Phone Access: scrollback pages, conversation entries and full tool output

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The phone's Terminal and Conversation tabs

**Files:**
- Modify: `Web/index.html`, the session section:
  - tabs at the end of `.sessionBar`;
  - `#screen` gets two children;
  - `#conversation` goes after `#screen`, inside `.screenWrap`.
- Modify: `Web/app.js`:
  - `renderScreen` targets `#live`;
  - `openSession` resets the tabs;
  - `refreshList` triggers the conversation refresh;
  - new history and conversation functions;
  - listeners in the setup block.
- Modify: `Web/style.css` (append).

**Interfaces:**
- Consumes: `/api/history`, `/api/conversation`, `/api/conversation/tool`, and the state rows'
  `hasTranscript`/`eventAt` (Task 4).

- [ ] **Step 1: Markup.**
  - In `.sessionBar`, after the `.tools` div:
    ```html
      <div class="viewTabs" role="tablist">
        <button id="tabTerminal" class="on" type="button" role="tab" aria-selected="true">Terminal</button>
        <button id="tabConversation" type="button" role="tab" aria-selected="false">Conversation</button>
      </div>
    ```
  - Replace `<div id="screen" class="screen" aria-live="off"></div>` with:
    ```html
      <div id="screen" class="screen" aria-live="off"><div id="earlier" class="earlier" hidden></div><div id="scrollback"></div><div id="live"></div></div>
      <div id="conversation" class="conversation" hidden></div>
    ```

- [ ] **Step 2: Terminal tab with scrollback.** In `app.js`:
  - In `renderScreen`, change `$('screen').replaceChildren(fragment);` to `$('live').replaceChildren(fragment);`.
  - In `openSession`, replace `$('screen').replaceChildren();` with `resetHistory(); resetConversation(); showTab('terminal');`.
  - Factor the line-rendering loop body of `renderScreen` into `function lineNode(raw)`, which returns the
    node, so scrollback lines render identically.
  - Add before `// ---------- Quick replies ----------`:

```js
// ---------- Terminal scrollback ----------

const history = { start: null, first: 0, busy: false };

function resetHistory() {
  history.start = null;
  history.first = 0;
  $('scrollback').replaceChildren();
  $('live').replaceChildren();
  $('earlier').hidden = true;
}

/// Near the top of the Terminal tab: fetch the page above what's shown and keep the view where it was.
async function loadEarlier() {
  if (history.busy || !current || (history.start !== null && history.start <= history.first)) return;
  history.busy = true;
  const tty = current;
  const screen = $('screen');
  try {
    const before = history.start === null ? '' : `&before=${history.start}`;
    const page = await api(`/api/history?tty=${encodeURIComponent(tty)}${before}`);
    if (tty !== current) return;
    // A cleared terminal is shorter than what we asked about: start over from its end.
    if (history.start !== null && page.total < history.start) { resetHistory(); return; }
    const fragment = document.createDocumentFragment();
    for (const raw of page.lines) fragment.append(lineNode(raw));
    const fromBottom = screen.scrollHeight - screen.scrollTop;
    $('scrollback').prepend(fragment);
    screen.scrollTop = screen.scrollHeight - fromBottom;
    history.start = page.start;
    history.first = page.first;
    $('earlier').hidden = false;
    $('earlier').textContent = page.start > page.first ? '↑ Scroll for earlier output' : 'Start of the scrollback';
  } catch (error) {
    $('screenError').textContent = error.message;
    $('screenError').hidden = false;
  } finally {
    history.busy = false;
  }
}
```

  - In the setup block, extend the existing `screen` scroll listener:
    `$('screen').addEventListener('scroll', () => { $('toBottom').hidden = isAtBottom(); if ($('screen').scrollTop < 300) loadEarlier(); }, { passive: true });`
    It replaces the current one-liner.

- [ ] **Step 3: Conversation tab.** Add after the scrollback section:

```js
// ---------- Conversation ----------

const conversation = { cursor: null, eventAt: null, busy: false, loaded: false };

function resetConversation() {
  conversation.cursor = null;
  conversation.eventAt = null;
  conversation.loaded = false;
  $('conversation').replaceChildren();
}

function showTab(name) {
  const terminal = name === 'terminal';
  $('screen').hidden = !terminal;
  $('conversation').hidden = terminal;
  $('toBottom').hidden = !terminal || isAtBottom();
  $('tabTerminal').classList.toggle('on', terminal);
  $('tabConversation').classList.toggle('on', !terminal);
  $('tabTerminal').setAttribute('aria-selected', String(terminal));
  $('tabConversation').setAttribute('aria-selected', String(!terminal));
  for (const id of ['wrapToggle', 'fontDown', 'fontUp']) $(id).hidden = !terminal;
  if (!terminal) refreshConversation(true);
}

function timeLabel(at) {
  return at ? new Date(at * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
}

function entryNode(entry) {
  if (entry.kind === 'tool') {
    const box = el('details', `toolRow${entry.failed ? ' failed' : ''}`);
    box.dataset.id = entry.id;
    const summary = el('summary');
    const status = entry.output === undefined ? '…' : (entry.failed ? '✗' : '✓');
    const took = entry.duration ? ` · ${duration(Date.now() / 1000 + clockOffset - entry.duration)}` : '';
    summary.append(el('span', 'toolName', entry.tool || 'tool'), el('span', 'toolText', entry.text),
                   el('span', 'toolMeta', `${took} ${status}`.trim()));
    box.append(summary);
    if (entry.output !== undefined) {
      box.append(el('pre', 'toolOutput', entry.output));
      if (entry.outputTruncated) {
        const more = el('button', 'link', 'Show all');
        more.type = 'button';
        more.addEventListener('click', () => showFullTool(entry.id, box));
        box.append(more);
      }
    }
    return box;
  }
  const bubble = el('div', `bubble ${entry.kind}`);
  bubble.append(el('div', 'bubbleText', entry.text), el('div', 'bubbleTime', timeLabel(entry.at)));
  return bubble;
}

function applyEntries(entries) {
  const box = $('conversation');
  const stick = box.scrollHeight - box.scrollTop - box.clientHeight < 60;
  for (const entry of entries) {
    if (entry.kind === 'toolResult') {
      const row = box.querySelector(`.toolRow[data-id="${CSS.escape(entry.id)}"]`);
      if (row) row.replaceWith(entryNode({ ...JSON.parse(row.dataset.entry || '{}'), ...entry, kind: 'tool' }));
      continue;
    }
    const node = entryNode(entry);
    if (entry.kind === 'tool') node.dataset.entry = JSON.stringify({ id: entry.id, tool: entry.tool, text: entry.text, at: entry.at });
    box.append(node);
  }
  if (stick) box.scrollTop = box.scrollHeight;
}

/// First open: the transcript's tail. Afterwards only what's new, and only when the session changed.
async function refreshConversation(force = false) {
  if (!current || $('conversation').hidden || conversation.busy) return;
  const session = state && state.sessions.find(s => s.tty === current);
  if (!force && conversation.loaded && session && session.eventAt === conversation.eventAt) return;
  conversation.busy = true;
  const tty = current;
  try {
    const after = conversation.cursor === null ? '' : `&after=${conversation.cursor}`;
    const result = await api(`/api/conversation?tty=${encodeURIComponent(tty)}${after}`);
    if (tty !== current) return;
    if (!conversation.loaded && result.truncatedBefore) $('conversation').append(el('p', 'muted small center', 'Earlier messages aren’t shown.'));
    applyEntries(result.entries);
    if (!conversation.loaded && !result.entries.length) $('conversation').append(el('p', 'muted small center', 'Nothing yet.'));
    conversation.cursor = result.cursor;
    conversation.eventAt = session ? session.eventAt : null;
    conversation.loaded = true;
  } catch (error) {
    if (!conversation.loaded) $('conversation').replaceChildren(el('p', 'muted center', error.message));
  } finally {
    conversation.busy = false;
  }
}

async function showFullTool(id, row) {
  try {
    const result = await api(`/api/conversation/tool?tty=${encodeURIComponent(current)}&id=${encodeURIComponent(id)}`);
    const node = entryNode(result.entry);
    node.open = true;
    row.replaceWith(node);
  } catch (error) {
    row.append(el('p', 'error', error.message));
  }
}
```

  - In `refreshList`, in the `if (current) return renderSessionMeta();` line, refresh the conversation too:
    `if (current) { refreshConversation(); return renderSessionMeta(); }`.
  - In the setup block: `$('tabTerminal').addEventListener('click', () => showTab('terminal'));` and
    `$('tabConversation').addEventListener('click', () => showTab('conversation'));`.

- [ ] **Step 4: Style.** Append to `Web/style.css`:

```css
.viewTabs { display: flex; gap: 4px; background: var(--bg); border-radius: 9px; padding: 3px; align-self: flex-start; }
.viewTabs button { border: 0; background: transparent; color: var(--muted); border-radius: 7px; padding: 5px 12px;
  font-size: 13px; font-weight: 600; }
.viewTabs button.on { background: var(--card); color: var(--text); box-shadow: 0 1px 2px rgba(0,0,0,0.15); }
.earlier { color: #8e8e93; font-size: 11px; text-align: center; padding: 4px 0 8px; }
.conversation { flex: 1; overflow: auto; overscroll-behavior: contain; display: flex; flex-direction: column; gap: 8px;
  padding: 4px 2px; }
.bubble { max-width: 88%; border-radius: 14px; padding: 8px 11px; font-size: 14.5px; line-height: 1.38;
  white-space: pre-wrap; overflow-wrap: anywhere; }
.bubble.prompt { align-self: flex-end; background: var(--accent); color: #fff; border-bottom-right-radius: 4px; }
.bubble.reply { align-self: flex-start; background: var(--card); border-bottom-left-radius: 4px; }
.bubbleTime { font-size: 10.5px; opacity: 0.6; margin-top: 3px; text-align: right; }
.toolRow { align-self: stretch; background: var(--card); border-radius: 10px; font-size: 12.5px; }
.toolRow summary { display: flex; gap: 6px; align-items: baseline; padding: 7px 10px; list-style: none; }
.toolRow summary::-webkit-details-marker { display: none; }
.toolName { flex: none; font-weight: 700; color: var(--muted); }
.toolText { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.toolMeta { flex: none; color: var(--muted); }
.toolRow.failed .toolMeta { color: var(--warn); }
.toolOutput { margin: 0; padding: 8px 10px; border-top: 1px solid var(--line); max-height: 40dvh; overflow: auto;
  font: 11.5px/1.35 ui-monospace, "SF Mono", Menlo, "Roboto Mono", monospace; white-space: pre-wrap; overflow-wrap: anywhere; }
```

- [ ] **Step 5: Check.**
  - `node --check Web/app.js && echo ok`.
  - Rebuild and install (`./scripts/build-app.sh --install`).
  - Open the phone app in the Mac's Chrome on the **scratch** session, using the temporary device's token.
    Set it into the page's `localStorage` (`vs.token`) via the Chrome tools in a scratch tab at
    `https://<mac>:8443/#s=<scratch tty>`.
  - Confirm:
    - the Terminal tab scrolls up into `seq` output, page after page;
    - the Conversation tab shows the prompt bubble, a `Bash` row that expands to output and "Show all",
      and the reply;
    - a new prompt typed **in the scratch window** appears in the Conversation tab within a few seconds.
  - Take a 360px-wide screenshot of the Conversation tab to check the layout.

- [ ] **Step 6: Commit.**
```bash
git add Web/index.html Web/app.js Web/style.css
git commit -m "Phone: Terminal tab with full scrollback, Conversation tab from the transcript

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: README and cleanup

- [ ] **Step 1: README.** In the Phone Access section, after the session view description, add:

```markdown
The session view has two tabs:

- **Terminal**: the live screen. Scroll up for the tab's earlier output (up to the last 5,000 lines).
- **Conversation**: the session as a clean timeline, read from Claude Code's (or Codex's) own transcript.
  It shows your prompts, the agent's replies and one row per tool call; tap a row for its output. It
  updates as the session moves.
```

- [ ] **Step 2: Cleanup.**
  - Exit the scratch Claude session (`/exit` in **its** window) and close that window.
  - Remove `History test (Claude)` in Phone Access, close the scratch Chrome tab, and `unset TOKEN LOGIN`.
- [ ] **Step 3: Full suite.** `swift test 2>&1 | tail -1` → all pass.
- [ ] **Step 4: Commit.**
```bash
git add README.md
git commit -m "README: Terminal and Conversation tabs on the phone

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
