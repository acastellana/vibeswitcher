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
