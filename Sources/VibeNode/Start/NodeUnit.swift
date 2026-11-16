import Foundation
import VibeCore

/// The user unit that runs the node, `vibeswitcher-node.service` (the bootstrap path's "Who starts the node"; the
/// security architecture document's S9; the start plan's ST-D4): its text, made whole from `Inputs` by `start` (and by
/// `switch` and `rollback`), read back by `inputs(parsing:prefix:)`, and what the manager must show of it after
/// `daemon-reload` (`expectedShow`, ST-D2).
///
/// An enum, not the plan's `struct`: it has no instances, only the unit's values (2026-11-16).
public enum NodeUnit {
    /// What a unit is made from: the install prefix and the commit whose folder `ExecStart` names (never `current`),
    /// the account's home, and the two folders the unit's PATH adds (swiftly's and node's, from fixed places: ST-D4).
    public struct Inputs: Equatable, Sendable {
        public var prefix: String
        public var commit: String
        public var home: String
        public var swiftBin: String
        public var nodeBin: String

        public init(prefix: String, commit: String, home: String, swiftBin: String, nodeBin: String) {
            self.prefix = prefix
            self.commit = commit
            self.home = home
            self.swiftBin = swiftBin
            self.nodeBin = nodeBin
        }
    }

    /// The unit's file name in the unit folder (`NodeFolders.unitFolder`).
    public static let fileName = VoiceRule.nodeUnit

    /// `TimeoutStopSec=`: the server's `stop` waits 30 s for sessions, then the shutdown follows (ST-D4).
    public static let timeoutStop = 45

    /// The names the manager's environment may hold that the unit takes out of the host's start, so that
    /// `systemctl --user set-environment` can't reach it: the loader's and the shells' variables, VibeSwitcher's own
    /// folder and the Mac's home override (S9, T27), then `unsetFromManager`. `SWIFT_BACKTRACE` is not here: systemd
    /// applies `UnsetEnvironment=` after `Environment=`, and a name here would remove the unit's own assignment too
    /// (`systemd.exec(5)`; `noNameIsBothUnsetAndAssigned`).
    public static let unset = ["LD_PRELOAD", "LD_AUDIT", "LD_LIBRARY_PATH", "GCONV_PATH", "BASH_ENV", "ENV", "VIBESWITCHER_HOME",
                               "CFFIXED_USER_HOME"] + unsetFromManager

    /// The names a desktop session's manager holds here that the unit unsets, and `start` therefore doesn't refuse
    /// (`NodeFolders.managerRefusal`): `SSH_AUTH_SOCK`, gnome-keyring's agent socket (D9: no agent socket reaches the
    /// host or a session). The lead's measurement, 2026-11-16 (ST-D2).
    public static let unsetFromManager = ["SSH_AUTH_SOCK"]

    /// What the unit's `KillMode=control-group` means, in the spec's words; the confirmation shows it.
    public static let killModeConsequence = "when the host exits for any reason (a crash, an OOM kill, an idle exit, a failed fallback, `stop`), every session, the server and every process left in the unit's cgroup end with it, as the vault's loss already ends every team"

    /// The properties `start` asks of the manager after `daemon-reload` (`systemctl --user show -p …`, ST-D2), in this
    /// order.
    public static let showProperties = ["FragmentPath", "DropInPaths", "ExecStart", "ExecStartPre", "ExecStartPost", "ExecStopPost",
                                        "Environment", "UnsetEnvironment", "Restart", "KillMode", "NeedDaemonReload"]

    /// The unit's PATH: root's folders first, then swiftly's and node's (S9, S10).
    public static func path(swiftBin: String, nodeBin: String) -> String {
        "/usr/local/bin:/usr/bin:/bin:\(swiftBin):\(nodeBin)"
    }

    /// The unit's `ExecStart`, word by word: the commit's own host with `--node`, its folder as `--node-root` and its
    /// server, never `current` (a moved link changes nothing until the user switches).
    public static func execStart(prefix: String, commit: String) -> [String] {
        let folder = "\(prefix)/\(commit)"
        return ["\(folder)/bin/vibeswitcher-host", "--node", "--node-root", folder, "--server", "\(folder)/bin/vibeswitcher-server"]
    }

