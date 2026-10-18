import AppKit
import SwiftUI
import VibeCore

/// The middle pane's Chat: the conversation, what the agent is doing now, search, and the composer.
struct ChatContainer: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var model: WindowModel
    @ObservedObject var leads: LeadController
    let actions: WindowActions
    /// Typing into the selected window session.
    let composer: ComposerActions
    /// Picks option N of the menu on the session's screen (typing an answer for a free-text option).
    let choose: (Int, String?) -> Void
    /// Moves between a question's tabs (→ / ←).
    let moveTab: (Int) -> Void
    let showTerminal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if chat.searchActive { ChatSearchBar(chat: chat) }
            let lead = model.selectedRow.flatMap(leads.lead(for:))
            if let lead {
                TeamStrip(board: lead.board) { task in
                    if let id = task.worker.flatMap(UUID.init(uuidString:)) { model.select(hostID: id) }
                }
                BaseMovePrompt(moves: leads.baseMoves, root: lead.root)
            } else if let todos = chat.log.todos, todos.contains(where: { $0.status != .done }) {
                TodoPanel(todos: todos)
            }
            ChatView(chat: chat, row: model.selectedRow, live: model.selectedRow.map(actions.isLive) == true && model.selectedRow?.hostID != nil,
                     leadQuestions: lead?.board.questionStack() ?? [], leadNotices: leads.answerNotices,
                     answerLead: { question, text in if let lead { leads.answer(question, root: lead.root, with: text) } },
                     showTerminal: showTerminal, choose: choose, moveTab: moveTab, resend: { _ = composer.send($0) })
                .id(chat.path ?? "")
                .environment(\.chatFolder, model.selectedRow?.cwd)
                .environment(\.chatRunner, chat.runner)
            Divider()
            if let row = model.selectedRow {
                if row.hostID != nil, actions.isLive(row) {
                    ComposerView(chat: chat, composer: chat.composer, rowID: row.draftKey, agent: row.session?.agent ?? .claude,
                                 // Background work (a dev server, a watcher) runs on after the turn: it takes prompts then.
                                 working: row.session?.status == .working,
                                 actions: ComposerActions(send: { text in
                                     let sent = composer.send(text)
                                     if sent { chat.scrollToBottom() }
                                     return sent
                                 }, steer: composer.steer, stop: composer.stop, cycleMode: composer.cycleMode))
                    // A text box of its own per session: nothing typed for one can end up in another.
                    .id(row.id)
                } else if let session = row.session, session.inTerminalApp, session.agent == .claude, session.status == .working {
                    // Steering needs no typing, so it reaches a Terminal session too.
                    ComposerView(chat: chat, composer: chat.composer, rowID: row.draftKey, agent: session.agent, working: true, steerOnly: true,
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
    /// The lead's questions stack (open ones, then lately withdrawn ones), when this is a project lead.
    var leadQuestions: [LeadQuestion] = []
    var leadNotices: [String: String] = [:]
    var answerLead: (LeadQuestion, String) -> Void = { _, _ in }
    let showTerminal: () -> Void
    let choose: (Int, String?) -> Void
    let moveTab: (Int) -> Void
    let resend: (String) -> Void
    /// Whether the end is on screen. Held, not observed: scrolling changes it, and only the Latest button needs
    /// redrawing for that.
    @State private var bottom = BottomTracker()
    @State private var viewing: ChatImage?
    @State private var didInitialScroll = false
    /// With Reduce Motion, scrolls jump instead of gliding.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let items = chat.items
        let matchList = chat.searchActive ? ChatSearch.matches(items, query: chat.searchQuery) : []
        let matches = Set(matchList)
        let current = matchList.isEmpty ? nil : matchList[min(chat.searchIndex, matchList.count - 1)]
        // Only the newest part is laid out (a search match further back widens it).
        let window = ChatWindow.shown(items, limit: chat.shownLimit, including: current)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch chat.state {
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    case .failed(let message):
                        Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                    case .none:
                        Text("No conversation").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                    case .ready:
                        if window.hidden > 0 {
                            Button("Show \(min(window.hidden, ChatWindow.page)) earlier") { chat.showEarlier() }
                                .buttonStyle(.borderless).frame(maxWidth: .infinity)
                        } else if chat.hasEarlier {
                            Button(chat.loadingEarlier ? "Loading…" : "Load earlier") { chat.loadEarlier() }
                                .buttonStyle(.borderless).frame(maxWidth: .infinity).disabled(chat.loadingEarlier)
                        }
                        ForEach(window.items) { item in
                            ChatItemView(item: item, chat: chat, expanded: item.isTools ? chat.expanded : [],
                                         agent: row?.markKind ?? .agent(.claude), rowID: row?.draftKey,
                                         canSend: live, resend: resend) { viewing = $0 }
                                .equatable()
                                .id(item.id)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 10).fill(
                                    item.id == current ? Color.yellow.opacity(0.18) : matches.contains(item.id) ? Color.yellow.opacity(0.07) : .clear))
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: RowTops.self, value: [item.id: geometry.frame(in: .named(RowTops.space)).minY])
                                })
                        }
                        ForEach(chat.steering) { message in
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(String(message.text.prefix(2_000))).font(.system(size: 13.5)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 13).padding(.vertical, 9)
                                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.5),
                                                                                                             style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                if chat.steeringStranded {
                                    // Its turn is over: no next step will take it.
                                    HStack(spacing: 8) {
                                        Text("Not delivered: \(row?.session?.agent.displayName ?? "the agent") isn't working, so nothing picks it up.")
                                            .font(.system(size: 10.5)).foregroundStyle(.orange)
                                        if live, let key = row?.draftKey {
                                            Button("Send now") { if let taken = chat.withdrawSteered(message) { resend(taken.text) } }.controlSize(.small)
                                            Button("Put back in the box") {
                                                if let taken = chat.withdrawSteered(message) {
                                                    chat.putBack(PendingMessage(text: taken.text, afterPrompts: 0), rowID: key)
                                                }
                                            }.controlSize(.small)
                                        } else {
                                            Button("Copy") { Pasteboard.copy(message.text) }.controlSize(.small)
                                            Button("Withdraw") { _ = chat.withdrawSteered(message) }.controlSize(.small)
                                        }
                                    }
                                } else {
                                    Text("steering… arrives at its next step").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.leading, 60).padding(.bottom, 6)
                        }
                        ForEach(chat.pending) { message in
                            let late = chat.late.contains(message.id)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(String(message.text.prefix(2_000))).font(.system(size: 13.5)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 13).padding(.vertical, 9)
                                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                                        late ? Color.orange.opacity(0.7) : Color.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                if late, let rowID = row?.draftKey {
                                    HStack(spacing: 8) {
                                        Text("Not in the conversation yet. It may not have reached \(row?.session?.agent.displayName ?? "the agent").")
                                            .font(.system(size: 10.5)).foregroundStyle(.orange)
                                        Button("Put back in the box") { chat.putBack(message, rowID: rowID) }.controlSize(.small)
                                        Button("Dismiss") { chat.dismiss(message) }.controlSize(.small)
                                    }
                                } else {
                                    Text(message.expectsSoon ? "sending…" : "queued").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.leading, 60).padding(.bottom, 6)
                        }
                        LeadQuestionStack(questions: leadQuestions, notices: leadNotices, answer: answerLead)
                        if live, let menu = chat.menu {
                            AnswerCard(menu: menu, pending: chat.log.pendingQuestions, agent: row?.session?.agent.displayName ?? "The agent",
                                       notice: chat.answerNotice, choose: choose, moveTab: moveTab, showTerminal: showTerminal)
                        } else if let row {
                            LiveStateView(row: row, showTerminal: showTerminal)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .coordinateSpace(name: RowTops.space)
                .onPreferenceChange(RowTops.self) { tops in chat.rowTops = tops.mapValues(Double.init) }
                .background(ScrollProbe { top, atEnd in
                    chat.visibleTop = top
                    chat.atBottom = atEnd
                    bottom.set(atEnd)
                })
                .padding(.horizontal, 22).padding(.vertical, 16)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .bottomTrailing) {
                if chat.state == .ready {
                    LatestButton(bottom: bottom) { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo("bottom", anchor: .bottom) } }
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
                if bottom.atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.scrollToBottomRequests) { _, _ in
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: current) { _, id in
                if let id { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id, anchor: .center) } }
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

