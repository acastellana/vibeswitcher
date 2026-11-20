import Foundation
import VibeCore

/// The web page's tokens at rest (the live plan's LW-D4, the live wire contract's §2): each token's SHA-256, never the
/// token, in `<root>/v2/web-tokens.json` (format 1, 0600, its folder 0700, written by `VibePaths.writePrivate`), so a
/// page reconnects by itself after the server restarts. A token is 32 random bytes in base64url; it lives `life` from
/// its issue; at most `cap` are alive, the oldest dropped.
///
/// The file is read once, when this is made (a server's start), and written through at each change. A file of a newer
/// format is refused: no token in it is taken and nothing is written over it (a newer server's record is left whole).
/// A file that can't be read or parsed is no tokens, and the next issue writes a fresh one.
///
/// **What the file is worth.** Any process of the user's can write it, so a worker can add a hash of its own and gain
/// a token. A token reads what that process reads already and drafts what the user confirms on the command line
/// (LW-D6): that is why a token must never be given a right that changes anything.
///
/// From any thread.
public final class WebTokens: @unchecked Sendable {
    /// Why tokens can't be issued or dropped.
    public struct Refusal: Error, Equatable, CustomStringConvertible, Sendable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// One token's record: its digest and its times.
    struct Entry: Codable, Equatable {
        /// SHA-256 of the token's text, lowercase hex.
        var sha256: String
        var issuedAt: String
        var expiresAt: String
    }

    private struct File: Codable {
        var format: Int
        var tokens: [Entry]?
    }

    public static let format = 1
    public static let fileName = "web-tokens.json"
    /// How long a token is taken after its issue.
    public static let life: TimeInterval = 24 * 3600
    /// The most tokens alive at once: the ninth drops the oldest.
    public static let cap = 8
    /// The bytes of randomness in a token.
    public static let tokenBytes = 32
    /// A token is 43 characters of base64url; anything much longer is no token and isn't hashed.
    static let longestToken = 128

    /// The tailnet's tokens (`TailnetWeb`): another file, so a loopback token is never taken on the tailnet nor the
    /// other way round.
    public static let tailnetFileName = "web-tokens-tailnet.json"
    /// How long a tailnet token is taken: a working day.
    public static let tailnetLife: TimeInterval = 8 * 3600
    /// The most tailnet tokens alive at once.
    public static let tailnetCap = 4

    /// `<root>/v2/web-tokens.json` (the tailnet's: `web-tokens-tailnet.json`).
    public let url: URL
    /// How long a token issued here is taken: `life`, or the tailnet's.
    public let tokenLife: TimeInterval
    /// The most alive at once here.
    public let tokenCap: Int
    private let lock = NSLock()
    /// Every token's record, the oldest first (expired ones included until the next write prunes them).
    private var entries: [(digest: [UInt8], issuedAt: Date, expiresAt: Date)] = []
    /// The file's format when it is newer than this server's: refused.
    private var newerFormat: Int?

    /// The tokens kept under `root` (the node's root: `<root>/v2/web-tokens.json`), read now.
    public convenience init(root: URL) {
        self.init(root: root, fileName: Self.fileName, life: Self.life, cap: Self.cap)
    }

    /// The tokens kept in `<root>/v2/<fileName>`, each `life` long, at most `cap` alive, read now.
    public init(root: URL, fileName: String, life: TimeInterval, cap: Int) {
        url = root.appendingPathComponent("v2", isDirectory: true).appendingPathComponent(fileName)
        tokenLife = life
        tokenCap = max(1, cap)
        load()
    }

    /// The tailnet's tokens under `root`: `web-tokens-tailnet.json`, 8 h, at most 4.
    public static func tailnet(root: URL) -> WebTokens {
        WebTokens(root: root, fileName: tailnetFileName, life: tailnetLife, cap: tailnetCap)
    }

    /// Why nothing can be issued here (nil: it can): a file of a newer format.
    public var refusal: Refusal? {
        lock.withLock { newerFormat.map { Self.newerRefusal($0, url: url) } }
    }

