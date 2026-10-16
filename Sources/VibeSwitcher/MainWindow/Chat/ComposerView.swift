import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeCore

/// What the composer can do to the session besides sending text.
struct ComposerActions {
    /// Types the message; false when it was refused (too long).
    var send: (String) -> Bool
    /// Hands the message to the working agent at its next step, without stopping it.
    var steer: (String) -> Bool
    /// Esc: stops the agent's turn.
    var stop: () -> Void
    /// shift+tab: the next permission mode.
    var cycleMode: () -> Void
}

/// The message box under the chat: ↩ sends, ⇧↩ adds a line, ↑ / ↓ in an empty box walk through earlier prompts,
/// `/` completes commands and `@` files. Pasting or dropping an image saves it and inserts its path; dropping
/// files inserts their paths. While the agent works, the stop button (or ⌘.) interrupts it.
struct ComposerView: View {
    @ObservedObject var chat: ChatModel
    let rowID: String
    let agent: Agent
    let working: Bool
    /// Only steering (a Terminal session: nothing can be typed into it from here).
    var steerOnly = false
    let actions: ComposerActions
    @State private var height: CGFloat = 22
    @State private var suggestions = Suggestions()
    @State private var notice: String?

    private var text: Binding<String> {
        Binding(get: { chat.drafts[rowID] ?? "" }, set: { chat.drafts[rowID] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !suggestions.items.isEmpty {
                SuggestionList(suggestions: $suggestions)
            }
            let images = AttachedImages.paths(in: text.wrappedValue)
            if !images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(images, id: \.self) { path in
                        AttachedThumbnail(path: path) { text.wrappedValue = AttachedImages.removing(path, from: text.wrappedValue) }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: attach) { Image(systemName: "paperclip").font(.system(size: 14)) }
                    .buttonStyle(.borderless).padding(.bottom, 9).help("Attach files or images")
                ZStack(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(working ? (steerOnly ? "Steer \(agent.displayName) while it works — ↩ sends it to its next step"
                                                  : "Working — ↩ steers it now without stopping it, ⌥↩ queues for after")
                                     : "Message \(agent.displayName)…  / for commands, @ for files")
                            .font(.system(size: 13)).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(text: text, height: $height, suggestions: $suggestions, history: chat.log.prompts,
                                     focusRequests: chat.focusComposerRequests, complete: complete,
                                     submit: { submit(queue: false) }, queue: { submit(queue: true) })
                        .frame(height: min(max(height, 22), 220))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.3)))
                if working && !steerOnly {
                    Button(action: actions.stop) {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(Circle().fill(Color.red.opacity(0.85)))
                    }
                    .buttonStyle(.plain).padding(.bottom, 4).help("Stop (⌘.) — like pressing Esc in the terminal")
                }
                Button { submit(queue: false) } label: {
                    Image(systemName: working ? "arrow.turn.down.right" : "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                  ? Color.secondary.opacity(0.4) : working ? Color.orange : Color.accentColor))
                }
                .buttonStyle(.plain).padding(.bottom, 4)
                .help(working ? "Steer (↩): it gets this at its next step, without stopping. ⌥↩ queues it for after the turn." : "Send (↩)")
            }
            if !steerOnly {
                ComposerChips(chat: chat, agent: agent, cycleMode: actions.cycleMode, notice: notice) { command in
                    _ = actions.send(command)
                }
            } else if let notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.red).padding(.leading, 30)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
    }

    /// ↩: steers while the agent works, sends otherwise. ⌥↩ (`queue`): typed in for after the turn.
    private func submit(queue: Bool) {
        let message = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let steering = working && (steerOnly || !queue)
        let limit = steering ? ComposerLimits.maxSteerCharacters : ComposerLimits.maxBytes
        guard (steering ? message.count : message.utf8.count) <= limit else {
            notice = "Too long to \(steering ? "steer" : "type into the terminal"). Save it to a file and mention it instead."
            return
        }
        notice = nil
        let accepted = steering ? actions.steer(message) : actions.send(message)
        if accepted {
            if working && !steering { chat.sent(message) }
            text.wrappedValue = ""
            suggestions = Suggestions()
        }
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map { RecentProjects.shellQuote($0.path) }.joined(separator: " ")
        let current = text.wrappedValue
        text.wrappedValue = current + (current.isEmpty || current.hasSuffix(" ") ? "" : " ") + paths + " "
        chat.focusComposer()
    }

    private func complete(_ token: ComposerToken) -> [Suggestion] {
        switch token.kind {
        case .slash:
            return SlashCatalog.match(token.query, in: chat.commands).map {
                Suggestion(title: "/" + $0.name, subtitle: $0.description, insert: "/" + $0.name + " ", symbol: "command")
            }
        case .mention:
            return FileIndex.match(token.query, in: chat.files).map {
                Suggestion(title: ($0 as NSString).lastPathComponent, subtitle: $0, insert: "@" + $0 + " ", symbol: "doc")
            }
        }
    }
}

