import Foundation

// The state-changing kinds, typed (`WireKind`, WireKinds.swift): each one's arguments (`WireArgs`: the keys it takes are
// its coding keys, and `RequestArguments` refuses any other, naming it) and its result. Sent only through
// `NodeClient.change`, after the typed word; recorded in the vault before they act (`Requests.recorded`).
// `@WireNull`: written as `null` when it has nothing; `@WireMaybe`: left out by one of the kind's replies and `null` in
// another; a plain optional: left out when it has nothing.

extension WireKinds {
    /// The state-changing kinds typed: `WireKindsLintTests` holds the command line to sending them through their types,
    /// and `RequestArguments` takes their keys from them.
    public static let changes: [any WireChangeKind.Type] = KindSpec.all.compactMap { $0.typed as? any WireChangeKind.Type }

    // MARK: The node

    public enum Start: WireChangeKind {
        public static let kind = "start"
        public typealias Args = WireNoArgs
        public struct Result: Codable, Sendable, Equatable {
            public var running: Bool?
            public var serverStartedAt: String?
            @WireNull public var hostStartedAt: String?
            public var epoch: String?
            public init(running: Bool, serverStartedAt: String, hostStartedAt: String?, epoch: String) {
                self.running = running
                self.serverStartedAt = serverStartedAt
                self.hostStartedAt = hostStartedAt
                self.epoch = epoch
            }
        }
    }

    public enum Stop: WireChangeKind {
        public static let kind = "stop"
        public typealias Args = WireNoArgs
        public struct Result: Codable, Sendable, Equatable {
            public var sessionsEnded: Int?
            public var host: String?
            public init(sessionsEnded: Int, host: String) {
                self.sessionsEnded = sessionsEnded
                self.host = host
            }
        }
    }

    public enum Lead: WireChangeKind {
        public static let kind = "lead"
        public struct Args: WireArgs, Equatable {
            public var folder: String?
            public var goal: String?
            public var takeHead: Bool?
            public var replace: Bool?
            public var resume: Bool?
            public var initialized: Bool?
            public enum CodingKeys: String, CodingKey, CaseIterable { case folder, goal, takeHead, replace, resume, initialized }
            public init(folder: String?, goal: String? = nil, takeHead: Bool? = nil, replace: Bool? = nil, resume: Bool? = nil, initialized: Bool? = nil) {
                self.folder = folder
                self.goal = goal
                self.takeHead = takeHead
                self.replace = replace
                self.resume = resume
                self.initialized = initialized
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var happened: String?
            @WireNull public var session: String?
            @WireNull public var program: String?
            public var notes: [String]?
            public init(happened: String, session: String?, program: String?, notes: [String]) {
                self.happened = happened
                self.session = session
                self.program = program
                self.notes = notes
            }
        }
    }

    // MARK: Cards

    /// A card's code and id: what `hold`, `base accept` and `base keep` take.
    public struct CardArgs: WireArgs, Equatable {
        public var card: String?
        public var code: String?
        public enum CodingKeys: String, CodingKey, CaseIterable { case card, code }
        public init(card: String?, code: String?) {
            self.card = card
            self.code = code
        }
    }

    /// `answer CARD TEXT`: a lead's question or approval answered (`outcome`, `notice`, the card as it is now), or a
    /// feature plugin's card settled (its own result: `outcome`, and what the plugin says, as `say`, `session`,
    /// `terminal` or fields of its own). An open result: its known fields typed, every field kept as the server sent
    /// it (a plugin's own too), so it encodes byte for byte.
    public enum Answer: WireChangeKind {
        public static let kind = "answer"
        public struct Args: WireArgs, Equatable {
            public var card: String?
            public var code: String?
            public var text: String?
            public var version: Int?
            public enum CodingKeys: String, CodingKey, CaseIterable { case card, code, text, version }
            public init(card: String?, code: String?, text: String?, version: Int? = nil) {
                self.card = card
                self.code = code
                self.text = text
                self.version = version
            }
        }

