import Foundation
import Testing

/// The security architecture document's numbered sections (`## S1.` to `## S12.`) keep their shape: every test a
/// `Held by:` line names exists under Tests/, every section says what it doesn't promise, and every section says
/// whether it is needed before the bootstrap (the stage 2 plan's Task 1, Step 1). A test renamed or removed while the
/// document still names it as holding a promise fails here, rather than leaving a promise held by nothing.
///
/// A name is a backticked token `Suite.test` (the suite being the type, or an extension of it, that declares
/// `func test(`); a backticked token with a `/` in it is a path, and paths stay out of backticks in `Held by:` lines.
/// The part of a `Held by:` line from `planned:` to the next `;` names tests not yet written and is skipped. The
/// unnumbered sections are reference and aren't read.
struct SecurityDocumentLintTests {
    static let repo = KeychainLintTests.repo
    static let documentPath = "docs/superpowers/specs/2026-11-13-v2-security-architecture.md"

    static func document() throws -> String {
        try String(contentsOf: repo.appendingPathComponent(documentPath), encoding: .utf8)
    }

    /// A numbered section: its number (`S6`) and its text, heading included, up to the next `## ` heading.
    struct Section {
        let number: String
        let text: String
    }

    static let numberedHeading = try! Regex(#"^## (S[0-9]+)\. "#)

    /// The numbered sections of `document`, outside fenced code blocks.
    static func sections(in document: String) -> [Section] {
        var found: [Section] = []
        var current: (number: String, lines: [String])?
        var fenced = false
        for line in document.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle() }
            if !fenced, line.hasPrefix("## ") {
                if let current { found.append(Section(number: current.number, text: current.lines.joined(separator: "\n"))) }
                current = nil
                if let match = line.firstMatch(of: numberedHeading), let number = match.output[1].substring {
                    current = (String(number), [line])
                }
                continue
            }
            current?.lines.append(line)
        }
        if let current { found.append(Section(number: current.number, text: current.lines.joined(separator: "\n"))) }
        return found
    }

    /// The text of a section's part that begins with a line starting `label` (`**Held by:**`), up to the next line
    /// that starts another bold part (`**`), label excluded; nil when the section has no such part.
    static func part(_ label: String, of section: Section) -> String? {
        var lines: [String]?
        for line in section.text.components(separatedBy: "\n") {
            if lines == nil {
                if line.hasPrefix(label) { lines = [String(line.dropFirst(label.count))] }
            } else if line.hasPrefix("**") {
                break
            } else {
                lines?.append(line)
            }
        }
        return lines?.joined(separator: "\n")
    }

    /// `text` without its `planned:` parts: from each `planned:` to the next `;`, or to the end.
    static func withoutPlanned(_ text: String) -> String {
        var rest = Substring(text)
        var kept = ""
        while let start = rest.range(of: "planned:") {
            kept += rest[..<start.lowerBound]
            rest = rest[start.upperBound...]
            guard let end = rest.firstIndex(of: ";") else { return kept }
            rest = rest[end...]
        }
        return kept + rest
    }

    /// The backticked tokens of `text`.
    static func backticked(_ text: String) -> [String] {
        text.split(separator: "`", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
    }

    static let testName = try! Regex(#"^([A-Z][A-Za-z0-9_]*)\.([a-z_][A-Za-z0-9_]*)$"#)

    /// The functions declared under Tests/, by the type (or extension) that declares them, from every Swift file.
    static func declaredFunctions() -> [String: Set<String>] {
        var index: [String: Set<String>] = [:]
        let tests = repo.appendingPathComponent("Tests")
        if let walk = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil) {
            for case let url as URL in walk where url.pathExtension == "swift" {
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (type, functions) in declaredFunctions(in: source) { index[type, default: []].formUnion(functions) }
            }
        }
        return index
    }

    static let typeDeclaration = try! Regex(
        #"^(\s*)(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final|open)\s+)*(?:struct|class|enum|actor|extension)\s+(?:[A-Za-z0-9_]+\.)*([A-Z][A-Za-z0-9_]*)"#)
    static let functionDeclaration = try! Regex(#"^(\s*)(?:@.*\s)?(?:[a-z]+\s+)*func\s+([A-Za-z_][A-Za-z0-9_]*)\s*[(<]"#)
    static let closingBrace = try! Regex(#"^(\s*)\}"#)

    /// The functions `source` declares, by the innermost type or extension around each, found by indentation: a
    /// declaration belongs to the nearest type above it that is indented less, and a type ends at a line indented as
    /// much or less that declares something or closes a brace. Other lines (`#if`, comments, a statement) are passed
    /// over, and a multi-line string's lines are indented at least as far as its closing quotes, so one can't end a
    /// type early.
    static func declaredFunctions(in source: String) -> [String: Set<String>] {
        var index: [String: Set<String>] = [:]
        var open: [(name: String, indent: Int)] = []
        func close(atOrAbove indent: Int) { while let last = open.last, last.indent >= indent { open.removeLast() } }
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("*") { continue }
            if let match = line.firstMatch(of: typeDeclaration), let name = match.output[2].substring {
                let indent = match.output[1].substring?.count ?? 0
                close(atOrAbove: indent)
                open.append((String(name), indent))
            } else if let match = line.firstMatch(of: functionDeclaration), let name = match.output[2].substring {
                let indent = match.output[1].substring?.count ?? 0
                close(atOrAbove: indent)
                if let owner = open.last { index[owner.name, default: []].insert(String(name)) }
            } else if let match = line.firstMatch(of: closingBrace) {
                close(atOrAbove: match.output[1].substring?.count ?? 0)
            }
        }
        return index
    }

    /// What's wrong with the `Held by:` lines of `document`'s numbered sections, given the functions declared under
    /// Tests/ by type: names that aren't declared, and paths in backticks.
    static func heldByProblems(in document: String, declared: [String: Set<String>]) -> [String] {
        var problems: [String] = []
        for section in sections(in: document) {
            guard let held = part("**Held by:**", of: section) else {
                problems.append("\(section.number): no **Held by:** part")
                continue
            }
            for token in backticked(withoutPlanned(held)) {
                if token.contains("/") {
                    problems.append("\(section.number): a path in backticks in Held by: `\(token)`")
                } else if let match = token.firstMatch(of: testName),
                          let suite = match.output[1].substring, let test = match.output[2].substring,
                          !(declared[String(suite)]?.contains(String(test)) ?? false) {
                    problems.append("\(section.number): `\(token)` isn't declared under Tests/")
                }
            }
        }
        return problems
    }

    /// The numbered sections of `document` with no `**Doesn't promise.**` part.
    static func sectionsWithoutDoesntPromise(in document: String) -> [String] {
        sections(in: document).filter { part("**Doesn't promise.**", of: $0) == nil }.map(\.number)
    }

    static let yesOrNo = try! Regex(#"^\s*(yes|no)\b"#)

    /// The numbered sections of `document` without a `**Before the bootstrap:**` line whose answer starts `yes` or `no`.
    static func sectionsWithoutWhenNeeded(in document: String) -> [String] {
        sections(in: document).filter { section in
            guard let answer = part("**Before the bootstrap:**", of: section) else { return true }
            return answer.firstMatch(of: yesOrNo) == nil
        }.map(\.number)
    }

    // MARK: The lints

    @Test func everyNamedTestExists() throws {
        let document = try Self.document()
        let declared = Self.declaredFunctions()
        #expect(Self.sections(in: document).map(\.number) == (1...12).map { "S\($0)" })
        let problems = Self.heldByProblems(in: document, declared: declared)
        #expect(problems == [], Comment(rawValue: "the security document's Held by lines:\n" + problems.joined(separator: "\n")
            + "\n(find the test's real name, or move it to planned:)"))

        // Shown failing on doctored copies: a test that doesn't exist, and a path in backticks.
        let missing = document.replacingOccurrences(of: "`ProcessSelfTests.tracerPidIsReadFromStatus`",
                                                    with: "`ProcessSelfTests.noSuchTestAnywhere`")
        #expect(missing != document)
        #expect(Self.heldByProblems(in: missing, declared: declared)
            == ["S6: `ProcessSelfTests.noSuchTestAnywhere` isn't declared under Tests/"])
        var path = document
        let first = try #require(path.range(of: "\n**Held by:** "))
        path.replaceSubrange(first, with: "\n**Held by:** `Tests/VibeCoreTests/SecurityDocumentLintTests.swift`, ")
        #expect(Self.heldByProblems(in: path, declared: declared)
            == ["S1: a path in backticks in Held by: `Tests/VibeCoreTests/SecurityDocumentLintTests.swift`"])
    }

    @Test func everySectionSaysWhatItDoesNotPromise() throws {
        let document = try Self.document()
        let missing = Self.sectionsWithoutDoesntPromise(in: document)
        #expect(missing == [], Comment(rawValue: "sections with no **Doesn't promise.** part: \(missing)"))

        // Shown failing on a doctored copy: S6 without its part.
        let doctored = document.replacingOccurrences(of: "**Doesn't promise.** The host's own start window",
                                                     with: "The host's own start window")
        #expect(doctored != document)
        #expect(Self.sectionsWithoutDoesntPromise(in: doctored) == ["S6"])
    }

    @Test func everySectionSaysWhenItIsNeeded() throws {
        let document = try Self.document()
        let missing = Self.sectionsWithoutWhenNeeded(in: document)
        #expect(missing == [], Comment(rawValue: "sections with no **Before the bootstrap:** yes or no: \(missing)"))

        // Shown failing on doctored copies: S12 answering neither, and S5 with no line.
        let neither = document.replacingOccurrences(of: "**Before the bootstrap:** no.", with: "**Before the bootstrap:** later.")
        #expect(neither != document)
        #expect(Self.sectionsWithoutWhenNeeded(in: neither) == ["S12"])
        let none = document.replacingOccurrences(of: "**Before the bootstrap:** yes.\n\n**Built in:** stage 2, Task 7",
                                                 with: "**Built in:** stage 2, Task 7")
        #expect(none != document)
        #expect(Self.sectionsWithoutWhenNeeded(in: none) == ["S5"])
    }

    @Test func theTestIndexFindsFunctionsByTheirType() {
        let source = """
        import Testing

        struct ATests {
            @Test func one() {}
            #if os(Linux)
            @Test("named") func two() async throws {
                let text = \"""
                    }
                    func inAString() {}
                    \"""
            }
            #endif
            struct Inner {
                func three<T>(_ t: T) {}
            }
            func four() {}
        }
        func free() {}
        extension ATests {
            static func five() {}
        }
        """
        let index = Self.declaredFunctions(in: source)
        // A string's lines are indented at least as far as its closing quotes, so its `}` closes no type; a `func` in
        // one is taken for a function of the type around it, which can only let a name pass, never fail one.
        #expect(index["ATests"] == ["one", "two", "four", "five", "inAString"])
        #expect(index["Inner"] == ["three"])
        #expect(Self.withoutPlanned("`A.b`; planned: `C.d` task 1; `E.f`") == "`A.b`; ; `E.f`")
    }
}
