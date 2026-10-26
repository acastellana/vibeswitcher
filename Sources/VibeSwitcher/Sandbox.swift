import AppKit
import Combine
import ObjectiveC
import SwiftUI
import VibeCore

/// `VibeSwitcher --sandbox STATE --shots DIR [--minutes N] [--fake-claude PATH]` (run by scripts/sandbox-app.sh): a
/// copy of the app's window that a worker builds from its worktree, drives and photographs, with nothing of the user's
/// in reach. The real window, chat, composer, settings and sheets, on a private session host running fake sessions
/// (the tests' FakeClaude on a scratch pty, never a real agent), all its state in STATE:
/// - a home of its own (HOME, CFFIXED_USER_HOME and VIBESWITCHER_HOME inside STATE, checked here), its own host on its
///   own lock (so the host keeps its vault in memory and never asks the Keychain for its key) and socket, and a
///   throwaway app key in memory: no Keychain item is read, the app's or the vault's (the app's Keychain stores are made
///   by AppDelegate alone, which this never makes);
/// - its own defaults, a suite in STATE (`redirectDefaults`): cfprefsd keeps an unbundled build's defaults in the real
///   ~/Library/Preferences whatever the home says, which is why it runs from a build folder only, never a bundle;
/// - no menu bar icon, hot key, notifications, Phone Access, remote server, Terminal reads or login item: none is made;
/// - never active, never on screen: its NSApplication (`SandboxApplication`) refuses activation, any policy but
///   `.prohibited` and modal runs, and keeps every window off screen, transparent, out of Mission Control and Spaces;
///   nothing is posted to the window server, the drive goes through the views themselves.
/// It's driven through files in STATE/control (`Driver.commands`; one request `req-ID` of NUL-separated words, its
/// reply `rep-ID`), and quits by itself after MINUTES (10) or on `quit`. `shot NAME` draws each of its windows in light
/// and dark into DIR as PNGs, from the views (no Screen Recording permission, as `--snapshot` and `--capture-window`).
enum Sandbox {
    /// Set at launch by `run`, the one place: only the `--sandbox` argument turns it on, never the environment or a
    /// default, so nothing can turn it on in the user's running app. What it guards does nothing in the sandbox.
    private(set) static var isOn = false

    /// Where the sandbox's windows sit: far off every screen.
    static let offscreen = NSPoint(x: -20_000, y: -20_000)
    /// The command the drive is on (for what the window guard notes).
    static var doing = "launch"

    static func run(arguments: [String]) -> Never {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let statePath = arguments.first.map({ ($0 as NSString).standardizingPath }), statePath.hasPrefix("/"),
              let shotsPath = value("--shots").map({ ($0 as NSString).standardizingPath }), shotsPath.hasPrefix("/") else {
            refuse("usage: VibeSwitcher --sandbox STATE --shots DIR [--minutes N] [--fake-claude PATH] (absolute paths); "
                   + "run it with scripts/sandbox-app.sh")
        }
        if let problem = refusal(state: statePath, bundleID: Bundle.main.bundleIdentifier, root: VibePaths.root.path,
                                 home: VibePaths.home, appHome: NSHomeDirectory(), accountHome: VibePaths.accountHome) {
            refuse(problem)
        }
        isOn = true
        // Before anything reads a default (AppKit included).
        redirectDefaults(to: (statePath as NSString).appendingPathComponent("defaults"))
        keepWindowsWherePut()
        // Before anything makes the shared application: this is the one.
        let app = SandboxApplication.shared
        _ = app.setActivationPolicy(.prohibited)
        VibePaths.ensurePrivateDirectories()
        let minutes = value("--minutes").flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 10
        let driver = Driver(state: URL(fileURLWithPath: statePath, isDirectory: true),
                            shots: URL(fileURLWithPath: shotsPath, isDirectory: true),
                            fakeClaude: value("--fake-claude"), minutes: minutes)
        app.delegate = driver
        withExtendedLifetime(driver) { app.run() }
        exit(0)
    }

    private static func refuse(_ text: String) -> Never {
        FileHandle.standardError.write(Data("sandbox: \(text)\n".utf8))
        exit(64)
    }

    /// Why the sandbox won't start with this state folder and these paths, or nil when it may: it runs unbundled (a
    /// build folder's binary: a bundle's defaults are the app's), on a home and a VibeSwitcher folder inside `state`,
    /// none of them the account's own.
    static func refusal(state: String, bundleID: String?, root: String, home: String, appHome: String, accountHome: String) -> String? {
        // One spelling for each place: Foundation writes /private/tmp as /tmp, the shell the other way.
        func spelled(_ path: String) -> String {
            let standard = (path as NSString).standardizingPath
            return standard.hasPrefix("/private/") ? String(standard.dropFirst("/private".count)) : standard
        }
        let state = spelled(state)
        func inside(_ path: String) -> Bool { spelled(path).hasPrefix(state + "/") }
        let own = spelled(accountHome)
        if let bundleID { return "runs from a build folder only (.build/debug/VibeSwitcher), not a bundle (\(bundleID)): a bundle's defaults are the installed app's" }
        if state == own || own.hasPrefix(state + "/") || state.hasPrefix(own + "/.vibeswitcher") {
            return "the state folder \(state) holds your home or is in your ~/.vibeswitcher"
        }
        guard FileManager.default.fileExists(atPath: state) else { return "no state folder at \(state)" }
        guard inside(root) else { return "VibeSwitcher's folder \(root) isn't inside the state folder: set VIBESWITCHER_HOME into it" }
        guard inside(home), inside(appHome) else {
            return "the home (\(home), \(appHome)) isn't inside the state folder: set HOME and CFFIXED_USER_HOME into it"
        }
        return nil
    }

    // MARK: Defaults

