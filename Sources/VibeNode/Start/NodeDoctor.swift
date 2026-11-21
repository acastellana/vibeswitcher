import Foundation
import VibeCore

/// `vibeswitcher doctor` (the parity table's first-run row; the app's onboarding and `ToolInstaller`, which install;
/// a node installs nothing): each thing the node needs, or that keeps it safe, checked from fixed places as `start`'s
/// preflight checks them (never the shell's PATH), each missing one with the exact command for the user to run. It runs
/// nothing to look: files are only looked at (no `gh`, no `tailscale`, no `claude`), and the node is asked nothing.
///
/// Needed: claude (from its link, `NodePreflight.claudeLink`), git in a folder only root can write, swiftly's swift and
/// nvm's node where the unit's PATH takes them (`NodeFolders.toolFolders`'s places). Then the steps in order: a build
/// installed (`<home>/.vibeswitcher/v2/builds/current`), the node started, the hooks installed. Advised: WSL interop off
/// (the security document's decision 2, the bootstrap path's M5), systemd as pid 1 (else the detached start), the
/// root-owned toolchain the install builds with, gh signed in (the install fetches and checks CI with it), and Tailscale
/// (only for `web --tailnet`).
public enum NodeDoctor {
    public enum Level: String, Sendable { case needed, step, advised }

    public struct Check: Equatable, Sendable {
        public var name: String
        public var level: Level
        public var ok: Bool
        /// What was found, or what's wrong.
        public var says: String
        /// The exact command(s) for the user to run when it isn't ok (nil: nothing to run).
        public var fix: String?
    }

    /// What it looks at, injected for tests.
    public struct Probes: Sendable {
        public var home: String
        public var claude: @Sendable () -> (path: String?, why: String?)
        public var git: @Sendable () -> String?
        public var executable: @Sendable (String) -> Bool
        public var exists: @Sendable (String) -> Bool
        public var read: @Sendable (String) -> String?
        public var systemd: @Sendable () -> NodeFolders.Mode
        public var nodeRunning: @Sendable () -> Bool
        public var hooksInstalled: @Sendable () -> Bool

        public init(home: String, claude: @escaping @Sendable () -> (path: String?, why: String?), git: @escaping @Sendable () -> String?,
                    executable: @escaping @Sendable (String) -> Bool, exists: @escaping @Sendable (String) -> Bool,
                    read: @escaping @Sendable (String) -> String?, systemd: @escaping @Sendable () -> NodeFolders.Mode,
                    nodeRunning: @escaping @Sendable () -> Bool, hooksInstalled: @escaping @Sendable () -> Bool) {
            self.home = home
            self.claude = claude
            self.git = git
            self.executable = executable
            self.exists = exists
            self.read = read
            self.systemd = systemd
            self.nodeRunning = nodeRunning
            self.hooksInstalled = hooksInstalled
        }
    }

    /// What this machine has: the node's root and the account's home; `running` asks whether the node answers.
    public static func live(root: URL, home: String, running: @escaping @Sendable () -> Bool) -> Probes {
        Probes(home: home,
               claude: { NodePreflight.resolve(NodePreflight.claudeLink(root: root, accountHome: home)) },
               git: { Platform.Tools.git == Platform.Tools.absentGit ? nil : Platform.Tools.git },
               executable: { NodePreflight.isExecutableFile($0) },
               exists: { FileManager.default.fileExists(atPath: $0) },
               read: { try? String(contentsOfFile: $0, encoding: .utf8) },
               systemd: { Platform.Service.runtimeFolder(uid: getuid()).map { NodeFolders.mode(runtimeFolder: $0) } ?? .noSystemd },
               nodeRunning: running,
               hooksInstalled: {
                   let config = (try? Data(contentsOf: HookInstaller.configURL(for: .claude, home: home)))
                       .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                   return config.map(HookInstaller.isInstalled(in:)) ?? false
               })
    }

    /// The toolchain `scripts/install-node.sh` builds with by default.
    public static let rootToolchain = "/opt/swift-6.4.2"

