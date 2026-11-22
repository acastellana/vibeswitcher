import Foundation
import VibeCore

/// A request an external plugin's `vs-ask` filed: the core's envelope around the plugin's payload (the definition's
/// "Filing"), its bytes what the session host stamped. The core writes it (`plugin.file`), the core reads it back.
struct PluginAskEnvelope: Codable, Equatable, StampedAsk {
    static let format = "vs-ask v1"
    var format: String
    var id: String
    var plugin: String
    var session: String
    var createdAt: Double
    var expiresAt: Double
    /// The plugin's payload, base64: opaque to the core.
    var payload: String

    var created: Date { Date(timeIntervalSince1970: createdAt) }
    var expires: Date { Date(timeIntervalSince1970: expiresAt) }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The envelope in `data` for `plugin`, only when `data` is exactly what `encoded()` writes for it.
    static func decode(_ data: Data, plugin: String) throws -> PluginAskEnvelope {
        let envelope = try JSONDecoder().decode(PluginAskEnvelope.self, from: data)
        guard envelope.format == format, envelope.plugin == plugin, WalletRequestFormat.isID(envelope.id),
              UUID(uuidString: envelope.session) != nil, envelope.session == envelope.session.lowercased(),
              envelope.expiresAt > envelope.createdAt, Data(base64Encoded: envelope.payload) != nil,
              try envelope.encoded() == data else { throw PluginRefusal("it isn't a request as vs-ask files one") }
        return envelope
    }
}

/// An external plugin (the definition's "External plugins"): a program in a folder the user added, run as a child
/// (`PluginProcess`) from a sealed copy checked against the vault's record, speaking protocol v1. Everything it answers
/// is data the core checks: a card's shape and the core's checks on it (`PluginDesk.draw`), its facts shown as its own
/// and named, an outcome's words plain and bounded, a page served by the core (`PluginPage`). An answer that doesn't
/// fit its shape is a breach: its program ends, its open cards are withdrawn, `plugin list` says why. It can't act on
/// the node: no session started, nothing typed, no card answered; it is asked, and answers.
final class ExternalPlugin: FeaturePlugin {
    let manifest: PluginManifest
    let record: PluginRecord
    let info: PluginInfo
    /// Why it can't run (its program or manifest changed since it was added, or isn't there).
    var held: String?
    /// Why its program ended (a breach), until it is turned off and on again.
    var ended: String?
    private var process: PluginProcess?
    private var starting: [(Result<PluginProcess, PluginRefusal>) -> Void] = []
    /// What became of each request (its outcome's state word), and the envelopes drawn.
    private var answers: [String: String] = [:]
    private var shown: [String: PluginAskEnvelope] = [:]
    private var asking: Set<String> = []

    init(manifest: PluginManifest, record: PluginRecord, held: String? = nil) {
        self.manifest = manifest
        self.record = record
        self.held = held
        info = manifest.info
    }

    func availability() -> String? {
        if let held { return held }
        return ended.map { "its program ended (\($0)): `vibeswitcher plugin off \(info.id)` then `on` starts it again" }
    }

    // MARK: The program

    /// The program, started once (from a sealed copy whose SHA-256 is the record's) and greeted; `then` on the engine's
    /// queue.
    func startedProcess(_ desk: PluginDesk, then: @escaping (Result<PluginProcess, PluginRefusal>) -> Void) { ensureStarted(desk, then: then) }

    private func ensureStarted(_ desk: PluginDesk, then: @escaping (Result<PluginProcess, PluginRefusal>) -> Void) {
        if let process, process.ended == nil { return then(.success(process)) }
        starting.append(then)
        guard starting.count == 1 else { return }
        let (record, manifest, root, note, id) = (record, manifest, desk.root, desk.note, info.id)
        let settings = desk.settings
        desk.work.async { [weak self] in
            let started = Self.start(record: record, manifest: manifest, root: root, note: note)
            desk.queue.async {
                guard let self else { return }
                switch started {
                case .failure(let why):
                    if why.description.contains("changed since") { self.held = why.description }
                    self.finishStarting(.failure(why))
                case .success(let process):
                    process.onEnd = { [weak self] why in desk.queue.async { self?.breached(why, desk: desk) } }
                    process.call("hello", ["protocol": 1, "settings": settings]) { answer in
                        desk.queue.async {
                            switch answer {
                            case .success(let hello) where hello["plugin"] as? String == id && hello["version"] as? String == manifest.version
                                && hello.count == 2:
                                self.process = process
                                self.finishStarting(.success(process))
                            case .success:
                                process.stop()
                                self.breached("its hello isn't its manifest's id and version", desk: desk)
                                self.finishStarting(.failure(PluginRefusal("its hello isn't its manifest's id and version")))
                            case .failure(let breach):
                                self.finishStarting(.failure(PluginRefusal(breach.description)))
                            }
                        }
                    }
                }
            }
        }
    }

