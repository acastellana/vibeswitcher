import Foundation
import Testing
@testable import VibeCore

struct SessionDigestTests {
    func tool(_ id: String, _ title: String, failed: Bool = false, output: String = "") -> ChatEvent {
        .entry(ChatEntry(id: id, at: nil, kind: .tool(ChatTool(id: id, name: "Bash", title: title, detail: .command(title), at: nil,
                                                               result: ChatResult(output: output, truncated: false, failed: failed, at: nil, images: [])))))
    }

    @Test func promptsRepliesAndToolRunsCondensed() {
        var log = ChatLog()
        log.append([.entry(ChatEntry(id: "p", at: nil, kind: .prompt(text: "Add login", images: []))),
                    tool("t1", "swift build"), tool("t2", "swift test", failed: true, output: "LoginTests failed: wrong password accepted\nmore"),
                    .entry(ChatEntry(id: "r", at: nil, kind: .reply("Login added; one test fails."))),
                    .entry(ChatEntry(id: "s", at: nil, kind: .steered(text: "use bcrypt", fromLead: false)))])
        let text = SessionDigest.text(log, limit: 10_000)
        #expect(text == """
        You: Add login
        [Ran 2 commands · 1 failed]
        ✕ swift test: LoginTests failed: wrong password accepted
        Agent: Login added; one test fails.
        You (while it worked): use bcrypt
        """)
    }

    @Test func theNewestPartIsKeptWhenItsTooLong() {
        var log = ChatLog()
        log.append((1...50).map { .entry(ChatEntry(id: "r\($0)", at: nil, kind: .reply("reply number \($0) " + String(repeating: "x", count: 100)))) })
        let text = SessionDigest.text(log, limit: 1000)
        #expect(text.count <= 1000)
        #expect(text.contains("reply number 50"))
        #expect(!text.contains("reply number 1 "))
        #expect(text.hasPrefix("[earlier part left out]"))
    }

    @Test func secretsInTheSessionStayOut() {
        var log = ChatLog()
        log.append([.entry(ChatEntry(id: "p", at: nil, kind: .prompt(text: "deploy --api-key=abc123 --env prod", images: [])))])
        let text = SessionDigest.text(log, limit: 10_000)
        #expect(!text.contains("abc123"))
        #expect(text.contains("--api-key=•••"))
    }
}

