import CoreGraphics
import Foundation

/// Where a session's terminal sits on screen: its window's frame (top-left origin, as Terminal reports
/// it) and the tab's position within that window.
public struct ScreenPosition: Equatable, Sendable {
    public let frame: CGRect
    public let tabIndex: Int
    /// Desktop (Space) number, 1-based like Mission Control; nil when it can't be determined.
    public var desktop: Int?
    /// The window is in its own full-screen space.
    public var fullscreen = false

    public init(frame: CGRect, tabIndex: Int, desktop: Int? = nil) {
        self.frame = frame
        self.tabIndex = tabIndex
        self.desktop = desktop
    }

    public func withTabIndex(_ index: Int) -> ScreenPosition {
        var copy = ScreenPosition(frame: frame, tabIndex: index, desktop: desktop)
        copy.fullscreen = fullscreen
        return copy
    }
}

public enum SessionOrder: String, CaseIterable, Sendable {
    /// Desktop by desktop (1, 2, 3… as in Mission Control), and within a desktop in reading order
    /// of the windows, so the dots follow ⌃← / ⌃→.
    case screen
    /// Oldest session first; positions never move.
    case started

    public var label: String {
        switch self {
        case .screen: return "By desktop and window position"
        case .started: return "Oldest first"
        }
    }
}

public enum SessionOrdering {
    /// Decides the order of the dots in the menu bar and the rows in the popover, which also defines
    /// the 1–9 keyboard shortcuts.
    public static func sort(_ sessions: [Session], by order: SessionOrder = .screen) -> [Session] {
        let byStart = sessions.sorted { ($0.startedAt, $0.tty) < ($1.startedAt, $1.tty) }
        guard order == .screen else { return byStart }

        // Sessions we can't place (other terminal apps, tab not found) keep their start order, at the end.
        let placed = byStart.filter { $0.screenPosition != nil }
        let unplaced = byStart.filter { $0.screenPosition == nil }
        let desktops = Dictionary(grouping: placed) { $0.screenPosition?.desktop ?? Int.max }
        return desktops.keys.sorted().flatMap { readingOrder(desktops[$0]!) } + unplaced
    }

    /// Top-to-bottom rows, left to right within a row; windows whose top edges are close count as one
    /// row (side-by-side tiles rarely line up to the point). Tabs of one window stay in tab order.
    static func readingOrder(_ sessions: [Session], rowTolerance: CGFloat = 80) -> [Session] {
        let byTop = sessions.sorted { $0.screenPosition!.frame.minY < $1.screenPosition!.frame.minY }
        var rows: [[Session]] = []
        for session in byTop {
            let top = session.screenPosition!.frame.minY
            if let rowTop = rows.last?.first?.screenPosition?.frame.minY, top - rowTop <= rowTolerance {
                rows[rows.count - 1].append(session)
            } else {
                rows.append([session])
            }
        }
        return rows.flatMap { row in
            row.sorted { a, b in
                let pa = a.screenPosition!, pb = b.screenPosition!
                if pa.frame.minX != pb.frame.minX { return pa.frame.minX < pb.frame.minX }
                if pa.frame.minY != pb.frame.minY { return pa.frame.minY < pb.frame.minY }
                if pa.tabIndex != pb.tabIndex { return pa.tabIndex < pb.tabIndex }
                return (a.startedAt, a.tty) < (b.startedAt, b.tty)
            }
        }
    }
}

