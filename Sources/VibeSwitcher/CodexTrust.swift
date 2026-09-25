import Foundation
import VibeCore

/// Codex skips user hooks until they are trusted (normally via `/hooks` in the TUI). This does the same
/// thing the TUI does: ask `codex app-server` for our hooks' keys and hashes (`hooks/list`), then record
/// them under `hooks.state` in `~/.codex/config.toml` (`config/batchWrite`). Only VibeSwitcher's own
/// hooks are touched.
enum CodexTrust {
    enum Failure: LocalizedError {
        case launch(String), protocolError(String), timeout
        var errorDescription: String? {
            switch self {
            case .launch(let message): return "Could not start codex app-server: \(message)"
            case .protocolError(let message): return "codex app-server: \(message)"
            case .timeout: return "codex app-server did not answer in time"
            }
        }
    }

    /// Returns how many hooks were newly trusted.
    @discardableResult
    static func trustOurHooks(timeout: TimeInterval = 30) throws -> Int {
        let process = Process()
        // A login shell, so Homebrew's `codex` and the `node` it runs on are on PATH even when launched from Finder.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec codex app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.launch(error.localizedDescription) }
        defer { if process.isRunning { process.terminate() } }

        let reader = LineReader(handle: output.fileHandleForReading)
        let deadline = Date().addingTimeInterval(timeout)

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            input.fileHandleForWriting.write(data)
        }
        func call(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            while Date() < deadline {
                guard let line = reader.nextLine(timeout: deadline.timeIntervalSinceNow) else { break }
                guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      message["id"] as? Int == id else { continue }
                if let error = message["error"] as? [String: Any] {
                    throw Failure.protocolError(error["message"] as? String ?? "\(error)")
                }
                return message["result"] as? [String: Any] ?? [:]
            }
            throw Failure.timeout
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        _ = try call(1, "initialize", ["clientInfo": ["name": "vibeswitcher", "title": "VibeSwitcher", "version": version]])
        try send(["jsonrpc": "2.0", "method": "initialized"])
        let listing = try call(2, "hooks/list", ["cwds": [NSHomeDirectory()]])
        let entries = (listing["data"] as? [[String: Any]]) ?? []
        var trust: [String: Any] = [:]
        for entry in entries {
            for hook in (entry["hooks"] as? [[String: Any]]) ?? [] {
                guard let key = hook["key"] as? String, let hash = hook["currentHash"] as? String,
                      key.hasPrefix(HookInstaller.configURL(for: .codex).path),
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

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: hook) else { return false }
        return String(decoding: data, as: UTF8.self).contains(HookInstaller.marker)
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
