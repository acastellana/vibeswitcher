import AppKit
import VibeCore

// Command-line maintenance modes, e.g. `VibeSwitcher.app/Contents/MacOS/VibeSwitcher --dump`.
let arguments = CommandLine.arguments
if arguments.contains("--install-hooks") || arguments.contains("--uninstall-hooks") {
    let install = arguments.contains("--install-hooks")
    if install, !HookBinary.sync() { print("warning: bundled hook binary not found next to the app executable") }
    var failed = false
    for agent in Agent.allCases {
        do {
            if install { try HookInstaller.install(agent: agent) } else { try HookInstaller.uninstall(agent: agent) }
            print("\(install ? "installed" : "removed") \(agent.displayName) hooks in \(HookInstaller.configURL(for: agent).path)")
        } catch {
            failed = true
            print("error: \(agent.displayName): \(error.localizedDescription)")
        }
    }
    exit(failed ? 1 : 0)
}
if arguments.contains("--dump") {
    for session in SessionScanner().scan() {
        let hook = session.hook.map { "\($0.lastEvent) (\(Int(Date().timeIntervalSince1970 - $0.lastEventAt))s ago)" } ?? "no hooks"
        print("\(session.tty)\t\(session.agent.rawValue)\tpid \(session.pid)\t\(hook)\t\(session.cwd ?? "?")")
    }
    exit(0)
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
