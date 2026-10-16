import Foundation
import Testing
@testable import VibeCore

struct SyntaxHighlightTests {
    /// (kind, text) pairs of the non-plain tokens.
    func marked(_ code: String, _ language: String?) -> [String] {
        SyntaxHighlight.tokens(code, language: language).filter { $0.kind != .plain }.map { "\($0.kind):\(code[$0.range])" }
    }

    @Test func swiftKeywordsStringsCommentsNumbersAndTypes() {
        #expect(marked("let x = \"hi\" // note\nreturn 42", "swift") ==
                ["keyword:let", "string:\"hi\"", "comment:// note", "keyword:return", "number:42"])
        #expect(marked("var view: NSView", "swift") == ["keyword:var", "type:NSView"])
    }

    @Test func pythonHashCommentsAndShell() {
        #expect(marked("def f(): # hi\n  pass", "python") == ["keyword:def", "comment:# hi", "keyword:pass"])
        #expect(marked("if [ -f x ]; then echo 'ok'; fi", "bash") ==
                ["keyword:if", "keyword:then", "keyword:echo", "string:'ok'", "keyword:fi"])
    }

    @Test func jsonKeysAndValues() {
        #expect(marked("{\"a\": 1, \"b\": true}", "json") == ["string:\"a\"", "number:1", "string:\"b\"", "keyword:true"])
    }

    @Test func unknownLanguagesStillGetStringsAndNumbers() {
        #expect(marked("foo \"bar\" 12", nil) == ["string:\"bar\"", "number:12"])
    }

    @Test func escapedQuotesStayInsideTheString() {
        #expect(marked("x = \"a\\\"b\" + 1", "js") == ["string:\"a\\\"b\"", "number:1"])
    }

    @Test func blockCommentsAndTokensCoverTheTextWithoutOverlap() {
        let code = "/* a\nb */ const y = 'z' // c"
        #expect(marked(code, "ts") == ["comment:/* a\nb */", "keyword:const", "string:'z'", "comment:// c"])
        let tokens = SyntaxHighlight.tokens(code, language: "ts")
        #expect(tokens.map { String(code[$0.range]) }.joined() == code)
    }

    @Test func numbersInsideIdentifiersArent() {
        #expect(marked("abc123 = v2", "python") == [])
    }
}