        public struct Result: Codable, Sendable, Equatable {
            /// Every field, as sent.
            public var fields: [String: NodeWire.Value]

            public init(fields: [String: NodeWire.Value]) { self.fields = fields }

            /// A lead's card answered: what came of it, a notice, the card now.
            public init(outcome: String, notice: String?, card: NodeWire.Value?) {
                fields = ["outcome": .string(outcome), "notice": notice.map(NodeWire.Value.string) ?? .null, "card": card ?? .null]
            }

            public var outcome: String? { fields["outcome"]?.string }
            public var notice: String? { fields["notice"]?.string }
            public var card: NodeWire.Value? { fields["card"].flatMap { $0 == .null ? nil : $0 } }
            public var say: [String]? { fields["say"]?.array?.compactMap(\.string) }
            public var session: String? { fields["session"]?.string }
            public var terminal: String? { fields["terminal"]?.string }

            public init(from decoder: Decoder) throws {
                fields = try NodeWire.Value(from: decoder).object ?? [:]
            }

            public func encode(to encoder: Encoder) throws {
                try NodeWire.Value.object(fields).encode(to: encoder)
            }
        }
    }

    public enum Hold: WireChangeKind {
        public static let kind = "hold"
        public typealias Args = CardArgs
        public struct Result: Codable, Sendable {
            public var held: Bool?
            @WireNull public var card: NodeWire.Value?
            public init(held: Bool, card: NodeWire.Value?) {
                self.held = held
                self.card = card
            }
        }
    }

    public enum ConfigAccept: WireChangeKind {
        public static let kind = "config.accept"
        public struct Args: WireArgs, Equatable {
            public var card: String?
            public var code: String?
            public var batch: Bool?
            public enum CodingKeys: String, CodingKey, CaseIterable { case card, code, batch }
            public init(card: String?, code: String?, batch: Bool? = nil) {
                self.card = card
                self.code = code
                self.batch = batch
            }
        }
        public struct Result: Codable, Sendable {
            public var sealed: [String]?
            public var floorRecorded: Bool?
            @WireNull public var card: NodeWire.Value?
            /// What the card left to the home folder's card (`ConfigHoldStore.SharedHome`) and is still held, that card
            /// and its folder: this folder's first look goes on until it is accepted, then this folder's card again.
            public var homeWaits: [String]?
            public var homeCard: String?
            public var homeFolder: String?
            public init(sealed: [String], floorRecorded: Bool, card: NodeWire.Value?) {
                self.sealed = sealed
                self.floorRecorded = floorRecorded
                self.card = card
            }
        }
    }

    public enum BaseAccept: WireChangeKind {
        public static let kind = "base.accept"
        public typealias Args = CardArgs
        public struct Result: Codable, Sendable {
            public var head: String?
            public var branch: String?
            @WireNull public var card: NodeWire.Value?
            public init(head: String, branch: String, card: NodeWire.Value?) {
                self.head = head
                self.branch = branch
                self.card = card
            }
        }
    }

    public enum BaseKeep: WireChangeKind {
        public static let kind = "base.keep"
        public typealias Args = CardArgs
        public struct Result: Codable, Sendable {
            public var kept: Bool?
            @WireNull public var card: NodeWire.Value?
            public init(kept: Bool, card: NodeWire.Value?) {
                self.kept = kept
                self.card = card
            }
        }
    }

    // MARK: Hooks, builds, the web

    /// The agents whose hooks `hooks install` and `hooks remove` act on.
    public struct AgentsArgs: WireArgs, Equatable {
        public var agents: [String]?
        public enum CodingKeys: String, CodingKey, CaseIterable { case agents }
        public init(agents: [String]?) { self.agents = agents }
    }

