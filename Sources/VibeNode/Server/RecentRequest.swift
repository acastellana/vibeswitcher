import Foundation
import VibeCore

/// The start page's recent projects (the parity table's start page row; the app's `Launcher.recentProjects` and
/// `StartPage`): the folders Claude Code knows (`~/.claude.json`'s `projects`, its keys only, ranked by when each one's
/// transcripts folder last changed) and Codex trusts (`~/.codex/config.toml`'s `[projects."…"]`), in the node's home,
/// newest first, folders gone and the home itself left out (`RecentProjects.rank`), each with the project of the lead
/// that runs there, if one does. `recent` is a read of the user's own (`NodeWire.Voice.webRead`: the user's on the socket, or a page's token that
/// reads; never a session's process, which would list the user's other projects); the page drafts the line that starts each (`vibeswitcher new FOLDER`, `vibeswitcher lead FOLDER`), never
/// starts one. Nothing else of those files is read (no account, no history), and nothing is written.
extension Requests {
    /// The most folders `recent` gives.
    static let recentShown = 12

    func recent(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let home = self.home
        let leads = Dictionary((engine?.leads.leads.values.map { ($0.root, $0.project) } ?? []), uniquingKeysWith: { first, _ in first })
        let queue = self.queue
        (engine?.work ?? DispatchQueue.global(qos: .userInitiated)).async {
            let projects = NodeRecent.projects(home: home, limit: Self.recentShown).map { candidate -> NodeWire.Value in
                .object(["folder": .string(candidate.path), "lastUsed": candidate.lastUsed == .distantPast ? .null : .date(candidate.lastUsed),
                         "lead": leads[candidate.path].map(NodeWire.Value.string) ?? .null])
            }
            queue.async { reply(.init(re: request.id, result: .object(["projects": .array(projects)]))) }
        }
    }
}

/// The recent project folders of a node's home (the app's `Launcher.recentProjects`, without the app's own observed
/// list: the page adds the node's sessions' folders itself).
public enum NodeRecent {
    /// The largest `~/.claude.json` read (it holds every project's settings and a little history).
    static let mostBytes = 16 << 20

    public static func projects(home: String, limit: Int = 12, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> [RecentProjects.Candidate] {
        var candidates: [RecentProjects.Candidate] = []
        let config = URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
        if let size = (try? FileManager.default.attributesOfItem(atPath: config.path))?[.size] as? NSNumber, size.intValue <= mostBytes,
           let data = try? Data(contentsOf: config),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let projects = json["projects"] as? [String: Any] {
            let transcripts = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
            for path in projects.keys where path.hasPrefix("/") {
                let folder = transcripts.appendingPathComponent(RecentProjects.claudeSlug(for: path))
                let modified = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date ?? .distantPast
                candidates.append(.init(path: path, lastUsed: modified))
            }
        }
        let codex = URL(fileURLWithPath: home).appendingPathComponent(".codex/config.toml")
        if let toml = try? String(contentsOf: codex, encoding: .utf8) {
            candidates += RecentProjects.codexProjects(fromConfig: toml).filter { $0.hasPrefix("/") }.map { .init(path: $0, lastUsed: .distantPast) }
        }
        return RecentProjects.rank(candidates, home: home, limit: limit, exists: exists)
    }
}
