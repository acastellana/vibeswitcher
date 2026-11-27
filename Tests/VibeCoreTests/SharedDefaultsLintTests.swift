import Foundation
import Testing

/// No test reads or writes the standard user defaults, itself or through a type made with its default-argument defaults
/// (a bare `WindowModel` initializer, a `ChatModel` or `ComposerDrafts` not handed `defaults:`): an unbundled test binary's standard defaults live in the real
/// ~/Library/Preferences, shared by every test process on this Mac whatever HOME says, so runs side by side flip each
/// other's settings (EndedFoldTests, 6 runs in 10 under load, 2026-11-23). A test keeps them in `Scratch.defaults(_:)`.
/// The rule is scripts/shared-defaults-lint.txt; every line counts, comments too, so a grep with its patterns over Tests
/// finds only what it allows.
struct SharedDefaultsLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temp = Scratch()

    /// A use allowed in `file`, on a line containing `text`, for `reason`.
    struct Allowed: Hashable {
        let file: String, text: String, reason: String
    }

    /// The patterns, calls (each up to its opening parenthesis) and allowed uses in scripts/shared-defaults-lint.txt.
    static func rules() throws -> (patterns: [Regex<AnyRegexOutput>], calls: [Regex<AnyRegexOutput>], allowed: [Allowed]) {
        let list = try String(contentsOf: repo.appendingPathComponent("scripts/shared-defaults-lint.txt"), encoding: .utf8)
        var patterns: [Regex<AnyRegexOutput>] = []
        var calls: [Regex<AnyRegexOutput>] = []
        var allowed: [Allowed] = []
        for line in list.components(separatedBy: "\n") {
            if line.hasPrefix("pattern: ") { patterns.append(try Regex(String(line.dropFirst("pattern: ".count)))) }
            if line.hasPrefix("call: ") { calls.append(try Regex(String(line.dropFirst("call: ".count)))) }
            if line.hasPrefix("allow: ") {
                let fields = line.dropFirst("allow: ".count).components(separatedBy: " | ")
                allowed.append(Allowed(file: fields[0], text: fields.count > 1 ? fields[1] : "", reason: fields.count > 2 ? fields[2] : ""))
            }
        }
        return (patterns, calls, allowed)
    }

    /// A call's arguments: what follows its opening parenthesis (the end of `match`) up to the one closing it, across
    /// lines; the rest of `text` if none does.
    static func arguments(in text: String, after match: Range<String.Index>) -> Substring {
        var depth = 1
        var index = match.upperBound
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { return text[match.upperBound..<index] }
            }
            index = text.index(after: index)
        }
        return text[match.upperBound...]
    }

    /// Whether a call's arguments hand it defaults of its own.
    static func handsItsDefaults(_ arguments: Substring) -> Bool {
        arguments.contains("defaults:") && !arguments.contains(".standard")
    }

    /// "Tests/…/File.swift:12" for each use in the Swift files under `root`/Tests that isn't allowed, in order (a call
    /// at the line it starts on); and the allowed entries some use matched.
    static func uses(under root: URL) throws -> (flagged: [String], used: Set<Allowed>) {
        let (patterns, calls, allowed) = try rules()
        let tests = root.appendingPathComponent("Tests")
        let files = (FileManager.default.subpaths(atPath: tests.path) ?? []).filter { $0.hasSuffix(".swift") }.sorted()
        var flagged: [String] = []
        var used: Set<Allowed> = []
        for file in files {
            let path = "Tests/" + file
            let text = try String(contentsOf: tests.appendingPathComponent(file), encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            var hits = Set(lines.indices.filter { index in patterns.contains { lines[index].contains($0) } })
            for call in calls {
                for match in text.matches(of: call) where !handsItsDefaults(arguments(in: text, after: match.range)) {
                    hits.insert(text[..<match.range.lowerBound].filter { $0 == "\n" }.count)
                }
            }
            for index in hits.sorted() {
                let allowing = allowed.filter { $0.file == path && lines[index].contains($0.text) }
                if allowing.isEmpty { flagged.append("\(path):\(index + 1)") } else { used.formUnion(allowing) }
            }
        }
        return (flagged, used)
    }

    @Test func noTestUsesTheSharedDefaults() throws {
        let flagged = try Self.uses(under: Self.repo).flagged
        #expect(flagged == [], """
            these use the standard defaults every test process on this Mac shares: give the test a suite of its own \
            (Scratch.defaults, handed to WindowModel(defaults:), ChatModel(defaults:) and the like), or allow a read of a key the app never \
            writes in scripts/shared-defaults-lint.txt with its reason:
            \(flagged.joined(separator: "\n"))
            """)
    }

    /// Each allowed use says why, and is still there (a test changed or gone would leave an entry that excuses nothing).
    @Test func everyAllowedUseHasAReasonAndIsStillThere() throws {
        let allowed = try Self.rules().allowed
        #expect(allowed.filter { $0.file.isEmpty || $0.text.isEmpty || $0.reason.trimmingCharacters(in: .whitespaces).isEmpty } == [])
        let used = try Self.uses(under: Self.repo).used
        #expect(allowed.filter { !used.contains($0) }.map { "\($0.file) | \($0.text)" } == [])
    }

    /// A new test file using the standard defaults, or a model made with them, is named with its lines, a comment's too;
    /// a model handed a suite of its own isn't, its `defaults:` on the call's first line or a later one. (The uses are
    /// spelled in pieces so this file has none.)
    @Test func aTestUsingTheSharedDefaultsIsNamedWithItsLine() throws {
        let root = temp.url("shared-defaults-lint")
        let folder = root.appendingPathComponent("Tests/VibeSwitcherTests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let standard = "UserDefaults" + ".standard", bare = "WindowModel" + "()", suite = "UserDefaults" + "(suiteName:"
        let chat = "ChatModel" + "(", drafts = "ComposerDrafts" + "("
        let example = """
            import Foundation
            let model = WindowModel(defaults: temp.defaults("x"))
            \(standard).set(true, forKey: "inspectorCollapsed")
            let other = \(bare)
            // \(standard) named in a comment
            let grouping = \(standard).string(forKey: "windowGrouping"), again = \(bare)
            let fine = \(suite) path)
            let a = \(chat))
            let b = \(chat)outbox: ComposerOutbox(url: temp.url("o")), home: home.path,
                              steerRoot: root)
            let c = \(chat)outbox: ComposerOutbox(url: temp.url("o")), home: home.path,
                              defaults: temp.defaults("chat"))
            let d = \(drafts))
            let e = \(drafts)defaults: temp.defaults("drafts"))
            let f = \(drafts)defaults: .standard)
            let g = Chat\(chat)), h = Composer\(drafts))
            """
        try example.write(to: folder.appendingPathComponent("ExampleTests.swift"), atomically: true, encoding: .utf8)
        #expect(try Self.uses(under: root).flagged == [3, 4, 5, 6, 8, 9, 13, 15].map { "Tests/VibeSwitcherTests/ExampleTests.swift:\($0)" })
    }
}
