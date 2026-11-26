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
    /// The user's node's job for a build (`NodeAgent.Job.node`: a checked node's command line), as `start` writes it.
    static func job(_ build: NodePins.Build) -> NodeAgent.Job? {
        let home = VibePaths.accountHome
        return try? NodeAgent.Job.node(prefix: NodeFolders.defaultPrefix(accountHome: home), commit: build.commit, home: home,
                                       dataRoot: NodeFolders.nodeRoot(accountHome: home), atLogin: false).get()
    }

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
                                                          confirm: { _ in .success(()) }, serverStop: { _ in .none("no server is asked") }, job: MacAgentCommand.job))
        switch agent.start(job, build: own.build, folder: own.folder) {
        case .success: return 0
        case .failure(let why): return said(why)
        }
    }

    /// `stop`: with a server that answers, its own stop asked once, under its rule (`TypedWord.said(approval:)`: the typed
    /// code, or the Mac's dialog), its answer kept (refused or unreadable: nothing is stopped); with none, what ends and
    /// how said and the typed code asked, then the bootout; then the job unloaded and waited for.
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
                                          serverStop: { what in
                                              guard let client = connection.client else { return .none("no server answered") }
                                              switch TypedWord.said(approval: client.approvalRule, action: action, what: what) {
                                              case .failure(let not): return .refused(StartRefusal(not.refusal))
                                              case .success(let typed):
                                                  // Within the server's stop's own bound (`Requests.stopWait + 30`); an answer
                                                  // that can't be read is a refusal (`throughServer`).
                                                  switch StopCommand.throughServer(context, client, action: action, typed: typed) {
                                                  case .success: return .stopped
                                                  case .failure(let why): return .refused(why)
                                                  }
                                              }
                                          },
                                          job: MacAgentCommand.job,
                                          // The server asked for `status` (its count, `host.liveSessions`), before the
                                          // prompt; its connection kept for its stop. An answer refused or unreadable
                                          // is a refusal: no bootout then.
                                          server: {
                                              switch NodeClient.connect(context) {
                                              case .failure(let failure): return .none(failure.message)
                                              case .success(let client):
                                                  switch client.read(WireKinds.Status.self, WireNoArgs()) {
                                                  case .failure(let failure):
                                                      return .refused(StartRefusal("its answer to status couldn't be read: \(failure.message)", exitCode: 1))
                                                  case .refused(let reply):
                                                      let code = reply.error?.code ?? "internal"
                                                      return .refused(StartRefusal("\(code): \(ConfigSeal.inert(reply.error?.message ?? "no reason", limit: .max))", exitCode: Say.exitCode(replyCode: code)))
                                                  case .success(let status, _):
                                                      connection.client = client
                                                      return .answered(sessions: status.host?.liveSessions ?? 0)
                                                  }
                                              }
                                          })
        switch MacAgent(place: place, steps: steps).stop() {
        case .success: return 0
        case .failure(let why): return said(why)
        }
    }

    /// `status`'s first line, from the host itself: nil when the node runs (the server's status follows), else the exit
    /// code once said.
    static func status(json: Bool) -> Int32? {
        guard let place = place() else { return Say.unbuilt("this system has no launchctl") }
        // With --json the line goes to stderr, so stdout stays the server's JSON.
        let agent = MacAgent(place: place, steps: .system(place: place, pins: { NodePins.read() }, say: { json ? Say.err($0) : Say.out($0) },
                                                          confirm: { _ in .success(()) }, serverStop: { _ in .none("no server is asked") }, job: MacAgentCommand.job))
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
