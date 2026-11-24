import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher web [--tailnet | --revoke]` (the live plan's F1; the live wire contract's §2; the remote access note):
/// the node's web page opened for one browser, on this machine's loopback or (`--tailnet`) on the user's tailnet, or
/// every web token dropped, the tailnet's too. Each is the server's `web.open` or `web.revoke` in the user's voice, after the
/// command line's own typed code (EN-D5), and the accepted request is written to the journal (ids only: never the
/// address, which holds the code).
///
/// In this order: the server checked (`NodeClient.connect`), what the request will do said, the code typed on the
/// controlling terminal (none: refused before any request), the request, then the address alone on its own line of
/// stdout, its explanation on stderr. The address holds a one-time pairing code in its fragment, good for 120 s: once a
/// browser has taken it, nothing in the scrollback or the browser's history opens anything.
enum WebCommand {
    static let usage = "usage: vibeswitcher web [--tailnet | --revoke]"

    static func run(_ arguments: [String]) -> Int32 {
        let revoke: Bool, tailnet: Bool
        switch arguments {
        case []: (revoke, tailnet) = (false, false)
        case ["--revoke"]: (revoke, tailnet) = (true, false)
        case ["--tailnet"]: (revoke, tailnet) = (false, true)
        default: return Say.usage(usage)
        }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let kind = revoke ? "web.revoke" : "web.open"
        let what = revoke
            ? "This drops every web token, the tailnet's too: each page open on this node, here or on another device, is closed, "
                + "and a browser needs `vibeswitcher web` (or `web --tailnet`) again."
            : tailnet ? tailnetWhat
            : "This opens the node's web page on this machine's loopback (127.0.0.1) for one browser: the address printed works once, "
                + "within 120 s, and gives that browser a token that reads the node and leaves draft answers for 24 hours. "
                + "Then this asks you to confirm the page by the phrase it shows; confirmed, it also watches the terminals, and acts "
                + "as you as `web_acts` allows. Under WSL's mirrored networking Windows' processes reach "
                + "the port too: the token is what keeps them out. `vibeswitcher web --revoke` drops every token."
        let id = UUID().uuidString.lowercased()
        let said = TypedWord.said(approval: client.approvalRule, action: id, what: what)
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }
        _ = kind
        if revoke {
            switch client.change(WireKinds.WebRevoke.self, WireNoArgs(), action: id, typed: typed, timeout: 30) {
            case .failure(let failure): return Say.failed(failure)
            case .refused(let reply): return Say.replyError(reply)
            case .success(let result, _):
                let remote = result.tailnetRevoked.map { "; on the tailnet: \($0)" } ?? ""
                Say.out("web tokens dropped: \(result.revoked ?? 0)\(remote); every page open on this node was closed")
                return 0
            }
        }
        switch client.change(WireKinds.WebOpen.self, .init(tailnet: tailnet ? true : nil), action: id, typed: typed, timeout: 30) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, _):
            guard let url = result.url, tailnet ? isTailnetAddress(url) : isPageAddress(url) else {
                return Say.refused("the server's reply holds no address of this node's page")
            }
            if tailnet {
                Say.err("Open this address in the phone's browser, with Tailscale on, within \(result.expiresIn ?? 120) s; it works once:")
                Say.out(url)
                return 0
            }
            Say.err("Open this address in a browser within \(result.expiresIn ?? 120) s; it works once:")
            Say.out(url)
            guard let code = result.code else { return 0 }
            return confirm(code, expiresIn: result.expiresIn ?? 120, client: client)
        }
    }

    /// The page that takes the address, confirmed here (the acting review's fix A): this waits for a page to take it,
    /// shows the phrase that page shows, and asks the user's typed code to confirm it is theirs. Until then, and if it is
    /// never confirmed, the page reads and drafts; confirmed, it watches the terminals, and acts as `web_acts` allows.
    /// Another page trying the same address is said, and nothing is confirmed. Ctrl-C leaves the page reading.
    static func confirm(_ code: String, expiresIn: Int, client: NodeClient) -> Int32 {
        Say.err("Waiting for the page to open it, to confirm it here (Ctrl-C leaves it reading and drafting only)…")
        // On the awake clock: a wall clock that jumps neither ends the wait early nor holds it.
        let started = MacTime.real.awake(), waits = TimeInterval(expiresIn) + 5
        var taken: WireKinds.WebPairing.Result?
        while MacTime.real.awake() - started < waits {
            switch client.read(WireKinds.WebPairing.self, .init(code: code), timeout: 30) {
            case .failure(let failure): return Say.failed(failure)
            case .refused(let reply): return Say.replyError(reply)
            case .success(let state, _):
                if state.state != "waiting" { taken = state }
            }
            if taken != nil { break }
            usleep(500_000)
        }
        guard let taken, let phrase = taken.phrase else {
            Say.err("No page opened the address in time: it reads nothing. Run `vibeswitcher web` again.")
            return 1
        }
        if taken.contested == true {
            return Say.refused("This address was used by another page too: not confirmed, and that page only reads and drafts. "
                + "If the page you opened didn't show it, run `vibeswitcher web --revoke`.")
        }
        if taken.state == "gone" { return Say.refused("The page that opened the address closed before it was confirmed: run `vibeswitcher web` again.") }
        Say.err("The page that opened the address shows: \(ConfigSeal.inert(phrase, limit: 80))")
        let id = UUID().uuidString.lowercased()
        let what = "Confirm only if YOUR page shows “\(ConfigSeal.inert(phrase, limit: 80))”: confirmed, it watches this node's terminals, "
            + "and acts as you as `web_acts` allows (`vibeswitcher settings` says the level), until it is reloaded or 12 hours pass. "
            + "If your browser instead said it wasn't admitted, another process took the address: don't confirm; run `vibeswitcher web --revoke`."
        let said = TypedWord.said(approval: client.approvalRule, action: id, what: what)
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }
        switch client.change(WireKinds.WebConfirm.self, .init(code: code, phrase: phrase), action: id, typed: typed, timeout: 30) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, _):
            let acts = result.rights?.contains("act") == true
            Say.out("Paired: the page \(acts ? "watches the terminals and acts as you (web_acts \(result.level ?? "?"))" : "watches the terminals; it acts only when web_acts is above off")")
            return 0
        }
    }

    /// What `web --tailnet` says before the typed code.
    static let tailnetWhat = "This opens the node's web page on your tailnet, for one browser on another of your devices (a phone): "
        + "this machine's Tailscale address is bound (never every address), under its MagicDNS name only. The address printed "
        + "works once, within 120 s, and gives that browser a token that reads the node and leaves draft answers for 8 hours. "
        + "It never answers, holds, starts or stops anything. Any device on your tailnet reaches the port; the code and the "
        + "token are what keep them out, so a tailnet ACL that lets only your own devices reach port \(NodeWeb.port) is a good "
        + "second lock. `vibeswitcher web --revoke` drops every token, the tailnet's too. Nothing is installed or changed in "
        + "Tailscale."

    /// `http://127.0.0.1:<port>/#pair=<base64url>` and nothing else: what is printed is never the listener's choice of
    /// text.
    static func isPageAddress(_ url: String) -> Bool {
        isAddress(url, host: "127.0.0.1")
    }

    /// `http://<machine>.<tailnet>.ts.net:<port>/#pair=<base64url>` (a MagicDNS name as `Tailnet.name` takes it) and
    /// nothing else.
    static func isTailnetAddress(_ url: String) -> Bool {
        let scheme = "http://"
        guard url.hasPrefix(scheme) else { return false }
        let rest = url.dropFirst(scheme.count)
        guard let colon = rest.firstIndex(of: ":") else { return false }
        let host = String(rest[..<colon])
        guard Tailnet.name(host) == host else { return false }
        return isAddress(url, host: host)
    }

    private static func isAddress(_ url: String, host: String) -> Bool {
        let prefix = "http://\(host):"
        guard url.hasPrefix(prefix), let slash = url.dropFirst(prefix.count).firstIndex(of: "/") else { return false }
        let port = url[url.index(url.startIndex, offsetBy: prefix.count)..<slash]
        guard let number = UInt16(port), number > 0 else { return false }
        let rest = url[slash...]
        guard rest.hasPrefix("/#pair=") else { return false }
        let code = rest.dropFirst("/#pair=".count)
        return !code.isEmpty && code.count <= 64 && code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
