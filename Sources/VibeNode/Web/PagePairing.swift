import Foundation
import VibeCore

/// A page's pairing, confirmed in the terminal (the acting review's fix A): the page that took a pairing code shows a
/// short phrase made from its token (`phrase`), and `vibeswitcher web` shows the phrase of the page that took its code;
/// the user confirms that they match with the typed code (`web.confirm`). Until then, and for any page that merely took
/// the code first, the page reads and drafts. A second attempt with a code already taken is said in the terminal
/// (`contested`): another page may have read the address.
public struct PagePairing: Sendable, Equatable {
    /// The pairing code's id (`codeID`): what `web.open` answers and the terminal waits on.
    public var code: String
    public var token: String
    public var tokenEnds: Date
    public var phrase: String
    public var at: Date
    /// Another attempt came with the same code after it was taken.
    public var contested: Bool

    /// A code's id as the terminal names it: the first 16 hex digits of its SHA-256 (never the code).
    public static func codeID(digest: [UInt8]) -> String { String(WebTokens.hex(digest).prefix(16)) }

    /// Three short words from `token`'s SHA-256: what the page and the terminal both show.
    public static func phrase(token: String) -> String {
        let digest = WebTokens.digest(token)
        return digest.prefix(3).map { words[Int($0)] }.joined(separator: " ")
    }

    /// How long a taken code's pairing waits for the terminal's confirmation.
    public static let waits: TimeInterval = 10 * 60

    /// 256 short, plain words, none like another (`PagePairingTests` holds the count).
    static let words: [String] = [
        "acorn", "amber", "anchor", "apple", "arrow", "aspen", "atlas", "badge", "baker", "bamboo", "banjo", "barley",
        "basil", "beacon", "berry", "birch", "bison", "blade", "bloom", "board", "bonsai", "boulder", "brass", "bread",
        "brick", "bridge", "brook", "bucket", "buffalo", "butter", "cabin", "cactus", "camel", "candle", "canoe", "canyon",
        "carbon", "cargo", "carrot", "castle", "cedar", "cello", "chalk", "cherry", "chess", "cider", "cinder", "circle",
        "citrus", "clay", "cliff", "clock", "cloud", "clover", "cobalt", "cocoa", "comet", "copper", "coral", "cotton",
        "cradle", "crane", "crater", "cricket", "crystal", "cube", "daisy", "delta", "denim", "desert", "diamond", "dingo",
        "dolphin", "dragon", "drum", "dune", "eagle", "ebony", "echo", "elbow", "elder", "ember", "emerald", "engine",
        "falcon", "feather", "fern", "fiddle", "fig", "flame", "flint", "forest", "fossil", "fountain", "fox", "frost",
        "galaxy", "garden", "garnet", "gecko", "geyser", "ginger", "glacier", "globe", "granite", "grape", "gravel", "harbor",
        "harp", "hazel", "heron", "hickory", "honey", "horizon", "husky", "iceberg", "indigo", "iris", "island", "ivory",
        "jade", "jasmine", "jelly", "jungle", "juniper", "kayak", "kelp", "kettle", "kiwi", "koala", "ladder", "lagoon",
        "lantern", "lava", "lemon", "lily", "linen", "lizard", "llama", "lobster", "lotus", "magnet", "mango", "maple",
        "marble", "meadow", "melon", "meteor", "mint", "mirror", "moss", "mountain", "mule", "nectar", "nickel", "nutmeg",
        "oak", "oasis", "ocean", "olive", "onyx", "orbit", "orchid", "otter", "owl", "paddle", "palm", "panda", "paper",
        "pebble", "pecan", "pepper", "piano", "pine", "planet", "plum", "pocket", "pollen", "pony", "poppy", "prairie",
        "prism", "pumpkin", "quartz", "quill", "rabbit", "radar", "raven", "reef", "ribbon", "river", "robin", "rocket",
        "rose", "ruby", "saddle", "saffron", "salmon", "sand", "sapphire", "saturn", "scarf", "shell", "silver", "sky",
        "slate", "snow", "spark", "sparrow", "spruce", "squash", "star", "stone", "storm", "sugar", "summit", "sun",
        "swan", "syrup", "tango", "teapot", "thistle", "thunder", "tiger", "timber", "toast", "topaz", "torch", "tulip",
        "tundra", "turtle", "umber", "valley", "velvet", "violet", "volcano", "walnut", "walrus", "wave", "wheat", "willow",
        "window", "winter", "wolf", "yarrow", "zebra", "zephyr", "zinc", "acre", "bell", "cove", "dawn", "frog", "gull", "hill", "kite",
    ]
}

