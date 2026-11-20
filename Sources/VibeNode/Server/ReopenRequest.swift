import Foundation
import VibeCore

// MARK: session.reopen

extension Requests {
    /// `session.reopen` with `all` (true), or `sessions` (each one's id as `status`'s `reopen` lists it, its host id, or a
    /// prefix of 4 or more of that id that only one offered session has), or `forget` (true) (the stability lane,
    /// 2026-11-20; the app's restart card for your own sessions, `SessionReopen.swift`): after a host restart, the user's
    /// own sessions it ended reopened in their same conversations, as the app's Reopen and Choose reopen them, or the
    /// offer put away. A user's-voice kind, recorded in the vault before it gets here.
    ///
    /// Each chosen session leaves the offer before anything starts (two asks never start one twice) and is checked
    /// off the queue (`LeadEngine.reopenable`: the record is only a hint); one that checks out starts as an ordinary
    /// Claude session (the app's label and the node's `claude` link, never the record's), `--resume <its conversation>`
    /// in its folder, at its window's size, one after the other. One that doesn't start goes back on the offer, its
    /// reason in the reply. The reply lists what started (`reopened`) and what didn't (`refused`); none started is a
    /// refusal naming each reason.
    func reopenSessions(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server keeps no record of your sessions"))) }
        let offered = engine.offeredSessions
        guard !offered.isEmpty else {
            return reply(.init(re: request.id, error: .init(.gone, "no session host restart left sessions of yours to reopen")))
        }
        if request.args?["forget"]?.bool == true {
            let count = engine.forgetOffered()
            note("session.reopen: the offer of \(count) session(s) put away")
            return reply(.init(re: request.id, result: .object(["forgotten": .int(count)])))
        }
        let ids: Set<UUID>
        if request.args?["all"]?.bool == true {
            ids = Set(offered.map(\.id))
        } else {
            guard let wanted = request.args?["sessions"]?.array?.compactMap(\.string), !wanted.isEmpty else {
                return reply(.init(re: request.id, error: .init(.badArgs, "session.reopen needs all, sessions or forget")))
            }
            var chosen: Set<UUID> = []
            for given in wanted {
                let lowered = given.trimmingCharacters(in: .whitespaces).lowercased()
                let bare = lowered.hasPrefix(NodeIds.node + ":") ? String(lowered.dropFirst(NodeIds.node.count + 1)) : lowered
                let matching = bare.count >= 4 && bare.allSatisfy({ $0.isHexDigit || $0 == "-" })
                    ? offered.filter { $0.id.uuidString.lowercased().hasPrefix(bare) } : []
                guard matching.count == 1, let entry = matching.first else {
                    let shown = ConfigSeal.inert(given, limit: 80)
                    return reply(.init(re: request.id, error: .init(.badArgs, matching.isEmpty
                        ? "no session \(shown) is offered to reopen (`vibeswitcher reopen` lists them)"
                        : "\(matching.count) offered sessions start with \(shown): give more of its id")))
                }
                chosen.insert(entry.id)
            }
            ids = chosen
        }
        let taken = engine.takeOffered(ids)
        resume(taken, engine: engine, request: request, giveBack: { engine.offerAgain($0) }, reply: reply)
    }

