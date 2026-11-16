import Foundation
import VibeCore

/// What the typed word came to (the engine plan's EN-D5): the code typed, another typed, or no controlling terminal to
/// ask on. The command line's `TypedWord` asks; the sequences take its answer (the start plan's Module structure).
public enum TypedOutcome: Equatable, Sendable {
    case typed
    case wrong
    case noTerminal

    /// What a refusal says for each outcome but `typed`.
    public var refusal: String {
        switch self {
        case .typed: return ""
        case .wrong: return "the code typed isn't the one shown: nothing was done"
        case .noTerminal: return "this needs a code typed on a terminal (this process has no controlling terminal: /dev/tty can't be opened): nothing was done"
        }
    }
}

/// `vibeswitcher start`'s arguments: `[--interop-is-on] [--at-login] [--node-version vX.Y.Z]`, each at most once.
public struct StartArguments: Equatable, Sendable {
    public var interopIsOn: Bool
    public var atLogin: Bool
    /// The nvm version whose `bin` the unit's PATH takes (ST-D4); checked by `NodeFolders.toolFolders`.
    public var nodeVersion: String?

    public init(interopIsOn: Bool = false, atLogin: Bool = false, nodeVersion: String? = nil) {
        self.interopIsOn = interopIsOn
        self.atLogin = atLogin
        self.nodeVersion = nodeVersion
    }

    public static let usage = "usage: vibeswitcher start [--interop-is-on] [--at-login] [--node-version vX.Y.Z]"

    /// The arguments, or nil when they aren't the usage's (a flag twice, a missing or flag-like version, anything else).
    public static func parse(_ words: [String]) -> StartArguments? {
        var parsed = StartArguments()
        var seen = Set<String>()
        var index = 0
        while index < words.count {
            let word = words[index]
            guard seen.insert(word).inserted else { return nil }
            switch word {
            case "--interop-is-on": parsed.interopIsOn = true
            case "--at-login": parsed.atLogin = true
            case "--node-version":
                index += 1
                guard index < words.count, !words[index].hasPrefix("-") else { return nil }
                parsed.nodeVersion = words[index]
            default: return nil
            }
            index += 1
        }
        return parsed
    }
}

/// `vibeswitcher start`'s order (the start plan's ST-D5), with every step injected (ST-D1): the command line only
/// wires `Steps`, and tests drive this with recording stand-ins.
///
/// 1. The arguments (given to `run`).
/// 2. The mode (`kind`: a scratch node, or the user's node and what `NodeFolders.mode` says), a read of files only.
/// 3. On the user's node, the installed-build check (ST-D3) before any write or call: the facts below run
///    `systemctl --user show-environment`, so the check comes before them, and before the interop refusal (ST-D5 put
///    that first; the Review Focus's "nothing is written or called before the installed-build check" wins, noted
///    2026-11-16).
/// 4. The facts and the interop refusal (`StartCheck`); their lines said. On a machine whose manager answers, the
///    manager-variable refusal (`NodeFolders.managerRefusal`) and the manager-configuration refusal.
/// 5. A server that answers and passes `ServerCheck`: "the node runs" (the command line's `serverAnswers` says it),
///    then S11's acknowledgment the first time, as before S2. A scratch node with no server is refused: its harness
///    starts it (69).
/// 6. Otherwise, on the user's node: a machine without the manager's socket (refused), or without systemd (the
///    detached start, S3: `runDetached`), then S11's list and its acknowledgment the first time, before anything is
///    started.
/// 7. The build: the unit's commit when there is a unit file (`unitBuild`), else the command line's own; the swift and
///    node folders (`toolFolders`); the preflight. The unit's `Inputs` are made from the account's home, those folders
///    and the commit, never from the unit's own `HOME` or swift folder (the review of S1).
/// 8. Whether the unit is enabled already (`enabledBy`, a read), then the confirmation (`NodeTexts.start`), which says
///    so, and the command line's own code.
/// 9. The starter (`NodeStarter.startUnit`: the unit's state, the unit written, `daemon-reload`, the show check, the
///    manager's environment again, then `beforeStart`, `enable` with `--at-login`, `start`, the wait). `beforeStart`
///    writes the journal entry `NodeJournal.entry(event: "start", action:)`, so `status` doesn't show the user's own
///    start as unexplained; it runs only once the starter's checks passed, so a start they refuse leaves no entry
///    that explains a job someone else starts within its window (the review of S2; ST-D5 put the entry before the
///    starter, noted 2026-11-16).
///
/// On a machine without systemd (S3, ST-D6) the start is detached (`Steps.detached`): no unit is read or written, the
/// build is this command line's own, `--at-login` is refused (nothing starts the node at login), and there is no
/// journal: S11's list and its code are asked at each start while the acknowledgment can't be read, and the start's
/// entry is written when it can be, said not recorded when it can't (2026-11-16).
public struct StartSequence {
    /// Which node the command line is on.
    public enum Kind: Equatable, Sendable {
        /// A scratch node (EN-D8): started by its harness, never by `start`.
        case scratch
        /// The user's node, and how this machine starts it.
        case node(NodeFolders.Mode)
    }

