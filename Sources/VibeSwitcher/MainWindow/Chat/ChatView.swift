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
    /// Answers the menu on the session's screen the card drew: option index, the free text typed for it.
    let choose: (ScreenMenu, Int, String?) -> Void
    /// Goes to a question's tab (its index).
    let moveTab: (Int) -> Void
    let showTerminal: () -> Void
    /// Esc in the terminal: closes the slash-command menu.
    var dismissMenu: () -> Void = {}

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
            // A session in a Terminal tab: its question is answered there, through the phone's guarded typing.
            let terminal = model.selectedRow.flatMap { $0.hostID == nil ? $0.session : nil }.flatMap { $0.inTerminalApp ? $0 : nil }
            ChatView(chat: chat, row: model.selectedRow, live: model.selectedRow.map(actions.isLive) == true && model.selectedRow?.hostID != nil,
                     inTerminal: terminal.map { session in { actions.openInTerminal(session) } },
                     leadQuestions: lead?.board.questionStack() ?? [], leadNotices: leads.answerNotices,
                     answerLead: { question, text in if let lead { leads.answer(question, root: lead.root, with: text) } },
                     showTerminal: showTerminal, choose: choose, moveTab: moveTab, resend: { _ = composer.send($0) }, dismissMenu: dismissMenu)
                .id(chat.path ?? "")
                .environment(\.chatFolder, model.selectedRow?.cwd)
                .environment(\.chatRunner, chat.runner)
                .environment(\.teamSummaries, leads.summaries)
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
                    TerminalReplyHint(canMove: MoveToWindow.canMove(session), asking: chat.menu != nil,
                                      open: { actions.openInTerminal(session) }, move: { actions.moveToWindow(session) })
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
    /// A session in a Terminal tab: opens it there (⌘O). Its answer card asks before typing into the tab.
    var inTerminal: (() -> Void)?
    /// The lead's questions stack (open ones, then lately withdrawn ones), when this is a project lead.
    var leadQuestions: [LeadQuestion] = []
    var leadNotices: [String: String] = [:]
    var answerLead: (LeadQuestion, String) -> Void = { _, _ in }
    let showTerminal: () -> Void
    /// Answers the menu the card drew: option index, the free text typed for it.
    let choose: (ScreenMenu, Int, String?) -> Void
    /// Goes to a question's tab (its index).
    let moveTab: (Int) -> Void
    let resend: (String) -> Void
    /// Esc in the terminal: closes the slash-command menu.
    var dismissMenu: () -> Void = {}
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
                            ChatItemView(item: item, chat: chat, expanded: item.opens ? chat.expanded : [],
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
                            let note = chat.note(for: message)
                            let late = note == .late
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
                                    Text(note == .held ? "waits until the question is answered" : note == .sending ? "sending…" : "queued")
                                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.leading, 60).padding(.bottom, 6)
                        }
                        LeadQuestionStack(questions: leadQuestions, notices: leadNotices, answer: answerLead)
                        if live || inTerminal != nil, let menu = chat.menu {
                            AnswerCard(menu: menu, pending: chat.log.pendingQuestions, agent: row?.session?.agent.displayName ?? "The agent",
                                       notice: chat.answerNotice, answering: chat.answering, choose: { choose(menu, $0, $1) },
                                       moveTab: moveTab, showTerminal: showTerminal, dismiss: dismissMenu, openInTerminal: inTerminal)
                        } else if let row {
                            LiveStateView(row: row, showTerminal: showTerminal, openInTerminal: inTerminal, notice: inTerminal == nil ? nil : chat.answerNotice)
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
    /// The opened tool groups, tools and team messages (only passed to those items).
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
        case .team(let entry, let message):
            TeamMessageCard(entry: entry, message: message, chat: chat, expanded: expanded).padding(.trailing, 40)
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
    /// A session in a Terminal tab: going there is how you answer (the mirror is read-only).
    var openInTerminal: (() -> Void)?
    /// Why an answer from the card wasn't typed (its question went away meanwhile).
    var notice: String?

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
                            Text("\(session.agent.displayName) is asking in \(openInTerminal == nil ? "the terminal" : "Terminal")")
                                .font(.system(size: 13, weight: .semibold))
                            if let detail = session.detail, !detail.isEmpty {
                                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                            }
                            if let notice {
                                Label(notice, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if let openInTerminal {
                            // Its own screen here is a read-only copy: Terminal is where it takes keys.
                            Button("Show Terminal", action: showTerminal).help("Its screen, read-only")
                            Button(action: openInTerminal) { Label("Open in Terminal", systemImage: "arrow.up.forward.app") }
                                .buttonStyle(.borderedProminent).help("Open in Terminal (⌘O)")
                        } else {
                            Button("Show Terminal", action: showTerminal).buttonStyle(.borderedProminent)
                        }
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
struct TerminalReplyHint: View {
    let canMove: Bool
    /// Its question is on the answer card above.
    var asking = false
    let open: () -> Void
    let move: () -> Void

    static func text(canMove: Bool, asking: Bool) -> String {
        if canMove { return "Runs in Terminal. Move it here to reply from this window." }
        return asking ? "Runs in Terminal. Answer its question above, or open it to type (⌘O)."
                      : "Runs in Terminal. Open it to type (⌘O); Move to Window is offered between turns."
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "macwindow").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(Self.text(canMove: canMove, asking: asking))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            if canMove {
                Button(action: move) { Label("Move to Window", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button(action: open) { Label("Open in Terminal", systemImage: "arrow.up.forward.app") }
                    .controlSize(.small).help("Open in Terminal (⌘O)")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}


/// A question on the session's screen (AskUserQuestion, a permission prompt, a picker), as buttons. What the
/// screen shows decides the options; the question's own input adds headers and descriptions. One click answers it
/// in the terminal, the way you would with the keys.
struct AnswerCard: View {
    let menu: ScreenMenu
    /// The AskUserQuestion still waiting, when that's what's on screen.
    let pending: [ChatQuestion]?
    let agent: String
    let notice: String?
    /// Its answer is being typed in: buttons wait until the terminal shows it.
    let answering: Bool
    let choose: (_ index: Int, _ typing: String?) -> Void
    let moveTab: (_ tab: Int) -> Void
    let showTerminal: () -> Void
    let dismiss: () -> Void
    /// A session in a Terminal tab: opens it there. An answer is asked about first, in one line: it brings
    /// Terminal to the front to type.
    var openInTerminal: (() -> Void)?
    @State private var otherText = ""
    @State private var typingOther = false
    /// The answer waiting for your go-ahead (Terminal sessions): option index, the free text typed for it.
    @State private var confirming: Choice?

    struct Choice: Equatable {
        var index: Int
        var typing: String?
    }

    init(menu: ScreenMenu, pending: [ChatQuestion]?, agent: String, notice: String?, answering: Bool,
         choose: @escaping (Int, String?) -> Void, moveTab: @escaping (Int) -> Void, showTerminal: @escaping () -> Void,
         dismiss: @escaping () -> Void, openInTerminal: (() -> Void)? = nil, confirming: Choice? = nil) {
        self.menu = menu
        self.pending = pending
        self.agent = agent
        self.notice = notice
        self.answering = answering
        self.choose = choose
        self.moveTab = moveTab
        self.showTerminal = showTerminal
        self.dismiss = dismiss
        self.openInTerminal = openInTerminal
        _confirming = State(initialValue: confirming)
    }

    /// A click on the card: answered now in a window session; in a Terminal one, once you confirm.
    private func pick(_ index: Int, _ typing: String?) {
        if openInTerminal == nil { choose(index, typing) } else { confirming = Choice(index: index, typing: typing) }
    }

    var body: some View {
        let content = AnswerCardContent(menu: menu, pending: pending)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Color.accentColor).font(.system(size: 15))
                    .accessibilityHidden(true)
                Text(content.commands ? "Commands" : "\(agent) is asking").font(.system(size: 13, weight: .semibold))
                if let position = content.position {
                    Text(position).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if content.commands {
                    Button("Close (Esc)", action: dismiss).buttonStyle(.borderless).font(.system(size: 11.5))
                }
                if let openInTerminal {
                    Button(action: openInTerminal) { Label("Open in Terminal", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.borderless).font(.system(size: 11.5)).help("Open in Terminal (⌘O)")
                } else {
                    Button("Answer in Terminal", action: showTerminal).buttonStyle(.borderless).font(.system(size: 11.5))
                }
            }
            if content.tabs.count > 1 {
                HStack(spacing: 6) {
                    ForEach(Array(content.tabs.enumerated()), id: \.offset) { index, tab in
                        Button { moveTab(index) } label: {
                            Label(tab.title, systemImage: tab.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11.5, weight: index == content.currentTab ? .semibold : .regular))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(index == content.currentTab ? Color.accentColor : .secondary)
                        // A Terminal tab is answered one question at a time, from the one it shows.
                        .disabled(openInTerminal != nil)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let header = content.header {
                    Text(header.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(content.question).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if content.multiSelect {
                    Text("Choose any that apply, then Submit.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(content.options, id: \.index) { option in
                    switch option.kind {
                    case .other:
                        otherRow(option, typed: content.otherText)
                    case .chat:
                        Button { pick(option.index, nil) } label: {
                            Label("Discuss it instead of answering", systemImage: "bubble.left.and.bubble.right").font(.system(size: 12))
                        }
                        .buttonStyle(.borderless).padding(.top, 2)
                    case .plain:
                        optionButton(option, selected: option.index == content.selected)
                    }
                }
                if let submit = content.submit {
                    Button { pick(content.options.count, nil) } label: {
                        Text(submit).font(.system(size: 12.5, weight: .semibold)).frame(minWidth: 70)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small).padding(.top, 2)
                    .help(submit == "Next" ? "On to the next question" : "Send these answers")
                }
            }
            .disabled(answering || confirming != nil)
            .opacity(answering || confirming != nil ? 0.55 : 1)
            if let confirming {
                HStack(spacing: 8) {
                    Text(ChatSync.confirmation(menu, index: confirming.index, typing: confirming.typing))
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Cancel") { self.confirming = nil }.controlSize(.small).keyboardShortcut(.cancelAction)
                    Button("Answer") {
                        self.confirming = nil
                        choose(confirming.index, confirming.typing)
                    }
                    // No Return shortcut: a stray one mustn't type into Terminal.
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.45)))
        // Asked about one question, never answered on the next one: its index means another option there.
        .onChange(of: menu) { old, new in if !new.sameQuestion(as: old) { confirming = nil } }
    }

    private func optionButton(_ option: AnswerCardContent.Option, selected: Bool) -> some View {
        Button { pick(option.index, nil) } label: {
            HStack(alignment: .top, spacing: 10) {
                if let checked = option.checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square").font(.system(size: 15))
                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                        .frame(width: 20, height: 20).accessibilityLabel(checked ? "Chosen" : "Not chosen")
                } else {
                    Text("\(option.index + 1)").font(.system(size: 11, weight: .bold).monospacedDigit())
                        .frame(width: 20, height: 20).background(Circle().fill(Color.accentColor.opacity(0.18)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.leading)
                    if let detail = option.detail {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func otherRow(_ option: AnswerCardContent.Option, typed: String?) -> some View {
        let index = option.index
        if typingOther {
            HStack(spacing: 8) {
                TextField("Your answer", text: $otherText).textFieldStyle(.roundedBorder)
                    .onSubmit { sendOther(index) }
                Button("Answer") { sendOther(index) }.buttonStyle(.borderedProminent)
                    .disabled(otherText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else if let typed {
            // Typed in the terminal's field: shown here, and editable.
            Button {
                otherText = typed
                typingOther = true
            } label: {
                HStack(spacing: 6) {
                    if let checked = option.checked {
                        Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(checked ? Color.accentColor : .secondary)
                            .accessibilityLabel(checked ? "Chosen" : "Not chosen")
                    } else {
                        Image(systemName: "square.and.pencil").accessibilityHidden(true)
                    }
                    Text("Other: “\(typed)”").font(.system(size: 12.5))
                }
            }
            .buttonStyle(.borderless)
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
        pick(index, text)
        otherText = ""
        typingOther = false
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
    /// Tool groups and team messages open and close.
    var opens: Bool {
        switch self {
        case .tools, .team: return true
        default: return false
        }
    }
}
