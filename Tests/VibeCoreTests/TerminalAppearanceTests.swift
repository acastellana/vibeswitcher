import Foundation
import Testing
@testable import VibeCore

struct TerminalAppearanceTests {
    @Test func defaults() {
        let appearance = TerminalAppearance()
        #expect(appearance.fontName == "")
        #expect(appearance.fontSize == TerminalAppearance.defaultFontSize)
        #expect(appearance.theme == .system)
        #expect(appearance.scrollbackLines == 10_000)
        #expect(appearance.optionAsMeta && appearance.cursorBlink)
        #expect(appearance.bell == .visual)
    }

    @Test func olderSettingsDecodeWithDefaultsForMissingKeys() throws {
        let partial = try JSONDecoder().decode(TerminalAppearance.self, from: Data(#"{"fontSize": 15, "theme": "dark"}"#.utf8))
        #expect(partial.fontSize == 15 && partial.theme == .dark && partial.scrollbackLines == 10_000)
        #expect(try JSONDecoder().decode(TerminalAppearance.self, from: Data("{}".utf8)) == TerminalAppearance())
        let unknownTheme = try JSONDecoder().decode(TerminalAppearance.self, from: Data(#"{"theme": "neon"}"#.utf8))
        #expect(unknownTheme.theme == .system)
    }

    @Test func roundTrips() throws {
        var appearance = TerminalAppearance()
        appearance.fontName = "Menlo"
        appearance.theme = .custom
        appearance.custom.background = "#101010"
        appearance.bell = .sound
        let data = try JSONEncoder().encode(appearance)
        #expect(try JSONDecoder().decode(TerminalAppearance.self, from: data) == appearance)
    }

    @Test func palettesAreComplete() {
        for palette in [Palette.light, .dark, .solarizedLight, .solarizedDark] {
            #expect(palette.ansi.count == 16)
            for hex in palette.ansi + [palette.foreground, palette.background, palette.cursor, palette.selection] {
                #expect(RGB(hex: hex) != nil, "\(hex)")
            }
        }
    }

    @Test func systemThemeFollowsDarkMode() {
        let appearance = TerminalAppearance()
        #expect(appearance.palette(darkMode: true) == .dark)
        #expect(appearance.palette(darkMode: false) == .light)
        var solarized = appearance
        solarized.theme = .solarizedDark
        #expect(solarized.palette(darkMode: false) == .solarizedDark)
    }

    @Test func hexParsing() {
        #expect(RGB(hex: "#ff8000") == RGB(red: 1, green: 128.0 / 255, blue: 0))
        #expect(RGB(hex: "FF8000") != nil)
        #expect(RGB(hex: "#fff") == nil)
        #expect(RGB(hex: "#gg0000") == nil)
    }

    @Test func fontSizeIsClamped() {
        let appearance = TerminalAppearance()
        #expect(appearance.withFontSize(100).fontSize == TerminalAppearance.fontSizeRange.upperBound)
        #expect(appearance.withFontSize(2).fontSize == TerminalAppearance.fontSizeRange.lowerBound)
    }
}