    /// The unit's whole text for `inputs`, or why it can't hold them: a path that isn't absolute, names `.` or `..`, is
    /// under `/mnt/`, or holds a character systemd reads (ST-D4), or a commit that isn't 40 lowercase hex digits.
    /// `[Unit]`, `[Service]` and `[Install]` in a fixed order, one assignment a line; `ExecStart` space-joined with no
    /// quoting (nothing in it needs any once refused), `HOME` and `PATH` quoted.
    public static func text(_ inputs: Inputs) -> Result<String, StartRefusal> {
        if let refused = refusal(inputs) { return .failure(refused) }
        let exec = execStart(prefix: inputs.prefix, commit: inputs.commit).joined(separator: " ")
        let lines = [
            "# Written whole by `vibeswitcher start`, `switch` and `rollback`: an edit here is replaced by the next of them,",
            "# and `start` checks what the manager shows of this unit after daemon-reload.",
            "[Unit]",
            "Description=VibeSwitcher node",
            "",
            "[Service]",
            "Type=simple",
            "ExecStart=\(exec)",
            "Restart=no",
            "# KillMode=control-group: \(killModeConsequence).",
            "KillMode=control-group",
            "TimeoutStopSec=\(timeoutStop)",
            "UnsetEnvironment=\(unset.joined(separator: " "))",
            "Environment=SWIFT_BACKTRACE=enable=no",
            "Environment=\"HOME=\(inputs.home)\"",
            "Environment=\"PATH=\(path(swiftBin: inputs.swiftBin, nodeBin: inputs.nodeBin))\"",
            "",
            "[Install]",
            "WantedBy=default.target",
        ]
        return .success(lines.joined(separator: "\n") + "\n")
    }

