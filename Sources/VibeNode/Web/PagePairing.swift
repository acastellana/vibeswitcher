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

/// A terminal's bytes on their way to a page, masked (`PairingMask`), each code byte turned into `*` one for one (what
/// the screen draws keeps its place):
///
/// - **On what the screen shows** (`shown`): escape sequences and control bytes left out and the matches mapped back, so
///   a code cut by a cursor move (a screen replay redrawing a wrapped line), a colour or a line break is found; and
///   across what went before (`tail`: the last run of code characters already sent), so one cut by a read, or by a
///   quiet flush, is found too.
/// - **On the raw bytes** as well, a backstop: a code inside an escape sequence's own payload (an OSC title, an OSC 8
///   hyperlink's target, a DCS or APC string) or anything the parser reads otherwise than a terminal does.
/// - Both find `pair=` and its percent-encoded `pair%3D` with the code after it, and any live code's text.
///
/// A read's tail waits for the next read when what it shows may be a code's start (it holds `pair=`, ends with the start
/// of `#pair=` or of a live code), and so does an escape sequence it ends inside, up to `openEscapeHeld` bytes (past
/// that it goes, masked on its raw bytes: an unterminated OSC never holds the stream). What is held goes after a short
/// quiet (`TerminalRelay.maskQuiet`, `flush`), the end of a run that may be a live code's start masked then.
public final class TerminalMask: @unchecked Sendable {
    /// Where a terminal's parser is (`shown`): carried across reads, so bytes released inside an escape sequence (past
    /// its cap, or at a quiet) are read on as its payload, as a terminal reads them.
    public enum State: Sendable, Equatable { case ground, escape, intermediate, csi, string }

    private var held: [UInt8] = []
    /// The parser's state at the start of `held`.
    private var state = State.ground
    /// The last run of code characters (and `#`, `=`, `%`) of what the screen was sent, at most `tailKept`.
    private var tail: [UInt8] = []
    /// The last `tailKept` raw bytes sent: the raw backstop matches across a release (a code split inside a payload).
    private var rawTail: [UInt8] = []

    /// The most an escape sequence left open at a read's end holds back.
    public static let openEscapeHeld = 4096
    static let tailKept = 64

    public init() {}

    /// Whether a tail is held back.
    public var holding: Bool { !held.isEmpty }

    /// What may go now, masked; a tail that may be a code's start, or an open escape (up to its cap), held back.
    public func pass(_ bytes: Data) -> Data {
        held.append(contentsOf: bytes)
        let shown = Self.shown(held, from: state)
        var cut = held.count
        if let open = shown.openEscape, held.count - open <= Self.openEscapeHeld { cut = open }
        var start = shown.text.count
        while start > 0, Self.inCode(shown.text[start - 1]) { start -= 1 }
        // The run continues what went before when it starts the bytes held.
        let run = (start == 0 && shown.at.first.map { $0 == 0 } != false ? tail : []) + shown.text[start...]
        if start < shown.text.count, run.count <= Self.tailKept, Self.mayBeCode(String(decoding: run, as: UTF8.self)) {
            cut = min(cut, shown.at[start])
        }
        let out = Array(held[..<cut])
        held = Array(held[cut...])
        // Released whole, an open sequence and all (past its cap): the parser goes on inside it; else from ground (a cut
        // is at an escape's start or inside shown text).
        let from = state
        state = cut == out.count && held.isEmpty ? shown.end : .ground
        return mask(out, from: from, final: shown.openEscape != nil && held.isEmpty)
    }

    /// Everything held, masked (a quiet: the end of a run that may be a live code's start masked too).
    public func flush() -> Data {
        let out = held
        held = []
        let from = state
        state = Self.shown(out, from: from).end
        return mask(out, from: from, final: true)
    }

