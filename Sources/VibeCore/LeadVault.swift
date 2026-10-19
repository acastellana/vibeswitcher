import CryptoKit
import Darwin
import Foundation

/// Who's who in a project lead's team, and the key the user's steered messages are sealed with, held by the session
/// host (`vibeswitcher-host`) in its memory (see `Book`), not in files: the team runs as your Unix user, and a file
/// one of them can read, any of them can (Bash isn't held by the roles' deny rules). The host keeps a copy on disk
/// sealed with a key from your login Keychain that only the host binary reads without asking you.
///
/// A role is a session: VibeSwitcher (the app starts the lead) or the lead (its workers and verifiers) asks the host
/// for a grant, starts the session and binds the grant to it. Whoever asks the host is told apart by the process
/// on the other end of its socket (its pid, then the session it runs in), never by what it says: so a worker's
/// Bash, running the tool server or writing to the socket itself, is the worker, and can't give a verdict, take the
/// lead's tools, seal a message as the user's or type into the lead.
///
/// This is a guard rail, not a sandbox: a process that runs code inside the host or the app (a debugger, a rewritten
/// binary), or that changes what the sessions run (their hooks, settings), isn't stopped by it.
public struct LeadVault: Sendable {
    public struct Member: Codable, Equatable, Sendable {
        /// The grant: what the issuer binds to the session it starts (it's no secret: only the issuer may bind it).
        public var id: String
        public var role: LeadLaunch.Role
        public var task: String?
        /// The session host's id of the session it was bound to, once it started.
        public var session: String?
        /// For a verifier: the branch's commit it was asked to check.
        public var auditing: String?
        public var issuedAt: Double
        /// Who asked for it: only they bind or withdraw it.
        public var issuer: Caller
    }

    /// A verdict as the verifier's own session gave it.
    public struct Verdict: Codable, Equatable, Sendable {
        public var task: String
        public var completion: LeadEvidence.Completion
        public var integrity: LeadEvidence.Integrity
        public var summary: String
        /// The commit it covers: the one the verifier was started on.
        public var commit: String
        /// The verifier that gave it (its grant and its session).
        public var verifier: String
        public var session: String
        public var at: Double

        public var passes: Bool { completion == .complete && integrity == .clean }
    }

    /// Who's asking, as the host tells from the process on the other end of the socket.
    public enum Caller: Codable, Equatable, Sendable {
        /// VibeSwitcher itself: the app's own binary, not running inside any session.
        case app
        /// A process inside the session the host started with this id (its program or anything under it).
        case session(String)
        /// Anything else (a process started outside the sessions, or one that left its session's process tree).
        case unknown
    }

    public enum Request: Codable, Equatable, Sendable {
        /// A grant for a role (the lead's from the app only; a worker's or verifier's from the repository's lead only).
        /// It replaces the role's earlier one: only the newest session holds the role. A new verifier also voids the
        /// task's verdict.
        case issue(role: LeadLaunch.Role, root: String, task: String?, auditing: String?)
        case bind(grant: String, root: String, session: String)
        case revoke(grant: String, root: String)
        /// The task is over: its worker's and verifier's grants and its verdict go (the lead).
        case retire(root: String, task: String)
        /// The caller's own role in the repository.
        case whoami(root: String)
        case current(role: LeadLaunch.Role, root: String, task: String?)
        /// The verdict of the verifier the caller's session is, on the commit it was started on.
        case submitVerdict(root: String, completion: LeadEvidence.Completion, integrity: LeadEvidence.Integrity, summary: String)
        case verdict(root: String, task: String)
        /// The lead, or the task's worker (a new report means new work).
        case clearVerdict(root: String, task: String)
        case head(root: String, branch: String)
        /// The app, or the repository's lead.
        case setHead(root: String, branch: String, commit: String)
        /// The user's message sealed (the app only).
        case seal(SteerMessage)
        /// Which of these carry a valid seal.
        case verify([SteerMessage])
        /// When the vault began empty in place of one that couldn't be read (`Reply.startedOver`).
        case startedOver
        /// A git command the caller's session is about to run, or just ran, in the repository (its hooks; see
        /// `GitMoves`): recorded under the session the host tells the caller is in.
        case ranGit(root: String, step: GitStep)
        /// Take the branch as it is now if the move since the lead last left it is the user's own (see `judge`).
        /// The app, or the repository's lead.
        case acceptMove(root: String, branch: String)
        /// What the lead last set workflow.md's guard rails to (see `LeadVault.guardedKeys`).
        case guarded(root: String)
        /// The app, or the repository's lead: these settings' hashes, by key, are the lead's now (the others stay).
        case setGuarded(root: String, hashes: [String: String])
        /// The app only: you approved merging the task at this commit (see `LeadVault.recordApproval`).
        case approve(root: String, task: String, commit: String)
        /// Whether you approved merging the task at exactly this commit.
        case approved(root: String, task: String, commit: String)
    }

