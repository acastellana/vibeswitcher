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

/// The pairing codes this node's gates made and that are still live (`WebAccess.openCode`, the loopback's and the
/// tailnet's; dropped the moment one is taken, revoked, or runs out): what a page's terminal and transcripts must never
/// show (the acting review's fix C). One per server instance, never a static: another server's (another test's) codes
/// are none of this one's. From any thread.
public final class PairingCodes: @unchecked Sendable {
    private let lock = NSLock()
    private var live: [String: (until: Date, by: ObjectIdentifier?)] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    /// A code made by `by` (a gate), live until `until`.
    public func made(_ code: String, until: Date, by: AnyObject? = nil) {
        lock.withLock { live[code] = (until, by.map(ObjectIdentifier.init)) }
    }

    /// A code taken: live no more.
    public func taken(_ code: String) { lock.withLock { _ = live.removeValue(forKey: code) } }
    /// Every code `by` made (its revoke): live no more; another gate's stay.
    public func clear(by: AnyObject) { lock.withLock { live = live.filter { $0.value.by != ObjectIdentifier(by) } } }

    /// The codes live now.
    public var codes: [String] {
        let at = now()
        return lock.withLock {
            live = live.filter { $0.value.until > at }
            return Array(live.keys)
        }
    }
}

/// Pairing codes in text (a transcript's, served to a page): what follows `pair=` or its percent-encoded `pair%3D`, at
/// most a code's length, and each of `codes` (the node's live ones, `PairingCodes`) wherever it appears, replaced.
/// Nothing else is changed.
public enum PairingMask {
    /// The longest a pairing code is (16 bytes in base64url).
    public static let codeLength = 22

    public static func mask(_ text: String, codes: [String] = [], with hidden: String = "…") -> String {
        var masked = text
        if masked.contains("pair=") || masked.range(of: "pair%3d", options: .caseInsensitive) != nil {
            masked = masked.replacingOccurrences(of: #"pair(=|%3[Dd])[A-Za-z0-9_\-]{1,22}"#, with: "pair$1" + hidden, options: .regularExpression)
        }
        for code in codes where !code.isEmpty && masked.contains(code) { masked = masked.replacingOccurrences(of: code, with: hidden) }
        return masked
    }
}

/// A terminal's bytes on their way to a page, masked. It changes no byte but a code's own: (a) the code characters
/// after a literal `pair=` or `pair%3D`, at most a code's length; (b) an exact match of a code live on this server
/// (`PairingCodes`). Each such byte becomes `*`, one for one, so what the screen draws keeps its place. With no live code
/// and no `pair=` in sight it is the identity, whatever the reads' cuts and the quiet flushes.
///
/// - **On what the screen shows** (`shown`): escape sequences and control bytes left out and the matches mapped back,
///   so a code cut by a cursor move, a colour or a line break is found; and across what went before (`tail`: the last
///   run of code characters sent, `rawTail`: the last raw bytes), so one cut by a read or a release is found too.
/// - **On the raw bytes** as well, a backstop: a code inside an escape sequence's own payload (a title, a hyperlink's
///   target, a DCS or APC string).
/// - **What waits.** A read's tail is held, never masked, while it may be a code's start: it holds `pair=` (or
///   `pair%3D`) with the code's characters still coming, or ends with at least `heldPrefix` characters that start a live
///   code; and an escape sequence it ends inside, up to `openEscapeHeld` bytes. A quiet flush releases what is held as
///   it is, except a run that may start a live code (`heldPrefix` or more of it), which waits for what follows or the
///   code's end. A held run that doesn't go on as the code goes out unchanged.
public final class TerminalMask: @unchecked Sendable {
    /// Where a terminal's parser is (`shown`): carried across reads.
    public enum State: Sendable, Equatable { case ground, escape, intermediate, csi, string }

    private let live: PairingCodes?
    private var held: [UInt8] = []
    private var state = State.ground
    private var tail: [UInt8] = []
    private var rawTail: [UInt8] = []

    /// The most an escape sequence left open at a read's end holds back.
    public static let openEscapeHeld = 4096
    /// How many of a live code's first characters a run must end with to be held for it.
    public static let heldPrefix = 4
    static let tailKept = 64

    /// `live`: this server's codes (none: `pair=` alone is masked).
    public init(codes live: PairingCodes? = nil) { self.live = live }

