import Foundation

/// The server's protocol on its Unix socket (the engine plan's "The protocol", EN-D2): JSON lines, one message a line,
/// compact JSON (which never holds a raw newline), at most `maxLine` bytes a line. Request and reply, and the events
/// `hello` and `bye`: the seed of stage 3's live protocol (the live wire contract,
/// docs/superpowers/specs/2026-11-17-v2-live-wire-contract.md), whose WebSocket text frames carry the same objects and
/// whose `subscribe`, `snapshot` and `delta` are named here and built by the live plan's tasks.
///
/// Rule 3: a message may gain fields, and readers ignore fields they don't know (`Codable` passes over them).
public enum NodeWire {
    /// The protocol's version, `v` on every message. A request with a higher one is answered `version`, then `bye`.
    public static let version = 1
    /// The longest line either side takes, its newline excluded: a longer one gets `bye` and the close.
    public static let maxLine = 1 << 20

    // MARK: Values

    /// A JSON value: a request's `args`, a reply's `result`.
    public enum Value: Codable, Equatable, Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([Value])
        case object([String: Value])

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() { self = .null }
            else if let value = try? single.decode(Bool.self) { self = .bool(value) }
            else if let value = try? single.decode(Int.self) { self = .int(value) }
            else if let value = try? single.decode(Double.self) { self = .double(value) }
            else if let value = try? single.decode(String.self) { self = .string(value) }
            else if let value = try? single.decode([Value].self) { self = .array(value) }
            else { self = .object(try single.decode([String: Value].self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .null: try single.encodeNil()
            case .bool(let value): try single.encode(value)
            case .int(let value): try single.encode(value)
            case .double(let value): try single.encode(value)
            case .string(let value): try single.encode(value)
            case .array(let value): try single.encode(value)
            case .object(let value): try single.encode(value)
            }
        }

        public var string: String? { if case .string(let value) = self { return value } else { return nil } }
        public var int: Int? { if case .int(let value) = self { return value } else { return nil } }
        public var bool: Bool? { if case .bool(let value) = self { return value } else { return nil } }
        public var array: [Value]? { if case .array(let value) = self { return value } else { return nil } }
        public var object: [String: Value]? { if case .object(let value) = self { return value } else { return nil } }
        public subscript(key: String) -> Value? { object?[key] }

        /// A date as the protocol writes one: ISO 8601, to the millisecond.
        public static func date(_ date: Date) -> Value { .string(NodeWire.dateText(date)) }
    }

