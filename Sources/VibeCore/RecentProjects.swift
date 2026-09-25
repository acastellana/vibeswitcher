import Foundation

/// Folders you've recently run an agent in, for the "New session" menu.
public enum RecentProjects {
    public struct Candidate: Equatable {
        public let path: String
        public let lastUsed: Date
        public init(path: String, lastUsed: Date) {
            self.path = path
            self.lastUsed = lastUsed
        }
    }

    /// Claude Code keeps per-project transcripts in `~/.claude/projects/<slug>`, where the slug is the
    /// path with every non-alphanumeric character replaced by "-". The folder's mtime is a good
    /// "last used" signal.
    public static func claudeSlug(for path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// Merges candidates from several sources: newest use wins per path, missing folders and
    /// bare home/root are dropped, most recent first.
    public static func rank(_ candidates: [Candidate], home: String = NSHomeDirectory(), limit: Int = 12,
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Candidate] {
        var newest: [String: Date] = [:]
        for candidate in candidates {
            let path = (candidate.path as NSString).standardizingPath
            guard path != home, path != "/", !path.isEmpty else { continue }
            newest[path] = max(newest[path] ?? .distantPast, candidate.lastUsed)
        }
        return newest
            .filter { exists($0.key) }
            .map { Candidate(path: $0.key, lastUsed: $0.value) }
            .sorted { $0.lastUsed != $1.lastUsed ? $0.lastUsed > $1.lastUsed : $0.path < $1.path }
            .prefix(limit)
            .map { $0 }
    }

    /// Paths from `[projects."<path>"]` tables in `~/.codex/config.toml`.
    public static func codexProjects(fromConfig toml: String) -> [String] {
        toml.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[projects.\""), trimmed.hasSuffix("\"]") else { return nil }
            return String(trimmed.dropFirst("[projects.\"".count).dropLast(2))
        }
    }

    /// A command line that starts `command` in `directory`, safe for any folder name.
    public static func shellCommand(cd directory: String, run command: String) -> String {
        "cd \(shellQuote(directory)) && \(command)"
    }

    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Keys under which a custom session name is remembered. The process key covers the session's
/// lifetime; the agent's session id additionally carries it across `--resume` when the id is kept.
public enum SessionKeys {
    public static func keys(pid: Int32, startedAt: Date, sessionId: String?) -> [String] {
        var keys = ["proc:\(pid)-\(Int(startedAt.timeIntervalSince1970))"]
        if let sessionId, !sessionId.isEmpty { keys.append("session:\(sessionId)") }
        return keys
    }
}
