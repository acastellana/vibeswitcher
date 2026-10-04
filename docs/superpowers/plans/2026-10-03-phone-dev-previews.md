# Phone dev-page previews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From the paired phone, open any localhost page that's open in Chrome on the Mac as a live,
interactive page, through VibeSwitcher's authenticating proxy and `tailscale serve`.

**Architecture:**
- **Testable core (VibeCore):** four pure units, unit-tested:
  - `DevPages`: which URLs qualify;
  - `PreviewSlots`: tickets and sessions;
  - `HTTPHead` + `PreviewGate`: parsing, access decisions and header rewriting;
  - `PreviewProxy`: the Network.framework relay, tested against an in-test fake server.
- **App target:** `ChromeTabs` reads Chrome's tabs with AppleScript. `DevPreviews` runs four proxies and
  their `tailscale serve` mappings (:8444–8447 to 127.0.0.1:47824–47827). `PhoneAccess` adds a toggle and
  two API routes.
- **Phone:** the web app gets a "Dev pages" section in the list view.

**Tech Stack:** Swift 6 toolchain (Swift 5 language mode), Network.framework, CryptoKit, Swift Testing,
SwiftUI, plain JS/CSS for the phone app. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-03-phone-dev-previews-design.md`

## Global Constraints

- **Platform and dependencies:**
  - macOS 14+.
  - `swift-tools-version:6.0` with `swiftLanguageModes: [.v5]`.
  - No third-party packages, Swift or JS.
- **Tests:** Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`). Run with `swift test`. All 65
  existing tests must keep passing.
- **Ports:**
  - Preview slots: public HTTPS 8444–8447, local 127.0.0.1:47824–47827.
  - The API stays on 8443 → 47823.
  - Never `tailscale funnel`.
- **Off by default:** the new UserDefaults key is `phoneDevPagesAllowed` (default `false`). Turning Phone
  Access off also stops previews.
- **Tickets and cookies:**
  - Tickets: single use, 60 s, made with `RemoteAuth.newToken()` (32 random bytes).
  - Slot cookie: `vs_preview_<publicPort>=<token>; Path=/; Secure; HttpOnly; SameSite=Strict`.
  - Every proxied request needs `Tailscale-User-Login` equal to this Mac's own login.
- **What may be opened:** only URLs that are open in Chrome at the time of the request. The phone sends an
  opaque `id`, never a URL.
