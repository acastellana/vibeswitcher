import AppKit
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

/// Pictures of Brief me: its panel after a made-up briefing (and the template's notice), and Settings › General ›
/// Briefing, drawn offscreen. Only with `BRIEFING_SNAPSHOT_DIR=/some/folder swift test --filter BriefingSnapshots`.
@MainActor
struct BriefingSnapshots {
    static let folder = ProcessInfo.processInfo.environment["BRIEFING_SNAPSHOT_DIR"]

    /// Draws `view` in an offscreen window (AppKit-backed controls draw too) into `name`.png.
    func draw<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, name: String) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: Self.folder!).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }

    @Test(.enabled(if: folder != nil)) func drawBriefing() async throws {
        let suite = "briefing-snapshots-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let voice = BriefingButtonTests.FakeVoice()
        let text = "In vibeswitcher, nine fixes landed and the install waits on your signing setup. Genswap has one question for you about the release notes, and its two workers are still running. Films was quiet. Two sessions need you: the api session and the docs session. Nothing else is stuck, so after those you're clear to step away for a while."
        let model = BriefingModel(snapshot: { .init(boards: [:], sessions: []) }, language: { .english },
                                  keyStore: AppProof.MemorySecret(), generate: { _ in text }, voice: voice, defaults: defaults)
        model.press()
        #expect(await until { model.phase == .speaking })
        let template = BriefingModel(snapshot: { .init(boards: [:], sessions: []) }, language: { .english },
                                     keyStore: AppProof.MemorySecret(), generate: { _ in nil }, voice: voice, defaults: defaults)
        template.press()
        #expect(await until { template.phase == .speaking })
        let preferences = Preferences(defaults: defaults, presetsFile: scratchRoot.appendingPathComponent("\(suite).json"))
        for scheme in [ColorScheme.light, .dark] {
            try draw(VStack(spacing: 0) {
                HStack { Text("VibeSwitcher").font(.headline); BriefMeButton(model: model); Spacer() }.padding(10)
                Divider()
                BriefingPanel(model: model) {}
            }, size: CGSize(width: 400, height: 230), scheme: scheme, name: "briefing-panel")
            try draw(BriefingPanel(model: template), size: CGSize(width: 400, height: 110), scheme: scheme, name: "briefing-template")
            try draw(Form { BriefingSettings(preferences: preferences, briefing: model) }.formStyle(.grouped),
                     size: CGSize(width: 620, height: 260), scheme: scheme, name: "briefing-settings")
        }
        try? FileManager.default.removeItem(at: scratchRoot.appendingPathComponent("\(suite).json"))
    }
}
