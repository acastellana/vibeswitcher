import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// An independent security read of acting from the page (8a28a36d, the web UI design's "Acting from the page"), from the
/// attacker's side: a hosted agent session of the user's uid (it reads and writes the files the sandbox leaves open,
/// opens 127.0.0.1, signals the user's processes) trying to get one user's-voice act done without the user's click. Each
/// case drives the real gate (`WebAccess` with `ActingPages` on a vault in memory), the real screen and the node's
/// listener from a raw TCP client, so the agent sends whatever headers it likes.
///
/// What holds: the token file buys a reading page, never an acting one; a page paired before acting was on never acts.
/// What doesn't (the findings): an acting token is a bearer credential any local process uses with no browser; whoever
/// redeems a pairing code first, while acting is on, gets an acting page; any reading page watches every hosted
/// terminal, where `vibeswitcher web` prints its code when the user runs it in one.
@Suite(.timeLimit(.minutes(5)))
struct ActingAttackTests {
    private let scratch = Scratch()

    /// The loopback page's gate and screen as `NodeLive` wires them, acting on a vault in memory, every request that
    /// reaches the acting path (`onPageVoice`) recorded instead of acted on.
    final class Rig: @unchecked Sendable {
        let vault = MemoryVaultV2()
        let access: WebAccess
        let acting: ActingPages
        let listener: WebListenerUnderTest
        let reached = Locked<[(kind: String, token: String)]>([])
        let now = Date()
        let root: URL

        init(_ scratch: Scratch, root: URL? = nil) throws {
            let root = root ?? scratch.url("acting-root")
            self.root = root
            let now = self.now
            access = WebAccess(tokens: WebTokens(root: root), now: { now })
            acting = ActingPages(vault: vault.client)
            access.acting = acting
            let screen = WebRequestScreen(RecordingHandler())
            let reached = self.reached
            screen.onPageVoice = { request, token, transport in
                reached.mutate { $0.append((request.kind, token)) }
                transport.send(NodeWire.message(NodeWire.Reply(re: request.id, result: .object(["acted": .bool(true)]))))
            }
            listener = try WebSecurityRig.listener(gate: access, handler: screen, clock: WebTestTime(), note: { _ in })
        }

        var port: UInt16 { listener.port }

        /// A client of the agent's own: the page's Host and Origin forged (a process, not a browser, sends what it likes).
        func agentClient() throws -> RawClient {
            let client = try RawClient(port: port)
            let status = try client.upgrade(host: "127.0.0.1:\(port)", origin: "http://127.0.0.1:\(port)")
            guard status == 101 else { throw RawClient.Failure("the upgrade was answered \(status)") }
            return client
        }

