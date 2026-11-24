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
            // The code's id when the page that takes it waits for this terminal's confirmation (the loopback gate's).
            reply(.init(re: request.id, typed: WireKinds.WebOpen.Result(url: opened.url, expiresIn: opened.expiresIn,
                                                                         code: web.acting == nil ? nil : opened.code)))
        }
    }

    /// `web.open` with `"tailnet": true` (`vibeswitcher web --tailnet`): the tailnet's listener bound on this machine's
    /// Tailscale address if it wasn't, a code of the tailnet's gate made: `{"url": "http://<name>:<port>/#pair=<code>",
    /// "expiresIn": 120, "tailnet": true}`. Refused, with nothing made, on a server with no tailnet (a scratch one), or
    /// when Tailscale isn't there, isn't running, has MagicDNS off, or the port can't be had: saying which.
    public func webOpenTailnet(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let tailnet else {
            return reply(.init(re: request.id, error: .init(.refused, "this server doesn't open the tailnet: only the user's node does")))
        }
        tailnet.open { opened in
            switch opened {
            case .failure(let refusal):
                reply(.init(re: request.id, error: .init(.refused, "the tailnet page isn't open: \(refusal.description)")))
            case .success(let opened):
                reply(.init(re: request.id, typed: WireKinds.WebOpen.Result(url: opened.url, expiresIn: opened.expiresIn, tailnet: true)))
            }
        }
    }

    /// Every token and code dropped, the tailnet's too, each page's connection closed (`revoked`, 4403):
    /// `{"revoked": <loopback tokens alive>, "tailnetRevoked": <tailnet tokens alive>}`.
    public func webRevoke(_ request: NodeWire.Request, web: WebAccess, reply: @escaping (NodeWire.Reply) -> Void) {
        // The tailnet's first: a refusal of the loopback's then still leaves no remote page.
        var remote = 0
        if let tailnet {
            switch tailnet.revoke() {
            case .failure(let refusal):
                return reply(.init(re: request.id, error: .init(.refused, "the tailnet's web tokens weren't dropped: \(refusal.description)")))
            case .success(let dropped): remote = dropped
            }
        }
        switch web.revoke() {
        case .failure(let refusal):
            reply(.init(re: request.id, error: .init(.refused, "the web tokens weren't dropped: \(refusal.description)")))
        case .success(let dropped):
            reply(.init(re: request.id, typed: WireKinds.WebRevoke.Result(revoked: dropped, tailnetRevoked: remote)))
        }
    }
}
