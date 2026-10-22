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

    /// How often the app sweeps (`sweep`) besides each connection to the session host and each session's end.
    public static let sweepEvery = 600

    /// The app's sweep: the folders of sessions that have ended (`removable`), what pytest keeps of earlier runs in the
    /// live ones' (`leftovers`), and the handover tests' leftovers under `handovers` (`handoverLeftovers`); never
    /// anything a live process holds (`open`, read after the ended sessions' folders go). What was removed. Nothing
    /// when the processes can't be read.
    @discardableResult
    public static func sweep(sessions: [HostSession], in root: URL = root, handovers: URL? = handoverRoot, now: Date = Date(),
                             open: () -> OpenPaths? = OpenPaths.now) -> [URL] {
        guard let held = open() else { return [] }
        var removed = removable(in: root, sessions: sessions, now: now).filter { !held.holds($0) }.filter(remove)
        removed += leftovers(in: root, isHeld: held.holds).filter(remove)
        if let handovers { removed += handoverLeftovers(in: handovers, now: now, isHeld: held.holds).filter(remove) }
        return removed
    }

    private static func remove(_ url: URL) -> Bool { (try? FileManager.default.removeItem(at: url)) != nil }

    /// A session's TMPDIR that takes much, for status's and the witness's low-disk words: every project's, named by the
    /// project and task of the session it belongs to when one is listed.
    public struct Big: Equatable, Sendable {
        public var path: String
        public var bytes: Int64
        /// The project (its folder's name) and the task (its worktree's), when a listed session runs there.
        public var project: String?
        public var task: String?

        /// "the TMPDIR of a session on TGE-ANALYSIS's task oktgmi, 2.6 GB (/private/tmp/vibeswitcher-501/oktgmi-i7pjc5)".
        public var text: String {
            let whose = switch (project, task) {
            case let (project?, task?): "a session on \(project)'s task \(task)"
            case let (project?, nil): "a session in \(project) (not a task's)"
            default: "a session no longer listed"
            }
            return "the TMPDIR of \(whose), \(DiskSpace.text(bytes)) (\(path))"
        }
    }

    /// Over this, a session's TMPDIR is named when disk space is low.
    public static let bigOver: Int64 = 500_000_000

    /// The session folders under `root` over `over`, biggest first, each named by the first of `cwds` (the listed
    /// sessions' folders, every project's) whose sessions it belongs to. Sizes each: slow for a big one.
    public static func big(cwds: [String], in root: URL = root, over: Int64 = bigOver, size: (String) -> Int64 = DiskSpace.size(of:)) -> [Big] {
        guard isPrivate(root) else { return [] }
        let named = Dictionary(Set(cwds).flatMap { cwd in folders(for: cwd, in: root).map { ($0.path, cwd) } }, uniquingKeysWith: min)
        return children(of: root).filter { $0.lastPathComponent.wholeMatch(of: #/[0-9a-z]+-[0-9a-z]+/#) != nil }.compactMap { url in
            let bytes = size(url.path)
            guard bytes > over else { return nil }
            var big = Big(path: url.path, bytes: bytes)
            if var cwd = named[url.path] {
                if let range = cwd.range(of: "/.vibeswitcher/worktrees/") {
                    big.task = String(cwd[range.upperBound...]).split(separator: "/").first.map(String.init)
                    cwd = String(cwd[..<range.lowerBound])
                }
                big.project = URL(fileURLWithPath: cwd).lastPathComponent
            }
            return big
        }.sorted { $0.bytes > $1.bytes }
    }

    /// What a live session's TMPDIR can lose while it runs: pytest keeps its last three runs' basetemp there
    /// (`pytest-of-<user>/pytest-N`), 1.3 GB each for TGE-ANALYSIS's suite, and a worker's held 2.6 GB with 3 GB left on
    /// the disk (2026-10-22). Each `pytest-of-*`'s `pytest-N` but the newest, in any session's folder under `root`, unless
    /// `isHeld` (a live process has a file, its working folder or its program in it). Real folders only, never a link;
    /// nothing when `root` isn't private (`isPrivate`).
    public static func leftovers(in root: URL = root, isHeld: (URL) -> Bool) -> [URL] {
        guard isPrivate(root) else { return [] }
        var found: [URL] = []
        for session in children(of: root) where session.lastPathComponent.wholeMatch(of: #/[0-9a-z]+-[0-9a-z]+/#) != nil {
            for pytest in children(of: session) where pytest.lastPathComponent.hasPrefix("pytest-of-") {
                let runs = children(of: pytest).compactMap { url in
                    url.lastPathComponent.wholeMatch(of: #/pytest-([0-9]+)/#).flatMap { Int($0.1) }.map { (number: $0, url: url) }
                }.sorted { $0.number < $1.number }
                found += runs.dropLast().map(\.url).filter { !isHeld($0) }
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Where the session host's handover tests put their scratch hosts when their TMPDIR is too long for a socket (a
    /// session's is): `vsho-XXXXXXXX` and `vsho-state-XXXXXXXX`. A run that's killed leaves them (6 held 275 MB on
    /// 2026-10-22). Only the user's own VibeSwitcher sweeps them (`handoverRoot` is nil for a scratch one).
    public static var handoverRoot: URL? {
        VibePaths.isAccountRoot(VibePaths.root, accountHome: VibePaths.accountHome) ? URL(fileURLWithPath: "/private/tmp", isDirectory: true) : nil
    }

    /// How long a handover test's folder stays untouched before it's taken as outliving its run: no test runs that
    /// long, and its scratch host (a program in it, so `isHeld`) runs while the test does.
    public static let handoverSettle: TimeInterval = 3600

    /// The handover tests' folders under `tmp` whose run has ended: the user's own (not a link), nothing in them
    /// changed for `handoverSettle`, and nothing in them `isHeld`.
    public static func handoverLeftovers(in tmp: URL, now: Date = Date(), isHeld: (URL) -> Bool) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        return entries.filter { $0.wholeMatch(of: #/vsho-(state-)?[0-9A-F]{8}/#) != nil }.map { tmp.appendingPathComponent($0) }.filter { url in
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) != S_IFLNK else { return false }
            let changed = ([url] + children(of: url, folders: false)).compactMap { url -> Date? in
                var info = stat()
                return lstat(url.path, &info) == 0 ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) : nil
            }.max() ?? now
            return now.timeIntervalSince(changed) >= handoverSettle && !isHeld(url)
        }.sorted { $0.path < $1.path }
    }

    /// The real folders in `folder` (every entry but links, with `folders` false), unsorted.
    private static func children(of folder: URL, folders: Bool = true) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { folder.appendingPathComponent($0) }
            .filter { url in
                var info = stat()
                guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return false }
                return !folders || (info.st_mode & S_IFMT) == S_IFDIR
            }
    }

    private static func prefix(_ cwd: String) -> String { ClaudeScratch.hash((cwd as NSString).standardizingPath) + "-" }

    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}

