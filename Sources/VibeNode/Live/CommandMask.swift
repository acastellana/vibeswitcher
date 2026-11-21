import Foundation
import VibeCore

/// A command line as a page may see it (a session's `command`, a launch preset's in `session.presets`; the security
/// review of 2026-11-21): `Redaction.secrets` and `PushText.scrub` first, then, word by word as a shell splits them
/// (single and double quotes, backslashes, the node's own `'claude' '--api-key' '…'` form included):
///
/// - the value after a secret-ish flag (`--api-key VALUE`, `--token=VALUE`, `-p`… whose name holds key, token, secret,
///   pass, auth, credential, cookie, bearer or session-id), quoted or not;
/// - an environment word's value (`NAME=VALUE`) whose name holds KEY, TOKEN, SECRET, PASS, AUTH or CREDENTIAL;
/// - a URL's query value whose name is secret-ish (`?key=…`, `&access_token=…`), and a URL's `user:pass@`;
/// - a `user:pass` value after such a flag, as any value is.
///
/// Each is replaced by `•••`, its quotes kept; nothing else is changed. Over-masking a harmless value whose flag merely
/// sounds secret is the cost: a page never needs the value.
enum CommandMask {
    static let mask = "•••"
    /// What makes a flag's or a query's name secret-ish (lower case, dashes and underscores dropped).
    static let secretWords = ["key", "token", "secret", "pass", "auth", "credential", "cookie", "bearer", "sessionid", "signature", "sig"]
    /// What makes an environment word's name secret-ish (upper case, as written).
    static let envWords = ["KEY", "TOKEN", "SECRET", "PASS", "AUTH", "CREDENTIAL"]

    static func masked(_ command: String) -> String {
        let text = Redaction.secrets(in: PushText.scrub(command))
        let words = split(text)
        var cuts: [Range<String.Index>] = []
        var maskNext = false
        for word in words {
            let value = word.value
            if maskNext {
                maskNext = false
                if !value.hasPrefix("-") || value == "-" { cuts.append(word.content); continue }
            }
            if value.hasPrefix("-"), !value.hasPrefix("---") {
                let name = value.drop { $0 == "-" }
                if let equals = name.firstIndex(of: "=") {
                    if secretish(String(name[..<equals])) { cuts.append(contentAfterEquals(word)) }
                } else if secretish(String(name)) {
                    maskNext = true
                }
                continue
            }
            if let equals = value.firstIndex(of: "="), value.first?.isLetter == true || value.first == "_",
               value[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                let name = value[..<equals].uppercased()
                if envWords.contains(where: name.contains) { cuts.append(contentAfterEquals(word)) }
            }
        }
        var out = text
        // Query values and URL credentials, anywhere in the text not already cut.
        for range in queryValues(in: text) where !cuts.contains(where: { $0.overlaps(range) }) { cuts.append(range) }
        for range in cuts.sorted(by: { $0.lowerBound > $1.lowerBound }) where !range.isEmpty { out.replaceSubrange(range, with: mask) }
        return out
    }

    static func secretish(_ name: String) -> Bool {
        let folded = name.lowercased().filter { $0 != "-" && $0 != "_" }
        guard !folded.isEmpty else { return false }
        return secretWords.contains { folded.contains($0) } || folded == "p"
    }

    /// One word of a command line: its text as a shell reads it (`value`), and the range in the line its characters
    /// take, quotes aside (`content`: from just inside its first quote, or its first character, to its end).
    struct Word {
        var value: String
        var whole: Range<String.Index>
        var content: Range<String.Index>
        /// The line it is in.
        var line: String
    }

    /// The range after the first `=` of a word's characters as written (quotes and all, the value's own).
    static func contentAfterEquals(_ word: Word) -> Range<String.Index> {
        // The `=` is in the line within the word's range; what follows it to the word's end, a closing quote left.
        let line = word.line
        guard let equals = line[word.whole].firstIndex(of: "=") else { return word.content }
        var end = word.whole.upperBound
        if end > line.index(after: equals), let last = line[..<end].last, last == "'" || last == "\"" { end = line.index(before: end) }
        var start = line.index(after: equals)
        if start < end, line[start] == "'" || line[start] == "\"" { start = line.index(after: start) }
        return start..<max(start, end)
    }

    /// Splits a line as a shell would into words (quotes and backslashes; no expansion), each with its ranges.
    static func split(_ line: String) -> [Word] {
        var words: [Word] = []
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex, line[index].isWhitespace { index = line.index(after: index) }
            guard index < line.endIndex else { break }
            let start = index
            var value = ""
            var contentStart: String.Index?
            var contentEnd = index
            while index < line.endIndex, !line[index].isWhitespace {
                let character = line[index]
                if character == "'" || character == "\"" {
                    let quote = character
                    index = line.index(after: index)
                    if contentStart == nil { contentStart = index }
                    while index < line.endIndex, line[index] != quote {
                        if quote == "\"", line[index] == "\\", line.index(after: index) < line.endIndex { index = line.index(after: index) }
                        value.append(line[index])
                        index = line.index(after: index)
                    }
                    contentEnd = index
                    if index < line.endIndex { index = line.index(after: index) }
                } else if character == "\\", line.index(after: index) < line.endIndex {
                    if contentStart == nil { contentStart = index }
                    index = line.index(after: index)
                    value.append(line[index])
                    index = line.index(after: index)
                    contentEnd = index
                } else {
                    if contentStart == nil { contentStart = index }
                    value.append(character)
                    index = line.index(after: index)
                    contentEnd = index
                }
            }
            words.append(Word(value: value, whole: start..<index, content: (contentStart ?? start)..<max(contentStart ?? start, contentEnd), line: line))
        }
        return words
    }

    /// The ranges of URL query values with a secret-ish name, and of `user:pass` before a URL's host.
    static func queryValues(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let stops: Set<Character> = ["&", "#", " ", "'", "\"", "\t", "\n"]
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "?" || character == "&" {
                let nameStart = text.index(after: index)
                var cursor = nameStart
                while cursor < text.endIndex, text[cursor] != "=", !stops.contains(text[cursor]), text[cursor] != "?" { cursor = text.index(after: cursor) }
                if cursor < text.endIndex, text[cursor] == "=", secretish(String(text[nameStart..<cursor])) {
                    let valueStart = text.index(after: cursor)
                    var end = valueStart
                    while end < text.endIndex, !stops.contains(text[end]) { end = text.index(after: end) }
                    if end > valueStart { ranges.append(valueStart..<end) }
                    index = end
                    continue
                }
            }
            index = text.index(after: index)
        }
        // `scheme://user:pass@host`: the password.
        var search = text.startIndex
        while let scheme = text.range(of: "://", range: search..<text.endIndex) {
            var end = scheme.upperBound
            while end < text.endIndex, !stops.contains(text[end]), text[end] != "/", text[end] != "@" { end = text.index(after: end) }
            if end < text.endIndex, text[end] == "@", let colon = text[scheme.upperBound..<end].firstIndex(of: ":") {
                let start = text.index(after: colon)
                if start < end { ranges.append(start..<end) }
            }
            search = scheme.upperBound
        }
        return ranges
    }
}
