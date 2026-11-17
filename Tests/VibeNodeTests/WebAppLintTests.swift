import Foundation
import Testing

/// Nothing an agent wrote is markup (the live plan's Global Constraints and Security table; Review Focus 6): no file the
/// web page runs, under `WebApp/` (its modules in `WebApp/js/`), builds markup or code from text. Refused, anywhere in
/// a file, comments included (a comment that names one is named another way): `innerHTML`, `outerHTML`,
/// `insertAdjacentHTML`, `document.write`/`writeln`, `createContextualFragment`, `DOMParser`, `setHTML` and
/// `setHTMLUnsafe`, `parseHTMLUnsafe`, `srcdoc`, `eval(`, `Function(` (with `new` or without), `setTimeout`/
/// `setInterval` given a string, `setAttribute` of an `on…` handler, a `javascript:` address; and in a page or an
/// image (`.html`, `.svg`), a `<script>` without `src` and an inline `on…=` handler.
///
/// Not the page's: the Node tests' folders (`WebApp/test/`, `WebApp/tests/`), which hold the client's own lint and
/// name what it refuses. They may hold `*.test.mjs` files alone, so nothing the page runs hides there.
struct WebAppLintTests {
    /// Held by the suite: a local `Scratch` may be released after its last use, and its folder removed with it.
    private let scratch = Scratch()
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let folder = "WebApp"
    /// The extensions the rule reads.
    static let scripts: Set<String> = ["js", "mjs", "cjs"]
    static let pages: Set<String> = ["html", "htm", "svg", "xhtml"]
    /// The Node tests' folders, never served: `*.test.mjs` only.
    static let testFolders = ["WebApp/test/", "WebApp/tests/"]

    struct Finding: Equatable, CustomStringConvertible {
        var path: String
        var line: Int
        var form: String
        var description: String { "\(path):\(line): \(form)" }
    }