    /// A new token, its digest written to the file before it is returned, and when it runs out. Drops the expired ones
    /// and, past `cap`, the oldest.
    public func issue(now: Date) throws -> (token: String, expiresAt: Date) {
        try lock.withLock {
            if let newer = newerFormat { throw Self.newerRefusal(newer, url: url) }
            let token = Self.randomText(bytes: Self.tokenBytes)
            let expiresAt = now.addingTimeInterval(tokenLife)
            var kept = entries.filter { $0.expiresAt > now }
            kept.append((Self.digest(token), now, expiresAt))
            if kept.count > tokenCap { kept.removeFirst(kept.count - tokenCap) }
            try write(kept)
            entries = kept
            return (token, expiresAt)
        }
    }

    /// When `token` stops being taken, when it is a live token's; nil otherwise. The candidate's digest is compared
    /// with every record's, each in constant time, none skipped.
    public func expiry(of token: String, now: Date) -> Date? {
        guard token.utf8.count <= Self.longestToken else { return nil }
        let candidate = Self.digest(token)
        return lock.withLock {
            guard newerFormat == nil else { return nil }
            var found: Date?
            for entry in entries where Self.same(entry.digest, candidate) && entry.expiresAt > now && found == nil {
                found = entry.expiresAt
            }
            return found
        }
    }

    /// Whether `token` is a live token's.
    public func check(_ token: String, now: Date) -> Bool { expiry(of: token, now: now) != nil }

    /// Every token dropped, the file written empty. Returns how many were alive.
    @discardableResult
    public func revokeAll(now: Date = Date()) throws -> Int {
        try lock.withLock {
            if let newer = newerFormat { throw Self.newerRefusal(newer, url: url) }
            let alive = entries.filter { $0.expiresAt > now }.count
            try write([])
            entries = []
            return alive
        }
    }

    /// `token` dropped, when it is one's (a token issued as a revoke ran, `WebAccess.admit`): the file written without
    /// it. Nothing happens for a token that isn't held.
    public func drop(_ token: String) throws {
        let candidate = Self.digest(token)
        try lock.withLock {
            guard newerFormat == nil, entries.contains(where: { Self.same($0.digest, candidate) }) else { return }
            let kept = entries.filter { !Self.same($0.digest, candidate) }
            try write(kept)
            entries = kept
        }
    }

    /// How many tokens are alive at `now`.
    public func live(now: Date) -> Int {
        lock.withLock { newerFormat == nil ? entries.filter { $0.expiresAt > now }.count : 0 }
    }

    // MARK: The file

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        guard file.format <= Self.format else {
            newerFormat = file.format
            return
        }
        guard file.format == Self.format else { return }
        entries = (file.tokens ?? []).compactMap { entry in
            guard let digest = Self.bytes(hex: entry.sha256), digest.count == 32,
                  let issued = NodeWire.date(entry.issuedAt), let expires = NodeWire.date(entry.expiresAt) else { return nil }
            return (digest, issued, expires)
        }
    }

    private func write(_ kept: [(digest: [UInt8], issuedAt: Date, expiresAt: Date)]) throws {
        let file = File(format: Self.format, tokens: kept.map {
            Entry(sha256: Self.hex($0.digest), issuedAt: NodeWire.dateText($0.issuedAt), expiresAt: NodeWire.dateText($0.expiresAt))
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try VibePaths.ensurePrivate(url.deletingLastPathComponent())
            try VibePaths.writePrivate(try encoder.encode(file), to: url, syncing: VibePaths.syncToDisk)
        } catch {
            throw Refusal("\(url.path) couldn't be written: \(error.localizedDescription)")
        }
    }

    private static func newerRefusal(_ format: Int, url: URL) -> Refusal {
        Refusal("\(url.path) is format \(format), newer than this server's \(Self.format): a newer build wrote it, so this one takes no token from it and writes nothing over it")
    }

    // MARK: Bytes

    /// `bytes` fresh random bytes (the system's cryptographic generator) as base64url without padding.
    public static func randomText(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64url(Data(bytes))
    }

    /// `data` as base64url (RFC 4648 §5) without padding.
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// SHA-256 of `text`'s UTF-8.
    static func digest(_ text: String) -> [UInt8] { Array(SHA256.hash(data: Data(text.utf8))) }

    /// Whether two digests are equal, looking at every byte whatever the first difference.
    static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func bytes(hex: String) -> [UInt8]? {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }
}
