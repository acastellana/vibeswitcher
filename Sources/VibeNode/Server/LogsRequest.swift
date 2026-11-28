import Foundation
import VibeCore

/// The node's logs as `vibeswitcher logs` reads them (Sources/vibeswitcher-cli/Logs.swift asks these, so the command line
/// and the `logs` kind read the same files the same way and mask their lines with the same code, `masked`):
/// - the server's and the host's log (their stderr): the node unit's journal (`journalctl --user -u UNIT`, its fixed
///   path and the tools' environment; a scratch node's stand-in `<root>/v2/test/journalctl`), or the detached host's
///   `<root>/v2/host.log` where pid 1 isn't systemd;
/// - the host's session log (`sessions`): `<root>/debug/host.log`, a scratch node's `<root>/host.log`.
public enum NodeLogs {
    public static let defaultLines = 40
    public static let maxLines = 2000
    /// The most of a log's end read for its last lines.
    public static let tailBytes = 512 * 1024

    /// One line of a log as anything outside the node may see it: its secrets masked (`Redaction.secrets`), then inert
    /// (no control character, no terminal escape, at most 1000 characters). The one masking of every log line shown,
    /// with `masked(_:last:)`, which a log's lines go through.
    public static func masked(_ text: String) -> String { ConfigSeal.inert(Redaction.secrets(in: text), limit: 1000) }

    /// A log's last `count` lines as anything outside the node may see them: each `masked`, and a private key printed
    /// over several lines (PEM, PGP: from a `-----BEGIN … PRIVATE KEY-----` line through its `-----END … PRIVATE
    /// KEY-----` line) masked whole, as `Redaction.secrets` masks it in one text (the review's P-C8-1: each line masked
    /// alone left the key's body). A line that begins inside a key shows `•••` for it, then what follows its END line's
    /// label, masked: so each line of the key's body is `•••`, and its BEGIN and END lines are masked as before. A key
    /// with no END masks every line after it; lines before an END with no BEGIN above it (a key whose start was cut off)
    /// are masked too. The lines before the last `count` are read only for where a key begins.
    public static func masked(_ lines: [String], last count: Int) -> [String] {
        var inside = KeyBlock.startsInside(lines)
        let first = max(0, lines.count - max(0, count))
        for line in lines[..<first] { inside = KeyBlock.scan(line, inside: inside).inside }
        return lines[first...].map { line in
            let scanned = KeyBlock.scan(line, inside: inside)
            defer { inside = scanned.inside }
            guard let rest = scanned.rest else { return masked(line) }
            return masked(Self.keyMask + rest)
        }
    }

    static let keyMask = "•••"

    /// Where a private key's block begins and ends in a log's lines, as `Redaction.privateKeys` and `keyEnd` find it in
    /// one text: `-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----` to the next `-----END <the same shape>`.
    enum KeyBlock {
        private static let begin = Array("-----BEGIN ".utf8), end = Array("-----END ".utf8), dashes = Array("-----".utf8)
        private static let name = Array("PRIVATE KEY".utf8), blockName = Array("PRIVATE KEY BLOCK".utf8)

        /// The labels in `text`, in order: whether each is an END, and where it ends (a UTF-8 offset).
        static func labels(_ text: String) -> [(isEnd: Bool, end: Int)] {
            guard text.contains("-----") else { return [] }
            let u = Array(text.utf8)
            var found: [(Bool, Int)] = []
            var i = 0
            while i + 5 <= u.count {
                if u[i] == 45, let (isEnd, stop) = label(u, i) {
                    found.append((isEnd, stop))
                    i = stop
                } else {
                    i += 1
                }
            }
            return found
        }

        private static func has(_ word: [UInt8], _ u: [UInt8], at i: Int) -> Bool {
            i >= 0 && i + word.count <= u.count && u[i..<(i + word.count)].elementsEqual(word)
        }

        private static func label(_ u: [UInt8], _ i: Int) -> (Bool, Int)? {
            let isEnd: Bool
            if has(begin, u, at: i) { isEnd = false } else if has(end, u, at: i) { isEnd = true } else { return nil }
            let from = i + (isEnd ? end.count : begin.count)
            var j = from
            while j < u.count && ((65...90).contains(u[j]) || (48...57).contains(u[j]) || u[j] == 32) { j += 1 }
            guard (j - from >= name.count && has(name, u, at: j - name.count))
                    || (j - from >= blockName.count && has(blockName, u, at: j - blockName.count)),
                  has(dashes, u, at: j) else { return nil }
            return (isEnd, j + dashes.count)
        }

