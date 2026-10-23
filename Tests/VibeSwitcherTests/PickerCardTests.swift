import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftTerm
import SwiftUI
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// 2026-10-21: "I typed /mcp in the chat and nothing showed; the selector only appeared after I sent another message."
/// A local command's picker writes nothing to the transcript, and its rows (no numbers) were never read off the
/// screen. Here Claude Code 2.1.306's own bytes (`PickerScreensTests`' scratch capture) are replayed on a real pty
/// through a scratch session host (its own socket, lock and key; never the user's) by a small program that draws
/// the capture up to a mark when told and records every byte typed into it. The chat follows it as the window does:
/// ChatSync typing the composer's message in, watching the host's screen, the card answered with keys.
@MainActor
@Suite(.serialized)
struct PickerCardTests {
    let temp = Scratch()

    @Test func theMCPPickerShowsAsACardAtOnceWithNoTranscriptLine() async throws {
        try await ReplayHarness.run(temp) { h in
            let transcript = try Data(contentsOf: h.transcript)
            let entries = h.chat.log.entries.count
            #expect(h.sync.type("/mcp"))
            try await h.typed("/mcp\r")
            #expect(h.sync.watching)
            // The terminal draws the picker: the card is up from the watch's own reads of the screen, nothing new in
            // the transcript and no heartbeat. At once: as the second read showing the picker is answered (the first
            // two that agree, `ScreenMenu.SettledPicker`), not a tick or a heartbeat later; counted in reads, not
            // seconds: under load a read comes late, never fewer of them.
            let before = h.reads.count
            h.draw("01-/mcp")
            #expect(await until(timeout: 30) { h.chat.menu?.picker == true })
            let first = h.reads.indices.dropFirst(before).first { ScreenMenu.parsePicker(h.reads[$0]) == h.chat.menu }
            let shown = try #require(first, "no read showed the card's picker")
            #expect(h.cards.indices.contains(shown + 1) && h.cards[shown + 1] == h.chat.menu,
                    "the picker was read twice by read \(shown + 2 - before), the card: \(h.cards.dropFirst(before).map { $0?.question })")
            let card = try await h.requireCard()
            #expect(card.picker)
            #expect(card.question == "Manage MCP servers\n2 servers")
            #expect(card.options.map(\.label) == ["✘ scratch-broken", "✔ scratch-notes"])
            #expect(card.options.map(\.detail) == [nil, "1 tool"])
            #expect(card.selected == 0)
            #expect(try Data(contentsOf: h.transcript) == transcript)
            #expect(h.chat.log.entries.count == entries)
            // ↓ in the terminal: the card's highlight follows.
            h.draw("02-down")
            #expect(await until(timeout: 30) { h.chat.menu?.selected == 1 })
            // Closed: the card goes, and so does the watch.
            h.draw("03-esc")
            #expect(await until(timeout: 30) { h.chat.menu == nil })
            #expect(await until(timeout: 30) { !h.sync.watching })
        }
    }

    @Test func aMessageWhileThePickerIsOpenWaitsAndEscClosesIt() async throws {
        try await ReplayHarness.run(temp) { h in
            _ = h.sync.type("/mcp")
            try await h.typed("/mcp\r")
            h.draw("01-/mcp")
            #expect(await until(timeout: 30) { h.chat.menu?.picker == true })
            // What happened to the user: their next message went in as text and ↩, which opened the highlighted server.
            // Now it waits, and the card says why.
            let entry = h.send("hello")
            try await Task.sleep(nanoseconds: 600_000_000)
            #expect(h.keys == "/mcp\r")
            #expect(h.chat.outbox.outbox.entries.first { $0.id == entry.id }?.state == .held)
            #expect(h.chat.answerNotice?.contains("Esc") == true)
            #expect(h.chat.sendNotice?.contains("picker is open") == true)
            // Esc from the composer (empty): the card takes it and closes the picker with the terminal's Esc.
            #expect(h.press(.escape, composer: "") == "")
            try await h.typed("/mcp\r\u{1b}")
            // Not with text in the box: the key is the box's.
            #expect(h.press(.escape, composer: "draft") == "draft")
            h.draw("03-esc")
            #expect(await until(timeout: 30) { h.chat.menu == nil })
            // Closed: the message goes in (once the window's heartbeat has seen nothing open for a moment), once.
            try await h.typed("/mcp\r\u{1b}hello\r", timeout: 30, heartbeat: true)
        }
    }

    @Test func theModelPickerAnsweredFromTheCardSendsTheTerminalsKeys() async throws {
        try await ReplayHarness.run(temp) { h in
            _ = h.sync.type("/model")
            h.draw("04-/model")
            #expect(await until(timeout: 30) { h.chat.menu?.options.count == 5 })
            let card = try await h.requireCard()
            #expect(card.question.hasPrefix("Select model"))
            #expect(card.options.map(\.label) == ["Default (recommended) ✔", "Opus", "Fable", "Sonnet", "Haiku"])
            #expect(card.selected == 0)
            // Fable chosen (the composer's ↓ ↓ ↩): down, down, Enter, as a terminal user types them.
            #expect(h.press(.down, composer: "") == "")
            #expect(h.press(.down, composer: "") == "")
            #expect(h.cardKeys.highlight == 2)
            try await h.typed("/model\r")
            #expect(h.press(.enter, composer: "") == "")
            try await h.typed("/model\r\u{1b}[B\u{1b}[B\r")
            #expect(h.chat.answering)
        }
    }

    @Test func aYesNoDialogIsACardEscClosesFromTheCard() async throws {
        try await ReplayHarness.run(temp) { h in
            _ = h.sync.type("/permissions")
            h.draw("11-enter")
            #expect(await until(timeout: 30) { h.chat.menu?.options == ["Yes", "No"] })
            let card = try await h.requireCard()
            #expect(card.question.hasPrefix("Delete allowed tool?"))
            #expect(card.selected == 1)
            #expect(card.hint == "Enter to confirm · Esc to cancel")
            // The card's Close (Esc).
            h.sync.cancel()
            try await h.typed("/permissions\r\u{1b}")
            // 2 pressed in the composer: "No" is where the cursor is, so just Enter.
            #expect(h.press(.digit(2), composer: "") == "")
            try await h.typed("/permissions\r\u{1b}\r")
        }
    }

    /// 2026-10-21: the test above failed 1 run in 3: its card's hint read "Enter to confirm · Esc to caect · ←/→ to
    /// switch · Esc to cancel". The replay writes 11-enter's 16 526 bytes at once, the host is handed the first
    /// 16 KiB of them (to byte 21943), and a read of its screen came before the other 142: Claude draws the dialog's
    /// footer over the list's ("En", then from column 9 "er to confirm · Esc to can", then "el" at 36), and what was
    /// left of the old one still ends in "Esc to cancel", so it parsed as the dialog, rows and all. Here that read
    /// is made to happen: the split screen is read once, and the rest is drawn before the next read.
    @Test func aRedrawSplitMidWordNeverReachesTheCard() async throws {
        try await ReplayHarness.run(temp) { h in
            _ = h.sync.type("/permissions")
            h.draw("10-down")
            #expect(await until(timeout: 30) { h.chat.menu?.options == ["Add a new rule…", "Bash(ls:*)"] && h.chat.menu?.selected == 1 })
            let list = h.chat.menu
            var shown: [ScreenMenu?] = []
            let watching = h.chat.$menu.sink { shown.append($0) }
            defer { watching.cancel() }
            let half = { (lines: [String]) in lines.contains { $0.contains("Esc to caect") } }
            let whole = { (lines: [String]) in lines.contains { $0.trimmingCharacters(in: .whitespaces) == "Enter to confirm · Esc to cancel" } }
            h.awaited = [half, whole]
            h.draw(at: 21943)
            #expect(await until(timeout: 30) { h.reads.last.map(half) == true })
            h.draw("11-enter")
            #expect(await until(timeout: 30) { h.chat.menu?.hint == "Enter to confirm · Esc to cancel" })
            #expect(h.reads.filter(half).count == 1)
            #expect(h.chat.menu?.options == ["Yes", "No"])
            #expect(h.chat.menu?.selected == 1)
            // The list's card stayed until the dialog's came: nothing in between.
            let dialog = h.chat.menu
            #expect(shown.allSatisfy { $0 == list || $0 == dialog }, "shown: \(shown.map { $0?.hint ?? "none" })")
        }
    }

    /// The pane's numbered menus settle too (/model's rows, `ScreenMenu.parse` over the pane's read). Two of its
    /// redraws read part way: ↓ at byte 14360, the old row's ❯ wiped and the new one's not drawn yet ("1. Default"
    /// and "2. Opus" both unmarked: no menu, the card would go), and Esc at 14801, the conversation drawn back over
    /// the dialog's top while its rows are still there ("❯ /model", "⎿  Kept model as Opus 5.5 (default)" read as
    /// the question). Each is read once and the rest drawn before the next read; the watch is stopped and there's no
    /// confirm read (`ChatSync.confirmAfter`: the pane's read here is the host's last, not the terminal's now), so
    /// the window's heartbeat (`beat`) is every read.
    @Test func aNumberedMenuSplitMidRowNeverReachesTheCard() async throws {
        try await ReplayHarness.run(temp) { h in
            _ = h.sync.type("/model")
            h.draw("04-/model")
            #expect(await until(timeout: 30) { h.chat.menu?.options.count == 5 && h.chat.menu?.selected == 0 })
            h.sync.stopWatching()
            h.sync.confirmAfter = nil
            // The watch's last read answered (one under way would take the first screen awaited).
            #expect(await until(timeout: 30) { h.readsUnderWay == 0 })
            var shown: [ScreenMenu?] = []
            let watching = h.chat.$menu.sink { shown.append($0) }
            defer { watching.cancel() }
            let has = ReplayHarness.has, marked = ReplayHarness.marked
            let halfDown = ReplayHarness.halfDown, halfEsc = ReplayHarness.halfEsc
            // ↓, split mid-row: the half read isn't taken, the whole one is once read twice.
            h.awaited = [halfDown]
            h.draw(at: 14360)
            await h.beat()
            h.draw("05-down")
            h.awaited = [marked("2. Opus")]
            await h.beat()
            await h.beat()
            #expect(h.chat.menu?.selected == 1)
            h.draw("06-down")
            h.awaited = [marked("3. Fable")]
            await h.beat()
            await h.beat()
            #expect(h.chat.menu?.selected == 2)
            // Esc, split: the half read isn't taken; closed, the card goes once read twice.
            h.awaited = [halfEsc]
            h.draw(at: 14801)
            await h.beat()
            h.draw("07-esc")
            h.awaited = [{ !has("Select model")($0) }]
            await h.beat()
            await h.beat()
            #expect(h.chat.menu == nil)
            #expect(h.reads.filter(halfDown).count == 1)
            #expect(h.reads.filter(halfEsc).count == 1)
            let cards = shown.map { $0.map { "\($0.question.prefix(30)) \($0.selected)" } ?? "none" }
            #expect(shown.map { $0?.selected } == [0, 1, 2, nil], "shown: \(cards)")
            #expect(!shown.contains { $0?.question.contains("Kept model") == true })
        }
    }

    /// The watch's ticks read the pane once each: the host's answer within a tick isn't a second read of the pane
    /// (the two would be of one instant and agree whatever they show). Esc split (`halfEsc`: the conversation drawn
    /// back over the dialog's top, "Kept model as …" read as a question) is read by one watch tick's host read, the
    /// rest drawn after a few more ticks: the half-drawn question never shows, the card goes once the closed screen
    /// is read twice.
    @Test func aRedrawSplitBetweenWatchTicksNeverReachesTheCard() async throws {
        try await ReplayHarness.run(temp) { h in
            _ = h.sync.type("/model")
            h.draw("04-/model")
            #expect(await until(timeout: 30) { h.chat.menu?.options.count == 5 && h.chat.menu?.selected == 0 })
            #expect(h.sync.watching)
            let drawn = h.chat.menu
            var shown: [ScreenMenu?] = []
            let watching = h.chat.$menu.sink { shown.append($0) }
            defer { watching.cancel() }
            let closed = { (lines: [String]) in !ReplayHarness.has("Select model")(lines) }
            h.awaited = [ReplayHarness.halfEsc, closed]
            h.draw(at: 14801)
            #expect(await until(timeout: 30) { h.reads.last.map(ReplayHarness.halfEsc) == true })
            // Ticks with the half read as the pane's last (the next host read waits for the closed screen).
            try await Task.sleep(nanoseconds: 800_000_000)
            #expect(h.chat.menu == drawn)
            h.draw("07-esc")
            #expect(await until(timeout: 30) { h.chat.menu == nil })
            #expect(h.reads.filter(ReplayHarness.halfEsc).count == 1)
            #expect(shown == [drawn, nil], "shown: \(shown.map { $0.map { "\($0.question.prefix(30)) \($0.selected)" } ?? "none" })")
        }
    }

    /// A click refused because the screen is mid-redraw (Esc split at 14801: the conversation drawn back over the
    /// dialog's top, "Kept model as …" read as a question): the card keeps the question it drew, the half-drawn one
    /// never shows, and once the closed screen is read twice the card goes and the notice says the question's gone.
    @Test func aClickRefusedMidRedrawKeepsTheCardUntilTheScreenSettles() async throws {
        try await ReplayHarness.run(temp) { h in
            _ = h.sync.type("/model")
            h.draw("04-/model")
            #expect(await until(timeout: 30) { h.chat.menu?.options.count == 5 && h.chat.menu?.selected == 0 })
            let drawn = try #require(h.chat.menu)
            var shown: [ScreenMenu?] = []
            let watching = h.chat.$menu.sink { shown.append($0) }
            defer { watching.cancel() }
            let closed = { (lines: [String]) in !ReplayHarness.has("Select model")(lines) }
            h.awaited = [ReplayHarness.halfEsc, closed]
            h.draw(at: 14801)
            #expect(await until(timeout: 30) { h.reads.last.map(ReplayHarness.halfEsc) == true })
            // Fable chosen on the card as drawn: the screen's last read is another question, not taken yet.
            h.sync.choose(2, drawn: drawn)
            #expect(h.keys == "/model\r")
            #expect(h.chat.menu == drawn)
            #expect(h.chat.answerNotice != nil)
            h.draw("07-esc")
            #expect(await until(timeout: 30) { h.chat.menu == nil })
            #expect(h.chat.answerNotice == "That question is gone.")
            #expect(h.keys == "/model\r")
            #expect(h.reads.filter(ReplayHarness.halfEsc).count == 1)
            #expect(shown == [drawn, nil], "shown: \(shown.map { $0.map { "\($0.question.prefix(30)) \($0.selected)" } ?? "none" })")
        }
    }

    /// The same screens read off the capture byte for byte (no host): a parse is taken when the read before parsed
    /// the same at another time, so a read landing mid-redraw is never taken (gone over twice, it's still one read),
    /// and a screen that couldn't be read counts as none.
    @Test func aPickerParseIsTakenOnceTwoReadsInARowAgree() throws {
        let raw = Array(try Data(contentsOf: ReplayHarness.capture.appendingPathExtension("raw")))
        func screen(_ end: Int) -> [String] {
            let terminal = Terminal(delegate: HeadlessDelegate(), options: TerminalOptions(cols: 110, rows: 40, scrollback: 100))
            terminal.feed(byteArray: Array(raw[0..<end]))
            return HostedSession.styledScreen(of: terminal).text.components(separatedBy: "\n")
        }
        let list = screen(19779), half = screen(21943), whole = screen(22085)
        #expect(ScreenMenu.parsePicker(half)?.hint == "Enter to confirm · Esc to caect · ←/→ to switch · Esc to cancel")
        var settled = ScreenMenu.SettledPicker()
        var clock = Date(timeIntervalSince1970: 1_000)
        func read(_ lines: [String]?) {
            clock += 0.25
            settled.read(lines, at: clock)
        }
        read(list)
        #expect(settled.menu == nil)
        #expect(settled.settling)
        read(list)
        let taken = try #require(settled.menu)
        #expect(taken.options == ["Add a new rule…", "Bash(ls:*)"])
        #expect(!settled.settling)
        read(half)
        #expect(settled.menu == taken)
        #expect(settled.settling)
        // The same read gone over again: one instant, not two reads agreeing.
        settled.read(half, at: clock)
        #expect(settled.menu == taken)
        #expect(settled.settling)
        read(whole)
        #expect(settled.menu == taken)
        read(whole)
        #expect(settled.menu?.hint == "Enter to confirm · Esc to cancel")
        #expect(settled.menu?.options == ["Yes", "No"])
        read(nil)
        #expect(settled.menu?.options == ["Yes", "No"])
        read(nil)
        #expect(settled.menu == nil)
    }

    /// The audit's probe: a message held while a picker is open, another session selected for a while (nothing open
    /// there), then back with the picker still open: the message still waits, and goes in once the picker closes.
    @Test func aHeldMessageStaysHeldAcrossSwitchingAwayAndBack() async throws {
        try await ReplayHarness.run(temp) { h in
            try await h.spawnOther()
            _ = h.sync.type("/mcp")
            try await h.typed("/mcp\r")
            h.draw("01-/mcp")
            #expect(await until(timeout: 30) { h.chat.menu?.picker == true })
            let entry = h.send("hello")
            h.selected = h.other.id
            try await h.beats(for: 2.5)
            #expect(h.chat.menu == nil)
            h.selected = nil
            try await h.beats(for: 2.5)
            #expect(h.keys == "/mcp\r")
            #expect(h.chat.outbox.outbox.entries.first { $0.id == entry.id }?.state == .held)
            #expect(h.chat.menu?.picker == true)
            h.draw("03-esc")
            try await h.typed("/mcp\rhello\r", timeout: 30, heartbeat: true)
        }
    }

    /// Out of sight (window closed or behind others, the terminal shown), the watch reads nothing; back, it goes on.
    @Test func noReadsWhileTheChatIsOutOfSight() async throws {
        try await ReplayHarness.run(temp) { h in
            _ = h.sync.type("/mcp")
            h.draw("01-/mcp")
            #expect(await until(timeout: 30) { h.chat.menu?.picker == true })
            h.inSight = false
            // The tick under way ends it.
            try await Task.sleep(nanoseconds: 500_000_000)
            let reads = h.hostReads
            try await Task.sleep(nanoseconds: 3_000_000_000)
            #expect(h.hostReads == reads, "\(h.hostReads - reads) reads while out of sight")
            #expect(h.sync.watching)
            // Back in sight: the heartbeat's read resumes the watch.
            h.inSight = true
            await h.beat()
            #expect(await until(timeout: 10) { h.hostReads >= reads + 4 })
            #expect(h.chat.menu?.picker == true)
        }
    }

    /// The bytes for a choice: arrows from the terminal's cursor, then Enter; Esc alone to close.
    @Test func theKeysForDownDownEnterAndForEsc() {
        let menu = ScreenMenu(question: "Select model", options: ["Default", "Opus", "Fable"], selected: 0)
        #expect(menu.keys(toChoose: 2).flatMap(\.bytes) == Array("\u{1b}[B\u{1b}[B\r".utf8))
        #expect(menu.keys(toChoose: 2).map(\.bytes) == [[27, 91, 66], [27, 91, 66], [13]])
        var picker = menu
        picker.picker = true
        let content = AnswerCardContent(menu: picker, pending: nil)
        let keys = AnswerCardKeys()
        #expect(keys.take(.escape, composer: "", content: content))
        #expect(keys.escapes == 1)
        // Not a question's: Esc there is the terminal's own answer, typed in the terminal.
        #expect(!keys.take(.escape, composer: "", content: AnswerCardContent(menu: menu, pending: nil)))
        #expect(!keys.take(.escape, composer: "text", content: content))
        #expect(keys.escapes == 1)
    }

    /// The watch stops by itself when no picker comes.
    @Test func theWatchEndsWhenNoPickerComes() async throws {
        try await ReplayHarness.run(temp) { h in
            _ = h.sync.type("/compact")
            #expect(h.sync.watching)
            #expect(await until(timeout: 60) { !h.sync.watching })
            #expect(h.chat.menu == nil)
        }
    }
}

