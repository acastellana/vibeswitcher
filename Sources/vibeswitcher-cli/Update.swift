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
/// 6. What still waits, in one line (`StatusCommand.waitingLine`), and what stays held.
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
    static let usage = "usage: vibeswitcher update [COMMIT] [--long]"

    static func run(_ arguments: [String]) -> Int32 {
        var named: String?
        var installer: String?
        var testBuild: String?
        var testScope: String?
        var testHold: String?
        var serverWait = SwitchSettle.serverWait
        var words = Say.takingLong(arguments)[...]
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
        // The install script this build's own, before anything is asked (`UpdateInstall.run` checks it again).
        if installer == nil {
            guard let own else { return Say.refused("update: a scratch node's update needs --test-installer or --test-build") }
            if case .failure(let refused) = SwitchSealCheck.installScript(prefix: prefix, own: own) { return Say.refused(refused.text) }
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
        guard let held else { return Say.refused("update: the server couldn't say which changes wait for your accept: nothing was asked or run") }
        if installer == nil, let refused = UpdateInstall.buildsRefusal(heldNames: held, looked: looked, now: SwitchSeal.listingLines(prefix)) {
            return Say.refused(refused.text)
        }
        // Two lines; the whole of it with --long.
        let aheadBy = target == offered ? status.update?["aheadBy"]?.int : nil
        let what = NodeTexts.updateShort(from: running, to: target, aheadBy: aheadBy, rewrites: rewrites, held: held)
            + (Say.long ? "\n" + NodeTexts.update(from: running, to: target, aheadBy: aheadBy, rewrites: rewrites, held: held) : "")
        let action = UUID().uuidString.lowercased()
        let said = TypedWord.said(approval: client.approvalRule, action: action, what: what)
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }

        // The install (`UpdateInstall.run`, the server's `update` kind's too): the builds folder read around it, still as
        // the vault's look found it (the code took a while), install-node opened as listed, its bytes in sealed memory, run
        // in a scope of the user's manager; a failed install switches nothing and leaves no new folder.
        let how: UpdateInstall.Installer = installer.map { .test(program: $0) } ?? .script(own: own ?? "", scope: scope)
        let installed: UpdateInstall.Done
        switch UpdateInstall.run(commit: target, prefix: prefix, installer: how, looked: installer == nil ? looked : nil, home: accountHome,
                                 scratch: context.isScratch, hold: { hold(testHold, $0) }, say: { Say.out($0) }) {
        case .failure(let refused): return Say.refused(refused.text)
        case .success(let done): installed = done
        }
        let seen = installed.seen.map { ($0.beforeListing, $0.after) }

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
            sayAccepted(sealed: result.sealed, refusals: result.sealRefusals)
            Say.detail(ConfigSeal.inert(result.said ?? "switched", limit: 400))
            guard result.outcome == "handed-over" || result.outcome == "already" else {
                Say.err("vibeswitcher: the server's reply names no outcome: \(ConfigSeal.inert(result.outcome ?? "none", limit: 64))")
                return 1
            }
            handedOver = result.outcome == "handed-over"
        }
        if handedOver {
            // Whatever the wait ends with, the follow-up runs: it checks the host again and says what is owed.
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
            // The server that stays, asked as the follow-up asks the host (one on its way out is asked again).
            switch SwitchCommand.connectSettled(context) {
            case .failure(let failure):
                Say.out("the node's new start line isn't accepted yet (the server couldn't be asked: \(ConfigSeal.inert(failure.message, limit: 400))): `vibeswitcher approve`")
            case .success(let fresh):
                // An action of its own, naming the switch's (the code typed for this update covers it).
                let seal = WireKinds.BuildSeal.Args(commit: target, from: running, switchAction: action)
                switch fresh.change(WireKinds.BuildSeal.self, seal, action: UUID().uuidString.lowercased(), typed: typed, timeout: 60) {
                case .success(let result, _): sayAccepted(sealed: result.sealed, refusals: result.sealRefusals)
                case .refused(let reply): Say.out("the node's new start line isn't accepted yet (\(ConfigSeal.inert(reply.error?.message ?? "refused", limit: 400))): `vibeswitcher approve`")
                case .failure(let failure): Say.out("the node's new start line isn't accepted yet (\(ConfigSeal.inert(failure.message, limit: 400))): `vibeswitcher approve`")
                }
            }
        }
        Say.detail(SwitchCommand.startLine(context, commit: target, hostPid: hostPid))
        // Updated, the page's address, and what still waits (each kind with its command), from the server that stays.
        Say.out("updated to build \(ConfigSeal.inert(String(target.prefix(12)), limit: 64))")
        if case .success(let fresh) = NodeClient.connect(context), case .success(let now, _) = fresh.read(WireKinds.Status.self, WireNoArgs()) {
            Say.out(StatusCommand.shortWebLine(now.web, tailnet: now.webTailnet))
            Say.out(StatusCommand.waitingLine(now.cards) ?? "nothing else waits on you")
            for notice in (now.notices ?? []) where notice.hasPrefix("the hooks are out of date") { Say.out(ConfigSeal.inert(notice, limit: 600)) }
        }
        return 0
    }

    /// What this code accepted (with `--long`), and why something wasn't (always), each a line.
    static func sayAccepted(sealed: [String]?, refusals: [String]?) {
        (sealed ?? []).forEach { Say.detail("accepted with this code: \(ConfigSeal.inert($0, limit: 200))") }
        (refusals ?? []).forEach { Say.out(ConfigSeal.inert($0, limit: 400)) }
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
}
