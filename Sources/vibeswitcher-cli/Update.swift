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
/// 4. The install: the install-node of the build this command line runs from, proved by its own image, which `current`
///    must name, run only while the builds folder is the accepted one (nothing of it held, unchanged since the vault's
///    look and while the code was asked: `SwitchSealCheck.installScript`), opened once and checked against the
///    listing's line for it (`openScript`), its bytes read once into sealed memory and the file checked again
///    (`sealedScript`), run from that copy with `--self` (`bash /dev/fd/N`; an older install-node, without `--self`,
///    from the checked descriptor), in a transient scope of the
///    user's systemd manager (`systemd-run --user --scope`: what it starts is never the user's voice; no manager, no
///    update), under `env -i HOME=… PATH=/usr/bin:/bin` as its header says, with no controlling terminal and stdin
///    /dev/null, its output on this terminal. The builds folder's listing is read before and after it
///    (`SwitchSeal`): the top-level entries it changed must be the install's alone (`SwitchSealCheck.installChange`). A
///    failed install switches nothing, and a build folder it left that wasn't there before is removed.
/// 5. `build.switch` with the code and both listing hashes: the server seals the builds folder first when its checks
///    pass (`SwitchSealCheck`, a). Then what `switch` does after a handover: the server that stays and a paired page's
///    listener waited for (`SwitchSettle`), the follow-up (the unit and `current`), and, on a node under systemd,
///    `build.seal` with the same action and code: the unit folder sealed when only its unit's `ExecStart` moved (b).
/// 6. What still waits, in one line (`CardText.waitingLine`), and what stays held.
///
/// A scratch node takes `--test-installer PROGRAM` in place of install-node (run as `PROGRAM COMMIT PREFIX`, none of the
/// checks of 4), or `--test-build FOLDER` for the build its command line "runs from" (every check of 4, its script run
/// with `--prefix`) with `--test-scope PROGRAM` standing in for systemd-run (a test never asks the user's manager), and
/// `--test-hold DIR` (`hold`); the user's node refuses each.
///
/// A new build's integrity rests on install-node verifying what it fetches (the commit by its hash, CI's runs, its own
/// bytes against the commit's blob): the layout check after it (`SwitchSealCheck.layoutRefusal`) compares the build
/// with its own `build-info`, so it says the folder is whole, not that it is the commit's.
enum UpdateCommand {
    static let usage = "usage: vibeswitcher update [COMMIT]"

    /// How long the install is waited for at most.
    static let installWait: TimeInterval = 3 * 60 * 60

