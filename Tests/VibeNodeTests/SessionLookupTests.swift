import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// A command line's SESSION (`SessionLookup`, every command that takes one): the node's id, the terminal name `status`
/// prints (or its device path), or a host id's prefix only one has; a name two sessions answer to is refused, naming them.
struct SessionLookupTests {
    private func session(_ uuid: String, terminal: String?, hosted: Bool = true) -> NodeWire.Value {
        var fields: [String: NodeWire.Value] = ["id": .string("\(NodeIds.node):\(uuid)"), "hosted": .bool(hosted)]
        if let terminal { fields["terminal"] = .string(terminal) }
        return .object(fields)
    }

    private let a = "3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f", b = "3f6c9999-1111-4222-8333-444455556666", c = "a1b2c3d4-0000-4000-8000-000000000000"
    private var sessions: [NodeWire.Value] { [session(a, terminal: "ttypts4"), session(b, terminal: "ttypts7"), session(c, terminal: "ttypts4", hosted: false)] }

    private func found(_ wanted: String) -> String? { try? SessionLookup.match(wanted, in: sessions).get()["id"]?.string }

    @Test func anIdATerminalOrAUniquePrefixNamesOne() {
        #expect(found("\(NodeIds.node):\(a)") == "\(NodeIds.node):\(a)")
        #expect(found(a.uppercased()) == "\(NodeIds.node):\(a)")
        #expect(found("ttypts7") == "\(NodeIds.node):\(b)")
        #expect(found("pts/7") == "\(NodeIds.node):\(b)")
        #expect(found("/dev/pts/7") == "\(NodeIds.node):\(b)")
        #expect(found("3f6c2c") == "\(NodeIds.node):\(a)")
        // A prefix names only a session the host runs.
        #expect(found("a1b2c3") == nil)
    }

    @Test func aNameTwoAnswerToIsRefusedNamingThem() throws {
        guard case .failure(let refusal) = SessionLookup.match("ttypts4", in: sessions) else { Issue.record("ttypts4 matched one"); return }
        #expect(refusal.description.contains("names 2 sessions") && refusal.description.contains(a) && refusal.description.contains(c), "\(refusal)")
        guard case .failure(let prefix) = SessionLookup.match("3f6c", in: sessions) else { Issue.record("3f6c matched one"); return }
        #expect(prefix.description.contains(a) && prefix.description.contains(b), "\(prefix)")
        guard case .failure(let none) = SessionLookup.match("ttypts9", in: sessions) else { Issue.record("ttypts9 matched"); return }
        #expect(none.description.contains("no session ttypts9"))
        // What a refusal names is shown inert.
        guard case .failure(let odd) = SessionLookup.match("\u{1B}[2Jx", in: sessions) else { Issue.record("matched"); return }
        #expect(!odd.description.contains("\u{1B}"))
    }

    /// `resume` and `reopen` find an ended or offered session by its id the same way (they have no terminal).
    /// Last, the name you gave a session (`rename`), whole and case aside; two of one name are refused, naming them;
    /// an id, a terminal or a prefix wins over a name.
    @Test func theNameYouGaveOneNamesIt() throws {
        func named(_ uuid: String, _ name: String, terminal: String) -> NodeWire.Value {
            guard case .object(var fields) = session(uuid, terminal: terminal) else { return .null }
            fields["name"] = .string(name)
            return .object(fields)
        }
        let list = [named(a, "Release notes", terminal: "ttypts4"), named(b, "Fix login", terminal: "ttypts7"), named(c, "fix login", terminal: "ttypts9")]
        #expect(try SessionLookup.match("release NOTES", in: list).get()["id"]?.string == "\(NodeIds.node):\(a)")
        guard case .failure(let two) = SessionLookup.match("Fix login", in: list) else { Issue.record("matched one"); return }
        #expect(two.ambiguous && two.description.contains(b) && two.description.contains(c), "\(two)")
        #expect((try? SessionLookup.match("Release", in: list).get()) == nil, "a part of a name isn't it")
        let shadow = [named(a, "ttypts7", terminal: "ttypts4"), named(b, "x", terminal: "ttypts7")]
        #expect(try SessionLookup.match("ttypts7", in: shadow).get()["id"]?.string == "\(NodeIds.node):\(b)", "a terminal wins over a name")
    }

    @Test func endedSessionsAreFoundByTheirIds() throws {
        let ended: [NodeWire.Value] = [.object(["session": .string("\(NodeIds.node):\(a)")]), .object(["session": .string("\(NodeIds.node):\(c)")])]
        let match = SessionLookup.match("a1b2", in: ended, idKey: "session", hostedOnly: false, noun: "ended session")
        #expect((try? match.get())?["session"]?.string == "\(NodeIds.node):\(c)")
        guard case .failure(let none) = SessionLookup.match("ffff", in: ended, idKey: "session", hostedOnly: false, noun: "ended session") else { return }
        #expect(none.description.contains("no ended session ffff"))
    }
}
