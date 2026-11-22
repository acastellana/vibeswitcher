import Foundation
import VibeCore

/// `build.switch` in the server (the start plan's S8b; the security architecture document's S8, the rule on switches,
/// and S9; the app's `HostClient` handover, port-map rows 52, 97 and 99): the host hands over to an installed build,
/// keeping every session, and the server says how it went before it is itself replaced.
///
/// - **The plan** (`SwitchPlan`): from the host's notes as asked now (`HostNotes.build`, the build that runs), the
///   commits installed (`installed(in:)`: the install root's folders named by a commit) and the live sessions' roles
///   (`LeadTeams.role(label:)`). A target not a commit, not installed, or asked while a worker or verifier is live
///   (decision 6, ST-D15: the live ones named) is refused with nothing asked of the host; the running build is
///   `already`.
/// - **The handover**: `HostRequest.handover(executable: <installRoot>/<commit>/bin/vibeswitcher-host)` on a
///   connection of its own through the link's dialer (the server's registered connector, so the host takes it as the
///   app's), where the host checks the target (`HandoverTarget`) and probes it. The reply is waited for `replyWait`
///   (the host's probe limit and a margin), with a note every `breadcrumb`; past it the connection stays open
///   `lateWait` more, and what comes then counts "after the wait". The connection closing without an answer is the
///   host executing the target (as the app took the drop).
/// - **The outcome** (`outcome(before:target:after:refusal:afterTheWait:)`): a refusal is the host's, said as it gave
///   it; otherwise the link's next welcome (at most `welcomeWait`) and the host's notes then say who answered. The same
///   pid on the target's build is handed over; the old build answering (a fallback), another pid, or no host at all is
///   a failure, said so. When the link has no welcome to give (it gave up reconnecting while the new build came up, or
///   none came in `welcomeWait`), the host is asked again on connections of its own (`HostCheck`, every `confirmEvery`
///   for `confirmWait`) before "no build answered" is said: a switch right after a start (2026-11-22, the real node)
///   said the host went away while it had handed over, its link having given up a moment before the new build listened.
///
/// The server replies with the outcome before its own replacement: a switch to a build whose server's bytes differ
/// ends the running server child once it is idle, or `ServerChild.idleLimit` after the first look (stage 2's 9d), and
/// that first look waits until this server's link has connected again to the new image (at most
/// `ServerChild.reconnectGrace`), so the welcome and the notes this reply waits for come first. The link stays open,
/// so in practice the server is replaced `idleLimit` after it reconnected.
///
/// The rule on switches is the server's first, from the labels it sees, and the node's host holds it too, before its
/// probe and again in the turn that executes (`HostServer.teamsWorking`): a worker a lead starts while the probe runs,
/// or one a lead started under a lead's label, refuses the handover there, and the reply says the host's words.
///
/// A handover is also refused while the seal has a change nobody accepted under the builds folder or the unit's folder
/// (`held`, `HeldChange` on `heldNames`; the lead's call of 2026-11-16 on the S8c review's finding 5): a switch then goes
/// only to a build folder the user looked at. Asked after the plan, so `already` (the way a follow-up the command line
/// didn't finish is finished, which itself changed the unit's folder) is never refused by it.
public struct SwitchRequest {
    /// The watched things a handover waits on the user's accept for: the builds folder and the unit's folder.
    public static var heldNames: [String] { [HooksRequest.buildsName, "~/.config/systemd/user"] }
    /// What a switch refused for one of them says to do first.
    public static let acceptFirst = "accept the held config first (vibeswitcher config held / config accept)"

    /// The host's probe limit (`HostHandover.probeLimit`, internal to `VibeHost`; a test ties the two).
    public static let probeLimit: TimeInterval = 180
    /// How long the handover's reply is waited for: the host's probe limit, and a margin for saving the sessions and the
    /// exec (the app's `handoverWait`).
    public static let replyWait: TimeInterval = probeLimit + 15
    /// How often the wait for the reply is noted.
    public static let breadcrumb: TimeInterval = 15
    /// How long the connection stays open after `replyWait` for a late answer.
    public static let lateWait: TimeInterval = 60
    /// How long the link's next welcome is waited for once the host executed the target.
    public static let welcomeWait: TimeInterval = 60
    /// When the link has no welcome to give: how long the host is asked again on connections of its own, and how often.
    public static let confirmWait: TimeInterval = 30
    public static let confirmEvery: TimeInterval = 1
    /// The longest a `build.switch` can take to answer: what the command line waits for at least (S8c). The host's
    /// notes are asked twice (before the plan, after the welcome), each at most `Requests.notesWait`.
    public static let longestWait: TimeInterval = replyWait + lateWait + welcomeWait + confirmWait + HostCheck.patience + 2 * Requests.notesWait

