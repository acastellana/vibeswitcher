import AppKit
import VibeCore

// Command-line maintenance modes, e.g. `VibeSwitcher.app/Contents/MacOS/VibeSwitcher --dump`.
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--chat-bench"), arguments.indices.contains(index + 1) {
    // Debug aid: the chat view offscreen in this process on a transcript, timing its layouts (see `ChatBench`).
    ChatBench.run(path: arguments[index + 1])
}
if let index = arguments.firstIndex(of: "--idle-bench") {
    // Debug aid: the app's window, list and timers on made-up sessions in this process, measuring what it costs
    // while nothing changes (see `IdleBench`). Needs CFFIXED_USER_HOME set to a scratch folder.
    IdleBench.run(arguments: Array(arguments[(index + 1)...]))
}
if let index = arguments.firstIndex(of: "--ui-bench") {
    // Debug aid: the window as you use it on two made-up leads in this process: clicks, a host restart, busy leads and
    // idle, checking SwiftUI's faults, main-thread stalls, CPU and memory (see `UIBench`). Needs CFFIXED_USER_HOME.
    UIBench.run(arguments: Array(arguments[(index + 1)...]))
}
if arguments.contains("--install-hooks") {
    let problems = HookSetup.installAll()
    problems.forEach { print("problem: \($0)") }
    if problems.isEmpty { print("installed hooks for Claude Code and Codex (Codex hooks trusted)") }
    exit(problems.isEmpty ? 0 : 1)
}
if arguments.contains("--uninstall-hooks") {
    var failed = false
    for agent in Agent.allCases {
        do {
            try HookInstaller.uninstall(agent: agent)
            print("removed \(agent.displayName) hooks from \(HookInstaller.configURL(for: agent).path)")
        } catch {
            failed = true
            print("error: \(agent.displayName): \(error.localizedDescription)")
        }
    }
    exit(failed ? 1 : 0)
}
/// Hands a command to the running app. Not running: the debug aids say so; the others start it (it can't take the
/// command until it's up, so it's asked again then).
func postToApp(_ name: Notification.Name, object: String? = nil, userInfo: [AnyHashable: Any]? = nil, startIfNeeded: Bool = true) {
    let bundleID = "dev.vibeswitcher.VibeSwitcher"
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .contains { $0.processIdentifier != getpid() && !$0.isTerminated }
    guard running else {
        if startIfNeeded, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [url.path]
            try? open.run()
            open.waitUntilExit()
            FileHandle.standardError.write(Data("VibeSwitcher wasn't running: started it. Run this again once it's up.\n".utf8))
        } else {
            FileHandle.standardError.write(Data("VibeSwitcher isn't running.\n".utf8))
        }
        exit(1)
    }
    DistributedNotificationCenter.default().postNotificationName(name, object: object, userInfo: userInfo, deliverImmediately: true)
}

if arguments.contains("--toggle") {
    postToApp(AppStatus.toggleNotification)
    exit(0)
}
/// A debug aid's output file: absolute, and only in a scratch place (see `DebugOutput`).
func debugPath(_ argument: String) -> String {
    let expanded = (argument as NSString).expandingTildeInPath
    let path = expanded.hasPrefix("/") ? expanded : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
    guard DebugOutput.allowed(path) else {
        FileHandle.standardError.write(Data("Debug output goes to /tmp, the temporary folder or ~/.vibeswitcher only.\n".utf8))
        exit(1)
    }
    return path
}

