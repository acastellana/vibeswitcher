import Foundation

/// The app ⇄ session host protocol. See docs/superpowers/specs/2026-10-16-ide-window-session-host-design.md.
public enum HostProtocol {
    /// Bumped whenever a message changes shape; app and host talk only when theirs match.
    public static let version = 1

    /// What a host can do beyond `version`, listed in its welcome (a host older than the list sends none).
    public enum Capability {
        /// Answers `styledScreen`.
        public static let styledScreen = "styledScreen"
        /// Answers input it can't take (the program isn't reading and its buffer is full) with an error, replying to
        /// that input's `seq`; older hosts dropped it silently.
        public static let inputRefusals = "inputRefusals"
        /// Takes `HostRequest.handover`: it's updated without ending its sessions.
        public static let handover = "handover"
        /// Answers `HostRequest.vault`: the lead's vault and the user's sealing key live in the host.
        public static let leadVault = "leadVault"
        /// Sends each connection a `HostEvent.challenge` and takes nothing from it as the app's until it answered
        /// (`HostRequest.proveApp`, see `AppProof`): `handover`, `kill` of another's session and the app's vault requests.
        public static let appProof = "appProof"
        /// Takes `HostRequest.inputUnit`: a unit of writes (a message's text and its Enter) goes into its session whole,
        /// whoever else types into it meanwhile. Without it, a client writes the unit as plain `input`.
        public static let inputUnits = "inputUnits"
    }

    /// The error a spawn gets once the host agreed to shut down.
    public static let shuttingDown = "The session host is shutting down."
}

/// Framing on the socket: a 4-byte big-endian length (kind byte + payload), the kind byte, the payload.
public enum HostFrame {
    public enum Kind: UInt8, Sendable {
        /// A JSON `HostRequestEnvelope` (app → host) or `HostEventEnvelope` (host → app).
        case control = 0
        /// Bytes a session printed: 16-byte session UUID, then the bytes.
        case output = 1
    }

    /// Largest payload a frame may carry (the kind byte not counted).
    public static let maxPayload = 1 << 20

    public static func encode(_ kind: Kind, _ payload: Data) -> Data {
        precondition(payload.count <= maxPayload, "frame payload too large")
        var length = UInt32(payload.count + 1).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(kind.rawValue)
        frame.append(payload)
        return frame
    }

    /// One session's output as frames no larger than `maxPayload`. Nothing for no bytes.
    public static func output(session: UUID, bytes: Data) -> [Data] {
        let id = withUnsafeBytes(of: session.uuid) { Data($0) }
        let room = maxPayload - id.count
        var frames: [Data] = []
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes.index(start, offsetBy: min(room, bytes.endIndex - start))
            frames.append(encode(.output, id + bytes[start..<end]))
            start = end
        }
        return frames
    }

    public static func parseOutput(_ payload: Data) -> (UUID, Data)? {
        guard payload.count >= 16 else { return nil }
        let b = [UInt8](payload.prefix(16))
        let id = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                             b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        return (id, Data(payload.dropFirst(16)))
    }
}

/// Collects bytes from the socket and hands out complete frames.
public struct HostFrameDecoder {
    /// The stream is corrupt: drop the connection.
    public enum Failure: Error, Equatable {
        case oversize(Int)
        case badKind(UInt8)
        case emptyFrame
    }

    private var buffer = Data()
    private var offset = 0
    /// One maximum frame plus the next socket read; callers consume frames between reads.
    public static let maxBufferedBytes = HostFrame.maxPayload + 5 + 65_536
    private var overflowed = false

    public init() {}

    public mutating func append(_ data: Data) {
        guard !overflowed else { return }
        guard data.count <= Self.maxBufferedBytes - (buffer.count - offset) else {
            overflowed = true
            buffer = Data()
            offset = 0
            return
        }
        // Compact once the consumed part is at least half of what's held: removing from the front copies.
        if offset > 0, offset >= buffer.count / 2 {
            buffer = Data(buffer.dropFirst(offset))
            offset = 0
        }
        buffer.append(data)
    }

