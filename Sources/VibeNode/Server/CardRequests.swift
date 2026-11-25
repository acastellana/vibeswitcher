import Foundation
import VibeCore

/// The server's requests on cards (the engine plan's E6, "The protocol"): `questions` (anyone of the uid), `answer`,
/// `hold`, `config.held`, `config.accept`, `base.show`, `base.accept`, `base.keep` (the user's voice; those on a card
/// with its code), and the lead's tool server's `question.post`, `question.revise` and `question.withdraw` (EN-D10). On
/// the engine's queue, as `handle` calls them.
extension Requests {
    /// Why a request on a card can't go on (nil: it can): no engine, no such card, or a code that isn't the card's.
    func cardRefusal(_ request: NodeWire.Request) -> NodeWire.Reply? {
        guard let engine else { return .init(re: request.id, error: .init(.refused, "this server keeps no cards")) }
        guard let wanted = request.args?["card"]?.string else { return .init(re: request.id, error: .init(.badArgs, "\(request.kind) needs card")) }
        guard let card = engine.cards.resolve(wanted) else {
            return .init(re: request.id, error: .init(.gone, "no card \(ConfigSeal.inert(wanted, limit: 80)) (it went, or the server restarted: list them again)"))
        }
        let kinds: [CardStore.Kind]
        switch request.kind {
        case "answer": kinds = [.question, .approval, .plugin]
        case "answer.replace": kinds = [.question]
        case "hold": kinds = [.question, .approval]
        case "config.accept": kinds = [.configHeld]
        default: kinds = [.baseMove]
        }
        guard kinds.contains(card.kind) else {
            return .init(re: request.id, error: .init(.badArgs, "card \(card.id) is a \(card.kind.rawValue) card: \(request.kind) doesn't take it"))
        }
        guard request.args?["code"]?.string?.uppercased() == card.code else {
            note("refused \(request.kind) on \(card.id): the code typed isn't the card's")
            return .init(re: request.id, error: .init(.voice, "code: the code typed isn't card \(card.id)'s"))
        }
        // A late answer to a withdrawn or decided question still reaches the lead as a note (the board says what became of it).
        guard card.isOpen || request.kind == "answer" || request.kind == "answer.replace" else { return .init(re: request.id, error: .init(.gone, "card \(card.id) is closed: \(card.closed ?? "")")) }
        return nil
    }

    private func engineCard(_ request: NodeWire.Request) -> (LeadEngine, CardStore.Card)? {
        guard let engine, let wanted = request.args?["card"]?.string, let card = engine.cards.resolve(wanted) else { return nil }
        return (engine, card)
    }

    func failed(_ request: NodeWire.Request, _ failure: LeadEngine.CardFailure) -> NodeWire.Reply {
        switch failure {
        case .gone(let why): return .init(re: request.id, error: .init(.gone, why))
        case .delivered(let why): return .init(re: request.id, error: .init(.delivered, why))
        case .refused(let why): return .init(re: request.id, error: .init(.refused, why))
        case .badArgs(let why): return .init(re: request.id, error: .init(.badArgs, why))
        }
    }

    /// The root a request names (`folder`, an absolute path), or its project's (`project`).
    private enum Named {
        case root(String?)
        case failure(NodeWire.Reply)
    }

    /// `then` hears the root on `queue`. A folder's repository is found by git, so off the engine's queue (as
    /// `LeadEngine.startLead` finds it): on the engine's `work`.
    private func namedRoot(_ request: NodeWire.Request, required: Bool, then: @escaping (Named) -> Void) {
        if let folder = request.args?["folder"]?.string {
            guard folder.hasPrefix("/") else { return then(.failure(.init(re: request.id, error: .init(.badArgs, "folder is an absolute path")))) }
            guard let engine else { return then(.root(nil)) }
            let (find, queue) = (repositoryOf, self.queue)
            engine.work.async {
                let root = find(folder)
                queue.async { then(.root(root)) }
            }
            return
        }
        if let project = request.args?["project"]?.string {
            guard let root = engine?.leads.leads[project]?.root ?? engine?.cards.cards.values.first(where: { $0.project == project })?.root else {
                return then(.failure(.init(re: request.id, error: .init(.gone, "no project \(ConfigSeal.inert(project, limit: 80)) on this node"))))
            }
            return then(.root(root))
        }
        then(required ? .failure(.init(re: request.id, error: .init(.badArgs, "\(request.kind) needs folder"))) : .root(nil))
    }