- **Test safety (from the user's memory):** never send input to, or move, the user's real Terminal sessions
  or windows. Integration tests use scratch servers on free ports and scratch Chrome tabs, which you close
  afterwards. Never print the Tailscale login or tailnet host name into chat or commits.
- **User-facing copy:** use exactly the strings given in the tasks.
- **Commits:** one per task, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Don't push.

## Review Focus

1. **Dev server listening only on `::1`** (Vite's default for `localhost` on recent macOS): the proxy must
   still reach it. Pinned in Task 4, `reachesServersListeningOnlyOnIPv6Loopback`.
2. **Large or streamed bodies** (multi-MB bundles, chunked or SSE responses): they must arrive byte-exact,
   streamed rather than buffered. Pinned in Task 4, `streamsLargeResponsesIntact`.
3. **Dev-app auth flows** that redirect to `http://localhost:PORT/login` or set
   `Set-Cookie: …; Domain=localhost`: the redirect becomes a same-origin path and the Domain attribute is
   dropped. Pinned in Task 3, `rewritesDevServerRedirectsAndCookies`.
4. **A Chrome tab URL whose path starts with `//host` or `/\host`**: it must never become a
   protocol-relative redirect off the Mac. Pinned in Task 1, `pathsCanNeverRedirectOffTheMac`.
5. **A slot taken over while an old preview tab is still open:** the old tab gets the "open it again" page
   and never the new server's content. Pinned in Task 2,
   `reusesASlotPerServerAndTakesOverTheLeastRecentlyUsed`, and Task 4,
   `refusesOtherAccountsAndStaleCookiesWithoutContactingTheServer`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/VibeCore/DevPages.swift` (new) | `DevPage`, `PreviewTarget`, URL qualification, dedupe, ids, safe paths |
| `Sources/VibeCore/PreviewSlots.swift` (new) | Slots, tickets, session tokens, LRU takeover |
| `Sources/VibeCore/PreviewGate.swift` (new) | `HTTPHead` (raw head parse/serialize), `PreviewGate` (decide + rewrite) |
| `Sources/VibeCore/PreviewProxy.swift` (new) | Loopback listener and relay (HTTP + upgrades) for one slot |
| `Tests/VibeCoreTests/DevPreviewTests.swift` (new) | Tests for all of the above, including the fake upstream server |
| `Sources/VibeSwitcher/ChromeTabs.swift` (new) | AppleScript read of Chrome's tabs and the failure kinds |
| `Sources/VibeSwitcher/DevPreviews.swift` (new) | Runs 4 proxies and their Tailscale mappings; pages cache; `open(page)` |
| `Sources/VibeSwitcher/Tailscale.swift` (modify) | Port-aware serve/stop and a single-call status read |
| `Sources/VibeSwitcher/PhoneAccess.swift` (modify) | Toggle, lifecycle wiring, `/api/devpages`, `/api/preview`, audit |
| `Sources/VibeSwitcher/PhoneAccessView.swift` (modify) | "Allow opening dev pages" toggle and problem line |
| `Sources/VibeSwitcher/main.swift` (modify) | `--dev-pages` maintenance flag (prints what the phone would list) |
| `Resources/Info.plist` (modify) | Automation usage text mentions Chrome |
| `Web/index.html`, `Web/app.js`, `Web/style.css` (modify) | Dev pages section and the open flow |
| `README.md` (modify) | Feature, security and limits |

---

### Task 1: Which pages qualify (`DevPages`)

**Files:**
- Create: `Sources/VibeCore/DevPages.swift`
- Test: `Tests/VibeCoreTests/DevPreviewTests.swift` (create)

**Interfaces:**
- Produces:
  - `public struct PreviewTarget: Equatable, Hashable, Sendable { connectHost: String; hostHeader: String; port: Int }`
  - `public struct DevPage: Equatable, Sendable { title: String; url: String; target: PreviewTarget; path: String }`
  - `DevPages.reservedPorts: ClosedRange<Int>` (47823…47827)
  - `DevPages.page(url:title:) -> DevPage?`
  - `DevPages.pages(fromTabs: [(url: String, title: String)]) -> [DevPage]`
  - `DevPages.id(for: DevPage) -> String`
  - `DevPages.safePath(_ path: String) -> String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/VibeCoreTests/DevPreviewTests.swift`:

```swift
import Foundation
import Network
import Testing
@testable import VibeCore

struct DevPagesTests {
    @Test func onlyLocalHttpPagesQualify() throws {
        let page = try #require(DevPages.page(url: "http://localhost:5173/settings?tab=2#top", title: " Settings "))
        #expect(page.title == "Settings")
        #expect(page.path == "/settings?tab=2#top")
        #expect(page.target == PreviewTarget(connectHost: "localhost", hostHeader: "localhost:5173", port: 5173))
        #expect(DevPages.page(url: "http://127.0.0.1:3000", title: "")?.title == "127.0.0.1:3000")
        #expect(DevPages.page(url: "http://127.0.0.1:3000", title: "")?.path == "/")
        #expect(DevPages.page(url: "http://[::1]:8080/", title: "x")?.target
                == PreviewTarget(connectHost: "::1", hostHeader: "[::1]:8080", port: 8080))
        #expect(DevPages.page(url: "http://app.localhost:3000/", title: "x")?.target.connectHost == "localhost")
        #expect(DevPages.page(url: "http://app.localhost:3000/", title: "x")?.target.hostHeader == "app.localhost:3000")
        for url in ["https://localhost:5173/", "http://example.com:5173/", "http://192.168.1.4:3000/",
                    "http://localhost/", "http://localhost:47823/", "http://localhost:47826/",
                    "http://user:pw@localhost:3000/", "chrome://settings", "http://localhost.evil.com:3000/"] {
            #expect(DevPages.page(url: url, title: "x") == nil, "\(url)")
        }
    }

    @Test func pathsCanNeverRedirectOffTheMac() {
        #expect(DevPages.page(url: "http://localhost:3000//evil.example/x", title: "x")?.path == "/evil.example/x")
        #expect(DevPages.safePath("/\\evil.example") == "/evil.example")
        #expect(DevPages.safePath("/ok/path?a=1") == "/ok/path?a=1")
        #expect(DevPages.safePath("") == "/")
    }

    @Test func listsEachPageOnceInTabOrder() throws {
        let pages = DevPages.pages(fromTabs: [("http://localhost:5173/", "A"), ("https://github.com/", "B"),
                                              ("http://localhost:5173/", "A again"), ("http://localhost:3000/x", "C")])
        #expect(pages.map(\.title) == ["A", "C"])
        #expect(DevPages.id(for: pages[0]) != DevPages.id(for: pages[1]))
        let renamed = try #require(DevPages.page(url: "http://localhost:5173/", title: "renamed"))
        #expect(DevPages.id(for: pages[0]) == DevPages.id(for: renamed))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DevPagesTests 2>&1 | tail -5`
Expected: build error `cannot find 'DevPages' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/VibeCore/DevPages.swift`:

```swift
import CryptoKit
import Foundation

/// Where a preview connects to: `connectHost` is what to dial ("localhost" lets the system try ::1 and
/// 127.0.0.1), `hostHeader` is what the browser sent as Host ("localhost:5173").
public struct PreviewTarget: Equatable, Hashable, Sendable {
    public var connectHost: String
    public var hostHeader: String
    public var port: Int

    public init(connectHost: String, hostHeader: String, port: Int) {
        self.connectHost = connectHost
        self.hostHeader = hostHeader
        self.port = port
    }
}

/// A localhost page open in Chrome on the Mac, which the paired phone may open as a preview.
public struct DevPage: Equatable, Sendable {
    public var title: String
    public var url: String
    public var target: PreviewTarget
    /// Path, query and fragment, always starting with exactly one "/".
    public var path: String
}

public enum DevPages {
    /// VibeSwitcher's own local ports (the Phone Access API and the preview slots); never offered.
    public static let reservedPorts: ClosedRange<Int> = 47823...47827

    /// The page for a Chrome tab, or nil unless it's plain http on this Mac (localhost, 127.0.0.1, [::1],
    /// *.localhost) on an unprivileged port that isn't ours.
    public static func page(url: String, title: String) -> DevPage? {
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "http",
              components.user == nil, components.password == nil,
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("[") { host = String(host.dropFirst().dropLast()) }
        let connectHost: String
        switch host {
        case "localhost", "127.0.0.1", "::1": connectHost = host
        default:
            guard host.hasSuffix(".localhost") else { return nil }
            connectHost = "localhost"
        }
        let port = components.port ?? 80
        guard (1024...65535).contains(port), !reservedPorts.contains(port) else { return nil }
        let hostHeader = (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
        var path = components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?\(query)" }
        if let fragment = components.percentEncodedFragment { path += "#\(fragment)" }
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        return DevPage(title: cleanTitle.isEmpty ? hostHeader : cleanTitle, url: url,
                       target: PreviewTarget(connectHost: connectHost, hostHeader: hostHeader, port: port),
                       path: safePath(path))
    }

    /// Chrome's tabs, filtered, each page once (same server and path), in tab order.
    public static func pages(fromTabs tabs: [(url: String, title: String)]) -> [DevPage] {
        var seen = Set<String>()
        return tabs.compactMap { tab in
            guard let page = page(url: tab.url, title: tab.title),
                  seen.insert(page.target.hostHeader + page.path).inserted else { return nil }
            return page
        }
    }

    /// Opaque, stable id the phone sends back: it never sends a URL, so it can only pick a listed page.
    public static func id(for page: DevPage) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data((page.target.hostHeader + page.path).utf8))).prefix(12))
    }

    /// A same-origin path: "//evil.example" and "/\evil.example" would be protocol-relative in a redirect.
    public static func safePath(_ path: String) -> String {
        "/" + path.drop { $0 == "/" || $0 == "\\" }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DevPagesTests 2>&1 | tail -5`
Expected: `Suite DevPagesTests passed`. If `[::1]` fails, print `URLComponents(string: "http://[::1]:8080/")?.host`
and adjust the bracket stripping. Both bracketed and bare forms must be accepted.

- [ ] **Step 5: Commit**

```bash
git add Sources/VibeCore/DevPages.swift Tests/VibeCoreTests/DevPreviewTests.swift
git commit -m "Dev pages: which localhost tabs the phone may open

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Slots, tickets and sessions (`PreviewSlots`)

**Files:**
- Create: `Sources/VibeCore/PreviewSlots.swift`
- Test: `Tests/VibeCoreTests/DevPreviewTests.swift` (append)

**Interfaces:**
- Consumes: `PreviewTarget` (Task 1), `RemoteAuth.newToken()`, `RemoteAuth.constantTimeEquals(_:_:)`.
- Produces:
  - `public struct PreviewSlots: Sendable` with `init(count: Int)`, `static ticketLifetime: TimeInterval`
    (60) and `private(set) var slots: [PreviewSlots.Slot]`. `Slot` has `target: PreviewTarget?`,
    `sessionToken: String?`, `lastUsed: Date` and `available: Bool`.
  - `mutating func setAvailable(_ index: Int, _ available: Bool)`
  - `mutating func open(_ target: PreviewTarget, path: String, now: Date = Date(), newToken: () -> String = RemoteAuth.newToken) -> (slot: Int, ticket: String)?`
  - `mutating func redeem(_ ticket: String, slot: Int, now: Date = Date(), newToken: () -> String = RemoteAuth.newToken) -> (path: String, sessionToken: String)?`
  - `mutating func target(slot: Int, sessionToken: String?, now: Date = Date()) -> PreviewTarget?`

- [ ] **Step 1: Write the failing tests** (append to `DevPreviewTests.swift`)

```swift
struct PreviewSlotsTests {
    let vite = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:5173", port: 5173)
    let next = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:3000", port: 3000)
    let other = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "127.0.0.1:8080", port: 8080)
    let t0 = Date(timeIntervalSince1970: 1000)

    func counter() -> () -> String {
        var n = 0
        return { n += 1; return "token\(n)" }
    }

    @Test func ticketsWorkOnceOnTheirOwnSlotWithinAMinute() throws {
        var slots = PreviewSlots(count: 2)
        let tokens = counter()
        let first = try #require(slots.open(vite, path: "/a", now: t0, newToken: tokens))
        // Presented on the wrong slot, a ticket is burned.
        #expect(slots.redeem(first.ticket, slot: first.slot == 0 ? 1 : 0, now: t0, newToken: tokens) == nil)
        #expect(slots.redeem(first.ticket, slot: first.slot, now: t0, newToken: tokens) == nil)
        let second = try #require(slots.open(vite, path: "/b", now: t0, newToken: tokens))
        let entry = try #require(slots.redeem(second.ticket, slot: second.slot, now: t0.addingTimeInterval(59), newToken: tokens))
        #expect(entry.path == "/b")
        #expect(slots.redeem(second.ticket, slot: second.slot, now: t0, newToken: tokens) == nil)
        #expect(slots.target(slot: second.slot, sessionToken: entry.sessionToken, now: t0) == vite)
        #expect(slots.target(slot: second.slot, sessionToken: "nope", now: t0) == nil)
        #expect(slots.target(slot: second.slot, sessionToken: nil, now: t0) == nil)
        let late = try #require(slots.open(vite, path: "/c", now: t0, newToken: tokens))
        #expect(slots.redeem(late.ticket, slot: late.slot, now: t0.addingTimeInterval(61), newToken: tokens) == nil)
    }

    @Test func reusesASlotPerServerAndTakesOverTheLeastRecentlyUsed() throws {
        var slots = PreviewSlots(count: 1)
        let tokens = counter()
        let first = try #require(slots.open(vite, path: "/", now: t0, newToken: tokens))
        let viteSession = try #require(slots.redeem(first.ticket, slot: 0, now: t0, newToken: tokens)).sessionToken
        // The same server again: same slot, same session, so tabs already open keep working.
        let second = try #require(slots.open(vite, path: "/x", now: t0, newToken: tokens))
        #expect(second.slot == 0)
        #expect(try #require(slots.redeem(second.ticket, slot: 0, now: t0, newToken: tokens)).sessionToken == viteSession)
        // Another server takes the only slot: the old session stops working and never sees the new server.
        let third = try #require(slots.open(next, path: "/", now: t0.addingTimeInterval(1), newToken: tokens))
        #expect(third.slot == 0)
        #expect(slots.target(slot: 0, sessionToken: viteSession, now: t0) == nil)
        #expect(try #require(slots.redeem(third.ticket, slot: 0, now: t0, newToken: tokens)).sessionToken != viteSession)
    }

    @Test func picksTheLeastRecentlyUsedSlotAndSkipsUnavailableOnes() throws {
        var slots = PreviewSlots(count: 3)
        let tokens = counter()
        slots.setAvailable(2, false)
        let a = try #require(slots.open(vite, path: "/", now: t0, newToken: tokens))
        let b = try #require(slots.open(next, path: "/", now: t0.addingTimeInterval(1), newToken: tokens))
        #expect([a.slot, b.slot] == [0, 1])
        let aSession = try #require(slots.redeem(a.ticket, slot: a.slot, now: t0, newToken: tokens)).sessionToken
        _ = slots.target(slot: a.slot, sessionToken: aSession, now: t0.addingTimeInterval(2))   // slot 0 used last
        let c = try #require(slots.open(other, path: "/", now: t0.addingTimeInterval(3), newToken: tokens))
        #expect(c.slot == 1)
        slots.setAvailable(0, false)
        slots.setAvailable(1, false)
        #expect(slots.open(vite, path: "/", now: t0, newToken: tokens) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PreviewSlotsTests 2>&1 | tail -5`
Expected: build error `cannot find 'PreviewSlots' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/VibeCore/PreviewSlots.swift`:

```swift
import Foundation

/// The phone's preview slots. Each slot shows one dev server at a time. The phone gets a one-time ticket
/// (60 s) for a slot; redeeming it on that slot's port yields the slot's session token, which the slot's
/// cookie carries from then on. Giving a slot to another server ends its session, so a tab still open
/// on the old server can't see the new one.
public struct PreviewSlots: Sendable {
    public static let ticketLifetime: TimeInterval = 60

    public struct Slot: Equatable, Sendable {
        public var target: PreviewTarget?
        public var sessionToken: String?
        public var lastUsed = Date.distantPast
        /// False while its listener or Tailscale mapping isn't up.
        public var available = true
    }

    private struct Ticket: Sendable {
        var slot: Int
        var path: String
        var expires: Date
    }

    public private(set) var slots: [Slot]
    private var tickets: [String: Ticket] = [:]

    public init(count: Int) {
        slots = Array(repeating: Slot(), count: count)
    }

    public mutating func setAvailable(_ index: Int, _ available: Bool) {
        guard slots.indices.contains(index) else { return }
        slots[index].available = available
        if !available { clear(index) }
    }

    /// A slot for `target` (the one already showing it, else a free one, else the least recently used)
    /// and a new ticket that opens `path` there. Nil when no slot is available.
    public mutating func open(_ target: PreviewTarget, path: String, now: Date = Date(),
                              newToken: () -> String = RemoteAuth.newToken) -> (slot: Int, ticket: String)? {
        tickets = tickets.filter { $0.value.expires > now }
        let usable = slots.indices.filter { slots[$0].available }
        guard let index = usable.first(where: { slots[$0].target == target })
                ?? usable.first(where: { slots[$0].target == nil })
                ?? usable.min(by: { slots[$0].lastUsed < slots[$1].lastUsed }) else { return nil }
        if slots[index].target != target {
            clear(index)
            slots[index].target = target
        }
        slots[index].lastUsed = now
        let ticket = newToken()
        tickets[ticket] = Ticket(slot: index, path: path, expires: now.addingTimeInterval(Self.ticketLifetime))
        return (index, ticket)
    }

    /// Single use: the ticket is gone after this call, whatever the outcome.
    public mutating func redeem(_ ticket: String, slot: Int, now: Date = Date(),
                                newToken: () -> String = RemoteAuth.newToken) -> (path: String, sessionToken: String)? {
        guard let entry = tickets.removeValue(forKey: ticket), entry.slot == slot, entry.expires > now,
              slots.indices.contains(slot), slots[slot].target != nil else { return nil }
        let token = slots[slot].sessionToken ?? newToken()
        slots[slot].sessionToken = token
        slots[slot].lastUsed = now
        return (entry.path, token)
    }

    /// What a request on `slot` carrying `sessionToken` may reach, or nil.
    public mutating func target(slot: Int, sessionToken: String?, now: Date = Date()) -> PreviewTarget? {
        guard let sessionToken, slots.indices.contains(slot), let expected = slots[slot].sessionToken,
              RemoteAuth.constantTimeEquals(expected, sessionToken) else { return nil }
        slots[slot].lastUsed = now
        return slots[slot].target
    }

    private mutating func clear(_ index: Int) {
        slots[index].target = nil
        slots[index].sessionToken = nil
        tickets = tickets.filter { $0.value.slot != index }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PreviewSlotsTests 2>&1 | tail -5`
Expected: `Suite PreviewSlotsTests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/VibeCore/PreviewSlots.swift Tests/VibeCoreTests/DevPreviewTests.swift
git commit -m "Dev pages: preview slots, one-time tickets and slot sessions

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Who gets through, and header rewriting (`HTTPHead`, `PreviewGate`)

**Files:**
- Create: `Sources/VibeCore/PreviewGate.swift`
- Test: `Tests/VibeCoreTests/DevPreviewTests.swift` (append)

**Interfaces:**
- Consumes: `PreviewTarget`, `DevPages.safePath` (Task 1).
- Produces:
  - **`HTTPHead`** (`Equatable, Sendable`):
    - fields `startLine` and `fields: [Field]`, where `Field` has `name` and `value`;
    - `enum Kind { request, response }`;
    - `enum ParseResult: Equatable { incomplete, invalid, tooLarge, complete(HTTPHead, consumed: Int) }`;
    - `static func parse(_ data: Data, kind: Kind, maxBytes: Int = 65536) -> ParseResult`;
    - lookups `value(_:)`, `values(_:)` and edits `set(_:_:)`, `remove(_:)`;
    - computed `serialized: Data`, `method`, `path`, `query: [String: String]` and `status: Int?`.
  - **`PreviewGate`:**
    - `enum Decision: Equatable { reject(status: Int, message: String), enter(ticket: String), forward(sessionToken: String) }`;
    - `enterPath`, plus the messages `wrongAccountMessage`, `expiredMessage`, `crossOriginMessage` and
      `unreachableMessage(_:)`;
    - `cookieName(publicPort:)`, `setCookie(publicPort:token:)`;
    - `decide(_:owner:ownOrigin:siblingOrigins:publicPort:)`, `isUpgrade(_:)`;
    - `upstreamRequest(_:target:ownOrigin:publicPort:)`, `clientResponse(_:target:)`.

- [ ] **Step 1: Write the failing tests** (append)

```swift
func requestHead(_ raw: String) -> HTTPHead {
    guard case .complete(let head, _) = HTTPHead.parse(Data((raw + "\r\n").utf8), kind: .request) else {
        fatalError("test request didn't parse: \(raw)")
    }
    return head
}

func responseHead(_ raw: String) -> HTTPHead {
    guard case .complete(let head, _) = HTTPHead.parse(Data((raw + "\r\n").utf8), kind: .response) else {
        fatalError("test response didn't parse: \(raw)")
    }
    return head
}

struct HTTPHeadTests {
    @Test func parsesAndReserializesHeads() throws {
        let raw = "GET /a?b=1 HTTP/1.1\r\nHost: x\r\nCookie: a=1\r\nCookie: b=2\r\n\r\nBODY"
        guard case .complete(let head, let consumed) = HTTPHead.parse(Data(raw.utf8), kind: .request) else {
            Issue.record("not parsed"); return
        }
        #expect(consumed == raw.utf8.count - 4)
        #expect(head.method == "GET")
        #expect(head.path == "/a")
        #expect(head.query == ["b": "1"])
        #expect(head.values("COOKIE") == ["a=1", "b=2"])
        #expect(String(decoding: head.serialized, as: UTF8.self) == String(raw.dropLast(4)))
        #expect(responseHead("HTTP/1.1 204\r\n").status == 204)
        #expect(HTTPHead.parse(Data("GET / HTTP/1.1\r\nHost".utf8), kind: .request) == .incomplete)
        #expect(HTTPHead.parse(Data("GET http://x/ HTTP/1.1\r\n\r\n".utf8), kind: .request) == .invalid)
        #expect(HTTPHead.parse(Data("SSH-2.0-OpenSSH\r\n\r\n".utf8), kind: .response) == .invalid)
        #expect(HTTPHead.parse(Data(String(repeating: "a", count: 70_000).utf8), kind: .request) == .tooLarge)
    }

    @Test func editsKeepOneValuePerName() {
        var head = requestHead("GET / HTTP/1.1\r\nConnection: keep-alive\r\nconnection: x\r\n")
        head.set("Connection", "close")
        #expect(head.values("connection") == ["close"])
        head.remove("CONNECTION")
        #expect(head.value("connection") == nil)
        head.set("Host", "a")
        #expect(head.fields.last == HTTPHead.Field(name: "Host", value: "a"))
    }
}

struct PreviewGateTests {
    let own = "https://mac.example.ts.net:8444"
    let siblings: Set<String> = Set((8443...8447).map { "https://mac.example.ts.net:\($0)" })
    let me = "Tailscale-User-Login: me@example.com\r\n"

    func decide(_ raw: String) -> PreviewGate.Decision {
        PreviewGate.decide(requestHead(raw), owner: "me@example.com", ownOrigin: own, siblingOrigins: siblings, publicPort: 8444)
    }

    @Test func decidesWhoGetsThrough() {
        #expect(decide("GET / HTTP/1.1\r\nCookie: vs_preview_8444=T\r\n")
                == .reject(status: 403, message: PreviewGate.wrongAccountMessage))
        #expect(decide("GET / HTTP/1.1\r\nTailscale-User-Login: other@example.com\r\nCookie: vs_preview_8444=T\r\n")
                == .reject(status: 403, message: PreviewGate.wrongAccountMessage))
        #expect(decide("GET /__vibeswitcher/enter?t=abc HTTP/1.1\r\n\(me)") == .enter(ticket: "abc"))
        #expect(decide("GET /x HTTP/1.1\r\n\(me)Cookie: a=1; vs_preview_8444=T\r\n") == .forward(sessionToken: "T"))
        #expect(decide("GET /x HTTP/1.1\r\n\(me)") == .reject(status: 403, message: PreviewGate.expiredMessage))
        // Another slot's cookie is not this slot's (cookies ignore ports).
        #expect(decide("GET /x HTTP/1.1\r\n\(me)Cookie: vs_preview_8445=T\r\n")
                == .reject(status: 403, message: PreviewGate.expiredMessage))
        // A page in another slot (or the app itself) may not use this slot's session.
        #expect(decide("POST /x HTTP/1.1\r\n\(me)Cookie: vs_preview_8444=T\r\nOrigin: https://mac.example.ts.net:8445\r\n")
                == .reject(status: 403, message: PreviewGate.crossOriginMessage))
        #expect(decide("POST /x HTTP/1.1\r\n\(me)Cookie: vs_preview_8444=T\r\nOrigin: \(own)\r\n") == .forward(sessionToken: "T"))
    }

    @Test func rewritesRequestsForTheDevServer() {
        let target = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:5173", port: 5173)
        let rewritten = PreviewGate.upstreamRequest(requestHead(
            "GET /src/main.ts HTTP/1.1\r\nHost: mac.example.ts.net:8444\r\n\(me)Tailscale-User-Name: Me\r\n"
            + "Origin: \(own)\r\nReferer: \(own)/settings\r\nCookie: theme=dark; vs_preview_8444=T\r\n"
            + "Connection: keep-alive\r\nKeep-Alive: timeout=5\r\n"), target: target, ownOrigin: own, publicPort: 8444)
        #expect(rewritten.startLine == "GET /src/main.ts HTTP/1.1")
        #expect(rewritten.value("host") == "localhost:5173")
        #expect(rewritten.value("origin") == "http://localhost:5173")
        #expect(rewritten.value("referer") == "http://localhost:5173/settings")
        #expect(rewritten.values("cookie") == ["theme=dark"])
        #expect(rewritten.value("tailscale-user-login") == nil)
        #expect(rewritten.value("tailscale-user-name") == nil)
        #expect(rewritten.value("connection") == "close")
        #expect(rewritten.value("keep-alive") == nil)
        let bare = PreviewGate.upstreamRequest(requestHead("GET / HTTP/1.1\r\nCookie: vs_preview_8444=T\r\n"),
                                               target: target, ownOrigin: own, publicPort: 8444)
        #expect(bare.value("cookie") == nil)
        let upgrade = PreviewGate.upstreamRequest(requestHead("GET /hmr HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"),
                                                  target: target, ownOrigin: own, publicPort: 8444)
        #expect(upgrade.value("connection") == "Upgrade")
    }

    @Test func rewritesDevServerRedirectsAndCookies() {
        let target = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:3000", port: 3000)
        let response = PreviewGate.clientResponse(responseHead(
            "HTTP/1.1 302 Found\r\nLocation: http://localhost:3000/login?next=%2F\r\n"
            + "Set-Cookie: sid=abc; Domain=localhost; Path=/; HttpOnly\r\nSet-Cookie: theme=dark; domain=.localhost\r\n"
            + "Connection: keep-alive\r\n"), target: target)
        #expect(response.value("location") == "/login?next=%2F")
        #expect(response.values("set-cookie") == ["sid=abc; Path=/; HttpOnly", "theme=dark"])
        #expect(response.value("connection") == "close")
        #expect(PreviewGate.clientResponse(responseHead("HTTP/1.1 301 Moved\r\nLocation: http://127.0.0.1:3000\r\n"),
                                           target: target).value("location") == "/")
        #expect(PreviewGate.clientResponse(responseHead("HTTP/1.1 302 Found\r\nLocation: http://localhost:3000//evil.example\r\n"),
                                           target: target).value("location") == "/evil.example")
        #expect(PreviewGate.clientResponse(responseHead("HTTP/1.1 302 Found\r\nLocation: https://accounts.example.com/o\r\n"),
                                           target: target).value("location") == "https://accounts.example.com/o")
        #expect(PreviewGate.clientResponse(responseHead("HTTP/1.1 302 Found\r\nLocation: http://localhost:4000/\r\n"),
                                           target: target).value("location") == "http://localhost:4000/")
        #expect(PreviewGate.clientResponse(responseHead("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"),
                                           target: target).value("connection") == "Upgrade")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "HTTPHeadTests|PreviewGateTests" 2>&1 | tail -5`
Expected: build error `cannot find 'HTTPHead' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/VibeCore/PreviewGate.swift`:

```swift
import Foundation

