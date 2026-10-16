# IDE Window Part 1 (Session Host + Main Window) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** VibeSwitcher gets a main window that runs Claude Code / Codex sessions itself (in a background session host that survives app restarts), lists every session by project, and replaces Terminal.app for agent work.

**Architecture:** A new `vibeswitcher-host` executable owns each session's PTY (via SwiftTerm's `forkpty` helper), keeps an output ring buffer plus a headless SwiftTerm `Terminal` per session, and serves the app over a Unix socket with a small framed JSON protocol. The app's `HostClient` connects (starting the host on demand), and a three-pane `NSSplitViewController` window shows sessions (SwiftUI list), the live terminal (SwiftTerm `TerminalView` subclass), and an inspector. The existing session scan keeps discovering agents by tty, so menu bar dots, notifications and phone access extend to window sessions with small branches.

**Tech Stack:** Swift 6.1 toolchain in Swift 5 language mode, SwiftPM, AppKit + SwiftUI, SwiftTerm 1.19.0, Swift Testing (`import Testing`, `@Test`, `#expect`).

**Spec:** `docs/superpowers/specs/2026-10-16-ide-window-session-host-design.md`

## Global Constraints

- Platform floor stays `.macOS(.v14)`; language mode stays `swiftLanguageModes: [.v5]`.
- SwiftTerm pinned `exact: "1.19.0"` (not 1.99/2.0).
- Socket `~/.vibeswitcher/host.sock` mode 0600 inside the 0700 `~/.vibeswitcher`; lock `~/.vibeswitcher/host.lock`; log `~/.vibeswitcher/host.log`.
- Protocol version `1`; frames: 4-byte big-endian length (kind byte + payload), 1-byte kind (`0` control JSON, `1` output), max payload 1 MB (`1 << 20`).
- Ring buffer 8 MB per session; headless scrollback 5,000 lines; ended sessions kept 24 h; host idle exit 10 min.
- Session environment adds `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=VibeSwitcher`, `VIBESWITCHER_SESSION=<id>`; launch is `$SHELL -l -i -c '<command>'` (plain shell: `$SHELL -l -i`; keep shell: `<command>; exec '<shell>' -l -i`).
- Ending a session: SIGHUP to its process group, SIGKILL after 5 s.
- Phone replies to window sessions: sanitized text written to the PTY, then `\r` as a separate write 60 ms later.
- **Never test input or kills against real sessions.** All tests use scratch programs (`/bin/sh -c …`, `cat`) in hosts started on temporary sockets (`/tmp/vsh-<random>.sock`). Never move or hide Terminal.app windows in tests.
- Code style: match the repo — doc comments (`///`) on types and non-obvious members, short sentences, no trailing commentary; tests in Swift Testing style like `Tests/VibeCoreTests/SecurityTests.swift`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A view re-attaching to a busy Claude session** (replay starts mid-stream) must show a correct screen after the redraw nudge, not garbage. → Task 2 tests the reset-point start; Task 3 tests the resize nudge delivers SIGWINCH; Task 13 checks it manually with a real throwaway Claude session.
2. **A huge burst of output with the window attached** (`yes | head -c 50000000`) must never block the program; the client gets `resync`. → Task 4 test `slowClientGetsResyncAndProgramKeepsRunning`.
3. **Terminal queries answered twice** (view + headless) would confuse TUIs; with no view attached a query must still be answered. → Task 3 test `headlessAnswersQueriesOnlyWhenNoClient`; Task 4 test `repliesFromNonPrimaryClientAreDropped`.
4. **A project folder that no longer exists / a command that isn't installed** must produce a visible error, not a silent session in `/`. → Task 3 test `spawnRejectsMissingFolder`; command-not-found shows in the shell output (Task 13 manual).
5. **App update while sessions run** (bundle replaced, old host still running) must not kill sessions. → Task 7 `HostClient` outdated logic; Task 13 manual `build-app.sh --install` mid-session.

## File Structure

| File | Responsibility |
|---|---|
| `Package.swift` | add SwiftTerm, `VibeHost`, `vibeswitcher-host`, `VibeHostTests` |
| `Sources/VibeCore/HostProtocol.swift` | frames, decoder, `HostSession`, `SpawnRequest`, `HostRequest`, `HostEvent`, envelopes, JSON coding |
| `Sources/VibeCore/UnixSocket.swift` | `sockaddr_un` building, connect, nonblocking helpers (shared by host + app) |
| `Sources/VibeCore/HostConnection.swift` | app-side socket client: send requests, deliver events/output |
| `Sources/VibeCore/OutputRing.swift` | per-session replay buffer with reset points |
| `Sources/VibeCore/LaunchPresets.swift` | presets model, storage, migration, `LaunchPlan` command building |
| `Sources/VibeCore/WindowRows.swift` | grouping store sessions + hosted extras into project sections |
| `Sources/VibeCore/TerminalAppearance.swift` | terminal settings model + palettes + hex colors |
| `Sources/VibeCore/HostInput.swift` | phone key names → bytes; reply write plan |
| `Sources/VibeCore/Paths.swift` (modify) | `hostSocket`, `hostLock`, `hostLog`, `presetsFile` |
| `Sources/VibeCore/Models.swift` (modify) | `Session.hostID`, `Session.agentSessionID` |
| `Sources/VibeHost/HostedSession.swift` | one PTY session: spawn, read, headless terminal, ring, input, resize, kill |
| `Sources/VibeHost/HostServer.swift` | lock, socket, clients, request handling, broadcast, idle exit |
| `Sources/VibeHost/ClientConnection.swift` | one connected client: decoder, bounded write queue, attachments |
| `Sources/vibeswitcher-host/main.swift` | executable entry |
| `Sources/VibeSwitcher/HostClient.swift` | connection lifecycle, host start/replace, published sessions, attach sinks |
| `Sources/VibeSwitcher/MainWindow/MainWindowController.swift` | window, split view, toolbar, activation policy, main menu |
| `Sources/VibeSwitcher/MainWindow/WindowModel.swift` | selection + rows + remembered agent ids |
| `Sources/VibeSwitcher/MainWindow/SessionListView.swift` | left pane |
| `Sources/VibeSwitcher/MainWindow/TerminalPane.swift` | middle pane: `HostTerminalView`, view cache, find bar, placeholder for Terminal.app sessions |
| `Sources/VibeSwitcher/MainWindow/SessionHeaderView.swift` | header bar above the terminal |
| `Sources/VibeSwitcher/MainWindow/InspectorView.swift` | right pane (facts) |
| `Sources/VibeSwitcher/SettingsWindow.swift` | General / Launch / Terminal tabs |
| `Sources/VibeSwitcher/{AppDelegate,SessionStore,PhoneAccess,Preferences,PopoverView,main}.swift` (modify) | wiring |
| `scripts/build-app.sh` (modify) | bundle + sign `vibeswitcher-host` |
| `Tests/VibeCoreTests/{HostProtocolTests,OutputRingTests,LaunchPresetsTests,WindowRowsTests,TerminalAppearanceTests,HostInputTests}.swift` | unit tests |
| `Tests/VibeHostTests/{HostedSessionTests,HostServerTests,TestSupport}.swift` | PTY + socket integration tests (scratch programs only) |

---