    /// Whether a tail is held back.
    public var holding: Bool { !held.isEmpty }
    /// How many bytes are held back (each read re-reads these: tests hold them bounded).
    var heldCount: Int { held.count }

    /// What may go now, masked; a tail that may be a code's start, or an open escape (up to its cap), held back.
    public func pass(_ bytes: Data) -> Data {
        held.append(contentsOf: bytes)
        return release(quiet: false)
    }

    /// A quiet: everything held goes, but a run that may start a live code (it waits on, for what follows or the code's
    /// end: `holding` says so, and the relay asks again after another quiet).
    public func flush() -> Data { release(quiet: true) }

    /// The stream's end (and tests): everything held goes, masked as it is.
    public func drain() -> Data {
        let out = held
        held = []
        let from = state
        state = Self.shown(out, from: from).end
        let (masked, nextTail) = Self.masked(out, from: from, after: tail, raw: rawTail, codes: live?.codes ?? [], forced: true)
        tail = nextTail
        rawTail = Array((rawTail + out).suffix(Self.tailKept))
        return Data(masked)
    }

    private func release(quiet: Bool) -> Data {
        let codes = live?.codes ?? []
        let shown = Self.shown(held, from: state)
        var cut = held.count
        if !quiet, let open = shown.openEscape, held.count - open <= Self.openEscapeHeld { cut = open }
        var start = shown.text.count
        while start > 0, Self.inCode(shown.text[start - 1]) { start -= 1 }
        if start < shown.text.count {
            let joined = (start == 0 && shown.at.first == 0 ? tail : []) + shown.text[start...]
            let run = String(decoding: joined, as: UTF8.self)
            if run.utf8.count <= Self.tailKept, Self.mayBeCode(run, codes: codes, quiet: quiet) { cut = min(cut, shown.at[start]) }
        }
        let out = Array(held[..<cut])
        held = Array(held[cut...])
        let from = state
        state = held.isEmpty ? shown.end : (cut == 0 ? state : Self.shown(out, from: from).end)
        // Released inside an escape sequence's payload (past its cap, or at a quiet): a run there that ends with a live
        // code's start can't wait, so that start is masked (rule b: an exact proper prefix at the end).
        let forced = held.isEmpty && shown.openEscape != nil
        let (masked, nextTail) = Self.masked(out, from: from, after: tail, raw: rawTail, codes: codes, forced: forced)
        tail = nextTail
        rawTail = Array((rawTail + out).suffix(Self.tailKept))
        return Data(masked)
    }

    /// Whether a run (code characters, `#`, `=`, `%`) at the end of what is held may be the start of a code still to
    /// come: `pair=` / `pair%3D` with fewer than a code's characters after it (not at a quiet: they go, masked), the start
    /// of `#pair=` (not at a quiet), or `heldPrefix` or more of a live code's first characters (at a quiet too).
    static func mayBeCode(_ run: String, codes: [String], quiet: Bool) -> Bool {
        guard !run.isEmpty else { return false }
        if !quiet {
            for marker in ["pair=", "pair%3D", "pair%3d"] {
                if let range = run.range(of: marker, options: .backwards), run[range.upperBound...].count < PairingMask.codeLength { return true }
            }
            if run.count >= 3, (3...min(6, run.count)).contains(where: { "#pair=".hasPrefix(run.suffix($0)) }) { return true }
        }
        guard run.count >= heldPrefix else { return false }
        return codes.contains { code in
            code.count > heldPrefix && (heldPrefix...min(code.count - 1, run.count)).contains { code.hasPrefix(run.suffix($0)) }
        }
    }