    /// The repository's top for `folder` (the lead's root), or the folder as given when it isn't in one.
    static func repository(_ folder: String) -> String {
        let top = Git.run(["rev-parse", "--show-toplevel"], in: folder)
        let path = top.ok && !top.output.isEmpty ? top.output : folder
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: questions

    /// The closed cards `questions --all` lists at most when it isn't given `limit`.
    static let closedListed = 50

    /// `questions [FOLDER] [--all]`: the open cards (closed ones too with `all`: the newest `limit` of them, at most
    /// `closedListed` unless given, `more` saying how many closed were left out), each as `CardStore.Card.value`.
    /// With `card` (a whole id or a prefix only one card has, `CardStore.resolve`), that card alone, open or closed,
    /// or none: what `answer`, `hold` and the accepts find a card by, however many the server holds. With `wait`, the
    /// open cards once there is one (`waitForCards`).
    func questions(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let args: WireKinds.Questions.Args
        switch request.typedArgs(WireKinds.Questions.Args.self) {
        case .failure(let failure): return reply(.init(re: request.id, error: failure))
        case .success(let typed): args = typed
        }
        if let wanted = args.card {
            let card = engine?.cards.resolve(wanted)
            return reply(.init(re: request.id, typed: WireKinds.Questions.Result(cards: card.map { [$0.value] } ?? [], more: 0)))
        }
        namedRoot(request, required: false) { [weak self] named in
            guard let self else { return }
            let project: String?
            switch named {
            case .failure(let refusal): return reply(refusal)
            case .root(let root): project = root.map { NodeIds.project(root: $0) }
            }
            if args.wait == true { return self.waitForCards(request, seconds: args.seconds, project: project, reply: reply) }
            let listed = self.engine?.cards.list(project: project, all: args.all == true) ?? []
            let limit = max(0, args.limit ?? Self.closedListed)
            let closed = listed.filter { !$0.isOpen }
            let left = Set(closed.dropLast(limit).map(\.id))
            let cards = listed.filter { !left.contains($0.id) }
            reply(.init(re: request.id, typed: WireKinds.Questions.Result(cards: cards.map(\.value), more: left.count)))
        }
    }

    /// How long `questions` with `wait` holds its reply at most before it answers with no card (`waited`): the command
    /// line asks again, so a client that went away holds nothing longer.
    public static let cardWait: TimeInterval = 300

    /// `questions --wait`: the open cards of `project` (every project's when nil) as soon as there is one: at once when
    /// there are, else at the first change of the cards that opens one; none after `wait` (or `cardWait`) seconds, with
    /// `waited` true. On `queue`.
    private func waitForCards(_ request: NodeWire.Request, seconds asked: Int?, project: String?, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server holds no cards"))) }
        let waiting = CardWait()
        func answer(_ cards: [CardStore.Card]) {
            guard !waiting.answered else { return }
            waiting.answered = true
            waiting.watch?.cancel()
            waiting.watch = nil
            reply(.init(re: request.id, typed: WireKinds.Questions.Result(cards: cards.map(\.value), more: 0, waited: cards.isEmpty)))
        }
        func look() {
            let open = engine.cards.list(project: project)
            if !open.isEmpty { answer(open) }
        }
        waiting.watch = engine.cards.changes.subscribe(on: queue) { _ in look() }
        let seconds = min(max(asked.map(TimeInterval.init) ?? Self.cardWait, 0), Self.cardWait)
        queue.asyncAfter(deadline: .now() + seconds) { answer([]) }
        look()
    }

    private final class CardWait: @unchecked Sendable {
        var answered = false
        var watch: Subscription?
    }

    // MARK: answer, hold

    func answer(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let (engine, card) = engineCard(request) else { return reply(.init(re: request.id, error: .init(.gone, "no such card"))) }
        guard let text = request.args?["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return reply(.init(re: request.id, error: .init(.badArgs, "answer needs text")))
        }
        engine.answer(card: card.id, text: text, version: request.args?["version"]?.int, action: request.action?.lowercased()) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure): reply(self.failed(request, failure))
            case .success(let answered): reply(.init(re: request.id, typed: answered))
            }
        }
    }

    /// `answer.replace` (`WireKinds.AnswerReplace`): the user's answer on a question card taken back before its lead had
    /// it, `text` in its place (`LeadEngine.replaceAnswer`).
    func answerReplace(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let (engine, card) = engineCard(request) else { return reply(.init(re: request.id, error: .init(.gone, "no such card"))) }
        guard let text = request.args?["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return reply(.init(re: request.id, error: .init(.badArgs, "answer.replace needs text")))
        }
        engine.replaceAnswer(card: card.id, text: text, action: request.action?.lowercased()) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure): reply(self.failed(request, failure))
            case .success(let replaced): reply(.init(re: request.id, typed: replaced))
            }
        }
    }

    func hold(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let (engine, card) = engineCard(request) else { return reply(.init(re: request.id, error: .init(.gone, "no such card"))) }
        engine.hold(card: card.id, action: request.action?.lowercased()) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure): reply(self.failed(request, failure))
            case .success(let held): reply(.init(re: request.id, typed: held))
            }
        }
    }

    // MARK: draft, draft.clear

    /// The longest draft a page may leave, in characters.
    static let draftLength = 4000

    /// `draft` and `draft.clear` from a web page (the live plan's B5, LW-D6; the wire contract's §8): the user's words
    /// kept on the card (`CardStore.Card.draft`), or taken off it, and told to nobody: nothing reaches the lead or the
    /// vault, and nothing is recorded. `vibeswitcher answer CARD` takes the draft in the user's voice, the card's code
    /// typed. Only `NodeLive` calls this, for a web connection whose token drafts (`WebRequestScreen` judged it first);
    /// `handle` refuses both kinds on the Unix socket.
    ///
    /// The card is named by its whole id (a page holds it); a closed one is `gone`; a draft for a wording the lead has
    /// revised since is `refused`. The reply carries `applied`, the `cards` stream's `seq` at which the change is in
    /// it, written after the stream took it (one turn of the queue later, after the stream's own), so a page's overlay
    /// meets its delta. A repeated action id is answered as the first was, and not done again (the last
    /// `repliesKept`).
    func draft(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let action = request.action?.lowercased(), UUID(uuidString: action) != nil else {
            return reply(.init(re: request.id, error: .init(.badArgs, "\(request.kind) needs an action id (a UUID)")))
        }
        if replies[action] != nil, let again = kept(request, action: action) { return reply(again) }
        let done = { [weak self] (answer: NodeWire.Reply) in
            self?.keep(answer, for: action, request: request)
            reply(answer)
        }
        guard !stopping else { return reply(.init(re: request.id, error: .init(.stopping, "the node is stopping"))) }
        if request.kind == "session.attach" { return attach(request, done: done) }
        if request.kind.hasPrefix("session.") { return sessionDraft(request, action: action, done: done) }
        guard let engine else { return done(.init(re: request.id, error: .init(.refused, "this server keeps no cards"))) }
        guard let id = request.args?["card"]?.string else { return done(.init(re: request.id, error: .init(.badArgs, "\(request.kind) needs card"))) }
        guard let card = engine.cards.cards[id] else {
            return done(.init(re: request.id, error: .init(.gone, "no card \(ConfigSeal.inert(id, limit: 80)) (it went, or the server restarted)")))
        }
        guard let question = card.question, card.kind == .question || card.kind == .approval else {
            return done(.init(re: request.id, error: .init(.badArgs, "card \(card.id) is a \(card.kind.rawValue) card: it takes no answer")))
        }
        guard card.isOpen else { return done(.init(re: request.id, error: .init(.gone, "card \(card.id) is closed: \(card.closed ?? "")"))) }
        if request.kind == "draft" {
            guard let text = request.args?["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return done(.init(re: request.id, error: .init(.badArgs, "draft needs text")))
            }
            guard text.count <= Self.draftLength else {
                return done(.init(re: request.id, error: .init(.badArgs, "a draft is at most \(Self.draftLength) characters")))
            }
            guard let version = request.args?["version"]?.int else { return done(.init(re: request.id, error: .init(.badArgs, "draft needs version"))) }
            guard version == question.version else {
                return done(.init(re: request.id, error: .init(.refused, "the lead revised question \(ConfigSeal.inert(question.short, limit: 40)) (version \(question.version)): read it again")))
            }
            engine.cards.change(card.id) { $0.draft = CardStore.Draft(text: text, version: version, at: Date(), action: action) }
        } else {
            engine.cards.change(card.id) { $0.draft = nil }
        }
        // Nothing of the text in the log: it is the user's words.
        note("\(request.kind) on \(card.id) from a web page (action \(action)): kept on the card, told to nobody")
        queue.async { [weak self] in
            guard let self else { return }
            done(.init(re: request.id, result: .object(["applied": .object(["cards": .int(self.liveSeq?("cards") ?? 0)]), "card": .string(card.id)])))
        }
    }

    // MARK: config

    func configHeld(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server keeps no cards"))) }
        let args: WireKinds.ConfigHeld.Args
        switch request.typedArgs(WireKinds.ConfigHeld.Args.self) {
        case .failure(let failure): return reply(.init(re: request.id, error: failure))
        case .success(let typed): args = typed
        }
        namedRoot(request, required: true) { [weak self] named in
            guard let self else { return }
            let root: String
            switch named {
            case .failure(let refusal): return reply(refusal)
            case .root(let given): root = given ?? ""
            }
            engine.configHeld(root: root, diff: args.diff) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let failure): reply(self.failed(request, failure))
                case .success(let held): reply(.init(re: request.id, typed: held))
                }
            }
        }
    }

    func configAccept(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let (engine, card) = engineCard(request) else { return reply(.init(re: request.id, error: .init(.gone, "no such card"))) }
        // An item of `vibeswitcher approve`'s batch (`batch`, which the batch's own items set): refused when it would
        // record a guard rail or a review floor. Without it, the user's own accept, as before.
        // An acting page's (its mark kept while it is done; a batch item's too): refused unless the floor and the guard
        // rails are the recorded ones (`ConfigHoldStore.pageRefusal`).
        let fromPage = request.action.map { pageMarks[$0.lowercased()] != nil } ?? false
        engine.configAccept(card: card.id, inBatch: request.args?["batch"]?.bool == true, fromPage: fromPage) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure): reply(self.failed(request, failure))
            case .success(let accepted): reply(.init(re: request.id, typed: accepted))
            }
        }
    }

    // MARK: base

    func baseShow(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server keeps no cards"))) }
        let args: WireKinds.BaseShow.Args
        switch request.typedArgs(WireKinds.BaseShow.Args.self) {
        case .failure(let failure): return reply(.init(re: request.id, error: failure))
        case .success(let typed): args = typed
        }
        namedRoot(request, required: true) { [weak self] named in
            guard let self else { return }
            let root: String
            switch named {
            case .failure(let refusal): return reply(refusal)
            case .root(let given): root = given ?? ""
            }
            engine.baseShow(root: root, from: args.from.flatMap { $0.isEmpty ? nil : $0 }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let failure): reply(self.failed(request, failure))
                case .success(.card(let card)): reply(.init(re: request.id, typed: WireKinds.BaseShow.Result(card: card.value)))
                case .success(.unmoved(let branch, let head)): reply(.init(re: request.id, typed: WireKinds.BaseShow.Result(branch: branch, unmoved: head)))
                }
            }
        }
    }

    func baseAnswer(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let (engine, card) = engineCard(request) else { return reply(.init(re: request.id, error: .init(.gone, "no such card"))) }
        func done<R: Encodable>(_ result: Result<R, LeadEngine.CardFailure>) {
            switch result {
            case .failure(let failure): reply(failed(request, failure))
            case .success(let typed): reply(.init(re: request.id, typed: typed))
            }
        }
        if request.kind == "base.accept" { engine.baseAccept(card: card.id) { done($0) } } else { engine.baseKeep(card: card.id) { done($0) } }
    }

    // MARK: The lead's questions

    /// `question.post`, `question.revise`, `question.withdraw` (EN-D10): taken only when the host's `.lead` seal over the
    /// post's digest verifies, the poster isn't under a `BranchCode` runner, and the poster runs in the session the vault
    /// binds to that project's lead role. A field that can't be read refuses it. The card's id is the reply.
    func questionPost(_ request: NodeWire.Request, from facts: PeerFacts, reply: @escaping (NodeWire.Reply) -> Void) {
        let note = self.note
        let refuse: @Sendable (NodeWire.Code, String) -> Void = { code, why in
            note("refused \(request.kind) from pid \(facts.pid): \(why)")
            reply(.init(re: request.id, error: .init(code, why)))
        }
        guard let op = NodeQuestionPost.Op(rawValue: request.kind), let engine else { return refuse(.refused, "this server keeps no cards") }
        // A revision carries what the lead gave (`NodeQuestionPost.Revision`), never the board's question.
        enum Posted { case question(LeadQuestion), revision(NodeQuestionPost.Revision) }
        let decoded = { (text: String) -> Posted? in
            let data = Data(text.utf8)
            if op == .revise { return (try? JSONDecoder().decode(NodeQuestionPost.Revision.self, from: data)).map(Posted.revision) }
            return (try? JSONDecoder().decode(LeadQuestion.self, from: data)).map(Posted.question)
        }
        guard let args = request.args, let root = args["root"]?.string, root.hasPrefix("/"), let text = args["question"]?.string,
              let posted = decoded(text),
              let seal = args["seal"], let id = seal["id"]?.string, let at = seal["at"]?.string.flatMap(Double.init),
              let name = seal["name"]?.string, let sealed = seal["seal"]?.string else {
            return refuse(.badArgs, "\(request.kind) needs root, question (its JSON: a revision's, what the lead gave) and seal (id, at, name, seal)")
        }
        guard name == NodeQuestionPost.leadName(root: root) else { return refuse(.voice, "seal: it names \(ConfigSeal.inert(name, limit: 80)), not this project's lead") }
        guard let runner = facts.underRunner else { return refuse(.voice, "whether the poster runs under branch code can't be read") }
        guard !runner else { return refuse(.voice, "the poster runs under a branch code runner") }
        guard let ancestry = facts.ancestry else { return refuse(.voice, "the poster's ancestry can't be read") }
        guard link.state == .connected else { return refuse(.notYet, "the server's link to its host isn't welcomed yet: retry") }
        let pids = Set(ancestry.map(\.pid))
        guard let session = link.sessions.first(where: { $0.isLive && pids.contains($0.childPID) }) else {
            return refuse(.voice, "the poster runs in no live session")
        }
        let message = { () -> SteerMessage in
            var message = NodeQuestionPost.sealed(digest: NodeQuestionPost.digest(op: op, root: root, question: Data(text.utf8)), root: root, id: id, at: at)
            message.seal = sealed
            return message
        }()
        let vault = link.vault
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let valid = (try? vault.verify([message])) == [true]
            let bound = vault.current(.lead, root: root, task: nil)?.session?.lowercased() == session.id.uuidString.lowercased()
            guard let self else { return }
            self.queue.async {
                guard valid else { return refuse(.voice, "seal: the post's seal isn't the host's for \(LeadMail.project(of: root))'s lead") }
                guard bound else { return refuse(.voice, "the poster's session isn't the one the vault binds to \(LeadMail.project(of: root))'s lead role") }
                let card: CardStore.Card?, short: String
                switch posted {
                case .question(let question): (card, short) = (engine.questionPosted(op, question: question, root: root), question.short)
                case .revision(let revision): (card, short) = (engine.questionRevised(revision, root: root), String(revision.id.prefix(8)))
                }
                guard let card else { return refuse(.gone, "no card for question \(ConfigSeal.inert(short, limit: 40)): it was never posted") }
                reply(.init(re: request.id, result: .object(["card": .string(card.id)])))
            }
        }
    }
}

