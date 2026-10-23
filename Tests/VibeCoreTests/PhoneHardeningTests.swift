import Foundation
import Testing
@testable import VibeCore

/// F-P1: replies to window sessions obey the screen lock, before every write.
struct RemoteInputGateTests {
    func conditions(locked: Bool = false, on: Bool = true, input: Bool = true, paired: Bool = true,
                    same: Bool = true) -> RemoteInputGate.Conditions {
        .init(screenLocked: locked, accessOn: on, inputAllowed: input, devicePaired: paired, sameSession: same)
    }

    @Test func aLockedMacRefusesWhateverElseHolds() {
        #expect(RemoteInputGate.verdict(conditions()) == .allowed)
        #expect(RemoteInputGate.verdict(conditions(locked: true)) == .locked)
        #expect(RemoteInputGate.verdict(conditions(locked: true, paired: false, same: false)) == .locked)
        #expect(RemoteInputGate.verdict(conditions(on: false)) == .notAllowed)
        #expect(RemoteInputGate.verdict(conditions(input: false)) == .notAllowed)
        #expect(RemoteInputGate.verdict(conditions(paired: false)) == .notAllowed)
        #expect(RemoteInputGate.verdict(conditions(same: false)) == .sessionChanged)
    }

    /// Runs the delayed writes by hand, so the lock can change between them.
    final class Harness {
        var locked = false
        var pending: [() -> Void] = []
        var sent: [[UInt8]] = []
        var stopped: (RemoteInputGate.Verdict, Int)?

        func deliver(_ writes: [HostInput.Write]) {
            RemoteInputGate.deliver(writes, check: { [unowned self] in
                RemoteInputGate.verdict(.init(screenLocked: self.locked, accessOn: true, inputAllowed: true,
                                              devicePaired: true, sameSession: true))
            }, after: { [unowned self] _, block in self.pending.append(block) },
               send: { [unowned self] in self.sent.append($0) },
               stopped: { [unowned self] in self.stopped = ($0, $1) })
        }

        func runNext() { if !pending.isEmpty { pending.removeFirst()() } }
    }

    @Test func lockingBetweenTheTextAndEnterDropsEnter() {
        let harness = Harness()
        harness.deliver(HostInput.writes(text: "rm -rf build", submit: true, key: nil))
        harness.runNext()                       // the text goes out
        #expect(harness.sent == [Array("rm -rf build".utf8)])
        harness.locked = true                   // the Mac locks before Enter
        harness.runNext()
        #expect(harness.sent.count == 1)        // Enter never reaches the session
        #expect(harness.stopped?.0 == .locked)
        #expect(harness.stopped?.1 == 1)
        #expect(harness.pending.isEmpty)        // and nothing else is queued
    }

    @Test func lockedFromTheStartNothingIsWritten() {
        let harness = Harness()
        harness.locked = true
        harness.deliver(HostInput.writes(text: "hello", submit: true, key: nil))
        while !harness.pending.isEmpty { harness.runNext() }
        #expect(harness.sent.isEmpty)
        #expect(harness.stopped?.0 == .locked)
    }

    @Test func unlockedEveryWriteGoesOutInOrder() {
        let harness = Harness()
        harness.deliver(HostInput.writes(text: "yes", submit: true, key: nil))
        while !harness.pending.isEmpty { harness.runNext() }
        #expect(harness.sent == [Array("yes".utf8), [13]])
        #expect(harness.stopped == nil)
    }
}

/// F-P2: only the tailnet name gets in, and failures are counted per source.
struct RemoteGateTests {
    let host = "mac.tail1234.ts.net"

    @Test func onlyTheTailnetNameIsServed() {
        #expect(RemoteGate.hostMatches("mac.tail1234.ts.net:8443", host: host, port: 8443))
        #expect(RemoteGate.hostMatches("MAC.tail1234.ts.net.:8443", host: host, port: 8443))
        #expect(RemoteGate.hostMatches("mac.tail1234.ts.net", host: host, port: 8443))
        // DNS rebinding: the attacker's own name, or loopback.
        #expect(!RemoteGate.hostMatches("evil.example:8443", host: host, port: 8443))
        #expect(!RemoteGate.hostMatches("evil.example", host: host, port: 8443))
        #expect(!RemoteGate.hostMatches("127.0.0.1:47823", host: host, port: 8443))
        #expect(!RemoteGate.hostMatches("localhost:47823", host: host, port: 8443))
        #expect(!RemoteGate.hostMatches("mac.tail1234.ts.net.evil.example:8443", host: host, port: 8443))
        #expect(!RemoteGate.hostMatches("mac.tail1234.ts.net:8444", host: host, port: 8443))
        #expect(!RemoteGate.hostMatches(nil, host: host, port: 8443))
        #expect(!RemoteGate.hostMatches("", host: host, port: 8443))
    }

