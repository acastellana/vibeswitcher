import Foundation
import VibeCore

/// Check for Updates on a node (the app's `AppUpdateWatch` and update card; the parity table's row): whether `origin/v2`
/// has a newer commit than the running build that both CI workflows passed, so `status` and the page can say so and
/// name the install line. Read-only: it installs nothing, fetches nothing into any checkout and changes no file but its
/// own record; `scripts/install-node.sh COMMIT` checks the commit again (on v2, both runners green) with nothing of the
/// user's configuration before it builds, so this only points at a commit, never vouches for one.
///
/// About 2 minutes after the server starts, then every 6 hours, it asks GitHub (`gh`, the token read from gh's own
/// store, run with no configuration folder of the user's, as the install script does) for v2's recent CI runs, takes
/// the newest commit whose latest run of each workflow is completed/success, and compares it with the running build
/// (GitHub's compare: `ahead` is newer). What it found is kept in `<node root>/update-check.json` (`Record`), so a
/// restart doesn't ask again before its time and `status` shows the last answer; a failure (offline, no gh, no token)
/// is logged once until a look succeeds and keeps the last answer.
///
/// Everything it reads of the world is injected (`Looker`, `now`), so tests use no network.
public final class UpdateWatch: @unchecked Sendable {
    public static let firstDelay: TimeInterval = 120
    public static let interval: TimeInterval = 6 * 60 * 60
    /// The tick that asks whether a look is due.
    static let tick = 60

    /// The repository and workflows the install script checks (`scripts/install-node.sh`'s `repository` and
    /// `workflows`; `UpdateWatchTests` reads them there, so the two can't drift).
    public static let repository = "acastellana/vibeswitcher"
    public static let branch = "v2"
    public static let workflows = ["v2 linux", "v2 macos"]

    /// One CI run, as `gh run list --json databaseId,workflowName,headSha,status,conclusion,event` gives it.
    public struct Run: Codable, Equatable, Sendable {
        public var databaseId: Int
        public var workflowName: String
        public var headSha: String
        public var status: String
        public var conclusion: String?
        public var event: String?
        public init(databaseId: Int, workflowName: String, headSha: String, status: String, conclusion: String?, event: String? = "push") {
            self.databaseId = databaseId
            self.workflowName = workflowName
            self.headSha = headSha
            self.status = status
            self.conclusion = conclusion
            self.event = event
        }
    }

    /// GitHub's compare of two commits (`repos/R/compare/BASE...HEAD`): `ahead` means HEAD is newer than BASE.
    public struct Compared: Equatable, Sendable {
        public var status: String
        public var aheadBy: Int?
        public init(status: String, aheadBy: Int?) {
            self.status = status
            self.aheadBy = aheadBy
        }
    }

    /// What it asks GitHub, injected.
    public struct Looker: Sendable {
        public var runs: @Sendable () -> Result<[Run], Refusal>
        public var compare: @Sendable (_ base: String, _ head: String) -> Result<Compared, Refusal>
        public init(runs: @escaping @Sendable () -> Result<[Run], Refusal>,
                    compare: @escaping @Sendable (_ base: String, _ head: String) -> Result<Compared, Refusal>) {
            self.runs = runs
            self.compare = compare
        }
    }

    public struct Refusal: Error, Equatable, CustomStringConvertible, Sendable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// A newer build to install.
    public struct Offer: Codable, Equatable, Sendable {
        public var commit: String
        /// How many commits it is ahead of the running build, as GitHub counted.
        public var aheadBy: Int?
    }

    /// What's kept across restarts.
    public struct Record: Codable, Equatable, Sendable {
        /// The running build's commit the last look compared with.
        public var running: String?
        /// When a look last succeeded, and when one was last tried.
        public var checkedAt: Date?
        public var triedAt: Date?
        /// The newer build the last successful look found (nil: up to date).
        public var offer: Offer?
        /// Why the last try failed (nil: it didn't).
        public var problem: String?
    }

    // MARK: Deciding

