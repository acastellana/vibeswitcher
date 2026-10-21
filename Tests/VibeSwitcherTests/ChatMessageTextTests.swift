import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// A message in the chat is one selectable text (`ChatMessageText`): a selection goes across its paragraphs, lists and
/// code blocks, and on into the messages below, and ⌘C or the context menu's Copy gives plain text with blank lines
/// between blocks, the list markers and the code as it is. With `CHAT_TEXT_SNAPSHOT_DIR=/some/folder` it also draws a
/// selection across a reply's paragraphs and code block (chat-text-selection-light.png and -dark.png).
@MainActor
@Suite(.serialized)
struct ChatMessageTextTests {
    nonisolated static let folder = ProcessInfo.processInfo.environment["CHAT_TEXT_SNAPSHOT_DIR"]
    let scratch = Scratch()

    static let reply = """
        The first paragraph says what changed.

        The second one says **why**, with `inline code` and a [link](https://example.com/docs).

        The third one comes before the code.

        ```swift
        let answer = 42
            print(answer)
        ```

        - one item
        - another item

        > A quote to finish,
        > on two lines.

        ---

        | Name | Value |
        |------|------:|
        | a    | 1     |
        """

    /// A message's text view at `width`, laid out, copying to a pasteboard of its own.
    func message(_ text: String, kind: ChatTextContent.Kind = .markdown, width: CGFloat = 520) -> ChatTextView {
        let view = ChatTextView()
        view.set(ChatTextContent.make(text, kind: kind, size: 13, folder: nil), runner: nil)
        let size = view.fittingSize(width: width)
        view.frame = NSRect(x: 0, y: 0, width: width, height: size.height)
        view.pasteboard = NSPasteboard(name: NSPasteboard.Name("ChatMessageTextTests-\(UUID().uuidString)"))
        return view
    }

    func copied(_ view: ChatTextView) -> String? {
        view.copy(nil)
        return view.pasteboard.string(forType: .string)
    }