enum ComposerLimits {
    /// Larger messages don't fit the session host's frames once encoded; refuse rather than lose them.
    static let maxBytes = 200 * 1024
    /// What a hook can hand Claude inline.
    static let maxSteerCharacters = 8_000
}

struct Suggestion: Equatable {
    var title: String
    var subtitle: String
    var insert: String
    var symbol: String
}

struct Suggestions: Equatable {
    var token: ComposerToken?
    var items: [Suggestion] = []
    var selected = 0
    /// Set by a click in the list; the text view applies it.
    var acceptIndex: Int?
}

private struct SuggestionList: View {
    @Binding var suggestions: Suggestions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.items.prefix(8).enumerated()), id: \.offset) { index, item in
                HStack(spacing: 8) {
                    Image(systemName: item.symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                    Text(item.title).font(.system(size: 12.5, weight: .medium))
                    Text(item.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(index == suggestions.selected ? Color.accentColor.opacity(0.18) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { suggestions.acceptIndex = index }
            }
            Text("↑↓ to choose · ↩ or ⇥ to insert · esc to close").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
        .padding(.leading, 30)
        .frame(maxWidth: 560, alignment: .leading)
    }
}

/// Mode, model and context, under the box.
private struct ComposerChips: View {
    @ObservedObject var chat: ChatModel
    let agent: Agent
    let cycleMode: () -> Void
    let notice: String?
    let command: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let mode = chat.mode {
                Button(action: cycleMode) {
                    Label(mode.label, systemImage: mode == .plan ? "list.bullet.rectangle" : mode == .normal ? "hand.raised" : "bolt")
                }
                .buttonStyle(ChipStyle(tint: mode == .plan ? .blue : mode == .bypass ? .red : mode == .normal ? .secondary : .orange))
                .help("Permission mode — click for the next one (like shift+tab)")
            }
            if let usage = chat.log.usage {
                if let model = usage.model {
                    Menu {
                        if agent == .claude {
                            ForEach(["opus", "sonnet", "haiku"], id: \.self) { alias in
                                Button(alias.capitalized) { command("/model \(alias)") }
                            }
                            Divider()
                        }
                        Button("Choose…") { command("/model") }
                    } label: {
                        Label(ModelNames.pretty(model), systemImage: "cpu")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .buttonStyle(ChipStyle(tint: .secondary))
                    .help("Model — choose another")
                }
                if let context = usage.contextTokens {
                    ContextMeter(tokens: context, window: usage.contextWindow)
                }
                if chat.log.outputTokens > 0 {
                    Text("\(TokenCount.short(chat.log.outputTokens)) out").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                        .help("Tokens the agent wrote in this conversation (as far as it's loaded)")
                }
                if let percent = usage.rateLimitPercent {
                    Text("limit \(Int(percent))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                        .help("Share of the usage limit used")
                }
            }
            Spacer(minLength: 0)
            if let notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
            } else if !chat.pending.isEmpty {
                Text("\(chat.pending.count) queued").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 30)
    }
}

private struct ChipStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.25 : 0.12)))
    }
}

private struct ContextMeter: View {
    let tokens: Int
    let window: Int?

    var body: some View {
        HStack(spacing: 5) {
            if let window, window > 0 {
                let share = min(1, Double(tokens) / Double(window))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(share > 0.85 ? Color.red : share > 0.6 ? Color.orange : Color.green).frame(width: 44 * share)
                }
                .frame(width: 44, height: 5)
                Text("\(Int(share * 100))% context").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Image(systemName: "text.word.spacing").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("\(TokenCount.short(tokens)) context").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .help("Tokens in the context of the latest request\(window.map { " (of \(TokenCount.short($0)))" } ?? "")")
    }
}

enum TokenCount {
    static func short(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: n >= 100_000 ? "%.0fk" : "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

enum ModelNames {
    /// "claude-opus-5-5" → "Opus 5.5"; other names as they are.
    static func pretty(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        let parts = id.dropFirst("claude-".count).split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }
}

/// Image paths written in the composer (as attachments), shown as thumbnails above it.
enum AttachedImages {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"]

    static func paths(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "'") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "'") else { break }
            let path = String(after[..<close])
            if extensions.contains((path as NSString).pathExtension.lowercased()), FileManager.default.fileExists(atPath: path),
               !found.contains(path) {
                found.append(path)
            }
            rest = after[after.index(after: close)...]
        }
        return found
    }

    static func removing(_ path: String, from text: String) -> String {
        text.replacingOccurrences(of: RecentProjects.shellQuote(path) + " ", with: "")
            .replacingOccurrences(of: RecentProjects.shellQuote(path), with: "")
    }
}

