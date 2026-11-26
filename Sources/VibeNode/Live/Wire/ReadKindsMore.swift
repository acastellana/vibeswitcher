import Foundation

// The rest of the command line's read kinds, typed as ReadKinds.swift's are (`WireKind`).

extension WireKinds {
    /// `brief [FOLDER]`: the briefing (`Requests.briefValue`).
    public enum Brief: WireKind {
        public static let kind = "brief"

        public struct Args: Codable, Sendable, Equatable {
            public var folder: String?
            public init(folder: String? = nil) { self.folder = folder }
        }

        public struct Result: Codable, Sendable, Equatable {
            public var text: String?
            public var byModel: Bool?
            public var language: String?
            public var at: String?
            @WireNull public var notice: String?
            public var asks: Int?
            public var kept: Bool?
            public init(text: String, byModel: Bool, language: String, at: String, notice: String?, asks: Int, kept: Bool) {
                self.text = text
                self.byModel = byModel
                self.language = language
                self.at = at
                self.notice = notice
                self.asks = asks
                self.kept = kept
            }
        }
    }

    /// `logs` (the no-terminal inventory's C8): the node's log's last lines as `vibeswitcher logs` shows them, masked
    /// (`NodeLogs.read`). `log`: "node" (the server's and the host's) or "sessions" (the host's session log); `cut`: the
    /// oldest lines left out to keep the reply bounded; `why`: why the log couldn't be read (no lines then).
    public enum Logs: WireKind {
        public static let kind = "logs"

        public struct Args: Codable, Sendable, Equatable {
            public var lines: Int?
            public var sessions: Bool?
            public init(lines: Int? = nil, sessions: Bool? = nil) {
                self.lines = lines
                self.sessions = sessions
            }
        }

        public struct Result: Codable, Sendable, Equatable {
            public var log: String?
            public var lines: [String]?
            public var cut: Int?
            @WireNull public var why: String?
            public init(log: String, lines: [String], cut: Int, why: String?) {
                self.log = log
                self.lines = lines
                self.cut = cut
                self.why = why
            }
        }
    }

    /// `status --check-updates`: the update watch's look (`UpdateWatch.checkedResult`): its record's answer for the build
    /// that runs, that build, and the notice a newer one gives.
    public enum UpdateCheck: WireKind {
        public static let kind = "update.check"
        public typealias Args = WireNoArgs

        public struct Result: Codable, Sendable, Equatable {
            @WireNull public var checkedAt: String?
            @WireNull public var commit: String?
            @WireNull public var aheadBy: Int?
            @WireNull public var install: String?
            @WireNull public var problem: String?
            public var running: String?
            @WireNull public var notice: String?
            public init(checkedAt: String?, commit: String?, aheadBy: Int?, install: String?, problem: String?, running: String?, notice: String?) {
                self.checkedAt = checkedAt
                self.commit = commit
                self.aheadBy = aheadBy
                self.install = install
                self.problem = problem
                self.running = running
                self.notice = notice
            }
        }
    }

    /// `mail [FOLDER] [--all]`: each project's messages between leads, newest first (`Requests.mail`).
    public enum Mail: WireKind {
        public static let kind = "mail"

        public struct Args: Codable, Sendable, Equatable {
            public var folder: String?
            public var all: Bool?
            public init(folder: String? = nil, all: Bool? = nil) {
                self.folder = folder
                self.all = all
            }
        }

        public struct Result: Codable, Sendable, Equatable {
            public var projects: [Project]?
            public init(projects: [Project]) { self.projects = projects }
        }

        public struct Project: Codable, Sendable, Equatable {
            public var root: String?
            public var project: String?
            public var total: Int?
            public var messages: [Message]?
            public init(root: String, project: String, total: Int, messages: [Message]) {
                self.root = root
                self.project = project
                self.total = total
                self.messages = messages
            }
        }

