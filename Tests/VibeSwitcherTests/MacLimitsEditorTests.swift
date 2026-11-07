import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// Settings › Project lead's Mac-wide limits as the editor saves them (`MacLimitsEditor`).
struct MacLimitsEditorTests {
    let temp = Scratch()

    /// "Ignore usage limits" is saved to mac-limits.json at once and, changed, tells the leads to look again
    /// (`MacLimitsEditor.usageLimitsChanged`, which `LeadController` turns into a nudge for every running lead).
    @Test func ignoringUsageLimitsIsSavedAndTellsTheLeadsWhenItChanges() throws {
        let file = temp.url("limits").appendingPathComponent("mac-limits.json")
        let editor = MacLimitsEditor(file: file)
        #expect(editor.ignoreUsageLimits == false)
        var posted = 0
        let observer = NotificationCenter.default.addObserver(forName: MacLimitsEditor.usageLimitsChanged, object: editor, queue: nil) { _ in
            // Saved before the leads are told.
            #expect(MacLimits.load(from: file).ignoreUsageLimits == editor.ignoreUsageLimits)
            posted += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        editor.ignoreUsageLimits = true
        #expect(MacLimits.load(from: file).ignoreUsageLimits && posted == 1)
        editor.heavySlots = 1
        #expect(posted == 1 && MacLimits.load(from: file).ignoreUsageLimits)
        editor.reload()
        #expect(posted == 1 && editor.ignoreUsageLimits)
        editor.ignoreUsageLimits = false
        #expect(!MacLimits.load(from: file).ignoreUsageLimits && posted == 2)
    }
}
