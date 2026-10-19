import Foundation

/// Adds/removes VibeSwitcher's entries in `~/.claude/settings.json` and `~/.codex/hooks.json`.
/// Only our own handlers are touched: a handler is ours when its command runs our hook binary with an agent's name and
/// nothing else (`ourHandler`). A user's handler that shares a group with ours stays where it is. The rest of the file
/// is kept byte for byte: only the `hooks` value is rewritten, and a file whose hooks are already right isn't written.
public enum HookInstaller {
    public static let marker = "vibeswitcher-hook"

    static let claudeEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                               "PermissionRequest", "Notification", "Stop", "PreCompact"]
    static let codexEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                              "PermissionRequest", "Stop", "Interrupt", "PreCompact", "PostCompact",
                              "SubagentStart", "SubagentStop"]
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PermissionRequest"]

    /// In the home this process was given (`VibePaths.home`), the one Claude Code and Codex follow: a scratch HOME or
    /// CFFIXED_USER_HOME keeps a test, a bench or a debug run off the user's own files. `NSHomeDirectory()` didn't
    /// follow HOME alone.
    public static func configURL(for agent: Agent, home: String = VibePaths.home) -> URL {
        let home = URL(fileURLWithPath: home)
        switch agent {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        }
    }

    /// `<hook binary> <agent>`, the binary shell-quoted when it needs it (a home folder with a space in it).
    public static func command(for agent: Agent, hookBinary: String = VibePaths.hookBinary.path) -> String {
        "\(shellQuoted(hookBinary)) \(agent.rawValue)"
    }

    private static let shellSafe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")

    /// `word` as it is when it's only safe characters (a plain path is written as it always was, so Codex's trust in
    /// it holds); otherwise in single quotes, each `'` as `'\''`.
    public static func shellQuoted(_ word: String) -> String {
        if !word.isEmpty, word.unicodeScalars.allSatisfy(shellSafe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: Pure transforms (tested)

    /// The hook binary and agent of one of our handlers: `command(for:)`'s form (`current`), or the unquoted form
    /// versions before quoting wrote (a path of safe characters and spaces). Anything else, such as a command that
    /// only mentions `vibeswitcher-hook` or runs `vibeswitcher-hook-evil`, isn't ours.
    static func ourHandler(_ handler: [String: Any]) -> (binary: String, agent: Agent, current: Bool)? {
        guard handler["type"] as? String == "command", let command = handler["command"] as? String else { return nil }
        for agent in Agent.allCases where command.hasSuffix(" " + agent.rawValue) {
            let word = String(command.dropLast(agent.rawValue.count + 1))
            let binary: String
            if word.hasPrefix("'") {
                let inner = word.dropFirst().dropLast().replacingOccurrences(of: #"'\''"#, with: "'")
                guard word.count >= 2, shellQuoted(inner) == word else { continue }
                binary = inner
            } else {
                guard word.unicodeScalars.allSatisfy({ shellSafe.contains($0) || $0 == " " }) else { continue }
                binary = word
            }
            guard binary.hasPrefix("/"), (binary as NSString).lastPathComponent == marker else { continue }
            return (binary, agent, shellQuoted(binary) == word)
        }
        return nil
    }

    static func groupHasOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains { ourHandler($0) != nil } ?? false
    }

    /// `groups` without our handlers; a group that held only ours goes.
    static func withoutOurs(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            guard let handlers = group["hooks"] as? [[String: Any]], handlers.contains(where: { ourHandler($0) != nil })
            else { return group }
            let others = handlers.filter { ourHandler($0) == nil }
            guard !others.isEmpty else { return nil }
            var group = group
            group["hooks"] = others
            return group
        }
    }

    public static func isInstalled(in config: [String: Any]) -> Bool {
        guard let hooks = config["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { groups in
            (groups as? [[String: Any]])?.contains(where: groupHasOurs) ?? false
        }
    }

    /// The config without our handlers. An event left with no groups goes, and `hooks` goes when it's left empty;
    /// one that held nothing of ours is kept as it was.
    public static func removingOurs(from config: [String: Any]) -> [String: Any] {
        var config = config
        guard var hooks = config["hooks"] as? [String: Any] else { return config }
        var removed = false
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]], groups.contains(where: groupHasOurs) else { continue }
            let kept = withoutOurs(groups)
            hooks[event] = kept.isEmpty ? nil : kept
            removed = true
        }
        if removed { config["hooks"] = hooks.isEmpty ? nil : hooks }
        return config
    }

    /// The group we add for `event`: our handler alone, with Claude's catch-all matcher on tool events.
    static func ourGroup(event: String, agent: Agent, hookBinary: String) -> [String: Any] {
        let handler: [String: Any] = ["type": "command", "command": command(for: agent, hookBinary: hookBinary), "timeout": 5]
        var group: [String: Any] = ["hooks": [handler]]
        // Claude wants an explicit catch-all matcher on tool events; Codex matchers are regexes
        // and treat an omitted matcher as "match everything".
        if agent == .claude, toolEvents.contains(event) { group["matcher"] = "*" }
        return group
    }

    /// Our group on each of `agent`'s events, and our handlers nowhere else. An event where ours is already our
    /// group alone, as it would be added, is left where it is, so installing over a right install changes nothing.
    public static func addingOurs(to config: [String: Any], agent: Agent,
                                  hookBinary: String = VibePaths.hookBinary.path) -> [String: Any] {
        var config = config
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        let events = agent == .claude ? claudeEvents : codexEvents
        let wanted = Dictionary(uniqueKeysWithValues: events.map { ($0, ourGroup(event: $0, agent: agent, hookBinary: hookBinary)) })
        let right = Set(events.filter { event in
            let ours = (hooks[event] as? [[String: Any]])?.filter(groupHasOurs) ?? []
            return ours.count == 1 && NSDictionary(dictionary: ours[0]).isEqual(to: wanted[event]!)
        })
        for (event, value) in hooks where !right.contains(event) {
            guard let groups = value as? [[String: Any]], groups.contains(where: groupHasOurs) else { continue }
            let kept = withoutOurs(groups)
            hooks[event] = kept.isEmpty ? nil : kept
        }
        for event in events where !right.contains(event) {
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [wanted[event]!]
        }
        config["hooks"] = hooks
        return config
    }

    /// Ours, in the form this version writes, on every event this version listens to: an install from an older
    /// version (Codex hooks without PostCompact or the subagent events, or an unquoted command) asks to be installed
    /// again.
    public static func isComplete(in config: [String: Any], agent: Agent) -> Bool {
        let hooks = config["hooks"] as? [String: Any] ?? [:]
        return (agent == .claude ? claudeEvents : codexEvents).allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains { handler in
                    guard let ours = ourHandler(handler) else { return false }
                    return ours.agent == agent && ours.current
                }
            }
        }
    }

    // MARK: File IO

    public static func isInstalled(agent: Agent) -> Bool {
        isComplete(in: readConfig(configURL(for: agent)) ?? [:], agent: agent)
    }

    /// Installs (or reinstalls) our hooks. The previous file is kept once as `<name>.vibeswitcher-backup`.
    /// `url` and `hookBinary` are for tests.
    public static func install(agent: Agent, at url: URL? = nil, hookBinary: String = VibePaths.hookBinary.path) throws {
        try edit(url ?? configURL(for: agent), backup: true) { addingOurs(to: $0, agent: agent, hookBinary: hookBinary) }
    }

    public static func uninstall(agent: Agent, at url: URL? = nil) throws {
        let url = url ?? configURL(for: agent)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try edit(url, backup: false, change: removingOurs)
    }

    enum EditError: LocalizedError, Equatable {
        case changed(String)
        var errorDescription: String? {
            switch self {
            case .changed(let path): return "\(path) kept changing while VibeSwitcher was editing it; try again"
            }
        }
    }

    /// Reads the file, changes its config and writes back only the `hooks` value, unless nothing changed. When the
    /// file changes between the read and the write (Claude or the user saving it), the edit starts over from it.
    static func edit(_ url: URL, backup: Bool, change: ([String: Any]) -> [String: Any]) throws {
        let target = try fileBehindLinks(url)
        for attempt in 1...3 {
            let stamp = Stamp(of: target)
            let data = stamp == nil ? Data() : try Data(contentsOf: target)
            let current = try parse(data, path: url.path)
            let changed = change(current)
            if NSDictionary(dictionary: changed).isEqual(to: current) { return }
            let updated = try replacingHooks(in: data, with: changed["hooks"])
            guard NSDictionary(dictionary: try parse(updated, path: url.path)).isEqual(to: changed) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            if backup { try backupOnce(url) }
            do {
                try replace(target, with: updated, expecting: stamp)
                return
            } catch EditError.changed where attempt < 3 {
                continue
            }
        }
    }

    static func readConfig(_ url: URL) -> [String: Any]? { try? readConfigThrowing(url) }

    static func readConfigThrowing(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try parse(try Data(contentsOf: url), path: url.path)
    }

    static func parse(_ data: Data, path: String) throws -> [String: Any] {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path])
        }
        return object
    }

    /// A copy of the file's contents (the file a symlink points at, not the link: that would follow our edits).
    static func backupOnce(_ url: URL) throws {
        let backup = url.appendingPathExtension("vibeswitcher-backup")
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: try fileBehindLinks(url), to: backup)
        }
    }

    /// What a file was when it was read; nil when it wasn't there.
    struct Stamp: Equatable {
        var inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int

        init?(of url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            inode = info.st_ino
            size = info.st_size
            seconds = info.st_mtimespec.tv_sec
            nanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    /// Puts `data` in place of `target` (the file behind any links, so a link stays a link) with one rename, the
    /// file keeping its permissions. Just before the rename the file is checked against `stamp`, what it was when it
    /// was read: if it changed since, renaming over it would lose that change, so this throws `EditError.changed`.
    /// `beforeRename` is for tests.
    static func replace(_ target: URL, with data: Data, expecting stamp: Stamp?,
                        beforeRename: () throws -> Void = {}) throws {
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".\(target.lastPathComponent).vibeswitcher-\(UUID().uuidString)")
        try data.write(to: temp, options: .withoutOverwriting)
        defer { try? fm.removeItem(at: temp) }
        if let mode = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] {
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
        }
        try beforeRename()
        guard Stamp(of: target) == stamp else { throw EditError.changed(target.path) }
        guard rename(temp.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// `url`, or what its chain of symlinks ends at (the end may not exist yet). A loop is an error.
    static func fileBehindLinks(_ url: URL) throws -> URL {
        var file = url
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: file.path) else { return file }
            file = destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                : file.deletingLastPathComponent().appendingPathComponent(destination)
        }
        throw POSIXError(.ELOOP)
    }

    // MARK: Editing the text

    /// `data`, a JSON object, with only its top-level `hooks` value replaced by `hooks`: added after the last member
    /// when there's none, taken out when `hooks` is nil. Every other byte stays, so numbers such as `0.1` and `1e3`,
    /// the order of the keys and the spacing come back exactly as they were.
    static func replacingHooks(in data: Data, with hooks: Any?) throws -> Data {
        let bytes = [UInt8](data)
        guard let object = try JSONObjectSpans(bytes) else {
            // An empty file: the whole of it is ours to write.
            guard let hooks else { return data }
            return try json(["hooks": hooks], indent: "") + Data("\n".utf8)
        }
        let found = object.members.indices.filter { object.members[$0].key == "hooks" }
        guard found.count <= 1 else { throw CocoaError(.fileReadCorruptFile) }
        var result = bytes
        switch (found.first, hooks) {
        case (nil, nil):
            return data
        case (let index?, let hooks?):
            let member = object.members[index]
            result.replaceSubrange(member.value, with: try json(hooks, indent: indentation(at: member.keyStart, in: bytes)))
        case (let index?, nil):
            let members = object.members
            if index > 0 {
                result.removeSubrange(members[index - 1].value.upperBound..<members[index].value.upperBound)
            } else if members.count > 1 {
                result.removeSubrange(members[0].keyStart..<members[1].keyStart)
            } else {
                result.removeSubrange(object.open + 1..<object.close)
            }
        case (nil, let hooks?):
            if let last = object.members.last {
                let indent = indentation(at: last.keyStart, in: bytes) ?? "  "
                let member = Data(",\n\(indent)\"hooks\": ".utf8) + (try json(hooks, indent: indent))
                result.insert(contentsOf: member, at: last.value.upperBound)
            } else {
                let member = Data("\n  \"hooks\": ".utf8) + (try json(hooks, indent: "  ")) + Data("\n".utf8)
                result.replaceSubrange(object.open + 1..<object.close, with: member)
            }
        }
        return Data(result)
    }

    /// The spaces and tabs a line starts with, when what's at `index` is the first thing on its line.
    private static func indentation(at index: Int, in bytes: [UInt8]) -> String? {
        var start = index
        while start > 0, bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 { start -= 1 }
        guard start == 0 || bytes[start - 1] == 0x0A || bytes[start - 1] == 0x0D else { return nil }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    /// Pretty-printed, each line after the first indented by `indent`.
    private static func json(_ value: Any, indent: String?) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let indent, !indent.isEmpty else { return data }
        return Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: "\n" + indent).utf8)
    }
}

