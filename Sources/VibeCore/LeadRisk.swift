import Foundation

/// The risk check: a review none task's level from what its branch actually changes, not only from the lead's label
/// and sensitive_paths. Before a review none task merges (merge, and auto_advance's step to it), its branch's diff is
/// read: a change over `risk_lines` (outside tests, benches and fixtures), code that deletes or rewrites files or data, changes permissions, spawns processes
/// or adds locks or threads (`patterns`), a change to the test or build infrastructure the suite relies on, or to
/// REVIEW.md, is audited instead (the deterministic triggers, `deterministic`). Then, when the lead's tool server has
/// one, headless Claude gets the diff's stat (no code), the contract and the base branch's REVIEW.md, and answers raise
/// or keep with one reason (`prompt`, `parse`). Either can only raise: an answer of keep, a timeout or an error leaves
/// the deterministic result, and the task moves on. A raise is the vault's review audit from then on (only the lead
/// lowers it), so merge refuses it until it has a passing audit, as any audit task.
///
/// Idea from Anthropic's post on how the Claude Code team reviews code (2026-10-26): a classifier sets the risk tier
/// from the change, not its author. The lead once filed a permissions change as review none; its audit, raised by
/// hand, found three escapes.
///
/// REVIEW.md, at the repository's root: the owner's few lines on what matters in this code, what to ignore and what
/// counts as a Nit. The verifier and the risk check read it from the base branch (`reviewGuide`), never from the branch
/// under review, so a worker can't weaken its own audit by editing it.
public enum LeadRisk {
    /// workflow.md's `risk_lines` when it says none: a branch changing more lines than this (added and removed, outside
    /// tests, benches and fixtures: `countsForSize`) is audited.
    public static let defaultLines = 400