### Task 1: Package setup and host protocol

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/VibeCore/Paths.swift`
- Create: `Sources/VibeCore/HostProtocol.swift`
- Create: `Sources/VibeHost/VibeHost.swift` (placeholder so the target builds; replaced in Task 3)
- Create: `Sources/vibeswitcher-host/main.swift` (placeholder; replaced in Task 5)
- Create: `Tests/VibeHostTests/TestSupport.swift`
- Test: `Tests/VibeCoreTests/HostProtocolTests.swift`

**Interfaces:**
- Produces: `HostProtocol.version: Int` (= 1); `HostFrame.Kind {control, output}`; `HostFrame.maxPayload`; `HostFrame.encode(_ kind: HostFrame.Kind, _ payload: Data) -> Data`; `HostFrame.output(session: UUID, bytes: Data) -> [Data]`; `HostFrame.parseOutput(_ payload: Data) -> (UUID, Data)?`; `HostFrameDecoder` (`append(_:)`, `next() throws -> (kind: HostFrame.Kind, payload: Data)?`); `HostSession`, `HostSession.Exit`, `SpawnRequest`, `HostRequest`, `HostEvent`, `HostRequestEnvelope(seq:request:)`, `HostEventEnvelope(replyTo:event:)`; `HostCoding.encode(_:) throws -> Data`, `HostCoding.decode(_:from:) throws -> T`; `VibePaths.hostSocket`, `.hostLock`, `.hostLog`, `.presetsFile` (all `URL`); test helper `eventually(timeout:_:)`.

- [ ] **Step 1: Update `Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VibeSwitcher",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Terminal emulator: the window's terminal view and the host's headless terminal.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
    ],
    targets: [
        // Shared model, status rules, process table and hook installer.
        .target(name: "VibeCore"),
        // The session host's internals: PTYs, replay buffers, the socket server.
        .target(name: "VibeHost", dependencies: ["VibeCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        // The menu bar app.
        .executableTarget(name: "VibeSwitcher", dependencies: ["VibeCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        // Background process that keeps window sessions alive across app restarts.
        .executableTarget(name: "vibeswitcher-host", dependencies: ["VibeHost"]),
        // Tiny binary that Claude Code / Codex hooks invoke on every lifecycle event.
        .executableTarget(name: "vibeswitcher-hook", dependencies: ["VibeCore"]),
        .testTarget(name: "VibeCoreTests", dependencies: ["VibeCore"]),
        .testTarget(name: "VibeHostTests", dependencies: ["VibeHost", "VibeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
```

- [ ] **Step 2: Add paths to `Sources/VibeCore/Paths.swift`** (inside `public enum VibePaths`, after `hookBinary`)

```swift
    /// The session host's socket, lock and log (see `HostServer`).
    public static var hostSocket: URL { root.appendingPathComponent("host.sock") }
    public static var hostLock: URL { root.appendingPathComponent("host.lock") }
    public static var hostLog: URL { root.appendingPathComponent("host.log") }
    /// Launch presets (see `LaunchPresets`).
    public static var presetsFile: URL { root.appendingPathComponent("presets.json") }
```

- [ ] **Step 3: Create placeholders so every target compiles**

`Sources/VibeHost/VibeHost.swift`:
```swift
import Foundation
```
`Sources/vibeswitcher-host/main.swift`:
```swift
import VibeHost
```
`Tests/VibeHostTests/TestSupport.swift`:
```swift
import Foundation

/// Polls `condition` until it holds or `timeout` passes. Host tests talk to real processes and sockets.
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

/// A short, unique socket path (Unix socket paths are limited to 104 bytes).
func scratchSocketPath() -> String { "/tmp/vsh-\(UUID().uuidString.prefix(8)).sock" }
```

- [ ] **Step 4: Write the failing tests** — `Tests/VibeCoreTests/HostProtocolTests.swift`

```swift
import Foundation
import Testing
@testable import VibeCore

struct HostFrameTests {
    @Test func framesSurviveArbitrarySplits() throws {
        let a = HostFrame.encode(.control, Data("{\"x\":1}".utf8))
        let b = HostFrame.encode(.output, Data([1, 2, 3]))
        let stream = a + b
        var decoder = HostFrameDecoder()
        var frames: [(HostFrame.Kind, Data)] = []
        for byte in stream {   // one byte at a time: the worst split
            decoder.append(Data([byte]))
            while let frame = try decoder.next() { frames.append((frame.kind, frame.payload)) }
        }
        #expect(frames.count == 2)
        #expect(frames[0].0 == .control && frames[0].1 == Data("{\"x\":1}".utf8))
        #expect(frames[1].0 == .output && frames[1].1 == Data([1, 2, 3]))
    }

    @Test func severalFramesInOneRead() throws {
        var decoder = HostFrameDecoder()
        decoder.append(HostFrame.encode(.control, Data("a".utf8)) + HostFrame.encode(.control, Data("b".utf8)))
        #expect(try decoder.next()?.payload == Data("a".utf8))
        #expect(try decoder.next()?.payload == Data("b".utf8))
        #expect(try decoder.next() == nil)
    }

    @Test func oversizeAndBadKindAreErrors() {
        var big = HostFrameDecoder()
        var length = UInt32(HostFrame.maxPayload + 2).bigEndian
        big.append(Data(bytes: &length, count: 4) + Data([0]))
        #expect(throws: HostFrameDecoder.Failure.self) { try big.next() }

        var bad = HostFrameDecoder()
        var one = UInt32(1).bigEndian
        bad.append(Data(bytes: &one, count: 4) + Data([9]))
        #expect(throws: HostFrameDecoder.Failure.badKind(9)) { try bad.next() }

        var empty = HostFrameDecoder()
        empty.append(Data([0, 0, 0, 0]))
        #expect(throws: HostFrameDecoder.Failure.emptyFrame) { try empty.next() }
    }

    @Test func largeOutputIsSplitAndKeepsItsSession() throws {
        let id = UUID()
        let bytes = Data((0..<(HostFrame.maxPayload * 2 + 10)).map { UInt8($0 % 251) })
        let frames = HostFrame.output(session: id, bytes: bytes)
        #expect(frames.count == 3)
        var decoder = HostFrameDecoder()
        frames.forEach { decoder.append($0) }
        var joined = Data()
        while let frame = try decoder.next() {
            #expect(frame.kind == .output)
            let (session, chunk) = try #require(HostFrame.parseOutput(frame.payload))
            #expect(session == id)
            joined.append(chunk)
        }
        #expect(joined == bytes)
        #expect(HostFrame.output(session: id, bytes: Data()).isEmpty)
    }
}

struct HostMessageTests {
    @Test func requestsAndEventsRoundTrip() throws {
        let id = UUID()
        let session = HostSession(id: id, tty: "ttys012", childPID: 42, cwd: "/tmp", command: "claude", label: "Claude",
                                  agent: "claude", title: "✳ Fix", startedAt: Date(timeIntervalSince1970: 1_000),
                                  cols: 120, rows: 40, exit: .init(status: 0, at: Date(timeIntervalSince1970: 2_000)))
        let requests: [HostRequest] = [
            .hello(protocolVersion: HostProtocol.version, app: "test"),
            .spawn(SpawnRequest(cwd: "/tmp", command: nil, env: ["A": "1"], cols: 80, rows: 24, keepShell: true,
                                label: "Shell", agent: nil)),
            .attach(id: id, cols: 80, rows: 24), .detach(id: id),
            .input(id: id, bytes: Data([0x1b, 0x5b, 0x41]), reply: false), .resize(id: id, cols: 100, rows: 30),
            .screen(id: id), .history(id: id, lines: 500), .kill(id: id), .remove(id: id), .shutdown,
        ]
        for request in requests {
            let data = try HostCoding.encode(HostRequestEnvelope(seq: 7, request: request))
            #expect(try HostCoding.decode(HostRequestEnvelope.self, from: data) == HostRequestEnvelope(seq: 7, request: request))
        }
        let events: [HostEvent] = [
            .welcome(protocolVersion: 1, hostBuild: 123, sessions: [session]), .spawned(session), .attached(id: id),
            .screenText(id: id, text: "hi"), .historyText(id: id, history: "a\nb", screen: "c"),
            .sessionChanged(session), .sessionRemoved(id: id), .resync(id: id), .bell(id: id), .error("nope"), .ok,
        ]
        for event in events {
            let data = try HostCoding.encode(HostEventEnvelope(replyTo: 3, event: event))
            #expect(try HostCoding.decode(HostEventEnvelope.self, from: data) == HostEventEnvelope(replyTo: 3, event: event))
        }
    }

    @Test func liveMeansNotExited() {
        var session = HostSession(id: UUID(), tty: "ttys001", childPID: 1, cwd: "/", command: nil, label: "Shell",
                                  agent: nil, title: "", startedAt: Date(), cols: 80, rows: 24, exit: nil)
        #expect(session.isLive)
        session.exit = .init(status: 1, at: Date())
        #expect(!session.isLive)
    }
}
```

- [ ] **Step 5: Run to verify they fail**

Run: `swift test --filter "HostFrameTests|HostMessageTests" 2>&1 | tail -5`
Expected: compile errors (`cannot find 'HostFrame' in scope`).

- [ ] **Step 6: Implement `Sources/VibeCore/HostProtocol.swift`**

```swift
import Foundation

/// The app ⇄ session host protocol. See docs/superpowers/specs/2026-10-16-ide-window-session-host-design.md.
public enum HostProtocol {
    /// Bumped whenever a message changes shape; app and host talk only when theirs match.
    public static let version = 1
}

/// Framing on the socket: a 4-byte big-endian length (kind byte + payload), the kind byte, the payload.
public enum HostFrame {
    public enum Kind: UInt8, Sendable {
        /// A JSON `HostRequestEnvelope` (app → host) or `HostEventEnvelope` (host → app).
        case control = 0
        /// Bytes a session printed: 16-byte session UUID, then the bytes.
        case output = 1
    }

    /// Largest payload a frame may carry (the kind byte not counted).
    public static let maxPayload = 1 << 20

    public static func encode(_ kind: Kind, _ payload: Data) -> Data {
        precondition(payload.count <= maxPayload, "frame payload too large")
        var length = UInt32(payload.count + 1).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(kind.rawValue)
        frame.append(payload)
        return frame
    }

    /// One session's output as frames no larger than `maxPayload`. Nothing for no bytes.
    public static func output(session: UUID, bytes: Data) -> [Data] {
        let id = withUnsafeBytes(of: session.uuid) { Data($0) }
        let room = maxPayload - id.count
        var frames: [Data] = []
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes.index(start, offsetBy: min(room, bytes.endIndex - start))
            frames.append(encode(.output, id + bytes[start..<end]))
            start = end
        }
        return frames
    }

    public static func parseOutput(_ payload: Data) -> (UUID, Data)? {
        guard payload.count >= 16 else { return nil }
        let b = [UInt8](payload.prefix(16))
        let id = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                             b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        return (id, Data(payload.dropFirst(16)))
    }
}

/// Collects bytes from the socket and hands out complete frames.
public struct HostFrameDecoder {
    /// The stream is corrupt: drop the connection.
    public enum Failure: Error, Equatable {
        case oversize(Int)
        case badKind(UInt8)
        case emptyFrame
    }

    private var buffer = Data()
    private var offset = 0

    public init() {}

    public mutating func append(_ data: Data) {
        // Compact once the consumed part is at least half of what's held: removing from the front copies.
        if offset > 0, offset >= buffer.count / 2 {
            buffer = Data(buffer.dropFirst(offset))
            offset = 0
        }
        buffer.append(data)
    }

    /// The next complete frame, or nil until more bytes arrive.
    public mutating func next() throws -> (kind: HostFrame.Kind, payload: Data)? {
        guard buffer.count - offset >= 4 else { return nil }
        let length = buffer[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
        guard length >= 1 else { throw Failure.emptyFrame }
        guard length - 1 <= HostFrame.maxPayload else { throw Failure.oversize(length) }
        guard buffer.count - offset >= 4 + length else { return nil }
        let kindByte = buffer[offset + 4]
        guard let kind = HostFrame.Kind(rawValue: kindByte) else { throw Failure.badKind(kindByte) }
        let payload = Data(buffer[(offset + 5)..<(offset + 4 + length)])
        offset += 4 + length
        return (kind, payload)
    }
}

/// A session the host runs, as both sides see it.
public struct HostSession: Codable, Equatable, Sendable, Identifiable {
    public struct Exit: Codable, Equatable, Sendable {
        /// The exit code, or 128 + signal number when it was killed.
        public var status: Int32
        public var at: Date
        public init(status: Int32, at: Date) {
            self.status = status
            self.at = at
        }
    }

    public var id: UUID
    /// "ttys012": the agent's hooks and the process scan report this.
    public var tty: String
    /// The login shell the host started (process group leader).
    public var childPID: Int32
    public var cwd: String
    /// The preset's command; nil for a plain shell.
    public var command: String?
    /// The preset it was started from, e.g. "Claude".
    public var label: String
    /// The agent the preset starts (`Agent.rawValue`), nil for a shell.
    public var agent: String?
    /// The terminal title the program set (OSC 0/2).
    public var title: String
    public var startedAt: Date
    public var cols: Int
    public var rows: Int
    public var exit: Exit?

    public var isLive: Bool { exit == nil }

    public init(id: UUID, tty: String, childPID: Int32, cwd: String, command: String?, label: String, agent: String?,
                title: String, startedAt: Date, cols: Int, rows: Int, exit: Exit?) {
        self.id = id
        self.tty = tty
        self.childPID = childPID
        self.cwd = cwd
        self.command = command
        self.label = label
        self.agent = agent
        self.title = title
        self.startedAt = startedAt
        self.cols = cols
        self.rows = rows
        self.exit = exit
    }
}

public struct SpawnRequest: Codable, Equatable, Sendable {
    public var cwd: String
    /// Nil: a plain login shell.
    public var command: String?
    public var env: [String: String]
    public var cols: Int
    public var rows: Int
    /// After the command exits, keep a shell in the session instead of ending it.
    public var keepShell: Bool
    public var label: String
    public var agent: String?

    public init(cwd: String, command: String?, env: [String: String], cols: Int, rows: Int, keepShell: Bool,
                label: String, agent: String?) {
        self.cwd = cwd
        self.command = command
        self.env = env
        self.cols = cols
        self.rows = rows
        self.keepShell = keepShell
        self.label = label
        self.agent = agent
    }
}

public enum HostRequest: Codable, Equatable, Sendable {
    case hello(protocolVersion: Int, app: String)
    case spawn(SpawnRequest)
    case attach(id: UUID, cols: Int, rows: Int)
    case detach(id: UUID)
    /// `reply`: an automatic answer to a terminal query (cursor position, colors…), not typing.
    case input(id: UUID, bytes: Data, reply: Bool)
    case resize(id: UUID, cols: Int, rows: Int)
    case screen(id: UUID)
    case history(id: UUID, lines: Int)
    case kill(id: UUID)
    case remove(id: UUID)
    /// Honoured only when no session is live.
    case shutdown
}

public enum HostEvent: Codable, Equatable, Sendable {
    /// `hostBuild`: identifies the host binary (see `HostBuild`), so the app can tell an outdated host.
    case welcome(protocolVersion: Int, hostBuild: Int, sessions: [HostSession])
    case spawned(HostSession)
    /// Replay is over; live output follows.
    case attached(id: UUID)
    case screenText(id: UUID, text: String)
    case historyText(id: UUID, history: String, screen: String)
    case sessionChanged(HostSession)
    case sessionRemoved(id: UUID)
    /// This client fell behind and was detached; attach again.
    case resync(id: UUID)
    case bell(id: UUID)
    case error(String)
    case ok
}

public struct HostRequestEnvelope: Codable, Equatable, Sendable {
    public var seq: Int
    public var request: HostRequest
    public init(seq: Int, request: HostRequest) {
        self.seq = seq
        self.request = request
    }
}

public struct HostEventEnvelope: Codable, Equatable, Sendable {
    /// The `seq` of the request this answers; nil for events nobody asked for.
    public var replyTo: Int?
    public var event: HostEvent
    public init(replyTo: Int?, event: HostEvent) {
        self.replyTo = replyTo
        self.event = event
    }
}

public enum HostCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}

/// Identifies a host binary by its modification time: a rebuilt app bundles a newer one.
public enum HostBuild {
    public static func id(ofExecutableAt path: String) -> Int {
        let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        return Int(date?.timeIntervalSince1970 ?? 0)
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter "HostFrameTests|HostMessageTests" 2>&1 | tail -5`
Expected: `Test run with 6 tests passed` (SwiftTerm is fetched on first build; needs network).

- [ ] **Step 8: Run the whole suite** — `swift test 2>&1 | tail -3` → all pass (157 + 6).

- [ ] **Step 9: Commit**

```bash
git add Package.swift Package.resolved Sources/VibeCore/Paths.swift Sources/VibeCore/HostProtocol.swift Sources/VibeHost Sources/vibeswitcher-host Tests/VibeHostTests Tests/VibeCoreTests/HostProtocolTests.swift
git commit -m "Session host protocol: framed JSON control messages and per-session output frames; SwiftTerm 1.19.0 and the host targets

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Output ring buffer with reset points

**Files:**
- Create: `Sources/VibeCore/OutputRing.swift`
- Test: `Tests/VibeCoreTests/OutputRingTests.swift`

**Interfaces:**
- Produces: `OutputRing(capacity: Int)`, `mutating append(_ chunk: Data)`, `replay() -> Data`, `totalWritten: Int`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import VibeCore

struct OutputRingTests {
    func data(_ s: String) -> Data { Data(s.utf8) }

    @Test func replaysEverythingWhileNothingWasDropped() {
        var ring = OutputRing(capacity: 1024)
        ring.append(data("hello "))
        ring.append(data("world"))
        #expect(ring.replay() == data("hello world"))
        #expect(ring.totalWritten == 11)
    }

    @Test func replayStartsAtTheLatestClearScreen() {
        var ring = OutputRing(capacity: 1024)
        ring.append(data("old stuff\u{1b}[2Jfirst screen"))
        ring.append(data("\u{1b}[?1049hsecond screen"))
        #expect(ring.replay() == data("\u{1b}[?1049hsecond screen"))
    }

    @Test func aResetSplitAcrossAppendsIsFound() {
        var ring = OutputRing(capacity: 1024)
        ring.append(data("before\u{1b}[?10"))
        ring.append(data("49hafter"))
        #expect(ring.replay() == data("\u{1b}[?1049hafter"))
    }

    @Test func terminalResetCounts() {
        var ring = OutputRing(capacity: 1024)
        ring.append(data("junk\u{1b}cclean"))
        #expect(ring.replay() == data("\u{1b}cclean"))
    }

    @Test func afterDroppingOldOutputReplayStartsAtALineStart() {
        var ring = OutputRing(capacity: 16)
        ring.append(data("aaaaaaaaaaaa\nbbbbbbbbbb\ncc"))   // 26 bytes > 16 + 4: trims to the last 16
        // Kept: "aa\nbbbbbbbbbb\ncc"; replay skips the partial first line.
        #expect(ring.replay() == data("bbbbbbbbbb\ncc"))
    }

    @Test func resetsInDroppedOutputAreForgotten() {
        var ring = OutputRing(capacity: 16)
        ring.append(data("\u{1b}[2Jxxxxxxxxxxxxxxxxxxxxxxxxx\nyy"))
        #expect(!ring.replay().starts(with: data("\u{1b}[2J")))
        #expect(ring.replay() == data("yy"))
    }

    @Test func aResetMatchedInsideTheTailIsNotCountedTwice() {
        var ring = OutputRing(capacity: 1024)
        ring.append(data("x\u{1b}c"))
        ring.append(data("y"))
        ring.append(data("z"))
        #expect(ring.replay() == data("\u{1b}cyz"))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter OutputRingTests 2>&1 | tail -3` → compile error `cannot find 'OutputRing'`.

- [ ] **Step 3: Implement `Sources/VibeCore/OutputRing.swift`**

```swift
import Foundation

/// What a session printed recently, replayed when a view (re)attaches: the last `capacity` bytes, and
/// where in them the screen was last wiped (a replay starting there draws a whole screen instead of
/// the middle of an escape sequence). The program is asked to redraw after a replay anyway.
public struct OutputRing: Sendable {
    public let capacity: Int
    private var bytes = Data()
    /// Stream offset of `bytes[0]`.
    private var base = 0
    /// Stream offsets where a clear-screen, alternate-screen switch or terminal reset starts.
    private var resets: [Int] = []
    /// The stream's last few bytes, to find a sequence split across two appends.
    private var tail: [UInt8] = []

    static let resetSequences: [[UInt8]] = [
        "\u{1b}[2J", "\u{1b}c", "\u{1b}[?1049h", "\u{1b}[?1047h", "\u{1b}[?47h",
    ].map { Array($0.utf8) }
    static let longestReset = 8

    public init(capacity: Int) {
        self.capacity = capacity
    }

    /// Everything ever appended, in bytes.
    public var totalWritten: Int { base + bytes.count }

    public mutating func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        let window = tail + [UInt8](chunk)
        let windowStart = totalWritten - tail.count
        for i in window.indices where window[i] == 0x1b {
            for sequence in Self.resetSequences {
                let end = i + sequence.count
                // Only matches that end in the new chunk: the others were counted already (or can't be complete).
                guard end <= window.count, end > tail.count else { continue }
                if window[i..<end].elementsEqual(sequence) {
                    resets.append(windowStart + i)
                    break
                }
            }
        }
        bytes.append(chunk)
        tail = Array(window.suffix(Self.longestReset - 1))
        // Trim in batches: dropping the front of `Data` copies it.
        if bytes.count > capacity + capacity / 4 {
            let drop = bytes.count - capacity
            bytes = Data(bytes.dropFirst(drop))
            base += drop
            resets.removeAll { $0 < base }
        }
    }

    /// From the latest reset still held; else, once older output was dropped, from the first line start;
    /// else everything.
    public func replay() -> Data {
        if let reset = resets.last { return Data(bytes.dropFirst(reset - base)) }
        guard base > 0 else { return bytes }
        guard let newline = bytes.firstIndex(of: 0x0a) else { return Data() }
        return Data(bytes[bytes.index(after: newline)...])
    }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter OutputRingTests 2>&1 | tail -3` → 7 passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/VibeCore/OutputRing.swift Tests/VibeCoreTests/OutputRingTests.swift
git commit -m "Output ring: a session's recent output for replay, starting at the last screen clear

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: HostedSession — one PTY session

**Files:**
- Delete: `Sources/VibeHost/VibeHost.swift`
- Create: `Sources/VibeHost/HostedSession.swift`
- Test: `Tests/VibeHostTests/HostedSessionTests.swift`

**Interfaces:**
- Consumes: `OutputRing`, `HostSession`, `SpawnRequest` (Tasks 1–2).
- Produces (all members must be used on the session's `queue`):
  - `HostedSession.spawn(_ request: SpawnRequest, shell: String, baseEnvironment: [String: String], ringCapacity: Int, queue: DispatchQueue) throws -> HostedSession`
  - `HostedSession.arguments(shell: String, command: String?, keepShell: Bool) -> [String]` (static, pure)
  - `HostedSession.environment(base: [String: String], extra: [String: String], id: UUID) -> [String]` (static, pure)
  - `var info: HostSession { get }`, `var id: UUID`
  - `var onOutput: ((Data) -> Void)?`, `var onChange: ((HostSession) -> Void)?`, `var onBell: (() -> Void)?`
  - `var clientsAttached: Bool`
  - `func replay() -> Data`, `func write(_ bytes: Data)`, `func resize(cols: Int, rows: Int)`, `func nudgeRedraw()`
  - `func screenText() -> String`, `func historyText(lines: Int) -> (history: String, screen: String)`
  - `func terminate()`, `func close()`
  - `enum HostedSession.Failure: Error { case noSuchFolder(String), spawnFailed }`

- [ ] **Step 1: Write the failing tests** — `Tests/VibeHostTests/HostedSessionTests.swift`

```swift
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Real PTYs, scratch programs only (`/bin/sh -c …`). Never point these at a real agent session.
final class SessionProbe {
    let queue = DispatchQueue(label: "probe")
    private let lock = NSLock()
    private var buffer = Data()
    private var changes: [HostSession] = []

    func attach(_ session: HostedSession) {
        session.onOutput = { [weak self] data in self?.locked { $0.buffer.append(data) } }
        session.onChange = { [weak self] info in self?.locked { $0.changes.append(info) } }
    }
    func locked(_ body: (SessionProbe) -> Void) { lock.lock(); body(self); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: buffer, as: UTF8.self) }
    var lastChange: HostSession? { lock.lock(); defer { lock.unlock() }; return changes.last }
}

struct HostedSessionTests {
    func start(_ command: String?, keepShell: Bool = false, cwd: String = "/tmp", probe: SessionProbe) throws -> HostedSession {
        let request = SpawnRequest(cwd: cwd, command: command, env: ["PROBE": "yes"], cols: 80, rows: 24,
                                   keepShell: keepShell, label: "Test", agent: nil)
        return try probe.queue.sync {
            let session = try HostedSession.spawn(request, shell: "/bin/sh", baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                                  ringCapacity: 1 << 20, queue: probe.queue)
            probe.attach(session)
            return session
        }
    }

    @Test func argumentsUseAnInteractiveLoginShell() {
        #expect(HostedSession.arguments(shell: "/bin/zsh", command: "claude", keepShell: false)
                == ["/bin/zsh", "-l", "-i", "-c", "claude"])
        #expect(HostedSession.arguments(shell: "/bin/zsh", command: nil, keepShell: false) == ["/bin/zsh", "-l", "-i"])
        #expect(HostedSession.arguments(shell: "/bin/zsh", command: "codex", keepShell: true)
                == ["/bin/zsh", "-l", "-i", "-c", "codex; exec '/bin/zsh' -l -i"])
    }

    @Test func environmentAddsTerminalVariablesAndExtras() {
        let id = UUID()
        let env = HostedSession.environment(base: ["PATH": "/bin", "TERM": "dumb"], extra: ["FOO": "bar", "1BAD": "x"], id: id)
        #expect(env.contains("TERM=xterm-256color"))
        #expect(env.contains("COLORTERM=truecolor"))
        #expect(env.contains("TERM_PROGRAM=VibeSwitcher"))
        #expect(env.contains("VIBESWITCHER_SESSION=\(id.uuidString)"))
        #expect(env.contains("FOO=bar"))
        #expect(!env.contains { $0.hasPrefix("1BAD=") })
        #expect(env.contains { $0.hasPrefix("LANG=") })
    }

    @Test func runsTheCommandInThePTYAndRecordsTheExit() throws {
        let probe = SessionProbe()
        let session = try start("echo out:$PROBE; tty; exit 3", probe: probe)
        #expect(eventually { probe.text.contains("out:yes") })
        let tty = probe.queue.sync { session.info.tty }
        #expect(tty.hasPrefix("ttys"))
        #expect(eventually { probe.text.contains("/dev/\(tty)") })   // the PTY is its terminal
        #expect(eventually { probe.lastChange?.exit?.status == 3 })
        probe.queue.sync { session.close() }
    }

    @Test func inputReachesTheProgram() throws {
        let probe = SessionProbe()
        let session = try start("read line; echo got:$line", probe: probe)
        Thread.sleep(forTimeInterval: 0.3)
        probe.queue.sync { session.write(Data("hello\r".utf8)) }
        #expect(eventually { probe.text.contains("got:hello") })
        probe.queue.sync { session.close() }
    }

    @Test func resizeAndRedrawNudgeSendSIGWINCH() throws {
        let probe = SessionProbe()
        let session = try start("trap 'echo winch' WINCH; echo ready; while :; do sleep 0.05; done", probe: probe)
        #expect(eventually { probe.text.contains("ready") })
        probe.queue.sync { session.resize(cols: 100, rows: 30) }
        #expect(eventually { probe.text.contains("winch") })
        #expect(probe.queue.sync { (session.info.cols, session.info.rows) } == (100, 30))
        probe.queue.sync { session.terminate() }
        #expect(eventually(timeout: 8) { probe.lastChange?.exit != nil })
        probe.queue.sync { session.close() }
    }

    @Test func titleAndScreenComeFromTheHeadlessTerminal() throws {
        let probe = SessionProbe()
        let session = try start("printf '\\033]0;My Title\\007line one\\nline two\\n'; sleep 5", probe: probe)
        #expect(eventually { probe.lastChange?.title == "My Title" })
        #expect(eventually { probe.queue.sync { session.screenText() }.contains("line two") })
        let history = probe.queue.sync { session.historyText(lines: 100) }
        #expect((history.history + "\n" + history.screen).contains("line one"))
        probe.queue.sync { session.terminate(); session.close() }
    }

    @Test func headlessAnswersQueriesOnlyWhenNoClient() throws {
        // A device-status query (ESC[6n) expects a cursor report (ESC[row;colR) on the program's input.
        let probe = SessionProbe()
        let script = "stty raw -echo; printf '\\033[6n'; dd bs=1 count=6 2>/dev/null | od -c | head -1; stty sane; sleep 5"
        let session = try start(script, probe: probe)
        #expect(eventually { probe.text.contains("033") })   // od printed the reply's ESC: answered
        probe.queue.sync { session.terminate(); session.close() }

        let probe2 = SessionProbe()
        let attached = try start("stty raw -echo; sleep 0.5; printf '\\033[6n'; dd bs=1 count=1 2>/dev/null | od -c; stty sane", probe: probe2)
        probe2.queue.sync { attached.clientsAttached = true }   // a view would answer; the host must not
        Thread.sleep(forTimeInterval: 1.5)
        #expect(!probe2.text.contains("033"))
        probe2.queue.sync { attached.terminate(); attached.close() }
    }

    @Test func replayHoldsEarlierOutput() throws {
        let probe = SessionProbe()
        let session = try start("echo first; sleep 5", probe: probe)
        #expect(eventually { probe.text.contains("first") })
        #expect(String(decoding: probe.queue.sync { session.replay() }, as: UTF8.self).contains("first"))
        probe.queue.sync { session.terminate(); session.close() }
    }

    @Test func spawnRejectsMissingFolder() {
        let probe = SessionProbe()
        #expect(throws: HostedSession.Failure.noSuchFolder("/no/such/folder")) {
            _ = try start("true", cwd: "/no/such/folder", probe: probe)
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `swift test --filter HostedSessionTests 2>&1 | tail -3` → compile error.

- [ ] **Step 3: Implement `Sources/VibeHost/HostedSession.swift`** (delete `Sources/VibeHost/VibeHost.swift`)

```swift
import Foundation
import SwiftTerm
import VibeCore

/// One window session: its pseudo-terminal and child process, everything it printed (replay buffer and a
/// headless terminal for title, screen and scrollback text), and input/resize/kill.
/// Not thread-safe: every member is used on `queue`.
public final class HostedSession {
    public enum Failure: Error, Equatable {
        case noSuchFolder(String)
        case spawnFailed
    }

    public private(set) var info: HostSession
    public var id: UUID { info.id }
    /// Each chunk the program printed.
    public var onOutput: ((Data) -> Void)?
    /// Title, size or exit changed.
    public var onChange: ((HostSession) -> Void)?
    public var onBell: (() -> Void)?
    /// While a view is attached it answers terminal queries; the headless terminal's answers are dropped.
    public var clientsAttached = false

    private let masterFD: Int32
    private let queue: DispatchQueue
    private var ring: OutputRing
    private let terminal: Terminal
    private let headless = HeadlessDelegate()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var exitSource: DispatchSourceProcess?
    private var pendingInput = Data()
    private var closed = false
    static let maxPendingInput = 1 << 20

    private init(info: HostSession, masterFD: Int32, queue: DispatchQueue, ringCapacity: Int) {
        self.info = info
        self.masterFD = masterFD
        self.queue = queue
        ring = OutputRing(capacity: ringCapacity)
        terminal = Terminal(delegate: headless, options: TerminalOptions(cols: info.cols, rows: info.rows, scrollback: 5_000))
    }

    /// `$SHELL -l -i [-c command]`: an interactive login shell reads both `.zprofile` and `.zshrc`, so the
    /// agent gets the PATH it has in Terminal (nvm, Homebrew…).
    public static func arguments(shell: String, command: String?, keepShell: Bool) -> [String] {
        guard let command else { return [shell, "-l", "-i"] }
        let line = keepShell ? "\(command); exec \(RecentProjects.shellQuote(shell)) -l -i" : command
        return [shell, "-l", "-i", "-c", line]
    }

    public static func environment(base: [String: String], extra: [String: String], id: UUID) -> [String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "VibeSwitcher"
        env["VIBESWITCHER_SESSION"] = id.uuidString
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (name, value) in extra where LaunchPlan.validEnvName(name) { env[name] = value }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    public static func spawn(_ request: SpawnRequest, shell: String, baseEnvironment: [String: String],
                             ringCapacity: Int, queue: DispatchQueue) throws -> HostedSession {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.noSuchFolder(request.cwd)
        }
        let id = UUID()
        let cols = max(2, min(request.cols, 1000)), rows = max(2, min(request.rows, 500))
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        let args = arguments(shell: shell, command: request.command, keepShell: request.keepShell)
        let env = environment(base: baseEnvironment, extra: request.env, id: id)
        guard let child = PseudoTerminalHelpers.fork(andExec: shell, args: args, env: env,
                                                     currentDirectory: request.cwd, desiredWindowSize: &size) else {
            throw Failure.spawnFailed
        }
        let name = ptsname(child.masterFd).map { String(cString: $0) } ?? ""
        let tty = name.hasPrefix("/dev/") ? String(name.dropFirst(5)) : name
        _ = fcntl(child.masterFd, F_SETFL, fcntl(child.masterFd, F_GETFL) | O_NONBLOCK)
        // Not inherited by sessions started later: another session holding this PTY open would keep it alive.
        _ = fcntl(child.masterFd, F_SETFD, FD_CLOEXEC)
        let info = HostSession(id: id, tty: tty, childPID: child.pid, cwd: request.cwd, command: request.command,
                               label: request.label, agent: request.agent, title: "", startedAt: Date(),
                               cols: cols, rows: rows, exit: nil)
        let session = HostedSession(info: info, masterFD: child.masterFd, queue: queue, ringCapacity: ringCapacity)
        session.start()
        return session
    }

    private func start() {
        headless.onReply = { [weak self] data in
            guard let self, !self.clientsAttached else { return }
            self.write(data)
        }
        headless.onTitle = { [weak self] title in
            guard let self, self.info.title != title else { return }
            self.info.title = title
            self.onChange?(self.info)
        }
        headless.onBell = { [weak self] in self?.onBell?() }

        let read = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        read.setEventHandler { [weak self] in self?.drain() }
        read.resume()
        readSource = read

        let exit = DispatchSource.makeProcessSource(identifier: info.childPID, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.reap() }
        exit.resume()
        exitSource = exit
    }

    /// Reads what's available; never blocks (the PTY is nonblocking), so the program never waits on us.
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<16 {
            let count = Darwin.read(masterFD, &buffer, buffer.count)
            if count > 0 {
                let chunk = Data(buffer[0..<count])
                ring.append(chunk)
                terminal.feed(buffer: buffer[0..<count])
                onOutput?(chunk)
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            // 0 or EIO: the terminal's other side is closed (the program and everything it started are gone).
            readSource?.cancel()
            readSource = nil
            return
        }
    }

    private func reap() {
        var status: Int32 = 0
        guard waitpid(info.childPID, &status, WNOHANG) == info.childPID else { return }
        let signal = status & 0x7f
        let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        exitSource?.cancel()
        exitSource = nil
        info.exit = .init(status: code, at: Date())
        onChange?(info)
    }

    public func replay() -> Data { ring.replay() }

    /// Writes to the program's input; what doesn't fit right now waits (up to 1 MB) for room.
    public func write(_ bytes: Data) {
        guard !closed, !bytes.isEmpty else { return }
        if pendingInput.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(masterFD, $0.baseAddress, $0.count) }
            if written == bytes.count { return }
            let rest = written > 0 ? bytes.dropFirst(written) : bytes[...]
            guard written >= 0 || errno == EAGAIN || errno == EINTR else { return }
            pendingInput = Data(rest)
        } else {
            guard pendingInput.count + bytes.count <= Self.maxPendingInput else { return }
            pendingInput.append(bytes)
        }
        if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
            source.setEventHandler { [weak self] in self?.flushInput() }
            source.resume()
            writeSource = source
        }
    }

    private func flushInput() {
        let written = pendingInput.withUnsafeBytes { Darwin.write(masterFD, $0.baseAddress, $0.count) }
        if written > 0 { pendingInput = Data(pendingInput.dropFirst(written)) }
        if pendingInput.isEmpty || (written < 0 && errno != EAGAIN && errno != EINTR) {
            pendingInput = Data()
            writeSource?.cancel()
            writeSource = nil
        }
    }

    public func resize(cols: Int, rows: Int) {
        let cols = max(2, min(cols, 1000)), rows = max(2, min(rows, 500))
        guard cols != info.cols || rows != info.rows else { return }
        setWindowSize(cols: cols, rows: rows)
        terminal.resize(cols: cols, rows: rows)
        info.cols = cols
        info.rows = rows
        onChange?(info)
    }

    /// Makes the program repaint: one row smaller, then back (two SIGWINCHes). Claude Code and Codex redraw
    /// their whole screen on a resize, which fixes up an approximate replay.
    public func nudgeRedraw() {
        guard !closed, info.isLive else { return }
        setWindowSize(cols: info.cols, rows: max(2, info.rows - 1))
        queue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, !self.closed else { return }
            self.setWindowSize(cols: self.info.cols, rows: self.info.rows)
        }
    }

    private func setWindowSize(cols: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: masterFD, windowSize: &size)
    }

    public func screenText() -> String {
        (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    /// The last `lines` lines above the screen (normal buffer), and the screen itself.
    public func historyText(lines: Int) -> (history: String, screen: String) {
        let all = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
            .components(separatedBy: "\n")
        let screenRows = terminal.rows
        let above = all.count > screenRows ? Array(all[0..<(all.count - screenRows - 1)]) : []
        return (above.suffix(lines).joined(separator: "\n"), screenText())
    }

    /// Like closing a Terminal tab: SIGHUP to the session's process group, SIGKILL after 5 s.
    public func terminate() {
        guard info.isLive else { return }
        let group = info.childPID
        Darwin.kill(-group, SIGHUP)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.info.isLive else { return }
            Darwin.kill(-group, SIGKILL)
        }
    }

    /// Releases the PTY. Call after the session ended (or when the host quits).
    public func close() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        writeSource?.cancel()
        exitSource?.cancel()
        Darwin.close(masterFD)
    }
}

/// The headless terminal's delegate: replies to queries, title, bell.
final class HeadlessDelegate: TerminalDelegate {
    var onReply: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onBell: (() -> Void)?

    func send(source: Terminal, data: ArraySlice<UInt8>) { onReply?(Data(data)) }
    func setTerminalTitle(source: Terminal, title: String) { onTitle?(title) }
    func bell(source: Terminal) { onBell?() }
}
```

`LaunchPlan.validEnvName` is created in Task 6; to keep this task compiling on its own, add it now in `Sources/VibeCore/LaunchPresets.swift` (Task 6 extends this file):

```swift
import Foundation

/// Building what a preset runs.
public enum LaunchPlan {
    /// Shell variable names: a letter or underscore, then letters, digits, underscores.
    public static func validEnvName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first),
              name.unicodeScalars.allSatisfy({ $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) })
        else { return false }
        return first.isASCII
    }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter HostedSessionTests 2>&1 | tail -5` → 9 passed. If `TerminalDelegate` reports missing members at compile time, add empty implementations for exactly those members (the protocol extension in SwiftTerm 1.19.0 provides defaults for all but `send`).

- [ ] **Step 5: Commit**

```bash
git rm -q Sources/VibeHost/VibeHost.swift
git add Sources/VibeHost/HostedSession.swift Sources/VibeCore/LaunchPresets.swift Tests/VibeHostTests/HostedSessionTests.swift
git commit -m "Hosted session: a PTY running the agent through an interactive login shell, with replay buffer, headless terminal (title, screen, scrollback), input, resize and kill

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Socket server and client

**Files:**
- Create: `Sources/VibeCore/UnixSocket.swift`
- Create: `Sources/VibeCore/HostConnection.swift`
- Create: `Sources/VibeHost/ClientConnection.swift`
- Create: `Sources/VibeHost/HostServer.swift`
- Test: `Tests/VibeHostTests/HostServerTests.swift`

**Interfaces:**
- Consumes: Task 1 protocol types; Task 3 `HostedSession`.
- Produces:
  - `UnixSocket.connect(path:) throws -> Int32`, `UnixSocket.listen(path:) throws -> Int32`, `UnixSocket.configure(_ fd: Int32)`, `UnixSocket.peerUID(_ fd: Int32) -> uid_t?`, `UnixSocket.Failure`
  - `HostConnection(path: String, queue: DispatchQueue) throws`; `onEvent: ((HostEventEnvelope) -> Void)?`, `onOutput: ((UUID, Data) -> Void)?`, `onClose: (() -> Void)?`; `@discardableResult send(_ request: HostRequest) -> Int`; `close()`. All calls on `queue`.
  - `HostServer(config: HostServer.Config)`; `HostServer.Config(socketPath:lockPath:shell:baseEnvironment:hostBuild:)` with vars `ringCapacity` (8 MB), `idleExit: TimeInterval?` (600), `keepEnded` (86 400), `housekeepingInterval` (30); `start() throws`; `stop(terminateSessions: Bool)`; `onExit: (() -> Void)?`; `queue: DispatchQueue`; `HostServer.Failure.alreadyRunning`.

- [ ] **Step 1: Write the failing tests** — `Tests/VibeHostTests/HostServerTests.swift`

```swift
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A host on a scratch socket, running `/bin/sh` sessions only.
final class TestHost {
    let socket = scratchSocketPath()
    let lock: String
    let server: HostServer

    init(build: Int = 42) throws {
        lock = socket + ".lock"
        var config = HostServer.Config(socketPath: socket, lockPath: lock, shell: "/bin/sh",
                                       baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], hostBuild: build)
        config.idleExit = nil
        config.ringCapacity = 1 << 20
        server = HostServer(config: config)
        try server.start()
    }

    deinit {
        server.stop(terminateSessions: true)
        unlink(lock)
    }
}

/// The app's side, recording everything it receives.
final class TestClient {
    let queue = DispatchQueue(label: "test-client")
    private let lock = NSLock()
    private var events: [HostEventEnvelope] = []
    private var output: [UUID: Data] = [:]
    private(set) var closed = false
    var connection: HostConnection!

    init(_ host: TestHost) throws {
        try queue.sync {
            connection = try HostConnection(path: host.socket, queue: queue)
            connection.onEvent = { [weak self] e in self?.with { $0.events.append(e) } }
            connection.onOutput = { [weak self] id, data in self?.with { $0.output[id, default: Data()].append(data) } }
            connection.onClose = { [weak self] in self?.with { $0.closed = true } }
        }
    }

    func with(_ body: (TestClient) -> Void) { lock.lock(); body(self); lock.unlock() }
    @discardableResult func send(_ request: HostRequest) -> Int { queue.sync { connection.send(request) } }
    func text(_ id: UUID) -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: output[id] ?? Data(), as: UTF8.self) }
    func reply(to seq: Int) -> HostEvent? {
        lock.lock(); defer { lock.unlock() }
        return events.first { $0.replyTo == seq }?.event
    }
    func hasEvent(_ match: (HostEvent) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return events.contains { match($0.event) }
    }
    func close() { queue.sync { connection.close() } }

    /// Spawns a scratch program and waits for the reply.
    func spawn(_ command: String, cwd: String = "/tmp") throws -> HostSession {
        let seq = send(.spawn(SpawnRequest(cwd: cwd, command: command, env: [:], cols: 80, rows: 24, keepShell: false,
                                           label: "Test", agent: nil)))
        #expect(eventually { reply(to: seq) != nil })
        guard case .spawned(let session) = reply(to: seq) else { throw CancellationError() }
        return session
    }

    func attach(_ id: UUID) {
        let seq = send(.attach(id: id, cols: 80, rows: 24))
        #expect(eventually { reply(to: seq) == .attached(id: id) })
    }
}

struct HostServerTests {
    @Test func helloListsSessionsAndTheBuild() throws {
        let host = try TestHost(build: 42)
        let client = try TestClient(host)
        let session = try client.spawn("sleep 5")
        let seq = client.send(.hello(protocolVersion: HostProtocol.version, app: "test"))
        #expect(eventually { client.reply(to: seq) != nil })
        guard case .welcome(let version, let build, let sessions) = client.reply(to: seq) else { Issue.record("no welcome"); return }
        #expect(version == HostProtocol.version && build == 42)
        #expect(sessions.map(\.id) == [session.id])
    }

    @Test func inputAndOutputFlowThroughAnAttachedSession() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let session = try client.spawn("read x; echo got:$x; sleep 5")
        client.attach(session.id)
        client.send(.input(id: session.id, bytes: Data("hi\r".utf8), reply: false))
        #expect(eventually { client.text(session.id).contains("got:hi") })
    }

    @Test func reattachReplaysEarlierOutput() throws {
        let host = try TestHost()
        let first = try TestClient(host)
        let session = try first.spawn("echo first-line; sleep 10")
        first.attach(session.id)
        #expect(eventually { first.text(session.id).contains("first-line") })
        first.close()
        let second = try TestClient(host)
        second.attach(session.id)
        #expect(eventually { second.text(session.id).contains("first-line") })
    }

    @Test func aSecondHostRefusesToStart() throws {
        let host = try TestHost()
        let config = HostServer.Config(socketPath: scratchSocketPath(), lockPath: host.lock, shell: "/bin/sh",
                                       baseEnvironment: [:], hostBuild: 1)
        #expect(throws: HostServer.Failure.alreadyRunning) { try HostServer(config: config).start() }
    }

    @Test func repliesFromNonPrimaryClientAreDropped() throws {
        let host = try TestHost()
        let a = try TestClient(host)
        let session = try a.spawn("read x; echo got:$x; sleep 5")
        a.attach(session.id)
        let b = try TestClient(host)
        b.attach(session.id)   // the latest to attach is primary
        a.send(.input(id: session.id, bytes: Data("zzz".utf8), reply: true))
        b.send(.input(id: session.id, bytes: Data("ok\r".utf8), reply: true))
        #expect(eventually { b.text(session.id).contains("got:") })
        #expect(b.text(session.id).contains("got:ok"))
        #expect(!b.text(session.id).contains("zzz"))
    }

    @Test func slowClientGetsResyncAndProgramKeepsRunning() throws {
        let host = try TestHost()
        let watcher = try TestClient(host)
        let session = try watcher.spawn("sleep 0.5; head -c 40000000 /dev/zero | tr '\\0' x; echo; echo all-done; sleep 5")
        // A client that attaches and then never reads: the host must not wait for it.
        let fd = try UnixSocket.connect(path: host.socket)
        defer { close(fd) }
        let attach = HostFrame.encode(.control, try HostCoding.encode(HostRequestEnvelope(seq: 1, request:
            .attach(id: session.id, cols: 80, rows: 24))))
        _ = attach.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        // The program finishes (its output wasn't blocked), which the host reports on screen.
        #expect(eventually(timeout: 30) {
            let seq = watcher.send(.screen(id: session.id))
            Thread.sleep(forTimeInterval: 0.2)
            if case .screenText(_, let text) = watcher.reply(to: seq) { return text.contains("all-done") }
            return false
        })
        // Now drain the slow client: somewhere in its stream is a resync.
        var decoder = HostFrameDecoder()
        var sawResync = false
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = Date().addingTimeInterval(10)
        while !sawResync, Date() < deadline {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { decoder.append(Data(buffer[0..<count])) } else { Thread.sleep(forTimeInterval: 0.01) }
            while let frame = try decoder.next() {
                if frame.kind == .control,
                   let envelope = try? HostCoding.decode(HostEventEnvelope.self, from: frame.payload),
                   envelope.event == .resync(id: session.id) { sawResync = true }
            }
        }
        #expect(sawResync)
    }

    @Test func killEndsTheSessionAndRemoveForgetsIt() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let session = try client.spawn("sleep 30 & sleep 30; wait")
        let early = client.send(.remove(id: session.id))
        #expect(eventually { client.reply(to: early) != nil })
        #expect(client.reply(to: early) == .error("The session is still running."))
        client.send(.kill(id: session.id))
        #expect(eventually(timeout: 8) { client.hasEvent { if case .sessionChanged(let s) = $0 { return s.id == session.id && s.exit != nil }; return false } })
        let seq = client.send(.remove(id: session.id))
        #expect(eventually { client.reply(to: seq) == .ok })
        #expect(eventually { client.hasEvent { $0 == .sessionRemoved(id: session.id) } })
    }

    @Test func spawnInAMissingFolderIsAnError() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let seq = client.send(.spawn(SpawnRequest(cwd: "/no/such/folder", command: "true", env: [:], cols: 80, rows: 24,
                                                  keepShell: false, label: "Test", agent: nil)))
        #expect(eventually { client.reply(to: seq) != nil })
        #expect(client.reply(to: seq) == .error("No such folder: /no/such/folder"))
    }

    @Test func shutdownWaitsForLiveSessions() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        _ = try client.spawn("sleep 30")
        let seq = client.send(.shutdown)
        #expect(eventually { client.reply(to: seq) != nil })
        #expect(client.reply(to: seq) == .error("Sessions are running."))
    }

    @Test func connectionsComeFromThisUser() throws {
        let host = try TestHost()
        let fd = try UnixSocket.connect(path: host.socket)
        defer { close(fd) }
        #expect(UnixSocket.peerUID(fd) == getuid())
        var info = stat()
        #expect(stat(host.socket, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `swift test --filter HostServerTests 2>&1 | tail -3` → compile errors.

- [ ] **Step 3: Implement `Sources/VibeCore/UnixSocket.swift`**

```swift
import Darwin
import Foundation

/// Unix-domain socket plumbing shared by the session host and the app.
public enum UnixSocket {
    public enum Failure: Error, Equatable {
        case pathTooLong
        case system(String, Int32)
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// A connected, nonblocking socket.
    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        do {
            var address = try address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw Failure.system("connect", errno) }
        } catch {
            Darwin.close(fd)
            throw error
        }
        configure(fd)
        return fd
    }

    /// Listens on `path`, replacing a stale socket file; only the owner may connect (0600).
    public static func listen(path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        do {
            var address = try address(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw Failure.system("bind", errno) }
            guard chmod(path, 0o600) == 0 else { throw Failure.system("chmod", errno) }
            guard Darwin.listen(fd, 16) == 0 else { throw Failure.system("listen", errno) }
        } catch {
            Darwin.close(fd)
            throw error
        }
        configure(fd)
        return fd
    }

    /// Nonblocking, no SIGPIPE on writes to a closed peer, not inherited by programs the host starts.
    public static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The user id of the process at the other end.
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }
}
```

- [ ] **Step 4: Implement `Sources/VibeCore/HostConnection.swift`**

```swift
import Darwin
import Foundation

/// The app's end of the session host socket. Every call and callback is on `queue`.
public final class HostConnection {
    public var onEvent: ((HostEventEnvelope) -> Void)?
    public var onOutput: ((UUID, Data) -> Void)?
    /// The connection ended (the host quit or crashed, or sent something unreadable). Called once.
    public var onClose: (() -> Void)?

    private let fd: Int32
    private let queue: DispatchQueue
    private var decoder = HostFrameDecoder()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var outgoing = Data()
    private var nextSeq = 1
    private var closed = false

    public init(path: String, queue: DispatchQueue) throws {
        fd = try UnixSocket.connect(path: path)
        self.queue = queue
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        readSource = source
        source.resume()
    }

    deinit { readSource?.cancel() }

    /// Sends a request; replies carry the returned number as `replyTo`.
    @discardableResult
    public func send(_ request: HostRequest) -> Int {
        let seq = nextSeq
        nextSeq += 1
        guard !closed, let payload = try? HostCoding.encode(HostRequestEnvelope(seq: seq, request: request)),
              payload.count <= HostFrame.maxPayload else { return seq }
        outgoing.append(HostFrame.encode(.control, payload))
        flush()
        return seq
    }

    public func close() { finish(notify: false) }

    private func flush() {
        while !outgoing.isEmpty {
            let written = outgoing.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                outgoing = Data(outgoing.dropFirst(written))
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                break
            } else {
                return finish(notify: true)
            }
        }
        if outgoing.isEmpty {
            writeSource?.cancel()
            writeSource = nil
        } else if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.flush() }
            source.resume()
            writeSource = source
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !closed {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                decoder.append(Data(buffer[0..<count]))
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { break }
            deliver()
            return finish(notify: true)
        }
        deliver()
    }

    private func deliver() {
        do {
            while !closed, let frame = try decoder.next() {
                switch frame.kind {
                case .control:
                    // An event this app doesn't know (a newer host) is skipped, not fatal.
                    if let envelope = try? HostCoding.decode(HostEventEnvelope.self, from: frame.payload) { onEvent?(envelope) }
                case .output:
                    if let (id, bytes) = HostFrame.parseOutput(frame.payload) { onOutput?(id, bytes) }
                }
            }
        } catch {
            finish(notify: true)
        }
    }

    private func finish(notify: Bool) {
        guard !closed else { return }
        closed = true
        writeSource?.cancel()
        writeSource = nil
        readSource?.cancel()
        readSource = nil
        if notify { onClose?() }
    }
}
```

- [ ] **Step 5: Implement `Sources/VibeHost/ClientConnection.swift`**

```swift
import Darwin
import Foundation
import VibeCore