    private func finishStarting(_ result: Result<PluginProcess, PluginRefusal>) {
        let waiting = starting
        starting = []
        waiting.forEach { $0(result) }
    }

    /// Reads the program into a sealed copy, checks it and the manifest against the record, and starts it. Blocks.
    static func start(record: PluginRecord, manifest: PluginManifest, root: URL, note: @escaping (String) -> Void) -> Result<PluginProcess, PluginRefusal> {
        let folder = URL(fileURLWithPath: record.folder)
        guard let bytes = PluginDesk.bounded(folder.appendingPathComponent(PluginManifest.fileName), limit: PluginManifest.bytesAtMost),
              BuildInfo.sha256(of: bytes) == record.manifest else {
            return .failure(PluginRefusal("its manifest changed since you added it: `vibeswitcher plugin add \(record.folder)` again"))
        }
        let path = (record.folder as NSString).appendingPathComponent(manifest.program)
        let copy: Platform.ProcessSelf.SealedCopy
        switch Platform.ProcessSelf.sealedCopy(of: path, name: "plugin-\(manifest.id)") {
        case .failure(let error): return .failure(PluginRefusal("its program couldn't be read (errno \(error.code))"))
        case .success(let made): copy = made
        }
        guard copy.withBytes({ BuildInfo.sha256(of: Data($0)) }) == record.program else {
            Sys.close(copy.fd)
            return .failure(PluginRefusal("its program changed since you added it: `vibeswitcher plugin add \(record.folder)` again"))
        }
        let work = root.appendingPathComponent("plugins/\(manifest.id)/work", isDirectory: true)
        do { try VibePaths.ensurePrivate(work.deletingLastPathComponent()); try VibePaths.ensurePrivate(work) } catch {
            Sys.close(copy.fd)
            return .failure(PluginRefusal("its working folder couldn't be made: \(error)"))
        }
        let process = PluginProcess(id: manifest.id, note: note)
        let started = process.start(copy: copy, work: work)
        Sys.close(copy.fd)
        return started.map { process }
    }

    /// Its program broke the protocol (or ended): it stays ended, its open cards withdrawn, until turned off and on.
    private func breached(_ why: String, desk: PluginDesk) {
        guard ended == nil else { return }
        ended = why
        process = nil
        desk.note("plugin \(info.id): \(why); its open cards withdrawn")
        desk.withdrawAll()
    }

    /// A breach of the program's answer's shape: its program is ended.
    private func misshapen(_ why: String, desk: PluginDesk) {
        process?.stop()
        breached("its answer didn't fit: \(why)", desk: desk)
    }

    // MARK: The look

    func look(_ desk: PluginDesk, done: @escaping () -> Void) {
        let id = info.id
        desk.stamped({ try PluginAskEnvelope.decode($0, plugin: id) }) { [weak self] asks in
            guard let self else { return done() }
            let now = desk.now
            let fresh = asks.filter {
                self.answers[$0.id] == nil && desk.card(request: $0.id) == nil && !desk.isSettled($0.id) && !self.asking.contains($0.id) && $0.expires > now
            }
            guard !fresh.isEmpty else { return done() }
            self.ensureStarted(desk) { started in
                guard case .success(let process) = started else { return done() }
                var left = fresh.count
                for ask in fresh {
                    self.asking.insert(ask.id)
                    process.call("card", ["request": ask.id, "payload": ask.payload, "settings": desk.settings]) { answer in
                        desk.queue.async {
                            self.asking.remove(ask.id)
                            self.drawCard(ask, answer, desk: desk)
                            left -= 1
                            if left == 0 { done() }
                        }
                    }
                }
            }
        }
    }