    /// `hooks install`'s: the agents, and `codex`, the Codex program the user was shown before the typed code (the link
    /// `NodePreflight.codex` resolves): the server trusts the Codex hooks by running it, only when it still resolves so.
    public struct HooksInstallArgs: WireArgs, Equatable {
        public var agents: [String]?
        public var codex: String?
        public enum CodingKeys: String, CodingKey, CaseIterable { case agents, codex }
        public init(agents: [String]?, codex: String? = nil) {
            self.agents = agents
            self.codex = codex
        }
    }

    public enum HooksInstall: WireChangeKind {
        public static let kind = "hooks.install"
        public typealias Args = HooksInstallArgs
        /// `trusted`: the Codex hooks trusted (`NodeCodexTrust`), absent when none was tried; `trustNote`: why none was
        /// (or what was refused).
        public struct Result: Codable, Sendable, Equatable {
            public var programs: [String]?
            public var configs: [String]?
            public var trusted: Int?
            public var trustNote: String?
            public init(programs: [String], configs: [String], trusted: Int? = nil, trustNote: String? = nil) {
                self.programs = programs
                self.configs = configs
                self.trusted = trusted
                self.trustNote = trustNote
            }
        }
    }

    public enum HooksRemove: WireChangeKind {
        public static let kind = "hooks.remove"
        public typealias Args = AgentsArgs
        public struct Result: Codable, Sendable, Equatable {
            public var configs: [String]?
            public init(configs: [String]) { self.configs = configs }
        }
    }

    /// `switch COMMIT` (`SwitchRequest`): `already`, or `handed-over` with the build it came from, the host's pid and
    /// whether it answered past the wait; the workers parked first, when any were.
    public enum BuildSwitch: WireChangeKind {
        public static let kind = "build.switch"
        public struct Args: WireArgs, Equatable {
            public var commit: String?
            /// `vibeswitcher update`'s: the builds folder's listing lines before and its listing hash right after the
            /// install it ran (`SwitchSealCheck.InstallSeen`): the folder is sealed as it was then, when the checks pass,
            /// before the plan.
            public var buildsBeforeListing: [String]?
            public var buildsAfter: String?
            public enum CodingKeys: String, CodingKey, CaseIterable { case commit, buildsBeforeListing, buildsAfter }
            public init(commit: String?, buildsBeforeListing: [String]? = nil, buildsAfter: String? = nil) {
                self.commit = commit
                self.buildsBeforeListing = buildsBeforeListing
                self.buildsAfter = buildsAfter
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var outcome: String?
            public var commit: String?
            @WireMaybe public var from: String?
            @WireMaybe public var pid: Int?
            public var afterTheWait: Bool?
            public var said: String?
            public var parked: [String]?
            /// With `buildsBefore` and `buildsAfter`: what was sealed (`~/.vibeswitcher/v2/builds`), what stays held, and
            /// why the folder wasn't sealed when it wasn't.
            public var sealed: [String]?
            public var held: [String]?
            public var sealRefusals: [String]?
            public init(outcome: String, commit: String, said: String) {
                self.outcome = outcome
                self.commit = commit
                self.said = said
            }
        }
    }

    /// `build.seal` (`vibeswitcher update`, after the switch's follow-up, naming the switch's action): the node's unit
    /// folder sealed when its unit's `ExecStart` moved from `from`'s build to `commit`'s and nothing else
    /// (`SwitchSealCheck.sealUnit`), taken only for that switch's completed handover (`Requests.sealRefusal`).
    public enum BuildSeal: WireChangeKind {
        public static let kind = "build.seal"
        public struct Args: WireArgs, Equatable {
            public var commit: String?
            public var from: String?
            /// The switch's own action id: this request has an action of its own (a server that answered the switch
            /// keeps its reply under that action, for that request's retries alone).
            public var switchAction: String?
            /// The builds folder's listing just before the switch's follow-up (`SwitchSeal.listingLines`): `current`, as
            /// the follow-up moves it, is sealed against it (`SwitchSealCheck`, c).
            public var buildsBefore: [String]?
            public enum CodingKeys: String, CodingKey, CaseIterable { case commit, from, switchAction, buildsBefore }
            public init(commit: String?, from: String?, switchAction: String?, buildsBefore: [String]? = nil) {
                self.commit = commit
                self.from = from
                self.switchAction = switchAction
                self.buildsBefore = buildsBefore
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var sealed: [String]?
            public var held: [String]?
            public var sealRefusals: [String]?
            public init(sealed: [String], held: [String], sealRefusals: [String]) {
                self.sealed = sealed
                self.held = held
                self.sealRefusals = sealRefusals
            }
        }
    }

