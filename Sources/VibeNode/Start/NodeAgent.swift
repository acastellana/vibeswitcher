import Foundation
import VibeCore

/// The LaunchAgent that runs the node on the Mac (the node on the Mac's design, "The service: a LaunchAgent, not the
/// app"; its step 5): `~/Library/LaunchAgents/dev.vibeswitcher.node.plist`, the Mac's `vibeswitcher-node.service`
/// (`NodeUnit`). Its property list, made whole from the same inputs as the unit (`NodeUnit.Inputs`) and read back
/// against them (`check`: exactly these keys and values, nothing added); the `launchctl` command lines that load, unload
/// and show it in `gui/<uid>`, and what `launchctl print` says of the job (its pid, state, runs and last exit). Built
/// and tested on both systems as data; nothing here runs `launchctl` or writes the file: `MacAgent` does, and `start` for
/// the user's node on the Mac is still refused (`NodeSystem.macUnbuilt`).
///
/// As the unit: `KeepAlive` false (`Restart=no`), `RunAtLoad` only with `--at-login`, the commit's own host with
/// `--node`, `--node-root` its folder and its server (never `current`): a checked node's command line exactly. Only
/// `SWIFT_BACKTRACE` is written in its environment (the checked start rebuilds `HOME` and `PATH`). Unlike it: `ProcessType` Interactive and `LimitLoadToSessionType` Aqua (the GUI session, where LocalAuthentication
/// can draw its dialog); stderr to a file in the node's root (`serverLog`), stdout to /dev/null; no way to unset what
/// `launchctl setenv` put in the user's launchd (`refusedManagerNames`: `start` reads `launchctl getenv` for each and
/// refuses).
public enum NodeAgent {
    public static let label = "dev.vibeswitcher.node"
    public static let fileName = "\(label).plist"

    /// `<home>/Library/LaunchAgents/dev.vibeswitcher.node.plist`.
    public static func path(home: String) -> String { NodeFolders.join(home, "Library/LaunchAgents/\(fileName)") }

    /// Where the host's stderr goes: `<node root>/node.log`.
    public static func serverLog(nodeRoot: String) -> String { NodeFolders.join(nodeRoot, "node.log") }

    /// The names `launchctl setenv` could put in every job of the user's launchd that would change what the host loads
    /// or runs (the unit's `UnsetEnvironment=`, the Mac's loader's): `start` refuses while `launchctl getenv` gives one.
    public static let refusedManagerNames = ["DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
                                             "DYLD_FALLBACK_FRAMEWORK_PATH", "DYLD_IMAGE_SUFFIX", "BASH_ENV", "ENV", "VIBESWITCHER_HOME",
                                             "CFFIXED_USER_HOME"]

    /// What the agent's property list holds (the node on the Mac's design, "The LaunchAgent", its table): the job's
    /// label, its program and arguments, the one variable written in it, where its stderr goes, and whether it starts at
    /// the user's login. The user's node's is `node(...)`; a test's scratch job gives its own label, scratch host and
    /// environment, and every other key is the same for both (`dictionary`).
    public struct Job: Equatable, Sendable {
        public var label: String
        public var programArguments: [String]
        public var environment: [String: String]
        public var standardErrorPath: String
        public var atLogin: Bool

        public init(label: String, programArguments: [String], environment: [String: String], standardErrorPath: String, atLogin: Bool) {
            self.label = label
            self.programArguments = programArguments
            self.environment = environment
            self.standardErrorPath = standardErrorPath
            self.atLogin = atLogin
        }

        /// The user's node's job for the build `commit` under `prefix`: `ProgramArguments` the host of that build and
        /// exactly a checked node's command line (`HostImages.CheckedCommandLine`'s rendering: `--node`, its folder,
        /// its server; `NodeUnit.execStart`), `SWIFT_BACKTRACE=enable=no` the only variable (the Swift runtime reads it
        /// at load, before the checked start's reset, which rebuilds `HOME` and `PATH` itself), stderr to the data
        /// root's `node.log`; or why the build can't be held (the unit's path and commit checks).
        public static func node(prefix: String, commit: String, home: String, dataRoot: String, atLogin: Bool) -> Result<Job, StartRefusal> {
            for (what, path) in [("prefix", prefix), ("home", home)] {
                if let why = NodeUnit.pathRefusal(path) {
                    return .failure(StartRefusal("the agent can't hold the \(what) \(ConfigSeal.inert(path, limit: .max)): \(why)"))
                }
            }
            guard NodeUnit.isCommit(commit) else {
                return .failure(StartRefusal("the agent can't hold the commit \(ConfigSeal.inert(commit, limit: .max)): it isn't 40 hex digits"))
            }
            if let why = NodeUnit.pathRefusal(dataRoot) {
                return .failure(StartRefusal("the agent can't hold the node's root \(ConfigSeal.inert(dataRoot, limit: .max)): \(why)"))
            }
            return .success(Job(label: NodeAgent.label, programArguments: NodeUnit.execStart(prefix: prefix, commit: commit),
                                environment: ["SWIFT_BACKTRACE": "enable=no"], standardErrorPath: serverLog(nodeRoot: dataRoot), atLogin: atLogin))
        }
    }

