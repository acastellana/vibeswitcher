import Foundation
import VibeCore

/// What a page may do beyond reading, and which pages the node admits at all, as the host's vault keeps it
/// (`LeadVaultV2.PageActs`; the web UI design's step 2, "Acting from the page", and its security reviews):
///
/// - **Page tokens.** A page is admitted only on a token the vault knows (`admits`): the node issued it when a pairing
///   code was taken (`issued`). The token file any process of the user's writes is no authority; a host restart, whose
///   vault starts over, needs every page paired again.
/// - **Confirmed pairings.** A page that took a code shows a short phrase; `vibeswitcher web` shows the same phrase and
///   the user confirms it with the typed code (`web.confirm`, the user's voice). Only then is the page given its pairing
///   secret (once, on its open connection: the `paired` message), which it keeps in its memory only: the vault holds the
///   SHA-256 of the token with it (`key`), never either. A confirmed pairing watches the hosted terminals (`watches`) at
///   every level and acts (`acts`) while the level is above off; it lives `life` at most (its token's end if sooner). A
///   reload loses the secret: the page reads and drafts until it is paired again.
/// - **The level** (`web_acts`): `off`, `confirm` (each acting request passes a passkey: `PageVoice`; refused to set
///   until it exists), `trust` (no check per request).
///
/// Only the loopback page's gate acts or watches (`WebAccess.acting`); the tailnet's gate asks this for its tokens
/// alone (scope `tailnet`).
///
/// What it says comes from its cache of the vault (no host call on the server's queue: a stalled host never holds a
/// page's auth or request): loaded at each welcome and on a timer (`refreshLater`), and written through by this server,
/// the vault's only writer of it. Each change applies to the cache at once and goes to the vault in order (one serial
/// queue); a refresh that began before a change doesn't undo it (`generation`). It is judged at each request.
public final class ActingPages: @unchecked Sendable {
    /// The longest a confirmed pairing lives: then pair again.
    public static let life: TimeInterval = 12 * 60 * 60
    /// The levels, lowest first.
    public static let levels = LeadVaultV2.pageActsLevels
    /// Whether `confirm`'s per-request check (a passkey) exists yet: until it does, `confirm` can't be set.
    public static let confirmBuilt = true

    private let vault: LeadVaultV2Client?
    private let note: (String) -> Void
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// The vault's calls, in order, off every server queue.
    private let writes = DispatchQueue(label: "vibeswitcher.acting-pages")
    private var cache: LeadVaultV2.PageActs?
    /// Counts this server's changes: a refresh that began before one doesn't overwrite it.
    private var generation = 0
    /// Called when the level goes down, at once, where `set` runs (the level now): the screen marks its connections
    /// as the level allows and closes those that acted (`WebRequestScreen.levelLowered`).
    public var onLowered: ((String) -> Void)?
    /// Called once a new level is kept (above off): the screen gives each confirmed connection its rights at that level.
    public var onLevel: ((String) -> Void)?
    /// Called when a write this server made couldn't be kept in the vault (a pairing's key, or a page token's digest):
    /// what it admitted ends.
    public var onLost: ((String) -> Void)?

    /// `vault`: the host's record (nil where there is none, the Mac's: no page is admitted through this).
    public init(vault: LeadVaultV2Client?, now: @escaping @Sendable () -> Date = { Date() }, note: @escaping (String) -> Void = { _ in }) {
        self.vault = vault
        self.now = now
        self.note = note
    }

    /// What the cache says now: nil before the vault first answered.
    public var state: LeadVaultV2.PageActs? { lock.withLock { cache } }

    /// The level now (`off` until the vault answered).
    public var level: String { state?.level ?? "off" }

    /// The vault's key of a confirmed pairing: SHA-256, lower-case hex, of its token and its pairing secret.
    public static func key(token: String, secret: String) -> String {
        BuildInfo.sha256(of: Data("\(token)\n\(secret)".utf8))
    }

    /// A token's SHA-256, lower-case hex (its id in a page mark is the first 12 digits).
    public static func digest(_ token: String) -> String { WebTokens.hex(WebTokens.digest(token)) }

    /// The page mark a request made from it is recorded with (`LeadVaultV2.UserAction.via`): its token's id and origin.
    public static func via(token: String, origin: String) -> String {
        "page \(digest(token).prefix(12)) from \(ConfigSeal.inert(origin, limit: 120))"
    }