    public enum WebOpen: WireChangeKind {
        public static let kind = "web.open"
        public struct Args: WireArgs, Equatable {
            public var tailnet: Bool?
            /// The address at `http://localhost:PORT` (the origin a passkey works on); the level `confirm` gives it anyway.
            public var localhost: Bool?
            public enum CodingKeys: String, CodingKey, CaseIterable { case tailnet, localhost }
            public init(tailnet: Bool? = nil, localhost: Bool? = nil) {
                self.tailnet = tailnet
                self.localhost = localhost
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var url: String?
            public var expiresIn: Int?
            public var tailnet: Bool?
            /// The code's id: what `web.pairing` and `web.confirm` name (the loopback page's; none on the tailnet).
            public var code: String?
            public init(url: String, expiresIn: Int, tailnet: Bool? = nil, code: String? = nil) {
                self.url = url
                self.expiresIn = expiresIn
                self.tailnet = tailnet
                self.code = code
            }
        }
    }

    /// `web.passkey.add` (the user's voice, recorded): the passkey a confirmed page registered for `register` (the
    /// terminal's `web.passkey`), kept in the vault for the level `confirm`, once `typed` is its id's first characters
    /// as the user read them off the page that made it.
    public enum WebPasskeyAdd: WireChangeKind {
        public static let kind = "web.passkey.add"
        public struct Args: WireArgs, Equatable {
            public var register: String?
            public var typed: String?
            public enum CodingKeys: String, CodingKey, CaseIterable { case register, typed }
            public init(register: String, typed: String) {
                self.register = register
                self.typed = typed
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var id: String?
            public var keys: Int?
            public init(id: String, keys: Int) {
                self.id = id
                self.keys = keys
            }
        }
    }

    /// `web.passkey.forget` (the user's voice, recorded): the passkeys whose id starts with `id` dropped (`all`: every one).
    public enum WebPasskeyForget: WireChangeKind {
        public static let kind = "web.passkey.forget"
        public struct Args: WireArgs, Equatable {
            public var id: String?
            public enum CodingKeys: String, CodingKey, CaseIterable { case id }
            public init(id: String) { self.id = id }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var forgotten: [String]?
            public var keys: Int?
            public init(forgotten: [String], keys: Int) {
                self.forgotten = forgotten
                self.keys = keys
            }
        }
    }

    /// `web.confirm` (the user's voice, recorded): the page that took the address `web.open` made, showing `phrase`,
    /// confirmed as the user's (the acting review's fix A).
    public enum WebConfirm: WireChangeKind {
        public static let kind = "web.confirm"
        public struct Args: WireArgs, Equatable {
            public var code: String?
            public var phrase: String?
            public enum CodingKeys: String, CodingKey, CaseIterable { case code, phrase }
            public init(code: String, phrase: String) {
                self.code = code
                self.phrase = phrase
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var confirmed: Bool?
            public var rights: [String]?
            public var level: String?
            public init(confirmed: Bool, rights: [String], level: String) {
                self.confirmed = confirmed
                self.rights = rights
                self.level = level
            }
        }
    }

    public enum WebRevoke: WireChangeKind {
        public static let kind = "web.revoke"
        public typealias Args = WireNoArgs
        public struct Result: Codable, Sendable, Equatable {
            public var revoked: Int?
            public var tailnetRevoked: Int?
            public init(revoked: Int, tailnetRevoked: Int) {
                self.revoked = revoked
                self.tailnetRevoked = tailnetRevoked
            }
        }
    }