        /// Whether the lines begin inside a key: their first label is an END (its BEGIN was before them).
        static func startsInside(_ lines: [String]) -> Bool {
            for line in lines { if let first = labels(line).first { return first.isEnd } }
            return false
        }

        /// `line` read on from `inside` (whether a key's block is open at its start): whether one is open at its end,
        /// and, when it began inside one, what follows the label of the END that closes it ("" when none does).
        static func scan(_ line: String, inside: Bool) -> (inside: Bool, rest: String?) {
            var open = inside
            var closedAt: Int?
            for found in labels(line) {
                if open, found.isEnd {
                    open = false
                    if inside, closedAt == nil { closedAt = found.end }
                } else if !open, !found.isEnd {
                    open = true
                }
            }
            guard inside else { return (open, nil) }
            guard let closedAt else { return (open, "") }
            return (open, String(decoding: Array(line.utf8)[closedAt...], as: UTF8.self))
        }
    }

    /// The file's last `count` lines (of its last `tailBytes`), each `masked`, never through a link; why not when it
    /// can't be read ("not there yet", "couldn't be read …"). Only a regular file is read: opened without waiting (a
    /// FIFO in its place would hold the read until a writer came: the review's N-C8-1), anything else refused.
    public static func tail(_ path: String, lines count: Int) -> Result<[String], NodeFacts.Failure> {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return .failure(.init(errno == ENOENT ? "not there yet" : "couldn't be read: errno \(errno)")) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var facts = stat()
        guard fstat(fd, &facts) == 0, (facts.st_mode & S_IFMT) == S_IFREG else { return .failure(.init("couldn't be read: it isn't a file")) }
        guard let size = try? handle.seekToEnd() else { return .failure(.init("couldn't be read")) }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // A partial first line when the read began mid-file.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return .success(masked(lines, last: count))
    }

    /// The node unit's journal lines, newest last, each `masked` and stamped: `journalctl --user -u UNIT -n N -o json`,
    /// through `run` (the program by its path, with the tools' environment); the command line's own entries left out.
    public static func journal(_ journalctl: String?, lines count: Int, uid: uid_t = getuid(),
                               run: (String, [String]) -> (status: Int32, output: String)?) -> Result<[String], NodeFacts.Failure> {
        guard let journalctl else { return .failure(.init("scratch node: no journal, no manager")) }
        let arguments = ["--user", "-o", "json", "--no-pager", "-n", String(count), "-u", VoiceRule.nodeUnit, "_UID=\(uid)"]
        guard let ran = run(journalctl, arguments), ran.status == 0 else { return .failure(.init("journalctl --user didn't answer")) }
        let stamp = ISO8601DateFormatter()
        let entries = NodeJournal.entries(json: ran.output).filter { $0.identifier != NodeJournal.identifier }
        // Stamped first: a stamp holds no key's label, so the key's lines are found as in the messages alone.
        return .success(masked(entries.map { entry in (entry.time.map { stamp.string(from: $0) + " " } ?? "") + (entry.message ?? "") }, last: count))
    }

    /// The host's session log: the user's host writes `<VibePaths.root>/debug/host.log` (`vibeswitcher-host`'s `--log`
    /// default), a scratch node's host the `--log` its test gave (`<root>/host.log`).
    public static func sessionLog(root: URL, scratch: Bool) -> String {
        scratch ? root.appendingPathComponent("host.log").path : VibePaths.root.appendingPathComponent("debug/host.log").path
    }

    /// Where the server's and the host's log is for the node at `root`, as the command line finds it (`NodeContext`):
    /// a scratch node's journal stand-in, the user's node's journal, or the detached host's file.
    public enum Place: Equatable, Sendable {
        case journal(journalctl: String?, environment: [String]?)
        case file(String)
    }

