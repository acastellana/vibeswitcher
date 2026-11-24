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
        if masked.contains("pair=") {
            masked = masked.replacingOccurrences(of: #"pair=[A-Za-z0-9_\-]+"#, with: "pair=" + hidden, options: .regularExpression)
        }
        for code in codes where masked.contains(code) { masked = masked.replacingOccurrences(of: code, with: hidden) }
        return masked
    }

}

/// A terminal's bytes on their way to a page, masked (`PairingMask`) though a code may be split across reads: a read's
/// trailing run of the bytes a code is made of waits for the next read only when it may be the start of one (it holds
/// `pair=`, ends with the start of `pair=`, or ends with the start of a live code); anything else goes at once.
public final class TerminalMask: @unchecked Sendable {
    private var held = Data()

    public init() {}

    /// What may go now, masked; a tail that may be a code's start held back.
    public func pass(_ bytes: Data) -> Data {
        held.append(bytes)
        var start = held.count
        while start > 0, Self.inCode(held[held.startIndex + start - 1]) { start -= 1 }
        let run = String(decoding: held.suffix(held.count - start), as: UTF8.self)
        let cut = run.utf8.count <= 64 && Self.mayBeCode(run) ? start : held.count
        let out = held.prefix(cut)
        held = Data(held.dropFirst(cut))
        return Self.masked(Data(out))
    }

    /// Everything held, masked.
    public func flush() -> Data {
        let out = held
        held = Data()
        return Self.masked(out)
    }

    static func mayBeCode(_ run: String) -> Bool {
        guard !run.isEmpty else { return false }
        if run.contains("pair=") { return true }
        func endsWithStart(of whole: String) -> Bool {
            (1...min(whole.count, run.count)).contains { whole.hasPrefix(run.suffix($0)) }
        }
        return endsWithStart(of: "#pair=") || PairingMask.codes.contains(where: endsWithStart)
    }

    static func inCode(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
            || byte == 0x3D || byte == 0x23
    }

    /// Masked byte for byte (Latin-1 reads every byte, so a character split across reads never stops the mask; a code
    /// and `pair=` are ASCII).
    static func masked(_ data: Data) -> Data {
        guard !data.isEmpty, let text = String(data: data, encoding: .isoLatin1) else { return data }
        let masked = PairingMask.mask(text, with: "***")
        return masked == text ? data : (masked.data(using: .isoLatin1) ?? data)
    }
}
