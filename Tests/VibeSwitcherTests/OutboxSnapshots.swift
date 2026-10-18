import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Pictures of the composer's outbox strip, light and dark: a message the app stopped while sending, one typed in
/// before a relaunch that the conversation doesn't show, and one the host didn't confirm. Only with
/// `OUTBOX_SNAPSHOT_DIR=/some/folder`; the outbox is a scratch file, never `~/.vibeswitcher/outbox.json`.
@MainActor
struct OutboxSnapshots {
    nonisolated static let folder = ProcessInfo.processInfo.environment["OUTBOX_SNAPSHOT_DIR"]

    @Test(.enabled(if: folder != nil)) func drawOutboxStrip() throws {
        let folder = try #require(Self.folder)
        let file = scratchRoot.appendingPathComponent("outbox-snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let key = "host:snapshot"
        let image = "/Users/albert/.vibeswitcher/attachments/pasted-2026-10-17-164759-3B80.png"
        try OutboxStore.save([
            OutboxEntry(key: key, message: "Look at this\n\n'\(image)'", text: "Look at this — the sidebar overlaps the chat.",
                        attachments: [image], state: .sending),
            OutboxEntry(key: key, message: "How are things going?", text: "How are things going? Can you check against your memory?",
                        state: .typed),
        ], to: file)
        let outbox = ComposerOutbox(url: file)
        outbox.add(OutboxEntry(key: key, message: "run the tests again", text: "run the tests again"))
        outbox.confirm(key: key, message: "run the tests again", ok: false)

        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let view = OutboxStrip(outbox: outbox, rowID: key, agent: "Claude", send: { _ in }, putBack: { _ in })
                .padding(16).frame(width: 760, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 760, height: 260), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme)
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("outbox-strip-\(scheme == .darkAqua ? "dark" : "light").png"))
        }
    }
}
