import AppKit
import Carbon.HIToolbox
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
    @ObservedObject var composer: ComposerDrafts
    let rowID: String
    let agent: Agent
    let working: Bool
    /// Only steering (a Terminal session: nothing can be typed into it from here).
    var steerOnly = false
    let actions: ComposerActions
    /// The answer card above, when it's a window session's: ⌘1–⌘9, ↩ and ↑ / ↓ are its while the box is empty.
    var cardKeys: AnswerCardKeys?
    /// The session's project and folder: dictation's vocabulary (its name, its branches).
    var project: String? = nil
    var folder: String? = nil
    @Environment(\.dictation) private var dictation
    @State private var height: CGFloat = 22
    @State private var suggestions = Suggestions()
    @State private var notice: String?

    private var text: Binding<String> {
        Binding(get: { composer.drafts[rowID] ?? "" }, set: { composer.drafts[rowID] = $0 })
    }

    private var images: [String] { (composer.attachments[rowID] ?? []).filter { FileManager.default.fileExists(atPath: $0) } }

    private func attachImage(_ url: URL) {
        composer.attach(url, to: rowID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !suggestions.items.isEmpty {
                SuggestionList(suggestions: $suggestions)
            }
            // Not while the conversation loads: what it shows may answer for some of them.
            if chat.state != .loading {
                OutboxStrip(outbox: chat.outbox, rowID: rowID, agent: agent.displayName, send: sendAgain) { entry in
                    chat.putBack(entry, rowID: rowID)
                }
            }
            if !images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(images, id: \.self) { path in
                        AttachedThumbnail(path: path) { composer.attachments[rowID]?.removeAll { $0 == path } }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: attach) { Image(systemName: "paperclip").font(.system(size: 14)).accessibilityLabel("Attach files") }
                    .buttonStyle(.borderless).padding(.bottom, 9).help("Attach files or images")
                if let dictation {
                    DictationButton(dictation: dictation, rowID: rowID, agent: steerOnly ? nil : agent, vocabulary: vocabulary)
                }
                ZStack(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(working ? (steerOnly ? "Steer \(agent.displayName) while it works — ↩ sends it to its next step"
                                                  : "Working — ↩ steers it now without stopping it, ⌥↩ queues for after")
                                     : "Message \(agent.displayName)…  / for commands, @ for files")
                            .font(.system(size: 13)).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(text: text, height: $height, suggestions: $suggestions, history: { [chat] in chat.log.prompts },
                                     focusRequests: chat.focusComposerRequests, complete: complete,
                                     submit: { submit(queue: false) }, queue: { submit(queue: true) }, attachImage: attachImage,
                                     cardKey: cardKey, rowID: rowID, dictation: dictation, agent: steerOnly ? nil : agent,
                                     vocabulary: vocabulary)
                        .frame(height: min(max(height, 22), 220))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.3)))
                if working && !steerOnly {
                    Button(action: actions.stop) {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .accessibilityLabel("Stop the agent")
                            .frame(width: 30, height: 30).background(Circle().fill(Color.red.opacity(0.85)))
                    }
                    .buttonStyle(.plain).padding(.bottom, 4).help("Stop (⌘.) — like pressing Esc in the terminal")
                }
                Button { submit(queue: false) } label: {
                    Image(systemName: working ? "arrow.turn.down.right" : "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .accessibilityLabel(working ? "Steer" : "Send")
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
                                                  ? Color.secondary.opacity(0.4) : working ? Color.orange : Color.accentColor))
                }
                .buttonStyle(.plain).padding(.bottom, 4)
                .help(working ? "Steer: send it to the agent's next step (↩)" : "Send (↩)")
                .help(working ? "Steer (↩): it gets this at its next step, without stopping. ⌥↩ queues it for after the turn." : "Send (↩)")
            }
            if let dictation { DictationStatusRow(dictation: dictation, rowID: rowID) }
            // A line of its own, wrapped: in the chips' row a long one ran over them and past the window's edge.
            if let notice = steerOnly ? notice : notice ?? chat.sendNotice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
            }
            if !steerOnly {
                ComposerChips(chat: chat, agent: agent, cycleMode: actions.cycleMode) { command in
                    _ = actions.send(command)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
    }

    /// Dictation's prompt maker, taken at a press: the files come from the conversation shown now, the branches from
    /// git when it runs (off the main thread).
    private func vocabulary() -> @Sendable () -> String {
        let files = DictationVocabulary.files(in: chat.log.entries)
        let (project, folder) = (project, folder)
        return { DictationVocabulary.prompt(project: project, branches: DictationVocabulary.branches(in: folder), files: files) }
    }

    /// ↩ and the Send button: steers while the agent works, sends otherwise. ⌥↩ (`queue`): typed in for after the turn.
    private func submit(queue: Bool) {
        switch ComposerSend(chat: chat, composer: composer, rowID: rowID, working: working, steerOnly: steerOnly, actions: actions)
            .submit(queue: queue) {
        case .empty: break
        case .tooLong(let why): notice = why
        case .refused: notice = nil
        case .sent:
            notice = nil
            suggestions = Suggestions()
        }
    }

    /// A key the answer card may take (WC-1): only while it shows a question and nothing's in the box (attached
    /// images count: ↩ sends them).
    private func cardKey(_ key: AnswerKeys.Key) -> Bool {
        guard let cardKeys, chat.state == .ready, let menu = chat.menu else { return false }
        let content = AnswerCardContent(menu: menu, pending: chat.log.pendingQuestions)
        return cardKeys.take(key, composer: text.wrappedValue + images.joined(), content: content, busy: chat.answering)
    }

    /// Send now, from the outbox strip: typed in again (queued if the agent works), never steered.
    private func sendAgain(_ entry: OutboxEntry) {
        chat.resend(entry, working: working, send: actions.send)
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        let (pictures, others) = AttachedImages.split(panel.urls)
        pictures.forEach(attachImage)
        guard !others.isEmpty else { return chat.focusComposer() }
        let paths = others.map { RecentProjects.shellQuote($0.path) }.joined(separator: " ")
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

/// What ↩ and the Send button do with the box (`ComposerView.submit`): its text and attached images as one message,
/// into the outbox and handed to the session, the box emptied; kept in the box when it's refused.
struct ComposerSend {
    let chat: ChatModel
    let composer: ComposerDrafts
    let rowID: String
    let working: Bool
    var steerOnly = false
    let actions: ComposerActions

    enum Outcome: Equatable {
        /// Nothing in the box.
        case empty
        /// Not sent, and why (said under the box).
        case tooLong(String)
        /// Refused (not connected, no agent): it's back in the box, as it was.
        case refused
        case sent
    }

    /// The box's text, then the attached images as their quoted paths (that's how the agent reads them; the box only
    /// showed thumbnails), one per line: Claude Code takes a pasted image path for one when it's a line of its own or
    /// starts with "/" after a space, and two quoted paths on a line were one path that isn't a file.
    static func message(text: String, images: [String]) -> String {
        let paths = images.map(RecentProjects.shellQuote).joined(separator: "\n")
        return [text, paths].filter { !$0.isEmpty }.joined(separator: text.isEmpty ? "" : "\n\n")
    }

    func submit(queue: Bool) -> Outcome {
        let draft = composer.drafts[rowID] ?? "", attached = composer.attachments[rowID] ?? []
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attached.filter { FileManager.default.fileExists(atPath: $0) }
        let message = Self.message(text: typed, images: images)
        guard !message.isEmpty else { return .empty }
        let steering = working && (steerOnly || !queue)
        let limit = steering ? ComposerLimits.maxSteerCharacters : ComposerLimits.maxBytes
        guard (steering ? message.count : message.utf8.count) <= limit else {
            return .tooLong("Too long to \(steering ? "steer" : "type into the terminal"). Save it to a file and mention it instead.")
        }
        // On disk before anything goes out, and the box emptied on disk too: whatever happens next (a hang, a
        // crash, a relaunch), the message is in the outbox, never lost and never in two places.
        let entry = OutboxEntry(key: rowID, message: message, text: typed, attachments: images, expectsSoon: !working)
        chat.outbox.add(entry)
        composer.drafts[rowID] = ""
        composer.attachments[rowID] = []
        composer.save()
        guard chat.deliver(entry, steering: steering, working: working, actions: actions) else {
            // Refused (not connected, too long to steer): it stays in the box, as it was.
            composer.drafts[rowID] = draft
            composer.attachments[rowID] = attached
            composer.save()
            return .refused
        }
        return .sent
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
                        .accessibilityHidden(true)
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
            if !chat.pending.isEmpty {
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
                Image(systemName: "text.word.spacing").font(.system(size: 10)).foregroundStyle(.secondary).accessibilityHidden(true)
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

    /// Image files (attached as thumbnails) and everything else (written as paths).
    static func split(_ urls: [URL]) -> (images: [URL], others: [URL]) {
        let images = urls.filter { extensions.contains($0.pathExtension.lowercased()) }
        return (images, urls.filter { !extensions.contains($0.pathExtension.lowercased()) })
    }

    /// A prompt's attached images and the rest of its text, worked out once per text (prompts can be tens of
    /// kilobytes of pasted text, and views ask often).
    static func prompt(_ text: String) -> (files: [String], text: String) {
        if let cached = promptCache.object(forKey: text as NSString) { return (cached.files, cached.text) }
        let files = paths(in: text)
        let rest = files.reduce(text) { removing($1, from: $0) }.trimmingCharacters(in: .whitespacesAndNewlines)
        promptCache.setObject(SplitPrompt(files: files, text: rest), forKey: text as NSString)
        return (files, rest)
    }

    private final class SplitPrompt {
        let files: [String]
        let text: String
        init(files: [String], text: String) { self.files = files; self.text = text }
    }

    private static let promptCache: NSCache<NSString, SplitPrompt> = {
        let cache = NSCache<NSString, SplitPrompt>()
        cache.countLimit = 500
        return cache
    }()

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
                    .accessibilityLabel("Remove \((path as NSString).lastPathComponent)")
            }
            .buttonStyle(.plain).offset(x: 5, y: -5)
            .help("Remove this attachment")
        }
        .help(path)
        .padding(.leading, 30)
    }
}

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var suggestions: Suggestions
    /// Earlier prompts, for ↑ (asked for only then: it's every prompt of the conversation).
    let history: () -> [String]
    let focusRequests: Int
    let complete: (ComposerToken) -> [Suggestion]
    let submit: () -> Void
    /// ⌥↩.
    let queue: () -> Void
    /// A pasted or dropped image (saved to a file): attached, not written into the text.
    let attachImage: (URL) -> Void
    /// A key for the answer card (true: it took it, so it isn't typed or sent).
    var cardKey: (AnswerKeys.Key) -> Bool = { _ in false }
    /// The box's row, and push to talk: ⌥Space held records, and transcripts land at the cursor.
    var rowID = ""
    var dictation: DictationController? = nil
    /// The session's agent: a Claude Code session's dictation goes through Claude's /voice.
    var agent: Agent? = nil
    var vocabulary: () -> @Sendable () -> String = { { "" } }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 from the start: `measure` asks for the layout manager, which switches a TextKit 2 view over, and
        // the TextKit 2 views it drops (content, selection, viewport) stayed alive, one set per chat opened.
        let textView = ComposerNSTextView(usingTextLayoutManager: false)
        textView.attachImage = attachImage
        textView.cardKey = cardKey
        textView.holdToTalk = dictation == nil ? nil : context.coordinator.holdToTalk
        textView.cancelTalk = { [weak coordinator = context.coordinator] in coordinator?.parent.dictation?.cancel() }
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
        context.coordinator.inbox.watch(dictation, rowID: { [weak coordinator = context.coordinator] in coordinator?.parent.rowID ?? "" },
                                        textView: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        (textView as? ComposerNSTextView)?.attachImage = attachImage
        (textView as? ComposerNSTextView)?.cardKey = cardKey
        (textView as? ComposerNSTextView)?.holdToTalk = dictation == nil ? nil : context.coordinator.holdToTalk
        context.coordinator.inbox.watch(dictation, rowID: { [weak coordinator = context.coordinator] in coordinator?.parent.rowID ?? "" },
                                        textView: textView)
        if textView.string != text {
            textView.string = text
            context.coordinator.undo.removeAllActions()
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
        /// The box's own ⌘Z history. Emptied whenever its text is replaced from outside the typing (sent, another
        /// session's draft, a history step): undoing into text that's gone raises a range exception.
        let undo = UndoManager()

        /// Transcripts for this box, put in at the cursor.
        let inbox = DictationInbox()

        init(_ parent: ComposerTextView) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        /// ⌥Space went down (true) or up (false) in the box.
        private(set) lazy var holdToTalk: (Bool) -> Void = { [weak self] down in
            guard let self, let dictation = self.parent.dictation else { return }
            if down { dictation.press(self.parent.rowID, agent: self.parent.agent, vocabulary: self.parent.vocabulary()) } else { dictation.release() }
        }

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
            // Esc while dictating: the recording is dropped.
            if selector == #selector(NSResponder.cancelOperation(_:)), let dictation = parent.dictation, dictation.isBusy(parent.rowID) {
                dictation.cancel()
                return true
            }
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
            // ↩ and ↑ / ↓ in an empty box: the answer card's, while it shows a question.
            if let key = Self.cardKey(selector, flags: NSApp.currentEvent?.modifierFlags ?? []), parent.cardKey(key) { return true }
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

        /// The answer card's key for a command: plain ↩ (⇧↩ and ⌥↩ stay the box's), ↑, ↓, and Esc (a picker's).
        static func cardKey(_ selector: Selector, flags: NSEvent.ModifierFlags) -> AnswerKeys.Key? {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                return flags.intersection([.shift, .option, .command, .control]).isEmpty ? .enter : nil
            case #selector(NSResponder.moveUp(_:)): return .up
            case #selector(NSResponder.moveDown(_:)): return .down
            case #selector(NSResponder.cancelOperation(_:)): return .escape
            default: return nil
            }
        }

        /// ↑ / ↓ go through earlier prompts while the box is empty or showing one of them.
        private func walkHistory(_ textView: NSTextView, by step: Int) -> Bool {
            let history = parent.history()
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
            undo.removeAllActions()
            parent.text = textView.string
            measure(textView)
            return true
        }
    }
}