    /// The waits a switch runs on; a test shortens them, or arms them on a clock it moves (`later`).
    public struct Timing {
        public var replyWait = SwitchRequest.replyWait
        public var breadcrumb = SwitchRequest.breadcrumb
        public var lateWait = SwitchRequest.lateWait
        public var welcomeWait = SwitchRequest.welcomeWait
        public var confirmWait = SwitchRequest.confirmWait
        public var confirmEvery = SwitchRequest.confirmEvery
        public var notesWait = Requests.notesWait
        /// Where every wait is armed: real time when nil.
        public var later: HostLink.Later?
        public init() {}
    }

    /// What `run` answers: a result, or a refusal with its code.
    public enum Answer: Equatable, Sendable {
        case done(NodeWire.Value)
        case refused(NodeWire.Code, String)
    }

    /// How a handover went (the app's `handoverOutcome`).
    public enum Outcome: Equatable, Sendable {
        /// The host that was asked runs the target now: the same pid, on the target's build.
        case handedOver(commit: String, pid: Int32?, afterTheWait: Bool)
        /// The same host answered on another build than the target (the new build couldn't restore and went back).
        case oldBuildAnswered(pid: Int32?, build: String?, asked: String)
        /// Another host answered: another pid than the one asked.
        case otherHostAnswered(pid: Int32?, build: String?, was: Int32?)
        /// No host answered after the handover.
        case hostGone(pid: Int32?)
        /// The host refused, with its reason.
        case refused(String)

        public var isHandedOver: Bool { if case .handedOver = self { return true } else { return false } }

        /// What the reply and the server's log say.
        public var text: String {
            func pid(_ pid: Int32?) -> String { pid.map(String.init) ?? "?" }
            switch self {
            case .handedOver(let commit, let host, let afterTheWait):
                return "handed over\(afterTheWait ? " after the wait" : "") (pid \(pid(host)), build \(commit))"
            case .oldBuildAnswered(let host, let build, let asked):
                return "handover failed: the old build answered (pid \(pid(host)), build \(build ?? "?"); asked for \(asked))"
            case .otherHostAnswered(let host, let build, let was):
                return "handover failed: a different host answered (pid \(pid(host)), build \(build ?? "?"); was pid \(pid(was)))"
            case .hostGone(let was):
                return "handover failed: the host (pid \(pid(was))) went away and no build answered"
            case .refused(let why):
                return "handover failed: \(ConfigSeal.inert(why, limit: .max))"
            }
        }
    }

    /// The outcome of a handover to `target` asked of the host `before` names (its pid, and the build it ran), from what
    /// answered `after` (nil: no host did) or the host's `refusal`. `afterTheWait`: the answer came past `replyWait`.
    /// A host too old to give its pid is judged by its build alone.
    public static func outcome(before: (pid: Int32?, build: String?), target: String, after: (pid: Int32?, build: String?)?,
                               refusal: String?, afterTheWait: Bool) -> Outcome {
        if let refusal { return .refused(refusal) }
        guard let after else { return .hostGone(pid: before.pid) }
        if before.pid != nil, after.pid != before.pid { return .otherHostAnswered(pid: after.pid, build: after.build, was: before.pid) }
        guard after.build == target else { return .oldBuildAnswered(pid: after.pid, build: after.build, asked: target) }
        return .handedOver(commit: target, pid: after.pid, afterTheWait: afterTheWait)
    }

    public let link: HostLink
    public let installRoot: String
    public var timing: Timing
    let dialer: HostDialer
    let note: (String) -> Void
    /// Why a handover is refused now for a change the seal holds (`HeldChange`), or nil; none: not asked. Blocking (the
    /// vault's calls go to the host): run off the link's queue.
    let held: (@Sendable () -> String?)?
    /// Parks the workers of the live sessions given that only wait on their lead (`SwitchPark`, the engine's), for a
    /// switch to the commit given: what it parked, by `SwitchPark.Worker.named`, on the link's queue. Nil: none parked
    /// (a server with no engine).
    public typealias Park = (_ live: [HostSession], _ commit: String, _ done: @escaping ([String]) -> Void) -> Void
    let park: Park?
    /// How long the sessions parked may take to end before the switch is planned again.
    static let parkedEndLimit: TimeInterval = 15

