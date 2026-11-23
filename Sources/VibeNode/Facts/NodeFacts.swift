import Foundation
import VibeCore

/// What the command line reads of the machine for `status` and `start` (the engine plan's E1; the security
/// architecture document's S1 and S11; the bootstrap path's step 8): plain mode, WSL interop, automount, a `kernel=`
/// line in a mounted `.wslconfig`, and the user manager's environment against the expected set. Never the server's:
/// what a seized server says about the machine is no record. Each reader injectable (`Readers`), so a test gives its
/// own and a scratch node reads its test's stand-ins.
public struct NodeFacts: Equatable, Sendable {
    /// What the manager's environment was found to be.
    public enum Manager: Equatable, Sendable {
        /// Read: the names in it beyond the expected set (empty: none).
        case extra([String])
        /// Not read, and why (no systemd, a scratch node).
        case unknown(String)
    }

    /// Whether WSL interop is on (an interop entry in `/proc/sys/fs/binfmt_misc` says `enabled`, binfmt_misc itself on:
    /// `interop(binfmt:)`); nil: it can't be told.
    public var interop: Bool?
    /// The automounted Windows drives (`9p` or `drvfs` mounts under `/mnt`), by mount point.
    public var automounts: [String]
    /// Each mounted `.wslconfig` that sets `kernel=`.
    public var kernelLines: [String]
    public var manager: Manager

    public init(interop: Bool?, automounts: [String], kernelLines: [String], manager: Manager) {
        self.interop = interop
        self.automounts = automounts
        self.kernelLines = kernelLines
        self.manager = manager
    }

    /// How each fact is read.
    public struct Readers {
        /// The entries of `/proc/sys/fs/binfmt_misc` by name (`status` among them), each one's text, or "" when it
        /// can't be read; nil when the folder can't be listed (binfmt_misc isn't mounted: nothing registered).
        public var binfmt: () -> [String: String]?
        /// The text of `/proc/mounts`; nil when it can't be read.
        public var mounts: () -> String?
        /// The text of a file; nil when it can't be read.
        public var file: (String) -> String?
        /// A folder's entries; nil when it can't be listed.
        public var folder: (String) -> [String]?
        /// `systemctl --user show-environment`'s output, or why it can't be had.
        public var managerEnvironment: () -> Result<String, Failure>

        public init(binfmt: @escaping () -> [String: String]?, mounts: @escaping () -> String?, file: @escaping (String) -> String?,
                    folder: @escaping (String) -> [String]?, managerEnvironment: @escaping () -> Result<String, Failure>) {
            self.binfmt = binfmt
            self.mounts = mounts
            self.file = file
            self.folder = folder
            self.managerEnvironment = managerEnvironment
        }

        /// This machine's: the files where Linux keeps them, and `managerEnvironment` as given.
        public static func machine(binfmtFolder: String = "/proc/sys/fs/binfmt_misc", mountsFile: String = "/proc/mounts",
                                   managerEnvironment: @escaping () -> Result<String, Failure>) -> Readers {
            Readers(binfmt: { entries(binfmtFolder) }, mounts: { read(mountsFile) }, file: read,
                    folder: { try? FileManager.default.contentsOfDirectory(atPath: $0) }, managerEnvironment: managerEnvironment)
        }

        /// Each entry of `folder` but `register` (write only), with its text ("" when it can't be read).
        private static func entries(_ folder: String) -> [String: String]? {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
            var entries: [String: String] = [:]
            for name in names where name != "register" { entries[name] = read((folder as NSString).appendingPathComponent(name)) ?? "" }
            return entries
        }

        private static func read(_ path: String) -> String? {
            FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// Why a reader had nothing.
    public struct Failure: Error, Equatable, Sendable {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    /// The facts as `readers` find them.
    public static func read(_ readers: Readers) -> NodeFacts {
        let mounts = automounts(fromMounts: readers.mounts() ?? "")
        var kernels: [String] = []
        for mount in mounts {
            for user in readers.folder(mount + "/Users") ?? [] {
                let path = mount + "/Users/" + user + "/.wslconfig"
                if let text = readers.file(path), setsKernel(wslconfig: text) { kernels.append(path) }
            }
        }
        let manager: Manager
        switch readers.managerEnvironment() {
        case .success(let text): manager = .extra(extraVariables(showEnvironment: text))
        case .failure(let failure): manager = .unknown(failure.reason)
        }
        return NodeFacts(interop: interop(binfmt: readers.binfmt()), automounts: mounts, kernelLines: kernels.sorted(), manager: manager)
    }

    /// Interop from binfmt_misc's entries (`Readers.binfmt`): WSL registers `WSLInterop`, and with systemd
    /// `WSLInterop-late` too, either of which runs Windows programs; an entry of another name whose interpreter is
    /// WSL's `/init` does the same. On when any of them is `enabled` and binfmt_misc's `status` isn't `disabled`; off
    /// when none is registered or every one is off; nil when one can't be read and none is on.
    public static func interop(binfmt entries: [String: String]?) -> Bool? {
        guard let entries else { return false }
        if let status = entries["status"], interop(fromBinfmt: status) == false { return false }
        var answer: Bool? = false
        for (name, text) in entries where name != "status" && name != "register" {
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            guard name.hasPrefix("WSLInterop") || lines.contains("interpreter /init") else { continue }
            switch interop(fromBinfmt: text) {
            case true?: return true
            case nil: answer = nil
            case false?: break
            }
        }
        return answer
    }

    /// One binfmt_misc entry's text (or `status`'s): on when its first line is `enabled`, off when `disabled` or when
    /// there is no such file (nothing registered), nil for anything else.
    public static func interop(fromBinfmt text: String?) -> Bool? {
        guard let text else { return false }
        switch text.split(separator: "\n").first.map({ $0.trimmingCharacters(in: .whitespaces) }) {
        case "enabled": return true
        case "disabled": return false
        default: return nil
        }
    }

    /// The mount points under `/mnt` of `9p` or `drvfs` file systems in a `/proc/mounts` text (`device point type …`).
    public static func automounts(fromMounts text: String) -> [String] {
        text.split(separator: "\n").compactMap { line -> String? in
            let words = line.split(separator: " ").map(String.init)
            guard words.count >= 3, ["9p", "drvfs"].contains(words[2]), words[1].hasPrefix("/mnt/") else { return nil }
            return words[1].replacingOccurrences(of: "\\040", with: " ")
        }.sorted()
    }

    /// Whether a `.wslconfig` text sets `kernel=` (in any section, a line not commented out).
    public static func setsKernel(wslconfig text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), let equals = trimmed.firstIndex(of: "=") else { return false }
            return trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "kernel"
        }
    }

