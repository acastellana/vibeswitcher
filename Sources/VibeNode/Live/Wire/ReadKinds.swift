import Foundation

// The read kinds the command line uses most, typed (`WireKind`, WireKinds.swift): each one's arguments and result, the
// result's fields in the order nothing (the encoder sorts them), each optional so an older server's reply decodes.
// `@WireNull`: a key the server writes as `null` when it has nothing; a plain optional: one it leaves out.

extension WireKinds {
    /// `status`: the node, its server and host, the sessions, leads and cards, what was accepted, the notices, and what a
    /// switch waits on (`Requests.statusResult`).
    public enum Status: WireKind {
        public static let kind = "status"
        public typealias Args = WireNoArgs

        public struct Result: Codable, Sendable {
            public var node: String?
            public var epoch: String?
            public var root: String?
            public var server: Server?
            public var host: Host?
            public var rule: Rule?
            /// The live wire's entities: each session's value (`Session.liveValue`), each lead's (`Requests.leadValue`).
            public var sessions: [NodeWire.Value]?
            public var leads: [NodeWire.Value]?
            public var cards: CardCounts?
            /// The feature plugins that are on (absent from a server before them).
            public var plugins: NodeWire.Value?
            /// The accepted requests, as the journal's entries carry them.
            public var accepted: [NodeWire.Value]?
            public var notices: [String]?
            public var reminders: [NodeWire.Value]?
            @WireNull public var restart: NodeWire.Value?
            public var reopen: NodeWire.Value?
            public var ended: NodeWire.Value?
            public var ending: NodeWire.Value?
            @WireNull public var builds: Builds?
            public var web: NodeWire.Value?
            @WireNull public var usage: NodeWire.Value?
            @WireNull public var boost: NodeWire.Value?
            public var switchBlockers: [String]?
            public var switchParks: [String]?
            /// The user's node's alone, each when it has one.
            public var webTailnet: NodeWire.Value?
            public var update: NodeWire.Value?
            public var health: NodeWire.Value?

            public init() {}
        }

        public struct Server: Codable, Sendable, Equatable {
            public var pid: Int?
            public var startedAt: String?
            public var commit: String?
            public init(pid: Int?, startedAt: String?, commit: String?) {
                self.pid = pid
                self.startedAt = startedAt
                self.commit = commit
            }
        }

        public struct Host: Codable, Sendable, Equatable {
            @WireNull public var startedAt: String?
            @WireNull public var pid: Int?
            public var state: String?
            public var liveSessions: Int?
            @WireNull public var notes: Notes?
            public init(startedAt: String?, pid: Int?, state: String?, liveSessions: Int?, notes: Notes?) {
                self.startedAt = startedAt
                self.pid = pid
                self.state = state
                self.liveSessions = liveSessions
                self.notes = notes
            }
        }

        /// The host's notes as last asked (`HostNotes`), and when.
        public struct Notes: Codable, Sendable, Equatable {
            public var startedAt: String?
            public var serverRestarts: Int?
            public var replacedPaths: [String]?
            public var refusedAppConnections: Int?
            @WireNull public var lockHeldElsewhere: String?
            @WireNull public var build: String?
            public var at: String?
            public init(startedAt: String?, serverRestarts: Int?, replacedPaths: [String]?, refusedAppConnections: Int?, lockHeldElsewhere: String?,
                        build: String?, at: String?) {
                self.startedAt = startedAt
                self.serverRestarts = serverRestarts
                self.replacedPaths = replacedPaths
                self.refusedAppConnections = refusedAppConnections
                self.lockHeldElsewhere = lockHeldElsewhere
                self.build = build
                self.at = at
            }
        }

        public struct Rule: Codable, Sendable, Equatable {
            public var mode: String?
            public var says: String?
            public var scopes: [String]?
            public init(mode: String?, says: String?, scopes: [String]?) {
                self.mode = mode
                self.says = says
                self.scopes = scopes
            }
        }

