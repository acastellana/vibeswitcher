import Foundation
import VibeCore
import VibeNode

/// The Mac's `start`, `stop` and `status` for the user's node, as its LaunchAgent (`MacAgent`; the node on the Mac's
/// design, "The LaunchAgent: start, stop and status"). Reached only past `NodeContext.usersNodeRefusal`, which on the
/// Mac refuses the user's node (`NodeSystem.macUnbuilt`) until the switch-on review lifts it: every value here is the
/// user's node's (`NodeAgent.Place.user`: the label `dev.vibeswitcher.node`, `~/Library/LaunchAgents`, the node's data
/// root, the home from the user database), the build the command line's own row in the root's record (`NodePins.read`,
/// `Platform.CodeIdentity.ownCdhash`), and nothing a flag, file or variable chooses. A scratch node is never started
/// or stopped here (its harness's, 69, as on Linux).
enum MacAgentCommand {
    /// The user's node's place, or nil where there is no launchctl.
    static func place() -> NodeAgent.Place? {
        guard let launchctl = Platform.Service.launchctl else { return nil }
        return .user(home: VibePaths.accountHome, uid: getuid(), launchctl: launchctl)
    }

    static func start(_ parsed: StartArguments, context: NodeContext) -> Int32 {
        guard !context.isScratch else { return Say.unbuilt(StartSequence.scratchNotStarted) }
        guard let place = place() else { return Say.unbuilt("this system has no launchctl") }
        let home = VibePaths.accountHome
        let pins = NodePins.read()
        let own: (build: NodePins.Build, folder: String)
        switch MacAgent.ownBuild(own: Platform.CodeIdentity.ownCdhash(), pins: pins, prefix: NodeFolders.defaultPrefix(accountHome: home)) {
        case .failure(let why): return said(why)
        case .success(let found): own = found
        }
        let job: NodeAgent.Job
        switch NodeAgent.Job.node(prefix: NodeFolders.defaultPrefix(accountHome: home), commit: own.build.commit, home: home,
                                  dataRoot: place.dataRoot, atLogin: parsed.atLogin) {
        case .failure(let why): return said(why)
        case .success(let made): job = made
        }
        let agent = MacAgent(place: place, steps: .system(place: place, pins: { pins }, say: { Say.out($0) },
                                                          confirm: { _ in .success(()) }, serverStop: {}))
        switch agent.start(job, build: own.build, folder: own.folder) {
        case .success: return 0
        case .failure(let why): return said(why)
        }
    }

    /// `stop`: what ends said and the typed code asked (`TypedWord`), the server's own stop when it answers (it ends the
    /// leads and every session), then the job booted out and waited for.
    static func stop(context: NodeContext) -> Int32 {
        guard let place = place() else { return Say.unbuilt("this system has no launchctl") }
        let action = UUID().uuidString.lowercased()
        let connection = StopCommand.Connection()
        let steps = MacAgent.Steps.system(place: place, pins: { NodePins.read() }, say: { Say.out($0) },
                                          confirm: { what in
                                              let (outcome, typed) = TypedWord.asked(code: NodeIds.code(action: action), what: what)
                                              connection.typed = typed
                                              return outcome == .typed ? .success(()) : .failure(StartRefusal(outcome.refusal))
                                          },
                                          serverStop: {
                                              guard case .answered = StopCommand.server(context, connection), let client = connection.client else { return }
                                              _ = StopCommand.throughServer(context, client, action: action, typed: connection.typed)
                                          })
        switch MacAgent(place: place, steps: steps).stop() {
        case .success: return 0
        case .failure(let why): return said(why)
        }
    }

    /// `status`'s first line, from the host itself: nil when the node runs (the server's status follows), else the exit
    /// code once said.
    static func status() -> Int32? {
        guard let place = place() else { return Say.unbuilt("this system has no launchctl") }
        let agent = MacAgent(place: place, steps: .system(place: place, pins: { NodePins.read() }, say: { Say.out($0) },
                                                          confirm: { _ in .success(()) }, serverStop: {}))
        switch agent.status() {
        case .success: return nil
        case .failure(let why): return said(why)
        }
    }

    static func said(_ why: StartRefusal) -> Int32 {
        if why.exitCode == 77 { return Say.refused(why.text) }
        Say.err("vibeswitcher: \(ConfigSeal.inert(why.text, limit: .max))")
        return why.exitCode
    }
}
