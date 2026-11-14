import Foundation
import VibePlatform

/// How a role's `claude` is launched where the systems differ (the stage 2 plan's Task 10b; the security architecture
/// document's S10), and the permission mode every role's launch names on both. `LeadLaunch` calls it from its hooks:
/// each of `deny`'s three cases appends `denyRules(for:)`, and `prepare` adds `permissionMode(command:)` to its command
/// and returns through `inline`. The host records a session's command through `recorded`. On the Mac `denyRules` is
/// empty, and `inline` and `recorded` return what they are given.
public enum LinuxLaunch {
    // MARK: Deny rules

    /// The rules `role` is refused beyond the ones `LeadLaunch.deny` gives on both systems, none of them already
    /// there: `Platform.Tools.roleDenyRules` for every role, and for the lead, where
    /// `Platform.Tools.leadGetsTracerRules`, the debuggers (`LeadLaunch.debuggers`) workers and verifiers already have.
    /// The Mac: none.
    static func denyRules(for role: LeadLaunch.Role) -> [String] {
        var added = Platform.Tools.roleDenyRules
        if role == .lead, Platform.Tools.leadGetsTracerRules { added = LeadLaunch.debuggers + added }
        var seen = Set(everyRolesRules)
        return added.filter { seen.insert($0).inserted }
    }

    /// The lists `LeadLaunch.deny` gives every role (`Edit(~/.vibeswitcher/lead/**)`, in `privateFiles`, is also one
    /// of Linux's): what `denyRules` leaves out so that no rule is there twice.
    static var everyRolesRules: [String] {
        LeadLaunch.gitAround + LeadLaunch.remoteWrites + LeadLaunch.privateFiles + LeadLaunch.outsideReads + LeadLaunch.userSettings
            + LeadLaunch.killsByName + LeadLaunch.crossSession
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
    /// configuration on `claude`'s command line as JSON strings (`--mcp-config '<json>'`, `--settings '<json>'`,
    /// shell-quoted) in place of the files `prepare` named, and its prompt too (`--append-system-prompt '<text>'`)
    /// while the whole command, prompt and all, fits `argumentLimit` less `argumentRoom`; each file then inlined is
    /// removed. A prompt too long for that stays its file (the security architecture document's S11, item 7).
    ///
    /// The inlined values go last, just before `-- '<start>'` (`start`, the command's end), after `--name` and
    /// `--model`: what they hold, the prompt's text above all, is never read as one of those
    /// (`LeadLaunch.name(inCommand:)` takes the first `--name`).
    ///
    /// The JSON is made from `mcp` and `settings`, the values `prepare` wrote (never read back from the files, which a
    /// worker could have rewritten meanwhile); nothing in them, or in the prompt, is secret: every process reads a
    /// command line (S11). The Mac: `prepared` as it is, files and all.
    static func inline(_ prepared: LeadLaunch.Prepared, prompt: String, mcp: [String: Any], settings: [String: Any], start: String,
                       enabled: Bool = Platform.Tools.roleSettingsInline) throws -> LeadLaunch.Prepared {
        guard enabled else { return prepared }
        let quote = RecentProjects.shellQuote
        let end = " -- " + quote(start)
        guard prepared.command.hasSuffix(end) else { throw Unexpected(command: prepared.command) }
        // The command before its end, without the file named by `flag` (the last such word: the project's own
        // Claude command comes first). Nil when it names no such file.
        func without(_ flag: String, _ file: String, in command: String) -> String? {
            command.range(of: " \(flag) \(quote(file))", options: .backwards).map { command.replacingCharacters(in: $0, with: "") }
        }
        var head = String(prepared.command.dropLast(end.count))
        var inlined: [String] = []
        for (flag, file, value) in [("--mcp-config", prepared.mcpFile, try json(mcp)), ("--settings", prepared.settingsFile, try json(settings))] {
            guard let rest = without(flag, file, in: head) else { continue }
            head = rest + " \(flag) \(quote(value))"
            inlined.append(file)
        }
        if let rest = without("--append-system-prompt-file", prepared.promptFile, in: head) {
            let withPrompt = rest + " --append-system-prompt \(quote(prompt))"
            if withPrompt.utf8.count + end.utf8.count <= argumentLimit - argumentRoom {
                head = withPrompt
                inlined.append(prepared.promptFile)
            }
        }
        var result = prepared
        result.command = head + end
        for file in inlined { unlink(file) }
        return result
    }

    /// `prepare`'s command didn't end with its start: never, so nothing is inlined and nothing is started.
    struct Unexpected: Error, CustomStringConvertible {
        var command: String
        var description: String { "A role's command line didn't end as it was made: \(command.prefix(200))" }
    }

    /// `object` as one line of JSON, its keys sorted, its slashes as they are.
    static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    // MARK: The command the host records

    /// Longer than this, an inline value is left out of the command the host records.
    static let recordedValueLimit = 512

    /// The command the host records for a session started with `command` (`HostSession.command`, which every client
    /// gets in each `welcome`, `list` and change of the session, ended sessions included for a day): where `enabled`
    /// (`Platform.Tools.roleSettingsInline`, Linux), `command` with each value of `--settings`, `--mcp-config` and
    /// `--append-system-prompt` longer than `recordedValueLimit` shown as `'…'`. The host runs `command` itself;
    /// only what it keeps and sends is shorter. A role's inline launch (`inline`) is 15 to 30 KiB, and a day of a
    /// team's sessions would pass a frame's 1 MiB (`HostFrame.maxPayload`), so that no client could be welcomed.
    /// The Mac: `command` as it is.
    public static func recorded(_ command: String?, enabled: Bool = Platform.Tools.roleSettingsInline) -> String? {
        guard enabled, let command, command.utf8.count > recordedValueLimit else { return command }
        let pattern = #"(^|\s)(--settings|--mcp-config|--append-system-prompt) ('[^']*(?:'\\''[^']*)*')"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return command }
        let text = command as NSString
        var result = ""
        var rest = 0
        for match in expression.matches(in: command, range: NSRange(location: 0, length: text.length)) {
            let value = match.range(at: 3)
            guard text.substring(with: value).utf8.count > recordedValueLimit else { continue }
            result += text.substring(with: NSRange(location: rest, length: value.location - rest)) + "'…'"
            rest = value.location + value.length
        }
        return rest == 0 ? command : result + text.substring(from: rest)
    }
}
