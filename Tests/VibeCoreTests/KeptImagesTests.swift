import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VibeCore

/// A PNG of `width`×`height` pixels; with `noise`, random pixels, which don't compress (a large file).
func testPNG(width: Int = 40, height: Int = 30, noise: Bool = false) -> Data {
    var pixels = [UInt8](repeating: 0x80, count: width * height * 4)
    if noise { for index in pixels.indices { pixels[index] = UInt8.random(in: 0...255) } }
    for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 0xFF }
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Whether the file at `path` loads as an image, as the app's updates view loads it.
func loadsAsImage(_ path: String) -> Bool {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return false }
    return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
}

/// post_update and done reports keep copies of their screenshots in the project's .vibeswitcher (2026-10-25: an
/// update's pictures pointed into a worktree auto_advance cleaned up right after the merge, and were gone).
struct KeptImagesTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("kept")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// A screenshot where a worker's sandbox puts them: in a worktree's .build.
    func shot(in folder: String, _ name: String = "board.png", _ data: Data = testPNG()) throws -> String {
        let shots = folder + "/.build/sandbox-shots"
        try FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: shots + "/" + name))
        return shots + "/" + name
    }

    @Test func anUpdatesImagesStillLoadAfterTheirWorktreeIsRemoved() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let worktree = root + "/.vibeswitcher/worktrees/all-done-card-a"
        let paths = [try shot(in: worktree, "light.png"), try shot(in: worktree, "dark.png")]

        let posted = lead.call("post_update", ["title": "All-done card", "body": "Shown in the sandbox.", "images": paths])
        #expect(!posted.isError, "\(posted.text)")
        try FileManager.default.removeItem(atPath: worktree)

        let update = try #require(BoardStore(root: root).load().updates.last)
        #expect(update.images == ["1-light.png", "2-dark.png"].map { "\(root)/.vibeswitcher/updates/\(update.id)/\($0)" })
        #expect(update.images.allSatisfy(loadsAsImage))
        // Private, like everything else in .vibeswitcher.
        let mode = try FileManager.default.attributesOfItem(atPath: update.images[0])[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func anUpdateWithAPathThatIsntThereOrIsntAnImageIsRefused() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let good = try shot(in: root + "/scratch")
        let text = root + "/notes.png"
        try "not a picture".write(toFile: text, atomically: true, encoding: .utf8)

        let missing = lead.call("post_update", ["title": "T", "body": "B", "images": [good, root + "/gone.png"]])
        #expect(missing.isError && missing.text == "Not posted: \(root)/gone.png isn't there: give the path of an image file that exists.", "\(missing.text)")
        let notImage = lead.call("post_update", ["title": "T", "body": "B", "images": [text]])
        #expect(notImage.isError && notImage.text.contains("\(text) isn't an image"), "\(notImage.text)")
        let folder = lead.call("post_update", ["title": "T", "body": "B", "images": [root]])
        #expect(folder.isError && folder.text.contains("isn't there"), "\(folder.text)")

        // Nothing was posted, and nothing kept.
        #expect(BoardStore(root: root).load().updates.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root + "/.vibeswitcher/updates")) ?? []).isEmpty)
        // An update without images posts as ever.
        #expect(!lead.call("post_update", ["title": "T", "body": "B"]).isError)
        #expect(BoardStore(root: root).load().updates.last?.images == [])
    }

    /// Past the cap, the oldest groups go first (an update's, a report's), never the one just kept; a task's evidence
    /// folder with nothing left goes with them.
    @Test func theFolderIsCappedByDroppingTheOldestFirst() throws {
        let root = try repo()
        let folder = root + "/.vibeswitcher"
        let image = testPNG(width: 64, height: 64, noise: true)
        let size = image.count
        let source = try shot(in: root + "/scratch", "shot.png", image)
        // Room for two groups of one image.
        let kept = KeptImages(folder: folder, cap: size * 2 + size / 2)
        let fm = FileManager.default
        let made = { (group: String, ago: Double) throws -> String in
            let path = try #require(kept.keep([source], as: group, relativeTo: root).first)
            // Their age set outright: what goes first doesn't hang on the clock's resolution.
            try fm.setAttributes([.creationDate: Date(timeIntervalSinceNow: -ago)], ofItemAtPath: folder + "/" + group)
            return path
        }
        let oldest = try made("evidence/add-b/r1", 300)
        let older = try made("updates/u1", 200)
        #expect(fm.fileExists(atPath: oldest) && fm.fileExists(atPath: older))

        let newest = try #require(kept.keep([source], as: "updates/u2", relativeTo: root).first)
        #expect(!fm.fileExists(atPath: oldest))
        #expect(!fm.fileExists(atPath: folder + "/evidence/add-b"), "the task's emptied evidence folder goes too")
        #expect(fm.fileExists(atPath: older) && fm.fileExists(atPath: newest))

        // One group over the cap by itself stays: it's the one just kept.
        let tiny = KeptImages(folder: folder, cap: size / 2)
        let alone = try #require(tiny.keep([source], as: "updates/u3", relativeTo: root).first)
        #expect(fm.fileExists(atPath: alone))
        #expect(!fm.fileExists(atPath: older) && !fm.fileExists(atPath: newest))
        #expect(KeptImages.defaultCap == 500 << 20)
    }

    /// An image over `largest` is downscaled to a PNG that fits, not refused; one that's small enough is copied as is.
    @Test func aLargeImageIsDownscaled() throws {
        let root = try repo()
        let big = testPNG(width: 400, height: 300, noise: true)
        let source = try shot(in: root + "/scratch", "big.jpg", big)
        let limit = big.count / 5
        let kept = KeptImages(folder: root + "/.vibeswitcher", largest: limit)
        let path = try #require(kept.keep([source], as: "updates/u1", relativeTo: root).first)
        #expect(path.hasSuffix("/1-big.png"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.count <= limit && loadsAsImage(path))
        let image = try #require(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        // Smaller, in proportion.
        #expect(image.width < 400 && abs(image.width * 3 - image.height * 4) <= 4, "\(image.width)×\(image.height)")

        let small = testPNG()
        let copied = try #require(KeptImages(folder: root + "/.vibeswitcher").keep([try shot(in: root + "/scratch", "small.png", small)],
                                                                                  as: "updates/u2", relativeTo: root).first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: copied)) == small)
        #expect(KeptImages.defaultLargest == 5 << 20)
    }

    /// A group is only ever a folder under the project's .vibeswitcher.
    @Test func nothingIsKeptOutsideTheProjectsFolder() throws {
        let root = try repo()
        let source = try shot(in: root + "/scratch")
        #expect(throws: KeptImages.Refusal.self) { try KeptImages(folder: root + "/.vibeswitcher").keep([source], as: "../outside", relativeTo: root) }
        #expect(!FileManager.default.fileExists(atPath: root + "/outside"))
    }
}
