import AppKit
import SwiftUI
import VibeCore

/// A prompt or a reply as one selectable text: one AppKit text view holding the whole message (headings, lists, quotes,
/// tables, inline code, links and code blocks, each code block's Copy and Run drawn over it), so a drag selects across
/// its paragraphs, ⌘A selects the message, and ⌘C copies plain text with blank lines between blocks, the list markers
/// and each code block as it is. A drag that leaves the message goes on into the messages above or below it
/// (`ChatTextView`); ⌘C then copies each one's part, in order.
///
/// It replaces a SwiftUI `Text` per paragraph: on the Mac a selectable `Text` is a text field of its own, and a selection
/// can't go from one view to the next.
struct ChatMessageText: View {
    let text: String
    let kind: ChatTextContent.Kind
    let fontSize: CGFloat
    /// A prompt's bubble fits its text; a reply takes the row's width.
    var hugs = false
    /// What the message's context menu offers after Copy and Select All.
    var menu: [ChatTextMenuItem] = []
    /// Its tooltip (a reply's time, once the pointer has reached its row).
    var help: String?
    /// The code blocks (by index) shown in full.
    @State private var expanded: Set<Int> = []
    @Environment(\.chatFolder) private var folder
    @Environment(\.chatRunner) private var runner

    var body: some View {
        ChatTextRepresentable(content: ChatTextContent.make(text, kind: kind, size: fontSize, folder: folder, expanded: expanded),
                              hugs: hugs, menu: menu, help: help, runner: runner) { expanded.insert($0) }
    }
}

/// A context-menu item of a message.
struct ChatTextMenuItem {
    let title: String
    let action: () -> Void
}

private struct ChatTextRepresentable: NSViewRepresentable {
    let content: ChatTextContent
    let hugs: Bool
    let menu: [ChatTextMenuItem]
    let help: String?
    let runner: ChatRunner?
    let showAll: (Int) -> Void

    func makeNSView(context: Context) -> ChatTextView {
        let view = ChatTextView()
        update(view)
        return view
    }

    func updateNSView(_ view: ChatTextView, context: Context) { update(view) }

    static func dismantleNSView(_ view: ChatTextView, coordinator: ()) { view.tearDown() }

    private func update(_ view: ChatTextView) {
        view.extraMenu = menu
        view.showAll = showAll
        if view.toolTip != help { view.toolTip = help }
        view.set(content, runner: runner)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ChatTextView, context: Context) -> CGSize? {
        // No width proposed: as wide as the chat's column gets.
        let width = proposal.width.map { max(1, $0) } ?? 900
        let size = view.fittingSize(width: width)
        return CGSize(width: hugs ? min(width, size.width) : width, height: size.height)
    }
}

// MARK: - The text

extension NSAttributedString.Key {
    /// What a character copies as instead of itself (a String): a blank line after a block, a tab between table cells,
    /// a space after a list marker.
    static let chatCopyAs = NSAttributedString.Key("vibeswitcher.chatCopyAs")
    /// A code block's text (a `ChatCodeRef`): copied whole when all of the shown part is selected, lines hidden behind
    /// "Show all" too.
    static let chatCode = NSAttributedString.Key("vibeswitcher.chatCode")
}

final class ChatCodeRef: NSObject {
    let code: String
    let language: String?
    /// The lines shown (the code's own count when it's shown in full).
    let shownLines: Int
    let lineCount: Int
    let index: Int
    /// How wide its longest shown line is: wider than its box, it scrolls sideways (`ChatCodeScroll`).
    let widest: CGFloat

    init(code: String, language: String?, shownLines: Int, lineCount: Int, index: Int, widest: CGFloat) {
        self.code = code
        self.language = language
        self.shownLines = shownLines
        self.lineCount = lineCount
        self.index = index
        self.widest = widest
    }

    var limited: Bool { shownLines < lineCount }

    /// The same block, as its header and its sideways scroller show it.
    func same(as other: ChatCodeRef) -> Bool {
        code == other.code && language == other.language && shownLines == other.shownLines && lineCount == other.lineCount && index == other.index
    }

    /// Equal by value: a block built again (after the cache let go of it) is the same block.
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ChatCodeRef else { return false }
        return same(as: other) && widest == other.widest
    }

    override var hash: Int { code.hashValue ^ index }
}

/// One block of a message (or a whole prompt) as text, without the newline ending it: built once (`ChatTextContent`).
final class ChatTextUnit {
    let key: String
    let string: NSAttributedString
    let codeBlocks: [(range: NSRange, ref: ChatCodeRef)]
    let quotes: [NSRange]
    let rules: [NSRange]
    let tables: [NSRange]

    init(key: String, string: NSAttributedString, codeBlocks: [(range: NSRange, ref: ChatCodeRef)], quotes: [NSRange], rules: [NSRange],
         tables: [NSRange]) {
        self.key = key
        self.string = string
        self.codeBlocks = codeBlocks
        self.quotes = quotes
        self.rules = rules
        self.tables = tables
    }
}

/// The fonts a message's text is built with, at one size, made on the main thread only. Texts are built on several
/// threads at once (`ChatTextContent.prepare`, `prepareNow`): AppKit's fonts made there (a system font, a bold one)
/// raced its own cache of them, and the losing font leaked (ChatTextPrepareLeakTests: `leaks` found the NSCTFont made by
/// +[NSFont systemFontOfSize:width:] and its glyph-advance cache). Off the main thread a text is built only at a size
/// whose fonts are made (`prepare` and `prepareNow` make them first).
final class ChatFonts: @unchecked Sendable {
    let body: NSFont
    /// A heading's (level 1, 2, then 3 and over).
    let headings: [NSFont]
    /// A list's markers: their digits all as wide.
    let marker: NSFont
    /// A line of next to nothing (the space above a table, a code block at the top, a rule).
    let tiny: NSFont
    let table: NSFont
    let tableHeader: NSFont
    /// A code block's.
    let code: NSFont
    /// Inline code's, by its size: a paragraph's (a heading's too) and a table's.
    let inlineCode: [CGFloat: NSFont]
    /// Bold, italic and both of each of these.
    private let styled: [String: NSFont]

    private init(_ size: CGFloat) {
        body = .systemFont(ofSize: size)
        headings = [size + 7, size + 4, size + 1.5].map { NSFont.systemFont(ofSize: $0, weight: .bold) }
        marker = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        tiny = .systemFont(ofSize: 1)
        table = .systemFont(ofSize: size - 1)
        tableHeader = .systemFont(ofSize: size - 1, weight: .semibold)
        code = ChatTextContent.codeFont
        inlineCode = Dictionary(uniqueKeysWithValues: [size - 1, size - 2].map { ($0, NSFont.monospacedSystemFont(ofSize: $0, weight: .regular)) })
        var styled: [String: NSFont] = [:]
        for font in [body, table, tableHeader] + headings {
            for traits in [NSFontDescriptor.SymbolicTraits.bold, .italic, [.bold, .italic]] {
                let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                styled[Self.key(font, traits)] = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            }
        }
        self.styled = styled
    }

    private static func key(_ font: NSFont, _ traits: NSFontDescriptor.SymbolicTraits) -> String { "\(font.fontName)|\(font.pointSize)|\(traits.rawValue)" }

    /// `font` in bold, italic or both; itself when it isn't one of these.
    func styled(_ font: NSFont, _ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        traits.isEmpty ? font : styled[Self.key(font, traits)] ?? font
    }

    private static let lock = NSLock()
    private static var sets: [CGFloat: ChatFonts] = [:]

