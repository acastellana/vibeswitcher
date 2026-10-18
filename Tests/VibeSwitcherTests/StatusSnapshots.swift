import AppKit
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

/// Pictures of how status is shown: the menu bar icon (dots, and the counts past 12 sessions), popover rows, sidebar
/// rows and the pill, one session per status plus a paused one. Only with
/// `STATUS_SNAPSHOT_DIR=/some/folder swift test --filter StatusSnapshots`; `STATUS_SNAPSHOT_NAME` names the files
/// (default "status": status-light.png, status-dark.png).
@MainActor
struct StatusSnapshots {
    static let folder = ProcessInfo.processInfo.environment["STATUS_SNAPSHOT_DIR"]
    static let name = ProcessInfo.processInfo.environment["STATUS_SNAPSHOT_NAME"] ?? "status"

    static func sessions() -> [Session] {
        let since = Date().addingTimeInterval(-300)
        let rows: [(String, SessionStatus, String?)] = [
            ("acme-web", .needsInput, "Run: npm publish --tag next"), ("api-server", .working, nil),
            ("data-jobs", .background, nil), ("docs-site", .done, nil), ("notes", .idle, nil), ("scratch", .unknown, nil),
            ("billing", .working, nil),
        ]
        return rows.enumerated().map { index, row in
            var session = Session(tty: "ttys00\(index)", agent: index == 2 ? .codex : .claude, pid: Int32(100 + index),
                                  startedAt: since, cwd: "/tmp/\(row.0)", project: row.0, task: "Tidy the \(row.0) tests",
                                  status: row.1, statusSince: since, detail: row.2, hasHooks: true, inTerminalApp: true)
            session.isCurrent = index == 1
            if row.0 == "billing" { session.pausedUntil = .distantFuture }
            return session
        }
    }

    @Test(.enabled(if: folder != nil)) func drawStatus() throws {
        let folder = try #require(Self.folder)
        let sessions = Self.sessions()
        let many = (0..<14).map { index in
            let like = sessions[index % sessions.count]
            var session = Session(tty: "ttys1\(index)", agent: like.agent, pid: like.pid, startedAt: like.startedAt, cwd: like.cwd,
                                  project: like.project, task: like.task, status: like.status, statusSince: like.statusSince,
                                  detail: nil, hasHooks: true, inTerminalApp: true)
            session.pausedUntil = like.pausedUntil
            return session
        }
        for scheme in [ColorScheme.light, .dark] {
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
            let bar = [StatusIcon.image(for: sessions), StatusIcon.image(for: many)].map { Self.rasterize($0, appearance) }
            let view = StatusPicture(sessions: sessions, bar: bar)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            var image: NSImage?
            appearance.performAsCurrentDrawingAppearance { image = renderer.nsImage }
            let tiff = try #require(image?.tiffRepresentation)
            let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(Self.name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    /// The menu bar image drawn as the bar would draw it in `appearance` (its colours resolve when drawn), at 4×.
    static func rasterize(_ image: NSImage, _ appearance: NSAppearance) -> NSImage {
        let scale: CGFloat = 4
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
                                   pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale))
        }
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: image.size)
        out.addRepresentation(rep)
        return out
    }
}

private struct StatusPicture: View {
    let sessions: [Session]
    let bar: [NSImage]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            caption("Menu bar")
            HStack(spacing: 24) {
                ForEach(Array(bar.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: image.size.width * 2, height: image.size.height * 2)
                }
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 48)
            .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.93))
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    caption("Popover")
                    VStack(spacing: 2) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            SessionRow(session: session, index: index, isSelected: index == 0)
                        }
                    }
                    .padding(6).frame(width: 400)
                    .background(scheme == .dark ? Color(white: 0.196) : Color(white: 0.925))
                }
                VStack(alignment: .leading, spacing: 6) {
                    caption("Sidebar")
                    VStack(spacing: 2) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            SessionRow(session: session, index: index, isSelected: false, compact: true)
                        }
                    }
                    .padding(6).frame(width: 260)
                    .background(scheme == .dark ? Color(white: 0.196) : Color(white: 0.925))
                    caption("Pill").padding(.top, 10)
                    FloatingDots(sessions: sessions, onOpen: { _ in }, onShowList: {})
                }
            }
        }
        .padding(16)
        .frame(width: 720, alignment: .leading)
        .background(scheme == .dark ? Color(white: 0.12) : Color.white)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}
