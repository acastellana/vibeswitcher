import Darwin
import Foundation

/// How full a volume is, and how much a folder takes on it.
public enum DiskSpace {
    public static let gigabyte: Int64 = 1_000_000_000

    /// The bytes free to you on the volume holding `path` (or its nearest folder that exists), as `df` counts them;
    /// nil when it can't be read.
    public static func free(at path: String) -> Int64? {
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

/// What a project's tasks keep on disk: each task's worktree and its sessions' temporary folders.
public struct TaskFolder: Equatable, Sendable {
    public enum Kind: String, Sendable { case worktree, temporary = "temporary folder" }
    public var task: String
    public var kind: Kind
    public var path: String
    public var bytes: Int64
    /// The task is finished (merged or abandoned): cleanup removes it.
    public var finished: Bool

    public init(task: String, kind: Kind, path: String, bytes: Int64, finished: Bool) {
        self.task = task
        self.kind = kind
        self.path = path
        self.bytes = bytes
        self.finished = finished
    }

    /// Every task's folders on the board, biggest first.
    public static func all(root: String, board: LeadBoard, scratch: URL = ClaudeScratch.root,
                           size: (String) -> Int64 = DiskSpace.size(of:)) -> [TaskFolder] {
        var folders: [TaskFolder] = []
        for task in board.tasks {
            let worktree = Worktrees.path(root: root, slug: task.slug)
            let finished = task.status == .done || (task.status == .failed && task.worktree == nil)
            if FileManager.default.fileExists(atPath: worktree) {
                folders.append(TaskFolder(task: task.slug, kind: .worktree, path: worktree, bytes: size(worktree), finished: finished))
            }
            for url in ClaudeScratch.folders(for: worktree, in: scratch) {
                folders.append(TaskFolder(task: task.slug, kind: .temporary, path: url.path, bytes: size(url.path), finished: finished))
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
