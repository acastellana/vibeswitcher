import Foundation
import VibePlatform

/// How a role's `claude` is launched where the systems differ (the stage 2 plan's Task 10b; the security architecture
/// document's S10), and the permission mode every role's launch names on both. `LeadLaunch` calls it from two hooks:
/// `deny` appends `denyRules`, and `prepare` adds `permissionMode(command:)` to its command and returns through
/// `inline`. On the Mac `denyRules` is empty and `inline` returns what it is given.
enum LinuxLaunch {
    // MARK: Deny rules

    /// The rules `role` is refused beyond `base`, the ones `LeadLaunch.deny` gives on both systems, none of them
    /// already there: `Platform.Tools.roleDenyRules` for every role, and for the lead, where
    /// `Platform.Tools.leadGetsTracerRules`, the debuggers (`LeadLaunch.debuggers`) workers and verifiers already have.
    /// The Mac: none.
    static func denyRules(for role: LeadLaunch.Role, base: [String]) -> [String] {
        var added = Platform.Tools.roleDenyRules
        if role == .lead, Platform.Tools.leadGetsTracerRules { added = LeadLaunch.debuggers + added }
        var seen = Set(base)
        return added.filter { seen.insert($0).inserted }
    }

    // MARK: The permission mode

    /// The permission mode every role is launched in, on both systems: auto mode. Until Task 10b no role's launch
    /// named one, so each ran in the mode Claude Code starts in when the user's settings name none: auto mode since
    /// 2.1.284 (the mode the rules were checked in, `LeadLaunchTests.noRoleMayWriteTheUsersMacWideSettings`' note,
    /// and that the briefs count on: a worker updates its branch by merging, which auto mode allows, and a rebase it
    /// refuses), and still in 2.1.323 (stage 1's R10, `docs/process/v2-linux-inventory.md`). Named, it no longer
    /// changes with Claude Code's default or with a `defaultMode` in the user's settings, which a worker's shell can
    /// write.
    static let permissionMode = "auto"

    /// What a role's command adds after the project's Claude command `command` to name its permission mode:
    /// `--permission-mode auto`, unless `command` names a mode itself (`--permission-mode x`, `--permission-mode=x`,
    /// `--dangerously-skip-permissions`), which it then keeps, as it did before, rather than give `claude` two.
    static func permissionMode(command: String) -> [String] {
        namesPermissionMode(command) ? [] : ["--permission-mode \(permissionMode)"]
    }

    /// Whether the Claude command line `command` names a permission mode of its own.
    static func namesPermissionMode(_ command: String) -> Bool {
        command.range(of: #"(^|\s)(--permission-mode(=|\s|$)|--dangerously-skip-permissions(\s|$))"#, options: .regularExpression) != nil
    }

    // MARK: Inline settings

    /// The most bytes one argument may hold here (Linux's `MAX_ARG_STRLEN`, 32 pages of 4 KiB, its closing NUL
    /// included): a session's whole command is one argument, the `-c` of its shell.
    static let argumentLimit = 128 * 1024
    /// What the host may add to that argument (a kept shell's `; exec /bin/bash --noprofile --norc -i`), and its NUL.
    static let argumentRoom = 1024

    /// `prepared` with, where `enabled` (`Platform.Tools.roleSettingsInline`, Linux), the role's settings and MCP
    /// configuration on `claude`'s command line as JSON strings (`--settings '<json>'`, `--mcp-config '<json>'`,
    /// shell-quoted) in place of the files `prepare` named, and its prompt too (`--append-system-prompt '<text>'`)
    /// while the whole command, prompt and all, fits `argumentLimit` less `argumentRoom`; each file then inlined is
    /// removed. A prompt too long for that stays its file (the security architecture document's S11, item 7).
    ///
    /// The JSON is made from `mcp` and `settings`, the values `prepare` wrote (never read back from the files, which a
    /// worker could have rewritten meanwhile); nothing in them, or in the prompt, is secret: every process reads a
    /// command line (S11). The Mac: `prepared` as it is, files and all.
    static func inline(_ prepared: LeadLaunch.Prepared, prompt: String, mcp: [String: Any], settings: [String: Any],
                       enabled: Bool = Platform.Tools.roleSettingsInline) throws -> LeadLaunch.Prepared {
        guard enabled else { return prepared }
        let quote = RecentProjects.shellQuote
        let original = prepared.command
        func swap(_ flag: String, _ file: String, for replacement: String) -> (range: Range<String.Index>, text: String, file: String)? {
            original.range(of: "\(flag) \(quote(file))").map { ($0, replacement, file) }
        }
        let fixed = [swap("--mcp-config", prepared.mcpFile, for: "--mcp-config \(quote(try json(mcp)))"),
                     swap("--settings", prepared.settingsFile, for: "--settings \(quote(try json(settings)))")].compactMap { $0 }
        var swaps = fixed
        var command = rewritten(original, fixed)
        if let promptSwap = swap("--append-system-prompt-file", prepared.promptFile, for: "--append-system-prompt \(quote(prompt))") {
            let withPrompt = rewritten(original, fixed + [promptSwap])
            if withPrompt.utf8.count <= argumentLimit - argumentRoom {
                swaps.append(promptSwap)
                command = withPrompt
            }
        }
        var result = prepared
        result.command = command
        for swap in swaps { unlink(swap.file) }
        return result
    }

    /// `command` with each of `swaps`' ranges (of `command`, none overlapping) replaced by its text.
    static func rewritten(_ command: String, _ swaps: [(range: Range<String.Index>, text: String, file: String)]) -> String {
        var result = ""
        var rest = command.startIndex
        for swap in swaps.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            result += command[rest..<swap.range.lowerBound] + swap.text
            rest = swap.range.upperBound
        }
        return result + command[rest...]
    }

    /// `object` as one line of JSON, its keys sorted, its slashes as they are.
    static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
