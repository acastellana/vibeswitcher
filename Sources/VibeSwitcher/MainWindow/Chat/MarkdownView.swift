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

extension EnvironmentValues {
    /// The session's folder: relative file paths in replies are resolved against it.
    var chatFolder: String? {
        get { self[ChatFolderKey.self] }
        set { self[ChatFolderKey.self] = newValue }
    }
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
        .textSelection(.enabled)
    }
}

/// Parsed blocks per text, so scrolling and live updates don't re-parse long replies.
enum MarkdownCache {
    private static let cache = NSCache<NSString, Box>()
    private final class Box { let blocks: [MDBlock]; init(_ blocks: [MDBlock]) { self.blocks = blocks } }

    static func blocks(_ text: String) -> [MDBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = MarkdownBlocks.parse(text)
        cache.setObject(Box(blocks), forKey: key)
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
    InlineCache.cache.setObject(InlineCache.Box(attributed), forKey: key)
    return attributed
}

private enum InlineCache {
    final class Box { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }
    static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 2000
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
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
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
        } else if ordered {
            Text("\(number).").font(.system(size: fontSize).monospacedDigit()).foregroundStyle(.secondary)
        } else {
            Text(item.depth == 0 ? "•" : "◦").font(.system(size: fontSize)).foregroundStyle(.secondary)
        }
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

/// A code block: language label, Copy, syntax colors, scrolls sideways instead of wrapping.
struct CodeBlockView: View {
    let language: String?
    let code: String
    /// Lines shown before "Show all" (nil: everything).
    var maxLines: Int? = 40
    @State private var showAll = false
    @State private var copied = false

    var body: some View {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        let limited = !showAll && maxLines.map { lines.count > $0 + 5 } == true
        let shown = limited ? lines.prefix(maxLines ?? 0).joined(separator: "\n") : code
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.lowercased() ?? "code").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxColors.attributed(String(shown), language: language))
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize()
                    .padding(10)
                    .textSelection(.enabled)
            }
            if limited {
                Button("Show all \(lines.count) lines") { showAll = true }
                    .buttonStyle(.borderless).font(.system(size: 11)).padding(.horizontal, 10).padding(.bottom, 8)
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
