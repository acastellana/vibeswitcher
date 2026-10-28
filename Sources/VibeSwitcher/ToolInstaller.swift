import AppKit
import Combine
import Foundation
import VibeCore

/// What a start found missing (`LaunchPreflight`), installed on your click: the alert says what's missing, the exact
/// command that installs it and where it comes from, with Install and Cancel (`ToolInstall`); nothing runs before
/// Install, and Cancel changes nothing. Apple's Command Line Tools: `xcode-select --install` opens Apple's installer,
/// and VibeSwitcher looks again every few seconds (off the main thread, for a while) until they're there. Claude Code:
/// Anthropic's installer runs in a session you see, and the look runs again when it exits. Then the start runs again
/// by itself. A miss no install fixes is only explained.
final class ToolInstaller {
    /// Asks (an alert): the index of the button chosen.
    var confirm: (_ title: String, _ text: String, _ buttons: [String]) -> Int = LeadController.runAlert
    /// Runs a program with its arguments, no shell between (off the main thread): the Command Line Tools' install. Its
    /// exit status, and what it said.
    var run: (_ command: [String]) -> (status: Int32, said: String) = ToolInstaller.runProgram
    /// Starts a session in the window (Claude Code's install), on the main thread.
    var startSession: (_ request: SpawnRequest, _ started: @escaping (Result<UUID, HostClientError>) -> Void) -> Void
    /// Hears a session end, once, on the main thread.
    var ended: (_ id: UUID, _ then: @escaping (HostSession.Exit) -> Void) -> Void
    /// Shows a session in the window.
    var select: (UUID) -> Void = { _ in }
    /// Says that VibeSwitcher waits on Apple's installer (its Stop Waiting calls `stop`); returns what takes it away.
    var waiting: (_ text: String, _ stop: @escaping () -> Void) -> () -> Void = ToolInstaller.showWaiting
    /// While Apple's installer runs: a look every `interval` seconds, `polls` at most (half an hour).
    var interval: TimeInterval = 5
    var polls = 360

    static let waitingText = "Installing Apple's Command Line Tools…"

    private var watches: [UUID: AnyCancellable] = [:]

    init(host: HostClient?) {
        startSession = { _, started in started(.failure(HostClientError(message: "No session host."))) }
        ended = { _, _ in }
        guard let host else { return }
        startSession = { request, started in
            // Only the app installs: a test run (no bundle of its own) never does, whatever it was handed.
            guard Bundle.main.bundleURL.pathExtension == "app" else {
                return started(.failure(HostClientError(message: "Only VibeSwitcher.app runs an installer.")))
            }
            host.spawn(request) { started($0.map(\.id)) }
        }
        ended = { [weak self, weak host] id, then in
            guard let self, let host else { return }
            self.watches[id] = host.$sessions.receive(on: DispatchQueue.main).sink { [weak self] sessions in
                // Gone from the list without an exit: the host went with it.
                let exit = sessions.first { $0.id == id }.map(\.exit) ?? HostSession.Exit(status: -1, at: Date())
                guard let exit, self?.watches.removeValue(forKey: id) != nil else { return }
                then(exit)
            }
        }
    }

    /// Offers the install `problem` allows, or only says what's missing. `preflight` looks again (off the main thread);
    /// `retry` starts again once what was installed is there. `what`: what didn't start ("the lead").
    func resolve(_ problem: LaunchPreflight.Problem, what: String = "the lead",
                 preflight: @escaping () -> LaunchPreflight.Problem?, retry: @escaping () -> Void) {
        guard let install = ToolInstall.offer(for: problem) else {
            _ = confirm(problem.title, "The lead wasn't started. " + problem.text, ["OK"])
            return
        }
        let offer = install.offer(problem, what: what)
        guard confirm(offer.title, offer.text, ToolInstall.buttons) == 0 else { return }
        switch install {
        case .commandLineTools: installCommandLineTools(preflight: preflight, retry: retry)
        case .claudeCode: installClaudeCode(preflight: preflight, retry: retry)
        }
    }