        /// The open cards, counted by kind.
        public struct CardCounts: Codable, Sendable, Equatable {
            public var questions: Int?
            public var approvals: Int?
            public var config: Int?
            public var base: Int?
            public init(questions: Int?, approvals: Int?, config: Int?, base: Int?) {
                self.questions = questions
                self.approvals = approvals
                self.config = config
                self.base = base
            }
        }

        /// The install root's builds and the rollback's target (`SwitchRequest.buildsValue`).
        public struct Builds: Codable, Sendable, Equatable {
            public var installRoot: String?
            public var installed: [String]?
            @WireNull public var rollback: Rollback?
            public init(installRoot: String?, installed: [String]?, rollback: Rollback?) {
                self.installRoot = installRoot
                self.installed = installed
                self.rollback = rollback
            }
        }

        public struct Rollback: Codable, Sendable, Equatable {
            public var commit: String?
            public var line: String?
            public init(commit: String?, line: String?) {
                self.commit = commit
                self.line = line
            }
        }
    }

    /// `questions [FOLDER] [--all | --wait]`, or one card by `card`: the cards (each `CardStore.Card.value`, an entity),
    /// how many closed ones were left out, and with `wait` whether it waited with none.
    public enum Questions: WireKind {
        public static let kind = "questions"

        public struct Args: Codable, Sendable, Equatable {
            public var card: String?
            public var folder: String?
            public var all: Bool?
            public var wait: Bool?
            public var limit: Int?
            public var seconds: Int?
            public init(card: String? = nil, folder: String? = nil, all: Bool? = nil, wait: Bool? = nil, limit: Int? = nil, seconds: Int? = nil) {
                self.card = card
                self.folder = folder
                self.all = all
                self.wait = wait
                self.limit = limit
                self.seconds = seconds
            }
        }

        public struct Result: Codable, Sendable {
            public var cards: [NodeWire.Value]?
            public var more: Int?
            public var waited: Bool?
            public init(cards: [NodeWire.Value], more: Int, waited: Bool? = nil) {
                self.cards = cards
                self.more = more
                self.waited = waited
            }
        }
    }

    /// `board [FOLDER]`: the boards (each `BoardValue`, an entity).
    public enum Board: WireKind {
        public static let kind = "board"

        public struct Args: Codable, Sendable, Equatable {
            public var folder: String?
            public init(folder: String? = nil) { self.folder = folder }
        }

        public struct Result: Codable, Sendable {
            public var boards: [NodeWire.Value]?
            public init(boards: [NodeWire.Value]) { self.boards = boards }
        }
    }

    /// `config held FOLDER [--diff NAME]`: the held config's card (an entity) and, with `diff`, what changed in that
    /// thing (its lines) or why there's nothing to show (a sentence).
    public enum ConfigHeld: WireKind {
        public static let kind = "config.held"

        public struct Args: Codable, Sendable, Equatable {
            public var folder: String?
            public var diff: String?
            public init(folder: String? = nil, diff: String? = nil) {
                self.folder = folder
                self.diff = diff
            }
        }

        public struct Result: Codable, Sendable {
            public var card: NodeWire.Value?
            public var difference: NodeWire.Value?
            public init(card: NodeWire.Value, difference: NodeWire.Value? = nil) {
                self.card = card
                self.difference = difference
            }
        }
    }

    /// `settings [FOLDER]`: the node's settings, a project's with a folder, what a node leaves out, the account's usage.
    public enum Settings: WireKind {
        public static let kind = "settings"

        public struct Args: Codable, Sendable, Equatable {
            public var folder: String?
            public init(folder: String? = nil) { self.folder = folder }
        }

        public struct Result: Codable, Sendable {
            public var node: Node?
            @WireNull public var project: Project?
            public var leftOut: [LeftOut]?
            public var usage: NodeWire.Value?
            public init(node: Node, project: Project?, leftOut: [LeftOut], usage: NodeWire.Value) {
                self.node = node
                self.project = project
                self.leftOut = leftOut
                self.usage = usage
            }
        }

