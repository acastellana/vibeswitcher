import Foundation
import Testing

/// The Mac's GlossaryTests' lint on Linux (`MacText`): a session's state is said with StateWord, not another word, in
/// VibeCore's (which v2 edits), the app's and the phone's string literals. Its word list and allow-list are read from the
/// Mac file; `literals`, `core` and `offGlossaryWords` are its copies.
struct MacGlossaryLintTests {
    static let mac = "GlossaryTests.swift"
    static let root = MacText.repo
    static let app = root.appendingPathComponent("Web/app.js")

    static let offGlossary: Set<String> = {
        let text = (try? MacText.file(mac)) ?? ""
        return Set(MacText.literals((try? MacText.between(text, "static let offGlossary: Set<String> = [", "]\n")) ?? ""))
    }()

    static let allowed: [(file: String, word: String, why: String)] = {
        let text = (try? MacText.file(mac)) ?? ""
        let body = (try? MacText.between(text, "static let allowed: [(file: String, word: String, why: String)] = [", "\n    ]")) ?? ""
        return body.split(separator: "\n").compactMap { line in
            let parts = MacText.literals(String(line))
            return parts.count == 3 ? (parts[0], parts[1], parts[2]) : nil
        }
    }()

    static func literals(in line: String, quotes: Set<Character>) -> [String] {
        let chars = Array(line)
        var index = 0
        var found: [String] = []

        func skipInterpolation(closing: Character) {
            let opening: Character = closing == ")" ? "(" : "{"
            var depth = 1
            while index < chars.count {
                let char = chars[index]
                index += 1
                if quotes.contains(char) {
                    found.append(string(char))
                } else if char == opening {
                    depth += 1
                } else if char == closing {
                    depth -= 1
                    if depth == 0 { return }
                }
            }
        }

        /// Called past the opening quote; returns the literal's text, leaving `index` past the closing quote.
        func string(_ quote: Character) -> String {
            var text = ""
            while index < chars.count {
                let char = chars[index]
                if char == quote { index += 1; return text }
                if char == "\\", index + 1 < chars.count {
                    index += 2
                    if chars[index - 1] == "(" && quote == "\"" {
                        skipInterpolation(closing: ")")
                        text += " "
                    } else {
                        text.append(chars[index - 1])
                    }
                    continue
                }
                if quote == "`", char == "$", index + 1 < chars.count, chars[index + 1] == "{" {
                    index += 2
                    skipInterpolation(closing: "}")
                    text += " "
                    continue
                }
                text.append(char)
                index += 1
            }
            return text
        }

        while index < chars.count {
            let char = chars[index]
            if char == "/", index + 1 < chars.count, chars[index + 1] == "/" { break }
            index += 1
            guard quotes.contains(char) else { continue }
            let literal = string(char)
            found.append(literal)
        }
        return found
    }

    static func core(_ literal: String) -> String {
        literal.trimmingCharacters(in: CharacterSet.whitespaces.union(.decimalDigits).union(CharacterSet(charactersIn: "·:,;()!.…⏸-—")))
            .lowercased()
    }

    static func offGlossaryWords(in text: String, file: String, allowedSeen: inout Set<String>) -> [String] {
        let quotes: Set<Character> = file.hasSuffix(".js") ? ["\"", "'", "`"] : ["\""]
        var found: [String] = []
        var inMultiline = false
        for (number, line) in text.components(separatedBy: "\n").enumerated() {
            // A Swift multi-line literal is prose (a prompt, a script); its lines aren't code to scan.
            let fences = line.components(separatedBy: "\"\"\"").count - 1
            if fences > 0 {
                if fences % 2 == 1 { inMultiline.toggle() }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inMultiline || trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            for literal in literals(in: line, quotes: quotes) {
                let word = core(literal)
                guard offGlossary.contains(word) else { continue }
                if allowed.contains(where: { $0.file == file && $0.word == word }) {
                    allowedSeen.insert("\(file) \(word)")
                    continue
                }
                found.append("\(file):\(number + 1): '\(word)' in \(trimmed)")
            }
        }
        return found
    }

    @Test func everyStateWordIsTheGlossarys() throws {
        #expect(Self.offGlossary.count >= 5 && Self.allowed.count >= 3, "the Mac's lists weren't read: \(Self.offGlossary) \(Self.allowed.count)")
        var files = [Self.app]
        for folder in ["Sources/VibeSwitcher", "Sources/VibeCore"] {
            let walk = try #require(FileManager.default.enumerator(at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            files += walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        var found: [String] = []
        var seen = Set<String>()
        for url in files {
            let file = url.standardizedFileURL.path.replacingOccurrences(of: Self.root.standardizedFileURL.path + "/", with: "")
            found += Self.offGlossaryWords(in: try String(contentsOf: url, encoding: .utf8), file: file, allowedSeen: &seen)
        }
        let stale = Self.allowed.filter { !seen.contains("\($0.file) \($0.word)") }.map { "\($0.file): '\($0.word)'" }
        #expect(stale.isEmpty, "the Mac's glossary allow-list names words no longer there (its gate fails): \(stale)")
        #expect(found.isEmpty, "the Mac's glossary lint fails on these: say a session's state with StateWord:\n\(found.joined(separator: "\n"))")
    }

    /// The Mac test's sample lines with their counts (`theLintFindsOffGlossaryWordsAndOnlyThose`): the copy finds as many.
    @Test func theCopyFindsTheMacsSamplesAsTheMacDoes() throws {
        let text = try MacText.file(Self.mac)
        let test = try MacText.between(text, "func theLintFindsOffGlossaryWordsAndOnlyThose()", "\n    }\n")
        let sample = try NSRegularExpression(pattern: ##"#expect\((swift|js)\((#".*?"#|"(?:\\.|[^"\\])*")\)(?:\.count == (\d+)|\.isEmpty)\)"##)
        var checked = 0
        var seen = Set<String>()
        for match in sample.matches(in: test, range: NSRange(test.startIndex..., in: test)) {
            guard let kind = Range(match.range(at: 1), in: test), let argument = Range(match.range(at: 2), in: test),
                  let line = MacText.literals(String(test[argument])).first else { continue }
            let count = Range(match.range(at: 3), in: test).flatMap { Int(test[$0]) } ?? 0
            let file = test[kind] == "js" ? "Web/x.js" : "Sources/VibeCore/X.swift"
            #expect(Self.offGlossaryWords(in: line, file: file, allowedSeen: &seen).count == count, "\(line)")
            checked += 1
        }
        #expect(checked >= 10, "the Mac's samples weren't read: \(checked)")
    }
}
