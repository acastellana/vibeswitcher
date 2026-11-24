import Foundation
import VibeCore

/// Acting from the page on this node (the web UI design's step 2, "Acting from the page"): whether the user turned
/// `web_acts` on, and which page tokens act, as the host's vault keeps them (`LeadVaultV2.PageActs`). Never a file: any
/// process of the user's can write the token file (`WebTokens`' own note), so a token found there reads and drafts, and
/// acts only when the vault holds its SHA-256, which only this server's pairing writes, and only while `web_acts` is on.
///
/// Only the loopback page's gate has one (`WebAccess.acting`, set by `NodeLive`); the tailnet's gate has none, so a
/// tailnet page never acts, whatever its token.
///
/// - At a page's auth with a token, the vault is asked then (`acts`): a revoke, `web_acts` off, or the token's end
///   counts at once, across the server's restarts and switches (the vault outlives them).
/// - A page that takes a pairing code (`vibeswitcher web`, the user's voice) while `web_acts` is on acts: its token's
///   SHA-256 goes to the vault (`paired`).
/// - `set web_acts off` (`set`) empties the vault's list and closes every acting connection (`onOff`); on again needs a
///   new pairing. The user's revoke drops every acting token (`revoked`).
///
/// What `status` says is the last the vault answered (`state`), asked again at each welcome (`refresh`). From any thread;
/// each vault call is a host call (`HostCall.vaultTimeout` at most).
public final class ActingPages: @unchecked Sendable {
    private let vault: LeadVaultV2Client?
    private let note: (String) -> Void
    private let lock = NSLock()
    private var last: LeadVaultV2.PageActs?
    /// Called once acting is turned off: the acting connections are closed (`WebRequestScreen.closeActing`).
    public var onOff: (() -> Void)?

    /// `vault`: the host's record (nil where there is none, the Mac's: no page acts).
    public init(vault: LeadVaultV2Client?, note: @escaping (String) -> Void = { _ in }) {
        self.vault = vault
        self.note = note
    }

    /// What the vault last said: nil before it answered.
    public var state: LeadVaultV2.PageActs? { lock.withLock { last } }

    /// A token's SHA-256 as the vault keeps it: lower-case hex.
    public static func digest(_ token: String) -> String { WebTokens.hex(WebTokens.digest(token)) }

    /// The page mark a request made from it is recorded with (`LeadVaultV2.UserAction.via`): its token's id (the first
    /// 12 hex digits of its SHA-256) and its origin.
    public static func via(token: String, origin: String) -> String {
        "page \(digest(token).prefix(12)) from \(ConfigSeal.inert(origin, limit: 120))"
    }

    /// Whether a page whose auth carried `token` acts: the vault asked now. False when it can't be asked.
    public func acts(token: String) -> Bool {
        guard let vault else { return false }
        do {
            let acts = try vault.pageActs()
            remember(acts)
            return acts.on && acts.tokens.contains(Self.digest(token))
        } catch {
            note("acting from the page: the vault couldn't be asked (\(error)): this page reads and drafts")
            return false
        }
    }

    /// A token just issued from a pairing code: kept as acting, until `until`, when `web_acts` is on. Whether it acts.
    public func paired(token: String, until: Date) -> Bool {
        guard let vault else { return false }
        do {
            guard try vault.pageActs().on else { return false }
            let acts = try vault.addActingToken(sha256: Self.digest(token), until: until.timeIntervalSince1970)
            remember(acts)
            note("acting from the page: a page paired while it is on acts")
            return acts.tokens.contains(Self.digest(token))
        } catch {
            note("acting from the page: a paired page's token wasn't kept as acting (\(error)): it reads and drafts")
            return false
        }
    }

    /// The user's `set web_acts on|off`: kept in the vault; off closes the acting connections.
    public func set(on: Bool) throws -> LeadVaultV2.PageActs {
        guard let vault else { throw LeadVaultV2Client.Refused("This node's host keeps no record of the user's actions: no page acts here.") }
        let acts = try vault.setPageActs(on: on)
        remember(acts)
        note("acting from the page turned \(on ? "on" : "off")")
        if !on { onOff?() }
        return acts
    }

    /// The user's revoke: no token acts any more.
    public func revoked() {
        guard let vault else { return }
        do { remember(try vault.dropActingTokens(nil)) } catch { note("acting from the page: the revoke's drop wasn't kept (\(error))") }
    }

    /// The vault asked again (at each welcome), for `status`.
    public func refresh() {
        guard let vault, let acts = try? vault.pageActs() else { return }
        remember(acts)
    }

    private func remember(_ acts: LeadVaultV2.PageActs) { lock.withLock { last = acts } }

    /// What `status` and the node stream say: on, since when, and how many acting pages are open (`pages`).
    public func value(pages: Int) -> NodeWire.Value {
        let acts = state
        return .object(["on": .bool(acts?.on == true), "since": acts?.since.map { .date(Date(timeIntervalSince1970: $0)) } ?? .null,
                        "pages": .int(pages)])
    }
}
