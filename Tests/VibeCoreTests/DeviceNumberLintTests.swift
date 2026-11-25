import Foundation
import Testing

/// A file's device (`st_dev`, `st_rdev`) goes to an unsigned number only through `Platform.Files.device` (its bits as
/// they are), never `UInt64(info.st_dev)`: the Mac's `dev_t` is a signed 32-bit number, a Unix socket's or a pipe's is
/// NODEV (-1), and the conversion traps ("Negative value is not representable"). The v2 macos host job of b7ef0ca3 died
/// on it: HostWebListenersTests asked a closed descriptor's number for its identity, and another test's socket had taken
/// the number. Linux's `dev_t` is unsigned, so only the Mac's runs found it.
///
/// Read: every Swift file under Sources and Tests but the Mac app's (Sources/VibeSwitcher, Tests/VibeSwitcherTests, not
/// edited on v2), the Linux-only files (`+Linux.swift`, where `dev_t` is unsigned) and this file's own examples; comment
/// lines left out.
struct DeviceNumberLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// An unsigned conversion of a stat's device field.
    static let conversion = try! NSRegularExpression(pattern: #"\bUInt(8|16|32|64)?\(\s*[A-Za-z_][A-Za-z0-9_.]*\.st_r?dev\s*\)"#)

    static func flagged(_ text: String) -> [Int] {
        text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return nil }
            return conversion.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil ? nil : index + 1
        }
    }

    @Test func theRuleFindsTheConversionAndLeavesTheHelper() {
        #expect(Self.flagged("let d = UInt64(info.st_dev)") == [1])
        #expect(Self.flagged("x\nreturn (UInt64( opened.st_rdev ), 1)") == [2])
        #expect(Self.flagged("let d = UInt32(s.st_dev)") == [1])
        #expect(Self.flagged("let d = Platform.Files.device(info)").isEmpty)
        #expect(Self.flagged("let d = UInt64(truncatingIfNeeded: info.st_dev)").isEmpty)
        #expect(Self.flagged("    /// `UInt64(info.st_dev)` traps").isEmpty)
    }

    @Test func noDeviceNumberIsConvertedByItsSign() throws {
        var found: [String] = []
        for top in ["Sources", "Tests"] {
            let root = Self.repo.appendingPathComponent(top)
            let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" {
                let path = String(url.path.dropFirst(Self.repo.path.count + 1))
                guard !path.hasPrefix("Sources/VibeSwitcher/"), !path.hasPrefix("Tests/VibeSwitcherTests/"),
                      !path.hasSuffix("+Linux.swift"), path != "Tests/VibeCoreTests/DeviceNumberLintTests.swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                found += Self.flagged(text).map { "\(path):\($0)" }
            }
        }
        #expect(found.isEmpty, "a device number converted by its sign (use Platform.Files.device): \(found.joined(separator: ", "))")
    }
}
