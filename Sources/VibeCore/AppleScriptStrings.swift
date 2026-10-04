import Foundation

/// AppleScript results read in `osascript -s s` form: a list of strings as AppleScript source, with
/// quotes and backslashes escaped. Text from a tab (a title, screen output) can contain any character,
/// including whatever a hand-rolled separator would be; inside quotes it can't end its own field.
public enum AppleScriptStrings {
    /// The strings of `{"a", "b"}`, or nil for anything else (a number, a nested list, bad quoting).
    public static func parse(_ output: String) -> [String]? {
        let scalars = Array(output.unicodeScalars)
        var index = 0
        func skipSpaces() { while index < scalars.count, scalars[index] == " " || scalars[index] == "\n" { index += 1 } }
        skipSpaces()
        guard index < scalars.count, scalars[index] == "{" else { return nil }
        index += 1
        var strings: [String] = []
        skipSpaces()
        if index < scalars.count, scalars[index] == "}" {
            index += 1
        } else {
            while true {
                guard index < scalars.count, scalars[index] == "\"" else { return nil }
                index += 1
                var value = String.UnicodeScalarView()
                var closed = false
                while index < scalars.count {
                    let scalar = scalars[index]
                    index += 1
                    if scalar == "\"" { closed = true; break }
                    if scalar == "\\" {
                        guard index < scalars.count else { return nil }
                        let escaped = scalars[index]
                        index += 1
                        switch escaped {
                        case "\"", "\\": value.append(escaped)
                        case "n": value.append("\n")
                        case "r": value.append("\r")
                        case "t": value.append("\t")
                        default: return nil
                        }
                    } else {
                        value.append(scalar)
                    }
                }
                guard closed else { return nil }
                strings.append(String(value))
                skipSpaces()
                guard index < scalars.count else { return nil }
                if scalars[index] == "}" { index += 1; break }
                guard scalars[index] == "," else { return nil }
                index += 1
                skipSpaces()
            }
        }
        skipSpaces()
        return index == scalars.count ? strings : nil
    }
}

/// One Terminal tab as `TerminalBridge.tabs` reads it: eight strings per tab.
public struct TerminalTabRecord: Equatable, Sendable {
    public var windowID: Int
    public var tabIndex: Int
    public var tty: String
    public var isSelected: Bool
    public var windowOrder: Int
    /// "left, top, right, bottom"
    public var bounds: String
    public var windowName: String
    public var title: String
}

public enum TerminalTabRecords {
    public static let fieldsPerTab = 8

    /// Nil unless the fields come in whole records. A tty listed twice is ambiguous and dropped.
    public static func parse(_ fields: [String]) -> [TerminalTabRecord]? {
        guard fields.count % fieldsPerTab == 0 else { return nil }
        var records: [TerminalTabRecord] = []
        for start in stride(from: 0, to: fields.count, by: fieldsPerTab) {
            let f = Array(fields[start..<start + fieldsPerTab])
            let tty = f[2].replacingOccurrences(of: "/dev/", with: "")
            guard tty.range(of: #"^ttys[0-9]{1,4}$"#, options: .regularExpression) != nil,
                  let windowID = Int(f[0]), let tabIndex = Int(f[1]), let order = Int(f[4]) else { continue }
            records.append(TerminalTabRecord(windowID: windowID, tabIndex: tabIndex, tty: tty, isSelected: f[3] == "true",
                                             windowOrder: order, bounds: f[5], windowName: f[6], title: f[7]))
        }
        let counts = Dictionary(grouping: records, by: \.tty).mapValues(\.count)
        return records.filter { counts[$0.tty] == 1 }
    }
}
