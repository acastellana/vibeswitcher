import AppKit
import SwiftUI
import VibeCore

/// The chat's text size (⌘+ / ⌘− while the chat is shown).
enum ChatFont {
    static let key = "chatFontSize"
    static let standard: Double = 13.5

    static func step(_ delta: Int) {
        let current = UserDefaults.standard.object(forKey: key) as? Double ?? standard
        let next = delta == 0 ? standard : min(22, max(10, current + Double(delta)))
        UserDefaults.standard.set(next, forKey: key)
    }
}

private struct ChatFolderKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct ChatRunnerKey: EnvironmentKey { static let defaultValue: ChatRunner? = nil }
private struct ChatTextSelectableKey: EnvironmentKey { static let defaultValue = true }
private struct ChatRowUnexposedKey: EnvironmentKey { static let defaultValue = false }

/// Runs a command from a code block in the selected session (Run, next to Copy). One object for the chat's
/// lifetime: what changes is only whether the session takes it now.
final class ChatRunner: ObservableObject {
    /// A window session you can type into is selected.
    @Published var canRun = false
    /// Types the prompt into it; false when it couldn't.
    var run: (String) -> Bool = { _ in false }
}

extension EnvironmentValues {
    /// The session's folder: relative file paths in replies are resolved against it.
    var chatFolder: String? {
        get { self[ChatFolderKey.self] }
        set { self[ChatFolderKey.self] = newValue }
    }

    var chatRunner: ChatRunner? {
        get { self[ChatRunnerKey.self] }
        set { self[ChatRunnerKey.self] = newValue }
    }

    /// The chat's row is out of accessibility's sight (`ChatExposure`): its AppKit text views leave the tree too, which
    /// `accessibilityHidden` doesn't reach.
    var chatRowUnexposed: Bool {
        get { self[ChatRowUnexposedKey.self] }
        set { self[ChatRowUnexposedKey.self] = newValue }
    }

    /// Whether the chat's text can be selected yet (see `ChatTextSelection`).
    var chatTextSelectable: Bool {
        get { self[ChatTextSelectableKey.self] }
        set { self[ChatTextSelectableKey.self] = newValue }
    }
}

/// Selectable text, once `chatTextSelectable` says so. On the Mac a selectable Text is an AppKit text field of its own,
/// and making one for every paragraph of a page was about a quarter of what opening a conversation or showing an earlier
/// page cost the main thread (2026-10-20, the chat bench's fixture: 0.035 s of 0.155 s a page). A row's text becomes
/// selectable when the pointer first reaches it, before any click or drag can start there (`ChatItemView`).
struct ChatTextSelection: ViewModifier {
    @Environment(\.chatTextSelectable) private var selectable

    func body(content: Content) -> some View {
        if selectable { content.textSelection(.enabled) } else { content }
    }
}

extension View {
    func chatTextSelection() -> some View { modifier(ChatTextSelection()) }
}

/// A reply rendered as markdown blocks.
struct MarkdownView: View {
    let text: String
    /// nil: the chat's text size.
    var fontSize: CGFloat?
    @AppStorage(ChatFont.key) private var chatFontSize = ChatFont.standard
    @Environment(\.chatFolder) private var folder

    var body: some View {
        let size = fontSize.map { $0 + CGFloat(chatFontSize - ChatFont.standard) } ?? CGFloat(chatFontSize)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownCache.blocks(text).enumerated()), id: \.offset) { _, block in
                BlockView(block: block, fontSize: size, folder: folder)
            }
        }
        .chatTextSelection()
    }
}

/// Parsed blocks per text, so scrolling and live updates don't re-parse long replies. Bounded by the text it holds
/// (about the shown page's replies a few times over), not only by memory pressure.
enum MarkdownCache {
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 8 << 20
        return cache
    }()
    private final class Box { let blocks: [MDBlock]; init(_ blocks: [MDBlock]) { self.blocks = blocks } }

    static func blocks(_ text: String) -> [MDBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = MarkdownBlocks.parse(text)
        // Its key and its blocks: about twice the text, in UTF-16.
        cache.setObject(Box(blocks), forKey: key, cost: 4 * key.length)
        return blocks
    }
}

/// Inline markdown (bold, italic, `code`, links) as styled text; plain text when it doesn't parse. Inline code
/// naming a file that exists (relative to `folder`) becomes a link that opens it.
func inlineMarkdown(_ text: String, folder: String? = nil, size: CGFloat = 13.5) -> AttributedString {
    let key = "\(folder ?? "")|\(size)|\(text)" as NSString
    if let hit = InlineCache.cache.object(forKey: key) { return hit.value }
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .inlineOnlyPreservingWhitespace
    options.failurePolicy = .returnPartiallyParsedIfPossible
    guard var attributed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
    // Inline code: monospaced on a faint background.
    for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
        attributed[run.range].font = .system(size: size - 1, design: .monospaced)
        attributed[run.range].backgroundColor = Color.secondary.opacity(0.15)
        if let path = PathLinks.target(String(attributed[run.range].characters), cwd: folder) {
            attributed[run.range].link = URL(fileURLWithPath: path)
        }
    }
    InlineCache.cache.setObject(InlineCache.Box(attributed), forKey: key, cost: 4 * key.length)
    return attributed
}

