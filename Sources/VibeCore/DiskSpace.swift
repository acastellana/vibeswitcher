import Darwin
import Foundation

/// How full a volume is, and how much a folder takes on it.
public enum DiskSpace {
    public static let gigabyte: Int64 = 1_000_000_000

    /// A test run: each test target sets it as its bundle loads (`fakeTheDisk` in its TestSupport.swift), before any
    /// test. No test's outcome may hang on how full the Mac's disk is: twice a test passed on a roomy disk and failed
    /// under 10 GB free (the low-disk line grew status past its bound; the witness's low-disk report reached a lead's
    /// inbox, 2026-10-22). A test that wants a low disk gives its own reading where it's read (`LeadToolset.freeSpace`,
    /// `LeadWitness.Disk`, the app's `LeadController.freeSpace`).
    public struct TestRun: Sendable {
        /// What `free(at:)` reads in the run: roomy, far above any warning.
        public var free: Int64
        /// Told of each read of the volume itself in the run (it's a bug, the test's result hangs on the Mac's disk);
        /// the read gives nil.
        public var readVolume: @Sendable (String) -> Void

        public init(free: Int64, readVolume: @escaping @Sendable (String) -> Void) {
            self.free = free
            self.readVolume = readVolume
        }
    }

    /// Set once, as a test bundle loads; nil in the app.
    public nonisolated(unsafe) static var testRun: TestRun?

    /// The bytes free to you on the volume holding `path` (`volumeFree`); in a test run, its roomy reading.
    public static func free(at path: String) -> Int64? {
        if let testRun { return testRun.free }
        return volumeFree(at: path)
    }

    /// The bytes free to you on the volume holding `path` (or its nearest folder that exists), as `df` counts them;
    /// nil when it can't be read, and in a test run (which is told).
    static func volumeFree(at path: String) -> Int64? {
        if let testRun {
            testRun.readVolume(path)
            return nil
        }
        var path = (path as NSString).standardizingPath
        while !FileManager.default.fileExists(atPath: path), path != "/", !path.isEmpty {
            path = (path as NSString).deletingLastPathComponent
        }
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// What a folder (and everything in it) takes on disk; links aren't followed.
    public static func size(of path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var total: Int64 = 0
        for case let item as URL in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// "6.2 GB", "340 MB".
    public static func text(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / Double(gigabyte)
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        return "\(max(0, bytes / 1_000_000)) MB"
    }

    /// `gigabytes` in bytes.
    static func bytes(_ gigabytes: Double) -> Int64 { Int64(gigabytes * Double(gigabyte)) }
}

/// The temporary folders Claude Code keeps for the sessions it runs in a folder: `/private/tmp/claude-<uid>/<the
/// folder's path, each character that isn't a letter or digit made a dash>`, one subfolder per session (its
/// scratchpad, its background commands' output). They outlive the sessions.
public enum ClaudeScratch {
    public static var root: URL { URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true) }

    /// Claude's longest folder name; a longer one is cut there and given a hash of the whole.
    static let longest = 200

    /// The name Claude gives `folder`'s temporary folder (its `sanitizePath`): within `longest`, the dashed path;
    /// longer, its first `longest` characters, a dash and a hash of the whole path. Two folders whose paths start
    /// the same for that long (a deep project's tasks) still have names of their own.
    public static func name(for folder: String) -> String {
        let name = dashed(folder)
        return name.utf16.count > longest ? String(decoding: name.utf16.prefix(longest), as: UTF16.self) + "-" + hash(folder) : name
    }

    /// Each character that isn't an ASCII letter or digit made a dash, counted as JavaScript does (in UTF-16 units:
    /// a character beyond them is two dashes).
    static func dashed(_ folder: String) -> String {
        let kept = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf16), dash = "-".utf16.first!
        return String(decoding: folder.utf16.map { kept.contains($0) ? $0 : dash }, as: UTF16.self)
    }

    /// Claude's hash for a long name: Java's string hash over the UTF-16 units in 32 bits, its magnitude in base 36.
    static func hash(_ text: String) -> String {
        let value = text.utf16.reduce(Int32(0)) { $0 &* 31 &+ Int32($1) }
        return String(Int64(value).magnitude, radix: 36)
    }

