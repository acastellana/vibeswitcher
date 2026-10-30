import AppKit
import Combine
import CryptoKit
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
            refuse("usage: VibeSwitcher --sandbox STATE --shots DIR [--minutes N] [--fake-claude PATH] [--empty] (absolute paths); "
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
                            fakeClaude: value("--fake-claude"), minutes: minutes, empty: arguments.contains("--empty"))
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
    /// Started with no session (`run --empty`): no session host either until something asks for one, as at a first launch.
    let empty: Bool
    let store: SessionStore
    let host: HostClient
    let model = WindowModel()
    let preferences = Preferences()
    lazy var leads: LeadController = {
        // A lead `startlead` starts runs a fake Claude, never a real one (its arguments after the fake's own are ignored).
        let controller = LeadController(host: host, store: store) { [weak self] folder in self?.leadCommand(folder) ?? "exec /bin/cat" }
        // A lead's questions to you would be alerts: none in the sandbox.
        controller.confirm = { [weak self] title, text, buttons in
            self?.refuse("a lead's question (\(title) \(text))")
            return buttons.count - 1
        }
        controller.answersTrust = false
        // The fake Claude needs nothing installed.
        controller.preflight = { _ in nil }
        return controller
    }()
    lazy var briefing = BriefingModel(
        snapshot: { [weak self] in BriefingModel.Snapshot(boards: self?.leads.boards ?? [:], sessions: self?.store.sessions ?? []) },
        language: { .preferred() }, keyStore: BriefingKey(saved: AppProof.MemorySecret()), generate: { _ in nil })
    /// Push to talk with no microphone and no OpenAI: a recorder that hands over a made-up recording, an HTTP client
    /// that answers a made-up transcript, a key in memory (`dictation key|nokey|press|release|note`).
    let dictationKey = AppProof.MemorySecret()
    lazy var dictation: DictationController = {
        let controller = DictationController(keyStore: dictationKey, recorder: SandboxRecorder(), microphone: SandboxMicrophone(),
                                             transcription: OpenAITranscription(client: SandboxTranscriber()), findKey: { nil })
        controller.openSettings = { [weak self] in self?.showSettings(.general) }
        // A fake Claude's /voice (`tell '{"op": "voice", "mode": "hold"}'`): never the user's Claude settings.
        controller.claudeSettings = { _ in ClaudeVoiceSettings() }
        controller.checkKey()
        return controller
    }()
    var window: MainWindowController?
    /// The main window's actions (`sheet new-session-menu` lists the empty sidebar's menu from them).
    var windowActions: WindowActions?
    var settings: SettingsWindowController?
    var sheet: NSWindow?
    var sheetName: String?
    /// The phone's web app, once `phone` serves it.
    var phone: PhoneAccess?
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
        /// nil: a plain shell, which no scan takes for an agent.
        var agent: Agent? = .claude
    }
    /// The key the app proves itself with: its own, or (`unproved`) one the host doesn't hold.
    final class SandboxKey: @unchecked Sendable {
        let own = AppProof.MemoryStore()
        var stranger: SymmetricKey?
        var current: SymmetricKey? { stranger ?? own.key() }
    }
    private let key: SandboxKey
    private let lock = NSLock()
    /// By tty (read on the scanner's queue).
    private var fakes: [String: Fake] = [:]
    private var fakeCount = 0

    var home: String { VibePaths.home }
    let watchdog = HangWatchdog(samples: false)
    var control: URL { state.appendingPathComponent("control", isDirectory: true) }

    init(state: URL, shots: URL, fakeClaude: String?, minutes: Double, empty: Bool) {
        self.state = state
        self.shots = shots
        self.fakeClaude = fakeClaude
        self.minutes = minutes
        self.empty = empty
        // Its own host: its own lock (not the user's host.lock: a host on it is the user's, which reads its vault key
        // from the Keychain), its socket in this home, ending with this process however it ends.
        let key = SandboxKey()
        self.key = key
        host = HostClient(socketPath: VibePaths.hostSocket.path, appKey: { key.current })
        // The lead's vault calls prove the app with the same key, as the app's do with its Keychain one (`HostClient.appKey`).
        HostConnection.appKey = key.own.key()
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
        host.$sessions.receiveLatest(on: RunLoop.main).sink { [weak self] in self?.store.updateHosted($0) }.store(in: &cancellables)
        store.$sessions.combineLatest(host.$sessions, host.$state, store.$tableRead).receiveLatest(on: RunLoop.main)
            .sink { [weak self] sessions, hosted, state, table in
                self?.model.update(sessions: sessions, hosted: hosted, table: table, hostAnswered: state != .connecting)
            }
            .store(in: &cancellables)
        // A fake agent leaves with its session, as a real one does.
        host.$sessions.receiveLatest(on: RunLoop.main).sink { [weak self] sessions in
            guard let self else { return }
            let live = Set(sessions.filter(\.isLive).map(\.tty))
            self.lock.withLock { self.fakes = self.fakes.filter { live.contains($0.key) } }
        }.store(in: &cancellables)
        store.hostScreens = { [weak self] in self?.host.screens ?? [:] }
        store.requestHostScreens = { [weak self] in self?.host.refreshScreens(ttys: $0) }
        _ = leads
        // Its own freezes, reported as the app's are (in its own ~/.vibeswitcher/debug), without `sample`.
        watchdog.describeState = { [weak self] in self?.window?.debugState() ?? "window never opened" }
        watchdog.start()
        store.start()
        let first: (@escaping (String?) -> Void) -> Void = empty ? { $0(nil) } : { self.startFake(label: "Fake Claude", $0) }
        first { [weak self] problem in
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
        RunnableCommand.Script.removeAll()
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
        let fakes = lock.withLock { self.fakes }
        let launched = Date().addingTimeInterval(-3600)
        var table = UIBench.processTable(agents: fakes.filter { $0.value.agent == .claude }.mapValues(\.pid), launched: launched)
        for (tty, fake) in fakes where fake.agent == .codex {
            table[fake.pid] = ProcInfo(pid: fake.pid, ppid: 60_000, tty: tty, comm: "codex", startTime: launched, agent: .codex)
        }
        return table
    }

    private func cwd(_ pid: Int32) -> String? {
        lock.withLock { fakes.values.first { $0.pid == pid }?.cwd }
    }

    /// A new fake session: FakeClaude (or, without its script, a shell's `cat`) on a scratch pty of the sandbox's host,
    /// with a short conversation already in its transcript and the hook state a Claude session leaves. `agent` .codex:
    /// the same fake, told apart as Codex; nil: a shell's `cat`, with no agent at all.
    func startFake(label: String, slug named: String? = nil, transcript firstLines: String = Driver.firstTurn, agent: Agent? = .claude,
                   title: String? = nil, _ done: @escaping (String?) -> Void) {
        let fakeClaude = agent == nil ? nil : self.fakeClaude
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
            // A terminal title as Claude Code sets one (OSC 0), when given: 2.1.311 titles its sessions "worker-<slug>".
            let titled = title.map { "printf '\\033]0;%s\\007' '\($0)'; " } ?? ""
            command = titled + "exec /usr/bin/python3 -I -u '\(fakeClaude)' '\(transcript)' '\(controlFile)' '\(agentState)'"
        } else {
            command = "printf 'A scratch terminal of the VibeSwitcher sandbox.\\n'; echo \"{\\\"pid\\\": $$}\" > '\(agentState)'; exec /bin/cat"
        }
        host.spawn(SpawnRequest(cwd: folder, command: command, env: [:], cols: 100, rows: 32, keepShell: false,
                                label: label, agent: fakeClaude == nil ? nil : agent?.rawValue)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): done(error.message)
            case .success(let session):
                self.adopt(session, label: label, folder: folder, transcript: fakeClaude == nil ? nil : transcript,
                           control: fakeClaude == nil ? nil : controlFile, agentState: agentState, agent: agent, done)
            }
        }
    }

    /// A fake agent's session, once its agent said its pid: listed as the agent it is, with the hook state a Claude
    /// session leaves (`transcript` nil: a plain shell's, with none).
    private func adopt(_ session: HostSession, label: String, folder: String, transcript: String?, control: String?, agentState: String,
                       agent: Agent?, _ done: @escaping (String?) -> Void) {
        waitForPid(agentState, tries: 300) { pid in
            guard let pid else { return done("the fake agent never said its pid") }
            var hook = HookState(agent: agent ?? .claude, tty: session.tty, lastEvent: "Stop", lastEventAt: Date().timeIntervalSince1970 - 30)
            hook.agentPid = pid
            hook.sessionId = UUID().uuidString
            hook.cwd = folder
            hook.firstPrompt = "What does the sandbox do?"
            hook.lastMessage = "Drive it with scripts/sandbox-app.sh."
            hook.transcriptPath = transcript
            if transcript != nil { try? hook.save(to: VibePaths.stateFile(tty: session.tty)) }
            self.lock.withLock {
                self.fakes[session.tty] = Fake(id: session.id, tty: session.tty, label: label, pid: pid, cwd: folder,
                                               transcript: transcript, control: control, agent: agent)
            }
            self.store.refresh()
            done(nil)
        }
    }

    /// The project `startlead` starts a real lead in, and its fake Claude's files.
    private var newLead: (folder: String, transcript: String, control: String, state: String) {
        let folder = (home as NSString).appendingPathComponent("projects/new-lead")
        let files = state.appendingPathComponent("lead-new-lead", isDirectory: true).path
        let transcript = (home as NSString).appendingPathComponent(".claude/projects/-sandbox-new-lead/lead.jsonl")
        return (folder, transcript, files + "/control.jsonl", files + "/state.json")
    }

    /// What a lead started in `folder` runs: the fake Claude on `startlead`'s files (a shell's `cat` without its script).
    func leadCommand(_ folder: String) -> String {
        let lead = newLead
        guard let fakeClaude else { return "exec /bin/cat" }
        return "exec /usr/bin/python3 -I -u '\(fakeClaude)' '\(lead.transcript)' '\(lead.control)' '\(lead.state)'"
    }

    /// A real lead start, as Project Lead's (`LeadController.startLead`: its vault grant, its launch, its session), in
    /// a new repository, its agent a fake Claude. After `run --empty` it's the first thing to ask the session host.
    func startRealLead(_ reply: @escaping (Bool, String) -> Void) {
        let lead = newLead
        let files = FileManager.default
        for path in [lead.folder, (lead.transcript as NSString).deletingLastPathComponent, (lead.state as NSString).deletingLastPathComponent] {
            try? VibePaths.ensurePrivate(URL(fileURLWithPath: path))
        }
        if !files.fileExists(atPath: lead.folder + "/.git") {
            try? VibePaths.writePrivate(Data("# New lead\n".utf8), to: URL(fileURLWithPath: lead.folder + "/README.md"))
            for args in [["init", "-q", "-b", "main"], ["config", "user.email", "sandbox@example.invalid"], ["config", "user.name", "Sandbox"],
                         ["add", "README.md"], ["commit", "-q", "-m", "First commit"]] {
                guard Git.run(args, in: lead.folder).ok else { return reply(false, "couldn't make its repository: git \(args.joined(separator: " "))") }
            }
        }
        try? VibePaths.writePrivate(Data(Driver.firstTurn.utf8), to: URL(fileURLWithPath: lead.transcript))
        try? VibePaths.writePrivate(Data(), to: URL(fileURLWithPath: lead.control))
        try? files.removeItem(atPath: lead.state)
        let hostWas = host.state
        let refusedBefore = refused.count
        leads.startLead(in: lead.folder)
        let label = "Lead · new-lead"
        waitFor({ [weak self] in
            guard let self else { return true }
            return self.host.sessions.contains { $0.label == label && $0.isLive } || self.refused.count > refusedBefore
        }) { [weak self] _ in
            guard let self else { return }
            guard let session = self.host.sessions.first(where: { $0.label == label && $0.isLive }) else {
                return reply(false, "the lead didn't start: \(self.refused.dropFirst(refusedBefore).joined(separator: "; "))")
            }
            self.adopt(session, label: label, folder: lead.folder, transcript: lead.transcript, control: lead.control, agentState: lead.state,
                       agent: .claude) { problem in
                if let problem { return reply(false, problem) }
                self.chat("Lead") { ok, text in
                    reply(ok, ok ? "lead started (the host was \(hostWas) before): \(text)" : text)
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
    func startLead(transcript: String? = nil, _ done: @escaping (String?) -> Void) {
        let slug = "sandbox-lead"
        let root = ((home as NSString).appendingPathComponent("projects/\(slug)") as NSString).standardizingPath
        var (lines, withdrawnAt) = Self.leadTurns(now: Date())
        if let transcript { lines = transcript }
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

    /// A fake worker on the fake lead's running task, in its worktree, named on the board as that task's worker; with
    /// `title`, titled as Claude Code titles it ("worker-<slug>").
    func startWorker(title: String? = nil, _ done: @escaping (String?) -> Void) {
        let lead = "sandbox-lead", slug = "sync-landing-base-with-2", label = "Worker: Sync landing-base with main"
        guard fakeList.contains(where: { $0.label.hasPrefix("Lead · ") }) else { return done("no fake lead: lead first") }
        startFake(label: label, slug: "\(lead)/.vibeswitcher/worktrees/\(slug)", title: title) { [weak self] problem in
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

    /// 2026-10-28's sidebar: the fake lead's worker and a verifier on its running task, titled as Claude Code 2.1.311
    /// names sessions ("worker-<slug>", "verify-<slug>"), and the lead's agent moved into its `.vibeswitcher/worktrees`
    /// (its hooks' cwd, as after a `cd` there). Its team still folds under it.
    func startNamedTeam(_ done: @escaping (String?) -> Void) {
        let slug = "sync-landing-base-with-2"
        guard let lead = fakeList.first(where: { $0.label.hasPrefix("Lead · ") }) else { return done("no fake lead: lead first") }
        startWorker(title: "worker-\(slug)") { [weak self] problem in
            guard let self else { return }
            if let problem { return done(problem) }
            self.startFake(label: "Verifier: Sync landing-base with main", slug: "sandbox-lead/.vibeswitcher/worktrees/\(slug)",
                           title: "verify-\(slug)") { [weak self] problem in
                guard let self else { return }
                if let problem { return done(problem) }
                let file = VibePaths.stateFile(tty: lead.tty)
                guard var hook = HookState.load(from: file) else { return done("the lead has no hook state") }
                hook.cwd = (lead.cwd as NSString).appendingPathComponent(".vibeswitcher/worktrees")
                do { try hook.save(to: file) } catch { return done("couldn't move the lead's cwd: \(error)") }
                self.store.refresh()
                let moved = hook.cwd
                self.waitFor({ [weak self] in self?.store.sessions.first { $0.tty == lead.tty }?.cwd == moved }) { met in
                    done(met ? nil : "the lead's session didn't read its new cwd")
                }
            }
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

    /// More on the fake lead's board, for what the phone and the Lead view show of it: a proposal whose timer runs, a
    /// blocking question the lead revised, the merged tasks' merges, a task the risk check raised to audit, one
    /// reverted, an all-done card with its receipts, and two results.
    func extras(_ done: @escaping (String?) -> Void) {
        guard fakeList.contains(where: { $0.label.hasPrefix("Lead · ") }) else { return done("no fake lead: lead first") }
        let root = ((home as NSString).appendingPathComponent("projects/sandbox-lead") as NSString).standardizingPath
        let now = Date().timeIntervalSince1970
        let contract = LeadContract(goal: "A sandbox task.", acceptance: ["It shows."], boundaries: [], context: "")
        do {
            try BoardStore(root: root).update { board in
                for index in board.tasks.indices where board.tasks[index].status == .done {
                    board.tasks[index].merged = LeadMergeRecord(commit: "abc\(index)def0", tested: true, audited: false, at: now - Double(index + 1) * 1_800)
                    board.tasks[index].review = LeadTask.Review.none
                }
                var raised = LeadTask(slug: "clean-ended-folders", title: "Clean up ended sessions' folders", contract: contract, status: .review)
                raised.review = .audit
                raised.since = now - 120
                raised.riskRaised = LeadRiskRaise(reason: "it deletes files (Sources/Cleanup.swift: try fm.removeItem(at: folder))", commit: "abc1234def0", byModel: false)
                var reverted = LeadTask(slug: "paste-images", title: "Paste images into the chat", contract: contract, status: .reverted)
                reverted.merged = LeadMergeRecord(commit: "abc9def0", tested: true, audited: false, at: now - 6_000)
                reverted.merged?.revertedBy = "fed9cba0"
                reverted.merged?.revertReason = "The chat froze on a large paste; reverted, a fix-forward is planned."
                board.tasks += [raised, reverted]
                board.questions.append(LeadQuestion(text: "Ship the hero image as WebP only, or keep a PNG fallback?", options: ["WebP only", "Keep a PNG fallback"],
                                                    priority: .whenever, whyNow: "The landing copy merges next; its images need one format.",
                                                    proposal: "Keep a PNG fallback", decideIn: 10, at: now - 150))
                var revised = LeadQuestion(text: "Launch to the testers on Thursday, or wait for the sidebar fixes?", options: ["Thursday", "Wait for the fixes"],
                                           priority: .blocking, whyNow: "The testers' invite goes out tomorrow morning.", at: now - 900)
                revised.revisions = [LeadQuestion.Revision(text: "Launch to everyone on Thursday?", options: ["Yes", "No"],
                                                           note: "Only the testers get it first", at: now - 400)]
                board.questions.append(revised)
                board.allDone = [Driver.allDoneMark()]
                board.updates = Driver.results(home: home)
                board.refreshScores(now: now)
            }
        } catch {
            return done("couldn't write the lead's board: \(error)")
        }
        done(nil)
    }

    /// The phone's web app, served for this sandbox (`PhoneAccess.serveInSandbox`) on a free port of 127.0.0.1, its
    /// lead views reading this sandbox's leads: STATE/phone.json says where, the phone's token, and the headers
    /// `tailscale serve` would add (a scratch proxy in front of it adds them; the web app is the Mac's, as served).
    private func servePhone(_ reply: @escaping (Bool, String) -> Void) {
        let status = TailscaleCLI.Status(dnsName: "sandbox-mac.tail0000.ts.net", login: "sandbox@example.invalid", httpsAvailable: true)
        let access = phone ?? PhoneAccess(store: store)
        access.hostClient = host
        access.inputAllowed = true
        let phoneDictation = PhoneDictation(keyStore: dictationKey, transcription: OpenAITranscription(client: SandboxTranscriber()),
                                            model: { [weak self] in self?.dictation.model ?? OpenAITranscription.defaultModel },
                                            session: { [weak self] sid in self?.store.sessions.first { $0.identity == sid } })
        access.transcribe = phoneDictation.transcribe
        access.dictationReady = { [weak self] in self?.dictation.keyState == .saved }
        PhoneLeads.wire(access, controller: leads, model: model)
        phone = access
        let port = UInt16.random(in: 50_000...59_999)
        access.serveInSandbox(port: port, status: status) { [weak self] token in
            guard let self else { return }
            guard let token else { return reply(false, "couldn't open 127.0.0.1:\(port); try again") }
            let file = self.state.appendingPathComponent("phone.json")
            let info: [String: Any] = ["url": "http://127.0.0.1:\(port)/", "token": token,
                                       "host": "\(status.dnsName):\(PhoneAccess.httpsPort)", "login": status.login]
            guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]),
                  (try? VibePaths.writePrivate(data, to: file)) != nil else { return reply(false, "couldn't write \(file.path)") }
            reply(true, "the phone's web app is served on http://127.0.0.1:\(port)/; \(file.path) has its token and headers")
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
        windowActions = actions
        let controller = MainWindowController(store: store, host: host, model: model, actions: actions, leads: leads, briefing: briefing,
                                              dictation: dictation)
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
                host: host, briefing: briefing, dictation: dictation, policy: WorkingPolicyEditor())
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
        ("runblock [yes]", "the shown chat's last code block with a Run: shows what Run asks first, as the sheet; with yes, runs it as Run does once you confirm (tell it {\"op\": \"realShell\"} first to see its output)"),
        ("tell JSON", "hands a fake Claude (the selected one, or the one labelled \"to\") a FakeClaude op, e.g. '{\"op\": \"permission\", \"command\": \"swift build\"}' or '{\"op\": \"work\"}' (see Tests/VibeSwitcherTests/FakeClaude.swift)"),
        ("new [codex|shell] [LABEL]", "starts another fake session: a Claude, or a Codex or a plain shell"),
        ("clear", "ends and removes every fake session: the sidebar is empty, with its New Session menu"),
        ("views", "the main window's AppKit views: how many, how deep, and the most common kinds (a chat that grows them stalls layout)"),
        ("scroll top|middle|bottom", "scrolls the shown chat"),
        ("scroll settings top|middle|bottom", "scrolls the shown Settings tab"),
        ("size WxH", "resizes the main window's content (e.g. 1728x1015)"),
        ("board [N]", "adds N finished tasks (default 250) to the fake lead's board (start the lead first)"),
        ("churn [N]", "changes the fake lead's board N times (default 40), 0.15 s apart, each read and shown as a real change is"),
        ("publish [N]", "has the lead controller publish N times (default 50), each laid out and drawn, and times them"),
        ("hangs [reset]", "the sandbox's main-thread freezes (its hang reports, as the health digest tells them) and its longest wait between two beats (reset: from now on)"),
        ("startlead", "starts a real project lead (LeadController.startLead, as Project Lead does: the host first if none runs, its vault grant) in a new repository, its agent a fake Claude, and shows its chat; first thing after `run --empty`, no session host runs before it"),
        ("lead [FILE]", "shows a fake project lead's chat, at its end (started the first time, on FILE's transcript if given): a board of tasks, a withdrawn question, tool runs and workers' messages"),
        ("team", "starts a fake worker on the fake lead's running task, in its worktree (start the lead first); select it and tell it a permission to see it wait on its lead"),
        ("team named", "starts the fake lead's worker and a verifier titled as Claude Code 2.1.311 names them (worker-<slug>, verify-<slug>) and moves the lead's agent into its .vibeswitcher/worktrees (start the lead first): its team still folds under it"),
        ("ask [TEXT]", "puts an open question for you (TEXT, or a made-up one) on the fake lead's board (start the lead first): its row reads needs you"),
        ("unfold", "shows the selected lead's team under its row in the sidebar"),
        ("replaced [N]", "shows the selected window session as a lead another session replaced, with N characters (default 200000) typed into it: the header's one line it makes"),
        ("answer", "answers the fake lead's open questions: its row reads as its terminal does again"),
        ("extras", "adds to the fake lead's board (start the lead first) a proposal on a timer, a revised question, a task needing an audit, an all-done card and two results"),
        ("phone", "serves the phone's web app for this sandbox on a port of 127.0.0.1, one phone paired: STATE/phone.json says where, its token, and the Host and Tailscale-User-Login headers to send (as tailscale serve would)"),
        ("dictation key|nokey|note|ack|press|release|letgo|cancel|turnon", "push to talk in the composer (no microphone, no OpenAI: a made-up recording and transcript): a key saved or none, the one-time note about OpenAI shown again on the next press, the mic held down in the selected session's composer (a Claude session's through its fake /voice, see tell's \"voice\" op: until it listens or says why not), let go (release: until the text is in; letgo: once it waits for Claude's text), its ✕ clicked, the notice's Turn on Claude dictation clicked"),
        ("select TEXT", "selects the first row whose title, project or task contains TEXT"),
        ("home", "shows the start page"),
        ("settings [TAB]", "opens Settings on a tab: " + SettingsTab.allCases.map(\.rawValue).joined(separator: ", ")),
        ("sheet NAME", "shows a sheet on the window: " + (Driver.sheets.map(\.name) + Driver.windowSheets.map(\.name) + ["choose-folder", "new-session-menu"]).joined(separator: ", ")),
        ("close settings|sheet", "closes Settings or the sheet"),
        ("shot NAME", "draws each window, light and dark, into the shots folder"),
        ("unproved", "connects again with a key the host doesn't hold: it refuses the app's proof and shows it no sessions"),
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
        // one was audited, one merged and then reverted, a question withdrawn lately and several answered, the Mac line, the Mac kept awake.
        // An all-done card with its batch's receipts summed (`LeadReceiptTotals`), its task list open.
        ("all-done", { driver in
            let mark = Driver.allDoneMark()
            return AnyView(AllDoneCard(mark: mark, chat: ChatModel(), expanded: [AllDoneCard.key(mark)]).frame(width: 560).padding(16))
        }),
        ("lead-team", { driver in
            let team = Driver.leadTeam()
            return AnyView(LeadTeamView(root: driver.home + "/projects/sandbox-project", board: team.board, seen: team.seen, open: { _ in },
                                        decisions: team.decisions, keepingAwake: true,
                                        mac: MacLine(text: "Mac: load 16.5, 5 team sessions across 3 projects", spoken: "", isOver: false))
                .frame(width: 360, height: 980))
        }),
    ]

    /// AppKit windows `sheet NAME` shows too: the question for a chosen folder in no repository (a scratch folder under
    /// the sandbox's home, with a .gitignore of its own that misses its secret-named files).
    static var windowSheets: [(name: String, make: (Driver) -> NSWindow?)] { [
        ("not-repository", { driver in
            let folder = driver.home + "/projects/notes-app"
            try? VibePaths.ensurePrivate(URL(fileURLWithPath: folder + "/src"))
            for (name, text) in [("README.md", "# Notes\n"), ("src/main.py", "print('hi')\n"), (".gitignore", "*.log\n"),
                                 (".env", "TOKEN=x\n"), ("server.pem", "-\n")] {
                try? VibePaths.writePrivate(Data(text.utf8), to: URL(fileURLWithPath: folder + "/" + name))
            }
            let scratch = URL(fileURLWithPath: driver.home + "/scratch")
            guard case .success(let plan) = FolderRepository.plan(for: folder, scratch: scratch) else { return nil }
            let alert = ProjectFolderStart.notRepositoryAlert(plan)
            alert.layout()
            return alert.window
        }),
        // A repository with no commits yet, staged file and all: the first commit LeadController offers.
        ("empty-repository", { driver in
            let folder = driver.home + "/projects/empty-repo"
            try? VibePaths.ensurePrivate(URL(fileURLWithPath: folder + "/src"))
            for (name, text) in [("README.md", "# Empty\n"), ("src/main.swift", "print(1)\n"), ("deploy.key", "-\n")] {
                try? VibePaths.writePrivate(Data(text.utf8), to: URL(fileURLWithPath: folder + "/" + name))
            }
            guard Git.run(["init", "--quiet"], in: folder).ok, Git.run(["add", "README.md"], in: folder).ok else { return nil }
            let scratch = URL(fileURLWithPath: driver.home + "/scratch")
            guard case .success(let plan) = FolderRepository.plan(for: folder, scratch: scratch) else { return nil }
            let alert = ProjectFolderStart.emptyRepositoryAlert(plan)
            alert.layout()
            return alert.window
        }),
        // A lead started on a Mac without Claude Code: the real look (`LaunchPreflight`), its login shell a stand-in
        // whose PATH has no claude, and the alert the start shows, offering Anthropic's installer (`ToolInstall`).
        ("missing-claude", { driver in
            let shell = driver.home + "/bin/fakesh"
            let script = "#!/bin/sh\nshift 2\nPATH=/usr/bin:/bin; export PATH\nexec /bin/sh \"$@\"\n"
            try? VibePaths.ensurePrivate(URL(fileURLWithPath: driver.home + "/bin"))
            try? VibePaths.writePrivate(Data(script.utf8), to: URL(fileURLWithPath: shell))
            chmod(shell, 0o700)
            guard let missing = LaunchPreflight(shell: shell).check(command: "claude"), let install = ToolInstall.offer(for: missing)
            else { return nil }
            let offer = install.offer(missing)
            let alert = LeadController.makeAlert(offer.title, offer.text, ToolInstall.buttons)
            alert.layout()
            return alert.window
        }),
        // A lead started on a Mac without Apple's Command Line Tools (nor git with them): the install it offers.
        ("missing-tools", { _ in
            let missing = LaunchPreflight.Problem(missing: [.commandLineTools])
            let offer = ToolInstall.commandLineTools.offer(missing)
            let alert = LeadController.makeAlert(offer.title, offer.text, ToolInstall.buttons)
            alert.layout()
            return alert.window
        }),
        // What shows while Apple's installer runs.
        ("installing-tools", { _ in ToolInstaller.waitingPanel(ToolInstaller.waitingText) {} }),
    ] }

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
        var reverted = task("Paste images into the chat", .reverted, since: 4_000)
        reverted.worktree = nil
        reverted.merged = LeadMergeRecord(commit: "abc9def0", tested: true, onto: "abc8def0", audited: false, at: now - 6_000)
        reverted.merged?.revertedBy = "fed9cba0"
        reverted.merged?.revertReason = "The chat froze on a large paste; reverted, a fix-forward is planned."
        // Review none, raised to audit by the risk check (see `LeadRisk`) when its worker reported done.
        var raised = task("Clean up ended sessions' folders", .review, since: 2 * 60)
        raised.review = .audit
        raised.riskRaised = LeadRiskRaise(reason: "it has code that deletes or rewrites files or data (Sources/Cleanup.swift: try fm.removeItem(at: folder))",
                                          commit: "abc1234def0", byModel: false)
        board.tasks = merged + [working, after, unsaid, twice, raised, reverted, abandoned]

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
        case "views": reply(true, views())
        case "board":
            // The fake lead's board grown by N finished tasks (a day's worth of a busy lead's), each with a contract.
            let count = max(1, Int(rest) ?? 250)
            let root = ((home as NSString).appendingPathComponent("projects/sandbox-lead") as NSString).standardizingPath
            let contract = LeadContract(goal: "A finished sandbox task, its goal as long as a real one's: what changes, where, and how it's checked.",
                                        acceptance: ["It shows."], boundaries: [], context: "")
            do {
                try BoardStore(root: root).update { board in
                    let start = board.tasks.count
                    for index in start..<(start + count) {
                        var task = LeadTask(slug: "finished-\(index)", title: "Finished task \(index) of the sandbox lead", contract: contract,
                                            status: index % 9 == 0 ? .abandoned : .done)
                        task.since = Date().timeIntervalSince1970 - Double(count - index) * 60
                        board.tasks.append(task)
                    }
                }
            } catch {
                return reply(false, "couldn't write the lead's board: \(error)")
            }
            leads.refresh()
            settle { reply(true, "\(count) finished tasks added to the lead's board") }
        case "churn":
            // The fake lead's board changing N times, 0.15 s apart (a checkpoint each, as a busy team's do), each read
            // and shown the way a real change is (`LeadController.refresh`): `hangs` then says what it cost.
            let count = max(1, Int(rest) ?? 40)
            let root = ((home as NSString).appendingPathComponent("projects/sandbox-lead") as NSString).standardizingPath
            func step(_ index: Int) {
                guard index < count else { return settle { reply(true, "board changed \(count) times") } }
                try? BoardStore(root: root).update { board in
                    guard let at = board.tasks.firstIndex(where: { $0.status == .running }) else { return }
                    board.tasks[at].checkpoints = (board.tasks[at].checkpoints ?? []) + [LeadCheckpoint(text: "Checkpoint \(index)")]
                }
                leads.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { step(index + 1) }
            }
            step(0)
        case "publish":
            // The lead controller publishing N times (a board changed), each laid out and drawn: what one costs the
            // window with the chat shown.
            guard let shown = window?.window else { return reply(false, "no window") }
            let count = max(1, Int(rest) ?? 50)
            var longest = 0.0
            let started = Date()
            for _ in 0..<count {
                let at = Date()
                leads.objectWillChange.send()
                RunLoop.main.run(mode: .default, before: Date())
                shown.contentView?.layoutSubtreeIfNeeded()
                shown.displayIfNeeded()
                longest = max(longest, Date().timeIntervalSince(at))
            }
            let total = Date().timeIntervalSince(started)
            reply(true, String(format: "%d publishes: %.1f ms each, longest %.1f ms", count, total * 1000 / Double(count), longest * 1000))
        case "scroll" where rest.hasPrefix("settings"):
            // The Settings tab's form: the window's first scroll view.
            func first(_ view: NSView) -> NSScrollView? { (view as? NSScrollView) ?? view.subviews.lazy.compactMap(first).first }
            guard let root = settings?.window?.contentView, let scroll = first(root), let document = scroll.documentView else {
                return reply(false, "no settings shown")
            }
            let to = rest.dropFirst("settings".count).trimmingCharacters(in: .whitespaces)
            let height = document.frame.height - scroll.contentSize.height
            let y = to == "top" ? 0 : to == "middle" ? height / 2 : height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle { reply(true, "scrolled settings to \(Int(y)) of \(Int(height))") }
        case "scroll":
            // The chat's scroll view: the one holding its messages.
            func holdsChat(_ view: NSView) -> Bool { view is ChatTextView || view.subviews.contains(where: holdsChat) }
            func find(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView, let document = scroll.documentView, holdsChat(document) { return scroll }
                return view.subviews.lazy.compactMap(find).first
            }
            guard let root = window?.window?.contentView, let scroll = find(root), let document = scroll.documentView else {
                return reply(false, "no chat shown")
            }
            let height = document.frame.height - scroll.contentSize.height
            let y = rest == "top" ? 0 : rest == "middle" ? height / 2 : height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle { reply(true, "scrolled to \(Int(y)) of \(Int(height))") }
        case "size":
            let parts = rest.split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2, let shown = window?.window else { return reply(false, "size WIDTHxHEIGHT") }
            shown.setContentSize(NSSize(width: parts[0], height: parts[1]))
            settle { reply(true, "window \(Int(parts[0]))×\(Int(parts[1]))") }
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
        case "runblock": runBlock(confirmed: rest == "yes", reply)
        case "clear":
            // Ended first, then removed (the host keeps an ended session's row until it's removed).
            let ids = host.sessions.map(\.id)
            ids.forEach(host.kill)
            waitFor({ [weak self] in self?.host.sessions.allSatisfy { !$0.isLive } ?? true }) { [weak self] _ in
                guard let self else { return }
                for id in ids { self.window?.pane.forget(id); self.host.remove(id) }
                self.waitFor({ self.host.sessions.isEmpty && self.store.sessions.isEmpty }) { cleared in
                    self.settle { reply(cleared, cleared ? "cleared: no sessions" : "sessions left: \(self.host.sessions.count)") }
                }
            }
        case "new":
            // "new codex LABEL" and "new shell LABEL": a Codex row, a plain shell's.
            let words = rest.split(separator: " ", maxSplits: 1).map(String.init)
            let kinded = words.first == "codex" || words.first == "shell"
            let agent: Agent? = words.first == "shell" ? nil : words.first == "codex" ? .codex : .claude
            let label = kinded ? words.dropFirst().joined() : rest
            startFake(label: label.isEmpty ? "Fake \(agent?.displayName ?? "Shell") \(fakeCount + 1)" : label, agent: agent) { problem in
                reply(problem == nil, problem ?? "started")
            }
        case "startlead": startRealLead(reply)
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
            // A transcript of your own making for it (a long one, to time the chat on): its lines instead of the made-up ones.
            var transcript: String?
            if !rest.isEmpty {
                guard rest.hasPrefix("/"), let text = try? String(contentsOfFile: rest, encoding: .utf8) else { return reply(false, "no transcript at \(rest)") }
                transcript = text
            }
            startLead(transcript: transcript) { problem in if let problem { reply(false, problem) } else { show() } }
        case "hangs":
            // The main thread's freezes so far, as the app's health digest tells them, and its longest wait for a beat.
            let folders = AppHealth.Folders(debug: watchdog.folder, reports: state.appendingPathComponent("no-crashes"))
            var lines = folders.hangNames().map { AppHealth.Watch.line([folders.hang($0)]) }
            if let longest = watchdog.longestGap(reset: rest == "reset") {
                lines.append(String(format: "longest between beats (0.25 s apart when free): %.2f s, ended %@", longest.gap, "\(longest.at)"))
            }
            reply(true, lines.isEmpty ? "none" : lines.joined(separator: "\n"))
        case "team" where rest == "named": startNamedTeam { problem in reply(problem == nil, problem ?? "worker and verifier started, the lead's agent in its worktrees folder") }
        case "team": startWorker { problem in reply(problem == nil, problem ?? "worker started") }
        case "unfold":
            guard let row = model.selectedRow else { return reply(false, "nothing selected") }
            if !model.expandedTeams.contains(row.id) { model.toggleTeam(row.id) }
            settle { reply(true, "\(row.title)'s team shown") }
        case "replaced":
            guard let row = model.selectedRow, let id = row.hostID, let tty = row.session?.tty else { return reply(false, "no window session selected") }
            var replaced = ReplacedLead(root: row.cwd ?? home, project: "sandbox-lead", tty: tty, live: nil)
            replaced.draft = String(repeating: "split the layer out, then the next one\n", count: (Int(rest) ?? 200_000) / 39 + 1)
            model.replacedLeads[id] = replaced
            settle { reply(true, "\(row.title) shown replaced, \(replaced.draft.count) characters typed into it") }
        case "ask": ask(rest, answer: false) { problem in reply(problem == nil, problem ?? "the lead asks you") }
        case "answer": ask("", answer: true) { problem in reply(problem == nil, problem ?? "its questions answered") }
        case "extras": extras { problem in reply(problem == nil, problem ?? "the lead's board has a proposal, a revised question, an all-done card and results") }
        case "phone": servePhone(reply)
        case "dictation": dictate(rest, reply)
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
        case "unproved":
            key.stranger = SymmetricKey(size: .bits256)
            host.confirmKeyReset = { _, _ in false }
            host.connectAgain()
            reply(true, "connecting again with a key the host doesn't hold")
        case "quit":
            reply(true, "quitting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        case "help", "":
            reply(true, Self.commands.map { "\($0.name): \($0.help)" }.joined(separator: "\n"))
        default:
            reply(false, "no command \(words[0]); these are:\n" + Self.commands.map { "  \($0.name): \($0.help)" }.joined(separator: "\n"))
        }
    }

    /// The main window's view tree in numbers: each display cycle walks all of it (tracking areas, cursor rects, the
    /// key-view loop), so its size is what a stall in those scales with.
    private func views() -> String {
        guard let root = window?.window?.contentView?.superview else { return "no window" }
        var kinds: [String: Int] = [:], total = 0, deepest = 0, keyLoop = 0
        var hosts: [String] = []
        func size(_ view: NSView) -> Int { view.subviews.reduce(1) { $0 + size($1) } }
        func walk(_ view: NSView, _ depth: Int) {
            total += 1
            if view is NSHostingView<AnyView> || String(describing: type(of: view)).hasPrefix("NSHostingView") {
                hosts.append("  host at depth \(depth): \(size(view)) views, \(Int(view.frame.width))×\(Int(view.frame.height)), \(String(describing: type(of: view)).prefix(50))")
            }
            deepest = max(deepest, depth)
            if view.canBecomeKeyView { keyLoop += 1 }
            kinds[String(describing: type(of: view)).prefix(60).description, default: 0] += 1
            view.subviews.forEach { walk($0, depth + 1) }
        }
        walk(root, 0)
        let top = kinds.sorted { $0.value > $1.value }.filter { $0.value > 4 || $0.key.contains("KeyView") }.map { "  \($0.value) \($0.key)" }
        return (["\(total) views, \(deepest) deep, \(keyLoop) can be key views"] + top + hosts).joined(separator: "\n")
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

    /// `dictation key|nokey|note|ack|press|release|letgo|cancel|turnon`.
    private func dictate(_ what: String, _ reply: @escaping (Bool, String) -> Void) {
        switch what {
        case "key", "nokey":
            dictationKey.write(what == "key" ? "sk-sandbox-\(String(repeating: "0", count: 24))" : nil)
            dictation.checkKey()
            settle { reply(true, what == "key" ? "a made-up key is saved" : "no key: the mic says one is needed") }
        case "note":
            UserDefaults.standard.removeObject(forKey: DictationController.privacyNotedKey)
            reply(true, "the next press shows the note about OpenAI")
        case "ack":
            dictation.acknowledgePrivacy()
            settle { reply(true, "the note about OpenAI was read: a press records") }
        case "press", "release", "letgo":
            guard let row = model.selectedRow else { return reply(false, "no session selected: chat NAME first") }
            let (agent, key) = (row.session?.agent, row.draftKey)
            if what == "press" { dictation.press(key, agent: agent) { "Words that may come up: sandbox." } } else { dictation.release(key) }
            let claude = dictation.isClaude(key)
            waitFor({ [weak self] in
                guard let dictation = self?.dictation else { return true }
                // Claude's: held until it listens (or says why not); let go until the text is in the composer (letgo: until
                // it waits for it).
                if claude, what == "letgo" { return !dictation.isRecording(key) }
                if claude { return what == "press" ? dictation.isListening(key) || !dictation.isBusy(key) : !dictation.isBusy(key) }
                return !dictation.isTranscribing(key)
            }) { [weak self] _ in
                self?.settle { reply(true, "\(self?.dictation.phase(key) ?? .idle)\(self?.dictation.isListening(key) == true ? ", listening" : "")") }
            }
        case "cancel":
            guard let row = model.selectedRow else { return reply(false, "no session selected: chat NAME first") }
            let key = row.draftKey
            dictation.cancel(key, .button)
            waitFor({ [weak self] in self?.dictation.isBusy(key) == false }) { [weak self] _ in
                self?.settle { reply(true, "cancelled: \(self?.dictation.phase(key) ?? .idle)") }
            }
        case "turnon":
            guard let row = model.selectedRow else { return reply(false, "no session selected: chat NAME first") }
            let key = row.draftKey
            dictation.turnOnClaude(key)
            waitFor({ [weak self] in self?.dictation.turningOn.contains(key) == false }) { [weak self] _ in
                self?.settle { reply(true, self?.dictation.notices[key]?.text ?? "no notice") }
            }
        default:
            reply(false, "dictation key|nokey|note|ack|press|release|letgo|cancel|turnon")
        }
    }

    private func tell(_ json: String, _ reply: @escaping (Bool, String) -> Void) {
        guard let op = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return reply(false, "not a JSON object: \(json)") }
        // "to": a fake's label, to tell one that isn't selected (a turn ending on a selected row counts as seen: idle, not done).
        let selected = model.selectedRow?.hostID
        let named = (op["to"] as? String).flatMap { to in fakeList.first { $0.label == to } }
        guard let fake = named ?? fakeList.first(where: { $0.id == selected }) ?? fakeList.first, let file = fake.control,
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
        // At work: the hook state a real Claude leaves mid-tool, so the chat shows its working line.
        if op["op"] as? String == "work", var hook = HookState.load(from: stateFile) {
            hook.lastEvent = "PreToolUse"
            hook.lastEventAt = Date().timeIntervalSince1970
            hook.toolName = "Bash"
            hook.toolStartedAt = Date().timeIntervalSince1970
            try? hook.save(to: stateFile)
        }
        // Its turn over just now: the Stop a real Claude leaves, so the row reads done.
        if op["op"] as? String == "done", var hook = HookState.load(from: stateFile) {
            hook.lastEvent = "Stop"
            hook.lastEventAt = Date().timeIntervalSince1970
            try? hook.save(to: stateFile)
        }
        reply(true, "told \(fake.label) \(json)")
    }

    /// The sheet in a window of its own beside the main one, off screen as it is: attached with `beginSheet`, AppKit
    /// would move the main window on screen to show it. Its content is the sheet's, at the size `.sheet` gives it.
    private func showSheet(_ name: String, _ reply: @escaping (Bool, String) -> Void) {
        if name == "choose-folder" {
            // NSOpenPanel draws out of process (a remote view): `shot` can't draw it, so this says how it's set up.
            let panel = Launcher.folderPanel(startingAt: home + "/projects", prompt: ProjectFolderStart.prompt(for: .chooseForLead))
            return reply(true, "folder panel (drawn out of process: shot can't draw it): button “\(panel.prompt ?? "")”, "
                         + "folders only: \(panel.canChooseDirectories && !panel.canChooseFiles), starts in \(panel.directoryURL?.path ?? "?")")
        }
        if name == "new-session-menu" {
            // A menu draws only while it's open, in a tracking loop on screen: this lists the empty sidebar's
            // (`NewSessionMenu(folder: nil)`), from the window's actions.
            guard let actions = windowActions else { return reply(false, "no main window") }
            let items = actions.presets(nil).map(\.name) + ["—", NewSessionMenu.leadItem(folder: nil, actions: actions).title]
            return reply(true, "the empty sidebar's New Session menu: " + items.joined(separator: ", "))
        }
        if let entry = Self.windowSheets.first(where: { $0.name == name }) {
            closeSheet()
            guard let shown = entry.make(self) else { return reply(false, "couldn't make \(name)") }
            Sandbox.hide(shown)
            sheet = shown
            sheetName = name
            shown.orderFrontRegardless()
            Sandbox.hide(shown)
            return settle { reply(true, "sheet \(name) shown") }
        }
        guard let entry = Self.sheets.first(where: { $0.name == name }) else {
            return reply(false, "no sheet \(name): " + (Self.sheets.map(\.name) + Self.windowSheets.map(\.name) + ["choose-folder", "new-session-menu"]).joined(separator: ", "))
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

    /// The shown chat's last code block that has a Run (`RunButton`): what its confirmation shows, as the sheet; once
    /// `confirmed`, run as the button runs it after you press Run there.
    private func runBlock(confirmed: Bool, _ reply: @escaping (Bool, String) -> Void) {
        guard let chat = window?.chat, model.showsChat else { return reply(false, "no chat: show a fake session's chat first (chat)") }
        let replies = chat.items.compactMap { item -> String? in
            guard case .reply(let entry) = item, case .reply(let text) = entry.kind else { return nil }
            return text
        }
        let runnable = replies.reversed().lazy.compactMap { text in
            MarkdownBlocks.parse(text).reversed().lazy.compactMap { block -> RunnableCommand.Runnable? in
                guard case .code(let language, let code) = block else { return nil }
                return RunnableCommand.runnable(code: code, language: language)
            }.first
        }.first
        guard let runnable else { return reply(false, "no code block with a Run in the chat's replies") }
        closeSheet()
        if confirmed {
            let ran = RunButton.run(runnable, with: chat.runner, confirm: { _ in true })
            return settle { reply(ran, ran ? "ran it: \(runnable.prompt)" : "it couldn't be typed into the session") }
        }
        let alert = RunButton.confirmation(runnable)
        alert.layout()
        let shown = alert.window
        Sandbox.hide(shown)
        sheet = shown
        sheetName = "runblock"
        shown.orderFrontRegardless()
        Sandbox.hide(shown)
        settle { reply(true, "Run's confirmation shown (sheet-runblock)") }
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

/// The sandbox's microphone: no device opened, a made-up recording handed over.
/// The sandbox's microphone permission: always allowed, never the Mac's (no dialog).
final class SandboxMicrophone: MicrophoneAuthorizer {
    var status: MicrophoneStatus { .allowed }
    func request(_ done: @escaping (Bool) -> Void) { done(true) }
}

final class SandboxRecorder: DictationRecorder {
    func permission(_ done: @escaping (Bool) -> Void) { done(true) }
    func start() throws {}
    func stop() -> DictationAudio? { DictationAudio(data: Data("sandbox-recording".utf8), mimeType: "audio/mp4", duration: 2) }
    func cancel() {}
}

/// The sandbox's OpenAI: nothing leaves the Mac, a made-up transcript comes back.
struct SandboxTranscriber: HTTPClient {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        (Data(#"{"text":"run the tests on ComposerView.swift"}"#.utf8),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
