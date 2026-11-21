import Foundation

/// The headers on every response of the web listener (the live plan's Security table; named so beside lane A's
/// `WebHeaders`, a request's). Lane C makes them with each file (`WebAssets`); lane A writes them as they are.
public enum WebSecurityHeaders {
    /// How long the browser keeps a response.
    public enum Caching: Sendable, Equatable {
        /// Asked again on every use, answered 304 when its `ETag` still matches: the page, `/build.json`, a file by
        /// its plain path. A new build is seen at the next load.
        case revalidate
        /// Kept for a year and never asked again: a build's file under `/_/<build>/`, whose path changes with any byte.
        case immutable
    }

    /// The page runs its own scripts and styles and nothing else, talks to its own socket only, is framed by nobody,
    /// and makes no element from a string (Trusted Types with no policy: `innerHTML` and its relatives throw). The port
    /// is in `connect-src` since a browser may not count `ws:` under `'self'`; so is the listener's name (`host`: the
    /// loopback's address, or the tailnet's MagicDNS name). `img-src` takes `blob:` too, and nothing else: a chat's
    /// images, whose bytes the page asks of the node (`chat.image`, read by a session's own image id) and shows as
    /// object URLs it made; no image of another origin, no `data:`.
    public static func policy(port: UInt16, host: String = "127.0.0.1") -> String {
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob:; font-src 'self'; "
            + "connect-src 'self' ws://\(host):\(port); manifest-src 'self'; worker-src 'self'; base-uri 'none'; "
            + "form-action 'none'; frame-ancestors 'none'; require-trusted-types-for 'script'; trusted-types 'none'"
    }

    public static func cacheControl(_ caching: Caching) -> String {
        switch caching {
        case .revalidate: return "no-cache"
        case .immutable: return "public, max-age=31536000, immutable"
        }
    }

    /// Every header of one response, in the order written. No cookie is ever set (the contract's §1).
    public static func all(port: UInt16, host: String = "127.0.0.1", contentType: String, etag: String, caching: Caching = .revalidate) -> [(String, String)] {
        [
            ("Content-Type", contentType),
            ("Cache-Control", cacheControl(caching)),
            ("ETag", etag),
            ("Content-Security-Policy", policy(port: port, host: host)),
            ("X-Content-Type-Options", "nosniff"),
            ("X-Frame-Options", "DENY"),
            ("Referrer-Policy", "no-referrer"),
            ("Cross-Origin-Opener-Policy", "same-origin"),
            ("Cross-Origin-Resource-Policy", "same-origin"),
        ]
    }
}
