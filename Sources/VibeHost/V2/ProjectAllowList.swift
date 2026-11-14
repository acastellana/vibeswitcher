import Foundation
import VibeCore

/// The project allow-list (the stage 2 plan's Task 10d, S2-D11; the security architecture document's S11, threat T25):
/// in the user's host on Linux, a `spawn` whose working folder isn't inside an allowed repository is refused, saying
/// why, whoever asks (the app included). The list is `~/.vibeswitcher/v2/projects` (`place`), one absolute path a line,
/// written by the user; blank lines and lines starting with `#` are skipped, and so is a line that isn't an absolute
/// path or names nothing there. It is read again at each spawn, so an edit counts at once; a list that is missing (or
/// isn't a regular file) refuses every spawn and says where it goes.
///
/// A folder is inside an allowed repository when, both resolved (`realpath`), it is the repository's folder or below
/// it, or it is (or is below) one of the repository's worktrees. A worktree is found by reading files, never by running
/// git in a folder a worker controls: the folder's `.git` file names its `gitdir:`, a folder directly under the allowed
/// repository's `.git/worktrees`; that folder's `commondir` names the allowed repository's `.git`; and its `gitdir`
/// names the folder's own `.git` back. A `.git` file alone, naming a real worktree's folder that points elsewhere, is
/// refused. Each file is opened without waiting (`O_NONBLOCK`: a FIFO put there can't stall the host's queue) and never
/// as a controlling terminal (`O_NOCTTY`), must be a regular file, and is read up to a limit.
///
/// `HostServer.Config.projectAllowList` is nil by default: the Mac's, and every scratch host's, spawns go anywhere, as
/// always. Only a `--node` host on Linux has a list (`place`). The list goes when the user marks stage 6 passed.
///
/// *Doesn't promise* (a guard rail, written down as one): the file is the user's to edit, so a worker can add a line;
/// a worker can write both halves of the worktree check (an entry in the allowed repository's shared `.git/worktrees`
/// and a `.git` file in any folder), and the pair passes (`ProjectAllowListTests.aForgedWorktreePairPassesAsKnown`);
/// a repository cloned inside an allowed one is inside it; a folder swapped for a link between the check and the
/// session's start is followed; and a session can run a scratch host with no list (S11 item 24).
public enum ProjectAllowList {
    /// Where the node's list is, under the account's own home.
    public static let nodeListFile = ".vibeswitcher/v2/projects"
    /// The most the list is read to, and a worktree's pointer files.
    static let listLimit = 64 * 1024
    static let pointerLimit = 4 * 1024

    /// The list of a host started with `arguments` (Linux): the account's own `~/.vibeswitcher/v2/projects` for the
    /// node's host (`--node`, `accountHome` from the user database). Nil otherwise (every scratch host), and on the Mac.
    public static func place(arguments: [String], accountHome: String?) -> URL? {
        guard !Platform.CodeIdentity.isAvailable, arguments.contains(HostImages.nodeFlag), let accountHome else { return nil }
        return URL(fileURLWithPath: accountHome, isDirectory: true).appendingPathComponent(nodeListFile)
    }

    /// Why a session can't start in `cwd` under the list at `list`, or nil: it may. Nil `list`: no list, any folder.
    public static func refusal(_ cwd: String, list: URL?) -> String? {
        guard let list else { return nil }
        guard let text = regularContents(list.path, limit: listLimit, followLink: true).map({ String(decoding: $0, as: UTF8.self) }) else {
            return "There is no project allow-list at \(list.path): the user writes each repository this host may start sessions in there, "
                + "one absolute path a line."
        }
        let allowed = repositories(in: text)
        guard cwd.hasPrefix("/"), let folder = HandoverTarget.realPath(cwd) else {
            return "\(cwd) isn't a folder this host can find, so it isn't inside a repository on the project allow-list (\(list.path))."
        }
        if allowed.contains(where: { folder == $0 || HandoverTarget.isInside(folder, $0) || isWorktree(holding: folder, of: $0) }) { return nil }
        return "\(cwd) isn't inside a repository on the project allow-list (\(list.path), \(allowed.count) named): "
            + "the user adds a repository there, one absolute path a line."
    }

    /// The repositories `text` names, each resolved: absolute paths, one a line, blank lines and `#` lines skipped, and
    /// a line naming nothing there.
    static func repositories(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let path = line.trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else { return nil }
            return HandoverTarget.realPath(path)
        }
    }

    /// Whether `folder` (resolved) is, or is below, a worktree of the repository at `repository` (resolved): from
    /// `folder` up to `/`, a folder whose `.git` is a regular file whose pair checks out (`pointsBack`).
    static func isWorktree(holding folder: String, of repository: String) -> Bool {
        var info = stat()
        let gitFolder = repository + "/.git"
        guard lstat(gitFolder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        var candidate = folder
        while true {
            let dotGit = (candidate == "/" ? "" : candidate) + "/.git"
            if lstat(dotGit, &info) == 0, info.st_mode & S_IFMT == S_IFREG, pointsBack(dotGit, commonFolder: gitFolder) { return true }
            guard candidate != "/", !candidate.isEmpty else { return false }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
    }

    /// Whether the `.git` file at `dotGit` names a folder directly under `commonFolder/worktrees` whose `commondir` is
    /// `commonFolder` and whose `gitdir` is `dotGit` again.
    static func pointsBack(_ dotGit: String, commonFolder: String) -> Bool {
        let holder = (dotGit as NSString).deletingLastPathComponent
        guard let named = pointer(dotGit, prefix: "gitdir:", relativeTo: holder),
              (named as NSString).deletingLastPathComponent == commonFolder + "/worktrees",
              pointer(named + "/commondir", prefix: nil, relativeTo: named) == commonFolder,
              let back = pointer(named + "/gitdir", prefix: nil, relativeTo: named) else { return false }
        return back == dotGit
    }

    /// The path the pointer file at `path` names (its first line, after `prefix` if given), relative to `folder` when
    /// it isn't absolute, resolved; nil when the file isn't a regular file (a link isn't followed), is too big or names
    /// nothing there.
    static func pointer(_ path: String, prefix: String?, relativeTo folder: String) -> String? {
        guard let data = regularContents(path, limit: pointerLimit, followLink: false) else { return nil }
        guard var line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) else { return nil }
        if let prefix {
            guard line.hasPrefix(prefix) else { return nil }
            line.removeFirst(prefix.count)
        }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return HandoverTarget.realPath(line.hasPrefix("/") ? line : folder + "/" + line)
    }

    /// A regular file's whole contents, at most `limit` bytes, opened without waiting (a FIFO is refused, not waited
    /// on) and never as a controlling terminal (`O_NOCTTY`: the Linux host leads a session that has none, and a list
    /// linked to a terminal nobody holds would otherwise become the host's); nil when it isn't a regular file, can't be
    /// read or is bigger. `followLink: false`: a link at `path` is refused.
    static func regularContents(_ path: String, limit: Int, followLink: Bool) -> Data? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC | (followLink ? 0 : O_NOFOLLOW))
        guard fd >= 0 else { return nil }
        defer { Sys.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= Int64(limit) else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
            if data.count > limit { return nil }
        }
    }
}
