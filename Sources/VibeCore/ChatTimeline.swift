import Foundation

/// What the chat shows, in order: tool calls between two messages fold into one item.
public enum ChatItem: Equatable, Sendable, Identifiable {
    case prompt(ChatEntry)
    case reply(ChatEntry)
    case tools(id: String, [ChatTool])
    /// A message VibeSwitcher handed over (a report, an audit, a notice, the user's words relayed): shown as a card
    /// under its sender, not as a prompt.
    case team(ChatEntry, TeamMessage)
    /// "New since you looked", with what happened since.
    case newMarker(summary: String)
    /// The lead's board cleared here: every task finished (see `BatchSummary.place`).
    case allDone(LeadAllDone)
    /// One of the lead's questions closed here without your answer (withdrawn, or its timer ran out): its history,
    /// where it happened, and what became of an answer that came too late (see `ChatTimeline.placeQuestions`).
    case question(LeadQuestion, notice: String?)

    public static func toolsID(_ firstToolID: String) -> String { "tools:\(firstToolID)" }

    public var id: String {
        switch self {
        case .prompt(let entry), .reply(let entry), .team(let entry, _): return entry.id
        case .tools(let id, _): return id
        case .newMarker: return "new-marker"
        case .allDone(let mark): return "all-done:\(mark.id)"
        case .question(let question, _): return "question:\(question.id)"
        }
    }
}

public enum ChatTimeline {
    /// `newAfter`: the id of the last entry you had seen; a marker goes after it when more followed.
    public static func items(_ entries: [ChatEntry], newAfter: String?) -> [ChatItem] {
        let markerAt = newAfter.flatMap { id in entries.firstIndex { $0.id == id } }.flatMap { $0 < entries.count - 1 ? $0 : nil }
        var items: [ChatItem] = []
        var run: [ChatTool] = []
        func flush() {
            if let first = run.first { items.append(.tools(id: ChatItem.toolsID(first.id), run)) }
            run = []
        }
        for (index, entry) in entries.enumerated() {
            switch entry.kind {
            // A message with nothing to show between two tool runs would split them in two rows: it's left out.
            case .prompt(let text, let images) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty && entry.team == nil:
                break
            case .reply(let text) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                break
            case .prompt, .steered:
                flush()
                items.append(entry.team.map { .team(entry, $0) } ?? .prompt(entry))
            case .reply: flush(); items.append(.reply(entry))
            case .tool(let tool): run.append(tool)
            }
            if index == markerAt {
                flush()
                items.append(.newMarker(summary: summary(of: Array(entries[(index + 1)...]))))
            }
        }
        flush()
        return items
    }

    /// `items` with `extras` placed by time: each before the first item that came after it. One from before the first
    /// item is left out (an earlier part of the conversation, or another session's), and nothing shows in a conversation
    /// with no items yet.
    public static func place(_ extras: [(at: Double, item: ChatItem)], in items: [ChatItem]) -> [ChatItem] {
        guard !extras.isEmpty, let first = items.lazy.compactMap(time).first else { return items }
        var pending = extras.filter { $0.at >= first }.sorted { $0.at < $1.at }[...]
        guard !pending.isEmpty else { return items }
        var placed: [ChatItem] = []
        placed.reserveCapacity(items.count + pending.count)
        for item in items {
            if let at = time(item) {
                while let extra = pending.first, extra.at < at {
                    placed.append(extra.item)
                    pending = pending.dropFirst()
                }
            }
            placed.append(item)
        }
        placed += pending.map(\.item)
        return placed
    }

    /// The lead's questions that closed without your answer (withdrawn, or decided when their timer ran out), each
    /// where it closed: it leaves the stack under the chat, which holds only open ones, for the conversation's history.
    /// An answered one needs none: your answer is in the conversation already, relayed with the question it answers.
    /// `notices`: what became of a late answer, by question id.
    public static func placeQuestions(_ questions: [LeadQuestion], notices: [String: String] = [:], in items: [ChatItem]) -> [ChatItem] {
        place(questions.compactMap { question in closed(question).map { ($0, ChatItem.question(question, notice: notices[question.id])) } },
              in: items)
    }