    /// The fonts at `size`: made here on the main thread, off it the ones made already (else made on the main thread).
    static func at(_ size: CGFloat) -> ChatFonts {
        if let made = lock.withLock({ sets[size] }) { return made }
        guard Thread.isMainThread else { return DispatchQueue.main.sync { at(size) } }
        let made = ChatFonts(size)
        lock.withLock { sets[size] = made }
        return made
    }
}

/// A message's text as the text view shows it, built once per text, size, folder and opened code blocks (`make`), from
/// its blocks' texts, each built once (`ChatTextUnit`): a reply coming in rebuilds only its last block, and the text
/// view replaces only that block's characters (`ChatTextView.set`).
final class ChatTextContent {
    enum Kind: String { case markdown, plain }

    let string: NSAttributedString
    /// Each code block: its characters (the terminating newline left out) and what it holds. The text view draws its
    /// box around them (`ChatTextView.drawDecorations`), as it draws each quote's bar and each rule: NSTextBlock lost
    /// its padding and borders whenever its paragraphs had line or paragraph spacing, or there were two of them.
    let codeBlocks: [(range: NSRange, ref: ChatCodeRef)]
    let quotes: [NSRange]
    let rules: [NSRange]
    /// Each table's characters: its rows' shading, the lines between them and its rounded border drawn behind it too.
    let tables: [NSRange]
    /// Each block's characters (with the newline ending it), and what it was built from.
    let units: [(key: String, range: NSRange)]
    let key: String

    init(string: NSAttributedString, codeBlocks: [(range: NSRange, ref: ChatCodeRef)], quotes: [NSRange], rules: [NSRange],
         tables: [NSRange], units: [(key: String, range: NSRange)], key: String) {
        self.string = string
        self.codeBlocks = codeBlocks
        self.quotes = quotes
        self.rules = rules
        self.tables = tables
        self.units = units
        self.key = key
    }

    /// Lines a code block shows before "Show all", as `CodeBlockView`.
    static let codeLines = 40
    static let codeHeader: CGFloat = 26
    static let showAllHeight: CGFloat = 24
    /// Room inside a code block's box around its lines (and between its header and its first line).
    static let codePadding: CGFloat = 10
    static let quoteIndent: CGFloat = 13
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static let cache: NSCache<NSString, ChatTextContent> = {
        let cache = NSCache<NSString, ChatTextContent>()
        cache.totalCostLimit = 8 << 20
        return cache
    }()

    private static let unitCache: NSCache<NSString, ChatTextUnit> = {
        let cache = NSCache<NSString, ChatTextUnit>()
        cache.totalCostLimit = 8 << 20
        return cache
    }()

    static func make(_ text: String, kind: Kind, size: CGFloat, folder: String?, expanded: Set<Int> = []) -> ChatTextContent {
        let key = "\(kind.rawValue)|\(size)|\(folder ?? "")|\(expanded.sorted())|\(text)"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        var built: [ChatTextUnit] = []
        switch kind {
        case .plain:
            built = [unit("plain|\(size)|\(text)", size: size, folder: nil) { $0.plain(text) }]
        case .markdown:
            var codes = 0
            for (position, block) in MarkdownCache.blocks(text).enumerated() {
                var code: Int?
                if case .code = block { code = codes; codes += 1 }
                let open = code.map(expanded.contains) ?? false
                // What the block's text depends on: the first has no space above it, a code block has its number.
                let first = position == 0
                let key = "md|\(size)|\(folder ?? "")|\(first)|\(code ?? -1)|\(open)|\(block)"
                built.append(unit(key, size: size, folder: folder) { builder in
                    builder.first = first
                    builder.codeIndex = code ?? 0
                    builder.expanded = open
                    builder.append(block, spacing: first ? 0 : 10)
                })
            }
        }
        let content = assemble(built, key: key)
        cache.setObject(content, forKey: key as NSString, cost: cost(content.string, key: key))
        return content
    }

    /// About what a text and its key hold in memory: its characters twice (the key holds them too) and each run's
    /// attributes. Counting 8 bytes a character let the caches hold several times their limit.
    private static func cost(_ string: NSAttributedString, key: String) -> Int {
        var runs = 0
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { _, _, _ in runs += 1 }
        return 2 * (string.length + (key as NSString).length) + 160 * runs + 512
    }

    /// Lets go of every text built (`ChatView`, once no chat is on screen): a closed window holds none of them.
    static func purge() {
        purges.increment()
        cache.removeAllObjects()
        unitCache.removeAllObjects()
    }

    /// Purges so far: texts asked for before the last one aren't made (a page's, queued as the window closed, filled
    /// the caches again once no chat was shown).
    private static let purges = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var current: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    /// A block's text, from the cache or `build`.
    private static func unit(_ key: String, size: CGFloat, folder: String?, build: (inout Builder) -> Void) -> ChatTextUnit {
        if let hit = unitCache.object(forKey: key as NSString) { return hit }
        var builder = Builder(size: size, folder: folder)
        build(&builder)
        let unit = ChatTextUnit(key: key, string: builder.out, codeBlocks: builder.codeBlocks, quotes: builder.quotes, rules: builder.rules,
                                tables: builder.tables)
        unitCache.setObject(unit, forKey: key as NSString, cost: Self.cost(builder.out, key: key))
        return unit
    }

