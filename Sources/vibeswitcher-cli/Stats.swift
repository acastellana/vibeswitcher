import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher stats [today|week|month] [--json]` (the parity table's Statistics row, 2026-11-21): the Mac's
/// Statistics window from the node, as `StatisticsText` prints it, or the server's JSON. A read: anyone of the uid, no
/// code; nothing changes. Seven days unless another range is named.
enum StatsCommand {
    static let usage = "usage: vibeswitcher stats [today|week|month] [--json]"

    static func run(_ arguments: [String]) -> Int32 {
        var range: String?
        var json = false
        for word in arguments {
            switch word {
            case "--json": json = true
            case "today", "week", "month":
                guard range == nil else { return Say.usage(usage) }
                range = word
            default: return Say.usage(usage)
            }
        }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        switch client.read(WireKinds.Stats.self, .init(range: range ?? "week")) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, let raw):
            if json {
                Say.out(String(decoding: NodeWire.printable(NodeWire.line(raw)).dropLast(), as: UTF8.self))
                return 0
            }
            StatisticsText.lines(result).forEach(Say.out)
            return 0
        }
    }
}
