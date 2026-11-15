import Foundation
import Testing
@testable import VibeNode

/// The node's ids (the engine plan's EN-D4) and typed codes (EN-D5).
struct NodeIdsTests {
    @Test func aProjectIdIsStableAndHoldsNoPath() {
        let id = NodeIds.project(root: "/home/someone/projects/app")
        #expect(NodeIds.project(root: "/home/someone/projects/app/") == id)
        #expect(NodeIds.project(root: "/home/someone/projects/other/../app") == id)
        #expect(NodeIds.project(root: "/home/someone/projects/./app") == id)
        #expect(NodeIds.project(root: "/home/someone/projects/app2") != id)
        #expect(!id.contains("/") && !id.contains("app") && !id.contains("someone"), "\(id)")
        // The phone's rule (`PhoneLeads.id(root:)`): 9 bytes, base64url, 12 characters.
        #expect(id.hasPrefix("local:project:") && id.dropFirst("local:project:".count).count == 12, "\(id)")
    }

    @Test func everyIdCarriesItsNode() {
        let host = UUID()
        let ids = [NodeIds.project(root: "/home/someone/x"), NodeIds.session(host: host), NodeIds.session(terminal: "ttypts3"), NodeIds.card()]
        for id in ids { #expect(id.hasPrefix("local:"), "\(id)") }
        #expect(NodeIds.session(host: host) == "local:" + host.uuidString.lowercased())
        // An unhosted session's id is stage 1's.
        #expect(NodeIds.session(terminal: "ttypts3") == LocalSession(terminal: "ttypts3", agent: .claude, pid: 1, cwd: nil,
                                                                     status: .unknown, since: Date()).id)
        #expect(NodeIds.card().hasPrefix("local:card:") && NodeIds.card() != NodeIds.card())
    }

    @Test func aCodeIsFourLettersFixedByItsIdAndKind() {
        let card = NodeIds.card()
        let code = NodeIds.code(card: card)
        #expect(code.count == 4 && code.allSatisfy { NodeIds.codeLetters.contains($0) }, "\(code)")
        #expect(NodeIds.code(card: card) == code)
        // A card's code and an action's are made apart: the same text gives each its own.
        let action = UUID().uuidString
        let codes = Set((0..<64).map { _ in NodeIds.code(card: NodeIds.card()) })
        #expect(codes.count > 32, "64 cards share \(codes.count) codes")
        #expect(NodeIds.code(action: action).count == 4)
        let same = (0..<16).map { _ in UUID().uuidString }.filter { NodeIds.code(action: $0) == NodeIds.code(card: $0) }
        #expect(same.count < 4, "\(same.count) of 16 ids gave the same code as a card and as an action")
    }
}
