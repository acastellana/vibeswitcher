import Foundation
import Testing

/// A file's device (`st_dev`, `st_rdev`) goes to an unsigned number only through `Platform.Files.device` (its bits as
/// they are), never `UInt64(info.st_dev)`: the Mac's `dev_t` is a signed 32-bit number, a Unix socket's or a pipe's is
/// NODEV (-1), and the conversion traps ("Negative value is not representable"). The v2 macos host job of b7ef0ca3 died
/// on it: HostWebListenersTests asked a closed descriptor's number for its identity, and another test's socket had taken
/// the number. Linux's `dev_t` is unsigned, so only the Mac's runs found it.
///
/// Read: every Swift file under Sources, Keeper/Sources (the keeper's package, slice K0's) and Tests but the Mac app's (Sources/VibeSwitcher, Tests/VibeSwitcherTests, not
/// edited on v2), the Linux-only files (`+Linux.swift`, where `dev_t` is unsigned) and this file's own examples; comment
/// lines left out.
struct DeviceNumberLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let tops = ["Sources", "Keeper/Sources", "Tests"]
    private let scratch = Scratch()

    /// An unsigned conversion of a stat's device field.
    static let conversion = try! NSRegularExpression(pattern: #"\bUInt(8|16|32|64)?\(\s*[A-Za-z_][A-Za-z0-9_.]*\.st_r?dev\s*\)"#)

    static func flagged(_ text: String) -> [Int] {
        text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return nil }
            return conversion.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil ? nil : index + 1
        }
    }

    /// The keeper's package is read: a conversion planted in a sample tree's `Keeper/Sources` is found by the same scan.
    @Test func theKeepersSourcesAreCovered() throws {
        let tree = scratch.url("device-number-keeper")
        let planted = tree.appendingPathComponent("Keeper/Sources/VibeKeep/Planted.swift")
        try FileManager.default.createDirectory(at: planted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "import Foundation\nlet d = UInt64(info.st_dev)\n".write(to: planted, atomically: true, encoding: .utf8)
        #expect(try Self.scan(tree) == ["Keeper/Sources/VibeKeep/Planted.swift:2"])
    }

    @Test func theRuleFindsTheConversionAndLeavesTheHelper() {
        #expect(Self.flagged("let d = UInt64(info.st_dev)") == [1])
        #expect(Self.flagged("x\nreturn (UInt64( opened.st_rdev ), 1)") == [2])
        #expect(Self.flagged("let d = UInt32(s.st_dev)") == [1])
        #expect(Self.flagged("let d = Platform.Files.device(info)").isEmpty)
        #expect(Self.flagged("let d = UInt64(truncatingIfNeeded: info.st_dev)").isEmpty)
        #expect(Self.flagged("    /// `UInt64(info.st_dev)` traps").isEmpty)
    }

    /// Each conversion in the files read of `tree` (the repository, or a test's), as "PATH:LINE".
    static func scan(_ tree: URL = repo) throws -> [String] {
        var found: [String] = []
        for top in tops {
            let root = tree.appendingPathComponent(top)
            // Relative to the folder as the walk gives them (a test's tree under a linked TMPDIR is walked resolved).
            guard let files = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let relative as String in files where relative.hasSuffix(".swift") {
                let url = root.appendingPathComponent(relative)
                let path = "\(top)/\(relative)"
                guard !path.hasPrefix("Sources/VibeSwitcher/"), !path.hasPrefix("Tests/VibeSwitcherTests/"),
                      !path.hasSuffix("+Linux.swift"), path != "Tests/VibeCoreTests/DeviceNumberLintTests.swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                found += flagged(text).map { "\(path):\($0)" }
            }
        }
        return found
    }

    @Test func noDeviceNumberIsConvertedByItsSign() throws {
        for top in Self.tops {
            #expect(FileManager.default.fileExists(atPath: Self.repo.appendingPathComponent(top).path), "\(top)")
        }
        let found = try Self.scan()
        #expect(found.isEmpty, "a device number converted by its sign (use Platform.Files.device): \(found.joined(separator: ", "))")
    }
}
