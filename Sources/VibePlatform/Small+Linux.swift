#if os(Linux)
import Foundation

/// One line of inline markdown as its words, where Foundation has no markdown parser: `Platform.plainInline` on
/// Linux. It follows CommonMark's rules for what it reads, which are the rules of the parser the Mac's Foundation
/// uses, so the two agree on it:
///
/// - emphasis and strong emphasis (`*a*`, `_a_`, `**a**`, `__a__`), by CommonMark's delimiter rules: a mark with
///   spaces on both sides, an underscore inside a word and a mark with no partner stay as they are;
/// - code spans (`` `a` ``, ``` ``a`b`` ```), whose text is taken as it is;
/// - inline links (`[text](address)`, with a title or an address in angle brackets), as their text;
/// - a backslash before a punctuation mark, as that mark.
///
/// Everything else is text, a block's mark too ("# ", "> ", "- ": only a line's inline markdown is read, as on the
/// Mac). It says nil, "not sure", for what it has no rules for, where the Mac's parser would do something this
/// doesn't know to do: more than one line, an image, an HTML tag or `<address>`, an entity (`&amp;`), strikethrough
/// (two runs of `~`, or one beside emphasis marks), a footnote (`[^1]`), a bare address with marks in it
/// (`https://example.com/_a_`), and a text over `limit` characters.
enum InlineMarkdown {
    /// The longest text read. A line of a chat or a tool's title is far under it, and a parse stays quick.
    static let limit = 16_384

    static func plain(_ markdown: String) -> String? {
        let source = Array(markdown.unicodeScalars)
        guard source.count <= limit, !markdown.contains(where: \.isNewline) else { return nil }
        var parser = Parser(source: source)
        return parser.plain()
    }

    private struct Parser {
        /// What the result is joined from: text, or a run of emphasis marks with those of them that are still text.
        enum Piece {
            case text(String)
            case marks(Unicode.Scalar, Int)
        }

        /// A run of `*` or `_` that may still open or close emphasis (CommonMark's delimiter stack).
        struct Run {
            /// Its place in `pieces`.
            let piece: Int
            let mark: Unicode.Scalar
            /// How many of its marks no emphasis has taken yet.
            var count: Int
            let original: Int
            let opens: Bool
            let closes: Bool
        }

        /// A "[" that may still begin a link's text.
        struct Bracket {
            let piece: Int
            /// How many `runs` there were before it: the ones after are inside the link's text.
            let runs: Int
            /// False once a link was made after it: a link holds no link.
            var active = true
        }

        let source: [Unicode.Scalar]
        var at = 0
        var pieces: [Piece] = []
        var pending = ""
        var runs: [Run] = []
        var brackets: [Bracket] = []
        var tildeRuns = 0
        /// Once a search for a code span's end has read to the end of the text: where the last run of backticks of
        /// each length begins, so a later search that can't succeed isn't made.
        var lastBackticks: [Int: Int]?

        mutating func plain() -> String? {
            while at < source.count {
                let scalar = source[at]
                let next = at + 1 < source.count ? source[at + 1] : nil
                switch scalar {
                case "\\":
                    if let next, Self.isASCIIPunctuation(next) {
                        pending.unicodeScalars.append(next)
                        at += 2
                    } else {
                        take(1)
                    }
                case "`":
                    codeSpan()
                case "*", "_":
                    guard marks() else { return nil }
                case "[":
                    if next == "^" { return nil }
                    flush()
                    brackets.append(Bracket(piece: pieces.count, runs: runs.count))
                    pieces.append(.text("["))
                    at += 1
                case "]":
                    closeBracket()
                case "!":
                    if next == "[" { return nil }
                    take(1)
                case "<":
                    if let next, next.isASCII, next.properties.isAlphabetic || next == "/" || next == "!" || next == "?" { return nil }
                    take(1)
                case "&":
                    if entityBegins() { return nil }
                    take(1)
                case "~":
                    tildeRuns += 1
                    if tildeRuns > 1 { return nil }
                    take(runLength())
                case ":", "w":
                    if addressBegins(), addressHoldsMarks() { return nil }
                    take(1)
                default:
                    take(1)
                }
            }
            flush()
            resolve(from: 0)
            return pieces.map(Self.text).joined()
        }

        // MARK: Text

        /// The next `count` characters are text.
        mutating func take(_ count: Int) {
            pending.unicodeScalars.append(contentsOf: source[at..<(at + count)])
            at += count
        }

        mutating func flush() {
            guard !pending.isEmpty else { return }
            pieces.append(.text(pending))
            pending = ""
        }

        /// How many times the character at `index` stands there in a row.
        func runLength(at index: Int? = nil) -> Int {
            let start = index ?? at
            var end = start
            while end < source.count, source[end] == source[start] { end += 1 }
            return end - start
        }

        static func text(_ piece: Piece) -> String {
            switch piece {
            case .text(let text): return text
            case .marks(let mark, let count): return String(repeating: String(Character(mark)), count: count)
            }
        }

