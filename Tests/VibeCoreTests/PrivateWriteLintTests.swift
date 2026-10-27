import Foundation
import Testing

/// Files under `~/.vibeswitcher` and a project's `.vibeswitcher/` are written with `VibePaths.writePrivate` (0600) in
/// folders made with `VibePaths.ensurePrivate` (0700). A raw `.write(to:`, `createFile(` or `createDirectory(` takes
/// the umask's 0644/0755 (docs/eval/open-2026-10-19.md, F-F1 + F-L6: board.json, the focus and sidebar logs, old
/// launch prompts, all readable by another account in staff). Every raw call in Sources is counted here, by file, with
/// why it may stay raw; a new one fails until it goes through the helper or is added with its reason.
struct PrivateWriteLintTests {
    /// Raw calls per file, and why.
    static let allowed: [String: (count: Int, why: String)] = [
        "Sources/VibeCore/Paths.swift": (2, "the helper itself (ensurePrivate's createDirectory, writePrivate's createFile)"),
        "Sources/VibeSwitcher/HangWatchdog.swift": (2, "~/.vibeswitcher/debug hang reports: the user's own area, left for their word (R9); its folder is 0700"),
        // In VibeSwitcher's folders, already private or under a 0700 folder; outside this change's files.
        "Sources/VibeCore/DebugLog.swift": (2, "debug/app.log: its folder is made 0700 and the file 0600 by its own attributes"),
        "Sources/VibeCore/LeadToolset.swift": (1, "the vault's check logs, in the vault's 0700 folder (vault.ensurePrivate)"),
        "Sources/VibeCore/Steer.swift": (1, "the steer folder, 0700 attributes"),
        "Sources/VibeCore/TeamSummaries.swift": (1, "its folder, 0700 attributes"),
        "Sources/VibeCore/TranscriptReader.swift": (2, "converted transcripts in a 0700 folder"),
        "Sources/VibeCore/Worktrees.swift": (9, "merge and revert scratch and check logs in the vault's 0700 folders; worktrees and hash copies are git checkouts"),
        "Sources/VibeHost/VaultStorage.swift": (1, "the host's vault: its own 0600 rules"),
        "Sources/VibeHost/HostLog.swift": (1, "the host's log: its own 0600 rules"),
        "Sources/vibeswitcher-host/main.swift": (1, "the host's launchers folder, 0700 attributes"),
        "Sources/VibeSwitcher/PhoneAccess.swift": (3, "remote/: its own 0600 writer and folder"),
        "Sources/VibeSwitcher/MainWindow/Chat/ComposerView.swift": (2, "attachments: 0700 folder, 0600 files by attributes"),
        "Sources/VibeCore/Attention.swift": (2, "~/.vibeswitcher state: repaired at launch (PrivateRepair); to move to the helper"),
        "Sources/VibeCore/ComposerOutbox.swift": (2, "~/.vibeswitcher/outbox.json: repaired at launch (PrivateRepair); to move to the helper"),
        "Sources/VibeCore/HookState.swift": (1, "the hook's state/<tty>.json in the 0700 state folder"),
        "Sources/VibeCore/LaunchPresets.swift": (2, "presets.json and its backup in ~/.vibeswitcher (0700): to move to the helper"),
        "Sources/VibeSwitcher/AppStatus.swift": (1, "app-status.json in ~/.vibeswitcher (0700): to move to the helper"),
        "Sources/VibeSwitcher/SessionStore.swift": (1, "the state folder, made 0700 by ensurePrivateDirectories first"),
        // Not VibeSwitcher's own files.
        "Sources/VibeCore/LeadBoard.swift": (2, ".git/info/exclude: git's file"),
        "Sources/VibeCore/LeadRecords.swift": (2, "records_dir: the repository's own committed files, with its usual modes"),
        "Sources/VibeCore/HookInstaller.swift": (2, "the agents' settings (~/.claude, ~/.codex): theirs"),
        "Sources/VibeCore/ProjectCreation.swift": (3, "a new project the user makes, with its usual modes"),
        "Sources/VibeCore/FolderRepository.swift": (3, "a folder the user chose for a lead: its .gitignore, and git's .git/info/exclude, with their usual modes"),
        "Sources/VibeSwitcher/AppDelegate.swift": (4, "the hook binary (bin/, a program: 0755) and snapshots to paths the user gives"),
        "Sources/VibeSwitcher/Snapshot.swift": (1, "a snapshot to a path the user gives"),
        "Sources/VibeSwitcher/MainWindow/MainWindowController.swift": (1, "a chat export to where the user saves it"),
        "Sources/VibeSwitcher/MainWindow/Chat/ToolViews.swift": (1, "an image to where the user saves it"),
        "Sources/VibeSwitcher/IdleBench.swift": (2, "a bench's scratch home"),
        "Sources/VibeSwitcher/UIBench.swift": (6, "a bench's scratch home (the soak's worker script, worktrees, transcripts and workers' stop files too)"),
        "Sources/VibeSwitcher/MainWindow/Lead/BoardBench.swift": (2, "a bench's scratch home"),
        "Sources/VibeSwitcher/MainWindow/Lead/TeamChurnBench.swift": (6, "a bench's scratch home"),
        "Sources/VibeSwitcher/PowerBench.swift": (4, "a bench's scratch home"),
        "Sources/VibeSwitcher/Sandbox.swift": (6, "the sandbox's state folder and scratch home (scripts/sandbox-app.sh), and its shots in the worktree's .build"),
    ]