    /// A switch on `link`'s host between the builds of `installRoot`, asked through the link's own dialer; `held` asked
    /// before a handover; `park` asked when only workers and verifiers stand in the way.
    public init(link: HostLink, installRoot: String, timing: Timing = Timing(), held: (@Sendable () -> String?)? = nil,
                park: Park? = nil, note: @escaping (String) -> Void = { _ in }) {
        self.link = link
        self.installRoot = installRoot
        self.timing = timing
        dialer = link.dialer
        self.held = held
        self.park = park
        self.note = note
    }

    /// `build.switch` to `commit`: the plan, then the handover and its outcome; `reply` once, on the link's queue. Call
    /// on the link's queue. While workers or verifiers live, the workers that only wait on their lead are parked first
    /// (`SwitchPark`), once a held change wouldn't refuse the switch anyway, and the switch is planned again once their
    /// sessions have ended: any worker mid-turn, verifier or other team member still refuses it (decision 6).
    public func run(commit: String, reply: @escaping (Answer) -> Void) {
        run(commit: commit, parked: nil, reply: reply)
    }

    /// `parked`: the workers parked for this switch already (nil: not tried yet), said in its reply.
    private func run(commit: String, parked: [String]?, reply plainReply: @escaping (Answer) -> Void) {
        let reply = { (answer: Answer) in
            guard let parked, !parked.isEmpty else { return plainReply(answer) }
            switch answer {
            case .done(let value):
                var fields = value.object ?? [:]
                fields["parked"] = .array(parked.map(NodeWire.Value.string))
                plainReply(.done(.object(fields)))
            case .refused(let code, let why):
                plainReply(.refused(code, why + " (parked meanwhile, idle since their last report: \(parked.joined(separator: ", ")))"))
            }
        }
        guard NodeUnit.isCommit(commit) else { return reply(.refused(.badArgs, "build.switch needs commit, 40 lowercase hex digits")) }
        notes { notes in
            let running = notes?.build
            let live = link.sessions.filter(\.isLive)
            let roles = live.compactMap { LeadTeams.role(label: $0.label) }
            switch SwitchPlan.plan(running: running, target: commit, installed: Self.installed(in: installRoot), live: roles) {
            case .badCommit:
                reply(.refused(.badArgs, "build.switch needs commit, 40 lowercase hex digits"))
            case .already:
                reply(.done(.object(["outcome": .string("already"), "commit": .string(commit),
                                     "said": .string("\(commit) runs already: nothing to switch")])))
            case .notInstalled:
                reply(.refused(.refused, "\(commit) isn't installed in \(installRoot): install it with install-node.sh, then switch"))
            case .refusedWhileTeamsWork:
                guard parked == nil, let park else {
                    let working = Self.blockers(live)
                    note("build.switch \(commit) refused: \(working.count) workers or verifiers live")
                    return reply(.refused(.refused, Self.blockedText(working)))
                }
                // A held change refuses it whatever the team: no worker is parked for a switch that can't run.
                let (queue, held) = (link.queue, self.held)
                DispatchQueue.global(qos: .userInitiated).async {
                    let refusal = held?()
                    queue.async {
                        if let refusal {
                            note("build.switch \(commit) refused: \(refusal)")
                            return reply(.refused(.refused, refusal))
                        }
                        park(live, commit) { names in
                            guard !names.isEmpty else { return run(commit: commit, parked: [], reply: plainReply) }
                            whenEnded(names: names, of: live) { run(commit: commit, parked: names, reply: plainReply) }
                        }
                    }
                }
            case .handOver(let target):
                guard let held else { return handOver(to: target, before: (link.hostPID, running), reply: reply) }
                let queue = link.queue
                DispatchQueue.global(qos: .userInitiated).async {
                    let refusal = held()
                    queue.async {
                        if let refusal {
                            note("build.switch \(commit) refused: \(refusal)")
                            return reply(.refused(.refused, refusal))
                        }
                        handOver(to: target, before: (link.hostPID, running), reply: reply)
                    }
                }
            }
        }
    }

