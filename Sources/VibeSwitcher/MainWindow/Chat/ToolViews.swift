import AppKit
import SwiftUI
import VibeCore

/// A run of tool calls between two messages: one summary line (and any screenshots), opening to each tool.
struct ToolGroupView: View {
    let id: String
    let tools: [ChatTool]
    /// For toggling only: the row doesn't observe the model (see `ChatItemView`).
    let chat: ChatModel
    let expanded: Set<String>
    let openImage: (ChatImage) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let open = expanded.contains(id)
        let images = tools.flatMap { $0.result?.images ?? [] }
        let failed = tools.contains { $0.result?.failed == true }
        let running = tools.contains { $0.result == nil }
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { chat.toggle(id) } } label: {
                HStack(spacing: 8) {
                    HStack(spacing: -4) {
                        ForEach(Array(Set(tools.map(ToolStyle.symbol)).sorted().prefix(4)), id: \.self) { symbol in
                            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.25)))
                        }
                    }
                    Text(ChatTimeline.summary(tools)).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    if running { ProgressView().controlSize(.mini) }
                    if let total = totalDuration, total >= 1 {
                        Text(Durations.short(total)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0)).accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images) { image in Thumbnail(image: image, height: 120) { openImage(image) } }
                    }
                }
            }
            if open {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(tools, id: \.id) { ToolRowView(tool: $0, chat: chat, open: expanded.contains($0.id)) }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1) }
            }
        }
    }

    private var totalDuration: TimeInterval? {
        let durations = tools.compactMap(\.duration)
        return durations.isEmpty ? nil : durations.reduce(0, +)
    }
}

enum ToolStyle {
    static func symbol(_ tool: ChatTool) -> String {
        switch tool.detail {
        case .thought: return "brain"
        case .todos: return "checklist"
        case .plan: return "list.bullet.rectangle"
        case .command: return "terminal"
        case .edit, .patch: return "pencil"
        case .write: return "doc.badge.plus"
        case .read: return "doc.text"
        case .questions: return "questionmark.bubble"
        case .agent: return "person.2"
        case .fields:
            if tool.name.lowercased().contains("chrome") || tool.name.contains("browser") || tool.name == "WebFetch" { return "globe" }
            if ["Grep", "Glob", "WebSearch", "ToolSearch"].contains(tool.name) { return "magnifyingglass" }
            return "wrench.and.screwdriver"
        }
    }
}

struct ToolRowView: View {
    let tool: ChatTool
    let chat: ChatModel
    let open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { chat.toggle(tool.id) } label: {
                HStack(spacing: 7) {
                    Image(systemName: tool.result?.failed == true ? "xmark.octagon.fill" : ToolStyle.symbol(tool))
                        .font(.system(size: 11)).foregroundStyle(tool.result?.failed == true ? .red : .secondary).frame(width: 16)
                        // Spoken only when it says the call failed; otherwise it just repeats the tool's name.
                        .accessibilityLabel("Failed").accessibilityHidden(tool.result?.failed != true)
                    Text(tool.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    if tool.result == nil { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 6)
                    if let duration = tool.duration, duration >= 1 {
                        Text(Durations.short(duration)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0)).accessibilityHidden(true)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ToolDetailView(tool: tool).padding(.leading, 23).padding(.bottom, 8)
            }
        }
    }
}

private struct ToolDetailView: View {
    let tool: ChatTool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch tool.detail {
            case .thought(let text):
                MarkdownView(text: text, fontSize: 12).foregroundStyle(.secondary).italic()
            case .todos(let todos):
                TodoListView(todos: todos)
            case .plan(let plan):
                MarkdownView(text: plan, fontSize: 12.5)
                    .padding(12).background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.07)))
            case .command(let command):
                CodeBlockView(language: "bash", code: command, maxLines: 12)
                output
            case .edit(let path, let changes):
                PathLabel(path: path)
                ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                    DiffView(lines: LineDiff.hunks(LineDiff.lines(old: change.old, new: change.new), context: 3))
                }
                if tool.result?.failed == true { output }
            case .write(let path, let content):
                PathLabel(path: path)
                CodeBlockView(language: SyntaxColors.language(forPath: path), code: content, maxLines: 40)
            case .read(let path):
                PathLabel(path: path)
                output
            case .patch(let patch):
                DiffView(lines: patch.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                    if line.hasPrefix("+"), !line.hasPrefix("+++") { return DiffLine(kind: .added, text: String(line.dropFirst())) }
                    if line.hasPrefix("-"), !line.hasPrefix("---") { return DiffLine(kind: .removed, text: String(line.dropFirst())) }
                    return DiffLine(kind: .same, text: String(line))
                })
                output
            case .questions(let questions):
                ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(question.question).font(.system(size: 12.5, weight: .semibold))
                        FlowChips(options: question.options, chosen: chosen(question))
                    }
                }
            case .agent(let description, let prompt):
                Text(description).font(.system(size: 12.5, weight: .semibold))
                Text(prompt).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled)
                if let result = tool.result, !result.output.isEmpty {
                    MarkdownView(text: result.output, fontSize: 12.5)
                        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
                }
            case .fields(let fields):
                if !fields.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                            GridRow {
                                Text(field.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                Text(field.value).font(.system(size: 11, design: .monospaced)).lineLimit(4).textSelection(.enabled)
                            }
                        }
                    }
                }
                output
            }
        }
    }

    @ViewBuilder private var output: some View {
        if let result = tool.result, !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            OutputView(text: result.output, failed: result.failed, truncated: result.truncated)
        }
    }

    /// The option you picked, from the answer Claude got back: `"question"="option"`.
    private func chosen(_ question: ChatQuestion) -> String? {
        guard let output = tool.result?.output else { return nil }
        return question.options.first { output.contains("=\"\($0)\"") }
    }
}