    public static func checks(_ probes: Probes) -> [Check] {
        let home = probes.home
        var checks: [Check] = []
        let claude = probes.claude()
        checks.append(Check(name: "claude", level: .needed, ok: claude.path != nil,
                            says: claude.path.map { "Claude Code at \($0)" } ?? (claude.why ?? "no claude"),
                            fix: ToolInstall.claudeCodeCommand))
        let git = probes.git()
        checks.append(Check(name: "git", level: .needed, ok: git != nil, says: git.map { "git at \($0)" } ?? "no git in a folder only root can write",
                            fix: "sudo apt-get install -y git"))
        let swift = NodeFolders.join(home, ".local/share/swiftly/bin/swift")
        checks.append(Check(name: "swift", level: .needed, ok: probes.executable(swift),
                            says: probes.executable(swift) ? "swiftly's swift at \(swift)" : "no swift at \(swift) (the unit's PATH takes swiftly's)",
                            fix: """
                                curl -fsSLO https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz && tar zxf swiftly-$(uname -m).tar.gz \
                                && ./swiftly init --quiet-shell-followup && . ~/.local/share/swiftly/env.sh && swiftly install latest
                                """))
        let versions = NodeFolders.join(home, ".nvm/versions/node")
        let node = nodeFound(versions: versions, probes: probes)
        checks.append(Check(name: "node", level: .needed, ok: node != nil,
                            says: node.map { "nvm's node at \($0)" } ?? "no node in \(versions)/v*/bin (the unit's PATH takes nvm's)",
                            fix: "install nvm (https://github.com/nvm-sh/nvm#installing-and-updating), then: nvm install --lts"))

        let current = NodeFolders.join(NodeFolders.defaultPrefix(accountHome: home), "current")
        let installed = probes.exists(current)
        checks.append(Check(name: "a build installed", level: .step, ok: installed,
                            says: installed ? "a build is installed (\(current))" : "no build installed under \(NodeFolders.defaultPrefix(accountHome: home))",
                            fix: "in your VibeSwitcher checkout: /usr/bin/env -i HOME=\(home) PATH=/usr/bin:/bin /bin/bash \"$PWD/scripts/install-node.sh\" COMMIT  "
                                + "(a v2 commit both CI runs passed: `vibeswitcher status` names one once the node runs)"))
        let running = probes.nodeRunning()
        checks.append(Check(name: "the node", level: .step, ok: running, says: running ? "the node is running" : "the node isn't running",
                            fix: "vibeswitcher start"))
        let hooks = probes.hooksInstalled()
        checks.append(Check(name: "hooks", level: .step, ok: hooks,
                            says: hooks ? "VibeSwitcher's hooks are in ~/.claude/settings.json" : "VibeSwitcher's hooks aren't in ~/.claude/settings.json",
                            fix: "vibeswitcher hooks install"))

        let interop = interopOn(probes)
        checks.append(Check(name: "WSL interop", level: .advised, ok: !interop,
                            says: interop ? "WSL interop is on: any process can run Windows programs and reach root (your choice to keep, `start --interop-is-on`; the security document's decision 2 turns it off)"
                                : "WSL interop is off, or this isn't WSL",
                            fix: "sudo nano /etc/wsl.conf  (add [interop] enabled=false and appendWindowsPath=false, [automount] enabled=false), "
                                + "then in PowerShell: wsl --shutdown"))
        let mode = probes.systemd()
        checks.append(Check(name: "systemd", level: .advised, ok: mode == .systemd,
                            says: mode == .systemd ? "systemd runs as pid 1: the node runs as a user unit"
                                : mode == .socketMissing ? "systemd runs, but your user manager's socket is missing"
                                : "pid 1 isn't systemd: the node starts detached (weaker: its pid file any worker can write)",
                            fix: mode == .socketMissing ? "loginctl enable-linger $USER, then log in again"
                                : "sudo nano /etc/wsl.conf  (add [boot] systemd=true), then in PowerShell: wsl --shutdown"))
        let toolchain = probes.executable(NodeFolders.join(rootToolchain, "usr/bin/swift"))
        checks.append(Check(name: "install toolchain", level: .advised, ok: toolchain,
                            says: toolchain ? "the root-owned toolchain at \(rootToolchain)" : "no root-owned toolchain at \(rootToolchain): scripts/install-node.sh builds with it",
                            fix: "the bootstrap path's M3 (docs/superpowers/plans/2026-11-13-v2-bootstrap-path.md): Swift 6.4.2 extracted by root into \(rootToolchain)"))
        let gh = probes.executable("/usr/bin/gh")
        let signedIn = probes.exists(NodeFolders.join(home, ".config/gh/hosts.yml"))
        checks.append(Check(name: "gh", level: .advised, ok: gh && signedIn,
                            says: !gh ? "no gh at /usr/bin/gh: the install fetches and checks CI with it" : signedIn ? "gh at /usr/bin/gh, signed in" : "gh isn't signed in",
                            fix: gh ? "gh auth login" : "sudo apt-get install -y gh && gh auth login"))
        let tailscale = probes.executable("/usr/bin/tailscale")
        checks.append(Check(name: "Tailscale", level: .advised, ok: tailscale,
                            says: tailscale ? "tailscale at /usr/bin/tailscale" : "no tailscale (only `vibeswitcher web --tailnet` needs it)",
                            fix: "https://tailscale.com/download/linux"))
        return checks
    }

    /// nvm's newest-looking `v*/bin/node` under `versions`, or nil.
    static func nodeFound(versions: String, probes: Probes) -> String? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: versions)) ?? []).filter { $0.hasPrefix("v") }.sorted().reversed()
        return names.map { NodeFolders.join(versions, "\($0)/bin/node") }.first(where: probes.executable)
    }

    /// Whether WSL's interop is on: its binfmt entry there and enabled.
    static func interopOn(_ probes: Probes) -> Bool {
        ["/proc/sys/fs/binfmt_misc/WSLInterop", "/proc/sys/fs/binfmt_misc/WSLInterop-late"].contains { path in
            probes.read(path)?.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces) == "enabled"
        }
    }

    /// The report as the command line prints it: each check's mark, name and what it found, then the command to run.
    public static func lines(_ checks: [Check]) -> [String] {
        var out: [String] = []
        for (level, heading) in [(Level.needed, "Needed:"), (.step, "Steps:"), (.advised, "Advised:")] {
            out.append(heading)
            for check in checks where check.level == level {
                out.append("  \(check.ok ? "ok  " : level == .advised ? "note" : "MISS") \(check.name): \(ConfigSeal.inert(check.says, limit: 300))")
                if !check.ok, let fix = check.fix { out.append("       run: \(fix)") }
            }
        }
        let missing = checks.filter { !$0.ok && $0.level != .advised }.count
        out.append(missing == 0 ? "Nothing needed is missing. VibeSwitcher installs nothing: each command above is yours to run."
                   : "\(missing) needed \(missing == 1 ? "thing is" : "things are") missing. VibeSwitcher installs nothing: run each command yourself, then `vibeswitcher doctor` again.")
        return out
    }
}
