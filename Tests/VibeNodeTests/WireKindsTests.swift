import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The typed kinds (`WireKind`, the architecture review's row 11) on the wire: each reply the server wrote before the
/// types (Tests/Fixtures/wire-kinds, captured from a scratch node with a lead, a question, a board, held config and a
/// running agent) decodes into its kind's result and encodes again byte for byte, so a command line from before reads
/// today's replies as it did; an older server's reply, missing fields, still decodes; a newer server's extra field is
/// skipped; and the typed arguments refuse a value of the wrong form.
struct WireKindsTests {
    static let fixtures = ServerLintTests.repo.appendingPathComponent("Tests/Fixtures/wire-kinds")

    /// Each fixture, by the kind that answered it.
    static let replies: [(file: String, kind: String)] = [
        ("status", "status"), ("questions", "questions"), ("questions-all", "questions"), ("questions-folder", "questions"),
        ("board", "board"), ("board-folder", "board"), ("config.held", "config.held"), ("config.held-repo", "config.held"),
        ("settings", "settings"), ("settings-folder", "settings"), ("plugin.list", "plugin.list"), ("approve.list", "approve.list"),
        ("approve.list-config", "approve.list"),
        ("brief-folder", "brief"), ("update.check", "update.check"), ("update.check-problem", "update.check"), ("mail", "mail"),
        ("mail-folder", "mail"), ("mail-messages", "mail"), ("session.presets", "session.presets"), ("session.presets-values", "session.presets"),
        ("shells", "shells"), ("stats", "stats"), ("stats-today", "stats"), ("base.show", "base.show"),
    ]

    /// `result` (a fixture's) through `kind`'s type and back: the bytes the wire writes.
    static func roundTrip(_ result: NodeWire.Value, kind: String) throws -> Data {
        func again<K: WireKind>(_: K.Type) throws -> Data { NodeWire.line(try result.wire(K.Result.self)) }
        switch kind {
        case "status": return try again(WireKinds.Status.self)
        case "questions": return try again(WireKinds.Questions.self)
        case "board": return try again(WireKinds.Board.self)
        case "config.held": return try again(WireKinds.ConfigHeld.self)
        case "settings": return try again(WireKinds.Settings.self)
        case "plugin.list": return try again(WireKinds.PluginList.self)
        case "approve.list": return try again(WireKinds.ApproveList.self)
        case "brief": return try again(WireKinds.Brief.self)
        case "update.check": return try again(WireKinds.UpdateCheck.self)
        case "mail": return try again(WireKinds.Mail.self)
        case "session.presets": return try again(WireKinds.Presets.self)
        case "shells": return try again(WireKinds.Shells.self)
        case "stats": return try again(WireKinds.Stats.self)
        case "base.show": return try again(WireKinds.BaseShow.self)
        default: throw CocoaError(.featureUnsupported)
        }
    }

    @Test func eachCapturedReplyIsItsTypeByteForByte() throws {
        #expect(Set(Self.replies.map(\.kind)) == Set(WireKinds.typed), "a fixture for every typed kind")
        for (file, kind) in Self.replies {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(file + ".json"))
            let reply = try #require(NodeWire.decode(NodeWire.Reply.self, data), "\(file)")
            let result = try #require(reply.result, "\(file)")
            let before = NodeWire.line(result)
            let after = try Self.roundTrip(result, kind: kind)
            #expect(after == before, "\(file): \(String(decoding: after, as: UTF8.self).prefix(400))")
            // And the result's bytes as the server wrote them, inside its reply (the reply's own encoding is the same).
            #expect(String(decoding: data, as: UTF8.self).contains(String(decoding: before.dropLast(), as: UTF8.self)), "\(file)")
        }
    }

    /// The state-changing kinds' replies, captured from the whole VibeNodeTests run before their types (every shape each
    /// kind's replies had, Tests/Fixtures/wire-kinds/changes): each decodes into its kind's result and encodes again byte
    /// for byte; every typed change kind has one.
    @Test func eachCapturedChangeReplyIsItsTypeByteForByte() throws {
        let folder = Self.fixtures.appendingPathComponent("changes")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }.sorted()
        func again<K: WireKind>(_: K.Type, _ result: NodeWire.Value) throws -> Data { NodeWire.line(try result.wire(K.Result.self)) }
        var covered: Swift.Set<String> = []
        for file in files {
            let kind = String(file.dropLast(".json".count).split(separator: "-").dropLast().joined(separator: "-"))
            let type = try #require(WireKinds.changes.first { $0.kind == kind }, "\(file): no typed kind \(kind)")
            let reply = try #require(NodeWire.decode(NodeWire.Reply.self, try Data(contentsOf: folder.appendingPathComponent(file))), "\(file)")
            let result = try #require(reply.result, "\(file)")
            let after = try again(type, result)
            #expect(after == NodeWire.line(result), "\(file): \(String(decoding: after, as: UTF8.self).prefix(400))")
            covered.insert(kind)
        }
        #expect(covered == Swift.Set(WireKinds.changes.map { $0.kind }), "\(Swift.Set(WireKinds.changes.map { $0.kind }).subtracting(covered))")
    }

    /// An older server's reply (fields it didn't have yet) decodes, the missing ones nil; a newer one's field the type
    /// doesn't name is skipped.
    @Test func resultsAreReadWhateverTheServersAge() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("status.json"))
        guard case .object(var fields) = try #require(NodeWire.decode(NodeWire.Reply.self, data)?.result) else { Issue.record("no object"); return }
        for older in ["switchBlockers", "switchParks", "plugins", "reminders", "health", "builds", "ending", "boost"] { fields[older] = nil }
        fields["fromTheFuture"] = .object(["x": .int(1)])
        let status = try NodeWire.Value.object(fields).wire(WireKinds.Status.Result.self)
        #expect(status.switchBlockers == nil && status.builds == nil && status.plugins == nil)
        #expect(status.server?.pid != nil && status.host?.notes?.build != nil && status.epoch != nil)
        let questions = try NodeWire.Value.object([:]).wire(WireKinds.Questions.Result.self)
        #expect(questions.cards == nil && questions.more == nil)
    }

    /// A null the server writes is written again as null (`@WireNull`), a key it leaves out left out.
    @Test func nullsAndAbsencesAreKept() throws {
        var status = WireKinds.Status.Result()
        status.host = .init(startedAt: nil, pid: nil, state: "connecting", liveSessions: 0, notes: nil)
        let text = String(decoding: NodeWire.line(status), as: UTF8.self)
        #expect(text.contains(#""builds":null"#) && text.contains(#""restart":null"#) && text.contains(#""usage":null"#) && text.contains(#""boost":null"#))
        #expect(text.contains(#""notes":null"#) && text.contains(#""pid":null"#))
        #expect(!text.contains("webTailnet") && !text.contains("health") && !text.contains("update"), "\(text)")
    }

    /// A read kind's arguments are typed: a value of the wrong form is `bad-args`, naming the field; an unknown one is
    /// skipped (a read changes nothing).
    @Test func typedArgumentsRefuseAWrongForm() {
        let wrong = NodeWire.Request(id: "1", kind: "questions", args: ["all": .string("yes")])
        guard case .failure(let failure) = wrong.typedArgs(WireKinds.Questions.Args.self) else { Issue.record("taken"); return }
        #expect(failure.code == "bad-args" && failure.message.contains("all"), "\(failure)")
        let extra = NodeWire.Request(id: "2", kind: "board", args: ["folder": .string("/x"), "later": .bool(true)])
        #expect(extra.typedArgs(WireKinds.Board.Args.self).taken?.folder == "/x")
        #expect(NodeWire.Request(id: "3", kind: "status").typedArgs(WireKinds.Status.Args.self).taken == WireNoArgs())
    }
}