    /// What asking the server came to.
    public enum ServerAnswer: Equatable, Sendable {
        /// It answered and passed `ServerCheck`; the command line has said "the node runs".
        case running
        /// Nothing listens: why, as the client says it ("the node isn't running: …").
        case notRunning(String)
        /// A listener that fails `ServerCheck`, and why.
        case refusedByCheck(String)
        /// Anything else (no hello, an error reply), as the command line refuses it.
        case failed(StartRefusal)
    }

    public enum Outcome: Equatable, Sendable {
        /// The node ran already.
        case running
        /// The unit was started for this commit, and its server answers.
        case started(commit: String)
    }

    /// Every step `run` takes, as the command line (or a test) gives them.
    public struct Steps {
        /// The account's home (`getpwuid`), which the unit's `HOME` is.
        public var home: String
        /// The install prefix (`NodeFolders.defaultPrefix`).
        public var prefix: String
        public var kind: () -> Kind
        /// `NodeFolders.installedBuild` of this command line.
        public var installedBuild: () -> Result<(commit: String, folder: String), StartRefusal>
        /// What the machine says (`NodeFacts`); its manager's environment read once with `managerEnvironment`.
        public var facts: () -> NodeFacts
        /// `systemctl --user show-environment`'s text, or why it can't be had.
        public var managerEnvironment: () -> Result<String, NodeFacts.Failure>
        /// `NodeFolders.managerConfigRefusal` of the account's home.
        public var managerConfig: () -> StartRefusal?
        /// The server asked for `start` (the command line connects, checks, asks, journals the request and says the
        /// node runs).
        public var serverAnswers: () -> ServerAnswer
        /// Whether the journal holds a `not-promised-ack` entry that passes the voice rule; or why it can't be read.
        public var acknowledged: () -> Result<Bool, NodeFacts.Failure>
        /// Says S11's list (`NotPromised.text`).
        public var showList: () -> Void
        /// Asks for `code` on the controlling terminal, showing `what` (`TypedWord.ask`).
        public var typed: (_ code: String, _ what: String) -> TypedOutcome
        /// Says a line on stdout: the facts, the confirmation, the outcome (the plan's `confirm`).
        public var say: (String) -> Void
        /// Writes an entry of the command line's (`NodeContext.writeJournal`); false when it didn't go.
        public var journal: ([(name: String, value: String)]) -> Bool
        /// The unit file's text, nil when there is none.
        public var existingUnit: () -> String?
        /// `NodeFolders.unitBuild` of that text.
        public var unitBuild: (String) -> Result<NodeUnit.Inputs, StartRefusal>
        /// The commit `<prefix>/current` names, nil when none.
        public var current: () -> String?
        /// The unit folder's folders that hold a link to the unit (`NodeStarter.enabledBy`), read before the code.
        public var enabledBy: () -> [String]
        /// `NodeFolders.toolFolders` for `--node-version` and the existing unit.
        public var toolFolders: (_ nodeVersion: String?, _ existingUnit: NodeUnit.Inputs?) -> Result<(swiftBin: String, nodeBin: String), StartRefusal>
        /// `StartPreflight.check` with those folders.
        public var preflight: (_ swiftBin: String, _ nodeBin: String) -> Result<StartPreflight.Found, StartRefusal>
        /// `NodeStarter.startUnit`, given `beforeStart` (the journal entry for the start) to run once its checks pass.
        public var starter: (_ unit: NodeUnit.Inputs, _ atLogin: Bool, _ beforeStart: @escaping () -> StartRefusal?) -> Result<NodeStarter.Started, StartRefusal>
        /// A new action id (a UUID's text), from which each typed code comes (`NodeIds.code(action:)`).
        public var newAction: () -> String
        /// The detached start (S3) of the unit's inputs on a machine without systemd, given `beforeStart` (the journal
        /// entry) to run before the host is started: the command line passes `NodeStarter.startDetached` with
        /// `NodeUnit.execStart`, then the wait.
        public var detached: (_ unit: NodeUnit.Inputs, _ beforeStart: @escaping () -> StartRefusal?) -> Result<NodeStarter.Started, StartRefusal>

