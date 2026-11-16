import Foundation
import VibeCore

/// `vibeswitcher stop`'s order (the start plan's ST-D7), with every step injected (ST-D1): the command line only wires
/// `Steps`, and tests drive this with recording stand-ins.
///
/// 1. The server, asked first (`server`): connected, checked (`ServerCheck`), its hello read, and asked `status` for
///    how many sessions live.
/// 2. A server that answered: its confirmation (`NodeTexts.stop(live:)`) and the typed code, then the server's own stop
///    (`throughServer`: the request, its journal entry and its line, as before S3). It never falls back.
/// 3. Otherwise (nothing listens, a listener that sends no hello, or one that fails `ServerCheck`): on a scratch node,
///    refused as before (69 with the client's "the node isn't running", 1 no hello, 77 the check). On the user's node
///    the fallback, which acts on the unit or the recorded host, not on what listens:
///    1. the installed-build check (ST-D3), before any write or call;
///    2. a machine whose manager's socket is missing is refused;
///    3. what the fallback stops (`fallback`: the unit, or the recorded host checked and shown by pid and command
///       line), or why nothing will be (the node isn't running, or the recorded pid now names another process);
///    4. the typed code;
///    5. the journal entry `NodeJournal.entry(event: "stop", action:)`, so `status` doesn't show the user's own stop as
///       unexplained;
///    6. the stopper (`NodeStopper.stopUnit` or `stopDetached`).
///
/// On a machine without systemd there is no journal: the entry is written when it can be, and said not recorded when
/// it can't (2026-11-16); through systemd an entry not written refuses the stop.
public struct StopSequence {
    /// What asking the server came to.
    public enum ServerAnswer: Equatable, Sendable {
        /// It answered, passed `ServerCheck`, and `status` says how many sessions live.
        case answered(live: Int)
        /// Nothing listens: why, as the client says it ("the node isn't running: …").
        case notRunning(String)
        /// What listens sent no hello in time (or didn't answer `status`), and why.
        case noHello(String)
        /// A listener that fails `ServerCheck`, and why.
        case refusedByCheck(String)
        /// An answer refused otherwise (an error reply to `status`), as the command line refuses it.
        case failed(StartRefusal)
    }

    public enum Outcome: Equatable, Sendable {
        /// The server took the stop.
        case throughServer
        /// The unit was stopped, or the recorded host ended, without the server.
        case withoutServer
    }

    /// Every step `run` takes, as the command line (or a test) gives them.
    public struct Steps {
        public var kind: () -> StartSequence.Kind
        /// `NodeFolders.installedBuild` of this command line.
        public var installedBuild: () -> Result<(commit: String, folder: String), StartRefusal>
        public var server: () -> ServerAnswer
        /// Asks for `code` on the controlling terminal, showing `what` (`TypedWord.ask`).
        public var typed: (_ code: String, _ what: String) -> TypedOutcome
        /// Says a line on stdout (the plan's `confirm`).
        public var say: (String) -> Void
        /// Writes an entry of the command line's (`NodeContext.writeJournal`); false when it didn't go.
        public var journal: ([(name: String, value: String)]) -> Bool
        /// The server's stop for the action whose code was typed: the request, its journal entry and what it says.
        public var throughServer: (_ action: String) -> Result<Void, StartRefusal>
        /// What the fallback stops on this machine, said before the code (`NodeTexts.stopUnit`, `stopDetached`), or why
        /// nothing will be stopped.
        public var fallback: (NodeFolders.Mode) -> Result<String, StartRefusal>
        /// The stop itself (`NodeStopper.stopUnit` or `stopDetached`).
        public var stopper: (NodeFolders.Mode) -> Result<Void, StartRefusal>
        /// A new action id (a UUID's text), from which the typed code comes (`NodeIds.code(action:)`).
        public var newAction: () -> String

