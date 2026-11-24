import Foundation

/// What a switch's one code seals beside the switch (2026-11-24, after the user's first switch on the real node took
/// some ten commands; the lead's rule of that day): the builds folder as `vibeswitcher update` found it right after its
/// install, and the node's unit folder with only the unit's `ExecStart` moved to the new build. The checks are the
/// server's (`SwitchSealCheck`, VibeNode); here, what they need of the seal's own reading:
///
/// - `partialKey`: the mark an app's accept carries when it seals only what it shows (`LeadVault`'s judge), the rest
///   held as a look holds it. Without it, an accept that doesn't show everything held seals nothing, as ever.
/// - `listingLines` and `entries(lines:)`: a `.listing` folder's lines as its hash hashes them (names, types, modes,
///   sizes, inodes, times, link targets, never contents), and its top-level entries' groups of them, each hashed.
/// - `folderHashes(folder:name:file:swap:)`: a `.folder`'s hash as the seal reads it, with one file read once: as it is, and with
///   its bytes as `swap` makes them, so a check can say the folder is the accepted one but for that file's change.
public enum SwitchSeal {
    /// The mark (a key no watched thing has) of an accept that seals only what it shows.
    public static let partialKey = ConfigSeal.keyPrefix + "#partial"
    /// The seal's names of the builds folder and the user manager's unit folder (`LinuxSealList.homeEntries`).
    public static var buildsName: String { "~/.vibeswitcher/v2/builds" }
    public static var unitFolderName: String { "~/.config/systemd/user" }
    public static var buildsKey: String { ConfigSeal.keyPrefix + buildsName }
    public static var unitFolderKey: String { ConfigSeal.keyPrefix + unitFolderName }

    /// The whole of a `.listing` folder, hashed as the seal hashes it.
    public static func listingHash(_ path: String) -> String { LinuxSealList.listingHash(path) }

    /// The listing line of the entry `relative` (under the listing's folder) whose stat is `info` (`path`: where it is,
    /// for a link's target): what an open file's `fstat` is compared with.
    public static func listingLine(_ info: stat, path: String, relative: String) -> String {
        LinuxSealList.line(info, path: path, relative: relative)
    }

    /// A listing's lines, as its hash hashes them (empty when nothing is there), and the hash of such lines.
    public static func listingLines(_ path: String) -> [String] { LinuxSealList.listingLines(path) ?? [] }
    public static func listingHash(lines: [String]) -> String { LinuxSealList.listingHash(lines: lines) }

    /// A listing's lines (`listingLines`) grouped by the top-level entry each is of (its relative path's first name,
    /// read by its length prefix), each group's lines hashed; the folder's own line belongs to none. A line that doesn't
    /// read is its own group under its text, so it is never the same as anything.
    public static func entries(lines: [String]) -> [String: String] {
        var groups: [String: [String]] = [:]
        for text in lines.dropFirst() {
            groups[topName(text) ?? ("?" + text), default: []].append(text)
        }
        return groups.mapValues { listingHash(lines: $0) }
    }

    /// The first name of a listing line's relative path ("f 12:name/sub …", "unreadable 4:name").
    static func topName(_ line: String) -> String? {
        let bytes = Array(line.utf8)
        guard let space = bytes.firstIndex(of: UInt8(ascii: " ")) else { return nil }
        var index = space + 1
        var count = 0
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
            count = count * 10 + Int(bytes[index] - UInt8(ascii: "0"))
            index += 1
            guard count <= 1 << 20 else { return nil }
        }
        guard index < bytes.count, bytes[index] == UInt8(ascii: ":"), index + 1 + count <= bytes.count, count > 0 else { return nil }
        let path = String(decoding: bytes[(index + 1)..<(index + 1 + count)], as: UTF8.self)
        return path.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init)
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
