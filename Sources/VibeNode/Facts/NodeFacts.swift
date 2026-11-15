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

    /// Whether WSL interop is on (`/proc/sys/fs/binfmt_misc/WSLInterop` says `enabled`); nil: it can't be told.
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
        /// The text of `/proc/sys/fs/binfmt_misc/WSLInterop`; nil when it isn't there (no interop registered).
        public var interop: () -> String?
        /// The text of `/proc/mounts`; nil when it can't be read.
        public var mounts: () -> String?
        /// The text of a file; nil when it can't be read.
        public var file: (String) -> String?
        /// A folder's entries; nil when it can't be listed.
        public var folder: (String) -> [String]?
        /// `systemctl --user show-environment`'s output, or why it can't be had.
        public var managerEnvironment: () -> Result<String, Failure>

        public init(interop: @escaping () -> String?, mounts: @escaping () -> String?, file: @escaping (String) -> String?,
                    folder: @escaping (String) -> [String]?, managerEnvironment: @escaping () -> Result<String, Failure>) {
            self.interop = interop
            self.mounts = mounts
            self.file = file
            self.folder = folder
            self.managerEnvironment = managerEnvironment
        }

        /// This machine's: the files where Linux keeps them, and `managerEnvironment` as given.
        public static func machine(interopFile: String = "/proc/sys/fs/binfmt_misc/WSLInterop", mountsFile: String = "/proc/mounts",
                                   managerEnvironment: @escaping () -> Result<String, Failure>) -> Readers {
            Readers(interop: { read(interopFile) }, mounts: { read(mountsFile) }, file: read,
                    folder: { try? FileManager.default.contentsOfDirectory(atPath: $0) }, managerEnvironment: managerEnvironment)
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
        return NodeFacts(interop: interop(fromBinfmt: readers.interop()), automounts: mounts, kernelLines: kernels.sorted(), manager: manager)
    }

    /// Interop from `WSLInterop`'s text: on when its first line is `enabled`, off when `disabled` or when there is no
    /// such file (nothing registered), nil for anything else.
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
    /// edited unit (S9, T23), and `start` and `status` name it. A first set from the documentation of systemd and WSL;
    /// the user's M4 output (the bootstrap path) checks it against this machine.
    public static let expectedManagerEnvironment: Set<String> = [
        "HOME", "LANG", "LANGUAGE", "LOGNAME", "PATH", "SHELL", "USER", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS",
        "XDG_DATA_DIRS", "XDG_CONFIG_DIRS", "MANAGERPID", "MANAGERPIDFDID", "INVOCATION_ID", "SYSTEMD_EXEC_PID",
        "JOURNAL_STREAM", "NOTIFY_SOCKET", "MEMORY_PRESSURE_WATCH", "MEMORY_PRESSURE_WRITE", "MOTD_SHOWN",
        "DISPLAY", "WAYLAND_DISPLAY", "PULSE_SERVER", "WSL2_GUI_APPS_ENABLED", "WSL_DISTRO_NAME", "WSLENV",
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
}