    /// A unit text's assignments, key to values in the order written (a key assigned twice has two); comments, blank
    /// lines and section headers left out. Values as written (quotes kept): `words` splits one.
    public static func parse(_ text: String) -> [String: [String]] {
        var found: [String: [String]] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";"), !line.hasPrefix("["),
                  let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            found[key, default: []].append(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
        }
        return found
    }

    /// A value's words, split on whitespace outside double quotes, the quotes dropped (`"PATH=/a b" X` is `PATH=/a b`
    /// and `X`). The unit's own values hold no backslash, so none is read as an escape.
    public static func words(_ value: String) -> [String] {
        var words: [String] = []
        var word = ""
        var quoted = false, inWord = false
        for character in value {
            if character == "\"" {
                quoted.toggle()
                inWord = true
            } else if character.isWhitespace, !quoted {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            } else {
                word.append(character)
                inWord = true
            }
        }
        if inWord { words.append(word) }
        return words
    }

    /// The inputs a unit's text names, or why it doesn't name them in `start`'s form: exactly one `ExecStart`, exactly
    /// `execStart(prefix:commit:)` for a commit of 40 hex digits in `prefix`; `HOME` and a `PATH` of `path`'s form
    /// from its `Environment=` lines; each of them what `text` takes. Whether the commit's folder is a build is
    /// `NodeFolders.verifyBuild`'s.
    public static func inputs(parsing text: String, prefix: String) -> Result<Inputs, StartRefusal> {
        let unit = parse(text)
        guard let exec = unit["ExecStart"], exec.count == 1 else {
            return .failure(StartRefusal("the unit holds \(unit["ExecStart"]?.count ?? 0) ExecStart lines, not one"))
        }
        let words = words(exec[0])
        let hostSuffix = "/bin/vibeswitcher-host"
        guard let host = words.first, host.hasPrefix(prefix + "/"), host.hasSuffix(hostSuffix),
              host.count > prefix.count + 1 + hostSuffix.count else {
            return .failure(StartRefusal("the unit's ExecStart runs \(ConfigSeal.inert(words.first ?? "nothing", limit: .max)), not a build's host in the prefix \(ConfigSeal.inert(prefix, limit: .max))"))
        }
        let commit = String(host.dropFirst(prefix.count + 1).dropLast(hostSuffix.count))
        guard isCommit(commit) else {
            return .failure(StartRefusal("the unit's ExecStart names the commit \(ConfigSeal.inert(commit, limit: .max)), which isn't 40 hex digits"))
        }
        let expected = execStart(prefix: prefix, commit: commit)
        guard words == expected else {
            return .failure(StartRefusal("the unit's ExecStart isn't exactly start's (\(expected.joined(separator: " "))): it reads \(ConfigSeal.inert(exec[0], limit: .max))"))
        }
        var assigned: [String: String] = [:]
        for word in (unit["Environment"] ?? []).flatMap(Self.words) {
            let parts = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { assigned[String(parts[0])] = String(parts[1]) }
        }
        guard let home = assigned["HOME"] else { return .failure(StartRefusal("the unit assigns no HOME")) }
        let root = String(path(swiftBin: "", nodeBin: "").dropLast(2))
        guard let unitPath = assigned["PATH"], unitPath.hasPrefix(root + ":") else {
            return .failure(StartRefusal("the unit's PATH isn't start's (\(root):<swiftly's bin>:<node's bin>): it reads \(ConfigSeal.inert(assigned["PATH"] ?? "nothing", limit: .max))"))
        }
        let folders = unitPath.dropFirst(root.count + 1).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard folders.count == 2 else {
            return .failure(StartRefusal("the unit's PATH isn't start's (\(root):<swiftly's bin>:<node's bin>): it reads \(ConfigSeal.inert(unitPath, limit: .max))"))
        }
        let inputs = Inputs(prefix: prefix, commit: commit, home: home, swiftBin: folders[0], nodeBin: folders[1])
        if let refused = refusal(inputs) { return .failure(refused) }
        return .success(inputs)
    }

    /// What `systemctl --user show -p <showProperties>` must print for the unit `text(inputs)` wrote at `unitFile`
    /// (ST-D2): that file as `FragmentPath`, no drop-in, no other command, the unit's own environment lines and values.
    /// `ExecStart`'s value is its first part, up to `ignore_errors=no ;`: the rest (`start_time`, `pid`, …) is the
    /// last run's, and `showMismatch` compares it as a prefix.
    public static func expectedShow(_ inputs: Inputs, unitFile: String) -> [String: String] {
        let exec = execStart(prefix: inputs.prefix, commit: inputs.commit)
        return [
            "FragmentPath": unitFile,
            "DropInPaths": "",
            "ExecStart": "{ path=\(exec[0]) ; argv[]=\(exec.joined(separator: " ")) ; ignore_errors=no ;",
            "ExecStartPre": "",
            "ExecStartPost": "",
            "ExecStopPost": "",
            "Environment": "SWIFT_BACKTRACE=enable=no HOME=\(inputs.home) PATH=\(path(swiftBin: inputs.swiftBin, nodeBin: inputs.nodeBin))",
            "UnsetEnvironment": unset.joined(separator: " "),
            "Restart": "no",
            "KillMode": "control-group",
            "NeedDaemonReload": "no",
        ]
    }

    /// The first of `expected`'s properties (in `showProperties`' order) that `shown` (`systemctl show`'s
    /// `Key=value` lines) doesn't match, said with both values; nil when every one does. A property not printed is
    /// empty (`show` leaves out an empty command list); a command list printed on several lines is all of them;
    /// `ExecStart` must be one line beginning with its expected value.
    public static func showMismatch(_ shown: String, expected: [String: String]) -> String? {
        var printed: [String: [String]] = [:]
        for line in shown.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            printed[String(line[..<equals]), default: []].append(String(line[line.index(after: equals)...]))
        }
        let order = showProperties.filter { expected[$0] != nil } + expected.keys.filter { !showProperties.contains($0) }.sorted()
        for key in order {
            guard let want = expected[key] else { continue }
            let values = printed[key] ?? []
            let got = values.joined(separator: "\n")
            let matches = key == "ExecStart" ? values.count == 1 && got.hasPrefix(want) : got == want
            if !matches {
                return "the manager shows \(key)=\(ConfigSeal.inert(got, limit: .max)) where start wrote \(key)=\(ConfigSeal.inert(want, limit: .max))"
            }
        }
        return nil
    }

    // MARK: - What the unit can hold

    /// Why the unit can't hold `inputs`, or nil.
    static func refusal(_ inputs: Inputs) -> StartRefusal? {
        for (label, path) in [("prefix", inputs.prefix), ("home", inputs.home), ("swift folder", inputs.swiftBin), ("node folder", inputs.nodeBin)] {
            if let why = pathRefusal(path) {
                return StartRefusal("the unit can't hold the \(label) \(ConfigSeal.inert(path, limit: .max)): \(why)")
            }
        }
        guard isCommit(inputs.commit) else {
            return StartRefusal("the unit can't hold the commit \(ConfigSeal.inert(inputs.commit, limit: .max)): it isn't 40 hex digits")
        }
        return nil
    }

    /// Why a path can't be written into the unit, or nil: a character systemd reads (`%` specifiers, whitespace it
    /// splits on, quotes, a backslash, `$`) or a control character, checked first; then not absolute, a `.` or `..`
    /// in it, or a folder under `/mnt/` (a Windows drive: the unit's PATH holds none, S9).
    static func pathRefusal(_ path: String) -> String? {
        if let character = unsafeCharacter(in: path) {
            return "it holds \(character) (systemd expands % specifiers, splits on whitespace and reads quotes, backslashes and $)"
        }
        guard path.hasPrefix("/") else { return "it isn't an absolute path" }
        let names = path.split(separator: "/")
        guard !names.contains("."), !names.contains("..") else { return "it names . or .." }
        guard path != "/mnt", !path.hasPrefix("/mnt/") else { return "it is under /mnt/ (a Windows drive; the unit holds no /mnt/ folder)" }
        return nil
    }

    /// The first character in `path` the unit can't hold unquoted, named: `%`, `"`, `'`, `\`, `$`, "whitespace" or
    /// "a control character".
    static func unsafeCharacter(in path: String) -> String? {
        for scalar in path.unicodeScalars {
            switch scalar {
            case "%", "\"", "'", "\\", "$": return String(scalar)
            default:
                if scalar.properties.isWhitespace { return "whitespace" }
                if scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value) { return "a control character" }
            }
        }
        return nil
    }

    /// 40 lowercase hex digits.
    static func isCommit(_ text: String) -> Bool {
        text.utf8.count == 40 && text.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }
}
