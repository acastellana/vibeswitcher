import Foundation

/// What the chat shows, in order: tool calls between two messages fold into one item.
public enum ChatItem: Equatable, Sendable, Identifiable {
    case prompt(ChatEntry)
    case reply(ChatEntry)
    case tools(id: String, [ChatTool])
    /// "New since you looked", with what happened since.
    case newMarker(summary: String)

    public static func toolsID(_ firstToolID: String) -> String { "tools:\(firstToolID)" }

    public var id: String {
        switch self {
        case .prompt(let entry), .reply(let entry): return entry.id
        case .tools(let id, _): return id
        case .newMarker: return "new-marker"
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
            case .prompt, .steered: flush(); items.append(.prompt(entry))
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

    /// "Ran 3 commands · edited 2 files · read 4 files · searched twice · used 1 tool · 1 failed".
    public static func summary(_ tools: [ChatTool]) -> String {
        var commands = 0, searches = 0, others = 0, failed = 0, thoughts = 0, todoUpdates = 0, plans = 0
        var edited = Set<String>(), read = Set<String>()
        for tool in tools {
            if tool.result?.failed == true { failed += 1 }
            switch (tool.name, tool.detail) {
            case (_, .thought): thoughts += 1
            case (_, .todos): todoUpdates += 1
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
}

/// The part of a conversation the chat lays out: the newest items. A long session has thousands, and every one
/// shown is laid out.
public enum ChatWindow {
    public static let page = 120

    /// The newest `limit` items, widened to reach `including` (a search match, where you were reading) with a few
    /// items of context before it. `hidden`: how many earlier items aren't shown.
    public static func shown(_ items: [ChatItem], limit: Int, including wanted: String?) -> (items: ArraySlice<ChatItem>, hidden: Int) {
        var start = max(0, items.count - limit)
        if let wanted, let index = items.firstIndex(where: { $0.id == wanted }), index < start {
            start = max(0, index - 5)
        }
        return (items[start...], start)
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
