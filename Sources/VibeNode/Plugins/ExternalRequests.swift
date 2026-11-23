import Foundation
import VibeCore

/// The server's requests on external plugins (the definition's "External plugins"): `plugin.inspect FOLDER` (the user's,
/// changing nothing: what `plugin add` shows), `plugin.add` (the user's voice, recorded first: the vault keeps the folder's
/// resolved path and the SHA-256 of its manifest and program, exactly those the user was shown), `plugin.remove` (the
/// user's voice: its cards withdrawn, its program stopped, its record gone), and `plugin.file` (an agent's `vs-ask`: the
/// plugin's `file` makes the payload from the words, the core wraps it; the session host stamps it in the filer, not
/// here). On the engine's queue.
extension Requests {
    private func refuse(_ request: NodeWire.Request, _ code: NodeWire.Code, _ why: String) -> NodeWire.Reply {
        .init(re: request.id, error: .init(code, ConfigSeal.inert(why, limit: 600)))
    }

    func pluginInspect(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(refuse(request, .refused, "this server keeps no plugins")) }
        guard let folder = request.args?["folder"]?.string, folder.hasPrefix("/") else { return reply(refuse(request, .badArgs, "plugin.inspect needs folder, an absolute path")) }
        let (builtIn, queue) = (engine.plugins.builtIn, self.queue)
        engine.pluginWork.async {
            let inspected = PluginFolder.inspect(folder, builtIn: builtIn)
            queue.async {
                switch inspected {
                case .failure(let why): reply(self.refuse(request, .refused, why.description))
                case .success(let found):
                    if engine.plugins.plugin(found.manifest.id) != nil {
                        return reply(self.refuse(request, .refused, "a plugin \(found.manifest.id) is in this node's list already (`vibeswitcher plugin remove \(found.manifest.id)` first)"))
                    }
                    reply(.init(re: request.id, result: Self.inspected(found)))
                }
            }
        }
    }

    static func inspected(_ found: PluginFolder) -> NodeWire.Value {
        let manifest = found.manifest
        return .object([
            "id": .string(manifest.id), "title": .string(manifest.title), "version": .string(manifest.version), "summary": .string(manifest.summary),
            "folder": .string(found.folder), "program": .string(found.program), "manifestSHA": .string(found.record.manifest),
            "programSHA": .string(found.record.program), "page": .bool(manifest.page == true),
            "commands": .array((manifest.commands ?? []).map { .string($0.name) }), "settings": .array((manifest.settings ?? []).map { .string($0.key) }),
            "life": .int(manifest.life ?? 1800),
        ])
    }

    func pluginAdd(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(refuse(request, .refused, "this server keeps no plugins")) }
        guard let folder = request.args?["folder"]?.string, let manifestSHA = request.args?["manifest"]?.string,
              let programSHA = request.args?["program"]?.string else { return reply(refuse(request, .badArgs, "plugin.add needs folder, manifest and program")) }
        let (builtIn, queue, client) = (engine.plugins.builtIn, self.queue, link.vaultV2)
        engine.pluginWork.async {
            // Read again: what is recorded is what was shown, or nothing is.
            let inspected = PluginFolder.inspect(folder, builtIn: builtIn)
            guard case .success(let found) = inspected else {
                if case .failure(let why) = inspected { queue.async { reply(self.refuse(request, .refused, why.description)) } }
                return
            }
            // The folder shown, as inspect resolved it: the same path, not one that resolves there now (L1).
            guard found.folder == folder else {
                return queue.async { reply(self.refuse(request, .refused, "the folder isn't the one shown (\(ConfigSeal.inert(found.folder, limit: 200))): nothing was added")) }
            }
            guard found.record.manifest == manifestSHA, found.record.program == programSHA else {
                return queue.async { reply(self.refuse(request, .refused, "the folder changed since it was shown (its manifest's or program's SHA-256 isn't the one you saw): nothing was added")) }
            }
            queue.async {
                guard engine.plugins.plugin(found.manifest.id) == nil else {
                    return reply(self.refuse(request, .refused, "a plugin \(found.manifest.id) is in this node's list already"))
                }
                engine.pluginWork.async {
                    let kept = Result { try client.setExternalPlugin(found.manifest.id, record: found.record.json) }
                    queue.async {
                        switch kept {
                        case .failure(let error): reply(self.refuse(request, .refused, "the session host's vault didn't keep it, so nothing was added: \(error)"))
                        case .success:
                            self.note("plugin \(found.manifest.id) added from \(found.folder) by the user (off until turned on)")
                            engine.askPlugins {
                                reply(.init(re: request.id, result: .object(["plugin": .string(found.manifest.id), "on": .bool(false)])))
                            }
                        }
                    }
                }
            }
        }
    }

    func pluginRemove(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(refuse(request, .refused, "this server keeps no plugins")) }
        guard let id = request.args?["plugin"]?.string else { return reply(refuse(request, .badArgs, "plugin.remove needs plugin")) }
        guard let plugin = engine.plugins.plugin(id) as? ExternalPlugin else {
            return reply(refuse(request, .gone, engine.plugins.builtIn.contains(id) ? "\(id) is built in: `vibeswitcher plugin off \(id)` turns it off"
                                                                                       : "no external plugin \(id) on this node"))
        }
        let open = engine.cards.list().filter { $0.plugin?.plugin == id }.count
        engine.withdraw(plugin)
        plugin.stop()
        let (client, queue, root) = (link.vaultV2, self.queue, engine.root)
        engine.pluginWork.async {
            let kept = Result { try client.setExternalPlugin(id, record: nil) }
            // Its folder (its data) goes with it, and its requests not yet settled: a program added back under its id
            // never sees them (the review of step C, L7). Only the node's own folders, never through a link (L4).
            for folder in ["plugins/\(id)", "plugin-requests/\(id)"] {
                if let why = PluginFolders.empty(root.appendingPathComponent(folder, isDirectory: true), andItself: true) {
                    self.note("plugin \(id) removed: \(why), so it was left as it is")
                }
            }
            queue.async {
                switch kept {
                case .failure(let error): reply(self.refuse(request, .refused, "the session host's vault didn't forget it: \(error)"))
                case .success:
                    self.note("plugin \(id) removed by the user")
                    engine.askPlugins { reply(.init(re: request.id, result: .object(["plugin": .string(id), "withdrawn": .int(open)]))) }
                }
            }
        }
    }

    /// An agent's `vs-ask`, through its tool server: the plugin on and external, the asking session one the user opened;
    /// the plugin's `file` makes the payload from the words; the core wraps it (its id, the session, its filing time and
    /// expiry, bounded by the plugin's declared life). The filer has the host stamp it. A page never files.
    func pluginFile(_ request: NodeWire.Request, from facts: PeerFacts, reply: @escaping (NodeWire.Reply) -> Void) {
        guard facts.pid != NodeLive.webPeer.pid else { return reply(refuse(request, .voice, "a page files nothing")) }
        guard let engine else { return reply(refuse(request, .refused, "this server keeps no plugins")) }
        guard let id = request.args?["plugin"]?.string, let session = request.args?["session"]?.string, UUID(uuidString: session) != nil,
              let words = request.args?["words"]?.array?.compactMap(\.string), let cwd = request.args?["cwd"]?.string,
              words.count <= 64, words.joined().utf8.count <= 16 * 1024, cwd.utf8.count <= 4096 else {
            return reply(refuse(request, .badArgs, "plugin.file needs plugin, session, words (64, 16 KiB at most) and cwd"))
        }
        guard let plugin = engine.plugins.plugin(id) as? ExternalPlugin, engine.plugins.isOn(id) else {
            return reply(refuse(request, .refused, "this node doesn't have \(id) on: nothing was filed"))
        }
        let desk = engine.desk(plugin)
        // The caller must run in that session, a live one the user opened, as the host lists it; whichever fails, the
        // same words, so nothing is learnt of which sessions are live (the review of step C, M3).
        let refusal = "only a live session the user opened files a request, from inside it"
        let pids = Set((facts.ancestry ?? []).map(\.pid))
        guard let caller = link.sessions.first(where: { $0.isLive && pids.contains($0.childPID) }),
              caller.id.uuidString.lowercased() == session.lowercased(), desk.opened(caller) else {
            return reply(refuse(request, .refused, refusal))
        }
        plugin.file(words: words, cwd: cwd, desk: desk) { made in
            switch made {
            case .failure(let why) where why.description.hasPrefix(ExternalPlugin.busy):
                reply(self.refuse(request, .refused, "\(plugin.info.title) is busy: \(ExternalPlugin.fileCallsAtMost) requests wait already; try again"))
            case .failure(let why): reply(self.refuse(request, .refused, "\(plugin.info.title) refused it: \(why)"))
            case .success(let filed):
                let now = Date()
                let life = min(filed.expiresIn, plugin.info.life)
                let envelope = PluginAskEnvelope(format: PluginAskEnvelope.format, id: UUID().uuidString.lowercased(), plugin: id,
                                                 session: session.lowercased(), createdAt: floor(now.timeIntervalSince1970),
                                                 expiresAt: floor(now.timeIntervalSince1970) + max(60, floor(life)), payload: filed.payload)
                guard let bytes = try? envelope.encoded() else { return reply(self.refuse(request, .internal, "the request didn't encode")) }
                reply(.init(re: request.id, result: .object(["id": .string(envelope.id), "request": .string(bytes.base64EncodedString()),
                                                             "title": .string(plugin.info.title)])))
            }
        }
    }
}

