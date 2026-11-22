import Foundation
import VibeCore

/// A feature plugin (docs/superpowers/specs/2026-11-22-v2-feature-plugins.md): one folder under `Plugins/<Name>/` that
/// declares everything its feature adds, compiled into this repository (no third-party code is loaded). What crosses its
/// edge is plain data (`PluginInfo`, `PluginCard`, the requests it reads: `Codable`, no closures), so a later plugin can
/// be a separate process speaking the same shapes. `PluginRegistry` lists them; nothing else in the node names a
/// plugin's id (`PluginLintTests`).
///
/// What stays the core's, whatever a plugin says (the definition's rules 1 to 6): a plugin reads only requests the
/// session host stamped, through the registry's one reader (`PluginDesk.stamped`); an acting answer reaches `perform`
/// only after `Requests.voiced` (the voice, the card's code, the vault's record) and the desk's checks (the word is one
/// of the card's actions, the card is open and waiting, not expired, marked before `perform` runs); its cards are
/// checked for blank-looking text and a decisive part that doesn't fit before they are drawn, and printed inert by the
/// renderers; on and off are the user's, kept in the vault (`PluginRegistry`).
public protocol FeaturePlugin: AnyObject {
    /// What it declares: data.
    var info: PluginInfo { get }
    /// Nil when it can run on this node; else why it can't (the system, a missing tool), as `plugin list` says it.
    func availability() -> String?
    /// Looks at what it has to look at (its requests, through `desk.stamped`), draws its cards (`desk.put`) and tells
    /// its askers, then `done`. Called only while it is on, on the engine's queue.
    func look(_ desk: PluginDesk, done: @escaping () -> Void)
    /// The user's answer `word` on its card, after the core's checks: the card is marked already (its state is the
    /// action's `marks`, put in the same turn), so a second answer finds it answered. `then` on the engine's queue.
    /// `act`: what it may do for this card (start a session), given only here.
    func perform(_ word: String, on card: CardStore.Card, desk: PluginDesk, act: PluginAct,
                 then: @escaping (Result<NodeWire.Value, LeadEngine.CardFailure>) -> Void)
    /// It was turned off while `card` was open: the desk closed it as withdrawn; the plugin keeps that nothing more comes
    /// of it, and says what its asker is told when the desk's words (`PluginDesk.withdrawnText`) wouldn't be true. On the
    /// engine's queue.
    func withdrawn(_ card: PluginCard, desk: PluginDesk) -> String?
    /// It was turned off: what is still under way (a card settled, but something it started still followed) and who must
    /// hear that nothing more will be said of it, as (session, words). On the engine's queue.
    func turnedOff(_ desk: PluginDesk) -> [(session: UUID, text: String)]
    /// `status`'s notices for what waits on the user beyond its cards' own (each open card's is the desk's). On the
    /// engine's queue.
    func notices(_ desk: PluginDesk) -> [String]
    /// A value the user gives one of its settings (`vibeswitcher set KEY VALUE`, its declared key's name): as kept, nil
    /// for its default, or why it isn't taken. `value` is the value given ("default": nil).
    func check(setting name: String, value: String?) -> Result<String?, PluginRefusal>
}

extension FeaturePlugin {
    public func availability() -> String? { nil }
    public func notices(_ desk: PluginDesk) -> [String] { [] }
    public func turnedOff(_ desk: PluginDesk) -> [(session: UUID, text: String)] { [] }
    public func check(setting name: String, value: String?) -> Result<String?, PluginRefusal> { .success(value) }
}

/// What a plugin declares, as data.
public struct PluginInfo: Codable, Equatable, Sendable {
    /// A command an agent's session gets (on its PATH), and what it does in a line.
    public struct Command: Codable, Equatable, Sendable {
        public var name: String
        public var about: String
        public init(name: String, about: String) {
            self.name = name
            self.about = about
        }
    }

    /// One entry it adds to the settings catalog, under its own section (`NodeSettings`), kept in the host's vault
    /// (`LeadVaultV2.Book.pluginSettings`) as `<plugin>.<key>`, so no session's file write changes it.
    public struct Setting: Codable, Equatable, Sendable {
        /// Its name within the plugin: a short lower-case word (`chains`); the catalog's key is `<plugin>_<key>`.
        public var key: String
        public var title: String
        public var about: String
        /// `NodeSettings.Form`'s word.
        public var form: String
        public var choices: [String]
        /// Its value when the user set none.
        public var defaultValue: String
        public init(key: String, title: String, about: String, form: String, choices: [String] = [], defaultValue: String = "") {
            self.key = key
            self.title = title
            self.about = about
            self.form = form
            self.choices = choices
            self.defaultValue = defaultValue
        }
    }

