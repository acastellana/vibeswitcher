import Foundation
import VibeCore

/// The node's logs as `vibeswitcher logs` reads them (Sources/vibeswitcher-cli/Logs.swift asks these, so the command line
/// and the `logs` kind read the same files the same way and mask each line with the same code, `masked`):
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
    /// (no control character, no terminal escape, at most 1000 characters). The one masking of every log line shown.
    public static func masked(_ text: String) -> String { ConfigSeal.inert(Redaction.secrets(in: text), limit: 1000) }

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
        return .success(lines.suffix(count).map(masked))
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
        return .success(entries.suffix(count).map { entry in
            masked((entry.time.map { stamp.string(from: $0) + " " } ?? "") + (entry.message ?? ""))
        })
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
