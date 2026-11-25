import Foundation

/// H1 (docs/process/v2-h1-plan.md, the security architecture's S11 item 32): the session host holds the node's web
/// listening sockets, and its server child only accepts on them. The server asks over its connector (`HostConnector`)
/// when the web goes on (`web.open`, a token alive at its start), the host binds, keeps the socket and hands the server
/// a duplicate (`SCM_RIGHTS`); when the web goes off (no code or token alive) the server says so and the host closes
/// its own. Between two servers (a crash, a restart, a handover, a switch) the host holds the port, so no other process
/// of the user can bind it and take what a page sends.
///
/// The messages, each one `SOCK_SEQPACKET` message on Linux's connector beside its one-byte connection requests, and one
/// framed message on the Mac's stream connector, to its newline (`Platform.Sockets.sendConnectorMessage`: every web
/// message's first byte, `w`, is the Mac's `framedStart`; no other message there starts with it):
///
/// - `web listen PLACE ADDRESS PORT`: PLACE `loopback`, `tailnet` or `page` (a plugin's one-request page). Answered `web ok listen PLACE ADDRESS PORT` with the
///   listening socket riding on it, or `web no listen PLACE ADDRESS PORT: WHY` with none.
/// - `web release PLACE`: answered `web ok release PLACE`. The host closes what it holds for PLACE (nothing when it holds
///   none). The server sends it only when the user revoked the web (`web --revoke`): a server that starts and finds no
///   code or token alive leaves the socket held, so no process that moved the token file aside and ended the server
///   can have the host free the port.
///
/// Each answer repeats its request's words, and the asker takes only the answer to its own (`answers`), so an answer that
/// came after its asker gave up never answers another request: a release never takes a listen's socket, nor a tailnet
/// listen a loopback one. The asker also checks the socket listens where it asked (`HostConnector.web`).
///
/// The host's own check (`refusal`): loopback is 127.0.0.1 only; the tailnet is an IPv4 address in 100.64.0.0/10
/// (Tailscale's CGNAT range) only, which the bind itself then requires to be this machine's (the server keeps its own
/// check that it is Tailscale's, `Tailnet.find`). On the user's host the port is the node's one web port (`port`); a
/// scratch host takes any (0: the kernel's pick). Never `SO_REUSEPORT`, so no other socket can share the port.
public enum HostWebListen {
    public enum Place: String, CaseIterable, Codable, Sendable {
        /// `page`: a plugin's one-request page (`PluginPage`), on loopback, on a port of the kernel's pick, one at a time:
        /// an origin of its own, never the node page's (the plugins definition's rule 6).
        case loopback, tailnet, page
    }

    /// The node's one web port, on loopback and on the tailnet (`NodeWeb.port`, which a test holds to this).
    public static let port: UInt16 = 47830

    /// The first word of every web message on the connector, a request's and an answer's: a connection's answer is
    /// one byte (`d`), so a reply is never taken for the other kind.
    static let word = "web "

    public enum Request: Equatable, Sendable {
        case listen(Place, address: String, port: UInt16)
        case release(Place)
    }

    /// `request` as its message's bytes.
    public static func bytes(_ request: Request) -> [UInt8] {
        switch request {
        case .listen(let place, let address, let port): return Array("\(word)listen \(place.rawValue) \(address) \(port)".utf8)
        case .release(let place): return Array("\(word)release \(place.rawValue)".utf8)
        }
    }

    /// Whether `bytes` is a web message (else it is a connection request, as every message was before H1).
    public static func isWeb(_ bytes: [UInt8]) -> Bool { bytes.starts(with: Array(word.utf8)) }

    /// The request `bytes` says; nil when it says none exactly (an unknown word, a place, an address that isn't
    /// numeric IPv4, a port that isn't a number below 65536, anything more).
    public static func parse(_ bytes: [UInt8]) -> Request? {
        guard bytes.count <= 128, let text = String(bytes: bytes, encoding: .utf8), text.hasPrefix(word) else { return nil }
        let words = text.dropFirst(word.count).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        switch words.first {
        case "listen":
            guard words.count == 4, let place = Place(rawValue: words[1]), ipv4(words[2]) != nil,
                  words[3].allSatisfy(\.isASCII), words[3].allSatisfy(\.isNumber), let port = UInt16(words[3]) else { return nil }
            return .listen(place, address: words[2], port: port)
        case "release":
            guard words.count == 2, let place = Place(rawValue: words[1]) else { return nil }
            return .release(place)
        default:
            return nil
        }
    }

    /// Why the host won't bind `address`:`port` for `place`, or nil. `usersHost`: the user's host, whose port is
    /// `port` alone.
    public static func refusal(_ place: Place, address: String, port: UInt16, usersHost: Bool) -> String? {
        guard let octets = ipv4(address) else { return "\(address) isn't a numeric IPv4 address" }
        switch place {
        case .loopback:
            guard address == "127.0.0.1" else { return "the loopback listener is 127.0.0.1 only, not \(address)" }
        case .tailnet:
            // 100.64.0.0/10: the first octet 100, the second's top two bits 01.
            guard octets[0] == 100, octets[1] & 0xC0 == 0x40 else { return "\(address) isn't a tailnet address (100.64.0.0/10)" }
        case .page:
            // Its own origin: loopback, never the node page's port (a new one each time, the kernel's pick).
            guard address == "127.0.0.1" else { return "a plugin's page is on 127.0.0.1 only, not \(address)" }
            guard port != Self.port else { return "a plugin's page never takes the node page's port \(Self.port)" }
            return nil
        }
        if usersHost, port != Self.port { return "the user's node listens on port \(Self.port) only, not \(port)" }
        return nil
    }

    /// `address`'s four numbers, when it is exactly a dotted-quad IPv4 address (no leading zeros, no other form).
    static func ipv4(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || !part.hasPrefix("0"), let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// `request`'s words after `web `.
    static func words(_ request: Request) -> String { String(decoding: bytes(request).dropFirst(word.count), as: UTF8.self) }

    /// The answer to `request` as its message's bytes: `web ok WORDS`, or `web no WORDS: WHY`.
    public static func answer(_ request: Request, refusal: String?) -> [UInt8] {
        Array((word + (refusal.map { "no \(words(request)): " + $0 } ?? "ok \(words(request))")).utf8)
    }

    /// The answer to a message that is no request at all: `web no: WHY` (no asker's words, so no asker takes it).
    public static func unasked(_ why: String) -> [UInt8] { Array((word + "no: " + why).utf8) }

    /// What `bytes` answers to `request`: nil when it is no answer to it (another request's, a connection's, garbled);
    /// `.some(nil)` for ok, `.some(why)` for a refusal.
    public static func answers(_ request: Request, _ bytes: [UInt8]) -> String?? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        let words = words(request)
        if text == word + "ok " + words { return .some(nil) }
        let refused = word + "no " + words + ": "
        if text.hasPrefix(refused) { return .some(String(text.dropFirst(refused.count))) }
        return nil
    }
}
