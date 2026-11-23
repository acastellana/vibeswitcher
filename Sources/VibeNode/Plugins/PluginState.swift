import Foundation
import VibeCore

/// The plugin runtime's bookkeeping, out of the engine (the architecture review's row 8, batch 2): each plugin request's
/// card, the stamps the host vouched for, the looks and the vault's asks under way, the settled requests, the page, the
/// tells, the settings, the clock and the queue the folders are read on. On the engine's queue (`queue`); the logic is
/// still the engine's (`PluginEngine.swift`, the desk), which reaches it as `pluginState`.
final class PluginState {
    let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    var cards: [PluginKey: String] = [:]
    var trusted: [String: [String: WalletStamp]] = [:]
    /// Each plugin's look under way, and who waits for its end.
    var looking: [String: [() -> Void]] = [:]
    /// Each plugin's look asked for while one was under way (which may have read its folder before what this one is
    /// for was filed): one more look, after it, and who waits for that one.
    var lookAgain: [String: [() -> Void]] = [:]
    var asking = false
    /// Who waits for the vault's answer under way.
    var askWaiters: [() -> Void] = []
    /// Waiters that came while an ask was under way, and whether another ask follows it (`LeadEngine.askPlugins`).
    var askNextWaiters: [() -> Void] = []
    var askAgain = false
    /// The plugin writes to the vault queued so far (on, off, add, remove, a setting): an ask queued before one of them
    /// read the vault before it, and its answer is stale (`LeadEngine.askPlugins`).
    var writes = 0
    var timer: Subscription?
    var now: () -> Date = Date.init
    /// The plugin requests settled (`PluginKey.name`), as the vault keeps them: never drawn again.
    var settled: Set<String> = []
    /// Whether the vault said which requests are settled (nothing is drawn until it did).
    var settledKnown = false
    /// The acting answers whose settle the vault is still asked for (`PluginKey.name`): nothing has run for them yet.
    var settling: Set<String> = []
    /// The plugin page open now (one at a time on a node).
    /// The node's one plugin page, whose plugin and request it serves (`LeadEngine.openPluginPage`).
    var page: PluginPageSlot?
    /// A page's address for the answer that opened it (`PluginKey.name`): printed in that answer's reply, then let go.
    var pageLines: [String: (url: URL, life: TimeInterval)] = [:]
    /// When the vault's record began, as the vault says (a host restart starts it over): what `plugin list` says a
    /// plugin is at its default since.
    var recordSince: Date?
    /// Each request the reader last gave, by `PluginKey.name`: the stamp it came with (its digest, its session) and when
    /// it was filed. What a card is drawn from, and who its tells go to.
    var stamps: [String: PluginStamp] = [:]
    /// The digest each card was drawn from, by `PluginKey.name`: a request whose bytes changed under its id is dropped.
    var drawn: [String: String] = [:]
    /// The sessions of a team (a worker's, a verifier's) as the vault's roster said at the last look: not the user's.
    var team: Set<String> = []
    /// What must reach a session from VibeSwitcher even while its plugin is off (a withdrawal's words), by key, until it
    /// did or the session is gone; tried again at each plugins' look.
    var tells: [String: (session: UUID, text: String)] = [:]
    var telling: Set<String> = []
    /// The plugins' settings the user set, as the vault last said (`<plugin>.<name>`).
    var settings: [String: String] = [:]
    /// A clock for the plugins' pages when the engine has none (a test's engine), on its queue.
    lazy var clock = NodeClock(queue: queue)
    let work = DispatchQueue(label: "vibenode.lead-engine.plugins", qos: .userInitiated)
}