    /// `then` on the link's queue once the sessions of `live` named `names` (`SwitchPark.Worker.named`) are no longer
    /// live in the link's list, or `parkedEndLimit` later.
    private func whenEnded(names: [String], of live: [HostSession], then: @escaping () -> Void) {
        let ids = Set(live.filter { session in names.contains("\(session.tty) (\(ConfigSeal.inert(session.label, limit: 80)))") }.map(\.id))
        let (link, deadline) = (self.link, Platform.Clock.steadyDate().addingTimeInterval(Self.parkedEndLimit))
        func look() {
            if Platform.Clock.steadyDate() >= deadline || !link.sessions.contains(where: { ids.contains($0.id) && $0.isLive }) { return then() }
            link.queue.asyncAfter(deadline: .now() + 0.1) { look() }
        }
        look()
    }

    /// The live sessions that refuse a switch by the rule on switches (decision 6): each worker's and verifier's, by
    /// its terminal and label ("ttypts4 (Worker · fix-login)"). `status` lists them (`switchBlockers`), so `vibeswitcher
    /// switch` says before its code is asked whether the switch can run now.
    public static func blockers(_ live: [HostSession]) -> [String] {
        live.filter { session in session.isLive && (LeadTeams.role(label: session.label).map { $0 != .lead } ?? false) }
            .map { "\($0.tty) (\(ConfigSeal.inert($0.label, limit: 80)))" }
    }

    /// The rule's words for `blockers`, as the server's refusal and the command line say them.
    public static func blockedText(_ blockers: [String]) -> String {
        "no switch of builds while a worker or verifier runs (decision 6, the rule on switches): "
            + blockers.joined(separator: ", ") + " live; switch once they have ended (a lead may stay)"
    }

    // MARK: The handover

    private func handOver(to target: String, before: (pid: Int32?, build: String?), reply: @escaping (Answer) -> Void) {
        let executable = installRoot + "/" + target + "/bin/" + BuildInfo.host
        let welcomes = link.welcomes
        let (link, timing, note) = (self.link, self.timing, self.note)
        note("build.switch: asking the host (pid \(before.pid.map(String.init) ?? "?"), build \(before.build ?? "?")) to hand over to \(executable)")
        let finish = { (outcome: Outcome) in
            note("build.switch: " + outcome.text)
            guard case .handedOver(let commit, let pid, let afterTheWait) = outcome else { return reply(.refused(.refused, outcome.text)) }
            reply(.done(.object(["outcome": .string("handed-over"), "commit": .string(commit), "from": before.build.map(NodeWire.Value.string) ?? .null,
                                 "pid": pid.map { .int(Int($0)) } ?? .null, "afterTheWait": .bool(afterTheWait), "said": .string(outcome.text)])))
        }
        HandoverCall(dialer: dialer, executable: executable, timing: timing, note: note).start { result in
            link.queue.async {
                switch result {
                case .unreachable(let why):
                    let text = "the host couldn't be asked to hand over: \(ConfigSeal.inert(why, limit: .max))"
                    note("build.switch: " + text)
                    reply(.refused(.refused, text))
                case .unanswered(let waited):
                    finish(.refused("the host didn't answer the handover in \(Int(waited)) s; it runs on as it was"))
                case .answered(.error(let why), let afterTheWait):
                    finish(Self.outcome(before: before, target: target, after: nil, refusal: why, afterTheWait: afterTheWait))
                case .answered(_, let afterTheWait), .closed(let afterTheWait):
                    // The host executes the target (or went): its next welcome, and its notes then, say who answered.
                    self.welcome(after: welcomes) { welcomed in
                        guard welcomed else {
                            // Nothing on the link: who runs is asked on connections of its own before "no build answered".
                            return self.confirm(attempts: max(1, Int(timing.confirmWait / timing.confirmEvery))) { answered in
                                finish(Self.outcome(before: before, target: target, after: answered, refusal: nil, afterTheWait: afterTheWait))
                            }
                        }
                        self.notes { notes in
                            finish(Self.outcome(before: before, target: target, after: (link.hostPID, notes?.build), refusal: nil,
                                                afterTheWait: afterTheWait))
                        }
                    }
                }
            }
        }
    }