    // MARK: Leads

    /// `answer.replace` (2026-11-24): the user's answer on `card` taken back before its lead had it, and `text` sent in
    /// its place (`LeadEngine.replaceAnswer`); refused `delivered` when the lead has the first one.
    public enum AnswerReplace: WireChangeKind {
        public static let kind = "answer.replace"
        public struct Args: WireArgs, Equatable {
            public var card: String?
            public var code: String?
            public var text: String?
            public var version: Int?
            public enum CodingKeys: String, CodingKey, CaseIterable { case card, code, text, version }
            public init(card: String?, code: String?, text: String?, version: Int? = nil) {
                self.card = card
                self.code = code
                self.text = text
                self.version = version
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var outcome: String?
            public var card: NodeWire.Value?
            public init(outcome: String, card: NodeWire.Value?) {
                self.outcome = outcome
                self.card = card
            }
        }
    }

    /// `tell.retract` (2026-11-24): the user's tell under `action` taken back before its lead had it
    /// (`LeadEngine.retractTell`); refused `delivered` when the lead has it.
    public enum TellRetract: WireChangeKind {
        public static let kind = "tell.retract"
        public struct Args: WireArgs, Equatable {
            public var action: String?
            public enum CodingKeys: String, CodingKey, CaseIterable { case action }
            public init(action: String?) { self.action = action }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var retracted: Bool?
            public init(retracted: Bool) { self.retracted = retracted }
        }
    }

    public enum Tell: WireChangeKind {
        public static let kind = "tell"
        public struct Args: WireArgs, Equatable {
            public var folder: String?
            public var text: String?
            public enum CodingKeys: String, CodingKey, CaseIterable { case folder, text }
            public init(folder: String?, text: String?) {
                self.folder = folder
                self.text = text
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var project: String?
            public var session: String?
            public init(project: String, session: String) {
                self.project = project
                self.session = session
            }
        }
    }

    /// The folder of a lead's push request and its id: what `push` and `decline-push` take.
    public struct PushArgs: WireArgs, Equatable {
        public var folder: String?
        public var request: String?
        public enum CodingKeys: String, CodingKey, CaseIterable { case folder, request }
        public init(folder: String?, request: String?) {
            self.folder = folder
            self.request = request
        }
    }

    /// What came of a push request (`LeadEngine.settlePush`).
    public struct PushResult: Codable, Sendable, Equatable {
        public var request: String?
        public var settled: String?
        public var ok: Bool?
        public var said: String?
        @WireNull public var target: String?
        public init(request: String, settled: String, ok: Bool, said: String, target: String?) {
            self.request = request
            self.settled = settled
            self.ok = ok
            self.said = said
            self.target = target
        }
    }

    public enum Push: WireChangeKind {
        public static let kind = "push"
        public typealias Args = PushArgs
        public typealias Result = PushResult
    }

    public enum PushDecline: WireChangeKind {
        public static let kind = "push.decline"
        public typealias Args = PushArgs
        public typealias Result = PushResult
    }

    public enum PromptAudit: WireChangeKind {
        public static let kind = "prompt-audit"
        public struct Args: WireArgs, Equatable {
            public var folder: String?
            public var `do`: String?
            public enum CodingKeys: String, CodingKey, CaseIterable { case folder, `do` }
            public init(folder: String?, do change: String?) {
                self.folder = folder
                self.do = change
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var project: String?
            public var root: String?
            public var `do`: String?
            @WireNull public var until: String?
            public init(project: String, root: String, do change: String, until: String?) {
                self.project = project
                self.root = root
                self.do = change
                self.until = until
            }
        }
    }

    // MARK: Sessions

    /// One session, by id or terminal: what `session.end` and `session.resume` take.
    public struct SessionArgs: WireArgs, Equatable {
        public var session: String?
        public enum CodingKeys: String, CodingKey, CaseIterable { case session }
        public init(session: String?) { self.session = session }
    }

