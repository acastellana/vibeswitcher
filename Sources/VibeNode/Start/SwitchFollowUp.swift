import Foundation
import VibeCore

/// What the command line does on the user's node once the server says the host handed over to another build (the start
/// plan's S8a; ST-D3: "a successful switch or rollback rewrites `ExecStart` and moves `current` to the target"), so the
/// next `start` (after a crash, say) starts the build that runs now. In this order, each refusal naming what failed:
///
/// 1. the target is a commit (40 lowercase hex digits) whose folder is a direct child of the prefix (by `realpath`),
///    its `bin` matching its `build-info` (`NodeFolders.verifyBuild`);
/// 2. `hostCheck` (the command line's: a fresh connection, `ServerCheck`, the welcome's pid and `HostNotes.build`)
///    reports the host that handed over: its pid still `hostPid`, its build the target;
/// 3. the unit is read back in start's form (`NodeUnit.inputs(parsing:prefix:)`) and written whole for the target
///    (`NodeUnit.text`): only `ExecStart` changes, every other line restored as start writes it;
/// 4. `systemctl --user daemon-reload`;
/// 5. `<prefix>/current` is moved to the target: a relative link, made beside it and renamed over it, as the install
///    lays it out.
///
/// Nothing is written or called before 1 to 3's checks pass. The unit and `current` are in folders the seal watches, so
/// the next look holds every team until `vs config accept` (ST-D23); the confirmations say so.
///
/// The plan's `unitFolder:systemctl:` are `NodeStarter.Tools` (the systemctl's environment needs the runtime folder
/// too), and the pid the host had before the switch is `hostPid:`, so `hostCheck` reports what it saw and the follow-up
/// judges it (2026-11-16).
public enum SwitchFollowUp {
    /// What `hostCheck` saw of the host through a freshly checked server: its pid (the welcome's) and the build its
    /// notes name (`HostNotes.build`, S5; nil when they name none).
    public struct Host: Equatable, Sendable {
        public var pid: pid_t
        public var build: String?

        public init(pid: pid_t, build: String?) {
            self.pid = pid
            self.build = build
        }
    }

    /// The name of the link to the build `vs` runs, in the prefix.
    public static let currentLink = "current"

    /// Rewrites the unit in `tools.unitFolder` for `commit`, reloads the manager and moves `<prefix>/current`, once the
    /// target and the host check out (the type's comment); `.success` once all of it is done.
    public static func apply(tools: NodeStarter.Tools, prefix: String, commit: String, hostPid: pid_t,
                             hostCheck: () -> Result<Host, StartRefusal>) -> Result<Void, StartRefusal> {
        // 1. The target.
        guard NodeUnit.isCommit(commit) else {
            return .failure(StartRefusal("the switch's target \(ConfigSeal.inert(commit, limit: 64)) isn't a commit (40 hex digits): nothing was rewritten"))
        }
        if case .failure(let refused) = NodeFolders.verifyBuild(folder: NodeFolders.join(prefix, commit), prefix: prefix) {
            return .failure(StartRefusal("the switch's target isn't an installed build: \(refused.text); nothing was rewritten"))
        }
        // 2. The host that handed over.
        let seen: Host
        switch hostCheck() {
        case .failure(let refused):
            return .failure(StartRefusal("the host couldn't be checked after the switch: \(refused.text); nothing was rewritten", exitCode: refused.exitCode))
        case .success(let host): seen = host
        }
        guard seen.pid == hostPid else {
            return .failure(StartRefusal("the host answering after the switch is pid \(seen.pid), not the one that handed over (pid \(hostPid)): nothing was rewritten", exitCode: 1))
        }
        guard let build = seen.build else {
            return .failure(StartRefusal("the host's notes name no build after the switch to \(commit): nothing was rewritten", exitCode: 1))
        }
        guard build == commit else {
            return .failure(StartRefusal("the host runs the build of \(ConfigSeal.inert(build, limit: 64)) after the switch, not \(commit): nothing was rewritten", exitCode: 1))
        }
        // 3. The unit, for the target.
        let starter = NodeStarter(tools: tools, listen: { .notYet })
        guard let unitText = try? String(contentsOfFile: starter.unitFile, encoding: .utf8) else {
            return .failure(StartRefusal("the unit \(ConfigSeal.inert(starter.unitFile, limit: .max)) can't be read: `vs start` writes it; nothing was rewritten"))
        }
        var inputs: NodeUnit.Inputs
        switch NodeUnit.inputs(parsing: unitText, prefix: prefix) {
        case .failure(let refused):
            return .failure(StartRefusal("the unit \(ConfigSeal.inert(starter.unitFile, limit: .max)) isn't start's: \(refused.text); nothing was rewritten (removing it lets `vs start` write it again)"))
        case .success(let read): inputs = read
        }
        inputs.commit = commit
        let text: String
        switch NodeUnit.text(inputs) {
        case .failure(let refused): return .failure(refused)
        case .success(let made): text = made
        }
        if let refused = starter.write(text) { return .failure(refused) }
        // 4. The manager reads it.
        if let refused = starter.ask(["--user", "daemon-reload"]).refusal {
            return .failure(StartRefusal("\(refused.text): the unit names \(commit) now, and the manager hasn't read it; `current` wasn't moved (`systemctl --user daemon-reload`, then switch again)", exitCode: 1))
        }
        // 5. current.
        if let refused = moveCurrent(prefix: prefix, to: commit) { return .failure(refused) }
        return .success(())
    }

    /// Points `<prefix>/current` at `commit` (a relative link): made as a temporary beside it, then renamed over it, so
    /// `current` always names one build. nil, or why not.
    static func moveCurrent(prefix: String, to commit: String) -> StartRefusal? {
        let current = NodeFolders.join(prefix, currentLink)
        let temporary = NodeFolders.join(prefix, ".\(currentLink).\(getpid()).\(UUID().uuidString.prefix(8)).tmp")
        guard symlink(commit, temporary) == 0 else {
            return StartRefusal("\(ConfigSeal.inert(current, limit: .max)) can't be moved to \(commit) (\(String(cString: strerror(errno)))): the unit names \(commit) and the manager has read it", exitCode: 1)
        }
        guard rename(temporary, current) == 0 else {
            let failed = errno
            unlink(temporary)
            return StartRefusal("\(ConfigSeal.inert(current, limit: .max)) can't be moved to \(commit) (\(String(cString: strerror(failed)))): the unit names \(commit) and the manager has read it", exitCode: 1)
        }
        return nil
    }
}