    /// Lower case, short (`LeadVaultV2.pluginID`): `shell`.
    public var id: String
    /// "Shell requests".
    public var title: String
    /// One line a person reads in `plugin list`.
    public var summary: String
    public var defaultOn: Bool
    /// The commands sessions get.
    public var commands: [Command]
    /// The MCP tools behind them (listed only while it is on).
    public var tools: [String]
    /// Where its agent command files requests, under the node's root (nil: it files none). The core reads it (the one
    /// reader) and, while the plugin is off, drops what is there unread.
    public var folder: String?
    /// How long a card of its waits before it expires, at most `PluginInfo.longestLife` unless `lifeWhy` says why.
    public var life: TimeInterval
    public var lifeWhy: String?
    /// Its settings section's entries.
    public var settings: [Setting]
    /// What it adds to an agent's brief and to `vibeswitcher brief`, one line each.
    public var brief: [String]

    public init(id: String, title: String, summary: String, defaultOn: Bool, commands: [Command] = [], tools: [String] = [],
                folder: String? = nil, life: TimeInterval = PluginInfo.longestLife, lifeWhy: String? = nil, settings: [Setting] = [],
                brief: [String] = []) {
        self.id = id
        self.title = title
        self.summary = summary
        self.defaultOn = defaultOn
        self.commands = commands
        self.tools = tools
        self.folder = folder
        self.life = life
        self.lifeWhy = lifeWhy
        self.settings = settings
        self.brief = brief
    }

    /// A card's longest wait unless its plugin says why (the definition's rule 4).
    public static let longestLife: TimeInterval = 30 * 60

    /// Why this declaration can't be registered (nil: it can): an id the vault won't keep, a life past the longest
    /// with no reason, a folder outside the node's root.
    public var refusal: String? {
        guard LeadVaultV2.pluginID(id) else { return "plugin id \(id): 1 to 32 of a-z, 0-9 and -, starting with a letter" }
        guard life > 0, life <= Self.longestLife || !(lifeWhy ?? "").trimmingCharacters(in: .whitespaces).isEmpty else {
            return "plugin \(id): a card's life past \(Int(Self.longestLife / 60)) minutes needs a reason"
        }
        if let folder {
            let parts = folder.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !folder.hasPrefix("/"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                return "plugin \(id): its folder is a plain path under the node's root"
            }
            guard let first = parts.first, !Self.coreFolders.contains(first) else {
                return "plugin \(id): its folder \(folder) is in the node's own state (\(parts.first ?? ""))"
            }
        }
        return nil
    }

    /// What the node keeps at its root for itself: no plugin's folder is in one (the plugins' are `shell-requests` and
    /// `wallet-requests`, which the agents' commands write).
    public static let coreFolders: Set<String> = [
        "account-usage.json", "attachments", "bin", "boost.json", "context", "debug", "disk-watch.json", "headless", "health.json",
        "host.lock", "host.log", "host.sock", "lead", "mac-limits.json", "node-limits.json", "open-sessions.json", "outbox.json", "plugins", "plugins.json",
        "policy-told.json", "policy.md", "power.json", "presets.json", "prompt-audit.json", "room-waits", "run-blocks", "session-marks.json",
        "settings", "settings.plist", "sleep-cost.json", "state", "stats", "steer", "swap-samples.json", "tmp", "toolchain.json",
        "update-check.json", "v2", "vault-requests", "engine.json", "journal", "logs",
    ]
}