extension CardStore.Card {
    /// The command that shows every card whole, whatever its size.
    public static let wholeCommand = "vibeswitcher questions"

    /// What stands in the place of a card withheld from a snapshot in parts (`LiveStream.Oversized`): `value`'s place
    /// (its id, kind, project and root, whether it is open, when, whether it blocks; a plugin card's plugin, asking
    /// session and asker, the host's), none of what it asks, and `tooLarge`: its bytes and the command that shows it
    /// whole. The page draws it as a card too large to show there.
    public static func tooLargeStub(_ value: NodeWire.Value, bytes: Int) -> NodeWire.Value? {
        var stub: [String: NodeWire.Value] = [:]
        for key in ["id", "kind", "project", "root", "open", "closed", "at", "blocking"] { stub[key] = value[key] ?? .null }
        if let plugin = value["plugin"] {
            stub["plugin"] = .object(["plugin": plugin["plugin"] ?? .null, "session": plugin["session"] ?? .null,
                                      "asker": plugin["asker"] ?? .null, "title": plugin["title"] ?? .null])
        }
        stub["tooLarge"] = .object(["bytes": .int(bytes), "command": .string(wholeCommand)])
        return .object(stub)
    }

    /// A draft as the card's `draft` carries it.
    static func draftValue(_ draft: CardStore.Draft) -> NodeWire.Value {
        .object(["text": .string(draft.text), "version": .int(draft.version), "at": .date(draft.at), "action": .string(draft.action)])
    }

