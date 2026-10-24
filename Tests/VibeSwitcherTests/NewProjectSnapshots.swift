import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Pictures of Home's New Project… sheet, light and dark, drawn offscreen in a real window: empty, and filled in with a
/// first goal. Only with `NEWPROJECT_SNAPSHOT_DIR=/some/folder`.
@MainActor
struct NewProjectSnapshots {
    static let folder = ProcessInfo.processInfo.environment["NEWPROJECT_SNAPSHOT_DIR"]

    @Test(.enabled(if: folder != nil)) func drawTheSheet() throws {
        let folder = try #require(Self.folder)
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = scheme == .darkAqua ? "dark" : "light"
            let empty = NewProjectModel(location: "~/dev")
            try write(render(NewProjectSheet(model: empty, created: { _, _ in }, close: {}), appearance: scheme),
                      to: folder, name: "new-project-\(suffix).png")
            let filled = NewProjectModel(location: "~/nonexistent-projects")
            filled.name = "Weather Station"
            filled.goal = "a page with today's forecast"
            try write(render(NewProjectSheet(model: filled, created: { _, _ in }, close: {}), appearance: scheme),
                      to: folder, name: "new-project-filled-\(suffix).png")
        }
    }

    private func render(_ view: some View, appearance: NSAppearance.Name) throws -> Data {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: max(size.height, 300)),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let frame = try #require(window.contentView)
        frame.layoutSubtreeIfNeeded()
        frame.displayIfNeeded()
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func write(_ data: Data, to folder: String, name: String) throws {
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }
}
