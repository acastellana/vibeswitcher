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
if arguments.contains("--dump") {
    for session in SessionScanner().scan() {
        let hook = session.hook.map { "\($0.lastEvent) (\(Int(Date().timeIntervalSince1970 - $0.lastEventAt))s ago)" } ?? "no hooks"
        print("\(session.tty)\t\(session.agent.rawValue)\tpid \(session.pid)\t\(hook)\t\(session.cwd ?? "?")")
    }
    exit(0)
}

if let index = arguments.firstIndex(of: "--focus"), arguments.indices.contains(index + 1) {
    // Same code path as clicking a session row.
    let ok = TerminalBridge.focus(tty: arguments[index + 1])
    print(ok ? "focused \(arguments[index + 1])" : "no Terminal tab on \(arguments[index + 1])")
    exit(ok ? 0 : 1)
}
if let index = arguments.firstIndex(of: "--snapshot") {
    _ = NSApplication.shared
    Snapshot.run(outputDirectory: arguments.indices.contains(index + 1) ? arguments[index + 1] : ".")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