/// The command line reads a typed kind (`WireKinds.typed`) only through its type (`NodeClient.read`) and sends a typed
/// state change (`WireKinds.changes`) only through its (`NodeClient.change(Kind.self, …)`): a `request("<kind>"`,
/// `change("<kind>"` or `act("<kind>"` of one in Sources/vibeswitcher-cli, which would read or send it by string key,
/// fails here; so does any `client.request(` or `client.change(` not naming a kind's type (or the generic helpers' `K`),
/// outside NodeClient itself.
struct WireKindsLintTests {
    @Test func theCommandLineReadsAndSendsTypedKindsThroughTheirTypes() throws {
        let folder = ServerLintTests.repo.appendingPathComponent("Sources/vibeswitcher-cli")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }.sorted()
        #expect(!files.isEmpty)
        let kinds = WireKinds.typed + WireKinds.changes.map { $0.kind }
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let place = "Sources/vibeswitcher-cli/\(file):\(number + 1)"
                for kind in kinds where ["request", "change", "act"].contains(where: { line.contains("\($0)(\"\(kind)\"") }) {
                    found.append("\(place): \(kind) by string key; ask it with client.read or send it with client.change(WireKinds.…)")
                }
                guard file != "NodeClient.swift", !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                // A kind left out on purpose (`WireKinds.leftOut`) may be asked or sent by name; nothing else is.
                let leftOut = WireKinds.leftOut.contains { line.contains("\"\($0)\"") }
                if line.contains("client.request("), !leftOut { found.append("\(place): a read not through its type (client.read(WireKinds.…))") }
                // `K.self`: the generic helpers' (`CardCommand.act`, `SessionCommand.act`), over a `WireChangeKind`; `kind`: the
                // one for the kinds left out (`SessionCommand.act`'s by name, which refuses any other).
                if line.contains("client.change("), !line.contains("client.change(WireKinds."), !line.contains("client.change(K.self"),
                   !(file == "Sessions.swift" && line.contains("client.change(kind,")), !leftOut {
                    found.append("\(place): a state change not through its type (client.change(WireKinds.…))")
                }
                if line.contains("act(\""), !leftOut { found.append("\(place): act by name for a kind that isn't left out (WireKinds.leftOut)") }
            }
        }
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    }

    /// The kinds left out are none of the typed ones, and every recorded kind is typed or left out.
    @Test func everyKindIsTypedOrLeftOut() {
        let typed = Swift.Set(WireKinds.typed + WireKinds.changes.map { $0.kind })
        #expect(typed.isDisjoint(with: WireKinds.leftOut))
        #expect(Requests.recorded.subtracting(typed).isSubset(of: WireKinds.leftOut), "\(Requests.recorded.subtracting(typed).subtracting(WireKinds.leftOut))")
        #expect(Swift.Set(RequestArguments.untyped.keys).isSubset(of: WireKinds.leftOut))
    }

    /// A typed state change's keys are its arguments' (`WireArgs.keys`): `RequestArguments` refuses any other, naming it.
    @Test func aTypedChangeTakesItsArgumentsKeysAndNoOther() throws {
        func keys<K: WireChangeKind>(_: K.Type) -> Swift.Set<String> { K.Args.keys }
        for kind in WireKinds.changes { #expect(RequestArguments.taken[kind.kind] == keys(kind), "\(kind.kind)") }
        #expect(RequestArguments.taken["lead"] == ["folder", "goal", "takeHead", "replace", "resume", "initialized"])
        let refused = try #require(RequestArguments.refusal(.init(id: "1", kind: "tell", args: ["folder": .string("/p"), "txet": .string("x")], action: "a")))
        #expect(refused.error?.code == "bad-args" && refused.error?.message.contains("tell doesn't take txet") == true, "\(refused)")
        // A key of the wrong form: refused naming it, before the vault records anything.
        let wrong = try #require(RequestArguments.formRefusal(.init(id: "2", kind: "session.pause", args: ["session": .string("s"), "hours": .string("2")], action: "a")))
        #expect(wrong.error?.code == "bad-args" && wrong.error?.message.contains("hours") == true, "\(wrong)")
        #expect(RequestArguments.formRefusal(.init(id: "3", kind: "session.pause", args: ["session": .string("s"), "for": .string("off")], action: "a")) == nil)
    }
}

