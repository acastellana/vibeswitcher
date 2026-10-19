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

    /// AX-5: nothing is drawn again every second but through `ElapsedTicks` (per second only in a time's first minute,
    /// or a countdown's last, and never with Reduce Motion or VoiceOver on): a 1 s timer or schedule anywhere else in
    /// the app fails here, and so does a schedule `from: .now` (a new one on every redraw, see `ticking(every:)`).
    static let perSecond = [
        #"ticking\(every: *1(\.0)? *[,)]"#,
        #"periodic\(from:[^)]*by: *1(\.0)? *\)"#,
        #"Timer\(timeInterval: *1(\.0)? *,"#,
        #"scheduledTimer\(withTimeInterval: *1(\.0)? *,"#,
        #"publish\(every: *1(\.0)? *,"#,
        #"\.every\(1\)"#,
        // A 1 inside a ternary: `every: fading ? 1 : 10`.
        #"(every|by|[iI]nterval)(: *|\()[^,()]*\?[^,()]*(?<![\d.])1(\.0)?(?![\d.])"#,
    ]
    static let fromNow = #"periodic\(from: *\.now"#

    /// The 1 s timers that stay, by file and what's on their line, each with why.
    static let allowedPerSecond: [(file: String, code: String, why: String)] = [
        ("HangWatchdog.swift", "Timer(timeInterval: 1", "the watchdog's state snapshot: nothing drawn (item 9, changing it waits for the user)"),
        ("Heartbeat.swift", "Timer(timeInterval: 1", "the shared clock its clients run on, only while it has any; nothing drawn"),
        ("MainWindowController.swift", "Heartbeat.shared.every(1)", "a Heartbeat client: the chat's poll of its transcript while it shows, redrawn only on change"),
        ("Onboarding.swift", "scheduledTimer(withTimeInterval: 1", "setup re-reads permissions while its window shows (they change in System Settings)"),
        ("PhoneAccessView.swift", "ticking(every: 1)", "the pairing code's countdown: a live counter you read while typing the code on the phone"),
    ]

    /// "File.swift:12: …" for each 1 s timer not on the allowed list, and each schedule from `.now`.
    static func perSecondTimers(in text: String, file: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var found: [String] = []
        for (index, line) in lines.enumerated() {
            let code = line.components(separatedBy: "//").first ?? line
            let fromNow = code.range(of: Self.fromNow, options: .regularExpression) != nil
            let ticks = perSecond.contains { code.range(of: $0, options: .regularExpression) != nil }
            let allowed = allowedPerSecond.contains { $0.file == file && code.contains($0.code) }
            if fromNow || (ticks && !allowed) {
                found.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return found
    }

    @Test func nothingTicksEverySecondButThroughTheHelper() throws {
        let files = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var found: [String] = []
        var scanned = 0
        // The benches drive the UI on purpose; they're not what people see.
        for case let url as URL in files where url.pathExtension == "swift" && !url.lastPathComponent.hasSuffix("Bench.swift") {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            found += Self.perSecondTimers(in: text, file: url.lastPathComponent)
        }
        #expect(scanned > 20)
        #expect(found.isEmpty, "Per-second timers: draw a time with TimelineView(.elapsed(since:…)) or .countdown(to:…) (ElapsedTicks), or add the timer to allowedPerSecond with why:\n\(found.joined(separator: "\n"))")
        // Every allowed one is still there (a stale entry would let a new timer in its file through).
        for entry in Self.allowedPerSecond {
            let text = try String(contentsOf: try #require(Self.file(named: entry.file)), encoding: .utf8)
            #expect(text.contains(entry.code), "\(entry.file) no longer has \(entry.code): drop it from allowedPerSecond")
        }
        // The desktop-switch flash follows Settings › Sidebar › Show briefly after switching desktops.
        let delegate = try String(contentsOf: try #require(Self.file(named: "AppDelegate.swift")), encoding: .utf8)
        #expect(delegate.contains("sidebarFlashOnSwitch { self.sidebar.flash() }"))
    }

    @Test func thePerSecondCheckCatchesTheOldTickers() {
        #expect(Self.perSecondTimers(in: "TimelineView(.ticking(every: 1)) { context in", file: "PopoverView.swift").count == 1)
        #expect(Self.perSecondTimers(in: "TimelineView(.periodic(from: session.statusSince, by: 1)) { context in", file: "ChatView.swift").count == 1)
        #expect(Self.perSecondTimers(in: "return TimelineView(.periodic(from: .now, by: 60)) { context in", file: "LeadViews.swift").count == 1)
        #expect(Self.perSecondTimers(in: "let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in }", file: "X.swift").count == 1)
        #expect(Self.perSecondTimers(in: "Timer.publish(every: 1, on: .main, in: .common)", file: "X.swift").count == 1)
        #expect(Self.perSecondTimers(in: "x = Heartbeat.shared.every(1) { tick() }", file: "X.swift").count == 1)
        #expect(Self.perSecondTimers(in: "TimelineView(.ticking(every: fading ? 1 : 10)) { context in", file: "LeadViews.swift").count == 1)
        #expect(Self.perSecondTimers(in: "Timer(timeInterval: busy ? 30 : 1.0, repeats: true)", file: "X.swift").count == 1)
        #expect(Self.perSecondTimers(in: "x = Heartbeat.shared.every(open ? 1 : 5) { tick() }", file: "X.swift").count == 1)
        // Not per second, the helper's schedules, or allowed where they are.
        #expect(Self.perSecondTimers(in: "TimelineView(.ticking(every: 10)) { context in", file: "X.swift").isEmpty)
        #expect(Self.perSecondTimers(in: "Timer(timeInterval: 15, repeats: true)", file: "X.swift").isEmpty)
        #expect(Self.perSecondTimers(in: "TimelineView(.ticking(every: fading ? 10 : 15)) { context in", file: "X.swift").isEmpty)
        #expect(Self.perSecondTimers(in: "TimelineView(.elapsed(since: start, reduceMotion: r, voiceOver: v)) { context in", file: "X.swift").isEmpty)
        #expect(Self.perSecondTimers(in: "TimelineView(.ticking(every: 1)) { context in", file: "PhoneAccessView.swift").isEmpty)
        #expect(Self.perSecondTimers(in: "TimelineView(.ticking(every: 1)) { context in", file: "Sidebar.swift").count == 1)
    }

    static func file(named name: String) -> URL? {
        guard let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in files where url.lastPathComponent == name { return url }
        return nil
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
