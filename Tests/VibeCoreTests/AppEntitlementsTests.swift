import Foundation
import Testing

/// The app runs under the hardened runtime (scripts/build-app.sh signs everything with `--options runtime`), which
/// refuses the Apple Events it sends to Terminal and Chrome (-1743, and no prompt) unless its signature carries the
/// automation entitlement. The helpers send none: they're signed without entitlements.
struct AppEntitlementsTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func theEntitlementsFileAllowsAppleEvents() throws {
        let data = try Data(contentsOf: Self.repo.appendingPathComponent("Resources/VibeSwitcher.entitlements"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["com.apple.security.automation.apple-events"] as? Bool == true)
        #expect(plist.count == 2, "only what the app needs: \(plist.keys.sorted())")
    }

    /// Push to talk records from the microphone (`EngineRecorder`): under the hardened runtime the input is silent and
    /// macOS asks nothing unless the signature carries the audio-input entitlement, and the Info.plist says why.
    @Test func theEntitlementsFileAllowsTheMicrophone() throws {
        let data = try Data(contentsOf: Self.repo.appendingPathComponent("Resources/VibeSwitcher.entitlements"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["com.apple.security.device.audio-input"] as? Bool == true)
        let infoData = try Data(contentsOf: Self.repo.appendingPathComponent("Resources/Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any])
        let why = try #require(info["NSMicrophoneUsageDescription"] as? String)
        #expect(why.contains("OpenAI") && why.contains("hold"))
    }

    @Test func buildAppSignsTheAppAloneWithIt() throws {
        let script = try String(contentsOf: Self.repo.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        let signs = script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("codesign --force") }
        #expect(signs.count == 4, "\(signs)")
        for line in signs { #expect(line.contains("--options runtime"), "\(line)") }
        let app = signs.filter { $0.hasSuffix("\"$APP\"") }
        #expect(app.count == 1 && app[0].contains("--entitlements Resources/VibeSwitcher.entitlements"), "\(app)")
        for helper in signs where !helper.hasSuffix("\"$APP\"") { #expect(!helper.contains("--entitlements"), "\(helper)") }
        let info = try String(contentsOf: Self.repo.appendingPathComponent("Resources/Info.plist"), encoding: .utf8)
        #expect(info.contains("<key>NSAppleEventsUsageDescription</key>"))
    }
}
