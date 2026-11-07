import Foundation

/// Read-only observations of the Mac's selected developer tools, independent of the app's launch environment.
public struct ToolchainSnapshot: Codable, Equatable, Sendable {
    public var developerDir: String
    public var swift: String
    public var sdkPath: String
    public var sdkVersion: String
    public var commandLineTools: String
    public var xcodeExists: Bool

    public init(developerDir: String, swift: String, sdkPath: String, sdkVersion: String,
                commandLineTools: String, xcodeExists: Bool) {
        self.developerDir = developerDir
        self.swift = Self.swiftVersion(swift)
        self.sdkPath = sdkPath
        self.sdkVersion = sdkVersion
        self.commandLineTools = commandLineTools
        self.xcodeExists = xcodeExists
    }

    /// Driver build identifiers and the target triple are not Swift language version changes.
    static func swiftVersion(_ output: String) -> String {
        guard let range = output.range(of: #"Apple Swift version [0-9]+(?:\.[0-9]+)*"#, options: .regularExpression) else { return output }
        return String(output[range])
    }

    static func isAvailable(_ value: String) -> Bool { !value.isEmpty && value != "unavailable" }

    /// Keep each field's last good observation without silencing changes in the other fields.
    mutating func keepLastGoodValues(from previous: Self?) {
        for key in [\Self.developerDir, \.swift, \.sdkPath, \.sdkVersion, \.commandLineTools] {
            if !Self.isAvailable(self[keyPath: key]), let previous {
                self[keyPath: key] = previous[keyPath: key]
            }
        }
    }

    public var needsXcode: Bool {
        developerDir.hasPrefix("/Library/Developer/CommandLineTools") && xcodeExists
    }

    /// All commands are queries; no shell, installation, selection or compilation. Failed queries remain visible.
    public static func read(run: (String, [String]) -> String? = command,
                            exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> Self {
        func query(_ executable: String, _ args: [String]) -> String {
            let output = run(executable, args)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output.isEmpty ? "unavailable" : output
        }
        func xcrun(_ args: [String]) -> String {
            query("/usr/bin/env", ["-u", "DEVELOPER_DIR", "-u", "SDKROOT", "-u", "TOOLCHAINS", "/usr/bin/xcrun"] + args)
        }
        let package = query("/usr/sbin/pkgutil", ["--pkg-info", "com.apple.pkg.CLTools_Executables"])
        let version = package.components(separatedBy: .newlines).first { $0.hasPrefix("version: ") }
            .map { String($0.dropFirst("version: ".count)) } ?? "unavailable"
        return Self(developerDir: query("/usr/bin/env", ["-u", "DEVELOPER_DIR", "/usr/bin/xcode-select", "-p"]),
                    swift: xcrun(["swift", "--version"]), sdkPath: xcrun(["--show-sdk-path"]),
                    sdkVersion: xcrun(["--show-sdk-version"]), commandLineTools: version,
                    xcodeExists: exists("/Applications/Xcode.app"))
    }

    public static func command(_ executable: String, _ args: [String]) -> String? {
        let result = Shell.run(executable: executable, args: args, in: "/", timeout: 15, grace: 1)
        return result.status == 0 && !result.timedOut ? result.output : nil
    }
}

/// Used on a serial background queue: saves a baseline at first launch, then emits one report for each change.
/// The last note is saved too, so the window still explains an update after a restart or denied notifications.
public final class ToolchainWatch: @unchecked Sendable {
    public static let interval = 10 * 60
    public static var file: URL { VibePaths.root.appendingPathComponent("toolchain.json") }
    private struct State: Codable {
        var snapshot: ToolchainSnapshot
        var note: String?
        var notedAt: Date?
    }
    private let file: URL
    private let now: () -> Date
    private let read: () -> ToolchainSnapshot
    private var state: State?
    private var loaded = false
    public var note: String? { state?.note }

    public init(file: URL = ToolchainWatch.file, read: @escaping () -> ToolchainSnapshot = { .read() },
                now: @escaping () -> Date = Date.init) {
        self.file = file
        self.read = read
        self.now = now
    }

    @discardableResult public func look() -> String? {
        load()
        if state?.note != nil, state?.notedAt.map({ now().timeIntervalSince($0) >= 24 * 60 * 60 }) ?? true {
            dismissNote()
        }
        var current = read()
        current.swift = ToolchainSnapshot.swiftVersion(current.swift)
        var previous = state?.snapshot
        if let swift = previous?.swift { previous?.swift = ToolchainSnapshot.swiftVersion(swift) }
        current.keepLastGoodValues(from: previous)
        guard previous != current else { return nil }
        let report = LeadWitness.toolchainText(before: previous, after: current)
        state = State(snapshot: current, note: report ?? state?.note, notedAt: report == nil ? state?.notedAt : now())
        save()
        return report
    }

    public func dismissNote() {
        load()
        state?.note = nil
        state?.notedAt = nil
        save()
    }

    private func load() {
        guard !loaded else { return }
        state = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        loaded = true
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { try? VibePaths.writePrivate(data, to: file) }
    }
}

extension LeadWitness {
    public static func toolchainText(before: ToolchainSnapshot?, after: ToolchainSnapshot) -> String? {
        var changes: [String] = []
        if let before {
            for (name, old, new) in [("Swift", before.swift, after.swift), ("SDK", before.sdkVersion, after.sdkVersion),
                                     ("SDK path", before.sdkPath, after.sdkPath),
                                     ("developer directory", before.developerDir, after.developerDir),
                                     ("Command Line Tools package", before.commandLineTools, after.commandLineTools)] where old != new && ToolchainSnapshot.isAvailable(old) && ToolchainSnapshot.isAvailable(new) {
                changes.append("\(name): \(old) → \(new)")
            }
        }
        let warning = after.needsXcode && (before?.needsXcode != true || !changes.isEmpty)
        guard !changes.isEmpty || warning else { return nil }
        var text = changes.isEmpty ? "Developer tools warning." : "Developer tools changed: " + changes.joined(separator: "; ") + "."
        text += " Active tools at \(after.developerDir); SDK \(after.sdkVersion) at \(after.sdkPath)."
        if warning {
            text += " Command Line Tools are active while /Applications/Xcode.app exists. SwiftUI macro plugins need Xcode; Command Line Tools alone can break these builds."
        }
        text += " If builds fail, review Xcode Settings › Locations › Command Line Tools and choose the intended Xcode. For missing Metal tools, check Xcode Settings › Components. See https://developer.apple.com/xcode/resources/. VibeSwitcher only reads these settings; it never changes them."
        return text
    }
}