/// Pastes images as saved files and drops files as their paths.
final class ComposerNSTextView: NSTextView {
    var attachImage: (URL) -> Void = { _ in }
    /// ⌘1–⌘9: the answer card's when it takes them (see `ComposerTextView.cardKey`). A digit typed alone is text:
    /// "1 more thing…" typed with a question up went in as option 1 (usually Yes).
    var cardKey: (AnswerKeys.Key) -> Bool = { _ in false }
    /// Where ⌘V reads from (a test's own pasteboard: never the user's clipboard).
    var pasteboard: NSPasteboard = .general
    /// Where a pasted or dropped image is saved (a test's scratch folder).
    var attachments: URL = Attachments.folder
    /// Push to talk: ⌥Space held down (true) and let go (false). Nil: ⌥Space types as usual.
    var holdToTalk: ((Bool) -> Void)?
    /// Esc while ⌥Space is held.
    var cancelTalk: (() -> Void)?
    /// ⌥Space is held now.
    private(set) var talking = false
    /// While held: the window going out of key (another app, another window), whose key-up goes elsewhere.
    private var leaving: NSObjectProtocol?

    override func keyDown(with event: NSEvent) {
        // Esc mid-hold (⌥ still down, so it isn't cancelOperation): the recording is dropped.
        if talking, event.keyCode == UInt16(kVK_Escape) {
            talking = false
            if let leaving { NotificationCenter.default.removeObserver(leaving) }
            leaving = nil
            cancelTalk?()
            return
        }
        if let holdToTalk, !hasMarkedText(), Self.isTalkKey(event) {
            // Its repeats while held do nothing.
            if !event.isARepeat, !talking {
                talking = true
                leaving = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                 queue: .main) { [weak self] _ in self?.endTalk() }
                holdToTalk(true)
            }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if talking, event.keyCode == UInt16(kVK_Space) { return endTalk() }
        super.keyUp(with: event)
    }