private enum InlineCache {
    final class Box { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }
    static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 2000
        cache.totalCostLimit = 8 << 20
        return cache
    }()
}

private struct BlockView: View {
    let block: MDBlock
    let fontSize: CGFloat
    let folder: String?

    private func inline(_ text: String) -> AttributedString { inlineMarkdown(text, folder: folder, size: fontSize) }

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: level == 1 ? fontSize + 7 : level == 2 ? fontSize + 4 : fontSize + 1.5, weight: .bold))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            Text(inline(text)).font(.system(size: fontSize)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    MarkerRow(spacing: 7) {
                        marker(ordered: ordered, number: start + index, item: item)
                        Text(inline(item.text)).font(.system(size: fontSize)).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .strikethrough(item.checked == true, color: .secondary)
                            .foregroundStyle(item.checked == true ? .secondary : .primary)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case .code(let language, let text):
            CodeBlockView(language: language, code: text)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor.opacity(0.6)).frame(width: 3)
                Text(inline(text)).font(.system(size: fontSize)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let header, let alignments, let rows):
            TableBlock(header: header, alignments: alignments, rows: rows, fontSize: fontSize, folder: folder)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    @ViewBuilder private func marker(ordered: Bool, number: Int, item: MDListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : .secondary).font(.system(size: fontSize - 1))
                .accessibilityLabel(checked ? "Checked" : "Unchecked")
        } else if ordered {
            Text("\(number).").font(.system(size: fontSize).monospacedDigit()).foregroundStyle(.secondary)
        } else {
            Text(item.depth == 0 ? "•" : "◦").font(.system(size: fontSize)).foregroundStyle(.secondary)
        }
    }
}

/// A list item: its marker at its own size, the text in the rest of the width, their first baselines lined up. What
/// `HStack(alignment: .firstTextBaseline, spacing:)` lays out, without the HStack's sharing out of the width: that measures
/// the text again at no width and at any width (one word a line, then one line), every item of every page shown.
struct MarkerRow: Layout {
    let spacing: CGFloat

    private struct Placed {
        var marker: ViewDimensions
        var text: ViewDimensions
        var markerY: CGFloat
        var textY: CGFloat
    }

    private func place(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Placed? {
        guard subviews.count == 2 else { return nil }
        let marker = subviews[0].dimensions(in: .unspecified)
        let width = proposal.width.map { max(0, $0 - marker.width - spacing) }
        let text = subviews[1].dimensions(in: ProposedViewSize(width: width, height: proposal.height))
        let baseline = max(marker[.firstTextBaseline], text[.firstTextBaseline])
        return Placed(marker: marker, text: text, markerY: baseline - marker[.firstTextBaseline], textY: baseline - text[.firstTextBaseline])
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let placed = place(proposal, subviews) else { return .zero }
        let top = min(placed.markerY, placed.textY)
        let bottom = max(placed.markerY + placed.marker.height, placed.textY + placed.text.height)
        return CGSize(width: placed.marker.width + spacing + placed.text.width, height: bottom - top)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let placed = place(proposal, subviews) else { return }
        let top = bounds.minY - min(placed.markerY, placed.textY)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: top + placed.markerY), proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.minX + placed.marker.width + spacing, y: top + placed.textY),
                          proposal: ProposedViewSize(width: placed.text.width, height: placed.text.height))
    }
}

