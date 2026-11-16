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
///    (`NodeUnit.text`) from what `start` writes it from (ST-D3, ST-D4): `accountHome` (`getpwuid`'s, never the
///    unit's HOME), and swiftly's and node's folders from `NodeFolders.toolFolders`, which takes only the unit's node
///    folder, and checks it. The unit's HOME and PATH are never written back: a worker's edit of them is undone, or
///    refused as `start` would refuse it (the review of S8a);
/// 4. `systemctl --user daemon-reload`;
/// 5. `<prefix>/current` is moved to the target: a relative link, made beside it and renamed over it, as the install
///    lays it out.
///
/// Nothing is written or called before 1 to 3's checks pass. The unit and `current` are in folders the seal watches, so
/// the next look holds every team until `vs config accept` (ST-D23); the confirmations say so.
///
/// Every failure comes after the host handed over, so the host runs the target while the unit or `current` still
/// name the old build. The way back each refusal names: `vs switch <target>` again. The server answers that it runs
/// already, and S8c then runs this follow-up again when `isDone` says the unit or `current` lag (the review of S8a).
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
    /// target and the host check out (the type's comment); `.success` once all of it is done. `accountHome` is the
    /// account's home from `getpwuid` (a test's scratch home).
    public static func apply(tools: NodeStarter.Tools, prefix: String, accountHome: String, commit: String, hostPid: pid_t,
                             hostCheck: () -> Result<Host, StartRefusal>) -> Result<Void, StartRefusal> {
        /// What each refusal past the handover says: the host runs the target, and how to finish.
        let again = "`vs switch \(commit)` again finishes this"
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
            return .failure(StartRefusal("the host couldn't be checked after the switch: \(refused.text); nothing was rewritten. `vs status` shows the host's build: once it is \(commit), \(again)", exitCode: refused.exitCode))
        case .success(let host): seen = host
        }
        let checkStatus = "nothing was rewritten. `vs status` shows the host: once it runs \(commit), \(again)"
        guard seen.pid == hostPid else {
            return .failure(StartRefusal("the host answering after the switch is pid \(seen.pid), not the one that handed over (pid \(hostPid)): \(checkStatus)", exitCode: 1))
        }
        guard let build = seen.build else {
            return .failure(StartRefusal("the host's notes name no build after the switch to \(commit): \(checkStatus)", exitCode: 1))
        }
        guard build == commit else {
            return .failure(StartRefusal("the host runs the build of \(ConfigSeal.inert(build, limit: 64)) after the switch, not \(commit): \(checkStatus)", exitCode: 1))
        }
        let runs = "the host runs \(commit) already"
        // 3. The unit, for the target.
        let starter = NodeStarter(tools: tools, listen: { .notYet })
        guard let unitText = try? String(contentsOfFile: starter.unitFile, encoding: .utf8) else {
            return .failure(StartRefusal("the unit \(ConfigSeal.inert(starter.unitFile, limit: .max)) can't be read: `vs start` writes it; nothing was rewritten, and \(runs)"))
        }
        let read: NodeUnit.Inputs
        switch NodeUnit.inputs(parsing: unitText, prefix: prefix) {
        case .failure(let refused):
            return .failure(StartRefusal("the unit \(ConfigSeal.inert(starter.unitFile, limit: .max)) isn't start's: \(refused.text); nothing was rewritten, and \(runs) (removing the unit lets `vs start` write it again)"))
        case .success(let parsed): read = parsed
        }
        // Only the node folder is taken from the unit, and checked; HOME and swiftly's folder are start's (ST-D4).
        let folders: (swiftBin: String, nodeBin: String)
        switch NodeFolders.toolFolders(accountHome: accountHome, nodeVersion: nil, existingUnit: read) {
        case .failure(let refused):
            return .failure(StartRefusal("the unit's folders aren't ones start writes: \(refused.text); nothing was rewritten, and \(runs): once they are, \(again)"))
        case .success(let found): folders = found
        }
        let inputs = NodeUnit.Inputs(prefix: prefix, commit: commit, home: accountHome, swiftBin: folders.swiftBin, nodeBin: folders.nodeBin)
        let text: String
        switch NodeUnit.text(inputs) {
        case .failure(let refused):
            return .failure(StartRefusal("\(refused.text); nothing was rewritten, and \(runs)", exitCode: refused.exitCode))
        case .success(let made): text = made
        }
        if let refused = starter.write(text) {
            return .failure(StartRefusal("\(refused.text); \(runs): \(again)", exitCode: refused.exitCode))
        }
        // 4. The manager reads it.
        if let refused = starter.ask(["--user", "daemon-reload"]).refusal {
            return .failure(StartRefusal("\(refused.text): the unit names \(commit) now, and the manager hasn't read it; `current` wasn't moved. `systemctl --user daemon-reload`, then \(again)", exitCode: 1))
        }
        // 5. current.
        if let refused = moveCurrent(prefix: prefix, to: commit) {
            return .failure(StartRefusal("\(refused.text); \(again)", exitCode: refused.exitCode))
        }
        return .success(())
    }

    /// Whether the follow-up to `commit` is done: the unit file, in start's form (`NodeUnit.inputs(parsing:prefix:)`),
    /// names `commit`, and `<prefix>/current` is a link naming it. S8c asks this when the server answers that the host
    /// runs `commit` already, and runs `apply` again when it isn't (a follow-up a failure left unfinished).
    public static func isDone(tools: NodeStarter.Tools, prefix: String, commit: String) -> Bool {
        let unitFile = NodeFolders.join(tools.unitFolder, NodeUnit.fileName)
        guard let unitText = try? String(contentsOfFile: unitFile, encoding: .utf8),
              case .success(let read) = NodeUnit.inputs(parsing: unitText, prefix: prefix), read.commit == commit else { return false }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: NodeFolders.join(prefix, currentLink))) == commit
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
