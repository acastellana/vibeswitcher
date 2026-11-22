import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher logs [--lines N] [--sessions]` (the parity table's Logs row; the app's Debug › Open Log): the node's
/// logs' last lines, from the command line's own reads, nothing asked of the server (a server that won't start still
/// has them), and where each is kept.
/// - The server's and the host's log (their stderr): the node unit's journal on a systemd machine (`journalctl --user
///   -u vibeswitcher-node.service`, its fixed path and the tools' environment, as `status` reads it), the detached
///   host's `<root>/v2/host.log` where pid 1 isn't systemd.
/// - With `--sessions`, the host's session log (`<root>/debug/host.log`, a scratch node's `<root>/host.log`): each
///   session started and how it ended, each kill, with the client that asked; its secrets masked as it was written.
/// Every line printed inert, its secrets masked again.
enum LogsCommand {
    static let usage = "usage: vibeswitcher logs [--lines N] [--sessions]"
    static let defaultLines = 40
    static let maxLines = 2000
    /// The most of a log's end read for its last lines.
    static let tailBytes = 512 * 1024

    struct Asked: Equatable {
        var lines = LogsCommand.defaultLines
        var sessions = false
    }

    static func parse(_ arguments: [String]) -> Asked? {
        var asked = Asked()
        var words = arguments[...]
        while let word = words.popFirst() {
            switch word {
            case "--lines":
                guard let value = words.popFirst().flatMap(Int.init), (1...maxLines).contains(value) else { return nil }
                asked.lines = value
            case "--sessions": asked.sessions = true
            default: return nil
            }
        }
        return asked
    }

    static func run(_ arguments: [String]) -> Int32 {
        guard let asked = parse(arguments) else { return Say.usage(usage) }
        let context = NodeContext.current()
        context.sayScratch()
        var where_: [String] = []
        if asked.sessions {
            let path = sessionLog(context)
            Say.out("the host's session log, its last \(asked.lines) lines:")
            print(tail(path, lines: asked.lines))
            where_.append("the host's session log: \(shown(path)) (and \(shown(path)).1, the one before)")
        } else {
            switch context.mode {
            case .detached:
                let path = NodeStarter.hostLog(root: context.root.path)
                Say.out("the server's and the host's log, its last \(asked.lines) lines:")
                print(tail(path, lines: asked.lines))
                where_.append("the server's and the host's log: \(shown(path))")
            case .node, .scratch:
                Say.out("the server's and the host's log (the node unit's journal), its last \(asked.lines) lines:")
                switch journal(context, lines: asked.lines) {
                case .success(let lines): print(lines.isEmpty ? ["  (none)"] : lines)
                case .failure(let why): Say.out("  (\(why))")
                }
                where_.append("the server's and the host's log: `journalctl --user -u \(VoiceRule.nodeUnit)`")
            }
            where_.append("the host's session log: `vibeswitcher logs --sessions` (\(shown(sessionLog(context))))")
        }
        where_.append("the server's last errors and their causes: `vibeswitcher status --health`")
        Say.out("where:")
        for line in where_ { Say.out("  " + line) }
        return 0
    }

    private static func print(_ lines: [String]) { for line in lines { Say.out(line) } }
    private static func shown(_ path: String) -> String { ConfigSeal.inert(path, limit: 400) }

    /// The host's session log: the user's host writes `<root>/debug/host.log` (`vibeswitcher-host`'s `--log` default),
    /// a scratch node's host the `--log` its test gave (`<root>/host.log`).
    static func sessionLog(_ context: NodeContext) -> String {
        context.isScratch ? context.root.appendingPathComponent("host.log").path : VibePaths.root.appendingPathComponent("debug/host.log").path
    }

    /// One line printed: inert, its secrets masked.
    static func line(_ text: String) -> String { "  " + ConfigSeal.inert(Redaction.secrets(in: text), limit: 1000) }

    /// The file's last `lines` lines (of its last `tailBytes`), never through a link; why not, as a line, when it can't
    /// be read.
    static func tail(_ path: String, lines count: Int) -> [String] {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return ["  (\(errno == ENOENT ? "not there yet" : "couldn't be read: errno \(errno)"))"] }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let size = try? handle.seekToEnd() else { return ["  (couldn't be read)"] }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // A partial first line when the read began mid-file.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        let last = lines.suffix(count)
        return last.isEmpty ? ["  (empty)"] : last.map(line)
    }

    /// The node unit's journal lines, newest last: `journalctl --user -u UNIT -n N -o json` (a scratch node's stand-in).
    static func journal(_ context: NodeContext, lines count: Int) -> Result<[String], NodeFacts.Failure> {
        guard let journalctl = context.journalctl else { return .failure(.init(NodeContext.noStandIn)) }
        let arguments = ["--user", "-o", "json", "--no-pager", "-n", String(count), "-u", VoiceRule.nodeUnit, "_UID=\(getuid())"]
        guard let ran = context.runTool(journalctl, arguments), ran.status == 0 else { return .failure(.init("journalctl --user didn't answer")) }
        let stamp = ISO8601DateFormatter()
        let entries = NodeJournal.entries(json: ran.output).filter { $0.identifier != NodeJournal.identifier }
        return .success(entries.suffix(count).map { entry in
            line((entry.time.map { stamp.string(from: $0) + " " } ?? "") + (entry.message ?? ""))
        })
    }
}
