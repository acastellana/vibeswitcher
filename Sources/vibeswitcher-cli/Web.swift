import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher web [--revoke]` (the live plan's F1; the live wire contract's §2): the node's web page opened for one
/// browser, or every web token dropped. Each is the server's `web.open` or `web.revoke` in the user's voice, after the
/// command line's own typed code (EN-D5), and the accepted request is written to the journal (ids only: never the
/// address, which holds the code).
///
/// In this order: the server checked (`NodeClient.connect`), what the request will do said, the code typed on the
/// controlling terminal (none: refused before any request), the request, then the address alone on its own line of
/// stdout, its explanation on stderr. The address holds a one-time pairing code in its fragment, good for 120 s: once a
/// browser has taken it, nothing in the scrollback or the browser's history opens anything.
enum WebCommand {
    static let usage = "usage: vibeswitcher web [--revoke]"

    static func run(_ arguments: [String]) -> Int32 {
        let revoke: Bool
        switch arguments {
        case []: revoke = false
        case ["--revoke"]: revoke = true
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
            ? "This drops every web token: each page open on this node is closed, and a browser needs `vibeswitcher web` again."
            : "This opens the node's web page on this machine's loopback (127.0.0.1) for one browser: the address printed works once, "
                + "within 120 s, and gives that browser a token that reads the node and leaves draft answers for 24 hours. "
                + "It never answers, holds, starts or stops anything. Under WSL's mirrored networking Windows' processes reach "
                + "the port too: the token is what keeps them out. `vibeswitcher web --revoke` drops every token."
        let id = UUID().uuidString.lowercased()
        let outcome = TypedWord.ask(code: NodeIds.code(action: id), what: what)
        guard outcome == .typed else { return Say.refused(TypedWord.refusal(outcome)) }
        switch client.request(kind, args: [:], action: id, timeout: 30) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            // Accepted (the voice passed and the server recorded it): its own refusal (`refused`) comes after that.
            if reply.ok || reply.error?.code == NodeWire.Code.refused.rawValue {
                context.writeJournal(NodeJournal.entry(event: "request", action: id, kind: kind, epoch: client.hello.epoch))
            }
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            if revoke {
                Say.out("web tokens dropped: \(result["revoked"]?.int ?? 0); every page open on this node was closed")
                return 0
            }
            guard let url = result["url"]?.string, isPageAddress(url) else {
                return Say.refused("the server's reply holds no address of this node's page")
            }
            Say.err("Open this address in a browser within \(result["expiresIn"]?.int ?? 120) s; it works once:")
            Say.out(url)
            return 0
        }
    }

    /// `http://127.0.0.1:<port>/#pair=<base64url>` and nothing else: what is printed is never the listener's choice of
    /// text.
    static func isPageAddress(_ url: String) -> Bool {
        let prefix = "http://127.0.0.1:"
        guard url.hasPrefix(prefix), let slash = url.dropFirst(prefix.count).firstIndex(of: "/") else { return false }
        let port = url[url.index(url.startIndex, offsetBy: prefix.count)..<slash]
        guard let number = UInt16(port), number > 0 else { return false }
        let rest = url[slash...]
        guard rest.hasPrefix("/#pair=") else { return false }
        let code = rest.dropFirst("/#pair=".count)
        return !code.isEmpty && code.count <= 64 && code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
