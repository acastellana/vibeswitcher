import Foundation

/// The check every route onto the base makes of the commit about to become it, before the base moves (2026-11-07: a
/// correctly audited true merge landed flattened, and the other Mac's lead records were dropped). It runs inside the two
/// places that move a base (`Worktrees.fastForward`, `Worktrees.commitFiles`), on the commit given there: what the route
/// made, never the branch's head. Both take a `Landing`, so a new route can't leave it out.
extension Worktrees {
    /// What a route says of its landing, for the check.
    public struct Landing {
        /// Who's landing, for the refusal: "merge(fix-it)", "batch (a, b)", "merge_remote", "revert(fix-it)", "records commit".
        public var route: String
        /// `records_dir`; nil when the lead's records aren't in the repository.
        public var records: String?
        /// The remote's commits the candidate is meant to carry, each worked out before the route made its candidate
        /// (from the audited branch, or the fetched tip): read from the candidate, a flattened one would carry none.
        public var carried: [String]
        /// Runs its body under the records' lock (`BoardStore.withRecordsLock`), for the lines not committed yet that
        /// the fast-forward must keep (`landKeepingRecords`); nil: they stop it, as anyone's uncommitted files do.
        public var lockRecords: ((() -> Merge) throws -> Merge)?
        /// A test's stand-in for a route gone wrong, or for git failing; nil in the app.
        public var probe: LandingProbe?

        public init(route: String, records: String?, carried: [String] = [], lockRecords: ((() -> Merge) throws -> Merge)? = nil,
                    probe: LandingProbe? = nil) {
            self.route = route
            self.records = records
            self.carried = carried
            self.lockRecords = lockRecords
            self.probe = probe
        }

        /// A landing with nothing to check: no records in the repository and no remote carried.
        public static func unchecked(_ route: String) -> Landing { Landing(route: route, records: nil) }

        func git(_ args: [String], in root: String) -> Git.Result {
            probe?.git?(args) ?? Git.run(args, in: root, timeout: landingCheckTimeout)
        }
    }

    /// See `Landing.probe`.
    public struct LandingProbe: @unchecked Sendable {
        /// Given the commit a route made, the one it's taken to have made; also how a test sees what's checked.
        public var candidate: ((String) -> String)?
        /// Answers the check's git in place of git, or nil to let it run.
        public var git: (([String]) -> Git.Result?)?

        public init(candidate: ((String) -> String)? = nil, git: (([String]) -> Git.Result?)? = nil) {
            self.candidate = candidate
            self.git = git
        }
    }

    /// How long each of the check's git commands may run.
    static let landingCheckTimeout: TimeInterval = 30

    /// The records whose lines may not be lost, and where each one's lines may go instead: `archive_decisions` and the
    /// month's roll of progress.md move them, unchanged.
    private static let guarded: [(kind: LeadRecords.Kind, archive: LeadRecords.Kind?)] = [
        (.decisions, .archive), (.incidents, nil), (.progress, .progressArchive)
    ]

    /// Why `candidate` may not become `base` (at `from`), naming the route, the file and what's missing; nil when it may.
    /// Anything it can't read or can't make sense of refuses too.
    static func landingRefusal(_ landing: Landing, candidate: String, from: String, base: String, root: String) -> String? { nil }

    private struct Refused: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    private static func count(_ lines: Int) -> String { "\(lines) line\(lines == 1 ? "" : "s")" }

    private static func clip(_ text: String) -> String { text.count > 120 ? String(text.prefix(119)) + "…" : text }

    /// The fast-forward of the main checkout over `files`, the lead's records with lines not committed yet that the
    /// candidate changes too: the lines stay. Before anything moves their files take the candidate's lines as well (by
    /// union, from `expected`), and their index entries become the candidate's, so git keeps them as they are (index
    /// matching the target: read-tree's two-way "keep index"). `move` is the fast-forward. If it doesn't happen, the files
    /// and the index are put back. Called under the records' lock, so no line is written between the read and the move.
    static func landKeepingRecords(files: [String], root: String, expected: String, commit: String, move: () -> Merge) -> Merge { move() }
}