    /// The defaults standard hands out, in place of the app's domain: a suite named by a path inside the state folder,
    /// which cfprefsd keeps in that path's .plist (a domain name would go to the real ~/Library/Preferences, see
    /// `Scratch.defaults` in the tests). Every `UserDefaults.standard` read and write goes there, and AppKit's own
    /// (window frames, split views).
    private static func redirectDefaults(to path: String) {
        SandboxDefaults.suite = UserDefaults(suiteName: path)
        guard SandboxDefaults.suite != nil,
              let standard = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)),
              let own = class_getClassMethod(SandboxDefaults.self, #selector(SandboxDefaults.sandboxStandard)) else {
            refuse("couldn't give the sandbox defaults of its own")
        }
        method_setImplementation(standard, method_getImplementation(own))
        guard UserDefaults.standard === SandboxDefaults.suite else { refuse("couldn't give the sandbox defaults of its own") }
    }

    // MARK: Windows

    /// AppKit pulls a titled window that's off every screen back until a corner of it shows (to -1240, -684 on a
    /// 1728-wide screen): in the sandbox a window stays where it's put, off screen (`hide`).
    private static func keepWindowsWherePut() {
        guard let constrain = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:))) else {
            refuse("couldn't keep the sandbox's windows off screen")
        }
        let asPut: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, frame, _ in frame }
        method_setImplementation(constrain, imp_implementationWithBlock(asPut))
    }

    /// Keeps `window` where nobody sees it: off every screen, transparent, out of Mission Control, ⌘` and window
    /// restoration, taking no clicks. Its views still lay out and draw for `shot`.
    static func hide(_ window: NSWindow) {
        if window.sheetParent == nil, window.frame.origin != offscreen { window.setFrameOrigin(offscreen) }
        if window.alphaValue != 0 { window.alphaValue = 0 }
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isRestorable = false
        if window.sheetParent == nil { window.collectionBehavior.formUnion([.transient, .ignoresCycle]) }
    }

    /// Whether `frame` reaches any of the screens.
    static func onScreen(_ frame: NSRect, screens: [NSRect] = NSScreen.screens.map(\.frame)) -> Bool {
        screens.contains { $0.intersects(frame) }
    }

    /// Each of the windows drawn as it is, its frame included, into `file` (PNG). False when it couldn't be drawn.
    static func draw(_ window: NSWindow, to file: URL) -> Bool {
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: file)) != nil
    }

    /// A file name's part from `text`: letters, digits, `.`, `_` and `-` only.
    static func fileName(_ text: String) -> String {
        let kept = text.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" }
        let name = String(kept).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return name.isEmpty ? "shot" : name
    }
}

/// Holds the sandbox's defaults for the replaced `UserDefaults.standard`.
private final class SandboxDefaults: NSObject {
    nonisolated(unsafe) static var suite: UserDefaults?
    @objc class func sandboxStandard() -> UserDefaults { suite! }
}

/// The sandbox's NSApplication: never active, never anything but `.prohibited` (no Dock icon, no menu bar), no modal
/// window (an alert's runModal answers Cancel at once, unseen), and every window kept off screen (`Sandbox.hide`). What
/// it refused is listed in `refused` (the `status` command, and the isolation test, read it).
final class SandboxApplication: NSApplication {
    private(set) var refused: [String] = []
    /// Windows the guard found on a screen (each moved off at once): none is ever put there.
    private(set) var foundOnScreen: [String] = []

    private func refuse(_ what: String) {
        refused.append(what)
        Breadcrumbs.shared.note("sandbox: refused \(what)")
    }

    override func activate() { refuse("activating the app") }
    override func activate(ignoringOtherApps flag: Bool) { refuse("activating the app") }

    override func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        guard activationPolicy == .prohibited else {
            refuse("activation policy \(activationPolicy.rawValue)")
            return false
        }
        return super.setActivationPolicy(activationPolicy)
    }

    override func runModal(for window: NSWindow) -> NSApplication.ModalResponse {
        refuse("a modal window (\(window.title.isEmpty ? String(describing: type(of: window)) : window.title))")
        return .cancel
    }

    /// After each event: every window off screen again, should anything have moved one.
    override func updateWindows() {
        super.updateWindows()
        guardWindows()
    }

    func guardWindows() {
        for window in windows where window.isVisible {
            if window.sheetParent == nil, Sandbox.onScreen(window.frame) {
                foundOnScreen.append("\(type(of: window)) “\(window.title)” at \(NSStringFromRect(window.frame)) during \(Sandbox.doing)")
                Breadcrumbs.shared.note("sandbox: a window was on screen, moved off: \(foundOnScreen.last!)")
            }
            Sandbox.hide(window)
        }
    }
}

/// The sandbox's window, host and fake sessions, and what drives them.
private final class Driver: NSObject, NSApplicationDelegate {
    let state: URL
    let shots: URL
    let fakeClaude: String?
    let minutes: Double
    let store: SessionStore
    let host: HostClient
    let model = WindowModel()
    let preferences = Preferences()
    lazy var leads: LeadController = {
        let controller = LeadController(host: host, store: store) { _ in "claude" }
        // A lead's questions to you would be alerts: none in the sandbox.
        controller.confirm = { [weak self] title, _, buttons in
            self?.refuse("a lead's question (\(title))")
            return buttons.count - 1
        }
        controller.answersTrust = false
        return controller
    }()
    lazy var briefing = BriefingModel(
        snapshot: { [weak self] in BriefingModel.Snapshot(boards: self?.leads.boards ?? [:], sessions: self?.store.sessions ?? []) },
        language: { .preferred() }, keyStore: BriefingKey(saved: AppProof.MemorySecret()), generate: { _ in nil })
    var window: MainWindowController?
    var settings: SettingsWindowController?
    var sheet: NSWindow?
    var sheetName: String?
    /// What the drive asked for that the sandbox doesn't do (Terminal, a real agent, an alert).
    var refused: [String] = []
    private var cancellables: Set<AnyCancellable> = []
    private var poller: DispatchSourceTimer?
    private var ready = false

    /// A fake session: FakeClaude on one of the host's ptys.
    struct Fake {
        var id: UUID
        var tty: String
        var label: String
        var pid: Int32
        var cwd: String
        var transcript: String?
        var control: String?
    }
    private let lock = NSLock()
    /// By tty (read on the scanner's queue).
    private var fakes: [String: Fake] = [:]
    private var fakeCount = 0

    var home: String { VibePaths.home }
    var control: URL { state.appendingPathComponent("control", isDirectory: true) }