    /// The next complete frame, or nil until more bytes arrive.
    public mutating func next() throws -> (kind: HostFrame.Kind, payload: Data)? {
        guard !overflowed else { throw Failure.oversize(Self.maxBufferedBytes + 1) }
        guard buffer.count - offset >= 4 else { return nil }
        let length = buffer[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
        guard length >= 1 else { throw Failure.emptyFrame }
        guard length - 1 <= HostFrame.maxPayload else { throw Failure.oversize(length) }
        guard buffer.count - offset >= 4 + length else { return nil }
        let kindByte = buffer[offset + 4]
        guard let kind = HostFrame.Kind(rawValue: kindByte) else { throw Failure.badKind(kindByte) }
        let payload = Data(buffer[(offset + 5)..<(offset + 4 + length)])
        offset += 4 + length
        return (kind, payload)
    }
}

/// A session the host runs, as both sides see it.
public struct HostSession: Codable, Equatable, Sendable, Identifiable {
    public struct Exit: Codable, Equatable, Sendable {
        /// The exit code, or 128 + signal number when it was killed.
        public var status: Int32
        public var at: Date
        /// The signal that killed it; nil when it exited (or an older host said nothing): a SIGTERM death and a
        /// program that exited 143 have the same `status`. The fields below are nil from an older host too.
        public var signal: Int32?
        /// It dumped core.
        public var core: Bool?
        /// The client that asked this host to end it (a `kill`), when one did: its process id and name.
        public var killedBy: Int32?
        public var killedByName: String?

        public init(status: Int32, at: Date, signal: Int32? = nil, core: Bool? = nil, killedBy: Int32? = nil,
                    killedByName: String? = nil) {
            self.status = status
            self.at = at
            self.signal = signal
            self.core = core
            self.killedBy = killedBy
            self.killedByName = killedByName
        }

        /// How it ended, in words: "killed by SIGTERM", "killed by SIGHUP from pid 4242 (vibeswitcher-mcp)", "exited 143".
        public var cause: String {
            guard status >= 0 || signal != nil else { return "lost with the session host" }
            let client = killedBy.map { pid in "pid \(pid)" + (killedByName.map { " (\($0))" } ?? "") }
            guard let signal else { return "exited \(status)" + (client.map { " after \($0) closed it" } ?? "") }
            return "killed by \(Self.signalName(signal))" + (client.map { " from \($0)" } ?? "") + (core == true ? " (core dumped)" : "")
        }

        public static func signalName(_ signal: Int32) -> String {
            let names: [Int32: String] = [1: "HUP", 2: "INT", 3: "QUIT", 4: "ILL", 5: "TRAP", 6: "ABRT", 8: "FPE", 9: "KILL",
                                          10: "BUS", 11: "SEGV", 13: "PIPE", 14: "ALRM", 15: "TERM", 24: "XCPU", 25: "XFSZ"]
            return names[signal].map { "SIG" + $0 } ?? "signal \(signal)"
        }
    }

    public var id: UUID
    /// "ttys012": the agent's hooks and the process scan report this.
    public var tty: String
    /// The login shell the host started (process group leader).
    public var childPID: Int32
    public var cwd: String
    /// The preset's command; nil for a plain shell.
    public var command: String?
    /// The preset it was started from, e.g. "Claude".
    public var label: String
    /// The agent the preset starts (`Agent.rawValue`), nil for a shell.
    public var agent: String?
    /// The terminal title the program set (OSC 0/2).
    public var title: String
    public var startedAt: Date
    public var cols: Int
    public var rows: Int
    public var exit: Exit?
    /// What the program last reported over OSC 7501 (its own record, not its tasks'); nil when it hasn't, or cleared it.
    /// Optional, so apps and hosts from before it still decode each other's sessions.
    public var programStatus: ProgramStatus?