/// A to-do list or plan steps, with their state.
struct TodoListView: View {
    let todos: [ChatTodo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: todo.status == .done ? "checkmark.circle.fill" : todo.status == .active ? "circle.dotted.circle" : "circle")
                        .foregroundStyle(todo.status == .done ? Color.green : todo.status == .active ? Color.accentColor : Color.secondary)
                        .font(.system(size: 12))
                        .accessibilityLabel(todo.status == .done ? "Done" : todo.status == .active ? "In progress" : "To do")
                    Text(todo.text).font(.system(size: 12.5, weight: todo.status == .active ? .semibold : .regular))
                        .strikethrough(todo.status == .done, color: .secondary)
                        .foregroundStyle(todo.status == .done ? .secondary : .primary)
                }
            }
        }
    }
}

private struct PathLabel: View {
    let path: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.head)
            Button { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") } label: {
                Image(systemName: "arrow.up.forward.square").accessibilityLabel("Reveal in Finder")
            }
                .buttonStyle(.borderless).font(.system(size: 10.5)).help("Reveal in Finder")
        }
    }
}

/// A tool's output: first lines, with "Show all".
private struct OutputView: View {
    let text: String
    let failed: Bool
    let truncated: Bool
    @State private var showAll = false

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let limit = 30
        let shown = showAll || lines.count <= limit + 5 ? text : lines.prefix(limit).joined(separator: "\n")
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(shown).font(.system(size: 11, design: .monospaced)).foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize().textSelection(.enabled).padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.07)))
            if !showAll, lines.count > limit + 5 {
                Button("Show all \(lines.count) lines") { showAll = true }.buttonStyle(.borderless).font(.system(size: 11))
            } else if truncated {
                Text("Output cut at \(ChatReader.outputLimit / 1024) KB").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct DiffView: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 0) {
                        Text(sign(line)).frame(width: 16).foregroundStyle(color(line))
                        Text(line.kind == .gap ? "⋯ \(line.text) unchanged lines" : line.text)
                            .foregroundStyle(line.kind == .gap ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.vertical, 1)
                    .padding(.trailing, 10)
                    .background(background(line))
                }
            }
            .fixedSize()
            .frame(minWidth: 400, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
    }

    private func sign(_ line: DiffLine) -> String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .same, .gap: return " "
        }
    }

    private func color(_ line: DiffLine) -> Color {
        switch line.kind {
        case .added: return .green
        case .removed: return .red
        case .same, .gap: return .secondary
        }
    }

    private func background(_ line: DiffLine) -> Color {
        switch line.kind {
        case .added: return Color.green.opacity(0.14)
        case .removed: return Color.red.opacity(0.14)
        case .same, .gap: return .clear
        }
    }
}

private struct FlowChips: View {
    let options: [String]
    let chosen: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 4) { chips }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(options, id: \.self) { option in
            HStack(spacing: 4) {
                if option == chosen { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).accessibilityLabel("Chosen") }
                Text(option).font(.system(size: 11.5))
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(option == chosen ? Color.white : Color.primary)
            .background(Capsule().fill(option == chosen ? Color.accentColor : Color.secondary.opacity(0.12)))
        }
    }
}

/// An image from the conversation, sized to a height; click to open it. Decoded small, off the main thread.
struct Thumbnail: View {
    let image: ChatImage
    let height: CGFloat
    let open: () -> Void
    @State private var decoded: NSImage?

    var body: some View {
        Group {
            if let decoded {
                Image(nsImage: decoded).resizable().aspectRatio(contentMode: .fit).frame(height: height)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)).frame(width: height * 1.5, height: height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
        .onTapGesture(perform: open)
        .help("Open full size")
        .task(id: image.id) { decoded = await ImageCache.thumbnail(image, maxPixels: Int(height * 2.5)) }
    }
}

enum ImageCache {
    /// Thumbnails by image id; bounded by memory (bytes of the decoded bitmaps).
    private static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()

    static func thumbnail(_ image: ChatImage, maxPixels: Int) async -> NSImage? {
        let key = "\(image.id)@\(maxPixels)" as NSString
        if let hit = thumbnails.object(forKey: key) { return hit }
        let data = image.data
        let decoded: (NSImage, Int)? = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                            kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return (NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)), cgImage.width * cgImage.height * 4)
        }.value
        guard let decoded else { return nil }
        thumbnails.setObject(decoded.0, forKey: key, cost: decoded.1)
        return decoded.0
    }

    /// Full size, for the viewer only (not kept).
    static func full(_ image: ChatImage) -> NSImage? { NSImage(data: image.data) }
}

/// Full-size image with Copy and Save.
struct ImageViewer: View {
    let image: ChatImage
    let close: () -> Void
    @State private var full: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(image.mediaType).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    guard let nsImage = full else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([nsImage])
                }
                Button("Save…") { save() }
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            if let nsImage = full {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(nsImage.size.width, 1400))
                        .padding(12)
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 1000, minHeight: 420, idealHeight: 720)
        .task(id: image.id) {
            let data = image.data
            full = await Task.detached(priority: .userInitiated) { NSImage(data: data) }.value
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "screenshot." + (image.mediaType.split(separator: "/").last.map(String.init) ?? "png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? image.data.write(to: url)
    }
}
