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
    /// The most bytes one part of a snapshot takes (the architecture review's row 14): a client that asks for parts
    /// (`subscribe`'s `parts`) gets a snapshot as messages of at most this, each a part of it, whatever the collection
    /// holds (`LiveHub.parted`).
    public static let partBytes = 256 << 10
    /// The most bytes one entry of a keyed collection takes, encoded: a part's room once its envelope is counted. Each
    /// collection's value keeps its entries under it by its own rule (a board's `BoardValue.mostBytes`); an entry
    /// past it anyway is withheld from a snapshot in parts, named in its `withheld`, never the snapshot dropped.
    public static let entryBytes = partBytes - (8 << 10)

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
        /// An acting page's passkey assertion for this request, at the level `confirm` (`PasskeyVoice`): its credential's
        /// id, client data, authenticator data and signature, base64url. Beside `args`, never in them.
        public var assertion: Value?

        public init(v: Int = NodeWire.version, id: String, kind: String, args: [String: Value]? = nil, action: String? = nil,
                    must: Bool? = nil, assertion: Value? = nil) {
            self.v = v
            self.id = id
            self.kind = kind
            self.args = args
            self.action = action
            self.must = must
            self.assertion = assertion
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
        /// An acting page's act at the level `confirm`: the line the vault recorded it with (what the passkey approved).
        public var recorded: String?

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
    /// Why a connection's first line is no hello (`greeting`).
    public struct NoHello: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// A connection's first line (nil: none came) as a client reads it: the hello; or, when the server closed it at
    /// once with a `bye` (one process past its share of connections, a full server), its reason, so the user sees why.
    /// The reason is the server's words as sent: a terminal shows them through `ConfigSeal.inert`.
    public static func greeting(_ first: Data?) -> Result<Hello, NoHello> {
        guard let first else { return .failure(NoHello(description: "the node's server sent no hello")) }
        if let hello = decode(Hello.self, first), hello.kind == "hello" { return .success(hello) }
        if let bye = decode(Bye.self, first), bye.kind == "bye" {
            return .failure(NoHello(description: "the node's server closed the connection: \(bye.reason)"))
        }
        return .failure(NoHello(description: "the node's server sent no hello"))
    }

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
        /// The feature plugins that are on, each `{id, title}` (`PluginRegistry.onValue`): a plugin that is off isn't
        /// listed, and the page draws nothing for it. Nil, and not written, from a server with no engine.
        public var plugins: Value?

        public init(node: String, epoch: String, server: Server, host: Host, kinds: [String], peer: Peer, rule: String,
                    auth: Value? = nil, assets: String? = nil, plugins: Value? = nil) {
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
            self.plugins = plugins
        }
    }

    /// The last message before the server closes a connection.
    public struct Bye: Codable, Equatable, Sendable {
        public var v: Int
        public var kind: String
        public var reason: String
        /// Why, as a word a client acts on (the live wire contract's §10): `auth`, `revoked`, `version`, `too-long`,
        /// `not-object`, `not-request`, `must`, `stopping` or `busy` (no room for the connection: its process holds its
        /// share, or the server is full). Nil, and not written, from a server before it.
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
        /// What an acting page drew (a card, a batch) changed since: nothing was done or recorded; look again.
        case changed
        /// This page no longer acts or watches (its pairing ran out or was dropped, the level was lowered, a revoke):
        /// it drops its pairing secret, reads and drafts, and is paired again to act.
        case actsEnded = "acts-ended"
        /// An act at the level `confirm` came without a passkey assertion, or with one whose challenge ran out: ask
        /// `act.challenge` and send it again with one. Nothing was done or kept.
        case assertionNeeded = "assertion-needed"
        /// Its passkey assertion didn't check: nothing was done.
        case passkey
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
        /// A read of a private record (Between leads' `mail`): the user's voice on the socket, with no typed word, or a
        /// web client's token with the `read` right (the page's Between leads view, 2026-11-21); never a session's
        /// process, which `anyone` would let read every project's leads' messages.
        case webRead
        /// A web client's token with the `draft` right (the live plan's LW-D6): never the user's voice, and refused on
        /// the Unix socket. It changes state (a draft on a card), so the integration task that takes such a kind checks
        /// the right before `Requests.handle`'s user's-voice path is reached.
        case webDraft
        /// A web client's terminal: watched on the user's node, typed into on a scratch node only (LW-D12, amended
        /// 2026-11-20).
        case webTerminal
        /// A page whose pairing the user confirmed in a terminal (`LiveRights.watch`): its passkey's part of the level
        /// `confirm` (a challenge for an act, a registration the terminal asked). Never the socket's.
        case webPaired
    }

    /// Every kind the protocol names, with the voice it needs: a view of `KindSpec.all` (who may send each, and why, is
    /// said there).
    public static let kinds: [String: Voice] = Dictionary(uniqueKeysWithValues: KindSpec.all.map { ($0.name, $0.sender) })

    /// The user's-voice kinds that change nothing (EN-D5: no typed word): `start` to a running node says when it
    /// started; `config.held` and `base.show` make the card the next request takes; `shells` lists the node's shells for
    /// Close Finished Shells; `update.check` asks GitHub now and keeps only its answer. (`mail`, a read of the user's or a page's, is `webRead`: it changes nothing either.)
    public static let changesNothing: Set<String> = Set(KindSpec.all.filter { $0.sender == .user && $0.effect != .change }.map(\.name))

    /// Whether `kind` changes state: every user's-voice kind but `changesNothing`'s, a kind added later included, and
    /// every web client's kind (a draft, a terminal). A kind missing from `kinds` needs the user's voice, as
    /// `Requests.handle` reads it, so it changes state too.
    public static func changesState(_ kind: String) -> Bool {
        KindSpec.spec(kind)?.changesState ?? true
    }

    /// The kinds this build's server takes (E1's; `lead` from E4; the cards and the lead's questions from E6; the hooks
    /// from the start plan's S6; `build.switch` from its S8b; the live protocol's `subscribe`, `unsubscribe`, `web.open`
    /// and `web.revoke` from the live plan's I1; `chat.page` from I2; `draft` and `draft.clear` from I3, a web page's
    /// only; `tell` from the node frictions of 2026-11-19; `board` from the board view's; `seen` from the parity gaps
    /// of 2026-11-19; `send`, `session.new`, `session.end`, `session.reply`, `session.draft` and `session.draft.clear`
    /// from driving sessions, 2026-11-20; `settings` and `set` from the settings, 2026-11-20; `push` and `push.decline`
    /// from the push row, 2026-11-20; `session.presets`, `session.complete` and `session.attach` from the composer's lane,
    /// 2026-11-20): every kind `kinds` names but the live protocol's later ones (the terminal from I4).
    public static let taken: [String] = KindSpec.all.filter { $0.servedBy != .terminalRelay && $0.sender != .webPaired }.map(\.name)

    // MARK: Lines

    /// `value` as one line: compact JSON and a newline.
    public static func line<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// `reply` as one line, or, when that line would pass `maxLine` (the reader would drop it and close: 2026-11-19, a
    /// node's every card past it broke `answer`), an `internal` failure under the same `re` saying how large it was and
    /// to ask for less. Never a line the other side can't take, unless `re` itself is that long (the caller checks).
    public static func replyLine(_ reply: Reply) -> Data {
        let data = line(reply)
        guard data.count - 1 > maxLine else { return data }
        return line(Reply(re: reply.re, error: Failure(.internal, "the reply was \(data.count - 1) bytes, past the line's limit of \(maxLine): "
            + "nothing was dropped, but nothing was sent; ask for less (a folder, a card, without --all)")))
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

    /// A message read as a request: the one check of its envelope both transports make (the Unix socket's lines and a
    /// WebSocket's texts), so they refuse the same things with the same `bye` codes.
    public enum Unwrapped: Equatable, Sendable {
        case request(Request)
        /// Not taken: `reply` (when there is one) is sent, then the connection ends with `code` and `reason`.
        case refused(reply: Reply?, code: String, reason: String)
    }

    /// `message` (one line or text, without its newline) as a request: not a JSON object is `not-object`; not a request
    /// (`v`, `id` and `kind` are needed) is `not-request`; a newer `v` is the `version` error, then `version`.
    public static func unwrap(_ message: Data) -> Unwrapped {
        guard isObject(message) else { return .refused(reply: nil, code: "not-object", reason: "a message that isn't a JSON object") }
        guard let request = decode(Request.self, message) else {
            return .refused(reply: nil, code: "not-request", reason: "a message that isn't a request (v, id and kind are needed)")
        }
        guard request.v <= version else {
            return .refused(reply: Reply(re: request.id, error: .init(.version, "this server speaks version \(version)")),
                            code: "version", reason: "a newer protocol than this server's")
        }
        return .request(request)
    }

    /// A kind this server doesn't take: its `unknown-kind` reply, and, when the client must have it, the connection's
    /// end (`must`).
    public static func unknownKind(_ request: Request) -> (reply: Reply, bye: (code: String, reason: String)?) {
        let reply = Reply(re: request.id, error: .init(.unknownKind, "this server doesn't take \(request.kind)"))
        guard request.must == true else { return (reply, nil) }
        return (reply, ("must", "a request this server must understand and doesn't (\(request.kind.prefix(80)))"))
    }

    /// Bytes as they come, cut into lines. A line longer than `maxLine` (with no newline yet past it) is `tooLong`:
    /// the reader closes the connection.
    ///
    /// Linear in the bytes, however they come (the fuzz tests of 2026-11-22, `ParserFuzzTests`): each byte is looked at
    /// for a newline once (`scanned`), not again at every append (a line dripped a byte at a time was quadratic: a
    /// megabyte of it, half a trillion looks), and the lines a chunk completes are cut from it once, at the end (taking
    /// each one moved all that followed it: a megabyte of one-byte lines, half a million moves of a megabyte).
    public struct Lines: Sendable {
        private var pending = Data()
        /// How much of `pending` holds no newline (looked at already).
        private var scanned = 0
        public private(set) var tooLong = false
        /// The longest line taken (the wire's `maxLine`; a plugin's protocol, `PluginProcess.lineBytesAtMost`).
        public let maxLine: Int

        public init(maxLine: Int = NodeWire.maxLine) { self.maxLine = maxLine }

        /// The whole lines `bytes` completes, in order, each without its newline; none once `tooLong`.
        public mutating func append(_ bytes: Data) -> [Data] {
            guard !tooLong else { return [] }
            pending.append(bytes)
            var lines: [Data] = []
            var lineStart = pending.startIndex
            var from = pending.startIndex + scanned
            while let newline = pending[from...].firstIndex(of: UInt8(ascii: "\n")) {
                guard newline - lineStart <= maxLine else {
                    tooLong = true
                    pending = Data()
                    return lines
                }
                lines.append(Data(pending[lineStart..<newline]))
                lineStart = newline + 1
                from = lineStart
            }
            if lineStart > pending.startIndex { pending = Data(pending[lineStart...]) }
            scanned = pending.count
            if pending.count > maxLine {
                tooLong = true
                pending = Data()
            }
            return lines
        }
    }
}
