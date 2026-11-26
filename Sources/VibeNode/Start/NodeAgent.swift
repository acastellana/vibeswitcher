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

    /// The two flags a checked node's next image is started with after its command line on an in-place switch, each
    /// with a number (`HostImages.CheckedCommandLine`, `MacHandoverKeeper.channelFlag` and `pidFlag`; a test holds them
    /// equal): what `MacAgent` lets a switched job's process run beyond its plist's arguments.
    public static let keeperFlags = (channel: "--handover-keeper-channel", pid: "--handover-keeper-pid")

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
            let job = Job(label: NodeAgent.label, programArguments: NodeUnit.execStart(prefix: prefix, commit: commit),
                          environment: ["SWIFT_BACKTRACE": "enable=no"], standardErrorPath: serverLog(nodeRoot: dataRoot), atLogin: atLogin)
            if let why = NodeAgent.unprintable(job) { return .failure(StartRefusal(why)) }
            return .success(job)
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

    /// Why `job` can't be written, or nil: a string of it that isn't printable ASCII (a newline in a variable, a control
    /// character in an argument, a non-ASCII byte in a path): launchd prints them raw, so they would be lines of its word.
    public static func unprintable(_ job: Job) -> String? {
        let strings = [job.label, job.standardErrorPath] + job.programArguments + job.environment.keys.sorted() + job.environment.values.sorted()
        guard let bad = strings.first(where: { !isPrintable($0) }) else { return nil }
        return "the agent's job can't hold \(ConfigSeal.inert(bad, limit: 120)): only printable ASCII is written in it (launchd prints it raw)"
    }

    /// The property list for `job` (XML, keys sorted), or why it can't be made.
    public static func plist(_ job: Job) -> Result<Data, StartRefusal> {
        if let why = unprintable(job) { return .failure(StartRefusal(why, exitCode: 1)) }
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
        // And byte for byte (a value of another type that reads back equal, an integer for a boolean, is another plist).
        guard case .success(let made) = plist(job), made == data else { return "the agent's file isn't byte for byte what start writes" }
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
        /// `arguments = { … }`: the program's arguments as launchd holds them.
        public var arguments: [String]?
        /// `environment = { NAME => VALUE … }`: the plist's `EnvironmentVariables` and launchd's own (not the inherited
        /// or default blocks).
        public var environment: [String: String]?
        /// `stdout path = …`, `stderr path = …`.
        public var stdoutPath: String?
        public var stderrPath: String?
        /// `properties = …`: launchd's flags for the job (`runatload`, `keepalive`, `inferred program`; measured on 27.2).
        public var properties: String?

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
        // The job's own blocks (one tab in, their lines two tabs in, up to the block's `}` one tab in).
        var block: String?
        var arguments: [String] = [], environment: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = block {
                if line == "\t}" {
                    if open == "arguments" { found.arguments = arguments }
                    if open == "environment" { found.environment = environment }
                    block = nil
                } else if line.hasPrefix("\t\t"), !line.hasPrefix("\t\t\t") {
                    let item = String(line.dropFirst(2))
                    if open == "arguments" { arguments.append(item) }
                    if open == "environment", let arrow = item.range(of: " => ") {
                        environment[String(item[..<arrow.lowerBound])] = String(item[arrow.upperBound...])
                    }
                }
                continue
            }
            if line == "\targuments = {" || line == "\tenvironment = {" {
                block = String(line.dropFirst().dropLast(4))
                continue
            }
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
            case "stdout path": found.stdoutPath = parts[1]
            case "stderr path": found.stderrPath = parts[1]
            case "properties": found.properties = parts[1]
            default: break
            }
        }
        return found
    }
}

// MARK: launchd's word, by one grammar

extension NodeAgent {
    /// Why `launchctl print`'s output couldn't be placed as `job`'s (the design's "The re-check's round").
    public struct Unplaced: Error, Equatable, Sendable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// Whether `text` is printable ASCII only (the job's strings, and launchd's lines once their tabs are dropped).
    public static func isPrintable(_ text: String) -> Bool { text.utf8.allSatisfy { (0x20...0x7e).contains($0) } }

    /// The variables launchd adds to every job's `environment` block (measured, macOS 27.2).
    public static func launchdVariables(label: String) -> [String: String] { ["OSLogRateLimit": "64", "XPC_SERVICE_NAME": label] }

