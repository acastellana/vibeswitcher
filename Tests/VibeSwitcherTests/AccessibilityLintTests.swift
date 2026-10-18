import Foundation
import Testing

/// Every SF Symbol the app shows is either named for VoiceOver or hidden from it: an icon-only button otherwise reads
/// as its symbol ("ellipsis circle", "arrow up forward app"). Scans the app's sources, so a new unlabeled icon fails here.
struct AccessibilityLintTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/VibeSwitcher")

    /// What counts as labelled, on the image's line, the line before it (an `// a11y:` note) or the few after it (the
    /// modifiers of the image or of the button or menu it labels).
    static let labelled = ["accessibilityLabel(", "accessibilityHidden(", "a11y:", "accessibilityDescription: \""]
    static let after = 4

    /// "File.swift:12: Image(systemName: …)" for each unlabeled symbol.
    static func unlabeled(in text: String, file: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var found: [String] = []
        for (index, line) in lines.enumerated() {
            let code = line.components(separatedBy: "//").first ?? line
            // A title that's empty says nothing: Label("", systemImage:) reads as the symbol's name.
            let emptyTitle = code.contains("Label(\"\", systemImage") || code.contains("Button(\"\", systemImage")
            let image = code.contains("Image(systemName:") || code.contains("systemSymbolName:")
            guard image || emptyTitle else { continue }
            let window = lines[max(0, index - 1)...min(lines.count - 1, index + after)].joined(separator: "\n")
            if emptyTitle || !labelled.contains(where: window.contains) {
                found.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return found
    }

    @Test func everySymbolIsNamedOrHidden() throws {
        let files = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var found: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            found += Self.unlabeled(in: text, file: url.path.replacingOccurrences(of: Self.sources.path + "/", with: ""))
        }
        #expect(scanned > 20)
        #expect(found.isEmpty, "Unlabeled symbols: add .accessibilityLabel(…) (and .help for a button), or .accessibilityHidden(true) when the words next to it say it all:\n\(found.joined(separator: "\n"))")
    }

    /// Every animation checks Reduce Motion: `Motion.isReduced` (AppKit) or `\.accessibilityReduceMotion` (SwiftUI)
    /// within a few lines, or an `// a11y:` note saying why it stays.
    static func unguardedAnimations(in text: String, file: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        let animations = ["withAnimation", ".animation(", "animator()", "runAnimationGroup"]
        let guards = ["Motion.isReduced", "reduceMotion", "a11y:"]
        var found: [String] = []
        for (index, line) in lines.enumerated() {
            let code = line.components(separatedBy: "//").first ?? line
            guard animations.contains(where: code.contains) else { continue }
            let window = lines[max(0, index - 6)...min(lines.count - 1, index + 3)].joined(separator: "\n")
            if !guards.contains(where: window.contains) {
                found.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return found
    }

    @Test func everyAnimationHonoursReduceMotion() throws {
        let files = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var found: [String] = []
        // The benches drive the UI on purpose; they're not what people see.
        for case let url as URL in files where url.pathExtension == "swift" && !url.lastPathComponent.hasSuffix("Bench.swift") {
            let text = try String(contentsOf: url, encoding: .utf8)
            found += Self.unguardedAnimations(in: text, file: url.lastPathComponent)
        }
        #expect(found.isEmpty, "Animations that ignore Reduce Motion:\n\(found.joined(separator: "\n"))")
        #expect(Self.unguardedAnimations(in: "withAnimation { open.toggle() }", file: "X.swift").count == 1)
        #expect(Self.unguardedAnimations(in: "withAnimation(reduceMotion ? nil : .default) { open.toggle() }", file: "X.swift").isEmpty)
    }

    @Test func theCheckCatchesAnUnlabeledIconButton() {
        let bare = """
        Button { stop() } label: { Image(systemName: "stop.fill") }
            .buttonStyle(.plain)
        """
        #expect(Self.unlabeled(in: bare, file: "X.swift").count == 1)
        #expect(Self.unlabeled(in: bare + "\n    .accessibilityLabel(\"Stop\")", file: "X.swift").isEmpty)
        #expect(Self.unlabeled(in: "Label(\"\", systemImage: \"pause.fill\").accessibilityLabel(\"x\")", file: "X.swift").count == 1)
        #expect(Self.unlabeled(in: "Image(systemName: \"gear\").accessibilityHidden(true)", file: "X.swift").isEmpty)
    }
}