    private func installCommandLineTools(preflight: @escaping () -> LaunchPreflight.Problem?, retry: @escaping () -> Void) {
        let (run, interval, polls) = (run, interval, polls)
        DispatchQueue.global(qos: .userInitiated).async {
            let opened = run(ToolInstall.commandLineToolsCommand)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard opened.status == 0 else {
                    _ = self.confirm("Apple's installer didn't open.", "\(ToolInstall.commandLineTools.shown) "
                        + (opened.said.isEmpty ? "exited with status \(opened.status)." : "said: \(opened.said)"), ["OK"])
                    return
                }
                let stop = DispatchSemaphore(value: 0)
                let dismiss = self.waiting(Self.waitingText) { stop.signal() }
                DispatchQueue.global(qos: .utility).async {
                    for _ in 0..<polls {
                        // Stop Waiting: nothing more is looked at or started.
                        if stop.wait(timeout: .now() + interval) == .success { return DispatchQueue.main.async { dismiss() } }
                        if ToolInstall.commandLineTools.done(preflight()) {
                            return DispatchQueue.main.async { dismiss(); retry() }
                        }
                    }
                    DispatchQueue.main.async { [weak self] in
                        dismiss()
                        _ = self?.confirm("Apple's Command Line Tools aren't there yet.",
                                          "VibeSwitcher stopped waiting for them. Once Apple's installer finishes, start the lead again.", ["OK"])
                    }
                }
            }
        }
    }

    private func installClaudeCode(preflight: @escaping () -> LaunchPreflight.Problem?, retry: @escaping () -> Void) {
        let request = SpawnRequest(cwd: NSHomeDirectory(), command: ToolInstall.claudeCodeCommand, env: [:], cols: 120, rows: 36,
                                   keepShell: false, label: ToolInstall.claudeCodeSession, agent: nil)
        let session = "“\(ToolInstall.claudeCodeSession)”"
        startSession(request) { [weak self] started in
            guard let self else { return }
            switch started {
            case .failure(let error):
                _ = self.confirm("Claude Code's installer didn't start.", error.message, ["OK"])
            case .success(let id):
                self.select(id)
                self.ended(id) { [weak self] exit in
                    guard exit.status == 0, exit.signal == nil else {
                        _ = self?.confirm("Claude Code's installer failed.", "It \(exit.cause). Its output stays in the \(session) "
                            + "session, so you can see why.", ["OK"])
                        return
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        let installed = ToolInstall.claudeCode.done(preflight())
                        DispatchQueue.main.async { [weak self] in
                            if installed { return retry() }
                            _ = self?.confirm("Claude Code still isn't found.", "Its installer finished, and your login shell still "
                                + "doesn't find “claude”. Its output is in the \(session) session: it may say how to add claude "
                                + "to your PATH. Then start the lead again.", ["OK"])
                        }
                    }
                }
            }
        }
    }

    /// Runs `command` (a program and its arguments, no shell). Only the app runs it: a test run never installs.
    static func runProgram(_ command: [String]) -> (status: Int32, said: String) {
        guard Bundle.main.bundleURL.pathExtension == "app", let program = command.first else {
            return (1, "only VibeSwitcher.app runs an installer")
        }
        let ran = Shell.run(executable: program, args: Array(command.dropFirst()), in: "/", timeout: 60)
        return (ran.ok ? 0 : (ran.status == 0 ? 1 : ran.status), (ran.error + "\n" + ran.output).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: The waiting panel

    /// A small panel saying what VibeSwitcher waits on, with Stop Waiting (the sandbox draws it too).
    static func waitingPanel(_ text: String, stop: @escaping () -> Void) -> NSPanel {
        WaitingPanel(text, stop: stop)
    }

    static func showWaiting(_ text: String, stop: @escaping () -> Void) -> () -> Void {
        let panel = waitingPanel(text, stop: stop)
        panel.makeKeyAndOrderFront(nil)
        return { panel.orderOut(nil) }
    }
}

/// "Installing Apple's Command Line Tools…", a spinner, and Stop Waiting.
private final class WaitingPanel: NSPanel {
    private let stop: () -> Void

    init(_ text: String, stop: @escaping () -> Void) {
        self.stop = stop
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110), styleMask: [.titled], backing: .buffered, defer: false)
        title = "VibeSwitcher"
        isReleasedWhenClosed = false
        // Apple's installer comes to the front as it opens: this stays in sight beside it (a panel hides when its app
        // isn't active, and VibeSwitcher is an accessory app).
        hidesOnDeactivate = false
        level = .floating
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let detail = NSTextField(wrappingLabelWithString: "Finish Apple's installer: the lead starts once the tools are there.")
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let button = NSButton(title: "Stop Waiting", target: self, action: #selector(stopWaiting))
        let top = NSStackView(views: [spinner, label])
        top.spacing = 8
        let stack = NSStackView(views: [top, detail, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        contentView = stack
        center()
    }

    @objc private func stopWaiting() {
        stop()
        orderOut(nil)
    }
}
