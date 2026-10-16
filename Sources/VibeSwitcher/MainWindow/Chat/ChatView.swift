import AppKit
import SwiftUI
import VibeCore

/// The middle pane's Chat: the conversation, what the agent is doing now, search, and the composer.
struct ChatContainer: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var model: WindowModel
    let actions: WindowActions
    /// Types the message into the selected window session.
    let send: (String) -> Void
    let showTerminal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if chat.searchActive { ChatSearchBar(chat: chat) }
            ChatView(chat: chat, row: model.selectedRow, showTerminal: showTerminal)
            Divider()
            if let row = model.selectedRow {
                if row.hostID != nil, actions.isLive(row) {
                    ComposerView(agent: row.markKind.name, history: chat.log.prompts) { text in
                        send(text)
                        chat.scrollToBottom()
                    }
                } else if let session = row.session, session.inTerminalApp {
                    TerminalReplyHint(canMove: MoveToWindow.canMove(session)) { actions.moveToWindow(session) }
                } else {
                    Text("This session has ended.").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(12)
                }
            }
        }
        // Opaque: the terminal stays attached underneath.
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct ChatView: View {
    @ObservedObject var chat: ChatModel
    let row: WindowRow?
    let showTerminal: () -> Void
    @State private var atBottom = true
    @State private var viewing: ChatImage?
    @State private var didInitialScroll = false

    var body: some View {
        let items = chat.items
        let matches = chat.searchActive ? ChatSearch.matches(items, query: chat.searchQuery) : []
        let current = matches.isEmpty ? nil : matches[min(chat.searchIndex, matches.count - 1)]
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    switch chat.state {
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    case .failed(let message):
                        Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                    case .none:
                        Text("No conversation").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                    case .ready:
                        if chat.hasEarlier {
                            Button(chat.loadingEarlier ? "Loading…" : "Load earlier") { chat.loadEarlier() }
                                .buttonStyle(.borderless).frame(maxWidth: .infinity).disabled(chat.loadingEarlier)
                        }
                        ForEach(items) { item in
                            ChatItemView(item: item, chat: chat, agent: row?.markKind ?? .agent(.claude)) { viewing = $0 }
                                .id(item.id)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 10).fill(
                                    item.id == current ? Color.yellow.opacity(0.18) : matches.contains(item.id) ? Color.yellow.opacity(0.07) : .clear))
                        }
                        if let row { LiveStateView(row: row, showTerminal: showTerminal) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 22).padding(.vertical, 16)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom, chat.state == .ready {
                    Button { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                        Label("Latest", systemImage: "arrow.down").font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small).clipShape(Capsule())
                    .padding(14)
                }
            }
            .onChange(of: chat.state) { _, state in
                guard state == .ready, !didInitialScroll else { return }
                didInitialScroll = true
                // Open at what's new since you looked, else at the end.
                DispatchQueue.main.async {
                    if chat.markerAfter != nil, items.contains(where: { $0.id == "new-marker" }) || chat.items.contains(where: { $0.id == "new-marker" }) {
                        proxy.scrollTo("new-marker", anchor: .top)
                    } else {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: chat.path) { _, _ in didInitialScroll = chat.state == .ready ? false : didInitialScroll }
            .onChange(of: chat.log.entries.count) { _, _ in
                if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.scrollToBottomRequests) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: current) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            .onAppear {
                if chat.state == .ready, !didInitialScroll {
                    didInitialScroll = true
                    proxy.scrollTo(chat.markerAfter != nil ? "new-marker" : "bottom", anchor: chat.markerAfter != nil ? .top : .bottom)
                }
            }
        }
        .sheet(item: $viewing) { image in ImageViewer(image: image) { viewing = nil } }
    }
}

private struct ChatItemView: View {
    let item: ChatItem
    @ObservedObject var chat: ChatModel
    let agent: MarkKind
    let openImage: (ChatImage) -> Void