    /// What the screen shows of `bytes`, as a terminal parses them (ECMA-48, the DEC/xterm parser): each printed byte and
    /// where it is; escape sequences and control bytes left out. A CSI takes parameter (0x30-0x3F) and intermediate
    /// (0x20-0x2F) bytes to its final (0x40-0x7E); a C0 control inside it is done and it goes on; CAN or SUB ends it, ESC
    /// ends it and begins another. An OSC, DCS, SOS, PM or APC string runs to BEL or ST (ESC \); CAN or SUB ends it, any
    /// other ESC ends it and begins another. `openEscape`: where a sequence the bytes end inside begins.
    static func shown(_ bytes: [UInt8], from start: State = .ground) -> (text: [UInt8], at: [Int], openEscape: Int?, end: State) {
        var state = start
        var text: [UInt8] = [], at: [Int] = []
        text.reserveCapacity(bytes.count)
        at.reserveCapacity(bytes.count)
        var begun = 0
        for (index, byte) in bytes.enumerated() {
            if byte == 0x18 || byte == 0x1A { state = .ground; continue }
            if byte == 0x1B {
                state = .escape
                begun = index
                continue
            }
            switch state {
            case .ground:
                if byte >= 0x20, byte != 0x7F {
                    text.append(byte)
                    at.append(index)
                }
            case .escape:
                switch byte {
                case 0x5B: state = .csi
                case 0x5D, 0x50, 0x58, 0x5E, 0x5F: state = .string
                case 0x20...0x2F: state = .intermediate
                case 0x30...0x7E: state = .ground
                default: break
                }
            case .intermediate:
                if (0x30...0x7E).contains(byte) { state = .ground }
            case .csi:
                if (0x40...0x7E).contains(byte) { state = .ground }
            case .string:
                if byte == 0x07 { state = .ground }
            }
        }
        return (text, at, state == .ground ? nil : (start != .ground && begun == 0 && bytes.first != 0x1B ? 0 : begun), state)
    }

    /// The bytes a code, `#`, `=` or `%` is made of: what a code's run is.
    static func inCode(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
            || byte == 0x3D || byte == 0x23 || byte == 0x25
    }

    /// The ranges of `text` (Latin-1) a code covers: the code characters after `pair=` / `pair%3D` (a code's length at
    /// most), and each exact live code.
    static func codeRanges(_ text: String, codes: [String]) -> [Range<Int>] {
        var hide: [Range<Int>] = []
        let ns = text as NSString
        for match in pairing.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
            if let range = Range(match.range(at: 1)) { hide.append(range) }
        }
        for code in codes {
            var from = 0
            while from < ns.length {
                let found = ns.range(of: code, range: NSRange(location: from, length: ns.length - from))
                guard found.location != NSNotFound, let range = Range(found) else { break }
                hide.append(range)
                from = found.location + found.length
            }
        }
        return hide
    }

    /// `bytes` masked, `tail` and `rawTail` what went before (only this read's bytes changed): on what the screen shows,
    /// then on the raw bytes. The new tail.
    static func masked(_ bytes: [UInt8], from state: State = .ground, after tail: [UInt8], raw rawTail: [UInt8] = [], codes: [String],
                       forced: Bool = false) -> (bytes: [UInt8], tail: [UInt8]) {
        guard !bytes.isEmpty else { return (bytes, tail) }
        var out = bytes
        let shown = Self.shown(bytes, from: state)
        let joined = tail + shown.text
        let offset = tail.count
        if let text = String(bytes: joined, encoding: .isoLatin1) {
            for range in codeRanges(text, codes: codes) {
                for index in range where index >= offset && index - offset < shown.at.count { out[shown.at[index - offset]] = 0x2A }
            }
        }
        let rawJoined = rawTail + bytes
        if let raw = String(bytes: rawJoined, encoding: .isoLatin1) {
            for range in codeRanges(raw, codes: codes) {
                for index in range where index >= rawTail.count && index - rawTail.count < out.count { out[index - rawTail.count] = 0x2A }
            }
        }
        if forced, let raw = String(bytes: rawJoined, encoding: .isoLatin1) {
            // The longest end of the raw bytes, `heldPrefix` or more, that a live code starts with: its bytes in this read.
            let longest = codes.compactMap { code -> Int? in
                (heldPrefix..<code.count).reversed().first { raw.count >= $0 && code.hasPrefix(raw.suffix($0)) }
            }.max()
            if let longest { for index in max(rawJoined.count - longest, rawTail.count)..<rawJoined.count { out[index - rawTail.count] = 0x2A } }
        }
        var start = joined.count
        while start > 0, inCode(joined[start - 1]) { start -= 1 }
        return (out, Array(joined[max(start, joined.count - tailKept)...]))
    }

    /// `pair=` or its percent-encoded `pair%3D`, then the code's characters (group 1), a code's length at most.
    static let pairing = try! NSRegularExpression(pattern: #"pair(?:=|%3[Dd])([A-Za-z0-9_\-]{1,22})"#)
}
