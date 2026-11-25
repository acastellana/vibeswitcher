import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The attacker's cases against acting from the page (the second security review of 8a28a36d, branch v2-acting-review),
/// each turned into a test that the attack now fails. The attacker is a hosted agent session of the user's uid: it reads
/// and writes the files the sandbox leaves open, opens 127.0.0.1 with whatever headers it likes, watches what a reading
/// page may watch, and signals the user's processes. Each case drives the real gate (`WebAccess` with `ActingPages` on a
/// vault in memory, its tokens the vault's), the real screen, and the node's listener from a raw TCP client.
///
/// The chain the review found: (a) a token written into web-tokens.json (the server killed, the host restarts it, it
/// reads the file again) gave a reading page; (b) a reading page watched every hosted terminal, replay and all, so it
/// read `#pair=<code>` when the user ran `vibeswitcher web` in one (or a transcript, run via `!`); (c) whoever redeemed
/// the code first got the acting page. Now: (a) a token the vault doesn't know isn't admitted; (b) watching needs a
/// pairing confirmed in the terminal, and no page is ever served a live code; (c) redeeming a code gives a page that
/// reads and drafts until the terminal confirms it by its phrase, and a second try with the code is said there.
@Suite(.timeLimit(.minutes(5)))
struct ActingAttackTests {
    private let scratch = Scratch()

    /// The loopback page's gate and screen as `NodeLive` wires them, every request that reaches the acting path
    /// (`onPageVoice`) recorded instead of acted on.
    final class Rig: @unchecked Sendable {
        let vault = MemoryVaultV2()
        let access: WebAccess
        let acting: ActingPages
        let screen: WebRequestScreen
        let listener: WebListenerUnderTest
        let reached = Locked<[String]>([])
        let root: URL