    public var isLive: Bool { exit == nil }

    /// The same as `other` but for the spinner frame in its title ("⠋ Fix login" → "⠙ Fix login"): a working agent's
    /// spinner changes the title many times a second, and that reads the same everywhere the app shows it.
    public func differsOnlyBySpinner(from other: HostSession) -> Bool {
        guard title != other.title else { return false }
        var retitled = other
        retitled.title = title
        guard retitled == self else { return false }
        let (activity, text) = StatusRules.parseTitle(title), (otherActivity, otherText) = StatusRules.parseTitle(other.title)
        return activity == .busy && otherActivity == .busy && text == otherText
    }

    public init(id: UUID, tty: String, childPID: Int32, cwd: String, command: String?, label: String, agent: String?,
                title: String, startedAt: Date, cols: Int, rows: Int, exit: Exit?, programStatus: ProgramStatus? = nil) {
        self.id = id
        self.tty = tty
        self.childPID = childPID
        self.cwd = cwd
        self.command = command
        self.label = label
        self.agent = agent
        self.title = title
        self.startedAt = startedAt
        self.cols = cols
        self.rows = rows
        self.exit = exit
        self.programStatus = programStatus
    }
}

public struct SpawnRequest: Codable, Equatable, Sendable {
    public var cwd: String
    /// Nil: a plain login shell.
    public var command: String?
    public var env: [String: String]
    public var cols: Int
    public var rows: Int
    /// After the command exits, keep a shell in the session instead of ending it.
    public var keepShell: Bool
    public var label: String
    public var agent: String?

    public init(cwd: String, command: String?, env: [String: String], cols: Int, rows: Int, keepShell: Bool,
                label: String, agent: String?) {
        self.cwd = cwd
        self.command = command
        self.env = env
        self.cols = cols
        self.rows = rows
        self.keepShell = keepShell
        self.label = label
        self.agent = agent
    }
}

public enum HostRequest: Codable, Equatable, Sendable {
    case hello(protocolVersion: Int, app: String)
    case spawn(SpawnRequest)
    case attach(id: UUID, cols: Int, rows: Int)
    case detach(id: UUID)
    /// `reply`: an automatic answer to a terminal query (cursor position, colors…), not typing.
    case input(id: UUID, bytes: Data, reply: Bool)
    /// Writes these into the session in order, each `delay` after the one before reached the program, the first a
    /// moment after the session's last unit (see `HostProtocol.Capability.inputUnits`); the session's other input,
    /// from every client, waits until the unit is in. `more`: the unit goes on with this connection's next
    /// `inputUnit` (its sender checks something first, say the screen): the session stays held for it, for a few
    /// seconds at most. Answered `ok` once the writes went in, or with an error once one couldn't (the rest aren't
    /// written, and the unit is over). A part with no writes and `more` false ends a held unit.
    case inputUnit(id: UUID, writes: [HostInput.Write], more: Bool)
    case resize(id: UUID, cols: Int, rows: Int)
    case screen(id: UUID)
    /// The screen's text and how its characters are drawn (see `ScreenRun`). A host older than this answers with
    /// an error: ask for `screen` then.
    case styledScreen(id: UUID)
    case history(id: UUID, lines: Int)
    case kill(id: UUID)
    case remove(id: UUID)
    /// Honoured only when no session is live.
    case shutdown
    /// The project lead's vault (see `LeadVault`), answered for the process on this connection. A host older than
    /// this answers with an error.
    case vault(LeadVault.Request)
    /// Re-execute as the host binary at `executable`, keeping every session (see `HostProtocol.Capability.handover`). Answered
    /// with `ok` just before, then the connection closes; connect again for the new build's welcome. An error: the
    /// running host carries on as it was.
    case handover(executable: String)
    /// The answer to this connection's `HostEvent.challenge` (see `AppProof`). Answered `ok`, or an error saying why
    /// the connection isn't the app's (it then isn't).
    case proveApp(answer: Data)
    /// The app's key, for a host that holds none (its challenge says so). Taken only from a connection the host tells
    /// is the app's code, and only while it holds none. Not answered.
    case enrollApp(key: Data)
    /// The app lost its key (its Keychain item is gone): the host takes this one in place of the one it holds, only
    /// from the app's code and only while no session runs, and logs it. Answered `ok` or with an error.
    case replaceAppKey(key: Data)
}

public enum HostEvent: Codable, Equatable, Sendable {
    /// `hostBuild`: identifies the host binary (see `HostBuild`), so the app can tell an outdated host.
    /// `capabilities` (see `HostProtocol.Capability`), `pid` and `startedAt` (the host's): nil from an older host.
    case welcome(protocolVersion: Int, hostBuild: Int, sessions: [HostSession], capabilities: [String]? = nil,
                 pid: Int32? = nil, startedAt: Date? = nil)
    case spawned(HostSession)
    /// Replay is over; live output follows.
    case attached(id: UUID)
    case screenText(id: UUID, text: String)
    case styledScreenText(id: UUID, text: String, runs: [ScreenRun])
    case historyText(id: UUID, history: String, screen: String)
    case sessionChanged(HostSession)
    case sessionRemoved(id: UUID)
    /// This client fell behind and was detached; attach again.
    case resync(id: UUID)
    case bell(id: UUID)
    case error(String)
    case ok
    case vault(LeadVault.Reply)
    /// Sent once to each connection as it's accepted, before anything else: what the app answers to be the app on it
    /// (`HostRequest.proveApp`). `keyless`: the host holds no app key yet (`HostRequest.enrollApp`).
    case challenge(Data, keyless: Bool)
}

/// A run of characters on one screen row drawn alike, when that isn't plain: faint (SGR 2), inverse (SGR 7: an
/// app's painted caret) or in a colour. `column` counts the row's characters in the screen's text, which has one per
/// terminal cell: a wide character (CJK, emoji) is followed by an empty one for its second cell.
public struct ScreenRun: Codable, Equatable, Sendable {
    public enum Color: Codable, Equatable, Sendable {
        /// The 256-colour palette (0–15 the ANSI colours).
        case palette(Int)
        case rgb(Int, Int, Int)
    }

