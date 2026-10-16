import Foundation

public struct SyntaxToken: Equatable, Sendable {
    public enum Kind: String, Sendable { case keyword, string, comment, number, type, plain }
    public var kind: Kind
    public var range: Range<String.Index>
}

/// Light syntax coloring for code blocks: keywords, strings, comments, numbers and type names, per language
/// family. Not a parser: it only has to look right for the snippets agents show.
public enum SyntaxHighlight {
    struct Language {
        var keywords: Set<String>
        var lineComment: [String]
        var blockComment: (String, String)?
        /// Capitalized identifiers are types (Swift, TS, Go, Rust, …).
        var capitalizedTypes: Bool
    }

    /// Tokens covering all of `code`, in order.
    public static func tokens(_ code: String, language: String?) -> [SyntaxToken] {
        let lang = self.language(language)
        var tokens: [SyntaxToken] = []
        func add(_ kind: SyntaxToken.Kind, _ range: Range<String.Index>) {
            guard !range.isEmpty else { return }
            if kind == .plain, let last = tokens.last, last.kind == .plain, last.range.upperBound == range.lowerBound {
                tokens[tokens.count - 1].range = last.range.lowerBound..<range.upperBound
            } else {
                tokens.append(SyntaxToken(kind: kind, range: range))
            }
        }
        var i = code.startIndex
        while i < code.endIndex {
            let rest = code[i...]
            if let (open, close) = lang.blockComment, rest.hasPrefix(open) {
                let end = code.range(of: close, range: code.index(i, offsetBy: open.count)..<code.endIndex)?.upperBound ?? code.endIndex
                add(.comment, i..<end)
                i = end
            } else if lang.lineComment.contains(where: { rest.hasPrefix($0) }), !(lang.lineComment == ["#"] && isInsideWord(code, i)) {
                let end = code[i...].firstIndex(of: "\n") ?? code.endIndex
                add(.comment, i..<end)
                i = end
            } else if let quote = rest.first, "\"'`".contains(quote) {
                let end = stringEnd(code, from: i, quote: quote)
                add(.string, i..<end)
                i = end
            } else if let c = rest.first, c.isNumber, !isInsideWord(code, i) {
                var end = code.index(after: i)
                while end < code.endIndex, code[end].isHexDigit || "._xXoObB".contains(code[end]) { end = code.index(after: end) }
                add(.number, i..<end)
                i = end
            } else if let c = rest.first, c.isLetter || c == "_" {
                var end = code.index(after: i)
                while end < code.endIndex, code[end].isLetter || code[end].isNumber || code[end] == "_" { end = code.index(after: end) }
                let word = String(code[i..<end])
                if lang.keywords.contains(word) {
                    add(.keyword, i..<end)
                } else if lang.capitalizedTypes, c.isUppercase, word.count > 1 {
                    add(.type, i..<end)
                } else {
                    add(.plain, i..<end)
                }
                i = end
            } else {
                let next = code.index(after: i)
                add(.plain, i..<next)
                i = next
            }
        }
        return tokens
    }

    private static func isInsideWord(_ code: String, _ index: String.Index) -> Bool {
        guard index > code.startIndex else { return false }
        let before = code[code.index(before: index)]
        return before.isLetter || before.isNumber || before == "_" || before == "$"
    }

    /// Past the closing quote; a backslash escapes the next character. ' and " strings end at a newline.
    private static func stringEnd(_ code: String, from start: String.Index, quote: Character) -> String.Index {
        var i = code.index(after: start)
        while i < code.endIndex {
            let c = code[i]
            if c == "\\" {
                i = code.index(after: i)
                if i < code.endIndex { i = code.index(after: i) }
                continue
            }
            if c == quote { return code.index(after: i) }
            if c == "\n", quote != "`" { return i }
            i = code.index(after: i)
        }
        return code.endIndex
    }