    @Test func badTokensFromOneSourceDontThrottleAnother() {
        var throttle = FailureThrottle(limit: 20, window: 60)
        let t0 = Date(timeIntervalSince1970: 1000)
        let attacker = RemoteGate.source(login: "me@example.com", forwardedFor: nil)
        let phone = RemoteGate.source(login: "me@example.com", forwardedFor: "100.64.0.7")
        #expect(attacker != phone)
        for i in 0..<20 { throttle.recordFailure(attacker, now: t0.addingTimeInterval(Double(i))) }
        #expect(throttle.isThrottled(attacker, now: t0.addingTimeInterval(21)))
        #expect(!throttle.isThrottled(phone, now: t0.addingTimeInterval(21)))
        // A minute later the attacker's failures have aged out.
        #expect(!throttle.isThrottled(attacker, now: t0.addingTimeInterval(81)))
    }

    @Test func aValidTokenAuthenticatesWhileItsSourceIsThrottled() {
        // The server checks the token first and only consults the throttle when it fails.
        let token = RemoteAuth.newToken()
        let device = PairedDevice(id: "p", name: "Pixel", tokenHash: RemoteAuth.hash(token),
                                  tailscaleLogin: "me@example.com", pairedAt: Date())
        var throttle = FailureThrottle()
        let source = RemoteGate.source(login: "me@example.com", forwardedFor: "100.64.0.7")
        for _ in 0..<50 { throttle.recordFailure(source) }
        #expect(throttle.isThrottled(source))
        #expect(RemoteAuth.authenticate(authorization: "Bearer \(token)", login: "me@example.com", devices: [device]) == device)
    }

    @Test func rotatingSourcesCantGrowTheTableForever() {
        var throttle = FailureThrottle(limit: 20, window: 60, maxSources: 8)
        let t0 = Date(timeIntervalSince1970: 1000)
        for i in 0..<1000 { throttle.recordFailure("s\(i)", now: t0) }
        for i in 0..<20 { throttle.recordFailure("loud", now: t0.addingTimeInterval(Double(i) / 100)) }
        #expect(throttle.isThrottled("loud", now: t0.addingTimeInterval(1)))
    }

    @Test func theSourceIsTheFirstForwardedAddress() {
        #expect(RemoteGate.source(login: "me", forwardedFor: "100.64.0.7, 127.0.0.1") == "me|100.64.0.7")
        #expect(RemoteGate.source(login: nil, forwardedFor: "") == "|local")
    }

    @Test func previewPortsOnlyAnswerTheirOwnTailnetAddress() {
        let own = "https://mac.example.ts.net:8444"
        func decide(_ raw: String) -> PreviewGate.Decision {
            PreviewGate.decide(requestHead(raw), owner: "me@example.com", ownOrigin: own, siblingOrigins: [], publicPort: 8444)
        }
        let rest = "Tailscale-User-Login: me@example.com\r\nCookie: vs_preview_8444=T\r\n"
        let wrong = PreviewGate.Decision.reject(status: 421, message: PreviewGate.wrongHostMessage)
        #expect(decide("GET / HTTP/1.1\r\nHost: mac.example.ts.net:8444\r\n\(rest)") == .forward(sessionToken: "T"))
        #expect(decide("GET / HTTP/1.1\r\nHost: evil.example:8444\r\n\(rest)") == wrong)
        #expect(decide("GET / HTTP/1.1\r\nHost: 127.0.0.1:47824\r\n\(rest)") == wrong)
        #expect(decide("GET / HTTP/1.1\r\nHost: mac.example.ts.net:8445\r\n\(rest)") == wrong)
        #expect(decide("GET / HTTP/1.1\r\n\(rest)") == wrong)
        #expect(decide("GET / HTTP/1.1\r\nHost: mac.example.ts.net:8444\r\nHost: evil.example\r\n\(rest)") == wrong)
        // The ticket link too.
        #expect(decide("GET /__vibeswitcher/enter?t=abc HTTP/1.1\r\nHost: evil.example\r\nTailscale-User-Login: me@example.com\r\n") == wrong)
    }
}

