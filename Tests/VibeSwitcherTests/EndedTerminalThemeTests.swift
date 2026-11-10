import AppKit
import Foundation
import SwiftTerm
import Testing
import VibeCore
@testable import VibeSwitcher

/// A terminal draws its own background in the app's theme: a drawing of it (an ended session's, a snapshot) has the
/// palette's background under the palette's text, in dark mode as in light, not whatever is behind it (white, under
/// the dark palette's light text).
@MainActor
struct EndedTerminalThemeTests {
    /// The colour drawn at the far corner of a terminal in `darkMode` whose screen holds some output.
    private func corner(darkMode: Bool) throws -> NSColor {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 640, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua)
        defer { window.close() }
        let terminal = HostTerminalView(frame: window.contentView!.bounds, font: nil, options: TerminalOptions())
        window.contentView!.addSubview(terminal)
        terminal.apply(TerminalAppearance(), darkMode: darkMode)
        terminal.feed(text: "albert@mac % echo hello\r\nhello\r\n")
        let rep = try #require(terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds))
        terminal.cacheDisplay(in: terminal.bounds, to: rep)
        return try #require(rep.colorAt(x: rep.pixelsWide - 20, y: rep.pixelsHigh - 20)?.usingColorSpace(.sRGB))
    }

    private func expected(darkMode: Bool) throws -> NSColor {
        let palette = TerminalAppearance().palette(darkMode: darkMode)
        let rgb = try #require(RGB(hex: palette.background))
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    /// Within a bitmap's colour-space rounding (a dark grey reads a few hundredths lighter through the device space).
    private func near(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) < 0.06 && abs(a.greenComponent - b.greenComponent) < 0.06
            && abs(a.blueComponent - b.blueComponent) < 0.06 && a.alphaComponent > 0.99
    }

    @Test func inDarkModeTheTerminalIsDrawnOnTheDarkBackground() throws {
        let drawn = try corner(darkMode: true), want = try expected(darkMode: true)
        #expect(near(drawn, want), "drawn \(drawn), want \(want)")
    }

    @Test func inLightModeTheTerminalIsDrawnOnTheLightBackground() throws {
        let drawn = try corner(darkMode: false), want = try expected(darkMode: false)
        #expect(near(drawn, want), "drawn \(drawn), want \(want)")
    }
}
