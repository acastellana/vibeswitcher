import AppKit
import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// Brief me on <project>: the global model hands out one model per led project, written from that project's log,
/// board and questions alone, with its own 'since' stamp (a project briefing never moves the global one's, nor the
/// other way round), through the same key, language and voice; one briefing speaks at a time. Fakes only: no
/// network, no Keychain (a memory store), no sound, no real Claude, a scratch defaults domain and scratch folders.
@MainActor
struct ProjectBriefingButtonTests {
    typealias FakeVoice = BriefingButtonTests.FakeVoice
    typealias FakeClaude = BriefingButtonTests.FakeClaude

    let now = 1_800_000_000.0
    let temp = Scratch()
    let defaults: UserDefaults
    let folder: URL
    let vibeswitcher: String
    let projectC: String

    init() throws {
        defaults = temp.defaults("project-briefing-tests")
        folder = temp.url("project-briefing-tests")
        vibeswitcher = folder.appendingPathComponent("vibeswitcher").path
        projectC = folder.appendingPathComponent("project-c").path
        try write(log: [(20, "Merged docs: Docs"), (10, "Started a worker on phone-menu")], root: vibeswitcher)
        try write(log: [(15, "Merged other: The other project's work")], root: projectC)
    }

    /// A progress log as the lead's tool server writes it, each entry that many minutes before `now`, where the
    /// project's briefing reads it.
    func write(log entries: [(minutesAgo: Double, text: String)], root: String) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let text = "# Progress\n\n" + entries.map { "- \(formatter.string(from: Date(timeIntervalSince1970: now - $0.minutesAgo * 60))) \($0.text)\n" }.joined()
        let path = BoardStore(root: root).recordPath("progress.md")
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func boards() -> [String: LeadBoard] {
        var board = LeadBoard()
        board.tasks = [LeadTask(slug: "phone-menu", title: "The phone's menu", contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""),
                                status: .running)]
        board.questions = [LeadQuestion(text: "Ship the install tonight?", options: ["yes", "no"])]
        return [vibeswitcher: board, projectC: LeadBoard()]
    }

    func model(claude: FakeClaude, voice: FakeVoice) -> BriefingModel {
        let boards = boards()
        let sessions = [Session(tty: "ttys001", agent: .claude, pid: 1, startedAt: .distantPast, cwd: nil, project: "project-c", task: nil,
                                status: .needsInput, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: false)]
        return BriefingModel(snapshot: { .init(boards: boards, sessions: sessions) }, language: { BriefingLanguage.named("es")! },
                             keyStore: AppProof.MemorySecret(nil), generate: { claude.generate($0) }, voice: voice, defaults: defaults,
                             now: { [now] in now })
    }

    /// One project with news: its log, board and questions, nothing of another project's; written in the chosen
    /// language and read by the same voice.
    @Test func aProjectBriefingIsWrittenFromThatProjectAlone() async {
        let claude = FakeClaude("En vibeswitcher aterrizó la documentación y una pregunta te espera.")
        let voice = FakeVoice()
        let global = model(claude: claude, voice: voice)
        let project = global.project(vibeswitcher)
        #expect(global.project(vibeswitcher) === project)
        #expect(project.project(vibeswitcher) === project)
        #expect(project.scope == .project(root: vibeswitcher))
        #expect(project.projectName == "vibeswitcher")
        #expect(global.projectName == nil)

        project.press()
        #expect(project.phase == .writing)
        #expect(await until { voice.said.count == 1 })
        #expect(project.phase == .speaking)
        #expect(project.briefing?.text == "En vibeswitcher aterrizó la documentación y una pregunta te espera.")
        #expect(voice.said.first?.language == "es")
        let prompt = claude.prompts[0]
        #expect(prompt.contains("in the project vibeswitcher"))
        #expect(prompt.contains("Spanish"))
        #expect(prompt.contains("Landed: Docs"))
        #expect(prompt.contains("Work started: The phone's menu"))
        #expect(prompt.contains("Question for the user: Ship the install tonight?"))
        #expect(!prompt.contains("other project"))
        #expect(!prompt.contains("project-c"))
        // The global model wasn't touched.
        #expect(global.briefing == nil && global.phase == .idle)
    }

    /// A quiet project: one line, its questions still named (the template, Claude not there).
    @Test func aQuietProjectsTemplateNamesItsQuestions() async throws {
        try write(log: [(600, "Merged old: Old work")], root: vibeswitcher)
        let voice = FakeVoice()
        let project = model(claude: FakeClaude(nil), voice: voice).project(vibeswitcher)
        project.press()
        #expect(await until { voice.said.count == 1 })
        #expect(project.briefing?.text == "Nothing new in vibeswitcher; 1 running, 1 question for the user. For you: Ship the install tonight?")
        #expect(project.briefing?.notice == "Claude isn't available, so this is a template briefing in English.")
    }

    /// Each scope keeps its own 'since': the project's briefing leaves the global stamp where it was, the global one
    /// leaves the project's, and another project's stays unset.
    @Test func eachProjectKeepsItsOwnSince() async {
        let claude = FakeClaude("Hecho.")
        let voice = FakeVoice()
        let global = model(claude: claude, voice: voice)
        let yesterday = now - 86_400
        defaults.set(yesterday, forKey: BriefingModel.lastKey)
        #expect(BriefingModel.lastKey(.all) == BriefingModel.lastKey)
        #expect(BriefingModel.lastKey(.project(root: vibeswitcher)) != BriefingModel.lastKey(.project(root: projectC)))

        let project = global.project(vibeswitcher)
        #expect(project.lastBriefed == nil)
        project.press()
        #expect(await until { voice.said.count == 1 })
        #expect(project.lastBriefed == now)
        #expect(global.lastBriefed == yesterday)
        #expect(defaults.object(forKey: BriefingModel.lastKey) as? Double == yesterday)
        // Its own since: the last three hours, not the global one's day.
        #expect(claude.prompts[0].contains("in the last 3 hours"))

        project.stop()
        global.press()
        #expect(await until { voice.said.count == 2 })
        // The global one still covered the day since its own last briefing, and only its stamp moved.
        #expect(claude.prompts[1].contains("in the last 24 hours"))
        #expect(claude.prompts[1].contains("across these projects"))
        #expect(global.lastBriefed == now)
        #expect(project.lastBriefed == now)
        #expect(global.project(projectC).lastBriefed == nil)
    }

    /// One voice: a briefing that starts stops the one being read, whichever it was; its end idles the one speaking.
    @Test func oneBriefingSpeaksAtATime() async {
        let voice = FakeVoice()
        let global = model(claude: FakeClaude("Todo bien."), voice: voice)
        global.press()
        #expect(await until { voice.said.count == 1 })
        #expect(global.phase == .speaking)

        let project = global.project(vibeswitcher)
        project.press()
        #expect(global.phase == .idle)
        #expect(voice.stops >= 1)
        #expect(await until { voice.said.count == 2 })
        #expect(project.phase == .speaking)
        // Stopping the idle global one doesn't cut the project's.
        let stops = voice.stops
        global.stop()
        #expect(voice.stops == stops)
        #expect(project.phase == .speaking)
        voice.finished()
        #expect(project.phase == .idle)
        // Play on the global one reads its own briefing again, and takes the voice back.
        global.playOrStop()
        #expect(await until { voice.said.count == 3 })
        #expect(voice.said.last?.text == "Todo bien.")
        #expect(global.phase == .speaking && project.phase == .idle)
    }

    /// From the window's menu: pressed, and the panel asked to show.
    @Test func theMenuPressesItAndShowsThePanel() async {
        let voice = FakeVoice()
        let project = model(claude: FakeClaude("Hecho."), voice: voice).project(vibeswitcher)
        project.panelHidden = true
        project.pressFromMenu()
        #expect(project.phase == .writing)
        #expect(project.panelHidden == false)
        #expect(project.revealed == 1)
        #expect(await until { voice.said.count == 1 })
    }

    /// Session › Brief Me (⇧⌘B, the global one), then Brief Me on <project> (⌥⇧⌘B) under it.
    @Test func theSessionMenuHasBothUnderEachOther() throws {
        let session = try #require(MainMenu.build().item(withTitle: "Session")?.submenu)
        let global = try #require(session.item(withTitle: "Brief Me"))
        let project = try #require(session.item(withTitle: MainMenu.briefProjectTitle))
        #expect(session.index(of: project) == session.index(of: global) + 1)
        #expect(global.action == #selector(MainWindowController.briefMeAction(_:)))
        #expect(project.action == #selector(MainWindowController.briefProjectAction(_:)))
        #expect(global.keyEquivalent == "b" && global.keyEquivalentModifierMask == [.command, .shift])
        #expect(project.keyEquivalent == "b" && project.keyEquivalentModifierMask == [.command, .option, .shift])
    }

    /// ⌘K: Brief Me always (with a briefing model), Brief Me on <project> only while a lead is selected; each runs
    /// its own briefing.
    @Test func thePaletteOffersBothBriefings() {
        var ran: [String] = []
        let withLead = PaletteItem.briefings(available: true, leadProject: "project-c", all: { ran.append("all") }, project: { ran.append("project") })
        #expect(withLead.map(\.title) == ["Brief Me", "Brief Me on project-c"])
        #expect(withLead.map(\.id) == ["cmd:brief", "cmd:brief-project"])
        #expect(withLead[0].subtitle.hasPrefix("⇧⌘B") && withLead[1].subtitle.hasPrefix("⌥⇧⌘B"))
        withLead[1].run()
        withLead[0].run()
        #expect(ran == ["project", "all"])
        // Found by searching the project's name.
        #expect(FuzzyMatch.rank(withLead, query: "brief project-c") { $0.searchText }.first?.id == "cmd:brief-project")

        let noLead = PaletteItem.briefings(available: true, leadProject: nil, all: {}, project: {})
        #expect(noLead.map(\.title) == ["Brief Me"])
        #expect(PaletteItem.briefings(available: false, leadProject: "project-c", all: {}, project: {}).isEmpty)
    }

    /// The Team tab's button says what it does.
    @Test func theTeamTabsButtonNamesTheProject() {
        #expect(ProjectBriefingBar.help(.idle, name: "project-c").hasPrefix("Brief me on project-c: 30 seconds"))
        #expect(ProjectBriefingBar.help(.writing, name: "project-c").contains("cancel"))
        #expect(ProjectBriefingBar.help(.speaking, name: "project-c").contains("Stop"))
    }
}
