import AppKit
import Foundation
import ServiceManagement
import UserNotifications
import VibeCore

/// User-facing toggles, persisted in UserDefaults. Every one is in Settings; the ⚙︎ menu repeats a few.
final class Preferences: ObservableObject {
    private let defaults: UserDefaults
    private let presetsFile: URL

    @Published var notifyNeedsInput: Bool { didSet { defaults.set(notifyNeedsInput, forKey: "notifyNeedsInput") } }
    @Published var notifyDone: Bool { didSet { defaults.set(notifyDone, forKey: "notifyDone") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    /// One reminder when a session has waited on you 10+ min, or shown no progress for 15+ min.
    @Published var notifyReminders: Bool { didSet { defaults.set(notifyReminders, forKey: "notifyReminders") } }
    /// Pausing a session minimizes its window (when it's the only tab there); resuming restores it.
    @Published var minimizeOnPause: Bool { didSet { defaults.set(minimizeOnPause, forKey: "minimizeOnPause") } }
    /// Docked session list on the right; picking a session shows only its window, on this desktop.
    @Published var sidebarMode: Bool { didSet { defaults.set(sidebarMode, forKey: "sidebarMode") } }
    /// Sidebar slides in at the right screen edge instead of staying docked.
    @Published var sidebarAutoHide: Bool { didSet { defaults.set(sidebarAutoHide, forKey: "sidebarAutoHide") } }
    /// The auto-hiding sidebar shows for a moment after you switch desktops. Off at first launch with Reduce Motion on.
    @Published var sidebarFlashOnSwitch: Bool {
        didSet { defaults.set(sidebarFlashOnSwitch, forKey: "sidebarFlashOnSwitch") }
    }
    @Published var sessionOrder: SessionOrder {
        didSet { defaults.set(sessionOrder.rawValue, forKey: "sessionOrder") }
    }
    /// What "New session" runs, e.g. `claude` or `claude --model opus`.
    @Published var claudeCommand: String { didSet { defaults.set(claudeCommand, forKey: "claudeCommand") } }
    @Published var codexCommand: String { didSet { defaults.set(codexCommand, forKey: "codexCommand") } }
    @Published private(set) var launchAtLogin: Bool
    /// Mirrors the system permission, for the popover banner.
    @Published var notificationsAllowed = true
    @Published var floatingPanel: FloatingPanelMode {
        didSet { defaults.set(floatingPanel.rawValue, forKey: "floatingPanel") }
    }
    /// Launch presets, in ~/.vibeswitcher/presets.json (the first load migrates the two launch commands).
    @Published var presets: LaunchPresets {
        didSet { if presetsCanSave { try? presets.save(to: presetsFile) } }
    }
    /// What couldn't be read from presets.json at launch, for the one notice that says so (nil: it read fine).
    let presetsNotice: String?
    /// False when presets.json couldn't be read and couldn't be copied aside: saving would lose it.
    private let presetsCanSave: Bool
    @Published var appearance: TerminalAppearance {
        didSet { defaults.set(try? JSONEncoder().encode(appearance), forKey: "terminalAppearance") }
    }
    /// Show the window when VibeSwitcher starts.
    @Published var openWindowAtLaunch: Bool { didSet { defaults.set(openWindowAtLaunch, forKey: "openWindowAtLaunch") } }
    /// The Team view says what each agent is doing in plain words, written by a small model (headless `claude -p`).
    @Published var aiSummaries: Bool { didSet { defaults.set(aiSummaries, forKey: "aiSummaries") } }
    /// Lead mail: one project's lead may tell another's with tell_lead (see `LeadMail`). The tool server reads this
    /// key in the app's defaults at each call (`LeadMail.isOn`): unset, it's on.
    @Published var leadRotation: LeadRotationMode { didSet { defaults.set(leadRotation.rawValue, forKey: "leadRotation") } }
    @Published var leadMail: Bool { didSet { defaults.set(leadMail, forKey: LeadMail.enabledKey) } }
    /// Keep the Mac from idle sleep while a lead's team works (see `KeepAwake`).
    @Published var keepAwake: KeepAwakeMode { didSet { defaults.set(keepAwake.rawValue, forKey: "keepAwake") } }
    /// On battery, the lead's witness tells it to hold new starts, audits and merges only below this charge, in %
    /// (10–90; 0 never, see `PowerWatch`).
    @Published var batteryHoldBelow: Int {
        didSet {
            let kept = PowerWatch.clamp(batteryHoldBelow)
            // Setting it here doesn't run didSet again.
            if kept != batteryHoldBelow { batteryHoldBelow = kept }
            defaults.set(kept, forKey: "batteryHoldBelow")
        }
    }
    /// The stepper's next limit: 5 at a time within 10–90, below 10 off (0) and up from off 10.
    static func batteryHoldStep(_ limit: Int, up: Bool) -> Int {
        let range = PowerWatch.limits
        if limit == 0 { return up ? range.lowerBound : 0 }
        if !up && limit <= range.lowerBound { return 0 }
        return PowerWatch.clamp(limit + (up ? 5 : -5))
    }
    /// Boost mode (Settings › Project lead): higher Mac-wide limits On, or Automatic while away and on AC power; on
    /// battery only with `boostOnBattery` (see `BoostWatch`, `Boost.decide`).
    @Published var boostMode: BoostMode { didSet { defaults.set(boostMode.rawValue, forKey: "boostMode") } }
    /// Boost's "Also on battery": On and Automatic work on battery as on AC while the charge is at
    /// `Boost.batteryFloor` % or more. Off by default.
    @Published var boostOnBattery: Bool { didSet { defaults.set(boostOnBattery, forKey: "boostOnBattery") } }
    /// The limits boost raises to (`BoostLimits`, kept as JSON); out-of-range values are kept as their nearest.
    @Published var boostLimits: BoostLimits {
        didSet {
            let kept = BoostLimits(loadThreshold: boostLimits.loadThreshold, maxSessions: boostLimits.maxSessions,
                                   maxWorkers: boostLimits.maxWorkers, heavySlots: boostLimits.heavySlots)
            // Setting it here doesn't run didSet again.
            if kept != boostLimits { boostLimits = kept }
            defaults.set(try? JSONEncoder().encode(kept), forKey: "boostLimits")
        }
    }
    /// Where Home's New Project… makes projects, as a tilde path ("~/dev").
    @Published var projectsFolder: String { didSet { defaults.set(projectsFolder, forKey: "projectsFolder") } }
    /// Projects made with New Project…, by when: Home lists them before an agent has run in them.
    private(set) var createdProjects: [String: Date] {
        get { defaults.dictionary(forKey: "createdProjects") as? [String: Date] ?? [:] }
        set { defaults.set(newValue, forKey: "createdProjects") }
    }
    /// The language the spoken briefing is written and read in (an ElevenLabs language code, see `BriefingLanguage`);
    /// the Mac's first preferred language until you pick one.
    @Published var briefingLanguage: String { didSet { defaults.set(briefingLanguage, forKey: "briefingLanguage") } }
    /// The Passage peer that is the Wallet Manager's Mac (its peer id), or `WalletAsk.WalletManager.onThisMac` for the
    /// Wallet Manager on this Mac; empty until you choose one, and until then wallet requests can be signed only in
    /// the browser wallet (from an 0x address).
    @Published var walletPeerID: String { didSet { defaults.set(walletPeerID, forKey: "walletPeerID") } }
    /// The `passage` command wallet requests go through; empty: `passage` on the PATH.
    @Published var walletPassagePath: String { didSet { defaults.set(walletPassagePath, forKey: "walletPassagePath") } }

    /// Settings › Agents › Let agents open shells without asking: a shell an agent asks for (`vs-shell run`) starts at
    /// once instead of waiting on its card for Run. Off until you turn it on.
    @Published var letAgentsOpenShells: Bool { didSet { defaults.set(letAgentsOpenShells, forKey: "letAgentsOpenShells") } }

    /// `defaults`, `presetsFile` and `reduceMotion` are for tests and offscreen renders; the app uses the standard ones.
    init(defaults: UserDefaults = .standard, presetsFile: URL = VibePaths.presetsFile, reduceMotion: Bool = Motion.isReduced) {
        self.defaults = defaults
        self.presetsFile = presetsFile
        Self.carryOverWalletKeys(defaults)
        // Decided once, at first launch, and kept: turning Reduce Motion on later doesn't flip it behind your back.
        if defaults.object(forKey: "sidebarFlashOnSwitch") == nil {
            defaults.set(Self.flashOnSwitchByDefault(reduceMotion: reduceMotion), forKey: "sidebarFlashOnSwitch")
        }
        defaults.register(defaults: ["notifyNeedsInput": true, "notifyDone": true, "playSound": true, "notifyReminders": true, "minimizeOnPause": true, "sidebarAutoHide": true, "aiSummaries": true,
                                     "claudeCommand": "claude", "codexCommand": "codex", "batteryHoldBelow": PowerWatch.defaultLimit,
                                     "projectsFolder": ProjectCreation.defaultLocation])
        notifyNeedsInput = defaults.bool(forKey: "notifyNeedsInput")
        notifyDone = defaults.bool(forKey: "notifyDone")
        playSound = defaults.bool(forKey: "playSound")
        notifyReminders = defaults.bool(forKey: "notifyReminders")
        minimizeOnPause = defaults.bool(forKey: "minimizeOnPause")
        claudeCommand = defaults.string(forKey: "claudeCommand") ?? "claude"
        sidebarMode = defaults.bool(forKey: "sidebarMode")
        sidebarAutoHide = defaults.bool(forKey: "sidebarAutoHide")
        sidebarFlashOnSwitch = defaults.bool(forKey: "sidebarFlashOnSwitch")
        sessionOrder = SessionOrder(rawValue: defaults.string(forKey: "sessionOrder") ?? "") ?? .screen
        codexCommand = defaults.string(forKey: "codexCommand") ?? "codex"
        launchAtLogin = SMAppService.mainApp.status == .enabled
        floatingPanel = FloatingPanelMode(rawValue: defaults.string(forKey: "floatingPanel") ?? "") ?? .automatic
        // Locals, not the @Published properties: those can't be read before init finishes.
        let loaded = LaunchPresets.loadChecked(from: presetsFile,
                                               claudeCommand: defaults.string(forKey: "claudeCommand") ?? "claude",
                                               codexCommand: defaults.string(forKey: "codexCommand") ?? "codex")
        presets = loaded.presets
        presetsNotice = loaded.notice
        presetsCanSave = loaded.canSave
        appearance = defaults.data(forKey: "terminalAppearance")
            .flatMap { try? JSONDecoder().decode(TerminalAppearance.self, from: $0) } ?? TerminalAppearance()
        openWindowAtLaunch = defaults.bool(forKey: "openWindowAtLaunch")
        aiSummaries = defaults.bool(forKey: "aiSummaries")
        leadRotation = LeadRotationMode(rawValue: defaults.string(forKey: "leadRotation") ?? "") ?? .context
        leadMail = LeadMail.isOn(defaults)
        keepAwake = KeepAwakeMode(rawValue: defaults.string(forKey: "keepAwake") ?? "") ?? .onPower
        batteryHoldBelow = PowerWatch.clamp(defaults.integer(forKey: "batteryHoldBelow"))
        briefingLanguage = defaults.string(forKey: "briefingLanguage").flatMap(BriefingLanguage.named)?.code ?? BriefingLanguage.preferred().code
        projectsFolder = defaults.string(forKey: "projectsFolder") ?? ProjectCreation.defaultLocation
        walletPeerID = defaults.string(forKey: "walletPeerID") ?? ""
        walletPassagePath = defaults.string(forKey: "walletPassagePath") ?? ""
        letAgentsOpenShells = defaults.bool(forKey: "letAgentsOpenShells")
        boostMode = BoostMode(rawValue: defaults.string(forKey: "boostMode") ?? "") ?? .off
        boostOnBattery = defaults.bool(forKey: "boostOnBattery")
        boostLimits = defaults.data(forKey: "boostLimits").flatMap { try? JSONDecoder().decode(BoostLimits.self, from: $0) } ?? BoostLimits()
    }

    /// The keys `walletPeerID` and `walletPassagePath` had while the feature was called vault requests (until
    /// 2026-10-31): their values carried over once, unless the new key is already set, and the old keys removed.
    static let formerWalletKeys = [("vaultPeerID", "walletPeerID"), ("vaultPassagePath", "walletPassagePath")]

    static func carryOverWalletKeys(_ defaults: UserDefaults) {
        for (old, new) in formerWalletKeys {
            guard let value = defaults.object(forKey: old) else { continue }
            if defaults.object(forKey: new) == nil { defaults.set(value, forKey: new) }
            defaults.removeObject(forKey: old)
        }
    }

    /// Showing the sidebar after a desktop switch slides it in at the screen's edge: not by default with Reduce Motion.
    static func flashOnSwitchByDefault(reduceMotion: Bool) -> Bool { !reduceMotion }

    /// The projects folder as a full path ("~/dev" expanded); the default when the setting is blank.
    var projectsFolderPath: String {
        ProjectCreation.expand(projectsFolder.trimmingCharacters(in: .whitespaces).isEmpty ? ProjectCreation.defaultLocation : projectsFolder)
    }

    /// Notes a project New Project… made, keeping the 20 newest.
    func noteCreatedProject(_ folder: String, at date: Date = Date()) {
        var created = createdProjects
        created[folder] = date
        createdProjects = Dictionary(uniqueKeysWithValues: created.sorted { $0.value > $1.value }.prefix(20).map { ($0.key, $0.value) })
    }

    func command(for agent: Agent) -> String {
        let kind: LaunchPreset.Kind = agent == .claude ? .claude : .codex
        return presets.global.first { $0.kind == kind }.flatMap(LaunchPlan.command(for:)) ?? agent.rawValue
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        // The sandbox (scripts/sandbox-app.sh) never changes your login items.
        guard !Sandbox.isOn else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("VibeSwitcher: login item change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

enum FloatingPanelMode: String, CaseIterable {
    /// Only when the menu bar icon is hidden (crowded menu bar / notch).
    case automatic
    case always
    case never

    var label: String {
        switch self {
        case .automatic: return "When the menu bar icon is hidden"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

/// Posts "needs your input" / "done" banners; clicking one focuses that session's tab.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let preferences: Preferences
    var onOpen: ((String) -> Void)?
    /// Every alert that passed the notification settings (title, text, tty), whether or not the Mac
    /// may show banners: Phone Access mirrors them.
    var onAlert: ((String, String, String) -> Void)?
    /// nil until the first check, so a permission that is already on doesn't trigger the test banner.
    private var allowed: Bool?

    /// A permission prompt's banner's Allow and Deny (set by the app: they need the session host). Without them a
    /// banner has no actions.
    var promptActions: PromptActions?
    /// Each terminal's latest alert, by number: a banner whose screen read finished after a newer alert isn't posted.
    private var posted: [String: Int] = [:]
    private var postCount = 0

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
        center.delegate = self
        center.setNotificationCategories([PromptActions.notificationCategory])
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("VibeSwitcher: notification authorization failed: \(error)") }
            self.refreshAuthorization()
        }
    }

    /// Re-reads the permission (it only changes in System Settings, while we're running), and confirms
    /// with a test banner the moment it gets switched on.
    func refreshAuthorization() {
        center.getNotificationSettings { settings in
            let allowed = [.authorized, .provisional].contains(settings.authorizationStatus)
                && settings.alertSetting != .disabled
            DispatchQueue.main.async {
                let wasAllowed = self.allowed
                self.allowed = allowed
                self.preferences.notificationsAllowed = allowed
                AppStatus.extras["notificationsAllowed"] = allowed
                if allowed, wasAllowed == false { self.postTest() }
            }
        }
    }

    /// The permission as setup shows it: allowed, turned off, or never asked. Doesn't ask.
    func readAccess(_ done: @escaping (NotificationAccess) -> Void) {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined: done(.notAsked)
            case .authorized, .provisional, .ephemeral: done(settings.alertSetting == .disabled ? .off : .allowed)
            default: done(.off)
            }
        }
    }

    /// macOS's prompt if it hasn't asked yet (System Settings doesn't list the app before that), else System Settings.
    func askOrOpenSettings() {
        readAccess { access in
            DispatchQueue.main.async { access == .notAsked ? self.requestAuthorization() : Self.openSettings() }
        }
    }

    /// Opens System Settings › Notifications › VibeSwitcher.
    static func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.vibeswitcher.VibeSwitcher"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func postTest() {
        let content = UNMutableNotificationContent()
        content.title = "VibeSwitcher notifications are on"
        content.body = "You'll get a banner when a session needs your input or finishes. Click one to jump to it."
        center.add(UNNotificationRequest(identifier: "vibeswitcher-test", content: content, trigger: nil))
        AppStatus.extras["lastAlert"] = "test \(ISO8601DateFormatter().string(from: Date()))"
    }

    /// What Settings › Notifications says, as `AlertRules` reads it.
    private var settings: AlertRules.Settings {
        AlertRules.Settings(needsInput: preferences.notifyNeedsInput, done: preferences.notifyDone,
                            reminders: preferences.notifyReminders, sound: preferences.playSound)
    }
    /// The first open question a lead's board asks the user, by the lead's session (set by the app).
    var leadQuestion: (Session) -> LeadQuestion? = { _ in nil }
    private var gate = AlertRules.Gate()

    /// A session went to needing input, or its turn ended.
    func post(for session: Session) {
        let alert = AlertRules.attention(session, question: session.teamRole == .lead ? leadQuestion(session) : nil, settings: settings)
        post(alert, permission: alert?.kind == .needsYou && PromptActions.asksPermission(session) ? session.hostID : nil)
    }

    func post(_ nudge: Nudge, for session: Session) {
        post(AlertRules.nudge(nudge, for: session, settings: settings))
    }

    /// What a lead's board says to the user: a question, its all-done card, something broken.
    func post(_ event: AlertRules.LeadEvent) {
        post(AlertRules.lead(event, settings: settings))
    }

    /// `permission`: the session host's session when the alert is about a permission prompt there: its banner gets
    /// Allow and Deny once its screen shows the prompt (`PromptActions.prepare`), none otherwise.
    private func post(_ alert: AlertRules.Alert?, permission: UUID? = nil) {
        guard let alert = gate.pass(alert) else { return }
        AppStatus.extras["lastAlert"] = "\(alert.kind) \(alert.tty) \(ISO8601DateFormatter().string(from: Date()))"
        onAlert?(alert.phoneTitle, alert.phoneBody, alert.tty)
        // Without notification permission, at least make a sound when something is blocked on you.
        guard allowed == true else {
            if alert.kind == .needsYou, alert.sound { NSSound(named: "Ping")?.play() }
            return
        }
        postCount += 1
        let number = postCount
        if !alert.tty.isEmpty {
            posted[alert.tty] = number
            promptActions?.forget(tty: alert.tty)
        }
        guard let permission, let promptActions, !alert.tty.isEmpty else { return deliver(alert, actions: false) }
        promptActions.prepare(tty: alert.tty, id: permission) { [weak self] ready in
            // A newer alert about that terminal came meanwhile: it's the one shown.
            guard let self, self.posted[alert.tty] == number else { return }
            self.deliver(alert, actions: ready)
        }
    }

    private func deliver(_ alert: AlertRules.Alert, actions: Bool) {
        // One notification per terminal: a newer state replaces the older banner.
        center.add(UNNotificationRequest(identifier: alert.tty.isEmpty ? UUID().uuidString : alert.tty,
                                         content: Self.content(for: alert, actions: actions), trigger: nil))
    }

    /// A banner's content: with Allow and Deny (`PromptActions.category`) only when `actions` (a permission prompt
    /// shown on its session's screen).
    static func content(for alert: AlertRules.Alert, actions: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        if let subtitle = alert.subtitle { content.subtitle = subtitle }
        content.body = alert.body
        content.sound = alert.sound ? .default : nil
        content.userInfo = ["tty": alert.tty]
        if actions { content.categoryIdentifier = PromptActions.category }
        return content
    }

    /// Says a banner's Allow or Deny didn't answer its prompt: a banner of its own (a click opens the session), and
    /// the chat's notice when the window shows that session (`onAnswerFailed`).
    func postAnswerFailed(tty: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["tty": tty]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// A plain informational banner (pairings, remote input).
    func postInfo(title: String, body: String) {
        guard allowed == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func clear(tty: String) {
        center.removeDeliveredNotifications(withIdentifiers: [tty])
        DispatchQueue.main.async { self.promptActions?.forget(tty: tty) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let tty = response.notification.request.content.userInfo["tty"] as? String {
            let action = response.actionIdentifier
            DispatchQueue.main.async {
                // Allow or Deny answers the prompt (and says so when it didn't); the banner itself opens the session.
                if PromptActions.choice(for: action) == nil {
                    self.onOpen?(tty)
                } else if let actions = self.promptActions {
                    actions.handle(action, tty: tty)
                } else {
                    self.postAnswerFailed(tty: tty, title: "Not answered", body: PromptAnswer.Failure.unknown.text)
                }
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// The Allow and Deny on a permission prompt's banner (`Notifier`): the prompt its session's screen showed when the
/// banner was posted (`prepare`) is the one answered (`PromptAnswer`), never another one the screen shows by then.
/// One that didn't go in is said (`notice`): the banner can't show that it did nothing. Apart from the notification
/// center, so a test drives the same handler.
final class PromptActions {
    static let category = "vibeswitcher.permission-prompt"
    static let allowAction = "vibeswitcher.permission.allow"
    static let denyAction = "vibeswitcher.permission.deny"

    /// The banner's category: Allow and Deny, neither bringing the app forward; only on an unlocked Mac.
    static var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: category, actions: [
            UNNotificationAction(identifier: allowAction, title: "Allow", options: [.authenticationRequired]),
            UNNotificationAction(identifier: denyAction, title: "Deny", options: [.authenticationRequired]),
        ], intentIdentifiers: [], options: [])
    }

    static func choice(for action: String) -> PromptAnswer.Choice? {
        switch action {
        case allowAction: return .allow
        case denyAction: return .deny
        default: return nil
        }
    }

    /// The hooks say `session` waits on a permission prompt (not a question, a plan, or a turn's end).
    static func asksPermission(_ session: Session) -> Bool {
        guard session.status == .needsInput else { return false }
        if session.hookEvent == "PermissionRequest" { return true }
        let detail = session.detail ?? ""
        return detail.hasPrefix("Run: ") || detail.hasPrefix("Allow: ") || detail.hasPrefix("Asks permission")
            || (session.hookEvent == "Notification" && detail.lowercased().contains("permission"))
    }

    let answerer: PromptAnswer
    /// Each terminal's prompt its banner was posted for.
    private(set) var prompts: [String: PromptAnswer.Prompt] = [:]
    /// A prompt that wasn't answered: title and text, for the terminal (a banner, and the chat's notice).
    var notice: (_ tty: String, _ title: String, _ body: String) -> Void = { _, _, _ in }

    init(answerer: PromptAnswer) {
        self.answerer = answerer
    }

    /// Reads `id`'s screen for the permission prompt the banner for `tty` is about: `ready` true once it's
    /// remembered (the banner gets Allow and Deny), false when the screen shows none (no actions).
    func prepare(tty: String, id: UUID, ready: @escaping (Bool) -> Void) {
        prompts[tty] = nil
        answerer.capture(id) { [weak self] menu in
            guard let self, let menu else { return ready(false) }
            self.prompts[tty] = PromptAnswer.Prompt(id: id, menu: menu)
            ready(true)
        }
    }

    /// The banner for `tty` is gone or replaced: its Allow and Deny answer nothing now.
    func forget(tty: String) {
        prompts[tty] = nil
    }

    /// A banner's action (`allowAction`, `denyAction`) for `tty`: its prompt answered, or the notice saying it wasn't.
    /// `done`: what came of it (nil: answered).
    func handle(_ action: String, tty: String, done: @escaping (PromptAnswer.Failure?) -> Void = { _ in }) {
        guard let choice = Self.choice(for: action) else { return }
        guard let prompt = prompts[tty] else {
            Breadcrumbs.shared.note("notification: \(choice.rawValue) for \(tty) refused, no prompt known")
            notice(tty, "Not answered", PromptAnswer.Failure.unknown.text)
            return done(.unknown)
        }
        // One answer per banner: a second click answers nothing.
        prompts[tty] = nil
        answerer.answer(prompt, choice) { [weak self] failure in
            if let failure {
                Breadcrumbs.shared.note("notification: \(choice.rawValue) for \(tty) not answered: \(failure)")
                self?.notice(tty, choice == .allow ? "Not allowed" : "Not denied", failure.text)
            } else {
                Breadcrumbs.shared.note("notification: \(choice.rawValue) answered for \(tty)")
            }
            done(failure)
        }
    }
}