    static func run(_ arguments: [String]) -> Int32 {
        var named: String?
        var installer: String?
        var testBuild: String?
        var testScope: String?
        var testHold: String?
        var serverWait = SwitchSettle.serverWait
        var words = arguments[...]
        while let word = words.popFirst() {
            if word == "--test-installer", let program = words.popFirst() { installer = program; continue }
            if word == "--test-build", let folder = words.popFirst() { testBuild = folder; continue }
            if word == "--test-scope", let program = words.popFirst() { testScope = program; continue }
            if word == "--test-hold", let folder = words.popFirst() { testHold = folder; continue }
            if word == "--test-server-wait", let text = words.popFirst(), let seconds = TimeInterval(text) { serverWait = seconds; continue }
            guard named == nil, NodeUnit.isCommit(word) else { return Say.usage(usage) }
            named = word
        }
        let context = NodeContext.current()
        context.sayScratch()
        if installer != nil || testBuild != nil || testScope != nil || testHold != nil || serverWait != SwitchSettle.serverWait, !context.isScratch {
            return Say.refused("update: --test-installer, --test-build, --test-scope and --test-hold are a scratch node's test flags")
        }
        // The install runs in a scope of the user's systemd manager, never this terminal's (a scratch node's test names
        // a stand-in for systemd-run): no manager, no update.
        let scope: String
        if let testScope {
            scope = testScope
        } else if installer == nil {
            if context.isScratch { return Say.refused("update: a scratch node's --test-build needs --test-scope (a test never asks the user's manager)") }
            if let why = SwitchSealCheck.userManagerRefusal() {
                return Say.refused("update: the install runs only in a scope of its own, and \(why): nothing was asked or run; install by hand (install-node.sh COMMIT, then vs switch COMMIT)")
            }
            scope = "/usr/bin/systemd-run"
        } else {
            scope = ""
        }
        let accountHome = VibePaths.accountHome
        // The build this command line runs from, proved by its own image (a scratch node's test names one): its
        // install-node is the one run (`SwitchSealCheck.installScript`).
        var own = testBuild
        if !context.isScratch, !Platform.CodeIdentity.isAvailable {
            switch NodeFolders.installedBuild(executable: "/proc/self/exe", prefix: NodeFolders.defaultPrefix(accountHome: accountHome)) {
            case .failure(let refused): return Say.refused("update: \(refused.text)")
            case .success(let build): own = build.folder
            }
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
        let offered = status.update?["commit"]?.string.flatMap { NodeUnit.isCommit($0) ? $0 : nil }
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
        var script = installer ?? ""
        if installer == nil {
            guard let own else { return Say.refused("update: a scratch node's update needs --test-installer or --test-build") }
            switch SwitchSealCheck.installScript(prefix: prefix, own: own) {
            case .failure(let refused): return Say.refused(refused.text)
            case .success(let path): script = path
            }
        }
        // What stays held: the home's held config, as `config held` shows it (the vault's look of now). The builds
        // folder must be the accepted one, nothing of it held, the same before and after that look: so the script run
        // below is the one the user accepted (its file's inode, size and times are in the folder's listing).
        let home = context.isScratch ? VibePaths.home : accountHome
        let looked = SwitchSeal.listingLines(prefix)
        var held: [String]?
        if case .success(let result, _) = client.read(WireKinds.ConfigHeld.self, .init(folder: home, diff: nil), timeout: 60) {
            held = (result.card?["config"]?["items"]?.array ?? []).compactMap { $0["name"]?.string }
        }
        guard let held else { return Say.refused("update: the server couldn't say what the seal holds: nothing was asked or run") }
        if installer == nil {
            guard !held.contains(SwitchSeal.buildsName), SwitchSeal.listingLines(prefix) == looked else {
                return Say.refused("update: the builds folder has a change you haven't accepted (`vibeswitcher config held`): nothing was asked or run, "
                                   + "as its install script may not be the one you accepted")
            }
        }
        let what = NodeTexts.update(from: running, to: target, aheadBy: target == offered ? status.update?["aheadBy"]?.int : nil,
                                    rewrites: rewrites, held: held)
        let action = UUID().uuidString.lowercased()
        let said = TypedWord.said(approval: client.approvalRule, action: action, what: what)
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }

        // The install, the builds folder read around it: still as the vault's look found it (the code took a while).
        let before = SwitchSeal.listingLines(prefix)
        if installer == nil, before != looked {
            return Say.refused("update: the builds folder changed while the code was asked: nothing was run or switched (`vibeswitcher config held`)")
        }
        let folder = (prefix as NSString).appendingPathComponent(target)
        let existed = FileManager.default.fileExists(atPath: folder)
        // The script opened as the listing just read lists it, and run through that descriptor (never its path again).
        var scriptFD: Int32 = -1
        if installer == nil {
            hold(testHold, "before-open")
            switch SwitchSealCheck.openScript(script, prefix: prefix, listing: before) {
            case .failure(let refused): return Say.refused(refused.text)
            case .success(let fd): scriptFD = fd
            }
            hold(testHold, "after-open")
        }
        defer { if scriptFD >= 0 { Sys.close(scriptFD) } }
        // Its bytes, as listed, in sealed memory: what runs, whatever is written to the file from now on.
        var copy: Platform.ProcessSelf.SealedCopy?
        if installer == nil {
            switch SwitchSealCheck.sealedScript(scriptFD, script: script, prefix: prefix, listing: before) {
            case .failure(let refused): return Say.refused(refused.text)
            case .success(let made): copy = made
            }
            hold(testHold, "after-copy")
        }
        defer { if let copy { Sys.close(copy.fd) } }
        let started = Platform.Clock.steadyDate()
        Say.out("installing \(target) (each step below is install-node's)…")
        let installed = install(script: script, fd: scriptFD, copy: copy, scope: scope, test: installer != nil, commit: target, prefix: prefix,
                                home: accountHome, scratch: context.isScratch)
        let took = Int(Platform.Clock.steadyDate().timeIntervalSince(started))
        guard installed == 0 else {
            if !existed, FileManager.default.fileExists(atPath: folder) { try? FileManager.default.removeItem(atPath: folder) }
            return Say.refused("update: the install of \(target) failed (exit \(installed), after \(took) s): nothing was switched"
                               + (existed ? "" : "; the folder it made is removed"))
        }
        Say.out("installed \(target) in \(took / 60) min \(took % 60) s")
        let afterLines = SwitchSeal.listingLines(prefix)
        let after = SwitchSeal.listingHash(lines: afterLines)
        let others = SwitchSealCheck.installChange(before: SwitchSeal.entries(lines: before), after: SwitchSeal.entries(lines: afterLines), commit: target)
        if !others.isEmpty {
            Say.out("the builds folder changed beyond this install (" + others.joined(separator: "; ") + "): it stays held for `vibeswitcher config held`")
        }
        let seen = others.isEmpty ? (before, after) : nil

        // The switch, the builds folder sealed first by the server when its checks pass.
        let hostPid = status.host?.pid.map { pid_t($0) }
        let serverBefore = client.hello.server
        let webBefore = SwitchSettle.Web(status.web)
        let args = WireKinds.BuildSwitch.Args(commit: target, buildsBeforeListing: seen?.0, buildsAfter: seen?.1)
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
            if let refused = SwitchCommand.settle(context, serverBefore: serverBefore, due: due, web: webBefore, target: target, serverWait: serverWait) {
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
                // An action of its own, naming the switch's (the code typed for this update covers it).
                let seal = WireKinds.BuildSeal.Args(commit: target, from: running, switchAction: action)
                switch fresh.change(WireKinds.BuildSeal.self, seal, action: UUID().uuidString.lowercased(), typed: typed, timeout: 60) {
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

    /// A scratch node's test hold (`--test-hold DIR`): `DIR/at-POINT` written, then `DIR/go-POINT` waited for (a minute at
    /// most). Nothing without one.
    static func hold(_ folder: String?, _ point: String) {
        guard let folder else { return }
        FileManager.default.createFile(atPath: (folder as NSString).appendingPathComponent("at-" + point), contents: nil)
        let go = (folder as NSString).appendingPathComponent("go-" + point)
        let deadline = Platform.Clock.steadyDate().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: go), Platform.Clock.steadyDate() < deadline { usleep(50_000) }
    }

    /// install-node for `commit` in `prefix` (or a scratch node's stand-in, `test`), its output on this terminal: its
    /// exit status (-1 when it couldn't be started or didn't end in `installWait`). install-node runs from `fd`, the
    /// script as opened and checked (`/dev/fd/N`: its path still resolves to the file, for its own checks), under
    /// `scope` (`systemd-run --user --scope`: a scope of its own in the user's manager), its environment emptied again
    /// inside.
    static func install(script: String, fd: Int32, copy: Platform.ProcessSelf.SealedCopy?, scope: String, test: Bool, commit: String, prefix: String,
                        home: String, scratch: Bool) -> Int32 {
        var spawn: Platform.Spawn
        if test {
            spawn = Platform.Spawn(executable: script, arguments: [script, commit, prefix])
        } else {
            // As its header says to run it: nothing of this shell's environment shapes it. `--repo none`: no courtesy
            // check of a checkout (the commit is the node's check's), where the script takes it (a build's script before it
            // wants to run inside a clean checkout: this terminal's folder, then). A scratch node's build's script: its
            // prefix named. From the sealed copy with `--self` where the script takes it; else (an older install-node)
            // from the checked descriptor, said.
            let text = copy?.withBytes { String(decoding: $0, as: UTF8.self) } ?? ""
            let takesNone = text.contains("[[ $repo != none ]]")
            let sealed = copy.map { _ in text.contains(SwitchSealCheck.takesSelf) } ?? false
            if !sealed { Say.out("this build's install-node runs from its checked file (it takes no --self): a write to it now would be read") }
            let runs = sealed ? (copy?.fd ?? fd) : fd
            let tail = (scratch ? ["--prefix", prefix] : (takesNone ? ["--repo", "none"] : [])) + (sealed ? ["--self", script] : [])
            let inner = ["/usr/bin/env", "-i", "HOME=\(home)", "PATH=/usr/bin:/bin", "/bin/bash", "/dev/fd/\(runs)", commit] + tail
            spawn = Platform.Spawn(executable: scope, arguments: SwitchSealCheck.scopeArguments(runner: scope, command: inner))
            // systemd-run's own: the manager's place, and nothing else of this shell's.
            spawn.environment = ["XDG_RUNTIME_DIR=/run/user/\(getuid())", "PATH=/usr/bin:/bin"]
            spawn.keep = [runs]
        }
        // Nothing to read from this terminal, and none to control: a session of its own.
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