    /// The blocks one after the other, each but the last ended by a newline (its last paragraph's, copied as a blank line).
    private static func assemble(_ units: [ChatTextUnit], key: String) -> ChatTextContent {
        let out = NSMutableAttributedString()
        var codeBlocks: [(range: NSRange, ref: ChatCodeRef)] = []
        var quotes: [NSRange] = [], rules: [NSRange] = [], tables: [NSRange] = []
        var ranges: [(key: String, range: NSRange)] = []
        for (index, unit) in units.enumerated() {
            let start = out.length
            out.append(unit.string)
            codeBlocks += unit.codeBlocks.map { (NSRange(location: $0.range.location + start, length: $0.range.length), $0.ref) }
            quotes += unit.quotes.map { NSRange(location: $0.location + start, length: $0.length) }
            rules += unit.rules.map { NSRange(location: $0.location + start, length: $0.length) }
            tables += unit.tables.map { NSRange(location: $0.location + start, length: $0.length) }
            let ended = index < units.count - 1
            if ended, out.length > 0 {
                let style = out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil) ?? NSParagraphStyle.default
                let font = out.attribute(.font, at: out.length - 1, effectiveRange: nil) ?? ChatFonts.at(13).body
                out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style, .chatCopyAs: "\n\n"]))
            }
            ranges.append((unit.key + (ended ? "|ended" : ""), NSRange(location: start, length: out.length - start)))
        }
        return ChatTextContent(string: out, codeBlocks: codeBlocks, quotes: quotes, rules: rules, tables: tables, units: ranges, key: key)
    }

    private static let preparing = DispatchQueue(label: "vibeswitcher.chat-text", qos: .userInitiated)

    /// Builds the texts of messages about to be shown, off the main thread, so their rows find them made (`make`).
    static func prepare(_ messages: [(text: String, kind: Kind)], size: CGFloat, folder: String?) {
        guard !messages.isEmpty else { return }
        _ = ChatFonts.at(size)
        let asked = purges.current
        preparing.async {
            for message in messages where purges.current == asked { _ = make(message.text, kind: message.kind, size: size, folder: folder) }
        }
    }

    private static var warmed = false

    /// Once a run, as a chat first appears (its conversation still being read): what only the first message costs, in
    /// a turn of its own rather than the one laying out the first rows (the first open's costliest turn was twice the
    /// reopen's). The parsers off the main thread; here, a text view's TextKit and fonts and a code block's header,
    /// made and let go: it leaves nothing behind.
    static func warmUp() {
        guard !warmed else { return }
        warmed = true
        // Built, not kept: nothing of it stays in the caches.
        _ = ChatFonts.at(13)
        preparing.async {
            var builder = Builder(size: 13, folder: nil)
            let sample = "# A\n\nSome **text**, `code` and [a link](https://example.com).\n\n- one\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet a = 1\n```"
            for block in MarkdownBlocks.parse(sample) { builder.append(block, spacing: 10) }
        }
        // Gone by the end of the call: no view kept.
        autoreleasepool {
            let string = NSMutableAttributedString(string: "A ", attributes: [.font: NSFont.systemFont(ofSize: 13)])
            string.append(NSAttributedString(string: "b ", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold)]))
            string.append(NSAttributedString(string: "c", attributes: [.font: codeFont, .backgroundColor: NSColor.chatCodeChip]))
            let view = ChatTextView()
            view.set(ChatTextContent(string: string, codeBlocks: [], quotes: [], rules: [], tables: [], units: [], key: "warm-up"), runner: nil)
            _ = view.fittingSize(width: 500)
            view.tearDown()
            let header = ChatCodeHeader(language: "swift", code: "a", run: nil)
            header.frame = NSRect(x: 0, y: 0, width: 500, height: codeHeader)
            header.layoutSubtreeIfNeeded()
        }
    }

    /// Builds the texts of messages about to be shown in this turn on every core, not on the main thread alone.
    static func prepareNow(_ messages: [(text: String, kind: Kind)], size: CGFloat, folder: String?) {
        guard !messages.isEmpty else { return }
        _ = ChatFonts.at(size)
        DispatchQueue.concurrentPerform(iterations: messages.count) { index in
            _ = make(messages[index].text, kind: messages[index].kind, size: size, folder: folder)
        }
    }

    /// How wide `text` is in `font`, through Core Text on a copy of the font. Texts are built on several threads at once
    /// (`prepare`, `prepareNow`): measured through the NSFont itself, threads filling the font's glyph-advance cache at
    /// once leaked it (ChatTextPrepareLeakTests).
    static func width(_ text: String, font: NSFont) -> CGFloat {
        let copy = CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize, nil, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: copy]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// What `range` copies as: blank lines between blocks, tabs between table cells, a code block whose shown part is
    /// all selected in full.
    static func plainText(_ string: NSAttributedString, range: NSRange) -> String {
        let characters = string.string as NSString
        var out = ""
        string.enumerateAttribute(.chatCode, in: range) { value, run, _ in
            if let ref = value as? ChatCodeRef, ref.limited, run.length == codeLength(string, at: run.location, ref: ref) {
                out += ref.code
                return
            }
            string.enumerateAttribute(.chatCopyAs, in: run) { value, piece, _ in
                if let replacement = value as? String {
                    out += String(repeating: replacement, count: piece.length)
                } else {
                    out += characters.substring(with: piece).replacingOccurrences(of: "\u{2028}", with: "\n")
                }
            }
        }
        return out
    }

    /// How many characters a code block's shown part has (from any of them).
    private static func codeLength(_ string: NSAttributedString, at location: Int, ref: ChatCodeRef) -> Int {
        var whole = NSRange()
        _ = string.attribute(.chatCode, at: location, longestEffectiveRange: &whole, in: NSRange(location: 0, length: string.length))
        return whole.length
    }

    /// Builds the attributed text of one block (or of a prompt).
    private struct Builder {
        var size: CGFloat
        var folder: String?
        /// The message's first block: nothing above it.
        var first = false
        /// The block's number among the message's code blocks, and whether it's shown in full.
        var codeIndex = 0
        var expanded = false
        let out = NSMutableAttributedString()
        var codeBlocks: [(range: NSRange, ref: ChatCodeRef)] = []
        var quotes: [NSRange] = []
        var rules: [NSRange] = []
        var tables: [NSRange] = []

        let fonts: ChatFonts

        init(size: CGFloat, folder: String?) {
            self.size = size
            self.folder = folder
            fonts = ChatFonts.at(size)
        }

        var body: NSFont { fonts.body }

        mutating func plain(_ text: String) {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            out.append(NSAttributedString(string: text, attributes: [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]))
        }

        private func style(_ spacing: CGFloat, lineSpacing: CGFloat = 3) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.paragraphSpacingBefore = spacing
            return style
        }

        mutating func append(_ block: MDBlock, spacing: CGFloat) {
            switch block {
            case .heading(let level, let text):
                let font = fonts.headings[min(level, 3) - 1]
                // Its inline code as a paragraph's, as MarkdownView's.
                out.append(inline(text, font: font, style: style(spacing + (level <= 2 ? 6 : 2), lineSpacing: 0), codeSize: size - 1))
            case .paragraph(let text):
                out.append(inline(text, font: body, style: style(spacing)))
            case .list(let ordered, let start, let items):
                let markerFont = fonts.marker
                let widest = ordered ? "\(start + max(0, items.count - 1))." : "•"
                let markerWidth = ceil(ChatTextContent.width(widest, font: markerFont)) + 7
                for (index, item) in items.enumerated() {
                    let indent = CGFloat(item.depth) * 18
                    let paragraph = style(index == 0 ? spacing : 5, lineSpacing: 2)
                    paragraph.firstLineHeadIndent = indent
                    paragraph.headIndent = indent + markerWidth
                    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]
                    let marker: String
                    var markerColor = NSColor.secondaryLabelColor
                    if let checked = item.checked {
                        marker = checked ? "☑" : "☐"
                        if checked { markerColor = .controlAccentColor }
                    } else {
                        marker = ordered ? "\(start + index)." : item.depth == 0 ? "•" : "◦"
                    }
                    out.append(NSAttributedString(string: marker, attributes: [.font: markerFont, .foregroundColor: markerColor, .paragraphStyle: paragraph]))
                    out.append(NSAttributedString(string: "\t", attributes: [.font: body, .paragraphStyle: paragraph, .chatCopyAs: " "]))
                    let text = NSMutableAttributedString(attributedString: inline(item.text, font: body, style: paragraph))
                    if item.checked == true {
                        let all = NSRange(location: 0, length: text.length)
                        text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: all)
                        text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: all)
                    }
                    out.append(text)
                    if index < items.count - 1 {
                        out.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: paragraph]))
                    }
                }
            case .code(let language, let text):
                code(language: language, text: text, spacing: spacing)
            case .quote(let text):
                // Its bar drawn beside it (`ChatTextView.drawDecorations`).
                let paragraph = style(spacing)
                paragraph.firstLineHeadIndent = ChatTextContent.quoteIndent
                paragraph.headIndent = ChatTextContent.quoteIndent
                let text = NSMutableAttributedString(attributedString: inline(text, font: body, style: paragraph))
                text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: text.length))
                quotes.append(NSRange(location: out.length, length: text.length))
                out.append(text)
            case .table(let header, let alignments, let rows):
                table(header: header, alignments: alignments, rows: rows, spacing: spacing)
            case .rule:
                // A line of its own, the rule drawn over it (`ChatTextView.drawDecorations`).
                let paragraph = NSMutableParagraphStyle()
                paragraph.paragraphSpacingBefore = spacing + 4
                paragraph.paragraphSpacing = 4
                paragraph.minimumLineHeight = 2
                paragraph.maximumLineHeight = 2
                rules.append(NSRange(location: out.length, length: 1))
                out.append(NSAttributedString(string: "\u{00A0}", attributes: [.font: fonts.tiny, .paragraphStyle: paragraph,
                                                                               .chatCopyAs: "---"]))
            }
        }

        private mutating func code(language: String?, text: String, spacing: CGFloat) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let limited = !expanded && lines.count > ChatTextContent.codeLines + 5
            let shownLines = limited ? Array(lines.prefix(ChatTextContent.codeLines)) : lines
            let shown = limited ? shownLines.joined(separator: "\n") : text
            let pad = ChatTextContent.codePadding
            // Each line is a paragraph: indented inside the box, the first with room above for the header, the last
            // with room below (and for "Show all"). A line isn't wrapped: one wider than the box scrolls sideways
            // (`ChatCodeScroll`).
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.lineBreakMode = .byClipping
            paragraph.firstLineHeadIndent = pad
            paragraph.headIndent = pad
            paragraph.tailIndent = -pad
            let top = paragraph.mutableCopy() as! NSMutableParagraphStyle
            top.paragraphSpacingBefore = spacing + ChatTextContent.codeHeader + pad
            let last = paragraph.mutableCopy() as! NSMutableParagraphStyle
            last.paragraphSpacing = pad + (limited ? ChatTextContent.showAllHeight : 0)
            // The top of the text has no spacing before its first paragraph: a line there of next to nothing, copied
            // as nothing, so a reply that starts with code still has its header's room.
            if first {
                let lead = NSMutableParagraphStyle()
                lead.minimumLineHeight = 1
                lead.maximumLineHeight = 1
                out.append(NSAttributedString(string: "\n", attributes: [.font: fonts.tiny, .paragraphStyle: lead, .chatCopyAs: ""]))
            }
            let font = fonts.code
            // Monospaced: the longest line in characters (a tab as 4) times one's width.
            let columns = shownLines.map { $0.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } }.max() ?? 0
            let advance = ChatTextContent.width("0", font: font)
            let ref = ChatCodeRef(code: text, language: language, shownLines: shownLines.count, lineCount: lines.count, index: codeIndex,
                                  widest: ceil(CGFloat(columns) * advance))
            let start = out.length
            // An empty block still has a line to hold its box.
            let colored = shown.isEmpty ? NSAttributedString(string: " ") : SyntaxColors.ns(shown, language: language)
            let piece = NSMutableAttributedString(attributedString: colored)
            let all = NSRange(location: 0, length: piece.length)
            piece.addAttributes([.font: font, .paragraphStyle: paragraph, .chatCode: ref], range: all)
            let characters = piece.string as NSString
            let lastLine = characters.paragraphRange(for: NSRange(location: piece.length - 1, length: 0))
            piece.addAttribute(.paragraphStyle, value: last, range: lastLine)
            let firstLine = characters.paragraphRange(for: NSRange(location: 0, length: 0))
            if firstLine == lastLine {
                let only = last.mutableCopy() as! NSMutableParagraphStyle
                only.paragraphSpacingBefore = top.paragraphSpacingBefore
                piece.addAttribute(.paragraphStyle, value: only, range: firstLine)
            } else {
                piece.addAttribute(.paragraphStyle, value: top, range: firstLine)
            }
            piece.enumerateAttribute(.foregroundColor, in: all) { value, run, _ in
                if value == nil { piece.addAttribute(.foregroundColor, value: NSColor.labelColor, range: run) }
            }
            out.append(piece)
            codeBlocks.append((NSRange(location: start, length: piece.length), ref))
        }

        private mutating func table(header: [String], alignments: [MDAlign], rows: [[String]], spacing: CGFloat) {
            let table = NSTextTable()
            table.numberOfColumns = max(1, header.count)
            table.collapsesBorders = true
            table.setContentWidth(100, type: .percentageValueType)
            // The space above it a line of its own, copied as nothing: a top margin on the table narrows it by as much
            // instead (it no longer reached the column's edge), and padding gave no space. One point of that margin
            // keeps its right border inside the column.
            table.setWidth(1, type: .absoluteValueType, for: .margin, edge: .minY)
            if spacing > 0 {
                let gap = NSMutableParagraphStyle()
                gap.minimumLineHeight = spacing
                gap.maximumLineHeight = spacing
                out.append(NSAttributedString(string: "\n", attributes: [.font: fonts.tiny, .paragraphStyle: gap, .chatCopyAs: ""]))
            }
            let all = [header] + rows
            let start = out.length
            let font = fonts.table
            let bold = fonts.tableHeader
            for (row, cells) in all.enumerated() {
                for column in 0..<table.numberOfColumns {
                    // Its shading, the line over it and the table's border drawn behind it (`ChatTextView.drawDecorations`),
                    // as MarkdownView's grid: a row's cells side by side, no line between them.
                    let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    cell.verticalAlignment = .middleAlignment
                    cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                    cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                    cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
                    cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.textBlocks = [cell]
                    switch alignments[safe: column] ?? .leading {
                    case .leading: paragraph.alignment = .natural
                    case .center: paragraph.alignment = .center
                    case .trailing: paragraph.alignment = .right
                    }
                    let text = column < cells.count ? cells[column] : ""
                    // An empty cell still holds a paragraph.
                    out.append(text.isEmpty ? NSAttributedString(string: " ", attributes: [.font: font, .paragraphStyle: paragraph])
                                            : inline(text, font: row == 0 ? bold : font, style: paragraph))
                    let last = row == all.count - 1 && column == table.numberOfColumns - 1
                    // The cell's own newline, but the table's last: a tab between cells, a newline between rows.
                    if !last {
                        let copyAs = column == table.numberOfColumns - 1 ? "\n" : "\t"
                        out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph, .chatCopyAs: copyAs]))
                    }
                }
            }
            tables.append(NSRange(location: start, length: out.length - start))
        }

        /// Inline markdown (bold, italic, `code`, links, strikethrough) in `font`; plain text when it doesn't parse.
        /// Inline code naming a file that exists (relative to `folder`) becomes a link that opens it. A line break
        /// inside the text stays in its paragraph.
        private func inline(_ text: String, font: NSFont, style: NSParagraphStyle, codeSize: CGFloat? = nil) -> NSAttributedString {
            let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
            let text = text.replacingOccurrences(of: "\n", with: "\u{2028}")
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            options.failurePolicy = .returnPartiallyParsedIfPossible
            guard let parsed = try? AttributedString(markdown: text, options: options) else {
                return NSAttributedString(string: text, attributes: base)
            }
            let out = NSMutableAttributedString()
            for run in parsed.runs {
                let piece = String(parsed[run.range].characters)
                var attributes = base
                var runFont = font
                let intent = run.inlinePresentationIntent ?? []
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                runFont = fonts.styled(runFont, traits)
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if intent.contains(.code) {
                    runFont = fonts.inlineCode[codeSize ?? font.pointSize - 1] ?? fonts.inlineCode[size - 1] ?? runFont
                    attributes[.backgroundColor] = NSColor.chatCodeChip
                    if let path = PathLinks.target(piece, cwd: folder) { attributes[.link] = URL(fileURLWithPath: path) }
                }
                if let link = run.link { attributes[.link] = link }
                if let link = attributes[.link] as? URL {
                    // In the link colour, underlined, the address in its tooltip.
                    attributes[.foregroundColor] = NSColor.linkColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.toolTip] = link.isFileURL ? link.path : link.absoluteString
                }
                attributes[.font] = runFont
                out.append(NSAttributedString(string: piece, attributes: attributes))
            }
            return out
        }
    }
}

