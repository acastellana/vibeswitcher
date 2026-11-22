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
        switch client.read(WireKinds.Board.self, .init(folder: folder)) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, let raw):
            let boards = result.boards ?? []
            if json {
                Say.out(String(decoding: NodeWire.printable(NodeWire.line(raw)).dropLast(), as: UTF8.self))
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
