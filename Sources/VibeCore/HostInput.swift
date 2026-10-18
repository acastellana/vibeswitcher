import Foundation

/// Phone replies to a window session, written straight into its terminal.
public enum HostInput {
    public struct Write: Equatable, Sendable {
        public var bytes: [UInt8]
        /// Wait this long after the previous write.
        public var delay: TimeInterval

        public init(bytes: [UInt8], delay: TimeInterval) {
            self.bytes = bytes
            self.delay = delay
        }
    }

    /// What a terminal sends for the phone's keys (names as in `RemoteInput.Key`).
    public static func bytes(forKey name: String) -> [UInt8]? {
        switch name {
        case "enter": return [13]
        case "escape": return [27]
        case "up": return [27, 91, 65]
        case "down": return [27, 91, 66]
        case "right": return [27, 91, 67]
        case "left": return [27, 91, 68]
        case "tab": return [9]
        case "backspace": return [127]
        case "interrupt": return [3]
        default: return nil
        }
    }

    /// The (already sanitized) text, then Enter or the key as a separate write a moment later: Claude Code
    /// and Codex treat a burst of input as a paste, where Enter would become part of the text.
    public static func writes(text: String?, submit: Bool, key: String?) -> [Write] {
        var writes: [Write] = []
        if let text, !text.isEmpty { writes.append(Write(bytes: Array(text.utf8), delay: 0)) }
        let gap: TimeInterval = writes.isEmpty ? 0 : 0.06
        if text != nil, submit { writes.append(Write(bytes: [13], delay: gap)) }
        if let key {
            guard let bytes = bytes(forKey: key) else { return writes.isEmpty ? [] : writes }
            writes.append(Write(bytes: bytes, delay: writes.isEmpty ? 0 : 0.06))
        }
        return writes
    }
}

extension HostInput {
    /// What's typed into a session whose keys don't go to its program (a replaced lead, see `ReplacedLead`), as a
    /// line: text, pastes (bracketed, newlines kept) and Backspace edit it, Enter submits it, ⌃C and ⌃U clear it.
    /// Arrows, Esc and other keys do nothing.
    public struct Line: Equatable, Sendable {
        /// The longest line kept (a paste beyond it is cut).
        public static let limit = 64 * 1024

        private var bytes: [UInt8] = []
        private var pasting = false
        /// An escape sequence under way: what it has so far.
        private var escape: [UInt8]?

        public init() {}

        /// What's typed so far.
        public var draft: String { String(decoding: bytes, as: UTF8.self) }

        /// Takes what was typed; returns the lines submitted with Enter (trimmed, empty ones dropped).
        public mutating func feed<Bytes: Sequence>(_ input: Bytes) -> [String] where Bytes.Element == UInt8 {
            var submitted: [String] = []
            for byte in input {
                if var sequence = escape {
                    sequence.append(byte)
                    escape = sequence
                    if let done = Self.finished(sequence) {
                        escape = nil
                        if done == [27, 91, 50, 48, 48, 126] { pasting = true }       // ESC [200~
                        if done == [27, 91, 50, 48, 49, 126] { pasting = false }      // ESC [201~
                    }
                    continue
                }
                switch byte {
                case 27:
                    escape = [27]
                case 13 where !pasting:
                    let line = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty { submitted.append(line) }
                    bytes = []
                case 10, 13:
                    append(10)
                case 127, 8:
                    guard !pasting else { continue }
                    // One character: its continuation bytes, then its first.
                    while let last = bytes.last, last & 0xC0 == 0x80 { bytes.removeLast() }
                    if !bytes.isEmpty { bytes.removeLast() }
                case 3, 21:
                    if !pasting { bytes = [] }
                case 9:
                    append(byte)
                case 0..<32:
                    continue
                default:
                    append(byte)
                }
            }
            // A lone Esc (its own key press, nothing after it in the same write) is over.
            if escape == [27] { escape = nil }
            return submitted
        }

        private mutating func append(_ byte: UInt8) {
            if bytes.count < Self.limit { bytes.append(byte) }
        }

        /// The sequence when it's complete: CSI (`ESC [` … a final byte), SS3 (`ESC O x`), or `ESC x` (Alt+key).
        private static func finished(_ sequence: [UInt8]) -> [UInt8]? {
            guard sequence.count >= 2 else { return nil }
            switch sequence[1] {
            case 91:  // [
                guard sequence.count >= 3, let last = sequence.last, (0x40...0x7E).contains(last) else {
                    return sequence.count > 32 ? sequence : nil
                }
                return sequence
            case 79:  // O
                return sequence.count >= 3 ? sequence : nil
            default:
                return sequence
            }
        }
    }
}
