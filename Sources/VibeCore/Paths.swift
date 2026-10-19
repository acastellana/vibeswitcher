import Foundation

/// Everything VibeSwitcher writes lives under `~/.vibeswitcher`, so it is easy to inspect or delete.
public enum VibePaths {
    /// Looked up at each read (see `root(environment:fallbackHome:)`), so a scratch HOME or VIBESWITCHER_HOME given to
    /// this process (a test run, a debug mode, the hook under an agent started on a scratch HOME) is the one it uses.
    public static var root: URL {
        root(environment: ProcessInfo.processInfo.environment, fallbackHome: NSHomeDirectory())
    }

    /// Where VibeSwitcher keeps its files, first of: `VIBESWITCHER_HOME` (the folder itself), `.vibeswitcher` in the
    /// home (`home(environment:fallbackHome:)`). A variable counts only when it's an absolute path. `NSHomeDirectory()`
    /// follows CFFIXED_USER_HOME and not HOME, so HOME alone used to leave this on the user's own folder
    /// (docs/eval/open-2026-10-19.md, E-30 + R10). Under a normal login HOME is the user's home: the same folder as ever.
    public static func root(environment: [String: String], fallbackHome: String) -> URL {
        if let own = absolute(environment["VIBESWITCHER_HOME"]) { return URL(fileURLWithPath: own, isDirectory: true) }
        return URL(fileURLWithPath: home(environment: environment, fallbackHome: fallbackHome)).appendingPathComponent(".vibeswitcher")
    }

    /// The home folder this process was given: where the agents' own files are looked for (`~/.claude`, `~/.codex`),
    /// Claude Code and Codex following HOME too.
    public static var home: String {
        home(environment: ProcessInfo.processInfo.environment, fallbackHome: NSHomeDirectory())
    }

