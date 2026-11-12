import CoreFoundation
import Foundation

extension Platform {
    /// Whether `number` is a true or a false, not a number: what `JSONSerialization` makes of a JSON `true` is an
    /// NSNumber too, and reads 1 as a number. On both systems the one that parsed a boolean is CoreFoundation's
    /// boolean (the Mac's `__NSCFBoolean`, and swift-corelibs-foundation's class of the same name, one object for true
    /// and one for false), which its type says. Asking Swift (`as? Bool`) doesn't tell them apart: a 1 and a 0 are
    /// Bools to it on both systems.
    public static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Whether the caller runs on the main thread, or as the main queue's work (the main actor's with it) wherever that
    /// runs. The Mac: `Thread.isMainThread`. On Linux a process in `dispatchMain()` (vibeswitcher-host, the test runner)
    /// has its first thread end there, and libdispatch runs the main queue on a thread of its own, where
    /// `Thread.isMainThread` says false.
    public static var isMainThread: Bool {
        #if canImport(Darwin)
        return Thread.isMainThread
        #else
        return Thread.isMainThread || DispatchQueue.getSpecific(key: mainQueueKey) != nil
        #endif
    }

    #if !canImport(Darwin)
    /// Set on the main queue as it is first read (dispatch_queue_set_specific takes effect at once): only the main
    /// queue's work reads it back.
    nonisolated(unsafe) private static let mainQueueKey: DispatchSpecificKey<Bool> = {
        let key = DispatchSpecificKey<Bool>()
        DispatchQueue.main.setSpecific(key: key, value: true)
        return key
    }()
    #endif

    /// `markdown`, one line of inline markdown, as its words: emphasis, code spans and links without their marks, a
    /// link without its address. A block's mark (a leading "# ", "> ", "- ") isn't inline markdown and stays. nil when
    /// it can't be parsed. On the Mac it is Foundation's parser (`AttributedString(markdown:)`, inline only,
    /// whitespace kept); Linux's Foundation has none, and `InlineMarkdown` (Small+Linux.swift) does the same for the
    /// text it is sure of and says nil for the rest: the caller then has the text as it came.
    public static func plainInline(_ markdown: String) -> String? {
        #if canImport(Darwin)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)).map { String($0.characters) }
        #else
        return InlineMarkdown.plain(markdown)
        #endif
    }

    /// `text` cut at each line feed, as the Mac's `text.components(separatedBy: "\n")` cuts it: a CRLF line keeps its
    /// CR, a lone CR ends no line, a BOM stays on the first line, and an LF is a line's end whatever follows it. Linux's
    /// Foundation answers that call in Swift's characters, where a CRLF is one character and no LF: a CRLF file read
    /// as one line. So Linux cuts at each LF scalar itself, as the Mac's Foundation does (a literal search from macOS
    /// 14 on, as a review read swift-foundation: `SmallTests.linesAreCutAtEachLineFeedAsTheMacCutsThem` is what the Mac
    /// runner checks it against).
    public static func lines<Text: StringProtocol>(_ text: Text) -> [String] {
        #if canImport(Darwin)
        return text.components(separatedBy: "\n")
        #else
        return String(text).unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
        #endif
    }
}
