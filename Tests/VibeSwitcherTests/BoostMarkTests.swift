import AppKit
import Foundation
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

/// The main window's Boost mark: the orange bolt in its toolbar while `BoostWatch` decides Boost on, gone (no item, no
/// room) while off, following each decision without a new window. The window is never shown.
@MainActor
@Suite(.serialized) struct BoostMarkTests {
    let temp = Scratch()

    final class Signals {
        var onAC: Bool? = true
        var away = true
    }

    func window(_ watch: BoostWatch, briefing: BriefingModel? = nil) throws -> MainWindowController {
        _ = NSApplication.shared
        let scratch = temp.url("boost-mark")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let host = HostClient(socketPath: scratch.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { scratch }, cwd: { _ in nil }, arguments: { _ in [] }))
        let leads = LeadController(host: host, store: store, vault: LeadVault(folder: scratch.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") }),
                                   inbox: scratch, home: scratch.path) { _ in "true" }
        return MainWindowController(store: store, host: host, model: WindowModel(), actions: EndedSnapshots.actions, leads: leads,
                                    briefing: briefing, boost: watch)
    }

    func watch(_ signals: Signals) -> (BoostWatch, Preferences) {
        let folder = temp.url("boost")
        let preferences = Preferences(defaults: temp.defaults("boost-mark-defaults"), presetsFile: folder.appendingPathComponent("presets.json"))
        preferences.boostMode = .automatic
        let watch = BoostWatch(preferences: preferences, file: folder.appendingPathComponent("boost.json"))
        watch.onAC = { signals.onAC }
        watch.percent = { 86 }
        watch.away = { signals.away }
        watch.usage = { AccountUsage() }
        return (watch, preferences)
    }

    /// One heartbeat's look, to its end (decided on the watch's queue, published on the main thread).
    func look(_ watch: BoostWatch) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in watch.look { done.resume() } }
    }

    func mark(_ controller: MainWindowController) -> BoostMark? {
        (controller.boostMarkItem?.view as? NSHostingView<BoostMark>)?.rootView
    }

    @Test func theMarkFollowsBoostOnAndOff() async throws {
        let signals = Signals()
        let (watch, preferences) = watch(signals)
        preferences.boostLimits = BoostLimits(loadThreshold: 36, maxSessions: 18, maxWorkers: 7, heavySlots: 3)
        let controller = try window(watch)
        // Not decided yet: no mark.
        #expect(controller.boostMarkItem == nil)
        let items = controller.window?.toolbar?.items.count ?? 0

        await look(watch)
        let on = try #require(mark(controller))
        #expect(BoostMark.label(on.state) == "Boost on: automatic: away, on AC")
        #expect(BoostMark.help(on.state).hasPrefix("Boost on (automatic: away, on AC)\n"))
        #expect(BoostMark.help(on.state).contains("18 team sessions on this Mac, 7 workers per project, 3 test and build slots"))
        #expect(controller.boostMarkItem?.toolTip == BoostMark.help(on.state))
        #expect(controller.window?.toolbar?.items.count == items + 1)
        // Left of the inspector's button, with the window's other items.
        let identifiers = controller.window?.toolbar?.items.map(\.itemIdentifier) ?? []
        #expect(identifiers.firstIndex(of: MainWindowController.boostItem).map { $0 + 1 } == identifiers.firstIndex(of: .toggleInspector))

        // Unplugged: gone, and the toolbar is as before.
        signals.onAC = false
        await look(watch)
        #expect(controller.boostMarkItem == nil)
        #expect(controller.window?.toolbar?.items.count == items)

        // On again, for another reason: back, with that reason's texts.
        signals.onAC = true
        await look(watch)
        #expect(mark(controller).map { BoostMark.label($0.state) } == "Boost on: automatic: away, on AC")
        preferences.boostMode = .on
        signals.away = false
        await look(watch)
        let again = try #require(mark(controller))
        #expect(BoostMark.label(again.state) == "Boost on: on in Settings, on AC")
        #expect(controller.window?.toolbar?.items.filter { $0.itemIdentifier == MainWindowController.boostItem }.count == 1)
    }

    /// The toolbar gives each item a slot of about a system button's width and draws the shared glass around the views,
    /// so a smaller view leaves the slot's room as a gap between the two icons. Side by side both fill a system button's
    /// 36×36 (the inspector's); Brief Me alone keeps its own size. The window is never shown, so this is what the views
    /// ask for, the size the toolbar lays out.
    @Test func theBoltAndBriefMeFillAToolbarButtonWhileTogether() async throws {
        let signals = Signals()
        let (watch, _) = watch(signals)
        let briefing = BriefingModel(snapshot: { .init(boards: [:], sessions: []) }, language: { .english }, keyStore: AppProof.MemorySecret(),
                                     generate: { _ in nil }, voice: BriefingButtonTests.FakeVoice(), defaults: temp.defaults("boost-mark-briefing"))
        let controller = try window(watch, briefing: briefing)
        let brief = try #require(controller.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "briefMe" }?.view)
        let alone = brief.fittingSize
        #expect(alone.width < 36 && alone.height < 36)

        await look(watch)
        let bolt = try #require(controller.boostMarkItem?.view)
        #expect(bolt.fittingSize == NSSize(width: 36, height: 36))
        #expect(brief.fittingSize == NSSize(width: 36, height: 36))

        // Boost off: Brief Me is back to its own size, and on again beside the mark.
        signals.onAC = false
        await look(watch)
        #expect(brief.fittingSize == alone)
        signals.onAC = true
        await look(watch)
        #expect(brief.fittingSize == NSSize(width: 36, height: 36))
    }

    /// A click opens Settings › Performance at Boost: the window hands it to `onBoostMark`.
    @Test func aClickOpensBoostSettings() async throws {
        let signals = Signals()
        let (watch, _) = watch(signals)
        let controller = try window(watch)
        var opened = 0
        controller.onBoostMark = { opened += 1 }
        await look(watch)
        try #require(mark(controller)).open()
        #expect(opened == 1)
    }
}
