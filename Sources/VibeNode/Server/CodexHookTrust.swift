import Foundation
import VibeCore

/// Trusting VibeSwitcher's hooks in Codex (the app's `CodexTrust`, Sources/VibeSwitcher/CodexTrust.swift, for a node):
/// Codex skips a user hook until it is trusted (normally `/hooks` in its TUI). This does what the TUI does: asks
/// `codex app-server` (started by the user's login shell, so their `codex` is found, in the node's home with no
/// `CODEX_HOME`) for the hooks' keys and hashes (`hooks/list`), and records ours under `hooks.state` in
/// `~/.codex/config.toml` (`config/batchWrite`). Only VibeSwitcher's own hooks: the exact command `HookInstaller` wrote
/// for Codex, in the hooks file it wrote (`isOurs`, `file(ofKey:)`); a planted hook beside ours is never trusted.
///
/// `hooks install --agent codex` runs it after the hooks are in, as the app's Settings does, inside the vault's
/// `appWrite` of `~/.codex/config.toml` (`HooksRequest.trustCodex`): what Codex writes there is sealed as VibeSwitcher's.
///
/// Started with `Platform.Spawn` (never Foundation's `Process`, whose wait hangs on the Mac's runners), in a process
/// group of its own that is ended when it's done; each line read with a deadline, so a Codex that never answers is a
/// refusal in `timeout`, never a hang. The server ignores SIGPIPE: a write after it quit is EPIPE, a `quit`.
public enum CodexHookTrust {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case launch(String), protocolError(String), timeout, quit
        public var description: String {
            switch self {
            case .launch(let message): return "codex app-server couldn't start: \(message)"
            case .protocolError(let message): return "codex app-server: \(ConfigSeal.inert(message, limit: 300))"
            case .timeout: return "codex app-server didn't answer in time"
            case .quit: return "codex app-server quit before it was done (is codex installed for your login shell?)"
            }
        }
    }

    /// How it starts: the user's login shell running `codex app-server`. Tests give a stand-in.
    public static func loginCommand() -> [String] { [Platform.Tools.loginShell, "-lc", "exec codex app-server"] }

    /// Asks the app-server and trusts our hooks in `home`'s Codex config; returns how many were newly trusted.
    /// `command`: the program and its arguments (`loginCommand()`); `hookBinary`: the program the hooks run, as
    /// `HookInstaller` wrote it into `<home>/.codex/hooks.json`. Blocks: never on a server queue.
    public static func trustOurHooks(home: String, hookBinary: String, command: [String] = loginCommand(),
                                     timeout: TimeInterval = 30) throws -> Int {
        guard let executable = command.first else { throw Failure.launch("no program") }
        var toChild: [Int32] = [-1, -1], fromChild: [Int32] = [-1, -1]
        guard Sys.pipe(&toChild) == 0 else { throw Failure.launch(String(cString: strerror(errno))) }
        guard Sys.pipe(&fromChild) == 0 else {
            let code = errno
            Sys.close(toChild[0]); Sys.close(toChild[1])
            throw Failure.launch(String(cString: strerror(code)))
        }
        var spawn = Platform.Spawn(executable: executable, arguments: command)
        spawn.stdin = .descriptor(toChild[0])
        spawn.stdout = .descriptor(fromChild[1])
        spawn.stderr = .path("/dev/null", flags: O_WRONLY)
        spawn.group = .ownGroup
        spawn.directory = home
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        environment["CODEX_HOME"] = nil
        spawn.environment = environment.map { "\($0.key)=\($0.value)" }
        let started = spawn.start()
        Sys.close(toChild[0])
        Sys.close(fromChild[1])
        let (input, output) = (toChild[1], fromChild[0])
        defer { Sys.close(input); Sys.close(output) }
        let pid: pid_t
        switch started {
        case .failure(let failure): throw Failure.launch(String(cString: strerror(failure.code)))
        case .success(let child): pid = child
        }
        defer { end(pid) }
        _ = fcntl(output, F_SETFL, fcntl(output, F_GETFL) | O_NONBLOCK)
        let reader = Lines(fd: output)
        let deadline = Date().addingTimeInterval(timeout)

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            let bytes = [UInt8](data)
            var done = 0
            while done < bytes.count {
                let wrote = bytes.withUnsafeBytes { Sys.write(input, $0.baseAddress! + done, bytes.count - done) }
                if wrote < 0, errno == EINTR { continue }
                guard wrote > 0 else { throw Failure.quit }
                done += wrote
            }
        }
        func call(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            while true {
                switch reader.next(until: deadline) {
                case .ended: throw Failure.quit
                case .timedOut: throw Failure.timeout
                case .line(let line):
                    guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                          message["id"] as? Int == id else { continue }
                    if let error = message["error"] as? [String: Any] {
                        throw Failure.protocolError(error["message"] as? String ?? "\(error)")
                    }
                    return message["result"] as? [String: Any] ?? [:]
                }
            }
        }

        _ = try call(1, "initialize", ["clientInfo": ["name": "vibeswitcher", "title": "VibeSwitcher", "version": "node"]])
        try send(["jsonrpc": "2.0", "method": "initialized"])
        let listing = try call(2, "hooks/list", ["cwds": [home]])
        let ours = trust(listing: listing, hooksFile: HookInstaller.configURL(for: .codex, home: home).path,
                         command: HookInstaller.command(for: .codex, hookBinary: hookBinary))
        guard !ours.isEmpty else { return 0 }
        _ = try call(3, "config/batchWrite", [
            "edits": [["keyPath": "hooks.state", "value": ours.mapValues { ["trusted_hash": $0] }, "mergeStrategy": "upsert"]],
            "reloadUserConfig": true,
        ])
        return ours.count
    }

    /// Of `hooks/list`'s answer, our hooks Codex doesn't trust yet (untrusted, or modified since): their keys and current
    /// hashes. Ours: in `hooksFile` (by where it really is) and exactly `command`'s handler.
    static func trust(listing: [String: Any], hooksFile: String, command: String) -> [String: String] {
        let file = realPath(hooksFile)
        var trust: [String: String] = [:]
        for entry in (listing["data"] as? [[String: Any]]) ?? [] {
            for hook in (entry["hooks"] as? [[String: Any]]) ?? [] {
                guard let key = hook["key"] as? String, let hash = hook["currentHash"] as? String,
                      self.file(ofKey: key).map(realPath) == file, isOurs(hook, command: command),
                      ["untrusted", "modified"].contains(hook["trustStatus"] as? String ?? "") else { continue }
                trust[key] = hash
            }
        }
        return trust
    }

    /// A hook's key is `<hooks.json path>:<event>:<group>:<handler>`.
    static func file(ofKey key: String) -> String? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        return parts.dropLast(3).joined(separator: ":")
    }

    /// Exactly the command handler `HookInstaller` writes for Codex: one that only mentions our program, or runs
    /// another whose name starts the same, isn't.
    static func isOurs(_ hook: [String: Any], command: String) -> Bool {
        hook["handlerType"] as? String == "command" && hook["command"] as? String == command
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Its group ended (TERM, then KILL after a moment) and the child reaped, never waiting unbounded.
    private static func end(_ pid: pid_t) {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { kill(-pid, SIGKILL); return }
        kill(-pid, SIGTERM)
        for _ in 0..<50 {
            if waitpid(pid, &status, WNOHANG) != 0 { kill(-pid, SIGKILL); return }
            usleep(20_000)
        }
        kill(-pid, SIGKILL)
        for _ in 0..<50 {
            if waitpid(pid, &status, WNOHANG) != 0 { return }
            usleep(20_000)
        }
    }

    /// Newline-delimited lines from a non-blocking descriptor, each waited for with `poll` until a deadline.
    final class Lines {
        enum Next: Equatable { case line(String), ended, timedOut }
        private let fd: Int32
        private var buffer = Data()
        private var closed = false
        init(fd: Int32) { self.fd = fd }

        func next(until deadline: Date) -> Next {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return .line(line)
                }
                // A cap on one line (a listing is a few kB): one that never ends isn't kept growing.
                if buffer.count > 4 * 1024 * 1024 { return .ended }
                if closed { return .ended }
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { return .timedOut }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, Int32(min(left, 1) * 1000) + 1)
                if ready < 0, errno != EINTR { closed = true; continue }
                guard ready > 0 else { continue }
                var chunk = [UInt8](repeating: 0, count: 16 * 1024)
                let count = Sys.read(fd, &chunk, chunk.count)
                if count > 0 { buffer.append(contentsOf: chunk[0..<count]) }
                else if count == 0 { closed = true }
                else if errno != EAGAIN, errno != EINTR { closed = true }
            }
        }
    }
}
