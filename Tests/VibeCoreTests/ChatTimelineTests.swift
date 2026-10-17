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