/// F-D1: preview sessions belong to the device that opened them.
struct PreviewDeviceTests {
    let vite = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:5173", port: 5173)
    let t0 = Date(timeIntervalSince1970: 1000)

    func counter() -> () -> String {
        var n = 0
        return { n += 1; return "token\(n)" }
    }

    @Test func unpairingADeviceEndsItsSessions() throws {
        var slots = PreviewSlots(count: 1)
        let tokens = counter()
        let openedA = slots.open(vite, path: "/", device: "A", now: t0, newToken: tokens)
        let a = try #require(openedA)
        let redeemedA = slots.redeem(a.ticket, slot: a.slot, now: t0, newToken: tokens)
        let sessionA = try #require(redeemedA).sessionToken
        let openedB = slots.open(vite, path: "/", device: "B", now: t0, newToken: tokens)
        let b = try #require(openedB)
        let redeemedB = slots.redeem(b.ticket, slot: b.slot, now: t0, newToken: tokens)
        let sessionB = try #require(redeemedB).sessionToken
        // Each phone has its own session on the slot.
        #expect(sessionA != sessionB)
        #expect(redeemedB?.clearSite == true)
        let ended = slots.revoke(device: "A")
        #expect(ended.map(\.token) == [sessionA])
        let afterA = slots.target(slot: 0, sessionToken: sessionA, now: t0)
        #expect(afterA == nil)
        #expect(!slots.isLive(slot: 0, sessionToken: sessionA, now: t0))
        // The other phone keeps working.
        let afterB = slots.target(slot: 0, sessionToken: sessionB, now: t0)
        #expect(afterB == vite)
    }

    @Test func anUnpairedDevicesUnusedTicketIsDeadToo() throws {
        var slots = PreviewSlots(count: 1)
        let opened = slots.open(vite, path: "/", device: "A", now: t0, newToken: counter())
        let ticket = try #require(opened).ticket
        slots.revoke(device: "A")
        let redeemed = slots.redeem(ticket, slot: 0, now: t0)
        #expect(redeemed == nil)
    }

    @Test func aSessionInConstantUseStillEndsAfterItsLifetime() throws {
        var slots = PreviewSlots(count: 1)
        let tokens = counter()
        let opened = slots.open(vite, path: "/", device: "A", now: t0, newToken: tokens)
        let ticket = try #require(opened).ticket
        let redeemed = slots.redeem(ticket, slot: 0, now: t0, newToken: tokens)
        let session = try #require(redeemed).sessionToken
        // Used every hour, never idle…
        var at = t0
        while at.timeIntervalSince(t0) < PreviewSlots.lifetime - 3600 {
            at = at.addingTimeInterval(3600)
            let used = slots.target(slot: 0, sessionToken: session, now: at)
            #expect(used == vite)
        }
        // …but past its lifetime it's over.
        let late = slots.target(slot: 0, sessionToken: session, now: t0.addingTimeInterval(PreviewSlots.lifetime + 1))
        #expect(late == nil)
        // Opening the page again gives a fresh session.
        let again = slots.open(vite, path: "/", device: "A", now: t0.addingTimeInterval(PreviewSlots.lifetime + 2), newToken: tokens)
        let againTicket = try #require(again).ticket
        let fresh = slots.redeem(againTicket, slot: 0, now: t0.addingTimeInterval(PreviewSlots.lifetime + 2), newToken: tokens)
        #expect(fresh?.sessionToken != session)
        #expect(fresh?.clearSite == true)
    }
}

/// F-D2: a cookie planted by another port's page can't shadow the slot's own.
struct PreviewShadowCookieTests {
    @Test func theLiveSessionWinsOverAShadowCookie() {
        let raw = "GET /app/x HTTP/1.1\r\nHost: mac.example.ts.net:8444\r\nTailscale-User-Login: me@example.com\r\n"
            + "Cookie: vs_preview_8444=bad; theme=dark; vs_preview_8444=good\r\n"
        let decision = PreviewGate.decide(requestHead(raw), owner: "me@example.com", ownOrigin: "https://mac.example.ts.net:8444",
                                          siblingOrigins: [], publicPort: 8444, accepts: { $0 == "good" })
        #expect(decision == .forward(sessionToken: "good"))
        // Spread over two Cookie fields as well.
        let split = "GET /app/x HTTP/1.1\r\nHost: mac.example.ts.net:8444\r\nTailscale-User-Login: me@example.com\r\n"
            + "Cookie: vs_preview_8444=bad\r\nCookie: vs_preview_8444=good\r\n"
        #expect(PreviewGate.decide(requestHead(split), owner: "me@example.com", ownOrigin: "https://mac.example.ts.net:8444",
                                   siblingOrigins: [], publicPort: 8444, accepts: { $0 == "good" }) == .forward(sessionToken: "good"))
    }
}

