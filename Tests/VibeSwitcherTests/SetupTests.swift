import AppKit
import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Preferences written by earlier versions, the first-run decision and the setup model's words.
@MainActor
struct SetupTests {
    /// A defaults suite of its own, emptied before and after.
    private func withSuite(_ body: (UserDefaults, URL) throws -> Void) throws {
        let name = "dev.vibeswitcher.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder)
        }
        try body(defaults, folder.appendingPathComponent("presets.json"))
    }

    /// Every key the ⚙︎ menu and the old Settings wrote, set to its non-default value, reads back unchanged.
    @Test func earlierVersionsPreferencesKeepTheirValues() throws {
        try withSuite { defaults, presets in
            var appearance = TerminalAppearance()
            appearance.fontSize = 17
            appearance.theme = .custom
            appearance.scrollbackLines = 50_000
            appearance.optionAsMeta = false
            let old: [String: Any] = [
                "notifyNeedsInput": false, "notifyDone": false, "playSound": false, "notifyReminders": false,
                "minimizeOnPause": false, "sidebarMode": true, "sidebarAutoHide": false, "sessionOrder": "started",
                "claudeCommand": "claude --model opus", "codexCommand": "codex --full-auto", "floatingPanel": "never",
                "openWindowAtLaunch": true, "terminalAppearance": try JSONEncoder().encode(appearance),
            ]
            for (key, value) in old { defaults.set(value, forKey: key) }

            let preferences = Preferences(defaults: defaults, presetsFile: presets)
            #expect(preferences.notifyNeedsInput == false)
            #expect(preferences.notifyDone == false)
            #expect(preferences.playSound == false)
            #expect(preferences.notifyReminders == false)
            #expect(preferences.minimizeOnPause == false)
            #expect(preferences.sidebarMode == true)
            #expect(preferences.sidebarAutoHide == false)
            #expect(preferences.sessionOrder == .started)
            #expect(preferences.claudeCommand == "claude --model opus")
            #expect(preferences.codexCommand == "codex --full-auto")
            #expect(preferences.floatingPanel == .never)
            #expect(preferences.openWindowAtLaunch == true)
            #expect(preferences.appearance == appearance)
            // With no presets file yet, the two old launch commands become the first presets.
            #expect(preferences.presets.global.contains { $0.kind == .claude && $0.command == "claude --model opus" })
            #expect(preferences.command(for: .codex) == "codex --full-auto")
        }
    }

    /// Settings writes back under the same keys, so an older build (or the ⚙︎ menu) sees the same value.
    @Test func changesAreStoredUnderTheSameKeys() throws {
        try withSuite { defaults, presets in
            let preferences = Preferences(defaults: defaults, presetsFile: presets)
            preferences.notifyDone = false
            preferences.sidebarMode = true
            preferences.sessionOrder = .started
            preferences.floatingPanel = .always
            preferences.openWindowAtLaunch = true
            #expect(defaults.object(forKey: "notifyDone") as? Bool == false)
            #expect(defaults.object(forKey: "sidebarMode") as? Bool == true)
            #expect(defaults.string(forKey: "sessionOrder") == "started")
            #expect(defaults.string(forKey: "floatingPanel") == "always")
            #expect(defaults.object(forKey: "openWindowAtLaunch") as? Bool == true)
            #expect(Preferences(defaults: defaults, presetsFile: presets).floatingPanel == .always)
        }
    }

    @Test func freshPreferencesUseTheDefaults() throws {
        try withSuite { defaults, presets in
            let preferences = Preferences(defaults: defaults, presetsFile: presets)
            #expect(preferences.notifyNeedsInput && preferences.notifyDone && preferences.playSound && preferences.notifyReminders)
            #expect(preferences.minimizeOnPause && preferences.sidebarAutoHide)
            #expect(!preferences.sidebarMode && !preferences.openWindowAtLaunch)
            #expect(preferences.sessionOrder == .screen)
            #expect(preferences.floatingPanel == .automatic)
        }
    }

    @Test func welcomeOnlyOnAMacThatNeverRanVibeSwitcher() throws {
        try withSuite { defaults, _ in
            let none: [Agent: Bool] = [.claude: false, .codex: false]
            #expect(FirstRun.shouldWelcome(defaults: defaults, stateDirExists: false, hooksInstalled: none))
            // Signs of an earlier run: the state folder, either agent's hooks.
            #expect(!FirstRun.shouldWelcome(defaults: defaults, stateDirExists: true, hooksInstalled: none))
            #expect(!FirstRun.shouldWelcome(defaults: defaults, stateDirExists: false, hooksInstalled: [.claude: false, .codex: true]))
            // Launched before by a version without the welcome window (it set this on its first launch).
            defaults.set(true, forKey: "didSetUpLoginItem")
            #expect(!FirstRun.shouldWelcome(defaults: defaults, stateDirExists: false, hooksInstalled: none))
            defaults.removeObject(forKey: "didSetUpLoginItem")
            // Shown once already (closed half way, say): Settings › General brings it back, launches don't.
            defaults.set(true, forKey: FirstRun.shownKey)
            #expect(!FirstRun.shouldWelcome(defaults: defaults, stateDirExists: false, hooksInstalled: none))
        }
    }

    /// `--settings TAB` keeps working for the tabs that existed, and reaches the new ones.
    @Test func settingsTabsKeepTheirNames() {
        for name in ["general", "launch", "terminal", "agents", "phone"] {
            #expect(SettingsTab(rawValue: name) != nil, "\(name)")
        }
    }

    @Test func setupReadsTheLiveStateAndSaysItInWords() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "dev.vibeswitcher.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults, presetsFile: folder.appendingPathComponent("presets.json"))
        let model = SetupModel(preferences: preferences,
                               system: .fixed(hooks: [.claude: true, .codex: false], terminal: .denied, notifications: .notAsked))
        model.refresh()
        for _ in 0..<100 where model.notifications == nil || model.terminal == nil || model.hooks.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(model.hookStatus(.claude) == .ok("Installed"))
        #expect(model.hookStatus(.codex) == .pending("Not installed"))
        #expect(model.anyHooksInstalled && !model.allHooksInstalled)
        #expect(!model.terminalStatus.isOK)
        #expect(model.terminalButton == "Open System Settings…")
        #expect(model.notificationStatus == .pending("Not asked yet"))
        #expect(model.notificationButton == "Allow Notifications…")
    }
}