    /// What a branch's code adds or removes that raises it to audit, by what it does: each a regular expression on a
    /// changed line of a file that isn't a test, a document or a comment. Raise-only, so a pattern that also matches
    /// harmless code costs an audit, never a missed one.
    public static let patterns: [(what: String, regex: String)] = [
        ("deletes or rewrites files or data",
         #"\b(removeItem|unlink|unlinkSync|rmdir|rmSync|truncate|ftruncate|moveItem|replaceItem|replaceItemAt|trashItem|rmtree)\s*\("#
            + #"|\brm\s+-[A-Za-z]*[rRf]|\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f|push\s+(-f\b|--force))|\b(DROP\s+TABLE|DELETE\s+FROM|TRUNCATE\s+TABLE)\b"#
            + #"|\bos\.remove\b|\bfs\.(rm|unlink|rmdir)\b"#),
        ("changes permissions",
         #"\b(chmod|fchmod|chown|chflags|umask|setuid|setgid|seteuid|posixPermissions|permissions|allowedTools|disallowedTools)\b|--dangerously"#),
        ("spawns processes",
         #"\b(Process|NSTask)\s*\(|\bposix_spawn|\bfork\s*\(|\bexec[lv][pe]?\s*\(|\bpopen\s*\(|(?<![.\w])system\s*\(|\bShell\.run\b|\bchild_process\b"#
            + #"|\bspawn(Sync)?\s*\(|\bsubprocess\.|\bos\.system\b|\b(bash|zsh|sh)\s+-l?c\b|\bnohup\b"#),
        ("adds locks or threads",
         #"\b(NSLock|NSRecursiveLock|NSCondition|NSConditionLock|os_unfair_lock|OSAllocatedUnfairLock|Mutex|DispatchSemaphore|FileLock|flock|pthread_[a-z_]+)\b"#
            + #"|\bDispatchQueue\s*\(|\bDispatchQueue\.global\b|\bThread\.detachNewThread\b|\bThread\s*\(|\bTask\.detached\b|\bactor\s+[A-Z]|\bthreading\.Thread\b"#),
    ]

    private static let compiled: [(what: String, regex: NSRegularExpression)] = patterns.map { ($0.what, try! NSRegularExpression(pattern: $0.regex)) }

    /// The test and build infrastructure the suite relies on, as globs (as in .gitignore): build manifests, test
    /// scripts and harnesses, shared helpers and fakes, CI. Besides these, any file workflow.md's test_command,
    /// init_command or regression_command names (`commandFiles`).
    public static let infrastructure = [
        "Package.swift", "Package.resolved", "Makefile", "CMakeLists.txt", "*.xcodeproj/", "*.xcworkspace/", "*.xctestplan",
        "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "pyproject.toml", "setup.py", "setup.cfg", "tox.ini",
        "pytest.ini", "conftest.py", "jest.config.*", "vitest.config.*", "playwright.config.*", "Cargo.toml", "Cargo.lock",
        "go.mod", "go.sum", "build.gradle*", "settings.gradle*", ".github/workflows/", ".gitlab-ci.yml",
        "/scripts/test*", "/scripts/lib/", "/scripts/build*", "/scripts/worktree-init*", "/Resources/bin/vs-heavy",
        "**/TestSupport*", "**/TestHelpers*", "**/TestUtils*", "**/Fixtures/", "Tests/**/Fake*",
    ]

    /// The files a workflow command names: each word that reads as a path (has a slash, or a script's extension).
    public static func commandFiles(_ workflow: LeadWorkflow) -> [String] {
        let commands = [workflow.testCommand, workflow.initCommand, workflow.regressionCommand].compactMap { $0 }
        let words = commands.flatMap { $0.split(whereSeparator: { " \t\n;&|()'\"".contains($0) }).map(String.init) }
        return words.filter { word in
            !word.hasPrefix("-") && !word.hasPrefix("$") && !word.hasPrefix("/")
                && (word.contains("/") || [".sh", ".py", ".js", ".mjs", ".rb", ".pl"].contains { word.hasSuffix($0) })
        }.map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }
    }

    /// A file of the suite's own infrastructure.
    public static func isInfrastructure(_ path: String, workflow: LeadWorkflow) -> Bool {
        commandFiles(workflow).contains(path) || infrastructure.contains { LeadWorkflow.matches(path, glob: $0) }
    }

    /// A test file: its own changes are the tests', not the product's (the patterns don't read them).
    public static func isTest(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        let name = parts.last ?? path
        if parts.dropLast().contains(where: { ["Tests", "tests", "test", "__tests__", "spec", "testdata"].contains($0) || $0.hasSuffix("Tests") }) { return true }
        return name.hasSuffix("Tests.swift") || name.hasSuffix("Test.swift") || name.hasPrefix("test_") || name.contains(".test.")
            || name.contains(".spec.") || name.hasSuffix("_test.go") || name.hasSuffix("_test.py")
    }

    /// A file whose lines count toward `risk_lines`: not a test, a bench script, or a file in a fixtures or evidence
    /// folder. A branch's tests and their data are often most of its lines, and they don't run in the product; the
    /// suite's own infrastructure among them is still its own trigger.
    public static func countsForSize(_ path: String) -> Bool {
        guard !isTest(path) else { return false }
        let parts = path.split(separator: "/").map { $0.lowercased() }
        let folders = parts.dropLast()
        if folders.contains(where: { ["fixtures", "fixture", "__fixtures__", "evidence"].contains($0) }) { return false }
        return !(folders.contains("scripts") && (parts.last ?? "").contains("bench"))
    }

    /// A document or an image: what it says doesn't run.
    public static func isDocument(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["md", "markdown", "txt", "rst", "adoc", "png", "jpg", "jpeg", "gif", "svg", "pdf", "webp", "icns", "strings", "xcstrings"].contains(ext)
    }

    /// A file's changed lines, as `git diff --numstat` counts them (a binary file's are 0).
    public struct Change: Equatable, Sendable {
        public var path: String
        public var added: Int
        public var removed: Int

        public init(path: String, added: Int, removed: Int) {
            self.path = path
            self.added = added
            self.removed = removed
        }
    }

    /// `git diff --numstat`'s lines as changes; a rename's path is where it went.
    public static func changes(numstat: String) -> [Change] {
        numstat.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard fields.count == 3 else { return nil }
            var path = fields[2]
            // "a/{old => new}/b" or "old => new".
            if let arrow = path.range(of: " => ") {
                if let open = path.range(of: "{"), let close = path.range(of: "}", range: arrow.upperBound..<path.endIndex) {
                    path = String(path[..<open.lowerBound]) + String(path[arrow.upperBound..<close.lowerBound]) + String(path[close.upperBound...])
                    path = path.replacingOccurrences(of: "//", with: "/")
                } else {
                    path = String(path[arrow.upperBound...])
                }
            }
            return Change(path: path, added: Int(fields[0]) ?? 0, removed: Int(fields[1]) ?? 0)
        }
    }

    /// The first changed line in `patch` (a `git diff -U0`) that does what a pattern says, in a file that isn't a test
    /// or a document, and isn't a comment: what it does, the file, and the line. `kinds`: only those patterns (by what).
    public static func flagged(_ patch: String, kinds: Set<String>? = nil) -> (what: String, path: String, line: String)? {
        var path: String?
        // Between `diff --git` and its first `@@`: a removed `-- x` or an added `++ x` in a hunk isn't a file's name.
        var header = true
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("diff --git ") {
                header = true
                path = nil
                continue
            }
            if raw.hasPrefix("@@") {
                header = false
                continue
            }
            // git prints `--- a/old` then `+++ b/new`: a new file's `---` is /dev/null and a deleted file's `+++` is, so
            // a deleted file's removed lines are read under its `---` path.
            if header, raw.hasPrefix("--- ") {
                let source = raw.dropFirst(4)
                path = source == "/dev/null" ? nil : String(source.hasPrefix("a/") ? source.dropFirst(2) : source)
                continue
            }
            if header, raw.hasPrefix("+++ ") {
                let target = raw.dropFirst(4)
                if target != "/dev/null" { path = String(target.hasPrefix("b/") ? target.dropFirst(2) : target) }
                continue
            }
            guard !header, let file = path, raw.hasPrefix("+") || raw.hasPrefix("-"), !isTest(file), !isDocument(file) else { continue }
            let code = raw.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty, !["//", "/*", "*", "#"].contains(where: { code.hasPrefix($0) }) else { continue }
            let range = NSRange(code.startIndex..., in: code)
            for pattern in compiled where kinds?.contains(pattern.what) ?? true && pattern.regex.firstMatch(in: code, range: range) != nil {
                return (pattern.what, file, String(code.prefix(80)))
            }
        }
        return nil
    }

    /// Why the change raises a review none task to audit, without a model; nil when nothing does. `patch` is read
    /// only when the change is under the size threshold (`git diff -U0`, here on the Mac; never sent anywhere).
    public static func deterministic(changes: [Change], patch: () -> String?, workflow: LeadWorkflow) -> String? {
        let lines = changes.filter { countsForSize($0.path) }.reduce(0) { $0 + $1.added + $1.removed }
        if workflow.riskLines > 0, lines > workflow.riskLines {
            return "it changes \(lines) lines outside tests, over risk_lines (\(workflow.riskLines))"
        }
        let infrastructure = changes.map(\.path).filter { isInfrastructure($0, workflow: workflow) }
        if !infrastructure.isEmpty {
            return "it changes test or build infrastructure the suite relies on (" + list(infrastructure) + ")"
        }
        if changes.contains(where: { $0.path == guideFile }) {
            return "it changes \(guideFile), which steers every later review"
        }
        guard let patch = patch() else { return "what its lines change can't be read, so it's audited" }
        if let flagged = flagged(patch) {
            return "it has code that \(flagged.what) (\(flagged.path): \(flagged.line))"
        }
        return nil
    }

    static func list(_ paths: [String]) -> String {
        paths.prefix(4).joined(separator: ", ") + (paths.count > 4 ? ", …" : "")
    }

    // MARK: REVIEW.md

    /// The owner's review guide at the repository's root.
    public static let guideFile = "REVIEW.md"
    /// The most of it a prompt takes.
    public static let guideLimit = 2_048

    /// REVIEW.md as the base branch has it (`git show <base>:REVIEW.md`), at most `guideLimit` bytes; nil when the base
    /// has none. Never the branch under review's: a worker can't weaken its own audit by editing it.
    public static func reviewGuide(root: String, base: String) -> String? {
        let shown = Git.run(["show", "refs/heads/\(base):\(guideFile)"], in: root)
        guard shown.ok else { return nil }
        let text = shown.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return clip(text, bytes: guideLimit)
    }

    /// `text` cut to at most `bytes` of UTF-8, on a character, with "…" when it was cut.
    static func clip(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var cut = ""
        for character in text {
            if cut.utf8.count + character.utf8.count > bytes - 3 { break }
            cut.append(character)
        }
        return cut + "…"
    }

    // MARK: The model pass

    /// The longest the diff's stat and the contract are in the model's prompt.
    public static let statLimit = 3_000
    public static let contractLimit = 4_000
    /// How long the model pass may take before the deterministic result stands.
    public static let timeout: TimeInterval = 60

    public static let system = """
        You decide whether a finished code change needs an independent reviewer before it merges. Its author's lead \
        filed it as needing none: its worker owns it, and the merge runs the full test suite on it. Most changes are \
        keep. Answer raise only when the task's own goal or boundaries say it does one of these, and its review level \
        didn't account for it: security, authentication or permissions; secrets or the owner's private data; deleting \
        or rewriting stored data; a change other agents or the user's real sessions would feel at once. Touching a \
        file that matters, a bug fix, new tests or a UI change are keep. When unsure, keep.
        """

    /// What the model reads: the diff's stat (file names and counts, no code), the task's contract and the base
    /// branch's REVIEW.md, redacted and bounded.
    public static func prompt(stat: String, contract: String, guide: String?) -> String {
        """
        Answer with exactly one line and nothing else: "raise: <one reason>" or "keep: <one reason>".

        The task's contract:
        \(Redaction.secrets(in: Summarizer.clip(contract, contractLimit)))

        What the branch changes (git diff --stat):
        \(Redaction.secrets(in: Summarizer.clip(stat, statLimit)))

        The project owner's REVIEW.md:
        \(guide.map { Redaction.secrets(in: $0) } ?? "(none)")
        """
    }

    /// The model's answer: raise with its reason, keep, or nil when it isn't either (then the deterministic result stands).
    public enum Answer: Equatable, Sendable {
        case raise(String)
        case keep
    }

    public static func parse(_ text: String?) -> Answer? {
        guard let text else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'-*• ").union(.whitespaces))
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("keep") { return .keep }
            guard lower.hasPrefix("raise") else { return nil }
            let reason = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: ":-—– ").union(.whitespaces))
            return .raise(Summarizer.clip(reason.isEmpty ? "the model said raise, without a reason" : reason, 200))
        }
        return nil
    }
}

/// A review none task the risk check raised to audit: why, on which commit, and by what (the triggers, or the model).
public struct LeadRiskRaise: Codable, Equatable, Sendable {
    public var reason: String
    public var commit: String
    public var byModel: Bool
    public var at: Double

    public init(reason: String, commit: String, byModel: Bool, at: Double = Date().timeIntervalSince1970) {
        self.reason = reason
        self.commit = commit
        self.byModel = byModel
        self.at = at
    }
}

extension ClaudeHeadless {
    /// The risk check's model pass for `prompt` (see `LeadRisk.prompt`), through the same headless Claude as the
    /// all-done summary, in its emptied folder; nil when Claude isn't there, fails or takes longer than
    /// `LeadRisk.timeout`. Blocks.
    public static func risk(_ prompt: String) -> String? {
        let command = command(prompt: prompt, system: LeadRisk.system)
        return run(executable: command.executable, args: command.args, timeout: LeadRisk.timeout)
    }
}