    public enum Reply: Codable, Equatable, Sendable {
        case ok
        case grant(String)
        case member(Member?)
        case verdict(Verdict?)
        case head(String?)
        case seal(String)
        case verified([Bool])
        case refused(String)
        case startedOver(Double?)
        case move(BaseMove)
        case guarded([String: String]?)
        case approved(Bool)
    }

    /// The host said no, or couldn't be asked.
    public struct Refused: Error, CustomStringConvertible, Equatable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// Where the roles' launch files and merges' scratch space go (they hold nothing secret).
    public let folder: URL
    let ask: @Sendable (Request) throws -> Reply

    public init(folder: URL, ask: @escaping @Sendable (Request) throws -> Reply) {
        self.folder = folder
        self.ask = ask
    }

    /// The session host's vault.
    public static var standard: LeadVault {
        LeadVault(folder: VibePaths.root.appendingPathComponent("lead", isDirectory: true)) { try HostCall.vault($0) }
    }

    func call(_ request: Request) throws -> Reply {
        let reply: Reply
        do { reply = try ask(request) } catch let refused as Refused { throw refused } catch {
            throw Refused("The session host didn't answer (\(error)); VibeSwitcher's lead tools need it running.")
        }
        if case .refused(let reason) = reply { throw Refused(reason) }
        return reply
    }

    // MARK: Grants

    public func issue(role: LeadLaunch.Role, root: String, task: String?, auditing: String? = nil) throws -> String {
        guard case .grant(let grant) = try call(.issue(role: role, root: root, task: task, auditing: auditing)) else { throw Self.unexpected }
        return grant
    }

    /// Ties a grant to the session it was issued for (once the session host started it).
    public func bind(_ grant: String, root: String, session: String) throws {
        _ = try call(.bind(grant: grant, root: root, session: session))
    }

    /// Withdraws a grant (its session didn't start).
    public func revoke(_ grant: String, root: String) throws {
        _ = try call(.revoke(grant: grant, root: root))
    }

    public func retire(root: String, task: String) throws {
        _ = try call(.retire(root: root, task: task))
    }

    /// The lead starts (from VibeSwitcher): a grant for it. `branch` as it is now becomes the head merges start from
    /// only when none is recorded, or when `takeHead` (you said so in the app, having been shown the move): starting
    /// the lead again (anything can ask for that) doesn't make a move nobody merged look like the lead's.
    public func startLead(root: String, branch: String, takeHead: Bool = false) throws -> String {
        let grant = try issue(role: .lead, root: root, task: nil)
        if let now = Self.branchHead(branch, root: root), takeHead || head(root: root, branch: branch) == nil {
            try setHead(now, root: root, branch: branch)
        }
        return grant
    }

    /// The lead that's still running when VibeSwitcher starts again (a relaunch, an install): its role bound to its
    /// session once more (the app). Only to the session the vault already binds the role to: nil when it binds it to
    /// none or to another (a vault that started over, a newer lead), and the session gets no role back.
    @discardableResult
    public func rebindLead(root: String, session: String) throws -> Member? {
        guard case .member(let member) = try call(.current(role: .lead, root: root, task: nil)) else { throw Self.unexpected }
        guard let member, member.session == session else { return nil }
        try bind(member.id, root: root, session: session)
        return member
    }