        /// `auth` with `credential` (`"pair"` or `"token"`): the hello's rights, and the token it gave (a pairing's).
        func auth(_ client: RawClient, _ key: String, _ value: String) throws -> (rights: [String], token: String?) {
            try client.sendText(#"{"v":1,"id":"0","kind":"auth","args":{"\#(key)":"\#(value)","client":"webapp"}}"#)
            let hello = try client.nextFrame()?.json
            return ((hello?["auth"]?["rights"]?.array ?? []).compactMap(\.string), hello?["auth"]?["token"]?.string)
        }

        /// A user's kind sent on `client`: whether it reached the acting path (its reply says so), else the refusal's code.
        func act(_ client: RawClient, _ kind: String, id: String = "9") throws -> String {
            try client.sendText(#"{"v":1,"id":"\#(id)","kind":"\#(kind)","args":{"key":"ai_summaries","value":"off"},"action":"\#(UUID().uuidString.lowercased())"}"#)
            let reply = try client.nextFrame()?.json
            if reply?["result"]?["acted"]?.bool == true { return "acted" }
            return reply?["error"]?["code"]?.string ?? "no reply"
        }

        func stop() { listener.stop() }
    }

    // MARK: What holds

    /// Attempt: the agent writes its own token's SHA-256 into `<root>/v2/web-tokens.json` (0600, but the user's: any of
    /// its processes may) and has the server read it again (it can end the server, which the host starts again in a
    /// second). The token is taken: a page that reads and drafts. It never acts, `web_acts` on or not: acting is the
    /// vault's list, which only a pairing writes.
    @Test func aTokenTheAgentWritesIntoTheFileReadsButNeverActs() throws {
        let root = scratch.url("acting-root")
        let forged = "a-token-the-agent-chose-for-itself-0123456789"
        let file = root.appendingPathComponent("v2/web-tokens.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Its own end, a year off: the file's dates are taken as written (no cap at a token's life).
        let entry = #"{"format":1,"tokens":[{"sha256":"\#(ActingPages.digest(forged))","issuedAt":"2026-11-24T00:00:00.000Z","expiresAt":"2027-11-24T00:00:00.000Z"}]}"#
        try Data(entry.utf8).write(to: file)
        let rig = try Rig(scratch, root: root)
        defer { rig.stop() }
        _ = try rig.vault.client.setPageActs(on: true)
        let client = try rig.agentClient()
        let (rights, _) = try rig.auth(client, "token", forged)
        #expect(rights == ["read", "draft"], "a forged token is taken, reading and drafting: \(rights)")
        #expect(try rig.act(client, "set") == "voice", "it never acts")
        #expect(rig.reached.value.isEmpty)
    }

    /// Attempt: a token from a pairing made while acting was off, then acting turned on: it never acts.
    @Test func aPagePairedBeforeActingWasOnNeverActs() throws {
        let rig = try Rig(scratch)
        defer { rig.stop() }
        let first = try rig.agentClient()
        let (rights, token) = try rig.auth(first, "pair", rig.access.openCode(now: rig.now))
        #expect(rights == ["read", "draft"])
        _ = try rig.vault.client.setPageActs(on: true)
        let again = try rig.agentClient()
        #expect(try rig.auth(again, "token", try #require(token)).rights == ["read", "draft"])
        #expect(try rig.act(again, "set") == "voice")
    }

    // MARK: The findings

    /// Finding 1 (as decided, but wider than a browser): an acting token is a bearer credential. The listener's Host,
    /// Origin and Sec-Fetch-Site checks keep other sites' pages out of the user's browser, but a process sends any
    /// headers: whoever holds the token (read from the browser's profile on disk, where Chromium keeps a tab's
    /// sessionStorage, the page's `vibeswitcher.token`, and Firefox its session; or from a page's memory) acts from a
    /// socket of its own, with no browser and nothing to tell it from the user's tab.
    @Test func anActingTokenActsFromAnyLocalProcessWithNoBrowser() throws {
        let rig = try Rig(scratch)
        defer { rig.stop() }
        _ = try rig.vault.client.setPageActs(on: true)
        // The user's browser pairs, as `vibeswitcher web`'s address has it do: an acting page.
        let browser = try rig.agentClient()
        let (rights, issued) = try rig.auth(browser, "pair", rig.access.openCode(now: rig.now))
        #expect(rights == ["read", "draft", "act"])
        let token = try #require(issued)
        // The agent, with the token copied out of the browser's storage: its own socket, forged headers, the user's act.
        let agent = try rig.agentClient()
        #expect(try rig.auth(agent, "token", token).rights == ["read", "draft", "act"])
        #expect(try rig.act(agent, "set") == "acted", "a user's act from the agent's own socket")
        #expect(rig.reached.value.map(\.kind) == ["set"])
    }

    /// Finding 2: while acting is on, whoever redeems a pairing code first gets the acting page; the user's browser,
    /// coming second, is refused and simply asks for another address. The code is in the address `vibeswitcher web`
    /// prints: wherever the agent reads that output (a hosted terminal: finding 3; a Claude Code `!` command's transcript
    /// in ~/.claude), it wins the race of a human opening a link.
    @Test func whoeverRedeemsTheCodeFirstGetsTheActingPage() throws {
        let rig = try Rig(scratch)
        defer { rig.stop() }
        _ = try rig.vault.client.setPageActs(on: true)
        let code = rig.access.openCode(now: rig.now)
        let agent = try rig.agentClient()
        #expect(try rig.auth(agent, "pair", code).rights == ["read", "draft", "act"], "the agent's page acts")
        let browser = try rig.agentClient()
        try browser.sendText(#"{"v":1,"id":"0","kind":"auth","args":{"pair":"\#(code)","client":"webapp"}}"#)
        #expect(try browser.nextFrame()?.json?["code"]?.string == "auth", "the user's own browser is turned away")
        #expect(try rig.act(agent, "set") == "acted")
    }

    /// Finding 3: any page that reads may watch every hosted session's terminal (`term.open`, `.read` alone), and the
    /// token file gives the agent such a page (above). So when the user runs `vibeswitcher web` in a terminal the node
    /// hosts (a `vs new --agent shell` shell, a page's terminal), the agent watching it reads the pairing address and
    /// redeems it first (finding 2): an acting page, with no click and no code of the user's.
    @Test func aReadingPageMayWatchEveryHostedTerminal() {
        let reading = Principal.page([.read, .draft], terminals: true)
        #expect(reading.route("term.open") == .terminal, "a reading page's term.open goes to the terminal relay")
        // The relay asks nothing more of it (TerminalRelay.open: `.read`, then any session the host runs).
    }

    /// Finding 4 (low): an acting page may set guard rails that are a project's merge gate as the user's
    /// (`security_audit_model`, `max_workers`), which `pageSetRefusal`'s own reason ("a worker's token would lower what
    /// holds its own merge") argues against, while `policy` and the floors are refused.
    @Test func anActingPageMaySetGuardRailsBesidesTheFloors() {
        func refusal(_ key: String) -> String? {
            Requests.pageSetRefusal(.init(id: "1", kind: "set", args: ["key": .string(key), "value": .string("x")], action: "a"))
        }
        #expect(refusal("floor_merge_policy") != nil && refusal("policy") != nil && refusal("web_acts") != nil)
        #expect(refusal("security_audit_model") == nil, "the sensitive audit's model, set from a page")
        #expect(refusal("max_workers") == nil)
    }
}
