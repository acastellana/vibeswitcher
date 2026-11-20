import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher reopen [all | SESSION… | --forget]` (the stability lane, 2026-11-20; the app's restart card for your
/// own sessions): after a session host restart (a reboot), the user's own Claude sessions it ended, listed with no
/// argument; `all` or the sessions named reopen each in its same conversation (`claude --resume <id>` in its folder),
/// `--forget` puts the offer away. Each change is the user's voice, as `new` is: what it does shown (inert), the typed
/// code, then `session.reopen`; the server records it in the vault and checks each session's record before it starts
/// anything. Journaled as the other requests are (ids only).
enum ReopenCommand {
    static let usage = "usage: vibeswitcher reopen [all | SESSION... | --forget]  (no argument: lists the sessions a host restart ended)"

    static func run(_ arguments: [String]) -> Int32 {
        let forget = arguments == ["--forget"], all = arguments == ["all"]
        guard forget || all || arguments.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("--") && $0 != "all" }) else { return Say.usage(usage) }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let offered: [NodeWire.Value]
        switch client.request("status") {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            offered = result["reopen"]?.array ?? []
        }
        guard !arguments.isEmpty else {
            guard !offered.isEmpty else {
                Say.out("nothing to reopen: no session host restart ended sessions of yours that weren't reopened since")
                return 0
            }
            Say.out("ended with the last session host restart:")
            offered.forEach { Say.out("  " + line($0)) }
            Say.out("`vibeswitcher reopen all` reopens them, `vibeswitcher reopen SESSION...` those named, each in its same conversation; "
                + "`vibeswitcher reopen --forget` puts the offer away")
            return 0
        }
        guard !offered.isEmpty else { return Say.refused("no session host restart left sessions of yours to reopen") }
        let chosen: [NodeWire.Value]
        if all || forget {
            chosen = offered
        } else {
            var picked: [NodeWire.Value] = []
            for given in arguments {
                let bare = given.lowercased().replacingOccurrences(of: NodeIds.node + ":", with: "")
                let matching = bare.count >= 4 ? offered.filter { short(full: $0).hasPrefix(bare) } : []
                guard matching.count == 1 else {
                    return Say.refused(matching.isEmpty ? "no session \(ConfigSeal.inert(given, limit: 80)) is offered to reopen (`vibeswitcher reopen` lists them)"
                                                        : "\(ConfigSeal.inert(given, limit: 80)) begins \(matching.count) offered sessions' ids: give more of it")
                }
                picked += matching
            }
            chosen = picked
        }
        let what = forget
            ? "This puts away the offer to reopen \(chosen.count) session\(chosen.count == 1 ? "" : "s") (they stay in Claude's history):\n"
                + chosen.map { "  " + line($0) }.joined(separator: "\n")
            : "This reopens, as you, each in its same conversation (Claude with --resume, in its folder):\n"
                + chosen.map { "  " + line($0) }.joined(separator: "\n")
        let action = UUID().uuidString.lowercased()
        let outcome = TypedWord.ask(code: NodeIds.code(action: action), what: what)
        guard outcome == .typed else { return Say.refused(TypedWord.refusal(outcome)) }
        let args: [String: NodeWire.Value] = forget ? ["forget": .bool(true)]
            : all ? ["all": .bool(true)] : ["sessions": .array(chosen.compactMap { $0["session"] })]
        switch client.request("session.reopen", args: args, action: action, timeout: 180) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            if reply.ok || reply.error?.code == NodeWire.Code.refused.rawValue {
                context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: "session.reopen", epoch: client.hello.epoch))
            }
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            if forget {
                Say.out("put away: the offer to reopen \(result["forgotten"]?.int ?? 0) session(s)")
                return 0
            }
            for started in result["reopened"]?.array ?? [] {
                let id = SessionCommand.short(started["session"]?.string)
                Say.out("reopened: \(ConfigSeal.inert(started["folder"]?.string ?? "?", limit: 200)) in session \(id) on "
                    + "\(ConfigSeal.inert(started["terminal"]?.string ?? "?", limit: 20)), conversation "
                    + "\(ConfigSeal.inert(started["conversation"]?.string ?? "?", limit: 40)) (`vibeswitcher send \(id) TEXT` types into it)")
            }
            let refused = result["refused"]?.array ?? []
            for failed in refused {
                Say.err("not reopened: \(ConfigSeal.inert(failed["why"]?.string ?? "?", limit: 400)) (still offered)")
            }
            return refused.isEmpty ? 0 : 77
        }
    }

    /// An offered session's host id, lowercased, without the node's prefix.
    private static func short(full value: NodeWire.Value) -> String {
        (value["session"]?.string ?? "").lowercased().replacingOccurrences(of: NodeIds.node + ":", with: "")
    }

    /// An offered session in a line: its id, name, folder and conversation, all inert.
    static func line(_ value: NodeWire.Value) -> String {
        let conversation = value["conversation"]?.string.map { "conversation \(ConfigSeal.inert($0, limit: 40))" }
            ?? "its conversation id wasn't known: it can't be reopened"
        return "\(SessionCommand.short(value["session"]?.string))  \(ConfigSeal.inert(value["name"]?.string ?? "?", limit: 60)) in "
            + "\(ConfigSeal.inert(value["folder"]?.string ?? "?", limit: 200))  (\(conversation))"
    }
}
