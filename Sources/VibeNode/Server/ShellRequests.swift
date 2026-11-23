import Foundation
import VibeCore

// MARK: shells, session.close-shells

extension Requests {
    /// A shell session the node's host runs that Close Finished Shells takes: no agent (`HostedAgents`), started as the
    /// app's built-in Shell (`vibeswitcher new --agent shell`) or by an agent's Run card (`ShellTidy.opened`), never a
    /// lead's or its team's.
    static func isNodeShell(_ session: HostSession) -> Bool {
        session.isLive && session.agent == nil && LeadTeams.role(label: session.label) == nil
            && (session.label == sessionLabels["shell"] || ShellTidy.opened(session))
    }

    /// Whether `session`'s shell is finished: back at its prompt (`ShellTidy.idle`: nothing it runs holds the terminal),
    /// and for a Run card's, its command ended (`ShellTidy.finished`). Off the engine's queue (it reads /proc).
    static func shellFinished(_ session: HostSession) -> Bool {
        ShellTidy.opened(session) ? !ShellTidy.finished([session]).isEmpty : ShellTidy.idle(session)
    }

    /// `shells` with `folder` (optional, absolute: the shells started in it or below) (the stability lane, 2026-11-20): the
    /// node's shell sessions (`isNodeShell`), each with its id, folder, terminal and whether it's `finished`
    /// (`shellFinished`). A read of the user's (no code): nothing changes.
    func shells(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let folder: String?
        switch request.typedArgs(WireKinds.Shells.Args.self) {
        case .failure(let failure): return reply(.init(re: request.id, error: failure))
        case .success(let typed): folder = typed.folder.map { ($0 as NSString).standardizingPath }
        }
        let found = link.sessions.filter(Self.isNodeShell).filter { session in
            folder.map { session.cwd == $0 || session.cwd.hasPrefix($0 + "/") } ?? true
        }
        let queue = self.queue
        DispatchQueue.global(qos: .userInitiated).async {
            let shells = found.map { session in
                WireKinds.Shells.Shell(session: NodeIds.session(host: session.id), folder: session.cwd, terminal: session.tty, finished: Self.shellFinished(session))
            }
            queue.async { reply(.init(re: request.id, typed: WireKinds.Shells.Result(shells: shells))) }
        }
    }

    /// `session.close-shells` with `sessions` (the node's ids of the shells the user was shown as finished) (the stability
    /// lane, 2026-11-20; the app's Close Finished Shells…): each of them still a finished shell of the node's
    /// (`isNodeShell`, `shellFinished`, read again right before) is ended, with whatever it left running; any other is
    /// left, and said. The reply comes once those ended are gone (at most `endWait`). The user's voice, recorded.
    func closeShells(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let wanted = request.args?["sessions"]?.array?.compactMap(\.string), !wanted.isEmpty else {
            return reply(.init(re: request.id, error: .init(.badArgs, "session.close-shells needs sessions, the shells shown")))
        }
        let byID = Dictionary(link.sessions.map { (NodeIds.session(host: $0.id), $0) }, uniquingKeysWith: { $1 })
        let candidates = wanted.compactMap { byID[$0] }.filter(Self.isNodeShell)
        let (link, queue, note) = (self.link, self.queue, self.note)
        DispatchQueue.global(qos: .userInitiated).async {
            let finished = candidates.filter(Self.shellFinished)
            queue.async {
                let ending = Set(finished.map(\.id))
                let left = wanted.filter { id in !finished.contains { NodeIds.session(host: $0.id) == id } }
                guard !ending.isEmpty else {
                    return reply(.init(re: request.id, error: .init(.refused, "none of them is a finished shell now (back at its prompt): nothing ended")))
                }
                let waiting = Waiting()
                let finish = {
                    guard !waiting.answered else { return }
                    waiting.answered = true
                    waiting.watch = nil
                    let gone = ending.filter { id in !link.sessions.contains { $0.id == id && $0.isLive } }
                    reply(.init(re: request.id, typed: WireKinds.CloseShells.Result(
                        ended: gone.sorted { $0.uuidString < $1.uuidString }.map { NodeIds.session(host: $0) }, left: left)))
                }
                let allGone = { ending.allSatisfy { id in !link.sessions.contains { $0.id == id && $0.isLive } } }
                waiting.watch = link.changes.subscribe(on: queue) { _ in if allGone() { finish() } }
                queue.asyncAfter(deadline: .now() + Self.endWait) { finish() }
                note("session.close-shells: ending \(ending.count) finished shell(s)")
                for id in ending { link.kill(id) }
            }
        }
    }
}
