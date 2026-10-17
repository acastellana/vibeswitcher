import Foundation

/// How the window's terminals look and behave (Settings › Terminal).
public struct TerminalAppearance: Codable, Equatable, Sendable {
    public enum Theme: String, Codable, CaseIterable, Sendable {
        case system, light, dark, solarizedLight, solarizedDark, custom

        public var label: String {
            switch self {
            case .system: return "Match System"
            case .light: return "Light"
            case .dark: return "Dark"
            case .solarizedLight: return "Solarized Light"
            case .solarizedDark: return "Solarized Dark"
            case .custom: return "Custom"
            }
        }
    }

    public enum CursorShape: String, Codable, CaseIterable, Sendable { case block, underline, bar }
    public enum Bell: String, Codable, CaseIterable, Sendable { case none, visual, sound }

    public static let defaultFontSize: Double = 13
    public static let fontSizeRange: ClosedRange<Double> = 8...36

    /// Empty: the system's monospaced font (SF Mono).
    public var fontName = ""
    public var fontSize = TerminalAppearance.defaultFontSize
    public var theme = Theme.system
    /// The colors used when `theme` is `.custom`.
    public var custom = Palette.dark
    public var cursorShape = CursorShape.block
    public var cursorBlink = true
    /// For terminals opened after the change.
    public var scrollbackLines = 10_000
    public var optionAsMeta = true
    public var bell = Bell.visual

    public init() {}

    public func palette(darkMode: Bool) -> Palette {
        switch theme {
        case .system: return darkMode ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        case .solarizedLight: return .solarizedLight
        case .solarizedDark: return .solarizedDark
        case .custom: return custom
        }
    }

    public func withFontSize(_ size: Double) -> TerminalAppearance {
        var copy = self
        copy.fontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case fontName, fontSize, theme, custom, cursorShape, cursorBlink, scrollbackLines, optionAsMeta, bell
    }

    /// Missing or unknown values keep their defaults (settings saved by another version).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        let defaults = TerminalAppearance()
        fontName = value(.fontName, defaults.fontName)
        fontSize = value(.fontSize, defaults.fontSize)
        theme = value(.theme, defaults.theme)
        custom = value(.custom, defaults.custom)
        cursorShape = value(.cursorShape, defaults.cursorShape)
        cursorBlink = value(.cursorBlink, defaults.cursorBlink)
        scrollbackLines = value(.scrollbackLines, defaults.scrollbackLines)
        optionAsMeta = value(.optionAsMeta, defaults.optionAsMeta)
        bell = value(.bell, defaults.bell)
    }
}

/// Terminal colors as "#rrggbb": text, background, cursor, selection and the 16 ANSI colors.
public struct Palette: Codable, Equatable, Sendable {
    public var foreground: String
    public var background: String
    public var cursor: String
    public var selection: String
    public var ansi: [String]

    public init(foreground: String, background: String, cursor: String, selection: String, ansi: [String]) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi
    }

    enum CodingKeys: String, CodingKey { case foreground, background, cursor, selection, ansi }

    /// Always 16 ANSI colors (an edited or older settings file can have fewer, and views index all 16).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        foreground = try c.decode(String.self, forKey: .foreground)
        background = try c.decode(String.self, forKey: .background)
        cursor = try c.decode(String.self, forKey: .cursor)
        selection = try c.decode(String.self, forKey: .selection)
        let colors = Array(try c.decode([String].self, forKey: .ansi).prefix(16))
        ansi = colors + Self.standardANSI.dropFirst(colors.count)
    }

    /// Terminal.app's basic colors.
    static let standardANSI = ["#000000", "#C23621", "#25BC24", "#ADAD27", "#492EE1", "#D338D3", "#33BBC8", "#CBCCCD",
                               "#818383", "#FC391F", "#31E722", "#EAEC23", "#5833FF", "#F935F8", "#14F0F0", "#E9EBEB"]
    public static let dark = Palette(foreground: "#E5E5E5", background: "#1E1E1E", cursor: "#E5E5E5", selection: "#3A4A6B",
                                     ansi: standardANSI)
    public static let light = Palette(foreground: "#1F1F1F", background: "#FFFFFF", cursor: "#1F1F1F", selection: "#B4D5FE",
                                      ansi: standardANSI)

    // Solarized (Ethan Schoonover).
    static let solarizedANSI = ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                                "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]
    public static let solarizedDark = Palette(foreground: "#839496", background: "#002B36", cursor: "#93A1A1",
                                              selection: "#073642", ansi: solarizedANSI)
    public static let solarizedLight = Palette(foreground: "#657B83", background: "#FDF6E3", cursor: "#586E75",
                                               selection: "#EEE8D5", ansi: solarizedANSI)
}

public struct RGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "#rrggbb" or "rrggbb".
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}