    /// The commits on `runs` whose latest run of each of `workflows` (pushes and manual runs; a re-run updates its run in
    /// place, so the highest id is the latest) is completed/success, newest first (by their newest run).
    public static func green(_ runs: [Run], workflows: [String] = workflows) -> [String] {
        let taken = runs.filter { ($0.event ?? "push") == "push" || $0.event == "workflow_dispatch" }
        let heads = Dictionary(grouping: taken, by: \.headSha)
        return heads.compactMap { sha, runs -> (String, Int)? in
            guard isCommit(sha) else { return nil }
            for workflow in workflows {
                guard let latest = runs.filter({ $0.workflowName == workflow }).max(by: { $0.databaseId < $1.databaseId }),
                      latest.status == "completed", latest.conclusion == "success" else { return nil }
            }
            return (sha, runs.map(\.databaseId).max() ?? 0)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// The newer build for `running`, or nil when it is the newest green one or newer; a refusal when GitHub couldn't be
    /// asked or the running build can't be compared. Blocks (it asks GitHub): never on a server queue.
    public static func decide(running: String, looker: Looker) -> Result<Offer?, Refusal> {
        guard isCommit(running) else { return .failure(Refusal("the running build's commit isn't known (\(ConfigSeal.inert(running, limit: 60)))")) }
        let runs: [Run]
        switch looker.runs() {
        case .failure(let refusal): return .failure(refusal)
        case .success(let found): runs = found
        }
        guard let newest = green(runs).first else { return .success(nil) }
        if newest == running { return .success(nil) }
        switch looker.compare(running, newest) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let compared):
            switch compared.status {
            case "ahead":
                // Still on v2 (a force push could have dropped it since its run): the install script refuses one that isn't.
                switch looker.compare(newest, branch) {
                case .failure(let refusal): return .failure(refusal)
                case .success(let onBranch) where ["identical", "ahead"].contains(onBranch.status):
                    return .success(Offer(commit: newest, aheadBy: compared.aheadBy))
                case .success: return .success(nil)
                }
            case "identical", "behind": return .success(nil)
            // Diverged: the running build isn't on v2's line (a branch's build): nothing to offer as an update.
            default: return .success(nil)
            }
        }
    }

    public static func isCommit(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    // MARK: Saying

    /// The install line for `commit`: built and installed by the script, then switched to.
    public static func installLine(_ commit: String) -> String {
        "scripts/install-node.sh \(commit), then `vibeswitcher switch \(commit)`"
    }

    /// `status`'s notice for `record` while the build running is `running` (nil: nothing to say).
    public static func notice(_ record: Record, running: String) -> String? {
        guard let offer = record.offer, record.running == running, offer.commit != running, isCommit(offer.commit) else { return nil }
        let ahead = offer.aheadBy.map { $0 == 1 ? " (1 commit ahead)" : " (\($0) commits ahead)" } ?? ""
        return "a newer build is on \(branch): \(offer.commit)\(ahead), which both CI runs (\(workflows.joined(separator: ", "))) passed. "
            + "Install it: \(installLine(offer.commit))"
    }

    // MARK: Watching

    public let file: URL
    public let running: String
    private let looker: Looker
    private let queue: DispatchQueue
    private let work = DispatchQueue(label: "vibenode.update-watch", qos: .utility)
    private let now: () -> Date
    private let note: (String) -> Void
    private let started: Date
    /// On `queue`.
    public private(set) var record: Record
    private var looking = false
    private var failing = false
    private var ticks: Subscription?

    /// `file`: the record (`<node root>/update-check.json`). `running`: the running build's commit. Its looks' answers
    /// land on `queue`.
    public init(file: URL, running: String, looker: Looker, queue: DispatchQueue, now: @escaping () -> Date = Date.init,
                note: @escaping (String) -> Void) {
        self.file = file
        self.running = running
        self.looker = looker
        self.queue = queue
        self.now = now
        self.note = note
        started = now()
        record = Self.load(file)
    }

    static func load(_ file: URL) -> Record {
        guard let data = try? Data(contentsOf: file), data.count < 64 * 1024 else { return Record() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Record.self, from: data)) ?? Record()
    }

    /// `status`'s notice now (nil: up to date, or not known). On `queue`.
    public var notice: String? { Self.notice(record, running: running) }

    /// What `status` carries: the last look's answer for this build. On `queue`.
    public var value: NodeWire.Value {
        let mine = record.running == running
        return .object([
            "checkedAt": (mine ? record.checkedAt : nil).map(NodeWire.Value.date) ?? .null,
            "commit": (mine ? record.offer?.commit : nil).map(NodeWire.Value.string) ?? .null,
            "aheadBy": (mine ? record.offer?.aheadBy : nil).map { .int($0) } ?? .null,
            "install": (mine ? record.offer?.commit : nil).map { .string(Self.installLine($0)) } ?? .null,
            "problem": record.problem.map { .string(ConfigSeal.inert($0, limit: 300)) } ?? .null,
        ])
    }

    /// Whether a look is due at `at`: never before `firstDelay` after the start; then when this build was never compared,
    /// or the last try is `interval` old. A failed try waits its interval too.
    func due(at: Date) -> Bool {
        guard at.timeIntervalSince(started) >= Self.firstDelay else { return false }
        guard record.running == running, let last = [record.checkedAt, record.triedAt].compactMap({ $0 }).max() else { return true }
        return at.timeIntervalSince(last) >= Self.interval
    }