    public enum Send: WireChangeKind {
        public static let kind = "send"
        public struct Args: WireArgs, Equatable {
            public var session: String?
            public var text: String?
            public var images: [String]?
            /// An older page's and command line's `now: true`: taken as `when: now`.
            public var now: Bool?
            /// When it reaches the agent (`SendWhen`): step, now, after, interrupt; absent: typed in as before.
            public var when: String?
            public enum CodingKeys: String, CodingKey, CaseIterable { case session, text, images, now, when }
            public init(session: String?, text: String?, images: [String]? = nil, now: Bool? = nil, when: String? = nil) {
                self.session = session
                self.text = text
                self.images = images
                self.now = now
                self.when = when
            }
        }
        /// What became of it: typed in now, opened, waiting (`waits`), steered in while working, or an answer to the
        /// question on its screen; each of those only when it happened.
        public struct Result: Codable, Sendable, Equatable {
            public var session: String?
            public var terminal: String?
            public var working: Bool?
            public var characters: Int?
            public var queued: Bool?
            public var waits: String?
            public var opened: String?
            public var steered: Bool?
            public var answered: String?
            public var agent: String?
            /// With `when`: what was done (`SendWhen`), and why when it isn't what was asked.
            public var when: String?
            public var said: String?
            public init(session: String, terminal: String, working: Bool, characters: Int, queued: Bool) {
                self.session = session
                self.terminal = terminal
                self.working = working
                self.characters = characters
                self.queued = queued
            }
        }
    }

    public enum SessionNew: WireChangeKind {
        public static let kind = "session.new"
        public struct Args: WireArgs, Equatable {
            public var folder: String?
            public var preset: String?
            public var digest: String?
            public var agent: String?
            public var model: String?
            public enum CodingKeys: String, CodingKey, CaseIterable { case folder, preset, digest, agent, model }
            public init(folder: String?, preset: String? = nil, digest: String? = nil, agent: String? = nil, model: String? = nil) {
                self.folder = folder
                self.preset = preset
                self.digest = digest
                self.agent = agent
                self.model = model
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var session: String?
            public var terminal: String?
            public var agent: String?
            public var folder: String?
            @WireNull public var model: String?
            @WireNull public var preset: String?
            public init(session: String, terminal: String, agent: String, folder: String, model: String?, preset: String?) {
                self.session = session
                self.terminal = terminal
                self.agent = agent
                self.folder = folder
                self.model = model
                self.preset = preset
            }
        }
    }

    public enum SessionEnd: WireChangeKind {
        public static let kind = "session.end"
        public typealias Args = SessionArgs
        public struct Result: Codable, Sendable, Equatable {
            public var session: String?
            public var terminal: String?
            public var ended: Bool?
            public init(session: String, terminal: String, ended: Bool) {
                self.session = session
                self.terminal = terminal
                self.ended = ended
            }
        }
    }

    public enum SessionReply: WireChangeKind {
        public static let kind = "session.reply"
        public struct Args: WireArgs, Equatable {
            public var session: String?
            public var choice: Int?
            public var text: String?
            public var question: String?
            public var options: [String]?
            public enum CodingKeys: String, CodingKey, CaseIterable { case session, choice, text, question, options }
            public init(session: String?, choice: Int?, text: String? = nil, question: String?, options: [String]?) {
                self.session = session
                self.choice = choice
                self.text = text
                self.question = question
                self.options = options
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var session: String?
            public var terminal: String?
            public var choice: Int?
            public var option: String?
            public var question: String?
            public init(session: String, terminal: String, choice: Int, option: String, question: String) {
                self.session = session
                self.terminal = terminal
                self.choice = choice
                self.option = option
                self.question = question
            }
        }
    }

    public enum SessionRename: WireChangeKind {
        public static let kind = "session.rename"
        public struct Args: WireArgs, Equatable {
            public var session: String?
            public var name: String?
            public enum CodingKeys: String, CodingKey, CaseIterable { case session, name }
            public init(session: String?, name: String?) {
                self.session = session
                self.name = name
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var session: String?
            @WireNull public var name: String?
            public init(session: String, name: String?) {
                self.session = session
                self.name = name
            }
        }
    }