/// PH-1: a question, permission prompt or picker reaches the phone as option buttons, masked, and a tap is typed as the
/// menu's keys only while the screen still shows the menu it was drawn from.
struct PhoneMenuTests {
    let sid = "4242-1700000000"
    func prompt(command: String = "curl -H TOKEN=abc123s3cr3t https://example.com", cursor: Int = 0) -> String {
        let options = ["Yes", "Yes, and don't ask again for TOKEN=abc123s3cr3t", "No, and tell Claude what to do differently (esc)"]
        let rows = options.enumerated().map { index, option in "│ \(index == cursor ? "❯" : " ") \(index + 1). \(option) │" }
        return (["⏺ Bash(\(command))", "╭──────────────────────────────────────╮", "│ Bash command │", "│ │", "│   \(command) │",
                 "│   Fetch with SECRET=hunter2hunter2 │", "│ │", "│ Do you want to proceed? │"] + rows
                + ["╰──────────────────────────────────────╯", "", "", ""]).joined(separator: "\n")
    }

    @Test func theStateCarriesTheMenuMasked() throws {
        let menu = try #require(PhoneMenu.read(screen: prompt(cursor: 1), needsInput: true))
        let object = PhoneMenu.json(menu, sid: sid)
        #expect(JSONSerialization.isValidJSONObject(object))
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        #expect(!text.contains("abc123s3cr3t"))
        #expect(!text.contains("hunter2hunter2"))
        #expect(Set(object.keys) == ["question", "options", "descriptions", "selected", "fingerprint"])
        #expect(object["question"] as? String == "Bash command\ncurl -H TOKEN=••• https://example.com\nFetch with SECRET=•••\nDo you want to proceed?")
        #expect(object["options"] as? [String] == ["Yes", "Yes, and don't ask again for TOKEN=•••",
                                                    "No, and tell Claude what to do differently (esc)"])
        #expect((object["descriptions"] as? [Any])?.count == 3)
        #expect((object["descriptions"] as? [Any])?.allSatisfy { $0 is NSNull } == true)
        #expect(object["selected"] as? Int == 1)
        #expect(object["fingerprint"] as? String == PhoneMenu.fingerprint(menu, sid: sid))
    }

    @Test func descriptionsAndAMultiSelectsBoxesAndSubmitRowGoToo() throws {
        let screen = ["☐ Toppings", "Which toppings?", "❯ 1. [✔] Cream", "     Whipped, with TOKEN=abcdefgh1234", "  2. [ ] Nuts", "    Submit", "",
                      "Enter to select · ↑/↓ to navigate · Esc to cancel"].joined(separator: "\n")
        let menu = try #require(PhoneMenu.read(screen: screen, needsInput: false))
        let object = PhoneMenu.json(menu, sid: sid)
        #expect(object["options"] as? [String] == ["Cream", "Nuts"])
        #expect((object["descriptions"] as? [Any])?.first as? String == "Whipped, with TOKEN=•••")
        #expect(object["checked"] as? [Bool] == [true, false])
        #expect(object["submit"] as? String == "Submit")
        // The Submit row is a choice too: down twice from Cream, then Enter.
        let fingerprint = PhoneMenu.fingerprint(menu, sid: sid)
        #expect(PhoneMenu.answer(choose: 2, fingerprint: fingerprint, screen: screen, needsInput: false, sid: sid)
                == .keys([HostInput.Write(bytes: [27, 91, 66], delay: 0), HostInput.Write(bytes: [27, 91, 66], delay: 0.03),
                          HostInput.Write(bytes: [13], delay: 0.08)], label: "Submit"))
        #expect(PhoneMenu.answer(choose: 3, fingerprint: fingerprint, screen: screen, needsInput: false, sid: sid) == .invalid)
    }

    @Test func numberedTextIsAMenuOnlyWhenItAsks() {
        let list = ["Plan:", "❯ 1. Build", "  2. Test"].joined(separator: "\n")
        #expect(PhoneMenu.detect(screen: list, needsInput: false) == nil)
        #expect(PhoneMenu.detect(screen: list, needsInput: true)?.options == ["Build", "Test"])
        #expect(PhoneMenu.detect(screen: list + "\n\nEnter to select · Esc to cancel", needsInput: false)?.options == ["Build", "Test"])
        #expect(PhoneMenu.detect(screen: "$ ls\nREADME.md", needsInput: true) == nil)
    }

    @Test func theFingerprintIsTheQuestionNotTheCursor() throws {
        let first = try #require(PhoneMenu.read(screen: prompt(cursor: 0), needsInput: true))
        let moved = try #require(PhoneMenu.read(screen: prompt(cursor: 2), needsInput: true))
        let other = try #require(PhoneMenu.read(screen: prompt(command: "rm -rf build"), needsInput: true))
        #expect(PhoneMenu.fingerprint(first, sid: sid) == PhoneMenu.fingerprint(moved, sid: sid))
        #expect(PhoneMenu.fingerprint(first, sid: sid) != PhoneMenu.fingerprint(other, sid: sid))
        // Another session showing the same prompt has its own.
        #expect(PhoneMenu.fingerprint(first, sid: sid) != PhoneMenu.fingerprint(first, sid: "4243-1700000000"))
    }

    /// An edit prompt as Claude Code 2.1 draws it: the dialog under a rule, its diff between dashed rules, the
    /// conversation above it (`progress`: a subagent's line that moves while the question waits).
    func edit(_ diff: [String], cursor: Int = 0, progress: String = "⎿  Read 3 files (12s)") -> String {
        let rule = String(repeating: "─", count: 60), dashed = String(repeating: "╌", count: 60)
        let options = ["Yes", "Yes, allow all edits during this session (shift+tab)", "No, and tell Claude what to do differently (esc)"]
        let rows = options.enumerated().map { index, option in " \(index == cursor ? "❯" : " ") \(index + 1). \(option)" }
        return (["⏺ Task(Review the parser)", "  \(progress)", "", rule, " Edit file", " Sources/Foo.swift", dashed]
                + diff.map { " \($0)" } + [dashed, " Do you want to make this edit to Foo.swift?"] + rows
                + ["", " Esc to cancel · Tab to amend", "", ""]).joined(separator: "\n")
    }

    @Test func twoEditsOfOneFileDifferByTheirDiff() throws {
        let a = edit(["12 - let x = 1", "12 + let x = 2"]), b = edit(["40 - try deleteAll()", "40 + // removed"])
        let shownA = try #require(PhoneMenu.read(screen: a, needsInput: true))
        let shownB = try #require(PhoneMenu.read(screen: b, needsInput: true))
        // The same question and options: only what's above them tells them apart.
        #expect(shownA.menu.question == "Do you want to make this edit to Foo.swift?")
        #expect(shownA.menu == shownB.menu)
        #expect(shownA.above == ["Edit file", "Sources/Foo.swift", String(repeating: "╌", count: 60), "12 - let x = 1", "12 + let x = 2",
                                 String(repeating: "╌", count: 60), "Do you want to make this edit to Foo.swift?"])
        let fingerprint = PhoneMenu.fingerprint(shownA, sid: sid)
        #expect(fingerprint != PhoneMenu.fingerprint(shownB, sid: sid))
        // A tap drawn from A, arriving once B is up (A was answered on the Mac): refused, nothing typed.
        #expect(PhoneMenu.answer(choose: 0, fingerprint: fingerprint, screen: b, needsInput: true, sid: sid) == .stale)
        #expect(!PhoneMenu.readyToEnter(0, fingerprint: fingerprint, screen: b, sid: sid))
        // Still A: answered, whatever moves in the conversation above the dialog.
        let progressed = edit(["12 - let x = 1", "12 + let x = 2"], progress: "⎿  Read 5 files (14s)")
        #expect(PhoneMenu.answer(choose: 0, fingerprint: fingerprint, screen: progressed, needsInput: true, sid: sid)
                == .keys([HostInput.Write(bytes: [13], delay: 0)], label: "Yes"))
    }

    @Test func enterWaitsForTheQuestionTappedWithTheCursorOnTheOption() throws {
        let screen = edit(["12 - let x = 1", "12 + let x = 2"])
        let fingerprint = PhoneMenu.fingerprint(try #require(PhoneMenu.read(screen: screen, needsInput: true)), sid: sid)
        #expect(PhoneMenu.readyToEnter(0, fingerprint: fingerprint, screen: screen, sid: sid))
        #expect(PhoneMenu.readyToEnter(2, fingerprint: fingerprint, screen: edit(["12 - let x = 1", "12 + let x = 2"], cursor: 2), sid: sid))
        // The cursor isn't on it (yet), the question went, or another session has the tab.
        #expect(!PhoneMenu.readyToEnter(1, fingerprint: fingerprint, screen: screen, sid: sid))
        #expect(!PhoneMenu.readyToEnter(0, fingerprint: fingerprint, screen: "⏺ Done.\n> ", sid: sid))
        #expect(!PhoneMenu.readyToEnter(0, fingerprint: fingerprint, screen: screen, sid: "4243-1700000000"))
    }

    @Test func aTapTypesTheKeysFromWhereTheCursorIsNow() throws {
        let drawn = try #require(PhoneMenu.read(screen: prompt(cursor: 0), needsInput: true))
        let fingerprint = PhoneMenu.fingerprint(drawn, sid: sid)
        let down: [UInt8] = [27, 91, 66], up: [UInt8] = [27, 91, 65]
        guard case .keys(let writes, let label) = PhoneMenu.answer(choose: 2, fingerprint: fingerprint, screen: prompt(cursor: 0),
                                                                   needsInput: true, sid: sid) else {
            Issue.record("not answered")
            return
        }
        #expect(writes.map(\.bytes) == [down, down, [13]])
        #expect(label == "No, and tell Claude what to do differently (esc)")
        // The cursor moved on the Mac since the phone drew it: the same question, keys from where it is now.
        guard case .keys(let fromThere, _) = PhoneMenu.answer(choose: 0, fingerprint: fingerprint, screen: prompt(cursor: 2),
                                                              needsInput: true, sid: sid) else {
            Issue.record("not answered")
            return
        }
        #expect(fromThere.map(\.bytes) == [up, up, [13]])
    }

    @Test func aStaleTapIsRefusedNotTyped() throws {
        let drawn = try #require(PhoneMenu.read(screen: prompt(), needsInput: true))
        let fingerprint = PhoneMenu.fingerprint(drawn, sid: sid)
        // Another question took its place.
        #expect(PhoneMenu.answer(choose: 0, fingerprint: fingerprint, screen: prompt(command: "rm -rf build"), needsInput: true, sid: sid)
                == .stale)
        // It was answered on the Mac and the agent went on.
        #expect(PhoneMenu.answer(choose: 0, fingerprint: fingerprint, screen: "⏺ Done.\n> ", needsInput: false, sid: sid) == .stale)
        // The same prompt in another session (its tab changed hands).
        #expect(PhoneMenu.answer(choose: 0, fingerprint: fingerprint, screen: prompt(), needsInput: true, sid: "4243-1700000000") == .stale)
        // A made-up fingerprint, and options that aren't there.
        #expect(PhoneMenu.answer(choose: 0, fingerprint: "AAAAAAAAAAAAAAAA", screen: prompt(), needsInput: true, sid: sid) == .stale)
        #expect(PhoneMenu.answer(choose: 3, fingerprint: fingerprint, screen: prompt(), needsInput: true, sid: sid) == .invalid)
        #expect(PhoneMenu.answer(choose: -1, fingerprint: fingerprint, screen: prompt(), needsInput: true, sid: sid) == .invalid)
    }
}

