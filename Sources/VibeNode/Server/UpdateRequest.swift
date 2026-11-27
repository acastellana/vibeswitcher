import Foundation
import VibeCore

/// The `update` kind (the no-terminal inventory's D1 and D2; group G3 of v2-remaining): what `vibeswitcher update COMMIT`
/// does up to the handover, done by the node's server, through the same code (`UpdateInstall`, which the command line
/// runs too): the target and the rule on switches checked, the builds folder the accepted one, install-node of the
/// server's own build run in a scope of the user's systemd manager, the builds folder read around it, then the existing
/// `build.switch` act (`Requests.buildSwitch`) with what the install left, so the builds folder is sealed by the switch's
/// own checks. With `rollback` it is `vibeswitcher rollback`: the commit must be the installs record's rollback target,
/// and nothing is installed.
///
/// **A guarded change, not a page's yet.** Its `page` is `.terminalOnly` (`KindSpec`): no page reaches it, whatever
/// `web_acts` says, until the device keys track's slices 14 and 15 wire it behind the guarded-change rule (a biometric of
/// its own, the change shown first). Until then only the user's voice may send it: the voice rule, the typed code, the
/// vault's record before the act, as for `build.switch`.
///
/// **What it never takes from a caller.** Its arguments are `commit` and `rollback` alone (`RequestArguments` refuses
/// any other): the installer program, the builds folder, the scope runner and the home are the server's own
/// (`Requests.updateInstaller`, `installRoot`), set at its start, never a request's.
///
/// **What it leaves owed** (said in its reply's `owed`, in plain words): after the handover the command line's
/// `update` still settles on the new server, writes the follow-up (the unit's `ExecStart`, `current`) and seals the
/// unit's folder (`build.seal`). Those run while the server that took this request is being replaced, so the kind
/// doesn't do them: `vibeswitcher switch COMMIT` finishes the follow-up, `vibeswitcher approve` accepts the unit's
/// change. Slices 14 and 15 plan them as kinds of their own.
extension WireKinds {
    public enum Update: WireChangeKind {
        public static let kind = "update"
        public struct Args: WireArgs, Equatable {
            /// The build to update to (40 lowercase hex digits): always named, so what the user was shown is what runs.
            public var commit: String?
            /// `vibeswitcher rollback`'s: `commit` is the installs record's rollback target; nothing is installed.
            public var rollback: Bool?
            public enum CodingKeys: String, CodingKey, CaseIterable { case commit, rollback }
            public init(commit: String?, rollback: Bool? = nil) {
                self.commit = commit
                self.rollback = rollback
            }
        }
        /// The switch's outcome (`BuildSwitch.Result`'s), whether this request installed the build, and what is still
        /// owed after it, one plain line each.
        public struct Result: Codable, Sendable, Equatable {
            public var outcome: String?
            public var commit: String?
            @WireMaybe public var from: String?
            public var installed: Bool?
            public var said: String?
            public var sealed: [String]?
            public var held: [String]?
            public var sealRefusals: [String]?
            public var owed: [String]?
            public init(outcome: String, commit: String, installed: Bool, said: String) {
                self.outcome = outcome
                self.commit = commit
                self.installed = installed
                self.said = said
            }
        }
    }
}

/// The install step of an update, the command line's (`vibeswitcher update`) and the server's (`update`) alike: the
/// builds folder read before (and checked against the vault's look, `looked`), install-node opened as the listing lists
/// it and read into sealed memory (`SwitchSealCheck`), run in a scope of the user's systemd manager under `env -i`, the
/// folder read again after it and the top-level entries it changed judged (`SwitchSealCheck.installChange`). A failed
/// install leaves no new build folder behind.
public enum UpdateInstall {
    /// How long the install is waited for at most.
    public static let installWait: TimeInterval = 3 * 60 * 60
    /// The user's manager's runner of a transient scope.
    public static let systemdRun = "/usr/bin/systemd-run"

    /// What runs the install.
    public enum Installer: Sendable, Equatable {
        /// install-node of the build `own` (its folder, proved to be the running code's), with every check, under `scope`
        /// (`/usr/bin/systemd-run`, or a scratch node's stand-in for it).
        case script(own: String, scope: String)
        /// A scratch node's test: `PROGRAM COMMIT PREFIX`, none of the checks (`update --test-installer`).
        case test(program: String)
    }

    /// What an install left.
    public struct Done: Equatable, Sendable {
        /// The builds folder's listing lines before it, and its hash after.
        public var before: [String]
        public var after: String
        /// The top-level entries it changed beyond its own (empty: only the install's).
        public var others: [String]
        public var seconds: Int
        /// What the switch seals the builds folder by: only when nothing else changed.
        public var seen: SwitchSealCheck.InstallSeen? { others.isEmpty ? .init(beforeListing: before, after: after) : nil }
    }