    private func drawCard(_ ask: PluginAskEnvelope, _ answer: Result<PluginProcess.Message, PluginProcess.Breach>, desk: PluginDesk) {
        guard case .success(let message) = answer else {
            // Asked when its program broke the protocol (or ended): this request is settled, never asked again, its asker told.
            answers[ask.id] = "failed"
            desk.settle(ask.id)
            desk.tell("[VibeSwitcher] Your \(info.title) request \(ask.id) wasn't shown: the plugin's program ended while it was asked about it.",
                      from: "from VibeSwitcher", request: ask.id) { _ in }
            return
        }
        if let refuse = message["refuse"] as? String, message.count == 1 {
            answers[ask.id] = "refused"
            desk.settle(ask.id)
            desk.note("plugin \(info.id) refused request \(ask.id): \(ConfigSeal.inert(refuse, limit: 200))")
            desk.tell("[VibeSwitcher] Your \(info.title) request \(ask.id) wasn't shown: the plugin said \u{201C}\(ConfigSeal.inert(refuse, limit: 300))\u{201D}.",
                      from: "from VibeSwitcher", request: ask.id) { _ in }
            return
        }
        guard let object = message["card"] as? [String: Any], message.count == 1 else {
            answers[ask.id] = "failed"
            desk.settle(ask.id)
            return misshapen("a card is {card} or {refuse}", desk: desk)
        }
        let card: PluginCard
        switch Self.card(object, ask: ask, manifest: manifest, folder: desk.live[ask.session]?.cwd) {
        case .failure(let why):
            answers[ask.id] = "failed"
            desk.settle(ask.id)
            return misshapen(why.description, desk: desk)
        case .success(let made): card = made
        }
        switch desk.draw(card, root: desk.live[ask.session]?.cwd ?? desk.root.path, at: ask.created) {
        case .success: shown[ask.id] = ask
        case .failure(let why):
            answers[ask.id] = "refused"
            desk.settle(ask.id)
            desk.note("plugin \(info.id): request \(ask.id) not shown: \(why)")
            desk.tell("[VibeSwitcher] Your \(info.title) request \(ask.id) wasn't shown: \(why). Nothing happened.", from: "from VibeSwitcher",
                      request: ask.id) { _ in }
        }
    }

    /// The card the plugin's `card` describes, its shape checked: plain fields, the plugin's facts named as its own, the
    /// asking session's folder the host's (drawn by the core), the expiry the core's.
    static func card(_ object: [String: Any], ask: PluginAskEnvelope, manifest: PluginManifest, folder: String?) -> Result<PluginCard, PluginRefusal> {
        let known: Set<String> = ["title", "noun", "ask", "facts", "body", "context", "severity", "actions", "waiting"]
        guard object.keys.allSatisfy(known.contains) else { return .failure(PluginRefusal("a card field this node doesn't read")) }
        func text(_ value: Any?, _ limit: Int) -> String? { (value as? String).flatMap { PluginManifest.plain($0, limit: limit) ? $0 : nil } }
        guard let title = text(object["title"], 60), let noun = text(object["noun"], 40), let askLine = text(object["ask"], 80),
              let body = object["body"] as? [String: Any], let bodyName = text(body["name"], 40), let bodyLabel = text(body["label"], 120),
              let bodyText = body["text"] as? String, body.keys.allSatisfy(["name", "label", "note", "text"].contains),
              let actions = object["actions"] as? [[String: Any]], (1...4).contains(actions.count) else {
            return .failure(PluginRefusal("a card's title, noun, ask, body and 1 to 4 actions"))
        }
        let note = body["note"].map { text($0, 160) }
        if note == .some(nil) { return .failure(PluginRefusal("a body's note is plain")) }
        var facts: [PluginCard.Fact] = []
        if let folder { facts.append(.init(name: "folder", label: "the asking session's folder", value: folder, folder: true, decisive: true)) }
        for fact in (object["facts"] as? [[String: Any]]) ?? [] {
            guard fact.keys.allSatisfy(["label", "value", "decisive"].contains), let label = text(fact["label"], 60), let value = fact["value"] as? String,
                  value.count <= 2000 else { return .failure(PluginRefusal("a fact is a plain label and a value")) }
            facts.append(.init(name: "fact", label: "\(manifest.title) says, \(label)", value: value, decisive: fact["decisive"] as? Bool == true))
        }
        guard facts.count <= 13, object["facts"] == nil || object["facts"] is [[String: Any]] else { return .failure(PluginRefusal("12 facts at most")) }
        var context: PluginCard.Context?
        if let given = object["context"] {
            guard let given = given as? [String: Any], given.keys.allSatisfy(["label", "text"].contains), let label = text(given["label"], 40),
                  let words = given["text"] as? String else { return .failure(PluginRefusal("a context is a plain label and text")) }
            context = .init(name: "context", label: label, text: words)
        }
        var made: [PluginCard.Action] = []
        for action in actions {
            guard action.keys.allSatisfy(["word", "label", "acts", "short", "does", "verb", "marks"].contains),
                  let word = action["word"] as? String, LeadVaultV2.pluginID(word), let label = text(action["label"], 30),
                  let acts = action["acts"] as? Bool, let short = text(action["short"], 80), let does = text(action["does"], 400),
                  let verb = text(action["verb"], 120), let marks = action["marks"] as? String, LeadVaultV2.pluginID(marks) else {
                return .failure(PluginRefusal("an action is a word, a label, acts, short, does, verb and marks"))
            }
            made.append(.init(word: word, label: label, acts: acts, short: short, does: does, verb: verb, marks: marks))
        }
        let severity = (object["severity"] as? String).flatMap(PluginCard.Severity.init(rawValue:)) ?? .important
        let waiting = object["waiting"].map { text($0, 160) }
        if waiting == .some(nil) { return .failure(PluginRefusal("waiting is plain")) }
        return .success(PluginCard(plugin: manifest.id, request: ask.id, session: "", asker: "", title: title, noun: noun, ask: askLine, facts: facts,
                                   body: .init(name: bodyName, label: bodyLabel, note: note ?? nil, text: bodyText), context: context, severity: severity,
                                   expiresAt: ask.expires, actions: made, waiting: waiting ?? nil))
    }