/// The paths the user's live processes hold: their open files and folders, their working folders and their programs.
/// What a sweep must leave (`SessionTemp.leftovers`, `handoverLeftovers`).
public struct OpenPaths: Sendable {
    /// Each one resolved (as the kernel gives them: /private/tmp, not /tmp).
    public let paths: Set<String>

    public init(paths: Set<String>) { self.paths = paths }

    /// Read now from every process of the user's that can be read; nil when the process list can't be.
    public static func now() -> OpenPaths? {
        guard let pids = ProcessTable.allPids() else { return nil }
        var paths = Set<String>()
        let me = getuid()
        for pid in pids {
            var short = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 1, &short, size) == size, short.pbsi_uid == me else { continue }
            if let cwd = ProcessTable.cwd(pid: pid) { paths.insert(cwd) }
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 { paths.insert(String(cString: buffer)) }
            paths.formUnion(files(of: pid))
        }
        return OpenPaths(paths: paths)
    }

    /// The files and folders `pid` has open.
    static func files(of pid: pid_t) -> [String] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 8)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        return fds.prefix(Int(got) / stride).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            return path.isEmpty ? nil : path
        }
    }

    /// Whether any of them is `url` or in it (by its resolved path: realpath's, as the kernel's, where Foundation's
    /// drops /private).
    public func holds(_ url: URL) -> Bool {
        var folder = url.path
        if let resolved = realpath(folder, nil) {
            folder = String(cString: resolved)
            free(resolved)
        }
        return paths.contains { $0 == folder || $0.hasPrefix(folder + "/") }
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
/// has been back above it (by `margin`, so hovering around the line doesn't tell it each time). Within an episode it's
/// told again when free space drops under a lower band (`bands`, those under the warning), once each, or after `quiet`
/// with it still under the warning. The app keeps it on disk by project (`file`): a relaunch (each install) started it
/// afresh, and free space hovering at 9.9–10.0 GB told the lead three times in a few minutes (2026-10-22).
public struct DiskWatch: Codable, Equatable, Sendable {
    public static let margin = DiskSpace.gigabyte
    public static let bands: [Int64] = [DiskSpace.bytes(5), DiskSpace.bytes(3)]
    public static let quiet: TimeInterval = 6 * 3600
    public private(set) var low = false
    /// The lowest line told in this episode: the warning, or a band under it.
    public private(set) var line: Int64?
    public private(set) var toldAt: Date?

    public init() {}

    /// Whether to tell now.
    public mutating func check(free: Int64?, warning: Int64, now: Date = Date()) -> Bool {
        guard let free else { return false }
        if low {
            if free >= warning + Self.margin {
                self = DiskWatch()
                return false
            }
            guard let under = Self.line(free: free, warning: warning) else { return false }
            if under < (line ?? warning) {
                line = under
            } else if now.timeIntervalSince(toldAt ?? .distantPast) < Self.quiet {
                return false
            }
            toldAt = now
            return true
        }
        guard let under = Self.line(free: free, warning: warning) else { return false }
        low = true
        line = under
        toldAt = now
        return true
    }

    /// The lowest of the warning and the bands under it that `free` is under; nil when it isn't under the warning.
    static func line(free: Int64, warning: Int64) -> Int64? {
        ([warning] + bands.filter { $0 < warning }).filter { free < $0 }.min()
    }

    /// Where the app keeps each project's, by its folder.
    public static var file: URL { VibePaths.root.appendingPathComponent("disk-watch.json") }

    /// The one kept for the project at `root`, if any.
    public static func load(root: String, from url: URL = file) -> DiskWatch? {
        guard let data = try? Data(contentsOf: url), let all = try? JSONDecoder().decode([String: DiskWatch].self, from: data) else { return nil }
        return all[root]
    }

    /// Keeps this as the project's at `root` (a fresh one, never low, is dropped).
    public func save(root: String, to url: URL = file) {
        var all = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: DiskWatch].self, from: $0) } ?? [:]
        all[root] = low ? self : nil
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? VibePaths.writePrivate(data, to: url)
    }
}