        public init(home: String, prefix: String, kind: @escaping () -> Kind,
                    installedBuild: @escaping () -> Result<(commit: String, folder: String), StartRefusal>,
                    facts: @escaping () -> NodeFacts, managerEnvironment: @escaping () -> Result<String, NodeFacts.Failure>,
                    managerConfig: @escaping () -> StartRefusal?, serverAnswers: @escaping () -> ServerAnswer,
                    acknowledged: @escaping () -> Result<Bool, NodeFacts.Failure>, showList: @escaping () -> Void,
                    typed: @escaping (_ code: String, _ what: String) -> TypedOutcome, say: @escaping (String) -> Void,
                    journal: @escaping ([(name: String, value: String)]) -> Bool, existingUnit: @escaping () -> String?,
                    unitBuild: @escaping (String) -> Result<NodeUnit.Inputs, StartRefusal>, current: @escaping () -> String?,
                    enabledBy: @escaping () -> [String],
                    toolFolders: @escaping (_ nodeVersion: String?, _ existingUnit: NodeUnit.Inputs?) -> Result<(swiftBin: String, nodeBin: String), StartRefusal>,
                    preflight: @escaping (_ swiftBin: String, _ nodeBin: String) -> Result<StartPreflight.Found, StartRefusal>,
                    starter: @escaping (_ unit: NodeUnit.Inputs, _ atLogin: Bool, _ beforeStart: @escaping () -> StartRefusal?) -> Result<NodeStarter.Started, StartRefusal>,
                    newAction: @escaping () -> String = { UUID().uuidString.lowercased() },
                    detached: @escaping (_ unit: NodeUnit.Inputs, _ beforeStart: @escaping () -> StartRefusal?) -> Result<NodeStarter.Started, StartRefusal>
                        = { _, _ in .failure(StartRefusal("no systemd: this command line has no detached start", exitCode: 1)) }) {
            self.home = home
            self.prefix = prefix
            self.kind = kind
            self.installedBuild = installedBuild
            self.facts = facts
            self.managerEnvironment = managerEnvironment
            self.managerConfig = managerConfig
            self.serverAnswers = serverAnswers
            self.acknowledged = acknowledged
            self.showList = showList
            self.typed = typed
            self.say = say
            self.journal = journal
            self.existingUnit = existingUnit
            self.unitBuild = unitBuild
            self.current = current
            self.enabledBy = enabledBy
            self.toolFolders = toolFolders
            self.preflight = preflight
            self.starter = starter
            self.newAction = newAction
            self.detached = detached
        }
    }

    public let steps: Steps

    public init(steps: Steps) { self.steps = steps }

    /// What a scratch node with no server says: its harness starts it (ST-D1).
    public static let scratchNotStarted = "scratch node: started by its harness, never by start"

    /// What the acknowledgment's code is asked with.
    public static let acknowledgeWhat = "This records that you read the list above (a journal entry)."

