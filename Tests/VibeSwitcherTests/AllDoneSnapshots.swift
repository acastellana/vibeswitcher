import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The all-done card's colours read: its green title and the text on its tint hold the status palette's 4.5:1 (7:1
/// with Increase Contrast) on the chat's backgrounds, as `StatusPalette`'s inks do.
struct AllDoneCardContrastTests {
    /// `ink` laid over `base` at `opacity`, as the card's tint is.
    static func blend(_ ink: StatusPalette.RGB, over base: StatusPalette.RGB, _ opacity: Double) -> StatusPalette.RGB {
        func channel(_ a: Double, _ b: Double) -> UInt32 { UInt32(((a * opacity + b * (1 - opacity)) * 255).rounded()) }
        return StatusPalette.RGB(hex: channel(ink.red, base.red) << 16 | channel(ink.green, base.green) << 8 | channel(ink.blue, base.blue))
    }

    @Test func theCardsTextReadsOnItsTint() {
        for dark in [false, true] {
            for highContrast in [false, true] {
                let floor = highContrast ? 7.0 : 4.5
                let ink = StatusPalette.ink(.done, dark: dark, highContrast: highContrast)
                // The palette's backgrounds for the mode (the inks' own rules), and the chat's: the text background.
                let bases = StatusPalette.backgrounds(dark: dark, highContrast: highContrast) + [StatusPalette.RGB(hex: dark ? 0x1E1E1E : 0xFFFFFF)]
                for base in bases {
                    let card = Self.blend(ink, over: base, AllDoneCard.tintOpacity(increased: highContrast))
                    let mode = "\(dark ? "dark" : "light")\(highContrast ? " high contrast" : "")"
                    #expect(StatusPalette.contrast(ink, card) >= floor, "\(mode) title is \(StatusPalette.contrast(ink, card)):1")
                    let secondary = StatusPalette.secondaryText(dark: dark, highContrast: highContrast)
                    #expect(StatusPalette.contrast(secondary, card) >= 4.5, "\(mode) secondary text is \(StatusPalette.contrast(secondary, card)):1")
                    let primary = StatusPalette.RGB(hex: dark ? 0xFFFFFF : 0x000000)
                    #expect(StatusPalette.contrast(primary, card) >= floor, "\(mode) text")
                }
            }
        }
    }
}

/// Pictures of a lead's chat with two all-done cards, light and dark, Increase Contrast off and on: one with Claude's
/// summary and its task list open, one with the written fallback. The real chat view, offscreen, on a made-up
/// transcript. Only with `ALL_DONE_SNAPSHOT_DIR=/some/folder` and HOME and CFFIXED_USER_HOME on a scratch folder (as
/// scripts/test.sh runs it), where the transcript is written.
@MainActor
@Suite(.serialized)
struct AllDoneSnapshots {
    nonisolated static let folder = ProcessInfo.processInfo.environment["ALL_DONE_SNAPSHOT_DIR"]

    static func time(_ minute: Int) -> String { String(format: "2026-10-19T08:%02d:00Z", minute) }
    static func at(_ minute: Int, second: Int = 0) -> Double {
        ISO8601DateFormatter().date(from: time(minute))!.timeIntervalSince1970 + Double(second)
    }

    static func transcript() throws -> Data {
        var lines: [[String: Any]] = []
        func user(_ text: String, _ minute: Int) {
            lines.append(["type": "user", "uuid": "u\(lines.count)", "timestamp": time(minute), "message": ["role": "user", "content": text]])
        }
        func reply(_ text: String, _ minute: Int) {
            lines.append(["type": "assistant", "uuid": "r\(lines.count)", "timestamp": time(minute),
                          "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
        }
        user("Can you make sign-in work with email, and fix the crash when the app starts?", 10)
        reply("On it: three tasks on the board, two workers started.", 11)
        reply("Merged **email-sign-in** and **fix-start-crash**; the last one, **remember-me**, is with its worker.", 30)
        reply("Merged **remember-me**. That's everything on the board.", 41)
        user("Great. Now the settings page please.", 44)
        reply("Planned **settings-page** and started a worker.", 45)
        reply("Merged **settings-page**.", 58)
        var data = Data()
        for line in lines { data.append(try JSONSerialization.data(withJSONObject: line)); data.append(0x0A) }
        return data
    }

    static func marks() -> [LeadAllDone] {
        var first = LeadAllDone(id: "first", at: at(41, second: 30), since: at(10), tasks: [
            .init(slug: "email-sign-in", title: "Sign in with an email address", outcome: .merged),
            .init(slug: "fix-start-crash", title: "Fix the crash when the app starts", outcome: .merged),
            .init(slug: "old-login-screen", title: "Redesign the old login screen", outcome: .folded),
            .init(slug: "remember-me", title: "Remember the user between visits", outcome: .merged),
        ])
        first.summary = .init(headline: "People can now sign in with just their email, and the app opens reliably.", bullets: [
            "Signing in takes an email address instead of a separate username, so there's one less thing to remember.",
            "The app no longer crashes when it starts, so everyone gets in on the first try.",
            "Returning visitors stay signed in, so they don't have to type their details every time.",
            "The new sign-in screen replaces the old one, which looks cleaner on phones too.",
        ], byModel: true)
        var second = LeadAllDone(id: "second", at: at(58, second: 30), since: first.at, tasks: [
            .init(slug: "settings-page", title: "A settings page for notifications", outcome: .merged),
            .init(slug: "dark-icons", title: "Dark icons for the settings page", outcome: .abandoned),
        ])
        second.summary = BatchSummary.fallback(second.tasks)
        return [first, second]
    }

    @Test(.enabled(if: folder != nil)) func drawAllDoneCards() async throws {
        let folder = try #require(Self.folder)
        let scratch = Scratch()
        // The chat reads transcripts only under ~/.claude/projects: a scratch home's, never the real one.
        let home = try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], "Run with CFFIXED_USER_HOME on a scratch folder")
        #expect(NSHomeDirectory() == home)
        let projects = scratch.adopt(URL(fileURLWithPath: home).appendingPathComponent(".claude/projects/all-done-snapshots-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let path = projects.appendingPathComponent("lead.jsonl")
        try Self.transcript().write(to: path)
        defer { Contrast.override = nil }
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            for increased in [false, true] {
                Contrast.override = increased
                let chat = ChatModel()
                chat.show(path: path.path)
                let deadline = Date().addingTimeInterval(hangGuard)
                // The read lands through the main queue: let it run.
                while chat.state != .ready, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
                #expect(chat.state == .ready)
                chat.showAllDone(Self.marks())
                #expect(chat.items.filter { if case .allDone = $0 { return true } else { return false } }.count == 2)
                chat.expanded.insert(AllDoneCard.key(Self.marks()[0]))
                let view = ChatView(chat: chat, row: nil, live: false, showTerminal: {}, choose: { _, _, _ in }, moveTab: { _ in }, resend: { _ in })
                    .environment(\.contrastOverride, increased)
                    .frame(width: 760, height: 1250)
                    .background(Color(nsColor: .textBackgroundColor))
                let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 760, height: 1250), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme)
                let host = NSHostingView(rootView: view)
                window.contentView = host
                window.orderFrontRegardless()
                defer { window.close() }
                // Laid out a few rows a turn (`ChatStaging`): until all of them are.
                while chat.staging != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
                for _ in 0..<6 {
                    try await Task.sleep(for: .milliseconds(50))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                let name = "chat-all-done-\(scheme == .darkAqua ? "dark" : "light")\(increased ? "-increased" : "").png"
                try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
        }
    }
}
