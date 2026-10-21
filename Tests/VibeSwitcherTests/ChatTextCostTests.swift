import AppKit
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher
/// What a page of the chat bench's rows (30 prompts and their replies) costs to lay out and draw: as one selectable text
/// per message (`ChatMessageText`), and as before, a prompt's Text and a reply's `MarkdownView` (a Text per paragraph),
/// in turns, 8 times each, medians printed. Only with `CHAT_TEXT_COST=1` (it times, and a busy Mac moves the numbers).
@MainActor
@Suite(.serialized)
struct ChatTextCostTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHAT_TEXT_COST"] != nil)) func aPageAsOneTextPerMessage() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/chat-bench.jsonl")
        var replies: [String] = [], prompts: [String] = []
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let d = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let m = d["message"] as? [String: Any] else { continue }
            if d["type"] as? String == "assistant", let c = m["content"] as? [[String: Any]] {
                for b in c where b["type"] as? String == "text" { replies.append(b["text"] as! String) }
            } else if d["type"] as? String == "user", let c = m["content"] as? String { prompts.append(c) }
        }
        let rows = Array(zip(prompts, replies).prefix(30))  // a page: 60 rows
        func run(_ new: Bool) -> Double {
            let start = Date()
            let content = VStack(alignment: .leading, spacing: 14) {
                ForEach(rows.indices, id: \.self) { i in
                    if new {
                        ChatMessageText(text: rows[i].0, kind: .plain, fontSize: 13.5, hugs: true).padding(.leading, 60)
                        ChatMessageText(text: rows[i].1, kind: .markdown, fontSize: 13.5).frame(maxWidth: .infinity, minHeight: 21, alignment: .topLeading).padding(.leading, 30)
                    } else {
                        Text(rows[i].0).font(.system(size: 13.5)).lineSpacing(2).chatTextSelection().fixedSize(horizontal: false, vertical: true).padding(.leading, 60)
                        MarkdownView(text: rows[i].1).frame(maxWidth: .infinity, minHeight: 21, alignment: .topLeading).padding(.leading, 30)
                    }
                }
            }.frame(width: 724)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 724, height: 10)
            let size = host.fittingSize
            host.frame.size = size
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0, width: 724, height: 800))!
            host.cacheDisplay(in: NSRect(x: 0, y: 0, width: 724, height: 800), to: rep)
            return Date().timeIntervalSince(start) * 1000
        }
        _ = run(false); _ = run(true)  // warm caches, both
        var old: [Double] = [], new: [Double] = []
        for _ in 0..<8 { old.append(run(false)); new.append(run(true)) }
        old.sort(); new.sort()
        print("chat text cost, a page of 60 rows, warm: a Text per paragraph median \(String(format: "%.1f", old[4])) ms \(old.map { Int($0) }), one text per message median \(String(format: "%.1f", new[4])) ms \(new.map { Int($0) })")
    }

    /// A reply (paragraphs, a list, code) coming in 20 tokens (words) an update, 12 updates from its first 2 KB: what each update costs the main thread, made, set, laid out and drawn, against a new text view each time.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHAT_TEXT_COST"] != nil)) func aReplyComingIn() throws {
        let paragraph = "The change keeps each block's text once it's built, so a reply that is still coming in only redoes its last block and the text view replaces only those characters, leaving the layout of everything above alone."
        let code = "```swift\nfunc render(_ blocks: [MDBlock]) -> NSAttributedString {\n    let out = NSMutableAttributedString()\n    for block in blocks { out.append(unit(block)) }\n    return out\n}\n```"
        let reply = [paragraph, "- first point about it\n- second point\n- third point, longer than the others by a few words", code, paragraph, paragraph, paragraph, paragraph, paragraph,
                     paragraph, paragraph, paragraph, paragraph, paragraph, paragraph]
            .joined(separator: "\n\n")
        let words = reply.split(separator: " ", omittingEmptySubsequences: false)
        var cut = 0, chars = 0
        while chars < 2048 { chars += words[cut].count + 1; cut += 1 }
        func prefix(_ count: Int) -> String { words.prefix(count).joined(separator: " ") }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 700, pixelsHigh: 1600, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        func update(_ view: ChatTextView, _ text: String) {
            view.set(ChatTextContent.make(text, kind: .markdown, size: 13.5, folder: nil), runner: nil)
            let size = view.fittingSize(width: 700)
            view.frame = NSRect(x: 0, y: 0, width: 700, height: size.height)
            view.layout()
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        var incremental: [Double] = [], whole: [Double] = []
        let view = ChatTextView()
        update(view, prefix(cut))
        var count = cut
        for _ in 0..<12 {
            count = min(words.count, count + 20)
            let text = prefix(count)
            var start = Date()
            update(view, text)
            incremental.append(Date().timeIntervalSince(start) * 1000)
            let fresh = ChatTextView()
            start = Date()
            // As before: the whole text built again (a new size key), every block, into a new view.
            update(fresh, text + " ")
            whole.append(Date().timeIntervalSince(start) * 1000)
        }
        incremental.sort(); whole.sort()
        print("chat text cost, a reply coming in (from \(prefix(cut).utf8.count) to \(prefix(count).utf8.count) bytes, 20 words an update, 12 updates): median \(String(format: "%.2f", incremental[6])) ms an update \(incremental.map { String(format: "%.1f", $0) }), the whole text again \(String(format: "%.2f", whole[6])) ms")
    }
}