    /// `start`, in ST-D5's order (the type's comment).
    public func run(_ arguments: StartArguments) -> Result<Outcome, StartRefusal> {
        let kind = steps.kind()
        var installedBuild: (commit: String, folder: String)?
        if case .node = kind {
            switch steps.installedBuild() {
            case .failure(let refused): return .failure(refused)
            case .success(let build): installedBuild = build
            }
        }
        let facts = steps.facts()
        if let refusal = StartCheck.refusal(facts: facts, interopIsOn: arguments.interopIsOn) { return .failure(StartRefusal(refusal)) }
        for line in facts.lines { steps.say(line) }
        if kind == .node(.systemd) {
            switch steps.managerEnvironment() {
            case .failure(let failure):
                return .failure(StartRefusal("the user manager's environment can't be read (\(ConfigSeal.inert(failure.reason, limit: .max))): start checks it before it starts anything"))
            case .success(let text):
                if let refused = NodeFolders.managerRefusal(showEnvironment: text) { return .failure(refused) }
            }
            if let refused = steps.managerConfig() { return .failure(refused) }
        }

        switch steps.serverAnswers() {
        case .running:
            if let refused = acknowledgeAfterAnswer() { return .failure(refused) }
            return .success(.running)
        case .failed(let refused):
            return .failure(refused)
        case .notRunning(let why):
            if kind == .scratch { return .failure(StartRefusal("\(why) (\(Self.scratchNotStarted))", exitCode: 69)) }
        case .refusedByCheck(let why):
            // On the user's node, `systemctl start` acts on the unit, not on what listens: the wait below waits past a
            // listener that fails the check. A scratch node's command line refuses it, as before.
            if kind == .scratch { return .failure(StartRefusal(why)) }
        }
        guard let installed = installedBuild else { return .failure(StartRefusal(Self.scratchNotStarted, exitCode: 69)) }
        switch kind {
        case .scratch, .node(.systemd): break
        case .node(.socketMissing):
            return .failure(StartRefusal("the user manager's socket is missing (<runtime folder>/systemd/private): pid 1 is systemd, so start won't take this machine for one without it and start the node detached; see `systemctl --user status`"))
        case .node(.noSystemd):
            return runDetached(arguments, installed: installed)
        }

        if let refused = acknowledgeBeforeStart() { return .failure(refused) }

        // The build: the unit's commit, or this command line's own.
        var unitInputs: NodeUnit.Inputs?
        if let text = steps.existingUnit() {
            switch steps.unitBuild(text) {
            case .failure(let refused): return .failure(refused)
            case .success(let inputs): unitInputs = inputs
            }
        }
        let commit = unitInputs?.commit ?? installed.commit
        let folders: (swiftBin: String, nodeBin: String)
        switch steps.toolFolders(arguments.nodeVersion, unitInputs) {
        case .failure(let refused): return .failure(refused)
        case .success(let found): folders = found
        }
        let found: StartPreflight.Found
        switch steps.preflight(folders.swiftBin, folders.nodeBin) {
        case .failure(let refused): return .failure(refused)
        case .success(let result): found = result
        }
        let inputs = NodeUnit.Inputs(prefix: steps.prefix, commit: commit, home: steps.home, swiftBin: folders.swiftBin, nodeBin: folders.nodeBin)
        if case .failure(let refused) = NodeUnit.text(inputs) { return .failure(refused) }

        let enabledBy = steps.enabledBy()
        steps.say(NodeTexts.start(unit: inputs, current: steps.current(), previousCommit: unitInputs?.commit, atLogin: arguments.atLogin, enabledBy: enabledBy))
        steps.say("claude: \(ConfigSeal.inert(found.claude, limit: .max)); git: \(ConfigSeal.inert(found.git, limit: .max))")
        let action = steps.newAction()
        let outcome = steps.typed(NodeIds.code(action: action), "This starts the node from the build above.")
        guard outcome == .typed else { return .failure(StartRefusal(outcome.refusal)) }
        let journal = steps.journal
        let entry = {
            journal(NodeJournal.entry(event: "start", action: action))
                ? nil : StartRefusal("the start couldn't be written to the journal: nothing was started", exitCode: 1)
        }
        switch steps.starter(inputs, arguments.atLogin, entry) {
        case .failure(let refused): return .failure(refused)
        case .success(let started):
            steps.say("the node started from \(started.commit); its server answers" + (started.enabledAtLogin ? " (enabled: it starts at your login)" : ""))
            return .success(.started(commit: started.commit))
        }
    }

