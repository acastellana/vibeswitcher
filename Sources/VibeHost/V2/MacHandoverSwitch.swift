import Foundation
import VibeCore

/// The host's half of the Mac's switch through a keeper (V2/MacHandoverKeeper.swift; the node on the Mac's design,
/// "The checked node start", "A switch").
extension HostServer {
    /// Whether this host's switch to `executable` goes through a keeper, and the code the target's file must be
    /// (`.success`), or why it is refused (`.failure`); nil: neither (Linux's, the Mac app's and every scratch host's
    /// switch, as before). A checked Mac node host's: the target a host the node's record pins (`HandoverTarget.macPinned`),
    /// its file's cdhash. A scratch host's test (`Config.testKeeperHost`): the target's file must have that cdhash.
    /// `pins` and `cdhashOf`: how the record and a file's cdhash are read (tests give them).
    func keeperTarget(_ executable: String, pins: @autoclosure () -> Result<NodePins, NodePins.Refused> = NodePins.read(),
                      cdhashOf: (String) -> Data? = { Platform.CodeIdentity.cdhash(atPath: $0) }) -> Result<Data, MacHandoverKeeper.Refused>? {
        guard Platform.CodeIdentity.isAvailable else { return nil }
        // A checked node host's, from its start on (not only once its server child is set: no window for the old exec).
        if config.checkedNode != nil {
            // The target's file read once: the cdhash the record is checked against is the one the keeper must run, never
            // a second read of a path a session can rename over (the blind check's item 1).
            var read: Data?
            let record = pins()
            if let why = HandoverTarget.macPinned(executable, pins: record, cdhashOf: { read = cdhashOf($0); return read }) {
                return .failure(MacHandoverKeeper.Refused(why.description))
            }
            guard let read, case .success(let pinned) = record, let row = pinned.build(host: read) else {
                return .failure(MacHandoverKeeper.Refused("\(executable) has no code signature to check it by"))
            }
            // Its build's server, by path, its row's (the review's N4): the new image's own start would find another
            // only after this image is gone, and the sessions with it.
            let folder = ((executable as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            let server = (folder as NSString).appendingPathComponent("bin/" + BuildInfo.server)
            guard cdhashOf(server) == row.server else {
                return .failure(MacHandoverKeeper.Refused("\(server) isn't the server the node's record pins for build \(row.commit)"))
            }
            return .success(read)
        }
        guard let pinned = config.testKeeperHost, config.checkedNode == nil else { return nil }
        guard Platform.CodeIdentity.cdhash(atPath: executable) == pinned else {
            return .failure(MacHandoverKeeper.Refused("\(executable) isn't the host this scratch host's test pins (\(NodePins.hex(pinned)))"))
        }
        return .success(pinned)
    }

    /// What the new image of a switch to `target` is started with, besides the handover's own flags: as this image was,
    /// and for a checked node, the target build's folders in place of this build's (`--node-root <folder>`, `--server
    /// <folder>/bin/vibeswitcher-server`, `target` being `<folder>/bin/vibeswitcher-host`), so its own checked start
    /// finds its row's server; a scratch host's as started.
    static func keeperArguments(started: [String], target: String, checkedNode: Bool) -> [String] {
        guard checkedNode else { return started }
        var kept: [String] = []
        var index = started.startIndex
        while index < started.endIndex {
            if [HostImages.nodeRootFlag, "--server"].contains(started[index]) { index += 2; continue }
            kept.append(started[index])
            index += 1
        }
        let folder = ((target as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return kept + [HostImages.nodeRootFlag, folder, "--server", (folder as NSString).appendingPathComponent("bin/" + BuildInfo.server)]
    }

    /// Hands over to `executable` through a keeper proven to run `expected` (`MacHandoverKeeper`): the keeper started
    /// and proven off the queue (the sessions carry on meanwhile); then, on the queue, the server child ended, the state
    /// built and parked with the keeper, and the exec with only the channel to it. Anything failing before the exec
    /// leaves this host as it was: the keeper ended, the server child started again, the parsers resumed.
    func handOverThroughKeeper(to executable: String, expected: Data, reply: @escaping (HostEvent) -> Void) {
        handingOver = true
        let fail: (Error) -> Void = { [weak self] error in
            self?.handingOver = false
            self?.log("handover to \(executable) failed: \(error)")
            reply(.error("Couldn't hand over: \(error)."))
        }
        // A scratch host's test: the target swapped after the path check (never a checked node's).
        if config.checkedNode == nil, let swap = config.testSwapAfterCheck { _ = rename(swap, executable) }
        log("handing over to \(executable) through a keeper")
        DispatchQueue.global().async { [weak self] in
            let started = MacHandoverKeeper.start(executable, expected: expected)
            self?.queue.async {
                guard let self else { return }
                let keeper: MacHandoverKeeper.Keeper
                switch started {
                case .failure(let why): return fail(why)
                case .success(let proven): keeper = proven
                }
                var secretFD: Int32?
                var parsersStopped = false
                var childEnded = false
                do {
                    if let why = self.serverChild?.handoverRefusal { throw MacHandoverKeeper.Refused(why) }
                    if let secrets = self.secretsForHandover?() { secretFD = try HostHandover.SecretChannel.make(secrets) }
                    self.serverChild?.endForHandover()
                    childEnded = true
                    self.sessions.values.forEach { $0.finishNow() }
                    let state = self.handoverState(secretFD: secretFD)
                    if let bad = state.descriptors.first(where: { !HostHandover.isOpen($0) }) { throw HostHandover.Failure.badDescriptor(bad) }
                    try MacHandoverKeeper.park(state, with: keeper).get()
                    // A scratch host's test: the target swapped after the keeper's proof, before the exec.
                    if self.config.checkedNode == nil, let swap = self.config.testSwapBeforeExec { _ = rename(swap, executable) }
                    reply(.ok)
                    self.sessions.values.forEach { $0.suspendParser() }
                    parsersStopped = true
                    // No fallback: going back would be an unchecked exec by path. The state is the keeper's.
                    // A checked node's next image takes no state file (its grammar has none): only the keeper's two.
                    let arguments = Self.keeperArguments(started: self.config.arguments, target: executable, checkedNode: self.config.checkedNode != nil)
                        + (self.config.checkedNode == nil ? ["--handover", self.config.handoverPath] : [])
                        + [MacHandoverKeeper.channelFlag, String(keeper.channel), MacHandoverKeeper.pidFlag, String(keeper.pid)]
                    throw HostHandover.exec(executable, arguments: arguments, inherit: [keeper.channel])
                } catch {
                    if parsersStopped { self.sessions.values.forEach { $0.resumeParser() } }
                    if let secretFD { Sys.close(secretFD) }
                    MacHandoverKeeper.abandon(keeper)
                    if childEnded { self.serverChild?.resumeAfterHandover() }
                    fail(error)
                    if case HostHandover.Failure.exec = error { self.clients.values.forEach { $0.close() } }
                }
            }
        }
    }
}
