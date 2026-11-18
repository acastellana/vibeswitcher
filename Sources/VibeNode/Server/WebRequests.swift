import Foundation
import VibeCore

/// `web.open` and `web.revoke` (the live plan's F1, LW-D3 and LW-D4; the live wire contract's §2): the user's voice
/// behind the typed code, as `vibeswitcher web` sends them. `handle` has judged the voice before either is reached
/// (both are `.user` in `NodeWire.kinds`), and the integrator (I1) lists both in `recorded`, so each is in the host's
/// vault before it acts, and hands `act`'s two cases here with the server's `WebAccess`. A WebSocket never reaches
/// them: `WebAccess.refusal(for:rights:)` refuses every user's-voice kind there first. On the engine's queue.
extension Requests {
    /// The listener bound if it wasn't, a pairing code made: `{"url": "http://127.0.0.1:<port>/#pair=<code>",
    /// "expiresIn": 120}`. Refused (`refused`, with nothing made) when the port can't be had, saying why.
    public func webOpen(_ request: NodeWire.Request, web: WebAccess, reply: @escaping (NodeWire.Reply) -> Void) {
        switch web.open() {
        case .failure(let refusal):
            reply(.init(re: request.id, error: .init(.refused, "the web isn't open: \(refusal.description)")))
        case .success(let opened):
            reply(.init(re: request.id, result: .object(["url": .string(opened.url), "expiresIn": .int(opened.expiresIn)])))
        }
    }

    /// Every token and code dropped, each page's connection closed (`revoked`, 4403): `{"revoked": <tokens alive>}`.
    public func webRevoke(_ request: NodeWire.Request, web: WebAccess, reply: @escaping (NodeWire.Reply) -> Void) {
        switch web.revoke() {
        case .failure(let refusal):
            reply(.init(re: request.id, error: .init(.refused, "the web tokens weren't dropped: \(refusal.description)")))
        case .success(let dropped):
            reply(.init(re: request.id, result: .object(["revoked": .int(dropped)])))
        }
    }
}
