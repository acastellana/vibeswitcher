import Foundation

/// What a switch's one code seals beside the switch (2026-11-24, after the user's first switch on the real node took
/// some ten commands; the lead's rule of that day): the builds folder as `vibeswitcher update` found it right after its
/// install, and the node's unit folder with only the unit's `ExecStart` moved to the new build. The checks are the
/// server's (`SwitchSealCheck`, VibeNode); here, what they need of the seal's own reading:
///
/// - `partialKey`: the mark an app's accept carries when it seals only what it shows (`LeadVault`'s judge), the rest
///   held as a look holds it. Without it, an accept that doesn't show everything held seals nothing, as ever.
/// - `entries(listing:)`: a `.listing` folder's top-level entries, each hashed as the seal hashes the whole
///   (`LinuxSealList.listingHash`: names, types, modes, sizes, inodes, times, link targets, never contents).
/// - `folderHashes(folder:name:file:swap:)`: a `.folder`'s hash as the seal reads it, with one file read once: as it is, and with
///   its bytes as `swap` makes them, so a check can say the folder is the accepted one but for that file's change.
public enum SwitchSeal {
    /// The mark (a key no watched thing has) of an accept that seals only what it shows.
    public static let partialKey = ConfigSeal.keyPrefix + "#partial"
    /// The seal's names of the builds folder and the user manager's unit folder (`LinuxSealList.homeEntries`).
    public static let buildsName = "~/.vibeswitcher/v2/builds"
    public static let unitFolderName = "~/.config/systemd/user"
    public static var buildsKey: String { ConfigSeal.keyPrefix + buildsName }
    public static var unitFolderKey: String { ConfigSeal.keyPrefix + unitFolderName }

    /// The whole of a `.listing` folder, hashed as the seal hashes it.
    public static func listingHash(_ path: String) -> String { LinuxSealList.listingHash(path) }

    /// Each top-level entry of the folder at `path`, by name, hashed as the seal hashes a listing (its subtree for a
    /// folder). Empty when it can't be read.
    public static func entries(listing path: String) -> [String: String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.map { ($0, LinuxSealList.listingHash((path as NSString).appendingPathComponent($0))) })
    }

    /// The folder at `path` (a `.folder` the seal names `name`) hashed as the seal hashes it, with its file `file` (relative) read once: the
    /// hash with that file as read (`now`), and with its bytes as `swap` makes them (`swapped`); nil when `file` isn't a
    /// regular file of at most `limit` bytes there, or `swap` gives nil.
    public static func folderHashes(folder path: String, name: String, file: String, limit: Int = 1 << 20,
                                    swap: (Data) -> Data?) -> (now: String, swapped: String, bytes: Data)? {
        let watched = ConfigSeal.Watched(name: name, path: path, kind: .folder)
        guard let bytes = ConfigSeal.regularContents((watched.path as NSString).appendingPathComponent(file), limit: limit, followLink: false),
              let swapped = swap(bytes) else { return nil }
        var lines: [ConfigSeal.FolderLine] = []
        var count = 0
        ConfigSeal.walk(watched.path, relative: "", name: watched.name, count: &count) { lines.append($0) }
        var found = false
        func hash(_ data: Data) -> String {
            var hasher = SHA256()
            for line in lines where !line.bookkeeping {
                var text = line.text
                if line.path == file, text.hasPrefix("f ") {
                    // "f <path> <mode> <digest>": the digest of the bytes read here.
                    let parts = text.split(separator: " ")
                    text = parts.dropLast().joined(separator: " ") + " " + ConfigSeal.hex(SHA256.hash(data: data))
                    found = true
                }
                hasher.update(data: Data((text + "\n").utf8))
            }
            return ConfigSeal.hex(hasher.finalize())
        }
        let now = hash(bytes)
        guard found else { return nil }
        return (now, hash(swapped), bytes)
    }
}
