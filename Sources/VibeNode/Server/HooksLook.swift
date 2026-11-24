import Foundation
import VibeCore

/// The hooks in `status` (2026-11-24, after the user's first switch on the real node: `approve` said the hooks were out
/// of date, `status` didn't): what `vibeswitcher approve` would list of them (`HooksRequest.outOfDate`), read off the
/// queue at each `refreshNotes` (each `status`, each housekeeping), and said as one notice with its command. Each
/// program's SHA-256 is kept by its file's stat (device, inode, size, change and modification times), so a look
/// that finds the same files hashes nothing again (a debug build's programs are 70 MB each).
final class HooksLook: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [String] = []
    private var agents: [Agent] = []
    private var hashes: [String: (stat: String, sha: String?)] = [:]
    let reads = DispatchQueue(label: "vibenode.status-hooks", qos: .utility)

    /// The notice, nil while the hooks are up to date (or not looked at yet).
    var notice: String? {
        let (reasons, agents) = lock.withLock { (self.reasons, self.agents) }
        guard !reasons.isEmpty else { return nil }
        return Self.notice(reasons: reasons, agents: agents)
    }

    static func notice(reasons: [String], agents: [Agent]) -> String {
        "the hooks are out of date: " + reasons.joined(separator: "; ") + ": " + HooksRequest.installCommand
            + " (or `vibeswitcher approve`, with what else waits)"
    }

    func set(reasons: [String], agents: [Agent]) { lock.withLock { (self.reasons, self.agents) = (reasons, agents) } }

    /// `path`'s SHA-256, from the last look when its stat is the same. On `reads`.
    func sha256(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let modified = Platform.Files.modified(info), changed = Platform.Files.changed(info)
        let key = "\(info.st_dev) \(info.st_ino) \(info.st_size) \(modified.tv_sec).\(modified.tv_nsec) \(changed.tv_sec).\(changed.tv_nsec)"
        if let kept = lock.withLock({ hashes[path] }), kept.stat == key { return kept.sha }
        let sha = HooksRequest.sha256(path)
        lock.withLock { hashes[path] = (key, sha) }
        return sha
    }
}

extension Requests {
    /// The hooks looked at again on `hooksLook`'s queue, as `approve` looks (the build's programs by the host's notes,
    /// Claude's config, and Codex's when it has one), then `done` on `queue`. Nothing on a server with no build folder
    /// (as `approve`'s hooks: a scratch server not installed).
    func refreshHooks(_ done: @escaping () -> Void = {}) {
        let (look, home, binaries, vault, queue) = (hooksLook, home, notes?.notes.binaries, link.vault, queue)
        guard let nodeRoot, !nodeRoot.isEmpty else { return done() }
        look.reads.async {
            var agents: [Agent] = [.claude]
            if FileManager.default.fileExists(atPath: HookInstaller.configURL(for: .codex, home: home).path) { agents.append(.codex) }
            let reasons = HooksRequest(nodeRoot: nodeRoot, home: home, binaries: binaries, vault: vault).outOfDate(agents: agents, hash: look.sha256)
            look.set(reasons: reasons, agents: agents)
            queue.async { done() }
        }
    }
}
