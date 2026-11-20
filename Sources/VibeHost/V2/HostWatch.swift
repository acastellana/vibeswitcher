import Foundation
import VibeCore

/// The host's half of `HostRequest.watch` (the user's node's web terminal, `Sources/VibeNode/Live/TerminalRelay.swift`
/// in its watch mode): a client gets a session's replay and then its output, as `attach` gives them, without taking
/// the session's terminal over. `HostServer.updateAttachment` leaves a watcher out, so:
///
/// - the session's `clientsAttached` stays as the other clients make it: with none attached, the host's parser goes on
///   answering the program's terminal queries (`ParserReplies.admit`), which a watching page's answers never are;
/// - a watcher is never `primary`: its replies (`input` with `reply`) aren't typed, its keys don't make it the one
///   whose size and replies count, and it sends no size: a watch neither resizes the session nor nudges it to redraw.
///
/// A watcher that falls behind is detached and told `resync`, as any client is (`deliver`); `detach` ends a watch, and
/// `attach` from the same connection makes it a full attachment.
extension HostServer {
    func watch(_ id: UUID, from client: ClientConnection, reply: (HostEvent) -> Void) {
        guard let session = sessions[id] else { return reply(.error(HostProtocol.noSuchSession)) }
        client.attached.insert(id)
        client.watchOnly.insert(id)
        updateAttachment(id)
        guard client.sendOutput(id, frames: HostFrame.output(session: id, bytes: session.replay())) else {
            client.attached.remove(id)
            client.watchOnly.remove(id)
            updateAttachment(id)
            return reply(.resync(id: id))
        }
        reply(.attached(id: id))
    }
}
