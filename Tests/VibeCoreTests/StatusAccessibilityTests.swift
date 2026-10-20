import CoreGraphics
import Foundation
import Testing
@testable import VibeCore

/// Status that reads without colour and colours that read: VoiceOver's summary, the shapes, and AA contrast.
struct StatusAccessibilityTests {
    static func session(_ tty: String, _ status: SessionStatus, paused: Bool = false) -> Session {
        var session = Session(tty: tty, agent: .claude, pid: 1, startedAt: Date(), cwd: nil, project: "p", task: nil, status: status,
                              statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: true)
        if paused { session.pausedUntil = .distantFuture }
        return session
    }

    @Test func theMenuBarSummarySaysWhatNeedsYouFirst() {
        let sessions = [Self.session("a", .working), Self.session("b", .needsInput), Self.session("c", .working),
                        Self.session("d", .needsInput), Self.session("e", .working)]
        #expect(StatusSummary.spoken(sessions) == "VibeSwitcher: 2 need you, 3 working")
        #expect(StatusSummary.spoken([Self.session("a", .needsInput)]) == "VibeSwitcher: 1 needs you")
        #expect(StatusSummary.spoken([]) == "VibeSwitcher: no sessions")
        // Paused sessions count as paused, whatever they're doing.
        let mixed = [Self.session("a", .done), Self.session("b", .background), Self.session("c", .working, paused: true),
                     Self.session("d", .idle), Self.session("e", .unknown)]
        #expect(StatusSummary.spoken(mixed) == "VibeSwitcher: 1 in background, 1 done, 1 idle, 1 unknown, 1 paused")
        #expect(StatusSummary.spoken(number: 3, name: "docs-site", status: .done, paused: false) == "3, docs-site, done")
        #expect(StatusSummary.spoken(number: 7, name: "billing", status: .working, paused: true) == "7, billing, paused")
    }

    @Test func everyStatusHasItsOwnShape() {
        let statuses: [SessionStatus] = [.needsInput, .working, .background, .done, .idle, .unknown]
        let marks = statuses.map { StatusMark(status: $0) } + [StatusMark(status: .working, paused: true)]
        #expect(Set(marks.map { "\($0)" }).count == marks.count)
        #expect(StatusMark(status: .needsInput) == .alert)
        #expect(StatusMark(status: .working) == .spinner)
        #expect(StatusMark(status: .done) == .check)
        #expect(StatusMark(status: .done, paused: true) == .paused)
    }

    @Test func marksStayInsideTheirRect() {
        let rect = CGRect(x: 3, y: 5, width: 9, height: 9)
        for mark in [StatusMark.alert, .spinner, .halfFilled, .check, .smallDot, .outline, .paused] {
            for yDown in [false, true] {
                let parts = mark.body(in: rect, yDown: yDown) + [mark.glyph(in: rect, yDown: yDown)].compactMap { $0 }
                #expect(!parts.isEmpty)
                for part in parts {
                    #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(part.boundingBoxOfPath), "\(mark) spills out")
                }
            }
        }
        // The glyphs that carry the meaning: "!", the check and the pause bars.
        #expect(StatusMark.alert.glyph(in: rect) != nil)
        #expect(StatusMark.check.glyph(in: rect) != nil)
        #expect(StatusMark.paused.glyph(in: rect) != nil)
        // "!" has its dot at the bottom in either coordinate system.
        let up = StatusMark.alert.glyph(in: rect)!.boundingBoxOfPath, down = StatusMark.alert.glyph(in: rect, yDown: true)!.boundingBoxOfPath
        #expect(abs(up.minY - (rect.maxY - (down.maxY - rect.minY))) < 0.01)
    }

