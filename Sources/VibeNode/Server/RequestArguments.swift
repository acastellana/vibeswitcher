import Foundation

/// The arguments each recorded kind (`Requests.recorded`: every state change in the user's voice, and `start`) takes:
/// one it doesn't know is refused `bad-args`, before the vault records anything (the architecture review's row 11,
/// 2026-11-22). Before, an unknown argument was ignored, so a command line newer than its server (right after a
/// switch) had an option it gave silently dropped: a `lead --goal` an older server didn't read would start the lead
/// with no goal. A key given as `null` is a key given. RequestKindsLint holds the table's kinds to `recorded`'s.
enum RequestArguments {
    /// Each recorded kind's keys: a typed kind's from its arguments' coding keys (`WireKinds.changes`, ChangeKinds.swift),
    /// so the table and the type can't drift; a kind not typed yet, from `untyped`.
    static let taken: [String: Set<String>] = untyped.merging(Dictionary(uniqueKeysWithValues: WireKinds.changes.map { ($0.kind, keys(of: $0)) })) { $1 }

    /// The recorded kinds not typed yet, and the keys each takes: the external plugins' (the plugins lane's, to follow
    /// the pattern; `WireKindsLintTests` holds the command line to sending every other kind through its type).
    static let untyped: [String: Set<String>] = [
        "plugin.add": ["folder", "manifest", "program"], "plugin.remove": ["plugin"],
    ]

    private static func keys<K: WireChangeKind>(of _: K.Type) -> Set<String> { K.Args.keys }

    /// `request`'s arguments read as its typed kind's (`WireKinds.changes`): `bad-args` naming the field when one is of
    /// the wrong form, before the vault records anything; nil when they are of their forms, or the kind isn't typed.
    static func formRefusal(_ request: NodeWire.Request) -> NodeWire.Reply? {
        guard let type = WireKinds.changes.first(where: { $0.kind == request.kind }) else { return nil }
        return formRefusal(request, as: type)
    }

    private static func formRefusal<K: WireChangeKind>(_ request: NodeWire.Request, as _: K.Type) -> NodeWire.Reply? {
        if case .failure(let failure) = request.typedArgs(K.Args.self) { return .init(re: request.id, error: failure) }
        return nil
    }

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