    static let raw = try! Regex(#"\.write\(to(File)?:|createFile\(|createDirectory\("#)

    /// Raw calls by file, in `code` (comments are left out).
    static func rawCalls(in code: [(path: String, lines: [String])]) -> [String: Int] {
        var found: [String: Int] = [:]
        for file in code {
            let count = file.lines.reduce(0) { $0 + $1.matches(of: raw).count }
            if count > 0 { found[file.path] = count }
        }
        return found
    }

    @Test func everyRawWriteIsOnTheList() {
        let found = Self.rawCalls(in: KeychainLintTests.code(in: "Sources"))
        for (path, count) in found.sorted(by: { $0.key < $1.key }) {
            let allowed = Self.allowed[path]?.count ?? 0
            #expect(count <= allowed, "\(path): \(count) raw .write(to:/createFile(/createDirectory( call(s), \(allowed) allowed. Under ~/.vibeswitcher or .vibeswitcher/, use VibePaths.writePrivate and VibePaths.ensurePrivate; anywhere else, add it to PrivateWriteLintTests.allowed with why")
        }
        // A list that says more than there is hides the next one: kept exact.
        for (path, entry) in Self.allowed {
            #expect(found[path] == entry.count, "\(path): allowed \(entry.count), found \(found[path] ?? 0); update the list")
        }
    }

    /// The writers this change moved onto the helper have no raw call left.
    @Test func theMovedWritersUseTheHelper() {
        let found = Self.rawCalls(in: KeychainLintTests.code(in: "Sources"))
        for path in ["Sources/VibeSwitcher/FocusLog.swift", "Sources/VibeSwitcher/Sidebar.swift", "Sources/VibeCore/LeadWorkflow.swift",
                     "Sources/VibeCore/LeadVault.swift", "Sources/VibeCore/LeadLaunch.swift"] {
            #expect(found[path] == nil, "\(path)")
        }
    }

    /// The check finds what it's for.
    @Test func theCheckFindsARawWrite() {
        let code = [(path: "Sources/X.swift", lines: ["try data.write(to: VibePaths.root.appendingPathComponent(\"a.json\"))",
                                                       "try text.write(toFile: path, atomically: true, encoding: .utf8)",
                                                       "FileManager.default.createFile(atPath: p, contents: d)",
                                                       "try fm.createDirectory(at: dir, withIntermediateDirectories: true)",
                                                       "try VibePaths.writePrivate(data, to: url)"])]
        #expect(Self.rawCalls(in: code) == ["Sources/X.swift": 4])
    }
}
