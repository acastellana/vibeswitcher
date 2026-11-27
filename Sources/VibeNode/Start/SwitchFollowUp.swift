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
        if let refused = check(prefix: prefix, commit: commit, hostPid: hostPid, hostCheck: hostCheck) { return .failure(refused) }
        let again = again(commit)
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

    /// What each refusal past the handover says: the host runs the target, and how to finish.
    static func again(_ commit: String) -> String { "`vs switch \(commit)` again finishes this" }

    /// Steps 1 and 2 (the type's comment), which `apply` and `applyDetached` run before anything is written, called or
    /// moved: the target an installed build in the prefix, and the host that handed over on it. nil when both pass.
    static func check(prefix: String, commit: String, hostPid: pid_t, hostCheck: () -> Result<Host, StartRefusal>) -> StartRefusal? {
        let again = again(commit)
        // 1. The target.
        guard NodeUnit.isCommit(commit) else {
            return StartRefusal("the switch's target \(ConfigSeal.inert(commit, limit: 64)) isn't a commit (40 hex digits): nothing was rewritten")
        }
        if case .failure(let refused) = NodeFolders.verifyBuild(folder: NodeFolders.join(prefix, commit), prefix: prefix) {
            return StartRefusal("the switch's target isn't an installed build: \(refused.text); nothing was rewritten")
        }
        // 2. The host that handed over.
        let seen: Host
        switch hostCheck() {
        case .failure(let refused):
            return StartRefusal("the host couldn't be checked after the switch: \(refused.text); nothing was rewritten. `vs status` shows the host's build: once it is \(commit), \(again)", exitCode: refused.exitCode)
        case .success(let host): seen = host
        }
        let checkStatus = "nothing was rewritten. `vs status` shows the host: once it runs \(commit), \(again)"
        guard seen.pid == hostPid else {
            return StartRefusal("the host answering after the switch is pid \(seen.pid), not the one that handed over (pid \(hostPid)): \(checkStatus)", exitCode: 1)
        }
        guard let build = seen.build else {
            return StartRefusal("the host's notes name no build after the switch to \(commit): \(checkStatus)", exitCode: 1)
        }
        guard build == commit else {
            return StartRefusal("the host runs the build of \(ConfigSeal.inert(build, limit: 64)) after the switch, not \(commit): \(checkStatus)", exitCode: 1)
        }
        return nil
    }

    /// Whether the follow-up to `commit` is done: the unit file, in start's form (`NodeUnit.inputs(parsing:prefix:)`),
    /// names `commit`, and `<prefix>/current` is a link naming it. S8c asks this when the server answers that the host
    /// runs `commit` already, and runs `apply` again when it isn't (a follow-up a failure left unfinished).
    public static func isDone(tools: NodeStarter.Tools, prefix: String, commit: String) -> Bool {
        let unitFile = NodeFolders.join(tools.unitFolder, NodeUnit.fileName)
        guard let unitText = try? String(contentsOfFile: unitFile, encoding: .utf8),
              case .success(let read) = NodeUnit.inputs(parsing: unitText, prefix: prefix), read.commit == commit else { return false }
        return isCurrent(prefix: prefix, commit: commit)
    }

    /// Whether `<prefix>/current` is a link naming `commit`.
    public static func isCurrent(prefix: String, commit: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: NodeFolders.join(prefix, currentLink))) == commit
    }

    /// The follow-up on a node started detached (no systemd, ST-D6; S8c, 2026-11-16): there is no unit, and its `start`
    /// starts the build `vs` runs from (`current/bin/vibeswitcher`), so after the same checks as `apply` (1 and 2) only
    /// `current` is moved (5). Nothing is called. Its way back is `apply`'s: the server answers that the host runs the
    /// target already, and the command line runs this again while `isCurrent` says no.
    public static func applyDetached(prefix: String, commit: String, hostPid: pid_t,
                                     hostCheck: () -> Result<Host, StartRefusal>) -> Result<Void, StartRefusal> {
        if let refused = check(prefix: prefix, commit: commit, hostPid: hostPid, hostCheck: hostCheck) { return .failure(refused) }
        if let refused = moveCurrent(prefix: prefix, to: commit, unit: false) {
            return .failure(StartRefusal("\(refused.text); the host runs \(commit) already: \(again(commit))", exitCode: refused.exitCode))
        }
        return .success(())
    }

    // MARK: Before the code, and a reply lost (the review of S8c, 2026-11-16)

    /// The switch's target checked before the code is asked: a commit whose folder in `prefix` is an installed build
    /// (`NodeFolders.verifyBuild`: its `bin/` holds exactly the files its `build-info` records, each with the recorded
    /// hash). The host checks only its own and its server's images against `build-info` at the handover, so a tool
    /// server or command line a worker rewrote is refused here, with nothing switched. A worker that rewrites
    /// `build-info` with them passes (the security document's S9, "Doesn't promise"). nil when it is one.
    public static func targetRefusal(prefix: String, commit: String) -> StartRefusal? {
        guard NodeUnit.isCommit(commit) else {
            return StartRefusal("the switch's target \(ConfigSeal.inert(commit, limit: 64)) isn't a commit (40 hex digits): nothing was switched")
        }
        if case .failure(let refused) = NodeFolders.verifyBuild(folder: NodeFolders.join(prefix, commit), prefix: prefix) {
            return StartRefusal("the switch's target isn't an installed build: \(refused.text); nothing was switched")
        }
        return nil
    }

    /// The host before a switch whose follow-up checks it (on a node under systemd or started detached): `pid` and
    /// `build` as `status` named them, or, when it named no pid (the server's link to its host isn't welcomed yet, as
    /// after a server restart), what `hostCheck` sees once it names one. Without it the follow-up would refuse after
    /// the handover, leaving the host on the target and the unit and `current` on the old build, so the switch is
    /// refused before the code instead, with nothing switched.
    public static func hostBefore(pid: pid_t?, build: String?, hostCheck: () -> Result<Host, StartRefusal>) -> Result<Host, StartRefusal> {
        if let pid { return .success(Host(pid: pid, build: build)) }
        switch hostCheck() {
        case .success(let host): return .success(host)
        case .failure(let refused):
            return .failure(StartRefusal("the host's pid isn't known (\(refused.text)), so the switch's follow-up couldn't check the host: nothing was switched; try again once `vs status` names the host's pid",
                                         exitCode: refused.exitCode))
        }
    }

    /// `build.switch`'s reply lost (`lost`: the connection closed, or no answer in time), which may come after the
    /// host handed over: the server a switch replaces may end before it replies (`ServerChild.replaceWhenIdle`). The
    /// host as `hostCheck` sees it decides: its pid still `hostPid` (when known) and on `commit` is handed over, and
    /// the follow-up runs. Anything else, or no answer, is a refusal saying the host may have switched, and how to
    /// finish (`vs switch <commit>` again: the server then answers that it runs already, and the follow-up runs).
    public static func afterLostReply(_ lost: String, commit: String, hostPid: pid_t?,
                                      hostCheck: () -> Result<Host, StartRefusal>) -> Result<Host, StartRefusal> {
        let mayHave = "\(ConfigSeal.inert(lost, limit: 400)); the host may have switched: `vs status` shows its build; \(again(commit))"
        switch hostCheck() {
        case .failure(let refused):
            return .failure(StartRefusal("\(mayHave) (the host couldn't be checked: \(refused.text))", exitCode: 1))
        case .success(let host):
            guard host.build == commit, hostPid.map({ $0 == host.pid }) ?? true else {
                return .failure(StartRefusal("\(mayHave) (the host now: pid \(host.pid), build \(host.build.map { ConfigSeal.inert($0, limit: 64) } ?? "none named"))", exitCode: 1))
            }
            return .success(host)
        }
    }

    /// Points `<prefix>/current` at `commit` (a relative link): made as a temporary beside it, then renamed over it, so
    /// `current` always names one build. nil, or why not.
    /// `unit`: whether a unit was rewritten and reloaded first (`apply`), which the refusal says.
    static func moveCurrent(prefix: String, to commit: String, unit: Bool = true) -> StartRefusal? {
        let done = unit ? ": the unit names \(commit) and the manager has read it" : ""
        let current = NodeFolders.join(prefix, currentLink)
        // Naming the target already (an `update`'s install moved it): left as it is, so the builds folder the update
        // sealed isn't changed after its seal (`SwitchSealCheck`, c; the real node, 2026-11-27).
        if let named = try? FileManager.default.destinationOfSymbolicLink(atPath: current), named == commit { return nil }
        let temporary = NodeFolders.join(prefix, ".\(currentLink).\(getpid()).\(UUID().uuidString.prefix(8)).tmp")
        guard symlink(commit, temporary) == 0 else {
            return StartRefusal("\(ConfigSeal.inert(current, limit: .max)) can't be moved to \(commit) (\(String(cString: strerror(errno))))\(done)", exitCode: 1)
        }
        guard rename(temporary, current) == 0 else {
            let failed = errno
            unlink(temporary)
            return StartRefusal("\(ConfigSeal.inert(current, limit: .max)) can't be moved to \(commit) (\(String(cString: strerror(failed))))\(done)", exitCode: 1)
        }
        return nil
    }
}
