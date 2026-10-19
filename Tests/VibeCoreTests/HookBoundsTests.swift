import Darwin
import Foundation
import Testing
@testable import VibeCore

private final class HookAnchor {}

/// A hook event never holds an agent's turn: VibeSwitcher's own work on one takes about a second at most, whatever
/// comes in (docs/eval/open-2026-10-19.md, R4 + E-28). `clip` reads a bounded head, the locks give up after a second,
/// and the built hook leaves on an alarm at 3 s. The hook runs here on a scratch home only.
struct HookBoundsTests {
    let temp = Scratch()

    // MARK: Clip

    /// `clip` as it was before it read only a head: the golden for texts under 1 KB.
    static func clipBefore(_ text: String?, to limit: Int = 280) -> String? {
        guard let text else { return nil }
        let flat = Redaction.secrets(in: text).split(whereSeparator: \.isNewline).joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// `SessionNaming.isSystemPrompt` as it was before it read only a head.
    static func isSystemPromptBefore(_ prompt: String) -> Bool {
        if TypedText.agentMessage(prompt) != nil { return true }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") else { return false }
        let tag = trimmed[trimmed.index(after: trimmed.startIndex)..<close].prefix { $0 != " " }
        return !tag.isEmpty && tag.allSatisfy { $0.isLetter || $0 == "-" || $0 == "_" }
    }

    static let pieces = [
        "word", "the ", " ", "  ", "\n", "\n\n", "**", "`", "```", "\t", "é", "日本語", "👍🏽", "e\u{301}", "\u{2028}",
        "token=abc123def", "ghp_" + String(repeating: "Ab1", count: 12), "sk-ant-api03-" + String(repeating: "xY9_", count: 10),
        "Bearer abcdefgh12345678", "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----",
        "<task-notification>", "<system-reminder>", "PASSWORD=\"two words\"", "https://user:pa55@host/x", "AKIAIOSFODNN7EXAMPLE",
        "Another Claude session sent a message:", "<cross-session-message from=\"lead\">", ">", "[",
    ]

    @Test func textsUnder1KBComeOutAsBefore() {
        var random = SystemRandomNumberGenerator()
        var differing: [String] = []
        for round in 0..<2000 {
            let target = round < 1000 ? Int.random(in: 0..<300, using: &random) : Int.random(in: 300..<1024, using: &random)
            var text = ""
            while text.utf8.count < target {
                let piece = Self.pieces.randomElement(using: &random)!
                guard (text + piece).utf8.count < 1024 else { break }
                text += piece
            }
            for limit in [280, 200, 160, 60] where HookState.clip(text, to: limit) != Self.clipBefore(text, to: limit) {
                differing.append("clip to \(limit): \(text.debugDescription)")
            }
            if SessionNaming.isSystemPrompt(text) != Self.isSystemPromptBefore(text) { differing.append("system: \(text.debugDescription)") }
        }
        #expect(differing.isEmpty, "\(differing.count) differ, first: \(differing.first ?? "")")
    }

    @Test func aSecretTheCutGoesThroughIsStillMasked() throws {
        let secret = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"
        // Newlines `clip` drops before the secret, so the cut (1,120 units in) goes through it within what's shown:
        // 15 of its characters before the cut.
        let before = "see " + String(repeating: "\n", count: 1120 - 4 - 19)
        let partial = String(secret.prefix(19))
        // What's before the cut, on its own, isn't recognised as a secret (too short): without the care it'd be shown.
        #expect(Redaction.secrets(in: before + partial).hasSuffix(partial))
        for text in [before + secret + " and more", before + secret] {
            let clipped = try #require(HookState.clip(text))
            #expect(!clipped.contains("ghp_") && !clipped.contains("A1b2C3"), "\(clipped)")
            #expect(clipped.hasPrefix("see"))
            #expect(Self.clipBefore(text)?.contains("A1b2C3") == false)
        }
        // A head that's all one word, cut: the start of a long token isn't shown.
        #expect(HookState.clip(String(repeating: "eyJhbGciOiJIUzI1NiJ9", count: 300)) == "•••…")
        #expect(HookState.clip("**" + String(repeating: "x", count: 5000)) == "•••…")
        // Prose that goes on past the cut: as before, from its start.
        let prose = String(repeating: "lorem ipsum dolor ", count: 400)
        #expect(HookState.clip(prose) == Self.clipBefore(prose))
    }

    @Test func aSystemPromptIsToldFromItsStartWhateverItsSize() {
        let tail = String(repeating: "x ", count: 2_500_000)
        #expect(SessionNaming.isSystemPrompt("\n  <task-notification>\n" + tail))
        #expect(SessionNaming.isSystemPrompt("<cross-session-message from=\"lead\">" + tail))
        #expect(!SessionNaming.isSystemPrompt("fix the build " + tail))
        #expect(!SessionNaming.isSystemPrompt("<" + tail))
    }

    /// A 5 MB prompt and a 5 MB turn-end message cost what 10 KB ones do: masking all of one took 6 s at load 195
    /// (verbatim copies, 2026-10-19), inside the hook's lock.
    @Test func aHugePromptOrMessageCostsWhatASmallOneDoes() {
        func text(_ bytes: Int) -> String {
            let line = "Run **npm test** in `pkg/` with token=abc123 and Bearer abcdefgh12345678, then tell me.\n"
            return String(repeating: line, count: bytes / line.utf8.count + 1)
        }
        func cost(_ payload: [String: Any]) -> TimeInterval {
            (0..<3).map { _ in
                let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                _ = HookState.reduce(current: nil, payload: payload, agent: .claude, tty: "ttys001", agentPid: 7, now: 1)
                return TimeInterval(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
            }.min()!
        }
        let small = text(10_000), big = text(5_000_000)
        for (event, field) in [("UserPromptSubmit", "prompt"), ("Stop", "last_assistant_message")] {
            let payload = { (text: String) -> [String: Any] in ["hook_event_name": event, "session_id": "s", field: text] }
            let baseline = cost(payload(small)), huge = cost(payload(big))
            #expect(huge - baseline < 0.020, "\(event): 5 MB \(huge * 1000) ms, 10 KB \(baseline * 1000) ms")
        }
    }

    // MARK: Locks

    @Test func aLockHeldElsewhereIsGivenUpAfterASecond() throws {
        let path = temp.url("lock").path
        let holder = open(path, O_CREAT | O_RDWR, 0o600), other = open(path, O_RDWR)
        defer { close(holder); close(other) }
        #expect(flock(holder, LOCK_EX) == 0)
        let start = Date()
        #expect(!HookLock.exclusive(other, within: 1))
        let waited = Date().timeIntervalSince(start)
        #expect(waited >= 0.95 && waited < 2.5, "waited \(waited) s")
        flock(holder, LOCK_UN)
        #expect(HookLock.exclusive(other, within: 1))
        flock(other, LOCK_UN)
    }

    @Test func aSteerInboxHeldElsewhereLeavesItsMessagesWaiting() throws {
        let root = temp.url("steer")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SteerInbox.post(SteerMessage(id: "a", text: "check the tests", from: .lead("lead"), agentPid: 42, at: 1), tty: "ttys001", root: root)
        let inbox = try SteerInbox.file("ttys001", "jsonl", root: root)
        let holder = open(inbox.path, O_RDWR)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX) == 0)
        let start = Date()
        #expect(SteerInbox.take(tty: "ttys001", agentPid: 42, root: root).isEmpty)
        let waited = Date().timeIntervalSince(start)
        #expect(waited >= 0.95 && waited < 2.5, "waited \(waited) s")
        flock(holder, LOCK_UN)
        #expect(SteerInbox.take(tty: "ttys001", agentPid: 42, root: root).map(\.id) == ["a"])
    }

