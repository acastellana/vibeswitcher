import Foundation
import Testing
@testable import VibeCore

struct ChatTimelineTests {
    func tool(_ id: String, _ name: String, _ detail: ToolDetail = .fields([]), failed: Bool = false, title: String? = nil) -> ChatEntry {
        let result = ChatResult(output: "", truncated: false, failed: failed, at: nil, images: [])
        return ChatEntry(id: id, at: nil, kind: .tool(ChatTool(id: id, name: name, title: title ?? name, detail: detail, at: nil, result: result)))
    }
    func prompt(_ id: String, _ text: String) -> ChatEntry { ChatEntry(id: id, at: nil, kind: .prompt(text: text, images: [])) }
    func reply(_ id: String, _ text: String) -> ChatEntry { ChatEntry(id: id, at: nil, kind: .reply(text)) }

    func shape(_ items: [ChatItem]) -> [String] {
        items.map { item in
            switch item {
            case .prompt(let entry): return "prompt:\(entry.id)"
            case .reply(let entry): return "reply:\(entry.id)"
            case .team(let entry, _): return "team:\(entry.id)"
            case .tools(_, let tools): return "tools:" + tools.map(\.id).joined(separator: ",")
            case .newMarker(let summary): return "new:\(summary)"
            }
        }
    }

    @Test func consecutiveToolsFoldIntoOneItem() {
        let entries = [prompt("p", "go"), tool("t1", "Bash"), tool("t2", "Read"), reply("r", "ok"), tool("t3", "Bash")]
        #expect(shape(ChatTimeline.items(entries, newAfter: nil)) == ["prompt:p", "tools:t1,t2", "reply:r", "tools:t3"])
    }

    @Test func summaryCountsKindsDistinctFilesAndFailures() {
        let tools = [tool("1", "Bash"), tool("2", "Bash", failed: true), tool("3", "Bash"),
                     tool("4", "Edit", .edit(path: "/a", changes: [])), tool("5", "Edit", .edit(path: "/a", changes: [])),
                     tool("6", "Write", .write(path: "/b", content: "")), tool("7", "Read", .read(path: "/c")),
                     tool("8", "Grep"), tool("9", "mcp__chrome__navigate")].compactMap { entry -> ChatTool? in
            if case .tool(let tool) = entry.kind { return tool } else { return nil }
        }
        #expect(ChatTimeline.summary(tools) == "Ran 3 commands · edited 2 files · read 1 file · searched once · used 1 tool · 1 failed")
    }

    @Test func singleCommandAndPatch() {
        let tools = [tool("1", "exec_command", .command("ls")), tool("2", "apply_patch", .patch("p"))].compactMap { entry -> ChatTool? in
            if case .tool(let tool) = entry.kind { return tool } else { return nil }
        }
        #expect(ChatTimeline.summary(tools) == "Ran 1 command · edited 1 file")
    }

    @Test func theNewMarkerGoesAfterTheLastSeenEntry() {
        let entries = [prompt("p", "go"), reply("r1", "a"), tool("t1", "Bash"), tool("t2", "Edit", .edit(path: "/x", changes: [])), reply("r2", "b")]
        #expect(shape(ChatTimeline.items(entries, newAfter: "r1")) ==
                ["prompt:p", "reply:r1", "new:Ran 1 command · edited 1 file · 1 reply", "tools:t1,t2", "reply:r2"])
        #expect(shape(ChatTimeline.items(entries, newAfter: "r2")).contains { $0.hasPrefix("new:") } == false)
        #expect(shape(ChatTimeline.items(entries, newAfter: "gone")).contains { $0.hasPrefix("new:") } == false)
    }

    @Test func aMarkerInsideAToolRunSplitsIt() {
        let entries = [tool("t1", "Bash"), tool("t2", "Bash")]
        #expect(shape(ChatTimeline.items(entries, newAfter: "t1")) == ["tools:t1", "new:Ran 1 command", "tools:t2"])
    }

    @Test func searchFindsPromptsRepliesAndToolsIgnoringCase() {
        let entries = [prompt("p", "Deploy the SITE"), reply("r", "Done deploying"), tool("t", "Bash", .command("npm run deploy"), title: "Ship"),
                       reply("r2", "unrelated")]
        let items = ChatTimeline.items(entries, newAfter: nil)
        #expect(ChatSearch.matches(items, query: "deploy") == ["p", "r", ChatItem.toolsID("t")])
        #expect(ChatSearch.matches(items, query: "  ").isEmpty)
    }

    @Test func composerTextIsCleanedAndSentAsAPasteWhenPossible() {
        let start: [UInt8] = [27, 91, 50, 48, 48, 126], end: [UInt8] = [27, 91, 50, 48, 49, 126]
        let pasted = ComposerText.writes("line one\r\nline\u{1b}[201~ two\t\n\n", bracketed: true)
        #expect(pasted.count == 2)
        #expect(pasted[0].bytes == start + Array("line one\nline[201~ two".utf8) + end)
        #expect(pasted[1] == HostInput.Write(bytes: [13], delay: 0.06))
        let typed = ComposerText.writes("a\nb\tc", bracketed: false)
        #expect(typed.map(\.bytes) == [Array("a b c".utf8), [13]])
        #expect(ComposerText.writes(" \n\u{7}", bracketed: true).isEmpty)
    }
}

struct ChatWindowTests {
    func items(_ count: Int) -> [ChatItem] {
        (0..<count).map { ChatItem.tools(id: "t\($0)", []) }
    }