    /// The forms, each with what it matches, in any file the page runs.
    static let forms: [(name: String, pattern: String)] = [
        ("innerHTML", #"innerHTML"#), ("outerHTML", #"outerHTML"#), ("insertAdjacentHTML", #"insertAdjacentHTML"#),
        ("document.write", #"\bdocument\s*\.\s*write"#), ("createContextualFragment", #"createContextualFragment"#),
        ("DOMParser", #"DOMParser"#), ("setHTML", #"\bsetHTML(Unsafe)?\b"#), ("parseHTMLUnsafe", #"parseHTMLUnsafe"#),
        ("srcdoc", #"(?i)srcdoc"#), ("eval", #"\beval\s*\("#), ("Function", #"\bFunction\s*\("#),
        ("a string run later", #"\bset(Timeout|Interval)\s*\(\s*['"`]"#),
        ("an on… attribute set", #"(?i)setAttribute\s*\(\s*['"`]on|setAttributeNS\s*\([^,]*,\s*['"`]on"#), ("javascript:", #"(?i)javascript\s*:"#),
        ("execScript", #"execScript"#),
    ]

    /// The forms only a page or an image has.
    static let pageForms: [(name: String, pattern: String)] = [
        ("an inline script", #"(?i)<script(?![^>]*\bsrc\s*=)[^>]*>"#),
        ("an inline handler", #"(?i)<[^>]*\son[a-z]+\s*="#),
    ]

    /// Every finding in `text`, a file at `path` (its extension says which forms apply).
    static func findings(in text: String, path: String) -> [Finding] {
        let ext = (path as NSString).pathExtension.lowercased()
        let applied = (scripts.contains(ext) || pages.contains(ext) ? forms : []) + (pages.contains(ext) ? pageForms : [])
        var found: [Finding] = []
        for form in applied {
            guard let regex = try? NSRegularExpression(pattern: form.pattern, options: [.dotMatchesLineSeparators]) else { continue }
            let whole = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text) else { continue }
                let line = text[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                found.append(Finding(path: path, line: line, form: form.name))
            }
        }
        return found.sorted { ($0.path, $0.line, $0.form) < ($1.path, $1.line, $1.form) }
    }

    /// Every file under `root`'s `WebApp/`, relative to `root`.
    static func files(under root: URL) -> [String] {
        let base = root.appendingPathComponent(folder)
        guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var paths: [String] = []
        for case let url as URL in walk where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            paths.append(folder + "/" + url.path.dropFirst(base.path.count + 1))
        }
        return paths.sorted()
    }

    /// What breaks the rule under `root`: every finding in the files the page runs, and each file in a tests' folder
    /// that isn't a Node test.
    static func check(_ root: URL) -> [String] {
        var broken: [String] = []
        for path in files(under: root) {
            if testFolders.contains(where: path.hasPrefix) {
                if !path.hasSuffix(".test.mjs") { broken.append("\(path): a tests' folder holds Node tests (*.test.mjs) alone") }
                continue
            }
            let ext = (path as NSString).pathExtension.lowercased()
            guard scripts.contains(ext) || pages.contains(ext) else { continue }
            guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(path).path) else {
                broken.append("\(path): unreadable")
                continue
            }
            broken += findings(in: String(decoding: data, as: UTF8.self), path: path).map(\.description)
        }
        return broken
    }

    @Test func noFileBuildsMarkupFromText() {
        let broken = Self.check(Self.repo)
        #expect(broken.isEmpty, "markup or code built from text in WebApp/ (use document.createElement and textContent): \(broken.joined(separator: "\n"))")
    }

    /// The rule finds each form, in a scratch copy of the page's files with one added (never the tree itself), and the
    /// copy as it is passes.
    @Test func theRuleFindsEachForm() throws {
        let root = scratch.url("webapp-lint")
        let js = root.appendingPathComponent("WebApp/js")
        try FileManager.default.createDirectory(at: js, withIntermediateDirectories: true)
        let clean = """
            // Rows are made of elements and text nodes.
            import { words } from './words.js';
            export function row(session) {
              const item = document.createElement('li');
              item.textContent = session.label;
              item.addEventListener('click', () => select(session.id));
              item.onclick = select;
              setTimeout(() => item.classList.add('shown'), 0);
              const html = 'text/html';
              return item;
            }
            """
        let page = """
            <!doctype html>
            <meta charset="utf-8">
            <script type="module" src="app.js"></script>
            <main id="app"></main>
            """
        func write(_ text: String, _ name: String) throws {
            try Data(text.utf8).write(to: root.appendingPathComponent("WebApp/" + name))
        }
        try write(clean, "js/row.js")
        try write(page, "index.html")
        #expect(Self.check(root).isEmpty, "\(Self.check(root))")
        // The Node tests' folder may name the forms, in a Node test.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("WebApp/tests"), withIntermediateDirectories: true)
        try write("assert.doesNotMatch(source, /innerHTML/);", "tests/lint.test.mjs")
        #expect(Self.check(root).isEmpty, "\(Self.check(root))")
        try write("export const x = 1;", "tests/helper.js")
        #expect(Self.check(root) == ["WebApp/tests/helper.js: a tests' folder holds Node tests (*.test.mjs) alone"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("WebApp/tests/helper.js"))

        let scriptCases: [(String, String)] = [
            ("innerHTML", "item.innerHTML = session.label;"), ("innerHTML", "// never innerHTML here"),
            ("outerHTML", "item.outerHTML = text;"), ("insertAdjacentHTML", "item.insertAdjacentHTML('beforeend', text);"),
            ("document.write", "document.write(text);"), ("document.write", "document.writeln(text);"),
            ("createContextualFragment", "document.createRange().createContextualFragment(text);"),
            ("DOMParser", "new DOMParser().parseFromString(text, 'text/html');"), ("setHTML", "item.setHTMLUnsafe(text);"),
            ("setHTML", "item.setHTML(text);"), ("parseHTMLUnsafe", "Document.parseHTMLUnsafe(text);"),
            ("srcdoc", "frame.srcdoc = text;"), ("eval", "eval(text);"), ("eval", "window.eval (text);"),
            ("Function", "new Function(text)();"), ("Function", "Function('return ' + text)();"),
            ("a string run later", "setTimeout('go()', 10);"), ("a string run later", "setInterval(`tick()`, 10);"),
            ("an on… attribute set", "item.setAttribute('onclick', text);"), ("javascript:", "link.href = 'javascript:go()';"),
            ("execScript", "window.execScript(text);"),
        ]
        for (form, line) in scriptCases {
            try write(clean + "\n" + line + "\n", "js/row.js")
            let found = Self.findings(in: clean + "\n" + line + "\n", path: "WebApp/js/row.js").map(\.form)
            #expect(found.contains(form), "\(line): \(found)")
            #expect(Self.check(root).contains { $0.hasPrefix("WebApp/js/row.js:12: ") }, "\(line): \(Self.check(root))")
        }
        try write(clean, "js/row.js")
        let pageCases: [(String, String)] = [
            ("an inline script", "<script>go()</script>"), ("an inline script", "<SCRIPT type=\"module\">go()</SCRIPT>"),
            ("an inline handler", "<img src=\"x.png\" onerror=\"go()\">"), ("an inline handler", "<body\nonload='go()'>"),
            ("javascript:", "<a href=\"javascript:go()\">x</a>"), ("innerHTML", "<p>innerHTML</p>"),
        ]
        for (form, line) in pageCases {
            try write(page + "\n" + line + "\n", "index.html")
            #expect(Self.findings(in: page + "\n" + line + "\n", path: "WebApp/index.html").map(\.form).contains(form), "\(line)")
            #expect(!Self.check(root).isEmpty, "\(line)")
        }
        // An SVG is a page too.
        try write(page, "index.html")
        try write("<svg xmlns=\"http://www.w3.org/2000/svg\"><script>go()</script></svg>", "icon.svg")
        #expect(Self.check(root).contains { $0.hasPrefix("WebApp/icon.svg:1: an inline script") }, "\(Self.check(root))")
    }
}
