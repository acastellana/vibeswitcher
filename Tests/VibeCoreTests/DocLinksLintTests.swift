import Foundation
import Testing

/// Every relative link in README.md and docs/**/*.md resolves: the file (or folder) it names is in the repository, and
/// an anchor (`#heading`) it names is a heading of that markdown file, as GitHub spells it. A guide that moves or a
/// heading that's renamed fails here rather than leaving a dead link for a reader.
struct DocLinksLintTests {
    static let repo = KeychainLintTests.repo

    /// `[text](target)` and `![alt](target)`, with an optional `"title"` after the target.
    static let link = try! Regex(#"!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#)
    /// An HTML image's `src="target"` or `srcset="target"` (a `<picture>` for light and dark).
    static let htmlSource = try! Regex(#"\b(?:src|srcset)="([^"\s]+)""#)

    /// The markdown files the check covers: README.md and everything under docs/.
    static func markdownFiles() -> [URL] {
        var files = [repo.appendingPathComponent("README.md")]
        let docs = repo.appendingPathComponent("docs")
        if let walk = FileManager.default.enumerator(at: docs, includingPropertiesForKeys: nil) {
            for case let url as URL in walk where url.pathExtension == "md" { files.append(url) }
        }
        return files
    }

    /// The link targets in `text`, outside fenced code blocks and inline code.
    static func targets(in text: String) -> [String] {
        var found: [String] = []
        var fenced = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle(); continue }
            guard !fenced else { continue }
            // Inline code spans hold commands and paths, not links.
            let prose = line.split(separator: "`", omittingEmptySubsequences: false).enumerated()
                .filter { $0.offset % 2 == 0 }.map { String($0.element) }.joined(separator: " ")
            for match in prose.matches(of: link) {
                if let target = match.output[1].substring { found.append(String(target)) }
            }
            for match in prose.matches(of: htmlSource) {
                if let target = match.output[1].substring { found.append(String(target)) }
            }
        }
        return found
    }

    /// A heading's anchor as GitHub makes it: lowercased, punctuation dropped (but `-` and `_`), spaces made `-`.
    static func anchor(_ heading: String) -> String {
        heading.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == " "
        }.map { $0 == " " ? "-" : String($0) }.joined()
    }

    /// An HTML anchor in the markdown: `<a id="e-19"></a>`.
    static let htmlAnchor = try! Regex(#"<a\s+(?:id|name)="([^"]+)""#)

    /// The anchors of `text`'s headings, outside fenced code blocks; a repeated one gets `-1`, `-2`… as on GitHub. Plus
    /// its HTML anchors.
    static func anchors(in text: String) -> Set<String> {
        var seen: [String: Int] = [:]
        var result: Set<String> = []
        var fenced = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle(); continue }
            guard !fenced else { continue }
            for match in line.matches(of: htmlAnchor) {
                if let id = match.output[1].substring { result.insert(id.lowercased()) }
            }
            guard line.hasPrefix("#") else { continue }
            let heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            guard !heading.isEmpty else { continue }
            let base = anchor(heading.replacingOccurrences(of: "`", with: ""))
            let count = seen[base, default: 0]
            seen[base] = count + 1
            result.insert(count == 0 ? base : "\(base)-\(count)")
        }
        return result
    }

    /// What's wrong with `target`, a link in `file`, or nil when it resolves (or isn't a relative link).
    static func problem(_ target: String, in file: URL) -> String? {
        let external = ["http://", "https://", "mailto:", "tel:", "data:"]
        if external.contains(where: target.lowercased().hasPrefix) { return nil }
        let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let pathPart = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let fragment = parts.count > 1 ? String(parts[1]) : nil
        let resolved = pathPart.isEmpty
            ? file
            : (pathPart.hasPrefix("/") ? repo.appendingPathComponent(String(pathPart.dropFirst()))
                                       : file.deletingLastPathComponent().appendingPathComponent(pathPart)).standardizedFileURL
        guard FileManager.default.fileExists(atPath: resolved.path) else { return "\(target): no such file" }
        if let fragment, !fragment.isEmpty, resolved.pathExtension == "md" {
            let text = (try? String(contentsOf: resolved, encoding: .utf8)) ?? ""
            if !anchors(in: text).contains(fragment.lowercased()) { return "\(target): no heading #\(fragment)" }
        }
        return nil
    }

    @Test func everyRelativeLinkInTheDocsResolves() throws {
        var broken: [String] = []
        for file in Self.markdownFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let name = file.path.replacingOccurrences(of: Self.repo.standardizedFileURL.path + "/", with: "")
            for target in Self.targets(in: text) {
                if let problem = Self.problem(target, in: file) { broken.append("\(name): \(problem)") }
            }
        }
        #expect(broken == [], Comment(rawValue: "dead links in the docs:\n" + broken.joined(separator: "\n")))
    }

    @Test func theCheckFindsADeadLinkAndAMissingHeading() {
        let readme = Self.repo.appendingPathComponent("README.md")
        #expect(Self.problem("docs/no-such-guide.md", in: readme) != nil)
        #expect(Self.problem("README.md#no-such-heading-anywhere", in: readme) != nil)
        #expect(Self.problem("https://example.com/x", in: readme) == nil)
        #expect(Self.targets(in: "`[a](nowhere.md)` and\n```\n[b](nowhere.md)\n```\n[c](here.md)") == ["here.md"])
        #expect(Self.targets(in: "<source srcset=\"d.png\">\n<img alt=\"x\" src=\"l.png\">") == ["d.png", "l.png"])
        #expect(Self.anchor("Security: the signing identity") == "security-the-signing-identity")
        #expect(Self.anchors(in: "# A\n## A\n```\n# B\n```\n<a id=\"e-19\"></a>**E-19**") == ["a", "a-1", "e-19"])
    }
}