    /// When a question closed without an answer; nil for an open or answered one.
    static func closed(_ question: LeadQuestion) -> Double? {
        switch question.state {
        case .withdrawn: return question.withdrawnAt
        case .autoDecided: return question.autoDecidedAt
        case .open, .answered: return nil
        }
    }

    /// When an item happened (seconds since 1970), when it says.
    static func time(_ item: ChatItem) -> Double? {
        switch item {
        case .prompt(let entry), .reply(let entry), .team(let entry, _): return entry.at?.timeIntervalSince1970
        case .tools(_, let tools): return tools.first?.at?.timeIntervalSince1970
        // Placed ones by their own time, so what's placed after them goes in order with them.
        case .allDone(let mark): return mark.at
        case .question(let question, _): return closed(question)
        case .newMarker: return nil
        }
    }

    /// "Ran 3 commands · edited 2 files · read 4 files · searched twice · used 1 tool · 1 failed".
    public static func summary(_ tools: [ChatTool]) -> String {
        var commands = 0, searches = 0, others = 0, failed = 0, thoughts = 0, todoUpdates = 0, plans = 0
        var edited = Set<String>(), read = Set<String>()
        for tool in tools {
            if tool.result?.failed == true { failed += 1 }
            switch (tool.name, tool.detail) {
            case (_, .thought): thoughts += 1
            case (_, .todos), ("TaskCreate", _), ("TaskUpdate", _): todoUpdates += 1
            case (_, .plan): plans += 1
            case (_, .edit(let path, _)), (_, .write(let path, _)): edited.insert(path)
            case (_, .patch): edited.insert(tool.id)
            case (_, .read(let path)): read.insert(path)
            case (_, .command): commands += 1
            case ("Bash", _), ("shell", _), ("local_shell", _), ("exec_command", _), ("exec", _): commands += 1
            case ("Edit", _), ("MultiEdit", _), ("Write", _), ("NotebookEdit", _), ("apply_patch", _): edited.insert(tool.id)
            case ("Read", _): read.insert(tool.id)
            case ("Grep", _), ("Glob", _), ("WebSearch", _), ("ToolSearch", _): searches += 1
            default: others += 1
            }
        }
        var parts: [String] = []
        if commands > 0 { parts.append("ran \(count(commands, "command"))") }
        if !edited.isEmpty { parts.append("edited \(count(edited.count, "file"))") }
        if !read.isEmpty { parts.append("read \(count(read.count, "file"))") }
        if searches > 0 { parts.append("searched \(searches == 1 ? "once" : searches == 2 ? "twice" : "\(searches) times")") }
        if others > 0 { parts.append("used \(count(others, "tool"))") }
        if todoUpdates > 0 { parts.append("updated the to-dos") }
        if plans > 0 { parts.append("wrote a plan") }
        if failed > 0 { parts.append("\(failed) failed") }
        if parts.isEmpty, thoughts > 0 { return "Thought" }
        return capitalized(parts.joined(separator: " · "))
    }

