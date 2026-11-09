import Foundation
import Testing
@testable import VibeCore

/// The shell reads a command line one code point at a time, so the parser has to as well: a combining mark after a
/// quote or an operator is still that quote or operator to the shell.
@Suite struct ReadOnlyCommandScalarTests {
    private let mark = "\u{301}"

    @Test func aMarkAfterAQuoteDoesntChangeWhatIsQuoted() {
        let line = "git log '\(mark)A' ; touch made-by-the-line ; echo 'B'\(mark)"
        #expect(!ReadOnlyCommand.allows(line))
        #expect(ReadOnlyCommand.parts(of: line)?.map { $0[0] } == ["git", "touch", "echo"])
        let hook = try? JSONSerialization.data(withJSONObject: ["tool_name": "Bash", "tool_input": ["command": line]])
        #expect(hook.flatMap { ReadOnlyCommand.hookAnswer($0) } == nil)
    }

    @Test(arguments: [";", "&&", "||", "|", "`", "$", "(", ")", "<", ">", "#", "*", "\""])
    func aMarkAfterAnOperatorLeavesItAnOperator(_ symbol: String) {
        #expect(!ReadOnlyCommand.allows("git log \(symbol)\(mark) x"))
    }

    /// Swift's `Character ==` is canonical: these are the same as an ASCII character to the parser and a plain word
    /// character to the shell, so a line holding one prompts, wherever it stands.
    @Test(arguments: ["\u{37E}", "\u{1FEF}", "\u{212A}"])
    func aCharacterEqualToAnASCIIOneIsRefused(_ lookalike: String) {
        #expect(ReadOnlyCommand.parts(of: "rg x src \(lookalike) head --pre ./tool") == nil)
        #expect(ReadOnlyCommand.parts(of: "git log '\(lookalike)'") == nil)
        #expect(!ReadOnlyCommand.allows("sort a\(lookalike)head -o out"))
    }

    @Test func aMarkInsideAQuotedWordIsJustPartOfIt() {
        #expect(ReadOnlyCommand.allows("git log --author='Jose\(mark)'"))
        #expect(ReadOnlyCommand.parts(of: "git log --author='Jose\(mark)'")?.first?.last == "--author=Jose\(mark)")
    }
}
