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
                switch SessionLookup.match(given, in: offered, idKey: "session", hostedOnly: false, noun: "session offered to reopen",
                                           listed: "`vibeswitcher reopen` lists them") {
                case .failure(let why): return Say.refused(why.description)
                case .success(let found): picked.append(found)
                }
            }
            chosen = picked
        }
        let what = forget
            ? "This puts away the offer to reopen \(chosen.count) session\(chosen.count == 1 ? "" : "s") (they stay in Claude's history):\n"
                + chosen.map { "  " + line($0) }.joined(separator: "\n")
            : "This reopens, as you, each in its same conversation (Claude with --resume, in its folder):\n"
                + chosen.map { "  " + line($0) }.joined(separator: "\n")
        let action = UUID().uuidString.lowercased()
        let outcome = TypedWord.ask(approval: client.approvalRule, code: NodeIds.code(action: action), what: what)
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
                Say.out("reopened: \(ConfigSeal.inert(started["folder"]?.string ?? "?", limit: .max)) in session \(id) on "
                    + "\(ConfigSeal.inert(started["terminal"]?.string ?? "?", limit: 20)), conversation "
                    + "\(ConfigSeal.inert(started["conversation"]?.string ?? "?", limit: 40)) (`vibeswitcher send \(id) TEXT` types into it)")
            }
            let refused = result["refused"]?.array ?? []
            for failed in refused {
                Say.err("not reopened: \(ConfigSeal.inert(failed["why"]?.string ?? "?", limit: .max)) (still offered)")
            }
            return refused.isEmpty ? 0 : 77
        }
    }

    /// An offered session in a line: its id, name, folder and conversation, all inert.
    static func line(_ value: NodeWire.Value) -> String {
        let conversation = value["conversation"]?.string.map { "conversation \(ConfigSeal.inert($0, limit: 40))" }
            ?? "its conversation id wasn't known: it can't be reopened"
        return "\(SessionCommand.short(value["session"]?.string))  \(ConfigSeal.inert(value["name"]?.string ?? "?", limit: 60)) in "
            + "\(ConfigSeal.inert(value["folder"]?.string ?? "?", limit: .max))  (\(conversation))"
    }
}

/// `vibeswitcher resume [SESSION]` (the stability lane, 2026-11-20; the app's ended sessions, Resume, Copy Resume Command
/// and Copy Session ID): with no SESSION, the user's own sessions that ended lately, each with its conversation id and
/// the command that resumes it by hand in a terminal; with one, that session started again in its same conversation on
/// the node (`session.resume`, the user's voice: shown, the typed code, then the request).
enum ResumeCommand {
    static let usage = "usage: vibeswitcher resume [SESSION]  (no SESSION: lists your sessions that ended lately)"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count <= 1, arguments.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("--") }) else { return Say.usage(usage) }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let ended: [NodeWire.Value], ending: [NodeWire.Value]
        switch client.request("status") {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            ended = result["ended"]?.array ?? []
            ending = result["ending"]?.array ?? []
        }
        guard let wanted = arguments.first else {
            guard !ended.isEmpty else {
                // One that ended within the grace isn't listed yet: said, with when it will be.
                if ending.isEmpty { Say.out("no session of yours ended lately") } else { ResumeText.endingLines(ending, now: Date()).forEach(Say.out) }
                return 0
            }
            Say.out("ended lately, newest first:")
            for session in ended {
                Say.out("  " + ReopenCommand.line(session) + "  ended \(ConfigSeal.inert(session["at"]?.string ?? "?", limit: 40))")
                if let conversation = session["conversation"]?.string {
                    Say.out("      by hand: cd \(RecentProjects.shellQuote(ConfigSeal.inert(session["folder"]?.string ?? "", limit: .max))) && claude --resume "
                        + RecentProjects.shellQuote(ConfigSeal.inert(conversation, limit: 40)))
                }
            }
            Say.out("`vibeswitcher resume SESSION` starts one again on the node, in its same conversation")
            return 0
        }
        let session: NodeWire.Value
        switch SessionLookup.match(wanted, in: ended, idKey: "session", hostedOnly: false, noun: "ended session",
                                   listed: "`vibeswitcher resume` lists yours") {
        case .failure(let why):
            if case .success = SessionLookup.match(wanted, in: ending, idKey: "session", hostedOnly: false, noun: "ended session", listed: "") {
                return Say.refused(ResumeText.endingLines(ending, now: Date()).joined(separator: "\n"))
            }
            return Say.refused(why.description)
        case .success(let found): session = found
        }
        let action = UUID().uuidString.lowercased()
        let outcome = TypedWord.ask(approval: client.approvalRule, code: NodeIds.code(action: action),
                                    what: "This starts again, as you, in its same conversation (Claude with --resume, in its folder):\n  " + ReopenCommand.line(session))
        guard outcome == .typed else { return Say.refused(TypedWord.refusal(outcome)) }
        switch client.request("session.resume", args: ["session": session["session"] ?? .string(wanted)], action: action, timeout: 180) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            if reply.ok || reply.error?.code == NodeWire.Code.refused.rawValue {
                context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: "session.resume", epoch: client.hello.epoch))
            }
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            for started in result["reopened"]?.array ?? [] {
                let id = SessionCommand.short(started["session"]?.string)
                Say.out("resumed: \(ConfigSeal.inert(started["folder"]?.string ?? "?", limit: .max)) in session \(id) on "
                    + "\(ConfigSeal.inert(started["terminal"]?.string ?? "?", limit: 20)) (`vibeswitcher send \(id) TEXT` types into it)")
            }
            return 0
        }
    }
}