extension SyntaxColors {
    /// Colored code for a text view.
    static func ns(_ code: String, language: String?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for token in SyntaxHighlight.tokens(code, language: language) {
            let color: NSColor
            switch token.kind {
            case .keyword: color = .systemPink
            case .string: color = .systemOrange
            case .comment: color = .secondaryLabelColor
            case .number: color = .systemPurple
            case .type: color = .systemTeal
            case .plain: color = .labelColor
            }
            out.append(NSAttributedString(string: String(code[token.range]), attributes: [.foregroundColor: color]))
        }
        return out
    }
}

extension NSColor {
    /// SwiftUI's `Color.secondary.opacity(opacity)`: the secondary label colour with its own alpha times `opacity`
    /// (`withAlphaComponent` replaces it, twice as dark in light mode).
    static func secondary(_ opacity: CGFloat, name: NSColor.Name? = nil) -> NSColor {
        NSColor(name: name) { appearance in
            var alpha: CGFloat = 1
            appearance.performAsCurrentDrawingAppearance { alpha = NSColor.secondaryLabelColor.alphaComponent }
            return NSColor.secondaryLabelColor.withAlphaComponent(alpha * opacity)
        }
    }

    /// Inline code's background: one colour, so a block's text built again is the same text.
    static let chatCodeChip = secondary(0.15, name: "vibeswitcher.chatCodeChip")
}