/// An HTTP/1.x message head kept as raw lines (order, case and duplicates preserved), so a proxy can
/// change a few fields and pass everything else through untouched. ISO Latin-1 round-trips every byte.
public struct HTTPHead: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var name: String
        public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }

    public enum Kind: Sendable { case request, response }

    public enum ParseResult: Equatable {
        case incomplete
        case invalid
        case tooLarge
        /// `consumed`: bytes of the head including the blank line; what follows is the body.
        case complete(HTTPHead, consumed: Int)
    }

    public var startLine: String
    public var fields: [Field]

    public init(startLine: String, fields: [Field]) {
        self.startLine = startLine
        self.fields = fields
    }

    public static func parse(_ data: Data, kind: Kind, maxBytes: Int = 64 * 1024) -> ParseResult {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxBytes ? .tooLarge : .incomplete
        }
        let length = end.lowerBound - data.startIndex
        guard length <= maxBytes else { return .tooLarge }
        guard let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .isoLatin1) else { return .invalid }
        var lines = text.components(separatedBy: "\r\n")
        let start = lines.removeFirst()
        let parts = start.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        switch kind {
        case .request:
            guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), !parts[0].isEmpty,
                  parts[0].allSatisfy({ $0.isLetter }), parts[1].hasPrefix("/") else { return .invalid }
        case .response:
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]),
                  (100...599).contains(code) else { return .invalid }
        }
        var fields: [Field] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = String(line[..<colon])
            guard !name.isEmpty, !name.contains(" "), !name.contains("\t") else { return .invalid }
            fields.append(Field(name: name, value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return .complete(HTTPHead(startLine: start, fields: fields), consumed: length + 4)
    }

    public var serialized: Data {
        let lines = [startLine] + fields.map { "\($0.name): \($0.value)" }
        return (lines.joined(separator: "\r\n") + "\r\n\r\n").data(using: .isoLatin1) ?? Data()
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    public func value(_ name: String) -> String? { fields.first { Self.same($0.name, name) }?.value }
    public func values(_ name: String) -> [String] { fields.filter { Self.same($0.name, name) }.map(\.value) }

    public mutating func remove(_ name: String) { fields.removeAll { Self.same($0.name, name) } }

    /// Replaces the first field of that name (dropping any others), or appends it.
    public mutating func set(_ name: String, _ value: String) {
        guard let index = fields.firstIndex(where: { Self.same($0.name, name) }) else {
            fields.append(Field(name: name, value: value))
            return
        }
        fields[index].value = value
        fields = fields.enumerated().filter { $0.offset <= index || !Self.same($0.element.name, name) }.map(\.element)
    }

    private var startParts: [Substring] { startLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false) }
    public var method: String { startParts.first.map(String.init) ?? "" }
    private var target: String { startParts.count > 1 ? String(startParts[1]) : "" }
    public var path: String { String(target.prefix { $0 != "?" }) }
    public var query: [String: String] {
        var query: [String: String] = [:]
        for item in URLComponents(string: target)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return query
    }
    public var status: Int? { startParts.count > 1 ? Int(startParts[1]) : nil }
}