    /// Looks every minute whether a look is due, on `clock`.
    public func start(clock: NodeClock) {
        ticks = clock.every(Self.tick) { [weak self] in
            guard let self, self.due(at: self.now()) else { return }
            self.look()
        }
    }

    /// Asks GitHub now (off `queue`), keeps the answer and calls `done` on `queue`. A look under way: `done` at once.
    public func look(done: (() -> Void)? = nil) {
        guard !looking else { done?(); return }
        looking = true
        let (running, looker, at) = (self.running, self.looker, now())
        work.async { [weak self] in
            let decided = Self.decide(running: running, looker: looker)
            self?.queue.async {
                guard let self else { return }
                self.looking = false
                self.keep(decided, at: at)
                done?()
            }
        }
    }

    private func keep(_ decided: Result<Offer?, Refusal>, at: Date) {
        var record = self.record
        record.triedAt = at
        switch decided {
        case .success(let offer):
            if record.running != running || record.offer != offer {
                note(offer.map { "update check: a newer build on \(Self.branch), \($0.commit)" } ?? "update check: up to date")
            }
            record.running = running
            record.checkedAt = at
            record.offer = offer
            record.problem = nil
            failing = false
        case .failure(let refusal):
            if !failing { note("update check: couldn't look (\(refusal)): the next try is in \(Int(Self.interval / 3600)) hours") }
            failing = true
            if record.running != running { record.offer = nil; record.checkedAt = nil }
            record.running = running
            record.problem = refusal.description
        }
        self.record = record
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try VibePaths.writePrivate(try encoder.encode(record), to: file)
        } catch {
            note("update check: \(file.path) not written: \(error)")
        }
    }
}

extension UpdateWatch.Looker {
    /// GitHub through `gh` (`gh`'s path: the install script's, `/usr/bin/gh`): the token read from gh's own store under
    /// `home` (a local read), then each call with that token and no configuration folder of the user's, so a
    /// `config.yml` can't route the answer elsewhere. Each call has 60 s.
    public static func github(gh: String = "/usr/bin/gh", home: String) -> UpdateWatch.Looker {
        let base = ["PATH": "/usr/bin:/bin", "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"]
        let token: @Sendable () -> Result<String, UpdateWatch.Refusal> = {
            guard FileManager.default.isExecutableFile(atPath: gh) else { return .failure(.init("gh isn't installed (\(gh))")) }
            let result = Shell.run(executable: gh, args: ["auth", "token", "-h", "github.com"], in: "/",
                                   env: base.merging(["HOME": home, "GH_TOKEN": "", "GITHUB_TOKEN": ""]) { $1 }, timeout: 30)
            let token = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.ok, !token.isEmpty, !token.contains(where: \.isWhitespace) else {
                return .failure(.init("gh has no token for github.com (gh auth login)"))
            }
            return .success(token)
        }
        let call: @Sendable ([String]) -> Result<Data, UpdateWatch.Refusal> = { args in
            let got: String
            switch token() {
            case .failure(let refusal): return .failure(refusal)
            case .success(let found): got = found
            }
            let result = Shell.run(executable: gh, args: args, in: "/",
                                   env: base.merging(["HOME": "/nonexistent", "GH_CONFIG_DIR": "/nonexistent", "GH_TOKEN": got,
                                                      "GH_HOST": "github.com", "GH_REPO": ""]) { $1 }, timeout: 60)
            guard result.ok else {
                let said = result.error.split(separator: "\n").first.map(String.init) ?? "exit \(result.status)"
                return .failure(.init("gh \(args.prefix(2).joined(separator: " ")) failed: \(ConfigSeal.inert(said, limit: 200))"))
            }
            return .success(Data(result.output.utf8))
        }
        return UpdateWatch.Looker(
            runs: {
                call(["run", "list", "-R", UpdateWatch.repository, "--branch", UpdateWatch.branch, "-L", "100",
                      "--json", "databaseId,workflowName,headSha,status,conclusion,event"]).flatMap { data in
                    guard let runs = try? JSONDecoder().decode([UpdateWatch.Run].self, from: data) else {
                        return .failure(.init("gh run list's answer isn't a list of runs"))
                    }
                    return .success(runs)
                }
            },
            compare: { base, head in
                call(["api", "repos/\(UpdateWatch.repository)/compare/\(base)...\(head)", "--jq", "{status: .status, ahead_by: .ahead_by}"])
                    .flatMap { data in
                        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                              let status = object["status"] as? String else {
                            return .failure(.init("GitHub's compare of \(base) with \(head) said nothing readable"))
                        }
                        return .success(UpdateWatch.Compared(status: status, aheadBy: object["ahead_by"] as? Int))
                    }
            })
    }
}
