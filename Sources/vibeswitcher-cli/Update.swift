import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher update [COMMIT]` (2026-11-24, the lead's ask after the user's first switch took some ten commands):
/// one command and one code from the user's terminal for what took an install, two accepts and a switch.
///
/// 1. The target: COMMIT, or the newer build the node's own check names (both CI runs passed). None known: said, with
///    the check's command. The command line must run from an installed build on the user's node (as `switch`).
/// 2. What refuses a switch now (a live worker or verifier) refuses it before anything is asked.
/// 3. The confirmation (`NodeTexts.update`): from and to, how far, what it runs, what its code accepts beside the
///    switch (the builds folder as this install leaves it, the unit's `ExecStart` naming the target) and what stays
///    held; then ONE typed code.
/// 4. The install: `<prefix>/current/Resources/install-node.sh COMMIT` under `env -i HOME=… PATH=/usr/bin:/bin`, as its
///    header says to run it, its output on this terminal. The builds folder's listing is read before and after it
///    (`SwitchSeal`): the top-level entries it changed must be the install's alone (`SwitchSealCheck.installChange`). A
///    failed install switches nothing, and a build folder it left that wasn't there before is removed.
/// 5. `build.switch` with the code and both listing hashes: the server seals the builds folder first when its checks
///    pass (`SwitchSealCheck`, a). Then what `switch` does after a handover: the server that stays and a paired page's
///    listener waited for (`SwitchSettle`), the follow-up (the unit and `current`), and, on a node under systemd,
///    `build.seal` with the same action and code: the unit folder sealed when only its unit's `ExecStart` moved (b).
/// 6. What still waits, in one line (`CardText.waitingLine`), and what stays held.
///
/// A scratch node takes `--test-installer PROGRAM` in place of install-node (run as `PROGRAM COMMIT PREFIX`): a test's
/// stand-in that lays a build out; the user's node refuses it.
enum UpdateCommand {
    static let usage = "usage: vibeswitcher update [COMMIT]"

    /// How long the install is waited for at most.
    static let installWait: TimeInterval = 3 * 60 * 60

    static func run(_ arguments: [String]) -> Int32 {
        var named: String?
        var installer: String?
        var words = arguments[...]
        while let word = words.popFirst() {
            if word == "--test-installer", let program = words.popFirst() { installer = program; continue }
            guard named == nil, NodeUnit.isCommit(word) else { return Say.usage(usage) }
            named = word
        }
        let context = NodeContext.current()
        context.sayScratch()
        if installer != nil, !context.isScratch { return Say.refused("update: --test-installer is a scratch node's test flag") }
        let accountHome = VibePaths.accountHome
        if !context.isScratch, !Platform.CodeIdentity.isAvailable,
           case .failure(let refused) = NodeFolders.installedBuild(executable: "/proc/self/exe", prefix: NodeFolders.defaultPrefix(accountHome: accountHome)) {
            return Say.refused("update: \(refused.text)")
        }
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let status: WireKinds.Status.Result
        switch client.read(WireKinds.Status.self, WireNoArgs()) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, _): status = result
        }
        guard let running = status.host?.notes?.build, NodeUnit.isCommit(running) else {
            return Say.refused("update: the host's notes name no build it runs: `vibeswitcher status` says what runs")
        }
        let offered = status.update?["commit"]?.string
        guard let target = named ?? offered else {
            return Say.refused("update: no newer build is known: `vibeswitcher status --check-updates` asks GitHub for one")
        }
        if target == running { Say.out("\(target) runs already: nothing to update"); return 0 }
        let rewrites = SwitchCommand.rewrites(context)
        let prefix: String
        if context.isScratch || Platform.CodeIdentity.isAvailable {
            guard let root = status.builds?.installRoot else { return Say.refused("update: the server names no install root") }
            prefix = root
        } else {
            prefix = NodeFolders.defaultPrefix(accountHome: accountHome)
        }
        let blockers = (status.switchBlockers ?? []).map { ConfigSeal.inert($0, limit: 120) }
        if !blockers.isEmpty {
            return Say.refused("update can't run now: " + SwitchRequest.blockedText(blockers) + ". Nothing was asked, installed or switched.")
        }
        let script = (prefix as NSString).appendingPathComponent("current/Resources/install-node.sh")
        if installer == nil, !FileManager.default.isExecutableFile(atPath: script) {
            return Say.refused("update: \(ConfigSeal.inert(script, limit: .max)) isn't there to install with: install the first build by hand (`install-node.sh COMMIT`)")
        }
        // What stays held: the home's held config, as `config held` shows it.
        let home = context.isScratch ? VibePaths.home : accountHome
        var held: [String] = []
        if case .success(let result, _) = client.read(WireKinds.ConfigHeld.self, .init(folder: home, diff: nil), timeout: 60) {
            held = (result.card?["config"]?["items"]?.array ?? []).compactMap { $0["name"]?.string }
        }
        let what = NodeTexts.update(from: running, to: target, aheadBy: target == offered ? status.update?["aheadBy"]?.int : nil,
                                    rewrites: rewrites, held: held)
        let action = UUID().uuidString.lowercased()
        let said = TypedWord.said(approval: client.approvalRule, action: action, what: what)
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }

        // The install, the builds folder read around it.
        let before = SwitchSeal.listingHash(prefix)
        let entriesBefore = SwitchSeal.entries(listing: prefix)
        let folder = (prefix as NSString).appendingPathComponent(target)
        let existed = FileManager.default.fileExists(atPath: folder)
        let started = Platform.Clock.steadyDate()
        Say.out("installing \(target) (each step below is install-node's)…")
        let installed = install(script: installer ?? script, test: installer != nil, commit: target, prefix: prefix, home: accountHome)
        let took = Int(Platform.Clock.steadyDate().timeIntervalSince(started))
        guard installed == 0 else {
            if !existed, FileManager.default.fileExists(atPath: folder) { try? FileManager.default.removeItem(atPath: folder) }
            return Say.refused("update: the install of \(target) failed (exit \(installed), after \(took) s): nothing was switched"
                               + (existed ? "" : "; the folder it made is removed"))
        }
        Say.out("installed \(target) in \(took / 60) min \(took % 60) s")
        let after = SwitchSeal.listingHash(prefix)
        let others = SwitchSealCheck.installChange(before: entriesBefore, after: SwitchSeal.entries(listing: prefix), commit: target)
        if !others.isEmpty {
            Say.out("the builds folder changed beyond this install (" + others.joined(separator: "; ") + "): it stays held for `vibeswitcher config held`")
        }
        let seen = others.isEmpty ? (before, after) : nil

        // The switch, the builds folder sealed first by the server when its checks pass.
        let hostPid = status.host?.pid.map { pid_t($0) }
        let serverBefore = client.hello.server
        let webBefore = SwitchSettle.Web(status.web)
        let args = WireKinds.BuildSwitch.Args(commit: target, buildsBefore: seen?.0, buildsAfter: seen?.1)
        let handedOver: Bool
        switch client.change(WireKinds.BuildSwitch.self, args, action: action, typed: typed, timeout: SwitchRequest.longestWait + 30) {
        case .failure(let failure):
            switch SwitchFollowUp.afterLostReply(failure.message, commit: target, hostPid: hostPid, hostCheck: { SwitchCommand.hostCheck(context) }) {
            case .failure(let refused):
                Say.err("vibeswitcher: \(ConfigSeal.inert(refused.text, limit: .max))")
                return refused.exitCode
            case .success:
                client.journal(WireKinds.BuildSwitch.kind, action: action, typed: typed)
                Say.out("the switch's reply was lost, but the host runs \(target) now, its pid unchanged: handed over")
                handedOver = true
            }
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, _):
            for line in sealLines(sealed: result.sealed, refusals: result.sealRefusals) { Say.out(line) }
            Say.out(ConfigSeal.inert(result.said ?? "switched", limit: 400))
            guard result.outcome == "handed-over" || result.outcome == "already" else {
                Say.err("vibeswitcher: the server's reply names no outcome: \(ConfigSeal.inert(result.outcome ?? "none", limit: 64))")
                return 1
            }
            handedOver = result.outcome == "handed-over"
        }
        if handedOver {
            let due = SwitchSettle.serverDue(installRoot: prefix, running: serverBefore.commit, target: target)
            if let refused = SwitchCommand.settle(context, serverBefore: serverBefore, due: due, web: webBefore, target: target) {
                Say.err("vibeswitcher: \(ConfigSeal.inert(refused.text, limit: .max))")
                return refused.exitCode
            }
        }
        if let refused = SwitchCommand.followUp(context, prefix: prefix, accountHome: accountHome, commit: target, handedOver: handedOver, hostPid: hostPid) {
            Say.err("vibeswitcher: \(ConfigSeal.inert(refused.text, limit: .max))")
            return refused.exitCode
        }
        // The unit's ExecStart move, sealed with the same code, on a node whose follow-up writes the unit.
        if case .unitAndCurrent = rewrites {
            if case .success(let fresh) = NodeClient.connect(context) {
                let seal = WireKinds.BuildSeal.Args(commit: target, from: running, buildsBefore: seen?.0, buildsAfter: seen?.1)
                switch fresh.change(WireKinds.BuildSeal.self, seal, action: action, typed: typed, timeout: 60) {
                case .success(let result, _): sealLines(sealed: result.sealed, refusals: result.sealRefusals).forEach(Say.out)
                case .refused(let reply): Say.out("the unit's change stays held: \(ConfigSeal.inert(reply.error?.message ?? "refused", limit: 400))")
                case .failure(let failure): Say.out("the unit's change stays held: \(ConfigSeal.inert(failure.message, limit: 400))")
                }
            }
        }
        Say.out(SwitchCommand.startLine(context, commit: target, hostPid: hostPid))
        // What still waits, from the server that stays.
        if case .success(let fresh) = NodeClient.connect(context), case .success(let now, _) = fresh.read(WireKinds.Status.self, WireNoArgs()) {
            Say.out(CardText.waitingLine(now.cards) ?? "nothing else waits on you")
            for notice in (now.notices ?? []) where notice.hasPrefix("the hooks are out of date") { Say.out(ConfigSeal.inert(notice, limit: 600)) }
        }
        return 0
    }

    /// What the server said of a seal: what it sealed, and why not, each a line.
    static func sealLines(sealed: [String]?, refusals: [String]?) -> [String] {
        (sealed ?? []).map { "accepted with this code: \(ConfigSeal.inert($0, limit: 200))" } + (refusals ?? []).map { ConfigSeal.inert($0, limit: 400) }
    }

    /// install-node for `commit` in `prefix` (or a scratch node's stand-in, `test`), its output on this terminal: its
    /// exit status (-1 when it couldn't be started or didn't end in `installWait`).
    static func install(script: String, test: Bool, commit: String, prefix: String, home: String) -> Int32 {
        var spawn: Platform.Spawn
        if test {
            spawn = Platform.Spawn(executable: script, arguments: [script, commit, prefix])
        } else {
            // As its header says to run it: nothing of this shell's environment shapes it.
            // `--repo none`: no courtesy check of a checkout (the commit is the node's check's), where the script takes it
            // (a build's script before it wants to run inside a clean checkout: this terminal's folder, then).
            let takesNone = (try? String(contentsOfFile: script, encoding: .utf8))?.contains("[[ $repo != none ]]") == true
            spawn = Platform.Spawn(executable: "/usr/bin/env",
                                   arguments: ["/usr/bin/env", "-i", "HOME=\(home)", "PATH=/usr/bin:/bin", "/bin/bash", script, commit] + (takesNone ? ["--repo", "none"] : []))
        }
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.group = .ownGroup
        guard case .success(let pid) = spawn.start() else { return -1 }
        let deadline = Platform.Clock.steadyDate().addingTimeInterval(installWait)
        var status: Int32 = 0
        while true {
            let ended = waitpid(pid, &status, WNOHANG)
            if ended == pid { break }
            if ended < 0, errno != EINTR { return -1 }
            if Platform.Clock.steadyDate() > deadline {
                kill(-pid, SIGTERM)
                return -1
            }
            usleep(200_000)
        }
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
}
