import Foundation
import Testing
@testable import VibeSwitcher

/// An image file attached from the composer is drawn in the chat and the composer decoded at its size on screen, not
/// the file's: a retina screenshot drawn whole took 20 MB a picture (ChatMemoryTests measures the chat).
struct ImageCacheTests {
    let scratch = Scratch()

    @Test func aScreenshotFileIsDecodedAtTheHeightItShows() async throws {
        let file = scratch.url("shot.png")
        try ChatMemoryTests.screenshot(seed: 1).write(to: file)
        // The chat's 90-point thumbnail at 2x: 180 pixels high, as wide as the 16:10 screenshot makes it.
        let image = try #require(ImageCache.decode(file: file.path, pixels: 180, fill: false))
        #expect(image.height == 180 && image.width == 288, "\(image.width)x\(image.height)")
        // The composer's 56-point square, filled: the shorter side has the pixels.
        #expect(ImageCache.decode(file: file.path, pixels: 112, fill: true)?.height == 112)
        // What the views ask for: made once, then the same one.
        let shown = await ImageCache.thumbnail(file: file.path, pixels: 180)
        #expect(shown != nil)
        #expect(await ImageCache.thumbnail(file: file.path, pixels: 180) === shown)
    }

    @Test func notAnImageOrNoFileGivesNothing() async throws {
        let text = scratch.url("notes.png")
        try Data("not a picture".utf8).write(to: text)
        #expect(await ImageCache.thumbnail(file: text.path, pixels: 180) == nil)
        #expect(await ImageCache.thumbnail(file: scratch.url("gone.png").path, pixels: 180) == nil)
    }

    @Test func theLongerSideFollowsTheAspect() {
        #expect(ImageCache.maxPixels(width: 2880, height: 1800, pixels: 180, fill: false) == 288)
        // Portrait: its height is the longer side.
        #expect(ImageCache.maxPixels(width: 1000, height: 2000, pixels: 180, fill: false) == 180)
        #expect(ImageCache.maxPixels(width: 1000, height: 2000, pixels: 112, fill: true) == 224)
        // Never more than the image has.
        #expect(ImageCache.maxPixels(width: 100, height: 50, pixels: 180, fill: false) == 100)
    }
}
