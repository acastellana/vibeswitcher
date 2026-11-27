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
    static let defaultLines = NodeLogs.defaultLines
    static let maxLines = NodeLogs.maxLines

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

    /// The host's session log (`NodeLogs.sessionLog`, the page's `logs` read the same).
    static func sessionLog(_ context: NodeContext) -> String { NodeLogs.sessionLog(root: context.root, scratch: context.isScratch) }

    /// One line printed: indented, masked by `NodeLogs.masked` (the `logs` kind's masking, the same code).
    static func line(_ text: String) -> String { "  " + NodeLogs.masked(text) }

    /// The file's last `lines` lines (`NodeLogs.tail`), printed; why not, as a line, when it can't be read.
    static func tail(_ path: String, lines count: Int) -> [String] {
        switch NodeLogs.tail(path, lines: count) {
        case .failure(let why): return ["  (\(why.reason))"]
        case .success(let lines): return lines.isEmpty ? ["  (empty)"] : lines.map { "  " + $0 }
        }
    }

    /// The node unit's journal lines, newest last (`NodeLogs.journal`, by the context's tools).
    static func journal(_ context: NodeContext, lines count: Int) -> Result<[String], NodeFacts.Failure> {
        NodeLogs.journal(context.journalctl, lines: count, run: context.runTool).map { $0.map { "  " + $0 } }
    }
}