    /// `date` as ISO 8601 with milliseconds, UTC.
    public static func dateText(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: date)
    }

    /// The date `dateText` wrote; nil for anything else.
    public static func date(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: Messages

    /// A client's request: `id` its own, unique on the connection; `action` a UUID on every state-changing kind (sent
    /// again on a retry, so an action is done once); `must`: a kind the server doesn't take closes the connection.
    public struct Request: Codable, Equatable, Sendable {
        public var v: Int
        public var id: String
        public var kind: String
        public var args: [String: Value]?
        public var action: String?
        public var must: Bool?

        public init(v: Int = NodeWire.version, id: String, kind: String, args: [String: Value]? = nil, action: String? = nil,
                    must: Bool? = nil) {
            self.v = v
            self.id = id
            self.kind = kind
            self.args = args
            self.action = action
            self.must = must
        }
    }

    /// Why a request failed: one of `Code`'s words, and what to tell the user.
    public struct Failure: Codable, Equatable, Sendable {
        public var code: String
        public var message: String

        public init(_ code: Code, _ message: String) {
            self.code = code.rawValue
            self.message = message
        }
    }

    /// The server's answer to one request: exactly one per request, `result` when `ok`, else `error`.
    public struct Reply: Codable, Equatable, Sendable {
        public var v: Int
        public var re: String
        public var ok: Bool
        public var result: Value?
        public var error: Failure?

        public init(re: String, result: Value) {
            v = NodeWire.version
            self.re = re
            ok = true
            self.result = result
            error = nil
        }

        public init(re: String, error: Failure) {
            v = NodeWire.version
            self.re = re
            ok = false
            result = nil
            self.error = error
        }
    }

    /// The first message on each connection, from the server, unasked.
    public struct Hello: Codable, Equatable, Sendable {
        public struct Server: Codable, Equatable, Sendable {
            public var commit: String
            public var startedAt: String
            public var pid: Int32
            public init(commit: String, startedAt: String, pid: Int32) {
                self.commit = commit
                self.startedAt = startedAt
                self.pid = pid
            }
        }

        public struct Host: Codable, Equatable, Sendable {
            /// When the host first started (its welcome's), nil before the link's first welcome.
            public var startedAt: String?
            /// The host's notes as last asked (`HostLink.notes`), when its welcome lists them.
            public var notes: Value?
            /// The host's pid, from its welcome (the start plan's S5); nil before the first welcome, or from a host
            /// that doesn't say.
            public var pid: Int32?
            public init(startedAt: String?, notes: Value?, pid: Int32? = nil) {
                self.startedAt = startedAt
                self.notes = notes
                self.pid = pid
            }
        }

        public struct Peer: Codable, Equatable, Sendable {
            /// `user`, or `other`.
            public var voice: String
            /// Why it isn't the user's, when it isn't.
            public var why: String?
            public init(voice: String, why: String?) {
                self.voice = voice
                self.why = why
            }
        }

        public var v: Int
        public var kind: String
        public var node: String
        /// A UUID made at each server start: a client that sees a new one knows the server restarted (rule 8).
        public var epoch: String
        public var server: Server
        public var host: Host
        /// The request kinds this server takes.
        public var kinds: [String]
        public var peer: Peer
        /// `systemd` (the cgroup rule), `weaker` (no cgroup to tell by: the other four lines, and a state change only
        /// from a peer with a controlling terminal) or `closed` (the server's own cgroup unread: no peer is the user's).
        public var rule: String
        /// A web connection's authentication (the live wire contract's §2): `rights`, `expiresAt`, and `token` only in
        /// answer to a pairing code. Nil, and not written, on the Unix socket.
        public var auth: Value?
        /// The build of the web files this server holds (`/build.json`'s `assets`). Nil, and not written, on the Unix
        /// socket.
        public var assets: String?

        public init(node: String, epoch: String, server: Server, host: Host, kinds: [String], peer: Peer, rule: String,
                    auth: Value? = nil, assets: String? = nil) {
            v = NodeWire.version
            kind = "hello"
            self.node = node
            self.epoch = epoch
            self.server = server
            self.host = host
            self.kinds = kinds
            self.peer = peer
            self.rule = rule
            self.auth = auth
            self.assets = assets
        }
    }

    /// The last message before the server closes a connection.
    public struct Bye: Codable, Equatable, Sendable {
        public var v: Int
        public var kind: String
        public var reason: String
        /// Why, as a word a client acts on (the live wire contract's §10): `auth`, `revoked`, `version`, `too-long`,
        /// `not-object`, `not-request`, `must` or `stopping`. Nil, and not written, from a server before it.
        public var code: String?

        public init(reason: String, code: String? = nil) {
            v = NodeWire.version
            kind = "bye"
            self.reason = reason
            self.code = code
        }
    }

    /// What every message from the server has, to tell `hello`, `bye` and a reply apart.
    public struct Envelope: Decodable, Sendable {
        public var v: Int?
        public var kind: String?
        public var re: String?
    }

    /// The error codes.
    public enum Code: String, Sendable, CaseIterable {
        case unknownKind = "unknown-kind"
        case version
        case badArgs = "bad-args"
        /// Refused for the voice or a wrong code: the message says which field failed.
        case voice
        /// The engine's reason (the request was taken, and recorded, first).
        case refused
        /// The node is stopping: the request wasn't taken (nor recorded).
        case stopping
        /// The host link isn't welcomed yet: retry.
        case notYet = "not-yet"
        /// The card or session is no longer there.
        case gone
        case `internal`
    }

    // MARK: Kinds

    /// Who a kind needs (S3: anything not listed is refused).
    public enum Voice: String, Sendable {
        /// Any process of the server's uid.
        case anyone
        /// The user's voice (`Voice.judge`).
        case user
        /// The lead's tool server, its post sealed by the host as the lead's (EN-D10).
        case leadToolServer
        /// A web client's token with the `draft` right (the live plan's LW-D6): never the user's voice, and refused on
        /// the Unix socket. It changes state (a draft on a card), so the integration task that takes such a kind checks
        /// the right before `Requests.handle`'s user's-voice path is reached.
        case webDraft
        /// A web client's terminal, on a scratch node only (LW-D12).
        case webTerminal
    }

    /// Every kind the protocol names, with the voice it needs. This server takes only `taken` (E1's); the others are
    /// answered `unknown-kind` until the task that adds each.
    public static let kinds: [String: Voice] = [
        "status": .anyone, "questions": .anyone, "start": .user, "stop": .user, "lead": .user, "answer": .user, "hold": .user,
        "config.held": .user, "config.accept": .user, "base.show": .user, "base.accept": .user, "base.keep": .user,
        "hooks.install": .user, "hooks.remove": .user, "build.switch": .user,
        "question.post": .leadToolServer, "question.revise": .leadToolServer, "question.withdraw": .leadToolServer,
        // The live protocol's (the live wire contract), taken from the integration task that wires each (I1 to I4).
        "subscribe": .anyone, "unsubscribe": .anyone, "chat.page": .anyone,
        "draft": .webDraft, "draft.clear": .webDraft,
        "web.open": .user, "web.revoke": .user,
        "term.open": .webTerminal, "term.close": .webTerminal,
    ]

    /// The user's-voice kinds that change nothing (EN-D5: no typed word): `start` to a running node says when it
    /// started; `config.held` and `base.show` make the card the next request takes.
    public static let changesNothing: Set<String> = ["start", "config.held", "base.show"]

    /// Whether `kind` changes state: every user's-voice kind but `changesNothing`'s, a kind added later included, and
    /// every web client's kind (a draft, a terminal). A kind missing from `kinds` needs the user's voice, as
    /// `Requests.handle` reads it, so it changes state too.
    public static func changesState(_ kind: String) -> Bool {
        switch kinds[kind] ?? .user {
        case .user: return !changesNothing.contains(kind)
        case .webDraft, .webTerminal: return true
        case .anyone, .leadToolServer: return false
        }
    }

    /// The kinds this build's server takes (E1's; `lead` from E4; the cards and the lead's questions from E6; the hooks
    /// from the start plan's S6; `build.switch` from its S8b; the live protocol's `subscribe`, `unsubscribe`, `web.open`
    /// and `web.revoke` from the live plan's I1): every kind `kinds` names but the live protocol's later ones (`chat.page`
    /// from I2, the drafts from I3, the terminal from I4).
    public static let taken = ["status", "start", "stop", "lead", "questions", "answer", "hold", "config.held", "config.accept",
                               "base.show", "base.accept", "base.keep", "question.post", "question.revise", "question.withdraw",
                               "hooks.install", "hooks.remove", "build.switch", "subscribe", "unsubscribe", "web.open", "web.revoke"]

    // MARK: Lines

    /// `value` as one line: compact JSON and a newline.
    public static func line<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// JSON text (`line`'s, or JSONSerialization's) for a terminal: every scalar `ConfigSeal.inert` would replace (C1
    /// controls, DEL, bidirectional and other format characters, separators, private-use and unassigned scalars)
    /// written as a `\uXXXX` escape (a surrogate pair past U+FFFF). The JSON means the same, so nothing is lost to a
    /// reader of it, and none of these reaches the terminal raw (Review Focus 7): JSONEncoder escapes only what's below
    /// U+0020. They can only be inside strings, so the escapes are valid JSON. A newline that ends `json` stays.
    public static func printable(_ json: Data) -> Data {
        var text = String.UnicodeScalarView()
        let body = json.last == UInt8(ascii: "\n") ? json.dropLast() : json[...]
        for scalar in String(decoding: body, as: UTF8.self).unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
                for unit in String(scalar).utf16 { text.append(contentsOf: String(format: "\\u%04x", unit).unicodeScalars) }
            default:
                text.append(scalar)
            }
        }
        var data = Data(String(text).utf8)
        if body.count != json.count { data.append(UInt8(ascii: "\n")) }
        return data
    }

    /// A line (without its newline) as `T`; nil when it isn't one.
    public static func decode<T: Decodable>(_ type: T.Type, _ line: Data) -> T? {
        try? JSONDecoder().decode(type, from: line)
    }

    /// Whether a line is a JSON object (not an array, a string, a number or no JSON at all).
    public static func isObject(_ line: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: line, options: [])) is [String: Any]
    }

    /// Bytes as they come, cut into lines. A line longer than `maxLine` (with no newline yet past it) is `tooLong`:
    /// the reader closes the connection.
    public struct Lines: Sendable {
        private var pending = Data()
        public private(set) var tooLong = false

        public init() {}

        /// The whole lines `bytes` completes, in order, each without its newline; none once `tooLong`.
        public mutating func append(_ bytes: Data) -> [Data] {
            guard !tooLong else { return [] }
            pending.append(bytes)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                guard line.count <= NodeWire.maxLine else {
                    tooLong = true
                    return lines
                }
                lines.append(Data(line))
                pending.removeSubrange(pending.startIndex...newline)
            }
            if pending.count > NodeWire.maxLine { tooLong = true }
            return lines
        }
    }
}