    // MARK: The built hook

    static let hook = Bundle(for: HookAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-hook")

    /// The terminal the hook started from this process records for (as its `main.swift` finds it), if any.
    static let terminal: String? = {
        let arguments = { (proc: ProcInfo) in ProcessTable.arguments(pid: proc.pid, start: Int(proc.startTime.timeIntervalSince1970), comm: proc.comm) }
        switch HookOwner.lineage(ProcessTable.ancestors(of: getpid()), arguments: arguments) {
        case .agent(_, let tty): return tty
        case .none: return ProcessTable.info(pid: getpid())?.tty
        case .nested, .detached: return nil
        }
    }()

    /// Runs the built hook (`claude`) on a scratch home with `input` as its stdin: how it ended, how long it took and
    /// what it printed.
    func runHook(home: URL, input: FileHandle) throws -> (status: Int32, reason: Process.TerminationReason, seconds: TimeInterval, stdout: Data) {
        #expect(FileManager.default.isExecutableFile(atPath: Self.hook.path), "build it first: swift build")
        let output = temp.url("hook-stdout")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let process = Process()
        process.executableURL = Self.hook
        process.arguments = ["claude"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        let start = Date()
        try process.run()
        if ended.wait(timeout: .now() + hangGuard) == .timedOut { process.terminate() }
        let seconds = Date().timeIntervalSince(start)
        return (process.terminationStatus, process.terminationReason, seconds, (try? Data(contentsOf: output)) ?? Data())
    }

    func home() throws -> URL {
        let home = temp.url("hook-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    func payload(_ object: [String: Any]) throws -> FileHandle {
        let file = temp.url("hook-input")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        return try FileHandle(forReadingFrom: file)
    }

    @Test func anInputThatNeverEndsHoldsTheHookThreeSeconds() throws {
        let home = try home()
        let pipe = Pipe()
        // Half an event, and the pipe held open past the alarm.
        pipe.fileHandleForWriting.write(Data("{\"hook_event_name\": \"UserPromptSubmit\", ".utf8))
        let run = try runHook(home: home, input: pipe.fileHandleForReading)
        try? pipe.fileHandleForWriting.close()
        #expect(run.reason == .exit && run.status == 0)
        #expect(run.stdout.isEmpty)
        #expect(run.seconds >= 2.9 && run.seconds < 8, "took \(run.seconds) s")
    }

    @Test(.enabled(if: HookBoundsTests.terminal != nil, "the hook records for no terminal from here"))
    func aStateLockHeldElsewhereCostsTheEventItsStateNotTheTurn() throws {
        let home = try home(), tty = try #require(Self.terminal)
        let state = home.appendingPathComponent(".vibeswitcher/state/\(tty).json")
        let prompt = "Fix **the build** in `Package.swift`\nwith token=abc123def please"
        let first = try runHook(home: home, input: payload(["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": prompt]))
        #expect(first.reason == .exit && first.status == 0 && first.stdout.isEmpty)
        // Under 1 KB, the hook records it as it always did.
        #expect(HookState.load(from: state)?.lastPrompt == Self.clipBefore(prompt))
        #expect(HookState.load(from: state)?.lastPrompt == "Fix the build in Package.swift with token=••• please")

        let lock = open(state.path + ".lock", O_RDWR)
        defer { close(lock) }
        #expect(lock >= 0 && flock(lock, LOCK_EX) == 0)
        let held = try runHook(home: home, input: payload(["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": "next"]))
        #expect(held.reason == .exit && held.status == 0 && held.stdout.isEmpty)
        // A second for the lock, then on: well before the alarm.
        #expect(held.seconds >= 0.95 && held.seconds < 2.9, "took \(held.seconds) s")
        #expect(HookState.load(from: state)?.lastPrompt == Self.clipBefore(prompt))
        flock(lock, LOCK_UN)
    }
}