    var body: some View {
        switch item {
        case .prompt(let entry):
            if case .prompt(let text, let images) = entry.kind {
                VStack(alignment: .trailing, spacing: 4) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !images.isEmpty {
                            HStack(spacing: 6) { ForEach(images) { image in Thumbnail(image: image, height: 90) { openImage(image) } } }
                        }
                        if !text.isEmpty {
                            Text(text).font(.system(size: 13.5)).lineSpacing(2).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.16)))
                    if let at = entry.at {
                        Text(at.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 60)
                .contextMenu { Button("Copy") { Pasteboard.copy(text) } }
            }
        case .reply(let entry):
            if case .reply(let text) = entry.kind {
                HStack(alignment: .top, spacing: 10) {
                    AgentMark(kind: agent, size: 20).padding(.top, 1)
                    MarkdownView(text: text).frame(maxWidth: .infinity, alignment: .leading)
                }
                .contextMenu { Button("Copy as Markdown") { Pasteboard.copy(text) } }
            }
        case .tools(let id, let tools):
            ToolGroupView(id: id, tools: tools, chat: chat, openImage: openImage).padding(.leading, 30)
        case .newMarker(let summary):
            HStack(spacing: 10) {
                Rectangle().fill(Color.accentColor).frame(height: 1)
                VStack(spacing: 1) {
                    Text("New since you looked").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                    if !summary.isEmpty { Text(summary).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                }
                .fixedSize()
                Rectangle().fill(Color.accentColor).frame(height: 1)
            }
            .padding(.vertical, 4)
        }
    }
}

/// The bottom of the chat while the agent works or waits for you.
private struct LiveStateView: View {
    let row: WindowRow
    let showTerminal: () -> Void

    var body: some View {
        if let session = row.session, !session.isPaused {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                switch session.status {
                case .working, .background:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(workingText(session, now: context.date)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 30)
                case .needsInput:
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.red).font(.system(size: 16))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(session.agent.displayName) is asking in the terminal").font(.system(size: 13, weight: .semibold))
                            if let detail = session.detail, !detail.isEmpty {
                                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                            }
                        }
                        Spacer()
                        Button("Show Terminal", action: showTerminal).buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.3)))
                default:
                    EmptyView()
                }
            }
        }
    }

    private func workingText(_ session: Session, now: Date) -> String {
        if let activity = session.activity, let since = session.activitySince {
            return "\(activity) · \(Durations.short(now.timeIntervalSince(since)))"
        }
        return "Working · \(Durations.short(now.timeIntervalSince(session.statusSince)))"
    }
}

private struct ChatSearchBar: View {
    @ObservedObject var chat: ChatModel
    @FocusState private var focused: Bool

    var body: some View {
        let count = ChatSearch.matches(chat.items, query: chat.searchQuery).count
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search this conversation", text: $chat.searchQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { step(1, count) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    step(-1, count)
                    return .handled
                }
                .onExitCommand { close() }
            if !chat.searchQuery.isEmpty {
                Text(count == 0 ? "No matches" : "\(min(chat.searchIndex, count - 1) + 1) of \(count)")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                Button { step(-1, count) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(count == 0)
                Button { step(1, count) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(count == 0)
            }
            Button("Done") { close() }.buttonStyle(.borderless)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focused = true }
        .onChange(of: chat.searchQuery) { _, _ in chat.searchIndex = 0 }
    }

    private func step(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        chat.searchIndex = ((min(chat.searchIndex, count - 1) + delta) % count + count) % count
    }

    private func close() {
        chat.searchActive = false
        chat.searchQuery = ""
    }
}

/// In place of the composer for a session that runs in Terminal.app.
private struct TerminalReplyHint: View {
    let canMove: Bool
    let move: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "macwindow").foregroundStyle(.secondary)
            Text(canMove ? "Runs in Terminal. Move it here to reply from this window."
                         : "Runs in Terminal. Reply there (Move to Window is offered between turns).")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            if canMove {
                Button(action: move) { Label("Move to Window", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