    public var row: Int
    public var column: Int
    public var length: Int
    public var faint: Bool
    public var inverse: Bool
    /// Nil: the default colour.
    public var color: Color?

    public init(row: Int, column: Int, length: Int, faint: Bool = false, inverse: Bool = false, color: Color? = nil) {
        self.row = row
        self.column = column
        self.length = length
        self.faint = faint
        self.inverse = inverse
        self.color = color
    }

    /// Drawn the way terminals show secondary text: faint, or in a mid grey (Claude Code's placeholder and
    /// suggested prompt are faint; its secondary text is grey).
    public var isDim: Bool {
        if faint { return true }
        switch color {
        case .palette(let code)?: return code == 8 || (237...250).contains(code)
        case .rgb(let r, let g, let b)?: return max(r, g, b) - min(r, g, b) <= 16 && (80...190).contains(r)
        case nil: return false
        }
    }
}

public struct HostRequestEnvelope: Codable, Equatable, Sendable {
    public var seq: Int
    public var request: HostRequest
    public init(seq: Int, request: HostRequest) {
        self.seq = seq
        self.request = request
    }
}

public struct HostEventEnvelope: Codable, Equatable, Sendable {
    /// The `seq` of the request this answers; nil for events nobody asked for.
    public var replyTo: Int?
    public var event: HostEvent
    public init(replyTo: Int?, event: HostEvent) {
        self.replyTo = replyTo
        self.event = event
    }
}

public enum HostCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}

/// Identifies a host binary by its modification time: a rebuilt app bundles a newer one.
public enum HostBuild {
    public static func id(ofExecutableAt path: String) -> Int {
        let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        return Int(date?.timeIntervalSince1970 ?? 0)
    }
}
