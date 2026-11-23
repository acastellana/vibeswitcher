import Foundation
import VibeCore

// MARK: session.rename, session.pause

extension Requests {
    /// The session `id` names exactly (the node's whole id for it, as `status` lists it), or the reply that refuses it.
    private func listedSession(_ request: NodeWire.Request) -> (Session, SessionMarks)? {
        guard let sessions, let marks = sessions.marks, let id = request.args?["session"]?.string else { return nil }
        return sessions.sessions.first { NodeSessions.id(of: $0) == id }.map { ($0, marks) }
    }

    /// `session.ports` with `session` (the dev pages row, 2026-11-21): the TCP ports the session's processes listen on
    /// (`DevPorts`: its program and what it started, loopback or every address, 1024 and up, never the node's own),
    /// each with its address, the process and the page's address on this machine. A read (anyone, a page's token too):
    /// the kernel's tables and the uid's own processes' descriptors, read off `queue`; nothing is connected to.
    func sessionPorts(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let sessions, let id = request.args?["session"]?.string, let session = sessions.sessions.first(where: { NodeSessions.id(of: $0) == id }) else {
            let id = request.args?["session"]?.string ?? ""
            return reply(.init(re: request.id, error: .init(id.isEmpty ? .badArgs : .gone,
                                                            id.isEmpty ? "session.ports needs session" : "no session \(ConfigSeal.inert(id, limit: 80)) on this node")))
        }
        let hosted = session.hostID.flatMap { host in link.sessions.first { $0.id == host } }
        let root = hosted.map(\.childPID) ?? Int32(session.pid)
        let queue = self.queue
        DispatchQueue.global(qos: .userInitiated).async {
            let value = root > 0 ? DevPorts.value(DevPorts.listening(pids: DevPorts.processes(of: root))) : DevPorts.value([])
            queue.async { reply(.init(re: request.id, result: value)) }
        }
    }

    private func markRefusal(_ request: NodeWire.Request) -> NodeWire.Reply {
        guard sessions?.marks != nil else { return .init(re: request.id, error: .init(.refused, "this server keeps no names or pauses")) }
        guard let id = request.args?["session"]?.string, !id.isEmpty else { return .init(re: request.id, error: .init(.badArgs, "\(request.kind) needs session")) }
        return .init(re: request.id, error: .init(.gone, "no session \(ConfigSeal.inert(id, limit: 80)) on this node (`vibeswitcher status` lists them)"))
    }

    /// `session.rename` with `session` and `name` (none or blank: the automatic name back) (the stability lane,
    /// 2026-11-20; the app's Rename… and Reset Name): your name for the session, its headline everywhere, kept by its
    /// keys (`SessionMarks`) so it survives `--resume`. Any session the node lists (one in a terminal of yours too: a
    /// name types nothing). The user's voice, recorded. The reply names the session and the name kept (null: reset).
    func renameSession(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let (session, marks) = listedSession(request) else { return reply(markRefusal(request)) }
        let name = request.args?["name"]?.string
        do {
            let kept = try marks.rename(SessionMarks.keys(of: session), to: name)
            note("session.rename: session \(NodeSessions.id(of: session)) \(kept == nil ? "back to its own name" : "renamed")")
            sessions?.refresh()
            reply(.init(re: request.id, typed: WireKinds.SessionRename.Result(session: NodeSessions.id(of: session), name: kept)))
        } catch {
            reply(.init(re: request.id, error: .init(.internal, "the name wasn't kept: \(error)")))
        }
    }

    /// `session.pause` with `session` and `for`: `indefinitely` (until resumed), `morning` (9:00 tomorrow, or this
    /// morning before 5:00), `hours` with `hours` (1 to 720), or `off` (resumed) (the stability lane, 2026-11-20; the
    /// app's Pause menu and Resume Notifications): the session greyed out, and nothing reminds or notifies you of it until
    /// then. The user's voice, recorded. The reply names the session and the pause's end (null: resumed; far in the
    /// future: until resumed).
    func pauseSession(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let (session, marks) = listedSession(request) else { return reply(markRefusal(request)) }
        let now = Date()
        let until: Date?
        switch request.args?["for"]?.string {
        case "indefinitely": until = .distantFuture
        case "morning": until = PauseStore.nextMorning(after: now)
        case "off": until = nil
        case "hours":
            guard let hours = request.args?["hours"]?.int, (1...720).contains(hours) else {
                return reply(.init(re: request.id, error: .init(.badArgs, "session.pause for hours needs hours, 1 to 720")))
            }
            until = now.addingTimeInterval(Double(hours) * 3600)
        default:
            return reply(.init(re: request.id, error: .init(.badArgs, "session.pause's for is indefinitely, morning, hours or off")))
        }
        do {
            try marks.pause(SessionMarks.keys(of: session), until: until)
            note("session.pause: session \(NodeSessions.id(of: session)) \(until == nil ? "resumed" : "paused")")
            sessions?.refresh()
            reply(.init(re: request.id, typed: WireKinds.SessionPause.Result(session: NodeSessions.id(of: session), until: until.map(NodeWire.dateText))))
        } catch {
            reply(.init(re: request.id, error: .init(.internal, "the pause wasn't kept: \(error)")))
        }
    }
}