/// Access decisions and header rewriting for one preview slot (see `PreviewProxy`).
public enum PreviewGate {
    public enum Decision: Equatable, Sendable {
        case reject(status: Int, message: String)
        case enter(ticket: String)
        case forward(sessionToken: String)
    }

    public static let enterPath = "/__vibeswitcher/enter"
    public static let wrongAccountMessage = "This page is only for the Tailscale account that runs VibeSwitcher."
    public static let expiredMessage = "This preview has expired. Open it again from VibeSwitcher on your phone."
    public static let crossOriginMessage = "Blocked: another page tried to use this preview."
    public static func unreachableMessage(_ target: PreviewTarget) -> String {
        "\(target.hostHeader) isn't answering. Is the dev server still running?"
    }

    /// Cookies ignore ports, so every slot needs its own cookie name.
    public static func cookieName(publicPort: Int) -> String { "vs_preview_\(publicPort)" }
    public static func setCookie(publicPort: Int, token: String) -> String {
        "\(cookieName(publicPort: publicPort))=\(token); Path=/; Secure; HttpOnly; SameSite=Strict"
    }

    public static func decide(_ head: HTTPHead, owner: String, ownOrigin: String, siblingOrigins: Set<String>,
                              publicPort: Int) -> Decision {
        guard head.value("tailscale-user-login") == owner else { return .reject(status: 403, message: wrongAccountMessage) }
        if let origin = head.value("origin"), origin != ownOrigin, siblingOrigins.contains(origin) {
            return .reject(status: 403, message: crossOriginMessage)
        }
        if head.path == enterPath, let ticket = head.query["t"], !ticket.isEmpty { return .enter(ticket: ticket) }
        guard let token = cookie(cookieName(publicPort: publicPort), in: head) else {
            return .reject(status: 403, message: expiredMessage)
        }
        return .forward(sessionToken: token)
    }

    public static func isUpgrade(_ head: HTTPHead) -> Bool {
        head.value("upgrade") != nil && (head.value("connection") ?? "").lowercased().contains("upgrade")
    }

    /// What the dev server sees: its own Host/Origin (Vite checks them), no Tailscale identity headers,
    /// no VibeSwitcher cookie, and one request per connection so every request is authenticated.
    public static func upstreamRequest(_ head: HTTPHead, target: PreviewTarget, ownOrigin: String,
                                       publicPort: Int) -> HTTPHead {
        var head = head
        head.fields.removeAll { $0.name.lowercased().hasPrefix("tailscale-") }
        let ours = cookieName(publicPort: publicPort) + "="
        let kept = head.values("cookie").flatMap { $0.split(separator: ";") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(ours) }
        head.remove("cookie")
        if !kept.isEmpty { head.set("Cookie", kept.joined(separator: "; ")) }
        head.set("Host", target.hostHeader)
        let local = "http://\(target.hostHeader)"
        if head.value("origin") == ownOrigin { head.set("Origin", local) }
        if let referer = head.value("referer"), referer == ownOrigin || referer.hasPrefix(ownOrigin + "/") {
            head.set("Referer", local + referer.dropFirst(ownOrigin.count))
        }
        if !isUpgrade(head) {
            head.remove("keep-alive")
            head.remove("proxy-connection")
            head.set("Connection", "close")
        }
        return head
    }

    /// What the phone sees: redirects to the dev server's own address become paths, cookies lose a
    /// `Domain=localhost` the phone's browser would reject, and the connection closes after the response.
    public static func clientResponse(_ head: HTTPHead, target: PreviewTarget) -> HTTPHead {
        var head = head
        if let location = head.value("location"), let path = localPath(location, port: target.port) {
            head.set("Location", path)
        }
        for index in head.fields.indices where head.fields[index].name.lowercased() == "set-cookie" {
            head.fields[index].value = head.fields[index].value
                .replacingOccurrences(of: #";\s*[Dd][Oo][Mm][Aa][Ii][Nn]=[^;]*"#, with: "", options: .regularExpression)
        }
        if head.status != 101 {
            head.remove("keep-alive")
            head.set("Connection", "close")
        }
        return head
    }

    /// "/login" for "http://localhost:3000/login" (or 127.0.0.1, [::1], *.localhost) on the target's port.
    static func localPath(_ location: String, port: Int) -> String? {
        guard let components = URLComponents(string: location), components.scheme?.lowercased() == "http",
              components.port == port, var host = components.host?.lowercased() else { return nil }
        if host.hasPrefix("[") { host = String(host.dropFirst().dropLast()) }
        guard ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".localhost") else { return nil }
        var path = components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?\(query)" }
        if let fragment = components.percentEncodedFragment { path += "#\(fragment)" }
        return DevPages.safePath(path)
    }

    static func cookie(_ name: String, in head: HTTPHead) -> String? {
        for value in head.values("cookie") {
            for pair in value.split(separator: ";") {
                let pair = pair.trimmingCharacters(in: .whitespaces)
                if pair.hasPrefix("\(name)=") { return String(pair.dropFirst(name.count + 1)) }
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "HTTPHeadTests|PreviewGateTests" 2>&1 | tail -5`
Expected: both suites pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VibeCore/PreviewGate.swift Tests/VibeCoreTests/DevPreviewTests.swift
git commit -m "Dev pages: request gate and header rewriting for previews

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The relay (`PreviewProxy`)

**Files:**
- Create: `Sources/VibeCore/PreviewProxy.swift`
- Test: `Tests/VibeCoreTests/DevPreviewTests.swift` (append)

**Interfaces:**
- Consumes: `HTTPHead`, `PreviewGate`, `PreviewTarget` (Tasks 1 and 3).
- Produces:
  - `public final class PreviewProxy`, with
    `init(label: String, context: @escaping () -> Context?, redeem: @escaping (String) -> (path: String, sessionToken: String)?, resolve: @escaping (String) -> PreviewTarget?)`.
  - `PreviewProxy.Context(owner:ownOrigin:siblingOrigins:publicPort:)`.
  - `start(port: UInt16, callbackQueue: DispatchQueue = .main, onReady: @escaping () -> Void, onFailure: @escaping (String) -> Void)`;
    port 0 means any free port.
  - `var port: UInt16?`, `var isListening: Bool`, `func stop()`.

- [ ] **Step 1: Write the failing tests** (append)

```swift
/// A one-request-per-connection HTTP server for proxy tests. It records each request head, answers with
/// `reply`, and then closes, or with `echoAfterReply` keeps echoing (an upgraded connection).
final class FakeUpstream: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-upstream")
    private var heads: [String] = []
    var reply = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8)
    var echoAfterReply = false

    init(host: String = "127.0.0.1") throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard case .ready = state, !resumed else { return }
                resumed = true
                continuation.resume(returning: listener.port!.rawValue)
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.readHead(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    var recorded: [String] { queue.sync { heads } }
    func stop() { listener.cancel() }

    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if !done { self.readHead(connection, buffer: buffer) }
                return
            }
            self.heads.append(String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self))
            connection.send(content: self.reply, completion: .contentProcessed { _ in
                if self.echoAfterReply { self.echo(connection) } else { connection.cancel() }
            })
        }
    }

    private func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            if let data, !data.isEmpty { connection.send(content: data, completion: .contentProcessed { _ in }) }
            if done { connection.cancel() } else { self?.echo(connection) }
        }
    }
}

/// Sends `request` to 127.0.0.1:`port`; returns everything received until the server closes.
func exchange(port: UInt16, _ request: String, timeout: TimeInterval = 5) async -> Data {
    await withCheckedContinuation { continuation in
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "test-client")
        var received = Data()
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            connection.cancel()
            continuation.resume(returning: received)
        }
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
                if let data { received.append(data) }
                if done || error != nil { finish() } else { read() }
            }
        }
        connection.start(queue: queue)
        connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in read() })
        queue.asyncAfter(deadline: .now() + timeout) { finish() }
    }
}

/// Sends an upgrade request; once the response head arrives, sends `payload` and waits for it to come back.
func upgradeExchange(port: UInt16, _ request: String, payload: Data) async -> (head: String, echoed: Data) {
    await withCheckedContinuation { continuation in
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "test-upgrade")
        var buffer = Data()
        var head: String?
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            connection.cancel()
            continuation.resume(returning: (head ?? String(decoding: buffer, as: UTF8.self), head == nil ? Data() : buffer))
        }
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let data { buffer.append(data) }
                if head == nil, let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    head = String(decoding: buffer[buffer.startIndex..<end.upperBound], as: UTF8.self)
                    buffer = Data(buffer[end.upperBound...])
                    connection.send(content: payload, completion: .contentProcessed { _ in })
                }
                if head != nil, buffer.count >= payload.count { return finish() }
                if done || error != nil { finish() } else { read() }
            }
        }
        connection.start(queue: queue)
        connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in read() })
        queue.asyncAfter(deadline: .now() + 5) { finish() }
    }
}

struct ProxyStartFailure: Error { let message: String }

struct PreviewProxyTests {
    static let me = "Tailscale-User-Login: me@example.com\r\n"
    static let ours = "Cookie: vs_preview_8444=TOK\r\n"

