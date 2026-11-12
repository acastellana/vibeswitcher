import Foundation

/// How a Run-card shell's command ended, as the session host saw it in the terminal's output: its exit status and the
/// last lines it printed. The launch line (`ShellAsk.spawnRequest`) reports the command's start (`ShellTidy.start`)
/// and its end with its status (`ShellTidy.report`), each over OSC 7501; the host (`CommandCapture`, fed every byte
/// the session prints) keeps what came between, and only that: nothing the shell printed before the command, nor
/// anything after its end (what the user then types into the shell that stays open). The app sends it to the session
/// that filed the request (`ShellAsk.ending`), capped and redacted there.
public struct CommandEnd: Codable, Equatable, Sendable {
    /// The command exited 0.
    public var ok: Bool
    /// Its exit status; nil when the end report didn't carry a readable one.
    public var status: Int?
    /// When the command started (the start report); nil when the host didn't see it.
    public var startedAt: Date?
    public var at: Date
    /// The last lines it printed, as plain text (escape sequences gone, `\r` overwrites applied), at most `maxLines`
    /// lines and `maxBytes` bytes; nil when the host couldn't capture them (it didn't see the command start).
    public var tail: String?
    /// Earlier lines than `tail`'s were left out.
    public var cut: Bool

    public static let maxLines = 40
    public static let maxBytes = 4096

    public init(ok: Bool, status: Int?, startedAt: Date?, at: Date, tail: String?, cut: Bool) {
        self.ok = ok
        self.status = status
        self.startedAt = startedAt
        self.at = at
        self.tail = tail
        self.cut = cut
    }
}

/// Watches a Run-card shell's output for its command's start and end reports (`ShellTidy.start`, `ShellTidy.report`)
/// and keeps the last `keep` bytes printed between them. One command per session: once it ended (`feed` gave its
/// `CommandEnd`), nothing more is looked at. Bytes go in as the terminal got them, in chunks split anywhere.
public final class CommandCapture {
    enum Phase { case waiting, running, ended }

    /// Raw output kept while the command runs: enough for `CommandEnd.maxLines` lines with their escape sequences.
    public static let keep = 64 * 1024

    private(set) var phase = Phase.waiting
    /// Waiting: the last bytes seen (a start report split across chunks). Running: the command's output so far, its
    /// last `keep` bytes, with whatever of an end report has come.
    private var bytes: [UInt8] = []
    /// Bytes were dropped off the front of `bytes` while running.
    private var trimmed = false
    /// Where in `bytes` to look for the next report (what's before has been looked at).
    private var from = 0
    private var startedAt: Date?

    public init() {}

    static let osc: [UInt8] = Array("\u{1b}]7501;".utf8)
    /// The longest report this looks at; a longer OSC 7501 payload isn't one of these.
    static let longest = 160

    /// Feeds what the terminal printed next; the command's end, once its report has come (once only).
    public func feed(_ data: Data, at now: Date) -> CommandEnd? {
        guard phase != .ended, !data.isEmpty else { return nil }
        bytes.append(contentsOf: data)
        while phase != .ended {
            guard let found = Self.report(in: bytes, from: from) else { break }
            switch found {
            case .incomplete(let at):
                from = at
                trim()
                return nil
            case .other(let after):
                from = after
            case .start(let after):
                if phase == .waiting {
                    phase = .running
                    startedAt = now
                    bytes.removeFirst(after)
                    from = 0
                    trimmed = false
                } else {
                    // A second start inside the command is the command's own output.
                    from = after
                }
            case .end(let begin, let ok, let status):
                // Ended with no start seen (a host that took the session over without it in its replay, a shell
                // from before starts were reported): its output isn't known, and isn't guessed.
                let tail = phase == .running ? Self.plainTail(Array(bytes[..<begin]), dropFirstLine: trimmed) : nil
                phase = .ended
                bytes = []
                return CommandEnd(ok: ok, status: status, startedAt: startedAt, at: now, tail: tail?.text, cut: tail?.cut ?? false)
            }
        }
        from = max(from, bytes.count - Self.osc.count + 1, 0)
        trim()
        return nil
    }

    /// Keeps `bytes` bounded: waiting, only what a report split across chunks needs; running, the last `keep`.
    private func trim() {
        let limit = phase == .waiting ? Self.longest : Self.keep
        guard bytes.count > limit else { return }
        // Never drop a report that's still coming in.
        let drop = min(bytes.count - limit, from)
        guard drop > 0 else { return }
        bytes.removeFirst(drop)
        from -= drop
        if phase == .running { trimmed = true }
    }

    enum Found: Equatable {
        /// An OSC 7501 report begins at this index and hasn't ended yet.
        case incomplete(at: Int)
        /// Some other OSC 7501 report, ending before this index.
        case other(after: Int)
        /// The command's start report, ending before `after`.
        case start(after: Int)
        /// Its end report, beginning at `begin`.
        case end(begin: Int, ok: Bool, status: Int?)
    }