    /// What a run of entries holds: its tools' summary plus the number of replies.
    static func summary(of entries: [ChatEntry]) -> String {
        let tools = entries.compactMap { entry -> ChatTool? in if case .tool(let tool) = entry.kind { return tool } else { return nil } }
        let replies = entries.filter { if case .reply = $0.kind { return true } else { return false } }.count
        var parts = [summary(tools)].filter { !$0.isEmpty }
        if replies > 0 { parts.append(replies == 1 ? "1 reply" : "\(replies) replies") }
        return capitalized(parts.joined(separator: " · "))
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private static func capitalized(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
}

public enum ChatSearch {
    /// Ids of the items containing `query` (prompts, replies, tool titles and commands), ignoring case.
    public static func matches(_ items: [ChatItem], query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return items.filter { item in
            switch item {
            case .team(_, let message):
                return message.title.localizedCaseInsensitiveContains(needle) || message.body.localizedCaseInsensitiveContains(needle)
            case .prompt(let entry), .reply(let entry):
                switch entry.kind {
                case .prompt(let text, _), .reply(let text), .steered(let text, _): return text.localizedCaseInsensitiveContains(needle)
                case .tool: return false
                }
            case .tools(_, let tools):
                return tools.contains { tool in
                    if tool.title.localizedCaseInsensitiveContains(needle) { return true }
                    if case .command(let command) = tool.detail { return command.localizedCaseInsensitiveContains(needle) }
                    return false
                }
            case .newMarker:
                return false
            case .question(let question, let notice):
                return ([question.text, question.withdrawReason ?? "", question.proposal ?? "", notice ?? ""]).contains { $0.localizedCaseInsensitiveContains(needle) }
            case .allDone(let mark):
                let summary = mark.summary.map { [$0.headline] + $0.bullets } ?? []
                return (["All tasks finished"] + summary + mark.tasks.map(\.title)).contains { $0.localizedCaseInsensitiveContains(needle) }
            }
        }.map(\.id)
    }
}

/// What the composer writes into a session's terminal.
public enum ComposerText {
    static let pasteStart: [UInt8] = [27, 91, 50, 48, 48, 126]   // ESC [ 200 ~
    static let pasteEnd: [UInt8] = [27, 91, 50, 48, 49, 126]     // ESC [ 201 ~

    /// The message, then Enter 60 ms later. `bracketed`: the program asked for bracketed paste, so the text goes
    /// as one paste and keeps its newlines; otherwise newlines and tabs become spaces (each would act as a key).
    /// Control characters (ESC included) are dropped, so the text can't end the paste or move the cursor.
    public static func writes(_ text: String, bracketed: Bool) -> [HostInput.Write] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var clean = String(String.UnicodeScalarView(normalized.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        }))
        while let last = clean.last, last.isWhitespace { clean.removeLast() }
        guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let body: [UInt8]
        if bracketed {
            body = pasteStart + Array(clean.utf8) + pasteEnd
        } else {
            body = Array(clean.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ").utf8)
        }
        return [HostInput.Write(bytes: body, delay: 0), HostInput.Write(bytes: [13], delay: 0.06)]
    }

    /// The extensions Claude Code reads a pasted path as an image by (others it takes as text at once).
    public static let pastedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// Whether Claude Code's input box (`box`: what's typed in it, see `LeadDelivery.box`) shows the `images` pasted
    /// into it as taken: each as its `[Image #N]`, or as its path (one it couldn't read goes in as text). Claude reads
    /// a pasted image path in the background, puts the images and the rest of the paste in only then, and drops an
    /// Enter that came meanwhile (2.1.310's paste handler): the message's Enter waits for this. Spaces don't count (a
    /// long box wraps).
    public static func imagesTaken(_ box: String, images: [String]) -> Bool {
        let shown = box.filter { !$0.isWhitespace }
        let placeholders = shown.components(separatedBy: "[Image#").count - 1
        let paths = images.filter { shown.contains($0.filter { !$0.isWhitespace }) }.count
        return !images.isEmpty && placeholders + paths >= images.count
    }
}

/// The part of a conversation the chat lays out: the newest items. A long session has thousands, and every one
/// shown is laid out.
public enum ChatWindow {
    public static let page = 60

    /// The newest `limit` items, widened to reach `including` (a search match, where you were reading) with a few
    /// items of context before it. `hidden`: how many earlier items aren't shown.
    public static func shown(_ items: [ChatItem], limit: Int, including wanted: String?) -> (items: ArraySlice<ChatItem>, hidden: Int) {
        var start = max(0, items.count - limit)
        if let wanted, let index = items.firstIndex(where: { $0.id == wanted }), index < start {
            start = max(0, index - 5)
        }
        return (items[start...], start)
    }

    /// The window's items without the rows `staging` still holds back.
    public static func visible(_ window: ArraySlice<ChatItem>, staging: ChatStaging?) -> [ChatItem] {
        chunks(window, staging: staging).flatMap(\.items)
    }