    func startProxy(target: PreviewTarget?, redeemed: (path: String, sessionToken: String)? = nil) async throws -> (PreviewProxy, UInt16) {
        let proxy = PreviewProxy(label: "test-proxy", context: {
            PreviewProxy.Context(owner: "me@example.com", ownOrigin: "https://mac.example.ts.net:8444",
                                 siblingOrigins: Set((8443...8447).map { "https://mac.example.ts.net:\($0)" }), publicPort: 8444)
        }, redeem: { $0 == "TICKET" ? redeemed : nil }, resolve: { $0 == "TOK" ? target : nil })
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            proxy.start(port: 0, callbackQueue: .global(), onReady: { continuation.resume(returning: proxy.port!) },
                        onFailure: { continuation.resume(throwing: ProxyStartFailure(message: $0)) })
        }
        return (proxy, port)
    }

    func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func ticketSetsTheSlotCookieAndRedirects() async throws {
        let (proxy, port) = try await startProxy(target: nil, redeemed: ("/app?x=1", "TOK"))
        defer { proxy.stop() }
        let response = text(await exchange(port: port, "GET /__vibeswitcher/enter?t=TICKET HTTP/1.1\r\n\(Self.me)\r\n"))
        #expect(response.hasPrefix("HTTP/1.1 302"))
        #expect(response.contains("Location: /app?x=1\r\n"))
        #expect(response.contains("Set-Cookie: vs_preview_8444=TOK; Path=/; Secure; HttpOnly; SameSite=Strict\r\n"))
        let wrong = text(await exchange(port: port, "GET /__vibeswitcher/enter?t=WRONG HTTP/1.1\r\n\(Self.me)\r\n"))
        #expect(wrong.hasPrefix("HTTP/1.1 403"))
    }

    @Test func forwardsToTheDevServerWithLocalHeaders() async throws {
        let upstream = try FakeUpstream()
        let upstreamPort = await upstream.start()
        upstream.reply = Data(("HTTP/1.1 302 Found\r\nLocation: http://localhost:\(upstreamPort)/login\r\n"
                               + "Set-Cookie: sid=1; Domain=localhost; Path=/\r\nContent-Length: 2\r\n\r\nok").utf8)
        let target = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "localhost:\(upstreamPort)", port: Int(upstreamPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let response = text(await exchange(port: port,
            "GET /x?y=1 HTTP/1.1\r\nHost: mac.example.ts.net:8444\r\n\(Self.me)Tailscale-User-Name: Me\r\n"
            + "Origin: https://mac.example.ts.net:8444\r\nCookie: theme=dark; vs_preview_8444=TOK\r\nConnection: keep-alive\r\n\r\n"))
        let seen = try #require(upstream.recorded.first)
        #expect(seen.hasPrefix("GET /x?y=1 HTTP/1.1\r\n"))
        #expect(seen.contains("Host: localhost:\(upstreamPort)"))
        #expect(seen.contains("Origin: http://localhost:\(upstreamPort)"))
        #expect(seen.contains("Cookie: theme=dark"))
        #expect(!seen.contains("vs_preview"))
        #expect(!seen.lowercased().contains("tailscale-"))
        #expect(seen.contains("Connection: close"))
        #expect(response.contains("Location: /login\r\n"))
        #expect(response.contains("Set-Cookie: sid=1; Path=/\r\n"))
        #expect(response.hasSuffix("\r\n\r\nok"))
    }

    @Test func refusesOtherAccountsAndStaleCookiesWithoutContactingTheServer() async throws {
        let upstream = try FakeUpstream()
        let upstreamPort = await upstream.start()
        let target = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "localhost:\(upstreamPort)", port: Int(upstreamPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let other = text(await exchange(port: port, "GET / HTTP/1.1\r\nTailscale-User-Login: someone@else.com\r\n\(Self.ours)\r\n"))
        #expect(other.hasPrefix("HTTP/1.1 403"))
        let stale = text(await exchange(port: port, "GET / HTTP/1.1\r\n\(Self.me)Cookie: vs_preview_8444=OLD\r\n\r\n"))
        #expect(stale.hasPrefix("HTTP/1.1 403"))
        #expect(stale.contains("Open it again from VibeSwitcher"))
        let crossSlot = text(await exchange(port: port,
            "POST / HTTP/1.1\r\n\(Self.me)\(Self.ours)Origin: https://mac.example.ts.net:8445\r\nContent-Length: 0\r\n\r\n"))
        #expect(crossSlot.hasPrefix("HTTP/1.1 403"))
        #expect(upstream.recorded.isEmpty)
    }

    @Test func streamsLargeResponsesIntact() async throws {
        let upstream = try FakeUpstream()
        let upstreamPort = await upstream.start()
        let body = Data((0..<5_000_000).map { UInt8($0 % 251) })
        upstream.reply = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        let target = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "localhost:\(upstreamPort)", port: Int(upstreamPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let response = await exchange(port: port, "GET /big.js HTTP/1.1\r\n\(Self.me)\(Self.ours)\r\n", timeout: 15)
        let split = try #require(response.range(of: Data("\r\n\r\n".utf8)))
        #expect(Data(response[split.upperBound...]) == body)
    }

    @Test func reachesServersListeningOnlyOnIPv6Loopback() async throws {
        let upstream = try FakeUpstream(host: "::1")
        let upstreamPort = await upstream.start()
        let target = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:\(upstreamPort)", port: Int(upstreamPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let response = text(await exchange(port: port, "GET / HTTP/1.1\r\n\(Self.me)\(Self.ours)\r\n"))
        #expect(response.hasPrefix("HTTP/1.1 200"))
        #expect(response.hasSuffix("ok"))
    }

    @Test func answers502WhenTheDevServerIsDown() async throws {
        let probe = try FakeUpstream()
        let deadPort = await probe.start()
        probe.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        let target = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "localhost:\(deadPort)", port: Int(deadPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop() }
        let response = text(await exchange(port: port, "GET / HTTP/1.1\r\n\(Self.me)\(Self.ours)\r\n", timeout: 10))
        #expect(response.hasPrefix("HTTP/1.1 502"))
        #expect(response.contains("isn't answering"))
    }

    @Test func pipesUpgradedConnectionsBothWays() async throws {
        let upstream = try FakeUpstream()
        upstream.echoAfterReply = true
        upstream.reply = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".utf8)
        let upstreamPort = await upstream.start()
        let target = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "localhost:\(upstreamPort)", port: Int(upstreamPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let result = await upgradeExchange(port: port,
            "GET /hmr HTTP/1.1\r\n\(Self.me)\(Self.ours)Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n", payload: Data("ping".utf8))
        #expect(result.head.hasPrefix("HTTP/1.1 101"))
        #expect(!result.head.contains("Connection: close"))
        #expect(result.echoed == Data("ping".utf8))
        let seen = try #require(upstream.recorded.first)
        #expect(seen.contains("Connection: Upgrade"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PreviewProxyTests 2>&1 | tail -5`
Expected: build error `cannot find 'PreviewProxy' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/VibeCore/PreviewProxy.swift`:

```swift
import Foundation
import Network

/// One preview slot's listener on 127.0.0.1 (the way in from the phone is `tailscale serve`).
/// Each request is checked by `PreviewGate`:
/// - `/__vibeswitcher/enter?t=` redeems a ticket into the slot's cookie;
/// - anything else needs that cookie, and is relayed to the dev server with local headers.
/// Responses are streamed back. Websocket upgrades are piped both ways until either side closes.
public final class PreviewProxy: @unchecked Sendable {
    public struct Context: Sendable {
        public var owner: String
        public var ownOrigin: String
        public var siblingOrigins: Set<String>
        public var publicPort: Int

        public init(owner: String, ownOrigin: String, siblingOrigins: Set<String>, publicPort: Int) {
            self.owner = owner
            self.ownOrigin = ownOrigin
            self.siblingOrigins = siblingOrigins
            self.publicPort = publicPort
        }
    }

    private final class Flag { var value = false }

    private static let maxConnections = 64
    private let queue: DispatchQueue
    private var listener: NWListener?
    /// Everything below is touched on `queue` only.
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var upstreams: [ObjectIdentifier: NWConnection] = [:]   // keyed by their client
    private let context: () -> Context?
    private let redeem: (String) -> (path: String, sessionToken: String)?
    private let resolve: (String) -> PreviewTarget?

    public init(label: String, context: @escaping () -> Context?,
                redeem: @escaping (String) -> (path: String, sessionToken: String)?,
                resolve: @escaping (String) -> PreviewTarget?) {
        queue = DispatchQueue(label: label)
        self.context = context
        self.redeem = redeem
        self.resolve = resolve
    }

    /// Exactly one callback runs, on `callbackQueue`. Port 0: any free port (see `port`).
    public func start(port: UInt16, callbackQueue: DispatchQueue = .main,
                      onReady: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = false
        guard let listener = try? NWListener(using: parameters) else {
            callbackQueue.async { onFailure("Couldn't open local port \(port).") }
            return
        }
        var reported = false
        let report: (String?) -> Void = { failure in     // on `queue`
            guard !reported else { return }
            reported = true
            callbackQueue.async { if let failure { onFailure(failure) } else { onReady() } }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: report(nil)
            case .failed(let error), .waiting(let error):
                listener.cancel()
                report("Local port \(port) unavailable (\(error)).")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public var port: UInt16? { listener?.port?.rawValue }
    public var isListening: Bool { listener?.state == .ready }

    /// Stops listening and closes every open preview connection (live reload included).
    public func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            self.clients.values.forEach { $0.cancel() }
            self.upstreams.values.forEach { $0.cancel() }
        }
    }

    private func accept(_ client: NWConnection) {
        guard clients.count < Self.maxConnections, Self.isLoopback(client.endpoint) else {
            client.cancel()
            return
        }
        let id = ObjectIdentifier(client)
        clients[id] = client
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed: client.cancel()
            case .cancelled:
                self?.clients[id] = nil
                self?.upstreams.removeValue(forKey: id)?.cancel()
            default: break
            }
        }
        client.start(queue: queue)
        let timeout = DispatchWorkItem { client.cancel() }
        queue.asyncAfter(deadline: .now() + 30, execute: timeout)
        readHead(client, buffer: Data(), timeout: timeout)
    }

    private func readHead(_ client: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPHead.parse(buffer, kind: .request) {
            case .incomplete:
                if isComplete || error != nil { client.cancel(); return }
                self.readHead(client, buffer: buffer, timeout: timeout)
            case .invalid:
                timeout.cancel()
                self.reply(client, Self.page(400, "Bad request."))
            case .tooLarge:
                timeout.cancel()
                self.reply(client, Self.page(431, "Request headers too large."))
            case .complete(let head, let consumed):
                timeout.cancel()
                self.handle(head, rest: buffer.subdata(in: (buffer.startIndex + consumed)..<buffer.endIndex), client: client)
            }
        }
    }

    private func handle(_ head: HTTPHead, rest: Data, client: NWConnection) {
        guard let context = context() else { return reply(client, Self.page(503, "Dev pages are off.")) }
        switch PreviewGate.decide(head, owner: context.owner, ownOrigin: context.ownOrigin,
                                  siblingOrigins: context.siblingOrigins, publicPort: context.publicPort) {
        case .reject(let status, let message):
            reply(client, Self.page(status, message))
        case .enter(let ticket):
            guard let entry = redeem(ticket) else { return reply(client, Self.page(403, PreviewGate.expiredMessage)) }
            reply(client, Self.response(302, [("Location", entry.path),
                                              ("Set-Cookie", PreviewGate.setCookie(publicPort: context.publicPort, token: entry.sessionToken))]))
        case .forward(let token):
            guard let target = resolve(token) else { return reply(client, Self.page(403, PreviewGate.expiredMessage)) }
            relay(head, rest: rest, client: client, target: target, context: context)
        }
    }

    private func relay(_ head: HTTPHead, rest: Data, client: NWConnection, target: PreviewTarget, context: Context) {
        let upgrade = PreviewGate.isUpgrade(head)
        var first = PreviewGate.upstreamRequest(head, target: target, ownOrigin: context.ownOrigin,
                                                publicPort: context.publicPort).serialized
        first.append(rest)
        // "localhost" lets the system try ::1 and 127.0.0.1, like the browser on the Mac did.
        let host: NWEndpoint.Host = target.connectHost == "localhost" ? .name("localhost", nil) : NWEndpoint.Host(target.connectHost)
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: target.port)) else {
            return reply(client, Self.page(502, PreviewGate.unreachableMessage(target)))
        }
        let upstream = NWConnection(host: host, port: port, using: .tcp)
        upstreams[ObjectIdentifier(client)] = upstream
        let settled = Flag()
        let fail = { [weak self] in
            guard !settled.value else { client.cancel(); return }
            settled.value = true
            upstream.cancel()
            self?.reply(client, Self.page(502, PreviewGate.unreachableMessage(target)))
        }
        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard !settled.value else { return }
                settled.value = true
                upstream.send(content: first, completion: .contentProcessed { error in
                    if error != nil { client.cancel(); return }
                    // Whatever else the client sends: the rest of a request body, or websocket frames.
                    self?.pump(from: client, to: upstream, onEnd: upgrade ? { upstream.cancel() } : nil)
                })
                self?.forwardResponse(upstream, to: client, buffer: Data(), ended: false, target: target)
            case .waiting, .failed:
                fail()
            default: break
            }
        }
        upstream.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { if !settled.value { fail() } }
    }

    private func forwardResponse(_ upstream: NWConnection, to client: NWConnection, buffer: Data, ended: Bool,
                                 target: PreviewTarget) {
        switch HTTPHead.parse(buffer, kind: .response) {
        case .incomplete:
            guard !ended else {
                upstream.cancel()
                return reply(client, Self.page(502, PreviewGate.unreachableMessage(target)))
            }
            upstream.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                var buffer = buffer
                if let data { buffer.append(data) }
                self?.forwardResponse(upstream, to: client, buffer: buffer, ended: isComplete || error != nil, target: target)
            }
        case .invalid, .tooLarge:
            upstream.cancel()
            reply(client, Self.page(502, "The dev server didn't answer with HTTP."))
        case .complete(let head, let consumed):
            let status = head.status ?? 0
            let interim = (100...199).contains(status) && status != 101   // e.g. 100 Continue: the real head follows
            let rest = buffer.subdata(in: (buffer.startIndex + consumed)..<buffer.endIndex)
            var out = PreviewGate.clientResponse(head, target: target).serialized
            if !interim { out.append(rest) }
            client.send(content: out, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { client.cancel(); return }
                if interim { return self.forwardResponse(upstream, to: client, buffer: rest, ended: ended, target: target) }
                if ended { client.cancel(); return }
                self.pump(from: upstream, to: client, onEnd: { client.cancel() })
            })
        }
    }

    /// Copies bytes until `source` ends. The next read waits for the previous write, so a slow phone
    /// slows the dev server down instead of filling memory.
    private func pump(from source: NWConnection, to destination: NWConnection, onEnd: (() -> Void)?) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            let ended = isComplete || error != nil
            guard let data, !data.isEmpty else {
                if ended { onEnd?() } else { self?.pump(from: source, to: destination, onEnd: onEnd) }
                return
            }
            destination.send(content: data, completion: .contentProcessed { sendError in
                if sendError != nil { source.cancel(); destination.cancel(); return }
                if ended { onEnd?() } else { self?.pump(from: source, to: destination, onEnd: onEnd) }
            })
        }
    }

    private func reply(_ client: NWConnection, _ data: Data) {
        client.send(content: data, completion: .contentProcessed { _ in client.cancel() })
    }

    static func page(_ status: Int, _ message: String) -> Data {
        let escaped = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = "<!doctype html><meta name=\"viewport\" content=\"width=device-width\"><title>VibeSwitcher</title>"
            + "<body style=\"font:16px -apple-system,system-ui,sans-serif;padding:24px;line-height:1.4\"><p>\(escaped)</p>"
        return response(status, [("Content-Type", "text/html; charset=utf-8")], body: Data(html.utf8))
    }

    static func response(_ status: Int, _ headers: [(String, String)], body: Data = Data()) -> Data {
        let reasons = [302: "Found", 400: "Bad Request", 403: "Forbidden", 431: "Request Header Fields Too Large",
                       502: "Bad Gateway", 503: "Service Unavailable"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        head += "Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address == .loopback
        case .ipv6(let address): return address == .loopback
        case .name(let name, _): return name == "localhost" || name == "127.0.0.1" || name == "::1"
        @unknown default: return false
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PreviewProxyTests 2>&1 | tail -12`
Expected: all 7 tests pass. If `reachesServersListeningOnlyOnIPv6Loopback` fails, check that the fake upstream
really bound to `::1` (`lsof -nP -iTCP -sTCP:LISTEN | grep <port>`) before changing the proxy.

- [ ] **Step 5: Run the whole suite**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass (65 existing plus the new ones).

- [ ] **Step 6: Commit**

```bash
git add Sources/VibeCore/PreviewProxy.swift Tests/VibeCoreTests/DevPreviewTests.swift
git commit -m "Dev pages: loopback relay for preview slots (HTTP and websockets)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Chrome's tabs, port-aware Tailscale, and the preview controller (app)

**Files:**
- Create: `Sources/VibeSwitcher/ChromeTabs.swift`, `Sources/VibeSwitcher/DevPreviews.swift`
- Modify: `Sources/VibeSwitcher/Tailscale.swift` (the `Failure.portInUse` case, `servedTarget`, `startServing`
  and `stopServing`), `Sources/VibeSwitcher/main.swift` (the `--dev-pages` flag, next to `--dump`), and
  `Resources/Info.plist:24`.

**Interfaces:**
- Consumes: `DevPages`, `PreviewSlots`, `PreviewProxy`, `PreviewGate.enterPath`, `TerminalBridge.runAppleScript`,
  `PhoneAccess.port`, `PhoneAccess.httpsPort`.
- Produces:
  - **`ChromeTabs`:** `enum ChromeTabs { static func localPages() -> Result<[DevPage], ChromeTabs.Failure> }`, where
    `Failure` is one of `notRunning`, `notAllowed` or `failed(String)`.
  - **`TailscaleCLI`:**
    - `servedTargets(host:timeout:) -> [Int: String]?`;
    - `servedTarget(host:httpsPort:timeout:) -> String?`;
    - `startServing(host:httpsPort:localTarget:) -> Failure?`;
    - `stopServing(host:mappings:timeout:)`;
    - `stopServing(host:localTarget:timeout:)`, unchanged for existing callers.
  - **`DevPreviews` (`final class`):**
    - `init(control: DispatchQueue)`;
    - `start(host:owner:completion: (String?) -> Void)`, `stop()`, `shutdown()`, `repairMappings()`;
    - `isHealthy: Bool`;
    - `pages(fresh:) -> Result<[DevPage], ChromeTabs.Failure>`, `isOpen(_:) -> Bool`, `open(_:) -> URL?`.

- [ ] **Step 1: Make Tailscale serving port-aware**

In `Sources/VibeSwitcher/Tailscale.swift`:
1. Change `case portInUse(String)` to `case portInUse(port: Int, target: String)`. Its description becomes
   `"Port \(port) is already served by Tailscale (to \(target))."`.
2. Replace `servedTarget(host:timeout:)`, `startServing(host:localTarget:)` and
   `stopServing(host:localTarget:timeout:)` with:

```swift
    /// What each of this Mac's HTTPS ports proxies to (port → target), or nil if it can't be read.
    static func servedTargets(host: String, timeout: TimeInterval = 10) -> [Int: String]? {
        let result = run(["serve", "status", "--json"], timeout: timeout)
        guard result.status == 0, let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var targets: [Int: String] = [:]
        for (key, value) in json["Web"] as? [String: Any] ?? [:] {
            guard key.hasPrefix("\(host):"), let port = Int(key.dropFirst(host.count + 1)),
                  let site = value as? [String: Any], let handlers = site["Handlers"] as? [String: Any],
                  let root = handlers["/"] as? [String: Any], let proxy = root["Proxy"] as? String else { continue }
            targets[port] = proxy
        }
        return targets
    }

    /// What one HTTPS port currently proxies to, if anything.
    static func servedTarget(host: String, httpsPort: Int = PhoneAccess.httpsPort, timeout: TimeInterval = 10) -> String? {
        servedTargets(host: host, timeout: timeout)?[httpsPort]
    }

    /// Maps https://<this mac>:<httpsPort> on the tailnet to a loopback server. Never `funnel`: tailnet only.
    static func startServing(host: String, httpsPort: Int = PhoneAccess.httpsPort, localTarget: String) -> Failure? {
        if let existing = servedTarget(host: host, httpsPort: httpsPort) {
            return existing == localTarget ? nil : .portInUse(port: httpsPort, target: existing)
        }
        let result = run(["serve", "--bg", "--https=\(httpsPort)", localTarget])
        guard result.status == 0 else { return .command(result.error.isEmpty ? result.output : result.error) }
        return servedTarget(host: host, httpsPort: httpsPort) == localTarget ? nil : .command("serve config didn't take effect")
    }

    /// Removes our mappings (port → our local target), each only if it's still ours. One status read.
    static func stopServing(host: String, mappings: [Int: String], timeout: TimeInterval = 10) {
        guard let served = servedTargets(host: host, timeout: timeout) else { return }
        for (port, target) in mappings where served[port] == target {
            _ = run(["serve", "--https=\(port)", "off"], timeout: timeout)
        }
    }

    static func stopServing(host: String, localTarget: String, timeout: TimeInterval = 10) {
        stopServing(host: host, mappings: [PhoneAccess.httpsPort: localTarget], timeout: timeout)
    }
```

Run: `swift build 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`. The existing callers in `PhoneAccess.swift` keep compiling through the defaults.

- [ ] **Step 2: Read Chrome's tabs**

Create `Sources/VibeSwitcher/ChromeTabs.swift`:

```swift
import AppKit
import VibeCore

/// The localhost pages open in Google Chrome, read with AppleScript. Only while Chrome is running:
/// this never launches it. The first read shows macOS's "control Google Chrome" prompt.
enum ChromeTabs {
    static let bundleID = "com.google.Chrome"

    enum Failure: Error, Equatable {
        case notRunning
        case notAllowed
        case failed(String)
    }

    static func localPages() -> Result<[DevPage], Failure> {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            return .failure(.notRunning)
        }
        let result = TerminalBridge.runAppleScript("""
        set out to ""
        tell application id "\(bundleID)"
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (URL of t) & (character id 31) & (title of t) & (character id 30)
                end repeat
            end repeat
        end tell
        return out
        """)
        guard result.status == 0 else {
            // -1743: the user said no (or hasn't been asked yet) under Privacy & Security › Automation.
            if result.error.contains("-1743") { return .failure(.notAllowed) }
            return .failure(.failed(String(result.error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))))
        }
        let tabs: [(url: String, title: String)] = result.output.split(separator: "\u{1E}").compactMap { record in
            let parts = record.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines), String(parts[1]))
        }
        return .success(DevPages.pages(fromTabs: tabs))
    }
}
```

In `Resources/Info.plist`, replace the `NSAppleEventsUsageDescription` string with:
`VibeSwitcher reads Terminal tab titles to show what each Claude/Codex session is doing and selects a tab when you click a session. If you allow dev pages for your phone, it also lists the localhost pages open in Google Chrome.`

In `Sources/VibeSwitcher/main.swift`, add this right after the `--dump` block:

```swift
if arguments.contains("--dev-pages") {
    // What the phone's Dev pages list would show right now.
    switch ChromeTabs.localPages() {
    case .success(let pages):
        pages.forEach { print("\($0.target.hostHeader)\($0.path)\t\($0.title)\tid \(DevPages.id(for: $0))") }
        if pages.isEmpty { print("no localhost pages open in Chrome") }
    case .failure(let failure):
        print("\(failure)")
    }
    exit(0)
}
```

- [ ] **Step 3: Check the Chrome read against a scratch tab**

```bash
swift build 2>&1 | grep -E "error|Build complete"
S=$(mktemp -d) && cd "$S" && echo '<title>VS scratch</title>ok' > index.html
python3 -m http.server 58123 --bind 127.0.0.1 >/dev/null 2>&1 & echo $! > "$S/pid"
open -a "Google Chrome" "http://localhost:58123/?probe=1"; sleep 2
cd "$(git rev-parse --show-toplevel)" && .build/debug/VibeSwitcher --dev-pages
```

Expected: a line `localhost:58123/?probe=1	VS scratch	id …`. The first run may show the macOS Automation
prompt *for the terminal app*, not VibeSwitcher, because it runs from the shell. Approve it, or ask the user to.
Then close **only** that scratch tab and stop the server:

```bash
osascript -e 'tell application "Google Chrome" to close (every tab of every window whose URL contains "localhost:58123")'
kill "$(cat "$S/pid")"
```

- [ ] **Step 4: The preview controller**

Create `Sources/VibeSwitcher/DevPreviews.swift`:

```swift
import AppKit
import VibeCore

/// Phone Access's dev-page previews: which localhost pages Chrome has open, the preview slots, their
/// loopback proxies (127.0.0.1:47824–47827) and the `tailscale serve` mappings (:8444–8447) that reach
/// them. Started and stopped by PhoneAccess on the main thread; the proxies call in from their queues.
final class DevPreviews {
    static let slotCount = 4
    static func publicPort(_ slot: Int) -> Int { PhoneAccess.httpsPort + 1 + slot }
    static func localPort(_ slot: Int) -> UInt16 { PhoneAccess.port + 1 + UInt16(slot) }
    static func localTarget(_ slot: Int) -> String { "http://127.0.0.1:\(localPort(slot))" }
    static var mappings: [Int: String] {
        Dictionary(uniqueKeysWithValues: (0..<slotCount).map { (publicPort($0), localTarget($0)) })
    }

    private let control: DispatchQueue
    private let lock = NSLock()
    // Under `lock`:
    private var slots = PreviewSlots(count: slotCount)
    private var context: (host: String, owner: String)?
    private var pageCache: (at: Date, result: Result<[DevPage], ChromeTabs.Failure>)?
    // Main thread:
    private var proxies: [PreviewProxy] = []
    private var running: String?
    private var generation = 0

    init(control: DispatchQueue) { self.control = control }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Starts the proxies and maps them on the tailnet. `completion(problem)` runs once every slot has been
    /// tried: nil when at least one slot works. Calling it again for the same host does nothing.
    func start(host: String, owner: String, completion: @escaping (String?) -> Void) {
        guard running != host else { return completion(nil) }
        stop()
        generation += 1
        let run = generation
        running = host
        withLock {
            context = (host, owner)
            slots = PreviewSlots(count: Self.slotCount)
            for slot in 0..<Self.slotCount { slots.setAvailable(slot, false) }
        }
        let group = DispatchGroup()
        var problems: [String] = []
        for slot in 0..<Self.slotCount {
            let proxy = makeProxy(slot)
            proxies.append(proxy)
            group.enter()
            proxy.start(port: Self.localPort(slot), onReady: { [weak self] in
                guard let self, self.generation == run else { return group.leave() }
                self.control.async {
                    let failure = TailscaleCLI.startServing(host: host, httpsPort: Self.publicPort(slot),
                                                            localTarget: Self.localTarget(slot))
                    DispatchQueue.main.async {
                        if self.generation == run {
                            if let failure { problems.append(failure.description) }
                            else { self.withLock { self.slots.setAvailable(slot, true) } }
                        }
                        group.leave()
                    }
                }
            }, onFailure: { message in
                problems.append(message)
                group.leave()
            })
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, self.generation == run else { return }
            let working = self.withLock { self.slots.slots.filter(\.available).count }
            completion(working == 0 ? (problems.first ?? "No preview port could be opened.") : nil)
        }
    }

    /// Closes the proxies (and their open pages) and takes the tailnet mappings down in the background.
    func stop() {
        generation += 1
        proxies.forEach { $0.stop() }
        proxies = []
        withLock {
            context = nil
            slots = PreviewSlots(count: Self.slotCount)
        }
        guard let host = running else { return }
        running = nil
        control.async { TailscaleCLI.stopServing(host: host, mappings: Self.mappings) }
    }

    /// On quit: synchronous, so nothing on the tailnet keeps pointing at ports we no longer own.
    func shutdown() {
        generation += 1
        proxies.forEach { $0.stop() }
        guard let host = running else { return }
        TailscaleCLI.stopServing(host: host, mappings: Self.mappings, timeout: 3)
    }

    var isHealthy: Bool { running == nil || proxies.allSatisfy(\.isListening) }

    /// On the control queue (PhoneAccess's health check): puts back mappings that went missing.
    func repairMappings() {
        let (host, available) = withLock { (context?.host, slots.slots.indices.filter { slots.slots[$0].available }) }
        guard let host, !available.isEmpty, let served = TailscaleCLI.servedTargets(host: host) else { return }
        for slot in available where served[Self.publicPort(slot)] != Self.localTarget(slot) {
            _ = TailscaleCLI.startServing(host: host, httpsPort: Self.publicPort(slot), localTarget: Self.localTarget(slot))
        }
    }

    /// Off the main thread. Chrome's localhost tabs, cached for 5 s; `fresh` reads them again.
    func pages(fresh: Bool = false) -> Result<[DevPage], ChromeTabs.Failure> {
        if !fresh, let cache = withLock({ pageCache }), cache.at.timeIntervalSinceNow > -5 { return cache.result }
        let result = ChromeTabs.localPages()
        withLock { pageCache = (Date(), result) }
        return result
    }

    /// Whether a slot is currently showing that server (the phone shows a dot).
    func isOpen(_ target: PreviewTarget) -> Bool {
        withLock { slots.slots.contains { $0.target == target } }
    }

    /// A one-time link (60 s) that opens `page` in a slot, or nil when no slot is available.
    func open(_ page: DevPage) -> URL? {
        withLock {
            guard let host = context?.host, let opened = slots.open(page.target, path: page.path) else { return nil }
            return URL(string: "https://\(host):\(Self.publicPort(opened.slot))\(PreviewGate.enterPath)?t=\(opened.ticket)")
        }
    }

    private func makeProxy(_ slot: Int) -> PreviewProxy {
        let publicPort = Self.publicPort(slot)
        return PreviewProxy(label: "vibeswitcher.preview.\(slot)", context: { [weak self] in
            guard let self else { return nil }
            return self.withLock { () -> PreviewProxy.Context? in
                guard let context = self.context else { return nil }
                let origins = Set((0...Self.slotCount).map { "https://\(context.host):\(PhoneAccess.httpsPort + $0)" })
                return PreviewProxy.Context(owner: context.owner, ownOrigin: "https://\(context.host):\(publicPort)",
                                            siblingOrigins: origins, publicPort: publicPort)
            }
        }, redeem: { [weak self] ticket in
            guard let self else { return nil }
            return self.withLock { self.slots.redeem(ticket, slot: slot) }
        }, resolve: { [weak self] token in
            guard let self else { return nil }
            return self.withLock { self.slots.target(slot: slot, sessionToken: token) }
        })
    }
}
```

Run: `swift build 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`.

- [ ] **Step 5: Commit**

```bash
git add Sources/VibeSwitcher/ChromeTabs.swift Sources/VibeSwitcher/DevPreviews.swift Sources/VibeSwitcher/Tailscale.swift Sources/VibeSwitcher/main.swift Resources/Info.plist
git commit -m "Dev pages: Chrome tab reader, port-aware tailscale serve, preview controller

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Phone Access wiring, API and the Mac toggle

**Files:**
- Modify: `Sources/VibeSwitcher/PhoneAccess.swift`:
  - properties near `inputAllowed`;
  - `init`;
  - `startServing(run:host:)`, `fail(_:)`, `stop()`, `shutdown()` and `checkHealth()`;
  - `route(_:respond:)`, `stateObject(for:)`;
  - new functions after `screen(_:respond:)`.
- Modify: `Sources/VibeSwitcher/PhoneAccessView.swift` (after the `inputAllowed` toggle).

**Interfaces:**
- Consumes: `DevPreviews` (Task 5), `DevPages.id(for:)`, `Redaction.secrets(in:)`.
- Produces:
  - `GET /api/devpages` returns `{"pages":[{"id","title","label","open"}], "hint"?}`.
  - `POST /api/preview {"id"}` returns `{"open": "<https url>"}`.
  - `/api/state` gains `"devPagesAllowed": Bool`.
  - `PhoneAccess.devPagesAllowed` and `PhoneAccess.devPagesProblem`.

- [ ] **Step 1: State and lifecycle**

In `PhoneAccess`, add after `pushOnlyWhenAway`:

```swift
    @Published var devPagesAllowed: Bool {
        didSet {
            guard devPagesAllowed != oldValue else { return }
            defaults.set(devPagesAllowed, forKey: "phoneDevPagesAllowed")
            audit("dev pages \(devPagesAllowed ? "allowed" : "blocked")")
            syncPreviews()
        }
    }
    /// Why previews couldn't start (shown under the toggle), or nil.
    @Published private(set) var devPagesProblem: String?
    private lazy var previews = DevPreviews(control: control)
```

In `init`, after `inputAllowed = …`: `devPagesAllowed = defaults.bool(forKey: "phoneDevPagesAllowed")`.

Add next to `fail(_:)`:

```swift
    /// Previews run exactly while Phone Access is on and dev pages are allowed.
    private func syncPreviews() {
        guard devPagesAllowed, state == .on, let host = tailscale?.dnsName, let owner = tailscale?.login else {
            previews.stop()
            devPagesProblem = nil
            return
        }
        previews.start(host: host, owner: owner) { [weak self] problem in self?.devPagesProblem = problem }
    }
```

Wire it in:
- **`startServing(run:host:)`:** at the end of the success path, after the `if self.state != .on { … }`
  block, add `self.syncPreviews()`.
- **`fail(_:)`:** add `previews.stop()` as the first line.
- **`stop()`:** add `previews.stop()` after `server = nil`.
- **`shutdown()`:** add `previews.shutdown()` after `server?.stop()`, *before* the `guard`.
- **`checkHealth()`:**
  - Before `control.async`, add `let previewsWanted = devPagesAllowed`.
  - Inside `control.async`, after the `served` line, add `if previewsWanted { self.previews.repairMappings() }`.
  - In the main-queue block, after `self.unhealthyChecks = 0`, add:

```swift
                if previewsWanted, !self.previews.isHealthy {
                    self.audit("dev pages restarting (a preview port stopped listening)")
                    self.previews.stop()
                    self.syncPreviews()
                }
```

- [ ] **Step 2: API**

In `route`, add before `default:`:

```swift
        case ("GET", "/api/devpages"): devPages(respond: respond)
        case ("POST", "/api/preview"): preview(request, device: device, respond: respond)
```

In `stateObject(for:)`, add `"devPagesAllowed": devPagesAllowed,` next to `"inputAllowed"`.

Add after `screen(_:respond:)`:

```swift
    private static let devPagesOff = "Opening dev pages is off. Turn it on in VibeSwitcher › Phone Access."

    private func devPages(respond: @escaping (HTTPResponse) -> Void) {
        guard devPagesAllowed else { return respond(.error(403, Self.devPagesOff)) }
        reads.async {
            let result = self.previews.pages()
            DispatchQueue.main.async {
                switch result {
                case .success(let pages):
                    respond(.json(["pages": pages.map { page -> [String: Any] in
                        ["id": DevPages.id(for: page), "title": Redaction.secrets(in: page.title),
                         "label": Redaction.secrets(in: page.target.hostHeader + page.path),
                         "open": self.previews.isOpen(page.target)]
                    }]))
                case .failure(.notRunning):
                    respond(.json(["pages": [], "hint": "Open the page in Chrome on your Mac first."]))
                case .failure(.notAllowed):
                    respond(.json(["pages": [], "hint": "On the Mac, allow VibeSwitcher to control Google Chrome: "
                                   + "System Settings › Privacy & Security › Automation."]))
                case .failure(.failed(let message)):
                    respond(.error(503, "Couldn't read Chrome's tabs (\(message))."))
                }
            }
        }
    }

    private func preview(_ request: HTTPRequest, device: PairedDevice, respond: @escaping (HTTPResponse) -> Void) {
        guard devPagesAllowed else { return respond(.error(403, Self.devPagesOff)) }
        guard let id = body(request)?["id"] as? String else { return respond(.error(400, "missing page")) }
        reads.async {
            // Fresh: only a page that is open in Chrome right now may be opened.
            let result = self.previews.pages(fresh: true)
            DispatchQueue.main.async {
                guard case .success(let pages) = result, let page = pages.first(where: { DevPages.id(for: $0) == id }) else {
                    return respond(.error(404, "That page isn't open in Chrome on your Mac anymore."))
                }
                guard let url = self.previews.open(page) else {
                    return respond(.error(503, "No preview slot is available right now."))
                }
                self.audit("\(device.name) opened \(Redaction.secrets(in: page.target.hostHeader + page.path))")
                respond(.json(["open": url.absoluteString]))
            }
        }
    }
```

- [ ] **Step 3: The Mac toggle**

In `PhoneAccessView.body`, after the `inputAllowed` toggle and before the `pushOnlyWhenAway` toggle, add:

```swift
                Toggle(isOn: $access.devPagesAllowed) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow opening dev pages")
                        Text("Localhost pages open in Chrome on this Mac can be opened from your paired phone.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let problem = access.devPagesProblem {
                            Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
```

- [ ] **Step 4: Build, test, install**

```bash
swift build 2>&1 | grep -E "error|Build complete"
swift test 2>&1 | tail -2
./scripts/build-app.sh --install 2>&1 | tail -1
```

Expected: `Build complete!`, all tests pass, and `Installed and launched /Applications/VibeSwitcher.app`.

- [ ] **Step 5: Verify on loopback with a temporary device**

Pair a temporary device named `Preview test (Claude)`:
1. Open VibeSwitcher › ⚙︎ › Phone Access…, click **Pair a Phone…**, and read the code from the window.
2. Run the commands below, with the login read silently:

```bash
LOGIN=$(TAILSCALE_BE_CLI=1 /Applications/Tailscale.app/Contents/MacOS/Tailscale status --json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["User"][str(d["Self"]["UserID"])]["LoginName"])')
TOKEN=$(curl -s -H "Tailscale-User-Login: $LOGIN" -d '{"code":"<CODE>","name":"Preview test (Claude)"}' http://127.0.0.1:47823/api/pair | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
API() { curl -s -H "Tailscale-User-Login: $LOGIN" -H "Authorization: Bearer $TOKEN" "$@"; }
API http://127.0.0.1:47823/api/devpages        # expect 403 "Opening dev pages is off…"
```

Turn on **Allow opening dev pages** in the window. Check `tailscale serve status` shows 8444–8447 →
127.0.0.1:47824–47827. Then start the scratch server and Chrome tab from Task 5, Step 3, and:

```bash
API http://127.0.0.1:47823/api/devpages                      # expect the scratch page with an id
ID=<id from above>
OPEN=$(API -d "{\"id\":\"$ID\"}" http://127.0.0.1:47823/api/preview | python3 -c 'import json,sys;print(json.load(sys.stdin)["open"])')
PATHQ=${OPEN#https://*/}; T=${OPEN##*t=}
curl -si -H "Tailscale-User-Login: $LOGIN" "http://127.0.0.1:47824/__vibeswitcher/enter?t=$T" | head -5   # expect 302 + Set-Cookie (slot may differ: use the port matching OPEN)
API -d '{"id":"nope"}' http://127.0.0.1:47823/api/preview    # expect 404 "isn't open in Chrome…"
```

Then follow the cookie:

```bash
curl -s -H "Tailscale-User-Login: $LOGIN" -H "Cookie: vs_preview_8444=<token from Set-Cookie>" http://127.0.0.1:47824/
```

Expected: the scratch page's HTML. Then close the scratch tab: the next `/api/preview` with the old id returns 404.
Clean up:
- Remove `Preview test (Claude)` in the Phone Access window.
- Close only the scratch Chrome tab and kill the scratch server.
- Turn **Allow opening dev pages** back off.
- `unset TOKEN LOGIN`.

- [ ] **Step 6: Commit**

```bash
git add Sources/VibeSwitcher/PhoneAccess.swift Sources/VibeSwitcher/PhoneAccessView.swift
git commit -m "Phone Access: allow opening dev pages (toggle, /api/devpages, /api/preview)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Dev pages on the phone

**Files:**
- Modify: `Web/index.html` (inside `<section id="list">`, after `<p id="empty" …>`), `Web/app.js` (end of
  `renderList()`, plus a new section before `// ---------- Session view ----------`), and `Web/style.css` (append).

**Interfaces:**
- Consumes: `GET /api/devpages`, `POST /api/preview`, and `state.devPagesAllowed` (Task 6). Also the
  existing `api`, `el` and `$` helpers in `app.js`.

- [ ] **Step 1: Markup**

In `Web/index.html`, after `<p id="empty" class="muted center" hidden>…</p>`:

```html
    <div id="devPages" hidden>
      <h3 class="sectionTitle">Dev pages <span>open in Chrome on your Mac</span></h3>
      <div id="devPageRows"></div>
      <p id="devPagesHint" class="muted small" hidden></p>
      <p id="devPagesError" class="error" hidden></p>
    </div>
```

- [ ] **Step 2: Behaviour**

In `Web/app.js`, add the call `refreshDevPages();` as the last line of `renderList()`, after `renderToday();`.
Then add before `// ---------- Session view ----------`:

```js
// ---------- Dev pages ----------

let devPagesAt = 0;
let devPagesBusy = false;

/// Chrome's localhost tabs on the Mac. Refreshed with the list, at most every 10 s.
async function refreshDevPages(force = false) {
  const box = $('devPages');
  box.hidden = !state || !state.devPagesAllowed;
  if (box.hidden || devPagesBusy || (!force && Date.now() - devPagesAt < 10000)) return;
  devPagesBusy = true;
  try {
    renderDevPages(await api('/api/devpages'));
    devPagesAt = Date.now();
  } catch (error) {
    showDevPagesError(error.message);
  } finally {
    devPagesBusy = false;
  }
}

function showDevPagesError(message) {
  $('devPagesError').textContent = message;
  $('devPagesError').hidden = !message;
}

function renderDevPages(result) {
  showDevPagesError('');
  const pages = result.pages || [];
  const hint = result.hint || (pages.length ? '' : 'No localhost pages are open in Chrome on your Mac.');
  $('devPagesHint').textContent = hint;
  $('devPagesHint').hidden = !hint;
  $('devPageRows').replaceChildren(...pages.map(page => {
    const row = el('button', 'row devPage');
    row.type = 'button';
    const text = el('div', 'text');
    const first = el('div', 'line1');
    first.append(el('b', 'name', page.title));
    if (page.open) first.append(el('span', 'when done', 'open'));
    text.append(first, el('div', 'detail', page.label));
    row.append(el('span', 'globe', '🌐'), text);
    row.addEventListener('click', () => openDevPage(page, row));
    return row;
  }));
}

async function openDevPage(page, row) {
  row.disabled = true;
  try {
    const result = await api('/api/preview', { method: 'POST', body: JSON.stringify({ id: page.id }) });
    // Opens outside the app (on Android, a Chrome tab); Back comes back here. The link works once, for a minute.
    const opened = window.open(result.open, '_blank');
    if (opened) opened.opener = null;
    else location.href = result.open;
    devPagesAt = 0;
  } catch (error) {
    showDevPagesError(error.message);
  } finally {
    row.disabled = false;
  }
}
```

- [ ] **Step 3: Style**

Append to `Web/style.css`:

```css
.sectionTitle { margin: 18px 2px 8px; font-size: 12px; font-weight: 700; color: var(--muted);
  text-transform: uppercase; letter-spacing: 0.04em; }
.sectionTitle span { text-transform: none; letter-spacing: 0; font-weight: 400; }
.globe { flex: none; width: 24px; text-align: center; font-size: 17px; line-height: 24px; }
.row:disabled { opacity: 0.5; }
.devPage .detail { -webkit-line-clamp: 1; }
```

- [ ] **Step 4: Check syntax and layout**

```bash
node --check Web/app.js && echo ok
```

Render a 360px-wide harness with two fake rows using `Web/style.css`, the way the Clear button was
checked: an iframe in headless Chrome, screenshot read back. Confirm that a long title ellipsizes, the
label stays on one line, and the "open" tag sits on the right.

- [ ] **Step 5: Commit**

```bash
git add Web/index.html Web/app.js Web/style.css
git commit -m "Phone: Dev pages section that opens Chrome's localhost tabs as previews

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: README, and an end-to-end check over Tailscale

**Files:**
- Modify: `README.md`, in the Phone Access section, after replies and quick replies.

- [ ] **Step 1: README**

Add:

```markdown
### Dev pages

Turn on **Allow opening dev pages** in Phone Access to open, on your phone, the localhost pages that are
open in Chrome on your Mac (`http://localhost:5173/…`, `127.0.0.1`, `[::1]`, `*.localhost`). They're live:
tap, type and hot reload work.

- **What appears:** only pages open in Chrome right now. Your other local servers can't be reached. The
  first time, macOS asks whether VibeSwitcher may control Google Chrome.
- **How it opens:** each page gets its own HTTPS port on your tailnet (8444–8447) through a proxy inside
  VibeSwitcher.
- **Who can open it:** every request must come from your own Tailscale account and carry a cookie that only
  the paired phone can get, from a link that works once, for a minute.
- **Limits:**
  - At most 4 pages at once; opening a fifth replaces the least recently used.
  - Links hard-coded to `http://localhost:…` inside the app won't work on the phone.
  - Dev servers that only serve HTTPS aren't supported.
  - Cookies a dev app sets are shared between its previews, because browsers scope cookies by host,
    not port.
```

- [ ] **Step 2: End to end through Tailscale, from the Mac's own Chrome**

1. Turn on **Allow opening dev pages**.
2. Start the scratch server and Chrome tab as in Task 5, Step 3, then pair the temporary device as in
   Task 6, Step 5.
3. Get an `open` URL from `/api/preview`, through `https://<mac>:8443` or loopback.
4. Open that URL in a **new** Chrome tab on the Mac. It goes through the tailnet name, so through Tailscale.

Expected: the scratch page loads at `https://<mac>.ts.net:844x/?probe=1`. Reloading it works because the
cookie is set. Opening the same `open` URL again gives the "has expired" page, because tickets are single use.

Then close **only** the scratch tabs, kill the scratch server, remove the temporary device and turn the
toggle off.

- [ ] **Step 3: Full suite and install**

```bash
swift test 2>&1 | tail -2
./scripts/build-app.sh --install 2>&1 | tail -1
```

Expected: all tests pass, and the app is installed and launched.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "README: dev pages on the phone

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Hand over to the user for the phone test**

Ask the user to:
1. Turn on **Allow opening dev pages**.
2. Open a real dev server page in Chrome on the Mac.
3. On the phone, pull to refresh the list and tap the page under **Dev pages**.
4. Edit something to see hot reload.

Don't push without the user's go-ahead.