    /// Why the builds folder isn't the accepted one now, or nil: held (`heldNames` names it), or changed since the vault's
    /// look (`looked`, the listing then). A script run from a folder nobody accepted may not be the one the user accepted.
    public static func buildsRefusal(heldNames: [String], looked: [String], now: [String]) -> StartRefusal? {
        guard !heldNames.contains(SwitchSeal.buildsName), now == looked else {
            return StartRefusal("update: the builds folder has a change you haven't accepted (`vibeswitcher config held`): nothing was asked or run, "
                                + "as its install script may not be the one you accepted")
        }
        return nil
    }

    /// The install of `commit` into `prefix` by `installer`, `home` the account's (install-node's `HOME`); `looked` the
    /// builds folder's listing at the vault's look (checked again right before the script is opened: nil for a test
    /// installer, which runs no script). `hold` marks the points a scratch node's test may hold at; `say` the lines a
    /// person reads.
    public static func run(commit: String, prefix: String, installer: Installer, looked: [String]?, home: String, scratch: Bool,
                           hold: (String) -> Void = { _ in }, say: (String) -> Void) -> Result<Done, StartRefusal> {
        let before = SwitchSeal.listingLines(prefix)
        if case .script = installer, before != looked {
            return .failure(StartRefusal("update: the builds folder changed while the code was asked: nothing was run or switched (`vibeswitcher config held`)"))
        }
        let folder = (prefix as NSString).appendingPathComponent(commit)
        let existed = FileManager.default.fileExists(atPath: folder)
        var script = "", scope = ""
        // The script opened as the listing just read lists it, and run through that descriptor (never its path again).
        var scriptFD: Int32 = -1
        var copy: Platform.ProcessSelf.SealedCopy?
        defer {
            if scriptFD >= 0 { Sys.close(scriptFD) }
            if let copy { Sys.close(copy.fd) }
        }
        switch installer {
        case .test(let program): script = program
        case .script(let own, let runner):
            scope = runner
            switch SwitchSealCheck.installScript(prefix: prefix, own: own) {
            case .failure(let refused): return .failure(refused)
            case .success(let path): script = path
            }
            hold("before-open")
            switch SwitchSealCheck.openScript(script, prefix: prefix, listing: before) {
            case .failure(let refused): return .failure(refused)
            case .success(let fd): scriptFD = fd
            }
            hold("after-open")
            // Its bytes, as listed, in sealed memory: what runs, whatever is written to the file from now on.
            switch SwitchSealCheck.sealedScript(scriptFD, script: script, prefix: prefix, listing: before) {
            case .failure(let refused): return .failure(refused)
            case .success(let made): copy = made
            }
            hold("after-copy")
        }
        let started = Platform.Clock.steadyDate()
        say("installing \(commit) (each step below is install-node's)…")
        let status = spawn(script: script, fd: scriptFD, copy: copy, scope: scope, test: { if case .test = installer { return true } else { return false } }(),
                           commit: commit, prefix: prefix, home: home, scratch: scratch, say: say)
        let took = Int(Platform.Clock.steadyDate().timeIntervalSince(started))
        guard status == 0 else {
            if !existed, FileManager.default.fileExists(atPath: folder) { try? FileManager.default.removeItem(atPath: folder) }
            return .failure(StartRefusal("update: the install of \(commit) failed (exit \(status), after \(took) s): nothing was switched"
                                         + (existed ? "" : "; the folder it made is removed")))
        }
        say("installed \(commit) in \(took / 60) min \(took % 60) s")
        let afterLines = SwitchSeal.listingLines(prefix)
        let others = SwitchSealCheck.installChange(before: SwitchSeal.entries(lines: before), after: SwitchSeal.entries(lines: afterLines), commit: commit)
        if !others.isEmpty {
            say("the builds folder changed beyond this install (" + others.joined(separator: "; ") + "): it stays held for `vibeswitcher config held`")
        }
        return .success(Done(before: before, after: SwitchSeal.listingHash(lines: afterLines), others: others, seconds: took))
    }

