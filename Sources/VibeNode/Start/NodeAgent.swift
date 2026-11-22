import Foundation
import VibeCore

/// The LaunchAgent that runs the node on the Mac (the node on the Mac's design, "The service: a LaunchAgent, not the
/// app"; its step 5): `~/Library/LaunchAgents/dev.vibeswitcher.node.plist`, the Mac's `vibeswitcher-node.service`
/// (`NodeUnit`). Its property list, made whole from the same inputs as the unit (`NodeUnit.Inputs`) and read back
/// against them (`check`: exactly these keys and values, nothing added); the `launchctl` command lines that load, unload
/// and show it in `gui/<uid>`, and what `launchctl print` says of the job (its pid and program). Built and tested on
/// both systems as data; nothing here runs `launchctl` or writes the file, and `start` on the Mac is still refused
/// (`NodeSystem.macUnbuilt`): wiring it, and what launchd really does with it, is a real Mac's (docs/process/v2-mac-tasks.md).
///
/// As the unit: `KeepAlive` false (`Restart=no`), `RunAtLoad` only with `--at-login`, the commit's own host with
/// `--node`, `--node-root` its folder and its server (never `current`), `HOME`, `PATH` and `SWIFT_BACKTRACE` written in
/// it. Unlike it: `ProcessType` Interactive and `LimitLoadToSessionType` Aqua (the GUI session, where LocalAuthentication
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

    /// The Mac's PATH for the host: root's folders first, then swiftly's and node's (as the unit's: S9, S10).
    public static func path(swiftBin: String, nodeBin: String) -> String {
        "/usr/bin:/bin:/usr/sbin:/sbin:\(swiftBin):\(nodeBin)"
    }

    /// The agent's keys and values for `inputs`, `nodeRoot` the node's root (its log there), `atLogin` whether it starts
    /// at the user's login; or why it can't hold them (the unit's path and commit checks, `NodeUnit.refusal`).
    public static func dictionary(_ inputs: NodeUnit.Inputs, nodeRoot: String, atLogin: Bool) -> Result<[String: Any], StartRefusal> {
        if let refused = NodeUnit.refusal(inputs) { return .failure(refused) }
        if let why = NodeUnit.pathRefusal(nodeRoot) {
            return .failure(StartRefusal("the agent can't hold the node's root \(ConfigSeal.inert(nodeRoot, limit: .max)): \(why)"))
        }
        return .success([
            "Label": label,
            "ProgramArguments": NodeUnit.execStart(prefix: inputs.prefix, commit: inputs.commit),
            "EnvironmentVariables": ["HOME": inputs.home, "PATH": path(swiftBin: inputs.swiftBin, nodeBin: inputs.nodeBin),
                                     "SWIFT_BACKTRACE": "enable=no"],
            "RunAtLoad": atLogin,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardErrorPath": serverLog(nodeRoot: nodeRoot),
            "StandardOutPath": "/dev/null",
        ])
    }

    /// The property list `start` writes (XML, keys sorted), or why it can't.
    public static func plist(_ inputs: NodeUnit.Inputs, nodeRoot: String, atLogin: Bool) -> Result<Data, StartRefusal> {
        dictionary(inputs, nodeRoot: nodeRoot, atLogin: atLogin).flatMap { values in
            do {
                return .success(try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0))
            } catch {
                return .failure(StartRefusal("the agent's property list couldn't be made: \(error)", exitCode: 1))
            }
        }
    }

    /// The property list for an installed build, as `scripts/install-node-mac.sh` writes it for the user to load
    /// (`vibeswitcher agent-plist`): the build `commit` under `prefix`, the account's swift and node folders (`folders`,
    /// `NodeFolders.toolFolders`), the node's root, no start at login; or why it can't be made.
    public static func installed(prefix: String, commit: String, home: String,
                                 folders: (String) -> Result<(swiftBin: String, nodeBin: String), StartRefusal> = {
                                     NodeFolders.toolFolders(accountHome: $0, nodeVersion: nil, existingUnit: nil)
                                 }) -> Result<Data, StartRefusal> {
        folders(home).flatMap { tools in
            plist(NodeUnit.Inputs(prefix: prefix, commit: commit, home: home, swiftBin: tools.swiftBin, nodeBin: tools.nodeBin),
                  nodeRoot: NodeFolders.nodeRoot(accountHome: home), atLogin: false)
        }
    }

    /// Why the property list `data` (the file as read back) isn't exactly the agent for these inputs, or nil: not a
    /// property list, a key added or missing, a value changed (a `KeepAlive`, an environment variable, another program).
    public static func check(_ data: Data, inputs: NodeUnit.Inputs, nodeRoot: String, atLogin: Bool) -> String? {
        let expected: [String: Any]
        switch dictionary(inputs, nodeRoot: nodeRoot, atLogin: atLogin) {
        case .failure(let refusal): return refusal.text
        case .success(let values): expected = values
        }
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
            default: break
            }
        }
        return found
    }
}