    /// `launchctl print`'s whole output read against the template derived from `job` (the design's "The re-check's round":
    /// macOS 27.2's format, every line placed, in launchd's order, nothing searched for): the job loaded from `plistPath`
    /// (the agent's plist as launchd resolves it) in `gui/<uid>`. What it says of the job, or why it can't be placed.
    public static func placed(_ output: Data, job: Job, plistPath: String, uid: uid_t) -> Result<Printed, Unplaced> {
        // Bytes: a tab, a newline or printable ASCII, nothing else (no CR, no byte above 0x7E).
        guard output.allSatisfy({ $0 == 0x09 || $0 == 0x0a || (0x20...0x7e).contains($0) }) else {
            return .failure(Unplaced("launchd's print holds a byte that isn't printable ASCII"))
        }
        let lines = output.split(separator: 0x0a, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var at = 0
        var found = Printed()
        func next() -> String? { at < lines.count ? lines[at] : nil }
        func fail(_ why: String) -> Result<Printed, Unplaced> {
            .failure(Unplaced("launchd's print isn't the job start wrote: \(why) (line \(at + 1): \(ConfigSeal.inert(next() ?? "(end)", limit: 200)))"))
        }
        func literal(_ line: String) -> Bool {
            guard next() == line else { return false }
            at += 1
            return true
        }
        /// `\t<key> = <value>` with `valid(value)`: the value, or nil (nothing taken).
        func value(_ key: String, _ valid: (String) -> Bool) -> String? {
            let head = "\t\(key) = "
            guard let line = next(), line.hasPrefix(head) else { return nil }
            let rest = String(line.dropFirst(head.count))
            guard valid(rest) else { return nil }
            at += 1
            return rest
        }
        func digits(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= 12 && text.allSatisfy(\.isNumber) && text.allSatisfy(\.isASCII) }
        func hex(_ text: String) -> Bool { text.hasPrefix("0x") && text.count > 2 && text.count <= 18 && text.dropFirst(2).allSatisfy(\.isHexDigit) }
        func words(_ text: String) -> Bool { !text.isEmpty && text.count <= 80 && text.allSatisfy { $0 == " " || ($0.isASCII && $0.isLowercase) } }
        func name(_ text: Substring) -> Bool {
            guard let first = text.first, first == "_" || (first.isASCII && first.isLetter) else { return false }
            return text.count <= 200 && text.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
        }
        func blank() -> Bool { literal("") }
        /// A block's `NAME => VALUE` lines up to its `\t}`: each name once.
        func variables() -> [String: String]? {
            var read: [String: String] = [:]
            while let line = next(), line != "\t}" {
                guard line.hasPrefix("\t\t"), let arrow = line.range(of: " => ") else { return nil }
                let key = line[line.index(line.startIndex, offsetBy: 2)..<arrow.lowerBound]
                guard name(key), read[String(key)] == nil else { return nil }
                read[String(key)] = String(line[arrow.upperBound...])
                at += 1
            }
            return literal("\t}") ? read : nil
        }
        let label = job.label
        guard literal("gui/\(uid)/\(label) = {") else { return fail("its first line") }
        guard value("active count", digits) != nil else { return fail("active count") }
        guard literal("\tpath = \(plistPath)") else { return fail("its path isn't the agent's plist") }
        found.path = plistPath
        guard literal("\ttype = LaunchAgent") else { return fail("type") }
        guard let state = value("state", { ["not running", "running", "xpcproxy"].contains($0) }) else { return fail("state") }
        found.state = state
        guard blank(), literal("\tprogram = \(job.programArguments[0])"), literal("\targuments = {") else { return fail("its program") }
        for argument in job.programArguments where !literal("\t\t\(argument)") { return fail("its arguments") }
        guard literal("\t}") else { return fail("its arguments") }
        found.program = job.programArguments[0]
        found.arguments = job.programArguments
        guard blank(), literal("\tstdout path = /dev/null"), literal("\tstderr path = \(job.standardErrorPath)") else { return fail("its output paths") }
        found.stdoutPath = "/dev/null"
        found.stderrPath = job.standardErrorPath
        guard literal("\tinherited environment = {"), variables() != nil, blank() else { return fail("its inherited environment") }
        guard literal("\tdefault environment = {"), literal("\t\tPATH => /usr/bin:/bin:/usr/sbin:/sbin"), literal("\t}"), blank() else {
            return fail("its default environment")
        }
        let expected = job.environment.merging(launchdVariables(label: label)) { $1 }
        guard literal("\tenvironment = {"), let environment = variables(), environment == expected, blank() else {
            return fail("its environment isn't the job's variables and launchd's two")
        }
        found.environment = environment
        guard value("domain", { text in
            let head = "gui/\(uid) ["
            return text.hasPrefix(head) && text.hasSuffix("]") && digits(String(text.dropFirst(head.count).dropLast()))
        }) != nil else { return fail("domain") }
        guard value("asid", digits) != nil, literal("\tminimum runtime = 10"), literal("\texit timeout = 5") else { return fail("asid, minimum runtime or exit timeout") }
        guard let runs = value("runs", digits) else { return fail("runs") }
        found.runs = Int(runs)
        // The running group: all of it or none.
        if let pid = value("pid", digits) {
            found.pid = pid_t(pid)
            let reasons = job.atLogin ? ["non-ipc demand", "speculative"] : ["non-ipc demand"]
            guard value("immediate reason", { reasons.contains($0) }) != nil else { return fail("immediate reason") }
            for key in ["forks", "execs", "initialized", "trampolined", "started suspended", "proxy started suspended"] where value(key, digits) == nil {
                return fail(key)
            }
            guard value("checked allocations", { text in
                let parts = text.split(separator: " ", omittingEmptySubsequences: false)
                return parts.count == 4 && digits(String(parts[0])) && parts[1] == "(queried" && parts[2] == "=" && parts[3].hasSuffix(")")
                    && digits(String(parts[3].dropLast()))
            }) != nil, value("checked allocations reason", words) != nil, value("checked allocations flags", hex) != nil else {
                return fail("checked allocations")
            }
        }
        // One last-exit line.
        // `(never exited)`, a number, or a number and its name (`78: EX_CONFIG`, measured).
        func exitCode(_ text: String) -> Bool {
            if text == "(never exited)" || digits(text) { return true }
            let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 && digits(String(parts[0])) && parts[1].hasPrefix(" ") && parts[1].count > 1 && parts[1].count <= 40
                && parts[1].dropFirst().allSatisfy { $0 == "_" || ($0.isASCII && ($0.isUppercase || $0.isNumber)) }
        }
        if let code = value("last exit code", exitCode) {
            found.lastExit = code == "(never exited)" ? nil : "exit code \(code)"
        } else if let signal = value("last terminating signal", { !$0.isEmpty && $0.count <= 80 }) {
            found.lastExit = "signal \(signal)"
        } else if let reason = value("last exit reason", { !$0.isEmpty && $0.count <= 80 && $0.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isUppercase || $0.isNumber)) } }) {
            found.lastExit = "reason \(reason)"
        } else {
            return fail("its last exit")
        }
        guard blank() else { return fail("a blank line after its last exit") }
        // The two coalition blocks: both or neither.
        if literal("\tresource coalition = {") {
            for kind in ["resource", "jetsam"] {
                if kind == "jetsam", !literal("\tjetsam coalition = {") { return fail("its jetsam coalition") }
                guard value("\tID", digits) != nil, literal("\t\ttype = \(kind)"), value("\tstate", words) != nil,
                      value("\tactive count", digits) != nil, literal("\t\tname = \(label)"), literal("\t}"), blank() else {
                    return fail("its \(kind) coalition")
                }
            }
        }
        guard literal("\tspawn type = interactive (4)") else { return fail("spawn type (ProcessType)") }
        guard value("jetsam priority", digits) != nil,
              value("jetsam memory limit (active)", { $0 == "(unlimited)" || digits($0) }) != nil,
              value("jetsam memory limit (inactive)", { $0 == "(unlimited)" || digits($0) }) != nil,
              literal("\tjetsamproperties category = daemon"), value("jetsam thread limit", digits) != nil,
              literal("\tcpumon = default"), value("sanitizer flags", hex) != nil, blank() else { return fail("its jetsam lines") }
        let properties = job.atLogin ? "runatload | inferred program" : "inferred program"
        guard literal("\tproperties = \(properties)") else { return fail("properties") }
        found.properties = properties
        guard literal("}") else { return fail("its closing line") }
        // Nothing after it but the output's last newline.
        guard at == lines.count - 1, lines[at].isEmpty else { return fail("a line after its closing line") }
        return .success(found)
    }
}