        init(_ scratch: Scratch, root: URL? = nil) throws {
            let root = root ?? scratch.url("acting-root")
            self.root = root
            access = pageGate(vault, root: root)
            acting = try #require(access.acting)
            screen = WebRequestScreen(RecordingHandler(), terminals: true)
            screen.acting = acting
            let reached = self.reached
            screen.onPageVoice = { request, _, transport in
                reached.mutate { $0.append(request.kind) }
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

        /// `auth` with `args`: the hello's rights, token and phrase, or the bye's code.
        func auth(_ client: RawClient, _ args: [String: String]) throws -> (rights: [String], token: String?, phrase: String?, bye: String?) {
            var all = args
            all["client"] = "webapp"
            let fields = all.map { "\"\($0.key)\":\"\($0.value)\"" }.sorted().joined(separator: ",")
            try client.sendText(#"{"v":1,"id":"0","kind":"auth","args":{\#(fields)}}"#)
            let frame = try client.nextFrame()?.json
            if frame?["kind"]?.string == "bye" { return ([], nil, nil, frame?["code"]?.string ?? "bye") }
            let auth = frame?["auth"]
            return ((auth?["rights"]?.array ?? []).compactMap(\.string), auth?["token"]?.string, auth?["phrase"]?.string, nil)
        }

        /// A user's kind sent on `client`: `acted` when it reached the acting path, else the refusal's code.
        func act(_ client: RawClient, _ kind: String = "set") throws -> String {
            try client.sendText(#"{"v":1,"id":"9","kind":"\#(kind)","args":{"key":"ai_summaries","value":"off"},"action":"\#(UUID().uuidString.lowercased())"}"#)
            let reply = try client.nextFrame()?.json
            if reply?["result"]?["acted"]?.bool == true { return "acted" }
            return reply?["error"]?["code"]?.string ?? "no reply"
        }

        func stop() { listener.stop() }
    }

    /// (a) The agent writes its own token's SHA-256 into web-tokens.json (with an end a year off) and has the server read
    /// it again: the token isn't admitted at all (the vault doesn't know it).
    @Test func aTokenTheAgentWritesIntoTheFileIsntAdmitted() throws {
        let root = scratch.url("acting-root")
        let forged = "a-token-the-agent-chose-for-itself-0123456789"
        let file = root.appendingPathComponent("v2/web-tokens.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry = #"{"format":1,"tokens":[{"sha256":"\#(ActingPages.digest(forged))","issuedAt":"2026-11-24T00:00:00.000Z","expiresAt":"2027-11-24T00:00:00.000Z"}]}"#
        try Data(entry.utf8).write(to: file)
        let rig = try Rig(scratch, root: root)
        defer { rig.stop() }
        _ = try rig.acting.set(level: "trust")
        let client = try rig.agentClient()
        #expect(try rig.auth(client, ["token": forged]).bye == "auth", "a token the vault doesn't know: not admitted")
        #expect(rig.reached.value.isEmpty)
    }

    /// A page that took a code, never confirmed in the terminal, never acts nor watches, whatever the level.
    @Test func anUnconfirmedPageNeverActsNorWatches() throws {
        let rig = try Rig(scratch)
        defer { rig.stop() }
        _ = try rig.acting.set(level: "trust")
        let first = try rig.agentClient()
        let (rights, token, phrase, _) = try rig.auth(first, ["pair": rig.access.openCode(now: Date())])
        #expect(rights == ["read", "draft"] && phrase != nil)
        #expect(try rig.act(first) == "voice")
        let again = try rig.agentClient()
        #expect(try rig.auth(again, ["token": try #require(token)]).rights == ["read", "draft"])
        #expect(try rig.act(again) == "voice")
        #expect(rig.reached.value.isEmpty)
    }

    /// Finding 1: the token alone, copied out of the browser's storage, acts nowhere: acting needs the pairing secret the
    /// confirmed page holds in its memory only, given once on its own connection.
    @Test func aCopiedTokenActsFromNoOtherSocket() throws {
        let rig = try Rig(scratch)
        defer { rig.stop() }
        _ = try rig.acting.set(level: "trust")
        let browser = try rig.agentClient()
        let code = rig.access.openCode(now: Date())
        let (_, issued, _, _) = try rig.auth(browser, ["pair": code])
        let token = try #require(issued)
        // The terminal confirms the user's page (`web.confirm`'s part).
        let id = PagePairing.codeID(digest: WebTokens.digest(code))
        let pairing = try #require(rig.access.takePairing(code: id))
        let secret = rig.acting.confirmed(token: pairing.token, tokenEnds: pairing.tokenEnds)
        #expect(rig.screen.confirmPairing(id, secret: secret, rights: [.read, .draft, .watch, .act]))
        let paired = try browser.nextFrame()?.json
        #expect(paired?["kind"]?.string == "paired" && paired?["act"]?.string == secret)
        #expect(try rig.act(browser) == "acted", "the user's own page acts")
        // The agent, with the token copied out of the browser's storage: its own socket, forged headers.
        let agent = try rig.agentClient()
        #expect(try rig.auth(agent, ["token": token]).rights == ["read", "draft"])
        #expect(try rig.act(agent) == "voice", "no user's act from the agent's socket")
        #expect(rig.reached.value == ["set"])
    }

    /// Finding 2: whoever redeems the code first gets a page that reads and drafts and shows its phrase; the user's
    /// browser, second, is turned away, and the terminal is told the code was tried again, so nothing is confirmed.
    @Test func redeemingTheCodeFirstGivesNoActingPage() throws {
        let rig = try Rig(scratch)
        defer { rig.stop() }
        _ = try rig.acting.set(level: "trust")
        let code = rig.access.openCode(now: Date())
        let agent = try rig.agentClient()
        let (rights, _, phrase, _) = try rig.auth(agent, ["pair": code])
        #expect(rights == ["read", "draft"], "the agent's page doesn't act")
        let browser = try rig.agentClient()
        #expect(try rig.auth(browser, ["pair": code]).bye == "auth")
        let id = PagePairing.codeID(digest: WebTokens.digest(code))
        #expect(rig.access.pairing(code: id) == .taken(phrase: try #require(phrase), contested: true), "said in the terminal")
        #expect(try rig.act(agent) == "voice")
        #expect(rig.reached.value.isEmpty)
    }

    /// Finding 3: a reading page watches no terminal (watching needs a confirmed pairing), and no page is ever served a
    /// live pairing code, in a terminal's bytes (even split across reads) or a transcript.
    @Test func aReadingPageWatchesNothingAndNoCodeIsServed() throws {
        #expect(Principal.page([.read, .draft], terminals: true).route("term.open") != .terminal)
        let code = WebTokens.randomText(bytes: WebAccess.codeBytes)
        // This server's live codes (another server's, another test's, are none of its mask's).
        let codes = PairingCodes()
        codes.made(code, until: Date().addingTimeInterval(120))
        let line = "Open this address in a browser within 120 s; it works once:\r\nhttp://127.0.0.1:8765/#pair=\(code)\r\n$ "
        let bytes = Data(line.utf8)
        for split in [10, 60, 85, 90, bytes.count - 3] {
            let mask = TerminalMask(codes: codes)
            let served = mask.pass(bytes.prefix(split)) + mask.pass(bytes.dropFirst(split)) + mask.drain()
            let text = String(decoding: served, as: UTF8.self)
            #expect(!text.contains(code) && text.contains("#pair=" + String(repeating: "*", count: code.count)), "split at \(split): \(text)")
        }
        #expect(!PairingMask.mask("ran `vibeswitcher web`: http://127.0.0.1:8765/#pair=\(code)").contains(code))
        // The re-read's R4: cut by what the screen does (a screen replay redraws a wrapped line with a cursor move; a
        // colour; a line break), split across reads inside an escape sequence, or percent-encoded: still masked, each
        // code character one `*`, the escapes kept.
        let half = code.index(code.startIndex, offsetBy: 11)
        for cut in ["\u{1B}[2;1H", "\u{1B}[0m\u{1B}[38;5;12m", "\r\n", "\u{1B}]8;;x\u{07}"] {
            let drawn = Data("http://127.0.0.1:8765/#pair=\(code[..<half])\(cut)\(code[half...]) \u{1B}[K$ ".utf8)
            for split in [30, 40, 41, 42, drawn.count - 6] {
                let mask = TerminalMask(codes: codes)
                let served = mask.pass(drawn.prefix(split)) + mask.pass(drawn.dropFirst(split)) + mask.drain()
                let text = String(decoding: served, as: UTF8.self)
                #expect(!text.contains(String(code[..<half])) && !text.contains(String(code[half...])), "\(cut.debugDescription) split at \(split): \(text.debugDescription)")
                #expect(text.contains(cut) && served.count == drawn.count, "the escapes kept, one for one: \(text.debugDescription)")
            }
        }
        let encoded = TerminalMask(codes: codes)
        let percent = String(decoding: encoded.pass(Data("open http%3A%2F%2F127.0.0.1%3A8765%2F%23pair%3D\(code) now\n".utf8)) + encoded.drain(), as: UTF8.self)
        #expect(!percent.contains(code), "\(percent)")
        #expect(!PairingMask.mask("http%3A%2F%2F127.0.0.1%3A8765%2F%23pair%3D\(code)").contains(code))
        // The automated review of b73aedc5: (1) a code inside an escape sequence's payload (an OSC 8 hyperlink's target,
        // a window title, a DCS or APC string) is masked on the raw bytes; (2) CAN, SUB and ESC end a string as a
        // terminal ends it, and what follows is shown (and masked); (3) an unterminated OSC never holds the stream; (4) a
        // code delivered byte by byte, a quiet flush after each, is masked whole.
        func served(_ text: String, splits: [Int] = []) -> String {
            let mask = TerminalMask(codes: codes)
            let bytes = Data(text.utf8)
            var out = Data(), from = 0
            for split in splits + [bytes.count] where split > from && split <= bytes.count {
                out += mask.pass(bytes.subdata(in: from..<split))
                from = split
            }
            return String(decoding: out + mask.drain(), as: UTF8.self)
        }
        for payload in ["\u{1B}]8;;http://127.0.0.1:8765/#pair=\(code)\u{1B}\\the link\u{1B}]8;;\u{1B}\\",
                        "\u{1B}]0;vibeswitcher web: #pair=\(code)\u{07}", "\u{1B}]2;\(code)\u{1B}\\",
                        "\u{1B}P1;2|pair=\(code)\u{1B}\\", "\u{1B}_pair%3D\(code)\u{1B}\\"] {
            for splits in [[], [7], [20, 40]] {
                let text = served(payload + " $ ", splits: splits)
                #expect(!text.contains(code), "\(payload.debugDescription) at \(splits): \(text.debugDescription)")
            }
        }
        for ended in ["\u{1B}]0;a title\u{18}#pair=\(code)\r\n", "\u{1B}]0;a title\u{1A}#pair=\(code)\r\n",
                      "\u{1B}]0;a title\u{1B}[31m#pair=\(code)\r\n", "\u{1B}[31\u{18}#pair=\(code)\r\n"] {
            #expect(!served(ended).contains(code), "\(ended.debugDescription)")
            let screen = TerminalMask.shown(Array(ended.utf8))
            #expect(String(decoding: screen.text, as: UTF8.self).hasPrefix("#pair="), "a terminal shows what follows: \(ended.debugDescription)")
        }
        let unterminated = Data(("\u{1B}]0;" + String(repeating: "x", count: 1 << 20)).utf8)
        let big = TerminalMask(codes: codes)
        var released = Data(), mostHeld = 0
        for at in stride(from: 0, to: unterminated.count, by: 4_096) {
            released += big.pass(unterminated.subdata(in: at..<min(at + 4_096, unterminated.count)))
            mostHeld = max(mostHeld, big.heldCount)
        }
        #expect(released.count >= unterminated.count - TerminalMask.openEscapeHeld - 4_096, "an open OSC held \(unterminated.count - released.count) bytes")
        #expect(released + big.drain() == unterminated)
        // What is re-read at each read stays bounded (no read re-reads the megabyte: never quadratic).
        #expect(mostHeld <= TerminalMask.openEscapeHeld + 4_096, "\(mostHeld) bytes held at once")
        let slow = TerminalMask(codes: codes)
        var trickled = Data()
        for byte in Data("http://127.0.0.1:8765/#pair=\(code) then more\r\n".utf8) {
            trickled += slow.pass(Data([byte]))
            trickled += slow.flush() // each byte after a quiet longer than the relay's (`maskQuiet`)
        }
        #expect(!String(decoding: trickled, as: UTF8.self).contains(code), "\(String(decoding: trickled, as: UTF8.self))")
        let live = TerminalMask(codes: codes)
        var alone = Data()
        for byte in Data("the code is \(code).\r\n".utf8) { alone += live.pass(Data([byte])) + live.flush() }
        alone += live.drain()
        // A live code's start waits at a quiet (from its `heldPrefix`th character), so no more than its first few go.
        #expect(!String(decoding: alone, as: UTF8.self).contains(code.prefix(TerminalMask.heldPrefix)), "\(String(decoding: alone, as: UTF8.self))")
        // The parser's state and the last raw bytes carried across a release: a code inside an OSC payload, split at
        // every byte across a cap release (past `openEscapeHeld`) and across a quiet flush, the address's form and a
        // bare live code.
        for form in ["pair=\(code)", code] {
            let long = Array("\u{1B}]0;\(String(repeating: "x", count: TerminalMask.openEscapeHeld + 8))\(form) more\u{07} $ ".utf8)
            let short = Array("\u{1B}]0;a title \(form) more\u{07} $ ".utf8)
            for (bytes, release) in [(long, "cap"), (short, "flush")] {
                let at = bytes.count - Array("\(form) more\u{07} $ ".utf8).count
                for split in (at - 2)...(at + form.utf8.count + 1) {
                    let mask = TerminalMask(codes: codes)
                    var out = Data(mask.pass(Data(bytes[..<split])))
                    if release == "flush" { out += mask.flush() }
                    out += mask.pass(Data(bytes[split...])) + mask.drain()
                    let text = String(decoding: out, as: UTF8.self)
                    #expect(!text.contains(code.prefix(6)) && !text.contains(code.suffix(6)) && out.count == bytes.count,
                            "\(release) at \(split) of \(form == code ? "a live code" : "an address"): \(text.suffix(60).debugDescription)")
                }
            }
        }
        // Plain output goes at once but for a tail that may start a code (it goes after a short quiet: `flush`), and
        // nothing is lost.
        let mask = TerminalMask(codes: codes)
        let now = mask.pass(Data("total 0\r\n$ ".utf8))
        #expect(String(decoding: now, as: UTF8.self).hasPrefix("total"), "\(String(decoding: now, as: UTF8.self))")
        #expect(now + mask.drain() == Data("total 0\r\n$ ".utf8))
    }

    /// The mask changes no byte but a code's own (team-lead's rule after the load gate): with no live code and no `pair=`,
    /// it is the identity whatever the reads' cuts and the quiet flushes; with a live code, text made only of a code's
    /// characters that isn't the code comes out unchanged; another server's live codes are none of this mask's.
    @Test func theMaskChangesNothingButACode() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
        func through(_ mask: TerminalMask, _ bytes: [UInt8]) -> Data {
            var out = Data(), at = 0
            while at < bytes.count {
                let next = min(bytes.count, at + Int.random(in: 1...64, using: &generator))
                out += mask.pass(Data(bytes[at..<next]))
                if Bool.random(using: &generator) { out += mask.flush() }
                at = next
            }
            return out + mask.drain()
        }
        for _ in 0..<2_000 {
            var bytes = (0..<Int.random(in: 0...512, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if String(decoding: bytes, as: UTF8.self).lowercased().contains("pair") { bytes = bytes.filter { $0 != 0x70 } }
            #expect(through(TerminalMask(codes: PairingCodes()), bytes) == Data(bytes), "random bytes changed")
        }
        let codes = PairingCodes()
        let code = WebTokens.randomText(bytes: WebAccess.codeBytes)
        codes.made(code, until: Date().addingTimeInterval(120))
        for _ in 0..<500 {
            let words = (0..<Int.random(in: 1...400, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            guard !String(decoding: words, as: UTF8.self).contains(code.prefix(TerminalMask.heldPrefix)) else { continue }
            #expect(through(TerminalMask(codes: codes), words) == Data(words), "code-alphabet text that isn't the code changed")
            // The footer the page's terminal shows, all a code's letters and spaces, unchanged however it comes.
            let footer = Array("  ? for shortcuts\r\n> ".utf8)
            #expect(through(TerminalMask(codes: codes), footer) == Data(footer))
        }
        // Another server's code: this mask doesn't know it, and changes nothing of it.
        let other = TerminalMask(codes: PairingCodes())
        #expect(through(other, Array("the code \(code) here".utf8)) == Data("the code \(code) here".utf8))
        // Taken, a code is live no more.
        codes.taken(code)
        #expect(through(TerminalMask(codes: codes), Array("the code \(code) here".utf8)) == Data("the code \(code) here".utf8))
    }

    /// The node's live codes are one set, its loopback's and its tailnet's (team-lead's review of the per-server fix):
    /// a tailnet pairing code printed in a watched terminal is masked; a bare live code quoted in a transcript is masked
    /// (as is any `pair=` address's code); a revoke on one gate leaves the other's codes live; and still, with no live
    /// code and no `pair=`, the terminal's mask and the transcript's change nothing.
    @Test func theNodesLiveCodesAreItsGatesBoth() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let clock = NodeClock(queue: world.queue, now: { 0 }, schedule: { _, _ in {} })
        let unreachable: Tailnet.Finder = { .failure(WebTokens.Refusal("no tailnet in this test")) }
        let live = NodeLive(requests: world.requests, sessions: nil, engine: world.engine, clock: clock, port: 0,
                            terminals: .watch, tailnet: .init(find: unreachable, admitPeer: { _ in false }))
        let tailnet = try #require(live.tailnet)
        let relayCodes = try #require(live.hub.terminals?.liveCodes)
        let plain = Data("  ? for shortcuts\r\n> \(String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 8))\r\n".utf8)
        func shown(_ bytes: Data) -> Data {
            let mask = TerminalMask(codes: relayCodes)
            var out = Data()
            for at in stride(from: 0, to: bytes.count, by: 7) { out += mask.pass(bytes.subdata(in: at..<min(at + 7, bytes.count))) + mask.flush() }
            return out + mask.drain()
        }
        #expect(shown(plain) == plain, "no live code, no pair=: the identity")
        let fromTailnet = tailnet.access.openCode(now: Date())
        let fromLoopback = live.access.openCode(now: Date())
        for code in [fromTailnet, fromLoopback] {
            let line = Data("Open this address on your tailnet: http://node.example.ts.net:8765/#pair=\(code)\r\nor the code: \(code)\r\n$ ".utf8)
            #expect(!String(decoding: shown(line), as: UTF8.self).contains(code), code == fromTailnet ? "the tailnet's code" : "the loopback's code")
        }
        #expect(shown(plain) == plain, "with live codes, text that isn't one: unchanged")
        // A transcript: a live code quoted alone is masked, as is an address's code; other text is left as it is.
        let reply = ChatItem.reply(ChatEntry(id: "r1", at: nil, kind: .reply("The code alone: \(fromTailnet). Run `vibeswitcher web` again for ? for shortcuts.")))
        let value = try #require(ChatValue.value(reply, codes: live.access.liveCodes))
        let text = "\(value)"
        #expect(!text.contains(fromTailnet) && text.contains("for ? for shortcuts"), "\(text)")
        #expect(PairingMask.mask("? for shortcuts and abcdefghijklmnopqrstuvwxyz", codes: relayCodes.codes) == "? for shortcuts and abcdefghijklmnopqrstuvwxyz")
        // The loopback's revoke: its codes live no more, the tailnet's stay.
        _ = live.access.revoke()
        #expect(Set(relayCodes.codes) == [fromTailnet])
    }

    /// Finding 4: the guard rails that are a project's merge gate are a terminal's, as the floors and the policy are.
    @Test func noPageSetsAGuardRail() {
        for key in ["security_audit_model", "max_workers", "floor_merge_policy", "policy", "verifier_model", "floor_worker_model"] {
            guard case .terminalOnly? = NodeSettings.setting(key)?.page else { Issue.record("\(key) is a page's"); continue }
        }
        if case .lowersOnly? = NodeSettings.setting("web_acts")?.page {} else { Issue.record("web_acts is raised from a page") }
    }
}
