import AppKit
import SwiftUI
import VibeCore

/// Debug aid (`VibeSwitcher --chat-bench TRANSCRIPT`): the chat view in this process (not the running app),
/// offscreen, on a real transcript, followed like the window does; prints the longest main-thread stall each
/// second, then exits.
enum ChatBench {
    static func run(path: String, seconds: Int = 15) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let chat = ChatModel()
        // VIBESWITCHER_BENCH_LIVE=1: as for a session that's working (its live line ticks every second).
        var row: WindowRow?
        if ProcessInfo.processInfo.environment["VIBESWITCHER_BENCH_LIVE"] == "1" {
            var session = Session(tty: "ttys999", agent: .claude, pid: 1, startedAt: Date(), cwd: "/tmp", project: "bench", task: nil,
                                  status: .working, statusSince: Date().addingTimeInterval(-300), detail: nil, hasHooks: true, inTerminalApp: false)
            session.activity = "Run tests"
            session.activitySince = Date().addingTimeInterval(-42)
            row = WindowRow(content: .agent(session), project: "bench")
        }
        let view = ChatView(chat: chat, row: row, live: false, showTerminal: {}, choose: { _, _ in }, moveTab: { _ in }, resend: { _ in })
        // VIBESWITCHER_BENCH_STACK=1: inside a VStack with a composer-like view below, as the window has it.
        let host = ProcessInfo.processInfo.environment["VIBESWITCHER_BENCH_STACK"] == "1"
            ? NSHostingView(rootView: AnyView(VStack(spacing: 0) { view; Text("composer").frame(height: 60) }))
            : NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        chat.show(path: path)
        var last = Date()
        var worst: TimeInterval = 0
        let beat = Timer(timeInterval: 0.02, repeats: true) { _ in
            let now = Date()
            worst = max(worst, now.timeIntervalSince(last))
            last = now
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
        let stall = ProcessInfo.processInfo.environment["VIBESWITCHER_BENCH_STALL"] == "1"
        if stall {
            HangWatchdog.shared.describeState = { "chat bench, items=\(chat.items.count)" }
            HangWatchdog.shared.start()
        }
        var second = 0
        let tick = Timer(timeInterval: 1, repeats: true) { _ in
            second += 1
            if stall, second == 3 { Breadcrumbs.shared.note("bench: blocking the main thread for 4 s"); sleep(4) }
            chat.poll()
            // A width change (sidebar or inspector toggled, the window dragged): every row is measured again.
            let sweeping = ProcessInfo.processInfo.environment["VIBESWITCHER_BENCH_SWEEP"] != nil
            if !sweeping, second % 2 == 0 {
                let started = Date()
                window.setContentSize(NSSize(width: second % 4 == 0 ? 640 : 1100, height: 900))
                host.layoutSubtreeIfNeeded()
                print("  resized to \(Int(window.frame.width)) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            }
            // Scroll like a reader: up to the top, the middle, back to the end.
            if !sweeping, let scroll = Self.scrollView(in: host), let document = scroll.documentView {
                let height = document.frame.height - scroll.contentSize.height
                let y = [0, height / 2, height][second % 3]
                let started = Date()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                print("  scrolled to \(Int(y)) of \(Int(height)) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
            print("t=\(second)s cpu=\(String(format: "%.1f", cpu))s state=\(chat.state) items=\(chat.items.count) shown=\(min(chat.items.count, chat.shownLimit)) worst stall=\(String(format: "%.2f", worst))s")
            fflush(stdout)
            worst = 0
            if second >= seconds { exit(0) }
        }
        RunLoop.main.add(tick, forMode: .common)
        app.run()
        exit(0)
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil, scroll.hasVerticalScroller || scroll.contentSize.height > 100 { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }
}