// MARK: - The view

/// Draws the selection of a message the drag has gone through as the message it started in draws its own: blue while
/// the window is key, not the grey of a text view that isn't focused.
final class ChatLayoutManager: NSLayoutManager {
    /// The code blocks' boxes, the quotes' bars and the rules under the text and its selection.
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        (firstTextView as? ChatTextView)?.drawDecorations(at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// A code block that scrolls sideways is drawn by its scroller (`ChatCodeScroll`), not here.
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let view = firstTextView as? ChatTextView else { return super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin) }
        var location = glyphsToShow.location
        for hidden in view.scrolledCodeGlyphs() where NSMaxRange(hidden) > location && hidden.location < NSMaxRange(glyphsToShow) {
            if hidden.location > location { super.drawGlyphs(forGlyphRange: NSRange(location: location, length: hidden.location - location), at: origin) }
            location = max(location, NSMaxRange(hidden))
        }
        if location < NSMaxRange(glyphsToShow) {
            super.drawGlyphs(forGlyphRange: NSRange(location: location, length: NSMaxRange(glyphsToShow) - location), at: origin)
        }
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange,
                                          color: NSColor) {
        guard let view = firstTextView as? ChatTextView else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
        if color == NSColor.unemphasizedSelectedTextBackgroundColor, view.drawsGroupSelection {
            NSColor.selectedTextBackgroundColor.setFill()
        }
        let selection = color == NSColor.selectedTextBackgroundColor || color == NSColor.unemphasizedSelectedTextBackgroundColor
        if !selection, let container = view.textContainer {
            // Inline code's chip, as MarkdownView's: as tall as its line's text, not its spacing below, and as wide as its
            // characters on a line it wraps from, not to the line's end.
            let origin = view.textContainerOrigin
            let spacing = (view.textStorage?.attribute(.paragraphStyle, at: charRange.location, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing ?? 0
            let rects = (0..<rectCount).map { index -> NSRect in
                var rect = rectArray[index]
                let glyph = glyphIndex(for: NSPoint(x: rect.minX - origin.x + 1, y: rect.midY - origin.y), in: container)
                let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
                rect.size.width = max(0, min(rect.maxX, used.maxX) - rect.minX)
                rect.size.height = max(0, min(rect.maxY, used.maxY - spacing) - rect.minY)
                return rect
            }
            return rects.withUnsafeBufferPointer { buffer in
                super.fillBackgroundRectArray(buffer.baseAddress!, count: buffer.count, forCharacterRange: charRange, color: color)
            }
        }
        // A code block's first line holds the room above it for the header: the selection leaves the header alone.
        let bands = view.codeHeaderBands()
        var rects = Array(UnsafeBufferPointer(start: rectArray, count: rectCount))
        if !bands.isEmpty {
            rects = rects.map { rect in
                var rect = rect
                // The first line's rectangle starts above the box, at the space before it.
                for band in bands where rect.minY < band.maxY && rect.maxY > band.maxY && rect.intersects(band) {
                    rect.size.height -= band.maxY - rect.minY
                    rect.origin.y = band.maxY
                }
                return rect
            }
        }
        rects.withUnsafeBufferPointer { buffer in
            super.fillBackgroundRectArray(buffer.baseAddress!, count: buffer.count, forCharacterRange: charRange, color: color)
        }
    }
}

/// One message's text. Not editable; selectable, and a drag goes on into the messages above or below.
final class ChatTextView: NSTextView {
    private(set) var content: ChatTextContent?
    var extraMenu: [ChatTextMenuItem] = []
    var showAll: (Int) -> Void = { _ in }
    /// Where ⌘C and Copy write (a test's own pasteboard).
    var pasteboard = NSPasteboard.general
    private weak var runner: ChatRunner?
    /// Each code block's header (language, Run, Copy), its "Show all" when it's cut short, and its scroller while a
    /// line of it is wider than its box.
    private var overlays: [Overlay] = []
    private struct Overlay {
        let ref: ChatCodeRef
        let header: ChatCodeHeader
        let showAll: NSButton?
        var scroll: ChatCodeScroll?

        func remove() {
            header.removeFromSuperview()
            showAll?.removeFromSuperview()
            scroll?.removeFromSuperview()
        }
    }
    private var sizes: [CGFloat: CGSize] = [:]

    /// The messages the last drag selected across, in order. Weak: a message scrolled out of the chat goes.
    private static var group: [Weak] = []
    private struct Weak { weak var view: ChatTextView? }

    convenience init() {
        // The text view makes and owns its TextKit 1 objects; a stack made here and handed to it was owned by no one,
        // its storage and layout manager holding each other after the view was gone (338 left after the footprint
        // bench's churn).
        self.init(usingTextLayoutManager: false)
        let layout = ChatLayoutManager()
        layout.allowsNonContiguousLayout = false
        textContainer?.replaceLayoutManager(layout)
        textContainer?.size = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = false
        textContainer?.lineFragmentPadding = 0
        frame = NSRect(x: 0, y: 0, width: 100, height: 20)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        usesFindBar = false
        isAutomaticLinkDetectionEnabled = false
        // Nothing to check or rewrite in a message: left on, each text set scheduled a text check (the first made the
        // spell checker) and each selection set told Writing Tools (the first loaded its library), in the open's turn.
        enabledTextCheckingTypes = 0
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        if #available(macOS 15.0, *) { writingToolsBehavior = .none }
        // The text gives links their colour and underline; here, the hand over them.
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
        setAccessibilityRoleDescription("message")
    }

    override var isFlipped: Bool { true }

    /// Lets go of its text and layout, in a pool of its own, once it's off screen for good (`dismantleNSView`): left to
    /// AppKit as the view went, the text storage was autoreleased into a pool that didn't drain, holding the message's
    /// text, its layout manager and container (334 of them after the footprint bench's churn). Not in deinit: the
    /// storage's edit reaches back to the view.
    func tearDown() {
        removeOverlays()
        autoreleasepool {
            textStorage?.setAttributedString(NSAttributedString())
            if let layoutManager { textStorage?.removeLayoutManager(layoutManager) }
        }
        content = nil
        NotificationCenter.default.removeObserver(self)
        layer?.contents = nil
    }

    // MARK: Drawn only on screen

    /// Off screen a message keeps no drawing: each text view's layer held a drawing of all of it, on screen or not (the
    /// footprint bench's churn read 110 MB more of graphics memory, 0.5 s after a window closed, than with a SwiftUI
    /// Text per paragraph), and every turn of a page drew every message again. Its layer is emptied instead
    /// (`updateLayer`), and it's drawn once it comes into view (scrolled to, or moved there).
    private var parked = false

    /// Outside the chat's scroll view's viewport. (Its `visibleRect` isn't cut to its bounds: no view clips to its bounds
    /// on the way up, so it's the viewport's rectangle, wherever that is.)
    private var offScreen: Bool { window == nil || !visibleRect.intersects(bounds) }

    override var wantsUpdateLayer: Bool { offScreen }

    override func updateLayer() {
        parked = true
        layer?.contents = nil
    }

    /// Drawn again on coming into view; let go of its drawing on leaving it (a row drawn before it was placed, then
    /// moved out of the viewport, kept it).
    private func placed() {
        if offScreen != parked { needsDisplay = true }
        if !offScreen { parked = false }
    }

    /// Into view by the chat scrolling (its clip view's bounds), or by its row moving (SwiftUI moves the view holding
    /// this one, not this one).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard window != nil else { return }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSView.boundsDidChangeNotification, object: clip)
        }
        if let holder = superview {
            holder.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSView.frameDidChangeNotification, object: holder)
        }
        placed()
    }

    @objc private func moved(_ note: Notification) { placed() }

    private func removeOverlays() {
        overlays.forEach { $0.remove() }
        overlays = []
    }

    func set(_ content: ChatTextContent, runner: ChatRunner?) {
        let newRunner = runner !== self.runner
        self.runner = runner
        guard content.key != self.content?.key else {
            if newRunner, !content.codeBlocks.isEmpty { updateOverlays(all: true) }
            return
        }
        let old = self.content
        self.content = content
        sizes = [:]
        // A reply still coming in keeps what's selected of it.
        let selected = selectedRange()
        replacing = true
        replaceText(old: old, new: content)
        replacing = false
        if selected.length > 0, NSMaxRange(selected) <= content.string.length, selectedRange() != selected { setSelectedRange(selected) }
        updateOverlays(all: newRunner)
        needsLayout = true
    }

    /// Only the blocks from the first that changed: a reply coming in redoes its last block, not every one before it.
    private func replaceText(old: ChatTextContent?, new: ChatTextContent) {
        guard let storage = textStorage else { return }
        guard let old, storage.length == old.string.length else { return storage.setAttributedString(new.string) }
        var same = 0
        while same < min(old.units.count, new.units.count), old.units[same].key == new.units[same].key { same += 1 }
        let from = same < old.units.count ? old.units[same].range.location : old.string.length
        let to = same < new.units.count ? new.units[same].range.location : new.string.length
        guard from == to else { return storage.setAttributedString(new.string) }
        let replaced = NSRange(location: from, length: old.string.length - from)
        let replacement = new.string.attributedSubstring(from: NSRange(location: to, length: new.string.length - to))
        guard replaced.length > 0 || replacement.length > 0 else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: replaced, with: replacement)
        storage.endEditing()
    }

    /// Set while the text is replaced (`set`): the layout manager hands back the selection it had, unmoved, and each
    /// time AppKit told accessibility zoom and input analytics of it, half of what setting a message's text cost.
    private var replacing = false

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if replacing, !stillSelecting, ranges == selectedRanges { return }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    /// The text's size at `width`: as tall as its lines, as wide as its longest.
    func fittingSize(width: CGFloat) -> CGSize {
        if let size = sizes[width] { return size }
        guard let layoutManager, let textContainer else { return .zero }
        // A text view keeps its container no wider than itself: as wide as `width` first (SwiftUI gives it its frame next).
        if frame.width != width { super.setFrameSize(NSSize(width: width, height: frame.height)) }
        setContainerWidth(width)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        // Code blocks and tables take the full width; a prompt's lines only theirs.
        // A code block at the end: its box goes below its last line.
        let bottom = codeBoxes().last.map { max(used.maxY, $0.maxY) } ?? used.maxY
        let size = CGSize(width: ceil(used.maxX) + 1, height: max(ceil(bottom), ceil(font?.pointSize ?? 13)))
        sizes[width] = size
        return size
    }

    private func setContainerWidth(_ width: CGFloat) {
        guard let textContainer, textContainer.size.width != width else { return }
        textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setContainerWidth(newSize.width)
        placeOverlays()
        placed()
    }

    // MARK: Code block headers

    /// The headers and scrollers of the code blocks that changed (all: every one), the others left as they are.
    private func updateOverlays(all: Bool) {
        let refs = content?.codeBlocks.map(\.ref) ?? []
        for index in overlays.indices.reversed() where index >= refs.count || all || !overlays[index].ref.same(as: refs[index]) {
            overlays[index].remove()
            if index >= refs.count { overlays.remove(at: index) }
        }
        for (index, ref) in refs.enumerated() {
            if index < overlays.count, !all, overlays[index].ref.same(as: ref) { continue }
            let overlay = makeOverlay(ref)
            if index < overlays.count { overlays[index] = overlay } else { overlays.append(overlay) }
        }
        placeOverlays()
    }

    private func makeOverlay(_ ref: ChatCodeRef) -> Overlay {
        let runnable = RunnableCommand.runnable(code: ref.code, language: ref.language, visibleLines: ref.limited ? ref.shownLines : nil)
        // AppKit: an NSHostingView per code block cost a page's rows ~0.6 ms each. SwiftUI only for Run, which
        // follows whether the session can take it.
        let header = ChatCodeHeader(language: ref.language, code: ref.code,
                                    run: runner.flatMap { runner in runnable.map { RunButton(runner: runner, runnable: $0) } })
        addSubview(header)
        var more: NSButton?
        if ref.limited {
            let button = ChatCodeHeader.button("Show all \(ref.lineCount) lines", symbol: nil) { [weak self] in self?.showAll(ref.index) }
            button.font = .systemFont(ofSize: 11)
            button.contentTintColor = .linkColor
            addSubview(button)
            more = button
        }
        return Overlay(ref: ref, header: header, showAll: more, scroll: nil)
    }

    /// The first and last lines of `range` (their used rectangles: without the spacing before or after them).
    private func lines(of range: NSRange) -> (first: NSRect, last: NSRect)? {
        guard let layoutManager, range.length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        return (layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil),
                layoutManager.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil))
    }

    /// Each code block's box in the text container: the container's width, from its header to below its last line.
    private func codeBoxes() -> [NSRect] {
        guard let content, let layoutManager, let textContainer else { return [] }
        layoutManager.ensureLayout(for: textContainer)
        let pad = ChatTextContent.codePadding
        return content.codeBlocks.map { entry in
            guard let lines = lines(of: entry.range) else { return .zero }
            let top = lines.first.minY - pad - ChatTextContent.codeHeader
            // The last line's rectangle holds its line spacing (2), but at the end of the text.
            let bottom = lines.last.maxY + pad - 2 + (entry.ref.limited ? ChatTextContent.showAllHeight : 0)
            return NSRect(x: 0, y: top, width: textContainer.size.width, height: bottom - top)
        }
    }

    /// Each code block's header and the padding below it, in the view.
    func codeHeaderBands() -> [NSRect] {
        let origin = textContainerOrigin
        return codeBoxes().map { box in
            NSRect(x: box.minX, y: box.minY, width: box.width, height: ChatTextContent.codeHeader + ChatTextContent.codePadding)
                .offsetBy(dx: origin.x, dy: origin.y)
        }
    }

    /// The code blocks' boxes (rounded, their header bands, where the language, Run and Copy sit, shaded), the
    /// quotes' bars and the rules, under the text.
    func drawDecorations(at origin: NSPoint) {
        guard let content else { return }
        for box in codeBoxes() where !box.isEmpty {
            let rect = box.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0.5, dy: 0.5)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            NSColor.textBackgroundColor.withAlphaComponent(0.55).setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSColor.secondary(0.08).setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: ChatTextContent.codeHeader).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.secondary(0.2).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        NSColor.controlAccentColor.withAlphaComponent(0.6).setFill()
        for quote in content.quotes {
            guard let lines = lines(of: quote) else { continue }
            NSRect(x: origin.x, y: origin.y + lines.first.minY, width: 3, height: lines.last.maxY - lines.first.minY).fill()
        }
        for table in content.tables { drawTable(table, at: origin) }
        NSColor.separatorColor.setFill()
        for rule in content.rules {
            guard let lines = lines(of: rule), let textContainer else { continue }
            NSRect(x: origin.x, y: origin.y + lines.first.midY, width: textContainer.size.width, height: 1).fill()
        }
    }

    /// A table as MarkdownView's grid: its header row and every other row shaded, a line between rows, a rounded border.
    private func drawTable(_ range: NSRange, at origin: NSPoint) {
        guard let layoutManager, let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        var rows: [Int: NSRect] = [:]
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
            guard let cell = (value as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            // The table's last cell, ended by the message's next block, has none: its row's other cells have.
            let bounds = layoutManager.boundsRect(for: cell, glyphRange: glyphs)
            guard !bounds.isEmpty else { return }
            let placed = bounds.offsetBy(dx: origin.x, dy: origin.y)
            rows[cell.startingRow] = rows[cell.startingRow].map { $0.union(placed) } ?? placed
        }
        guard let outer = rows.values.reduce(nil, { (all: NSRect?, row) in all.map { $0.union(row) } ?? row }) else { return }
        let shape = NSBezierPath(roundedRect: outer.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        for (row, rect) in rows where row == 0 || row % 2 == 0 {
            NSColor.secondary(row == 0 ? 0.12 : 0.05).setFill()
            NSRect(x: outer.minX, y: rect.minY, width: outer.width, height: rect.height).fill()
        }
        NSColor.separatorColor.setFill()
        for (row, rect) in rows where row > 0 {
            NSRect(x: outer.minX, y: rect.minY - 0.5, width: outer.width, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.secondary(0.25).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    private func placeOverlays() {
        guard !overlays.isEmpty, let content else { return }
        let origin = textContainerOrigin
        let pad = ChatTextContent.codePadding
        var scrollersChanged = false
        for (index, box) in codeBoxes().enumerated() where index < overlays.count && index < content.codeBlocks.count {
            let box = box.offsetBy(dx: origin.x, dy: origin.y)
            overlays[index].header.frame = NSRect(x: box.minX, y: box.minY, width: box.width, height: ChatTextContent.codeHeader)
            if let more = overlays[index].showAll {
                let size = more.fittingSize
                more.frame = NSRect(x: box.minX + pad, y: box.maxY - ChatTextContent.showAllHeight - 2, width: size.width, height: size.height)
            }
            // Wider than the box: its lines in a scroller over the box, the text's own left undrawn.
            let range = content.codeBlocks[index].range
            let wide = overlays[index].ref.widest > box.width - 2 * pad
            if wide, overlays[index].scroll == nil, let storage = textStorage {
                let scroll = ChatCodeScroll(code: storage.attributedSubstring(from: range))
                addSubview(scroll, positioned: .below, relativeTo: overlays[index].header)
                overlays[index].scroll = scroll
                scrollersChanged = true
            } else if !wide, let scroll = overlays[index].scroll {
                scroll.removeFromSuperview()
                overlays[index].scroll = nil
                scrollersChanged = true
            }
            if let scroll = overlays[index].scroll, let lines = lines(of: range) {
                scroll.frame = NSRect(x: box.minX + pad, y: origin.y + lines.first.minY, width: box.width - 2 * pad,
                                      height: lines.last.maxY - lines.first.minY)
            }
        }
        if scrollersChanged { needsDisplay = true }
    }

    /// The glyphs of the code blocks their scrollers draw.
    func scrolledCodeGlyphs() -> [NSRange] {
        guard let content, let layoutManager else { return [] }
        return zip(overlays, content.codeBlocks).compactMap { overlay, block in
            overlay.scroll == nil ? nil : layoutManager.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
        }
    }

    /// Sideways over a code block that scrolls: that block's; anything else, the chat's.
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
           let scroll = overlays.lazy.compactMap(\.scroll).first(where: { $0.frame.insetBy(dx: 0, dy: -4).contains(point) }) {
            return scroll.scrollWheel(with: event)
        }
        super.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        placeOverlays()
    }

    // MARK: Selecting across messages

    /// Shown in the selection colour of a focused text view: one of the messages a drag in this window selected.
    var drawsGroupSelection: Bool {
        guard let window, window.isKeyWindow, let focused = window.firstResponder as? ChatTextView, focused !== self else { return false }
        return Self.group.contains { $0.view === self } && Self.group.contains { $0.view === focused }
    }

    /// The chat's messages in this window, top to bottom.
    private func messages() -> [ChatTextView] {
        guard let root = enclosingScrollView?.documentView ?? window?.contentView else { return [self] }
        var found: [ChatTextView] = []
        func walk(_ view: NSView) {
            if let text = view as? ChatTextView { found.append(text); return }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.map { ($0, $0.convert($0.bounds, to: root)) }
            .sorted { a, b in
                let flipped = root.isFlipped
                let ay = flipped ? a.1.minY : -a.1.maxY, by = flipped ? b.1.minY : -b.1.maxY
                return ay != by ? ay < by : a.1.minX < b.1.minX
            }
            .map(\.0)
    }

    /// Selects from character `start` of `anchor` to the point under `location` (in window coordinates), through every
    /// message between them, and nothing in the rest of `messages`.
    static func select(in messages: [ChatTextView], from anchor: ChatTextView, at start: Int, to location: NSPoint) {
        guard let anchorIndex = messages.firstIndex(where: { $0 === anchor }) else { return }
        // The first message the point isn't below; past the last one, the last one's end.
        var targetIndex = messages.count - 1
        var offset = messages[targetIndex].string.utf16.count
        for (index, view) in messages.enumerated() {
            let point = view.convert(location, from: nil)
            guard point.y <= view.bounds.maxY else { continue }
            targetIndex = index
            offset = point.y < view.bounds.minY ? 0 : view.characterIndexForInsertion(at: point)
            break
        }
        select(in: messages, from: (anchorIndex, start), to: (targetIndex, offset))
    }

    /// Selects from (message, character) to (message, character) in `messages`, in either direction.
    static func select(in messages: [ChatTextView], from: (Int, Int), to: (Int, Int)) {
        let (low, high) = from.0 < to.0 || (from.0 == to.0 && from.1 <= to.1) ? (from, to) : (to, from)
        var group: [Weak] = []
        for (index, view) in messages.enumerated() {
            let length = view.string.utf16.count
            let range: NSRange
            if index < low.0 || index > high.0 {
                range = NSRange(location: min(view.selectedRange().location, length), length: 0)
            } else {
                let lower = index == low.0 ? min(low.1, length) : 0
                let upper = index == high.0 ? min(high.1, length) : length
                range = NSRange(location: lower, length: max(0, upper - lower))
                group.append(Weak(view: view))
            }
            if view.selectedRange() != range { view.setSelectedRange(range) }
        }
        Self.group = group
        messages.forEach { $0.needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        // Double and triple clicks select a word or a paragraph, shift-click extends: in this message, as AppKit does.
        guard event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              let window else { return super.mouseDown(with: event) }
        let pressed = press(at: event.locationInWindow)
        var messages = pressed.messages
        let start = pressed.start
        var last = event
        var dragged = false
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        tracking: while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            switch next.type {
            case .leftMouseUp:
                break tracking
            case .leftMouseDragged:
                last = next
                if !dragged, hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) < 3 { continue }
                dragged = true
            default:
                guard dragged else { continue }
            }
            // Scrolled: the chat may have made the rows coming into view.
            if autoscroll(with: last) { messages = self.messages() }
            Self.select(in: messages, from: self, at: start, to: last.locationInWindow)
        }
        if !dragged {
            let index = messages.firstIndex { $0 === self } ?? 0
            Self.select(in: messages, from: (index, start), to: (index, start))
            click(at: start)
        }
    }

    /// The button going down at `location` (in the window): this message becomes the window's first responder (so
    /// its selection draws in the active colour and ⌘C comes here), and nothing is selected but the caret there.
    /// The chat's messages, and the character pressed on.
    func press(at location: NSPoint) -> (messages: [ChatTextView], start: Int) {
        let messages = messages()
        let start = characterIndexForInsertion(at: convert(location, from: nil))
        window?.makeFirstResponder(self)
        Self.select(in: messages, from: self, at: start, to: location)
        return (messages, start)
    }

    /// A click (no drag) at character `index`: on a link, opens it.
    func click(at index: Int) {
        guard index < string.utf16.count, let link = textStorage?.attribute(.link, at: index, effectiveRange: nil) else { return }
        clicked(onLink: link, at: index)
    }

    override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        for message in Self.group.compactMap(\.view) where message !== self {
            message.setSelectedRange(NSRange(location: 0, length: 0))
        }
        Self.group = [Weak(view: self)]
    }

    // MARK: Copying

    /// What's selected, message by message: this one's, or each one's the drag went through when this is one of them.
    func selectedParts() -> [(view: ChatTextView, range: NSRange)] {
        let group = Self.group.compactMap(\.view)
        let views = group.contains { $0 === self } ? group : [self]
        return views.compactMap { view in
            let range = view.selectedRange()
            return range.length > 0 ? (view, range) : nil
        }
    }

    /// The selection as plain text: each message's part, a blank line between them.
    func selectedPlainText() -> String {
        selectedParts().compactMap { part in part.view.textStorage.map { ChatTextContent.plainText($0, range: part.range) } }
            .joined(separator: "\n\n")
    }

    override func copy(_ sender: Any?) {
        let parts = selectedParts()
        guard !parts.isEmpty else { return }
        let rich = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            guard let storage = part.view.textStorage else { continue }
            if index > 0 { rich.append(NSAttributedString(string: "\n\n")) }
            rich.append(storage.attributedSubstring(from: part.range))
        }
        // Pasted elsewhere it takes that place's colours, not the chat's (white on white in dark mode otherwise).
        let all = NSRange(location: 0, length: rich.length)
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .cursor, .chatCode, .chatCopyAs] {
            rich.removeAttribute(key, range: all)
        }
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .rtf], owner: nil)
        pasteboard.setString(selectedPlainText(), forType: .string)
        if let rtf = rich.rtf(from: all, documentAttributes: [:]) { pasteboard.setData(rtf, forType: .rtf) }
    }

    /// Services and dragging the selection out: the same plain text.
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else { return super.writeSelection(to: pboard, type: type) }
        let text = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
            .map { ChatTextContent.plainText(storage, range: $0) }.joined(separator: "\n")
        return pboard.setString(text, forType: .string)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedParts().isEmpty }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let all = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        if !extraMenu.isEmpty {
            menu.addItem(.separator())
            for item in extraMenu {
                let entry = NSMenuItem(title: item.title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = item.action
                menu.addItem(entry)
            }
        }
        return menu
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }
}