    /// Each of `taken` (out of their list already, so a second ask can't start one twice) checked off the queue
    /// (`LeadEngine.reopenable`) and, when it checks out, started as an ordinary Claude session on the node's `claude`,
    /// `--resume <its conversation>` in its folder at its window's size, one after the other; those that didn't start go
    /// to `giveBack`. The reply lists what started (`reopened`) and what didn't (`refused`); none started is a refusal
    /// naming each reason. On `queue`.
    func resume(_ taken: [RestartReopen.Entry], engine: LeadEngine, request: NodeWire.Request,
                giveBack: @escaping ([RestartReopen.Entry]) -> Void, reply: @escaping (NodeWire.Reply) -> Void) {
        let (home, claudeLink) = (engine.home, engine.preflight.claudeLink)
        let environment = VibePaths.isAccountRoot(root, accountHome: VibePaths.accountHome) ? [:] : ["VIBESWITCHER_HOME": root.path]
        let (link, queue, note) = (self.link, self.queue, self.note)
        // Off the queue: the folders, the transcripts and the link are read from the disk.
        DispatchQueue.global(qos: .userInitiated).async {
            let program = NodePreflight.resolve(claudeLink)
            let checked = taken.map { entry -> (RestartReopen.Entry, Result<LeadEngine.Reopening, LeadEngine.Refused>) in
                guard program.path != nil else { return (entry, .failure(.init(program.why ?? "no claude for this node"))) }
                return (entry, LeadEngine.reopenable(entry, home: home))
            }
            queue.async {
                let run = ReopenRun()
                func finish() {
                    giveBack(run.back)
                    note("session.reopen: \(run.reopened.count) reopened, \(run.refused.count) not")
                    guard !run.reopened.isEmpty else {
                        let why = run.refused.compactMap { $0["why"]?.string }.joined(separator: "; ")
                        return reply(.init(re: request.id, error: .init(.refused, "nothing reopened: " + why)))
                    }
                    reply(.init(re: request.id, result: .object(["reopened": .array(run.reopened), "refused": .array(run.refused)])))
                }
                func next(_ index: Int) {
                    guard index < checked.count else { return finish() }
                    let (entry, result) = checked[index]
                    let was = NodeIds.session(host: entry.id)
                    func refuse(_ why: String) {
                        run.back.append(entry)
                        run.refused.append(.object(["was": .string(was), "folder": .string(entry.folder), "why": .string(why)]))
                        next(index + 1)
                    }
                    let plan: LeadEngine.Reopening
                    switch result {
                    case .failure(let refused): return refuse(refused.description)
                    case .success(let found): plan = found
                    }
                    guard let path = program.path else { return refuse(program.why ?? "no claude for this node") }
                    let spawn = SpawnRequest(cwd: plan.folder, command: Self.claudeCommand(program: path, model: plan.model, resume: plan.conversation),
                                             env: environment, cols: plan.cols, rows: plan.rows, keepShell: false,
                                             label: Self.sessionLabels["claude"] ?? "Claude", agent: "claude")
                    link.spawn(spawn) { started in
                        queue.async {
                            switch started {
                            case .success(let session):
                                note("session.reopen: conversation \(plan.conversation.prefix(8)) reopened in session \(session.id.uuidString.prefix(8)) (\(session.tty))")
                                run.reopened.append(.object([
                                    "was": .string(was), "folder": .string(plan.folder), "conversation": .string(plan.conversation),
                                    "session": .string(NodeIds.session(host: session.id)), "terminal": .string(session.tty),
                                ]))
                                next(index + 1)
                            case .failure(let failure):
                                refuse("the session host didn't start it: \(failure.message)")
                            }
                        }
                    }
                }
                next(0)
            }
        }
    }

    /// One reopen's outcome so far, on `queue`.
    private final class ReopenRun: @unchecked Sendable {
        var reopened: [NodeWire.Value] = []
        var refused: [NodeWire.Value] = []
        var back: [RestartReopen.Entry] = []
    }
}

// MARK: session.resume

extension Requests {
    /// `session.resume` with `session` (an ended session's id as `status`'s `ended` lists it, its host id, or a prefix
    /// of 4 or more of that id that only one ended session has) (the stability lane, 2026-11-20; the app's ended
    /// sessions' Resume): the user's own session that ended lately, started again in its same conversation as `reopen`
    /// starts one (`resume`: checked as a hint, the node's `claude` with `--resume`). The user's voice, recorded. One that
    /// doesn't start goes back on the list.
    func resumeSession(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server keeps no record of your sessions"))) }
        guard let given = request.args?["session"]?.string?.trimmingCharacters(in: .whitespaces).lowercased(), !given.isEmpty else {
            return reply(.init(re: request.id, error: .init(.badArgs, "session.resume needs session")))
        }
        let bare = given.hasPrefix(NodeIds.node + ":") ? String(given.dropFirst(NodeIds.node.count + 1)) : given
        let matching = bare.count >= 4 && bare.allSatisfy({ $0.isHexDigit || $0 == "-" })
            ? engine.endedSessions.filter { $0.entry.id.uuidString.lowercased().hasPrefix(bare) } : []
        guard matching.count == 1, let entry = matching.first.flatMap({ engine.takeEnded($0.entry.id) }) else {
            let shown = ConfigSeal.inert(given, limit: 80)
            return reply(.init(re: request.id, error: .init(matching.isEmpty ? .gone : .badArgs, matching.isEmpty
                ? "no ended session \(shown) of yours to resume (`vibeswitcher resume` lists them)"
                : "\(matching.count) ended sessions start with \(shown): give more of its id")))
        }
        resume([entry], engine: engine, request: request, giveBack: { engine.endedAgain($0) }, reply: reply)
    }
}