/// A plugin's card, as data (the definition's "The card is data"): one shape for every plugin, drawn by one renderer
/// per client (`CardText`, the page's `pluginCard`, the Mac's dialog text in `Requests.approvalCard`, `approve`'s list,
/// the brief). The host or the server derives the facts; the body is the decisive part, whole; the agent's own words are
/// the context, marked and cut, never before the body.
public struct PluginCard: Codable, Equatable, Sendable {
    /// A label and value the host or the server derived (never the agent's): the asking session, the folder, the chain.
    public struct Fact: Codable, Equatable, Sendable {
        /// What a refusal calls it ("folder").
        public var name: String
        /// As shown ("in the folder").
        public var label: String
        public var value: String
        /// A folder: shown as a path.
        public var folder: Bool
        /// Part of the decision: shown wherever the decisive part is (the Mac's dialog shows each, or asks nothing; the
        /// notice names each).
        public var decisive: Bool
        public init(name: String, label: String, value: String, folder: Bool = false, decisive: Bool = false) {
            self.name = name
            self.label = label
            self.value = value
            self.folder = folder
            self.decisive = decisive
        }
    }

    /// The decisive content, whole: lines of inert text and their size.
    public struct Body: Codable, Equatable, Sendable {
        /// What a refusal calls it ("command").
        public var name: String
        /// What precedes it ("running exactly this command").
        public var label: String
        /// What follows its size ("by your login shell, which stays open after it").
        public var note: String?
        public var lines: [String]
        public var bytes: Int
        public init(name: String, label: String, note: String? = nil, text: String) {
            self.name = name
            self.label = label
            self.note = note
            // By scalars: "\r\n" is one Character, two lines' worth of bytes.
            lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
            bytes = text.utf8.count
        }
        public var text: String { lines.joined(separator: "\n") }
        /// Its lines and bytes, as every client says them.
        public var size: String { PluginText.size(lines: lines.count, bytes: bytes) }
    }

    /// The agent's own words beside the decisive part ("named"), cut when long.
    public struct Context: Codable, Equatable, Sendable {
        public var name: String
        public var label: String
        public var text: String
        public init(name: String, label: String, text: String) {
            self.name = name
            self.label = label
            self.text = text
        }
    }

    /// An answer word.
    public struct Action: Codable, Equatable, Sendable {
        /// `vibeswitcher answer CARD WORD`.
        public var word: String
        /// A button's or a heading's word ("Run").
        public var label: String
        /// Whether it acts (runs code, moves money), beyond settling the card.
        public var acts: Bool
        /// What it does, after "it ": "runs it", "declines it" (the notice, the page's copy line).
        public var short: String
        /// What it does, whole, after "This " (before the code is asked): one line.
        public var does: String
        /// The Mac's dialog's decisive words ("run an agent's command in your login shell"); an acting one is followed by
        /// the body (one line, whole) and the folder.
        public var verb: String
        /// The state the card takes at once, before `perform` runs ("starting", "declined").
        public var marks: String
        public init(word: String, label: String, acts: Bool, short: String, does: String, verb: String, marks: String) {
            self.word = word
            self.label = label
            self.acts = acts
            self.short = short
            self.does = does
            self.verb = verb
            self.marks = marks
        }
    }

    public enum Severity: String, Codable, Sendable, CaseIterable { case blocking, important, whenever }

    /// The plugin's id.
    public var plugin: String
    /// The request's id, as the host stamped it.
    public var request: String
    /// The asking session (`NodeIds.session`), as the host placed the filing process.
    public var session: String
    /// That session's name as the node lists it.
    public var asker: String
    /// The card's heading ("A shell asked for").
    public var title: String
    /// What one is called in counts ("shell request").
    public var noun: String
    /// What the asker asks, after its name ("asks for a new shell session").
    public var ask: String
    public var facts: [Fact]
    public var body: Body
    public var context: Context?
    public var severity: Severity
    public var expiresAt: Date?
    public var actions: [Action]
    /// What waiting means ("nothing runs until you answer run").
    public var waiting: String?
    /// "waiting" while it can be answered; the plugin's word once settled ("withdrawn" when turned off).
    public var state: String
    /// What it says once settled.
    public var outcome: String?

    public init(plugin: String, request: String, session: String, asker: String, title: String, noun: String, ask: String,
                facts: [Fact], body: Body, context: Context? = nil, severity: Severity = .important,
                expiresAt: Date?, actions: [Action], waiting: String? = nil, state: String = PluginCard.waitingState,
                outcome: String? = nil) {
        self.plugin = plugin
        self.request = request
        self.session = session
        self.asker = asker
        self.title = title
        self.noun = noun
        self.ask = ask
        self.facts = facts
        self.body = body
        self.context = context
        self.severity = severity
        self.expiresAt = expiresAt
        self.actions = actions
        self.waiting = waiting
        self.state = state
        self.outcome = outcome
    }