    /// The names a user manager's environment holds on this machine without anyone setting them: systemd's own and
    /// what WSL's start gives it. Anything else came from `systemctl --user set-environment`, `environment.d` or an
    /// edited unit (S9, T23), and `start` and `status` name it. A first set from the documentation of systemd and WSL,
    /// checked against this machine's manager on 2026-11-17 (names only; `docs/process/v2-linux-inventory.md`, "The
    /// user manager's environment"): every name it holds is here but `SSH_AUTH_SOCK`.
    public static let expectedManagerEnvironment: Set<String> = [
        "HOME", "LANG", "LANGUAGE", "LOGNAME", "PATH", "SHELL", "USER", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS",
        "XDG_DATA_DIRS", "XDG_CONFIG_DIRS", "MANAGERPID", "MANAGERPIDFDID", "INVOCATION_ID", "SYSTEMD_EXEC_PID",
        "JOURNAL_STREAM", "NOTIFY_SOCKET", "MEMORY_PRESSURE_WATCH", "MEMORY_PRESSURE_WRITE", "MOTD_SHOWN",
        "DISPLAY", "WAYLAND_DISPLAY", "PULSE_SERVER", "WSL2_GUI_APPS_ENABLED", "WSL_DISTRO_NAME", "WSLENV",
        // Measured here by the lead, 2026-11-16 (the start plan's ST-D2): a desktop session's, set by gnome-keyring's
        // start. They change nothing the host or a session runs (Qt's accessibility bridge, and a flag that only
        // gnome-session reads). `SSH_AUTH_SOCK`, measured with them, isn't here: the unit unsets it
        // (`NodeUnit.unsetFromManager`).
        "QT_ACCESSIBILITY", "GSM_SKIP_SSH_AGENT_WORKAROUND",
    ]

    /// The names in a `systemctl --user show-environment` text (`NAME=value` lines; a value may be quoted, `$'…'`)
    /// that aren't expected, sorted. `LC_*` is a locale's and expected.
    public static func extraVariables(showEnvironment text: String) -> [String] {
        Set(text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let name = String(line[..<equals])
            return expectedManagerEnvironment.contains(name) || name.hasPrefix("LC_") ? nil : name
        }).sorted()
    }

    /// The lines `status` and `start` print: the standing plain-mode line first (S11), then interop, automount,
    /// `kernel=` and the manager's environment. Paths and names through `ConfigSeal.inert`.
    public var lines: [String] {
        var lines = ["plain mode: no sandbox before stage 6; what that doesn't promise is S11's list (`vibeswitcher start` prints it once)"]
        switch interop {
        case true?: lines.append("interop: on (S11 item 1: while it is on, every lock this node has is void; decision 2 turns it off)")
        case false?: lines.append("interop: off")
        case nil: lines.append("interop: can't be told")
        }
        lines.append(automounts.isEmpty ? "automount: off"
                     : "automount: on (\(automounts.map { ConfigSeal.inert($0, limit: .max) }.joined(separator: ", ")); S11 item 2)")
        if !kernelLines.isEmpty {
            lines.append("kernel= set in \(kernelLines.map { ConfigSeal.inert($0, limit: .max) }.joined(separator: ", ")) (S11 item 2: the next WSL boot runs that kernel)")
        }
        switch manager {
        case .extra(let names) where names.isEmpty: lines.append("the manager's environment: nothing beyond the expected")
        case .extra(let names): lines.append("the manager's environment holds more than expected: \(names.map { ConfigSeal.inert($0, limit: .max) }.joined(separator: ", "))")
        case .unknown(let why): lines.append("the manager's environment: not read (\(why))")
        }
        return lines
    }
}

/// `vibeswitcher start`'s check before anything (S1, decision 2): with interop on it refuses, unless the user says so.
public enum StartCheck {
    /// Why `start` refuses, or nil when it goes on: interop on (or not told) without `--interop-is-on`.
    public static func refusal(facts: NodeFacts, interopIsOn: Bool) -> String? {
        guard facts.interop != false, !interopIsOn else { return nil }
        return facts.interop == true
            ? "WSL interop is on: any process can run Windows programs and `wsl.exe -u root`, and every lock this node has is void (S11 item 1). Turn it off (decision 2), or pass --interop-is-on to start anyway."
            : "whether WSL interop is on can't be told; pass --interop-is-on to start anyway"
    }

    /// The start line this machine's node needs (`stop` and `status` say it): `--interop-is-on` while `start` would
    /// refuse without it. On 2026-11-23 the user was given the bare `vibeswitcher start` after a stop, and the node
    /// stayed down until its refusal was read.
    public static func startLine(facts: NodeFacts) -> String {
        "vibeswitcher start" + (refusal(facts: facts, interopIsOn: false) == nil ? "" : " --interop-is-on")
    }
}