    // MARK: Page tokens

    /// Whether a page token of `scope` is admitted now: the vault knows it, live.
    public func admits(scope: String, token: String) -> Bool {
        guard let end = state?.pages["\(scope):\(Self.digest(token))"] else { return false }
        return end > now().timeIntervalSince1970
    }

    /// A token the node just issued for `scope` (a pairing code taken): admitted at once, then kept in the vault.
    public func issued(scope: String, token: String, until: Date) {
        let sha = Self.digest(token), until = until.timeIntervalSince1970
        change({ $0.pages["\(scope):\(sha)"] = until }) { try $0.addPageToken(scope: scope, sha256: sha, until: until) } lost: { [weak self] in
            self?.onLost?(sha)
        }
    }

    /// Every page token of `scope` admitted no more (the user's revoke).
    public func dropPages(scope: String) {
        change({ $0.pages = $0.pages.filter { !$0.key.hasPrefix(scope + ":") } }) { try $0.dropPageTokens(scope: scope, nil) } lost: {}
    }

    // MARK: Confirmed pairings

    /// Whether a page with `token` and pairing `secret` has a confirmed pairing, live now: it watches the terminals.
    public func watches(token: String, secret: String?) -> Bool {
        guard let secret, !secret.isEmpty, let end = state?.tokens[Self.key(token: token, secret: secret)] else { return false }
        return end > now().timeIntervalSince1970
    }

    /// Whether it acts now: a confirmed pairing, live, and the level above off.
    /// At `confirm`, only on the origin that can do passkeys (`http://localhost:PORT`: `origin` the page's host).
    public func acts(token: String, secret: String?, origin: String? = nil) -> Bool {
        let level = self.level
        guard level != "off", watches(token: token, secret: secret) else { return false }
        return level != "confirm" || Self.passkeyHost(origin)
    }

    /// Whether `host` (a page's, `name:port`) is the one a passkey works on: `localhost`.
    public static func passkeyHost(_ host: String?) -> Bool { host?.hasPrefix(WebAuthn.rpID + ":") == true }

    /// A pairing the user confirmed in a terminal (`web.confirm`): its secret (sent once, on its connection), kept at
    /// once in the cache and then in the vault, until `life` from now or the token's end. Never waits on the host.
    public func confirmed(token: String, tokenEnds: Date) -> String {
        let secret = WebTokens.randomText(bytes: WebTokens.tokenBytes)
        let key = Self.key(token: token, secret: secret)
        let until = min(tokenEnds.timeIntervalSince1970, now().addingTimeInterval(Self.life).timeIntervalSince1970)
        change({ $0.tokens[key] = until }) { try $0.addActingToken(sha256: key, until: until) } lost: { [weak self] in self?.onLost?(key) }
        note("a page's pairing confirmed in a terminal: it watches\(level == "off" ? "" : " and acts"), 12 hours at most")
        return secret
    }

    /// One pairing dropped (its connection closed before it was given its secret).
    public func dropPairing(key: String) {
        change({ _ = $0.tokens.removeValue(forKey: key) }) { try $0.dropActingTokens([key]) } lost: {}
    }

    /// The user's revoke: no pairing watches or acts any more.
    public func revoked() {
        change({ $0.tokens = [:] }) { try $0.dropActingTokens(nil) } lost: {}
    }

    // MARK: Passkeys (the level `confirm`)

    /// A passkey kept (the terminal's `web.passkey.add`). Waits on the host: off the server's queue.
    public func addPasskey(id: String, publicKey: String) throws -> LeadVaultV2.PageActs {
        try written { try $0.addPasskey(id: id, publicKey: publicKey) }
    }

    /// These passkeys forgotten. Waits on the host: off the server's queue.
    public func dropPasskeys(_ ids: [String]) throws -> LeadVaultV2.PageActs {
        try written { try $0.dropPasskeys(ids) }
    }

    /// An assertion by passkey `id` with sign count `count` taken (refused unless the count moved past the kept one).
    /// Waits on the host: off the server's queue.
    public func usePasskey(id: String, count: UInt32) throws {
        _ = try written { try $0.usePasskey(id: id, count: count) }
    }