    private func mask(_ bytes: [UInt8], from: State, final: Bool) -> Data {
        let (masked, tail) = Self.masked(bytes, from: from, after: tail, raw: rawTail, final: final)
        self.tail = tail
        rawTail = Array((rawTail + bytes).suffix(Self.tailKept))
        return Data(masked)
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
                // In a string, ESC \ is its end (ST): the backslash is taken as the escape's final below.
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
                default: break // a C0 control: done; the escape goes on
                }
            case .intermediate:
                if (0x30...0x7E).contains(byte) { state = .ground }
            case .csi:
                if (0x40...0x7E).contains(byte) { state = .ground }
                // 0x20-0x3F: its parameters and intermediates; a C0 control: done, and it goes on.
            case .string:
                if byte == 0x07 { state = .ground }
            }
        }
        // Begun before these bytes (a sequence carried in): open from their start.
        return (text, at, state == .ground ? nil : (start != .ground && begun == 0 && bytes.first != 0x1B ? 0 : begun), state)
    }

    static func mayBeCode(_ run: String) -> Bool {
        guard !run.isEmpty else { return false }
        if run.contains("pair=") || run.range(of: "pair%3d", options: .caseInsensitive) != nil { return true }
        func endsWithStart(of whole: String) -> Bool {
            (1...min(whole.count, run.count)).contains { whole.hasPrefix(run.suffix($0)) }
        }
        return endsWithStart(of: "#pair=") || endsWithStart(of: "%23pair%3D") || PairingMask.codes.contains(where: endsWithStart)
    }

    /// The bytes a code, `#`, `=` or `%` is made of: what a code's run is.
    static func inCode(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
            || byte == 0x3D || byte == 0x23 || byte == 0x25
    }

    /// The code alphabet alone (base64url).
    static func codeByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
    }

    /// The ranges of `text` (Latin-1) a code covers: what follows `pair=` or `pair%3D`, and each live code.
    static func codeRanges(_ text: String) -> [Range<Int>] {
        var hide: [Range<Int>] = []
        let ns = text as NSString
        for match in pairing.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
            if let range = Range(match.range(at: 1)) { hide.append(range) }
        }
        for code in PairingMask.codes {
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

    /// `bytes` masked, `tail` what went before: on what the screen shows (with `tail` before it, only this read's bytes
    /// changed), then on the raw bytes; `final`, the end of a run that may be a live code's start masked too. The new tail.
    static func masked(_ bytes: [UInt8], from state: State = .ground, after tail: [UInt8], raw rawTail: [UInt8] = [],
                       final: Bool) -> (bytes: [UInt8], tail: [UInt8]) {
        guard !bytes.isEmpty else { return (bytes, tail) }
        var out = bytes
        let shown = Self.shown(bytes, from: state)
        // The tail continues this read's text only when nothing shown came between: it is the run its first bytes join.
        let joined = tail + shown.text
        let offset = tail.count
        if let text = String(bytes: joined, encoding: .isoLatin1) {
            for range in codeRanges(text) {
                for index in range where index >= offset && index - offset < shown.at.count { out[shown.at[index - offset]] = 0x2A }
            }
        }
        // A quiet's end: a run that may be a live code's start is masked, whatever comes next.
        if final {
            var start = shown.text.count
            while start > 0, codeByte(shown.text[start - 1]) { start -= 1 }
            let run = String(decoding: shown.text[start...], as: UTF8.self)
            if !run.isEmpty, PairingMask.codes.contains(where: { code in (1...min(code.count, run.count)).contains { code.hasPrefix(run.suffix($0)) } }) {
                for index in start..<shown.text.count { out[shown.at[index]] = 0x2A }
            }
        }
        // The backstop: the raw bytes, escape payloads among them, after the last raw bytes sent (a code split across a
        // release inside a payload), only this read's changed; at a release's end, a raw run that may be a live code's
        // start masked too.
        let rawJoined = rawTail + bytes
        if let raw = String(bytes: rawJoined, encoding: .isoLatin1) {
            for range in codeRanges(raw) {
                for index in range where index >= rawTail.count && index - rawTail.count < out.count { out[index - rawTail.count] = 0x2A }
            }
        }
        if final {
            var start = bytes.count
            while start > 0, codeByte(bytes[start - 1]) { start -= 1 }
            let run = String(decoding: bytes[start...], as: UTF8.self)
            if !run.isEmpty, PairingMask.codes.contains(where: { code in (1...min(code.count, run.count)).contains { code.hasPrefix(run.suffix($0)) } }) {
                for index in start..<bytes.count { out[index] = 0x2A }
            }
        }
        // The new tail: the last run of what the screen was sent, joined to the old one when this read's text continues it.
        var start = joined.count
        while start > 0, inCode(joined[start - 1]) { start -= 1 }
        let next = Array(joined[max(start, joined.count - tailKept)...])
        return (out, next)
    }

    /// `pair=` or its percent-encoded `pair%3D`, then the code's characters (group 1).
    static let pairing = try! NSRegularExpression(pattern: #"pair(?:=|%3[Dd])([A-Za-z0-9_\-]+)"#)
}
