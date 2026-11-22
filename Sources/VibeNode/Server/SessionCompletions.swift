import Foundation
import VibeCore

/// What a session's composer completes (the composer's lane, 2026-11-20): `/` to its agent's commands (the built-in
/// ones, the user's and the project's custom commands and skills: `SlashCatalog`, as the app's `loadCompletions` reads
/// them) and `@` to its folder's files (`FileIndex`: hidden files and build output left out). Each list is made off the
/// queue and kept `kept` seconds, so a page asking at each keystroke walks a folder once. Thread-safe.
final class SessionCompletions: @unchecked Sendable {
    /// How long a list is reused before it is made again (the app lists files again each time it's asked; a page asks
    /// at every keystroke).
    static let kept: TimeInterval = 30
    /// The most entries a cache keeps, of each kind.
    static let cachedLists = 16

    private let lock = NSLock()
    private var commands: [String: (at: Date, list: [SlashCommand])] = [:]
    private var files: [String: (at: Date, list: [String])] = [:]
    /// The folders being listed now: a page typing meanwhile gets the last list (or none), not another walk.
    private var listing: Set<String> = []

    /// The commands `/` offers in `folder` for `agent`, the user's from `home` (`~/.claude/commands`, `~/.claude/skills`,
    /// Codex's `~/.codex/prompts`). Reads the disk: never on the engine's queue.
    func commands(agent: Agent, folder: String, home: URL, now: Date = Platform.Clock.steadyDate()) -> [SlashCommand] {
        let key = "\(agent.rawValue)\n\(folder)\n\(home.path)"
        if let hit = lock.withLock({ commands[key] }), now.timeIntervalSince(hit.at) < Self.kept { return hit.list }
        var list: [SlashCommand]
        switch agent {
        case .claude:
            let place = URL(fileURLWithPath: folder, isDirectory: true)
            list = SlashCatalog.builtins(agent) + SlashCatalog.scan(
                commandDirs: [home.appendingPathComponent(".claude/commands"), place.appendingPathComponent(".claude/commands")],
                skillDirs: [home.appendingPathComponent(".claude/skills"), place.appendingPathComponent(".claude/skills")])
        case .codex:
            list = SlashCatalog.builtins(agent) + SlashCatalog.scan(commandDirs: [home.appendingPathComponent(".codex/prompts")], skillDirs: [])
                .map { SlashCommand(name: "prompts:\($0.name)", description: $0.description) }
        }
        lock.withLock { commands = Self.kept(commands, key, (now, list)) }
        return list
    }

    /// The files `@` offers in `folder`, relative to it: one walk of a folder at a time (asked meanwhile, the last
    /// list, or none). Reads the disk: never on the engine's queue.
    func files(in folder: String, now: Date = Platform.Clock.steadyDate()) -> [String] {
        let (hit, walk) = lock.withLock { () -> ((at: Date, list: [String])?, Bool) in
            let hit = files[folder]
            if let hit, now.timeIntervalSince(hit.at) < Self.kept { return (hit, false) }
            return (hit, listing.insert(folder).inserted)
        }
        guard walk else { return hit?.list ?? [] }
        let list = FileIndex.files(in: folder)
        lock.withLock {
            files = Self.kept(files, folder, (now, list))
            listing.remove(folder)
        }
        return list
    }

    /// `cache` with `value` for `key`, the oldest dropped past `cachedLists`.
    private static func kept<T>(_ cache: [String: (at: Date, list: T)], _ key: String, _ value: (at: Date, list: T)) -> [String: (at: Date, list: T)] {
        var cache = cache
        cache[key] = value
        while cache.count > cachedLists, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key { cache[oldest] = nil }
        return cache
    }

    /// A completion as the wire carries it: what replaces the token, and the row's title and subtitle.
    static func value(insert: String, title: String, subtitle: String) -> NodeWire.Value {
        .object(["insert": .string(insert), "title": .string(title), "subtitle": .string(subtitle)])
    }
}

extension Requests {
    /// The most completions a reply carries (the app's list shows 12).
    static let completionsLimit = 12

    /// `session.complete` with `session`, `kind` (`slash` or `mention`) and `query` (what follows the `/` or `@`), a read
    /// (the composer's lane, 2026-11-20): what the app's composer offers there (`SessionCompletions`), best first
    /// (`SlashCatalog.match`, `FileIndex.match`), at most `completionsLimit`, each with the text that replaces the token
    /// (`/name ` or `@path `). Only for a session the node's host runs with an agent in it (the only ones a page drafts
    /// for). Off the queue: the disk is read.
    func complete(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let kind = request.args?["kind"]?.string
        guard kind == "slash" || kind == "mention" else {
            return reply(.init(re: request.id, error: .init(.badArgs, "session.complete's kind is slash or mention")))
        }
        let query = request.args?["query"]?.string ?? ""
        guard query.count <= 200, !query.contains(where: \.isNewline) else {
            return reply(.init(re: request.id, error: .init(.badArgs, "session.complete's query is a word")))
        }
        let session: HostSession
        switch hostedSession(request.args?["session"]?.string, for: "session.complete", id: request.id) {
        case .failure(let refusal): return reply(refusal)
        case .found(let found): session = found
        }
        guard let agent = HostedAgents.agent(of: session) else {
            return reply(.init(re: request.id, error: .init(.refused, "a shell's composer completes nothing: it has no agent")))
        }
        let (queue, index, home) = (self.queue, completionIndex, URL(fileURLWithPath: self.home, isDirectory: true))
        DispatchQueue.global(qos: .userInitiated).async {
            let items: [NodeWire.Value]
            if kind == "slash" {
                items = SlashCatalog.match(query, in: index.commands(agent: agent, folder: session.cwd, home: home), limit: Self.completionsLimit).map {
                    SessionCompletions.value(insert: "/" + $0.name + " ", title: "/" + $0.name, subtitle: $0.description)
                }
            } else {
                items = FileIndex.match(query, in: index.files(in: session.cwd), limit: Self.completionsLimit).map {
                    SessionCompletions.value(insert: "@" + $0 + " ", title: ($0 as NSString).lastPathComponent, subtitle: $0)
                }
            }
            queue.async { reply(.init(re: request.id, result: .object(["items": .array(items)]))) }
        }
    }
}
