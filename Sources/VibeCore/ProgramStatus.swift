import Foundation

/// What a program says it's doing, over the Program Status Protocol (OSC 7501, superlogical.com/rex/docs/build/program-status,
/// rev 0.2). Claude Code 2.1.295+ asks `OSC 7501 ; ? ST` at startup and reports only if the terminal answers `OSC 7501 ; ? ST`:
/// `state=working:app=claude-code`, `state=blocked:app=claude-code:kind=permission:msg=<base64>`, `state=clear`…
/// A status straight from the program, with no hooks: the host keeps the session's own (top-level) record.
public struct ProgramStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case idle, working, done, blocked, error
    }

    public var state: State
    /// Why it's blocked ("permission", "question", "auth"); only with `blocked`.
    public var kind: String?
    /// "claude-code".
    public var app: String?
    /// 0–100, only with `working` or `blocked`; nil means indeterminate.
    public var progress: Int?
    public var title: String?
    public var message: String?
    /// When this report arrived.
    public var since: Date

    public init(state: State, kind: String? = nil, app: String? = nil, progress: Int? = nil, title: String? = nil,
                message: String? = nil, since: Date) {
        self.state = state
        self.kind = kind
        self.app = app
        self.progress = progress
        self.title = title
        self.message = message
        self.since = since
    }

    public static let code = 7501
    /// The terminal's answer to the feature query.
    public static let queryReply = Data("\u{1b}]7501;?\u{1b}\\".utf8)

    public enum Report: Equatable, Sendable {
        /// `OSC 7501 ; ?`: the program asks whether the terminal speaks the protocol.
        case query
        /// Removes the record `id` and its children; nil removes every record.
        case clear(id: String?)
        /// Replaces the record `id` (nil: the program's own) completely.
        case status(id: String?, ProgramStatus)
    }

    /// One OSC 7501 payload (what follows `7501;`). Nil when the spec says to ignore or discard it.
    public static func parse(_ payload: String, at now: Date) -> Report? {
        if payload.hasPrefix("?") { return .query }
        var pairs: [String: String] = [:]
        for pair in payload.split(separator: ":", omittingEmptySubsequences: true) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<equals], value = pair[pair.index(after: equals)...]
            // Malformed pairs are skipped; the rest of the report still counts. The last of a repeated key wins.
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isLowercase }), value.allSatisfy(isValueCharacter) else { continue }
            pairs[String(key)] = String(value)
        }
        let id = pairs["id"]
        if let id, !validID(id) { return nil }
        guard let stateValue = pairs["state"] else { return nil }
        if stateValue == "clear" { return .clear(id: id) }
        guard let state = State(rawValue: stateValue) else { return nil }
        if let app = pairs["app"], !validSegment(app) { return nil }
        var status = ProgramStatus(state: state, app: pairs["app"], since: now)
        if state == .blocked { status.kind = pairs["kind"].flatMap { $0.isEmpty ? nil : $0 } }
        if state == .working || state == .blocked, let text = pairs["progress"] {
            guard let value = Int(text), (0...100).contains(value) else { return nil }
            status.progress = value
        }
        // A free-text value over its limit, that isn't base64 or that decodes to control characters discards the report.
        if let encoded = pairs["title"] {
            guard let text = decodeText(encoded, encodedLimit: 256, decodedLimit: 192) else { return nil }
            status.title = text
        }
        if let encoded = pairs["msg"] {
            guard let text = decodeText(encoded, encodedLimit: 2732, decodedLimit: 2048) else { return nil }
            status.message = text
        }
        return .status(id: id, status)
    }

    private static func isValueCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "_.,+/=-".contains(character))
    }

    private static func validSegment(_ segment: some StringProtocol) -> Bool {
        (1...32).contains(segment.utf8.count)
            && segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.+-".contains($0)) }
    }

    /// `a/b/c`: segments of 1–32 characters, at most 8 deep and 128 bytes.
    private static func validID(_ id: String) -> Bool {
        let segments = id.split(separator: "/", omittingEmptySubsequences: false)
        return id.utf8.count <= 128 && segments.count <= 8 && segments.allSatisfy(validSegment)
    }

    private static func decodeText(_ encoded: String, encodedLimit: Int, decodedLimit: Int) -> String? {
        guard encoded.utf8.count <= encodedLimit else { return nil }
        var padded = encoded
        // Padding is optional.
        while padded.utf8.count % 4 != 0 { padded += "=" }
        guard let data = Data(base64Encoded: padded), data.count <= decodedLimit,
              let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return text
    }
}
