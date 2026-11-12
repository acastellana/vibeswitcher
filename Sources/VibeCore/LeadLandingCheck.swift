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
    static func landingRefusal(_ landing: Landing, candidate: String, from: String, base: String, root: String) -> String? {
        let start = "\(landing.route) would land \(candidate.prefix(8)) on \(base)"
        let unmoved = "\(base) wasn't moved."
        func failed(_ what: String, _ result: Git.Result) -> String {
            "\(landing.route): the check of \(candidate.prefix(8)) before it lands on \(base) couldn't read \(what) (\(said(result))), so it doesn't land. \(unmoved)"
        }
        for carried in landing.carried {
            let found = landing.git(["merge-base", "--is-ancestor", carried, candidate], in: root)
            if found.ok { continue }
            guard found.status == 1, !found.timedOut, !found.cancelled, !found.signaled else { return failed("whether it holds \(carried.prefix(8))", found) }
            return "\(start) without the remote's commit \(carried.prefix(8)) as its ancestor: the remote's commits would land as copies, or not at all, and a push of \(base) wouldn't be a fast-forward. \(unmoved)"
        }
        guard let dir = landing.records else { return nil }
        /// The record's non-blank lines at `commit`, compared without the whitespace around them; empty when it has no such file.
        func lines(_ commit: String, _ file: String) throws -> Set<String> {
            let listed = landing.git(["ls-tree", "-z", commit, "--", file], in: root)
            guard listed.ok else { throw Refused(failed("\(file) at \(commit.prefix(8))", listed)) }
            guard !listed.output.isEmpty else { return [] }
            let entry = listed.output.split(separator: "\0").map(String.init)
            let parts = entry.first?.split(separator: "\t", maxSplits: 1).map(String.init) ?? []
            let fields = parts.first?.split(separator: " ").map(String.init) ?? []
            guard entry.count == 1, parts.count == 2, parts[1] == file, fields.count == 3, fields[1] == "blob" else {
                throw Refused(failed("\(file) at \(commit.prefix(8)): git listed “\(clip(listed.output))”, not one file", listed))
            }
            let read = landing.git(["cat-file", "blob", fields[2]], in: root)
            guard read.ok else { throw Refused(failed("\(file) at \(commit.prefix(8))", read)) }
            return Set(Platform.lines(read.output).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        do {
            for (kind, archive) in guarded {
                let file = "\(dir)/\(kind.name)"
                var kept = try lines(candidate, file)
                if let archive { kept.formUnion(try lines(candidate, "\(dir)/\(archive.name)")) }
                // The one line decisions.md rewrites: how many entries the archive holds.
                let missing = try lines(from, file).filter { !kept.contains($0) && !$0.hasPrefix(LeadRecords.pointerPrefix) }
                if let first = missing.sorted().first {
                    return "\(start), and \(file) would lose \(count(missing.count)) \(base) has, “\(clip(first))” among them. Records only ever grow; lines leave only through archive_decisions or the month's roll of progress.md. \(unmoved)"
                }
                // What the remote's commits brought is in the candidate itself: nothing after the move has to add it.
                for carried in landing.carried {
                    let ancestor = landing.git(["merge-base", from, carried], in: root)
                    guard ancestor.ok || ancestor.status == 1 else { return failed("what \(carried.prefix(8)) shares with \(base)", ancestor) }
                    let older: Set<String> = try ancestor.output.isEmpty ? [] : lines(ancestor.output, file)
                    let brought = try lines(carried, file).subtracting(older).filter { !kept.contains($0) && !$0.hasPrefix(LeadRecords.pointerPrefix) }
                    if let first = brought.sorted().first {
                        return "\(start), and \(file) would lack \(count(brought.count)) the remote's commit \(carried.prefix(8)) brought, “\(clip(first))” among them. \(unmoved)"
                    }
                }
            }
        } catch let refused as Refused {
            return refused.text
        } catch {
            return "\(landing.route): the check of \(candidate.prefix(8)) failed (\(error)), so it doesn't land. \(unmoved)"
        }
        return nil
    }

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
    static func landKeepingRecords(files: [String], root: String, expected: String, commit: String, move: () -> Merge) -> Merge {
        var ours: [String: Data] = [:]
        for file in files {
            guard let data = FileManager.default.contents(atPath: (root as NSString).appendingPathComponent(file)) else {
                return .refused("\(file) has uncommitted changes and can't be read, so the merge can't keep them.")
            }
            ours[file] = data
        }
        var union: [String: Data]
        switch unionRecords(root: root, paths: files, ours: ours, ancestor: expected, theirs: commit) {
        case .failure(let failure): return .refused("Taking the merge's lines into the uncommitted \(files.joined(separator: ", ")) failed: \(failure)")
        case .success(let changed): union = changed
        }
        var target: [String] = []
        for file in files {
            let listed = Git.run(["ls-tree", "-z", commit, "--", file], in: root)
            let fields = listed.output.split(separator: "\t").first?.split(separator: " ").map(String.init) ?? []
            guard listed.ok, fields.count == 3, fields[1] == "blob" else {
                return .refused("\(file) has uncommitted changes, and \(commit.prefix(8)) doesn't have it as a file to keep them on.")
            }
            target += ["--cacheinfo", "\(fields[0]),\(fields[2]),\(file)"]
        }
        let listed = Git.run(["ls-files", "-s", "-z", "--"] + files, in: root)
        guard listed.ok else { return .refused("Reading the main checkout's index failed: \(said(listed))") }
        var before: [String: String] = [:]
        for entry in listed.output.split(separator: "\0") {
            // "<mode> <blob> <stage>\t<path>"
            let parts = entry.split(separator: "\t", maxSplits: 1).map(String.init)
            let fields = parts.first?.split(separator: " ").map(String.init) ?? []
            if parts.count == 2, fields.count == 3 { before[parts[1]] = "\(fields[0]),\(fields[1])" }
        }
        let put = { (args: [String]) in withIndexLock(root: root, wait: 5) { Git.run(["update-index", "--add"] + args, in: root) } }
        let back = {
            _ = put(files.flatMap { file in before[file].map { ["--cacheinfo", "\($0),\(file)"] } ?? ["--force-remove", file] })
            for (file, data) in ours { try? data.write(to: URL(fileURLWithPath: (root as NSString).appendingPathComponent(file)), options: .atomic) }
        }
        let staged = put(target)
        guard staged.ok else { return .refused("The main checkout's index couldn't be set for the merge: \(said(staged))") }
        do {
            for (file, data) in union { try data.write(to: URL(fileURLWithPath: (root as NSString).appendingPathComponent(file)), options: .atomic) }
        } catch {
            back()
            return .refused("Writing the merge's lines into the uncommitted records failed: \(error)")
        }
        let moved = move()
        if moved != .merged { back() }
        return moved
    }
}
