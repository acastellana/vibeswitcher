import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// No chat item the node serves carries a URL's credentials (`ChatValue.value` through `PushText.scrub`): the lead's
/// push_remote reply, a command's output, a reply or a prompt quoting `https://someone:TOKEN@host/repo`, or a token in a
/// URL's query, reach a page without them; nothing else in the text changes.
struct ChatCredentialsTests {
    static let secret = "hunter2-token"

    /// The wire's items for transcript lines (`objects`), as the node serves them.
    func items(_ objects: [[String: Any]]) throws -> [NodeWire.Value] {
        var text = ""
        for object in objects { text += String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n" }
        var log = ChatLog()
        log.append(ChatReader.read(Data(text.utf8), format: .claude).events)
        return ChatValue.values(ChatTimeline.items(log.entries, newAfter: nil)).map(\.value)
    }

    @Test func aTranscriptQuotingACredentialURLReachesThePageWithoutIt() throws {
        let url = "https://someone:\(Self.secret)@example.invalid/repo.git"
        let reply = "Push request 3c9e1f20: main at c41d7e09, 1 commit ahead of origin/main, to \(url). Waiting for the user's click."
        let wire = try items([
            ["type": "user", "uuid": "u1", "timestamp": "2026-11-20T09:00:00.000Z", "message": ["role": "user", "content": "Push to \(url) please"]],
            ["type": "assistant", "uuid": "a1", "timestamp": "2026-11-20T09:00:01.000Z", "message": ["id": "m1", "role": "assistant", "content": [
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "git remote -v; curl 'https://example.invalid/api?access_token=\(Self.secret)&page=2'"]],
            ]]],
            ["type": "user", "uuid": "u2", "timestamp": "2026-11-20T09:00:02.000Z", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": "origin\t\(url) (fetch)\norigin\t\(url) (push)"],
            ]]],
            ["type": "assistant", "uuid": "a2", "timestamp": "2026-11-20T09:00:03.000Z", "message": ["id": "m2", "role": "assistant", "content": [
                ["type": "tool_use", "id": "t2", "name": "mcp__vibeswitcher__push_remote", "input": [:] as [String: Any]],
            ]]],
            ["type": "user", "uuid": "u3", "timestamp": "2026-11-20T09:00:04.000Z", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t2", "content": reply],
            ]]],
            ["type": "assistant", "uuid": "a3", "timestamp": "2026-11-20T09:00:05.000Z", "message": ["id": "m3", "role": "assistant", "content": [
                ["type": "text", "text": "Asked to push to \(url); mail me at someone@example.invalid, docs at https://example.invalid/guide?page=2#push"],
            ]]],
        ])
        let all = wire.map { String(decoding: NodeWire.line($0), as: UTF8.self) }.joined()
        #expect(!all.isEmpty && !all.contains(Self.secret), "\(all)")
        #expect(all.contains("https://example.invalid/repo.git"), "the URL stays, without its userinfo: \(all)")
        #expect(all.contains("access_token=…&page=2"), "a query token's value goes, the other parameters stay: \(all)")
        // Nothing else is rewritten: an address, an ordinary query and fragment.
        #expect(all.contains("someone@example.invalid") && all.contains("https://example.invalid/guide?page=2#push"), "\(all)")
    }

    @Test func theScrubTouchesOnlyCredentials() {
        #expect(PushText.scrub("no url here, a@b:c") == "no url here, a@b:c")
        #expect(PushText.scrub("see https://example.invalid/x?a=1&b=2") == "see https://example.invalid/x?a=1&b=2")
        #expect(PushText.scrub("git@example.invalid:r.git and ssh://git@example.invalid/r") == "git@example.invalid:r.git and ssh://example.invalid/r")
        #expect(PushText.scrub("https://x.invalid/?Token=\(Self.secret)#top") == "https://x.invalid/?Token=…#top")
        #expect(PushText.scrub("'https://\(Self.secret)@x.invalid/r' and http://u:p@y.invalid") == "'https://x.invalid/r' and http://y.invalid")
    }
}