if let index = arguments.firstIndex(of: "--capture-window"), arguments.indices.contains(index + 1) {
    // Debug aid: the running app draws its window into this PNG.
    postToApp(AppStatus.captureNotification, object: debugPath(arguments[index + 1]), startIfNeeded: false)
    exit(0)
}
if let index = arguments.firstIndex(of: "--settings") {
    // Opens Settings in the running app, optionally on a tab: general, launch or terminal.
    let tab = arguments.indices.contains(index + 1) ? arguments[index + 1] : "general"
    postToApp(AppStatus.settingsNotification, object: tab)
    exit(0)
}
if let index = arguments.firstIndex(of: "--screen"), arguments.indices.contains(index + 2) {
    // Debug aid: `--screen TEXT PATH` writes the screen of the first window session whose label contains TEXT.
    postToApp(AppStatus.screenNotification, object: arguments[index + 1], userInfo: ["path": debugPath(arguments[index + 2])], startIfNeeded: false)
    exit(0)
}
if let index = arguments.firstIndex(of: "--lead"), arguments.indices.contains(index + 1) {
    // `--lead FOLDER [--goal TEXT]`: starts the project lead for the repository holding FOLDER (or tells the running
    // one the goal), without taking over the window's selection.
    let folder = (arguments[index + 1] as NSString).expandingTildeInPath
    let goal = arguments.firstIndex(of: "--goal").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    postToApp(AppStatus.leadNotification, object: folder, userInfo: goal.map { ["goal": $0] })
    print("asked VibeSwitcher to start the project lead for \(folder)")
    exit(0)
}
if let index = arguments.firstIndex(of: "--window") {
    // `--window [palette | home | select:TEXT | move:TTY]`: opens the window, optionally with the command palette,
    // the start page, the first session whose title, project or task contains TEXT, or moving the Terminal session
    // on TTY into the window (between turns only; without asking).
    let extra = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
    postToApp(AppStatus.windowNotification, object: extra)
    exit(0)
}
if let index = arguments.firstIndex(of: "--open"), arguments.indices.contains(index + 1) {
    // Asks the running app to open a session, exactly like clicking its row.
    postToApp(AppStatus.openNotification, object: arguments[index + 1])
    exit(0)
}
if let index = arguments.firstIndex(of: "--new"), arguments.indices.contains(index + 1) {
    // `--new <preset name | claude | codex | shell> [folder] [--terminal]`: the running app starts it like ⊕ does.
    let rest = arguments[(index + 2)...].filter { $0 != "--terminal" }
    let folder = ((rest.first ?? FileManager.default.currentDirectoryPath) as NSString).expandingTildeInPath
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
        print("error: no such folder: \(folder)")
        exit(1)
    }
    postToApp(AppStatus.newSessionNotification, object: nil, userInfo: ["preset": arguments[index + 1], "folder": folder, "terminal": arguments.contains("--terminal")])
    print("asked VibeSwitcher to start \(arguments[index + 1]) in \(folder)")
    exit(0)
}

if arguments.contains("--dump") {
    let sessions = SessionScanner().scan()
    let screens = TerminalBridge.screens(for: Set(sessions.filter { $0.agent == .claude }.map(\.tty)))
    for session in sessions {
        let footer = screens[session.tty].flatMap { BackgroundWork.summary(fromScreen: $0) }.map { "\tfooter: \($0)" } ?? ""
        let jobs = BackgroundJobs.summary(session.backgroundJobs).map { "\tshells: \($0)" } ?? ""
        let work = footer + jobs
        let hook = session.hook.map { "\($0.lastEvent) (\(Int(Date().timeIntervalSince1970 - $0.lastEventAt))s ago)" } ?? "no hooks"
        print("\(session.tty)\t\(session.agent.rawValue)\tpid \(session.pid)\t\(hook)\t\(session.cwd ?? "?")\(work)")
    }
    let observed = UserDefaults.standard.dictionary(forKey: "observedProjects") as? [String: Date] ?? [:]
    print("\nrecent projects:")
    for project in Launcher.recentProjects(observed: observed) { print("  \(project.path)") }
    exit(0)
}
if arguments.contains("--dev-pages") {
    // What the phone's Dev pages list would show right now.
    switch ChromeTabs.localPages() {
    case .success(let pages):
        pages.forEach { print("\($0.target.hostHeader)\($0.path)\t\($0.title)\tid \(DevPages.id(for: $0))") }
        if pages.isEmpty { print("no localhost pages open in Chrome") }
    case .failure(let failure):
        print("\(failure)")
    }
    exit(0)
}

if let index = arguments.firstIndex(of: "--focus"), arguments.indices.contains(index + 1) {
    // Selects the tab only; unlike --open (a real row click) it does not handle activating Terminal.
    let ok = TerminalBridge.focus(tty: arguments[index + 1])
    print(ok ? "focused \(arguments[index + 1])" : "no Terminal tab on \(arguments[index + 1])")
    exit(ok ? 0 : 1)
}
if let index = arguments.firstIndex(of: "--snapshot") {
    AppStatus.enabled = false
    _ = NSApplication.shared
    Snapshot.run(outputDirectory: arguments.indices.contains(index + 1) ? arguments[index + 1] : ".")
    exit(0)
}

// One copy at a time. Two would show two icons, double every notification, and fight over the
// Phone Access port and Tailscale mapping (one quitting removes the other's). A copy that is still
// quitting (e.g. during an update) gets a few seconds; a live one is shown instead and we leave.
if let bundleID = Bundle.main.bundleIdentifier {
    func others() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
    }
    let deadline = Date().addingTimeInterval(5)
    while !others().isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
    if !others().isEmpty {
        DistributedNotificationCenter.default().postNotificationName(AppStatus.toggleNotification, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
        exit(0)   // not NSApp.terminate: our quit path would tear down the other copy's Phone Access
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