/// A code block wider than its box, scrolling sideways over it: its lines drawn here, the message's own text under it
/// left undrawn (`ChatLayoutManager`). Clicks and drags go through to the message, so a selection still runs through
/// the code; a sideways scroll over the block comes here (`ChatTextView.scrollWheel`).
final class ChatCodeScroll: NSScrollView {
    init(code: NSAttributedString) {
        super.init(frame: .zero)
        let text = NSMutableAttributedString(attributedString: code)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.lineBreakMode = .byClipping
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = false
        view.textStorage?.setAttributedString(text)
        view.setAccessibilityElement(false)
        if let layout = view.layoutManager, let container = view.textContainer {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            view.frame = NSRect(x: 0, y: 0, width: ceil(used.width) + ChatTextContent.codePadding, height: ceil(used.height) + 4)
        }
        documentView = view
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        verticalScrollElasticity = .none
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Clicks and drags belong to the message under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A code block's header in a message: its language, Run (when the session takes it) and Copy.
final class ChatCodeHeader: NSView {
    private let code: String
    private let label: NSTextField
    private let copy: ClosureButton
    private let run: NSView?

    init(language: String?, code: String, run: RunButton?) {
        self.code = code
        label = NSTextField(labelWithString: language?.lowercased() ?? "code")
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        copy = Self.button("Copy", symbol: "doc.on.doc") {}
        self.run = run.map { NSHostingView(rootView: $0) }
        super.init(frame: .zero)
        copy.handler = { [weak self] in self?.copyCode() }
        [label, copy].forEach(addSubview)
        self.run.map(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    /// A borderless button in the header's style.
    fileprivate static func button(_ title: String, symbol: String?, action: @escaping () -> Void) -> ClosureButton {
        let button = ClosureButton(title: title, target: nil, action: nil)
        button.handler = action
        button.target = button
        button.action = #selector(ClosureButton.fire(_:))
        button.isBordered = false
        // Out of the key-view loop, as the rows' SwiftUI controls (`chatRowControl`).
        button.refusesFirstResponder = true
        button.font = .systemFont(ofSize: 10.5)
        button.contentTintColor = .secondaryLabelColor
        if let symbol {
            // a11y: the button's title names it.
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            button.imagePosition = .imageLeading
        }
        return button
    }

    private func copyCode() {
        Pasteboard.copy(code)
        show("Copied", symbol: "checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.show("Copy", symbol: "doc.on.doc") }
    }

    private func show(_ title: String, symbol: String) {
        // a11y: the button's title says what it does or did.
        copy.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        copy.title = title
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = ChatTextContent.codePadding
        let labelSize = label.fittingSize
        label.frame = NSRect(x: pad, y: (bounds.height - labelSize.height) / 2, width: labelSize.width, height: labelSize.height)
        let copySize = copy.fittingSize
        copy.frame = NSRect(x: bounds.width - pad - copySize.width, y: (bounds.height - copySize.height) / 2, width: copySize.width, height: copySize.height)
        if let run {
            let size = run.fittingSize
            run.frame = NSRect(x: copy.frame.minX - 12 - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        }
    }
}

/// An NSButton running a closure.
fileprivate final class ClosureButton: NSButton {
    var handler: () -> Void = {}
    @objc func fire(_ sender: Any?) { handler() }
}

/// A code block's header: its language, Run (when the session takes it) and Copy.
struct CodeBlockHeader: View {
    let language: String?
    let code: String
    let runnable: RunnableCommand.Runnable?
    @State private var copied = false
    @Environment(\.chatRunner) private var runner

    var body: some View {
        HStack {
            Text(language?.lowercased() ?? "code").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            if let runner, let runnable { RunButton(runner: runner, runnable: runnable) }
            Button {
                Pasteboard.copy(code)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5))
            }
            .buttonStyle(.borderless)
            .chatRowControl()
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}