    /// install-node for `commit` in `prefix` (or a scratch node's stand-in, `test`), its output on this process's: its
    /// exit status (-1 when it couldn't be started or didn't end in `installWait`). install-node runs from `fd`, the
    /// script as opened and checked (`/dev/fd/N`: its path still resolves to the file, for its own checks), under
    /// `scope` (`systemd-run --user --scope`: a scope of its own in the user's manager), its environment emptied again
    /// inside.
    static func spawn(script: String, fd: Int32, copy: Platform.ProcessSelf.SealedCopy?, scope: String, test: Bool, commit: String, prefix: String,
                      home: String, scratch: Bool, say: (String) -> Void) -> Int32 {
        var spawn: Platform.Spawn
        if test {
            spawn = Platform.Spawn(executable: script, arguments: [script, commit, prefix])
        } else {
            // As its header says to run it: nothing of this process's environment shapes it. `--repo none`: no courtesy
            // check of a checkout (the commit is the node's check's), where the script takes it. A scratch node's
            // build's script: its prefix named. From the sealed copy with `--self` where the script takes it; else (an
            // older install-node) from the checked descriptor, said.
            let text = copy?.withBytes { String(decoding: $0, as: UTF8.self) } ?? ""
            let takesNone = text.contains("[[ $repo != none ]]")
            let sealed = copy.map { _ in text.contains(SwitchSealCheck.takesSelf) } ?? false
            if !sealed { say("this build's install-node runs from its checked file (it takes no --self): a write to it now would be read") }
            let runs = sealed ? (copy?.fd ?? fd) : fd
            let tail = (scratch ? ["--prefix", prefix] : (takesNone ? ["--repo", "none"] : [])) + (sealed ? ["--self", script] : [])
            let inner = ["/usr/bin/env", "-i", "HOME=\(home)", "PATH=/usr/bin:/bin", "/bin/bash", "/dev/fd/\(runs)", commit] + tail
            spawn = Platform.Spawn(executable: scope, arguments: SwitchSealCheck.scopeArguments(runner: scope, command: inner))
            // systemd-run's own: the manager's place, and nothing else of this process's.
            spawn.environment = ["XDG_RUNTIME_DIR=/run/user/\(getuid())", "PATH=/usr/bin:/bin"]
            spawn.keep = [runs]
        }
        // Nothing to read, and no terminal to control: a session of its own.
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.group = .ownSession
        guard case .success(let pid) = spawn.start() else { return -1 }
        let deadline = Platform.Clock.steadyDate().addingTimeInterval(installWait)
        var status: Int32 = 0
        while true {
            let ended = waitpid(pid, &status, WNOHANG)
            if ended == pid { break }
            if ended < 0, errno != EINTR { return -1 }
            if Platform.Clock.steadyDate() > deadline {
                kill(-pid, SIGTERM)  // its session's group: its id is its pid
                return -1
            }
            usleep(200_000)
        }
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
}

/// The `update` kind's plan and install, before the switch (`Requests.update` runs it off its queue, then the existing
/// `build.switch` act): every input the server's own, read on its queue (`running`, `blockers`, `rollbackTarget`) or
/// set at its start (`installRoot`, `installer`, `home`); the vault's look of the builds folder a call (`held`, blocking).
struct UpdateRequest {
    var installRoot: String
    var home: String
    var installer: UpdateInstall.Installer?
    /// The build the host runs (`HostNotes.build`), the sessions that refuse a switch now, the installs record's rollback
    /// target: as the server's queue read them.
    var running: String?
    var blockers: [String]
    var rollbackTarget: String?
    /// The builds folder held in the vault's look, or changed since it (`HeldChange`): why, or nil.
    var held: () -> StartRefusal?
    var say: (String) -> Void

    /// What the plan comes to.
    enum Plan: Equatable {
        /// The commit runs already: nothing installed or switched.
        case already(WireKinds.Update.Result)
        /// Switch now: `seen` what the install left of the builds folder (nil: nothing installed, or more than the install
        /// changed), `installed` whether this request installed it.
        case switchTo(commit: String, seen: SwitchSealCheck.InstallSeen?, installed: Bool)
        case refused(NodeWire.Code, String)
    }

    /// Why an update's arguments name no commit (40 lowercase hex digits), or nil.
    static func commitRefusal(_ args: WireKinds.Update.Args) -> NodeWire.Failure? {
        guard let commit = args.commit, NodeUnit.isCommit(commit) else { return .init(.badArgs, "update needs commit, 40 lowercase hex digits") }
        return nil
    }

