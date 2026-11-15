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
        case "answer": kinds = [.question, .approval]
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
        guard card.isOpen || request.kind == "answer" else { return .init(re: request.id, error: .init(.gone, "card \(card.id) is closed: \(card.closed ?? "")")) }
        return nil
    }

    private func engineCard(_ request: NodeWire.Request) -> (LeadEngine, CardStore.Card)? {
        guard let engine, let wanted = request.args?["card"]?.string, let card = engine.cards.resolve(wanted) else { return nil }
        return (engine, card)
    }

    private func failed(_ request: NodeWire.Request, _ failure: LeadEngine.CardFailure) -> NodeWire.Reply {
        switch failure {
        case .gone(let why): return .init(re: request.id, error: .init(.gone, why))
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

    /// `questions [FOLDER] [--all]`: the open cards (closed ones too with `all`), each as `CardStore.Card.value`.
    func questions(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        namedRoot(request, required: false) { [weak self] named in
            guard let self else { return }
            let project: String?
            switch named {
            case .failure(let refusal): return reply(refusal)
            case .root(let root): project = root.map { NodeIds.project(root: $0) }
            }
            let cards = self.engine?.cards.list(project: project, all: request.args?["all"]?.bool == true) ?? []
            reply(.init(re: request.id, result: .object(["cards": .array(cards.map(\.value))])))
        }
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
            case .success(let value): reply(.init(re: request.id, result: value))
            }
        }
    }

    func hold(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let (engine, card) = engineCard(request) else { return reply(.init(re: request.id, error: .init(.gone, "no such card"))) }
        engine.hold(card: card.id, action: request.action?.lowercased()) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure): reply(self.failed(request, failure))
            case .success(let value): reply(.init(re: request.id, result: value))
            }
        }
    }

    // MARK: config

    func configHeld(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server keeps no cards"))) }
        namedRoot(request, required: true) { [weak self] named in
            guard let self else { return }
            let root: String
            switch named {
            case .failure(let refusal): return reply(refusal)
            case .root(let given): root = given ?? ""
            }
            engine.configHeld(root: root, diff: request.args?["diff"]?.string) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let failure): reply(self.failed(request, failure))
                case .success(let value): reply(.init(re: request.id, result: value))
                }
            }
        }
    }

    func configAccept(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let (engine, card) = engineCard(request) else { return reply(.init(re: request.id, error: .init(.gone, "no such card"))) }
        engine.configAccept(card: card.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure): reply(self.failed(request, failure))
            case .success(let value): reply(.init(re: request.id, result: value))
            }
        }
    }

    // MARK: base

    func baseShow(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server keeps no cards"))) }
        namedRoot(request, required: true) { [weak self] named in
            guard let self else { return }
            let root: String
            switch named {
            case .failure(let refusal): return reply(refusal)
            case .root(let given): root = given ?? ""
            }
            engine.baseShow(root: root, from: request.args?["from"]?.string.flatMap { $0.isEmpty ? nil : $0 }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let failure): reply(self.failed(request, failure))
                case .success(let card): reply(.init(re: request.id, result: .object(["card": card.value])))
                }
            }
        }
    }

    func baseAnswer(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let (engine, card) = engineCard(request) else { return reply(.init(re: request.id, error: .init(.gone, "no such card"))) }
        let done: (Result<NodeWire.Value, LeadEngine.CardFailure>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure): reply(self.failed(request, failure))
            case .success(let value): reply(.init(re: request.id, result: value))
            }
        }
        if request.kind == "base.accept" { engine.baseAccept(card: card.id, then: done) } else { engine.baseKeep(card: card.id, then: done) }
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
        guard let args = request.args, let root = args["root"]?.string, root.hasPrefix("/"), let text = args["question"]?.string,
              let question = try? JSONDecoder().decode(LeadQuestion.self, from: Data(text.utf8)),
              let seal = args["seal"], let id = seal["id"]?.string, let at = seal["at"]?.string.flatMap(Double.init),
              let name = seal["name"]?.string, let sealed = seal["seal"]?.string else {
            return refuse(.badArgs, "\(request.kind) needs root, question (its JSON) and seal (id, at, name, seal)")
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
                guard let card = engine.questionPosted(op, question: question, root: root) else {
                    return refuse(.gone, "no card for question \(question.short): it was never posted")
                }
                reply(.init(re: request.id, result: .object(["card": .string(card.id)])))
            }
        }
    }
}

extension CardStore.Card {
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
                return .object(i)
            })
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
        return .object(fields)
    }
}