    /// The card as the protocol carries it. What the lead or a worker wrote (the question, its options, notes, a
    /// commit's subject, file names) is the lead's words or git's: the command line prints every such field inert.
    public var value: NodeWire.Value {
        func text(_ value: String?) -> NodeWire.Value { value.map(NodeWire.Value.string) ?? .null }
        func texts(_ values: [String]) -> NodeWire.Value { .array(values.map(NodeWire.Value.string)) }
        var fields: [String: NodeWire.Value] = [:]
        fields["id"] = .string(id)
        fields["kind"] = .string(kind.rawValue)
        fields["project"] = .string(project)
        fields["root"] = .string(root)
        fields["open"] = .bool(isOpen)
        fields["closed"] = text(closed)
        fields["notice"] = text(notice)
        fields["at"] = .date(at)
        fields["blocking"] = .bool(isBlocking)
        // The user's own words, drafted on a page: shown as theirs, inert on the command line like every other field.
        fields["draft"] = draft.map(Self.draftValue) ?? .null
        if let question {
            var q: [String: NodeWire.Value] = [:]
            q["id"] = .string(question.id)
            q["short"] = .string(question.short)
            q["text"] = .string(question.text)
            q["options"] = texts(question.options)
            q["priority"] = .string(question.rank.rawValue)
            q["whyNow"] = text(question.whyNow)
            q["version"] = .int(question.version)
            q["revisionNote"] = text(question.lastRevision?.note)
            q["proposal"] = text(question.proposal)
            q["decideBy"] = question.isCounting ? question.decideBy.map { NodeWire.Value.date(Date(timeIntervalSince1970: $0)) } ?? .null : .null
            q["state"] = .string(question.state.rawValue)
            q["answer"] = text(question.answer)
            q["answeredVersion"] = question.answeredVersion.map(NodeWire.Value.int) ?? .null
            q["withdrawReason"] = text(question.withdrawReason)
            q["task"] = text(question.task)
            fields["question"] = .object(q)
        }
        if let approval {
            var a: [String: NodeWire.Value] = [:]
            a["commit"] = .string(approval.commit)
            a["tasks"] = texts(approval.tasks)
            a["base"] = text(approval.base)
            a["files"] = texts(approval.files)
            a["diffstat"] = .string(approval.diffstat)
            a["subject"] = text(approval.subject)
            a["verdicts"] = .object(approval.verdicts.mapValues(NodeWire.Value.string))
            a["sensitive"] = approval.sensitive.map(texts) ?? .null
            a["problems"] = texts(approval.problems)
            fields["approval"] = .object(a)
        }
        if let config {
            var c: [String: NodeWire.Value] = [:]
            c["items"] = .array(config.items.map { item in
                var i: [String: NodeWire.Value] = [:]
                i["name"] = .string(item.name)
                i["changedAt"] = item.changedAt.map(NodeWire.Value.date) ?? .null
                i["size"] = item.size.map(NodeWire.Value.int) ?? .null
                i["hash"] = .string(item.hash)
                i["change"] = text(item.change)
                i["outside"] = .bool(item.outside)
                i["files"] = texts(item.files.map { ConfigSeal.fileLabel($0, in: item.name) })
                i["sinceAccept"] = text(item.sinceAccept)
                return .object(i)
            })
            c["guarded"] = .array(config.guarded.map { rail in
                .object(["key": .string(rail.key), "value": .string(rail.value), "sinceAccept": text(rail.sinceAccept)])
            })
            c["lastAccept"] = config.lastAccept.map(NodeWire.Value.date) ?? .null
            if config.firstLook == true { c["firstLook"] = .bool(true) }
            c["sharedHome"] = config.sharedHome.map { shared in
                .object(["names": texts(shared.names), "card": .string(shared.card), "folder": .string(shared.folder)])
            } ?? .null
            if let floor = config.floor {
                var f: [String: NodeWire.Value] = [:]
                f["mergePolicy"] = .string(floor.mergePolicy.rawValue)
                f["auditFinders"] = .int(floor.auditFinders)
                f["sensitivePaths"] = texts(floor.sensitivePaths)
                f["strictPaths"] = texts(floor.strictPaths)
                f["riskLines"] = .int(floor.riskLines)
                f["riskModel"] = .bool(floor.riskModel)
                f["verifierDifferent"] = .bool(floor.verifierDifferent)
                f["auditSamplePercent"] = .int(floor.auditSamplePercent)
                c["floor"] = .object(f)
            } else {
                c["floor"] = .null
            }
            c["baseBranch"] = text(config.baseBranch)
            fields["config"] = .object(c)
        }
        if let plugin { fields["plugin"] = plugin.value }
        if let base {
            var b: [String: NodeWire.Value] = [:]
            b["branch"] = .string(base.branch)
            b["from"] = text(base.from)
            b["fromIs"] = .string(base.fromIs.rawValue)
            b["to"] = .string(base.to)
            b["reason"] = text(base.reason)
            b["commits"] = .array(base.commits.map { NodeWire.Value.object(["sha": .string($0.sha), "subject": .string($0.subject)]) })
            fields["base"] = .object(b)
        }
        fields["seen"] = .string(Self.seen(of: fields))
        return .object(fields)
    }

    /// What an acting page names to answer or accept it (acting from the page, the web UI design's step 2): the SHA-256,
    /// lower-case hex, of the card as the protocol carries it, but its draft (the page's own words) and this. Anything
    /// else on it changes it, so the node refuses an act on a card that changed since the page drew it.
    public var seen: String { value["seen"]?.string ?? "" }

    static func seen(of fields: [String: NodeWire.Value]) -> String {
        var shown = fields
        shown["draft"] = nil
        shown["seen"] = nil
        return BuildInfo.sha256(of: NodeWire.line(NodeWire.Value.object(shown)))
    }
}
