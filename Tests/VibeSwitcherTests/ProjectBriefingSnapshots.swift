import AppKit
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

/// Pictures of Brief me on <project>: the lead's Team tab with its header button (idle), and with the panel after a
/// made-up briefing and while one is written, drawn offscreen. Only with
/// `BRIEFING_SNAPSHOT_DIR=/some/folder swift test --filter ProjectBriefingSnapshots`.
@MainActor
struct ProjectBriefingSnapshots {
    @Test(.enabled(if: BriefingSnapshots.folder != nil)) func drawProjectBriefing() async throws {
        let suite = "project-briefing-snapshots-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = "/Users/me/dev/vibeswitcher"
        var board = LeadBoard()
        let contract = LeadContract(goal: "", acceptance: [], boundaries: [], context: "")
        board.tasks = [LeadTask(slug: "phone-menu", title: "The phone's menu", contract: contract, status: .running),
                       LeadTask(slug: "signing", title: "Signing the release", contract: contract, status: .blocked),
                       LeadTask(slug: "docs", title: "Docs for the briefing", contract: contract, status: .done)]
        board.questions = [LeadQuestion(text: "Ship the install tonight?", options: ["Yes", "Tomorrow"], priority: .blocking)]
        let text = "In vibeswitcher, the docs for the briefing landed and the phone's menu is still being built. Signing the release is blocked on your certificate. One question waits on you: whether to ship the install tonight."
        let held = BriefingButtonTests.FakeClaude(text)
        held.held = true
        func model(_ generate: @escaping @Sendable (String) -> String?) -> BriefingModel {
            BriefingModel(snapshot: { .init(boards: [root: board], sessions: []) }, language: { .english },
                          keyStore: AppProof.MemorySecret(), generate: generate, voice: BriefingButtonTests.FakeVoice(), defaults: defaults)
        }
        let idle = model { _ in text }.project(root)
        let spoken = model { _ in text }.project(root)
        spoken.press()
        #expect(await until { spoken.phase == .speaking })
        let writing = model { held.generate($0) }.project(root)
        writing.press()
        let snapshots = BriefingSnapshots()
        func tab(_ model: BriefingModel) -> some View {
            VStack(spacing: 0) {
                Picker("Inspector", selection: .constant("team")) {
                    Text("Team").tag("team")
                    Text("Overview").tag("overview")
                    Text("Activity").tag("activity")
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                ProjectBriefingBar(model: model)
                Divider()
                LeadTeamView(root: root, board: board, seen: [:], open: { _ in }, clock: Date(timeIntervalSince1970: 1_800_000_000))
            }
        }
        for scheme in [ColorScheme.light, .dark] {
            try snapshots.draw(tab(idle), size: CGSize(width: 340, height: 300), scheme: scheme, name: "project-briefing-button")
            try snapshots.draw(tab(spoken), size: CGSize(width: 340, height: 460), scheme: scheme, name: "project-briefing-panel")
            try snapshots.draw(tab(writing), size: CGSize(width: 340, height: 340), scheme: scheme, name: "project-briefing-writing")
        }
        writing.press()
        held.gate.signal()
    }
}