    @Test func aSelectionAcrossParagraphsAndACodeBlockCopiesThemAll() throws {
        let view = message(Self.reply)
        let string = view.string as NSString
        let start = string.range(of: "paragraph says").location
        let end = string.range(of: "print(answer)")
        #expect(start != NSNotFound && end.location != NSNotFound)
        view.setSelectedRange(NSRange(location: start, length: NSMaxRange(end) - start))
        #expect(copied(view) == """
            paragraph says what changed.

            The second one says why, with inline code and a link.

            The third one comes before the code.

            let answer = 42
                print(answer)
            """)
    }

    /// As MarkdownView draws them: a table's cells in the middle of their row's height, inline code in a heading at a
    /// paragraph's size, on SwiftUI's `Color.secondary.opacity(0.15)` (not twice as dark).
    @Test func tableCellsAreCentredAndInlineCodeIsAsMarkdownViews() throws {
        let view = message("# Title with `code`\n\n| A | B |\n|---|---|\n| a cell long enough to wrap onto a second line here | mid |", width: 260)
        let storage = try #require(view.textStorage)
        let layout = try #require(view.layoutManager)
        let string = storage.string as NSString
        let mid = layout.glyphRange(forCharacterRange: string.range(of: "mid"), actualCharacterRange: nil)
        let style = try #require(storage.attribute(.paragraphStyle, at: string.range(of: "mid").location, effectiveRange: nil) as? NSParagraphStyle)
        let cell = try #require(style.textBlocks.last as? NSTextTableBlock)
        let row = layout.boundsRect(for: cell, glyphRange: mid)
        let line = layout.lineFragmentUsedRect(forGlyphAt: mid.location, effectiveRange: nil)
        let long = layout.glyphRange(forCharacterRange: string.range(of: "a cell long"), actualCharacterRange: nil)
        #expect(row.height > 2 * line.height, "the row holds the long cell's two lines: \(row), \(line)")
        #expect(abs(line.midY - row.midY) < 2, "\(line) in \(row)")
        #expect(layout.lineFragmentUsedRect(forGlyphAt: long.location, effectiveRange: nil).minY < line.minY)
        let code = string.range(of: "code").location
        #expect((storage.attribute(.font, at: code, effectiveRange: nil) as? NSFont)?.pointSize == 12)
        #expect(storage.attribute(.backgroundColor, at: code, effectiveRange: nil) as? NSColor == NSColor.chatCodeChip)
        for (name, opacity) in [(NSAppearance.Name.aqua, 0.5 * 0.15), (.darkAqua, 0.55 * 0.15)] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let alpha = NSColor.chatCodeChip.alphaComponent
                #expect(abs(alpha - opacity) < 0.02, "\(name.rawValue): \(alpha)")
            }
        }
    }

    /// Off screen a message keeps no drawing (its layer emptied), and it's drawn once scrolled to: only what's in the
    /// chat's viewport holds a drawing.
    @Test func onlyTheMessagesOnScreenHoldADrawing() throws {
        let chat = ScrollView { VStack(spacing: 8) { ForEach(0..<30, id: \.self) { ChatMessageText(text: "Message \($0).\n\nIts second paragraph.", kind: .markdown, fontSize: 13) } } }
            .frame(width: 400, height: 300)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: chat)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        var texts: [ChatTextView] = []
        func walk(_ view: NSView) { if let text = view as? ChatTextView { texts.append(text) }; view.subviews.forEach(walk) }
        walk(host)
        let drawn = { texts.filter { $0.layer?.contents != nil } }
        #expect(texts.count == 30)
        #expect((1...10).contains(drawn().count), "\(drawn().count) drawn")
        #expect(texts.first?.layer?.contents != nil && texts.last?.layer?.contents == nil)
        let clip = try #require(texts.last?.enclosingScrollView?.contentView)
        let end = (clip.documentView?.frame.height ?? 0) - clip.bounds.height
        clip.scroll(to: NSPoint(x: 0, y: clip.isFlipped ? end : 0))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect((1...10).contains(drawn().count), "\(drawn().count) drawn")
        #expect(texts.first?.layer?.contents == nil && texts.last?.layer?.contents != nil)
    }

    @Test func selectAllCopiesTheWholeMessageWithItsListMarkers() throws {
        let view = message(Self.reply)
        view.selectAll(nil)
        #expect(view.selectedRange() == NSRange(location: 0, length: (view.string as NSString).length))
        #expect(copied(view) == """
            The first paragraph says what changed.

            The second one says why, with inline code and a link.

            The third one comes before the code.

            let answer = 42
                print(answer)

            • one item
            • another item

            A quote to finish,
            on two lines.

            ---

            Name\tValue
            a\t1
            """)
    }

    @Test func theContextMenusCopyCopiesTheSameAndKeepsTheLinkInRTF() throws {
        let view = message(Self.reply)
        view.selectAll(nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(view.menu(for: event))
        let copy = try #require(menu.items.first { $0.title == "Copy" })
        #expect(view.validateUserInterfaceItem(copy))
        _ = (copy.target as AnyObject?)?.perform(copy.action, with: copy)
        let plain = try #require(view.pasteboard.string(forType: .string))
        #expect(plain.hasPrefix("The first paragraph says what changed.\n\nThe second one"))
        #expect(plain.contains("let answer = 42\n    print(answer)"))
        let rtf = try #require(view.pasteboard.data(forType: .rtf))
        let pasted = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let at = (pasted.string as NSString).range(of: "link").location
        #expect(at != NSNotFound)
        let link = pasted.attribute(.link, at: at, effectiveRange: nil)
        #expect((link as? URL)?.absoluteString == "https://example.com/docs" || (link as? String) == "https://example.com/docs")
    }

    @Test func aLongCodeBlockCutShortCopiesInFullWhenAllOfItIsSelected() throws {
        let code = (1...60).map { "line \($0)" }.joined(separator: "\n")
        let view = message("Before.\n\n```\n\(code)\n```\n\nAfter.")
        view.selectAll(nil)
        #expect(copied(view) == "Before.\n\n\(code)\n\nAfter.")
    }

    @Test func aSelectionGoesOnIntoTheMessagesBelowAndCopiesThemInOrder() throws {
        let prompt = message("Can you explain the change?\nIn two lines.", kind: .plain)
        let reply = message(Self.reply)
        let next = message("Thanks, that's all.", kind: .plain)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 2000))
        var y: CGFloat = 0
        for view in [prompt, reply, next] {
            view.frame.origin.y = y
            y += view.frame.height + 20
            document.addSubview(view)
        }
        let messages = [prompt, reply, next]
        let start = (prompt.string as NSString).range(of: "explain").location
        let end = NSMaxRange((reply.string as NSString).range(of: "The second one says why"))
        ChatTextView.select(in: messages, from: (0, start), to: (1, end))
        #expect(prompt.selectedRange().length > 0 && reply.selectedRange().length > 0 && next.selectedRange().length == 0)
        let expected = """
            explain the change?
            In two lines.

            The first paragraph says what changed.

            The second one says why
            """
        #expect(prompt.selectedPlainText() == expected)
        #expect(copied(reply) == expected)

        // Upwards from the last message to the reply's code: the same, in reading order.
        let code = (reply.string as NSString).range(of: "print(answer)").location
        ChatTextView.select(in: messages, from: (2, 6), to: (1, code))
        #expect(copied(next) == "print(answer)\n\n• one item\n• another item\n\nA quote to finish,\non two lines.\n\n---\n\nName\tValue\na\t1\n\nThanks")

        // ⌘A in one message selects that message only.
        reply.selectAll(nil)
        #expect(prompt.selectedRange().length == 0 && next.selectedRange().length == 0)
        #expect(copied(reply)?.hasPrefix("The first paragraph") == true)
    }

    @Test func aReplyStillComingInKeepsItsSelection() throws {
        let view = message("The first paragraph.\n\nThe second")
        view.setSelectedRange(NSRange(location: 4, length: 5))
        view.set(ChatTextContent.make("The first paragraph.\n\nThe second, and more of it.", kind: .markdown, size: 13, folder: nil), runner: nil)
        #expect(view.selectedRange() == NSRange(location: 4, length: 5))
        #expect(copied(view) == "first")
    }

    /// VoiceOver reads each message as one text: its words, under the role "message".
    @Test func voiceOverReadsTheMessage() throws {
        let view = message(Self.reply)
        #expect(view.accessibilityRole() == .textArea)
        #expect(view.accessibilityRoleDescription() == "message")
        let value = try #require(view.accessibilityValue() as? String)
        #expect(value.hasPrefix("The first paragraph says what changed."))
        #expect(value.contains("let answer = 42"))
        #expect(view.isAccessibilityElement())
    }

    /// A link is in the link colour, underlined, its address in its tooltip; a click on it opens it.
    @Test func aLinkLooksLikeOneAndAClickOpensIt() throws {
        let view = message(Self.reply)
        let at = (view.string as NSString).range(of: "link").location
        let storage = try #require(view.textStorage)
        #expect(storage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor == .linkColor)
        #expect(storage.attribute(.underlineStyle, at: at, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(storage.attribute(.toolTip, at: at, effectiveRange: nil) as? String == "https://example.com/docs")
        let opened = LinkCatcher()
        view.delegate = opened
        view.click(at: at + 1)
        #expect((opened.links.first as? URL)?.absoluteString == "https://example.com/docs")
        view.click(at: 2)
        #expect(opened.links.count == 1)
    }

    /// The row's first hover (which comes as a drag ends on it) adds its menu and tooltip around the same text view:
    /// what's selected in it stays.
    @Test func aSelectionSurvivesTheRowsFirstHover() throws {
        let home = scratch.url("chat-row")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let chat = ChatModel(outbox: ComposerOutbox(url: home.appendingPathComponent("outbox.json")), home: home.path, steerRoot: home)
        let item = ChatItem.reply(ChatEntry(id: "r1", at: Date(), kind: .reply(Self.reply)))
        func row(_ reached: Bool) -> ChatItemRow {
            ChatItemRow(item: item, chat: chat, expanded: [], agent: .agent(.claude), rowID: nil, canSend: false, resend: { _ in }, openImage: { _ in },
                        reached: reached)
        }
        let host = NSHostingView(rootView: row(false).frame(width: 600))
        let window = KeyWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 600, height: 600), styleMask: [.borderless],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let before = try #require(Self.texts(in: host).first)
        before.setSelectedRange(NSRange(location: 4, length: 20))
        host.rootView = row(true).frame(width: 600)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let after = try #require(Self.texts(in: host).first)
        #expect(after === before)
        #expect(after.selectedRange() == NSRange(location: 4, length: 20))
        #expect(after.toolTip != nil)
    }

    /// A reply coming in: each update replaces only its last block's characters (or the one before's too, when the new
    /// text joins it), ends as the whole text built at once,
    /// and leaves the headers of code blocks that didn't change as they were. With `purging`, the built texts' caches are
    /// emptied before each update, as when the cache lets them go: the text is the same, block by block.
    @Test(arguments: [false, true]) func aReplyComingInRedoesOnlyItsLastBlock(purging: Bool) throws {
        let full = Self.reply + "\n\nAnd a last paragraph that keeps on growing word by word until it ends."
        let view = message(String(full.prefix(40)))
        let edits = EditRecorder()
        view.textStorage?.delegate = edits
        var header: NSView?
        var cut = 40
        while cut < full.count {
            cut = min(full.count, cut + 17)
            let text = String(full.prefix(cut))
            if purging { ChatTextContent.purge() }
            // The edit starts in what was the last block, or the one before when the new text joins it (a list's next
            // item, after a lone "-" was a paragraph of its own), whatever the cache kept: never further back.
            let units = try #require(view.content?.units)
            let last = units[max(0, units.count - 2)].range.location
            edits.ranges = []
            view.set(ChatTextContent.make(text, kind: .markdown, size: 13, folder: nil), runner: nil)
            #expect(!edits.ranges.isEmpty && edits.ranges.allSatisfy { $0.location >= last }, "after \(cut) characters: \(edits.ranges) from \(last)")
            _ = view.fittingSize(width: 520)
            ChatTextContent.purge()
            let whole = ChatTextContent.make(text, kind: .markdown, size: 13, folder: nil).string
            let storage = try #require(view.textStorage)
            #expect(Self.runs(storage) == Self.runs(whole), "after \(cut) characters")
            // Once the code block is whole, its header stays the same view (while the cache keeps the block).
            if text.contains("print(answer)\n```\n") {
                let now = view.subviews.first { $0 is ChatCodeHeader }
                if let header, !purging { #expect(now === header) }
                header = now
            }
        }
        #expect(header != nil)
    }

    /// The ranges a text storage's edits changed.
    final class EditRecorder: NSObject, NSTextStorageDelegate {
        var ranges: [NSRange] = []
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range: NSRange,
                         changeInLength delta: Int) {
            ranges.append(range)
        }
    }

    /// A text as its characters and, run by run, the attributes that show: what a block built again must give, whatever
    /// objects it's made of (a paragraph style's text blocks by their place in their table, a code block by value).
    static func runs(_ text: NSAttributedString) -> [String] {
        var out = [text.string]
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var parts = ["\(range.location)+\(range.length)"]
            for key in attributes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                let value = attributes[key]!
                switch value {
                case let font as NSFont: parts.append("\(key.rawValue)=\(font.fontName) \(font.pointSize)")
                case let style as NSParagraphStyle: parts.append("\(key.rawValue)=\(Self.describe(style))")
                case let ref as ChatCodeRef: parts.append("\(key.rawValue)=code \(ref.index) \(ref.language ?? "-") \(ref.shownLines)/\(ref.lineCount) \(ref.code.count)")
                default: parts.append("\(key.rawValue)=\(value)")
                }
            }
            out.append(parts.joined(separator: " "))
        }
        return out
    }

    static func describe(_ style: NSParagraphStyle) -> String {
        let blocks = style.textBlocks.map { block -> String in
            guard let cell = block as? NSTextTableBlock else { return String(describing: type(of: block)) }
            return "cell \(cell.startingRow),\(cell.startingColumn) of \(cell.table.numberOfColumns)"
        }
        return [style.lineSpacing, style.paragraphSpacing, style.paragraphSpacingBefore, style.headIndent, style.firstLineHeadIndent,
                style.tailIndent, style.minimumLineHeight, style.maximumLineHeight].map { "\($0)" }.joined(separator: ",")
            + " \(style.alignment.rawValue) \(style.lineBreakMode.rawValue) tabs \(style.tabStops.map(\.location)) \(blocks)"
    }

    /// A press makes the message the window's first responder (taking it from the composer), so its selection draws
    /// in the active colour and ⌘C goes to it. (`mouseDown` begins with it; its tracking loop needs a running app.)
    @Test func aPressMakesTheMessageFirstResponder() throws {
        let view = message(Self.reply)
        let window = KeyWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 520, height: 900), styleMask: [.borderless],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 900))
        root.addSubview(view)
        root.addSubview(field)
        window.contentView = root
        defer { window.close() }
        window.makeFirstResponder(field)
        let pressed = view.press(at: view.convert(NSPoint(x: 30, y: 8), to: nil))
        #expect(window.firstResponder === view)
        #expect(pressed.messages.contains { $0 === view })
        #expect(view.selectedRange().length == 0)
    }

    /// A code line wider than its box isn't wrapped: it scrolls sideways in a scroller over the box, and the message's
    /// own copy of it is left undrawn but still selected and copied.
    @Test func aWideCodeLineScrollsSidewaysInsteadOfWrapping() throws {
        let long = "let reallyLongName = [" + (1...60).map { "item\($0)" }.joined(separator: ", ") + "]"
        let view = message("Before.\n\n```swift\n\(long)\nprint(1)\n```", width: 400)
        let storage = try #require(view.textStorage)
        let layout = try #require(view.layoutManager)
        let code = (storage.string as NSString).range(of: long)
        let glyphs = layout.glyphRange(forCharacterRange: code, actualCharacterRange: nil)
        var fragments = 0
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in fragments += 1 }
        #expect(fragments == 1)
        view.layout()
        let scroll = try #require(view.subviews.first { $0 is ChatCodeScroll } as? NSScrollView)
        #expect((scroll.documentView?.frame.width ?? 0) > scroll.frame.width)
        #expect(view.scrolledCodeGlyphs().count == 1)
        view.selectAll(nil)
        #expect(copied(view)?.contains(long) == true)
        // Wide enough: no scroller, the text draws its own code.
        _ = view.fittingSize(width: 6000)
        view.frame.size.width = 6000
        view.layout()
        #expect(!view.subviews.contains { $0 is ChatCodeScroll })
    }

    /// A table reaches the right edge of the message's column, first in the message or after another block (a top
    /// margin for the space above it narrowed it by as much).
    @Test(arguments: ["", "A paragraph first.\n\n"]) func aTableReachesTheColumnsEdge(before: String) throws {
        let view = message(before + "| Name | Value |\n|------|------:|\n| a | 1 |", width: 500)
        let layout = try #require(view.layoutManager)
        let storage = try #require(view.textStorage)
        var cells: [NSRect] = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let cell = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock else { return }
            cells.append(layout.boundsRect(for: cell, glyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)))
        }
        #expect(cells.count == 4)
        #expect((cells.map(\.minX).min() ?? 99) < 1)
        let end = cells.map(\.maxX).max() ?? 0
        #expect(end > 498 && end <= 500, "the table ends at \(end) of 500")
    }

    static func texts(in view: NSView) -> [ChatTextView] {
        if let text = view as? ChatTextView { return [text] }
        return view.subviews.flatMap { texts(in: $0) }
    }

    @Test func aPromptCopiesAsTyped() throws {
        let text = "First line\n\nSecond paragraph\n- not a list"
        let view = message(text, kind: .plain)
        view.selectAll(nil)
        #expect(copied(view) == text)
    }

    /// A selection from the first paragraph into the code block, drawn as the window shows it.
    @Test(.enabled(if: folder != nil)) func drawASelectionAcrossParagraphs() throws {
        let folder = try #require(Self.folder)
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let view = VStack(alignment: .leading, spacing: 16) {
                ChatMessageText(text: "Please explain the change, then show me the code.", kind: .plain, fontSize: 13, hugs: true)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.16)))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                ChatMessageText(text: Self.reply + "\n\n```\nlet wide = [" + (1...30).map { "\"item \($0)\"" }.joined(separator: ", ") + "]\n```",
                                kind: .markdown, fontSize: 13).padding(.leading, 30)
            }
            .padding(20)
            .frame(width: 620, height: 760, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            let window = KeyWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 620, height: 760), styleMask: [.borderless],
                                   backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme)
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            var texts: [ChatTextView] = []
            func walk(_ view: NSView) {
                if let text = view as? ChatTextView { texts.append(text) } else { view.subviews.forEach(walk) }
            }
            walk(host)
            let reply = try #require(texts.first { $0.string.hasPrefix("The first") })
            let string = reply.string as NSString
            let start = string.range(of: "paragraph says").location
            let end = NSMaxRange(string.range(of: "let answer"))
            window.makeFirstResponder(reply)
            reply.setSelectedRange(NSRange(location: start, length: end - start))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("chat-text-selection-\(scheme == .darkAqua ? "dark" : "light").png"))
        }
    }
}

/// A borderless window that is key (the test process isn't the active app, so none of its windows is), so a selection
/// draws as in the window you type in.
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}

/// Records the links a text view was asked to open, and opens none.
private final class LinkCatcher: NSObject, NSTextViewDelegate {
    var links: [Any] = []
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        links.append(link)
        return true
    }
}