    /// Who runs the host, asked on a connection of its own (`HostCheck`: its welcome's pid, its notes' build), up to
    /// `attempts` times `confirmEvery` apart: `done` (on the link's queue) with the first answer, nil when none came.
    private func confirm(attempts: Int, _ done: @escaping ((pid: Int32?, build: String?)?) -> Void) {
        let (queue, timing, dialer, note) = (link.queue, self.timing, self.dialer, self.note)
        HostCheck(dialer: dialer, later: timing.later).start { answered in
            queue.async {
                if let answered {
                    note("build.switch: the link had no welcome; asked on a connection of its own, pid \(answered.pid.map(String.init) ?? "?") "
                         + "runs build \(answered.build ?? "?")")
                    return done(answered)
                }
                guard attempts > 1 else { return done(nil) }
                Self.arm(timing.confirmEvery, on: timing.later) { queue.async { self.confirm(attempts: attempts - 1, done) } }
            }
        }
    }

    /// `done` (on the link's queue) once the link has a welcome past `count`, false when the link went or none came in
    /// `welcomeWait`.
    private func welcome(after count: Int, _ done: @escaping (Bool) -> Void) {
        let once = Once()
        link.welcomed(after: count) { welcomed in if once.first() { done(welcomed) } }
        let queue = link.queue
        after(timing.welcomeWait) { queue.async { if once.first() { done(false) } } }
    }

    /// The host's notes asked now (`HostLink.notes`), `done` once on the link's queue: nil when they didn't come in
    /// `notesWait`.
    private func notes(_ done: @escaping (HostNotes?) -> Void) {
        let once = Once()
        let queue = link.queue
        link.notes { notes in queue.async { if once.first() { done(notes) } } }
        after(timing.notesWait) { queue.async { if once.first() { done(nil) } } }
    }

