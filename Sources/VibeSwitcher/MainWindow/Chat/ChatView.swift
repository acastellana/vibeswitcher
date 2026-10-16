import AppKit
import SwiftUI
import VibeCore

/// The middle pane's Chat: the conversation, what the agent is doing now, search, and the composer.
struct ChatContainer: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var model: WindowModel
    let actions: WindowActions
    /// Typing into the selected window session.
    let composer: ComposerActions
    /// Picks option N of the menu on the session's screen.
    let choose: (Int) -> Void
    let showTerminal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if chat.searchActive { ChatSearchBar(chat: chat) }
            if let todos = chat.log.todos, todos.contains(where: { $0.status != .done }) { TodoPanel(todos: todos) }
            ChatView(chat: chat, row: model.selectedRow, live: model.selectedRow.map(actions.isLive) == true && model.selectedRow?.hostID != nil,
                     showTerminal: showTerminal, choose: choose, resend: { _ = composer.send($0) })
                .id(chat.path ?? "")
                .environment(\.chatFolder, model.selectedRow?.cwd)
            Divider()
            if let row = model.selectedRow {
                if row.hostID != nil, actions.isLive(row) {
                    ComposerView(chat: chat, rowID: row.id, agent: row.session?.agent ?? .claude,
                                 working: [.working, .background].contains(row.session?.status),
                                 actions: ComposerActions(send: { text in
                                     let sent = composer.send(text)
                                     if sent { chat.scrollToBottom() }
                                     return sent
                                 }, steer: composer.steer, stop: composer.stop, cycleMode: composer.cycleMode))
                    // A text box of its own per session: nothing typed for one can end up in another.
                    .id(row.id)
                } else if let session = row.session, session.inTerminalApp, session.agent == .claude,
                          [.working, .background].contains(session.status) {
                    // Steering needs no typing, so it reaches a Terminal session too.
                    ComposerView(chat: chat, rowID: row.id, agent: session.agent, working: true, steerOnly: true,
                                 actions: ComposerActions(send: { _ in false }, steer: composer.steer, stop: {}, cycleMode: {}))
                        .id(row.id)
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
    /// A window session you can type into (answer cards, Send Again).
    let live: Bool
    let showTerminal: () -> Void
    let choose: (Int) -> Void
    let resend: (String) -> Void
    @State private var atBottom = true
    @State private var viewing: ChatImage?
    @State private var didInitialScroll = false

    var body: some View {
        let items = chat.items
        let matchList = chat.searchActive ? ChatSearch.matches(items, query: chat.searchQuery) : []
        let matches = Set(matchList)
        let current = matchList.isEmpty ? nil : matchList[min(chat.searchIndex, matchList.count - 1)]
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
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ChatItemView(item: item, chat: chat, agent: row?.markKind ?? .agent(.claude), rowID: row?.id,
                                         canSend: live, resend: resend) { viewing = $0 }
                                .id(item.id)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 10).fill(
                                    item.id == current ? Color.yellow.opacity(0.18) : matches.contains(item.id) ? Color.yellow.opacity(0.07) : .clear))
                                .onAppear { chat.visibleItems[item.id] = index }
                                .onDisappear { chat.visibleItems[item.id] = nil }
                        }
                        ForEach(chat.steering) { message in
                            Text(message.text).font(.system(size: 13.5)).foregroundStyle(.secondary)
                                .padding(.horizontal, 13).padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.5),
                                                                                                         style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                .overlay(alignment: .bottomTrailing) {
                                    Text("steering… arrives at its next step").font(.system(size: 9.5)).foregroundStyle(.tertiary).offset(y: 14)
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.leading, 60).padding(.bottom, 10)
                        }
                        ForEach(chat.pending) { message in
                            Text(message.text).font(.system(size: 13.5)).foregroundStyle(.secondary)
                                .padding(.horizontal, 13).padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.4),
                                                                                                         style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                .overlay(alignment: .bottomTrailing) {
                                    Text("queued").font(.system(size: 9.5)).foregroundStyle(.tertiary).offset(y: 14)
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.leading, 60).padding(.bottom, 10)
                        }
                        if live, let menu = chat.menu {
                            AnswerCard(menu: menu, agent: row?.session?.agent.displayName ?? "The agent", choose: choose, showTerminal: showTerminal)
                        } else if let row {
                            LiveStateView(row: row, showTerminal: showTerminal)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { atBottom = true; chat.atBottom = true }
                        .onDisappear { atBottom = false; chat.atBottom = false }
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
                // Open where you were reading, else at what's new since you looked, else at the end.
                DispatchQueue.main.async {
                    if let anchor = chat.restoreAnchor, chat.items.contains(where: { $0.id == anchor }) {
                        proxy.scrollTo(anchor, anchor: .top)
                    } else if chat.items.contains(where: { $0.id == "new-marker" }) {
                        proxy.scrollTo("new-marker", anchor: .top)
                    } else {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
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
    @AppStorage(ChatFont.key) private var chatFontSize = ChatFont.standard
    let item: ChatItem
    @ObservedObject var chat: ChatModel
    let agent: MarkKind
    let rowID: String?
    let canSend: Bool
    let resend: (String) -> Void
    let openImage: (ChatImage) -> Void

    var body: some View {
        switch item {
        case .prompt(let entry):
            if case .steered(let text, let fromLead) = entry.kind {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(text).font(.system(size: CGFloat(chatFontSize))).lineSpacing(2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.13)))
                    Label(fromLead ? "from another agent (not you)" : "steered while it worked", systemImage: fromLead ? "person.2" : "arrow.turn.down.right")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 60)
                .contextMenu { Button("Copy") { Pasteboard.copy(text) } }
            } else if case .prompt(let rawText, let images) = entry.kind {
                // Images attached from the composer travel as quoted paths: show them as pictures, not as text.
                let files = AttachedImages.paths(in: rawText)
                let text = files.reduce(rawText) { AttachedImages.removing($1, from: $0) }.trimmingCharacters(in: .whitespacesAndNewlines)
                VStack(alignment: .trailing, spacing: 4) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !images.isEmpty || !files.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(images) { image in Thumbnail(image: image, height: 90) { openImage(image) } }
                                ForEach(files, id: \.self) { path in FileThumbnail(path: path, height: 90) }
                            }
                        }
                        if !text.isEmpty {
                            Text(text).font(.system(size: CGFloat(chatFontSize))).lineSpacing(2).textSelection(.enabled)
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
                .contextMenu {
                    Button("Copy") { Pasteboard.copy(text) }
                    if canSend, let rowID {
                        Button("Edit in Composer") {
                            chat.drafts[rowID] = text
                            chat.focusComposer()
                        }
                        Button("Send Again") { resend(text) }
                    }
                }
            }
        case .reply(let entry):
            if case .reply(let text) = entry.kind {
                HStack(alignment: .top, spacing: 10) {
                    AgentMark(kind: agent, size: 20).padding(.top, 1)
                    MarkdownView(text: text).frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(entry.at.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
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

    private func step(_ delta: Int, _ count: Int) { chat.stepSearch(delta) }

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


/// A numbered choice on the session's screen, as buttons: one click answers it in the terminal.
private struct AnswerCard: View {
    let menu: ScreenMenu
    let agent: String
    let choose: (Int) -> Void
    let showTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Color.accentColor).font(.system(size: 15))
                Text("\(agent) is asking").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Show Terminal", action: showTerminal).buttonStyle(.borderless).font(.system(size: 11.5))
            }
            if !menu.question.isEmpty {
                Text(menu.question).font(.system(size: 12.5)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(menu.options.enumerated()), id: \.offset) { index, option in
                    Button { choose(index) } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)").font(.system(size: 11, weight: .bold).monospacedDigit())
                                .frame(width: 18, height: 18).background(Circle().fill(Color.accentColor.opacity(0.18)))
                            Text(option).font(.system(size: 12.5)).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(index == menu.selected ? Color.accentColor.opacity(0.12)
                                                                                                  : Color.secondary.opacity(0.07)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.45)))
    }
}

/// The current to-do list or plan steps, pinned above the conversation while any is open.
private struct TodoPanel: View {
    let todos: [ChatTodo]
    @AppStorage("chatTodosOpen") private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist").foregroundStyle(Color.accentColor)
                    Text("Plan").font(.system(size: 12, weight: .semibold))
                    Text("\(todos.filter { $0.status == .done }.count) of \(todos.count) done").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    if let active = todos.first(where: { $0.status == .active }), !open {
                        Text("· \(active.text)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { TodoListView(todos: todos).padding(.leading, 4) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}


/// An image file referenced by a prompt (attached from the composer); click to open it.
private struct FileThumbnail: View {
    let path: String
    let height: CGFloat

    var body: some View {
        if let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                .help(path)
        }
    }
}
