import Foundation

/// The checked-out branch of the repository holding a folder, read from `.git/HEAD` (no git process).
public enum GitBranch {
    /// "main"; a 7-character hash for a detached HEAD; nil outside a repository.
    public static func current(in directory: String) -> String? {
        let fileManager = FileManager.default
        var folder = (directory as NSString).standardizingPath
        while true {
            let dotGit = URL(fileURLWithPath: folder).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDir = isDirectory.boolValue ? dotGit : linkedGitDir(dotGit, in: URL(fileURLWithPath: folder))
                return gitDir.flatMap { branch(head: $0.appendingPathComponent("HEAD")) }
            }
            // "/" is its own parent here ("/" + ".." would never end).
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent.isEmpty { return nil }
            folder = parent
        }
    }

    /// A worktree's or submodule's `.git` file: `gitdir: <path>`, relative to the folder holding it.
    private static func linkedGitDir(_ file: URL, in folder: URL) -> URL? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path).standardizedFileURL
    }

    private static func branch(head: URL) -> String? {
        guard let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let heads = "refs/heads/"
            return ref.hasPrefix(heads) ? String(ref.dropFirst(heads.count)) : ref.split(separator: "/").last.map(String.init)
        }
        guard line.count >= 7, line.allSatisfy(\.isHexDigit) else { return nil }
        return String(line.prefix(7))
    }
}