/// The pairing codes a page's terminal and transcripts must never show (the acting review's fix C): any `#pair=<code>`
/// in what the node serves a page from a terminal or a transcript is masked, and so is any live code's text wherever it
/// appears. From any thread.
public enum PairingMask {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var live: [String: Date] = [:]

    /// A code made now, alive until `until`.
    public static func made(_ code: String, until: Date) {
        lock.withLock {
            let now = Date()
            live = live.filter { $0.value > now }
            live[code] = until
        }
    }

    /// The codes alive now.
    static var codes: [String] { lock.withLock { let now = Date(); return live.filter { $0.value > now }.map(\.key) } }

    /// `text` with every pairing address's code and every live code replaced by `with`.
    public static func mask(_ text: String, with hidden: String = "…") -> String {
        var masked = text
        if masked.contains("pair=") || masked.range(of: "pair%3d", options: .caseInsensitive) != nil {
            masked = masked.replacingOccurrences(of: #"pair=[A-Za-z0-9_\-]+"#, with: "pair=" + hidden, options: .regularExpression)
            masked = masked.replacingOccurrences(of: #"pair%3[Dd][A-Za-z0-9_\-]+"#, with: "pair%3D" + hidden, options: .regularExpression)
        }
        for code in codes where masked.contains(code) { masked = masked.replacingOccurrences(of: code, with: hidden) }
        return masked
    }

}

/// A terminal's bytes on their way to a page, masked (`PairingMask`): matched on what the screen shows, so a code is
/// found though escape sequences (a cursor move, a colour, a screen replay's redraw of a wrapped line) or line breaks cut
/// it, and its characters alone become `*`, one for one (what the screen draws keeps its place); `pair=` and its
/// percent-encoded form `pair%3D` too. A code split across reads is held: the read's tail waits for the next when what
/// it shows may be the start of one (it holds `pair=`, ends with the start of `#pair=`, or with the start of a live
/// code), and so does an escape sequence the read ends inside; anything else goes at once. What is held goes after a
/// short quiet (`TerminalRelay.maskQuiet`), so a prompt never waits.
public final class TerminalMask: @unchecked Sendable {
    private var held: [UInt8] = []

    public init() {}

    /// What may go now, masked; a tail that may be a code's start held back.
    public func pass(_ bytes: Data) -> Data {
        held.append(contentsOf: bytes)
        let shown = Self.shown(held)
        var cut = held.count
        if let open = shown.openEscape { cut = open }
        // The trailing run of what the screen shows that a code is made of.
        var start = shown.text.count
        while start > 0, Self.inCode(shown.text[start - 1]) { start -= 1 }
        let run = String(decoding: shown.text[start...], as: UTF8.self)
        if start < shown.text.count, run.utf8.count <= 64, Self.mayBeCode(run) { cut = min(cut, shown.at[start]) }
        let out = Array(held[..<cut])
        held = Array(held[cut...])
        return Self.masked(out)
    }

    /// Whether a tail is held back.
    public var holding: Bool { !held.isEmpty }

    /// Everything held, masked.
    public func flush() -> Data {
        let out = held
        held = []
        return Self.masked(out)
    }

    /// What the screen shows of `bytes`: each printed byte and where it is; escape sequences (CSI, OSC, DCS and the like,
    /// and two-byte ones) and control bytes (line breaks among them) left out; `openEscape`: where an escape sequence
    /// the bytes end inside begins.
    static func shown(_ bytes: [UInt8]) -> (text: [UInt8], at: [Int], openEscape: Int?) {
        var text: [UInt8] = [], at: [Int] = []
        text.reserveCapacity(bytes.count)
        at.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                let begun = index
                guard index + 1 < bytes.count else { return (text, at, begun) }
                let kind = bytes[index + 1]
                index += 2
                switch kind {
                case 0x5B: // CSI: parameters and intermediates, then a final byte 0x40-0x7E
                    while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) { index += 1 }
                    guard index < bytes.count else { return (text, at, begun) }
                    index += 1
                case 0x5D, 0x50, 0x58, 0x5E, 0x5F: // OSC, DCS, SOS, PM, APC: to BEL or ST (ESC \)
                    var ended = false
                    while index < bytes.count {
                        if bytes[index] == 0x07 { index += 1; ended = true; break }
                        if bytes[index] == 0x1B, index + 1 < bytes.count, bytes[index + 1] == 0x5C { index += 2; ended = true; break }
                        index += 1
                    }
                    guard ended else { return (text, at, begun) }
                default:
                    // A two-byte sequence, or one with intermediates (ESC ( B): its intermediates, then its final byte.
                    if (0x20...0x2F).contains(kind) {
                        while index < bytes.count, (0x20...0x2F).contains(bytes[index]) { index += 1 }
                        guard index < bytes.count else { return (text, at, begun) }
                        index += 1
                    }
                }
                continue
            }
            if byte >= 0x20, byte != 0x7F {
                text.append(byte)
                at.append(index)
            }
            index += 1
        }
        return (text, at, nil)
    }

    static func mayBeCode(_ run: String) -> Bool {
        guard !run.isEmpty else { return false }
        if run.contains("pair=") || run.contains("pair%3D") { return true }
        func endsWithStart(of whole: String) -> Bool {
            (1...min(whole.count, run.count)).contains { whole.hasPrefix(run.suffix($0)) }
        }
        return endsWithStart(of: "#pair=") || endsWithStart(of: "%23pair%3D") || PairingMask.codes.contains(where: endsWithStart)
    }

    static func inCode(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
            || byte == 0x3D || byte == 0x23 || byte == 0x25
    }

    /// `bytes` with each code character the screen shows (a live code's, or what follows `pair=` / `pair%3D`) turned
    /// into `*`, escape sequences and line breaks between them left as they were.
    static func masked(_ bytes: [UInt8]) -> Data {
        guard !bytes.isEmpty else { return Data() }
        let shown = Self.shown(bytes)
        guard let text = String(bytes: shown.text, encoding: .isoLatin1) else { return Data(bytes) }
        var hide: [Range<Int>] = []
        let whole = NSRange(location: 0, length: (text as NSString).length)
        for match in Self.pairing.matches(in: text, range: whole) where match.numberOfRanges > 1 {
            if let range = Range(match.range(at: 1)) { hide.append(range) }
        }
        let nsText = text as NSString
        for code in PairingMask.codes {
            var from = 0
            while from < nsText.length {
                let found = nsText.range(of: code, range: NSRange(location: from, length: nsText.length - from))
                guard found.location != NSNotFound, let range = Range(found) else { break }
                hide.append(range)
                from = found.location + found.length
            }
        }
        guard !hide.isEmpty else { return Data(bytes) }
        var out = bytes
        for range in hide { for index in range where index < shown.at.count { out[shown.at[index]] = 0x2A } }
        return Data(out)
    }

    /// `pair=` or its percent-encoded `pair%3D`, then the code's characters (group 1).
    static let pairing = try! NSRegularExpression(pattern: #"pair(?:=|%3[Dd])([A-Za-z0-9_\-]+)"#)
}
