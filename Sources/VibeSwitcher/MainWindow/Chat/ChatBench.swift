import AppKit
import SwiftUI
import VibeCore

/// Debug aid (`VibeSwitcher --chat-bench TRANSCRIPT`): the chat view in this process (not the running app),
/// offscreen, on a real transcript, followed like the window does; prints the longest main-thread stall each
/// second, how often the view was laid out and what heights its content took, then exits (status 2 when the main
/// thread got stuck for 10 s, 3 when an opened chat's content height never settled).
enum ChatBench {
    private static let env = ProcessInfo.processInfo.environment

    static func run(path: String) -> Never {
        // VIBESWITCHER_BENCH_SECONDS=N: how long it runs (default 15).
        let seconds = env["VIBESWITCHER_BENCH_SECONDS"].flatMap(Int.init) ?? 15
        // VIBESWITCHER_BENCH_FONT=SIZE: the chat's text size (⌘+ / ⌘−); unset: the standard one.
        if let font = env["VIBESWITCHER_BENCH_FONT"].flatMap(Double.init) {
            UserDefaults.standard.set(font, forKey: ChatFont.key)
        } else {
            UserDefaults.standard.removeObject(forKey: ChatFont.key)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let chat = ChatModel()
        // VIBESWITCHER_BENCH_LIVE=1: as for a session that's working (its live line ticks every second).
        var row: WindowRow?
        // VIBESWITCHER_BENCH_WINDOW=1: the chat pane as the window has it (ChatContainer): a lead's team strip above
        // (VIBESWITCHER_BENCH_BOARD=REPO: its .vibeswitcher/board.json), a window session you can type into, the
        // composer below; replies resolve paths against VIBESWITCHER_BENCH_FOLDER and offer Run on code blocks.
        let whole = env["VIBESWITCHER_BENCH_WINDOW"] == "1"
        if env["VIBESWITCHER_BENCH_LIVE"] == "1" || whole {
            var session = Session(tty: "ttys999", agent: .claude, pid: 1, startedAt: Date(), cwd: "/tmp", project: "bench", task: nil,
                                  status: .working, statusSince: Date().addingTimeInterval(-300), detail: nil, hasHooks: true, inTerminalApp: false)
            session.activity = "Run tests"
            session.activitySince = Date().addingTimeInterval(-42)
            row = WindowRow(content: .agent(session), project: "bench")
        }
        // A new chat view per conversation, as ChatContainer has it (`.id(chat.path)`).
        chat.runner.canRun = whole && env["VIBESWITCHER_BENCH_TICKS"] != "1"
        // VIBESWITCHER_BENCH_TICKS=1: what the window's chat timer does after a conversation is shown: Run is
        // offered once the session is seen to take input, the composer is focused, the model publishes changes.
        let ticks = env["VIBESWITCHER_BENCH_TICKS"] == "1"
        let what = env["VIBESWITCHER_BENCH_WHAT"] ?? "rfp"
        let view = BenchRoot(chat: chat, row: row, whole: whole,
                             board: env["VIBESWITCHER_BENCH_BOARD"].map { BoardStore(root: $0).load() }, folder: env["VIBESWITCHER_BENCH_FOLDER"])
        // VIBESWITCHER_BENCH_STACK=1: inside a VStack with a composer-like view below, as the window has it.
        let host = CountingHost(rootView: env["VIBESWITCHER_BENCH_STACK"] == "1"
            ? AnyView(VStack(spacing: 0) { view; Text("composer").frame(height: 60) })
            : AnyView(view))
        // VIBESWITCHER_BENCH_SIZE=WxH: the chat pane's size (default 900x900); e.g. 1100x950 for a 1728x1014 window
        // with the list and the inspector showing.
        let size = env["VIBESWITCHER_BENCH_SIZE"].map { $0.split(separator: "x").compactMap { Double($0) } }.flatMap { $0.count == 2 ? $0 : nil } ?? [900, 900]
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size[0], height: size[1]), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        print("  window \(Int(size[0]))x\(Int(size[1])) at scale \(window.backingScaleFactor), screen \(window.screen.map { "\($0.backingScaleFactor)" } ?? "none")")
        let probe = Probe(host: host)
        Watchdog.start()
        // VIBESWITCHER_BENCH_OPEN=top|middle|bottom: the conversation is opened, read there, left and opened again
        // (the window restores where you were reading), then only watched: no resizes, no scrolls.
        let open = env["VIBESWITCHER_BENCH_OPEN"]
        // VIBESWITCHER_BENCH_SEEN=N: you had last seen entry N, so it's opened again at "New since you looked".
        let seen = env["VIBESWITCHER_BENCH_SEEN"].flatMap(Int.init)
        Self.setSeen(nil, path: path)
        chat.show(path: path)
        var last = Date()
        var worst: TimeInterval = 0
        let beat = Timer(timeInterval: 0.02, repeats: true) { _ in
            let now = Date()
            worst = max(worst, now.timeIntervalSince(last))
            last = now
            probe.sample()
            Watchdog.beat(layouts: host.layouts)
        }
        RunLoop.main.add(beat, forMode: .common)
        // VIBESWITCHER_BENCH_SWEEP=N: scrolls N points a frame, end to end and back, like a trackpad.
        if let step = ProcessInfo.processInfo.environment["VIBESWITCHER_BENCH_SWEEP"].flatMap(Double.init), step > 0 {
            var direction = -1.0
            let sweep = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
                guard let scroll = Self.scrollView(in: host), let document = scroll.documentView else { return }
                let height = max(0, document.frame.height - scroll.contentSize.height)
                var y = scroll.contentView.bounds.origin.y + direction * step
                if y <= 0 || y >= height { direction = -direction; y = min(max(0, y), height) }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            RunLoop.main.add(sweep, forMode: .common)
        }
        // VIBESWITCHER_BENCH_STALL=1: also checks the hang watchdog (the main thread blocks for 4 s at t=3).
        let stall = env["VIBESWITCHER_BENCH_STALL"] == "1"
        if stall {
            HangWatchdog.shared.describeState = { "chat bench, items=\(chat.items.count)" }
            HangWatchdog.shared.start()
        }
        var second = 0
        var reopenedAt: Int?
        let tick = Timer(timeInterval: 1, repeats: true) { _ in
            second += 1
            if stall, second == 3 { Breadcrumbs.shared.note("bench: blocking the main thread for 4 s") ; sleep(4) }
            chat.poll()
            let sweeping = ProcessInfo.processInfo.environment["VIBESWITCHER_BENCH_SWEEP"] != nil
            if ticks, chat.state == .ready {
                if what.contains("r") { chat.runner.canRun = whole }
                if what.contains("f") { chat.focusComposer() }
                if what.contains("p") { chat.objectWillChange.send() }
            }
            if open != nil || seen != nil {
                // t=1: read at that position; t=2: leave it; t=3: come back to it.
                if second == 1, let open, let scroll = Self.scrollView(in: host) { Self.scroll(scroll, to: open, host: host) }
                if second == 1, let seen { Self.setSeen(chat.log.entries[min(seen, chat.log.entries.count) - 1].id, path: path) }
                if second == 2 { chat.show(path: nil) }
                if second == 3 {
                    chat.show(path: path)
                    probe.reset()
                    reopenedAt = second
                    print("  reopened, anchor \(chat.restoreAnchor ?? "none")")
                }
            } else if !sweeping {
                // A width change (sidebar or inspector toggled, the window dragged): every row is measured again.
                if second % 2 == 0 {
                    let started = Date()
                    window.setContentSize(NSSize(width: second % 4 == 0 ? 640 : 1100, height: size[1]))
                    host.layoutSubtreeIfNeeded()
                    print("  resized to \(Int(window.frame.width)) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                }
                // Scroll like a reader: up to the top, the middle, back to the end.
                if let scroll = Self.scrollView(in: host) {
                    Self.scroll(scroll, to: ["top", "middle", "bottom"][second % 3], host: host)
                }
            }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
            print("t=\(second)s cpu=\(String(format: "%.1f", cpu))s state=\(chat.state) entries=\(chat.log.entries.count) items=\(chat.items.count) "
                + "shown=\(min(chat.items.count, chat.shownLimit)) worst stall=\(String(format: "%.2f", worst))s \(probe.summary()) "
                + "atEnd=\(chat.atBottom) top=\(Int(chat.visibleTop)) rows=\(chat.rowTops.count) anchor=\(ChatWindow.anchor(tops: chat.rowTops, visibleTop: chat.visibleTop) ?? "-")")
            fflush(stdout)
            probe.nextSecond()
            worst = 0
            if second >= seconds {
                // Opened and left alone, the content must have settled: no height changes in the last 3 seconds.
                if let reopenedAt, second - reopenedAt > 4, probe.changedRecently(seconds: 3) {
                    print("FAIL: the content height still changes \(second - reopenedAt) s after opening")
                    exit(3)
                }
                exit(0)
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        app.run()
        exit(0)
    }

    private static func scroll(_ scroll: NSScrollView, to position: String, host: NSView) {
        guard let document = scroll.documentView else { return }
        let height = document.frame.height - scroll.contentSize.height
        let y = position == "top" ? 0 : position == "middle" ? height / 2 : height
        let started = Date()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        print("  scrolled to \(Int(y)) of \(Int(height)) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    }

    /// What ChatModel.markSeen keeps (in this process's own defaults, not the app's).
    private static func setSeen(_ id: String?, path: String) {
        var stored = UserDefaults.standard.dictionary(forKey: "chatSeen") ?? [:]
        stored[path] = id.map { ["id": $0, "at": Date().timeIntervalSince1970] }
        UserDefaults.standard.set(stored, forKey: "chatSeen")
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil, scroll.hasVerticalScroller || scroll.contentSize.height > 100 { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }

    private struct BenchRoot: View {
        @ObservedObject var chat: ChatModel
        let row: WindowRow?
        let whole: Bool
        let board: LeadBoard?
        let folder: String?

        var body: some View {
            if whole, let row {
                VStack(spacing: 0) {
                    if let board { TeamStrip(board: board) { _ in } }
                    ChatView(chat: chat, row: row, live: true, leadQuestions: board?.questions.filter { $0.answer == nil } ?? [],
                             showTerminal: {}, choose: { _, _ in }, moveTab: { _ in }, resend: { _ in })
                        .id(chat.path ?? "")
                        .environment(\.chatFolder, folder)
                        .environment(\.chatRunner, chat.runner)
                    Divider()
                    ComposerView(chat: chat, composer: chat.composer, rowID: row.draftKey, agent: .claude, working: true,
                                 actions: ComposerActions(send: { _ in false }, steer: { _ in false }, stop: {}, cycleMode: {}))
                        .id(row.id)
                }
                .background(Color(nsColor: .textBackgroundColor))
            } else {
                ChatView(chat: chat, row: row, live: false, showTerminal: {}, choose: { _, _ in }, moveTab: { _ in }, resend: { _ in })
                    .id(chat.path ?? "")
            }
        }
    }

    /// Counts the hosting view's layout passes.
    private final class CountingHost: NSHostingView<AnyView> {
        var layouts = 0
        override func layout() {
            layouts += 1
            super.layout()
        }
    }

    /// Layout passes and the heights the scroll view's content took, per second and in all.
    private final class Probe {
        let host: CountingHost
        private var layoutsBefore = 0
        private(set) var heights: [Int] = []
        private var heightsThisSecond: [Int] = []
        private var lastChange = Date()

        init(host: CountingHost) { self.host = host }

        /// Starts counting afresh (after the conversation is opened again).
        func reset() {
            heights = []
            heightsThisSecond = []
            layoutsBefore = host.layouts
        }

        /// Notes the content's height when it changed (on every beat: SwiftUI sizes its document view without frame
        /// notifications).
        func sample() {
            guard let height = ChatBench.scrollView(in: host)?.documentView.map({ Int($0.frame.height) }), height != heights.last else { return }
            heights.append(height)
            heightsThisSecond.append(height)
            lastChange = Date()
        }

        func summary() -> String {
            let range = heights.isEmpty ? "-" : "\(heights.min()!)–\(heights.max()!)"
            return "layouts=\(host.layouts - layoutsBefore) heights=\(heightsThisSecond.count) [\(heightsThisSecond.suffix(6).map(String.init).joined(separator: ","))] all=\(heights.count) range=\(range)"
        }

        func nextSecond() {
            heightsThisSecond = []
        }

        func changedRecently(seconds: TimeInterval) -> Bool { Date().timeIntervalSince(lastChange) < seconds }
    }

    /// From another thread: a main thread stuck for 10 s is reported (with how far layout got) and ends the bench.
    private enum Watchdog {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var lastBeat = Date()
        nonisolated(unsafe) private static var layouts = 0

        static func beat(layouts: Int) { lock.lock(); lastBeat = Date(); Self.layouts = layouts; lock.unlock() }

        static func start() {
            Thread.detachNewThread {
                while true {
                    Thread.sleep(forTimeInterval: 0.5)
                    lock.lock()
                    let stuck = Date().timeIntervalSince(lastBeat), layouts = Self.layouts
                    lock.unlock()
                    if stuck > 10 {
                        print("HANG: the main thread is stuck for \(Int(stuck)) s (\(layouts) layouts before it)")
                        fflush(stdout)
                        exit(2)
                    }
                }
            }
        }
    }
}