        /// One message (`Requests.mailMessage`): a lead's words in `text` and `detail`.
        public struct Message: Codable, Sendable, Equatable {
            public var at: String?
            public var from: String?
            public var to: String?
            public var received: Bool?
            @WireNull public var kind: String?
            public var text: String?
            public var outcome: String?
            public var sent: Bool?
            public var detail: String?
            public init(at: String, from: String, to: String, received: Bool, kind: String?, text: String, outcome: String, sent: Bool, detail: String) {
                self.at = at
                self.from = from
                self.to = to
                self.received = received
                self.kind = kind
                self.text = text
                self.outcome = outcome
                self.sent = sent
                self.detail = detail
            }
        }
    }

    /// `session.presets [folder] [values]`: the launch presets (each `SessionPresets.value`, an entity the page shows
    /// too) and what in the file couldn't be read.
    public enum Presets: WireKind {
        public static let kind = "session.presets"

        public struct Args: Codable, Sendable, Equatable {
            public var folder: String?
            public var values: Bool?
            public init(folder: String? = nil, values: Bool? = nil) {
                self.folder = folder
                self.values = values
            }
        }

        public struct Result: Codable, Sendable, Equatable {
            public var presets: [NodeWire.Value]?
            public var problems: [String]?
            public init(presets: [NodeWire.Value], problems: [String]) {
                self.presets = presets
                self.problems = problems
            }
        }
    }

    /// `shells [folder]`: the node's shell sessions and whether each is finished.
    public enum Shells: WireKind {
        public static let kind = "shells"

        public struct Args: Codable, Sendable, Equatable {
            public var folder: String?
            public init(folder: String? = nil) { self.folder = folder }
        }

        public struct Result: Codable, Sendable, Equatable {
            public var shells: [Shell]?
            public init(shells: [Shell]) { self.shells = shells }
        }

        public struct Shell: Codable, Sendable, Equatable {
            public var session: String?
            public var folder: String?
            public var terminal: String?
            public var finished: Bool?
            public init(session: String, folder: String, terminal: String, finished: Bool) {
                self.session = session
                self.folder = folder
                self.terminal = terminal
                self.finished = finished
            }
        }
    }

    /// `stats [range]`: the Mac's statistics page for the node (`StatisticsWire`); its figures, rows and quality are the
    /// page's shapes too, and stay values (`StatisticsText` reads them).
    public enum Stats: WireKind {
        public static let kind = "stats"

        public struct Args: Codable, Sendable, Equatable {
            public var range: String?
            public init(range: String? = nil) { self.range = range }
        }

        public struct Result: Codable, Sendable {
            public var range: String?
            public var title: String?
            public var span: String?
            public var mac: [NodeWire.Value]?
            public var columns: [String]?
            public var projects: [NodeWire.Value]?
            @WireNull public var total: NodeWire.Value?
            @WireNull public var quality: NodeWire.Value?
            public init(range: String, title: String, span: String, mac: [NodeWire.Value], columns: [String], projects: [NodeWire.Value],
                        total: NodeWire.Value?, quality: NodeWire.Value?) {
                self.range = range
                self.title = title
                self.span = span
                self.mac = mac
                self.columns = columns
                self.projects = projects
                self.total = total
                self.quality = quality
            }
        }
    }

    /// `base show FOLDER [--from COMMIT]`: the base move's card (an entity); none, and `unmoved` the head, when the base
    /// is where the vault recorded it: nothing to accept.
    public enum BaseShow: WireKind {
        public static let kind = "base.show"

        public struct Args: Codable, Sendable, Equatable {
            public var folder: String?
            public var from: String?
            public init(folder: String? = nil, from: String? = nil) {
                self.folder = folder
                self.from = from
            }
        }

        public struct Result: Codable, Sendable {
            public var card: NodeWire.Value?
            public var branch: String?
            public var unmoved: String?
            public init(card: NodeWire.Value) { self.card = card }
            public init(branch: String, unmoved head: String) {
                self.branch = branch
                self.unmoved = head
            }
        }
    }
}