    static func language(_ name: String?) -> Language {
        let cLike: (String, String) = ("/*", "*/")
        switch name?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "swift":
            return Language(keywords: ["let", "var", "func", "return", "if", "else", "guard", "for", "in", "while", "switch", "case",
                                       "default", "struct", "class", "enum", "protocol", "extension", "import", "public", "private",
                                       "fileprivate", "internal", "static", "self", "Self", "nil", "true", "false", "try", "await",
                                       "async", "throws", "throw", "do", "catch", "init", "deinit", "where", "defer", "break",
                                       "continue", "final", "override", "some", "any", "inout", "lazy", "weak", "mutating", "typealias"],
                            lineComment: ["//"], blockComment: cLike, capitalizedTypes: true)
        case "js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs":
            return Language(keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "of", "in", "new",
                                       "class", "extends", "import", "from", "export", "default", "async", "await", "try", "catch",
                                       "finally", "throw", "typeof", "instanceof", "this", "null", "undefined", "true", "false",
                                       "switch", "case", "break", "continue", "interface", "type", "enum", "implements", "readonly",
                                       "public", "private", "protected", "static", "as", "void", "yield", "delete"],
                            lineComment: ["//"], blockComment: cLike, capitalizedTypes: true)
        case "py", "python", "python3":
            return Language(keywords: ["def", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import",
                                       "from", "as", "class", "try", "except", "finally", "raise", "with", "pass", "break",
                                       "continue", "lambda", "yield", "None", "True", "False", "async", "await", "global", "self"],
                            lineComment: ["#"], blockComment: nil, capitalizedTypes: false)
        case "sh", "bash", "zsh", "shell", "console", "shellscript":
            return Language(keywords: ["if", "then", "else", "elif", "fi", "for", "do", "done", "while", "case", "esac", "in",
                                       "function", "return", "export", "local", "echo", "cd", "exit", "set", "unset", "source",
                                       "sudo", "git", "swift", "npm", "brew", "rm", "mkdir", "cp", "mv", "cat", "grep", "sed"],
                            lineComment: ["#"], blockComment: nil, capitalizedTypes: false)
        case "json", "jsonc":
            return Language(keywords: ["true", "false", "null"], lineComment: [], blockComment: nil, capitalizedTypes: false)
        case "go", "golang":
            return Language(keywords: ["func", "return", "if", "else", "for", "range", "package", "import", "var", "const", "type",
                                       "struct", "interface", "map", "chan", "go", "defer", "select", "switch", "case", "default",
                                       "nil", "true", "false", "break", "continue"],
                            lineComment: ["//"], blockComment: cLike, capitalizedTypes: true)
        case "rust", "rs":
            return Language(keywords: ["fn", "let", "mut", "return", "if", "else", "for", "in", "while", "loop", "match", "struct",
                                       "enum", "impl", "trait", "pub", "use", "mod", "crate", "self", "Self", "true", "false",
                                       "async", "await", "move", "ref", "where", "const", "static", "unsafe", "dyn"],
                            lineComment: ["//"], blockComment: cLike, capitalizedTypes: true)
        case "c", "cpp", "c++", "h", "hpp", "java", "kotlin", "kt", "cs", "csharp", "objc", "objective-c":
            return Language(keywords: ["int", "char", "void", "return", "if", "else", "for", "while", "struct", "class", "public",
                                       "private", "protected", "static", "const", "new", "true", "false", "null", "nullptr",
                                       "import", "package", "fun", "val", "var", "switch", "case", "break", "include"],
                            lineComment: ["//"], blockComment: cLike, capitalizedTypes: true)
        case "yaml", "yml", "toml", "ruby", "rb":
            return Language(keywords: ["true", "false", "null", "def", "end", "do", "if", "else", "nil"],
                            lineComment: ["#"], blockComment: nil, capitalizedTypes: false)
        case "sql":
            return Language(keywords: ["select", "from", "where", "insert", "into", "update", "delete", "create", "table", "join",
                                       "on", "and", "or", "not", "null", "order", "by", "group", "limit", "as",
                                       "SELECT", "FROM", "WHERE", "INSERT", "INTO", "UPDATE", "DELETE", "CREATE", "TABLE", "JOIN",
                                       "ON", "AND", "OR", "NOT", "NULL", "ORDER", "BY", "GROUP", "LIMIT", "AS"],
                            lineComment: ["--"], blockComment: cLike, capitalizedTypes: false)
        default:
            return Language(keywords: [], lineComment: [], blockComment: nil, capitalizedTypes: false)
        }
    }
}