/// A short human description of the tool call a session is running, e.g. "Run unit tests",
/// "npm test", "Edit Package.swift".
public enum ToolActivity {
    public static func describe(toolName: String, input: [String: Any]) -> String {
        func text(_ key: String) -> String? {
            if let value = input[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
            if let parts = input[key] as? [String], !parts.isEmpty { return parts.joined(separator: " ") } // Codex argv
            return nil
        }
        func file(_ key: String) -> String? { text(key).map { ($0 as NSString).lastPathComponent } }

        let detail: String?
        switch toolName {
        case "Bash", "shell", "local_shell", "exec_command", "container.exec":
            // Claude's own one-line description reads better than the raw command when present.
            detail = text("description") ?? text("command").map(firstLine) ?? text("cmd").map(firstLine)
            return clip(detail ?? toolName)
        case "Read": detail = file("file_path").map { "Read \($0)" }
        case "Edit", "MultiEdit": detail = file("file_path").map { "Edit \($0)" }
        case "Write": detail = file("file_path").map { "Write \($0)" }
        case "NotebookEdit": detail = file("notebook_path").map { "Edit \($0)" }
        case "Grep": detail = text("pattern").map { "Search “\($0)”" }
        case "Glob": detail = text("pattern").map { "Find \($0)" }
        case "WebFetch": detail = text("url").map { "Fetch \(URL(string: $0)?.host ?? $0)" }
        case "WebSearch": detail = text("query").map { "Search web: \($0)" }
        case "Task", "Agent": detail = text("description").map { "Agent: \($0)" }
        case "apply_patch": detail = "Apply patch"
        default:
            // MCP tools: "mcp__server__tool_name" → "tool name (server)"
            let parts = toolName.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" {
                detail = "\(parts[2...].joined(separator: " ").replacingOccurrences(of: "_", with: " ")) (\(parts[1]))"
            } else {
                detail = nil
            }
        }
        return clip(detail ?? toolName)
    }

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    static func clip(_ text: String, to limit: Int = 70) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

/// Terminal's tabs are native macOS window tabs: scripting sees every tab as its own window, and the
/// window server only puts the *visible* tab of a tab group on a desktop. Tabs of one group share the
/// exact same frame, which is how the hidden ones are matched to the visible one.
public enum TabGroups {
    /// Fills in the desktop of windows the window server doesn't place (hidden tabs) from a placed
    /// window with the identical frame (the visible tab of the same group).
    public static func inheritDesktops<Placement>(frames: [Int: CGRect], placed: [Int: Placement]) -> [Int: Placement] {
        var result = placed
        for (id, frame) in frames where placed[id] == nil {
            let sibling = placed.keys.sorted().first { frames[$0] == frame }
            if let sibling { result[id] = placed[sibling] }
        }
        return result
    }
}

extension TabGroups {
    /// Matches tab-bar titles (left to right, one array per window) to Terminal window names and returns
    /// each matched window's 1-based tab position. Names are compared without the activity glyph and
    /// the "— 120×40" size suffix, which change between the two reads.
    public static func tabIndices(windowNames: [Int: String], tabBars: [[String]]) -> [Int: Int] {
        let normalizedNames = windowNames.mapValues(normalize)
        var result: [Int: Int] = [:]
        for bar in tabBars {
            var used: Set<Int> = []
            for (index, title) in bar.enumerated() {
                let wanted = normalize(title)
                guard !wanted.isEmpty else { continue }
                let candidates = normalizedNames.filter { !used.contains($0.key) }
                let exact = candidates.filter { $0.value == wanted }.map(\.key).sorted()
                let loose = candidates.filter { $0.value.hasPrefix(wanted) || wanted.hasPrefix($0.value) }.map(\.key).sorted()
                if let id = exact.first ?? (loose.count == 1 ? loose.first : nil) {
                    used.insert(id)
                    result[id] = index + 1
                }
            }
        }
        return result
    }

    static func normalize(_ title: String) -> String {
        var text = title
        if let size = text.range(of: #"\s*—\s*\d+×\d+\s*$"#, options: .regularExpression) { text.removeSubrange(size) }
        let glyphs = CharacterSet(charactersIn: "✳◐◓◑◒·✢✶✻✽*").union(CharacterSet(charactersIn: "\u{2800}"..."\u{28FF}"))
        text = String(String.UnicodeScalarView(text.unicodeScalars.filter { !glyphs.contains($0) }))
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