/// A scratch host running the capture's replay, and the chat (ChatModel, ChatSync) following it. No pane: the
/// session stays the capture's size (110 x 40), and the screen is the host's.
@MainActor
final class ReplayHarness {
    static let program = #"""
# Replays a terminal capture: draws it up to a mark when told ({"to": MARK} lines appended to CONTROL; {"at": N} up to
# byte N), records
# every byte typed into it (KEYS). Usage: python3 -I -u replay.py RAW MARKS CONTROL KEYS
import json, os, select, sys, tty
RAW, MARKS, CONTROL, KEYS = sys.argv[1:5]
raw = open(RAW, "rb").read()
marks = json.load(open(MARKS))
tty.setraw(0)
at = 0
def draw(end):
    global at
    data = raw[at:end] if end >= at else b""
    while data:
        data = data[os.write(1, data):]
    at = max(at, end)
draw(marks["idle"])
seen = 0
while True:
    ready, _, _ = select.select([0], [], [], 0.02)
    if ready:
        data = os.read(0, 4096)
        if not data:
            break
        with open(KEYS, "ab") as f:
            f.write(data)
    with open(CONTROL) as f:
        lines = f.read().splitlines()
    for line in lines[seen:]:
        told = json.loads(line)
        draw(told["at"] if "at" in told else marks[told["to"]])
    seen = len(lines)
"""#

    static let capture: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("VibeHostTests/Fixtures/claude-2.1.306-pickers-110x40")

    let server: HostServer
    let socket: String
    let keyStore: AppProof.MemoryStore
    let host: HostClient
    let chat: ChatModel
    let sync: ChatSync
    let transcript: URL, control: URL, keysFile: URL
    /// The scratch folder the harness's files are in, and the replay's working folder.
    let home: URL
    let key = "host:replay"
    var session: HostSession!
    let cardKeys = AnswerCardKeys()
    private let command: String

    private init(_ temp: Scratch) throws {
        let launcher = Bundle(for: ReplayAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
        socket = try temp.shortFolder("vsh-pick") + "/h.sock"
        let appKey = SymmetricKey(size: .bits256)
        home = temp.url("picker-home").resolvingSymlinksInPath()
        let folder = home.appendingPathComponent(".claude/projects/-tmp-scratch-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        transcript = folder.appendingPathComponent("\(UUID().uuidString).jsonl")
        let first = [#"{"type":"user","uuid":"u0","timestamp":"2026-10-21T08:00:00.000Z","message":{"role":"user","content":"start"}}"#,
                     #"{"type":"assistant","uuid":"a0","timestamp":"2026-10-21T08:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Ready."}]}}"#]
        FileManager.default.createFile(atPath: transcript.path, contents: Data((first.joined(separator: "\n") + "\n").utf8))
        control = home.appendingPathComponent("control.jsonl")
        FileManager.default.createFile(atPath: control.path, contents: nil)
        keysFile = home.appendingPathComponent("keys.bin")
        FileManager.default.createFile(atPath: keysFile.path, contents: nil)
        let script = home.appendingPathComponent("replay.py")
        try Self.program.write(to: script, atomically: true, encoding: .utf8)
        var config = HostServer.Config(socketPath: socket, lockPath: socket + ".lock", shell: "/bin/sh", launcher: launcher,
                                       baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": home.path],
                                       hostBuild: HostBuild.id(ofExecutableAt: HostClient.hostExecutable.path))
        config.idleExit = nil
        config.appKey = appKey
        config.appExecutable = HostServer.executable(of: getpid())
        server = HostServer(config: config)
        try server.start()
        keyStore = AppProof.MemoryStore(key: appKey)
        host = HostClient(socketPath: socket, appKey: { [keyStore] in keyStore.key() })
        chat = ChatModel(outbox: ComposerOutbox(url: home.appendingPathComponent("outbox.json")), home: home.path,
                         steerRoot: home.appendingPathComponent("vibeswitcher"))
        sync = ChatSync(chat: chat, host: host)
        let capture = Self.capture.path
        command = "exec /usr/bin/python3 -I -u '\(script.path)' '\(capture).raw' '\(capture).marks.json' '\(control.path)' '\(keysFile.path)'"
        // Every read of the host's screen counted, and kept as the pane's read of it would be (trimmed both sides),
        // stamped with when it was read (the pane's reads of it, until the next, are of that instant): the pane
        // follows the same session stream.
        // A read answered only once the host's screen passes the first of `awaited` (that one used up), or given up on
        // after a minute (the test's own checks fail then, it doesn't hang).
        let read = sync.hostScreen
        hostRead = read
        func answer(_ id: UUID, by deadline: Date, _ done: @escaping ([String]?) -> Void) {
            read(id) { [weak self] lines in
                guard let self else { return done(lines) }
                if let wanted = self.awaited.first {
                    guard let lines, wanted(lines) || Date() > deadline else {
                        return DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { answer(id, by: deadline, done) }
                    }
                    self.awaited.removeFirst()
                }
                if let lines {
                    self.paneReads[id] = ScreenRead(lines: lines.map { $0.replacingOccurrences(of: "\u{0}", with: " ").trimmingCharacters(in: .whitespaces) },
                                                    at: Date())
                }
                if let lines { self.reads.append(lines) }
                done(lines)
                if lines != nil { self.cards.append(self.chat.menu) }
            }
        }
        sync.hostScreen = { [weak self] id, done in
            self?.hostReads += 1
            self?.readsUnderWay += 1
            answer(id, by: Date().addingTimeInterval(60)) { lines in
                self?.readsUnderWay -= 1
                done(lines)
            }
        }
        sync.screen = { [weak self] id in self?.paneReads[id] ?? ScreenRead() }
        sync.inSight = { [weak self] in self?.inSight ?? false }
    }

    /// A harness on its scratch host for `body`, ended (`end`) once it's done, also when it throws.
    static func run(_ temp: Scratch, _ body: (ReplayHarness) async throws -> Void) async throws {
        let h = try ReplayHarness(temp)
        do {
            try await begin(h)
            try await body(h)
        } catch {
            await h.end()
            throw error
        }
        await h.end()
    }

    private static func begin(_ h: ReplayHarness) async throws {
        h.host.connectIfRunning()
        #expect(await until { h.host.state == .connected })
        var result: Result<HostSession, HostClientError>?
        h.host.spawn(SpawnRequest(cwd: h.home.path, command: h.command, env: [:], cols: 110, rows: 40, keepShell: false,
                                  label: "Replayed Claude", agent: "claude")) { result = $0 }
        #expect(await until { result != nil })
        h.session = try #require(result).get()
        h.sync.target = { [weak h] in
            guard let h else { return nil }
            let id = h.selected ?? h.session.id
            return ChatSync.Target(id: id, key: id == h.session.id ? h.key : "host:other", agent: .claude, needsInput: false)
        }
        h.chat.show(path: h.transcript.path, key: h.key)
        #expect(await until(timeout: 90) { h.chat.state == .ready })
        // The idle screen drawn: the replay is listening.
        let deadline = Date().addingTimeInterval(90)
        var idle = false
        while !idle, Date() < deadline {
            idle = await h.hostLines().contains { $0.contains("manual mode on") }
            if !idle { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        let shown = await h.hostLines()
        #expect(idle, "the replay never drew its idle screen: \(shown)")
        // What the host's parser answered the capture's terminal queries with (its version, its colours) went in as
        // input: what's typed from here on is counted after it.
        try await Task.sleep(nanoseconds: 500_000_000)
        h.typedBefore = (try? Data(contentsOf: h.keysFile).count) ?? 0
    }

    /// Ends the scratch host, waits for what was still under way to end, then removes the harness's folder. The host
    /// ends its session and drops the client at once, but the client finds that out only once the main actor runs
    /// again: then a composer message still waiting for the host's word fails, ChatSync's callback saves the outbox,
    /// and `OutboxStore.save` makes the folder again for it. Removed before that (the Scratch's removal, once the
    /// test returned: a test ends as soon as the replay has the keys, and under load the host's word comes later),
    /// it was back with an outbox.json in it, left in TMPDIR. So: the client has lost the host, no message is still
    /// sending, the replay has exited; then the folder goes.
    func end() async {
        sync.stopWatching()
        server.stop(terminateSessions: true)
        unlink(socket + ".lock")
        let replay = session?.childPID
        var exited = replay == nil
        let settled = await until(timeout: 60) {
            // Reaped here: the stopped host no longer waits for its child.
            var status: Int32 = 0
            if !exited, let replay { exited = waitpid(replay, &status, WNOHANG) != 0 }
            return exited && host.state != .connected && !chat.outbox.outbox.entries.contains { $0.state == .sending }
        }
        #expect(settled, "the replay never ended: \(host.state), \(chat.outbox.outbox.entries.map(\.state)), exited: \(exited)")
        try? FileManager.default.removeItem(at: home)
        #expect(!FileManager.default.fileExists(atPath: home.path), "\(home.path) is still there")
    }

    /// Host lines (NULs where the program moved the cursor on instead of drawing) holding `text`.
    static func has(_ text: String) -> ([String]) -> Bool {
        { lines in lines.contains { $0.replacingOccurrences(of: "\u{0}", with: " ").contains(text) } }
    }

    /// `row` (`"2. Opus"`) with the cursor on it.
    static func marked(_ row: String) -> ([String]) -> Bool { has("❯ \(row)") }

    /// /model's ↓ read part way (byte 14360): the old row's ❯ wiped, the new one's not drawn yet.
    static let halfDown = { (lines: [String]) in has("Select model")(lines) && !(1...5).contains { marked("\($0).")(lines) } }

    /// /model's Esc read part way (byte 14801): the conversation drawn back over the dialog's top, its rows still there.
    static let halfEsc = { (lines: [String]) in has("Kept model as")(lines) && marked("3. Fable")(lines) }

    /// The host's screen, as ChatSync reads it (not counted, never awaited).
    func hostLines() async -> [String] {
        await withCheckedContinuation { done in hostRead(session.id) { done.resume(returning: $0 ?? []) } }
    }

    /// The terminal draws the capture up to byte `offset`.
    func draw(at offset: Int) {
        let handle = try! FileHandle(forWritingTo: control)
        handle.seekToEndOfFile()
        handle.write(Data(#"{"at": \#(offset)}"#.utf8) + Data("\n".utf8))
        try? handle.close()
    }

    /// The terminal draws the capture up to `mark`.
    func draw(_ mark: String) {
        let handle = try! FileHandle(forWritingTo: control)
        handle.seekToEndOfFile()
        handle.write(Data(#"{"to": "\#(mark)"}"#.utf8) + Data("\n".utf8))
        try? handle.close()
    }

    /// The selected session (nil: the replay's).
    var selected: UUID?
    /// A second session to select (`spawnOther`): a sleep, its screen blank.
    var other: HostSession!
    /// The window shown and in front, the chat over the terminal (`ChatSync.inSight`).
    var inSight = true
    /// Reads of the host's screen so far.
    var hostReads = 0
    /// Reads of the host's screen not answered yet.
    var readsUnderWay = 0
    /// What each read answered with, in order.
    var reads: [[String]] = []
    /// The card once each of `reads` was answered (ChatSync done with it).
    var cards: [ScreenMenu?] = []
    /// Screens the next reads wait for, one each: a read is answered only once the host's screen passes the first (read
    /// again every 20 ms), which is then used up. A test decides what the watch gets to see.
    var awaited: [([String]) -> Bool] = []
    /// The host's screen read as the chat's own `hostScreen` would, before the harness counts it.
    private var hostRead: (UUID, @escaping ([String]?) -> Void) -> Void = { _, done in done(nil) }
    /// Each session's screen as the pane would read it, as of the last read of the host's.
    var paneReads: [UUID: ScreenRead] = [:]

    func spawnOther() async throws {
        var result: Result<HostSession, HostClientError>?
        host.spawn(SpawnRequest(cwd: home.path, command: "exec /bin/sleep 600", env: [:], cols: 110, rows: 40, keepShell: false,
                                label: "Other", agent: "claude")) { result = $0 }
        #expect(await until { result != nil })
        other = try #require(result).get()
    }

    /// The window's heartbeat (`MainWindowController.followChat`, each second while the chat is in sight): the
    /// selected session's screen read.
    func beat() async {
        guard inSight else { return }
        if let target = sync.target() { _ = await withCheckedContinuation { done in sync.hostScreen(target.id) { done.resume(returning: $0) } } }
        sync.readScreen()
    }

    /// `beat` each second for `seconds`.
    func beats(for seconds: TimeInterval) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            await beat()
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Bytes in the session's input before the test typed anything (the parser's answers to the capture's queries).
    var typedBefore = 0

    /// Every byte typed into the session since it was ready.
    var keys: String { String(decoding: ((try? Data(contentsOf: keysFile)) ?? Data()).dropFirst(typedBefore), as: UTF8.self) }

    /// The card, or a failed test (Swift Testing's own `#require(h.card)` reflects the harness until the stack runs out).
    func requireCard(sourceLocation: SourceLocation = #_sourceLocation) async throws -> AnswerCardContent {
        guard let card else {
            let lines = await hostLines()
            Issue.record("no card; the host's screen:\n\(lines.joined(separator: "\n"))", sourceLocation: sourceLocation)
            throw ReplayError.noCard
        }
        return card
    }

    /// Waits for exactly `expected` to have been typed in.
    /// `heartbeat`: the window's 1 s reading of the screen goes on meanwhile (`MainWindowController.followChat`).
    func typed(_ expected: String, timeout: TimeInterval = 10, heartbeat: Bool = false,
               sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var beaten = Date.distantPast
        var met = keys == expected
        while !met, Date() < deadline {
            if heartbeat, Date().timeIntervalSince(beaten) >= 1 {
                beaten = Date()
                await beat()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            met = keys == expected
        }
        if !met { Issue.record("typed \(keys.debugDescription), not \(expected.debugDescription)", sourceLocation: sourceLocation) }
    }

    var card: AnswerCardContent? { chat.menu.map { AnswerCardContent(menu: $0, pending: chat.log.pendingQuestions) } }

    /// A key pressed in the composer holding `composer` (`ComposerView.cardKey`): the card takes it as the window's
    /// does (a choice answered, an Esc closing the picker through the card's Close); else it goes into the box.
    func press(_ key: AnswerKeys.Key, composer: String) -> String {
        guard let menu = chat.menu else { return composer }
        let content = AnswerCardContent(menu: menu, pending: chat.log.pendingQuestions)
        let before = (cardKeys.press, cardKeys.escapes)
        guard cardKeys.take(key, composer: composer, content: content, busy: chat.answering) else {
            if case .digit(let n) = key { return composer + "\(n)" }
            return composer
        }
        if cardKeys.escapes != before.1 { sync.cancel() }
        if let press = cardKeys.press, press != before.0, case .answer(let index) = AnswerKeys.pick(press.index, in: content) {
            sync.choose(index, drawn: menu)
        }
        return composer
    }

    /// The composer's ↩: in the outbox, then typed in (held while a picker is open).
    @discardableResult
    func send(_ text: String) -> OutboxEntry {
        let entry = OutboxEntry(key: key, message: text, text: text, expectsSoon: true)
        chat.outbox.add(entry)
        let actions = ComposerActions(send: { [unowned self] in self.sync.type($0) }, steer: { _ in false }, stop: {}, cycleMode: {})
        _ = chat.deliver(entry, steering: false, working: false, actions: actions)
        return entry
    }
}

private final class ReplayAnchor {}

enum ReplayError: Error { case noCard }

/// Pictures of the picker card over the replayed capture (`PickerCardTests`: a scratch host, never a real session),
/// light and dark, with the host's screen beside it: /mcp's server list and /model with the cursor moved to Fable.
/// Only with `CHAT_SYNC_SNAPSHOT_DIR=/some/folder scripts/test.sh --filter PickerCardSnapshots` (picker-card-mcp-light.png, …).
@MainActor
@Suite(.serialized)
struct PickerCardSnapshots {
    nonisolated static let folder = ProcessInfo.processInfo.environment["CHAT_SYNC_SNAPSHOT_DIR"]
    let temp = Scratch()

    @Test(.enabled(if: folder != nil)) func drawTheMCPPicker() async throws {
        try await ReplayHarness.run(temp) { h in
            _ = h.sync.type("/mcp")
            h.draw("01-/mcp")
            #expect(await until(timeout: 30) { h.chat.menu?.picker == true })
            try await draw(h, "mcp")
        }
    }

    @Test(.enabled(if: folder != nil)) func drawTheModelPicker() async throws {
        try await ReplayHarness.run(temp) { h in
            _ = h.sync.type("/model")
            h.draw("06-down")
            #expect(await until(timeout: 30) { h.chat.menu?.selected == 2 })
            try await draw(h, "model")
        }
    }

    func draw(_ h: ReplayHarness, _ name: String) async throws {
        let folder = try #require(Self.folder)
        let row = WindowRow(content: .hosted(h.session), project: "scratch-project")
        let screen = await h.hostLines().suffix(22).joined(separator: "\n")
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let view = HStack(alignment: .top, spacing: 0) {
                ChatView(chat: h.chat, row: row, live: true, showTerminal: {}, choose: { _, _, _ in }, moveTab: { _ in }, resend: { _ in })
                    .frame(width: 620, height: 640)
                Text(screen).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(white: 0.9))
                    .frame(width: 700, height: 640, alignment: .topLeading).padding(10).background(Color(white: 0.1))
            }
            .background(Color(nsColor: .windowBackgroundColor))
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1340, height: 660), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme)
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.close() }
            try await Task.sleep(nanoseconds: 600_000_000)
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("picker-card-\(name)-\(scheme == .darkAqua ? "dark" : "light").png"))
        }
    }
}