/// One connected app, on the server's queue. Writes never block: they queue up to `maxQueued` bytes;
/// output beyond that means the app fell behind (the server detaches it from that session and says resync).
final class ClientConnection {
    /// More than a full replay (8 MB ring) plus room for live output.
    static let maxQueued = 16 << 20

    let fd: Int32
    var attached: Set<UUID> = []
    var onFrame: ((HostFrame.Kind, Data) -> Void)?
    var onClose: (() -> Void)?

    private let queue: DispatchQueue
    private var decoder = HostFrameDecoder()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private struct Pending {
        var data: Data
        /// Output of this session (droppable on resync); nil for control frames.
        var session: UUID?
    }
    private var pending: [Pending] = []
    /// Bytes of `pending[0]` already written.
    private var headWritten = 0
    private(set) var queuedBytes = 0
    private(set) var closed = false

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        readSource = source
        source.resume()
    }

    func send(_ envelope: HostEventEnvelope) {
        guard let payload = try? HostCoding.encode(envelope), payload.count <= HostFrame.maxPayload else { return }
        enqueue(Pending(data: HostFrame.encode(.control, payload), session: nil))
    }

    /// False when this would exceed the queue limit: nothing was queued.
    func sendOutput(_ id: UUID, frames: [Data]) -> Bool {
        let size = frames.reduce(0) { $0 + $1.count }
        guard queuedBytes + size <= Self.maxQueued else { return false }
        frames.forEach { enqueue(Pending(data: $0, session: id)) }
        return true
    }

    /// Drops queued output of `id`, except a frame already partly written (cutting it would corrupt the stream).
    func dropQueuedOutput(of id: UUID) {
        var kept: [Pending] = []
        for (index, item) in pending.enumerated() {
            if item.session == id, !(index == 0 && headWritten > 0) { queuedBytes -= item.data.count } else { kept.append(item) }
        }
        pending = kept
    }

    func close() {
        guard !closed else { return }
        closed = true
        writeSource?.cancel()
        writeSource = nil
        readSource?.cancel()
        readSource = nil
        onClose?()
    }

    private func enqueue(_ item: Pending) {
        guard !closed else { return }
        pending.append(item)
        queuedBytes += item.data.count
        flush()
    }

    private func flush() {
        while let head = pending.first {
            let written = head.data.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + headWritten, raw.count - headWritten)
            }
            if written > 0 {
                headWritten += written
                if headWritten == head.data.count {
                    pending.removeFirst()
                    queuedBytes -= head.data.count
                    headWritten = 0
                }
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                break
            } else {
                return close()
            }
        }
        if pending.isEmpty {
            writeSource?.cancel()
            writeSource = nil
        } else if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.flush() }
            source.resume()
            writeSource = source
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !closed {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                decoder.append(Data(buffer[0..<count]))
            } else if count < 0, errno == EAGAIN || errno == EINTR {
                break
            } else {
                return close()
            }
        }
        do {
            while !closed, let frame = try decoder.next() { onFrame?(frame.kind, frame.payload) }
        } catch {
            close()
        }
    }
}
```

- [ ] **Step 6: Implement `Sources/VibeHost/HostServer.swift`**

```swift
import Darwin
import Foundation
import VibeCore

/// The session host: one per user (a lock file), serving the app over a Unix socket. Everything runs on `queue`.
public final class HostServer {
    public struct Config {
        public var socketPath: String
        public var lockPath: String
        public var shell: String
        public var baseEnvironment: [String: String]
        public var hostBuild: Int
        public var ringCapacity = 8 << 20
        /// Quit after this long with no live session and no app connected; nil: never.
        public var idleExit: TimeInterval? = 600
        /// Ended sessions are forgotten after this long.
        public var keepEnded: TimeInterval = 24 * 3600
        public var housekeepingInterval: TimeInterval = 30

        public init(socketPath: String, lockPath: String, shell: String, baseEnvironment: [String: String], hostBuild: Int) {
            self.socketPath = socketPath
            self.lockPath = lockPath
            self.shell = shell
            self.baseEnvironment = baseEnvironment
            self.hostBuild = hostBuild
        }
    }

    public enum Failure: Error, Equatable {
        case alreadyRunning
        case lock(Int32)
    }

    public let queue = DispatchQueue(label: "vibeswitcher.host")
    /// Called (on `queue`) after an idle exit or an accepted `shutdown`, once everything is closed.
    public var onExit: (() -> Void)?

    private let config: Config
    private var sessions: [UUID: HostedSession] = [:]
    private var order: [UUID] = []
    private var clients: [ObjectIdentifier: ClientConnection] = [:]
    /// Per session, the client whose terminal answers queries and sets the size: the last to attach or type.
    private var primary: [UUID: ObjectIdentifier] = [:]
    private var lockFD: Int32 = -1
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var housekeeping: DispatchSourceTimer?
    private var lastBusy = Date()
    private var stopped = false

    public init(config: Config) {
        self.config = config
    }

    public func start() throws {
        queue.setSpecific(key: Self.queueKey, value: true)
        lockFD = open(config.lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw Failure.lock(errno) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD)
            lockFD = -1
            throw Failure.alreadyRunning
        }
        // Holding the lock: any socket file left behind is stale.
        listenFD = try UnixSocket.listen(path: config.socketPath)
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.resume()
        acceptSource = source

        let interval = config.idleExit.map { min(config.housekeepingInterval, max(0.5, $0 / 3)) } ?? config.housekeepingInterval
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.tidy() }
        timer.resume()
        housekeeping = timer
    }

    /// Closes everything. `terminateSessions`: also end the programs (tests); otherwise they lose their terminal anyway.
    public func stop(terminateSessions: Bool) {
        let work = {
            guard !self.stopped else { return }
            self.stopped = true
            self.acceptSource?.cancel()
            self.housekeeping?.cancel()
            self.clients.values.forEach { $0.close() }
            self.clients = [:]
            for session in self.sessions.values {
                if terminateSessions { session.terminate() }
                session.close()
            }
            self.sessions = [:]
            if self.listenFD >= 0 { Darwin.close(self.listenFD); unlink(self.config.socketPath) }
            if self.lockFD >= 0 { Darwin.close(self.lockFD) }
            self.listenFD = -1
            self.lockFD = -1
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { work() } else { queue.sync(execute: work) }
    }

    private static let queueKey = DispatchSpecificKey<Bool>()

    private func acceptAll() {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            guard UnixSocket.peerUID(fd) == getuid() else {
                Darwin.close(fd)
                continue
            }
            UnixSocket.configure(fd)
            let client = ClientConnection(fd: fd, queue: queue)
            let key = ObjectIdentifier(client)
            client.onFrame = { [weak self, weak client] kind, payload in
                guard let self, let client else { return }
                self.handle(kind, payload, from: client)
            }
            client.onClose = { [weak self] in self?.dropClient(key) }
            clients[key] = client
            client.start()
        }
    }

    private var allInfo: [HostSession] { order.compactMap { sessions[$0]?.info } }

    private func handle(_ kind: HostFrame.Kind, _ payload: Data, from client: ClientConnection) {
        guard kind == .control, let envelope = try? HostCoding.decode(HostRequestEnvelope.self, from: payload) else {
            return client.close()
        }
        let key = ObjectIdentifier(client)
        let reply: (HostEvent) -> Void = { client.send(HostEventEnvelope(replyTo: envelope.seq, event: $0)) }
        let missing = HostEvent.error("No such session.")
        switch envelope.request {
        case .hello:
            reply(.welcome(protocolVersion: HostProtocol.version, hostBuild: config.hostBuild, sessions: allInfo))
        case .spawn(let request):
            do {
                let session = try HostedSession.spawn(request, shell: config.shell, baseEnvironment: config.baseEnvironment,
                                                      ringCapacity: config.ringCapacity, queue: queue)
                register(session)
                reply(.spawned(session.info))
                broadcast(.sessionChanged(session.info), except: key)
            } catch HostedSession.Failure.noSuchFolder(let path) {
                reply(.error("No such folder: \(path)"))
            } catch {
                reply(.error("Couldn't start the session."))
            }
        case .attach(let id, let cols, let rows):
            guard let session = sessions[id] else { return reply(missing) }
            client.attached.insert(id)
            primary[id] = key
            session.clientsAttached = true
            if !client.sendOutput(id, frames: HostFrame.output(session: id, bytes: session.replay())) {
                client.attached.remove(id)
                updateAttachment(id)
                return reply(.resync(id: id))
            }
            reply(.attached(id: id))
            session.resize(cols: cols, rows: rows)
            session.nudgeRedraw()
        case .detach(let id):
            client.attached.remove(id)
            updateAttachment(id)
            reply(.ok)
        case .input(let id, let bytes, let isReply):
            guard let session = sessions[id] else { return }
            if isReply {
                guard primary[id] == key else { return }
            } else {
                primary[id] = key
            }
            session.write(bytes)
        case .resize(let id, let cols, let rows):
            guard let session = sessions[id], primary[id] == nil || primary[id] == key else { return }
            session.resize(cols: cols, rows: rows)
        case .screen(let id):
            reply(sessions[id].map { .screenText(id: id, text: $0.screenText()) } ?? missing)
        case .history(let id, let lines):
            guard let session = sessions[id] else { return reply(missing) }
            let text = session.historyText(lines: max(1, min(lines, 5_000)))
            reply(.historyText(id: id, history: text.history, screen: text.screen))
        case .kill(let id):
            sessions[id]?.terminate()
            reply(.ok)
        case .remove(let id):
            guard let session = sessions[id] else { return reply(.ok) }
            guard !session.info.isLive else { return reply(.error("The session is still running.")) }
            forget(id)
            reply(.ok)
        case .shutdown:
            guard !sessions.values.contains(where: { $0.info.isLive }) else { return reply(.error("Sessions are running.")) }
            reply(.ok)
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.stop(terminateSessions: false)
                self?.onExit?()
            }
        }
    }

    private func register(_ session: HostedSession) {
        let id = session.id
        sessions[id] = session
        order.append(id)
        session.onOutput = { [weak self] data in self?.deliver(data, of: id) }
        session.onChange = { [weak self] info in self?.broadcast(.sessionChanged(info)) }
        session.onBell = { [weak self] in self?.broadcast(.bell(id: id)) }
    }

    private func deliver(_ data: Data, of id: UUID) {
        let frames = HostFrame.output(session: id, bytes: data)
        for client in clients.values where client.attached.contains(id) {
            guard !client.sendOutput(id, frames: frames) else { continue }
            // Fell behind: stop sending it this session; it attaches again and gets a fresh replay.
            client.attached.remove(id)
            client.dropQueuedOutput(of: id)
            client.send(HostEventEnvelope(replyTo: nil, event: .resync(id: id)))
            updateAttachment(id)
        }
    }

    private func updateAttachment(_ id: UUID) {
        let watching = clients.filter { $0.value.attached.contains(id) }
        sessions[id]?.clientsAttached = !watching.isEmpty
        if let current = primary[id], watching[current] == nil { primary[id] = watching.keys.first }
    }

    private func broadcast(_ event: HostEvent, except: ObjectIdentifier? = nil) {
        for (key, client) in clients where key != except { client.send(HostEventEnvelope(replyTo: nil, event: event)) }
    }

    private func dropClient(_ key: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: key) else { return }
        client.attached.forEach(updateAttachment)
    }

    private func forget(_ id: UUID) {
        sessions.removeValue(forKey: id)?.close()
        order.removeAll { $0 == id }
        primary[id] = nil
        for client in clients.values { client.attached.remove(id) }
        broadcast(.sessionRemoved(id: id))
    }

    private func tidy() {
        let now = Date()
        for session in sessions.values {
            if let exit = session.info.exit, now.timeIntervalSince(exit.at) > config.keepEnded { forget(session.id) }
        }
        if !clients.isEmpty || sessions.values.contains(where: { $0.info.isLive }) {
            lastBusy = now
        } else if let idle = config.idleExit, now.timeIntervalSince(lastBusy) >= idle {
            stop(terminateSessions: false)
            onExit?()
        }
    }
}
```

`stop` may run on `queue` (from `tidy` or `shutdown`) or from outside (tests); the `queueKey` marker set in `start()` tells which.

- [ ] **Step 7: Run tests** — `swift test --filter HostServerTests 2>&1 | tail -5` → 9 passed. Then `swift test 2>&1 | tail -3` → all pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/VibeCore/UnixSocket.swift Sources/VibeCore/HostConnection.swift Sources/VibeHost/ClientConnection.swift Sources/VibeHost/HostServer.swift Tests/VibeHostTests/HostServerTests.swift
git commit -m "Session host server and client: one host per user (lock), owner-only socket, attach with replay and redraw, input and query replies from the primary client, slow clients resynced instead of blocking the program, kill/remove/shutdown

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The `vibeswitcher-host` executable and bundling

**Files:**
- Modify: `Sources/vibeswitcher-host/main.swift`
- Modify: `scripts/build-app.sh`

**Interfaces:**
- Consumes: `HostServer`, `HostBuild`, `VibePaths`.
- Produces: executable `vibeswitcher-host` accepting `--socket PATH`, `--lock PATH`, `--idle-exit SECONDS`; bundled at `VibeSwitcher.app/Contents/MacOS/vibeswitcher-host`.

- [ ] **Step 1: Write `Sources/vibeswitcher-host/main.swift`**

```swift
import Foundation
import VibeCore
import VibeHost