        /// "&name;", "&#123;" or "&#x1F;" at the cursor.
        func entityBegins() -> Bool {
            var index = at + 1
            func run(_ allowed: (Unicode.Scalar) -> Bool, upTo most: Int) -> Int {
                var count = 0
                while index < source.count, count < most, allowed(source[index]) {
                    index += 1
                    count += 1
                }
                return count
            }
            func digit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }
            func letter(_ scalar: Unicode.Scalar) -> Bool { ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) }
            if index < source.count, source[index] == "#" {
                index += 1
                if index < source.count, source[index] == "x" || source[index] == "X" {
                    index += 1
                    guard run({ digit($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) }, upTo: 6) > 0 else { return false }
                } else {
                    guard run(digit, upTo: 7) > 0 else { return false }
                }
            } else {
                guard run({ letter($0) || digit($0) }, upTo: 32) > 0, letter(source[at + 1]) else { return false }
            }
            return index < source.count && source[index] == ";"
        }

        /// A bare address at the cursor, which GitHub's markdown (the Mac's parser is built on it) makes a link by
        /// itself: the ":" of "http://", "https://" or "ftp://", or the "w" of a "www." that begins a word.
        func addressBegins() -> Bool {
            func follows(_ text: String) -> Bool {
                let scalars = Array(text.unicodeScalars)
                return at + scalars.count <= source.count && Array(source[at..<(at + scalars.count)]) == scalars
            }
            if source[at] == ":" {
                var start = at
                while start > 0, source[start - 1].isASCII, source[start - 1].properties.isAlphabetic { start -= 1 }
                let scheme = String(String.UnicodeScalarView(source[start..<at])).lowercased()
                return follows("://") && ["http", "https", "ftp"].contains(scheme)
            }
            return follows("www.") && (at == 0 || Self.isSpace(source[at - 1]) || "*_~(".unicodeScalars.contains(source[at - 1]))
        }

        /// Whether the address at the cursor (to the next space or "<", less the punctuation that ends a sentence)
        /// holds a character read here as markdown. With such a parser the whole address is a link's text and its
        /// marks are text; by CommonMark alone they are marks. Which of the two the Mac does isn't known here.
        func addressHoldsMarks() -> Bool {
            var end = at
            while end < source.count, !Self.isSpace(source[end]), source[end] != "<" { end += 1 }
            while end > at, "?!.,:*_~'\"".unicodeScalars.contains(source[end - 1]) { end -= 1 }
            return source[at..<end].contains { "\\`*_[]~&".unicodeScalars.contains($0) }
        }

        // MARK: Code spans

        /// A run of backticks: with a run of the same length after it, what is between them is text as it stands
        /// (less one space at each end when both are there and it isn't all spaces); with none, the backticks are
        /// text.
        mutating func codeSpan() {
            let length = runLength()
            let start = at + length
            if let lastBackticks, (lastBackticks[length] ?? -1) < start {
                take(length)
                return
            }
            var seen: [Int: Int] = [:]
            var index = start
            while index < source.count {
                guard source[index] == "`" else {
                    index += 1
                    continue
                }
                let closing = runLength(at: index)
                if closing == length {
                    var inside = source[start..<index]
                    if inside.count >= 2, inside.first == " ", inside.last == " ", inside.contains(where: { $0 != " " }) {
                        inside = inside.dropFirst().dropLast()
                    }
                    pending.unicodeScalars.append(contentsOf: inside)
                    at = index + closing
                    return
                }
                seen[closing] = index
                index += closing
            }
            lastBackticks = seen
            take(length)
        }

        // MARK: Emphasis

        /// A run of `*` or `_`, with whether it may open and close emphasis: CommonMark's left- and right-flanking
        /// rules, from the characters on its two sides (a line's start and end count as spaces). False, "not sure",
        /// with a "~" beside it: a parser that reads strikethrough looks past the tilde for the run's neighbour.
        mutating func marks() -> Bool {
            let mark = source[at]
            let length = runLength()
            let before: Unicode.Scalar = at > 0 ? source[at - 1] : " "
            let after: Unicode.Scalar = at + length < source.count ? source[at + length] : " "
            if before == "~" || after == "~" { return false }
            let left = !Self.isSpace(after) && (!Self.isPunctuation(after) || Self.isSpace(before) || Self.isPunctuation(before))
            let right = !Self.isSpace(before) && (!Self.isPunctuation(before) || Self.isSpace(after) || Self.isPunctuation(after))
            // An underscore inside a word is part of the word.
            let opens = mark == "_" ? left && (!right || Self.isPunctuation(before)) : left
            let closes = mark == "_" ? right && (!left || Self.isPunctuation(after)) : right
            flush()
            runs.append(Run(piece: pieces.count, mark: mark, count: length, original: length, opens: opens, closes: closes))
            pieces.append(.marks(mark, length))
            at += length
            return true
        }

        /// CommonMark's "process emphasis" for the runs from `bottom` on: each run that may close takes the nearest
        /// run before it that may open with the same mark, two marks of each for strong emphasis, else one; the runs
        /// between them are text from then on. The marks a run is left with are text.
        mutating func resolve(from bottom: Int) {
            // For a mark, a length mod 3 and whether the closer opens too: the piece before which no opener is
            // (a closer found none), so the next such closer doesn't look there again.
            var floors: [Int: Int] = [:]
            var closer = bottom
            while closer < runs.count {
                let closing = runs[closer]
                guard closing.closes else {
                    closer += 1
                    continue
                }
                let key = (closing.mark == "_" ? 0 : 6) + (closing.opens ? 3 : 0) + closing.original % 3
                let floor = floors[key] ?? -1
                var opener = closer - 1
                var found = false
                while opener >= bottom, runs[opener].piece >= floor {
                    let opening = runs[opener]
                    // The rule of three: when one of the two could do both, their lengths don't add up to a multiple
                    // of 3 unless both are one.
                    let barred = (opening.closes || closing.opens) && (opening.original + closing.original) % 3 == 0
                        && !(opening.original % 3 == 0 && closing.original % 3 == 0)
                    if opening.mark == closing.mark, opening.opens, !barred {
                        found = true
                        break
                    }
                    opener -= 1
                }
                guard found else {
                    floors[key] = closing.piece
                    if closing.opens { closer += 1 } else { runs.remove(at: closer) }
                    continue
                }
                let used = runs[opener].count >= 2 && runs[closer].count >= 2 ? 2 : 1
                for index in [opener, closer] {
                    runs[index].count -= used
                    pieces[runs[index].piece] = .marks(runs[index].mark, runs[index].count)
                }
                runs.removeSubrange((opener + 1)..<closer)
                closer = opener + 1
                if runs[opener].count == 0 {
                    runs.remove(at: opener)
                    closer -= 1
                }
                // A closer with marks left looks for another opener.
                if runs[closer].count == 0 { runs.remove(at: closer) }
            }
        }

        // MARK: Links

        /// A "]": with a "[" before it that may begin a link and "(address)" after it, what is between the brackets
        /// becomes the link's text, its emphasis its own. Else it is text: with no line of definitions, "[a]" and
        /// "[a][b]" lead nowhere.
        mutating func closeBracket() {
            guard let opener = brackets.popLast(), opener.active, at + 1 < source.count, source[at + 1] == "(",
                  let end = linkEnd(from: at + 2) else {
                take(1)
                return
            }
            flush()
            resolve(from: opener.runs)
            runs.removeSubrange(opener.runs...)
            let text = pieces[(opener.piece + 1)...].map(Self.text).joined()
            pieces.removeSubrange(opener.piece...)
            pieces.append(.text(text))
            for index in brackets.indices { brackets[index].active = false }
            at = end
        }

        /// Where a link's "(address)" or "(address "title")" that begins after its "(" at `start` ends: the index
        /// after its ")"; nil when what is there isn't one.
        func linkEnd(from start: Int) -> Int? {
            var index = start
            func skipSpaces() {
                while index < source.count, source[index] == " " || source[index] == "\t" { index += 1 }
            }
            /// To `close`, a backslash's next character skipped; false when `close` isn't there or `barred` is.
            func skip(to close: Unicode.Scalar, barred: Unicode.Scalar?) -> Bool {
                while index < source.count, source[index] != close {
                    if source[index] == barred { return false }
                    index += source[index] == "\\" && index + 1 < source.count ? 2 : 1
                }
                guard index < source.count else { return false }
                index += 1
                return true
            }
            skipSpaces()
            if index < source.count, source[index] == "<" {
                index += 1
                guard skip(to: ">", barred: "<") else { return nil }
            } else {
                // To a space, its parentheses in pairs.
                var depth = 0
                while index < source.count {
                    let scalar = source[index]
                    if scalar == "\\", index + 1 < source.count, Self.isASCIIPunctuation(source[index + 1]) {
                        index += 2
                        continue
                    }
                    if scalar == "(" {
                        depth += 1
                        if depth > 32 { return nil }
                    } else if scalar == ")" {
                        if depth == 0 { break }
                        depth -= 1
                    } else if scalar == " " || scalar == "\t" {
                        break
                    }
                    index += 1
                }
                guard depth == 0 else { return nil }
            }
            let afterAddress = index
            skipSpaces()
            // A title, after a space: "…", '…' or (…).
            let titleEnds: [Unicode.Scalar: Unicode.Scalar] = ["\"": "\"", "'": "'", "(": ")"]
            if index > afterAddress, index < source.count, let close = titleEnds[source[index]] {
                let open = source[index]
                index += 1
                guard skip(to: close, barred: open == "(" ? "(" : nil) else { return nil }
                skipSpaces()
            }
            guard index < source.count, source[index] == ")" else { return nil }
            return index + 1
        }

        // MARK: Kinds of character

        static func isASCIIPunctuation(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: return true
            default: return false
            }
        }

        static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x09, 0x0A, 0x0C, 0x0D, 0x20: return true
            default: return scalar.properties.generalCategory == .spaceSeparator
            }
        }

        static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
            if scalar.isASCII { return isASCIIPunctuation(scalar) }
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
                 .finalPunctuation, .otherPunctuation:
                return true
            default:
                return false
            }
        }
    }
}
#endif
