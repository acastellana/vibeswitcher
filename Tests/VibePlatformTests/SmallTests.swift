import Foundation
import Testing
import VibePlatform

struct SmallTests {
    /// What `JSONSerialization` makes of a JSON true and of a 1 are both NSNumbers, and Swift calls both Bools: only
    /// `isBoolean` tells which the file said.
    @Test func aJSONTrueIsABooleanAndAOneIsNot() throws {
        let text = #"{"yes": true, "no": false, "one": 1, "zero": 0, "real": 1.0, "minus": -1, "word": "true"}"#
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        func isBoolean(_ key: String) throws -> Bool {
            Platform.isBoolean(try #require(object[key] as? NSNumber, "\(key) isn't a number"))
        }
        #expect(try isBoolean("yes"))
        #expect(try isBoolean("no"))
        #expect(try !isBoolean("one"))
        #expect(try !isBoolean("zero"))
        #expect(try !isBoolean("real"))
        #expect(try !isBoolean("minus"))
        #expect(object["word"] as? NSNumber == nil)
        // The trap `isBoolean` is for: Swift reads the number 1 as a Bool too.
        #expect(object["one"] as? Bool == true)

        let list = try #require(try JSONSerialization.jsonObject(with: Data("[true, 1]".utf8)) as? [Any])
        #expect(list.map { Platform.isBoolean($0 as? NSNumber ?? 7) } == [true, false])
    }

    /// Numbers made in the program, not parsed: a Bool is a boolean, an integer of any width isn't.
    @Test func aNumberMadeFromABoolIsABooleanAndFromAnIntegerIsNot() {
        #expect(Platform.isBoolean(NSNumber(value: true)))
        #expect(Platform.isBoolean(NSNumber(value: false)))
        #expect(!Platform.isBoolean(NSNumber(value: 1)))
        #expect(!Platform.isBoolean(NSNumber(value: Int8(1))))
        #expect(!Platform.isBoolean(NSNumber(value: UInt8(0))))
        #expect(!Platform.isBoolean(NSNumber(value: 1.0)))
    }

    /// The same words on both systems, from the Mac's Foundation and from Linux's own reader: each text here is one
    /// whose reading CommonMark leaves no doubt about (matched emphasis, a code span, a link with a plain address,
    /// an underscore inside a word, a star with a space on each side).
    @Test func plainInlineDropsEmphasisAndLinks() {
        #expect(Platform.plainInline("**a** [b](http://x) `c`") == "a b c")
        #expect(Platform.plainInline("See [the docs](https://example.com) and _this_") == "See the docs and this")
        #expect(Platform.plainInline("Run **the** `Parser` tests") == "Run the Parser tests")
        #expect(Platform.plainInline("Edit App.swift") == "Edit App.swift")
        #expect(Platform.plainInline("snake_case_name stays") == "snake_case_name stays")
        #expect(Platform.plainInline("2 * 3 * 4") == "2 * 3 * 4")
    }

    #if os(Linux)
    /// Linux's reader, by CommonMark's rules. A block's mark at the start of the line is text, as the Mac's inline
    /// parsing leaves it (`ActivityFeed.plain` takes it off afterwards).
    @Test func linuxReadsInlineMarkdownByCommonMarksRules() {
        let cases: [(String, String)] = [
            ("## See [the docs](https://example.com) and _this_", "## See the docs and this"),
            ("- one two", "- one two"),
            ("> *quoted*", "> quoted"),
            ("* item *x*", "* item x"),
            // Emphasis: nested, three marks, inside a word, and marks that don't pair.
            ("**a *b* c**", "a b c"),
            ("***a***", "a"),
            ("foo*bar*baz", "foobarbaz"),
            ("__init__", "init"),
            ("foo_bar_", "foo_bar_"),
            ("*unclosed", "*unclosed"),
            ("a* b", "a* b"),
            ("**a*", "*a"),
            ("*a**b**c*", "abc"),
            // The rule of three: "*foo**bar*" isn't strong-in-emphasis, the two stars in the middle stay.
            ("*foo**bar*", "foo**bar"),
            ("\"_quoted_\" (_too_)", "\"quoted\" (too)"),
            ("пристаням_стремятся_", "пристаням_стремятся_"),
            // Code spans: marks inside are text; a longer fence holds a backtick; a run with no partner is text.
            ("`a * b` *c*", "a * b c"),
            ("`` a`b ``", "a`b"),
            ("`  `", "  "),
            ("``` not closed", "``` not closed"),
            ("`a` ``b` c", "a ``b` c"),
            // Links: a title, an address in angle brackets or with parentheses, emphasis in and around the text.
            ("[a](u \"title\")", "a"),
            ("[a](<u v>)", "a"),
            ("[a](f(x))", "a"),
            ("[](u)", ""),
            ("[*a* b](u)", "a b"),
            ("*[a](u) b*", "a b"),
            ("*[a*](u)", "*a*"),
            // Not links: an address with a space, brackets with no address, a link inside a link's text.
            ("[a](u v)", "[a](u v)"),
            ("[x] done, see [a][b]", "[x] done, see [a][b]"),
            ("[x [a](u) y](v)", "[x a y](v)"),
            ("a ] b [ c", "a ] b [ c"),
            // A backslash before a mark makes it text; before anything else it is itself.
            ("\\*not\\* \\[a](u)", "*not* [a](u)"),
            ("C:\\Users\\me", "C:\\Users\\me"),
            // What only looks like the things it won't read.
            ("a < b & c > d", "a < b & c > d"),
            ("AT&T and R&D", "AT&T and R&D"),
            ("~/dev/app", "~/dev/app"),
            // A bare address with nothing in it to read as markdown is text, and what is around it is read.
            ("**see** https://example.com/docs?page=2, *now*", "see https://example.com/docs?page=2, now"),
            ("**www.example.com**", "www.example.com"),
            ("[the docs](https://example.com/a_b_c) *here*", "the docs here"),
            ("ratio 3:2, twice: **now**", "ratio 3:2, twice: now"),
            ("wow! [a](u)", "wow! a"),
            ("  kept  spaces  ", "  kept  spaces  "),
            ("", ""),
        ]
        for (markdown, plain) in cases {
            #expect(Platform.plainInline(markdown) == plain, "\(markdown)")
        }
    }

    /// What Linux's reader has no rules for is nil, not a guess: the caller keeps the text as it came.
    @Test func linuxSaysNilForWhatItDoesNotRead() {
        let unread = [
            "one\ntwo", "one\r\ntwo", "a <b>bold</b>", "see <https://example.com>", "a &amp; b", "&#65;", "&#x41;",
            "![alt](image.png)", "~~gone~~ kept", "~a~ and ~b~", "a note[^1]", "*a*~", "~_a_",
            "https://example.com/_a_ and *b*", "see http://example.com/a*b*c", "www.example.com/`a`", "ftp://host/[a](b)",
            String(repeating: "a", count: 16_385),
        ]
        for markdown in unread {
            #expect(Platform.plainInline(markdown) == nil, "\(markdown.prefix(40))")
        }
        #expect(Platform.plainInline(String(repeating: "a", count: 16_384)) != nil)
    }

    /// Text made to cost a careless reader the square of its length (marks, backticks and brackets that never
    /// pair) comes back, unchanged or nil: this test ends.
    @Test func linuxReadsTextOfMarksThatNeverPair() {
        let stars = String(repeating: "a* ", count: 5000), openers = String(repeating: "_a ", count: 2500) + String(repeating: "a* ", count: 2500)
        #expect(Platform.plainInline(stars) == stars)
        #expect(Platform.plainInline(openers) == openers)
        var fences = ""
        for length in 1...170 { fences += String(repeating: "`", count: length) + "a" }
        #expect(Platform.plainInline(fences) == fences)
        let brackets = String(repeating: "[a](< ", count: 2000)
        #expect(Platform.plainInline(brackets) == brackets)
    }
    #endif

    /// The main actor's work is the main thread's on both systems (on Linux the test runner is in `dispatchMain()`, and
    /// libdispatch runs the main queue on a thread of its own); a thread of its own and a global queue's aren't.
    @MainActor @Test func theMainActorIsOnTheMainThreadAndOtherThreadsAreNot() async {
        #expect(Platform.isMainThread)
        let thread = await withCheckedContinuation { done in Thread.detachNewThread { done.resume(returning: Platform.isMainThread) } }
        #expect(!thread)
        let queued = await withCheckedContinuation { done in DispatchQueue.global().async { done.resume(returning: Platform.isMainThread) } }
        #expect(!queued)
    }
}