    /// The place for the server's own node: a scratch node when `root` isn't the user's node's (`NodeFolders.isUsersRoot`),
    /// its stand-in if its test made one; the user's node's file when it was started detached (pid 1 isn't systemd), else
    /// its journal by the system's `journalctl` with the tools' environment.
    public static func place(root: URL, accountHome: String = VibePaths.accountHome, uid: uid_t = getuid()) -> (place: Place, scratch: Bool) {
        if !NodeFolders.isUsersRoot(root, accountHome: accountHome) {
            let standIn = root.appendingPathComponent("v2/test/journalctl").path
            return (.journal(journalctl: FileManager.default.isExecutableFile(atPath: standIn) ? standIn : nil, environment: nil), true)
        }
        if let runtime = Platform.Service.runtimeFolder(uid: uid), NodeFolders.mode(runtimeFolder: runtime) == .noSystemd {
            return (.file(NodeStarter.hostLog(root: root.path)), false)
        }
        return (.journal(journalctl: Platform.Service.journalctl, environment: NodeStarter.environment(runtimeFolder: NodeFolders.runtimeFolder(uid: uid))), false)
    }

    // MARK: The `logs` kind

    /// The most lines a page asks for (`logs`' `lines`), and the default.
    public static let pageLines = 500
    public static let pageDefault = 200
    /// The most bytes of lines a `logs` reply carries: its oldest lines go first past it (`cut` says how many).
    public static let replyBytes = 192 * 1024
    /// The most `logs` reads a node runs at once.
    public static let readsInFlight = 4

    /// `logs` with `lines` (1…`pageLines`, `pageDefault` when absent) and `sessions`: what `vibeswitcher logs [--lines N]
    /// [--sessions]` prints of them, each line `masked`, at most `replyBytes` of lines (the oldest dropped first); `why`
    /// when the log can't be read.
    static func read(_ args: WireKinds.Logs.Args, root: URL, place: Place, scratch: Bool,
                            run: (String, [String], [String]?) -> (status: Int32, output: String)?) -> Result<WireKinds.Logs.Result, Requests.ReadRefusal> {
        let count = args.lines ?? pageDefault
        guard (1...pageLines).contains(count) else { return .failure(Requests.ReadRefusal(.badArgs, "logs' lines is from 1 to \(pageLines)")) }
        let sessions = args.sessions == true
        let read: Result<[String], NodeFacts.Failure>
        if sessions {
            read = tail(sessionLog(root: root, scratch: scratch), lines: count)
        } else {
            switch place {
            case .file(let path): read = tail(path, lines: count)
            case .journal(let journalctl, let environment):
                read = journal(journalctl, lines: count) { program, arguments in run(program, arguments, environment) }
            }
        }
        switch read {
        case .failure(let why): return .success(.init(log: sessions ? "sessions" : "node", lines: [], cut: 0, why: why.reason))
        case .success(var lines):
            var cut = 0
            var bytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
            while bytes > replyBytes, !lines.isEmpty {
                bytes -= lines.removeFirst().utf8.count + 1
                cut += 1
            }
            return .success(.init(log: sessions ? "sessions" : "node", lines: lines, cut: cut, why: nil))
        }
    }
}

extension Requests {
    /// `logs` (the no-terminal inventory's C8, 2026-11-26): `NodeLogs.read` for this node, off the server's queue (a
    /// journal's read runs a program), answered on it. A read of the user's: the user on the socket or a page with its
    /// read right (`webRead`), never a session's process. At most `NodeLogs.readsInFlight` at once (the review's N-C8-3:
    /// each may run `journalctl` for up to 10 s); one past them is refused, nothing read.
    func logs(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let args: WireKinds.Logs.Args
        switch request.typedArgs(WireKinds.Logs.Args.self) {
        case .failure(let failure): return reply(.init(re: request.id, error: failure))
        case .success(let typed): args = typed
        }
        guard logReads < NodeLogs.readsInFlight else {
            return reply(.init(re: request.id, error: .init(.refused, "\(NodeLogs.readsInFlight) reads of the logs are under way already: ask again once one has answered")))
        }
        logReads += 1
        let (root, queue) = (self.root, self.queue)
        DispatchQueue.global(qos: .userInitiated).async {
            let (place, scratch) = NodeLogs.place(root: root)
            let read = NodeLogs.read(args, root: root, place: place, scratch: scratch) { program, arguments, environment in
                NodeStarter.run(program, arguments, environment: environment, timeout: 10)
            }
            queue.async {
                self.logReads -= 1
                switch read {
                case .failure(let refusal): reply(.init(re: request.id, error: refusal.failure))
                case .success(let result): reply(.init(re: request.id, typed: result))
                }
            }
        }
    }
}