private struct TableBlock: View {
    let header: [String]
    let alignments: [MDAlign]
    let rows: [[String]]
    let fontSize: CGFloat
    let folder: String?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(header.indices, id: \.self) { column in
                    cell(header[column], column: column, bold: true)
                }
            }
            .background(Color.secondary.opacity(0.12))
            ForEach(rows.indices, id: \.self) { index in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(column < rows[index].count ? rows[index][column] : "", column: column, bold: false)
                    }
                }
                .background(index % 2 == 1 ? Color.secondary.opacity(0.05) : .clear)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func cell(_ text: String, column: Int, bold: Bool) -> some View {
        let alignment: Alignment
        switch alignments[safe: column] ?? .leading {
        case .leading: alignment = .leading
        case .center: alignment = .center
        case .trailing: alignment = .trailing
        }
        return Text(inlineMarkdown(text, folder: folder, size: fontSize - 1))
            .font(.system(size: fontSize - 1, weight: bold ? .semibold : .regular))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Runs a code block's command in the session: typed in as `! command`, so it runs in the session's shell and the
/// output joins the conversation. Shown only while a window session you can type into is selected. Anything longer than
/// one plain line is shown in full first (see `RunnableCommand`); a script block is shown as it is, then written to its
/// private file and run from there.
struct RunButton: View {
    @ObservedObject var runner: ChatRunner
    let runnable: RunnableCommand.Runnable
    @State private var sent = false

    private var prompt: String { runnable.prompt }

    var body: some View {
        if runner.canRun {
            Button {
                guard Self.run(runnable, with: runner, confirm: { Self.confirmation($0).runModal() == .alertFirstButtonReturn })
                else { return }
                sent = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { sent = false }
            } label: {
                Label(sent ? "Sent" : "Run", systemImage: sent ? "checkmark" : "play.fill").font(.system(size: 10.5))
            }
            .buttonStyle(.borderless)
            .chatRowControl()
            .help("Runs it in this session: \(prompt)")
        }
    }

    /// Asks first when it must (`confirm`), writes a script's file, and types the prompt; false when it wasn't typed
    /// (cancelled, the file couldn't be written, or the session couldn't take it: then the file goes too).
    @discardableResult
    static func run(_ runnable: RunnableCommand.Runnable, with runner: ChatRunner,
                    confirm: (RunnableCommand.Runnable) -> Bool) -> Bool {
        guard !runnable.needsConfirmation || confirm(runnable) else { return false }
        do { try runnable.script?.write() } catch {
            NSSound.beep()
            return false
        }
        guard runner.run(runnable.prompt) else {
            if let file = runnable.script?.file { try? FileManager.default.removeItem(at: file) }
            NSSound.beep()
            return false
        }
        return true
    }

    /// The exact text that will run, wrapped so nothing sits off to the side: what's typed, or a script's own lines
    /// with what's typed to run them below.
    static func confirmation(_ runnable: RunnableCommand.Runnable) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Run this in the session?"
        if let script = runnable.script {
            alert.informativeText = "These lines run as one \(script.shell) script, exactly as shown. It's typed as:\n\(runnable.prompt)"
        } else {
            alert.informativeText = "This is exactly what will be typed:"
        }
        let shown = runnable.script?.text ?? runnable.prompt
        let lines = shown.components(separatedBy: "\n").count
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: min(max(CGFloat(lines) * 16 + 12, 60), 320))
        scroll.hasVerticalScroller = true
        if let text = scroll.documentView as? NSTextView {
            text.string = shown
            text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            text.isEditable = false
            text.isSelectable = true
        }
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}

/// A code block: language label, Copy, syntax colors, scrolls sideways instead of wrapping.
struct CodeBlockView: View {
    let language: String?
    let code: String
    /// Lines shown before "Show all" (nil: everything).
    var maxLines: Int? = 40
    @State private var showAll = false

    var body: some View {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        let limited = !showAll && maxLines.map { lines.count > $0 + 5 } == true
        let shown = limited ? lines.prefix(maxLines ?? 0).joined(separator: "\n") : code
        VStack(alignment: .leading, spacing: 0) {
            // No Run while lines are hidden behind "Show all".
            CodeBlockHeader(language: language, code: code,
                            runnable: RunnableCommand.runnable(code: code, language: language, visibleLines: limited ? maxLines : nil))
                .background(Color.secondary.opacity(0.08))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxColors.attributed(String(shown), language: language))
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize()
                    .padding(10)
                    .chatTextSelection()
            }
            if limited {
                Button("Show all \(lines.count) lines") { showAll = true }
                    .buttonStyle(.borderless).font(.system(size: 11)).chatRowControl().padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
    }
}

enum SyntaxColors {
    private final class Box { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 300
        return cache
    }()

    /// Colored code, cached (a long block would otherwise be re-tokenized on every update of the chat).
    static func attributed(_ code: String, language: String?) -> AttributedString {
        let key = "\(language ?? "")|\(code)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let value = tokenized(code, language: language)
        cache.setObject(Box(value), forKey: key)
        return value
    }

    private static func tokenized(_ code: String, language: String?) -> AttributedString {
        var out = AttributedString()
        for token in SyntaxHighlight.tokens(code, language: language) {
            var piece = AttributedString(code[token.range])
            switch token.kind {
            case .keyword: piece.foregroundColor = Color(nsColor: .systemPink)
            case .string: piece.foregroundColor = Color(nsColor: .systemOrange)
            case .comment: piece.foregroundColor = .secondary
            case .number: piece.foregroundColor = Color(nsColor: .systemPurple)
            case .type: piece.foregroundColor = Color(nsColor: .systemTeal)
            case .plain: break
            }
            out += piece
        }
        return out
    }

    /// The code-block language for a file, from its extension.
    static func language(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        let map = ["swift": "swift", "ts": "ts", "tsx": "tsx", "js": "js", "jsx": "jsx", "mjs": "js", "py": "python", "go": "go",
                   "rs": "rust", "sh": "bash", "zsh": "bash", "json": "json", "yml": "yaml", "yaml": "yaml", "toml": "toml",
                   "rb": "ruby", "sql": "sql", "c": "c", "h": "c", "cpp": "cpp", "java": "java", "kt": "kotlin", "md": "markdown"]
        return map[ext]
    }
}
