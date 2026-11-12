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
}
