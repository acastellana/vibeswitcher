import Foundation

/// The conversation as Markdown, for Export Chat.
public enum ChatExport {
    public static func markdown(_ entries: [ChatEntry], agent: String) -> String {
        var parts: [String] = []
        var run: [ChatTool] = []
        func flush() {
            let summary = ChatTimeline.summary(run)
            if !run.isEmpty, !summary.isEmpty { parts.append("> \(summary)") }
            run = []
        }
        for entry in entries {
            switch entry.kind {
            case .prompt(let text, let images):
                flush()
                parts.append("**You**\n\n" + text + (images.isEmpty ? "" : "\n\n_(\(images.count) image\(images.count == 1 ? "" : "s"))_"))
            case .steered(let text, let fromLead):
                flush()
                parts.append("**\(fromLead ? "Project lead" : "You") (while it worked)**\n\n" + text)
            case .reply(let text):
                flush()
                parts.append("**\(agent)**\n\n" + text)
            case .tool(let tool):
                run.append(tool)
            }
        }
        flush()
        return parts.joined(separator: "\n\n") + "\n"
    }
}

/// A message you sent that the transcript doesn't show yet (the agent queues it while it works).
public struct PendingMessage: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var text: String
    /// How many prompts the conversation had when it was sent.
    public var afterPrompts: Int
    /// Typed into an idle agent: it shows in the conversation within seconds (a queued one waits for the turn).
    public var expectsSoon: Bool
    public var sentAt: Date

    public init(text: String, afterPrompts: Int, expectsSoon: Bool = false, sentAt: Date = Date()) {
        self.text = text
        self.afterPrompts = afterPrompts
        self.expectsSoon = expectsSoon
        self.sentAt = sentAt
    }

    /// Should be in the conversation by now and isn't: the keys may not have reached the agent.
    public func late(at now: Date = Date()) -> Bool {
        expectsSoon && !text.hasPrefix("/") && now.timeIntervalSince(sentAt) > 15
    }

    /// Those not yet among the prompts that came after them.
    public static func remaining(_ pending: [PendingMessage], prompts: [String]) -> [PendingMessage] {
        var used = Set<Int>()
        return pending.filter { message in
            let wanted = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            for index in prompts.indices where index >= message.afterPrompts && !used.contains(index) {
                if prompts[index].trimmingCharacters(in: .whitespacesAndNewlines) == wanted {
                    used.insert(index)
                    return false
                }
            }
            return true
        }
    }
}

/// File paths written as inline code in replies (`Sources/App.swift:42`), turned into links when the file exists.
public enum PathLinks {
    public static func target(_ code: String, cwd: String?, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        var text = code.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count < 400, !text.contains(" "), text.contains("/") || text.contains(".") else { return nil }
        // Drop ":line" and ":line:column".
        while let colon = text.lastIndex(of: ":"), text[text.index(after: colon)...].allSatisfy(\.isNumber),
              text.index(after: colon) < text.endIndex {
            text = String(text[..<colon])
        }
        let path: String
        if text.hasPrefix("~/") { path = NSHomeDirectory() + text.dropFirst(1) }
        else if text.hasPrefix("/") { path = text }
        else if let cwd { path = (cwd as NSString).appendingPathComponent(text) }
        else { return nil }
        let standard = (path as NSString).standardizingPath
        return exists(standard) ? standard : nil
    }
}