    /// The detached start (S3, ST-D6; the type's comment): `--at-login` refused; S11's list; the build (this command
    /// line's own), its folders and the preflight; the confirmation (`NodeTexts.startDetached`); the start's own code;
    /// then `detached`, whose `beforeStart` writes the journal entry when there is a journal.
    private func runDetached(_ arguments: StartArguments, installed: (commit: String, folder: String)) -> Result<Outcome, StartRefusal> {
        if arguments.atLogin {
            return .failure(StartRefusal("no systemd: nothing starts the node when you log in (start --at-login needs the user manager); run start without it"))
        }
        if let refused = acknowledgeWithoutJournal() { return .failure(refused) }
        let folders: (swiftBin: String, nodeBin: String)
        switch steps.toolFolders(arguments.nodeVersion, nil) {
        case .failure(let refused): return .failure(refused)
        case .success(let found): folders = found
        }
        let found: StartPreflight.Found
        switch steps.preflight(folders.swiftBin, folders.nodeBin) {
        case .failure(let refused): return .failure(refused)
        case .success(let result): found = result
        }
        let inputs = NodeUnit.Inputs(prefix: steps.prefix, commit: installed.commit, home: steps.home, swiftBin: folders.swiftBin, nodeBin: folders.nodeBin)
        // The unit's refusals of a path (a character systemd reads, /mnt/) hold for the detached host's PATH and HOME too.
        if case .failure(let refused) = NodeUnit.text(inputs) { return .failure(refused) }
        let root = NodeFolders.nodeRoot(accountHome: steps.home)
        steps.say(NodeTexts.startDetached(unit: inputs, current: steps.current(), log: NodeStarter.hostLog(root: root), record: NodeRecord.path(root: root)))
        steps.say("claude: \(ConfigSeal.inert(found.claude, limit: .max)); git: \(ConfigSeal.inert(found.git, limit: .max))")
        let action = steps.newAction()
        let outcome = steps.typed(NodeIds.code(action: action), "This starts the node detached from the build above.")
        guard outcome == .typed else { return .failure(StartRefusal(outcome.refusal)) }
        let journal = steps.journal, say = steps.say
        let entry: () -> StartRefusal? = {
            if !journal(NodeJournal.entry(event: "start", action: action)) {
                say("(no journal on a machine without systemd: this start isn't recorded)")
            }
            return nil
        }
        switch steps.detached(inputs, entry) {
        case .failure(let refused): return .failure(refused)
        case .success(let started):
            steps.say("the node started detached from \(started.commit); its server answers")
            return .success(.started(commit: started.commit))
        }
    }

    /// S11's list before a detached start, the first time: as `acknowledgeBeforeStart`, but where the journal can't be
    /// read or written (a machine without systemd has none) the list is shown and its code asked at each start, and
    /// said not recorded.
    private func acknowledgeWithoutJournal() -> StartRefusal? {
        let unread: String?
        switch steps.acknowledged() {
        case .success(true): return nil
        case .success(false): unread = nil
        case .failure(let failure): unread = failure.reason
        }
        steps.showList()
        let action = steps.newAction()
        let outcome = steps.typed(NodeIds.code(action: action), Self.acknowledgeWhat)
        guard outcome == .typed else { return StartRefusal(outcome.refusal) }
        if unread == nil, steps.journal(NodeJournal.entry(event: NotPromised.ackEvent, action: action)) {
            steps.say("recorded: you read what plain mode doesn't promise")
        } else {
            steps.say("(no journal\(unread.map { " (\(ConfigSeal.inert($0, limit: .max)))" } ?? ""): the acknowledgment can't be recorded, and start shows the list again next time)")
        }
        return nil
    }

    /// S11's list once, to a node that runs (as before S2): a journal that can't be read shows the list and says the
    /// acknowledgment can't be recorded (no refusal); a code not typed is refused (77), an entry not written fails (1).
    private func acknowledgeAfterAnswer() -> StartRefusal? {
        switch steps.acknowledged() {
        case .success(true): return nil
        case .failure(let failure):
            steps.showList()
            steps.say("(\(failure.reason): the acknowledgment can't be recorded)")
            return nil
        case .success(false):
            steps.showList()
            let action = steps.newAction()
            let outcome = steps.typed(NodeIds.code(action: action), Self.acknowledgeWhat)
            guard outcome == .typed else { return StartRefusal(outcome.refusal) }
            guard steps.journal(NodeJournal.entry(event: NotPromised.ackEvent, action: action)) else {
                return StartRefusal("the acknowledgment couldn't be written to the journal", exitCode: 1)
            }
            steps.say("recorded: you read what plain mode doesn't promise")
            return nil
        }
    }

    /// S11's list and its acknowledgment before a stopped node is started, the first time: refused unless the code is
    /// typed and the entry written, or when the journal can't be read (it holds the record).
    private func acknowledgeBeforeStart() -> StartRefusal? {
        switch steps.acknowledged() {
        case .success(true): return nil
        case .failure(let failure):
            return StartRefusal("the journal can't be read (\(ConfigSeal.inert(failure.reason, limit: .max))): start records your acknowledgment and its own start there", exitCode: 1)
        case .success(false):
            steps.showList()
            let action = steps.newAction()
            let outcome = steps.typed(NodeIds.code(action: action), Self.acknowledgeWhat)
            guard outcome == .typed else { return StartRefusal(outcome.refusal) }
            guard steps.journal(NodeJournal.entry(event: NotPromised.ackEvent, action: action)) else {
                return StartRefusal("the acknowledgment couldn't be written to the journal: nothing was started", exitCode: 1)
            }
            steps.say("recorded: you read what plain mode doesn't promise")
            return nil
        }
    }
}
