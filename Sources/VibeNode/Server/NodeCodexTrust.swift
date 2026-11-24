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
/// - It runs with a clean environment (PATH as the server has it, HOME the node's home, LANG), its own process group,
///   stdin and stdout pipes, stderr to /dev/null, in the home: nothing of a session's. `Platform.Spawn`, a bounded wait
///   (`limit`, 30 s for the whole exchange), its group killed and collected after, never Foundation's waitUntilExit.
/// - Only entries of the node's own `~/.codex/hooks.json` whose handler is exactly the command `HookInstaller` writes
///   for Codex with the node's `~/.vibeswitcher/bin/vibeswitcher-hook` (`isOurs`), untrusted or modified, each with
///   the hash Codex reports for exactly that entry, in a plain form (`hashShape`: else refused, never written).
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

    /// What trusting did: how many were trusted (taken, as the second listing says), which keys were refused for their
    /// hash, or written and not taken, and whether `config.toml` was put back (Codex wrote more under `hooks.state` than
    /// our trust).
    public struct Outcome: Equatable, Sendable {
        public var trusted: Int
        /// Ours Codex listed trusted already (the hash it holds is the entry's).
        public var already = 0
        public var refused: [String] = []
        public var notTaken: [String] = []
        public var putBack = false
    }

    /// A hash as Codex reports one (`sha256:…`): letters, digits and `:+/=_-`, at most 200; anything else isn't written.
    static func hashShape(_ hash: String) -> Bool {
        !hash.isEmpty && hash.count <= 200
            && hash.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || ":+/=_-".unicodeScalars.contains($0) }
    }

    /// What `config.toml` was found holding after the exchange (`check`).
    public enum FileCheck: Equatable, Sendable {
        /// As it was, or with only our trust added: the app's to seal.
        case ours
        /// Codex wrote more under `hooks.state` than our trust, or another hash: put back as it was.
        case putBack
        /// Changed outside `hooks.state`, which Codex's write doesn't touch: a hand edit while this ran (or a Codex
        /// that isn't Codex). Left as it is and sealed nothing, so it is held: a held file is recoverable, a dropped
        /// edit isn't.
        case changedMeanwhile
    }

    /// Trusts our hooks in `home`'s Codex by running `codex app-server`, the server's `path` as its PATH (Codex runs on
    /// node). `hookBinary`: the node's hook program. Called inside the vault's `appWrite(_:sealIf:)` of `config.toml`,
    /// which seals what it leaves there only when `file` is `.ours`: the file is checked once Codex has ended, on every
    /// path out (`check`).
    public static func trust(codex: String, home: String, hookBinary: String, path: String?, limit: TimeInterval = limit,
                             file: inout FileCheck) throws -> Outcome {
        file = .ours
        var info = stat()
        guard stat(codex, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(codex, X_OK) == 0 else {
            throw Failure.launch("\(codex) isn't an executable regular file")
        }
        let config = (home as NSString).appendingPathComponent(".codex/config.toml")
        let before = FileManager.default.contents(atPath: config)
        var beforeMode: mode_t = 0o600
        if stat(config, &info) == 0 { beforeMode = info.st_mode & 0o7777 }
        let ourFile = realPath(HookInstaller.configURL(for: .codex, home: home).path)
        let command = HookInstaller.command(for: .codex, hookBinary: hookBinary)
        func ours(_ listing: [String: Any]) -> [(key: String, hash: String, status: String)] {
            ((listing["data"] as? [[String: Any]]) ?? []).flatMap { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { hook -> (String, String, String)? in
                    guard let key = hook["key"] as? String, let hash = hook["currentHash"] as? String,
                          Self.file(ofKey: key).map(realPath) == ourFile, isOurs(hook, command: command) else { return nil }
                    return (key, hash, hook["trustStatus"] as? String ?? "")
                }
            }
        }
        var trust: [String: String] = [:]
        var outcome = Outcome(trusted: 0)
        do {
            let session = try Session(codex: codex, home: home, path: path, limit: limit)
            defer { session.end() }
            _ = try session.call(1, "initialize", ["clientInfo": ["name": "vibeswitcher", "title": "VibeSwitcher", "version": "node"]])
            try session.send(["jsonrpc": "2.0", "method": "initialized"])
            let listed = ours(try session.call(2, "hooks/list", ["cwds": [home]]))
            outcome.already = listed.filter { $0.status == "trusted" }.count
            for hook in listed where ["untrusted", "modified"].contains(hook.status) {
                // A key's or a hash's form not Codex's (a quote, a control character) is never written.
                guard hashShape(hook.hash), !hook.key.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                    outcome.refused.append(hook.key)
                    continue
                }
                trust[hook.key] = hook.hash
            }
            if !trust.isEmpty { try write(session) }
        } catch {
            // Ended (above) before the file is looked at: whatever it wrote before it failed is checked as below.
            file = (try? check(config: config, before: before, mode: beforeMode, trust: trust)) ?? .changedMeanwhile
            throw error
        }
        func write(_ session: Session) throws {
            _ = try session.call(3, "config/batchWrite", [
                "edits": [["keyPath": "hooks.state", "value": trust.mapValues { ["trusted_hash": $0] }, "mergeStrategy": "upsert"]],
                "reloadUserConfig": true,
            ])
            // Taken: each written key listed again, trusted now.
            let after = Dictionary(ours(try session.call(4, "hooks/list", ["cwds": [home]])).map { ($0.key, $0.status) }, uniquingKeysWith: { first, _ in first })
            outcome.trusted = trust.keys.filter { after[$0] == "trusted" }.count
            outcome.notTaken = trust.keys.filter { after[$0] != "trusted" }.sorted()
        }
        // Its group ended (`end`): what the file holds now is what it left, ours or not (nothing to trust: as it was).
        do { file = try check(config: config, before: before, mode: beforeMode, trust: trust) } catch {
            file = .changedMeanwhile
            throw error
        }
        guard file == .ours else {
            return Outcome(trusted: 0, already: outcome.already, refused: outcome.refused, notTaken: trust.keys.sorted(), putBack: file == .putBack)
        }
        return outcome
    }

    /// What `config` holds against `before` (`FileCheck`): put back as it was (`before`, or taken out when there was
    /// none) only when what differs is all under `hooks.state`, Codex's part.
    static func check(config: String, before: Data?, mode: mode_t, trust: [String: String]) throws -> FileCheck {
        let now = FileManager.default.contents(atPath: config)
        if now == before { return .ours }
        let was = before.map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard let now else { return .changedMeanwhile }
        let text = String(decoding: now, as: UTF8.self)
        if onlyOurTrust(before: was, after: text, trust: trust) { return .ours }
        guard sameOutsideHooksState(was, text) else { return .changedMeanwhile }
        if let before { try restore(before, to: config, mode: mode) } else { unlink(config) }
        return .putBack
    }

    /// Whether `before` and `after` are the same but for the tables under `hooks.state` (blank lines aside).
    static func sameOutsideHooksState(_ before: String, _ after: String) -> Bool {
        func outside(_ text: String) -> [String] {
            tables(text).filter { !($0.header == "[hooks.state]" || $0.header.hasPrefix("[hooks.state.")) }.flatMap { [$0.header] + $0.lines }
        }
        return outside(before) == outside(after)
    }

    /// The file as (table header, its lines), blank lines left out; the lines before any header under "".
    static func tables(_ text: String) -> [(header: String, lines: [String])] {
        var found: [(header: String, lines: [String])] = [("", [])]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") { found.append((line, [])) } else { found[found.count - 1].lines.append(raw) }
        }
        return found
    }

    /// `bytes` put in `path` as one rename, the file's mode `mode` from its making (never wider meanwhile).
    static func restore(_ bytes: Data, to path: String, mode: mode_t) throws {
        let temporary = path + ".vibeswitcher-\(UUID().uuidString.prefix(8))"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Platform.Errno(code: errno) }
        var failed: Int32 = 0
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let wrote = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if wrote > 0 { offset += wrote } else if wrote < 0, errno == EINTR { continue } else { failed = errno == 0 ? EIO : errno; return }
            }
        }
        if failed == 0, fchmod(fd, mode) != 0 || fsync(fd) != 0 { failed = errno }
        Sys.close(fd)
        guard failed == 0, rename(temporary, path) == 0 else {
            let code = failed == 0 ? errno : failed
            unlink(temporary)
            throw Platform.Errno(code: code)
        }
    }

    /// `after` is `before` with our trust in it (Codex's form, `[hooks.state."<key>"]` with `trusted_hash = "<hash>"`, and
    /// an empty `[hooks.state]`), and nothing else changed: every other table as it was, line for line (blank lines
    /// aside), another hook's trust among them; each of ours holding exactly the hash Codex listed for it.
    static func onlyOurTrust(before: String, after: String, trust: [String: String]) -> Bool {
        func header(_ key: String) -> String {
            "[hooks.state.\"" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"]"
        }
        let ourHeaders = Dictionary(uniqueKeysWithValues: trust.map { (header($0.key), $0.value) })
        func rest(_ tables: [(header: String, lines: [String])]) -> [String] {
            tables.filter { table in
                !(ourHeaders[table.header] != nil || (table.header == "[hooks.state]" && table.lines.isEmpty))
            }.flatMap { [$0.header] + $0.lines }
        }
        let was = tables(before), now = tables(after)
        guard rest(was) == rest(now) else { return false }
        for (header, hash) in ourHeaders {
            let found = now.filter { $0.header == header }
            guard found.count == 1, found[0].lines.map({ $0.trimmingCharacters(in: .whitespaces) }) == ["trusted_hash = \"\(hash)\""] else { return false }
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

        init(codex: String, home: String, path: String?, limit: TimeInterval) throws {
            var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1]
            guard Sys.pipeClosedOnExec(&inPipe) == 0 else { throw Failure.launch("no pipe (errno \(errno))") }
            guard Sys.pipeClosedOnExec(&outPipe) == 0 else {
                inPipe.forEach { Sys.close($0) }
                throw Failure.launch("no pipe (errno \(errno))")
            }
            var spawn = Platform.Spawn(executable: codex, arguments: [codex, "app-server"])
            spawn.environment = ["HOME=\(home)", "PATH=\(path ?? "/usr/bin:/bin")", "LANG=C.UTF-8"]
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

        /// Its pipes closed, its group ended, and it collected (bounded: 5 s, then left to init).
        func end() {
            Sys.close(input)
            Sys.close(output)
            Sys.kill(-pid, SIGKILL)
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
