import AppKit
import SwiftUI
import VibeCore

/// Debug aid (`VibeSwitcher --chat-bench TRANSCRIPT`): the chat view in this process (not the running app),
/// offscreen, on a real transcript, followed like the window does; prints the longest main-thread stall each
/// second, how often the view was laid out and what heights its content took, then exits. By default it resizes
/// and scrolls like a reader; OPEN, SEEN, AT and SWITCH instead open a conversation the way the window does and
/// then leave it alone, and EARLIER pages back from there; it must settle: status 3 when its content height still
/// changed in the last 3 seconds, 2 when the main thread got stuck for 10 s, 4 when a tick stalled over the limit
/// (see `StallRule`).
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
        // VIBESWITCHER_BENCH_TICKS=1: what the window's chat timer does once a second while a conversation is shown:
        // Run is offered once the session is seen to take input, the composer is focused, the model publishes.
        let ticks = env["VIBESWITCHER_BENCH_TICKS"] == "1"
        // VIBESWITCHER_BENCH_UPDATES=1: the model publishes every 20 ms (a busy session: transcript lines, screen
        // reads, steering), so every layout the chat asks for gets its chance to run.
        let updates = env["VIBESWITCHER_BENCH_UPDATES"] == "1"
        chat.runner.canRun = whole && !ticks
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
        // VIBESWITCHER_BENCH_AT=top|middle|bottom: once opened again, it's scrolled there (and then left alone).
        let at = env["VIBESWITCHER_BENCH_AT"]
        // VIBESWITCHER_BENCH_SWITCH=PATH: at t=2 another session is selected, whose conversation is in PATH (the chat
        // goes straight from one conversation to the other).
        let other = env["VIBESWITCHER_BENCH_SWITCH"]
        // VIBESWITCHER_BENCH_EARLIER=N: once the conversation watched (the one opened again, or with no OPEN, SEEN, AT
        // or SWITCH the first) has settled, Show earlier is pressed N times, scrolled to the top first as you reach the
        // button, each page left to settle before the next.
        let earlier = max(0, env["VIBESWITCHER_BENCH_EARLIER"].flatMap(Int.init) ?? 0)
        let scenario = other != nil || open != nil || seen != nil || at != nil
        // VIBESWITCHER_BENCH_STALL=1: also checks the hang watchdog (the main thread blocks for 4 s at t=3).
        let stall = env["VIBESWITCHER_BENCH_STALL"] == "1"
        let rule = StallRule.fromEnvironment(env)
        let startLoad = rule.load()
        if !stall { print("  stall rule: \(rule.describe(load: startLoad))") }
        Self.setSeen(nil, path: path)
        var last = Date()
        var worst: TimeInterval = 0
        let longest = LongestTicks()
        var opened = false
        let mainThread = mach_thread_self()
        var lastCPU: TimeInterval?
        let beat = Timer(timeInterval: 0.02, repeats: true) { _ in
            let now = Date()
            worst = max(worst, now.timeIntervalSince(last))
            let cpu = Self.cpuTime(of: mainThread)
            longest.note(now.timeIntervalSince(last), cpu: cpu.flatMap { now in lastCPU.map { now - $0 } })
            lastCPU = cpu
            last = now
            // Opened on the first beat, so the ticks count its layout and not the app's launch.
            if !opened {
                opened = true
                chat.show(path: path)
            }
            if updates, chat.state == .ready { chat.objectWillChange.send() }
            probe.sample()
            probe.note(position: chat.atBottom ? "end" : ChatWindow.anchor(tops: chat.rowTops, visibleTop: chat.visibleTop) ?? "-")
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
        if stall {
            HangWatchdog.shared.describeState = { "chat bench, items=\(chat.items.count)" }
            HangWatchdog.shared.start()
        }
        var second = 0
        // With EARLIER alone the conversation watched is the first one, opened at t=0.
        var reopenedAt: Int? = earlier > 0 && !scenario ? 0 : nil
        // When the conversation opened again had loaded (a big transcript on a busy machine can take seconds): AT
        // scrolls then, and the run lasts long enough after it to tell settling from a slow load.
        var readyAt: Int?
        let paging = Paging()
        /// Ends the run with `status` (3: it never settled), or 4 when a tick stalled over the rule's limit.
        func finish(_ status: Int32) -> Never {
            var failed = false
            if !stall {
                let verdict = rule.verdict(longest, load: [startLoad, rule.load()].compactMap { $0 }.max())
                print(verdict.text)
                failed = verdict.failed
            }
            fflush(stdout)
            exit(status != 0 ? status : failed ? 4 : 0)
        }
        let tick = Timer(timeInterval: 1, repeats: true) { _ in
            second += 1
            longest.second = second
            if stall, second == 3 { Breadcrumbs.shared.note("bench: blocking the main thread for 4 s"); sleep(4) }
            chat.poll()
            let justReady = reopenedAt != nil && readyAt == nil && chat.state == .ready && !chat.items.isEmpty
            if justReady { readyAt = second }
            // The first open is over once its conversation shows and has kept its height for a second, or when the run
            // moves on from it (t=2: resized, switched or left). Paging back, it lasts until the first settle (the
            // first page's press): that much longer a sample of how busy the Mac is.
            if longest.firstOpen == nil, earlier == 0,
               (chat.state == .ready && !chat.items.isEmpty && !probe.changedRecently(seconds: 1)) || (reopenedAt != 0 && second >= 2) || second > seconds {
                longest.endFirstOpen()
            }
            let sweeping = ProcessInfo.processInfo.environment["VIBESWITCHER_BENCH_SWEEP"] != nil
            if ticks, chat.state == .ready {
                chat.runner.canRun = whole
                chat.focusComposer()
                chat.objectWillChange.send()
            }
            if let other {
                if second == 2 {
                    chat.show(path: other)
                    probe.reset()
                    reopenedAt = second
                    print("  switched to \((other as NSString).lastPathComponent)")
                }
            } else if open != nil || seen != nil || at != nil {
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
                if justReady, let at, let scroll = Self.scrollView(in: host) { Self.scroll(scroll, to: at, host: host) }
            } else if earlier == 0, !sweeping {
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
                + "shown=\(min(chat.items.count, chat.shownLimit)) atBottom=\(chat.atBottom) top=\(Int(chat.visibleTop)) rows=\(chat.rowTops.count) "
                + "anchor=\(ChatWindow.anchor(tops: chat.rowTops, visibleTop: chat.visibleTop) ?? "-") worst stall=\(String(format: "%.2f", worst))s \(probe.summary())")
            fflush(stdout)
            probe.nextSecond()
            worst = 0
            if earlier > 0, let reopenedAt {
                // Paging back: once the conversation watched has kept its height for 3 s, Show earlier; once that page
                // has, the next. Each phase may take the run's length (and loading 30 s more).
                guard let readyAt else {
                    if second - reopenedAt >= seconds + 30 {
                        print("FAIL: the conversation never loaded \(second - reopenedAt) s after opening")
                        finish(3)
                    }
                    return
                }
                let since = paging.pressedSecond ?? readyAt
                guard !probe.changedRecently(seconds: 3), !chat.loadingEarlier else {
                    if second - since > seconds {
                        let after = paging.pressedSecond == nil ? "it loaded" : "pressing Show earlier (page \(paging.settles.count + 1))"
                        print("FAIL: the content height still changes \(second - since) s after \(after): height=\(probe.heights.last ?? 0) "
                            + "heights=\(probe.heights.count) range=\(probe.range) \(paging.summary(pages: earlier)) longest tick=\(LongestTicks.text(longest.overall, cpu: longest.overallCPU))")
                        finish(3)
                    }
                    return
                }
                if let pressedAt = paging.pressedAt {
                    paging.settled(max(0, probe.lastChange.timeIntervalSince(pressedAt)), longestTick: LongestTicks.text(longest.page, cpu: longest.pageCPU))
                    print("  page \(paging.settles.count) settled in \(Self.seconds(paging.settles.last ?? 0)): shown=\(min(chat.items.count, chat.shownLimit)) "
                        + "of \(chat.items.count) height=\(probe.heights.last ?? 0), longest tick \(LongestTicks.text(longest.page, cpu: longest.pageCPU))")
                } else {
                    print("  settled \(second - readyAt) s after it loaded: height=\(probe.heights.last ?? 0)")
                }
                let shown = ChatWindow.shown(chat.items, limit: chat.shownLimit, including: nil)
                if paging.settles.count < earlier, shown.hidden > 0 || chat.hasEarlier {
                    // As you reach the button: at the top.
                    if let scroll = Self.scrollView(in: host) { Self.scroll(scroll, to: "top", host: host) }
                    if longest.firstOpen == nil { longest.endFirstOpen() }
                    longest.startPage(paging.settles.count + 1)
                    paging.pressed(at: Date(), second: second)
                    if shown.hidden > 0 {
                        print("  page \(paging.settles.count + 1): Show \(min(shown.hidden, ChatWindow.page)) earlier at t=\(second)s")
                        chat.showEarlier()
                    } else {
                        print("  page \(paging.settles.count + 1): Load earlier at t=\(second)s")
                        chat.loadEarlier()
                    }
                    return
                }
                if paging.settles.count < earlier { print("  nothing earlier to show after \(paging.settles.count) pages") }
                print("settled \(second - reopenedAt) s after opening (loaded after \(readyAt - reopenedAt) s): height=\(probe.heights.last ?? 0) "
                    + "heights=\(probe.heights.count) range=\(probe.range) layouts=\(probe.layouts) last 3 s: \(probe.layoutsRecently) layouts "
                    + "\(paging.summary(pages: earlier)) longest tick=\(LongestTicks.text(longest.overall, cpu: longest.overallCPU))")
                finish(0)
            }
            if earlier > 0 { return }
            // Opened again: the same time after it had loaded as after the reopen when it loads at once (at most 30 s more).
            if let reopenedAt, second >= seconds, second < seconds + 30, readyAt.map({ second - $0 < seconds - reopenedAt - 1 }) ?? true { return }
            if second >= seconds {
                // Opened and left alone, the content must have settled: no height changes in the last 3 seconds.
                if let reopenedAt {
                    guard let readyAt else {
                        print("FAIL: the conversation never loaded \(second - reopenedAt) s after opening")
                        finish(3)
                    }
                    let verdict = probe.changedRecently(seconds: 3) ? "FAIL: the content height still changes" : "settled"
                    print("\(verdict) \(second - reopenedAt) s after opening (loaded after \(readyAt - reopenedAt) s): height=\(probe.heights.last ?? 0) heights=\(probe.heights.count) "
                        + "range=\(probe.range) layouts=\(probe.layouts) last 3 s: \(probe.layoutsRecently) layouts longest tick=\(LongestTicks.text(longest.overall, cpu: longest.overallCPU))")
                    finish(probe.changedRecently(seconds: 3) ? 3 : 0)
                }
                finish(0)
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        app.run()
        exit(0)
    }

    static func seconds(_ value: TimeInterval) -> String { String(format: "%.2fs", value) }

    /// The CPU time `thread` has used.
    static func cpuTime(of thread: thread_act_t) -> TimeInterval? {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }

    /// A tick is the main thread's longest gap between the bench's 20 ms beats. One over 0.25 s fails the bench. On a
    /// Mac whose 1-minute load is over load_threshold (VIBESWITCHER_BENCH_WORKFLOW's workflow.md, else twice the cores,
    /// as the lead's) stalls say how busy the Mac is rather than what the layout does: the first open's ticks are only
    /// recorded (paging back: up to the first settle), and later ones fail over 4 × the first open's longest, never
    /// under 0.25 s:
    /// the second page lays out three times the rows the first open did, and at load 55-60 a page's longest tick was
    /// up to 4.6 × the open's with nothing wrong. So a loaded Mac gives no false failures, a quiet one is strict, and a
    /// layout that stalls for seconds still fails on both.
    struct StallRule {
        static let limit: TimeInterval = 0.25
        static let loadedFactor = 4.0
        let threshold: Double
        /// Where the threshold comes from, for the output.
        let source: String
        /// VIBESWITCHER_BENCH_LOAD=L stands in for the Mac's 1-minute load (the tests).
        let fakeLoad: Double?

        static func fromEnvironment(_ env: [String: String]) -> StallRule {
            let workflow = env["VIBESWITCHER_BENCH_WORKFLOW"].map(LeadWorkflow.load(from:)) ?? LeadWorkflow()
            return StallRule(threshold: workflow.loadLimit,
                             source: workflow.loadThreshold == nil ? "twice the \(MacLoad.processors) cores" : "workflow.md",
                             fakeLoad: env["VIBESWITCHER_BENCH_LOAD"].flatMap(Double.init))
        }

        func load() -> Double? { fakeLoad ?? MacLoad.oneMinute() }

        static func number(_ value: Double) -> String { String(format: "%g", (value * 10).rounded() / 10) }

        /// Over load_threshold; an unknown load is judged as a quiet one.
        func loaded(_ load: Double?) -> Bool { load.map { $0 > threshold } ?? false }

        /// What a tick after the first open may take.
        static func limit(loaded: Bool, firstOpen: TimeInterval?) -> TimeInterval {
            loaded ? max(limit, loadedFactor * (firstOpen ?? 0)) : limit
        }

        func describe(load: Double?, firstOpen: TimeInterval? = nil) -> String {
            guard let load else { return "the Mac's 1-minute load is unknown: any tick over \(ChatBench.seconds(Self.limit)) fails" }
            let mac = "the Mac's 1-minute load \(Self.number(load)) is"
            let line = "load_threshold \(Self.number(threshold)) (\(source))"
            guard loaded(load) else { return "\(mac) not over \(line): any tick over \(ChatBench.seconds(Self.limit)) fails" }
            let limit = firstOpen.map { " = \(ChatBench.seconds(Self.limit(loaded: true, firstOpen: $0)))" } ?? ""
            return "\(mac) over \(line): the first open's ticks are only recorded, later ones fail over "
                + "\(Self.number(Self.loadedFactor)) × its longest\(firstOpen.map { " (\(ChatBench.seconds($0)))" } ?? ""), "
                + "never under \(ChatBench.seconds(Self.limit))\(limit)"
        }

        /// The run's ticks judged at `load`: whether one went over, and a line saying so with the rule.
        func verdict(_ ticks: LongestTicks, load: Double?) -> (failed: Bool, text: String) {
            let loaded = loaded(load)
            let firstOpen = ticks.firstOpen ?? ticks.overall
            let judged = loaded ? ticks.afterOpen : ticks.overall
            let limit = Self.limit(loaded: loaded, firstOpen: firstOpen)
            let place = loaded ? ticks.afterOpenPlace : ticks.overallPlace
            let rule = "rule: " + describe(load: load, firstOpen: loaded ? firstOpen : nil)
            return judged > limit
                ? (true, "FAIL: a tick stalled \(ChatBench.seconds(judged)) (\(place)), over \(ChatBench.seconds(limit)); \(rule)")
                : (false, "ticks: longest \(ChatBench.seconds(judged))\(place.isEmpty ? "" : " (\(place))"), not over \(ChatBench.seconds(limit)); \(rule)")
        }
    }

    /// The longest ticks: in all (from the first beat, so not the app's launch), in the first open, after it, and in
    /// the page being shown, with where each one was.
    final class LongestTicks {
        private var started = false
        /// The tick timer's second, and what the run is doing, for where a tick was.
        var second = 0
        private var phase = "opening"
        private(set) var overall: TimeInterval = 0
        private(set) var overallPlace = ""
        /// The first open's longest, once it's over.
        private(set) var firstOpen: TimeInterval?
        private(set) var afterOpen: TimeInterval = 0
        private(set) var afterOpenPlace = ""
        private(set) var page: TimeInterval = 0
        /// The main thread's CPU time in the overall and the page's longest: near the tick, the main thread was busy
        /// (a layout); far under it, it waited for a core (the Mac's load).
        private(set) var overallCPU: TimeInterval?
        private(set) var pageCPU: TimeInterval?

        /// A tick of `gap` seconds, `cpu` of them on the main thread's CPU.
        func note(_ gap: TimeInterval, cpu: TimeInterval? = nil) {
            guard started else { started = true; return }
            let place = "t=\(second + 1)s, \(phase)" + (cpu.map { ", \(ChatBench.seconds($0)) of it on the CPU" } ?? "")
            if gap > overall { overall = gap; overallPlace = place; overallCPU = cpu }
            if firstOpen != nil, gap > afterOpen { afterOpen = gap; afterOpenPlace = place }
            if gap > page { page = gap; pageCPU = cpu }
        }

        /// "0.66s (cpu 0.61s)".
        static func text(_ tick: TimeInterval, cpu: TimeInterval?) -> String {
            ChatBench.seconds(tick) + (cpu.map { " (cpu \(ChatBench.seconds($0)))" } ?? "")
        }

        func endFirstOpen() {
            firstOpen = overall
            phase = "after the first open"
        }

        func startPage(_ number: Int) {
            page = 0
            pageCPU = nil
            phase = "page \(number)"
        }
    }

    /// Show earlier pressed page by page: when the one pending was pressed, and how each settled.
    private final class Paging {
        private(set) var pressedAt: Date?
        private(set) var pressedSecond: Int?
        private(set) var settles: [TimeInterval] = []
        private var longestTicks: [String] = []

        func pressed(at date: Date, second: Int) {
            pressedAt = date
            pressedSecond = second
        }

        func settled(_ settle: TimeInterval, longestTick: String) {
            settles.append(settle)
            longestTicks.append(longestTick)
            pressedAt = nil
            pressedSecond = nil
        }

        /// "earlier=2 settled=[0.41s,0.38s] page ticks=[0.08s (cpu 0.07s),0.07s (cpu 0.07s)]": the pages asked for, each
        /// one's settle (from the press to its last height change) and longest tick.
        func summary(pages: Int) -> String {
            "earlier=\(pages) settled=[\(settles.map(ChatBench.seconds).joined(separator: ","))] page ticks=[\(longestTicks.joined(separator: ","))]"
        }
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
                             showTerminal: {}, choose: { _, _, _ in }, moveTab: { _ in }, resend: { _ in })
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
                ChatView(chat: chat, row: row, live: false, showTerminal: {}, choose: { _, _, _ in }, moveTab: { _ in }, resend: { _ in })
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
        /// Where it showed (the first row on screen, or the end), each time that changed.
        private var positionsThisSecond: [String] = []
        private var position = ""
        private(set) var lastChange = Date()
        /// Layout counts at the last few seconds' ends.
        private var layoutsAt: [Int] = []

        init(host: CountingHost) { self.host = host }

        /// Starts counting afresh (after the conversation is opened again).
        func reset() {
            heights = []
            heightsThisSecond = []
            layoutsBefore = host.layouts
            layoutsAt = []
        }

        var layouts: Int { host.layouts - layoutsBefore }
        var layoutsRecently: Int { layouts - (layoutsAt.count >= 4 ? layoutsAt[layoutsAt.count - 4] : 0) }
        var range: String { heights.isEmpty ? "-" : "\(heights.min()!)–\(heights.max()!)" }

        /// Notes the content's height when it changed (on every beat: SwiftUI sizes its document view without frame
        /// notifications).
        func sample() {
            guard let height = ChatBench.scrollView(in: host)?.documentView.map({ Int($0.frame.height) }), height != heights.last else { return }
            heights.append(height)
            heightsThisSecond.append(height)
            lastChange = Date()
        }

        func note(position: String) {
            guard position != self.position else { return }
            self.position = position
            positionsThisSecond.append(position)
        }

        func summary() -> String {
            "at=[\(positionsThisSecond.suffix(8).joined(separator: ","))] layouts=\(layouts) heights=\(heightsThisSecond.count) [\(heightsThisSecond.suffix(6).map(String.init).joined(separator: ","))] all=\(heights.count) range=\(range)"
        }

        func nextSecond() {
            heightsThisSecond = []
            positionsThisSecond = []
            layoutsAt.append(layouts)
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
