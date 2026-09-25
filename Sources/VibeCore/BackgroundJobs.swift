import Foundation

/// A command a Claude Code session left running in the background (a `run_in_background` shell,
/// a monitor loop…), found in the process tree rather than guessed from the screen.
public struct BackgroundJob: Equatable, Sendable {
    public let pid: Int32
    public let command: String
    public let startedAt: Date
}

public enum BackgroundJobs {
    /// Claude runs each shell command as a direct child `zsh -c "source <shell-snapshot> … && eval '<command>' …"`.
    /// Once a turn has ended, any such child still alive is background work.
    public static func jobs(forAgent agentPid: Int32, in processes: [Int32: ProcInfo],
                            arguments: (ProcInfo) -> [String]) -> [BackgroundJob] {
        processes.values
            .filter { $0.ppid == agentPid && ["zsh", "bash", "sh"].contains($0.comm) }
            .compactMap { process in
                let argv = arguments(process)
                guard argv.contains(where: { $0.contains("/shell-snapshots/") }),
                      let command = command(fromWrapper: argv.joined(separator: " ")) else { return nil }
                return BackgroundJob(pid: process.pid, command: command, startedAt: process.startTime)
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// The user-facing command inside Claude's shell wrapper: the last statement that does real work,
    /// skipping heredoc bodies, setup (`mkdir`, `cd`, `export`), file writes (`cat >> f <<EOF`) and
    /// `echo`s, with output redirections removed.
    static func command(fromWrapper wrapper: String) -> String? {
        guard let start = wrapper.range(of: "eval '") else { return nil }
        var body = String(wrapper[start.upperBound...])
        if let end = body.range(of: "' < /dev/null", options: .backwards) ?? body.range(of: "'", options: .backwards) {
            body = String(body[..<end.lowerBound])
        }
        // Both shell idioms for a quote inside single quotes: '\'' and '"'"'
        body = body.replacingOccurrences(of: "'\\''", with: "'").replacingOccurrences(of: "'\"'\"'", with: "'")
        let statements = withoutHeredocBodies(body)
            .components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: " && ") }
            .flatMap { $0.components(separatedBy: "; ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let trivial = ["mkdir ", "cd ", "export ", "echo ", "printf ", "cat >", "set ", "true", "done", "do ", "then", "fi"]
        // The last real step is usually the slow one (`git add -A && npm run prove`).
        let main = statements.last { statement in !trivial.contains { statement.hasPrefix($0) } } ?? statements.first
        return main.map(stripRedirections).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Removes the lines between `<<EOF` / `<<'EOF'` / `<<-"EOF"` and their terminator, keeping the
    /// command line that opened the heredoc.
    static func withoutHeredocBodies(_ script: String) -> String {
        var output: [String] = []
        var terminator: String?
        for line in script.components(separatedBy: .newlines) {
            if let end = terminator {
                if line.trimmingCharacters(in: .whitespaces) == end { terminator = nil }
                continue
            }
            output.append(line)
            if let match = line.range(of: #"<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?"#, options: .regularExpression) {
                terminator = String(line[match]).trimmingCharacters(in: CharacterSet(charactersIn: "<-'\" "))
            }
        }
        return output.joined(separator: "\n")
    }

    static func stripRedirections(_ statement: String) -> String {
        // `2>&1` first, then file redirections (`> log`, `>> $(date).log`, `>| x`), then heredoc markers.
        statement
            .replacingOccurrences(of: #"\s*\d?>&\d"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\d?>{1,2}\|?\s*(?:\$\([^)]*\)|[^\s;|&$])+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*<<-?\s*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// "npm run prove · 6h" or "5 shells · oldest 7h: until ! ps aux | grep …".
    public static func summary(_ jobs: [BackgroundJob], now: Date = Date()) -> String? {
        guard let oldest = jobs.first else { return nil }
        let age = Durations.short(now.timeIntervalSince(oldest.startedAt))
        let command = ToolActivity.clip(oldest.command, to: 64)
        if jobs.count == 1 { return "\(command) · \(age)" }
        return "\(jobs.count) shells · oldest \(age): \(command)"
    }
}

public enum Durations {
    /// 45s, 12m, 3h 5m, 2d 4h
    public static func short(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return s % 3600 >= 60 ? "\(s / 3600)h \(s % 3600 / 60)m" : "\(s / 3600)h" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}
