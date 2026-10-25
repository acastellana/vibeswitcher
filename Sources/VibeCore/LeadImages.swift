import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Copies of the screenshots the user and the lead are shown: a post_update's images and a done report's evidence
/// screenshots, kept in the project's `.vibeswitcher` folder (`updates/<update id>/`, `evidence/<task>/<report id>/`).
/// What's given usually points into a worktree's `.build` (sandbox shots), which goes when the task is cleaned up, and
/// auto_advance cleans up right after a merge: on 2026-10-25 an update's pictures were gone minutes after it was posted.
///
/// Each image is at most `largest` bytes: a larger one is downscaled (a PNG that fits), not refused. The folder holds
/// at most `cap` bytes: past it, the oldest groups (an update's or a report's images) go first, never the one just
/// kept; where they're shown, a missing image reads "no longer available".
public struct KeptImages {
    public static let defaultCap = 500 << 20
    public static let defaultLargest = 5 << 20

    /// The project's `.vibeswitcher` folder.
    public let folder: String
    public var cap = KeptImages.defaultCap
    public var largest = KeptImages.defaultLargest

    public init(folder: String, cap: Int = KeptImages.defaultCap, largest: Int = KeptImages.defaultLargest) {
        self.folder = folder
        self.cap = cap
        self.largest = largest
    }

    /// Why images weren't kept: a path that isn't there or isn't an image, or the copy failed. Nothing was kept then.
    public struct Refusal: Error, Equatable { public var text: String }

    /// The kinds of groups, each a folder of groups: `updates/<id>`, `evidence/<task>/<id>`.
    static let updates = "updates", evidence = "evidence"

    /// Keeps `paths` (absolute, or relative to `base`) as group `group` (e.g. "updates/<id>"), in their order, and
    /// returns the kept copies' paths. Every path is checked before anything is copied.
    public func keep(_ paths: [String], as group: String, relativeTo base: String) throws -> [String] {
        guard !paths.isEmpty else { return [] }
        let top = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
        let into = top.appendingPathComponent(group, isDirectory: true).standardizedFileURL
        // Only ever under the project's .vibeswitcher (a group is ours to name, but checked all the same).
        guard into.path.hasPrefix(top.path + "/") else { throw Refusal(text: "\(group) isn't a folder under \(folder).") }
        let sources = try paths.map { try Self.image(at: $0, relativeTo: base) }
        do {
            try VibePaths.ensurePrivate(into, within: top)
            let kept = try sources.enumerated().map { index, source -> String in
                var data = try Data(contentsOf: source)
                var name = source.lastPathComponent
                if data.count > largest {
                    guard let smaller = Self.downscaled(source, size: data.count, under: largest) else {
                        throw Refusal(text: "\(source.path) is \(Self.megabytes(data.count)) and doesn't downscale under \(Self.megabytes(largest)): crop it or send a smaller one.")
                    }
                    data = smaller
                    name = (name as NSString).deletingPathExtension + ".png"
                }
                let url = into.appendingPathComponent("\(index + 1)-\(name)")
                try VibePaths.writePrivate(data, to: url)
                return url.path
            }
            prune(keeping: into.path)
            return kept
        } catch {
            try? FileManager.default.removeItem(at: into)
            if let refusal = error as? Refusal { throw refusal }
            throw Refusal(text: "Couldn't keep the images in \(into.path) (\(error.localizedDescription)).")
        }
    }

    /// The file at `path` when it's there and reads as an image; else the refusal says which.
    static func image(at path: String, relativeTo base: String) throws -> URL {
        let given = (path as NSString).expandingTildeInPath
        let url = (given.hasPrefix("/") ? URL(fileURLWithPath: given) : URL(fileURLWithPath: base).appendingPathComponent(given)).standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else {
            throw Refusal(text: "\(path) isn't there\(given.hasPrefix("/") ? "" : " (looked in \(base))"): give the path of an image file that exists.")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] != nil else {
            throw Refusal(text: "\(path) isn't an image (PNG, JPEG, …): give the path of a screenshot.")
        }
        return url
    }

    /// The image at `url` (`size` bytes) as a PNG of at most `limit` bytes, scaled down in steps; nil when even a
    /// small one doesn't fit.
    static func downscaled(_ url: URL, size: Int, under limit: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // Bytes go roughly with the area: the side that would fit, a little under, then smaller until it does.
        var side = Double(max(width, height)) * min(0.9, (Double(limit) / Double(size)).squareRoot() * 0.9)
        while side >= 32 {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: Int(side)]
            let data = NSMutableData()
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if data.length <= limit { return data as Data }
            side *= 0.7
        }
        return nil
    }

    /// Drops the oldest groups until the folder holds at most `cap` bytes, never `keeping` (the group just kept).
    public func prune(keeping: String? = nil) {
        let fm = FileManager.default
        let top = URL(fileURLWithPath: folder, isDirectory: true)
        let children = { (url: URL) in
            (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []
        }
        let groups = children(top.appendingPathComponent(Self.updates)) + children(top.appendingPathComponent(Self.evidence)).flatMap(children)
        var sized = groups.map { group -> (url: URL, bytes: Int, made: Date) in
            let files = (try? fm.contentsOfDirectory(at: group, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let made = (try? group.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return (group, bytes, made)
        }
        var total = sized.reduce(0) { $0 + $1.bytes }
        sized.sort { $0.made < $1.made }
        for group in sized where total > cap && group.url.standardizedFileURL.path != keeping.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) {
            guard (try? fm.removeItem(at: group.url)) != nil else { continue }
            total -= group.bytes
            // A task's evidence folder with no report's images left goes too.
            let parent = group.url.deletingLastPathComponent()
            if parent.deletingLastPathComponent().lastPathComponent == Self.evidence, children(parent).isEmpty { try? fm.removeItem(at: parent) }
        }
    }

    static func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / Double(1 << 20)) }
}