    /// The branch moved since the lead last left it, and not through its merges: where it was left, and where it is.
    public func headMoved(root: String, branch: String) -> (recorded: String, now: String)? {
        guard let recorded = head(root: root, branch: branch), let now = Self.branchHead(branch, root: root), recorded != now else { return nil }
        return (recorded, now)
    }

    static func branchHead(_ branch: String, root: String) -> String? {
        let head = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root)
        return head.ok && !head.output.isEmpty ? head.output : nil
    }

    /// The caller's own role in this repository, if it holds a current one.
    public func whoami(root: String) throws -> Member? {
        guard case .member(let member) = try call(.whoami(root: root)) else { throw Self.unexpected }
        return member
    }

    /// The role's current member (the lead, or a task's worker or verifier).
    public func current(_ role: LeadLaunch.Role, root: String, task: String?) -> Member? {
        guard case .member(let member)? = try? call(.current(role: role, root: root, task: task)) else { return nil }
        return member
    }

    // MARK: Verdicts

    @discardableResult
    public func submitVerdict(root: String, completion: LeadEvidence.Completion, integrity: LeadEvidence.Integrity,
                              summary: String) throws -> Verdict {
        guard case .verdict(let verdict?) = try call(.submitVerdict(root: root, completion: completion, integrity: integrity,
                                                                   summary: summary)) else { throw Self.unexpected }
        return verdict
    }

    public func verdict(root: String, task: String) -> Verdict? {
        guard case .verdict(let verdict)? = try? call(.verdict(root: root, task: task)) else { return nil }
        return verdict
    }

    public func clearVerdict(root: String, task: String) throws {
        _ = try call(.clearVerdict(root: root, task: task))
    }

    /// Why `task` has no verdict here when that isn't the whole story: the vault began empty after an earlier
    /// session host's couldn't be read, so an audit recorded before then is lost (not missing). Nil otherwise.
    public func missingVerdictReason(root: String, task: String) -> String? {
        guard verdict(root: root, task: task) == nil, case .startedOver(let since?)? = try? call(.startedOver) else { return nil }
        let when = Date(timeIntervalSince1970: since).formatted(date: .abbreviated, time: .shortened)
        return "\(task) has no verdict in the session host's vault: the audit was recorded by an earlier session host; re-run audit. (The vault began empty \(when): the one kept before couldn't be read, its Keychain key unreadable by this build.)"
    }

    // MARK: The lead's branch

    /// The branch's head as the lead last left it.
    public func head(root: String, branch: String) -> String? {
        guard case .head(let head)? = try? call(.head(root: root, branch: branch)) else { return nil }
        return head
    }

    public func setHead(_ commit: String, root: String, branch: String) throws {
        _ = try call(.setHead(root: root, branch: branch, commit: commit))
    }

    // MARK: The user's messages

    public func seal(_ message: SteerMessage) throws -> String {
        guard case .seal(let seal) = try call(.seal(message)) else { throw Self.unexpected }
        return seal
    }

    public func verify(_ messages: [SteerMessage]) throws -> [Bool] {
        guard case .verified(let valid) = try call(.verify(messages)), valid.count == messages.count else { throw Self.unexpected }
        return valid
    }

    static let unexpected = Refused("The session host answered something else; it may be older than the app.")

    // MARK: Files

    /// Where a role's launch files go.
    public func runFolder(root: String, name: String) -> URL {
        folder.appendingPathComponent("run/\(Self.key(root))/\(name)", isDirectory: true)
    }

    /// A private place for merges' scratch worktrees and locks.
    public func scratch(root: String, _ name: String) -> URL {
        folder.appendingPathComponent("scratch/\(Self.key(root))/\(name)")
    }

    /// Creates `folder` (and what's under it up to `url`) private to you.
    public func ensurePrivate(_ url: URL) throws {
        var created: [URL] = []
        var current = url
        while current.path.hasPrefix(folder.path), !FileManager.default.fileExists(atPath: current.path) {
            created.append(current)
            current = current.deletingLastPathComponent()
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for directory in created + [folder] { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    }

    /// Writes a file only you can read (0600), atomically.
    public static func writePrivate(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func canonical(_ root: String) -> String {
        URL(fileURLWithPath: (root as NSString).standardizingPath).resolvingSymlinksInPath().path
    }

    /// A repository's name in the vault: the same however its path is written.
    static func key(_ root: String) -> String { String(hash(canonical(root)).prefix(20)) }
}

extension LeadVault {
    /// The vault itself: the teams, their verdicts and heads, and the user's sealing key, with the rules for who may
    /// change what. The session host holds one; `answer` takes each request with the caller the host told apart.
    public final class Book: @unchecked Sendable {
        struct Team: Codable {
            var root: String
            var members: [Member] = []
            var verdicts: [String: Verdict] = [:]
            /// Each branch's head as the lead last left it (after its own merges, or when it started).
            var heads: [String: String] = [:]
            /// The git commands sessions ran here that can move a branch, newest last (optional: older vaults have none).
            var runs: [GitRun]?
            /// Sessions of workers and verifiers whose grant went (a newer one replaced it, the task was retired) while
            /// they may still run: they hold no role, but they're still the lead's to end. Newest last (optional:
            /// older vaults have none).
            var former: [String]?
            /// workflow.md's guard rails as the lead last set them (`LeadVault.guardedHashes`); nil until it did
            /// (optional: older vaults have none).
            var guarded: [String: String]?
            /// The commits you approved merging, by task, newest last (optional: older vaults have none).
            var approvals: [String: [String]]?

            /// Takes the members `drop` picks out; the sessions the workers and verifiers among them were bound to
            /// become `former`.
            mutating func remove(where drop: (Member) -> Bool) {
                let gone = members.filter { drop($0) && $0.role != .lead }.compactMap(\.session)
                members.removeAll(where: drop)
                guard !gone.isEmpty else { return }
                former = Array(((former ?? []).filter { !gone.contains($0) } + gone).suffix(200))
            }
        }

        struct State: Codable {
            var teams: [String: Team] = [:]
            /// HMAC key for the user's steered messages (see `SteerInbox`).
            var senderKey: Data
            /// The key the app proves itself with on each connection (see `AppProof`); nil until the app gave it.
            var appKey: Data?
            /// When this vault began empty because the one kept before couldn't be read (an earlier session host's,
            /// sealed with a Keychain key this build can't read): what it held, verdicts included, is lost.
            var startedOver: Double?
        }

        private var state: State
        private let lock = NSLock()
        /// The whole state, encoded, after each change (the host keeps it sealed on disk).
        public var onChange: ((Data) -> Void)?

        /// A vault as it was saved (`saved`, from `onChange` or `serialized`), or a new one when there's none or it
        /// doesn't read. `startingOver`: a new one stands in for one that was kept but couldn't be read.
        public init(restoring saved: Data? = nil, startingOver: Bool = false) {
            if let saved, let state = Self.state(saved) {
                self.state = state
            } else {
                state = State(senderKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
                if startingOver { state.startedOver = Date().timeIntervalSince1970 }
            }
        }

        private static func state(_ data: Data) -> State? {
            guard let state = try? JSONDecoder().decode(State.self, from: data), state.senderKey.count == 32 else { return nil }
            return state
        }

        /// `data` is a vault `init(restoring:)` reads (not a new one in its place).
        public static func reads(_ data: Data) -> Bool { state(data) != nil }

        /// The whole vault, encoded as `init(restoring:)` reads it: what a handover carries to the next build.
        public var serialized: Data {
            lock.lock()
            defer { lock.unlock() }
            return (try? JSONEncoder().encode(state)) ?? Data()
        }

        // MARK: The app's key

        /// The key the app proves itself with (see `AppProof`), once the app gave it.
        public var appKey: SymmetricKey? {
            lock.lock()
            defer { lock.unlock() }
            return state.appKey.map { SymmetricKey(data: $0) }
        }

        /// Takes `key` as the app's, only while the vault holds none (or `replacing` the one it holds: the host decides
        /// when): once it has one, only that one proves the app. True when `key` is the app's key now.
        @discardableResult
        public func adoptAppKey(_ key: Data, replacing: Bool = false) -> Bool {
            lock.lock()
            var changed = false
            if state.appKey == nil || replacing, state.appKey != key, key.count == AppProof.keySize {
                state.appKey = key
                changed = true
            }
            let adopted = state.appKey == key
            let data = changed ? try? JSONEncoder().encode(state) : nil
            lock.unlock()
            if let data { onChange?(data) }
            return adopted
        }

        /// Whether `caller` is the lead of a team `session` holds a role in, or held one in as a worker or verifier.
        public func leads(_ session: String, caller: Caller) -> Bool {
            guard case .session(let from) = caller else { return false }
            lock.lock()
            defer { lock.unlock() }
            return state.teams.values.contains { team in
                team.members.contains { $0.role == .lead && $0.session == from }
                    && (team.members.contains { $0.session == session } || team.former?.contains(session) == true)
            }
        }

        /// A client asking this book directly, as `caller` (tests, and the host's own checks); `userOpened` as `answer`.
        public func vault(folder: URL, as caller: @escaping @Sendable () -> Caller, userOpened: Bool = false) -> LeadVault {
            LeadVault(folder: folder) { [self] request in answer(request, from: caller(), userOpened: userOpened) }
        }

        /// `userOpened`: the caller's session is one the app opened (the host knows; no session started it), so the
        /// git commands it records are the user's while it holds no role in the team.
        public func answer(_ request: Request, from caller: Caller, userOpened: Bool = false) -> Reply {
            // It reads git: outside the lock.
            if case .acceptMove(let root, let branch) = request { return acceptMove(root: root, branch: branch, from: caller) }
            lock.lock()
            defer { lock.unlock() }
            var changed = false
            let reply = answer(request, from: caller, userOpened: userOpened, changed: &changed)
            if changed, let onChange, let data = try? JSONEncoder().encode(state) { onChange(data) }
            return reply
        }

        /// The base moved since the lead last left it: the head moves on to where it is when the move is the user's
        /// own (`LeadVault.judge`), from what git says now and the commands recorded here.
        private func acceptMove(root: String, branch: String, from caller: Caller) -> Reply {
            lock.lock()
            let allowed = caller == .app || isLead(caller, root)
            let recorded = team(root)?.heads[branch]
            let members = Set(team(root)?.members.compactMap(\.session) ?? [])
            // A session that holds a role now is no user's, whatever it held when it ran the command.
            let runs = (team(root)?.runs ?? []).map { run in
                var run = run
                run.user = run.user && !members.contains(run.session)
                return run
            }
            lock.unlock()
            guard allowed else { return .refused("Only VibeSwitcher or the lead asks to take a move of the lead's branch.") }
            guard let recorded else { return .refused("No head is recorded for \(branch) here: the lead takes it as it is when it starts.") }
            guard let history = BaseHistory.read(root: root, branch: branch, since: recorded) else {
                return .refused("Couldn't read \(branch) in \(root).")
            }
            guard history.head != recorded else {
                return .move(BaseMove(branch: branch, from: recorded, to: recorded, accepted: true, commits: [], sessions: []))
            }
            var move = LeadVault.judge(from: recorded, history: history, branch: branch, runs: runs)
            guard move.accepted else { return .move(move) }
            lock.lock()
            var changed = false
            if team(root)?.heads[branch] == recorded {
                change(root, &changed) { $0.heads[branch] = move.to }
            } else {
                move.accepted = false
                move.reason = "The lead's merges moved \(branch) meanwhile: ask again."
            }
            let data = changed ? try? JSONEncoder().encode(state) : nil
            lock.unlock()
            if let data { onChange?(data) }
            return .move(move)
        }

        /// Whether `caller` may type into `session`: one that holds a role in a team takes keys only from the app,
        /// from itself, and (a worker's or verifier's) from its repository's lead. Any other session takes them from
        /// anyone, as before.
        public func mayType(into session: String, from caller: Caller) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let holds = state.teams.values.filter { team in team.members.contains { $0.session == session } }
            guard !holds.isEmpty else { return true }
            switch caller {
            case .app: return true
            case .unknown: return false
            case .session(let from):
                if from == session { return true }
                return holds.contains { team in
                    team.members.contains { $0.session == session && $0.role != .lead }
                        && team.members.contains { $0.role == .lead && $0.session == from }
                }
            }
        }

        // MARK: Rules

        private func answer(_ request: Request, from caller: Caller, userOpened: Bool, changed: inout Bool) -> Reply {
            switch request {
            case .issue(let role, let root, let task, let auditing):
                if role == .lead {
                    guard caller == .app else { return .refused("Only VibeSwitcher starts a project lead.") }
                } else {
                    guard isLead(caller, root) else { return .refused("Only the repository's lead starts workers and verifiers.") }
                    guard task != nil else { return .refused("A worker or verifier is for a task.") }
                }
                let member = Member(id: UUID().uuidString, role: role, task: role == .lead ? nil : task, session: nil,
                                    auditing: auditing, issuedAt: Date().timeIntervalSince1970, issuer: caller)
                change(root, &changed) { team in
                    team.remove { $0.role == role && $0.task == member.task }
                    if role == .verifier, let task { team.verdicts[task] = nil }
                    team.members.append(member)
                }
                return .grant(member.id)
            case .bind(let grant, let root, let session):
                guard let member = team(root)?.members.first(where: { $0.id == grant }), member.issuer == caller else {
                    return .refused("That grant isn't yours to bind (or it was withdrawn).")
                }
                guard member.session == nil || member.session == session else { return .refused("That grant is bound already.") }
                if let holder = team(root)?.members.first(where: { $0.session == session }), holder.id != grant {
                    return .refused("That session holds another role here (\(holder.role.rawValue)) already.")
                }
                change(root, &changed) { team in
                    guard let index = team.members.firstIndex(where: { $0.id == grant }) else { return }
                    team.members[index].session = session
                }
                return .ok
            case .revoke(let grant, let root):
                guard let member = team(root)?.members.first(where: { $0.id == grant }) else { return .ok }
                guard member.issuer == caller else { return .refused("That grant isn't yours to withdraw.") }
                change(root, &changed) { team in team.remove { $0.id == grant } }
                return .ok
            case .retire(let root, let task):
                guard isLead(caller, root) else { return .refused("Only the repository's lead retires a task.") }
                change(root, &changed) { team in
                    team.remove { $0.task == task }
                    team.verdicts[task] = nil
                    // A new task of the same name starts with none.
                    team.approvals?[task] = nil
                }
                return .ok
            case .whoami(let root):
                guard case .session(let session) = caller else { return .member(nil) }
                return .member(team(root)?.members.first { $0.session == session })
            case .current(let role, let root, let task):
                return .member(team(root)?.members.first { $0.role == role && $0.task == task })
            case .submitVerdict(let root, let completion, let integrity, let summary):
                guard case .session(let session) = caller,
                      let member = team(root)?.members.first(where: { $0.session == session }), member.role == .verifier,
                      let task = member.task, let commit = member.auditing else {
                    return .refused("Only the verifier VibeSwitcher's lead started on a task gives its verdict, from its own session.")
                }
                let verdict = Verdict(task: task, completion: completion, integrity: integrity, summary: summary, commit: commit,
                                      verifier: member.id, session: session, at: Date().timeIntervalSince1970)
                change(root, &changed) { $0.verdicts[task] = verdict }
                return .verdict(verdict)
            case .verdict(let root, let task):
                return .verdict(team(root)?.verdicts[task])
            case .clearVerdict(let root, let task):
                let worker: Bool = {
                    guard case .session(let session) = caller else { return false }
                    return team(root)?.members.contains { $0.session == session && $0.role == .worker && $0.task == task } == true
                }()
                guard worker || isLead(caller, root) else { return .refused("Only the lead, or the task's own worker, sets a verdict aside.") }
                guard team(root)?.verdicts[task] != nil else { return .ok }
                change(root, &changed) { $0.verdicts[task] = nil }
                return .ok
            case .head(let root, let branch):
                return .head(team(root)?.heads[branch])
            case .setHead(let root, let branch, let commit):
                guard caller == .app || isLead(caller, root) else { return .refused("Only VibeSwitcher or the lead records where the lead's branch is.") }
                change(root, &changed) { $0.heads[branch] = commit }
                return .ok
            case .seal(let message):
                guard caller == .app else { return .refused("Only VibeSwitcher seals a message as the user's.") }
                return .seal(SteerInbox.seal(message, key: SymmetricKey(data: state.senderKey)))
            case .verify(let messages):
                let key = SymmetricKey(data: state.senderKey)
                return .verified(messages.map { message in message.seal.map { $0 == SteerInbox.seal(message, key: key) } ?? false })
            case .startedOver:
                return .startedOver(state.startedOver)
            case .ranGit(let root, let step):
                guard case .session(let session) = caller else { return .refused("Only a session's own hooks say what it ran.") }
                // Kept only where a lead works: nothing reads them anywhere else.
                guard let team = team(root) else { return .ok }
                let user = userOpened && !team.members.contains { $0.session == session }
                let now = Date().timeIntervalSince1970
                switch step.phase {
                case .before:
                    let run = GitRun(session: session, user: user, call: step.call, verb: step.verb, branch: step.branch,
                                     before: step.head, started: now)
                    change(root, &changed) { team in
                        team.runs = Array((team.runs ?? []).filter { now - $0.started < 7 * 86_400 }.suffix(199)) + [run]
                    }
                case .after:
                    guard let index = team.runs?.lastIndex(where: { run in
                        run.session == session && run.ended == nil && run.verb == step.verb && (step.call == nil || run.call == step.call)
                    }) else { return .ok }
                    change(root, &changed) { team in
                        guard var run = team.runs?[index] else { return }
                        run.ended = now
                        run.user = run.user && user
                        // On another branch now (it checked one out): where it left the first one isn't known.
                        if run.branch == step.branch { run.after = step.head }
                        team.runs?[index] = run
                    }
                }
                return .ok
            case .acceptMove:
                return .refused("Asked outside the lock.")
            case .guarded(let root):
                return .guarded(team(root)?.guarded)
            case .setGuarded(let root, let hashes):
                // Its commands run as the lead in merge, and its limits hold the team: a worker's or verifier's
                // session (or anything outside the sessions) that wrote workflow.md doesn't get them taken as the lead's.
                guard caller == .app || isLead(caller, root) else { return .refused("Only VibeSwitcher or the lead records workflow.md's guard rails.") }
                change(root, &changed) { $0.guarded = ($0.guarded ?? [:]).merging(hashes) { $1 } }
                return .ok
            case .approve(let root, let task, let commit):
                // Only your answer in the app approves a merge: not the lead that asks for it, nor a worker whose
                // work it is, whatever they write on the board.
                guard caller == .app else { return .refused("Only VibeSwitcher records your approval of a merge, when you answer in it.") }
                let commit = commit.lowercased()
                guard LeadVault.isFullCommit(commit) else { return .refused("An approval names a whole commit (\(commit.prefix(12)) isn't one).") }
                guard !task.isEmpty else { return .refused("An approval is for a task.") }
                change(root, &changed) { team in
                    var approvals = team.approvals ?? [:]
                    approvals[task] = Array(((approvals[task] ?? []).filter { $0 != commit } + [commit]).suffix(20))
                    team.approvals = approvals
                }
                return .ok
            case .approved(let root, let task, let commit):
                return .approved(team(root)?.approvals?[task]?.contains(commit.lowercased()) == true)
            }
        }

        private func team(_ root: String) -> Team? { state.teams[LeadVault.key(root)] }

        private func isLead(_ caller: Caller, _ root: String) -> Bool {
            guard case .session(let session) = caller else { return false }
            return team(root)?.members.contains { $0.role == .lead && $0.session == session } == true
        }

        private func change(_ root: String, _ changed: inout Bool, _ body: (inout Team) -> Void) {
            let key = LeadVault.key(root)
            var team = state.teams[key] ?? Team(root: LeadVault.canonical(root))
            body(&team)
            state.teams[key] = team
            changed = true
        }
    }
}
