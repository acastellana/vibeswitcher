import AppKit
import Combine
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

/// Settings › Appearance › Theme sets the look of the whole app as well as the terminal. The tests give `AppLook` a
/// scratch view to set, as the app gives it `NSApp`: the app's own appearance would change the look of every other test.
@MainActor
struct AppLookTests {
    let temp = Scratch()

    /// Each theme, and what the app's appearance must be with it (nil: follows macOS).
    static let themes: [(name: String, change: (inout TerminalAppearance) -> Void, expected: NSAppearance.Name?)] = [
        ("Match System", { $0.theme = .system }, nil),
        ("Light", { $0.theme = .light }, .aqua),
        ("Dark", { $0.theme = .dark }, .darkAqua),
        ("Solarized Light", { $0.theme = .solarizedLight }, .aqua),
        ("Solarized Dark", { $0.theme = .solarizedDark }, .darkAqua),
        ("Custom, light background", { $0.theme = .custom; $0.custom.background = "#FAFAFA" }, .aqua),
        ("Custom, dark background", { $0.theme = .custom; $0.custom.background = "#101010" }, .darkAqua),
    ]

    private func preferences(_ name: String, _ defaults: UserDefaults) -> Preferences {
        Preferences(defaults: defaults, presetsFile: temp.url("look-presets-\(name)"))
    }

    @Test func eachThemeSetsTheAppsLookAtOnceAndAgainAtTheNextLaunch() {
        for (index, row) in Self.themes.enumerated() {
            let defaults = temp.defaults("look-\(index)")
            let first = preferences("\(index)", defaults)
            let app = NSView()
            let following = AppLook.follow(first, on: app)
            // From another look, so a theme that sets what was already there can't pass.
            first.appearance.theme = row.expected == .darkAqua ? .light : .dark
            #expect(app.appearance != nil && app.appearance?.name != row.expected, "\(row.name): before the change")

            row.change(&first.appearance)
            #expect(app.appearance?.name == row.expected, "\(row.name): not applied when changed")
            following.cancel()

            // The next launch: a new Preferences on the same defaults, and the look set when it starts following.
            let relaunched = preferences("\(index)", defaults)
            #expect(relaunched.appearance == first.appearance, "\(row.name): not read back")
            let appAgain = NSView()
            appAgain.appearance = NSAppearance(named: row.expected == .darkAqua ? .aqua : .darkAqua)
            let again = AppLook.follow(relaunched, on: appAgain)
            #expect(appAgain.appearance?.name == row.expected, "\(row.name): not restored at launch")
            again.cancel()
        }
    }

    /// Every theme has a row above, so a new one can't be left out of the app's look.
    @Test func theTableCoversEveryTheme() {
        var seen = Set<TerminalAppearance.Theme>()
        for row in Self.themes {
            var appearance = TerminalAppearance()
            row.change(&appearance)
            seen.insert(appearance.theme)
            #expect(AppLook.name(for: appearance) == row.expected, "\(row.name)")
        }
        #expect(seen == Set(TerminalAppearance.Theme.allCases))
    }

    @Test func aCustomThemeFollowsItsBackgroundAsItIsEdited() {
        let settings = preferences("custom", temp.defaults("look-custom"))
        let app = NSView()
        let following = AppLook.follow(settings, on: app)
        settings.appearance.theme = .custom
        settings.appearance.custom.background = "#FFFFFF"
        #expect(app.appearance?.name == .aqua)
        settings.appearance.custom.background = "#000000"
        #expect(app.appearance?.name == .darkAqua)
        // Not a color (an edited settings file): the look isn't guessed, macOS decides.
        settings.appearance.custom.background = "not a color"
        #expect(app.appearance == nil)
        following.cancel()
    }

    /// Setting an app's appearance redraws every window, so only a change of look may reach it.
    @Test func changesThatKeepTheLookLeaveTheAppAlone() {
        let settings = preferences("same", temp.defaults("look-same"))
        settings.appearance.theme = .dark
        let app = NSView()
        let following = AppLook.follow(settings, on: app)
        let marker = NSAppearance(named: .vibrantDark)
        app.appearance = marker
        settings.appearance.fontSize = 20
        settings.appearance.theme = .solarizedDark
        #expect(app.appearance === marker)
        following.cancel()
    }