    // MARK: Answers

    func perform(_ word: String, on card: CardStore.Card, desk: PluginDesk, act: PluginAct,
                 then: @escaping (Result<NodeWire.Value, LeadEngine.CardFailure>) -> Void) {
        guard let id = card.plugin?.request, let ask = shown[id], answers[id] == nil else {
            return then(.failure(.gone("no \(info.title) request on card \(card.id) to answer")))
        }
        answers[id] = "answering"
        ensureStarted(desk) { [weak self] started in
            guard let self else { return }
            guard case .success(let process) = started else {
                self.answers[id] = nil
                return then(.failure(.refused("\(self.info.title)'s program isn't running: nothing was done")))
            }
            process.call("perform", ["request": id, "payload": ask.payload, "word": word, "settings": desk.settings]) { answer in
                desk.queue.async {
                    switch answer {
                    case .failure(let breach): then(.failure(.refused("\(self.info.title)'s program: \(breach.description); nothing more was done")))
                    case .success(let message):
                        if let outcome = message["outcome"] as? [String: Any], message.count == 1 {
                            guard let applied = self.apply(outcome, request: id, desk: desk) else {
                                self.misshapen("an outcome is a state word, a line for the person and one for the agent", desk: desk)
                                return then(.failure(.refused("\(self.info.title)'s answer didn't fit: nothing more was done")))
                            }
                            then(.success(.object(["outcome": .string(applied.state), "notice": .null, "say": .array([.string(applied.person)])])))
                        } else if let page = message["page"] as? [String: Any], message.count == 1, self.manifest.page == true {
                            self.openPage(page, request: id, ask: ask, process: process, desk: desk, act: act, then: then)
                        } else {
                            self.misshapen("perform answers {outcome} or, for a plugin that serves one, {page}", desk: desk)
                            then(.failure(.refused("\(self.info.title)'s answer didn't fit: nothing more was done")))
                        }
                    }
                }
            }
        }
    }