    @Test func statusTextAndBadgesMeetAA() {
        for status in [SessionStatus.needsInput, .working, .background, .done, .idle, .unknown] {
            for dark in [false, true] {
                let ink = StatusPalette.ink(status, dark: dark)
                for background in dark ? StatusPalette.darkBackgrounds : StatusPalette.lightBackgrounds {
                    let ratio = StatusPalette.contrast(ink, background)
                    #expect(ratio >= 4.5, "\(status) \(dark ? "dark" : "light") text is \(ratio):1")
                }
                for background in dark ? StatusPalette.darkBackgrounds : StatusPalette.lightBackgrounds {
                    let replaced = StatusPalette.contrast(StatusPalette.replaced(dark: dark), background)
                    #expect(replaced >= 4.5, "replaced lead \(dark ? "dark" : "light") text is \(replaced):1")
                }
                let inside = StatusPalette.contrast(StatusPalette.onInk(dark: dark), ink)
                #expect(inside >= 4.5, "\(status) \(dark ? "dark" : "light") badge number is \(inside):1")
            }
        }
        // The formula, against WCAG's own corner cases.
        #expect(abs(StatusPalette.contrast(.init(hex: 0xFFFFFF), .init(hex: 0x000000)) - 21) < 0.001)
        #expect(abs(StatusPalette.contrast(.init(hex: 0xFF9500), .init(hex: 0xFFFFFF)) - 2.20) < 0.01)
    }

    /// With Increase Contrast on, every text/background pair in the popover, sidebar, pill and menu bar dots is at
    /// least 7:1 (AAA) on their solid backgrounds and tints; without it, the same text stays AA.
    @Test func increaseContrastGivesSevenToOneAndAAWithout() {
        for highContrast in [false, true] {
            let floor = highContrast ? 7.0 : 4.5
            for dark in [false, true] {
                let mode = "\(dark ? "dark" : "light")\(highContrast ? " high contrast" : "")"
                let backgrounds = StatusPalette.backgrounds(dark: dark, highContrast: highContrast)
                var texts: [(String, StatusPalette.RGB)] = [
                    ("replaced lead", StatusPalette.replaced(dark: dark, highContrast: highContrast)),
                    ("Claude badge", StatusPalette.claude(dark: dark, highContrast: highContrast)),
                    ("secondary text", StatusPalette.secondaryText(dark: dark, highContrast: highContrast)),
                ]
                for status in [SessionStatus.needsInput, .working, .background, .done, .idle, .unknown] {
                    let ink = StatusPalette.ink(status, dark: dark, highContrast: highContrast)
                    texts.append(("\(status)", ink))
                    let inside = StatusPalette.contrast(StatusPalette.onInk(dark: dark, highContrast: highContrast), ink)
                    #expect(inside >= floor, "\(status) \(mode) badge number is \(inside):1")
                }
                for (name, text) in texts {
                    for background in backgrounds {
                        let ratio = StatusPalette.contrast(text, background)
                        #expect(ratio >= floor, "\(name) \(mode) text is \(ratio):1")
                    }
                }
            }
        }
        // The solid background is what the high-contrast pairs were measured on.
        #expect(StatusPalette.highContrastLightBackgrounds.first == StatusPalette.solidBackground(dark: false))
        #expect(StatusPalette.highContrastDarkBackgrounds.first == StatusPalette.solidBackground(dark: true))
    }

    static let views = web.deletingLastPathComponent().appendingPathComponent("Sources/VibeSwitcher")