    /// The temporary folders under `root` that belong to sessions run in `folder` exactly (not in a folder whose
    /// name only starts the same), by the path as given and as it resolves (Claude names it by the resolved one).
    public static func folders(for folder: String, in root: URL = root) -> [URL] {
        var paths = [folder]
        if let resolved = realpath(folder, nil) {
            paths.append(String(cString: resolved))
            free(resolved)
        }
        let entries = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        return Set(paths.map(name(for:))).intersection(entries).map { root.appendingPathComponent($0, isDirectory: true) }.filter { url in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }.sorted { $0.path < $1.path }
    }
}

/// The TMPDIR each lead, worker and verifier session starts with (`LeadLaunch.prepare`), one folder per session (0700)
/// under `root`: `<hash of its folder>-<hash of its name>`. SwiftPM leaves empty `TemporaryDirectory.XXXXXX` folders in
/// TMPDIR at every swift build and swift test and never removes them (7 a no-op build, 5 a `swift test --skip-build`;
/// 32,871 had piled up in the user's /var/folders/…/T/ by 2026-10-20), so a session's go with it: cleanup removes its
/// task's (found by the worktree, as the witness counts them), the app an ended session's (`removable`).
public enum SessionTemp {
    /// `/private/tmp/vibeswitcher-<uid>` for the user's own VibeSwitcher; in a scratch one's folder otherwise (a test
    /// run, a bench), which goes with it. Short: a session's sockets (the session host's tests, SwiftPM's) are made
    /// under its TMPDIR, and a socket's path is limited to 104 bytes.
    public static var root: URL { root(vibeRoot: VibePaths.root, accountHome: VibePaths.accountHome) }

    static func root(vibeRoot: URL, accountHome: String) -> URL {
        VibePaths.isAccountRoot(vibeRoot, accountHome: accountHome)
            ? URL(fileURLWithPath: "/private/tmp/vibeswitcher-\(getuid())", isDirectory: true)
            : vibeRoot.appendingPathComponent("tmp", isDirectory: true)
    }

    /// The folder of the session named `name` (its `--name`) started in `cwd`: under the user's root at most 43
    /// characters for uid 501, 50 for a 10-digit one (each hash is at most 6, "zik0zk").
    public static func folder(cwd: String, name: String, in root: URL = root) -> URL {
        root.appendingPathComponent("\(prefix(cwd))\(ClaudeScratch.hash(name))", isDirectory: true)
    }

    /// Makes the folder and `root` private to you (0700), its time now: a session that's about to start in it is fresh
    /// (see `removable`). Nil when it can't be made, or `root` isn't a folder of yours (anyone may make one in /tmp).
    public static func make(cwd: String, name: String, in root: URL = root) -> URL? {
        let folder = folder(cwd: cwd, name: name, in: root)
        // Before anything is made or changed through a link in its place.
        var info = stat()
        if lstat(root.path, &info) == 0, info.st_uid != getuid() || (info.st_mode & S_IFMT) != S_IFDIR { return nil }
        guard (try? VibePaths.ensurePrivate(folder, within: root)) != nil, isPrivate(root), isPrivate(folder) else { return nil }
        utimes(folder.path, nil)
        return folder
    }

    /// A real folder (not a link), yours, 0700: what `make` leaves `root` and each folder as, and what `folders` and
    /// `removable` read only when `root` is. /tmp is anyone's: another account could put a link to one of your folders
    /// in the root's place (it's cleared at each restart), and cleanup or the app would then remove what's there.
    /// What's left is that account swapping the root between this check and the removal.
    static func isPrivate(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_uid == getuid() && (info.st_mode & S_IFMT) == S_IFDIR && info.st_mode & 0o777 == 0o700
    }

    /// The folders of the sessions started in `cwd` (a task's worktree), by the path as given and as it resolves; none
    /// when `root` isn't private (`isPrivate`).
    public static func folders(for cwd: String, in root: URL = root) -> [URL] {
        var paths = [cwd]
        if let resolved = realpath(cwd, nil) {
            paths.append(String(cString: resolved))
            free(resolved)
        }
        let prefixes = Set(paths.map(prefix))
        guard isPrivate(root) else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return entries.filter { name in prefixes.contains { name.hasPrefix($0) } }.map { root.appendingPathComponent($0, isDirectory: true) }
            .filter(isDirectory).sorted { $0.path < $1.path }
    }

