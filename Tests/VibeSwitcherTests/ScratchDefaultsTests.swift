import Foundation
import Testing

/// A test's own defaults (`Scratch.defaults`) are isolation only if they don't fall back on the test process's standard
/// domain for a key they don't hold: the composer reads "chatDrafts" and "chatAttachments" at start, and a draft left in
/// the shared standard defaults would otherwise still reach a harness given a suite of its own.
struct ScratchDefaultsTests {
    let temp = Scratch()

    @Test func aScratchSuiteDoesNotReadAKeyFromTheStandardDomain() {
        let key = "vibeswitcher-tests-isolation-\(UUID().uuidString)"
        let shared = UserDefaults.standard
        shared.set("from the shared defaults", forKey: key)
        defer { shared.removeObject(forKey: key) }
        #expect(shared.string(forKey: key) == "from the shared defaults")
        let own = temp.defaults("isolation")
        #expect(own.object(forKey: key) == nil)
        #expect(own.dictionaryRepresentation()[key] == nil)
    }
}