/// The server's replies, built from the types, keep the keys the captured ones have (a scratch node).
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct WireKindsServerTests {
    private let scratch = Scratch()

    @Test func theServersRepliesHaveTheCapturedKeys() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let client = try WireClient(node)
        func keys(_ value: NodeWire.Value?) -> Set<String> { Set(value?.object?.keys.map { $0 } ?? []) }
        for (file, kind) in [("status", "status"), ("settings", "settings"), ("plugin.list", "plugin.list"), ("questions", "questions"), ("board", "board"),
                             ("shells", "shells"), ("session.presets", "session.presets"), ("stats", "stats")] {
            let reply = try #require(WireClient.reply(client.request(kind, action: nil)), "\(kind)")
            let captured = try Data(contentsOf: WireKindsTests.fixtures.appendingPathComponent(file + ".json"))
            let before = try #require(NodeWire.decode(NodeWire.Reply.self, captured)?.result)
            #expect(reply.ok && keys(reply.result) == keys(before), "\(kind): \(keys(reply.result).symmetricDifference(keys(before)))")
            if kind == "status" {
                #expect(keys(reply.result?["host"]) == keys(before["host"]) && keys(reply.result?["server"]) == keys(before["server"]))
                #expect(keys(reply.result?["host"]?["notes"]) == keys(before["host"]?["notes"]), "\(String(describing: reply.result?["host"]))")
            }
        }
    }
}
