import Foundation
import VibeCore

/// A session's folder's git branch as the node reads it for the inspector (`Session.liveValue`'s `branch`; the security
/// review of 2026-11-21): what `GitBranch.current` says, read so that a repository the session wrote can't make the
/// node read much, wait long or hand a page anything but a branch's name.
///
/// - The folder and those above it are looked at for a `.git` with `lstat`: a link there ends the search (no branch).
/// - A `.git` folder's `HEAD`, or a worktree's `.git` file and then its `gitdir`'s `HEAD`, is read with
///   `Platform.Files.readRegular`: no link followed below the folder, a regular file only, at most `mostBytes` (its
///   size checked before a byte is read).
/// - Only a ref-shaped value is a branch: `ref: refs/…` of at most `mostRef` bytes in `[A-Za-z0-9._/-]`, no `..`, no
///   `//`, shown without `refs/heads/`; or a detached HEAD's 40 or 64 hex digits, shown as their first 7. Anything else
///   is no branch.
///
/// Off the engine's queue: `SessionLiveValues` reads on a queue of its own.
enum NodeGitBranch {
    /// The most bytes of a `HEAD` or a `.git` file read.
    static let mostBytes = 512
    /// The longest ref accepted, in bytes.
    static let mostRef = 200
    /// How many folders up the search goes.
    static let mostLevels = 64

    static func current(in directory: String) -> String? {
        var folder = (directory as NSString).standardizingPath
        for _ in 0..<mostLevels {
            let dotGit = (folder as NSString).appendingPathComponent(".git")
            var info = stat()
            if lstat(dotGit, &info) == 0 {
                switch info.st_mode & S_IFMT {
                case S_IFDIR: return head(in: folder, path: [".git", "HEAD"])
                case S_IFREG: return worktree(folder)
                default: return nil
                }
            }
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent.isEmpty { return nil }
            folder = parent
        }
        return nil
    }

    /// A worktree's or submodule's `.git` file: `gitdir: <path>`, relative to the folder holding it; its `HEAD`.
    static func worktree(_ folder: String) -> String? {
        guard case .data(let data) = Platform.Files.readRegular(in: folder, path: [".git"], limit: mostBytes),
              let text = String(data: data, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        let gitDir = path.hasPrefix("/") ? path : (folder as NSString).appendingPathComponent(path)
        return head(in: (gitDir as NSString).standardizingPath, path: ["HEAD"])
    }

    static func head(in root: String, path: [String]) -> String? {
        guard case .data(let data) = Platform.Files.readRegular(in: root, path: path, limit: mostBytes),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return branch(head: text)
    }

    /// The branch a `HEAD`'s text names, or nil when it isn't ref-shaped.
    static func branch(head text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.contains(where: \.isNewline) else { return nil }
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            guard ref.hasPrefix("refs/"), ref.utf8.count <= mostRef, !ref.contains(".."), !ref.contains("//"), !ref.hasSuffix("/"),
                  ref.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._/-".unicodeScalars.contains($0) })
            else { return nil }
            let heads = "refs/heads/"
            let name = ref.hasPrefix(heads) ? String(ref.dropFirst(heads.count)) : ref.split(separator: "/").last.map(String.init) ?? ""
            return name.isEmpty ? nil : name
        }
        guard line.count == 40 || line.count == 64, line.allSatisfy(\.isHexDigit) else { return nil }
        return String(line.prefix(7))
    }
}
