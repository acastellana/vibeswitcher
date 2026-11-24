import Foundation
import VibeCore

/// Acting from the page on this node (the web UI design's step 2, "Acting from the page"): whether the user turned
/// `web_acts` on, and which pages act, as the host's vault keeps them (`LeadVaultV2.PageActs`). Never a file: any process
/// of the user's can write the token file (`WebTokens`' own note), and a browser keeps its token where any process of the
/// user's reads it (Chromium writes a page's storage to its profile on disk, under /mnt/c on WSL). So acting needs a
/// second secret: one a page paired while `web_acts` is on is given once (`hello.auth.act`) and keeps in its memory only;
/// the vault holds the SHA-256 of the token with it (`key`), never either. A reload loses it: the page reads and drafts
/// until it is paired again. An acting pairing lives `life` at most (its token's end if sooner).
///
/// Only the loopback page's gate has one (`WebAccess.acting`, set by `NodeLive`); the tailnet's gate has none, so a
/// tailnet page never acts, whatever it sends.
///
/// What it says comes from its cache of the vault (no host call on the server's queue: a stalled host never holds a
/// page's auth or request): loaded at each welcome and on a timer (`refreshLater`), and written through by this server,
/// the vault's only writer of it: a pairing (`paired`), the user's `set web_acts` (`set`), the user's revoke (`revoked`).
/// Each change applies to the cache at once and goes to the vault in order (one serial queue); a refresh that began
/// before a change doesn't undo it (`generation`). Acting is judged against the cache at each request (`acts`), so a
/// pairing's end, an off or a revoke counts at the next request, not the next connection.
public final class ActingPages: @unchecked Sendable {
    /// The longest an acting pairing lives: then pair again.
    public static let life: TimeInterval = 12 * 60 * 60

    private let vault: LeadVaultV2Client?
    private let note: (String) -> Void
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// The vault's calls, in order, off every server queue.
    private let writes = DispatchQueue(label: "vibeswitcher.acting-pages")
    private var cache: LeadVaultV2.PageActs?
    /// Counts this server's changes: a refresh that began before one doesn't overwrite it.
    private var generation = 0
    /// Called once acting is turned off, at once, where `set` runs: the screen marks its acting connections not acting
    /// and closes them (`WebRequestScreen.endActing`).
    public var onOff: (() -> Void)?
    /// Called when a pairing's acting couldn't be kept in the vault (its key): that connection acts no more.
    public var onLost: ((String) -> Void)?

    /// `vault`: the host's record (nil where there is none, the Mac's: no page acts).
    public init(vault: LeadVaultV2Client?, now: @escaping @Sendable () -> Date = { Date() }, note: @escaping (String) -> Void = { _ in }) {
        self.vault = vault
        self.now = now
        self.note = note
    }

    /// What the cache says now: nil before the vault first answered.
    public var state: LeadVaultV2.PageActs? { lock.withLock { cache } }

    /// The vault's key of an acting pairing: SHA-256, lower-case hex, of its token and its acting secret.
    public static func key(token: String, secret: String) -> String {
        BuildInfo.sha256(of: Data("\(token)\n\(secret)".utf8))
    }

    /// A token's SHA-256, lower-case hex (its id in a page mark is the first 12 digits).
    public static func digest(_ token: String) -> String { WebTokens.hex(WebTokens.digest(token)) }

    /// The page mark a request made from it is recorded with (`LeadVaultV2.UserAction.via`): its token's id (the first
    /// 12 hex digits of its SHA-256) and its origin.
    public static func via(token: String, origin: String) -> String {
        "page \(digest(token).prefix(12)) from \(ConfigSeal.inert(origin, limit: 120))"
    }

    /// Whether a page with `token` and acting `secret` acts now: on, and its pairing live in the cache.
    public func acts(token: String, secret: String?) -> Bool {
        guard let secret, !secret.isEmpty, let cache = state, cache.on, let end = cache.tokens[Self.key(token: token, secret: secret)] else { return false }
        return end > now().timeIntervalSince1970
    }

    /// A token just issued from a pairing code: when acting is on, its acting secret (sent once, `hello.auth.act`), kept
    /// at once in the cache and then in the vault, until `life` from now or the token's end; nil when off (or not known
    /// yet). Never waits on the host.
    public func paired(token: String, tokenEnds: Date) -> String? {
        guard vault != nil, state?.on == true else { return nil }
        let secret = WebTokens.randomText(bytes: WebTokens.tokenBytes)
        let key = Self.key(token: token, secret: secret)
        let until = min(tokenEnds.timeIntervalSince1970, now().addingTimeInterval(Self.life).timeIntervalSince1970)
        let made = lock.withLock { () -> Int in
            generation += 1
            cache?.tokens[key] = until
            return generation
        }
        writes.async { [weak self] in
            guard let self, let vault = self.vault else { return }
            do {
                self.apply(try vault.addActingToken(sha256: key, until: until), from: made)
                self.note("acting from the page: a page paired while it is on acts, for 12 hours at most")
            } catch {
                self.note("acting from the page: a paired page's acting wasn't kept in the vault (\(error)): it reads and drafts")
                self.lock.withLock {
                    self.generation += 1
                    _ = self.cache?.tokens.removeValue(forKey: key)
                }
                self.onLost?(key)
            }
        }
        return secret
    }

    /// The user's `set web_acts on|off` (the request recorded already): kept in the vault, then in the cache; off ends
    /// every acting connection at once (`onOff`). Waits on the host: called off the server's queue.
    public func set(on: Bool) throws -> LeadVaultV2.PageActs {
        guard let vault else { throw LeadVaultV2Client.Refused("This node's host keeps no record of the user's actions: no page acts here.") }
        if !on {
            // Off in the cache first: no request acts from here, whatever the vault's answer.
            lock.withLock {
                generation += 1
                cache = .init(since: nil, tokens: [:])
            }
            onOff?()
        }
        let acts = try writes.sync { try vault.setPageActs(on: on) }
        lock.withLock {
            generation += 1
            cache = acts
        }
        note("acting from the page turned \(on ? "on" : "off")")
        return acts
    }

    /// The user's revoke: no pairing acts any more (the cache at once, the vault in order).
    public func revoked() {
        let made = lock.withLock { () -> Int in
            generation += 1
            cache?.tokens = [:]
            return generation
        }
        writes.async { [weak self] in
            guard let self, let vault = self.vault else { return }
            do { self.apply(try vault.dropActingTokens(nil), from: made) } catch { self.note("acting from the page: the revoke's drop wasn't kept (\(error))") }
        }
    }

    /// The vault asked again, off every server queue (at each welcome, on the timer).
    public func refreshLater() {
        let began = lock.withLock { generation }
        writes.async { [weak self] in
            guard let self, let vault = self.vault, let acts = try? vault.pageActs() else { return }
            self.apply(acts, from: began)
        }
    }

    /// Waits for the vault's calls asked so far (tests, and `settings`, which shows what the vault says).
    func settled() { writes.sync {} }

    /// What the vault said, unless this server changed the cache since the call began.
    private func apply(_ acts: LeadVaultV2.PageActs, from began: Int) {
        lock.withLock { if generation == began { cache = acts } }
    }

    /// What `status` and the node stream say: on, since when, and how many acting pages are open (`pages`).
    public func value(pages: Int) -> NodeWire.Value {
        let acts = state
        return .object(["on": .bool(acts?.on == true), "since": acts?.since.map { .date(Date(timeIntervalSince1970: $0)) } ?? .null,
                        "pages": .int(pages)])
    }
}
