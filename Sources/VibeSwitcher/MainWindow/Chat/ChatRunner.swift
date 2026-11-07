import AppKit
import SwiftUI
import VibeCore

/// What came of a code block's Run.
enum RunOutcome: Equatable {
    case ran
    /// Not typed in, and why, in one short line (said under the composer, and in the button's tooltip).
    case refused(String)
}

/// Why a Run didn't go, where the button itself can tell (the session's own reasons come from `ChatSync.run`).
enum RunRefusal {
    static let noSession = "Not run: nothing here takes commands now."
    static let otherSession = "Not run: another session is shown now. Run it again from its chat if you meant that one."
    static let wayChanged = "Not run: the terminal changed meanwhile (its agent started or exited). Run it again."
    static func notWritten(_ error: Error) -> String {
        "Not run: its script file couldn't be written (\(error.localizedDescription))."
    }
}

/// Runs a code block's command in the selected session (Run, next to Copy). One object for the chat's lifetime: what
/// changes is how the session shown takes a command, if it can.
final class ChatRunner: ObservableObject {
    /// How the selected session takes a command (`RunnableCommand.Way`): its agent's `!` (Claude Code, a lead, Codex)
    /// or its plain shell's prompt. nil when nothing there can (it ended, or it's in a Terminal tab, whose screen is
    /// read-only here): Run isn't shown.
    @Published var way: RunnableCommand.Way?
    /// The selected session: a Run asked about first goes only to the session it was asked for.
    var session: () -> UUID? = { nil }
    /// Types the block's command into the session as `way` takes it, then answers what came of it (on the main thread).
    var run: (RunnableCommand.Runnable, RunnableCommand.Way, @escaping (RunOutcome) -> Void) -> Void = { _, _, done in
        done(.refused(RunRefusal.noSession))
    }
    /// Says why a Run didn't go (the composer's notice line).
    var refused: (String) -> Void = { _ in }
}

/// Runs a code block's command in the session: typed in as `! command` for an agent (it runs in the agent's shell and
/// the output joins the conversation), as it is at a plain shell's prompt. Shown while the session shown can take a
/// command (`ChatRunner.way`); when it can't take it now, it says why. Anything longer than one plain line is shown in
/// full first (see `RunnableCommand`); a script block is shown as it is, then written to its private file and run from
/// there.
struct RunButton: View {
    @ObservedObject var runner: ChatRunner
    let runnable: RunnableCommand.Runnable
    @State private var shown: Shown = .ready
    /// Which click `shown` is for: an earlier click's timer doesn't put back a later one's.
    @State private var click = 0

    enum Shown: Equatable {
        case ready, sent
        case refused(String)
    }

    var body: some View {
        if let way = runner.way {
            Button {
                Self.run(runnable, way: way, with: runner,
                         confirm: { Self.confirmation($0, way: way).runModal() == .alertFirstButtonReturn }) { outcome in
                    switch outcome {
                    case .ran?: show(.sent, for: 1.5)
                    case .refused(let reason)?: show(.refused(reason), for: 4)
                    case nil: break
                    }
                }
            } label: {
                Label(label, systemImage: symbol).font(.system(size: 10.5))
            }
            .buttonStyle(.borderless)
            .chatRowControl()
            .help(help(way))
        }
    }

    private var label: String {
        switch shown {
        case .ready: return "Run"
        case .sent: return "Sent"
        case .refused: return "Not run"
        }
    }

    private var symbol: String {
        switch shown {
        case .ready: return "play.fill"
        case .sent: return "checkmark"
        case .refused: return "exclamationmark.circle"
        }
    }

    private func help(_ way: RunnableCommand.Way) -> String {
        if case .refused(let reason) = shown { return reason }
        let typed = runnable.typed(way)
        return way == .shell ? "Runs it at this terminal's shell prompt: \(typed)" : "Runs it in this session: \(typed)"
    }

    private func show(_ state: Shown, for seconds: TimeInterval) {
        click += 1
        let mine = click
        shown = state
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { if click == mine { shown = .ready } }
    }

    /// Asks first when it must (`confirm`), checks the session is still the one asked about and takes commands the
    /// same way, writes a script's file and has the runner type it. `done`: nil when cancelled; refused with why not
    /// (also told through `runner.refused`; the script's file goes then, unless an earlier Run left it there).
    static func run(_ runnable: RunnableCommand.Runnable, way: RunnableCommand.Way, with runner: ChatRunner,
                    confirm: (RunnableCommand.Runnable) -> Bool, done: @escaping (RunOutcome?) -> Void = { _ in }) {
        let session = runner.session()
        // The file this Run wrote: one there before is an earlier Run's of the same block, maybe still queued to run.
        var wrote: URL?
        func refuse(_ reason: String) {
            if let wrote { try? FileManager.default.removeItem(at: wrote) }
            NSSound.beep()
            runner.refused(reason)
            done(.refused(reason))
        }
        guard !runnable.needsConfirmation || confirm(runnable) else { return done(nil) }
        // While it asked, the window may have come to show another session, or this one's agent started or exited.
        guard let session, runner.session() == session else { return refuse(RunRefusal.otherSession) }
        guard runner.way == way else { return refuse(RunRefusal.wayChanged) }
        if let script = runnable.script {
            let there = FileManager.default.fileExists(atPath: script.file.path)
            do { try script.write() } catch { return refuse(RunRefusal.notWritten(error)) }
            if !there { wrote = script.file }
        }
        runner.run(runnable, way) { outcome in
            if case .refused(let reason) = outcome { return refuse(reason) }
            done(outcome)
        }
    }

    /// The exact text that will run, wrapped so nothing sits off to the side: what's typed, or a script's own lines
    /// with what's typed to run them below.
    static func confirmation(_ runnable: RunnableCommand.Runnable, way: RunnableCommand.Way = .bang) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = way == .shell ? "Run this at the terminal's shell prompt?" : "Run this in the session?"
        let typed = runnable.typed(way)
        if let script = runnable.script {
            alert.informativeText = "These lines run as one \(script.shell) script, exactly as shown. It's typed as:\n\(typed)"
        } else {
            alert.informativeText = "This is exactly what will be typed:"
        }
        let shown = runnable.script?.text ?? typed
        let lines = shown.components(separatedBy: "\n").count
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: min(max(CGFloat(lines) * 16 + 12, 60), 320))
        scroll.hasVerticalScroller = true
        if let text = scroll.documentView as? NSTextView {
            text.string = shown
            text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            text.isEditable = false
            text.isSelectable = true
        }
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