    /// The first OSC 7501 report in `bytes` at or after `from`.
    static func report(in bytes: [UInt8], from: Int) -> Found? {
        guard let begin = find(osc, in: bytes, from: from) else { return nil }
        let payloadStart = begin + osc.count
        var index = payloadStart
        while index < bytes.count, index - begin <= longest {
            let byte = bytes[index]
            if byte == 0x07 || (byte == 0x1b && index + 1 < bytes.count && bytes[index + 1] == 0x5c) {
                let after = index + (byte == 0x07 ? 1 : 2)
                let payload = String(decoding: bytes[payloadStart..<index], as: UTF8.self)
                return classify(payload, begin: begin, after: after)
            }
            if byte == 0x1b, index + 1 == bytes.count { return .incomplete(at: begin) }
            if byte < 0x20 { return .other(after: index) }
            index += 1
        }
        return index - begin > longest ? .other(after: payloadStart) : .incomplete(at: begin)
    }

    /// A start report is `ShellTidy.start`'s payload; an end, a `done` or `error` of app `vs-shell` with no id.
    static func classify(_ payload: String, begin: Int, after: Int) -> Found {
        var pairs: [String: String] = [:]
        for pair in payload.split(separator: ":") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            pairs[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        guard pairs["app"] == ShellTidy.app else { return .other(after: after) }
        if pairs["id"] == ShellTidy.startID, pairs["state"] == "working" { return .start(after: after) }
        guard pairs["id"] == nil, let state = pairs["state"], state == "done" || state == "error" else { return .other(after: after) }
        // `exit=` with what the shell gave: digits only, 0–255, else not known. An end report from before statuses
        // were reported has none: done is 0 then, error not known.
        let digits = pairs["exit"].flatMap { $0.count <= 3 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int($0) : nil }
        let status = digits.flatMap { (0...255).contains($0) ? $0 : nil } ?? (state == "done" && pairs["exit"] == nil ? 0 : nil)
        let ok = state == "done"
        // A report whose status contradicts its state isn't believed about the status.
        return .end(begin: begin, ok: ok, status: status.flatMap { ($0 == 0) == ok ? $0 : nil })
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var index = max(0, from)
        while index <= haystack.count - needle.count {
            if haystack[index] == needle[0], haystack[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }

    /// `bytes` as a terminal would leave its lines, roughly: escape sequences dropped, `\r` returns to the line's
    /// start and what follows overwrites it, backspace steps back, erase-in-line erases; then the last
    /// `CommandEnd.maxLines` lines, at most `CommandEnd.maxBytes` bytes, trailing blank lines and blanks gone.
    /// `dropFirstLine`: the bytes start mid-output, so their first line is partial. `cut`: lines were left out.
    public static func plainTail(_ bytes: [UInt8], dropFirstLine: Bool = false, maxLines: Int = CommandEnd.maxLines,
                                 maxBytes: Int = CommandEnd.maxBytes) -> (text: String, cut: Bool) {
        enum State { case normal, escape, csi, string, stringEscape, skipOne }
        var lines: [String] = []
        var line: [Character] = []
        var cursor = 0
        var state = State.normal
        var parameters = ""
        func put(_ character: Character) {
            if cursor < line.count { line[cursor] = character } else { line.append(character) }
            cursor += 1
        }
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            switch state {
            case .normal:
                switch scalar.value {
                case 0x0a:
                    lines.append(String(line))
                    line = []
                    cursor = 0
                case 0x0d: cursor = 0
                case 0x08: cursor = max(0, cursor - 1)
                case 0x09: put("\t")
                case 0x1b: state = .escape
                case 0x9b: state = .csi; parameters = ""
                case 0x9d, 0x90, 0x9e, 0x9f: state = .string
                case 0..<0x20, 0x7f, 0x80..<0xa0: break
                default: put(Character(scalar))
                }
            case .escape:
                switch scalar {
                case "[": state = .csi; parameters = ""
                case "]", "P", "^", "_", "X": state = .string
                case "(", ")", "*", "+", "#", "%", "-", ".", "/": state = .skipOne
                default: state = .normal
                }
            case .skipOne:
                state = .normal
            case .csi:
                if (0x40...0x7e).contains(scalar.value) {
                    state = .normal
                    if scalar == "K" {
                        switch parameters {
                        case "", "0": if cursor < line.count { line.removeSubrange(cursor...) }
                        case "1": for index in 0..<min(cursor, line.count) { line[index] = " " }
                        case "2": line = []
                        default: break
                        }
                    }
                } else {
                    parameters.unicodeScalars.append(scalar)
                    if parameters.count > 32 { state = .normal }
                }
            case .string:
                if scalar.value == 0x07 || scalar.value == 0x9c { state = .normal } else if scalar.value == 0x1b { state = .stringEscape }
            case .stringEscape:
                state = scalar == "\\" ? .normal : .string
            }
        }
        if !line.isEmpty { lines.append(String(line)) }
        var cut = false
        if dropFirstLine, !lines.isEmpty {
            lines.removeFirst()
            cut = true
        }
        lines = lines.map { String($0.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
            cut = true
        }
        var text = lines.joined(separator: "\n")
        while text.utf8.count > maxBytes {
            cut = true
            if lines.count > 1 {
                lines.removeFirst()
                text = lines.joined(separator: "\n")
            } else {
                // One line longer than the cap: its end.
                var end = Substring(text)
                while end.utf8.count > maxBytes - 3 { end = end.dropFirst(max(1, (end.utf8.count - maxBytes) / 4)) }
                text = "…" + end
                break
            }
        }
        return (text, cut)
    }
}
