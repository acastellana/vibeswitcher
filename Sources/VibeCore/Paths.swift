import Foundation

/// Everything VibeSwitcher writes lives under `~/.vibeswitcher`, so it is easy to inspect or delete.
public enum VibePaths {
    /// Looked up at each read (see `root(environment:fallbackHome:)`), so a scratch HOME or VIBESWITCHER_HOME given to
    /// this process (a test run, a debug mode, the hook under an agent started on a scratch HOME) is the one it uses.
    public static var root: URL {
        root(environment: ProcessInfo.processInfo.environment, fallbackHome: NSHomeDirectory())
    }

    /// Where VibeSwitcher keeps its files, first of: `VIBESWITCHER_HOME` (the folder itself), `$HOME/.vibeswitcher`,
    /// `.vibeswitcher` in `fallbackHome`. A variable counts only when it's an absolute path. `NSHomeDirectory()`, the
    /// fallback, follows CFFIXED_USER_HOME and not HOME, so HOME alone used to leave this on the user's own folder
    /// (docs/eval/open-2026-10-19.md, E-30 + R10). Under a normal login HOME is the user's home: the same folder as ever.
    public static func root(environment: [String: String], fallbackHome: String) -> URL {
        if let own = absolute(environment["VIBESWITCHER_HOME"]) { return URL(fileURLWithPath: own, isDirectory: true) }
        return URL(fileURLWithPath: home(environment: environment, fallbackHome: fallbackHome)).appendingPathComponent(".vibeswitcher")
    }

    /// The home folder this process was given: `$HOME` when it's an absolute path, else `NSHomeDirectory()`. Where the
    /// agents' own files are looked for (`~/.claude`, `~/.codex`): Claude Code and Codex follow HOME too.
    public static var home: String {
        home(environment: ProcessInfo.processInfo.environment, fallbackHome: NSHomeDirectory())
    }

    public static func home(environment: [String: String], fallbackHome: String) -> String {
        absolute(environment["HOME"]) ?? fallbackHome
    }

    private static func absolute(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        return path
    }

    /// The account's own home, from the user database: what neither HOME nor CFFIXED_USER_HOME moves.
    public static var accountHome: String {
        getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }

    /// Whether `root` is the account's own `~/.vibeswitcher`, however it's spelled (`..`, a trailing slash, a symlink).
    /// Only that folder: another one under the account's home (a worktree's `.build/scratchhome`) is not.
    public static func isAccountRoot(_ root: URL, accountHome: String) -> Bool {
        let own = URL(fileURLWithPath: accountHome, isDirectory: true).appendingPathComponent(".vibeswitcher")
        return root.standardizedFileURL.path == own.standardizedFileURL.path
            || root.resolvingSymlinksInPath().path == own.resolvingSymlinksInPath().path
    }

    /// Why the test suites won't run with `root` as VibeSwitcher's folder, or nil when they may: tests write there
    /// (logs, state, the lead's files), and on the user's own folder that's their app's data. Each test target asks
    /// this when its bundle loads, before any test (`refuseTheAccountRoot` in its TestSupport.swift).
    public static func testRefusal(root: URL = VibePaths.root, accountHome: String = VibePaths.accountHome) -> String? {
        guard isAccountRoot(root, accountHome: accountHome) else { return nil }
        return "Refusing to run the tests: VibeSwitcher's folder resolves to your own \(root.path), which they would "
            + "write into. Run scripts/test.sh (a scratch HOME, CFFIXED_USER_HOME, VIBESWITCHER_HOME and TMPDIR), or set "
            + "VIBESWITCHER_HOME, or HOME and CFFIXED_USER_HOME, to a scratch folder."
    }
    /// One `<tty>.json` per terminal, written by the hook binary.
    public static var stateDir: URL { root.appendingPathComponent("state") }
    /// One `<yyyy-MM-dd>.json` per day: where the agents' time went (see `ActivityLedger`).
    public static var statsDir: URL { root.appendingPathComponent("stats") }
    public static var binDir: URL { root.appendingPathComponent("bin") }
    /// Stable location referenced from the Claude/Codex hook configs (independent of where the .app lives).
    public static var hookBinary: URL { binDir.appendingPathComponent("vibeswitcher-hook") }
    /// The session host's socket, lock and log (see `HostServer`).
    public static var hostSocket: URL { root.appendingPathComponent("host.sock") }
    public static var hostLock: URL { root.appendingPathComponent("host.lock") }
    public static var hostLog: URL { root.appendingPathComponent("host.log") }
    /// Launch presets (see `LaunchPresets`).
    public static var presetsFile: URL { root.appendingPathComponent("presets.json") }

    /// Creates `~/.vibeswitcher` and its state folder private to you (0700), fixing older installs too.
    public static func ensurePrivateDirectories() {
        let fm = FileManager.default
        for dir in [root, stateDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    public static func stateFile(tty: String) -> URL {
        stateDir.appendingPathComponent("\(tty).json")
    }
}