    /// The footer, durations and status text are text the user must read: secondary at the quietest, and the
    /// measured secondary (`.secondaryInk`), never `.tertiary` or the system's `.secondary` (3.8:1 on the popover).
    /// The material gives way to a solid background with Increase Contrast on.
    @Test func whatYouMustReadIsNeverTertiary() throws {
        for file in ["PopoverView.swift", "FloatingPanel.swift", "Sidebar.swift"] {
            let text = try String(contentsOf: Self.views.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                for quiet in [".tertiary", ".quaternary", "foregroundStyle(.secondary)", "AnyShapeStyle(.secondary)",
                              "Color.secondary", ".regularMaterial"] {
                    let use = try Regex(NSRegularExpression.escapedPattern(for: quiet) + "(?!Ink)")
                    #expect(!code.contains(use), "\(file):\(index + 1) uses \(quiet): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        let popover = try String(contentsOf: Self.views.appendingPathComponent("PopoverView.swift"), encoding: .utf8)
        let pill = try String(contentsOf: Self.views.appendingPathComponent("FloatingPanel.swift"), encoding: .utf8)
        let style = try String(contentsOf: Self.views.appendingPathComponent("StatusStyle.swift"), encoding: .utf8)
        #expect(popover.contains(".contrastBackground(") && popover.contains(".fill(.solidBackground)"))
        #expect(pill.contains(".contrastBackground("))
        // AppKit reads the setting when a colour resolves; SwiftUI from the environment.
        #expect(style.contains("accessibilityDisplayShouldIncreaseContrast") && style.contains("colorSchemeContrast"))
    }

    // MARK: The phone app

    static let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Web")

    /// "--name: #rrggbb" pairs in a block of CSS.
    static func colors(in css: Substring) -> [String: StatusPalette.RGB] {
        var found: [String: StatusPalette.RGB] = [:]
        let pattern = try! NSRegularExpression(pattern: "--([A-Za-z-]+):\\s*#([0-9a-fA-F]{6})\\b")
        let text = String(css)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let name = String(text[Range(match.range(at: 1), in: text)!])
            let hex = UInt32(text[Range(match.range(at: 2), in: text)!], radix: 16)!
            found[name] = StatusPalette.RGB(hex: hex)
        }
        return found
    }

    @Test func thePhoneShowsTheSameAAPaletteInLightAndDark() throws {
        let css = try String(contentsOf: Self.web.appendingPathComponent("style.css"), encoding: .utf8)
        let darkStart = try #require(css.range(of: "@media (prefers-color-scheme: dark)"))
        let light = Self.colors(in: css[..<darkStart.lowerBound])
        let dark = light.merging(Self.colors(in: css[darkStart.lowerBound...].prefix(while: { $0 != "}" }) + "}"), uniquingKeysWith: { $1 })
        let names: [(String, SessionStatus)] = [("needsInput", .needsInput), ("working", .working), ("background", .background),
                                                ("done", .done), ("idle", .idle)]
        for (scheme, colors, isDark) in [("light", light, false), ("dark", dark, true)] {
            let backgrounds = [try #require(colors["bg"]), try #require(colors["card"])]
            let onStatus = try #require(colors["on-status"])
            for (name, status) in names {
                let ink = try #require(colors["st-\(name)"], "\(scheme) --st-\(name)")
                #expect(ink == StatusPalette.ink(status, dark: isDark), "\(scheme) --st-\(name) isn't the app's colour")
                for background in backgrounds {
                    #expect(StatusPalette.contrast(ink, background) >= 4.5, "\(scheme) \(name) text")
                }
                #expect(StatusPalette.contrast(onStatus, ink) >= 4.5, "\(scheme) \(name) badge number")
            }
            for name in ["warn", "claude", "muted"] {
                let color = try #require(colors[name], "\(scheme) --\(name)")
                for background in backgrounds {
                    #expect(StatusPalette.contrast(color, background) >= 4.5, "\(scheme) --\(name)")
                }
            }
        }
        // Status text takes its colour from the palette, not a hex of its own (the old ones were 2:1 on white).
        let app = try String(contentsOf: Self.web.appendingPathComponent("app.js"), encoding: .utf8)
        for line in css.split(separator: "\n") where [".when.", ".askLabel", ".status {", ".agent.claude", ".badge"].contains(where: line.hasPrefix) {
            #expect(!line.contains("color: #"), "\(line)")
        }
        for old in ["#ff453a", "#ff9f0a", "#0a84ff", "#30d158", "#8e8e93"] {
            #expect(!app.lowercased().contains(old), "app.js still draws status in \(old)")
        }
    }

    @Test func thePhoneHonoursReducedMotion() throws {
        let css = try String(contentsOf: Self.web.appendingPathComponent("style.css"), encoding: .utf8)
        let app = try String(contentsOf: Self.web.appendingPathComponent("app.js"), encoding: .utf8)
        let block = try #require(css.range(of: "@media (prefers-reduced-motion: reduce)"))
        let rules = css[block.upperBound...].prefix(200)
        #expect(rules.contains("animation: none") && rules.contains("transition: none") && rules.contains("scroll-behavior: auto"))
        // Scrolls in the list and the conversation jump; a smooth one would have to check the preference itself.
        #expect(!app.contains("'smooth'") && !app.contains("\"smooth\""))
    }
}