private struct AttachedThumbnail: View {
    let path: String
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain).offset(x: 5, y: -5)
        }
        .help(path)
        .padding(.leading, 30)
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var suggestions: Suggestions
    let history: [String]
    let focusRequests: Int
    let complete: (ComposerToken) -> [Suggestion]
    let submit: () -> Void
    /// ⌥↩.
    let queue: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.string = text
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // A new box (another session) takes the focus once it's on screen.
        context.coordinator.lastFocusRequest = focusRequests - 1
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.measure(textView)
        }
        if focusRequests != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequests
            DispatchQueue.main.async {
                // Never while the chat is hidden behind the terminal: the keys belong to the terminal then.
                guard !scroll.isHiddenOrHasHiddenAncestor else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
        if let index = suggestions.acceptIndex {
            DispatchQueue.main.async { context.coordinator.accept(index, in: textView) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var lastFocusRequest = 0
        /// Position while walking through history (nil: not walking).
        private var historyIndex: Int?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            historyIndex = nil
            measure(textView)
            refreshSuggestions(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            refreshSuggestions(textView)
        }

        private func refreshSuggestions(_ textView: NSTextView) {
            let caret = textView.selectedRange().location
            guard textView.selectedRange().length == 0, let token = ComposerToken.at(textView.string, caret: caret) else {
                if !parent.suggestions.items.isEmpty { parent.suggestions = Suggestions() }
                return
            }
            let items = parent.complete(token)
            parent.suggestions = Suggestions(token: token, items: items, selected: 0)
        }

        func accept(_ index: Int, in textView: NSTextView) {
            guard let token = parent.suggestions.token, parent.suggestions.items.indices.contains(index) else {
                parent.suggestions = Suggestions()
                return
            }
            let insert = parent.suggestions.items[index].insert
            parent.suggestions = Suggestions()
            textView.insertText(insert, replacementRange: token.range)
            textView.window?.makeFirstResponder(textView)
        }

        func measure(_ textView: NSTextView) {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height) + 6
            if abs(parent.height - height) > 0.5 { DispatchQueue.main.async { self.parent.height = height } }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // An input method is composing (Japanese, Chinese…): its keys aren't ours.
            if textView.hasMarkedText() { return false }
            let count = min(parent.suggestions.items.count, 8)
            if count > 0 {
                switch selector {
                case #selector(NSResponder.moveUp(_:)):
                    parent.suggestions.selected = (parent.suggestions.selected - 1 + count) % count
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    parent.suggestions.selected = (parent.suggestions.selected + 1) % count
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    accept(parent.suggestions.selected, in: textView)
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    parent.suggestions = Suggestions()
                    return true
                default:
                    break
                }
            }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else if flags.contains(.option) {
                    parent.queue()
                } else {
                    parent.submit()
                }
                return true
            case #selector(NSResponder.moveUp(_:)):
                return walkHistory(textView, by: -1)
            case #selector(NSResponder.moveDown(_:)):
                return walkHistory(textView, by: 1)
            default:
                return false
            }
        }

        /// ↑ / ↓ go through earlier prompts while the box is empty or showing one of them.
        private func walkHistory(_ textView: NSTextView, by step: Int) -> Bool {
            let history = parent.history
            guard !history.isEmpty, textView.string.isEmpty || historyIndex != nil else { return false }
            let next = (historyIndex ?? history.count) + step
            guard next >= 0 else { return true }
            if next >= history.count {
                historyIndex = nil
                textView.string = ""
            } else {
                historyIndex = next
                textView.string = history[next]
            }
            parent.text = textView.string
            measure(textView)
            return true
        }
    }
}

/// Pastes images as saved files and drops files as their paths.
private final class ComposerNSTextView: NSTextView {
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return insertPaths(urls)
        }
        // Image data wins over the text flavor that browsers, Preview and Slack copy along with it.
        if board.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: board), let url = Attachments.save(image) {
            return insertPaths([url])
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            insertPaths(urls)
            return true
        }
        if let image = NSImage(pasteboard: board), let url = Attachments.save(image) {
            insertPaths([url])
            return true
        }
        return super.performDragOperation(sender)
    }

    private func insertPaths(_ urls: [URL]) {
        let text = urls.map { RecentProjects.shellQuote($0.path) }.joined(separator: " ")
        let location = selectedRange().location
        let before = location > 0 ? (string as NSString).substring(with: NSRange(location: location - 1, length: 1)) : " "
        insertText((before == " " || before == "\n" ? "" : " ") + text + " ", replacementRange: selectedRange())
        window?.makeFirstResponder(self)
    }
}

/// Images pasted into the composer, saved where the agent can read them.
enum Attachments {
    static var folder: URL { VibePaths.root.appendingPathComponent("attachments", isDirectory: true) }

    static func save(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        prune()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = folder.appendingPathComponent("pasted-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).png")
        guard fileManager.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600]) else { return nil }
        return url
    }

    /// Pasted images older than 30 days go (the agents have long read them).
    private static func prune() {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        for url in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if modified < cutoff { try? fileManager.removeItem(at: url) }
        }
    }
}
