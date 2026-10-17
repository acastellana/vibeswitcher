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
        let host = NSHostingView(rootView: ChatView(chat: chat, row: nil, live: false, showTerminal: {}, choose: { _, _ in },
                                                    moveTab: { _ in }, resend: { _ in }))
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
            if second % 2 == 0 {
                let started = Date()
                window.setContentSize(NSSize(width: second % 4 == 0 ? 640 : 1100, height: 900))
                host.layoutSubtreeIfNeeded()
                print("  resized to \(Int(window.frame.width)) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            }
            // Scroll like a reader: up to the top, the middle, back to the end.
            if let scroll = Self.scrollView(in: host), let document = scroll.documentView {
                let height = document.frame.height - scroll.contentSize.height
                let y = [0, height / 2, height][second % 3]
                let started = Date()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                print("  scrolled to \(Int(y)) of \(Int(height)) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            }
            print("t=\(second)s state=\(chat.state) items=\(chat.items.count) shown=\(min(chat.items.count, chat.shownLimit)) worst stall=\(String(format: "%.2f", worst))s")
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
