import AppKit
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The main window's answers when something can't be done or isn't obvious (product review 2026-11-08): the composer
/// says why it refused, the menu items that can't apply are off, ⌘N with nothing selected says what it does, Statistics
/// can be reached from the menu bar and ⌘K. The window is never shown, and there's no session host to reach.
@MainActor
@Suite(.serialized) struct MainWindowProductFixesTests {
    let temp = Scratch()

    func window(actions: WindowActions = EndedSnapshots.actions) throws -> MainWindowController {
        _ = NSApplication.shared
        let scratch = temp.url("product-fixes")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let host = HostClient(socketPath: scratch.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { scratch }, cwd: { _ in nil }, arguments: { _ in [] }))
        let leads = LeadController(host: host, store: store, vault: LeadVault(folder: scratch.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") }),
                                   inbox: scratch, home: scratch.path) { _ in "true" }
        return MainWindowController(store: store, host: host, model: WindowModel(), actions: actions, leads: leads)
    }

    func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }

    /// A window session of the fake's, selected.
    func select(_ controller: MainWindowController, transcript: String? = nil) {
        var session = Session(tty: "ttys009", agent: .claude, pid: 1, startedAt: Date(), cwd: "/dev/app", project: "app",
                              task: "tidy up", status: .idle, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: false)
        session.hostID = UUID()
        session.transcriptPath = transcript
        controller.model.update(sessions: [session], hosted: [], table: TableRead(at: Date()))
        controller.model.selectedID = controller.model.rows.first?.id
    }

    // MARK: The composer, not connected

    @Test func enterWhileNotConnectedSaysWhyAndKeepsTheMessage() throws {
        let controller = try window()
        let chat = controller.chat, key = "product-fixes-draft"
        defer { chat.composer.drafts[key] = nil }
        chat.composer.drafts[key] = "hello"
        let send = ComposerSend(chat: chat, composer: chat.composer, rowID: key, working: false,
                                actions: ComposerActions(send: controller.sendToSelected, steer: { _ in true }, stop: {}, cycleMode: {}))
        #expect(send.submit(queue: false) == .refused)
        #expect(chat.sendNotice == ChatSync.notConnected)
        #expect(chat.composer.drafts[key] == "hello")
        #expect(chat.outbox.outbox.entries.isEmpty)
    }

    @Test func theComposerHearsThatTheHostIsntThere() async throws {
        let controller = try window()
        #expect(await until { !controller.chat.hostConnected })
    }

    @Test func sendDimsWhenThereIsNothingToSendOrNoHostToTypeIt() {
        func dimmed(empty: Bool = false, connected: Bool = true, working: Bool = false, steerOnly: Bool = false, agent: Agent = .claude) -> Bool {
            ComposerSend.dimmed(empty: empty, connected: connected, working: working, steerOnly: steerOnly, agent: agent)
        }
        #expect(!dimmed())
        #expect(dimmed(empty: true))
        #expect(dimmed(connected: false))
        // A steer to Claude goes through its hook: no host needed.
        #expect(!dimmed(connected: false, working: true))
        #expect(!dimmed(connected: false, working: true, steerOnly: true))
        // Codex's steer is typed in.
        #expect(dimmed(connected: false, working: true, agent: .codex))
    }

    // MARK: Menu validation

    @Test func stopAndNewShellAndExportAreOffWhenTheyCantApply() async throws {
        let stop = item(#selector(MainWindowController.stopAction(_:)))
        let export = item(#selector(MainWindowController.exportChatAction(_:)))
        let shell = item(#selector(MainWindowController.newShellAction(_:)))

        // Nothing selected, no Shell preset.
        let none = try window()
        #expect(!none.validateMenuItem(stop))
        #expect(!none.validateMenuItem(export))
        #expect(!none.validateMenuItem(shell))

        var ended = EndedSnapshots.actions
        ended.presets = { _ in [LaunchPreset(name: "Shell", kind: .shell, command: "")] }
        // A shell in a folder you'll pick: nil folder still applies.
        let noSelection = try window(actions: ended)
        #expect(noSelection.validateMenuItem(shell))

        // Selected but not live: nothing to stop, and its chat has nothing loaded.
        let dead = try window(actions: ended)
        select(dead)
        #expect(!dead.validateMenuItem(stop))
        #expect(!dead.validateMenuItem(export))

        // Live, with a conversation on disk.
        var live = ended
        live.isLive = { _ in true }
        let controller = try window(actions: live)
        // Where the chat reads conversations from: under the (scratch) home's .claude/projects.
        let home = try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], "Run with CFFIXED_USER_HOME on a scratch folder")
        let projects = temp.adopt(URL(fileURLWithPath: home).appendingPathComponent(".claude/projects/product-fixes-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let transcript = projects.appendingPathComponent("chat.jsonl")
        try #"{"type":"user","uuid":"u1","timestamp":"2026-11-08T10:00:00Z","message":{"role":"user","content":"hello"}}"#
            .appending("\n").write(to: transcript, atomically: true, encoding: .utf8)
        select(controller, transcript: transcript.path)
        controller.chat.show(path: transcript.path)
        #expect(await until { !controller.chat.log.entries.isEmpty })
        #expect(controller.validateMenuItem(stop))
        #expect(controller.validateMenuItem(export))
        #expect(controller.validateMenuItem(shell))
    }

    // MARK: Statistics

    @Test func statisticsIsInTheWindowMenuAndThePalette() throws {
        let window = try #require(MainMenu.build().item(withTitle: "Window")?.submenu)
        let item = try #require(window.item(withTitle: "Statistics…"))
        #expect(item.action == #selector(MainWindowController.showStatisticsAction(_:)))
        #expect(item.keyEquivalent == "s" && item.keyEquivalentModifierMask == [.command, .option])

        let controller = try self.window()
        var shown = 0
        controller.onStatistics = { shown += 1 }
        let entry = try #require(controller.paletteItems().first { $0.title == "Statistics…" })
        #expect(entry.subtitle == "⌥⌘S")
        entry.run()
        #expect(shown == 1)
    }

    // MARK: ⌘N with nothing selected

    @Test func theToolbarAndTheStartPageSayWhatCommandNDoesWithNothingSelected() throws {
        let controller = try window()
        let toolbar = try #require(controller.window?.toolbar)
        let new = controller.toolbar(toolbar, itemForItemIdentifier: .init("newSession"), willBeInsertedIntoToolbar: false)
        #expect(new?.toolTip == MainWindowController.newSessionHelp)
        #expect(MainWindowController.newSessionHelp.contains("project lead"))
        #expect(MainWindowController.newSessionHelp.contains("⌘N"))
        let start = Shortcuts.keys.first { $0.0 == "⌘N" }?.1
        #expect(start?.contains("project lead") == true && start?.contains("folder") == true)
    }

    // MARK: The inspector

    @Test func aTeamTabLeftForASessionWithNoTeamIsOverviewAndComesBack() {
        #expect(InspectorView.effectiveTab("team", team: false) == "overview")
        #expect(InspectorView.effectiveTab("team", team: true) == "team")
        #expect(InspectorView.effectiveTab("activity", team: false) == "activity")
        #expect(InspectorView.effectiveTab("overview", team: true) == "overview")
        #expect(InspectorView.effectiveTab("something old", team: false) == "overview")
    }
}