    public enum SessionPause: WireChangeKind {
        public static let kind = "session.pause"
        public struct Args: WireArgs, Equatable {
            public var session: String?
            public var `for`: String?
            public var hours: Int?
            public enum CodingKeys: String, CodingKey, CaseIterable { case session, `for`, hours }
            public init(session: String?, for span: String?, hours: Int? = nil) {
                self.session = session
                self.for = span
                self.hours = hours
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var session: String?
            @WireNull public var until: String?
            public init(session: String, until: String?) {
                self.session = session
                self.until = until
            }
        }
    }

    /// A session started again in its conversation (`session.reopen`, `session.resume`), and one that wasn't, with why.
    public struct Reopened: Codable, Sendable, Equatable {
        public var was: String?
        public var folder: String?
        public var conversation: String?
        public var session: String?
        public var terminal: String?
        public init(was: String, folder: String, conversation: String, session: String, terminal: String) {
            self.was = was
            self.folder = folder
            self.conversation = conversation
            self.session = session
            self.terminal = terminal
        }
    }

    public struct NotReopened: Codable, Sendable, Equatable {
        public var was: String?
        public var folder: String?
        public var why: String?
        public init(was: String, folder: String, why: String) {
            self.was = was
            self.folder = folder
            self.why = why
        }
    }

    /// What `session.reopen` and `session.resume` did; `forgotten`: how many offers `reopen --forget` put away.
    public struct ReopenResult: Codable, Sendable, Equatable {
        public var reopened: [Reopened]?
        public var refused: [NotReopened]?
        public var forgotten: Int?
        public init(reopened: [Reopened], refused: [NotReopened]) {
            self.reopened = reopened
            self.refused = refused
        }
        public init(forgotten: Int) { self.forgotten = forgotten }
    }

    public enum SessionResume: WireChangeKind {
        public static let kind = "session.resume"
        public typealias Args = SessionArgs
        public typealias Result = ReopenResult
    }

    public enum SessionReopen: WireChangeKind {
        public static let kind = "session.reopen"
        public struct Args: WireArgs, Equatable {
            public var forget: Bool?
            public var all: Bool?
            public var sessions: [String]?
            public enum CodingKeys: String, CodingKey, CaseIterable { case forget, all, sessions }
            public init(forget: Bool? = nil, all: Bool? = nil, sessions: [String]? = nil) {
                self.forget = forget
                self.all = all
                self.sessions = sessions
            }
        }
        public typealias Result = ReopenResult
    }

    public enum CloseShells: WireChangeKind {
        public static let kind = "session.close-shells"
        public struct Args: WireArgs, Equatable {
            public var sessions: [String]?
            public enum CodingKeys: String, CodingKey, CaseIterable { case sessions }
            public init(sessions: [String]?) { self.sessions = sessions }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var ended: [String]?
            public var left: [String]?
            public init(ended: [String], left: [String]) {
                self.ended = ended
                self.left = left
            }
        }
    }

    // MARK: Settings and presets

    public enum SetSetting: WireChangeKind {
        public static let kind = "set"
        public struct Args: WireArgs, Equatable {
            public var key: String?
            public var value: String?
            public var folder: String?
            public enum CodingKeys: String, CodingKey, CaseIterable { case key, value, folder }
            public init(key: String?, value: String?, folder: String? = nil) {
                self.key = key
                self.value = value
                self.folder = folder
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var key: String?
            public var value: String?
            public var was: String?
            public var scope: String?
            @WireNull public var project: String?
            @WireNull public var told: String?
            /// What to say of it (`web_acts`: what turning it on means); nil for every other setting.
            public var say: [String]?
            public init(key: String, value: String, was: String, scope: String, project: String?, told: String?) {
                self.key = key
                self.value = value
                self.was = was
                self.scope = scope
                self.project = project
                self.told = told
            }
        }
    }