    /// Where the agent lives and the node it starts: its label, the folder of its property list, the node's data root
    /// (its socket, lock and log), the user's `gui/<uid>` domain and the `launchctl` that loads it. The user's node's is
    /// `user(...)`; a test gives a scratch label (`dev.vibeswitcher.node.test-…`), folder and root.
    public struct Place: Equatable, Sendable {
        public var label: String
        public var plistFolder: String
        public var dataRoot: String
        /// The host's lock in the data root: the node's `host.lock`; a scratch host's its own.
        public var lock: String
        public var uid: uid_t
        public var launchctl: String

        public init(label: String, plistFolder: String, dataRoot: String, lock: String, uid: uid_t, launchctl: String) {
            self.label = label
            self.plistFolder = plistFolder
            self.dataRoot = dataRoot
            self.lock = lock
            self.uid = uid
            self.launchctl = launchctl
        }

        /// The user's node: `dev.vibeswitcher.node`, `~/Library/LaunchAgents`, `~/.vibeswitcher/v2/node` (the home from
        /// the user database), its `host.lock`.
        public static func user(home: String, uid: uid_t, launchctl: String) -> Place {
            let root = NodeFolders.nodeRoot(accountHome: home)
            return Place(label: NodeAgent.label, plistFolder: NodeFolders.join(home, "Library/LaunchAgents"), dataRoot: root,
                         lock: NodeFolders.join(root, "host.lock"), uid: uid, launchctl: launchctl)
        }

        public var plistPath: String { NodeFolders.join(plistFolder, "\(label).plist") }
        public var domain: String { NodeAgent.domain(uid: uid) }
        public var target: String { "\(domain)/\(label)" }
        /// The host's socket: `<data root>/host.sock`.
        public var socket: String { NodeFolders.join(dataRoot, "host.sock") }
        public var log: String { NodeAgent.serverLog(nodeRoot: dataRoot) }
    }

    /// The agent's keys and values for `job`: its own, and the ones every job of the node's has (`KeepAlive` false,
    /// `ProcessType` Interactive, `LimitLoadToSessionType` Aqua, stdout to /dev/null).
    public static func dictionary(_ job: Job) -> [String: Any] {
        [
            "Label": job.label,
            "ProgramArguments": job.programArguments,
            "EnvironmentVariables": job.environment,
            "RunAtLoad": job.atLogin,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardErrorPath": job.standardErrorPath,
            "StandardOutPath": "/dev/null",
        ]
    }

    /// The agent's keys and values for `inputs`, `nodeRoot` the node's root (its log there), `atLogin` whether it starts
    /// at the user's login; or why it can't hold them (the unit's path and commit checks, `NodeUnit.refusal`).
    public static func dictionary(_ inputs: NodeUnit.Inputs, nodeRoot: String, atLogin: Bool) -> Result<[String: Any], StartRefusal> {
        if let refused = NodeUnit.refusal(inputs) { return .failure(refused) }
        return Job.node(prefix: inputs.prefix, commit: inputs.commit, home: inputs.home, dataRoot: nodeRoot, atLogin: atLogin).map(dictionary)
    }

    /// The property list for `job` (XML, keys sorted), or why it can't be made.
    public static func plist(_ job: Job) -> Result<Data, StartRefusal> {
        do {
            return .success(try PropertyListSerialization.data(fromPropertyList: dictionary(job), format: .xml, options: 0))
        } catch {
            return .failure(StartRefusal("the agent's property list couldn't be made: \(error)", exitCode: 1))
        }
    }

    /// The property list `start` writes (XML, keys sorted), or why it can't.
    public static func plist(_ inputs: NodeUnit.Inputs, nodeRoot: String, atLogin: Bool) -> Result<Data, StartRefusal> {
        if let refused = NodeUnit.refusal(inputs) { return .failure(refused) }
        return Job.node(prefix: inputs.prefix, commit: inputs.commit, home: inputs.home, dataRoot: nodeRoot, atLogin: atLogin).flatMap(plist)
    }

    /// The property list for an installed build, as `scripts/install-node-mac.sh` writes it for the user to load
    /// (`vibeswitcher agent-plist`): the build `commit` under `prefix`, the node's root, no start at login; or why it
    /// can't be made.
    public static func installed(prefix: String, commit: String, home: String) -> Result<Data, StartRefusal> {
        Job.node(prefix: prefix, commit: commit, home: home, dataRoot: NodeFolders.nodeRoot(accountHome: home), atLogin: false).flatMap(plist)
    }