    /// The plan for `args`, the install run when it is one. Blocking (the vault's look, install-node): off the server's
    /// queue.
    func plan(_ args: WireKinds.Update.Args) -> Plan {
        guard Self.commitRefusal(args) == nil, let commit = args.commit else {
            return .refused(.badArgs, "update needs commit, 40 lowercase hex digits")
        }
        if commit == running {
            return .already(.init(outcome: "already", commit: commit, installed: false, said: "\(commit) runs already: nothing to update"))
        }
        // The rule on switches first, as the command line asks it before any code: nothing is installed for a switch that
        // can't run.
        if !blockers.isEmpty {
            return .refused(.refused, "update can't run now: " + SwitchRequest.blockedText(blockers) + ". Nothing was installed or switched.")
        }
        if args.rollback == true {
            guard let rollbackTarget, rollbackTarget == commit else {
                return .refused(.refused, "update: \(commit.prefix(12)) isn't the build to roll back to ("
                                + (rollbackTarget.map { "the installs record names \($0.prefix(12))" } ?? "the installs record names none") + "): nothing was switched")
            }
            return .switchTo(commit: commit, seen: nil, installed: false)
        }
        guard let installer else {
            return .refused(.refused, "this server runs no install for update: `vibeswitcher update \(commit)` in a terminal installs and switches")
        }
        // The install runs only in a scope of its own in the user's manager (the command line's rule): no manager, no update.
        if case .script(_, let scope) = installer, scope == UpdateInstall.systemdRun, let why = SwitchSealCheck.userManagerRefusal(runner: scope) {
            return .refused(.refused, "update: the install runs only in a scope of its own, and \(why): nothing was installed or switched")
        }
        // The builds folder read before the vault's look and again after it, as the command line reads it: a change made
        // while the vault looked isn't the folder the vault vouched for.
        let looked = SwitchSeal.listingLines(installRoot)
        if let held = held() { return .refused(.refused, held.text) }
        if let refused = UpdateInstall.buildsRefusal(heldNames: [], looked: looked, now: SwitchSeal.listingLines(installRoot)) {
            return .refused(.refused, refused.text)
        }
        switch UpdateInstall.run(commit: commit, prefix: installRoot, installer: installer, looked: looked, home: home, scratch: false, say: say) {
        case .failure(let refused): return .refused(.refused, refused.text)
        case .success(let done): return .switchTo(commit: commit, seen: done.seen, installed: true)
        }
    }

    /// The update's result from the switch's, with what is still owed after a handover (the command line's follow-up and
    /// seal, which run while this server is replaced).
    static func result(_ switched: WireKinds.BuildSwitch.Result, installed: Bool) -> WireKinds.Update.Result {
        let commit = switched.commit ?? "?"
        var result = WireKinds.Update.Result(outcome: switched.outcome ?? "?", commit: commit, installed: installed, said: switched.said ?? "switched")
        result.from = switched.from
        result.sealed = switched.sealed
        result.held = switched.held
        result.sealRefusals = switched.sealRefusals
        if switched.outcome == "handed-over" { result.owed = owed(commit) }
        return result
    }

    /// What a handed-over update still owes, in plain words: the command line's steps after the handover.
    static func owed(_ commit: String) -> [String] {
        ["the node's start line and `current` still name the build before: `vibeswitcher switch \(commit)` in a terminal finishes that, "
            + "so the next start runs this build",
         "the start line's change and the new build wait for your accept: `vibeswitcher approve` in a terminal"]
    }
}

extension Requests {
    /// `update` with `commit` (and `rollback`): `UpdateRequest`'s plan and install off `queue`, then `build.switch`'s act
    /// under this request's id and action. On `queue`.
    func update(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let args: WireKinds.Update.Args
        switch request.typedArgs(WireKinds.Update.Args.self) {
        case .failure(let failure): return reply(.init(re: request.id, error: failure))
        case .success(let taken): args = taken
        }
        if let failure = UpdateRequest.commitRefusal(args) { return reply(.init(re: request.id, error: failure)) }
        guard let installRoot else {
            return reply(.init(re: request.id, error: .init(.refused, "this server has no install root to update in")))
        }
        let running = notes?.notes.build
        let (home, vault) = (self.home, link.vault)
        let plan = UpdateRequest(installRoot: installRoot, home: home, installer: updateInstaller, running: running, blockers: switchBlockersNow().blockers,
                                 rollbackTarget: running.flatMap { SwitchPlan.rollbackTarget(installs: SwitchRequest.installs(in: installRoot), running: $0)?.commit },
                                 held: { HeldChange.refusal([HooksRequest.buildsName], home: home, vault: vault, accept: SwitchRequest.acceptFirst) },
                                 say: note)
        let queue = self.queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let planned = plan.plan(args)
            queue.async {
                guard let self else { return }
                switch planned {
                case .already(let result): reply(.init(re: request.id, typed: result))
                case .refused(let code, let why): reply(.init(re: request.id, error: .init(code, why)))
                case .switchTo(let commit, let seen, let installed):
                    var switchArgs: [String: NodeWire.Value] = ["commit": .string(commit)]
                    if let seen {
                        switchArgs["buildsBeforeListing"] = .array(seen.beforeListing.map(NodeWire.Value.string))
                        switchArgs["buildsAfter"] = .string(seen.after)
                    }
                    let switching = NodeWire.Request(id: request.id, kind: WireKinds.BuildSwitch.kind, args: switchArgs, action: request.action)
                    self.buildSwitch(switching) { answer in
                        guard answer.ok, let value = answer.result, let switched = try? value.wire(WireKinds.BuildSwitch.Result.self) else {
                            return reply(answer)
                        }
                        reply(.init(re: request.id, typed: UpdateRequest.result(switched, installed: installed)))
                    }
                }
            }
        }
    }
}