/// PH-1, the phone's side: Web/app.js in node on a fake DOM, with a fake Mac (Tests/Web/phone-menu.test.mjs). It draws
/// the state's menu as buttons (text only), hides the quick replies, posts a tap's index with the menu's fingerprint,
/// and shows a 409's message with the menu that's up now. And its Brief me button (Tests/Web/phone-briefing.test.mjs).
struct PhoneWebTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let node: String? = {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return (path + ["/opt/homebrew/bin", "/usr/local/bin"]).map { "\($0)/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    @Test(.enabled(if: node != nil, "node isn't installed on this Mac: the phone's web test can't run"))
    func thePhoneDrawsTheMenuAsButtonsAndPostsATap() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Self.node))
        process.arguments = [Self.repo.appendingPathComponent("Tests/Web/phone-menu.test.mjs").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(text)")
        #expect(text.contains("phone-menu: ok"))
    }

    /// Brief me (Tests/Web/phone-briefing.test.mjs): the press posts /api/briefing with the token, shows a spinner,
    /// asks until it's written, then plays the Mac's bytes from a blob through the page's <audio> and shows the text.
    @Test(.enabled(if: node != nil, "node isn't installed on this Mac: the phone's web test can't run"))
    func thePhonesBriefMePlaysTheBriefingAndShowsItsText() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Self.node))
        process.arguments = [Self.repo.appendingPathComponent("Tests/Web/phone-briefing.test.mjs").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(text)")
        #expect(text.contains("phone-briefing: ok"))
    }
}
