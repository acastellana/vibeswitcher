import Foundation
import VibeCore

/// The node's `hooks.install` trusts VibeSwitcher's own Codex hooks itself, as the Mac app does (`CodexTrust`): Codex
/// skips user hooks until they are trusted (normally `/hooks` in its TUI); this asks `codex app-server` for the hooks'
/// keys and hashes (`hooks/list`) and records ours under `hooks.state` in `~/.codex/config.toml` (`config/batchWrite`),
/// then lists them again to see each taken.
///
/// The node's rules, beside the Mac's:
/// - The program is the one the node's own Codex sessions run (`NodePreflight.codex`: the link `~/.local/bin/codex`
///   resolved, an executable regular file, never looked up on a PATH or through a shell), and only the one the user
///   was shown before the typed code: another (the link changed since) isn't run.
/// - It runs with a clean environment (PATH as the server has it, HOME the node's home, LANG), stdin and stdout pipes,
///   stderr to /dev/null, in the home: nothing of a session's. On the user's node with its systemd manager reachable,
///   in a transient scope of its own (`systemd-run --user --scope`, as update runs install-node), stopped after, which
///   ends whatever it started; else in its own process group, killed after. `Platform.Spawn`, a bounded wait (`limit`,
///   30 s for the whole exchange), collected after, never Foundation's waitUntilExit.
/// - Only entries of the node's own `~/.codex/hooks.json` at the places this install wrote ours (`positions`:
///   `<event>:<group>:<handler>`), whose handler is exactly the command `HookInstaller` writes for Codex with the
///   node's `~/.vibeswitcher/bin/vibeswitcher-hook` (`isOurs`), untrusted or modified, each with the hash Codex
///   reports for exactly that entry, in a plain form (`hashShape`: else refused, never written).
/// - What it leaves in `config.toml` is sealed as the app's only when it is our trust alone beside the file as it was
///   (`sealable`, read again as the vault decides); anything else, whoever made it, is left as it is and sealed
///   nothing: held, for `config held`. Never put back: a held file is recoverable, a dropped edit isn't.
/// - Codex missing, not answering in time, or speaking another protocol: nothing is trusted, and the install still
///   succeeds (its caller says to run /hooks in Codex).
public enum NodeCodexTrust {
    public static let limit: TimeInterval = 30

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case launch(String), protocolError(String), timeout, quit
        public var description: String {
            switch self {
            case .launch(let message): return "codex app-server couldn't be started: \(message)"
            case .protocolError(let message): return "codex app-server answered otherwise than expected: \(ConfigSeal.inert(message, limit: 200))"
            case .timeout: return "codex app-server didn't answer in \(Int(NodeCodexTrust.limit)) s"
            case .quit: return "codex app-server quit before it was done"
            }
        }
    }

    /// What trusting did: how many were trusted (taken, as the second listing says), how many of ours were trusted
    /// already, which keys were refused for their hash, or written and not taken.
    public struct Outcome: Equatable, Sendable {
        public var trusted: Int
        public var already = 0
        public var refused: [String] = []
        public var notTaken: [String] = []
    }

    /// What the exchange saw, for the seal's decision (`sealable`): `config.toml` before it, and the trust it asked for.
    public struct Seen: Sendable {
        public var config = ""
        public var before: Data?
        public var trust: [String: String] = [:]
        public init() {}
    }

    /// A hash as Codex reports one (`sha256:…`): letters, digits and `:+/=_-`, at most 200; anything else isn't written.
    static func hashShape(_ hash: String) -> Bool {
        !hash.isEmpty && hash.count <= 200
            && hash.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || ":+/=_-".unicodeScalars.contains($0) }
    }

    /// Codex's name for a hooks.json event (`PreToolUse` → `pre_tool_use`), as its keys spell it.
    static func snake(_ event: String) -> String {
        var out = ""
        for (index, character) in event.enumerated() {
            if character.isUppercase, index > 0 { out.append("_") }
            out.append(contentsOf: character.lowercased())
        }
        return out
    }

    /// Where `command` is a command handler in a hooks.json (`hooksJSON`): `<event>:<group>:<handler>`, Codex's key
    /// without its file, each.
    public static func positions(hooksJSON: Data, command: String) -> Set<String> {
        guard let object = (try? JSONSerialization.jsonObject(with: hooksJSON)) as? [String: Any],
              let events = object["hooks"] as? [String: Any] else { return [] }
        var found: Set<String> = []
        for (event, groups) in events {
            for (group, entry) in ((groups as? [[String: Any]]) ?? []).enumerated() {
                for (handler, hook) in ((entry["hooks"] as? [[String: Any]]) ?? []).enumerated()
                where hook["type"] as? String == "command" && hook["command"] as? String == command {
                    found.insert("\(snake(event)):\(group):\(handler)")
                }
            }
        }
        return found
    }

    /// Trusts our hooks in `home`'s Codex by running `codex app-server`, the server's `path` as its PATH (Codex runs on
    /// node). `hookBinary`: the node's hook program; `expected`: the places this install wrote ours (`positions`);
    /// `scope`: `systemd-run`, to run it in a transient scope of the user's manager, or nil (its own process group).
    /// `seen`: what the vault's `appWrite(_:sealIf:)` decides by (`sealable`), filled before anything runs.
    public static func trust(codex: String, home: String, hookBinary: String, expected: Set<String>, path: String?, scope: String? = nil,
                             limit: TimeInterval = limit, seen: inout Seen) throws -> Outcome {
        seen = Seen()
        seen.config = (home as NSString).appendingPathComponent(".codex/config.toml")
        seen.before = FileManager.default.contents(atPath: seen.config)
        var info = stat()
        guard stat(codex, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(codex, X_OK) == 0 else {
            throw Failure.launch("\(codex) isn't an executable regular file")
        }
        let ourFile = realPath(HookInstaller.configURL(for: .codex, home: home).path)
        let command = HookInstaller.command(for: .codex, hookBinary: hookBinary)
        func ours(_ listing: [String: Any]) -> [(key: String, hash: String, status: String)] {
            ((listing["data"] as? [[String: Any]]) ?? []).flatMap { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { hook -> (String, String, String)? in
                    guard let key = hook["key"] as? String, let hash = hook["currentHash"] as? String,
                          let file = Self.file(ofKey: key), realPath(file) == ourFile,
                          expected.contains(String(key.dropFirst(file.count + 1))), isOurs(hook, command: command) else { return nil }
                    return (key, hash, hook["trustStatus"] as? String ?? "")
                }
            }
        }
        var outcome = Outcome(trusted: 0)
        let session = try Session(codex: codex, home: home, path: path, scope: scope, limit: limit)
        defer { session.end() }
        _ = try session.call(1, "initialize", ["clientInfo": ["name": "vibeswitcher", "title": "VibeSwitcher", "version": "node"]])
        try session.send(["jsonrpc": "2.0", "method": "initialized"])
        let listed = ours(try session.call(2, "hooks/list", ["cwds": [home]]))
        outcome.already = listed.filter { $0.status == "trusted" }.count
        var trust: [String: String] = [:]
        for hook in listed where ["untrusted", "modified"].contains(hook.status) {
            // A key's or a hash's form not Codex's (a quote, a control character) is never written.
            guard hashShape(hook.hash), !hook.key.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                outcome.refused.append(hook.key)
                continue
            }
            trust[hook.key] = hook.hash
        }
        guard !trust.isEmpty else { return outcome }
        seen.trust = trust
        _ = try session.call(3, "config/batchWrite", [
            "edits": [["keyPath": "hooks.state", "value": trust.mapValues { ["trusted_hash": $0] }, "mergeStrategy": "upsert"]],
            "reloadUserConfig": true,
        ])
        // Taken: each written key listed again, trusted now.
        let after = Dictionary(ours(try session.call(4, "hooks/list", ["cwds": [home]])).map { ($0.key, $0.status) }, uniquingKeysWith: { first, _ in first })
        outcome.trusted = trust.keys.filter { after[$0] == "trusted" }.count
        outcome.notTaken = trust.keys.filter { after[$0] != "trusted" }.sorted()
        return outcome
    }

    /// Whether `config.toml`, read now, is the app's to seal: as it was before the exchange, or that with only the trust
    /// it asked for (`onlyOurTrust`). Called by the vault's `appWrite(_:sealIf:)` between its two reads of the file.
    public static func sealable(_ seen: Seen) -> Bool {
        let now = FileManager.default.contents(atPath: seen.config)
        if now == seen.before { return true }
        guard let now else { return false }
        return onlyOurTrust(before: seen.before.map { String(decoding: $0, as: UTF8.self) } ?? "", after: String(decoding: now, as: UTF8.self), trust: seen.trust)
    }

    /// A TOML file's lines by table: each table's header (trimmed), and its raw lines, the blank ones just above its
    /// header with it (Codex writes a new table so); the lines before any header under "", blank lines at the end with
    /// the last table.
    static func tables(_ text: String) -> [(header: String, lines: [String])] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var found: [(header: String, lines: [String])] = [("", [])]
        var blanks: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { blanks.append(raw); continue }
            if line.hasPrefix("[") {
                found.append((line, blanks + [raw]))
            } else {
                found[found.count - 1].lines += blanks + [raw]
            }
            blanks = []
        }
        found[found.count - 1].lines += blanks
        return found
    }

    /// `after` is `before` with our trust in it (Codex's form: `[hooks.state."<key>"]` holding `trusted_hash = "<hash>"`,
    /// and an empty `[hooks.state]`), and nothing else changed: every other table as it was, raw line for raw line,
    /// blank and whitespace-only ones too, another hook's trust among them; each of ours holding exactly the hash Codex
    /// listed for it.
    static func onlyOurTrust(before: String, after: String, trust: [String: String]) -> Bool {
        func header(_ key: String) -> String {
            "[hooks.state.\"" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"]"
        }
        let ourHeaders = Dictionary(uniqueKeysWithValues: trust.map { (header($0.key), $0.value) })
        func blank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }
        func ours(_ table: (header: String, lines: [String])) -> Bool {
            ourHeaders[table.header] != nil || (table.header == "[hooks.state]" && table.lines.filter { !blank($0) }.count == 1)
        }
        func rest(_ tables: [(header: String, lines: [String])]) -> [String] { tables.filter { !ours($0) }.flatMap(\.lines) }
        let was = tables(before), now = tables(after)
        guard rest(was) == rest(now) else { return false }
        for (header, hash) in ourHeaders {
            let found = now.filter { $0.header == header }
            guard found.count == 1,
                  found[0].lines.filter({ !blank($0) }).map({ $0.trimmingCharacters(in: .whitespaces) }) == [header, "trusted_hash = \"\(hash)\""] else { return false }
        }
        return true
    }

    /// One app-server: its process, its pipes, a deadline for the whole exchange.
    final class Session {
        let pid: pid_t
        let input: Int32, output: Int32
        let deadline: TimeInterval
        var buffer: [UInt8] = []
        var ended = false

        /// The transient scope's unit, when it runs in one (`systemd-run --user --scope`), stopped at `end`.
        let unit: String?

        init(codex: String, home: String, path: String?, scope: String?, limit: TimeInterval) throws {
            var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1]
            guard Sys.pipeClosedOnExec(&inPipe) == 0 else { throw Failure.launch("no pipe (errno \(errno))") }
            guard Sys.pipeClosedOnExec(&outPipe) == 0 else {
                inPipe.forEach { Sys.close($0) }
                throw Failure.launch("no pipe (errno \(errno))")
            }
            let unit = scope.map { _ in "vibeswitcher-codex-trust-\(UUID().uuidString.prefix(8).lowercased())" }
            let ran = Self.command(codex: codex, home: home, path: path, scope: scope, unit: unit)
            var spawn = Platform.Spawn(executable: ran.executable, arguments: ran.arguments)
            spawn.environment = ran.environment
            spawn.directory = home
            spawn.stdin = .descriptor(inPipe[0])
            spawn.stdout = .descriptor(outPipe[1])
            spawn.stderr = .path("/dev/null", flags: O_WRONLY)
            spawn.group = .ownGroup
            let started = spawn.start()
            Sys.close(inPipe[0])
            Sys.close(outPipe[1])
            guard case .success(let pid) = started else {
                Sys.close(inPipe[1])
                Sys.close(outPipe[0])
                if case .failure(let error) = started { throw Failure.launch("errno \(error.code)") }
                throw Failure.launch("not started")
            }
            self.pid = pid
            self.unit = unit
            input = inPipe[1]
            output = outPipe[0]
            deadline = MacTime.real.awake() + limit
        }

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            let sent = data.withUnsafeBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count {
                    let wrote = write(input, bytes.baseAddress! + offset, bytes.count - offset)
                    if wrote > 0 { offset += wrote; continue }
                    if wrote < 0, errno == EINTR { continue }
                    return false
                }
                return true
            }
            // A write to an app-server that quit fails (EPIPE: the server ignores SIGPIPE).
            guard sent else { throw Failure.quit }
        }

        /// The next line of its output, by the deadline; nil when its output ended or the time is up.
        func line() -> String? {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    return line
                }
                if ended { return nil }
                let left = deadline - MacTime.real.awake()
                guard left > 0 else { return nil }
                var watched = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
                let woke = poll(&watched, 1, Int32(max(1, min(left * 1_000, 1_000))))
                if woke < 0, errno == EINTR { continue }
                if woke == 0 { continue }
                let got = Sys.read(output, &chunk, chunk.count)
                if got < 0, errno == EINTR || errno == EAGAIN { continue }
                guard got > 0 else { ended = true; continue }
                buffer.append(contentsOf: chunk[0..<got])
                // A line past 8 MiB isn't this protocol's.
                if buffer.count > 8 << 20 { ended = true; buffer = [] }
            }
        }

        func call(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            while let line = line() {
                guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], message["id"] as? Int == id else { continue }
                if let error = message["error"] as? [String: Any] {
                    throw Failure.protocolError(error["message"] as? String ?? "an error")
                }
                guard let result = message["result"] as? [String: Any] else { throw Failure.protocolError("\(method): no result object") }
                return result
            }
            throw ended ? Failure.quit : Failure.timeout
        }

        /// What runs: `codex app-server` with the clean environment, in its own transient scope when `scope` names
        /// `systemd-run` (`env -i` inside it; systemd-run's own environment only the manager's place and a PATH).
        static func command(codex: String, home: String, path: String?, scope: String?, unit: String?) -> (executable: String, arguments: [String], environment: [String]) {
            let clean = ["HOME=\(home)", "PATH=\(path ?? "/usr/bin:/bin")", "LANG=C.UTF-8"]
            guard let scope else { return (codex, [codex, "app-server"], clean) }
            let inner = ["/usr/bin/env", "-i"] + clean + [codex, "app-server"]
            return (scope, [scope, "--user", "--scope", "--quiet", "--collect"] + (unit.map { ["--unit=\($0)"] } ?? []) + ["--"] + inner,
                    ["XDG_RUNTIME_DIR=/run/user/\(getuid())", "PATH=/usr/bin:/bin"])
        }

        /// Its pipes closed, its group ended (and its scope stopped, which ends what it started in other groups), and it
        /// collected (bounded: 5 s, then left to init).
        func end() {
            Sys.close(input)
            Sys.close(output)
            Sys.kill(-pid, SIGKILL)
            if let unit, let systemctl = Platform.Service.systemctl {
                _ = NodeStarter.run(systemctl, ["--user", "stop", unit + ".scope"],
                                    environment: ["XDG_RUNTIME_DIR=/run/user/\(getuid())", "PATH=/usr/bin:/bin"], timeout: 5)
            }
            let by = MacTime.real.awake() + 5
            var status: Int32 = 0
            while MacTime.real.awake() < by {
                let reaped = waitpid(pid, &status, WNOHANG)
                if reaped == pid || (reaped < 0 && errno != EINTR) { return }
                usleep(10_000)
            }
        }
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A hook's key is `<hooks.json path>:<event>:<group>:<handler>`; Codex writes the path resolved
    /// (`/private/tmp/…` where Foundation says `/tmp/…`), so paths are compared by where they really are.
    static func file(ofKey key: String) -> String? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        return parts.dropLast(3).joined(separator: ":")
    }

    /// Ours: exactly the command handler `HookInstaller` writes for Codex (`hooks/list` gives a hook's `handlerType`
    /// and `command`). One that only mentions our binary (`curl … | sh # vibeswitcher-hook`) or runs another binary
    /// whose name starts the same (`vibeswitcher-hook-evil codex`) isn't, and is never trusted.
    static func isOurs(_ hook: [String: Any], command: String = HookInstaller.command(for: .codex)) -> Bool {
        hook["handlerType"] as? String == "command" && hook["command"] as? String == command
    }
}