    /// One write to the vault, in order with the others, its answer the cache.
    private func written(_ write: (LeadVaultV2Client) throws -> LeadVaultV2.PageActs) throws -> LeadVaultV2.PageActs {
        guard let vault else { throw LeadVaultV2Client.Refused("This node's host keeps no record of the user's actions.") }
        let acts = try writes.sync { try write(vault) }
        lock.withLock {
            generation += 1
            cache = acts
        }
        return acts
    }

    // MARK: The level

    /// The user's `set web_acts LEVEL` (the request recorded already): kept in the vault, then in the cache; a lower
    /// level counts at once (`onLowered`, before the vault answers). Waits on the host: called off the server's queue.
    public func set(level: String) throws -> LeadVaultV2.PageActs {
        guard let vault else { throw LeadVaultV2Client.Refused("This node's host keeps no record of the user's actions: no page acts here.") }
        guard let asked = Self.levels.firstIndex(of: level) else { throw LeadVaultV2Client.Refused("web_acts is off, confirm or trust") }
        // Lower at once, before the vault answers (and before a refresh queued earlier, whose answer the bumped
        // generation turns away): from here no request acts above `level`. Off counts at once even before the vault ever
        // answered.
        if asked < (Self.levels.firstIndex(of: self.level) ?? 0) || level == "off" {
            lock.withLock {
                generation += 1
                var acts = cache ?? LeadVaultV2.PageActs()
                acts.level = level
                if level == "off" { acts.since = nil; acts.tokens = [:] }
                cache = acts
            }
            onLowered?(level)
        }
        let acts = try writes.sync { try vault.setPageActs(level: level) }
        lock.withLock {
            generation += 1
            cache = acts
        }
        note("acting from the page set to \(level)")
        if level != "off" { onLevel?(level) }
        return acts
    }

    // MARK: The cache

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

    /// One change: to the cache at once (an empty one made if the vault never answered: this server's own issue counts),
    /// then the vault's write in order, whose answer is taken unless a later change came; `lost` when it fails.
    private func change(_ local: (inout LeadVaultV2.PageActs) -> Void, write: @escaping (LeadVaultV2Client) throws -> LeadVaultV2.PageActs,
                        lost: @escaping () -> Void) {
        guard vault != nil else { return }
        let made = lock.withLock { () -> Int in
            generation += 1
            var acts = cache ?? LeadVaultV2.PageActs()
            local(&acts)
            cache = acts
            return generation
        }
        writes.async { [weak self] in
            guard let self, let vault = self.vault else { return }
            do { self.apply(try write(vault), from: made) } catch {
                self.note("a page's pairing wasn't kept in the vault (\(error)): what it admitted ends")
                self.lock.withLock { self.generation += 1 }
                self.refreshLater()
                lost()
            }
        }
    }

    /// What the vault said, unless this server changed the cache since the call began.
    private func apply(_ acts: LeadVaultV2.PageActs, from began: Int) {
        lock.withLock { if generation == began { cache = acts } }
    }

    /// What `status` and the node stream say: the level (and whether it is above off), since when, and how many acting
    /// pages are open (`pages`).
    public func value(pages: Int, port: UInt16? = nil) -> NodeWire.Value {
        let acts = state
        let keys = (acts?.keys ?? [:]).sorted { $0.value.added < $1.value.added }
        // A passkey added in the last week is said (one added by something passing as the user's voice doesn't go unseen).
        let recent = keys.filter { now().timeIntervalSince1970 - $0.value.added < 7 * 86_400 }
        let notice: NodeWire.Value = recent.isEmpty ? .null : .string(recent.map { "a passkey (\($0.key.prefix(12))) was added on "
            + NodeWire.dateText(Date(timeIntervalSince1970: $0.value.added)) }.joined(separator: "; ")
            + ": if that wasn't you, run `vibeswitcher web --passkey --forget ID`")
        return .object(["level": .string(acts?.level ?? "off"), "on": .bool(acts?.on == true),
                        "since": acts?.since.map { .date(Date(timeIntervalSince1970: $0)) } ?? .null, "pages": .int(pages),
                        "keys": .array(keys.map { key in .object(["id": .string(String(key.key.prefix(12))),
                                                                  "added": .date(Date(timeIntervalSince1970: key.value.added)),
                                                                  "lastUsed": key.value.lastUsed.map { .date(Date(timeIntervalSince1970: $0)) } ?? .null]) }),
                        "passkeyOrigin": port.map { .string("http://\(WebAuthn.rpID):\($0)") } ?? .null, "notice": notice])
    }
}