extension ExternalPlugin {
    /// Filing calls waiting on a program, at most (the review of step C, M3): the rest are refused as busy.
    static let fileCallsAtMost = 4
    static let busy = "busy"

    struct Filed {
        var payload: String
        var expiresIn: TimeInterval
    }

    /// The plugin's `file`: the payload (base64, 32 KiB at most) and how long it waits, or its refusal; `then` on the
    /// engine's queue.
    func file(words: [String], cwd: String, desk: PluginDesk, then: @escaping (Result<Filed, PluginRefusal>) -> Void) {
        startedProcess(desk) { started in
            guard case .success(let process) = started else { return then(.failure(PluginRefusal("its program isn't running"))) }
            process.call("file", ["words": words, "cwd": cwd], atMost: Self.fileCallsAtMost) { answer in
                desk.later {
                    switch answer {
                    case .failure(let breach) where breach.busy: then(.failure(PluginRefusal(Self.busy)))
                    case .failure(let breach): then(.failure(PluginRefusal(breach.description)))
                    case .success(let message):
                        if let why = message["refuse"] as? String, message.count == 1 {
                            return then(.failure(PluginRefusal(ConfigSeal.inert(why, limit: 400))))
                        }
                        guard let payload = message["payload"] as? String, let bytes = Data(base64Encoded: payload), bytes.count <= 32 * 1024,
                              let expiresIn = message["expiresIn"] as? Int, expiresIn > 0, message.count == 2 else {
                            return then(.failure(PluginRefusal("its answer didn't fit (payload, expiresIn)")))
                        }
                        then(.success(Filed(payload: payload, expiresIn: TimeInterval(expiresIn))))
                    }
                }
            }
        }
    }
}
