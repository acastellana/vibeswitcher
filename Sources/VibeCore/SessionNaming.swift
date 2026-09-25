import Foundation

/// How a session is labelled: a project name you recognise at a glance, plus what it is working on.
public enum SessionNaming {
    /// The project a session belongs to: the git repository containing the directory the agent was
    /// started in (so `cd`-ing into subfolders doesn't rename it), else that directory itself.
    public static func project(forLaunchDirectory directory: String, home: String = NSHomeDirectory(),
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        name(forProjectRoot: projectRoot(forLaunchDirectory: directory, home: home, fileExists: fileExists), home: home)
    }

    /// The git repository root containing `directory`, else `directory` itself.
    public static func projectRoot(forLaunchDirectory directory: String, home: String = NSHomeDirectory(),
                                   fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let standardized = (directory as NSString).standardizingPath
        var current = standardized
        while current != "/", current != home, !current.isEmpty {
            if fileExists((current as NSString).appendingPathComponent(".git")) { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return standardized
    }

    public static func name(forProjectRoot root: String, home: String = NSHomeDirectory()) -> String {
        root == home ? "~ (home)" : (root as NSString).lastPathComponent
    }

    static let genericTitles: Set<String> = ["terminal", "claude", "claude code", "codex", "zsh", "-zsh", "bash", "-bash", "node"]

    /// What the session is doing, from the terminal tab title (Claude writes an AI summary there;
    /// Codex appends " | <project>"). Falls back to the session's first prompt. Nil when nothing useful.
    public static func task(fromTitle title: String?, project: String, firstPrompt: String?) -> String? {
        var text = (title ?? "").trimmingCharacters(in: .whitespaces)
        // Codex: "Explore the billing API | payments"
        if let bar = text.range(of: " | ", options: .backwards) {
            let suffix = text[bar.upperBound...].trimmingCharacters(in: .whitespaces)
            if suffix.caseInsensitiveCompare(project) == .orderedSame { text = String(text[..<bar.lowerBound]) }
        }
        let lowered = text.lowercased()
        if !text.isEmpty, !genericTitles.contains(lowered), lowered != project.lowercased() {
            return text
        }
        guard let prompt = firstPrompt?.trimmingCharacters(in: .whitespaces), !prompt.isEmpty else { return nil }
        return prompt.count > 60 ? String(prompt.prefix(60)) + "…" : prompt
    }

    /// Prompts that are not something the user typed: background-task notices and other injected
    /// system messages arrive through UserPromptSubmit as XML-ish blocks.
    public static func isSystemPrompt(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") else { return false }
        let tag = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        return !tag.isEmpty && tag.allSatisfy { $0.isLetter || $0 == "-" || $0 == "_" }
    }
}