/// Where the members of a JSON text's top-level object are, by byte offset. Only for text JSONSerialization has
/// already read, so it doesn't check the grammar beyond what it needs to find its way.
private struct JSONObjectSpans {
    struct Member {
        var key: String, keyStart: Int, value: Range<Int>
    }

    var open = 0, close = 0
    var members: [Member] = []

    /// Nil when there is nothing but whitespace.
    init?(_ bytes: [UInt8]) throws {
        var i = 0
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        func skipSpace() { while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 } }
        func expect(_ byte: UInt8) throws {
            guard i < bytes.count, bytes[i] == byte else { throw CocoaError(.fileReadCorruptFile) }
        }
        func skipString() throws {
            try expect(UInt8(ascii: "\""))
            i += 1
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\\"): i += 2
                case UInt8(ascii: "\""): i += 1; return
                default: i += 1
                }
            }
            throw CocoaError(.fileReadCorruptFile)
        }
        func skipValue() throws {
            guard i < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            switch bytes[i] {
            case UInt8(ascii: "\""):
                try skipString()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                repeat {
                    guard i < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
                    switch bytes[i] {
                    case UInt8(ascii: "\""): try skipString(); continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
                    default: break
                    }
                    i += 1
                } while depth > 0
            default:
                while i < bytes.count, !Array(",}] \n\r\t".utf8).contains(bytes[i]) { i += 1 }
            }
        }

        skipSpace()
        guard i < bytes.count else { return nil }
        try expect(UInt8(ascii: "{"))
        open = i
        i += 1
        skipSpace()
        while i < bytes.count, bytes[i] != UInt8(ascii: "}") {
            let keyStart = i
            try skipString()
            let key = try JSONSerialization.jsonObject(with: Data(bytes[keyStart..<i]), options: .fragmentsAllowed) as? String
            skipSpace()
            try expect(UInt8(ascii: ":"))
            i += 1
            skipSpace()
            let valueStart = i
            try skipValue()
            members.append(Member(key: key ?? "", keyStart: keyStart, value: valueStart..<i))
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: ",") { i += 1; skipSpace() }
        }
        try expect(UInt8(ascii: "}"))
        close = i
    }
}
