import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher board [FOLDER] [--json]` (the parity table's gap 4): the board of the lead whose project holds FOLDER,
/// or every lead's board without one, as `BoardText` prints it (one short line a task, grouped, a count line), or as
/// the server's JSON. A read: anyone of the uid, no code; nothing on a board changes. A folder with no lead is refused,
/// saying how to start one.
enum BoardCommand {
    static let usage = "usage: vibeswitcher board [FOLDER] [--json]"

    static func run(_ arguments: [String]) -> Int32 {
        var folder: String?
        var json = false
        for word in arguments {
            switch word {
            case "--json": json = true
            default:
                guard folder == nil, !word.hasPrefix("--") else { return Say.usage(usage) }
                folder = CardCommand.absolute(word)
            }
        }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        var args: [String: NodeWire.Value] = [:]
        if let folder { args["folder"] = .string(folder) }
        switch client.request("board", args: args) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let boards = reply.result?["boards"]?.array else { return Say.replyError(reply) }
            if json {
                Say.out(String(decoding: NodeWire.printable(NodeWire.line(reply.result ?? .null)).dropLast(), as: UTF8.self))
                return 0
            }
            if boards.isEmpty { Say.out("no lead on this node: `vibeswitcher lead FOLDER` starts one") }
            for (index, board) in boards.enumerated() {
                if index > 0 { Say.out("") }
                BoardText.lines(board, home: ProcessInfo.processInfo.environment["HOME"]).forEach(Say.out)
            }
            return 0
        }
    }
}