    @Test func onlyTheNewestItemsAreShown() {
        let all = items(500)
        let window = ChatWindow.shown(all, limit: 120, including: nil)
        #expect(window.items.count == 120)
        #expect(window.items.first?.id == "t380")
        #expect(window.hidden == 380)
        #expect(ChatWindow.shown(items(50), limit: 120, including: nil).hidden == 0)
    }

    @Test func aWantedItemWidensTheWindow() {
        let all = items(500)
        // A search match, or where you were reading: shown, with a little before it.
        let window = ChatWindow.shown(all, limit: 120, including: "t100")
        #expect(window.items.contains { $0.id == "t100" })
        #expect(window.items.last?.id == "t499")
        #expect(window.hidden <= 100)
        #expect(ChatWindow.shown(all, limit: 120, including: "missing").hidden == 380)
    }
}

struct ChatStagingTests {
    func items(_ count: Int) -> [ChatItem] {
        (0..<count).map { ChatItem.tools(id: "t\($0)", []) }
    }

    func ids(_ items: [ChatItem]) -> [String] { items.map(\.id) }

    @Test func anEarlierPageFillsInUnderItsFirstRows() {
        // 240 items, 60 shown (180...239); Show earlier: the window starts at 120.
        let all = items(240)
        let window = ChatWindow.shown(all, limit: 120, including: nil).items
        var staging = ChatStaging.page(start: 120, previous: 180)
        var turns = [ids(ChatWindow.visible(window, staging: staging))]
        while !staging.isDone {
            staging.step()
            turns.append(ids(ChatWindow.visible(window, staging: staging)))
        }
        #expect(turns.count == 3)
        // At once: the page's first rows, at the top where the view is, then the rows that were shown.
        #expect(turns[0] == (120..<140).map { "t\($0)" } + (180..<240).map { "t\($0)" })
        // Each turn adds the next rows under those, never anything above them: the first rows never move.
        for (before, after) in zip(turns, turns.dropFirst()) {
            #expect(Array(after.prefix(20)) == Array(before.prefix(20)))
            #expect(Array(after.suffix(60)) == Array(before.suffix(60)))
            #expect(after.count == before.count + 20)
        }
        #expect(turns.last == ids(Array(window)))
        // A short page (the conversation's first rows): all of it at once.
        #expect(ChatStaging.page(start: 0, previous: 18).isDone)
        #expect(ChatStaging.page(start: 0, previous: 40).below == 20..<40)
    }

    @Test func theRowsComeInBlocksThatKeepTheirNumber() {
        let all = items(247)
        // 120 shown: 127...246, in blocks 2 (127...179), 3 (180...239) and 4 (240...246).
        let window = ChatWindow.shown(all, limit: 120, including: nil).items
        let chunks = ChatWindow.chunks(window, staging: nil)
        #expect(chunks.map(\.id) == [2, 3, 4])
        #expect(chunks.map(\.items.count) == [53, 60, 7])
        #expect(chunks.flatMap(\.items) == Array(window))
        // A page filling in changes only the block it fills in: the others are the same values.
        var staging = ChatStaging.page(start: 127, previous: 187)
        let before = ChatWindow.chunks(window, staging: staging)
        staging.step()
        let after = ChatWindow.chunks(window, staging: staging)
        #expect(before.map(\.id) == [2, 3, 4] && after.map(\.id) == [2, 3, 4])
        #expect(before[0] != after[0] && before[1] == after[1] && before[2] == after[2])
        #expect(ChatWindow.visible(window, staging: staging) == after.flatMap(\.items))
    }

    @Test func anOpenComesNewestFirst() {
        let all = items(240)
        let window = ChatWindow.shown(all, limit: 60, including: nil).items
        var staging = ChatStaging.open(start: 180, end: 240)
        #expect(ids(ChatWindow.visible(window, staging: staging)) == (220..<240).map { "t\($0)" })
        staging.step()
        #expect(ids(ChatWindow.visible(window, staging: staging)) == (200..<240).map { "t\($0)" })
        var turns = 1
        while !staging.isDone { staging.step(); turns += 1 }
        #expect(turns == 2)
        #expect(ChatWindow.visible(window, staging: staging).count == 60)
        // Fewer rows than a turn adds: all at once.
        #expect(ChatStaging.open(start: 222, end: 240).isDone)
        #expect(ChatWindow.visible(window, staging: nil).count == 60)
    }
}

struct ChatScrollPlaceTests {
    @Test func theAnchorIsTheItemAtTheTopOfTheView() {
        let tops: [String: Double] = ["a": 0, "b": 120, "c": 400, "d": 900]
        #expect(ChatWindow.anchor(tops: tops, visibleTop: 0) == "a")
        #expect(ChatWindow.anchor(tops: tops, visibleTop: 300) == "b")   // b runs from 120 past 300
        #expect(ChatWindow.anchor(tops: tops, visibleTop: 400) == "c")
        #expect(ChatWindow.anchor(tops: tops, visibleTop: 5_000) == "d")
        #expect(ChatWindow.anchor(tops: [:], visibleTop: 10) == nil)
    }

    @Test func atTheEndWithinASmallMargin() {
        #expect(ChatWindow.atEnd(contentHeight: 2_000, visibleBottom: 2_000))
        #expect(ChatWindow.atEnd(contentHeight: 2_000, visibleBottom: 1_980))
        #expect(!ChatWindow.atEnd(contentHeight: 2_000, visibleBottom: 1_800))
        // Shorter than the view: everything, the end included, is on screen.
        #expect(ChatWindow.atEnd(contentHeight: 300, visibleBottom: 900))
    }
}
