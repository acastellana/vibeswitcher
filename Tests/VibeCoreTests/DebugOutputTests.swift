import Foundation
import Testing
@testable import VibeCore

struct DebugOutputTests {
    @Test func debugFilesOnlyGoToScratchPlaces() {
        let home = "/Users/someone"
        #expect(DebugOutput.allowed("/tmp/w.png", home: home))
        #expect(DebugOutput.allowed("/private/tmp/x/screen.txt", home: home))
        #expect(DebugOutput.allowed(NSTemporaryDirectory() + "a.png", home: home))
        #expect(DebugOutput.allowed("/Users/someone/.vibeswitcher/debug/w.png", home: home))
        // Anywhere else could overwrite the user's files (any same-user process can post the notification).
        #expect(!DebugOutput.allowed("/Users/someone/Documents/notes.txt", home: home))
        #expect(!DebugOutput.allowed("/Users/someone/.zshrc", home: home))
        #expect(!DebugOutput.allowed("/tmp/../Users/someone/.zshrc", home: home))
        #expect(!DebugOutput.allowed("relative.png", home: home))
    }
}