    /// The menu bar popover isn't drawn in the app's look: a status item's popover takes the system's (AppKit's
    /// `NSStatusBarWindow` overrides `_appearanceForAttachedPopovers`), so it follows the setting itself.
    @Test func theMenuBarPopoverFollowsItToo() throws {
        let settings = preferences("popover", temp.defaults("look-popover"))
        let popover = NSPopover()
        let following = AppLook.follow(settings, on: popover)
        settings.appearance.theme = .dark
        #expect(popover.appearance?.name == .darkAqua)
        settings.appearance.theme = .system
        #expect(popover.appearance == nil)
        following.cancel()

        let source = try SettingsCatalogTests.read("Sources/VibeSwitcher/AppDelegate.swift")
        #expect(source.contains("AppLook.follow(preferences, on: popover)"), "the app's popover doesn't follow Theme")
    }

    /// The app follows the setting first thing at launch: before any window, so none is drawn in the wrong look.
    @Test func theAppFollowsItFromTheStartOfItsLaunch() throws {
        let source = try SettingsCatalogTests.read("Sources/VibeSwitcher/AppDelegate.swift")
        let launch = try #require(source.range(of: "func applicationDidFinishLaunching"))
        let follow = try #require(source.range(of: "AppLook.follow(preferences, on: NSApp)", range: launch.upperBound..<source.endIndex))
        let firstWindow = try #require(source.range(of: "showMainWindow()", range: launch.upperBound..<source.endIndex))
        #expect(follow.lowerBound < firstWindow.lowerBound)
        #expect(!source[launch.upperBound..<follow.lowerBound].contains("Window"))
    }

    /// Picking in the pane, through the binding its Picker holds (SwiftUI draws a Form's picker with no AppKit control to
    /// press): what's stored under `terminalAppearance`, and a fresh read of it, for every theme.
    @Test func pickingAThemeInThePaneStoresItAndReadsItBack() throws {
        let pane = try SettingsCatalogTests.read("Sources/VibeSwitcher/SettingsWindow.swift")
        let row = try #require(pane.range(of: "SettingRow(\"theme\")"))
        let picker = try #require(pane.range(of: "Picker(selection: ", range: row.upperBound..<pane.endIndex))
        #expect(pane[picker.upperBound...].hasPrefix("$preferences.appearance.theme)"), "the Theme row's Picker sets something else")

        let defaults = temp.defaults("look-pane")
        let settings = preferences("pane", defaults)
        let selection = ObservedObject(wrappedValue: settings).projectedValue.appearance.theme
        for theme in TerminalAppearance.Theme.allCases.reversed() {
            selection.wrappedValue = theme
            #expect(settings.appearance.theme == theme, "\(theme): not set")
            let stored = try #require(defaults.data(forKey: "terminalAppearance"), "\(theme): nothing stored")
            #expect(try JSONDecoder().decode(TerminalAppearance.self, from: stored).theme == theme, "\(theme): stored wrong")
            #expect(preferences("pane", defaults).appearance.theme == theme, "\(theme): not read back")
        }
    }

    @Test func theCatalogSaysAppAndTerminalAndSearchingDarkFindsItFirst() throws {
        let theme = try #require(SettingsCatalog.all.first { $0.id == "theme" })
        let description = theme.description.lowercased()
        #expect(description.contains("app") && description.contains("terminal"))
        for keyword in ["dark mode", "light mode", "appearance", "theme"] { #expect(theme.keywords.contains(keyword), "\(keyword)") }
        #expect(SettingsCatalog.search("dark").first?.id == "theme")
        #expect(SettingsCatalog.all.first { $0.category == .appearance }?.id == "theme")

        let pane = try SettingsCatalogTests.read("Sources/VibeSwitcher/SettingsWindow.swift")
        let themeRow = try #require(pane.range(of: "SettingRow(\"theme\")"))
        let fontRow = try #require(pane.range(of: "SettingRow(\"font\")"))
        #expect(themeRow.lowerBound < fontRow.lowerBound, "Theme is the first row of Appearance")
    }
}