    /// How long a folder no live session uses stays after its last change: a session being started in it isn't listed
    /// yet (`make` touches it), and an ended one's last build may still be writing there.
    public static let settle: TimeInterval = 60

    /// The folders under `root` no live session in `sessions` (the session host's whole list) uses, untouched for
    /// `settle`: an ended session's, and any a host that's gone left. Each is a session's TMPDIR: removing it takes
    /// only what SwiftPM and the session's own commands left there. Nothing when `root` isn't private (`isPrivate`).
    public static func removable(in root: URL = root, sessions: [HostSession], now: Date = Date()) -> [URL] {
        guard isPrivate(root) else { return [] }
        let live = Set(sessions.filter(\.isLive).compactMap { session in
            LeadLaunch.name(inCommand: session.command ?? "").map { folder(cwd: session.cwd, name: $0, in: root).lastPathComponent }
        })
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return entries.filter { name in
            guard !live.contains(name), name.wholeMatch(of: #/[0-9a-z]+-[0-9a-z]+/#) != nil else { return false }
            let modified = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path))?[.modificationDate] as? Date
            return modified.map { now.timeIntervalSince($0) >= settle } ?? false
        }.map { root.appendingPathComponent($0, isDirectory: true) }.filter(isDirectory).sorted { $0.path < $1.path }
    }

    private static func prefix(_ cwd: String) -> String { ClaudeScratch.hash((cwd as NSString).standardizingPath) + "-" }

    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}

/// What a project's tasks keep on disk: each task's worktree and its sessions' temporary folders.
public struct TaskFolder: Equatable, Sendable {
    public enum Kind: String, Sendable { case worktree, temporary = "temporary folder", tmpdir = "TMPDIR" }
    public var task: String
    public var kind: Kind
    public var path: String
    public var bytes: Int64
    /// The task is finished (merged, folded or abandoned): cleanup removes it.
    public var finished: Bool

    public init(task: String, kind: Kind, path: String, bytes: Int64, finished: Bool) {
        self.task = task
        self.kind = kind
        self.path = path
        self.bytes = bytes
        self.finished = finished
    }

    /// Every task's folders on the board, biggest first. `sessions`: where its sessions' TMPDIRs are (`SessionTemp`).
    public static func all(root: String, board: LeadBoard, scratch: URL = ClaudeScratch.root, sessions: URL = SessionTemp.root,
                           size: (String) -> Int64 = DiskSpace.size(of:)) -> [TaskFolder] {
        var folders: [TaskFolder] = []
        for task in board.tasks {
            let worktree = Worktrees.path(root: root, slug: task.slug)
            let finished = LeadTeams.isFinished(task)
            if FileManager.default.fileExists(atPath: worktree) {
                folders.append(TaskFolder(task: task.slug, kind: .worktree, path: worktree, bytes: size(worktree), finished: finished))
            }
            for url in ClaudeScratch.folders(for: worktree, in: scratch) {
                folders.append(TaskFolder(task: task.slug, kind: .temporary, path: url.path, bytes: size(url.path), finished: finished))
            }
            for url in SessionTemp.folders(for: worktree, in: sessions) {
                folders.append(TaskFolder(task: task.slug, kind: .tmpdir, path: url.path, bytes: size(url.path), finished: finished))
            }
        }
        return folders.sorted { $0.bytes > $1.bytes }
    }

    /// "fix-the-chat-layout's temporary folder 6.2 GB (finished: cleanup removes it)".
    public var text: String {
        "\(task)'s \(kind.rawValue) \(DiskSpace.text(bytes))" + (finished ? " (finished: cleanup removes it)" : "")
    }
}

/// Low disk space, told once per episode: when free space first drops below the warning, and again only after it
/// has been back above it (by `margin`, so hovering around the line doesn't tell it each time).
public struct DiskWatch: Equatable, Sendable {
    public static let margin = DiskSpace.gigabyte
    public private(set) var low = false

    public init() {}

    /// Whether to tell now.
    public mutating func check(free: Int64?, warning: Int64) -> Bool {
        guard let free else { return false }
        if low {
            if free >= warning + Self.margin { low = false }
            return false
        }
        guard free < warning else { return false }
        low = true
        return true
    }
}