    /// The plugin's page, served once by the core: its answer handed to `page.answer`.
    private func openPage(_ given: [String: Any], request id: String, ask: PluginAskEnvelope, process: PluginProcess, desk: PluginDesk, act: PluginAct,
                          then: @escaping (Result<NodeWire.Value, LeadEngine.CardFailure>) -> Void) {
        guard given.keys.allSatisfy(["html", "scripts", "styles", "life"].contains), let html = given["html"] as? String,
              let scripts = given["scripts"] as? [String], let styles = given["styles"] as? [String], let life = given["life"] as? Int else {
            misshapen("a page is html, scripts, styles and life", desk: desk)
            return then(.failure(.refused("\(info.title)'s page didn't fit: nothing was opened")))
        }
        let spec = PluginPage.Spec(html: html, scripts: scripts, styles: styles, life: TimeInterval(life))
        if let why = spec.refusal {
            answers[id] = nil
            desk.change(request: id, state: "failed", outcome: "Its page wasn't served: \(why)", closed: "its page wasn't served: \(why)")
            return then(.failure(.refused("\(info.title)'s page wasn't served: \(why)")))
        }
        act.openPage(spec, take: { [weak self] bytes, answer in
            guard let self else { return answer(false) }
            process.call("page.answer", ["request": id, "payload": ask.payload, "answer": String(decoding: bytes, as: UTF8.self)]) { reply in
                desk.queue.async {
                    guard case .success(let message) = reply else { return answer(false) }
                    if message["refuse"] is String, message.count == 1 { return answer(false) }
                    guard let outcome = message["outcome"] as? [String: Any], message.count == 1, self.apply(outcome, request: id, desk: desk) != nil else {
                        self.misshapen("page.answer answers {outcome} or {refuse}", desk: desk)
                        return answer(false)
                    }
                    answer(true)
                }
            }
        }, ended: { [weak self] taken in
            guard let self, !taken else { return }
            _ = self.apply(["state": "no-answer", "person": "No answer came back from its page", "agent": "Its page got no answer before it stopped: it may or may not have been done. Ask the user before asking again."],
                           request: id, desk: desk)
        }) { opened in
            switch opened {
            case .failure(let why):
                self.answers[id] = nil
                desk.change(request: id, state: "failed", outcome: "Its page wasn't served: \(why)", closed: "its page wasn't served: \(why)")
                then(.failure(.refused("\(self.info.title)'s page wasn't served: \(why)")))
            case .success(let url):
                desk.change(request: id, state: "page", outcome: "Its page is open (its address went to your terminal)")
                then(.success(.object(["outcome": .string("page"), "notice": .null, "say": .array([
                    .string("Open this page in your browser (it works once, \(life / 60) minutes at most):"), .string("  " + url.absoluteString)])])))
            }
        }
    }

    /// An outcome's words, checked: a state word, a line for the person (the card's), one for the asking agent (told from
    /// the plugin, through VibeSwitcher). The card settles. Nil when it doesn't fit.
    private func apply(_ outcome: [String: Any], request id: String, desk: PluginDesk) -> (state: String, person: String)? {
        guard outcome.keys.allSatisfy(["state", "person", "agent"].contains), let state = outcome["state"] as? String, LeadVaultV2.pluginID(state),
              state != PluginCard.waitingState, let person = outcome["person"] as? String, PluginManifest.plain(person, limit: 300),
              let agent = outcome["agent"] as? String, PluginManifest.plain(agent, limit: 1000, lines: true) else { return nil }
        answers[id] = state
        desk.change(request: id, state: state, outcome: person, closed: person)
        desk.tell("[\(info.title), through VibeSwitcher] Your request \(id): \(agent)", from: "from \(info.title)", request: id) { _ in }
        return (state, person)
    }

    // MARK: Settings, off

    func check(setting name: String, value: String?) -> Result<String?, PluginRefusal> { .failure(PluginRefusal("asked of its program")) }

    func check(setting name: String, value: String?, then: @escaping (Result<String?, PluginRefusal>) -> Void) {
        guard let value else { return then(.success(nil)) }
        guard let process, process.ended == nil else { return then(.failure(PluginRefusal("its program isn't running"))) }
        process.call("settings.check", ["key": name, "value": value]) { answer in
            switch answer {
            case .success(let message) where message["ok"] as? Bool == true && message.count == 1: then(.success(value))
            case .success(let message) where message["refuse"] is String && message.count == 1:
                then(.failure(PluginRefusal(ConfigSeal.inert(message["refuse"] as? String ?? "", limit: 200))))
            case .success: then(.failure(PluginRefusal("its answer didn't fit")))
            case .failure(let breach): then(.failure(PluginRefusal(breach.description)))
            }
        }
    }

    func withdrawn(_ card: PluginCard, desk: PluginDesk) -> String? {
        process?.call("withdrawn", ["request": card.request]) { _ in }
        answers[card.request] = PluginCard.withdrawnState
        return nil
    }

    func turnedOff(_ desk: PluginDesk) -> [(session: UUID, text: String)] {
        process?.stop()
        process = nil
        return []
    }

    /// Removed or the server stopping: its program ends.
    func stop() {
        process?.stop()
        process = nil
    }
}