    /// Why the property list `data` (the file as read back) isn't exactly the agent for these inputs, or nil.
    public static func check(_ data: Data, inputs: NodeUnit.Inputs, nodeRoot: String, atLogin: Bool) -> String? {
        if let refused = NodeUnit.refusal(inputs) { return refused.text }
        switch Job.node(prefix: inputs.prefix, commit: inputs.commit, home: inputs.home, dataRoot: nodeRoot, atLogin: atLogin) {
        case .failure(let refusal): return refusal.text
        case .success(let job): return check(data, job: job)
        }
    }

    /// Why the property list `data` isn't exactly `job`'s, or nil: not a property list, a key added or missing, a value
    /// changed (a `KeepAlive`, an environment variable, another program).
    public static func check(_ data: Data, job: Job) -> String? {
        let expected = dictionary(job)
        guard data.count <= 64 * 1024,
              let read = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return "the agent's file isn't a property list"
        }
        let added = Set(read.keys).subtracting(expected.keys).sorted()
        if let key = added.first { return "the agent's file holds \(ConfigSeal.inert(key, limit: 80)), which start doesn't write" }
        for key in expected.keys.sorted() {
            guard let value = read[key] else { return "the agent's file has no \(key)" }
            guard equal(value, expected[key] as Any) else { return "the agent's \(key) isn't what start wrote" }
        }
        return nil
    }

    /// Two property-list values equal (strings, booleans, arrays and dictionaries of them).
    static func equal(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case let (x as String, y as String): return x == y
        case let (x as Bool, y as Bool): return x == y
        case let (x as [Any], y as [Any]): return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case let (x as [String: Any], y as [String: Any]):
            return Set(x.keys) == Set(y.keys) && x.keys.allSatisfy { key in equal(x[key] as Any, y[key] as Any) }
        default: return false
        }
    }

    // MARK: launchctl

    /// The domain the agent lives in: the user's GUI session.
    public static func domain(uid: uid_t) -> String { "gui/\(uid)" }
    /// The job's service target.
    public static func target(uid: uid_t) -> String { "\(domain(uid: uid))/\(label)" }

    /// `launchctl bootstrap gui/<uid> <path>`: loads (and, with RunAtLoad, starts) the agent.
    public static func bootstrap(launchctl: String, uid: uid_t, home: String) -> [String] { [launchctl, "bootstrap", domain(uid: uid), path(home: home)] }
    /// `launchctl kickstart gui/<uid>/dev.vibeswitcher.node`: starts it now.
    public static func kickstart(launchctl: String, uid: uid_t) -> [String] { [launchctl, "kickstart", target(uid: uid)] }
    /// `launchctl bootout gui/<uid>/dev.vibeswitcher.node`: unloads it (launchd ends the job's process group).
    public static func bootout(launchctl: String, uid: uid_t) -> [String] { [launchctl, "bootout", target(uid: uid)] }
    /// `launchctl print gui/<uid>/dev.vibeswitcher.node`: the job as launchd holds it.
    public static func print(launchctl: String, uid: uid_t) -> [String] { [launchctl, "print", target(uid: uid)] }
    /// `launchctl getenv NAME`: what the user's launchd gives every job for `name` (named so: the start's code reads no
    /// environment of its own, `StartCommandTests`).
    public static func managerVariable(launchctl: String, name: String) -> [String] { [launchctl, "getenv", name] }

    /// What `launchctl print` says of the job: its pid (nil while it doesn't run) and its program (the first of its
    /// arguments). The output's lines `pid = <n>` and `program = <path>` at the job's own level (one tab in), never a
    /// nested block's.
    public struct Printed: Equatable, Sendable {
        public var pid: pid_t?
        public var program: String?
        /// `state = running` or `not running` (measured, the design's "The LaunchAgent").
        public var state: String?
        /// `runs = N`: how often launchd has started it since it was loaded.
        public var runs: Int?
        /// `last exit code = N` or `last terminating signal = Killed: 9`, as launchd says it; nil before one.
        public var lastExit: String?
        /// `path = …`: the property list launchd loaded it from.
        public var path: String?

        public init(pid: pid_t? = nil, program: String? = nil, state: String? = nil, runs: Int? = nil, lastExit: String? = nil, path: String? = nil) {
            self.pid = pid
            self.program = program
            self.state = state
            self.runs = runs
            self.lastExit = lastExit
            self.path = path
        }
    }

    public static func printed(_ output: String) -> Printed {
        var found = Printed()
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            // The job's own properties sit one tab in; a nested block's (`environment = {`, `endpoints = {`) deeper.
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let parts = line.dropFirst().split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "pid": found.pid = pid_t(parts[1])
            case "program": found.program = parts[1]
            case "state": found.state = parts[1]
            case "runs": found.runs = Int(parts[1])
            case "last exit code": found.lastExit = parts[1] == "(never exited)" ? nil : "exit code \(parts[1])"
            case "last terminating signal": found.lastExit = "signal \(parts[1])"
            case "path": found.path = parts[1]
            default: break
            }
        }
        return found
    }
}