// The session host: keeps the window's sessions running while VibeSwitcher quits, crashes or updates.
// The app starts it detached (its own session); it exits by itself once idle. One per user.

signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

VibePaths.ensurePrivateDirectories()
let environment = ProcessInfo.processInfo.environment
// What a fresh Terminal session would inherit from launchd; the login shell adds the rest.
let inherited = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "SSH_AUTH_SOCK",
                 "__CF_USER_TEXT_ENCODING"]
let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
var config = HostServer.Config(
    socketPath: value(after: "--socket") ?? VibePaths.hostSocket.path,
    lockPath: value(after: "--lock") ?? VibePaths.hostLock.path,
    shell: shell,
    baseEnvironment: environment.filter { inherited.contains($0.key) },
    hostBuild: HostBuild.id(ofExecutableAt: Bundle.main.executablePath ?? arguments[0]))
config.idleExit = value(after: "--idle-exit").flatMap(TimeInterval.init) ?? 600

let server = HostServer(config: config)
server.onExit = { exit(0) }
do {
    try server.start()
} catch HostServer.Failure.alreadyRunning {
    exit(0)
} catch {
    FileHandle.standardError.write(Data("vibeswitcher-host: \(error)\n".utf8))
    exit(1)
}
FileHandle.standardError.write(Data("vibeswitcher-host: started \(Date())\n".utf8))
dispatchMain()
```

- [ ] **Step 2: Verify the lock and idle exit by hand (scratch paths only)**

```bash
swift build 2>&1 | tail -1
H=.build/debug/vibeswitcher-host; S=/tmp/vsh-manual.sock; L=/tmp/vsh-manual.lock
$H --socket $S --lock $L --idle-exit 3 & sleep 1
$H --socket $S --lock $L; echo "second copy exit=$?"        # expect: second copy exit=0 (immediately)
ls -l $S                                                     # expect: srw------- 
sleep 4; pgrep -f vsh-manual.sock || echo "idle exit ok"     # expect: idle exit ok
rm -f $L
```

- [ ] **Step 3: Bundle it in `scripts/build-app.sh`**

Replace
```bash
cp "$BIN/VibeSwitcher" "$BIN/vibeswitcher-hook" "$APP/Contents/MacOS/"
```
with
```bash
cp "$BIN/VibeSwitcher" "$BIN/vibeswitcher-hook" "$BIN/vibeswitcher-host" "$APP/Contents/MacOS/"
```
After `cp -R Web "$APP/Contents/Resources/Web"` add
```bash
# SwiftPM resource bundles (SwiftTerm's Metal shaders); found through Bundle.main.resourceURL.
for bundle in "$BIN"/*.bundle; do [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"; done
```
and replace
```bash
codesign --force "${IDENTITY[@]}" "$APP/Contents/MacOS/vibeswitcher-hook"
```
with
```bash
codesign --force "${IDENTITY[@]}" "$APP/Contents/MacOS/vibeswitcher-hook"
codesign --force "${IDENTITY[@]}" "$APP/Contents/MacOS/vibeswitcher-host"
```

- [ ] **Step 4: Verify the bundle** — `./scripts/build-app.sh 2>&1 | tail -2 && ls build/VibeSwitcher.app/Contents/MacOS build/VibeSwitcher.app/Contents/Resources && codesign --verify --deep --strict build/VibeSwitcher.app && echo signed-ok` → lists `VibeSwitcher vibeswitcher-hook vibeswitcher-host`, `signed-ok`. (Do not pass `--install` here.)

- [ ] **Step 5: Commit**

```bash
git add Sources/vibeswitcher-host/main.swift scripts/build-app.sh
git commit -m "vibeswitcher-host executable (lock, idle exit, scratch --socket/--lock for testing), bundled and signed with the app

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Launch presets

**Files:**
- Modify: `Sources/VibeCore/LaunchPresets.swift` (created in Task 3 with `LaunchPlan.validEnvName`)
- Test: `Tests/VibeCoreTests/LaunchPresetsTests.swift`

**Interfaces:**
- Produces: `LaunchPreset` (`id`, `name`, `kind: Kind {claude, codex, shell}`, `command`, `env`, `keepShell`, `place: Place {window, terminal}`, `agent: Agent?`); `LaunchPresets` (`global`, `byProject: [String: [LaunchPreset]]`, `defaults: [String: UUID]`, `static builtIns(claudeCommand:codexCommand:)`, `presets(for root: String?) -> [LaunchPreset]`, `defaultPreset(for:) -> LaunchPreset?`, `preset(id:) -> LaunchPreset?`, `static load(from:claudeCommand:codexCommand:) -> LaunchPresets`, `save(to:) throws`); `LaunchPlan.command(for:) -> String?`, `LaunchPlan.terminalLine(for:in:) -> String`, `LaunchPlan.resumeCommand(base:agent:sessionID:) -> String`, `LaunchPlan.validEnvName(_:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import VibeCore

struct LaunchPresetsTests {
    @Test func builtInsCarryTheOldLaunchCommands() {
        let presets = LaunchPresets.builtIns(claudeCommand: "claude --model opus", codexCommand: " ")
        #expect(presets.global.map(\.name) == ["Claude", "Codex", "Shell"])
        #expect(presets.global[0].command == "claude --model opus")
        #expect(presets.global[1].command == "codex")
        #expect(presets.global.allSatisfy { $0.place == .window })
    }

    @Test func aProjectsDefaultComesFirstThenItsOwnThenGlobal() {
        var presets = LaunchPresets.builtIns()
        let own = LaunchPreset(name: "Opus", kind: .claude, command: "claude --model opus")
        presets.byProject["/p"] = [own]
        #expect(presets.presets(for: "/p").map(\.name) == ["Opus", "Claude", "Codex", "Shell"])
        presets.defaults["/p"] = presets.global[1].id
        #expect(presets.presets(for: "/p").map(\.name) == ["Codex", "Opus", "Claude", "Shell"])
        #expect(presets.defaultPreset(for: "/p")?.name == "Codex")
        #expect(presets.presets(for: "/other").map(\.name) == ["Claude", "Codex", "Shell"])
        #expect(presets.presets(for: nil).first?.name == "Claude")
        #expect(presets.preset(id: own.id) == own)
    }

    @Test func commandsForTheHost() {
        #expect(LaunchPlan.command(for: LaunchPreset(name: "S", kind: .shell, command: "ignored")) == nil)
        #expect(LaunchPlan.command(for: LaunchPreset(name: "C", kind: .codex, command: "  ")) == "codex")
        #expect(LaunchPlan.command(for: LaunchPreset(name: "C", kind: .claude, command: " claude -c ")) == "claude -c")
    }

    @Test func terminalLineQuotesFolderAndEnvironment() {
        let preset = LaunchPreset(name: "C", kind: .claude, command: "claude",
                                  env: ["B": "two words", "A": "it's", "9X": "bad"])
        #expect(LaunchPlan.terminalLine(for: preset, in: "/tmp/my dir")
                == "cd '/tmp/my dir' && A='it'\\''s' B='two words' claude")
        #expect(LaunchPlan.terminalLine(for: LaunchPreset(name: "S", kind: .shell, command: ""), in: "/x") == "cd '/x'")
    }

    @Test func resumeCommands() {
        #expect(LaunchPlan.resumeCommand(base: "claude --model opus", agent: .claude, sessionID: "abc")
                == "claude --model opus --resume 'abc'")
        #expect(LaunchPlan.resumeCommand(base: nil, agent: .codex, sessionID: "x-1") == "codex resume 'x-1'")
    }

    @Test func envNames() {
        #expect(LaunchPlan.validEnvName("ANTHROPIC_MODEL"))
        #expect(LaunchPlan.validEnvName("_x1"))
        #expect(!LaunchPlan.validEnvName("1A"))
        #expect(!LaunchPlan.validEnvName("A-B"))
        #expect(!LaunchPlan.validEnvName(""))
        #expect(!LaunchPlan.validEnvName("É"))
    }

    @Test func loadFallsBackToBuiltInsAndSaveRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("presets.json")
        #expect(LaunchPresets.load(from: file, claudeCommand: "claude -c", codexCommand: "codex") ==
                LaunchPresets.builtIns(claudeCommand: "claude -c", codexCommand: "codex"))
        try Data("not json".utf8).write(to: file)
        #expect(LaunchPresets.load(from: file, claudeCommand: "claude", codexCommand: "codex").global.count == 3)
        var presets = LaunchPresets.builtIns()
        presets.byProject["/p"] = [LaunchPreset(name: "Mine", kind: .shell, command: "", keepShell: true, place: .terminal)]
        try presets.save(to: file)
        #expect(LaunchPresets.load(from: file, claudeCommand: "", codexCommand: "") == presets)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `swift test --filter LaunchPresetsTests 2>&1 | tail -3` → compile errors.

- [ ] **Step 3: Replace `Sources/VibeCore/LaunchPresets.swift` with**

```swift
import Foundation

/// A way to start a session: which agent, its exact command, extra environment, and where it runs.
public struct LaunchPreset: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case claude, codex, shell

        public var label: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .shell: return "Shell"
            }
        }
    }

    public enum Place: String, Codable, CaseIterable, Sendable {
        /// VibeSwitcher's window (the session host).
        case window
        /// A new Terminal.app window, as before.
        case terminal
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// What runs, e.g. `claude --model opus`. Ignored for a shell.
    public var command: String
    public var env: [String: String]
    /// When the agent exits, keep a shell open in the session.
    public var keepShell: Bool
    public var place: Place

    public var agent: Agent? {
        switch kind {
        case .claude: return .claude
        case .codex: return .codex
        case .shell: return nil
        }
    }

    public init(id: UUID = UUID(), name: String, kind: Kind, command: String, env: [String: String] = [:],
                keepShell: Bool = false, place: Place = .window) {
        self.id = id
        self.name = name
        self.kind = kind
        self.command = command
        self.env = env
        self.keepShell = keepShell
        self.place = place
    }
}

/// All presets: global ones, ones that belong to a project, and each project's default.
public struct LaunchPresets: Codable, Equatable, Sendable {
    public var global: [LaunchPreset]
    /// By project root.
    public var byProject: [String: [LaunchPreset]]
    /// Each project's default preset, by project root.
    public var defaults: [String: UUID]

    public init(global: [LaunchPreset], byProject: [String: [LaunchPreset]] = [:], defaults: [String: UUID] = [:]) {
        self.global = global
        self.byProject = byProject
        self.defaults = defaults
    }

    /// Fixed ids, so a project's default survives the built-ins being recreated.
    static let claudeID = UUID(uuidString: "00000000-0000-0000-0000-00000000C1A0")!
    static let codexID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!
    static let shellID = UUID(uuidString: "00000000-0000-0000-0000-000000005E11")!

    /// Claude, Codex and Shell, using the commands from the old "Launch Commands…" setting.
    public static func builtIns(claudeCommand: String = "claude", codexCommand: String = "codex") -> LaunchPresets {
        func or(_ command: String, _ fallback: String) -> String {
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? fallback : trimmed
        }
        return LaunchPresets(global: [
            LaunchPreset(id: claudeID, name: "Claude", kind: .claude, command: or(claudeCommand, "claude")),
            LaunchPreset(id: codexID, name: "Codex", kind: .codex, command: or(codexCommand, "codex")),
            LaunchPreset(id: shellID, name: "Shell", kind: .shell, command: ""),
        ])
    }

    /// The project's default first, then its own presets, then the global ones.
    public func presets(for root: String?) -> [LaunchPreset] {
        var list = (root.flatMap { byProject[$0] } ?? []) + global
        if let root, let id = defaults[root], let index = list.firstIndex(where: { $0.id == id }) {
            list.insert(list.remove(at: index), at: 0)
        }
        return list
    }

    public func defaultPreset(for root: String?) -> LaunchPreset? { presets(for: root).first }

    public func preset(id: UUID) -> LaunchPreset? {
        (global + byProject.values.flatMap { $0 }).first { $0.id == id }
    }

    /// Saved presets, or the built-ins (from the old two commands) when there are none or the file is unreadable.
    public static func load(from url: URL, claudeCommand: String, codexCommand: String) -> LaunchPresets {
        guard let data = try? Data(contentsOf: url),
              let presets = try? JSONDecoder().decode(LaunchPresets.self, from: data), !presets.global.isEmpty
        else { return builtIns(claudeCommand: claudeCommand, codexCommand: codexCommand) }
        return presets
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Building what a preset runs.
public enum LaunchPlan {
    /// What the session host runs; nil for a shell.
    public static func command(for preset: LaunchPreset) -> String? {
        guard preset.kind != .shell else { return nil }
        let command = preset.command.trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? preset.kind.rawValue : command
    }

    /// For Terminal.app: `cd '<folder>' && NAME='value' … <command>`; a shell preset only changes folder.
    public static func terminalLine(for preset: LaunchPreset, in directory: String) -> String {
        guard let command = command(for: preset) else { return "cd \(RecentProjects.shellQuote(directory))" }
        let env = preset.env.filter { validEnvName($0.key) }.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(RecentProjects.shellQuote($0.value)) " }.joined()
        return RecentProjects.shellCommand(cd: directory, run: env + command)
    }

    /// Picks up an ended session where it left off: `claude … --resume <id>` / `codex … resume <id>`.
    public static func resumeCommand(base: String?, agent: Agent, sessionID: String) -> String {
        let trimmed = base?.trimmingCharacters(in: .whitespaces) ?? ""
        let command = trimmed.isEmpty ? agent.rawValue : trimmed
        let id = RecentProjects.shellQuote(sessionID)
        switch agent {
        case .claude: return "\(command) --resume \(id)"
        case .codex: return "\(command) resume \(id)"
        }
    }

    /// Shell variable names: an ASCII letter or underscore, then ASCII letters, digits, underscores.
    public static func validEnvName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII, first == "_" || CharacterSet.letters.contains(first)
        else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || CharacterSet.alphanumerics.contains($0)) }
    }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter "LaunchPresetsTests|HostedSessionTests" 2>&1 | tail -3` → all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VibeCore/LaunchPresets.swift Tests/VibeCoreTests/LaunchPresetsTests.swift
git commit -m "Launch presets: per-project and global presets (agent, command, environment, keep shell, window or Terminal), migrated from the two launch commands; resume commands

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: HostClient in the app

**Files:**
- Create: `Sources/VibeSwitcher/HostClient.swift`
- Modify: `Sources/VibeSwitcher/AppDelegate.swift` (own a `HostClient`, connect at launch, write host state into the status file)

**Interfaces:**
- Consumes: `HostConnection`, protocol types, `HostBuild`, `VibePaths`.
- Produces (main thread): `final class HostClient: ObservableObject` with `@Published sessions: [HostSession]`, `@Published state: HostClient.State` (`.notRunning`, `.connecting`, `.connected`, `.outdated(live: Int, compatible: Bool)`, `.failed(String)`), `var isUsable: Bool`, `var onBell: ((UUID) -> Void)?`, `screens: [String: String]` (by tty), `connectIfRunning()`, `spawn(_:completion: (Result<HostSession, HostClientError>) -> Void)`, `attach(_ id: UUID, cols: Int, rows: Int, sink: HostClient.Sink)`, `detach(_:)`, `send(_ id: UUID, bytes: Data, reply: Bool)`, `resize(_:cols:rows:)`, `screen(_:completion: (String?) -> Void)`, `history(_:lines:completion: ((history: String, screen: String)?) -> Void)`, `kill(_:)`, `remove(_:)`, `refreshScreens(ttys: Set<String>)`, `restartHost()`; `struct HostClient.Sink { output: (Data) -> Void; attached: () -> Void; resync: () -> Void }`; `struct HostClientError: Error, LocalizedError { message: String }`.

- [ ] **Step 1: Implement `Sources/VibeSwitcher/HostClient.swift`**

```swift
import AppKit
import Combine
import VibeCore

struct HostClientError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// The app's link to `vibeswitcher-host`: one connection, the host started when a window session is first
/// needed, the hosted sessions published, each session's output routed to the view that attached it.
/// Main thread only.
final class HostClient: ObservableObject {
    enum State: Equatable {
        case notRunning
        case connecting
        case connected
        /// The running host is an older build; it keeps serving its live sessions (if the protocol matches)
        /// and is replaced once none are left.
        case outdated(live: Int, compatible: Bool)
        case failed(String)
    }

    struct Sink {
        var output: (Data) -> Void
        /// Replay is over; live output follows.
        var attached: () -> Void
        /// The host dropped this view's stream: clear it; it's attached again with a fresh replay.
        var resync: () -> Void
    }

    @Published private(set) var sessions: [HostSession] = []
    @Published private(set) var state: State = .notRunning
    var onBell: ((UUID) -> Void)?
    /// Each live session's screen text by tty, refreshed by `refreshScreens` (the store reads Claude's footer from it).
    private(set) var screens: [String: String] = [:]

    private var connection: HostConnection?
    private var replies: [Int: (HostEvent) -> Void] = [:]
    private var sinks: [UUID: (sink: Sink, cols: Int, rows: Int)] = [:]
    private var whenReady: [(String?) -> Void] = []
    private var replacing = false
    private var restartWhenEnded = false
    private var hostProcess: DispatchSourceProcess?

    static var hostExecutable: URL {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host")
    }

    var isUsable: Bool {
        switch state {
        case .connected, .outdated(_, true): return true
        default: return false
        }
    }

    /// At launch: reattach to a host that's already running; don't start one.
    func connectIfRunning() {
        _ = connect()
    }

    /// Connects (starting the host if it isn't running) and calls `ready` with nil, or why it couldn't.
    func ensureHost(_ ready: @escaping (String?) -> Void) {
        if isUsable { return ready(nil) }
        whenReady.append(ready)
        guard connection == nil else { return }   // a welcome is on its way
        if connect() { return }
        do {
            try startHost()
        } catch {
            return finishWaiting("Couldn't start the session host: \(error.localizedDescription)")
        }
        retryConnect(attempts: 30)
    }

    private func retryConnect(attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard self.connection == nil else { return }
            if self.connect() { return }
            if attempts > 0 { return self.retryConnect(attempts: attempts - 1) }
            self.state = .failed("The session host didn't start. See ~/.vibeswitcher/host.log.")
            self.finishWaiting("The session host didn't start. See ~/.vibeswitcher/host.log.")
        }
    }

    private func finishWaiting(_ error: String?) {
        let waiting = whenReady
        whenReady = []
        waiting.forEach { $0(error) }
    }

    @discardableResult
    private func connect() -> Bool {
        if connection != nil { return true }
        guard let connection = try? HostConnection(path: VibePaths.hostSocket.path, queue: .main) else { return false }
        self.connection = connection
        state = .connecting
        connection.onEvent = { [weak self] in self?.handle($0) }
        connection.onOutput = { [weak self] id, bytes in self?.sinks[id]?.sink.output(bytes) }
        connection.onClose = { [weak self] in self?.connectionLost() }
        connection.send(.hello(protocolVersion: HostProtocol.version, app: "VibeSwitcher"))
        return true
    }

    /// Detached (own session, not our child for signals), stdout/stderr appended to host.log.
    private func startHost() throws {
        let path = Self.hostExecutable.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw HostClientError(message: "vibeswitcher-host is missing from the app")
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, VibePaths.hostLog.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        guard result == 0 else { throw HostClientError(message: String(cString: strerror(result))) }
        // Reap it when it exits (idle exit or replacement) so it doesn't linger as a zombie.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            self?.hostProcess?.cancel()
            self?.hostProcess = nil
        }
        source.resume()
        hostProcess = source
    }

    private func connectionLost() {
        connection = nil
        let pending = replies
        replies = [:]
        pending.values.forEach { $0(.error("The session host went away.")) }
        if replacing {
            replacing = false
            try? startHost()
            return retryConnect(attempts: 30)
        }
        // A host that's gone took its sessions with it.
        sessions = []
        screens = [:]
        state = .notRunning
        sinks.values.forEach { $0.sink.resync() }
        finishWaiting("The session host stopped.")
    }

    private func handle(_ envelope: HostEventEnvelope) {
        if let seq = envelope.replyTo, let reply = replies.removeValue(forKey: seq) { reply(envelope.event) }
        switch envelope.event {
        case .welcome(let version, let build, let list):
            sessions = list
            let live = list.filter(\.isLive).count
            let bundled = HostBuild.id(ofExecutableAt: Self.hostExecutable.path)
            if version == HostProtocol.version, build == bundled || bundled == 0 {
                state = .connected
            } else if live == 0 {
                return replaceHost()
            } else {
                state = .outdated(live: live, compatible: version == HostProtocol.version)
            }
            finishWaiting(isUsable ? nil : "The session host is out of date. Restart it from the window.")
            for (id, entry) in sinks { sendAttach(id, cols: entry.cols, rows: entry.rows) }
        case .spawned(let session), .sessionChanged(let session):
            upsert(session)
        case .sessionRemoved(let id):
            sessions.removeAll { $0.id == id }
            sinks[id] = nil
        case .resync(let id):
            guard let entry = sinks[id] else { return }
            entry.sink.resync()
            sendAttach(id, cols: entry.cols, rows: entry.rows)
        case .bell(let id):
            onBell?(id)
        default:
            break
        }
    }

    private func upsert(_ session: HostSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session } else { sessions.append(session) }
        if !session.isLive { screens[session.tty] = nil }
        if case .outdated = state, !sessions.contains(where: \.isLive) { replaceHost() }
        else if restartWhenEnded, !sessions.contains(where: \.isLive) { restartWhenEnded = false; replaceHost() }
    }

    /// Asks an idle host to quit; `connectionLost` then starts the bundled one.
    private func replaceHost() {
        guard !replacing else { return }
        replacing = true
        request(.shutdown) { [weak self] event in
            if case .error = event { self?.replacing = false }
        }
    }

    /// Ends every window session, then replaces the host (for an incompatible, outdated host).
    func restartHost() {
        restartWhenEnded = true
        sessions.filter(\.isLive).forEach { kill($0.id) }
        if !sessions.contains(where: \.isLive) { restartWhenEnded = false; replaceHost() }
    }

    private func request(_ request: HostRequest, reply: ((HostEvent) -> Void)? = nil) {
        guard let connection else {
            reply?(.error("Not connected to the session host."))
            return
        }
        let seq = connection.send(request)
        if let reply { replies[seq] = reply }
    }

    func spawn(_ spawn: SpawnRequest, completion: @escaping (Result<HostSession, HostClientError>) -> Void) {
        ensureHost { error in
            if let error { return completion(.failure(HostClientError(message: error))) }
            self.request(.spawn(spawn)) { event in
                switch event {
                case .spawned(let session):
                    self.upsert(session)
                    completion(.success(session))
                case .error(let message):
                    completion(.failure(HostClientError(message: message)))
                default:
                    completion(.failure(HostClientError(message: "Unexpected reply from the session host.")))
                }
            }
        }
    }

    func attach(_ id: UUID, cols: Int, rows: Int, sink: Sink) {
        sinks[id] = (sink, cols, rows)
        sendAttach(id, cols: cols, rows: rows)
    }

    private func sendAttach(_ id: UUID, cols: Int, rows: Int) {
        request(.attach(id: id, cols: cols, rows: rows)) { [weak self] event in
            if case .attached = event { self?.sinks[id]?.sink.attached() }
        }
    }

    func detach(_ id: UUID) {
        guard sinks.removeValue(forKey: id) != nil else { return }
        request(.detach(id: id))
    }

    func send(_ id: UUID, bytes: Data, reply: Bool) {
        request(.input(id: id, bytes: bytes, reply: reply))
    }

    func resize(_ id: UUID, cols: Int, rows: Int) {
        if sinks[id] != nil { sinks[id]?.cols = cols; sinks[id]?.rows = rows }
        request(.resize(id: id, cols: cols, rows: rows))
    }

    func screen(_ id: UUID, completion: @escaping (String?) -> Void) {
        request(.screen(id: id)) { event in
            if case .screenText(_, let text) = event { completion(text) } else { completion(nil) }
        }
    }

    func history(_ id: UUID, lines: Int, completion: @escaping ((history: String, screen: String)?) -> Void) {
        request(.history(id: id, lines: lines)) { event in
            if case .historyText(_, let history, let screen) = event { completion((history, screen)) } else { completion(nil) }
        }
    }

    func kill(_ id: UUID) { request(.kill(id: id)) }

    func remove(_ id: UUID) {
        request(.remove(id: id)) { [weak self] event in
            if case .ok = event { self?.sessions.removeAll { $0.id == id } }
        }
    }

    /// Re-reads the screens of these live sessions (by tty) into `screens`.
    func refreshScreens(ttys: Set<String>) {
        screens = screens.filter { ttys.contains($0.key) }
        for session in sessions where session.isLive && ttys.contains(session.tty) {
            screen(session.id) { [weak self] text in self?.screens[session.tty] = text }
        }
    }
}
```

- [ ] **Step 2: Wire it into `AppDelegate`**

Add a property next to `store`: `let hostClient = HostClient()`.
In `applicationDidFinishLaunching`, right after `VibePaths.ensurePrivateDirectories()`, add:
```swift
        hostClient.connectIfRunning()
```
Add to the status file (in the existing `store.$sessions` sink is not needed; add a separate sink after it):
```swift
        hostClient.$state
            .receive(on: RunLoop.main)
            .sink { state in
                AppStatus.extras["host"] = "\(state)"
            }
            .store(in: &cancellables)
```

- [ ] **Step 3: Build** — `swift build 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | tail -5` → `Build complete!` with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/VibeSwitcher/HostClient.swift Sources/VibeSwitcher/AppDelegate.swift
git commit -m "HostClient: the app reattaches to a running session host at launch, starts it detached when a window session is needed, replaces an outdated host once its sessions end, and routes each session's output to its view

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Window sessions in the session model and store

**Files:**
- Modify: `Sources/VibeCore/Models.swift`
- Create: `Sources/VibeCore/WindowRows.swift`
- Modify: `Sources/VibeSwitcher/SessionStore.swift`
- Modify: `Sources/VibeSwitcher/AppDelegate.swift` (feed hosted sessions and screens into the store)
- Test: `Tests/VibeCoreTests/WindowRowsTests.swift`

**Interfaces:**
- Consumes: `HostSession`, `HostClient`.
- Produces: `Session.hostID: UUID?`, `Session.inWindow: Bool`, `Session.agentSessionID: String?`; `WindowRow` (`content: .agent(Session) | .hosted(HostSession)`, `project`, `id: String`, `hostID: UUID?`); `WindowSection` (`project`, `rows`, `id`); `WindowRows.extras(hosted:agentTTYs:) -> [HostSession]`; `WindowRows.sections(sessions:hosted:projectName:) -> [WindowSection]`; `SessionStore.updateHosted(_ sessions: [HostSession])`, `SessionStore.windowViewingTTY: String?` (setter refreshes), `SessionStore.hostScreens: () -> [String: String]`, `SessionStore.requestHostScreens: (Set<String>) -> Void`.

- [ ] **Step 1: Write the failing tests** — `Tests/VibeCoreTests/WindowRowsTests.swift`

```swift
import Foundation
import Testing
@testable import VibeCore

struct WindowRowsTests {
    func agent(_ tty: String, project: String, host: UUID? = nil) -> Session {
        var session = Session(tty: tty, agent: .claude, pid: 1, startedAt: Date(), cwd: "/dev/\(project)", project: project,
                              task: nil, status: .idle, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: host == nil)
        session.hostID = host
        return session
    }

    func hosted(_ tty: String, cwd: String, live: Bool = true, started: TimeInterval = 0) -> HostSession {
        HostSession(id: UUID(), tty: tty, childPID: 2, cwd: cwd, command: nil, label: "Shell", agent: nil, title: "",
                    startedAt: Date(timeIntervalSince1970: started), cols: 80, rows: 24,
                    exit: live ? nil : .init(status: 0, at: Date()))
    }

    @Test func extrasAreHostedSessionsWithoutALiveAgent() {
        let withAgent = hosted("ttys001", cwd: "/a")
        let shell = hosted("ttys002", cwd: "/a")
        let ended = hosted("ttys003", cwd: "/a", live: false)
        let extras = WindowRows.extras(hosted: [withAgent, shell, ended], agentTTYs: ["ttys001", "ttys003"])
        #expect(extras.map(\.id) == [shell.id, ended.id])   // an ended session stays even if its tty is reused
    }

    @Test func sectionsFollowTheStoreOrderThenAddExtras() {
        let windowID = UUID()
        let sessions = [agent("ttys005", project: "beta"), agent("ttys001", project: "alpha", host: windowID),
                        agent("ttys002", project: "beta")]
        let older = hosted("ttys009", cwd: "/x/alpha", started: 1)
        let newer = hosted("ttys010", cwd: "/x/gamma", started: 2)
        let ended = hosted("ttys011", cwd: "/x/alpha", live: false, started: 3)
        let sections = WindowRows.sections(sessions: sessions, hosted: [older, ended, newer],
                                           projectName: { ($0 as NSString).lastPathComponent })
        #expect(sections.map(\.project) == ["beta", "alpha", "gamma"])
        #expect(sections[0].rows.map(\.id) == ["tty:ttys005", "tty:ttys002"])
        #expect(sections[1].rows.map(\.id) == ["host:\(windowID)", "host:\(older.id)", "host:\(ended.id)"])
        #expect(sections[1].rows[0].hostID == windowID)
    }

    @Test func aWindowSessionKeepsItsRowIDWhenItsAgentEnds() {
        let id = UUID()
        let running = WindowRow(content: .agent(agent("ttys001", project: "a", host: id)), project: "a")
        var info = hosted("ttys001", cwd: "/a", live: false)
        info.id = id
        let ended = WindowRow(content: .hosted(info), project: "a")
        #expect(running.id == ended.id)
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `swift test --filter WindowRowsTests 2>&1 | tail -3` → compile errors.

- [ ] **Step 3: Add to `Session` in `Sources/VibeCore/Models.swift`** (after `transcriptPath`)

```swift
    /// The session host's id for it when it runs in VibeSwitcher's window; nil in Terminal.app or elsewhere.
    public var hostID: UUID?
    public var inWindow: Bool { hostID != nil }
    /// The agent's own session id (from its hooks): what `--resume` takes.
    public var agentSessionID: String?
```

- [ ] **Step 4: Create `Sources/VibeCore/WindowRows.swift`**

```swift
import Foundation

/// One row of the window's session list.
public struct WindowRow: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// An agent session the scan found (in the window, in Terminal.app, or elsewhere).
        case agent(Session)
        /// A window session with no live agent: a shell, an ended session, or one that is still starting.
        case hosted(HostSession)
    }

    public var content: Content
    public var project: String

    public init(content: Content, project: String) {
        self.content = content
        self.project = project
    }

    /// Window sessions are keyed by their host id, so a row keeps its identity (and selection) when the
    /// agent in it ends.
    public var id: String {
        switch content {
        case .agent(let session): return session.hostID.map { "host:\($0)" } ?? "tty:\(session.tty)"
        case .hosted(let session): return "host:\(session.id)"
        }
    }

    public var hostID: UUID? {
        switch content {
        case .agent(let session): return session.hostID
        case .hosted(let session): return session.id
        }
    }
}

public struct WindowSection: Identifiable, Equatable, Sendable {
    public var project: String
    public var rows: [WindowRow]
    public var id: String { project }
}

public enum WindowRows {
    /// Hosted sessions the scan didn't match to a live agent.
    public static func extras(hosted: [HostSession], agentTTYs: Set<String>) -> [HostSession] {
        hosted.filter { !($0.isLive && agentTTYs.contains($0.tty)) }
    }

    /// Sections by project, in the store's order; window-only rows (live first, newest first) after.
    public static func sections(sessions: [Session], hosted: [HostSession], projectName: (String) -> String) -> [WindowSection] {
        var order: [String] = []
        var rows: [String: [WindowRow]] = [:]
        func add(_ row: WindowRow) {
            if rows[row.project] == nil { order.append(row.project) }
            rows[row.project, default: []].append(row)
        }
        sessions.forEach { add(WindowRow(content: .agent($0), project: $0.project)) }
        let extras = extras(hosted: hosted, agentTTYs: Set(sessions.map(\.tty))).sorted {
            if $0.isLive != $1.isLive { return $0.isLive }
            return $0.startedAt < $1.startedAt
        }
        extras.forEach { add(WindowRow(content: .hosted($0), project: projectName($0.cwd))) }
        return order.map { WindowSection(project: $0, rows: rows[$0] ?? []) }
    }
}
```

(The test expects older-before-newer within live extras: sort ascending by `startedAt`, as written.)

- [ ] **Step 5: Run tests** — `swift test --filter WindowRowsTests 2>&1 | tail -3` → 3 passed.

- [ ] **Step 6: Teach `SessionStore` about window sessions** (`Sources/VibeSwitcher/SessionStore.swift`)

Add properties (main-thread section):
```swift
    /// Live window sessions by tty, from the session host.
    private var hosted: [String: HostSession] = [:]
    /// The window session shown in the (key) main window; it counts as being looked at.
    var windowViewingTTY: String? { didSet { if windowViewingTTY != oldValue { refresh() } } }
    /// Window sessions' screen text by tty (Claude's footer shows background work), and how to ask for fresh text.
    var hostScreens: () -> [String: String] = { [:] }
    var requestHostScreens: (Set<String>) -> Void = { _ in }
    private var lastHostScreenRequest = Date.distantPast

    func updateHosted(_ sessions: [HostSession]) {
        hosted = Dictionary(sessions.filter(\.isLive).map { ($0.tty, $0) }, uniquingKeysWith: { $1 })
        refresh()
    }
```
In `refresh(forceTerminal:)`, after `let quiet = quietClaudeTTYs`, add:
```swift
        let hosted = self.hosted
        let hostQuiet = quiet.intersection(hosted.keys)
        if !hostQuiet.isEmpty, forceTerminal || Date().timeIntervalSince(lastHostScreenRequest) >= 6 {
            lastHostScreenRequest = Date()
            requestHostScreens(hostQuiet)
        }
        let hostScreens = self.hostScreens()
```
In the scan closure, replace `let background = self.backgroundWork` with:
```swift
            var background = self.backgroundWork
            for (tty, screen) in hostScreens where hosted[tty] != nil {
                background[tty] = BackgroundWork.summary(fromScreen: screen)
            }
```
and pass `hosted` into `apply`: change the call to `self.apply(raw: raw, tabs: tabs, hosted: hosted, background: background, transcripts: transcripts, now: now)`, change the signature to `private func apply(raw: [RawSession], tabs: [String: TerminalTab], hosted: [String: HostSession], background: [String: String], transcripts: [String: String], now: Date)`, and in `refreshNow()` pass `hosted: [:]`.

In `apply`, replace
```swift
            let tab = tabs[item.tty]
            let parsed = tab.map { StatusRules.parseTitle($0.title) }
```
with
```swift
            let tab = tabs[item.tty]
            let window = hosted[item.tty]
            let parsed = (tab?.title ?? window?.title).map { StatusRules.parseTitle($0) }
```
replace
```swift
            let viewing = terminalFront && tab.map { $0.isSelected && $0.isOnScreenTab && $0.windowOrder == 1 } == true
```
with
```swift
            let viewing = (terminalFront && tab.map { $0.isSelected && $0.isOnScreenTab && $0.windowOrder == 1 } == true)
                || (window != nil && windowViewingTTY == item.tty)
```
and after `session.transcriptPath = transcripts[item.tty]` add:
```swift
            session.hostID = window?.id
            session.agentSessionID = item.hook?.sessionId
```

- [ ] **Step 7: Feed the store from `AppDelegate`** (after the `hostClient.$state` sink from Task 7)

```swift
        store.hostScreens = { [weak self] in self?.hostClient.screens ?? [:] }
        store.requestHostScreens = { [weak self] ttys in self?.hostClient.refreshScreens(ttys: ttys) }
        hostClient.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in self?.store.updateHosted(sessions) }
            .store(in: &cancellables)
```

- [ ] **Step 8: Build and test** — `swift build 2>&1 | tail -1 && swift test 2>&1 | tail -2` → build complete, all tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/VibeCore/Models.swift Sources/VibeCore/WindowRows.swift Sources/VibeSwitcher/SessionStore.swift Sources/VibeSwitcher/AppDelegate.swift Tests/VibeCoreTests/WindowRowsTests.swift
git commit -m "Window sessions in the store: title, viewing and Claude's background-work footer come from the session host for sessions in the window; the window's list is grouped by project and keeps a row when its agent ends

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: The main window

**Files:**
- Create: `Sources/VibeSwitcher/MainWindow/WindowModel.swift`
- Create: `Sources/VibeSwitcher/MainWindow/TerminalPane.swift`
- Create: `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Create: `Sources/VibeSwitcher/MainWindow/SessionHeaderView.swift`
- Create: `Sources/VibeSwitcher/MainWindow/InspectorView.swift`
- Create: `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Create: `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Modify: `Sources/VibeSwitcher/AppDelegate.swift`, `Sources/VibeSwitcher/AppStatus.swift`, `Sources/VibeSwitcher/main.swift`, `Sources/VibeSwitcher/PopoverView.swift`

**Interfaces:**
- Consumes: `HostClient` (Task 7), `WindowRows`/`WindowRow`/`WindowSection`, `Session.hostID`/`agentSessionID` (Task 8), `LaunchPresets`, `LaunchPlan` (Task 6), `SessionStore.windowViewingTTY`.
- Produces:
  - `WindowModel` (`sections`, `selectedID`, `selectedRow`, `rows`, `agentSessions: [UUID: (agent: Agent, sessionID: String)]`, `update(sessions:hosted:)`, `select(hostID:)`, `select(tty:)`, `select(index:)`, `move(by:)`, `selectNextNeedingYou()`)
  - `extension WindowRow { var session: Session?; var hosted: HostSession?; var cwd: String? }`
  - `struct WindowActions` (closures: `newSession(LaunchPreset?, String?)`, `endSession(WindowRow)`, `resume(WindowRow)`, `remove(WindowRow)`, `rename(Session)`, `pause(Session, PauseStore.Duration)`, `resumePaused(Session)`, `openInTerminal(Session)`, `presets(String?) -> [LaunchPreset]`, `isLive(WindowRow) -> Bool`, `canResume(WindowRow) -> Bool`)
  - `HostTerminalView` (SwiftTerm `TerminalView` subclass, `onReply`), `TerminalPaneController` (`show(hostID:)`, `show(placeholder:)`, `forget(_:)`, `detachAll()`, `focus()`, `currentView`, `clearScrollback()`, `configure: (HostTerminalView) -> Void`, `reconfigureAll()`)
  - `MainWindowController(store:host:model:actions:)` with `present()`, `pane`, and `@objc` actions `newSessionAction(_:)`, `newShellAction(_:)`, `endSessionAction(_:)`, `nextSession(_:)`, `previousSession(_:)`, `nextNeedingYou(_:)`, `selectSessionByTag(_:)`, `toggleInspectorAction(_:)`, `biggerFont(_:)`, `smallerFont(_:)`, `actualSizeFont(_:)`, `clearScrollbackAction(_:)`; `var onFontSize: (Int) -> Void` (+1, −1, 0 = reset)
  - `MainMenu.build() -> NSMenu`
  - `AppDelegate.showMainWindow(select:)`, `AppDelegate.startSession(_ preset: LaunchPreset, in folder: String)`
  - `AppStatus.windowNotification`; CLI `VibeSwitcher --window`

- [ ] **Step 1: `WindowModel.swift`**

```swift
import Combine
import Foundation
import VibeCore

/// The main window's list and selection.
final class WindowModel: ObservableObject {
    @Published private(set) var sections: [WindowSection] = []
    @Published var selectedID: String? {
        didSet { if selectedID != oldValue { UserDefaults.standard.set(selectedID, forKey: Self.selectionKey) } }
    }
    /// The agent's own session id last seen in each window session, so it can be resumed once it ends.
    private(set) var agentSessions: [UUID: (agent: Agent, sessionID: String)] = [:]
    private static let selectionKey = "windowSelection"

    init() {
        selectedID = UserDefaults.standard.string(forKey: Self.selectionKey)
    }

    var rows: [WindowRow] { sections.flatMap(\.rows) }
    var selectedRow: WindowRow? { rows.first { $0.id == selectedID } }

    func update(sessions: [Session], hosted: [HostSession]) {
        for session in sessions {
            if let host = session.hostID, let id = session.agentSessionID { agentSessions[host] = (session.agent, id) }
        }
        let known = Set(hosted.map(\.id))
        agentSessions = agentSessions.filter { known.contains($0.key) }
        let fresh = WindowRows.sections(sessions: sessions, hosted: hosted) { SessionNaming.name(forProjectRoot: $0) }
        if fresh != sections { sections = fresh }
        // Keep the selection while its row exists (or before anything has loaded).
        guard !rows.isEmpty, !rows.contains(where: { $0.id == selectedID }) else { return }
        selectedID = rows.first?.id
    }

    func select(hostID: UUID) { selectedID = "host:\(hostID)" }

    func select(tty: String) {
        if let row = rows.first(where: { $0.session?.tty == tty }) { selectedID = row.id }
    }

    func select(index: Int) {
        if rows.indices.contains(index) { selectedID = rows[index].id }
    }

    func move(by delta: Int) {
        let rows = self.rows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : 0)
        selectedID = rows[((current + delta) % rows.count + rows.count) % rows.count].id
    }

    /// The next row after the selected one (wrapping) whose agent is waiting on you.
    func selectNextNeedingYou() {
        let rows = self.rows
        guard !rows.isEmpty else { return }
        let start = rows.firstIndex { $0.id == selectedID } ?? -1
        for step in 1...rows.count {
            let row = rows[(start + step) % rows.count]
            if row.session?.status == .needsInput, row.session?.isPaused == false {
                selectedID = row.id
                return
            }
        }
    }
}

extension WindowRow {
    var session: Session? {
        if case .agent(let session) = content { return session }
        return nil
    }

    var hosted: HostSession? {
        if case .hosted(let session) = content { return session }
        return nil
    }

    var cwd: String? { session?.cwd ?? hosted?.cwd }
}

/// What the window asks the app to do.
struct WindowActions {
    var newSession: (_ preset: LaunchPreset?, _ folder: String?) -> Void
    var endSession: (WindowRow) -> Void
    var resume: (WindowRow) -> Void
    var remove: (WindowRow) -> Void
    var rename: (Session) -> Void
    var pause: (Session, PauseStore.Duration) -> Void
    var resumePaused: (Session) -> Void
    var openInTerminal: (Session) -> Void
    var presets: (_ folder: String?) -> [LaunchPreset]
    var isLive: (WindowRow) -> Bool
    var canResume: (WindowRow) -> Bool
}
```

- [ ] **Step 2: `TerminalPane.swift`**

```swift
import AppKit
import SwiftTerm
import SwiftUI
import VibeCore

/// SwiftTerm's view, telling what you type apart from its automatic answers to terminal queries: only the
/// primary view's answers reach the program (see the session host's "one answer per query" rule).
final class HostTerminalView: TerminalView {
    var onReply: ((Data) -> Void)?

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        onReply?(Data(data))
    }
}

/// The middle pane: the selected window session's live terminal, or a placeholder. Views of the last few
/// sessions stay attached, so switching back is instant.
final class TerminalPaneController: NSViewController, TerminalViewDelegate {
    static let keepAttached = 8

    private let host: HostClient
    private var views: [UUID: HostTerminalView] = [:]
    private var recent: [UUID] = []
    private var placeholder: NSView?
    private(set) var current: UUID?
    /// Applied to each view when it's created and by `reconfigureAll` (fonts, colors, cursor; Settings).
    var configure: (HostTerminalView) -> Void = { _ in }
    /// Scrollback for new views.
    var scrollbackLines = 10_000
    /// Called for a bell in the session on screen.
    var onBell: (HostTerminalView) -> Void = { _ in NSSound.beep() }

    init(host: HostClient) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = NSView()
    }

    var currentView: HostTerminalView? { current.flatMap { views[$0] } }

    func show(hostID: UUID) {
        placeholder?.removeFromSuperview()
        placeholder = nil
        views.values.forEach { $0.isHidden = true }
        let terminal = views[hostID] ?? makeView(for: hostID)
        terminal.isHidden = false
        current = hostID
        recent.removeAll { $0 == hostID }
        recent.insert(hostID, at: 0)
        for evicted in recent.dropFirst(Self.keepAttached) { forget(evicted) }
        focus()
    }

    func show(placeholder content: AnyView) {
        views.values.forEach { $0.isHidden = true }
        current = nil
        placeholder?.removeFromSuperview()
        let hosting = NSHostingView(rootView: content)
        pin(hosting)
        placeholder = hosting
    }

    /// Stops showing a session (evicted, removed or the window closed); the host keeps it running.
    func forget(_ id: UUID) {
        views.removeValue(forKey: id)?.removeFromSuperview()
        recent.removeAll { $0 == id }
        host.detach(id)
        if current == id { current = nil }
    }

    func detachAll() {
        Array(views.keys).forEach(forget)
    }

    var attachedIDs: [UUID] { Array(views.keys) }

    func reconfigureAll() {
        views.values.forEach(configure)
    }

    func focus() {
        guard let terminal = currentView else { return }
        view.window?.makeFirstResponder(terminal)
    }

    func clearScrollback() {
        currentView?.feed(text: "\u{1b}[3J")
    }

    private func makeView(for id: UUID) -> HostTerminalView {
        let terminal = HostTerminalView(frame: view.bounds, font: nil, options: TerminalOptions(scrollback: scrollbackLines))
        terminal.terminalDelegate = self
        terminal.onReply = { [weak self] data in self?.host.send(id, bytes: data, reply: true) }
        configure(terminal)
        pin(terminal)
        views[id] = terminal
        let size = terminal.getTerminal()
        host.attach(id, cols: size.cols, rows: size.rows, sink: .init(
            output: { [weak terminal] data in terminal?.feed(byteArray: [UInt8](data)[...]) },
            attached: {},
            // The host dropped our stream (we fell behind): start clean; a fresh replay follows.
            resync: { [weak terminal] in terminal?.feed(text: "\u{1b}c") }))
        return terminal
    }

    private func pin(_ subview: NSView) {
        subview.frame = view.bounds
        subview.autoresizingMask = [.width, .height]
        view.addSubview(subview)
    }

    private func id(of source: TerminalView) -> UUID? {
        views.first { $0.value === source }?.key
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let id = id(of: source) else { return }
        host.send(id, bytes: Data(data), reply: false)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let id = id(of: source) else { return }
        host.resize(id, cols: newCols, rows: newRows)
    }

    func bell(source: TerminalView) {
        guard let terminal = source as? HostTerminalView, terminal === currentView else { return }
        onBell(terminal)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Programs don't get to read your clipboard.
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Shown for a session that runs in Terminal.app: its current screen and a way to go there.
struct TerminalAppPlaceholder: View {
    let session: Session
    let open: () -> Void
    @State private var screen: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("This session runs in Terminal.").font(.headline)
                Spacer()
                Button("Open in Terminal", action: open).keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(screen ?? "Reading its screen…")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .task(id: session.identity) {
            let tty = session.tty
            let text = await Task.detached { TerminalBridge.screens(for: [tty])[tty] }.value
            screen = text ?? "Couldn't read its Terminal tab."
        }
    }
}

/// Nothing selected.
struct EmptySessionView: View {
    let newSession: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("No session selected").font(.title3).foregroundStyle(.secondary)
            Button("New Session", action: newSession)
            Text("⌘N").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 3: `SessionListView.swift`**

```swift
import SwiftUI
import VibeCore

/// The left pane: sessions grouped by project.
struct SessionListView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var host: HostClient
    let actions: WindowActions

    var body: some View {
        List(selection: $model.selectedID) {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        WindowRowView(row: row, info: row.hostID.flatMap { id in host.sessions.first { $0.id == id } })
                            .tag(row.id as String?)
                            .contextMenu { RowMenu(row: row, actions: actions) }
                    }
                } header: {
                    HStack {
                        Text(section.project)
                        Spacer()
                        NewSessionMenu(folder: section.rows.first?.cwd, actions: actions)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.sections.isEmpty {
                VStack(spacing: 8) {
                    Text("No sessions").foregroundStyle(.secondary)
                    NewSessionMenu(folder: nil, actions: actions, title: "New Session")
                }
            }
        }
    }
}

struct WindowRowView: View {
    let row: WindowRow
    /// The session host's record, for window sessions.
    let info: HostSession?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if let agent = row.session?.agent ?? info?.agent.flatMap(Agent.init(rawValue:)) { AgentBadge(agent: agent) }
                    if row.session?.inTerminalApp == true {
                        Text("Terminal").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).background(.quaternary, in: Capsule())
                    }
                }
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(isEnded || row.session?.isPaused == true ? 0.55 : 1)
    }

    private var isEnded: Bool { info?.isLive == false }

    private var title: String {
        if let session = row.session { return session.customName ?? session.task ?? session.displayName }
        if let info, !info.title.isEmpty { return info.title }
        return info?.label ?? "Session"
    }

    private var subtitle: String? {
        if let exit = info?.exit {
            return "ended \(Durations.short(Date().timeIntervalSince(exit.at))) ago · exit \(exit.status)"
        }
        if let session = row.session {
            if let activity = session.activity, let since = session.activitySince {
                return "⚙ \(activity) · \(Durations.short(Date().timeIntervalSince(since)))"
            }
            return session.detail ?? session.status.label
        }
        if info?.agent != nil { return "Starting…" }
        return info.map { SessionNaming.name(forProjectRoot: $0.cwd) }.map { "Shell · \($0)" }
    }

    private var dotColor: Color {
        if isEnded { return .gray.opacity(0.5) }
        if let session = row.session { return session.isPaused ? Color(nsColor: Session.pausedNSColor) : session.status.color }
        return info?.agent != nil ? .orange.opacity(0.6) : .secondary
    }
}

struct RowMenu: View {
    let row: WindowRow
    let actions: WindowActions

    var body: some View {
        if let session = row.session {
            Button("Rename…") { actions.rename(session) }
            if session.isPaused {
                Button("Resume Notifications") { actions.resumePaused(session) }
            } else {
                Menu("Pause") {
                    Button("Until I Resume It") { actions.pause(session, .indefinitely) }
                    Button("For 1 Hour") { actions.pause(session, .hours(1)) }
                    Button("Until Tomorrow Morning") { actions.pause(session, .untilTomorrowMorning) }
                    Button("For 1 Week") { actions.pause(session, .hours(24 * 7)) }
                }
            }
            if session.inTerminalApp { Button("Open in Terminal") { actions.openInTerminal(session) } }
        }
        if row.hostID != nil {
            Divider()
            if actions.isLive(row) {
                Button("End Session…") { actions.endSession(row) }
            } else {
                if actions.canResume(row) { Button("Resume") { actions.resume(row) } }
                Button("Remove") { actions.remove(row) }
            }
        }
        if let cwd = row.cwd {
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }
        }
    }
}

/// ⊕: the folder's presets (its default first).
struct NewSessionMenu: View {
    let folder: String?
    let actions: WindowActions
    var title: String?

    var body: some View {
        Menu {
            ForEach(actions.presets(folder)) { preset in
                Button(preset.name) { actions.newSession(preset, folder) }
            }
        } label: {
            if let title { Text(title) } else { Image(systemName: "plus") }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New session in this project")
    }
}
```

- [ ] **Step 4: `SessionHeaderView.swift` and `InspectorView.swift`**

```swift
import SwiftUI
import VibeCore

/// The bar above the terminal: what's selected, its state, and End / Resume / Remove.
struct SessionHeaderView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var host: HostClient
    let actions: WindowActions

    var body: some View {
        HStack(spacing: 10) {
            if let row = model.selectedRow {
                let info = row.hostID.flatMap { id in host.sessions.first { $0.id == id } }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.session?.displayName ?? info?.label ?? "Session").font(.headline).lineLimit(1)
                    Text(details(row, info)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if row.hostID != nil {
                    if actions.isLive(row) {
                        Button("End") { actions.endSession(row) }
                    } else {
                        if actions.canResume(row) { Button("Resume") { actions.resume(row) } }
                        Button("Remove") { actions.remove(row) }
                    }
                }
            } else {
                Spacer()
            }
            hostState
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private func details(_ row: WindowRow, _ info: HostSession?) -> String {
        var parts: [String] = []
        if let cwd = row.cwd { parts.append(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        if let session = row.session { parts.append(session.status.label) }
        if let exit = info?.exit { parts.append("ended · exit \(exit.status)") }
        if let info, info.isLive { parts.append("up \(Durations.short(Date().timeIntervalSince(info.startedAt)))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var hostState: some View {
        switch host.state {
        case .connecting:
            Text("Connecting…").font(.caption).foregroundStyle(.orange)
        case .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.red).lineLimit(1)
        case .outdated(let live, let compatible):
            if compatible {
                Text("Older session host until its \(live) session\(live == 1 ? "" : "s") end").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Restart Session Host (ends \(live))") { host.restartHost() }
            }
        case .connected, .notRunning:
            EmptyView()
        }
    }
}
```

```swift
import SwiftUI
import VibeCore

/// The right pane. Part 1: facts about the selected session (parts 2–3 add changes, files, transcript, previews).
struct InspectorView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var host: HostClient

    var body: some View {
        Form {
            if let row = model.selectedRow {
                let info = row.hostID.flatMap { id in host.sessions.first { $0.id == id } }
                Section("Session") {
                    if let cwd = row.cwd { LabeledContent("Folder", value: cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
                    if let session = row.session {
                        LabeledContent("Agent", value: session.agent.displayName)
                        LabeledContent("Status", value: session.status.label)
                        LabeledContent("Process", value: "\(session.pid) on \(session.tty)")
                        if let id = session.agentSessionID {
                            LabeledContent("Session ID") { Text(id).textSelection(.enabled) }
                        }
                    }
                    if let info {
                        LabeledContent("Started", value: info.startedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Command", value: info.command ?? "Shell")
                        LabeledContent("Size", value: "\(info.cols) × \(info.rows)")
                        if let exit = info.exit { LabeledContent("Exit", value: "\(exit.status)") }
                    } else if row.session?.inTerminalApp == true {
                        LabeledContent("Runs in", value: "Terminal")
                    }
                }
            } else {
                Text("Nothing selected").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 5: `MainWindowController.swift`**

```swift
import AppKit
import Combine
import SwiftUI
import VibeCore

/// The main window: sessions by project | the selected session's terminal | inspector.
/// While it's open the app is a regular app (Dock icon, ⌘-Tab); closing it goes back to menu bar only.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let model: WindowModel
    let pane: TerminalPaneController
    /// ⌘+ (1), ⌘− (−1), ⌘0 (0 = default size).
    var onFontSize: (Int) -> Void = { _ in }

    private let store: SessionStore
    private let host: HostClient
    private let actions: WindowActions
    private let split = NSSplitViewController()
    private var inspectorItem: NSSplitViewItem!
    private var shownID: String?
    private var cancellables: Set<AnyCancellable> = []

    init(store: SessionStore, host: HostClient, model: WindowModel, actions: WindowActions) {
        self.store = store
        self.host = host
        self.model = model
        self.actions = actions
        pane = TerminalPaneController(host: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "VibeSwitcher"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 420)
        super.init(window: window)
        window.delegate = self

        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(
            rootView: SessionListView(model: model, host: host, actions: actions)))
        sidebar.minimumThickness = 220
        sidebar.maximumThickness = 420
        let middle = NSViewController()
        middle.view = makeMiddle()
        let content = NSSplitViewItem(viewController: middle)
        content.minimumThickness = 420
        inspectorItem = NSSplitViewItem(inspectorWithViewController: NSHostingController(
            rootView: InspectorView(model: model, host: host)))
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 420
        inspectorItem.isCollapsed = UserDefaults.standard.object(forKey: "inspectorCollapsed") as? Bool ?? false
        split.splitViewItems = [sidebar, content, inspectorItem]
        split.splitView.autosaveName = "MainWindowSplit"
        window.contentViewController = split

        let toolbar = NSToolbar(identifier: "MainWindow")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.setFrameAutosaveName("MainWindow")

        model.$selectedID.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.showSelection() } }
            .store(in: &cancellables)
        model.$sections.receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.showSelection() } }
            .store(in: &cancellables)
        host.$sessions.receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                let known = Set(sessions.map(\.id))
                self.pane.attachedIDs.filter { !known.contains($0) }.forEach(self.pane.forget)
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeMiddle() -> NSView {
        let header = NSHostingView(rootView: SessionHeaderView(model: model, host: host, actions: actions))
        let divider = NSBox()
        divider.boxType = .separator
        let stack = NSStackView(views: [header, divider, pane.view])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        for view in [header, divider, pane.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        header.heightAnchor.constraint(equalToConstant: 40).isActive = true
        pane.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return stack
    }

    func present() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        shownID = nil
        showSelection()
    }

    private func showSelection() {
        guard window?.isVisible == true else { return }
        defer { updateViewing() }
        guard let row = model.selectedRow else {
            guard shownID != "" else { return }
            shownID = ""
            pane.show(placeholder: AnyView(EmptySessionView { [weak self] in self?.actions.newSession(nil, nil) }))
            return
        }
        if let id = row.hostID {
            if pane.current != id { pane.show(hostID: id) }
        } else if let session = row.session, shownID != row.id {
            pane.show(placeholder: AnyView(TerminalAppPlaceholder(session: session) { [weak self] in
                self?.actions.openInTerminal(session)
            }))
        }
        shownID = row.id
    }

    private func updateViewing() {
        let row = model.selectedRow
        store.windowViewingTTY = window?.isKeyWindow == true && row?.hostID != nil ? row?.session?.tty : nil
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        updateViewing()
        pane.focus()
    }

    func windowDidResignKey(_ notification: Notification) { updateViewing() }

    func windowWillClose(_ notification: Notification) {
        store.windowViewingTTY = nil
        pane.detachAll()
        shownID = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Toolbar

    private static let newItem = NSToolbarItem.Identifier("newSession")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.newItem, .inspectorTrackingSeparator,
         .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.newItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "New Session"
        item.toolTip = "New session in the selected project (⌘N)"
        item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Session")
        item.target = self
        item.action = #selector(newSessionAction(_:))
        return item
    }

    // MARK: Menu actions (reached through the responder chain)

    private var selectedFolder: String? { model.selectedRow?.cwd }

    @objc func newSessionAction(_ sender: Any?) { actions.newSession(nil, selectedFolder) }

    @objc func newShellAction(_ sender: Any?) {
        actions.newSession(actions.presets(selectedFolder).first { $0.kind == .shell }, selectedFolder)
    }

    @objc func endSessionAction(_ sender: Any?) {
        guard let row = model.selectedRow, row.hostID != nil, actions.isLive(row) else { return NSSound.beep() }
        actions.endSession(row)
    }

    @objc func nextSession(_ sender: Any?) { model.move(by: 1) }
    @objc func previousSession(_ sender: Any?) { model.move(by: -1) }
    @objc func nextNeedingYou(_ sender: Any?) { model.selectNextNeedingYou() }
    @objc func selectSessionByTag(_ sender: NSMenuItem) { model.select(index: sender.tag - 1) }

    @objc func toggleInspectorAction(_ sender: Any?) {
        inspectorItem.animator().isCollapsed.toggle()
        // The animator proxy already reports the new value.
        UserDefaults.standard.set(inspectorItem.isCollapsed, forKey: "inspectorCollapsed")
    }

    @objc func biggerFont(_ sender: Any?) { onFontSize(1) }
    @objc func smallerFont(_ sender: Any?) { onFontSize(-1) }
    @objc func actualSizeFont(_ sender: Any?) { onFontSize(0) }
    @objc func clearScrollbackAction(_ sender: Any?) { pane.clearScrollback() }
}
```

- [ ] **Step 6: `MainMenu.swift`**

```swift
import AppKit

/// The menu bar menus while the window is open (the app is a regular app then).
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                  tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            return item
        }
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))

        submenu("VibeSwitcher", [
            item("About VibeSwitcher", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", Selector(("showSettings:")), ","),
            .separator(),
            item("Hide VibeSwitcher", #selector(NSApplication.hide(_:)), "h"),
            item("Quit VibeSwitcher", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("New Session", #selector(MainWindowController.newSessionAction(_:)), "n"),
            item("New Shell", #selector(MainWindowController.newShellAction(_:)), "n", [.command, .option]),
            .separator(),
            item("End Session…", #selector(MainWindowController.endSessionAction(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
        ])
        submenu("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: Int(NSFindPanelAction.showFindPanel.rawValue)),
            item("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", tag: Int(NSFindPanelAction.next.rawValue)),
            item("Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift],
                 tag: Int(NSFindPanelAction.previous.rawValue)),
            item("Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "e",
                 tag: Int(NSFindPanelAction.setFindString.rawValue)),
        ])
        submenu("View", [
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Toggle Inspector", #selector(MainWindowController.toggleInspectorAction(_:)), "0", [.command, .option]),
            .separator(),
            item("Bigger", #selector(MainWindowController.biggerFont(_:)), "="),
            item("Smaller", #selector(MainWindowController.smallerFont(_:)), "-"),
            item("Default Size", #selector(MainWindowController.actualSizeFont(_:)), "0"),
            .separator(),
            item("Clear Scrollback", #selector(MainWindowController.clearScrollbackAction(_:)), "k"),
        ])
        submenu("Session", [
            item("Next Session", #selector(MainWindowController.nextSession(_:)), down, [.command, .option]),
            item("Previous Session", #selector(MainWindowController.previousSession(_:)), up, [.command, .option]),
            item("Next Needing You", #selector(MainWindowController.nextNeedingYou(_:)), "j"),
            .separator(),
        ] + (1...9).map { item("Session \($0)", #selector(MainWindowController.selectSessionByTag(_:)), "\($0)", tag: $0) })
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        return main
    }
}
```

- [ ] **Step 7: Wire the window into `AppDelegate`**

Add to `AppStatus` (next to `openNotification`):
```swift
    static let windowNotification = Notification.Name("dev.vibeswitcher.window")
```
In `main.swift`, after the `--toggle` block:
```swift
if arguments.contains("--window") {
    DistributedNotificationCenter.default().postNotificationName(AppStatus.windowNotification, object: nil,
                                                                 userInfo: nil, deliverImmediately: true)
    exit(0)
}
```
In `AppDelegate`, add properties:
```swift
    let windowModel = WindowModel()
    private var mainWindow: MainWindowController?
    private lazy var windowActions = WindowActions(
        newSession: { [weak self] preset, folder in self?.newSession(preset: preset, in: folder) },
        endSession: { [weak self] row in self?.endSession(row) },
        resume: { [weak self] row in self?.resumeSession(row) },
        remove: { [weak self] row in
            guard let id = row.hostID else { return }
            self?.mainWindow?.pane.forget(id)
            self?.hostClient.remove(id)
        },
        rename: { [weak self] in self?.rename($0) },
        pause: { [weak self] in self?.store.pause($0, for: $1) },
        resumePaused: { [weak self] in self?.store.resume($0) },
        openInTerminal: { [weak self] in self?.open($0, source: "window") },
        presets: { [weak self] folder in self?.presets(for: folder) ?? [] },
        isLive: { [weak self] row in
            guard let id = row.hostID else { return row.session != nil }
            return self?.hostClient.sessions.first { $0.id == id }?.isLive ?? (row.session != nil)
        },
        canResume: { [weak self] row in
            guard let self, let id = row.hostID, self.hostClient.sessions.first(where: { $0.id == id })?.isLive == false
            else { return false }
            return self.windowModel.agentSessions[id] != nil
        })
```
Add methods:
```swift
    func showMainWindow(select hostID: UUID? = nil) {
        if mainWindow == nil {
            let controller = MainWindowController(store: store, host: hostClient, model: windowModel, actions: windowActions)
            controller.onFontSize = { [weak self] step in self?.changeFontSize(step) }
            mainWindow = controller
        }
        if let hostID { windowModel.select(hostID: hostID) }
        mainWindow?.present()
    }

    /// Part 1 placeholder until Settings (Task 10) stores the size: adjusts the open terminals only.
    private func changeFontSize(_ step: Int) {
        guard let pane = mainWindow?.pane else { return }
        pane.configure = { view in
            let size = step == 0 ? 13 : max(8, min(36, view.font.pointSize + CGFloat(step)))
            view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        pane.reconfigureAll()
    }

    /// Built-ins from the old launch commands until Task 10 stores presets.
    private func presets(for folder: String?) -> [LaunchPreset] {
        LaunchPresets.builtIns(claudeCommand: preferences.claudeCommand, codexCommand: preferences.codexCommand)
            .presets(for: folder)
    }

    private func newSession(preset: LaunchPreset?, in folder: String?) {
        popover.performClose(nil)
        guard let folder = folder ?? Launcher.chooseFolder(startingAt: popoverState.recentProjects.first
            .map { ($0.path as NSString).deletingLastPathComponent }) else { return }
        guard let preset = preset ?? presets(for: folder).first else { return }
        startSession(preset, in: folder)
    }

    func startSession(_ preset: LaunchPreset, in folder: String) {
        hostClient.spawn(SpawnRequest(cwd: folder, command: LaunchPlan.command(for: preset), env: preset.env,
                                      cols: 120, rows: 36, keepShell: preset.keepShell, label: preset.name,
                                      agent: preset.agent?.rawValue)) { [weak self] result in
            switch result {
            case .success(let session):
                self?.showMainWindow(select: session.id)
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "Couldn't start the session"
                alert.informativeText = error.message
                NSApp.activate()
                alert.runModal()
            }
        }
    }

    private func endSession(_ row: WindowRow) {
        guard let id = row.hostID else { return }
        if let session = row.session, [.working, .needsInput, .background].contains(session.status) {
            let alert = NSAlert()
            alert.messageText = "End “\(session.displayName)”?"
            alert.informativeText = "\(session.agent.displayName) is \(session.status.label.lowercased()). Ending the session stops it, like closing its Terminal tab."
            alert.addButton(withTitle: "End Session")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        hostClient.kill(id)
    }

    private func resumeSession(_ row: WindowRow) {
        guard let id = row.hostID, let info = hostClient.sessions.first(where: { $0.id == id }),
              let agentSession = windowModel.agentSessions[id] else { return }
        let command = LaunchPlan.resumeCommand(base: info.command, agent: agentSession.agent, sessionID: agentSession.sessionID)
        hostClient.spawn(SpawnRequest(cwd: info.cwd, command: command, env: [:], cols: info.cols, rows: info.rows,
                                      keepShell: false, label: info.label, agent: agentSession.agent.rawValue)) { [weak self] result in
            guard case .success(let session) = result else { return }
            self?.mainWindow?.pane.forget(id)
            self?.hostClient.remove(id)
            self?.showMainWindow(select: session.id)
        }
    }
```
In `applicationDidFinishLaunching`, after the `hostClient.$sessions` sink from Task 8, add:
```swift
        store.$sessions.combineLatest(hostClient.$sessions)
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions, hosted in self?.windowModel.update(sessions: sessions, hosted: hosted) }
            .store(in: &cancellables)
        NSApp.mainMenu = MainMenu.build()
        DistributedNotificationCenter.default().addObserver(forName: AppStatus.windowNotification, object: nil,
                                                            queue: .main) { [weak self] _ in self?.showMainWindow() }
```
At the top of `open(_ session:source:)`, before `popover.performClose(nil)`'s existing body continues into Terminal, insert:
```swift
        if let hostID = session.hostID {
            popover.performClose(nil)
            store.acknowledge(session)
            notifier?.clear(tty: session.tty)
            if preferences.sidebarMode { sidebar.dismissAfterSelection() }
            showMainWindow(select: hostID)
            return
        }
```
In `statusItemClicked`, as the first statement:
```swift
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true { return showMainWindow() }
```
Change `applicationShouldHandleReopen` to:
```swift
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = mainWindow?.window, window.isVisible || window.isMiniaturized {
            mainWindow?.present()
        } else if !popover.isShown {
            togglePopover()
        }
        return false
    }
```
Add `@objc func showSettings(_ sender: Any?) {}` to `AppDelegate` (filled in Task 10) so the Settings… menu item resolves.

In `PopoverView`, add a stored property after `isSidebar`: `var onOpenWindow: () -> Void = {}`, and next to `newSessionMenu` in the header `HStack` add:
```swift
            Button { onOpenWindow() } label: { Image(systemName: "macwindow") }
                .buttonStyle(.borderless)
                .help("Open the VibeSwitcher window (⌘-click the menu bar icon)")
```
Pass `onOpenWindow: { [weak self] in self?.popover.performClose(nil); self?.showMainWindow() }` as the last argument where `AppDelegate` creates `PopoverView` for the popover, and `onOpenWindow: { [weak self] in self?.showMainWindow() }` for the sidebar copy (after `isSidebar: true`).

- [ ] **Step 8: Build** — `swift build 2>&1 | grep -E "error:|Build complete"` → `Build complete!`. Fix any SwiftTerm signature mismatch by matching the declarations in `.build/checkouts/SwiftTerm/Sources/SwiftTerm/Apple/TerminalViewDelegate.swift`.

- [ ] **Step 9: Install and smoke-test with a scratch shell (never a real session)**

```bash
./scripts/build-app.sh --install 2>&1 | tail -1
mkdir -p /tmp/vs-scratch
B=/Applications/VibeSwitcher.app/Contents/MacOS/VibeSwitcher
$B --window; sleep 2
grep '"host"' ~/.vibeswitcher/app-status.json || true      # "notRunning" until a session is started
```
Start a scratch Shell session through the window's ⊕ menu is manual; for an automated check use Task 11's `--new` (re-run this smoke test there). Here verify the window opens: `osascript -e 'tell application "System Events" to get name of windows of process "VibeSwitcher"'` may lack Accessibility; instead list windows with the CGWindowList helper:
```bash
swift - <<'EOF'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == "VibeSwitcher" { print(w[kCGWindowName as String] ?? "", w[kCGWindowBounds as String]!) }
EOF
```
Expected: a window around 1280×800 (title may print empty without Screen Recording permission). Take a screenshot to look at it: `screencapture -x -o -l <window number> /tmp/vs-window.png` (window number from `kCGWindowNumber`), then view the PNG.

- [ ] **Step 10: Commit**

```bash
git add Sources/VibeSwitcher/MainWindow Sources/VibeSwitcher/AppDelegate.swift Sources/VibeSwitcher/AppStatus.swift Sources/VibeSwitcher/main.swift Sources/VibeSwitcher/PopoverView.swift
git commit -m "Main window: sessions by project, the selected window session's live terminal (SwiftTerm, query replies kept apart from typing), inspector, menus and shortcuts; opened from the popover, ⌘-click on the icon, --window, or any open of a window session

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Settings window and terminal appearance

**Files:**
- Create: `Sources/VibeCore/TerminalAppearance.swift`
- Create: `Sources/VibeSwitcher/SettingsWindow.swift`
- Modify: `Sources/VibeSwitcher/Preferences.swift`, `Sources/VibeSwitcher/AppDelegate.swift`, `Sources/VibeSwitcher/MainWindow/TerminalPane.swift`, `Sources/VibeSwitcher/PopoverView.swift`
- Test: `Tests/VibeCoreTests/TerminalAppearanceTests.swift`

**Interfaces:**
- Produces: `TerminalAppearance` (`fontName` — `""` = system monospaced, `fontSize`, `theme: Theme {system, light, dark, solarizedLight, solarizedDark, custom}`, `custom: Palette`, `cursorShape: CursorShape {block, underline, bar}`, `cursorBlink`, `scrollbackLines`, `optionAsMeta`, `bell: Bell {none, visual, sound}`, `palette(darkMode:) -> Palette`, `withFontSize(_:) -> TerminalAppearance`, `static fontSizeRange`, `static defaultFontSize`); `Palette` (`foreground`, `background`, `cursor`, `selection`, `ansi: [String]` (16), statics `.light`, `.dark`, `.solarizedLight`, `.solarizedDark`); `RGB(hex:)` (`red`, `green`, `blue` in 0…1); `Preferences.presets: LaunchPresets`, `Preferences.appearance: TerminalAppearance`, `Preferences.openWindowAtLaunch: Bool`; `SettingsWindowController.show(tab:)` with `SettingsTab {general, launch, terminal}`; `HostTerminalView.apply(_:darkMode:)`; `AppDelegate.showSettings(_:)`, `AppDelegate.showSettings(tab:)`.

- [ ] **Step 1: Write the failing tests** — `Tests/VibeCoreTests/TerminalAppearanceTests.swift`

```swift
import Foundation
import Testing
@testable import VibeCore

struct TerminalAppearanceTests {
    @Test func defaults() {
        let appearance = TerminalAppearance()
        #expect(appearance.fontName == "")
        #expect(appearance.fontSize == TerminalAppearance.defaultFontSize)
        #expect(appearance.theme == .system)
        #expect(appearance.scrollbackLines == 10_000)
        #expect(appearance.optionAsMeta && appearance.cursorBlink)
        #expect(appearance.bell == .visual)
    }

    @Test func olderSettingsDecodeWithDefaultsForMissingKeys() throws {
        let partial = try JSONDecoder().decode(TerminalAppearance.self, from: Data(#"{"fontSize": 15, "theme": "dark"}"#.utf8))
        #expect(partial.fontSize == 15 && partial.theme == .dark && partial.scrollbackLines == 10_000)
        #expect(try JSONDecoder().decode(TerminalAppearance.self, from: Data("{}".utf8)) == TerminalAppearance())
        let unknownTheme = try JSONDecoder().decode(TerminalAppearance.self, from: Data(#"{"theme": "neon"}"#.utf8))
        #expect(unknownTheme.theme == .system)
    }

    @Test func roundTrips() throws {
        var appearance = TerminalAppearance()
        appearance.fontName = "Menlo"
        appearance.theme = .custom
        appearance.custom.background = "#101010"
        appearance.bell = .sound
        let data = try JSONEncoder().encode(appearance)
        #expect(try JSONDecoder().decode(TerminalAppearance.self, from: data) == appearance)
    }

    @Test func palettesAreComplete() {
        for palette in [Palette.light, .dark, .solarizedLight, .solarizedDark] {
            #expect(palette.ansi.count == 16)
            for hex in palette.ansi + [palette.foreground, palette.background, palette.cursor, palette.selection] {
                #expect(RGB(hex: hex) != nil, "\(hex)")
            }
        }
    }

    @Test func systemThemeFollowsDarkMode() {
        let appearance = TerminalAppearance()
        #expect(appearance.palette(darkMode: true) == .dark)
        #expect(appearance.palette(darkMode: false) == .light)
        var solarized = appearance
        solarized.theme = .solarizedDark
        #expect(solarized.palette(darkMode: false) == .solarizedDark)
    }

    @Test func hexParsing() {
        #expect(RGB(hex: "#ff8000") == RGB(red: 1, green: 128.0 / 255, blue: 0))
        #expect(RGB(hex: "FF8000") != nil)
        #expect(RGB(hex: "#fff") == nil)
        #expect(RGB(hex: "#gg0000") == nil)
    }

    @Test func fontSizeIsClamped() {
        let appearance = TerminalAppearance()
        #expect(appearance.withFontSize(100).fontSize == TerminalAppearance.fontSizeRange.upperBound)
        #expect(appearance.withFontSize(2).fontSize == TerminalAppearance.fontSizeRange.lowerBound)
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `swift test --filter TerminalAppearanceTests 2>&1 | tail -3` → compile errors.

- [ ] **Step 3: Implement `Sources/VibeCore/TerminalAppearance.swift`**

```swift
import Foundation

/// How the window's terminals look and behave (Settings › Terminal).
public struct TerminalAppearance: Codable, Equatable, Sendable {
    public enum Theme: String, Codable, CaseIterable, Sendable {
        case system, light, dark, solarizedLight, solarizedDark, custom

        public var label: String {
            switch self {
            case .system: return "Match System"
            case .light: return "Light"
            case .dark: return "Dark"
            case .solarizedLight: return "Solarized Light"
            case .solarizedDark: return "Solarized Dark"
            case .custom: return "Custom"
            }
        }
    }

    public enum CursorShape: String, Codable, CaseIterable, Sendable { case block, underline, bar }
    public enum Bell: String, Codable, CaseIterable, Sendable { case none, visual, sound }

    public static let defaultFontSize: Double = 13
    public static let fontSizeRange: ClosedRange<Double> = 8...36

    /// Empty: the system's monospaced font (SF Mono).
    public var fontName = ""
    public var fontSize = TerminalAppearance.defaultFontSize
    public var theme = Theme.system
    /// The colors used when `theme` is `.custom`.
    public var custom = Palette.dark
    public var cursorShape = CursorShape.block
    public var cursorBlink = true
    /// For terminals opened after the change.
    public var scrollbackLines = 10_000
    public var optionAsMeta = true
    public var bell = Bell.visual

    public init() {}

    public func palette(darkMode: Bool) -> Palette {
        switch theme {
        case .system: return darkMode ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        case .solarizedLight: return .solarizedLight
        case .solarizedDark: return .solarizedDark
        case .custom: return custom
        }
    }

    public func withFontSize(_ size: Double) -> TerminalAppearance {
        var copy = self
        copy.fontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case fontName, fontSize, theme, custom, cursorShape, cursorBlink, scrollbackLines, optionAsMeta, bell
    }

    /// Missing or unknown values keep their defaults (settings saved by another version).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        let defaults = TerminalAppearance()
        fontName = value(.fontName, defaults.fontName)
        fontSize = value(.fontSize, defaults.fontSize)
        theme = value(.theme, defaults.theme)
        custom = value(.custom, defaults.custom)
        cursorShape = value(.cursorShape, defaults.cursorShape)
        cursorBlink = value(.cursorBlink, defaults.cursorBlink)
        scrollbackLines = value(.scrollbackLines, defaults.scrollbackLines)
        optionAsMeta = value(.optionAsMeta, defaults.optionAsMeta)
        bell = value(.bell, defaults.bell)
    }
}

/// Terminal colors as "#rrggbb": text, background, cursor, selection and the 16 ANSI colors.
public struct Palette: Codable, Equatable, Sendable {
    public var foreground: String
    public var background: String
    public var cursor: String
    public var selection: String
    public var ansi: [String]

    public init(foreground: String, background: String, cursor: String, selection: String, ansi: [String]) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi
    }

    /// Terminal.app's basic colors.
    static let standardANSI = ["#000000", "#C23621", "#25BC24", "#ADAD27", "#492EE1", "#D338D3", "#33BBC8", "#CBCCCD",
                               "#818383", "#FC391F", "#31E722", "#EAEC23", "#5833FF", "#F935F8", "#14F0F0", "#E9EBEB"]
    public static let dark = Palette(foreground: "#E5E5E5", background: "#1E1E1E", cursor: "#E5E5E5", selection: "#3A4A6B",
                                     ansi: standardANSI)
    public static let light = Palette(foreground: "#1F1F1F", background: "#FFFFFF", cursor: "#1F1F1F", selection: "#B4D5FE",
                                      ansi: standardANSI)

    // Solarized (Ethan Schoonover).
    static let solarizedANSI = ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                                "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]
    public static let solarizedDark = Palette(foreground: "#839496", background: "#002B36", cursor: "#93A1A1",
                                              selection: "#073642", ansi: solarizedANSI)
    public static let solarizedLight = Palette(foreground: "#657B83", background: "#FDF6E3", cursor: "#586E75",
                                               selection: "#EEE8D5", ansi: solarizedANSI)
}

public struct RGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "#rrggbb" or "rrggbb".
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter TerminalAppearanceTests 2>&1 | tail -3` → 7 passed.

- [ ] **Step 5: Store presets and appearance in `Preferences`**

Add properties:
```swift
    /// Launch presets, in ~/.vibeswitcher/presets.json (the first load migrates the two launch commands).
    @Published var presets: LaunchPresets {
        didSet { try? presets.save(to: VibePaths.presetsFile) }
    }
    @Published var appearance: TerminalAppearance {
        didSet { defaults.set(try? JSONEncoder().encode(appearance), forKey: "terminalAppearance") }
    }
    /// Show the window when VibeSwitcher starts.
    @Published var openWindowAtLaunch: Bool { didSet { defaults.set(openWindowAtLaunch, forKey: "openWindowAtLaunch") } }
```
At the end of `init()`:
```swift
        // Locals, not the @Published properties: those can't be read before init finishes.
        presets = LaunchPresets.load(from: VibePaths.presetsFile,
                                     claudeCommand: defaults.string(forKey: "claudeCommand") ?? "claude",
                                     codexCommand: defaults.string(forKey: "codexCommand") ?? "codex")
        appearance = defaults.data(forKey: "terminalAppearance")
            .flatMap { try? JSONDecoder().decode(TerminalAppearance.self, from: $0) } ?? TerminalAppearance()
        openWindowAtLaunch = defaults.bool(forKey: "openWindowAtLaunch")
```
Change `command(for:)` to read the presets (callers such as `--new` keep working):
```swift
    func command(for agent: Agent) -> String {
        let kind: LaunchPreset.Kind = agent == .claude ? .claude : .codex
        return presets.global.first { $0.kind == kind }.flatMap(LaunchPlan.command(for:)) ?? agent.rawValue
    }
```

- [ ] **Step 6: Apply appearance to terminal views** — add to `TerminalPane.swift`:

```swift
extension HostTerminalView {
    func apply(_ appearance: TerminalAppearance, darkMode: Bool) {
        let size = CGFloat(appearance.fontSize)
        font = (appearance.fontName.isEmpty ? nil : NSFont(name: appearance.fontName, size: size))
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let palette = appearance.palette(darkMode: darkMode)
        func color(_ hex: String) -> NSColor {
            let rgb = RGB(hex: hex) ?? RGB(red: 0.5, green: 0.5, blue: 0.5)
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
        nativeForegroundColor = color(palette.foreground)
        nativeBackgroundColor = color(palette.background)
        caretColor = color(palette.cursor)
        selectedTextBackgroundColor = color(palette.selection)
        installColors(palette.ansi.map { hex in
            let rgb = RGB(hex: hex) ?? RGB(red: 0, green: 0, blue: 0)
            return SwiftTerm.Color(red: UInt16(rgb.red * 65_535), green: UInt16(rgb.green * 65_535), blue: UInt16(rgb.blue * 65_535))
        })
        optionAsMetaKey = appearance.optionAsMeta
        let style: CursorStyle
        switch (appearance.cursorShape, appearance.cursorBlink) {
        case (.block, true): style = .blinkBlock
        case (.block, false): style = .steadyBlock
        case (.underline, true): style = .blinkUnderline
        case (.underline, false): style = .steadyUnderline
        case (.bar, true): style = .blinkBar
        case (.bar, false): style = .steadyBar
        }
        getTerminal().setCursorStyle(style)
    }

    /// A short flash over the terminal (Settings › Terminal › Bell: Visual).
    func flash() {
        let overlay = NSView(frame: bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            overlay.animator().alphaValue = 0
        }, completionHandler: { overlay.removeFromSuperview() })
    }
}
```

- [ ] **Step 7: `Sources/VibeSwitcher/SettingsWindow.swift`**

```swift
import AppKit
import SwiftUI
import VibeCore

enum SettingsTab: String { case general, launch, terminal }

final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// VibeSwitcher › Settings…: General, Launch presets, Terminal.
final class SettingsWindowController: NSWindowController {
    private let selection = SettingsSelection()

    init(preferences: Preferences, recentProjects: @escaping () -> [String]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, selection: selection,
                                                                  recentProjects: recentProjects))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(tab: SettingsTab) {
        selection.tab = tab
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var selection: SettingsSelection
    let recentProjects: () -> [String]

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettings(preferences: preferences)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            LaunchSettings(preferences: preferences, recentProjects: recentProjects())
                .tabItem { Label("Launch", systemImage: "play.rectangle") }.tag(SettingsTab.launch)
            TerminalSettings(preferences: preferences)
                .tabItem { Label("Terminal", systemImage: "terminal") }.tag(SettingsTab.terminal)
        }
        .padding(20)
        .frame(width: 640, height: 480)
    }
}

struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Toggle("Open the window when VibeSwitcher starts", isOn: $preferences.openWindowAtLaunch)
            Toggle("Launch at login", isOn: Binding(get: { preferences.launchAtLogin },
                                                    set: { preferences.setLaunchAtLogin($0) }))
            Text("Window sessions keep running when VibeSwitcher quits or updates. Ended sessions stay listed for a day.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// Presets: global ones, and ones for a project (with that project's default).
struct LaunchSettings: View {
    @ObservedObject var preferences: Preferences
    let recentProjects: [String]
    /// nil: global presets.
    @State private var project: String?
    @State private var selected: UUID?

    private var list: [LaunchPreset] {
        project.map { preferences.presets.byProject[$0] ?? [] } ?? preferences.presets.global
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Presets for", selection: $project) {
                    Text("All projects").tag(String?.none)
                    ForEach(recentProjects, id: \.self) { path in
                        Text(SessionNaming.name(forProjectRoot: path)).tag(Optional(path))
                    }
                }
                List(selection: $selected) {
                    ForEach(list) { preset in
                        HStack {
                            Text(preset.name)
                            Spacer()
                            if let project, preferences.presets.defaults[project] == preset.id {
                                Text("Default").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(Optional(preset.id))
                    }
                }
                .frame(width: 220)
                HStack {
                    Button { add() } label: { Image(systemName: "plus") }
                    Button { removeSelected() } label: { Image(systemName: "minus") }.disabled(selected == nil || list.count <= 1 && project == nil)
                    Spacer()
                    if let project {
                        Menu("Default") {
                            ForEach(preferences.presets.presets(for: project)) { preset in
                                Button(preset.name) { preferences.presets.defaults[project] = preset.id }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            if let id = selected, let binding = binding(for: id) {
                PresetEditor(preset: binding)
            } else {
                Text("Select a preset").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func binding(for id: UUID) -> Binding<LaunchPreset>? {
        guard list.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { preferences.presets.preset(id: id) ?? list[0] },
            set: { updated in update { presets in
                if let index = presets.firstIndex(where: { $0.id == id }) { presets[index] = updated }
            } })
    }

    private func update(_ change: (inout [LaunchPreset]) -> Void) {
        if let project {
            var presets = preferences.presets.byProject[project] ?? []
            change(&presets)
            preferences.presets.byProject[project] = presets.isEmpty ? nil : presets
        } else {
            change(&preferences.presets.global)
        }
    }

    private func add() {
        let preset = LaunchPreset(name: "New Preset", kind: .claude, command: "claude")
        update { $0.append(preset) }
        selected = preset.id
    }

    private func removeSelected() {
        guard let id = selected else { return }
        update { $0.removeAll { $0.id == id } }
        preferences.presets.defaults = preferences.presets.defaults.filter { $0.value != id }
        selected = nil
    }
}

struct PresetEditor: View {
    @Binding var preset: LaunchPreset
    @State private var envText = ""

    var body: some View {
        Form {
            TextField("Name", text: $preset.name)
            Picker("Starts", selection: $preset.kind) {
                ForEach(LaunchPreset.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if preset.kind != .shell {
                TextField("Command", text: $preset.command, prompt: Text(preset.kind.rawValue))
                    .font(.system(.body, design: .monospaced))
                Toggle("Keep a shell open after it exits", isOn: $preset.keepShell)
            }
            Picker("Runs in", selection: $preset.place) {
                Text("VibeSwitcher window").tag(LaunchPreset.Place.window)
                Text("Terminal").tag(LaunchPreset.Place.terminal)
            }
            VStack(alignment: .leading) {
                Text("Environment (NAME=value, one per line)")
                TextEditor(text: $envText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 70)
                    .onChange(of: envText) { _, text in preset.env = Self.parse(text) }
            }
        }
        .formStyle(.grouped)
        .onAppear { envText = Self.format(preset.env) }
        .onChange(of: preset.id) { _, _ in envText = Self.format(preset.env) }
    }

    static func format(_ env: [String: String]) -> String {
        env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    static func parse(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            if LaunchPlan.validEnvName(name) { env[name] = String(line[line.index(after: equals)...]) }
        }
        return env
    }
}

struct TerminalSettings: View {
    @ObservedObject var preferences: Preferences

    private var fonts: [String] {
        let fixed = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        return Array(Set(fixed.compactMap { NSFont(name: $0, size: 12)?.familyName })).sorted()
    }

    var body: some View {
        Form {
            Section("Text") {
                Picker("Font", selection: $preferences.appearance.fontName) {
                    Text("System Monospaced").tag("")
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Size: \(Int(preferences.appearance.fontSize)) pt",
                        value: $preferences.appearance.fontSize, in: TerminalAppearance.fontSizeRange, step: 1)
            }
            Section("Colors") {
                Picker("Theme", selection: $preferences.appearance.theme) {
                    ForEach(TerminalAppearance.Theme.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if preferences.appearance.theme == .custom {
                    ColorRow(title: "Text", hex: $preferences.appearance.custom.foreground)
                    ColorRow(title: "Background", hex: $preferences.appearance.custom.background)
                    ColorRow(title: "Cursor", hex: $preferences.appearance.custom.cursor)
                    ColorRow(title: "Selection", hex: $preferences.appearance.custom.selection)
                    DisclosureGroup("ANSI colors") {
                        ForEach(0..<16, id: \.self) { index in
                            ColorRow(title: "Color \(index)", hex: $preferences.appearance.custom.ansi[index])
                        }
                    }
                }
            }
            Section("Behavior") {
                Picker("Cursor", selection: $preferences.appearance.cursorShape) {
                    Text("Block").tag(TerminalAppearance.CursorShape.block)
                    Text("Underline").tag(TerminalAppearance.CursorShape.underline)
                    Text("Bar").tag(TerminalAppearance.CursorShape.bar)
                }
                Toggle("Blinking cursor", isOn: $preferences.appearance.cursorBlink)
                Stepper("Scrollback: \(preferences.appearance.scrollbackLines) lines",
                        value: $preferences.appearance.scrollbackLines, in: 1_000...100_000, step: 1_000)
                Toggle("Use Option as Meta key", isOn: $preferences.appearance.optionAsMeta)
                Picker("Bell", selection: $preferences.appearance.bell) {
                    Text("None").tag(TerminalAppearance.Bell.none)
                    Text("Flash").tag(TerminalAppearance.Bell.visual)
                    Text("Sound").tag(TerminalAppearance.Bell.sound)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ColorRow: View {
    let title: String
    @Binding var hex: String

    var body: some View {
        ColorPicker(title, selection: Binding(
            get: {
                let rgb = RGB(hex: hex) ?? RGB(red: 0, green: 0, blue: 0)
                return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
            },
            set: { color in
                guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                hex = RGB(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent).hex
            }), supportsOpacity: false)
    }
}
```

- [ ] **Step 8: Wire Settings and appearance in `AppDelegate`**

Add `private var settingsWindow: SettingsWindowController?` and replace the empty `showSettings(_:)` with:
```swift
    @objc func showSettings(_ sender: Any?) { showSettings(tab: .general) }

    func showSettings(tab: SettingsTab) {
        popover.performClose(nil)
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(preferences: preferences) { [weak self] in
                self?.popoverState.recentProjects.map(\.path) ?? []
            }
        }
        loadRecentProjects()
        settingsWindow?.show(tab: tab)
    }
```
Replace `presets(for:)` with `preferences.presets.presets(for: folder)`; replace `changeFontSize` with:
```swift
    private func changeFontSize(_ step: Int) {
        let current = preferences.appearance
        preferences.appearance = step == 0 ? current.withFontSize(TerminalAppearance.defaultFontSize)
                                           : current.withFontSize(current.fontSize + Double(step))
    }
```
In `showMainWindow`, right after creating the controller, configure the pane:
```swift
            controller.pane.configure = { [weak self] view in
                guard let self else { return }
                let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                view.apply(self.preferences.appearance, darkMode: dark)
            }
            controller.pane.scrollbackLines = preferences.appearance.scrollbackLines
            controller.pane.onBell = { [weak self] view in
                switch self?.preferences.appearance.bell {
                case .sound: NSSound.beep()
                case .visual: view.flash()
                default: break
                }
            }
```
In `applicationDidFinishLaunching` add:
```swift
        preferences.$appearance
            .receive(on: RunLoop.main)
            .sink { [weak self] appearance in
                DispatchQueue.main.async {
                    self?.mainWindow?.pane.scrollbackLines = appearance.scrollbackLines
                    self?.mainWindow?.pane.reconfigureAll()
                }
            }
            .store(in: &cancellables)
        NSApp.publisher(for: \.effectiveAppearance)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.mainWindow?.pane.reconfigureAll() } }
            .store(in: &cancellables)
        if preferences.openWindowAtLaunch { showMainWindow() }
```
In `PopoverView`, add a stored property after `onOpenWindow`: `var onSettings: () -> Void = {}`; in the gear (settings) menu next to "Launch at login" add `Button("Settings…", action: onSettings)`; pass `onSettings: { [weak self] in self?.showSettings(tab: .general) }` at both `PopoverView` creation sites (last argument).

- [ ] **Step 9: Build and test** — `swift build 2>&1 | grep -E "error:|Build complete" && swift test 2>&1 | tail -2` → build complete; all tests pass.

- [ ] **Step 10: Commit**

```bash
git add Sources/VibeCore/TerminalAppearance.swift Tests/VibeCoreTests/TerminalAppearanceTests.swift Sources/VibeSwitcher/SettingsWindow.swift Sources/VibeSwitcher/Preferences.swift Sources/VibeSwitcher/AppDelegate.swift Sources/VibeSwitcher/MainWindow/TerminalPane.swift Sources/VibeSwitcher/PopoverView.swift
git commit -m "Settings window: General, Launch presets (global and per project, with defaults and environment), Terminal (font, size, themes incl. Solarized and custom colors, cursor, scrollback, Option as Meta, bell); applied live to open terminals

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Starting sessions from presets everywhere

**Files:**
- Modify: `Sources/VibeSwitcher/AppDelegate.swift`, `Sources/VibeSwitcher/PopoverView.swift`, `Sources/VibeSwitcher/main.swift`, `Sources/VibeSwitcher/Launcher.swift`, `Sources/VibeSwitcher/AppStatus.swift`

**Interfaces:**
- Consumes: `Preferences.presets`, `LaunchPlan.terminalLine`, `AppDelegate.startSession`.
- Produces: `PopoverView.onNewSession: (LaunchPreset, String?) -> Void`, `PopoverView.presetsFor: (String?) -> [LaunchPreset]`; `Launcher.launch(line:)`; `AppStatus.newSessionNotification`; CLI `VibeSwitcher --new <preset name or claude|codex|shell> [folder] [--terminal]`.

- [ ] **Step 1: `Launcher.launch(line:)`** — in `Launcher.swift`, split the existing `launch(command:in:)`:

```swift
    /// Opens a new Terminal window in `directory` running `command`, and brings it to the front.
    static func launch(command: String, in directory: String) {
        launch(line: RecentProjects.shellCommand(cd: directory, run: command))
    }

    /// Opens a new Terminal window running a full shell line (see `LaunchPlan.terminalLine`).
    static func launch(line: String) {
        let escaped = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = TerminalBridge.runAppleScript("tell application \"Terminal\" to do script \"\(escaped)\"")
            if result.status != 0 { NSLog("VibeSwitcher: launch failed: \(result.error)") }
            if let terminal = TerminalBridge.app { _ = HostApp.bringToFrontAndWait(terminal) }
        }
    }
```

- [ ] **Step 2: Route presets by place in `AppDelegate`** — replace `startSession(_:in:)` with:

```swift
    func startSession(_ preset: LaunchPreset, in folder: String) {
        guard preset.place == .window else { return Launcher.launch(line: LaunchPlan.terminalLine(for: preset, in: folder)) }
        hostClient.spawn(SpawnRequest(cwd: folder, command: LaunchPlan.command(for: preset), env: preset.env,
                                      cols: 120, rows: 36, keepShell: preset.keepShell, label: preset.name,
                                      agent: preset.agent?.rawValue)) { [weak self] result in
            switch result {
            case .success(let session):
                self?.showMainWindow(select: session.id)
            case .failure(let error):
                // The window can't take it: start it in Terminal as before, and say why.
                Launcher.launch(line: LaunchPlan.terminalLine(for: preset, in: folder))
                self?.notifier?.postInfo(title: "Started in Terminal instead",
                                         body: "The VibeSwitcher window couldn't start it: \(error.message)")
            }
        }
    }
```
Delete `editLaunchCommands()` and the old `newSession(agent:in:)`.

- [ ] **Step 3: Popover menu uses presets** — in `PopoverView`:

Change `var onNewSession: (Agent, String?) -> Void = { _, _ in }` to
```swift
    var onNewSession: (LaunchPreset, String?) -> Void = { _, _ in }
    /// A folder's presets, its default first (nil: other folder).
    var presetsFor: (String?) -> [LaunchPreset] = { _ in LaunchPresets.builtIns().global }
```
and replace `newSessionMenu`'s body with:
```swift
        Menu {
            if !state.recentProjects.isEmpty {
                Section("Recent projects") {
                    ForEach(state.recentProjects, id: \.path) { project in
                        Menu(Self.menuLabel(for: project.path)) {
                            ForEach(presetsFor(project.path)) { preset in
                                Button(preset.name) { onNewSession(preset, project.path) }
                            }
                        }
                    }
                }
            }
            Menu("Other Folder…") {
                ForEach(presetsFor(nil)) { preset in
                    Button(preset.name) { onNewSession(preset, nil) }
                }
            }
            Divider()
            Button("Launch Presets…", action: onEditCommands)
        } label: {
            Image(systemName: "plus.circle")
        }
```
(keep the existing modifiers after `label:`). In `AppDelegate`, at both `PopoverView` creation sites, pass
`onNewSession: { [weak self] preset, folder in self?.newSession(preset: preset, in: folder) }`,
`onEditCommands: { [weak self] in self?.showSettings(tab: .launch) }` and add
`presetsFor: { [weak self] folder in self?.preferences.presets.presets(for: folder) ?? [] }` right after `onEditCommands:` (the sidebar copy passes the same closures instead of `sidebarView.onNewSession` / `sidebarView.onEditCommands`).

- [ ] **Step 4: `--new` goes through the running app** — in `AppStatus` add `static let newSessionNotification = Notification.Name("dev.vibeswitcher.new")`. Replace the `--new` block in `main.swift` with:

```swift
if let index = arguments.firstIndex(of: "--new"), arguments.indices.contains(index + 1) {
    // `--new <preset name | claude | codex | shell> [folder] [--terminal]`: the running app starts it like ⊕ does.
    let rest = arguments[(index + 2)...].filter { $0 != "--terminal" }
    let folder = ((rest.first ?? FileManager.default.currentDirectoryPath) as NSString).expandingTildeInPath
    DistributedNotificationCenter.default().postNotificationName(
        AppStatus.newSessionNotification, object: nil,
        userInfo: ["preset": arguments[index + 1], "folder": folder, "terminal": arguments.contains("--terminal")],
        deliverImmediately: true)
    print("asked VibeSwitcher to start \(arguments[index + 1]) in \(folder)")
    exit(0)
}
```
and in `AppDelegate.applicationDidFinishLaunching` add:
```swift
        DistributedNotificationCenter.default().addObserver(forName: AppStatus.newSessionNotification, object: nil,
                                                            queue: .main) { [weak self] note in
            guard let self, let name = note.userInfo?["preset"] as? String, let folder = note.userInfo?["folder"] as? String,
                  FileManager.default.fileExists(atPath: folder) else { return }
            let presets = self.preferences.presets.presets(for: folder)
            guard var preset = presets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                    ?? presets.first(where: { $0.kind.rawValue == name.lowercased() }) else { return }
            if note.userInfo?["terminal"] as? Bool == true { preset.place = .terminal }
            self.startSession(preset, in: folder)
        }
```
Update the README's `--new` line in Task 13.

- [ ] **Step 5: Build, install, and verify with scratch shells only**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
./scripts/build-app.sh --install 2>&1 | tail -1; sleep 2
mkdir -p /tmp/vs-scratch
B=/Applications/VibeSwitcher.app/Contents/MacOS/VibeSwitcher
$B --new shell /tmp/vs-scratch; sleep 3
grep '"host"' ~/.vibeswitcher/app-status.json             # "connected"
pgrep -fl vibeswitcher-host                                # the host is running
ps -o pid,tty,command -ax | grep -E "zsh -l -i" | grep -v grep   # the scratch shell on a ttys
```
Then quit and relaunch the app and check the shell survived:
```bash
pkill -x VibeSwitcher; sleep 1; pgrep -fl vibeswitcher-host && echo "host survived"
open /Applications/VibeSwitcher.app; sleep 3; $B --window; sleep 2
```
Screenshot the window (see Task 9 Step 9) and confirm the scratch shell is listed and its prompt is visible.

- [ ] **Step 6: Commit**

```bash
git add Sources/VibeSwitcher/AppDelegate.swift Sources/VibeSwitcher/PopoverView.swift Sources/VibeSwitcher/main.swift Sources/VibeSwitcher/Launcher.swift Sources/VibeSwitcher/AppStatus.swift
git commit -m "New sessions start from launch presets everywhere (popover, window, --new): in the window by default, in Terminal when the preset says so or the window can't start it

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Phone access for window sessions

**Files:**
- Create: `Sources/VibeCore/HostInput.swift`
- Modify: `Sources/VibeSwitcher/PhoneAccess.swift`, `Sources/VibeSwitcher/AppDelegate.swift`
- Test: `Tests/VibeCoreTests/HostInputTests.swift`

**Interfaces:**
- Consumes: `HostClient.screen`, `.history`, `.send`; `Session.hostID`/`inWindow`; `RemoteInput.sanitized`, `RemoteInput.Key`.
- Produces: `HostInput.bytes(forKey:) -> [UInt8]?`; `HostInput.writes(text:submit:key:) -> [HostInput.Write]` where `struct Write: Equatable { bytes: [UInt8]; delay: TimeInterval }`; `PhoneAccess.hostClient: HostClient?`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import VibeCore

struct HostInputTests {
    @Test func keysMapToTerminalBytes() {
        #expect(HostInput.bytes(forKey: "enter") == [13])
        #expect(HostInput.bytes(forKey: "escape") == [27])
        #expect(HostInput.bytes(forKey: "up") == [27, 91, 65])
        #expect(HostInput.bytes(forKey: "down") == [27, 91, 66])
        #expect(HostInput.bytes(forKey: "right") == [27, 91, 67])
        #expect(HostInput.bytes(forKey: "left") == [27, 91, 68])
        #expect(HostInput.bytes(forKey: "tab") == [9])
        #expect(HostInput.bytes(forKey: "backspace") == [127])
        #expect(HostInput.bytes(forKey: "interrupt") == [3])
        #expect(HostInput.bytes(forKey: "nope") == nil)
    }

    @Test func textThenEnterSeparately() {
        #expect(HostInput.writes(text: "hi", submit: true, key: nil)
                == [.init(bytes: Array("hi".utf8), delay: 0), .init(bytes: [13], delay: 0.06)])
        #expect(HostInput.writes(text: "hi", submit: false, key: nil) == [.init(bytes: Array("hi".utf8), delay: 0)])
        #expect(HostInput.writes(text: nil, submit: true, key: "escape") == [.init(bytes: [27], delay: 0)])
        #expect(HostInput.writes(text: "x", submit: false, key: "down")
                == [.init(bytes: [120], delay: 0), .init(bytes: [27, 91, 66], delay: 0.06)])
        #expect(HostInput.writes(text: nil, submit: false, key: "bogus").isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `swift test --filter HostInputTests 2>&1 | tail -3` → compile error.

- [ ] **Step 3: Implement `Sources/VibeCore/HostInput.swift`**

```swift
import Foundation

/// Phone replies to a window session, written straight into its terminal.
public enum HostInput {
    public struct Write: Equatable, Sendable {
        public var bytes: [UInt8]
        /// Wait this long after the previous write.
        public var delay: TimeInterval

        public init(bytes: [UInt8], delay: TimeInterval) {
            self.bytes = bytes
            self.delay = delay
        }
    }

    /// What a terminal sends for the phone's keys (names as in `RemoteInput.Key`).
    public static func bytes(forKey name: String) -> [UInt8]? {
        switch name {
        case "enter": return [13]
        case "escape": return [27]
        case "up": return [27, 91, 65]
        case "down": return [27, 91, 66]
        case "right": return [27, 91, 67]
        case "left": return [27, 91, 68]
        case "tab": return [9]
        case "backspace": return [127]
        case "interrupt": return [3]
        default: return nil
        }
    }

    /// The (already sanitized) text, then Enter or the key as a separate write a moment later: Claude Code
    /// and Codex treat a burst of input as a paste, where Enter would become part of the text.
    public static func writes(text: String?, submit: Bool, key: String?) -> [Write] {
        var writes: [Write] = []
        if let text, !text.isEmpty { writes.append(Write(bytes: Array(text.utf8), delay: 0)) }
        let gap: TimeInterval = writes.isEmpty ? 0 : 0.06
        if text != nil, submit { writes.append(Write(bytes: [13], delay: gap)) }
        if let key {
            guard let bytes = bytes(forKey: key) else { return writes.isEmpty ? [] : writes }
            writes.append(Write(bytes: bytes, delay: writes.isEmpty ? 0 : 0.06))
        }
        return writes
    }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter HostInputTests 2>&1 | tail -3` → 2 passed.

- [ ] **Step 5: Branch `PhoneAccess` for window sessions**

Add a property: `weak var hostClient: HostClient?`; set it in `AppDelegate.applicationDidFinishLaunching` before `phoneAccess.startIfEnabled()`: `phoneAccess.hostClient = hostClient`.

Sessions list JSON (`"inTerminal": session.inTerminalApp`) becomes:
```swift
"inTerminal": session.inTerminalApp || session.inWindow, "inWindow": session.inWindow,
```
(The phone's `inTerminal` means "has a screen to show and can take replies".)

In `screen(_:respond:)`: replace `guard session.inTerminalApp else {…}` with
```swift
        guard session.inTerminalApp || session.inWindow else { return respond(.error(409, "This session isn't in a Terminal tab or the window.")) }
```
and replace the `reads.async { let raw = TerminalBridge.screens(for: [tty])[tty] … }` block's first line by reading through a helper, keeping everything after `let raw = …` unchanged but moved into a `finish(raw:)` closure:
```swift
        screenWaiters[key] = [respond]
        let finish: (String?) -> Void = { raw in
            // Visible screen only, credentials masked, trailing blank lines dropped.
            var lines = Redaction.secrets(in: raw ?? "").components(separatedBy: "\n")
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async {
                let waiters = self.screenWaiters.removeValue(forKey: key) ?? []
                let live = Set(self.store.sessions.map(\.identity))
                self.screenCache = self.screenCache.filter { live.contains($0.key) }
                let response: HTTPResponse
                if self.store.sessions.first(where: { $0.tty == tty })?.identity != key {
                    response = .error(409, Self.sessionChanged)
                } else if raw == nil {
                    response = .error(503, "Couldn't read that tab right now.")
                } else {
                    self.screenCache[key] = (Date(), text)
                    response = .json(["tty": tty, "text": text])
                }
                waiters.forEach { $0(response) }
            }
        }
        if let hostID = session.hostID, let hostClient {
            hostClient.screen(hostID) { raw in self.reads.async { finish(raw) } }
        } else {
            reads.async { finish(TerminalBridge.screens(for: [tty])[tty]) }
        }
```
In `history(_:respond:)`: same `guard` change; replace the `transcriptReads.async { let lines = TerminalBridge.history(tty: tty).map { … } … }` block's read with:
```swift
        let finish: ((history: String, screen: String)?) -> Void = { read in
            // Masked as a whole, before it's split into lines: a private key spans many lines.
            let lines = read.map {
                Scrollback.lines(history: Redaction.secrets(in: $0.history), screen: Redaction.secrets(in: $0.screen))
            }
            DispatchQueue.main.async {
                let waiters = self.historyWaiters.removeValue(forKey: key) ?? []
                let live = Set(self.store.sessions.map(\.identity))
                self.historyCache = self.historyCache.filter { live.contains($0.key) }
                if let lines, self.store.sessions.first(where: { $0.tty == tty })?.identity == key {
                    self.historyCache[key] = (Date(), lines)
                }
                waiters.forEach { $0(lines) }
            }
        }
        if let hostID = session.hostID, let hostClient {
            hostClient.history(hostID, lines: 5_000) { read in self.transcriptReads.async { finish(read) } }
        } else {
            transcriptReads.async { finish(TerminalBridge.history(tty: tty)) }
        }
```
In `input(_:device:respond:)`: change the session guard to `session.inTerminalApp || session.inWindow`, and right after `let sid = session.identity` insert:
```swift
        if let hostID = session.hostID {
            // Straight into the session's terminal: no focus changes, no Accessibility, nothing typed elsewhere.
            let allowed = {
                self.state == .on && self.inputAllowed && self.devices.contains { $0.id == device.id }
                    && self.store.sessions.first(where: { $0.tty == tty })?.identity == sid
                    && SessionIdentity.isRunning(pid: session.pid, startedAt: session.startedAt)
                    && ProcessTable.info(pid: session.pid)?.tty == tty
            }
            guard allowed() else { return respond(.error(409, Self.sessionChanged)) }
            var clean: String?
            if let text {
                guard let sanitized = RemoteInput.sanitized(text) else {
                    return respond(.error(400, RemoteInput.Failure.invalidText.description))
                }
                clean = sanitized
            }
            var at: TimeInterval = 0
            for write in HostInput.writes(text: clean, submit: submit, key: key?.rawValue) {
                at += write.delay
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                    guard let self, allowed() else { return }
                    self.hostClient?.send(hostID, bytes: Data(write.bytes), reply: false)
                }
            }
            audit("\(device.name) typed into \(session.displayName): \(summary)")
            onEvent?("\(device.name) typed into \(session.displayName)", summary)
            DispatchQueue.main.asyncAfter(deadline: .now() + at + 0.1) { self.store.refresh() }
            return respond(.json(["ok": true]))
        }
```

- [ ] **Step 6: Build and test** — `swift build 2>&1 | grep -E "error:|Build complete" && swift test 2>&1 | tail -2`.

- [ ] **Step 7: Verify against a scratch session (never a real one)** — with the app installed (`./scripts/build-app.sh --install`) and Phone Access on, start `VibeSwitcher --new shell /tmp/vs-scratch`, then in that window session run `cat` (type it in the window). From the paired phone, open the scratch session: its screen shows; send "hello" → the window shows `hello` echoed by `cat`. If no phone is at hand, skip and note it in the final report.

- [ ] **Step 8: Commit**

```bash
git add Sources/VibeCore/HostInput.swift Tests/VibeCoreTests/HostInputTests.swift Sources/VibeSwitcher/PhoneAccess.swift Sources/VibeSwitcher/AppDelegate.swift
git commit -m "Phone: window sessions' screen and scrollback come from the session host; replies go straight into the session's terminal (text, then Enter a moment later), with the same pairing, replies-switch and session checks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Docs and end-to-end verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: README** — add a section after "Sidebar mode":

```markdown
**The window** (⌘-click the menu bar icon, the window button in the list, or `VibeSwitcher --window`): every
session grouped by project on the left, the selected one's live terminal in the middle, details on the right.
New sessions (⊕, ⌘N) start **in the window** by default: VibeSwitcher runs them itself, in a small background
process (`vibeswitcher-host`) that keeps them going when VibeSwitcher quits, crashes or updates; reopening the
window reattaches them. ⌥⌘N opens a plain shell in the same project. Sessions you still run in Terminal are
listed too and open there. Settings (⌘,) has launch presets (per project: command, flags, environment, window or
Terminal) and the terminal's font, colors, cursor, scrollback and bell. Tools run inside window sessions ask for
privacy permissions (Desktop, Documents…) as VibeSwitcher rather than Terminal.
```
Replace the `--new` line under the command-line section with:
```
VibeSwitcher --new claude ~/dev/app   # start a preset (name, or claude/codex/shell) there; --terminal: in Terminal
VibeSwitcher --window                 # open the window
```

- [ ] **Step 2: Full test suite** — `swift test 2>&1 | tail -3` → all pass (157 existing + new).

- [ ] **Step 3: End-to-end with throwaway sessions only**

```bash
./scripts/build-app.sh --install 2>&1 | tail -1; sleep 2
B=/Applications/VibeSwitcher.app/Contents/MacOS/VibeSwitcher
mkdir -p /tmp/vs-scratch
$B --new shell /tmp/vs-scratch; sleep 2
$B --new claude /tmp/vs-scratch; sleep 8            # a throwaway Claude session in a scratch folder
cat ~/.vibeswitcher/app-status.json | grep -E '"host"|"tty"|"status"'
```
Checks (screenshot the window each time, see Task 9 Step 9):
1. Both scratch sessions are listed under "vs-scratch"; the Claude one shows a status dot and its welcome screen.
2. `pkill -x VibeSwitcher; open /Applications/VibeSwitcher.app; sleep 3; $B --window` → both still listed; the Claude screen redraws correctly (Review Focus 1).
3. `./scripts/build-app.sh --install` again → same as 2, no session lost (Review Focus 5).
4. In the scratch shell type `yes | head -c 50000000 | tail -c 100; echo ok` → the window stays responsive and prints `ok` (Review Focus 2).
5. In the scratch shell type `cd /nonexistent-folder-xyz; claude-not-installed` → errors print in the session (Review Focus 4).
6. End both sessions (⌘W, confirm) → rows turn "ended"; Remove clears them.
7. Menu bar dots include the scratch Claude session while it runs; clicking its dot opens the window on it.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "README: the window, window sessions that survive restarts, launch presets, terminal settings, --new/--window

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

