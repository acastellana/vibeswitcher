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
        /// share, the server is full, or it was closed to make room). Nil, and not written, from a server before it.
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
    }

    /// Every kind the protocol names, with the voice it needs. This server takes only `taken` (E1's); the others are
    /// answered `unknown-kind` until the task that adds each.
    public static let kinds: [String: Voice] = [
        "status": .anyone, "questions": .anyone, "board": .anyone, "start": .user, "stop": .user, "lead": .user, "answer": .user, "hold": .user,
        "config.held": .user, "config.accept": .user, "base.show": .user, "base.accept": .user, "base.keep": .user,
        "hooks.install": .user, "hooks.remove": .user, "build.switch": .user, "tell": .user,
        "question.post": .leadToolServer, "question.revise": .leadToolServer, "question.withdraw": .leadToolServer,
        // The live protocol's (the live wire contract), taken from the integration task that wires each (I1 to I4).
        "subscribe": .anyone, "unsubscribe": .anyone, "chat.page": .anyone,
        // A finished session seen (the parity gaps of 2026-11-19): it changes nothing but the seen mark, so no voice.
        "seen": .anyone,
        "draft": .webDraft, "draft.clear": .webDraft,
        "web.open": .user, "web.revoke": .user,
        "term.open": .webTerminal, "term.close": .webTerminal,
        // Driving an ordinary session (the parity table's gaps 1, 3 and 6, 2026-11-20): the user's voice, and a page's draft.
        "send": .user, "session.new": .user, "session.end": .user, "session.reply": .user, "session.reopen": .user,
        // Between leads (the stability lane, 2026-11-20): a read, but the projects' private record of their leads'
        // messages, so never a session's: the user's, with no typed word, and since 2026-11-21 a page's token that reads
        // (the page's Between leads view, read-only: the leads' messages reach the page's chats already).
        "mail": .webRead,
        // The prompt-audit reminder's snooze, off and on (the stability lane, 2026-11-20).
        "prompt-audit": .user,
        // A session renamed or paused (the stability lane, 2026-11-20).
        "session.rename": .user, "session.pause": .user, "session.resume": .user,
        // Close Finished Shells (the stability lane, 2026-11-20): the list a read of the user's (no code), the closing
        // the user's voice.
        "shells": .user, "session.close-shells": .user,
        // A launch preset added, changed or removed (the page-actions lane, 2026-11-20).
        "presets.edit": .user,
        "session.draft": .webDraft, "session.draft.clear": .webDraft,
        // The composer and launch presets (2026-11-20): what a session's `/` and `@` offer, and the presets, are reads.
        "session.presets": .anyone, "session.complete": .anyone, "session.attach": .webDraft,
        // A session's tokens and cost, read from its transcript (the inspector, 2026-11-21).
        "session.usage": .anyone,
        // An image a session's chat shows, its bytes in parts (the chat's images, 2026-11-21): a read.
        "chat.image": .anyone,
        // The Statistics window's figures (2026-11-21): a read.
        "stats": .anyone,
        // A board task's details as its row opens, a result's screenshot (the Team tab, 2026-11-21): reads.
        "board.task": .anyone, "board.image": .anyone,
        // A session's dev servers, the ports its processes listen on (the dev pages row, 2026-11-21): a read.
        "session.ports": .anyone,
        // The node's settings (the parity table's gap 9, 2026-11-20): read by anyone of the uid (a page too), set in the
        // user's voice.
        "settings": .anyone, "set": .user,
        // The start page's recent projects (2026-11-21): a read of the folders Claude Code and Codex know, the user's
        // other projects among them, so never a session's: the user's or a page's that reads (`webRead`, as `mail`).
        "recent": .webRead,
        // Brief me (2026-11-21): a read of the user's own, which may ask the summaries' model, so never a session's.
        "brief": .webRead,
        // Settling the lead's push request (the parity table's push row, 2026-11-20): the user's voice.
        "push": .user, "push.decline": .user,
        // Check for Updates now (`status --check-updates`, 2026-11-21): it asks GitHub and keeps the answer in the update
        // watch's own record, changing nothing else; the user's, with no typed word, never a session's or a page's.
        "update.check": .user,
        // `vibeswitcher approve` (2026-11-22): the list of what a plain accept settles changes nothing (no typed word);
        // the batch's go-ahead is the user's voice, one typed code, each item recorded as its own action.
        "approve.list": .user, "approve": .user,
        // The feature plugins (2026-11-22): the list a read, on and off the user's voice.
        "plugin.list": .anyone, "plugin.on": .user, "plugin.off": .user,
    ]

    /// The user's-voice kinds that change nothing (EN-D5: no typed word): `start` to a running node says when it
    /// started; `config.held` and `base.show` make the card the next request takes; `shells` lists the node's shells for
    /// Close Finished Shells; `update.check` asks GitHub now and keeps only its answer. (`mail`, a read of the user's or a page's, is `webRead`: it changes nothing either.)
    public static let changesNothing: Set<String> = ["start", "config.held", "base.show", "shells", "update.check", "approve.list"]

    /// Whether `kind` changes state: every user's-voice kind but `changesNothing`'s, a kind added later included, and
    /// every web client's kind (a draft, a terminal). A kind missing from `kinds` needs the user's voice, as
    /// `Requests.handle` reads it, so it changes state too.
    public static func changesState(_ kind: String) -> Bool {
        switch kinds[kind] ?? .user {
        case .user: return !changesNothing.contains(kind)
        case .webDraft, .webTerminal: return true
        case .anyone, .leadToolServer, .webRead: return false
        }
    }

    /// The kinds this build's server takes (E1's; `lead` from E4; the cards and the lead's questions from E6; the hooks
    /// from the start plan's S6; `build.switch` from its S8b; the live protocol's `subscribe`, `unsubscribe`, `web.open`
    /// and `web.revoke` from the live plan's I1; `chat.page` from I2; `draft` and `draft.clear` from I3, a web page's
    /// only; `tell` from the node frictions of 2026-11-19; `board` from the board view's; `seen` from the parity gaps
    /// of 2026-11-19; `send`, `session.new`, `session.end`, `session.reply`, `session.draft` and `session.draft.clear`
    /// from driving sessions, 2026-11-20; `settings` and `set` from the settings, 2026-11-20; `push` and `push.decline`
    /// from the push row, 2026-11-20; `session.presets`, `session.complete` and `session.attach` from the composer's lane,
    /// 2026-11-20): every kind `kinds` names but the live protocol's later ones (the terminal from I4).
    public static let taken = ["status", "start", "stop", "lead", "questions", "draft", "draft.clear", "answer", "hold", "config.held", "config.accept",
                               "base.show", "base.accept", "base.keep", "question.post", "question.revise", "question.withdraw",
                               "hooks.install", "hooks.remove", "build.switch", "subscribe", "unsubscribe", "web.open", "web.revoke",
                               "chat.page",
                               "tell",
                               "board", "seen",
                               "send", "session.new", "session.end", "session.reply", "session.draft", "session.draft.clear",
                               "session.presets", "session.complete", "session.attach", "session.usage", "chat.image", "stats", "session.ports", "board.task", "board.image",

                               "settings", "set",
                               "push", "push.decline",
                               "session.reopen", "mail", "prompt-audit", "session.rename", "session.pause",
                               "session.resume", "shells", "session.close-shells", "presets.edit",
                               "recent", "brief", "update.check", "approve.list", "approve", "plugin.list", "plugin.on", "plugin.off"]

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
