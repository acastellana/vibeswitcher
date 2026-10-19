import Foundation
import VibeCore

/// Codex skips user hooks until they are trusted (normally via `/hooks` in the TUI). This does the same
/// thing the TUI does: ask `codex app-server` for our hooks' keys and hashes (`hooks/list`), then record
/// them under `hooks.state` in `~/.codex/config.toml` (`config/batchWrite`). Only VibeSwitcher's own
/// hooks are touched.
enum CodexTrust {
    enum Failure: LocalizedError, Equatable {
        case launch(String), protocolError(String), timeout, quit
        var errorDescription: String? {
            switch self {
            case .launch(let message): return "Could not start codex app-server: \(message)"
            case .protocolError(let message): return "codex app-server: \(message)"
            case .timeout: return "codex app-server did not answer in time"
            case .quit: return "codex app-server quit before it was done"
            }
        }
    }

    /// Returns how many hooks were newly trusted. `arguments` are for tests: zsh running a stand-in app-server.
    @discardableResult
    static func trustOurHooks(timeout: TimeInterval = 30, arguments: [String] = ["-lc", "exec codex app-server"]) throws -> Int {
        let process = Process()
        // A login shell, so Homebrew's `codex` and the `node` it runs on are on PATH even when launched from Finder.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = arguments
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // The app doesn't ignore SIGPIPE (its children would inherit that): a write after the app-server quits must
        // fail with EPIPE on this pipe rather than kill VibeSwitcher.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { throw Failure.launch(error.localizedDescription) }
        defer { if process.isRunning { process.terminate() } }

        let reader = LineReader(handle: output.fileHandleForReading)
        let deadline = Date().addingTimeInterval(timeout)

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            do { try input.fileHandleForWriting.write(contentsOf: data) } catch { throw Failure.quit }
        }
        func call(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            while Date() < deadline {
                guard let line = reader.nextLine(timeout: deadline.timeIntervalSinceNow) else {
                    // Its output ended: it quit, however much time was left.
                    if reader.ended { throw Failure.quit }
                    break
                }
                guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      message["id"] as? Int == id else { continue }
                if let error = message["error"] as? [String: Any] {
                    throw Failure.protocolError(error["message"] as? String ?? "\(error)")
                }
                return message["result"] as? [String: Any] ?? [:]
            }
            // Out of time: slow only if it's still there (a process it started may hold its output open after it quit).
            throw process.isRunning ? Failure.timeout : Failure.quit
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        _ = try call(1, "initialize", ["clientInfo": ["name": "vibeswitcher", "title": "VibeSwitcher", "version": version]])
        try send(["jsonrpc": "2.0", "method": "initialized"])
        let listing = try call(2, "hooks/list", ["cwds": [NSHomeDirectory()]])
        let entries = (listing["data"] as? [[String: Any]]) ?? []
        var trust: [String: Any] = [:]
        let ourFile = realPath(HookInstaller.configURL(for: .codex).path)
        for entry in entries {
            for hook in (entry["hooks"] as? [[String: Any]]) ?? [] {
                guard let key = hook["key"] as? String, let hash = hook["currentHash"] as? String,
                      file(ofKey: key).map(realPath) == ourFile,
                      isOurs(hook),
                      ["untrusted", "modified"].contains(hook["trustStatus"] as? String ?? "") else { continue }
                trust[key] = ["trusted_hash": hash]
            }
        }
        guard !trust.isEmpty else { return 0 }
        _ = try call(3, "config/batchWrite", [
            "edits": [["keyPath": "hooks.state", "value": trust, "mergeStrategy": "upsert"]],
            "reloadUserConfig": true,
        ])
        return trust.count
    }

    /// A hook's key is `<hooks.json path>:<event>:<group>:<handler>`; Codex writes the path resolved
    /// (`/private/tmp/…` where Foundation says `/tmp/…`), so paths are compared by where they really are.
    static func file(ofKey key: String) -> String? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        return parts.dropLast(3).joined(separator: ":")
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Ours: exactly the command handler `HookInstaller` writes for Codex (`hooks/list` gives a hook's `handlerType`
    /// and `command`). One that only mentions our binary (`curl … | sh # vibeswitcher-hook`) or runs another binary
    /// whose name starts the same (`vibeswitcher-hook-evil codex`) isn't, and is never trusted.
    static func isOurs(_ hook: [String: Any], command: String = HookInstaller.command(for: .codex)) -> Bool {
        hook["handlerType"] as? String == "command" && hook["command"] as? String == command
    }
}

/// Minimal newline-delimited reader over a pipe, with a timeout per line.
private final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var lines: [String] = []
    private let lock = NSCondition()
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.append(chunk)
        }
    }

    deinit { handle.readabilityHandler = nil }

    private func append(_ chunk: Data) {
        lock.lock()
        if chunk.isEmpty { closed = true; handle.readabilityHandler = nil }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.broadcast()
        lock.unlock()
    }

    /// Whether its output ended and every line was read.
    var ended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed && lines.isEmpty
    }

    func nextLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        lock.lock()
        defer { lock.unlock() }
        while lines.isEmpty, !closed {
            if !lock.wait(until: deadline) { return nil }
        }
        return lines.isEmpty ? nil : lines.removeFirst()
    }
}