    /// First of: CFFIXED_USER_HOME, `$HOME`, `fallbackHome` (`NSHomeDirectory()`). CFFIXED_USER_HOME is the one way to
    /// move `NSHomeDirectory()`, so when it's set it was set on purpose, and comes before HOME: the debug modes and the
    /// chat benches run on a scratch home given by CFFIXED_USER_HOME alone, with HOME still the user's.
    public static func home(environment: [String: String], fallbackHome: String) -> String {
        absolute(environment["CFFIXED_USER_HOME"]) ?? absolute(environment["HOME"]) ?? fallbackHome
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

    /// Creates `~/.vibeswitcher` and its state folder private to you (0700), fixing older installs too. `root` is
    /// VibeSwitcher's folder (tests give a scratch one).
    public static func ensurePrivateDirectories(root: URL = VibePaths.root) {
        for dir in [root, root.appendingPathComponent("state")] { try? ensurePrivate(dir) }
    }

    // MARK: Private files

    /// Creates `dir` private to you (0700), with the folders above it it had to create, and makes it 0700 when it was
    /// there already (an older 0755 one). With `top`, only folders under `top` are changed, and `top` itself: the
    /// vault's way (`LeadVault.ensurePrivate`). Every folder VibeSwitcher makes under `~/.vibeswitcher` or a project's
    /// `.vibeswitcher/` is made here (docs/eval/open-2026-10-19.md, F-F1 + F-L6; `PrivateWriteLintTests`).
    public static func ensurePrivate(_ dir: URL, within top: URL? = nil) throws {
        let fm = FileManager.default
        var created: [URL] = []
        var current = dir
        while current.path != "/", !fm.fileExists(atPath: current.path) {
            created.append(current)
            current = current.deletingLastPathComponent()
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let changed = top.map { top in created.filter { $0.path.hasPrefix(top.path) } + [top] } ?? created + [dir]
        for directory in changed { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    }

    /// Writes a file only you can read (0600), atomically. Every file VibeSwitcher writes under `~/.vibeswitcher` or a
    /// project's `.vibeswitcher/` is written here.
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

    public static func stateFile(tty: String) -> URL {
        stateDir.appendingPathComponent("\(tty).json")
    }
}

/// The one-time repair of what older versions wrote with default modes (0644 files, 0755 folders): in `~/.vibeswitcher`
/// at the app's launch (`atLaunch`), in a project's `.vibeswitcher/` the first time this version writes there
/// (`BoardStore`'s folder; the app only learns its leads' projects once the host answers). Once each: a marker file
/// says it's done, and the repair is logged once, when it changed something (docs/eval/open-2026-10-19.md, F-F1 + F-L6).
public enum PrivateRepair {
    /// What a repair did: paths made private, launch files removed, and stale ones kept because a live session names them.
    public struct Outcome: Equatable, Sendable {
        public var madePrivate: [String] = []
        public var removed: [String] = []
        public var keptLive: [String] = []
        public var isEmpty: Bool { madePrivate.isEmpty && removed.isEmpty && keptLive.isEmpty }
    }

    /// The marker a repaired folder keeps.
    public static let marker = ".private-repair-1"
    /// A launch file this much older than now that no live session names is removed.
    public static let staleAfter: TimeInterval = 24 * 3600

    /// Left as they are in `~/.vibeswitcher`: the session host's files and the vault (the host keeps its own 0600
    /// rules), the signing setup's keychain folder, and the hook binary's folder (a program, to stay runnable).
    public static let skippedAtRoot: Set<String> = ["lead", "host", "host.sock", "host.lock", "host.log", "signing", "bin"]
    /// Left as they are in a project's `.vibeswitcher/`: the workers' git worktrees (the project's own code and modes).
    public static let skippedInProject: Set<String> = ["worktrees"]

    /// `~/.vibeswitcher`, once, off the main thread: the app's one call at launch.
    public static func atLaunch() {
        DispatchQueue.global(qos: .utility).async {
            once(VibePaths.root, skipping: skippedAtRoot, cleaningRun: false)
        }
    }

    /// A project's `.vibeswitcher/` (`folder`), once per process and once ever (its marker); with its old launch files.
    public static func project(_ folder: String) {
        lock.lock()
        let first = done.insert(folder).inserted
        lock.unlock()
        guard first else { return }
        once(URL(fileURLWithPath: folder, isDirectory: true), skipping: skippedInProject, cleaningRun: true)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var done: Set<String> = []

    private static func once(_ folder: URL, skipping: Set<String>, cleaningRun: Bool) {
        let mark = folder.appendingPathComponent(marker)
        guard !FileManager.default.fileExists(atPath: mark.path), FileManager.default.fileExists(atPath: folder.path) else { return }
        let outcome = repair(folder, skipping: skipping, cleaningRun: cleaningRun)
        if !outcome.isEmpty {
            Breadcrumbs.shared.note("privacy: \(folder.path): \(outcome.madePrivate.count) made private (0600 files, 0700 folders), "
                + "\(outcome.removed.count) old launch file(s) removed from run/, \(outcome.keptLive.count) kept: a live session names them")
        }
        // One a live session still names is looked at again next time, so the folder isn't marked done yet.
        if outcome.keptLive.isEmpty { try? VibePaths.writePrivate(Data(), to: mark) }
    }

    /// Makes everything under `folder` private: folders 0700, files without group or other access (0644 → 0600; a
    /// program keeps running, 0755 → 0700). Symbolic links aren't followed, and the top-level names in `skipping` are
    /// left alone. With `cleaningRun`, the entries of `run/` (the old launch folders, one per role) last changed over
    /// `staleAfter` before `now` are removed, unless a live process's arguments name them (`liveArguments`; when the
    /// processes can't be listed, none is removed); its
    /// `.lock` files are kept and only made private: another process may be about to flock one, and a lock
    /// unlinked under it would let two holders in. Changes nothing the second time.
    @discardableResult
    public static func repair(_ folder: URL, skipping: Set<String> = [], cleaningRun: Bool = false, now: Date = Date(),
                              liveArguments: () -> [String]? = PrivateRepair.liveArguments) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        if cleaningRun { clean(folder.appendingPathComponent("run"), now: now, liveArguments: liveArguments, into: &outcome) }
        func visit(_ url: URL, top: Bool) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { return }
            let mode = info.st_mode & 0o7777
            let wanted: mode_t = kind == S_IFDIR ? 0o700 : mode & 0o700
            if mode != wanted, chmod(url.path, wanted) == 0 { outcome.madePrivate.append(url.path) }
            guard kind == S_IFDIR else { return }
            for name in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] where !(top && skipping.contains(name)) {
                visit(url.appendingPathComponent(name), top: false)
            }
        }
        visit(folder, top: true)
        return outcome
    }

    private static func clean(_ run: URL, now: Date, liveArguments: () -> [String]?, into outcome: inout Outcome) {
        let fm = FileManager.default
        var live: [String]??
        for name in ((try? fm.contentsOfDirectory(atPath: run.path)) ?? []).sorted() where !name.hasSuffix(".lock") {
            let entry = run.appendingPathComponent(name)
            guard let changed = newest(entry), now.timeIntervalSince(changed) > staleAfter else { continue }
            if live == nil { live = liveArguments() }
            let named = ".vibeswitcher/run/\(name)"
            guard let arguments = live! else {
                outcome.keptLive.append(entry.path)
                continue
            }
            if arguments.contains(where: { $0.contains(named + "/") || $0.hasSuffix(named) }) {
                outcome.keptLive.append(entry.path)
            } else if (try? fm.removeItem(at: entry)) != nil {
                outcome.removed.append(entry.path)
            }
        }
    }

    /// When `url` or anything in it last changed; nil when it can't be read.
    private static func newest(_ url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        var latest = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        if info.st_mode & S_IFMT == S_IFDIR {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
                if let inner = newest(url.appendingPathComponent(name)), inner > latest { latest = inner }
            }
        }
        return latest
    }

    /// Every argument of every process this user can read: a session started from a launch folder names its files.
    /// Nil when the processes can't be listed.
    public static func liveArguments() -> [String]? {
        ProcessTable.allPids().map { $0.flatMap { ProcessTable.readArguments(pid: $0) } }
    }
}
