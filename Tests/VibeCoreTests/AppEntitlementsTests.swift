import Foundation
import Testing

/// The app runs under the hardened runtime (scripts/build-app.sh signs everything with `--options runtime`), which
/// refuses the Apple Events it sends to Terminal and Chrome (-1743, and no prompt) unless its signature carries the
/// automation entitlement. The helpers send none: they're signed without it (the session host carries audio input alone).
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
        #expect(why.contains("OpenAI") && why.contains("hold") && why.contains("Claude"))
    }

    /// A Claude Code session's dictation records in claude itself (its own signature carries the audio-input
    /// entitlement), under the session host and its launcher, which the app spawns without disclaiming: macOS asks about
    /// VibeSwitcher, the responsible process, so the app's entitlement and usage text are the ones that count (tccd's
    /// AUTHREQ_ATTRIBUTION for claude under the host, 2026-10-29: responsible dev.vibeswitcher.VibeSwitcher, allowed).
    /// A host that is its own responsible process (started outside the app) is asked about instead: the host's
    /// signature carries audio input for that (`theSessionHostMayHoldTheMicrophoneAndNothingElse`).
    @Test func theSessionHostIsSpawnedUnderTheAppsMicrophonePermission() throws {
        let sources = Self.repo.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" || $0.pathExtension == "c" || $0.pathExtension == "m" } ?? []
        #expect(files.count > 50)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("spawnattrs_setdisclaim"), "\(file.lastPathComponent) disclaims the app's responsibility")
        }
    }

    @Test func buildAppSignsTheAppAloneWithIt() throws {
        let script = try String(contentsOf: Self.repo.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        let signs = script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("codesign --force") }
        #expect(signs.count == 4, "\(signs)")
        for line in signs { #expect(line.contains("--options runtime"), "\(line)") }
        let app = signs.filter { $0.hasSuffix("\"$APP\"") }
        #expect(app.count == 1 && app[0].contains("--entitlements Resources/VibeSwitcher.entitlements"), "\(app)")
        let host = signs.filter { $0.hasSuffix("/vibeswitcher-host\"") }
        #expect(host.count == 1 && host[0].contains("--entitlements Resources/VibeSwitcherHost.entitlements"), "\(host)")
        for helper in signs where !helper.hasSuffix("\"$APP\"") && !host.contains(helper) {
            #expect(!helper.contains("--entitlements"), "\(helper)")
        }
        let info = try String(contentsOf: Self.repo.appendingPathComponent("Resources/Info.plist"), encoding: .utf8)
        #expect(info.contains("<key>NSAppleEventsUsageDescription</key>"))
    }

    /// A host that is its own responsible process: under the hardened runtime macOS gives it, and the Claude Code it
    /// runs, silence and asks nothing unless its signature carries audio input (a hardened scratch binary run as its own
    /// responsible process, 2026-10-29: all zeros, tccd "requires entitlement com.apple.security.device.audio-input but
    /// it is missing"). Nothing else: it sends no Apple Events.
    @Test func theSessionHostMayHoldTheMicrophoneAndNothingElse() throws {
        let data = try Data(contentsOf: Self.repo.appendingPathComponent("Resources/VibeSwitcherHost.entitlements"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist as NSDictionary == ["com.apple.security.device.audio-input": true] as NSDictionary)
    }
}