/// Where each shown item starts, from the top of the stack (for where you were reading).
private struct RowTops: PreferenceKey {
    static let space = "chat-rows"
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Reports where the scroll view around it is: the top of what's visible (from the top of this view) and whether
/// the end is on screen. Read from AppKit as you scroll; the stack is eager, so its rows don't appear and disappear.
private struct ScrollProbe: NSViewRepresentable {
    let report: (_ top: Double, _ atEnd: Bool) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) { view.report = report }

    final class ProbeView: NSView {
        var report: ((Double, Bool) -> Void)?
        private weak var clip: NSClipView?
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard window != nil, let scroll = enclosingScrollView else { return }
            clip = scroll.contentView
            scroll.contentView.postsBoundsChangedNotifications = true
            postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSView.frameDidChangeNotification, object: self)
            changed()
        }

        @objc private func changed() {
            guard let clip else { return }
            let visible = convert(clip.bounds, from: clip)
            report?(Double(visible.minY), ChatWindow.atEnd(contentHeight: Double(bounds.height), visibleBottom: Double(visible.maxY)))
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Whether the chat's end is on screen; only the Latest button watches it.
final class BottomTracker: ObservableObject {
    @Published private(set) var atBottom = true

    func set(_ value: Bool) {
        if atBottom != value { atBottom = value }
    }
}

/// Jumps to the end; shown while it's off screen.
private struct LatestButton: View {
    @ObservedObject var bottom: BottomTracker
    let jump: () -> Void

    var body: some View {
        if !bottom.atBottom {
            Button(action: jump) {
                Label("Latest", systemImage: "arrow.down").font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.borderedProminent).controlSize(.small).clipShape(Capsule())
            .padding(14)
        }
    }
}

/// One item of the conversation. It doesn't observe the model: it's drawn again only when its own inputs change
/// (`.equatable()`), not on every keystroke in the composer or every line the transcript gains.
private struct ChatItemView: View, Equatable {
    @AppStorage(ChatFont.key) private var chatFontSize = ChatFont.standard
    let item: ChatItem
    /// For actions only (toggling, editing a draft).
    let chat: ChatModel
    /// The opened tool groups and tools (only passed to tool items).
    let expanded: Set<String>
    let agent: MarkKind
    let rowID: String?
    let canSend: Bool
    let resend: (String) -> Void
    let openImage: (ChatImage) -> Void

    static func == (a: ChatItemView, b: ChatItemView) -> Bool {
        a.item == b.item && a.expanded == b.expanded && a.agent == b.agent && a.rowID == b.rowID && a.canSend == b.canSend
    }

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
                let (files, text) = AttachedImages.prompt(rawText)
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
                            chat.composer.drafts[rowID] = text
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
            ToolGroupView(id: id, tools: tools, chat: chat, expanded: expanded, openImage: openImage).padding(.leading, 30)
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
            // From a fixed date: one from `.now` is a new schedule on every redraw of the chat, and the window then
            // laid out about 20 times a second for as long as the line was there.
            TimelineView(.periodic(from: session.statusSince, by: 1)) { context in
                switch session.status {
                case .working:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(workingText(session, now: context.date)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 30)
                case .background:
                    // The turn is over; something it started keeps running. It's waiting for you.
                    Label("Turn done · \(session.detail.map { "still running: \($0)" } ?? "background work still running")",
                          systemImage: "checkmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.leading, 30)
                case .needsInput:
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.red).font(.system(size: 16))
                            .accessibilityHidden(true)
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
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
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
                Button { step(-1, count) } label: { Image(systemName: "chevron.up").accessibilityLabel("Previous match") }
                    .buttonStyle(.borderless).disabled(count == 0).help("Previous match (⇧↩)")
                Button { step(1, count) } label: { Image(systemName: "chevron.down").accessibilityLabel("Next match") }
                    .buttonStyle(.borderless).disabled(count == 0).help("Next match (↩)")
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
            Image(systemName: "macwindow").foregroundStyle(.secondary).accessibilityHidden(true)
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


/// A question on the session's screen (AskUserQuestion, a permission prompt, a picker), as buttons. What the
/// screen shows decides the options; the question's own input adds headers and descriptions. One click answers it
/// in the terminal, the way you would with the keys.
private struct AnswerCard: View {
    let menu: ScreenMenu
    /// The AskUserQuestion still waiting, when that's what's on screen.
    let pending: [ChatQuestion]?
    let agent: String
    let notice: String?
    let choose: (_ index: Int, _ typing: String?) -> Void
    let moveTab: (_ delta: Int) -> Void
    let showTerminal: () -> Void
    @State private var otherText = ""
    @State private var typingOther = false

    private var question: ChatQuestion? {
        guard let pending else { return nil }
        let questionTabs = menu.tabs.filter { $0.title != "Submit" }
        return pending.indices.contains(menu.currentTab ?? 0) && !questionTabs.isEmpty ? pending[menu.currentTab ?? 0] : pending.first
    }

    var body: some View {
        let questionTabs = menu.tabs.filter { $0.title != "Submit" }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Color.accentColor).font(.system(size: 15))
                    .accessibilityHidden(true)
                Text("\(agent) is asking").font(.system(size: 13, weight: .semibold))
                if questionTabs.count > 1, let current = menu.currentTab {
                    Text("Question \(min(current, questionTabs.count - 1) + 1) of \(questionTabs.count)")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Answer in Terminal", action: showTerminal).buttonStyle(.borderless).font(.system(size: 11.5))
            }
            if menu.tabs.count > 1 {
                HStack(spacing: 6) {
                    ForEach(Array(menu.tabs.enumerated()), id: \.offset) { index, tab in
                        Button { moveTab(index - (menu.currentTab ?? 0)) } label: {
                            Label(tab.title, systemImage: tab.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11.5, weight: index == menu.currentTab ? .semibold : .regular))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(index == menu.currentTab ? Color.accentColor : .secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let header = question?.header, menu.tabs.isEmpty {
                    Text(header.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(question?.question ?? menu.question).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if question?.multiSelect == true {
                    Text("Choose any that apply, then Submit.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(menu.options.enumerated()), id: \.offset) { index, option in
                    if isOther(option) {
                        otherRow(index)
                    } else if isChat(option) {
                        Button { choose(index, nil) } label: {
                            Label("Discuss it instead of answering", systemImage: "bubble.left.and.bubble.right").font(.system(size: 12))
                        }
                        .buttonStyle(.borderless).padding(.top, 2)
                    } else {
                        optionButton(index, option)
                    }
                }
            }
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.45)))
    }

    private func optionButton(_ index: Int, _ option: String) -> some View {
        let description = menu.descriptions.indices.contains(index) ? menu.descriptions[index] : nil
        let fromInput = question.flatMap { q in q.options.firstIndex(of: option).flatMap { q.descriptions.indices.contains($0) ? q.descriptions[$0] : nil } }
        let detail = description ?? fromInput
        return Button { choose(index, nil) } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index + 1)").font(.system(size: 11, weight: .bold).monospacedDigit())
                    .frame(width: 20, height: 20).background(Circle().fill(Color.accentColor.opacity(0.18)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.leading)
                    if let detail, detail != option {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(index == menu.selected ? Color.accentColor.opacity(0.12)
                                                                                      : Color.secondary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func otherRow(_ index: Int) -> some View {
        if typingOther {
            HStack(spacing: 8) {
                TextField("Your answer", text: $otherText).textFieldStyle(.roundedBorder)
                    .onSubmit { sendOther(index) }
                Button("Answer") { sendOther(index) }.buttonStyle(.borderedProminent)
                    .disabled(otherText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else {
            Button { typingOther = true } label: {
                Label("Other…", systemImage: "square.and.pencil").font(.system(size: 12.5))
            }
            .buttonStyle(.borderless)
        }
    }

    private func sendOther(_ index: Int) {
        let text = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        choose(index, text)
        otherText = ""
        typingOther = false
    }

    private func isOther(_ option: String) -> Bool { option.lowercased().hasPrefix("type something") }
    private func isChat(_ option: String) -> Bool { option.lowercased().hasPrefix("chat about this") }
}

/// The current to-do list or plan steps, pinned above the conversation while any is open.
private struct TodoPanel: View {
    let todos: [ChatTodo]
    @AppStorage("chatTodosOpen") private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                    Text("Plan").font(.system(size: 12, weight: .semibold))
                    Text("\(todos.filter { $0.status == .done }.count) of \(todos.count) done").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    if let active = todos.first(where: { $0.status == .active }), !open {
                        Text("· \(active.text)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 0 : -90)).accessibilityHidden(true)
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

private extension ChatItem {
    var isTools: Bool { if case .tools = self { return true } else { return false } }
}
