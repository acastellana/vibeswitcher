import AppKit
import VibeCore

// Command-line maintenance modes, e.g. `VibeSwitcher.app/Contents/MacOS/VibeSwitcher --dump`.
let arguments = CommandLine.arguments
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
if arguments.contains("--toggle") {
    DistributedNotificationCenter.default().postNotificationName(AppStatus.toggleNotification, object: nil,
                                                                 userInfo: nil, deliverImmediately: true)
    exit(0)
}
if let index = arguments.firstIndex(of: "--open"), arguments.indices.contains(index + 1) {
    // Asks the running app to open a session, exactly like clicking its row.
    DistributedNotificationCenter.default().postNotificationName(AppStatus.openNotification, object: arguments[index + 1],
                                                                 userInfo: nil, deliverImmediately: true)
    exit(0)
}
if let index = arguments.firstIndex(of: "--new"), arguments.indices.contains(index + 1),
   let agent = Agent(rawValue: arguments[index + 1]) {
    // Same as the popover's "New session" menu: a new Terminal window running the configured command.
    let folder = arguments.indices.contains(index + 2) ? arguments[index + 2] : FileManager.default.currentDirectoryPath
    let command = Preferences().command(for: agent)
    Launcher.launch(command: command, in: (folder as NSString).expandingTildeInPath)
    Thread.sleep(forTimeInterval: 2) // launch runs asynchronously
    print("started \(command) in \(folder)")
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