    private func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        Self.arm(seconds, on: timing.later, work)
    }

    static func arm(_ seconds: TimeInterval, on later: HostLink.Later?, _ work: @escaping () -> Void) {
        if let later { later(seconds, work) } else { DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work) }
    }

    /// A one-shot guard: the first `first()` is true.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    // MARK: The install root

    /// The commits installed in `installRoot`: its entries named by 40 lowercase hex digits that are folders (a link
    /// isn't followed), sorted.
    public static func installed(in installRoot: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: installRoot)) ?? []
        return names.filter { name in
            var info = stat()
            return NodeUnit.isCommit(name) && lstat(installRoot + "/" + name, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        }.sorted()
    }

    /// The most of `<installRoot>/installs` read.
    static let installsLimit = 1 << 20

    /// The lines of `<installRoot>/installs` (`<commit> <ISO time>`, oldest first, ST-D14), read as a regular file opened
    /// without following a link, at most `installsLimit` bytes; none when it can't be.
    public static func installs(in installRoot: String) -> [String] {
        let fd = Sys.open(installRoot + "/installs", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { Sys.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return [] }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < installsLimit {
            let count = buffer.withUnsafeMutableBytes { Sys.read(fd, $0.baseAddress, min($0.count, installsLimit - data.count)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// `status`'s `builds`: the install root, the commits installed, and the rollback's target from its `installs` for
    /// the build that runs (`running`, the host's notes'), with its line; nil when there is none.
    public static func buildsValue(installRoot: String, running: String?) -> NodeWire.Value {
        let rollback = running.flatMap { SwitchPlan.rollbackTarget(installs: installs(in: installRoot), running: $0) }
        return .object(["installRoot": .string(installRoot), "installed": .array(installed(in: installRoot).map(NodeWire.Value.string)),
                        "rollback": rollback.map { .object(["commit": .string($0.commit), "line": .string($0.line)]) } ?? .null])
    }
}

/// Who runs the host, asked on a connection of its own: the hello, its welcome's pid, then its notes' build. `done`
/// once, on this call's queue: the pid and build, or nil when it couldn't connect, closed, or didn't answer in
/// `patience`.
final class HostCheck: @unchecked Sendable {
    /// How long one check waits for its answers.
    static let patience: TimeInterval = 10

    private let dialer: HostDialer
    private let later: HostLink.Later?
    private let queue = DispatchQueue(label: "vibenode.build-switch.check")
    // On `queue`.
    private var connection: HostConnection?
    private var pid: Int32?
    private var welcomed = false
    private var notesSeq: Int?
    private var done: (((pid: Int32?, build: String?)?) -> Void)?

    init(dialer: HostDialer, later: HostLink.Later?) {
        self.dialer = dialer
        self.later = later
    }

    func start(_ done: @escaping ((pid: Int32?, build: String?)?) -> Void) {
        queue.async { [self] in
            self.done = done
            let made: HostConnection
            do { made = try dialer.connect(queue: queue, patience: 5) } catch { return finish(nil) }
            connection = made
            made.onClose = { [self] in finish(nil) }
            made.onEvent = { [self] envelope in
                if case .welcome(_, _, _, _, let pid, _) = envelope.event, !welcomed {
                    welcomed = true
                    self.pid = pid
                    do { notesSeq = try made.send(.hostNotes) } catch { finish(nil) }
                } else if let notesSeq, envelope.replyTo == notesSeq {
                    if case .hostNotes(let notes) = envelope.event { finish((self.pid, notes.build)) } else { finish((self.pid, nil)) }
                }
            }
            do { try made.send(.hello(protocolVersion: HostProtocol.version, app: "vibeswitcher-server")) } catch { return finish(nil) }
            SwitchRequest.arm(Self.patience, on: later) { [weak self] in
                guard let self else { return }
                self.queue.async { self.finish(nil) }
            }
        }
    }

    private func finish(_ answer: (pid: Int32?, build: String?)?) {
        guard let done else { return }
        self.done = nil
        let open = connection
        connection = nil
        open?.onClose = nil
        open?.onEvent = nil
        open?.close()
        done(answer)
    }
}

/// The handover asked on a connection of its own (hello, the welcome, `handover`, its reply), on a queue of its own:
/// its reply as it came, the connection closing without one, or none in `replyWait` + `lateWait` (the connection
/// closed then). Every `breadcrumb` before `replyWait` the wait is noted, and at `replyWait` that it goes on.
private final class HandoverCall: @unchecked Sendable {
    enum Result {
        case answered(HostEvent, afterTheWait: Bool)
        case closed(afterTheWait: Bool)
        case unanswered(TimeInterval)
        case unreachable(String)
    }

    private let dialer: HostDialer
    private let executable: String
    private let timing: SwitchRequest.Timing
    private let note: (String) -> Void
    private let queue = DispatchQueue(label: "vibenode.build-switch")
    // On `queue`.
    private var connection: HostConnection?
    private var seq: Int?
    private var afterTheWait = false
    private var done: ((Result) -> Void)?

    init(dialer: HostDialer, executable: String, timing: SwitchRequest.Timing, note: @escaping (String) -> Void) {
        self.dialer = dialer
        self.executable = executable
        self.timing = timing
        self.note = note
    }

    /// Asks it; `done` once, on this call's queue. The call keeps itself until then.
    func start(_ done: @escaping (Result) -> Void) {
        queue.async { [self] in
            self.done = done
            let made: HostConnection
            do { made = try dialer.connect(queue: queue, patience: 5) } catch { return finish(.unreachable("\(error)")) }
            connection = made
            // A close before the handover was sent is no outcome: nothing was asked (another switch's exec, or a host
            // that went before it welcomed this connection).
            made.onClose = { [self] in
                finish(seq == nil ? .unreachable("the host closed the connection before the handover was asked") : .closed(afterTheWait: afterTheWait))
            }
            made.onEvent = { [self] envelope in
                if case .welcome = envelope.event, seq == nil {
                    do { seq = try made.send(.handover(executable: executable)) } catch { finish(.unreachable("the handover wasn't sent: \(error)")) }
                } else if let seq, envelope.replyTo == seq {
                    finish(.answered(envelope.event, afterTheWait: afterTheWait))
                }
            }
            do { try made.send(.hello(protocolVersion: HostProtocol.version, app: "vibeswitcher-server")) } catch {
                return finish(.unreachable("the hello wasn't sent: \(error)"))
            }
            for seconds in stride(from: timing.breadcrumb, to: timing.replyWait, by: timing.breadcrumb) {
                arm(seconds) { [self] in note("build.switch: waiting for the new build's probe, \(Int(seconds)) s") }
            }
            arm(timing.replyWait) { [self] in
                afterTheWait = true
                note("build.switch: no answer in \(Int(timing.replyWait)) s; the connection stays open \(Int(timing.lateWait)) s more")
            }
            arm(timing.replyWait + timing.lateWait) { [self] in finish(.unanswered(timing.replyWait + timing.lateWait)) }
        }
    }

    /// `work` on `queue` after `seconds`, unless the call ended by then.
    private func arm(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        SwitchRequest.arm(seconds, on: timing.later) { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, self.done != nil else { return }
                work()
            }
        }
    }

    private func finish(_ result: Result) {
        guard let done else { return }
        self.done = nil
        let open = connection
        connection = nil
        open?.onClose = nil
        open?.onEvent = nil
        open?.close()
        done(result)
    }
}