        public struct Node: Codable, Sendable, Equatable {
            public var root: String?
            public var settings: [Setting]?
            public init(root: String, settings: [Setting]) {
                self.root = root
                self.settings = settings
            }
        }

        public struct Project: Codable, Sendable, Equatable {
            public var project: String?
            public var root: String?
            public var settings: [Setting]?
            public init(project: String, root: String, settings: [Setting]) {
                self.project = project
                self.root = root
                self.settings = settings
            }
        }

        /// One setting as shown (`NodeSettings.Shown.typed`).
        public struct Setting: Codable, Sendable, Equatable {
            public var key: String?
            public var title: String?
            public var about: String?
            public var section: String?
            public var scope: String?
            public var form: String?
            public var home: String?
            public var choices: [String]?
            @WireNull public var limits: String?
            public var value: String?
            public var `default`: String?
            public var isDefault: Bool?
            public var `where`: String?
            public var guardRail: Bool?
            @WireNull public var note: String?
            public init(key: String, title: String, about: String, section: String, scope: String, form: String, home: String, choices: [String],
                        limits: String?, value: String, default: String, isDefault: Bool, where: String, guardRail: Bool, note: String?) {
                self.key = key
                self.title = title
                self.about = about
                self.section = section
                self.scope = scope
                self.form = form
                self.home = home
                self.choices = choices
                self.limits = limits
                self.value = value
                self.default = `default`
                self.isDefault = isDefault
                self.where = `where`
                self.guardRail = guardRail
                self.note = note
            }
        }

        public struct LeftOut: Codable, Sendable, Equatable {
            public var title: String?
            public var why: String?
            public init(title: String, why: String) {
                self.title = title
                self.why = why
            }
        }
    }

    /// `plugin list`: each plugin's entry (the registry's value, an entity of the plugins' own).
    public enum PluginList: WireKind {
        public static let kind = "plugin.list"
        public typealias Args = WireNoArgs

        public struct Result: Codable, Sendable {
            public var plugins: [NodeWire.Value]?
            public init(plugins: [NodeWire.Value]) { self.plugins = plugins }
        }
    }

    /// `approve.list [only]`: what one code would settle (`items`, with the batch's id and code when there are any), what
    /// needs the user's own decision (`own`, `decide`: open questions and plugin cards, `pushes`: leads' roots).
    public enum ApproveList: WireKind {
        public static let kind = "approve.list"

        public struct Args: Codable, Sendable, Equatable {
            public var only: [String]?
            public init(only: [String]? = nil) { self.only = only }
        }

        public struct Result: Codable, Sendable {
            public var items: [Item]?
            public var decide: [NodeWire.Value]?
            public var pushes: [NodeWire.Value]?
            public var own: [Own]?
            public var batch: String?
            public var code: String?
            /// An acting page's list: how many items it left out (a page may not approve them) and what runs them.
            public var terminal: Terminal?
            public init(items: [Item], decide: [NodeWire.Value], pushes: [NodeWire.Value], own: [Own], batch: String? = nil, code: String? = nil) {
                self.items = items
                self.decide = decide
                self.pushes = pushes
                self.own = own
                self.batch = batch
                self.code = code
            }
        }

        public struct Terminal: Codable, Sendable, Equatable {
            public var count: Int?
            public var command: String?
            public init(count: Int, command: String) {
                self.count = count
                self.command = command
            }
        }

        public struct Item: Codable, Sendable {
            public var kind: String?
            public var subject: String?
            @WireNull public var card: NodeWire.Value?
            public var reasons: [String]?
            /// What an acting page names for it in `approve`'s `seen` (its card's `seen`, or the item's own digest).
            public var seen: String?
            public init(kind: String, subject: String, card: NodeWire.Value?, reasons: [String], seen: String? = nil) {
                self.kind = kind
                self.subject = subject
                self.card = card
                self.reasons = reasons
                self.seen = seen
            }
        }

        public struct Own: Codable, Sendable, Equatable {
            public var text: String?
            public var command: String?
            public init(text: String, command: String) {
                self.text = text
                self.command = command
            }
        }
    }
}
