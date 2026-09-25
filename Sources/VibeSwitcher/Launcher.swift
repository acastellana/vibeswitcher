import AppKit
import Foundation
import VibeCore

/// Starts a new Claude Code / Codex session in a new Terminal window, and knows which folders you've
/// recently worked in.
enum Launcher {
    /// Recent project folders from what VibeSwitcher has seen, Claude Code's project list (ranked by
    /// transcript activity) and Codex's trusted projects. Reads a few files: call off the main thread.
    static func recentProjects(observed: [String: Date]) -> [RecentProjects.Candidate] {
        let home = NSHomeDirectory()
        var candidates = observed.map { RecentProjects.Candidate(path: $0.key, lastUsed: $0.value) }

        let claudeConfig = URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: claudeConfig),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let projects = json["projects"] as? [String: Any] {
            let transcripts = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
            for path in projects.keys {
                let folder = transcripts.appendingPathComponent(RecentProjects.claudeSlug(for: path))
                let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                candidates.append(.init(path: path, lastUsed: modified))
            }
        }

        let codexConfig = URL(fileURLWithPath: home).appendingPathComponent(".codex/config.toml")
        if let toml = try? String(contentsOf: codexConfig, encoding: .utf8) {
            candidates += RecentProjects.codexProjects(fromConfig: toml).map { .init(path: $0, lastUsed: .distantPast) }
        }
        return RecentProjects.rank(candidates, home: home)
    }

    /// Opens a new Terminal window in `directory` running `command`, and brings it to the front.
    static func launch(command: String, in directory: String) {
        let line = RecentProjects.shellCommand(cd: directory, run: command)
        let escaped = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = TerminalBridge.runAppleScript("tell application \"Terminal\" to do script \"\(escaped)\"")
            if result.status != 0 { NSLog("VibeSwitcher: launch failed: \(result.error)") }
            if let terminal = TerminalBridge.app { _ = HostApp.bringToFrontAndWait(terminal) }
        }
    }

    /// Asks for a folder, starting in the most recent project's parent.
    static func chooseFolder(startingAt directory: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Session Here"
        if let directory { panel.directoryURL = URL(fileURLWithPath: directory) }
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// Custom session names, persisted in UserDefaults under every key of the session (see `SessionKeys`).
final class NameStore {
    private let defaultsKey = "customNames"
    private var names: [String: String]

    init() {
        names = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    func name(for keys: [String]) -> String? {
        keys.lazy.compactMap { self.names[$0] }.first
    }

    func set(_ name: String?, for keys: [String]) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        for key in keys { names[key] = (trimmed?.isEmpty == false) ? trimmed : nil }
        save()
    }

    /// Process keys die with their process; session-id keys are kept so `--resume` finds the name.
    func prune(liveKeys: Set<String>) {
        let stale = names.keys.filter { $0.hasPrefix("proc:") && !liveKeys.contains($0) }
        guard !stale.isEmpty else { return }
        stale.forEach { names[$0] = nil }
        save()
    }

    private func save() {
        UserDefaults.standard.set(names, forKey: defaultsKey)
    }
}
