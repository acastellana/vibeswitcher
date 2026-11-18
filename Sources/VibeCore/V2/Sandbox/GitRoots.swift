import Foundation

/// A worktree's git folders, read from its files, never by running git in a folder a worker writes (git takes its
/// config and hooks from the folder it runs in): its `.git` file names its own folder, `<common>/worktrees/<slug>`,
/// whose `commondir` names the common folder and whose `gitdir` names the `.git` file again (as `ProjectAllowList`
/// reads them in the host). A `.git` that is a link or a folder, or a file that names a folder outside its
/// repository's `worktrees/`, is refused.
public enum GitRoots {
    /// The most a pointer file may hold.
    static let pointerLimit = 4096

    public struct Roots: Equatable, Sendable {
        /// The repository's common git folder (`<root>/.git`).
        public var common: String
        /// The worktree's own git folder (`<common>/worktrees/<slug>`).
        public var own: String
        /// Its name there.
        public var slug: String
    }

    public static func read(worktree: String) -> Result<Roots, SandboxRefusal> {
        func refuse(_ reason: String) -> Result<Roots, SandboxRefusal> { .failure(SandboxRefusal(value: worktree, reason: reason)) }
        let dotGit = worktree + "/.git"
        guard let named = pointer(dotGit, prefix: "gitdir:", relativeTo: worktree) else {
            return refuse("its .git isn't a worktree's pointer file")
        }
        let worktrees = (named as NSString).deletingLastPathComponent
        guard (worktrees as NSString).lastPathComponent == "worktrees" else {
            return refuse("its .git names \(named), outside a repository's worktrees/")
        }
        let common = (worktrees as NSString).deletingLastPathComponent
        guard let commonNamed = pointer(named + "/commondir", prefix: nil, relativeTo: named), commonNamed == common else {
            return refuse("its git folder \(named) doesn't belong to the repository at \(common)")
        }
        guard let back = pointer(named + "/gitdir", prefix: nil, relativeTo: named),
              back == SandboxPolicy.resolved(dotGit) else {
            return refuse("its git folder \(named) names another worktree")
        }
        return .success(Roots(common: common, own: named, slug: (named as NSString).lastPathComponent))
    }

    /// The path the pointer file at `path` names (its first line, after `prefix` if given), relative to `folder` when
    /// it isn't absolute, its links followed; nil when the file isn't a regular file (a link at `path` isn't followed),
    /// is too big, or names nothing.
    static func pointer(_ path: String, prefix: String?, relativeTo folder: String) -> String? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { Sys.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= off_t(pointerLimit) else { return nil }
        var bytes = [UInt8](repeating: 0, count: pointerLimit)
        let count = Sys.read(fd, &bytes, bytes.count)
        guard count > 0 else { return nil }
        guard var line = String(decoding: bytes[0..<count], as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) else {
            return nil
        }
        if let prefix {
            guard line.hasPrefix(prefix) else { return nil }
            line.removeFirst(prefix.count)
        }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        let spelled = URL(fileURLWithPath: line.hasPrefix("/") ? line : folder + "/" + line).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: spelled) else { return nil }
        return SandboxPolicy.resolved(spelled)
    }

    /// The ref a worktree's HEAD names (`ref: refs/heads/…`), from its own git folder's `HEAD`; nil when HEAD is
    /// detached, a link, or not a ref.
    public static func branch(_ roots: Roots) -> String? {
        let path = roots.own + "/HEAD"
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { Sys.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= off_t(pointerLimit) else { return nil }
        var bytes = [UInt8](repeating: 0, count: pointerLimit)
        let count = Sys.read(fd, &bytes, bytes.count)
        guard count > 0, let line = String(decoding: bytes[0..<count], as: UTF8.self).split(whereSeparator: \.isNewline).first,
              line.hasPrefix("ref: ") else { return nil }
        let ref = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        // A ref's name: no `..`, no empty part, nothing a path could escape by.
        guard ref.hasPrefix("refs/heads/"), !ref.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return nil
        }
        return ref
    }
}
