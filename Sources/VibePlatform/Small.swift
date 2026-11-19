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

    /// Whether two JSON objects hold the same members: each as `JSONSerialization` read it, or built in the program
    /// from dictionaries, arrays, strings, numbers, Bools and `NSNull`. The Mac: `NSDictionary`'s `isEqual(to:)`, as
    /// the callers asked it before.
    ///
    /// On Linux that call says false for an object with a `true` or a `false` among its own members, compared with
    /// itself too: swift-corelibs-foundation's `isEqual(to:)` reads its own value back as a Swift `Bool` and the
    /// other dictionary's as the `__NSCFBoolean` the parser made, and `AnyHashable` calls those two different (a
    /// boolean inside a nested array or object is compared another way, and is found equal). So Linux walks the two
    /// values itself: objects by key, arrays in order, strings by their scalars, numbers by value. There a boolean
    /// is never equal to a number (`true` isn't 1), which the Mac's call doesn't tell apart.
    public static func sameJSON(_ one: [String: Any], _ other: [String: Any]) -> Bool {
        #if canImport(Darwin)
        return NSDictionary(dictionary: one).isEqual(to: other)
        #else
        return sameJSONValue(one, other)
        #endif
    }

    #if !canImport(Darwin)
    private static func sameJSONValue(_ one: Any, _ other: Any) -> Bool {
        switch (one, other) {
        case (let one as [String: Any], let other as [String: Any]):
            return one.count == other.count && one.allSatisfy { key, value in
                other[key].map { sameJSONValue(value, $0) } ?? false
            }
        case (let one as [Any], let other as [Any]):
            return one.count == other.count && zip(one, other).allSatisfy(sameJSONValue)
        case (let one as String, let other as String):
            return one.unicodeScalars.elementsEqual(other.unicodeScalars)
        case (let one as NSNumber, let other as NSNumber):
            return isBoolean(one) == isBoolean(other) && one.isEqual(other)
        case (is NSNull, is NSNull):
            return true
        default:
            return false
        }
    }
    #endif

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
