import Foundation
import VibeCore

/// A command line as a page may see it (a session's `command`, a launch preset's in `session.presets`; the security
/// review of 2026-11-21): `Redaction.secrets` and `PushText.scrub` first, then, word by word as a shell splits them
/// (single and double quotes, backslashes, the node's own `'claude' '--api-key' '…'` form included):
///
/// - the word after a secret-ish flag written without `=` (`--api-key VALUE`, `-p VALUE`… whose name holds key, token,
///   secret, pass, auth, credential, cookie, bearer or session-id; `--user` and `-u` too), always, whatever it starts
///   with; the value after its `=` (`--token=VALUE`), quoted or not, however many dashes it has;
/// - a short flag's attached value, looked at first: of a secret-ish letter (`p`, `k`, `t`, `u`): `-pSECRET`,
///   `-uuser:pass`; a credential header (`-HAuthorization: …`, `-H'X-Api-Key: …'`): what follows its colon;
/// - a header's value after `-H` or `--header` when the header holds key, token, auth, bearer or cookie;
/// - an environment word's value (`NAME=VALUE`) whose name holds KEY, TOKEN, SECRET, PASS, AUTH or CREDENTIAL, and in
///   any environment word a `user:pass` value or a `user:pass@host`'s password;
/// - a `user:pass`-shaped word anywhere (what follows its first colon), a scheme-less `user:pass@host`'s password; a
///   URL's query value whose name is secret-ish (`?key=…`, `&access_token=…`), and a URL's `user:pass@`.
///
/// Each is replaced by `•••`, its quotes kept; nothing else is changed. Over-masking a harmless value whose flag merely
/// sounds secret (or a `host:port`) is the cost: a page never needs the value.
enum CommandMask {
    static let mask = "•••"
    /// What makes a flag's or a query's name secret-ish (lower case, dashes and underscores dropped).
    static let secretWords = ["key", "token", "secret", "pass", "auth", "credential", "cookie", "bearer", "sessionid", "signature", "sig"]
    /// What makes an environment word's name secret-ish (upper case, as written).
    static let envWords = ["KEY", "TOKEN", "SECRET", "PASS", "AUTH", "CREDENTIAL"]
    /// The flags whose next word is a user's credentials (`curl -u user:pass`).
    static let userFlags: Set<String> = ["user", "u"]
    /// The flags whose next word is a header, masked when it holds one of `headerWords`.
    static let headerFlags: Set<String> = ["H", "header"]
    static let headerWords = ["key", "token", "auth", "bearer", "cookie", "secret", "pass"]
    /// The short flags whose attached value is masked (`-pSECRET`).
    static let shortSecret: Set<Character> = ["p", "k", "t", "u"]

    private enum Next { case always, header }

    static func masked(_ command: String) -> String {
        let text = Redaction.secrets(in: PushText.scrub(command))
        let words = split(text)
        var cuts: [Range<String.Index>] = []
        var next: Next?
        for word in words {
            let value = word.value
            if let pending = next {
                next = nil
                switch pending {
                case .always: cuts.append(word.content)
                case .header: if headerish(value) { cuts.append(afterColon(word) ?? word.content) }
                }
                continue
            }
            if value.hasPrefix("-"), value.count > 1 {
                let name = value.drop { $0 == "-" }
                let dashes = value.count - name.count
                if let equals = name.firstIndex(of: "=") {
                    let flag = String(name[..<equals])
                    if secretish(flag) || userFlags.contains(flag) || (headerFlags.contains(flag) && headerish(String(name[name.index(after: equals)...]))) {
                        cuts.append(contentAfterEquals(word))
                    }
                } else {
                    // A short flag's attached value is looked at first: `-HAuthorization: …` (a credential header: what
                    // follows its colon, or all of it), `-pSECRET`, `-uuser:pass`.
                    let short = dashes == 1 && name.count > 1 ? name.first : nil
                    if short == "H", headerish(String(name.dropFirst())) {
                        // A credential header attached: what follows its colon; with nothing there (`-HAuthorization:`
                        // `Bearer …`, `-HX-Api-Key=abc`, `-HTokenabc`), all of it and the next word too (over-masking).
                        if let range = attachedAfterColon(word) {
                            cuts.append(range)
                        } else {
                            cuts.append(attached(word))
                            next = .always
                        }
                    } else {
                        if let short, short != "H", shortSecret.contains(short) { cuts.append(attached(word)) }
                        // A word that (also) reads as a secret-ish long flag (`-password`): the word after it too
                        // (over-masking, not under).
                        if secretish(String(name)) || userFlags.contains(String(name)) {
                            next = .always
                        } else if headerFlags.contains(String(name)) {
                            next = .header
                        }
                    }
                }
                continue
            }
            if let equals = value.firstIndex(of: "="), value.first?.isLetter == true || value.first == "_",
               value[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                let name = value[..<equals].uppercased()
                let assigned = String(value[value.index(after: equals)...])
                if envWords.contains(where: name.contains) {
                    cuts.append(contentAfterEquals(word))
                } else if let range = atCredentials(word, after: "=") {
                    cuts.append(range)
                } else if userPass(assigned), let range = afterColon(word, after: "=") {
                    cuts.append(range)
                }
                continue
            }
            if let range = atCredentials(word) {
                cuts.append(range)
            } else if userPass(value), let range = afterColon(word) {
                cuts.append(range)
            }
        }
        var out = text
        // Query values and URL credentials, anywhere in the text not already cut.
        for range in queryValues(in: text) where !cuts.contains(where: { $0.overlaps(range) }) { cuts.append(range) }
        for range in cuts.sorted(by: { $0.lowerBound > $1.lowerBound }) where !range.isEmpty { out.replaceSubrange(range, with: mask) }
        return out
    }

