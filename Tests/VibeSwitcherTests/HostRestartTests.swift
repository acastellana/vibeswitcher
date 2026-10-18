import AppKit
import SwiftUI
import Testing
@testable import VibeSwitcher

/// What the header, the menu bar and Settings offer for an outdated session host.
@MainActor
struct HostRestartTests {
    @Test func aHostThatHandsOverKeepsSessionsWithoutAsking() {
        let plan = HostClient.RestartPlan.handOver
        #expect(plan.title == "Restart Session Host (keeps sessions)")
        #expect(!plan.needsConfirmation)
    }

    @Test func anyOtherSaysHowManySessionsInAllProjectsItEndsAndAsksFirst() {
        #expect(HostClient.RestartPlan.endAndReplace(live: 3).title == "Restart Session Host… (ends 3 sessions in all projects)")
        #expect(HostClient.RestartPlan.endAndReplace(live: 1).title == "Restart Session Host… (ends 1 session in all projects)")
        #expect(HostClient.RestartPlan.endAndReplace(live: 3).help.contains("ends 3 sessions in all projects"))
        #expect(HostClient.RestartPlan.endAndReplace(live: 3).needsConfirmation)
        // Nothing live to end: no question.
        #expect(HostClient.RestartPlan.endAndReplace(live: 0).title == "Restart Session Host")
        #expect(!HostClient.RestartPlan.endAndReplace(live: 0).needsConfirmation)
    }

    @Test func theMenuBarHasTheRestartBesideSettings() throws {
        let app = try #require(MainMenu.build().item(withTitle: "VibeSwitcher")?.submenu)
        let restart = try #require(app.item(withTitle: MainMenu.restartHostTitle))
        #expect(restart.action == #selector(AppDelegate.restartSessionHost(_:)))
        #expect(restart.target == nil)   // through the responder chain to the app's delegate
        let settings = try #require(app.item(withTitle: "Settings…"))
        #expect(app.index(of: restart) == app.index(of: settings) + 1)
    }

    @Test func settingsSaysWhatTheHostIs() {
        #expect(HostRestartSection.status(.connected) == "Up to date")
        #expect(HostRestartSection.status(.outdated(live: 2, compatible: true)) == "Older than this app")
    }

    static let folder = ProcessInfo.processInfo.environment["HOST_RESTART_SNAPSHOT_DIR"]

    /// The header's button in each case. Only with `HOST_RESTART_SNAPSHOT_DIR=/some/folder swift test --filter HostRestart`.
    @Test(.enabled(if: folder != nil)) func drawTheButtons() throws {
        let folder = try #require(Self.folder)
        let plans: [(String, HostClient.RestartPlan)] = [("handover", .handOver), ("ends-3", .endAndReplace(live: 3)),
                                                         ("ends-none", .endAndReplace(live: 0))]
        for (name, plan) in plans {
            for scheme in [ColorScheme.light, .dark] {
                // Buttons are AppKit views, which `ImageRenderer` leaves out: drawn in a window far off every display.
                let view = HostRestartButton(plan: plan) {}.padding(12)
                    .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                    .environment(\.colorScheme, scheme)
                let hosting = NSHostingView(rootView: view)
                let size = hosting.fittingSize
                let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = hosting
                window.orderFrontRegardless()
                defer { window.close() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: folder)
                    .appendingPathComponent("host-restart-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