    public static let waitingState = "waiting"
    public static let withdrawnState = "withdrawn"

    public var isWaiting: Bool { state == Self.waitingState }

    /// The action `text` names: its word, any case, spaces and line breaks at its ends dropped.
    public func action(_ text: String) -> Action? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return actions.first { $0.word == word }
    }

    /// The folder a fact names, when one does.
    public var folder: String? { facts.first(where: \.folder)?.value }

    /// The most a body holds: it is shown whole, so one that doesn't fit is refused, never cut.
    public static let bodyBytesAtMost = 16 * 1024
    public static let bodyLinesAtMost = 400
    /// The agent's words are cut past this.
    public static let contextAtMost = 400

    /// Why this card isn't drawn (nil: it may be): a value that draws as blank or nothing (`PluginText.blank`) or holds a
    /// control character but a tab or a line feed, a body past what is shown whole, no actions, a word twice, an action
    /// that would leave it waiting. The asker's name (the user's, or the host's) is checked for control characters only:
    /// an emoji's variation selector there refuses nothing. Its asker is told why.
    public var refusal: String? {
        var named: [(String, String)] = facts.map { ($0.name, $0.value) } + [(body.name, body.text)]
        if let context { named.append((context.name, context.text)) }
        for (name, text) in named {
            if let scalar = text.unicodeScalars.first(where: PluginText.blank) {
                return "its \(name) holds a character that draws as blank or nothing (U+\(String(format: "%04X", scalar.value))), "
                    + "which could hide part of it on the card: it wasn't shown, and nothing ran. File it again with plain spaces"
            }
            if let scalar = text.unicodeScalars.first(where: { PluginText.control($0) && $0 != "\n" && $0 != "\t" }) {
                return "its \(name) holds a control character (U+\(String(format: "%04X", scalar.value))): it wasn't shown, and nothing ran"
            }
        }
        if asker.unicodeScalars.contains(where: PluginText.control) { return "its asker's name holds a control character" }
        if let waiting = actions.first(where: { $0.marks == Self.waitingState }) {
            return "its answer \(waiting.word) would leave it waiting: an answer is taken once"
        }
        guard body.bytes <= Self.bodyBytesAtMost, body.lines.count <= Self.bodyLinesAtMost else {
            return "its \(body.name) is \(body.size), more than a card shows whole (\(Self.bodyLinesAtMost) lines, "
                + "\(Self.bodyBytesAtMost / 1024) KiB): it wasn't shown, and nothing ran"
        }
        guard !actions.isEmpty, Set(actions.map(\.word)).count == actions.count else { return "its answer words are none, or one twice" }
        return nil
    }

    /// The card with its context cut to `contextAtMost` (marked "…"): what is drawn.
    public var drawn: PluginCard {
        var card = self
        if let context, context.text.count > Self.contextAtMost {
            card.context?.text = String(context.text.prefix(Self.contextAtMost)) + " …"
        }
        return card
    }
}

/// The text rules every plugin's card keeps (the shell review's of 2026-11-21, now the registry's).
public enum PluginText {
    /// Whether `scalar` draws as blank or nothing: non-ASCII white space (U+00A0, U+2003, U+3000…), the Hangul fillers
    /// (U+115F, U+1160, U+3164, U+FFA0), the braille blank (U+2800), default-ignorable code points (U+034F, U+200B,
    /// U+E0100…) and variation selectors (U+FE0F…).
    public static func blank(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return false }
        let properties = scalar.properties
        return properties.isWhitespace || properties.isDefaultIgnorableCodePoint || properties.isVariationSelector
            || [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800].contains(scalar.value)
    }

    /// Whether `scalar` is a control character (C0, DEL, C1).
    public static func control(_ scalar: Unicode.Scalar) -> Bool { scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) }

    /// "2 lines, 43 bytes".
    public static func size(lines: Int, bytes: Int) -> String { "\(lines) line\(lines == 1 ? "" : "s"), \(bytes) bytes" }

    /// `text`'s size as a body's: its lines and UTF-8 bytes.
    public static func size(_ text: String) -> String {
        size(lines: text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).count, bytes: text.utf8.count)
    }
}