    /// A header holding a secret-ish word.
    static func headerish(_ value: String) -> Bool {
        let folded = value.lowercased()
        return headerWords.contains { folded.contains($0) }
    }

    /// `user:pass`-shaped: something, a colon, something, with no space, slash or `@`, and not a URL.
    static func userPass(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":"), colon > value.startIndex, value.index(after: colon) < value.endIndex else { return false }
        return !value.contains("://") && !value.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" })
    }

    /// `user:pass@host` with no scheme (`postgres:pw@db`, `DB=bob:pw@host:5432`): the range from just after its first
    /// colon to its `@`, as written in the line (in an env word, the value after `after`). Nil for anything else (a URL
    /// is the query rule's; `git@host:org/repo` has its colon after the `@`).
    static func atCredentials(_ word: Word, after: Character? = nil) -> Range<String.Index>? {
        let line = word.line
        var start = word.content.lowerBound
        if let after {
            guard let mark = line[word.content].firstIndex(of: after) else { return nil }
            start = line.index(after: mark)
        }
        let part = line[start..<word.content.upperBound]
        guard !part.contains("://"), let at = part.firstIndex(of: "@"), let colon = part[..<at].firstIndex(of: ":"),
              colon > part.startIndex, line.index(after: colon) < at,
              !part[..<at].contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        return line.index(after: colon)..<at
    }

    /// A short flag's attached value after its colon (`-H'X-Api-Key: abc'` → `abc`), as written in the line.
    static func attachedAfterColon(_ word: Word) -> Range<String.Index>? {
        let rest = attached(word)
        let line = word.line
        guard let colon = line[rest].firstIndex(of: ":") else { return nil }
        var start = line.index(after: colon)
        while start < rest.upperBound, line[start] == " " { start = line.index(after: start) }
        return start < rest.upperBound ? start..<rest.upperBound : nil
    }

    /// What follows a word's first colon (and the spaces after it), as written in the line; with `after`, the first
    /// colon after that character (an env word's value).
    static func afterColon(_ word: Word, after: Character? = nil) -> Range<String.Index>? {
        let line = word.line
        var from = word.content.lowerBound
        if let after {
            guard let mark = line[word.content].firstIndex(of: after) else { return nil }
            from = line.index(after: mark)
        }
        guard let colon = line[from..<word.content.upperBound].firstIndex(of: ":") else { return nil }
        var start = line.index(after: colon)
        while start < word.content.upperBound, line[start] == " " { start = line.index(after: start) }
        return start < word.content.upperBound ? start..<word.content.upperBound : nil
    }

    /// A short flag's attached value: the word after its dash and letter, as written.
    static func attached(_ word: Word) -> Range<String.Index> {
        let line = word.line
        var start = word.content.lowerBound
        var skipped = 0
        while start < word.content.upperBound, skipped < 2 {
            if !["'", "\"", "\\"].contains(line[start]) { skipped += 1 }
            start = line.index(after: start)
        }
        return start..<max(start, word.content.upperBound)
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
