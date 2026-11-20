import Foundation
import VibeCore

/// The messages `send` holds behind an open question (`HeldSend`), kept across a server restart or a `switch` (the parity
/// table's composer row, 2026-11-20; the app's outbox is on disk too): `<root>/v2/held-sends.json` (format 1), by the
/// host's id for the session, in the order sent. The file is no seal (a worker of the user's uid can write it), so the
/// engine's rule for its held messages holds here (EN-D9): as a message is held, its digest is recorded in the vault
/// under the `send` request's action, for that session (`recordUserAction`, kind `message`); at the server's start each
/// held message is restored only when the vault vouches for its action with the digest of what it would type, for that
/// session, and only while the session lives; any other is dropped, said in the log. Once typed (or dropped) its action
/// is spent, so a copy put back in the file is never typed again. The vault's calls and the file's writes go one after
/// another on `heldWrites`, so an action is never spent before it was recorded.
extension Requests {
    /// One held message as the file keeps it.
    struct HeldEntry: Codable, Equatable {
        var message: String
        var text: String
        var images: [String]
        var at: Double
        var action: String
    }

    struct HeldFile: Codable, Equatable {
        var format = 1
        /// By the host's id for the session (its UUID, lowercased), in the order sent.
        var sessions: [String: [HeldEntry]] = [:]
    }

    /// `<root>/v2/held-sends.json`.
    static func heldURL(root: URL) -> URL { root.appendingPathComponent("v2", isDirectory: true).appendingPathComponent("held-sends.json") }

    /// What the vault records a held message's digest for: its session, as the node names it.
    static func heldSubject(_ hostID: UUID) -> String { "send " + NodeIds.session(host: hostID) }

    /// `held`, just held for the session `hostID`: its digest recorded in the vault, then the file written. On `queue`.
    func recordHeld(_ held: HeldSend, session hostID: UUID) {
        let (client, note, subject) = (link.vaultV2, note, Self.heldSubject(hostID))
        heldWrites.async {
            do { _ = try client.recordUserAction(held.action, kind: LeadVaultV2.messageKind, subject: subject, digest: LeadVaultV2.digest(held.message)) } catch {
                note("send: a held message wasn't recorded in the vault (\(error)): it isn't kept across a server restart")
            }
        }
        heldChanged()
    }

    /// The held messages of `actions` were typed or dropped: spent in the vault (after their record), and the file
    /// written. On `queue`.
    func heldGone(_ actions: [String]) {
        let client = link.vaultV2
        if !actions.isEmpty { heldWrites.async { try? client.spendUserActions(actions) } }
        heldChanged()
    }

    /// The file written as `heldSends` holds now, after what was asked before it. On `queue`.
    func heldChanged() {
        var file = HeldFile()
        for (id, list) in heldSends.values {
            guard id.hasPrefix(NodeIds.node + ":"), let host = UUID(uuidString: String(id.dropFirst(NodeIds.node.count + 1))) else { continue }
            file.sessions[host.uuidString.lowercased()] = list.map {
                HeldEntry(message: $0.message, text: $0.text, images: $0.images, at: $0.at.timeIntervalSince1970, action: $0.action)
            }
        }
        let (url, root, note) = (Self.heldURL(root: self.root), self.root, note)
        heldWrites.async {
            do {
                try VibePaths.ensurePrivate(url.deletingLastPathComponent(), within: root)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try VibePaths.writePrivate(try encoder.encode(file), to: url)
            } catch {
                note("send: \(url.path) not written (\(error)): the held messages aren't kept across a server restart")
            }
        }
    }

    /// The held messages the file keeps, restored at the server's first welcome: each only when the vault vouches for its
    /// action with the digest of the message its words and images make, for its session, and while that session lives;
    /// then typed in as any held one is (`pumpHeld`). Once. On `queue`.
    public func restoreHeldSends() {
        guard !heldRestored else { return }
        heldRestored = true
        let (url, client, queue) = (Self.heldURL(root: root), link.vaultV2, self.queue)
        heldWrites.async { [weak self] in
            guard let data = try? Data(contentsOf: url) else { return }
            guard let file = try? JSONDecoder().decode(HeldFile.self, from: data), file.format == 1 else {
                return queue.async { self?.note("send: \(url.path) doesn't read: its held messages are dropped"); self?.heldChanged() }
            }
            var vouched: [UUID: [HeldSend]] = [:]
            var dropped = 0
            for (key, entries) in file.sessions.sorted(by: { $0.key < $1.key }) {
                guard let host = UUID(uuidString: key) else { dropped += entries.count; continue }
                var seen: Set<String> = []
                for entry in entries {
                    let message = Self.message(text: entry.text, images: entry.images)
                    guard message == entry.message, seen.insert(entry.action).inserted,
                          (try? client.vouches(action: entry.action, digest: LeadVaultV2.digest(message), subject: Self.heldSubject(host))) == true else {
                        dropped += 1
                        continue
                    }
                    vouched[host, default: []].append(HeldSend(message: message, text: entry.text, images: entry.images,
                                                               at: Date(timeIntervalSince1970: entry.at), action: entry.action))
                }
            }
            queue.async {
                guard let self else { return }
                var restored = 0
                for (host, list) in vouched {
                    guard self.link.sessions.contains(where: { $0.id == host && $0.isLive }) else {
                        dropped += list.count
                        continue
                    }
                    let id = NodeIds.session(host: host)
                    self.heldSends.send(id, (self.heldSends.values[id] ?? []) + list)
                    restored += list.count
                    self.queue.asyncAfter(deadline: .now() + Self.heldEvery) { [weak self] in self?.pumpHeld(host) }
                }
                if restored + dropped > 0 {
                    self.note("send: \(restored) held message(s) kept across the restart"
                              + (dropped > 0 ? "; \(dropped) dropped (the vault doesn't vouch for them, or their session ended)" : ""))
                }
                self.heldChanged()
            }
        }
    }
}