        public init(kind: @escaping () -> StartSequence.Kind,
                    installedBuild: @escaping () -> Result<(commit: String, folder: String), StartRefusal>,
                    server: @escaping () -> ServerAnswer, typed: @escaping (_ code: String, _ what: String) -> TypedOutcome,
                    say: @escaping (String) -> Void, journal: @escaping ([(name: String, value: String)]) -> Bool,
                    throughServer: @escaping (_ action: String) -> Result<Void, StartRefusal>,
                    fallback: @escaping (NodeFolders.Mode) -> Result<String, StartRefusal>,
                    stopper: @escaping (NodeFolders.Mode) -> Result<Void, StartRefusal>,
                    newAction: @escaping () -> String = { UUID().uuidString.lowercased() }) {
            self.kind = kind
            self.installedBuild = installedBuild
            self.server = server
            self.typed = typed
            self.say = say
            self.journal = journal
            self.throughServer = throughServer
            self.fallback = fallback
            self.stopper = stopper
            self.newAction = newAction
        }
    }

    public let steps: Steps

    public init(steps: Steps) { self.steps = steps }

    /// The kind `stop` runs as: `.scratch` for a scratch node, and on the Mac (`onTheMac`: no node runs detached there,
    /// though `NodeFolders.mode` says `.noSystemd` with no `/run/systemd/system`), so its stop with no server refuses as
    /// before S3 (69, "the node isn't running") with no fallback (the review of S3); the user's node on Linux otherwise,
    /// with this machine's mode (`mode`, read only then).
    public static func kind(isScratch: Bool, onTheMac: Bool, mode: () -> NodeFolders.Mode) -> StartSequence.Kind {
        isScratch || onTheMac ? .scratch : .node(mode())
    }

    /// `stop`, in ST-D7's order (the type's comment).
    public func run() -> Result<Outcome, StartRefusal> {
        let kind = steps.kind()
        let why: String
        switch steps.server() {
        case .failed(let refused):
            return .failure(refused)
        case .answered(let live):
            let action = steps.newAction()
            let outcome = steps.typed(NodeIds.code(action: action), NodeTexts.stop(live: live))
            guard outcome == .typed else { return .failure(StartRefusal(outcome.refusal)) }
            return steps.throughServer(action).map { .throughServer }
        case .notRunning(let said):
            if kind == .scratch { return .failure(StartRefusal(said, exitCode: 69)) }
            why = said
        case .noHello(let said):
            if kind == .scratch { return .failure(StartRefusal(said, exitCode: 1)) }
            why = said
        case .refusedByCheck(let said):
            if kind == .scratch { return .failure(StartRefusal(said)) }
            why = said
        }
        guard case .node(let mode) = kind else { return .failure(StartRefusal(why, exitCode: 69)) }

        if case .failure(let refused) = steps.installedBuild() {
            return .failure(StartRefusal("the node's server didn't answer (\(ConfigSeal.inert(why, limit: .max))), and stop without it runs only from an installed build: \(refused.text)"))
        }
        if mode == .socketMissing {
            return .failure(StartRefusal("the node's server didn't answer (\(ConfigSeal.inert(why, limit: .max))), and the user manager's socket is missing (<runtime folder>/systemd/private): pid 1 is systemd, so stop won't take this machine for one without it; see `systemctl --user status`"))
        }
        let stops: String
        switch steps.fallback(mode) {
        case .failure(let refused): return .failure(refused)
        case .success(let text): stops = text
        }
        steps.say("the node's server didn't answer (\(ConfigSeal.inert(why, limit: .max))): stop goes without it")
        let action = steps.newAction()
        let outcome = steps.typed(NodeIds.code(action: action), stops)
        guard outcome == .typed else { return .failure(StartRefusal(outcome.refusal)) }
        if !steps.journal(NodeJournal.entry(event: "stop", action: action)) {
            guard mode == .noSystemd else {
                return .failure(StartRefusal("the stop couldn't be written to the journal: nothing was stopped", exitCode: 1))
            }
            steps.say("(no journal on a machine without systemd: this stop isn't recorded)")
        }
        switch steps.stopper(mode) {
        case .failure(let refused): return .failure(refused)
        case .success:
            steps.say(mode == .noSystemd ? "the node's host ended" : "the node's unit stopped")
            return .success(.withoutServer)
        }
    }
}