    /// A run of the window's items in one block of `size` (by index, counted from the conversation's first: a block
    /// keeps its number as the window grows earlier or later).
    public struct Chunk: Equatable, Sendable, Identifiable {
        public let id: Int
        public let items: [ChatItem]
    }

    /// The window's items shown, `staging` holding some back, in blocks of `size` (see `Chunk`): the chat lays out each
    /// block as a unit, so a page filling in or a line arriving redoes one block, not every row shown.
    public static func chunks(_ window: ArraySlice<ChatItem>, staging: ChatStaging?, size: Int = page) -> [Chunk] {
        var chunks: [Chunk] = []
        var current: (id: Int, items: [ChatItem])?
        for index in window.indices where staging.map({ !$0.holds(index) }) ?? true {
            let id = index / size
            if current?.id != id {
                if let current { chunks.append(Chunk(id: current.id, items: current.items)) }
                current = (id, [])
            }
            current?.items.append(window[index])
        }
        if let current { chunks.append(Chunk(id: current.id, items: current.items)) }
        return chunks
    }

    /// The item at the top of the view: the last one starting at or above `visibleTop` (positions from the top of
    /// the content).
    public static func anchor(tops: [String: Double], visibleTop: Double) -> String? {
        let above = tops.filter { $0.value <= visibleTop + 1 }
        return (above.isEmpty ? tops.min { $0.value < $1.value } : above.max { $0.value < $1.value })?.key
    }

    /// Whether the end of the content is on screen (within a few points).
    public static func atEnd(contentHeight: Double, visibleBottom: Double) -> Bool {
        visibleBottom >= contentHeight - 24
    }
}

/// The rows of the chat's window still to be laid out: a few more each turn of the run loop, so that opening a
/// conversation or showing an earlier page doesn't hold the main thread for all of its rows at once (60 new rows took
/// it 0.1-0.15 s, ~1.7 ms a row however simple). A page shown earlier fills in under its first rows, which are where the
/// view is (at the top) and don't move: the rest arrive below the fold. An opened conversation is laid out out of sight
/// and shown once all of it is, where it opens (`ChatModel.assembling`). Item indices.
public struct ChatStaging: Equatable, Sendable {
    /// How many rows a turn adds: on the chat bench's rows ~0.04 s of the main thread's time a turn (in 10s, 0.03 s, but
    /// each turn's own update of the window cost a page 20-40% more in all; in 20s it costs what one turn did). 14 since
    /// a prompt's and a reply's text is a text view of its own (`ChatMessageText`): a row costs a turn more, and a page's
    /// costliest turn was 0.060 s at 14 against 0.065-0.080 s at 20 (the chat bench's median, 2026-10-20 and -21).
    public static let batch = 14

    /// Still to come under the rows shown, added from the top down.
    public private(set) var below: Range<Int>
    /// Still to come over the rows shown, added from the bottom up.
    public private(set) var above: Range<Int>

    public var isDone: Bool { below.isEmpty && above.isEmpty }

    /// Whether item `index` is held back.
    public func holds(_ index: Int) -> Bool { below.contains(index) || above.contains(index) }

    /// The next turn: up to `count` more rows, those below first.
    public mutating func step(_ count: Int = batch) {
        if !below.isEmpty {
            below = min(below.upperBound, below.lowerBound + count)..<below.upperBound
        } else if !above.isEmpty {
            above = above.lowerBound..<max(above.lowerBound, above.upperBound - count)
        }
    }

    /// An earlier page: the window now starts at `start` and started at `previous`. Its first rows come at once (they
    /// are where the view is, at the top), the rest of it under them.
    public static func page(start: Int, previous: Int, batch: Int = batch) -> ChatStaging {
        let first = min(previous, start + batch)
        return ChatStaging(below: first..<max(first, previous), above: 0..<0)
    }

    /// A conversation opened on the window `start..<end`: the newest rows at once, then those over them.
    public static func open(start: Int, end: Int, batch: Int = batch) -> ChatStaging {
        ChatStaging(below: end..<end, above: start..<max(start, end - batch))
    }
}
