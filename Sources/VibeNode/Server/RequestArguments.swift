import Foundation

/// The arguments each recorded kind (`Requests.recorded`: every state change in the user's voice, and `start`) takes:
/// one it doesn't know is refused `bad-args`, before the vault records anything (the architecture review's row 11,
/// 2026-11-22). Before, an unknown argument was ignored, so a command line newer than its server (right after a
/// switch) had an option it gave silently dropped: a `lead --goal` an older server didn't read would start the lead
/// with no goal. A key given as `null` is a key given. RequestKindsLint holds the table's kinds to `recorded`'s.
enum RequestArguments {
    static let taken: [String: Set<String>] = [
        "start": [],
        "stop": [],
        "lead": ["folder", "goal", "takeHead", "replace", "resume"],
        // A card's: its id and code (`cardRefusal`); an answer's text and the wording's version it answered.
        "answer": ["card", "code", "text", "version"],
        "hold": ["card", "code"],
        // `batch`: an accept that `approve`'s batch makes (`ApproveRequest`).
        "config.accept": ["card", "code", "batch"],
        "base.accept": ["card", "code"],
        "base.keep": ["card", "code"],
        "hooks.install": ["agents"],
        "hooks.remove": ["agents"],
        "build.switch": ["commit"],
        "web.open": ["tailnet"],
        "web.revoke": [],
        "tell": ["folder", "text"],
        "send": ["session", "text", "images", "now"],
        "session.new": ["folder", "preset", "digest", "agent", "model"],
        "session.end": ["session"],
        // Bound to the question shown: its wording and options, checked against the screen's.
        "session.reply": ["session", "choice", "text", "question", "options"],
        "set": ["key", "value", "folder"],
        "push": ["folder", "request"],
        "push.decline": ["folder", "request"],
        "session.reopen": ["forget", "all", "sessions"],
        "prompt-audit": ["folder", "do"],
        "session.rename": ["session", "name"],
        "session.pause": ["session", "for", "hours"],
        "session.resume": ["session"],
        "session.close-shells": ["sessions"],
        "presets.edit": ["op", "name", "folder", "digest", "rename", "kind", "args", "env", "unset", "keepShell", "default"],
        "approve": ["batch", "code"],
        // A feature plugin turned on or off (`PluginRequests`).
        "plugin.on": ["plugin"], "plugin.off": ["plugin"],
    ]

    /// `request`'s `bad-args` refusal when it gives an argument its kind doesn't take; nil when it gives none (or its
    /// kind isn't in the table: a read's arguments aren't checked here).
    static func refusal(_ request: NodeWire.Request) -> NodeWire.Reply? {
        guard let known = taken[request.kind], let given = request.args?.keys else { return nil }
        let unknown = given.filter { !known.contains($0) }.sorted()
        guard !unknown.isEmpty else { return nil }
        let names = unknown.prefix(5).map { String($0.prefix(40)) }.joined(separator: ", ")
        let takes = known.isEmpty ? "it takes none" : "it takes \(known.sorted().joined(separator: ", "))"
        return .init(re: request.id, error: .init(.badArgs, "\(request.kind) doesn't take \(names) (\(takes)): "
                                                    + "the server may run an older build than this command line: restart or switch to use its new options"))
    }
}