    public enum PresetsEdit: WireChangeKind {
        public static let kind = "presets.edit"
        public struct Args: WireArgs, Equatable {
            public var op: String?
            public var name: String?
            public var folder: String?
            public var digest: String?
            public var rename: String?
            public var kind: String?
            public var args: String?
            public var env: [String: String]?
            public var unset: [String]?
            public var keepShell: Bool?
            public var `default`: Bool?
            public enum CodingKeys: String, CodingKey, CaseIterable { case op, name, folder, digest, rename, kind, args, env, unset, keepShell, `default` }
            public init(op: String?, name: String?) {
                self.op = op
                self.name = name
            }
        }
        public struct Result: Codable, Sendable, Equatable {
            public var op: String?
            public var name: String?
            @WireNull public var folder: String?
            public var env: [String]?
            public var held: Bool?
            public init(op: String, name: String, folder: String?, env: [String]?, held: Bool) {
                self.op = op
                self.name = name
                self.folder = folder
                self.env = env
                self.held = held
            }
        }
    }

    /// `approve`: each item done (with its own result), the one refused and why, the ones left.
    public enum Approve: WireChangeKind {
        public static let kind = "approve"
        public struct Args: WireArgs, Equatable {
            public var batch: String?
            public var code: String?
            public enum CodingKeys: String, CodingKey, CaseIterable { case batch, code }
            public init(batch: String?, code: String?) {
                self.batch = batch
                self.code = code
            }
        }
        public struct Result: Codable, Sendable {
            public var done: [Done]?
            @WireNull public var refused: Refused?
            public var left: [Left]?
            public init(done: [Done], refused: Refused?, left: [Left]) {
                self.done = done
                self.refused = refused
                self.left = left
            }
        }
        public struct Done: Codable, Sendable {
            public var kind: String?
            public var subject: String?
            public var action: String?
            /// The item's own kind's result, as its reply carried it.
            @WireNull public var result: NodeWire.Value?
            public init(kind: String, subject: String, action: String, result: NodeWire.Value?) {
                self.kind = kind
                self.subject = subject
                self.action = action
                self.result = result
            }
        }
        public struct Refused: Codable, Sendable, Equatable {
            public var kind: String?
            public var subject: String?
            public var action: String?
            public var code: String?
            public var message: String?
            public init(kind: String, subject: String, action: String, code: String, message: String) {
                self.kind = kind
                self.subject = subject
                self.action = action
                self.code = code
                self.message = message
            }
        }
        public struct Left: Codable, Sendable, Equatable {
            public var kind: String?
            public var subject: String?
            public init(kind: String, subject: String) {
                self.kind = kind
                self.subject = subject
            }
        }
    }

    // MARK: Feature plugins

    /// A feature plugin by its id: what `plugin on` and `plugin off` take.
    public struct PluginArgs: WireArgs, Equatable {
        public var plugin: String?
        public enum CodingKeys: String, CodingKey, CaseIterable { case plugin }
        public init(plugin: String?) { self.plugin = plugin }
    }

    /// Whether it is on now, and how many of its cards turning it off withdrew.
    public struct PluginSetResult: Codable, Sendable, Equatable {
        public var plugin: String?
        public var on: Bool?
        public var withdrawn: Int?
        public init(plugin: String, on: Bool, withdrawn: Int) {
            self.plugin = plugin
            self.on = on
            self.withdrawn = withdrawn
        }
    }

    public enum PluginOn: WireChangeKind {
        public static let kind = "plugin.on"
        public typealias Args = PluginArgs
        public typealias Result = PluginSetResult
    }

    public enum PluginOff: WireChangeKind {
        public static let kind = "plugin.off"
        public typealias Args = PluginArgs
        public typealias Result = PluginSetResult
    }
}

/// A state-changing kind: its arguments name the keys it takes.
public protocol WireChangeKind: WireKind where Args: WireArgs {}
