import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// 2026-10-25: the app's footprint climbed 100-180 MB an hour (1.5 GB after 11.5 h, 2.8 GB after 29 h). The soak bench
/// (`--ui-bench --soak`) put it on the chat: while it wasn't at its end (you read further up, or the view lost track of
/// the end), every entry the transcript gained widened the window laid out, and nothing narrowed it again, so a chat
/// left on a working lead laid out every row it wrote, for good. Here the real ChatModel follows a growing transcript
/// in a scratch home: what arrives while reading up widens the window by `ChatWindow.arrivalsKept` rows at most, and
/// back at the end the window is what you asked for again (Show earlier's pages kept).
@MainActor
@Suite(.serialized)
struct ChatWindowGrowthTests {
    let temp = Scratch()

    /// A chat on a made-up transcript of `turns` exchanges under a scratch home's ~/.claude/projects, read and ready.
    func chat(turns: Int) async throws -> (ChatModel, String) {
        let home = temp.url("chat-window-growth")
        let projects = home.appendingPathComponent(".claude/projects/-growth")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let path = projects.appendingPathComponent("lead.jsonl").path
        IdleBench.writeTranscript(to: path, turns: turns)
        let chat = ChatModel(outbox: ComposerOutbox(url: home.appendingPathComponent("outbox.json")), home: home.path,
                             steerRoot: home.appendingPathComponent("vibeswitcher"))
        chat.show(path: path)
        #expect(await until { chat.state == .ready && !chat.reading })
        return (chat, path)
    }

    /// `turns` more exchanges at the end of the transcript, read in by a poll (as the window's heartbeat does).
    func grow(_ chat: ChatModel, _ path: String, turns: Int) async {
        let before = chat.items.count
        for turn in 0..<turns { UIBench.appendTurn(to: path, turn: turn) }
        chat.poll()
        #expect(await until { !chat.reading && chat.items.count > before })
    }

    @Test func whatArrivesWhileReadingUpWidensTheWindowABoundedWay() async throws {
        let (chat, path) = try await chat(turns: 100)
        #expect(chat.shownLimit == ChatWindow.page)
        chat.atBottom = false
        // A little arrives: nothing you're looking at moves (the window grows by what came).
        let before = chat.items.count
        await grow(chat, path, turns: 2)
        #expect(chat.shownLimit == ChatWindow.page + chat.items.count - before)
        // A working night's worth: the window stops growing at the bound.
        for _ in 0..<10 { await grow(chat, path, turns: 20) }
        #expect(chat.items.count > before + 2 * ChatWindow.arrivalsKept, "\(chat.items.count) items")
        #expect(chat.shownLimit == ChatWindow.page + ChatWindow.arrivalsKept, "\(chat.shownLimit) rows laid out")
    }

    @Test func backAtTheEndTheWindowIsWhatYouAskedForAgain() async throws {
        let (chat, path) = try await chat(turns: 200)
        // Two pages, asked for with Show earlier, then reading up while the session works.
        chat.showEarlier()
        #expect(chat.shownLimit == 2 * ChatWindow.page)
        chat.atBottom = false
        await grow(chat, path, turns: 10)
        #expect(chat.shownLimit > 2 * ChatWindow.page)
        // At the end again: the next arrival leaves the two pages asked for, not what arrived meanwhile.
        chat.atBottom = true
        await grow(chat, path, turns: 1)
        #expect(chat.shownLimit == 2 * ChatWindow.page)
    }
}

extension ChatWindowGrowthTests {
    /// Left reading up at `anchor`, then away on another conversation while `arrived` turns come in, then back.
    func reopen(arrived: Int) async throws -> (chat: ChatModel, anchor: String) {
        let (chat, path) = try await chat(turns: 100)
        #expect(await until { !chat.assembling })
        let anchor = try #require(chat.items.dropLast(20).last?.id)
        chat.atBottom = false
        chat.rowTops = [anchor: 0]
        chat.visibleTop = 0
        let other = (path as NSString).deletingLastPathComponent + "/other.jsonl"
        IdleBench.writeTranscript(to: other, turns: 10)
        chat.show(path: other)
        #expect(await until { chat.state == .ready && !chat.reading })
        for turn in 0..<arrived { UIBench.appendTurn(to: path, turn: turn) }
        chat.show(path: path)
        #expect(await until { chat.state == .ready && !chat.reading })
        return (chat, anchor)
    }

    /// Back on a conversation you left reading up: where you were is laid out again when it isn't far back.
    @Test func backWhereYouWereReadingWhenItIsNear() async throws {
        let (chat, anchor) = try await reopen(arrived: 5)
        #expect(chat.restoreAnchor == anchor)
        let index = try #require(chat.items.firstIndex { $0.id == anchor })
        #expect(chat.shownLimit >= chat.items.count - index, "\(chat.shownLimit) rows laid out, the anchor \(chat.items.count - index) back")
    }

    /// A lead that worked for hours since you left: it opens at the end rather than laying out everything back to
    /// where you were (it laid out 952 rows in the soak bench).
    @Test func notBackWhereYouWereReadingWhenAllDayIsInBetween() async throws {
        let (chat, _) = try await reopen(arrived: 200)
        #expect(chat.restoreAnchor == nil)
        #expect(chat.shownLimit <= ChatWindow.page + ChatWindow.arrivalsKept, "\(chat.shownLimit) rows laid out")
    }
}

extension ChatWindowGrowthTests {
    /// Paged back four pages with Show earlier and reading near the top of them: switching away and straight back
    /// returns there (the bound is what you had laid out, plus what may arrive, not a fixed distance from the end).
    @Test func backWhereYouWereReadingAfterShowEarlier() async throws {
        let (chat, path) = try await chat(turns: 100)
        #expect(await until { !chat.assembling })
        for _ in 0..<3 {
            chat.showEarlier()
            #expect(await until { !chat.assembling && chat.staging == nil })
        }
        #expect(chat.shownLimit == 4 * ChatWindow.page)
        let anchor = chat.items[chat.items.count - 230].id
        chat.atBottom = false
        chat.rowTops = [anchor: 0]
        chat.visibleTop = 0
        let other = (path as NSString).deletingLastPathComponent + "/other.jsonl"
        IdleBench.writeTranscript(to: other, turns: 10)
        chat.show(path: other)
        #expect(await until { chat.state == .ready && !chat.reading })
        chat.show(path: path)
        #expect(await until { chat.state == .ready && !chat.reading })
        #expect(chat.restoreAnchor == anchor)
        #expect(chat.shownLimit >= 230, "\(chat.shownLimit) rows laid out")
    }
}