    /// Focus moving away mid-hold: its key-up would go elsewhere, so it ends here.
    override func resignFirstResponder() -> Bool {
        endTalk()
        return super.resignFirstResponder()
    }

    /// ⌥Space let go, or as good as: the recording goes to be transcribed.
    func endTalk() {
        guard talking else { return }
        talking = false
        if let leaving { NotificationCenter.default.removeObserver(leaving) }
        leaving = nil
        holdToTalk?(false)
    }

    /// ⌥Space, nothing else held.
    static func isTalkKey(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == UInt16(kVK_Space)
            && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .option
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, !hasMarkedText(), let digit = Self.digit(event), cardKey(digit) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘ and a 1–9 key (with ⇧ too), by the key pressed: ⌘ on AZERTY's top row types "&", "é"…
    static func digit(_ event: NSEvent) -> AnswerKeys.Key? {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]) == .command,
              let index = digitKeys.firstIndex(of: Int(event.keyCode)) else { return nil }
        return .digit(index % 9 + 1)
    }

    private static let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
                                    kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                                    kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]

    /// A plain-text view only enables Paste for clipboards it can read: without these, an image-only clipboard
    /// leaves ⌘V disabled and `paste(_:)` is never called.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.fileURL, .png, .tiff]
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), pasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil {
            return isEditable
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        let board = pasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return take(urls)
        }
        // Image data wins over the text flavor that browsers, Preview and Slack copy along with it.
        if board.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: board), let url = Attachments.save(image, in: attachments) {
            return attachImage(url)
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            take(urls)
            return true
        }
        if let image = NSImage(pasteboard: board), let url = Attachments.save(image, in: attachments) {
            attachImage(url)
            return true
        }
        return super.performDragOperation(sender)
    }

    /// Images become attachments; other files are written as their paths.
    private func take(_ urls: [URL]) {
        let (images, others) = AttachedImages.split(urls)
        images.forEach(attachImage)
        if !others.isEmpty { insertPaths(others) }
        window?.makeFirstResponder(self)
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

    static func save(_ image: NSImage, in folder: URL = folder) -> URL? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        prune(folder)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = folder.appendingPathComponent("pasted-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).png")
        guard fileManager.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600]) else { return nil }
        return url
    }

    /// Pasted images older than 30 days go (the agents have long read them).
    private static func prune(_ folder: URL) {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        for url in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if modified < cutoff { try? fileManager.removeItem(at: url) }
        }
    }
}