    init(state: URL, shots: URL, fakeClaude: String?, minutes: Double) {
        self.state = state
        self.shots = shots
        self.fakeClaude = fakeClaude
        self.minutes = minutes
        // Its own host: its own lock (not the user's host.lock: a host on it is the user's, which reads its vault key
        // from the Keychain), its socket in this home, ending with this process however it ends.
        host = HostClient(socketPath: VibePaths.hostSocket.path, appKey: { [key = AppProof.MemoryStore()] in key.key() })
        host.hostArguments = HostClient.endsWithThisProcess + ["--lock", VibePaths.root.appendingPathComponent("sandbox-host.lock").path]
        weak var weakSelf: Driver?
        // Only the fake sessions: never the Mac's processes, never Terminal's tabs.
        store = SessionStore(scanner: SessionScanner(processes: { weakSelf?.processes() ?? [:] },
                                                     cwd: { pid in weakSelf?.cwd(pid) },
                                                     arguments: { _ in [] }),
                             bridge: .init(tabs: { .tabs([:]) }, screens: { _ in [:] }))
        super.init()
        weakSelf = self
        store.terminalFront = { (false, nil) }
        store.minimizeOnPause = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Breadcrumbs.shared.note("sandbox: started in \(state.path), quitting in \(minutes) min")
        try? FileManager.default.createDirectory(at: control, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        watchTheClock()
        host.$sessions.receive(on: RunLoop.main).sink { [weak self] in self?.store.updateHosted($0) }.store(in: &cancellables)
        store.$sessions.combineLatest(host.$sessions, host.$state, store.$tableRead).receive(on: RunLoop.main)
            .sink { [weak self] sessions, hosted, state, table in
                self?.model.update(sessions: sessions, hosted: hosted, table: table, hostAnswered: state != .connecting)
            }
            .store(in: &cancellables)
        // A fake agent leaves with its session, as a real one does.
        host.$sessions.receive(on: RunLoop.main).sink { [weak self] sessions in
            guard let self else { return }
            let live = Set(sessions.filter(\.isLive).map(\.tty))
            self.lock.withLock { self.fakes = self.fakes.filter { live.contains($0.key) } }
        }.store(in: &cancellables)
        store.hostScreens = { [weak self] in self?.host.screens ?? [:] }
        store.requestHostScreens = { [weak self] in self?.host.refreshScreens(ttys: $0) }
        _ = leads
        store.start()
        startFake(label: "Fake Claude") { [weak self] problem in
            guard let self else { return }
            if let problem { Breadcrumbs.shared.note("sandbox: the first fake session didn't start: \(problem)") }
            self.openWindow()
            self.waitForRow {
                self.ready = true
                try? VibePaths.writePrivate(Data("\(getpid())\n".utf8), to: self.control.appendingPathComponent("started"))
                print("sandbox: ready (pid \(getpid()))")
                fflush(stdout)
            }
        }
        listen()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Breadcrumbs.shared.note("sandbox: quitting")
        Breadcrumbs.shared.flush()
    }

    /// Quits after `minutes`, from a thread of its own: a main thread that's stuck still ends.
    private func watchTheClock() {
        let seconds = minutes * 60
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: seconds)
            DispatchQueue.main.async {
                Breadcrumbs.shared.note("sandbox: \(seconds / 60) min up, quitting")
                NSApp.terminate(nil)
            }
            Thread.sleep(forTimeInterval: 15)
            exit(0)
        }
    }

    private func refuse(_ what: String) {
        refused.append(what)
        Breadcrumbs.shared.note("sandbox: refused \(what)")
    }

    // MARK: Fake sessions

    private func processes() -> [Int32: ProcInfo] {
        let agents = lock.withLock { fakes.mapValues(\.pid) }
        return UIBench.processTable(agents: agents, launched: Date().addingTimeInterval(-3600))
    }

    private func cwd(_ pid: Int32) -> String? {
        lock.withLock { fakes.values.first { $0.pid == pid }?.cwd }
    }

    /// A new fake session: FakeClaude (or, without its script, a shell's `cat`) on a scratch pty of the sandbox's host,
    /// with a short conversation already in its transcript and the hook state a Claude session leaves.
    func startFake(label: String, slug named: String? = nil, transcript firstLines: String = Driver.firstTurn,
                   _ done: @escaping (String?) -> Void) {
        fakeCount += 1
        let number = fakeCount
        let slug = named ?? "sandbox-project" + (number == 1 ? "" : "-\(number)")
        let folder = (home as NSString).appendingPathComponent("projects/\(slug)")
        let files = state.appendingPathComponent("fake-\(number)", isDirectory: true)
        let projects = (home as NSString).appendingPathComponent(".claude/projects/-sandbox-\(slug)")
        let transcript = (projects as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        let controlFile = files.appendingPathComponent("control.jsonl").path
        let agentState = files.appendingPathComponent("state.json").path
        for path in [folder, files.path, projects] {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let command: String
        if let fakeClaude {
            FileManager.default.createFile(atPath: transcript, contents: Data(firstLines.utf8))
            FileManager.default.createFile(atPath: controlFile, contents: nil)
            command = "exec /usr/bin/python3 -I -u '\(fakeClaude)' '\(transcript)' '\(controlFile)' '\(agentState)'"
        } else {
            command = "printf 'A scratch terminal of the VibeSwitcher sandbox.\\n'; echo \"{\\\"pid\\\": $$}\" > '\(agentState)'; exec /bin/cat"
        }
        host.spawn(SpawnRequest(cwd: folder, command: command, env: [:], cols: 100, rows: 32, keepShell: false,
                                label: label, agent: fakeClaude == nil ? nil : "claude")) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): done(error.message)
            case .success(let session):
                self.waitForPid(agentState, tries: 300) { pid in
                    guard let pid else { return done("the fake agent never said its pid") }
                    var hook = HookState(agent: .claude, tty: session.tty, lastEvent: "Stop", lastEventAt: Date().timeIntervalSince1970 - 30)
                    hook.agentPid = pid
                    hook.sessionId = UUID().uuidString
                    hook.cwd = folder
                    hook.firstPrompt = "What does the sandbox do?"
                    hook.lastMessage = "Drive it with scripts/sandbox-app.sh."
                    hook.transcriptPath = self.fakeClaude == nil ? nil : transcript
                    if self.fakeClaude != nil { try? hook.save(to: VibePaths.stateFile(tty: session.tty)) }
                    self.lock.withLock {
                        self.fakes[session.tty] = Fake(id: session.id, tty: session.tty, label: label, pid: pid, cwd: folder,
                                                       transcript: self.fakeClaude == nil ? nil : transcript,
                                                       control: self.fakeClaude == nil ? nil : controlFile)
                    }
                    self.store.refresh()
                    done(nil)
                }
            }
        }
    }

    /// The fake agent's pid, from the state it writes once it's drawn (checked every 0.1 s, `tries` times).
    private func waitForPid(_ path: String, tries: Int, _ done: @escaping (Int32?) -> Void) {
        let object = FileManager.default.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        if let pid = (object?["pid"] as? NSNumber)?.int32Value { return done(pid) }
        guard tries > 0 else { return done(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForPid(path, tries: tries - 1, done) }
    }

    /// The fake session's conversation so far: a question and an answer with some markdown.
    static let firstTurn: String = {
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let answer = "It's a copy of VibeSwitcher built from this worktree, on a session host of its own:\\n\\n"
            + "- the real window, chat and settings\\n- fake sessions only, like this one\\n- nothing of yours: "
            + "its own defaults, folder and host\\n\\nDrive it with `scripts/sandbox-app.sh`."
        return """
        {"type":"user","uuid":"u0","timestamp":"\(stamp)","isSidechain":false,"message":{"role":"user","content":"What does the sandbox do?"}}
        {"type":"assistant","uuid":"a0","timestamp":"\(stamp)","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"\(answer)"}]}}

        """
    }()

    /// A fake project lead: a session labelled as a lead, its board (tasks in every state, a question it withdrew)
    /// in its folder, and a conversation of short replies between tool calls, with a worker's FYI and a worker's question.
    func startLead(_ done: @escaping (String?) -> Void) {
        let slug = "sandbox-lead"
        let root = ((home as NSString).appendingPathComponent("projects/\(slug)") as NSString).standardizingPath
        let (lines, withdrawnAt) = Self.leadTurns(now: Date())
        let contract = LeadContract(goal: "A sandbox task.", acceptance: ["It shows."], boundaries: [], context: "")
        let tasks: [(String, String, LeadTask.Status)] = [
            ("sync-landing-base-with-2", "Sync landing-base with main", .running),
            ("gen-attention-badge", "Your GEN attention badge counts the right things", .blocked),
            ("ui-consistency-pass", "UI consistency pass over the sidebar", .blocked),
            ("landing-copy", "Landing page copy for the launch", .done),
            ("landing-hero", "Landing hero image and its dark variant", .done),
            ("sidebar-review", "Sidebar review fixes", .done),
            ("stats-cache", "Cache the stats endpoint", .done),
            ("old-onboarding", "Old onboarding flow", .abandoned),
        ]
        do {
            // Its board makes the folders it's in.
            try BoardStore(root: root).update { board in
                board.tasks = tasks.map { LeadTask(slug: $0.0, title: $0.1, contract: contract, status: $0.2) }
                var question = LeadQuestion(text: "Should the sidebar keep its review badges?", options: ["Keep them", "Drop them"],
                                            at: withdrawnAt - 300)
                question.withdrawnAt = withdrawnAt
                question.withdrawReason = "User asked to re-ask it. Sidebar review found: (1) the badges overlap the titles, (2) they don't clear when read."
                board.questions = [question]
            }
        } catch {
            return done("couldn't write the lead's board: \(error)")
        }
        startFake(label: "Lead · \(slug)", slug: slug, transcript: lines, done)
    }

    /// A fake worker on the fake lead's running task, in its worktree, named on the board as that task's worker.
    func startWorker(_ done: @escaping (String?) -> Void) {
        let lead = "sandbox-lead", slug = "sync-landing-base-with-2", label = "Worker: Sync landing-base with main"
        guard fakeList.contains(where: { $0.label.hasPrefix("Lead · ") }) else { return done("no fake lead: lead first") }
        startFake(label: label, slug: "\(lead)/.vibeswitcher/worktrees/\(slug)") { [weak self] problem in
            guard let self else { return }
            if let problem { return done(problem) }
            guard let fake = self.fakeList.first(where: { $0.label == label }) else { return done("the worker isn't listed") }
            let root = ((self.home as NSString).appendingPathComponent("projects/\(lead)") as NSString).standardizingPath
            do {
                try BoardStore(root: root).update { board in
                    guard let index = board.tasks.firstIndex(where: { $0.slug == slug }) else { return }
                    board.tasks[index].worker = fake.id.uuidString
                    board.tasks[index].worktree = fake.cwd
                }
            } catch {
                return done("couldn't write the lead's board: \(error)")
            }
            done(nil)
        }
    }

    /// An open question for you on the fake lead's board (`text`, or a made-up one), or (`answer`) its open questions
    /// answered; done once the lead's session reads it (`Session.leadAsks`).
    func ask(_ text: String, answer: Bool, _ done: @escaping (String?) -> Void) {
        guard let lead = fakeList.first(where: { $0.label.hasPrefix("Lead · ") }) else { return done("no fake lead: lead first") }
        let root = ((home as NSString).appendingPathComponent("projects/sandbox-lead") as NSString).standardizingPath
        do {
            try BoardStore(root: root).update { board in
                if answer {
                    for index in board.questions.indices where board.questions[index].isOpen {
                        board.questions[index].answer = board.questions[index].options.first ?? "Yes"
                        board.questions[index].answeredAt = Date().timeIntervalSince1970
                    }
                } else {
                    board.questions.append(LeadQuestion(text: text.isEmpty ? "Ship the landing page to everyone, or only to the testers first?" : text,
                                                        options: ["Everyone", "Testers first"]))
                }
            }
        } catch {
            return done("couldn't write the lead's board: \(error)")
        }
        waitFor({ [weak self] in self?.store.sessions.first { $0.tty == lead.tty }?.leadAsks == !answer }) { met in
            done(met ? nil : "the lead's session didn't read its board's question")
        }
    }

    /// The fake lead's conversation, ending a minute ago: the transcript's lines, and when it withdrew its question.
    static func leadTurns(now: Date) -> (String, Double) {
        var lines: [String] = []
        var clock = now.addingTimeInterval(-600)
        var withdrawnAt = clock.timeIntervalSince1970
        let formatter = ISO8601DateFormatter()
        func add(_ type: String, _ content: Any, usage: Bool = false) {
            clock = clock.addingTimeInterval(15)
            var message: [String: Any] = ["role": type, "content": content]
            if usage { message["model"] = "claude-opus-5-5"; message["usage"] = ["input_tokens": 224_000, "output_tokens": 21_600] }
            let line: [String: Any] = ["type": type, "uuid": "lead-\(lines.count)", "timestamp": formatter.string(from: clock),
                                       "isSidechain": false, "message": message]
            if let data = try? JSONSerialization.data(withJSONObject: line), let text = String(data: data, encoding: .utf8) { lines.append(text) }
        }
        func say(_ text: String) { add("assistant", [["type": "text", "text": text]]) }
        func tool(_ name: String, _ input: [String: Any], _ result: String) {
            let id = "toolu_\(lines.count)"
            add("assistant", [["type": "tool_use", "id": id, "name": name, "input": input]])
            add("user", [["type": "tool_result", "tool_use_id": id, "content": result]])
        }
        add("user", "Sync the landing pages with main, and finish the sidebar review.")
        say("On it. The board first.")
        tool("mcp__vibeswitcher__board", [:], "8 tasks: 1 working, 2 blocked, 4 done, 1 abandoned.")
        say("Two tasks wait on the base. Starting a worker on the sync.")
        tool("mcp__vibeswitcher__start", ["task": "sync-landing-base-with-2"], "Started.")
        say("Started sync-landing-base-with-2.")
        tool("Bash", ["command": "git log --oneline -3 origin/main"], "5f19605 Merge #272\n1a2b3c4 Landing copy\n9f8e7d6 Stats cache")
        // A blank message between two tool calls: nothing to show, so the calls are one row.
        say("   ")
        tool("Read", ["file_path": "/sandbox/docs/landing.md"], "# Landing")
        tool("Grep", ["pattern": "badge"], "Sidebar.swift:42")
        say("The base is at #272; the landing branch is two merges behind.")
        add("user", "[VibeSwitcher · worker sync-landing-base-with-2, not the user] The worker on sync-landing-base-with-2 asks: "
            + "FYI: origin/main 5f19605 tops at #272, so the sync needs no merge from main beyond it. I'll go on with the landing "
            + "copy and report when it's done; nothing for you to decide.\nAnswer with message(sync-landing-base-with-2, …).")
        tool("mcp__vibeswitcher__progress", ["text": "sync: base is #272"], "Noted.")
        say("Noted: nothing to do for the sync.")
        withdrawnAt = clock.addingTimeInterval(7).timeIntervalSince1970
        tool("mcp__vibeswitcher__withdraw_question", ["reason": "User asked to re-ask it."], "Withdrawn.")
        say("Withdrew the sidebar question: I'll ask it again once the review is in.")
        add("user", "[VibeSwitcher · worker ui-consistency-pass, not the user] The worker on ui-consistency-pass asks: "
            + "Should the GEN badge show 99+ past 99, or the exact count?\nAnswer with message(ui-consistency-pass, …).")
        tool("mcp__vibeswitcher__message", ["task": "ui-consistency-pass", "text": "99+"], "Sent.")
        add("assistant", [["type": "text", "text": "Told it 99+. Waiting on the two blocked tasks."]], usage: true)
        return (lines.joined(separator: "\n") + "\n", withdrawnAt)
    }

    var fakeList: [Fake] { lock.withLock { fakes.values.sorted { $0.label < $1.label } } }

    // MARK: The window

    private func openWindow() {
        let actions = WindowActions(
            newSession: { [weak self] preset, _ in self?.startFake(label: preset?.name ?? "Fake Claude") { _ in } },
            endSession: { [weak self] row in row.hostID.map { self?.host.kill($0) } },
            resume: { [weak self] _ in self?.refuse("resuming a conversation (a real agent)") },
            remove: { [weak self] row in
                guard let id = row.hostID else { return }
                self?.window?.pane.forget(id)
                self?.host.remove(id)
            },
            rename: { [weak self] _ in self?.refuse("renaming (an alert)") },
            pause: { [weak self] in self?.store.pause($0, for: $1) },
            resumePaused: { [weak self] in self?.store.resume($0) },
            openInTerminal: { [weak self] _ in self?.refuse("opening Terminal") },
            presets: { [weak self] folder in self?.preferences.presets.presets(for: folder) ?? [] },
            isLive: { [weak self] row in
                guard let id = row.hostID else { return row.session != nil }
                return self?.host.sessions.first { $0.id == id }?.isLive ?? false
            },
            canResume: { _ in false }, resumeCommand: { _ in nil },
            settings: { [weak self] in self?.showSettings(.general) },
            moveToWindow: { [weak self] _ in self?.refuse("moving a Terminal session") },
            startLead: { [weak self] _ in self?.refuse("starting a project lead (a real agent)") },
            projectsFolder: { [weak self] in (self?.home ?? "") + "/projects" },
            projectCreated: { [weak self] folder, _ in self?.refuse("starting a lead in the new project \(folder)") })
        let controller = MainWindowController(store: store, host: host, model: model, actions: actions, leads: leads, briefing: briefing)
        controller.pane.configure = { [weak self, weak controller] view in
            guard let self else { return }
            let dark = (view.window ?? controller?.window)?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            view.apply(self.preferences.appearance, darkMode: dark)
        }
        controller.pane.scrollbackLines = preferences.appearance.scrollbackLines
        window = controller
        if let window = controller.window { Sandbox.hide(window) }
        controller.presentOffscreen()
        (NSApp as? SandboxApplication)?.guardWindows()
    }

    /// Calls `done` once the window lists the first fake session (or after 30 s without it).
    private func waitForRow(tries: Int = 300, _ done: @escaping () -> Void) {
        let first = fakeList.first
        if first == nil || model.allRows.contains(where: { $0.hostID == first?.id }) || tries == 0 { return done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForRow(tries: tries - 1, done) }
    }

    func showSettings(_ tab: SettingsTab) {
        if settings == nil {
            settings = SettingsWindowController(
                preferences: preferences, setup: SetupModel(preferences: preferences, system: .fixed(hooks: [.claude: true, .codex: false], terminal: .notAsked, notifications: .off)),
                phoneAccess: PhoneAccess(store: store), recentProjects: { [] }, showWelcome: { [weak self] in self?.refuse("the welcome window") },
                host: host, briefing: briefing, policy: WorkingPolicyEditor())
        }
        guard let window = settings?.window else { return }
        Sandbox.hide(window)
        settings?.open(tab: tab)
        window.orderFrontRegardless()
        Sandbox.hide(window)
    }

    // MARK: The control channel

    /// What `scripts/sandbox-app.sh COMMAND` can ask, with what it does.
    static let commands: [(name: String, help: String)] = [
        ("status", "the sandbox's pid, host, fake sessions, windows and anything it refused"),
        ("chat [TEXT]", "selects the fake session whose title contains TEXT (the first one) and shows its chat"),
        ("terminal", "shows the selected session's terminal instead of its chat"),
        ("type TEXT", "types TEXT into the chat's composer (through its text view, as the keyboard does)"),
        ("send", "presses Return in the composer: the message goes to the fake session"),
        ("tell JSON", "hands the selected fake Claude a FakeClaude op, e.g. '{\"op\": \"permission\", \"command\": \"swift build\"}' or '{\"op\": \"work\"}' (see Tests/VibeSwitcherTests/FakeClaude.swift)"),
        ("new [LABEL]", "starts another fake session"),
        ("lead", "shows a fake project lead's chat, at its end (started the first time): a board of tasks, a withdrawn question, tool runs and workers' messages"),
        ("team", "starts a fake worker on the fake lead's running task, in its worktree (start the lead first); select it and tell it a permission to see it wait on its lead"),
        ("ask [TEXT]", "puts an open question for you (TEXT, or a made-up one) on the fake lead's board (start the lead first): its row reads needs you"),
        ("unfold", "shows the selected lead's team under its row in the sidebar"),
        ("answer", "answers the fake lead's open questions: its row reads as its terminal does again"),
        ("select TEXT", "selects the first row whose title, project or task contains TEXT"),
        ("home", "shows the start page"),
        ("settings [TAB]", "opens Settings on a tab: " + SettingsTab.allCases.map(\.rawValue).joined(separator: ", ")),
        ("sheet NAME", "shows a sheet on the window: " + Driver.sheets.map(\.name).joined(separator: ", ")),
        ("close settings|sheet", "closes Settings or the sheet"),
        ("shot NAME", "draws each window, light and dark, into the shots folder"),
        ("quit", "quits (the host and fake sessions end with it)"),
    ]

    /// The sheets `sheet NAME` shows: a sheet a change adds or touches goes here, so a worker can photograph it.
    static let sheets: [(name: String, make: (Driver) -> AnyView)] = [
        ("new-project", { driver in
            AnyView(NewProjectSheet(model: NewProjectModel(location: driver.home + "/projects"),
                                    created: { [weak driver] folder, _ in driver?.refuse("starting a lead in \(folder)") },
                                    close: { [weak driver] in driver?.closeSheet() }))
        }),
        // The lead's results as the Lead view lists them: an update whose screenshot post_update kept (its worktree
        // since removed), and an older one whose path into a cleaned-up worktree is gone.
        ("results", { driver in AnyView(ResultsList(updates: Driver.results(home: driver.home)).frame(width: 460).padding(12)) }),
        // A lead's Team tab: a task at work, two blocked (one after it, one with no word why), one whose verifier ended
        // twice, merged ones of which
        // one was audited, a question withdrawn lately and several answered, the Mac line, the Mac kept awake.
        // An all-done card with its batch's receipts summed (`LeadReceiptTotals`), its task list open.
        ("all-done", { driver in
            let mark = Driver.allDoneMark()
            return AnyView(AllDoneCard(mark: mark, chat: ChatModel(), expanded: [AllDoneCard.key(mark)]).frame(width: 560).padding(16))
        }),
        ("lead-team", { driver in
            let team = Driver.leadTeam()
            return AnyView(LeadTeamView(root: driver.home + "/projects/stakegen", board: team.board, seen: team.seen, open: { _ in },
                                        decisions: team.decisions, keepingAwake: true,
                                        mac: MacLine(text: "Mac: load 16.5, 5 team sessions across 3 projects", spoken: "", isOver: false))
                .frame(width: 360, height: 980))
        }),
    ]

    /// The `lead-team` sheet's board, as of now.
    static func leadTeam() -> (board: LeadBoard, seen: [String: MemberSeen], decisions: [LeadDecision]) {
        let now = Date().timeIntervalSince1970
        var board = LeadBoard()
        func task(_ title: String, _ status: LeadTask.Status, since: Double) -> LeadTask {
            var task = LeadTask(slug: Slug.make(title, taken: []), title: title,
                                contract: LeadContract(goal: title, acceptance: [], boundaries: [], context: ""), status: status)
            task.createdAt = now - 7_200
            task.since = now - since
            if status != .planned { task.worker = UUID().uuidString; task.worktree = "/tmp/\(task.slug)" }
            return task
        }
        var working = task("Payout ledger reconciles nightly", .running, since: 4 * 60)
        working.checkpoints = [LeadCheckpoint(text: "Ledger diff written; running the reconciliation tests", at: now - 120)]
        var after = task("Payout report shows reconciled totals", .blocked, since: 18 * 60)
        after.after = [working.slug]
        let unsaid = task("Stake history pages load under a second", .blocked, since: 18 * 60)
        var merged = (1...4).map { index -> LeadTask in
            var done = task("Merged task \(index)", .done, since: Double(index) * 3_000)
            done.worktree = nil
            done.merged = LeadMergeRecord(commit: "abc\(index)def0", tested: true, audited: index == 1 ? nil : false, at: now - Double(index) * 3_000)
            done.review = index == 1 ? .audit : LeadTask.Review.none
            done.receipt = Driver.receipt(worked: Double(index) * 1_500, opus: index * 900_000, fable: index == 1 ? 2_400_000 : nil, end: now - Double(index) * 3_000)
            return done
        }
        var audits = LeadAuditLedger()
        audits.rounds = 6
        audits.passed = true
        merged[0].audits = audits
        var abandoned = task("Old staking widget", .abandoned, since: 9_000)
        abandoned.abandonedBecause = "Replaced by the payout report."
        // auto_advance audited it again once after its verifier's agent quit; the retry's verifier ended too.
        var twice = task("Attention badge from stored scans", .review, since: 25 * 60)
        twice.review = .audit
        let verifier = UUID().uuidString
        twice.verifier = verifier
        twice.verifierRetry = LeadVerifierRetry(commit: "abc1234def0", first: LeadWitness.agentQuitEnding, verifiers: [verifier], second: "killed by SIGTERM")
        // Review none, raised to audit by the risk check (see `LeadRisk`) when its worker reported done.
        var raised = task("Clean up ended sessions' folders", .review, since: 2 * 60)
        raised.review = .audit
        raised.riskRaised = LeadRiskRaise(reason: "it has code that deletes or rewrites files or data (Sources/Cleanup.swift: try fm.removeItem(at: folder))",
                                          commit: "abc1234def0", byModel: false)
        board.tasks = merged + [working, after, unsaid, twice, raised, abandoned]

        var withdrawn = LeadQuestion(text: "Sidebar review found three overlapping rows. Re-plan the sidebar as one task, or fix each row on its own?\nThe review's notes are in progress.md.",
                                     options: ["One task", "Each row"], at: now - 1_500)
        withdrawn.withdrawnAt = now - 600
        withdrawn.withdrawReason = "User asked to re-ask it. Sidebar review found the rows were one bug."
        var answered: [LeadQuestion] = []
        for (index, (text, answer)) in [("Which payout fixes go first: 1 the rounding, 2 the late cron, 3 the stale cache?\nEach is a task of its own; 1 and 3 touch the same file.", "1 and 3"),
                                        ("The ledger can be fixed now (C) or redesigned (B). C now and plan B as its own task, or B only?", "C now + plan B as its own task"),
                                        ("Keep the old CSV export?", "Yes, for a month"),
                                        ("Run the reconciliation at 02:00 or 04:00 UTC?", "04:00"),
                                        ("Merge the stake history work with no audit (review none)?", "Yes")].enumerated() {
            var question = LeadQuestion(text: text, options: [], at: now - Double(index + 1) * 2_400)
            question.answer = answer
            question.answeredAt = question.askedAt + 300
            answered.append(question)
        }
        board.questions = answered.reversed() + [withdrawn]
        board.refreshScores(now: now)

        var seen: [String: MemberSeen] = [:]
        seen[working.worker!] = MemberSeen(live: true, needsYou: false, working: true, activity: "Running swift test", since: Date(timeIntervalSince1970: now - 60),
                                           startedAt: Date(timeIntervalSince1970: now - 240))
        seen[verifier] = MemberSeen(live: false, needsYou: false, working: false, activity: nil, since: nil, startedAt: Date(timeIntervalSince1970: now - 900))
        let decisions = (1...16).map { LeadDecision(at: now - Double($0) * 900, text: "Earlier decision \($0)", why: "") }
        return (board, seen, decisions)
    }

    /// A merged task's receipt: `opus` tokens of its worker's (mostly cache reads, as a worker's are), `fable` of its
    /// verifier's.
    static func receipt(worked: Double, opus: Int, fable: Int?, end: Double) -> LeadReceipt {
        func tokens(_ total: Int, _ model: String) -> LeadTokens {
            let read = total * 9 / 10, write = total / 20, output = total / 50
            var tokens = LeadTokens(input: total - read - write - output, output: output, cacheRead: read, cacheWrite: write, cacheWrite1h: write,
                                    sessions: 1, models: [model])
            let price = LeadPrices.price(model)!
            tokens.cost = (Double(tokens.input) * price.input + Double(output) * price.output + Double(read) * price.cacheRead
                           + Double(write) * price.input * 2) / 1_000_000
            return tokens
        }
        return LeadReceipt(ending: .merged, startedAt: end - worked * 1.6, endedAt: end, worked: worked, worker: tokens(opus, "claude-opus-5-5"),
                           verifier: fable.map { tokens($0, "claude-fable-5-1") }, rounds: fable == nil ? 0 : 1, tests: 1_412)
    }

    /// The `all-done` sheet's mark: a batch of four, three merged with receipts and one folded.
    static func allDoneMark() -> LeadAllDone {
        let now = Date().timeIntervalSince1970
        let made: [(String, String, LeadAllDone.Task.Outcome, LeadReceipt?)] = [
            ("payout-ledger", "Payout ledger reconciles nightly", .merged, receipt(worked: 5_400, opus: 14_800_000, fable: 3_100_000, end: now - 900)),
            ("payout-report", "Payout report shows reconciled totals", .merged, receipt(worked: 2_700, opus: 6_200_000, fable: nil, end: now - 600)),
            ("stake-history", "Stake history pages load under a second", .merged, receipt(worked: 1_800, opus: 4_100_000, fable: nil, end: now - 300)),
            ("old-widget", "Old staking widget", .folded, nil),
        ]
        var tasks: [LeadTask] = []
        for (slug, title, _, receipt) in made {
            var task = LeadTask(slug: slug, title: title, contract: LeadContract(goal: title, acceptance: [], boundaries: [], context: ""), status: .done)
            task.receipt = receipt
            tasks.append(task)
        }
        var mark = LeadAllDone(id: "sandbox-all-done", at: now - 60, since: now - 4 * 3_600, tasks: made.map { .init(slug: $0.0, title: $0.1, outcome: $0.2) })
        mark.summary = .init(headline: "Payouts now reconcile every night, and the stake history loads fast.", bullets: [
            "The payout ledger is checked against the bank's records each night, and the report shows the reconciled totals.",
            "Stake history pages load in under a second.",
        ], byModel: true)
        mark.receipts = LeadReceiptTotals(tasks)
        return mark
    }

    /// Two updates for the `results` sheet, their images in a scratch project under the sandbox's home.
    static func results(home: String) -> [LeadUpdate] {
        let project = home + "/projects/results", worktree = project + "/.vibeswitcher/worktrees/shots-a"
        let shot = worktree + "/.build/sandbox-shots/board.png"
        let symbol = NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: "Done")?
            .withSymbolConfiguration(.init(pointSize: 96, weight: .regular))
        if let tiff = symbol?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? VibePaths.ensurePrivate(URL(fileURLWithPath: (shot as NSString).deletingLastPathComponent))
            try? VibePaths.writePrivate(png, to: URL(fileURLWithPath: shot))
        }
        var kept = LeadUpdate(title: "Board shows the done card", body: "Checked in the sandbox; the screenshot is a kept copy.")
        kept.images = (try? KeptImages(folder: project + "/.vibeswitcher").keep([shot], as: "updates/\(kept.id)", relativeTo: project)) ?? []
        try? FileManager.default.removeItem(atPath: worktree)
        var gone = LeadUpdate(title: "Older result", body: "Posted before images were kept: its screenshot was in a worktree since cleaned up.",
                              images: [worktree + "/.build/all-done-snapshots/card.png"])
        gone.at = kept.at - 600
        return [gone, kept]
    }

    private func listen() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.takeRequests() }
        timer.resume()
        poller = timer
    }

    private var answering: Set<String> = []

    private func takeRequests() {
        guard ready, let names = try? FileManager.default.contentsOfDirectory(atPath: control.path) else { return }
        for name in names.sorted() where name.hasPrefix("req-") && !answering.contains(name) {
            let file = control.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file) else { continue }
            try? FileManager.default.removeItem(at: file)
            let id = String(name.dropFirst("req-".count))
            answering.insert(name)
            let words = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
                .filter { !$0.isEmpty }
            Breadcrumbs.shared.note("sandbox: asked \(words.first ?? "nothing")")
            Sandbox.doing = words.first ?? ""
            handle(words) { [weak self] ok, text in
                guard let self else { return }
                self.answering.remove(name)
                let reply = (ok ? "ok\n" : "error\n") + text + (text.hasSuffix("\n") || text.isEmpty ? "" : "\n")
                try? VibePaths.writePrivate(Data(reply.utf8), to: self.control.appendingPathComponent("rep-\(id)"))
            }
        }
    }

    private func handle(_ words: [String], reply: @escaping (Bool, String) -> Void) {
        let rest = words.dropFirst().joined(separator: " ")
        switch words.first ?? "" {
        case "status": reply(true, status())
        case "chat": chat(rest, reply)
        case "terminal":
            model.showsChat = false
            reply(true, "terminal shown")
        case "type":
            guard let composer = composer() else { return reply(false, "no composer: show a fake session's chat first (chat)") }
            composer.window?.makeFirstResponder(composer)
            composer.insertText(rest, replacementRange: composer.selectedRange())
            reply(true, "typed \(rest.count) characters")
        case "send":
            guard let composer = composer() else { return reply(false, "no composer: show a fake session's chat first (chat)") }
            composer.window?.makeFirstResponder(composer)
            composer.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            reply(true, "sent")
        case "tell": tell(rest, reply)
        case "new":
            startFake(label: rest.isEmpty ? "Fake Claude \(fakeCount + 1)" : rest) { problem in
                reply(problem == nil, problem ?? "started")
            }
        case "lead":
            // Started once; then its chat, once its board is read, at the end (where its pinned questions are).
            let show = { [weak self] in
                guard let self else { return }
                self.chat("lead") { ok, text in
                    guard ok else { return reply(ok, text) }
                    self.waitFor({ [weak self] in self?.model.selectedRow.flatMap { self?.leads.lead(for: $0) } != nil }) { [weak self] met in
                        self?.window?.chat.scrollToBottom()
                        self?.settle { reply(met, met ? text + ", its team read" : "the lead's board wasn't read") }
                    }
                }
            }
            if fakeList.contains(where: { $0.label.hasPrefix("Lead · ") }) { return show() }
            startLead { problem in if let problem { reply(false, problem) } else { show() } }
        case "team": startWorker { problem in reply(problem == nil, problem ?? "worker started") }
        case "unfold":
            guard let row = model.selectedRow else { return reply(false, "nothing selected") }
            if !model.expandedTeams.contains(row.id) { model.toggleTeam(row.id) }
            settle { reply(true, "\(row.title)'s team shown") }
        case "ask": ask(rest, answer: false) { problem in reply(problem == nil, problem ?? "the lead asks you") }
        case "answer": ask("", answer: true) { problem in reply(problem == nil, problem ?? "its questions answered") }
        case "select":
            guard let row = WindowGroups.filter(model.sections, query: rest).first?.rows.first else { return reply(false, "no row matches \(rest)") }
            model.selectedID = row.id
            reply(true, "selected \(row.title)")
        case "home":
            model.showHome()
            reply(true, "start page shown")
        case "settings":
            guard let tab = rest.isEmpty ? .general : SettingsTab(rawValue: rest) else {
                return reply(false, "no tab \(rest): " + SettingsTab.allCases.map(\.rawValue).joined(separator: ", "))
            }
            showSettings(tab)
            settle { reply(true, "settings shown on \(tab.rawValue)") }
        case "sheet": showSheet(rest, reply)
        case "close":
            switch rest {
            case "settings": settings?.close()
            case "sheet": closeSheet()
            default: return reply(false, "close settings or close sheet")
            }
            reply(true, "closed \(rest)")
        case "shot": shot(rest.isEmpty ? "shot" : rest, reply)
        case "quit":
            reply(true, "quitting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        case "help", "":
            reply(true, Self.commands.map { "\($0.name): \($0.help)" }.joined(separator: "\n"))
        default:
            reply(false, "no command \(words[0]); these are:\n" + Self.commands.map { "  \($0.name): \($0.help)" }.joined(separator: "\n"))
        }
    }

    private func status() -> String {
        let app = NSApp as? SandboxApplication
        var lines = ["pid \(getpid())", "state \(state.path)", "home \(home)", "vibeswitcher \(VibePaths.root.path)",
                     "defaults \(state.appendingPathComponent("defaults.plist").path)",
                     "host \(host.state) on \(VibePaths.hostSocket.path), started with: \(host.hostArguments.joined(separator: " "))",
                     "shots \(shots.path)"]
        for fake in fakeList { lines.append("fake \(fake.label) on \(fake.tty), pid \(fake.pid), host id \(fake.id)") }
        for window in NSApp.windows where window.isVisible {
            lines.append("window \(type(of: window)) “\(window.title)” \(NSStringFromRect(window.frame)) alpha \(window.alphaValue)")
        }
        lines.append("selected \(model.selectedRow?.title ?? "none"), chat \(model.showsChat ? "on" : "off"), chat state \(window?.chat.state ?? .none)")
        lines.append("active \(NSApp.isActive), activation policy \(NSApp.activationPolicy().rawValue)")
        for line in (app?.refused ?? []) + refused { lines.append("refused \(line)") }
        for line in app?.foundOnScreen ?? [] { lines.append("on screen \(line)") }
        return lines.joined(separator: "\n")
    }

    private func chat(_ text: String, _ reply: @escaping (Bool, String) -> Void) {
        let fake = fakeList.first { text.isEmpty || $0.label.localizedCaseInsensitiveContains(text) } ?? (text.isEmpty ? nil : fakeList.first)
        guard let fake else { return reply(false, "no fake session\(text.isEmpty ? "" : " matching \(text)")") }
        model.select(hostID: fake.id)
        model.showsChat = true
        waitFor({ [weak self] in self?.window?.chat.state == .ready && self?.composer() != nil }) { [weak self] met in
            guard let self else { return }
            self.window?.chat.poll()
            self.settle { reply(met, met ? "chat of \(fake.label) shown" : "the chat of \(fake.label) didn't load: \(self.window?.chat.state ?? .none)") }
        }
    }

    private func tell(_ json: String, _ reply: @escaping (Bool, String) -> Void) {
        guard let op = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return reply(false, "not a JSON object: \(json)") }
        let selected = model.selectedRow?.hostID
        guard let fake = fakeList.first(where: { $0.id == selected }) ?? fakeList.first, let file = fake.control,
              let handle = FileHandle(forWritingAtPath: file) else { return reply(false, "no fake Claude to tell") }
        handle.seekToEndOfFile()
        handle.write(Data((json + "\n").utf8))
        try? handle.close()
        // A permission prompt: the hook state a real Claude leaves on one, so the session waits on input as one does.
        let stateFile = VibePaths.stateFile(tty: fake.tty)
        if op["op"] as? String == "permission", var hook = HookState.load(from: stateFile) {
            hook.lastEvent = "PermissionRequest"
            hook.lastEventAt = Date().timeIntervalSince1970
            hook.toolName = "Bash"
            hook.request = "Bash: " + (op["command"] as? String ?? "")
            try? hook.save(to: stateFile)
        }
        reply(true, "told \(fake.label) \(json)")
    }

    /// The sheet in a window of its own beside the main one, off screen as it is: attached with `beginSheet`, AppKit
    /// would move the main window on screen to show it. Its content is the sheet's, at the size `.sheet` gives it.
    private func showSheet(_ name: String, _ reply: @escaping (Bool, String) -> Void) {
        guard let entry = Self.sheets.first(where: { $0.name == name }) else {
            return reply(false, "no sheet \(name): " + Self.sheets.map(\.name).joined(separator: ", "))
        }
        guard let parent = window?.window else { return reply(false, "no window") }
        closeSheet()
        let content = NSHostingController(rootView: entry.make(self))
        let sheet = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        sheet.contentViewController = content
        // As tall as its content (a Form's own height is whatever it's given), at most as tall as the window.
        let measure = NSHostingView(rootView: entry.make(self).fixedSize(horizontal: false, vertical: true))
        let fitting = measure.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            sheet.setContentSize(NSSize(width: fitting.width, height: min(fitting.height, parent.frame.height - 60)))
        }
        sheet.appearance = parent.appearance
        Sandbox.hide(sheet)
        self.sheet = sheet
        sheetName = name
        sheet.orderFrontRegardless()
        Sandbox.hide(sheet)
        settle { reply(true, "sheet \(name) shown") }
    }

    func closeSheet() {
        sheet?.orderOut(nil)
        sheet = nil
        sheetName = nil
    }

    /// The composer's text view in the window's chat, when it's shown.
    private func composer() -> NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? ComposerNSTextView, !text.isHiddenOrHasHiddenAncestor { return text }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return window?.window?.contentView.flatMap(find)
    }

    /// Checks `condition` every 0.1 s for up to 30 s.
    private func waitFor(_ condition: @escaping () -> Bool, tries: Int = 300, _ done: @escaping (Bool) -> Void) {
        if condition() { return done(true) }
        guard tries > 0 else { return done(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitFor(condition, tries: tries - 1, done) }
    }

    /// Lets SwiftUI and AppKit lay out and draw what just changed (a few turns of the run loop), then `done`.
    private func settle(_ done: @escaping () -> Void) {
        for window in NSApp.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            for window in NSApp.windows where window.isVisible {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            DispatchQueue.main.async(execute: done)
        }
    }

    // MARK: Shots

    /// Each window the sandbox shows (the main window, Settings when open, the sheet when shown), drawn in light and in
    /// dark: `NAME-main-light.png`, `NAME-main-dark.png`, `NAME-settings-light.png`…
    private func shot(_ name: String, _ reply: @escaping (Bool, String) -> Void) {
        let base = Sandbox.fileName(name)
        var windows: [(label: String, window: NSWindow)] = []
        if let main = window?.window, main.isVisible { windows.append(("main", main)) }
        if let sheet, sheet.isVisible { windows.append(("sheet-\(sheetName ?? "sheet")", sheet)) }
        if let settings = settings?.window, settings.isVisible { windows.append(("settings", settings)) }
        guard !windows.isEmpty else { return reply(false, "no window to draw") }
        if model.showsChat { window?.chat.poll() }
        var written: [String] = []
        var failed: [String] = []
        func take(_ appearances: ArraySlice<(String, NSAppearance.Name)>) {
            guard let (mode, appearance) = appearances.first else {
                windows.forEach { $0.window.appearance = nil }
                window?.pane.reconfigureAll()
                return reply(failed.isEmpty, (written + failed.map { "couldn't draw \($0)" }).joined(separator: "\n"))
            }
            windows.forEach { $0.window.appearance = NSAppearance(named: appearance) }
            window?.pane.reconfigureAll()
            settle { [weak self] in
                guard let self else { return }
                for (label, window) in windows {
                    let file = self.shots.appendingPathComponent("\(base)-\(label)-\(mode).png")
                    if Sandbox.draw(window, to: file) { written.append(file.path) } else { failed.append(file.lastPathComponent) }
                }
                take(appearances.dropFirst())
            }
        }
        take([("light", .aqua), ("dark", .darkAqua)][...])
    }
}
