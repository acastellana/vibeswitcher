import Foundation
import VibeCore

/// Brief me (the parity table's row; the app's `Briefing/`, `BriefingModel`): what happened lately and what is asked of
/// you, at the highest level, across the projects this node leads (or one, with a folder). Built from what the node
/// keeps: each lead's progress log and board (`Briefing.compose`, the app's own composer: its log's entries since the
/// last briefing or 3 hours, its counts and open questions, every line redacted), the sessions waiting on you, the open
/// cards beyond questions (approvals, held config, a moved base), and each board's all-done mark of the last day.
/// Written by the summaries' model when AI summaries may run (`LeadEngine.summariesAllowed`: on in Settings, Haiku not
/// held back; `Options.summarizeBrief`, the user's node's headless Claude with the briefing's system prompt), else the
/// app's written template, in English.
///
/// `brief [folder]` is a read of the user's own (`NodeWire.Voice.webRead`, as `mail`): the user's on the socket, or a
/// page's token that reads; never a session's process, which would make the node spend the account's usage on its
/// asking. A briefing is kept `kept` seconds for its scope, so asking again doesn't ask the model again. Nothing is
/// written but the time of the last briefing, in the server's memory.
extension Requests {
    /// How long a briefing is given again rather than written anew, in seconds.
    static let briefKept: TimeInterval = 120

    func brief(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server keeps no leads"))) }
        let folder = request.args?["folder"]?.string
        if let folder, !folder.hasPrefix("/") { return reply(.init(re: request.id, error: .init(.badArgs, "folder is an absolute path"))) }
        let (find, queue) = (repositoryOf, self.queue)
        let now = engine.briefNow()
        let scope = folder.map(find) ?? ""
        if let kept = engine.briefs[scope], now.timeIntervalSince1970 - kept.at < Self.briefKept {
            return reply(.init(re: request.id, result: Self.briefValue(kept.text, asks: kept.asks, kept: true)))
        }
        // What the engine knows now, on its queue; the logs read and the model asked off it.
        let leads = engine.leads.leads.values.map(\.root).sorted()
        let roots = folder == nil ? leads : [scope]
        let boards = engine.boards
        let sessions = self.sessions?.sessions ?? []
        let cards = engine.cards.list(project: nil)
        let model = engine.summariesAllowed ? engine.briefModel : nil
        let last = engine.briefed[scope]
        engine.work.async {
            let sources = roots.map { root in
                Briefing.Source(name: LeadMail.project(of: root), progress: NodeBrief.progress(root: root), board: boards[root] ?? BoardStore(root: root).load())
            }
            let names = Set(sources.map(\.name))
            let mine = folder == nil ? sessions : sessions.filter { names.contains($0.project) }
            var input = folder == nil
                ? Briefing.compose(sources, sessions: mine, lastBriefed: last, now: now.timeIntervalSince1970)
                : Briefing.compose(project: sources[0], sessions: mine, lastBriefed: last, now: now.timeIntervalSince1970)
            if folder != nil { input.project = input.projects.first?.name }
            let extra = NodeBrief.extra(boards: sources.map { ($0.name, $0.board) }, cards: cards, roots: Set(roots), now: now)
            let text = NodeBrief.write(input, extra: extra, generate: model, now: now.timeIntervalSince1970)
            let asks = input.projects.reduce(0) { $0 + $1.questionCount } + input.waitingCount + extra.otherCards
            queue.async {
                engine.briefed[scope] = now.timeIntervalSince1970
                engine.briefs[scope] = (text, asks, now.timeIntervalSince1970)
                reply(.init(re: request.id, result: Self.briefValue(text, asks: asks, kept: false)))
            }
        }
    }

    /// As the wire carries it (`WireSchema`'s `brief.result`): the briefing's words, by the model or the template, when,
    /// what it says when it isn't the model's, how many things wait on you, and whether it was given again.
    static func briefValue(_ text: BriefingText, asks: Int, kept: Bool) -> NodeWire.Value {
        briefValue(text: text.text, byModel: text.byModel, language: text.language.code, at: text.at, notice: text.notice, asks: asks, kept: kept)
    }

    static func briefValue(text: String, byModel: Bool, language: String, at: Double, notice: String?, asks: Int, kept: Bool) -> NodeWire.Value {
        .object(["text": .string(text), "byModel": .bool(byModel), "language": .string(language), "at": .date(Date(timeIntervalSince1970: at)),
                 "notice": notice.map(NodeWire.Value.string) ?? .null, "asks": .int(asks), "kept": .bool(kept)])
    }
}

/// What a node adds to the app's briefing, and how it writes one.
public enum NodeBrief {
    /// The most bytes of a progress log read (its newest entries are at the end).
    static let progressBytes = 2 << 20

    /// `root`'s progress log, read below the root with no link followed (`Platform.Files.readRegular`, as the board's
    /// records are), its last `progressBytes`; nil when there is none or it can't be read so.
    static func progress(root: String) -> String? {
        let recordsDir = BoardRecords.read(root: root).recordsDir
        guard case .data(let data) = Platform.Files.readRegular(in: root, path: BoardRecords.path(of: "progress.md", recordsDir: recordsDir),
                                                                  limit: progressBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Redacted, on one line, at most `Briefing.entryLimit` characters (the app's `Briefing.clean`).
    static func clean(_ text: String) -> String {
        let line = Redaction.secrets(in: text).split(whereSeparator: \.isNewline).joined(separator: " ")
        return Summarizer.clip(line.trimmingCharacters(in: .whitespaces), Briefing.entryLimit)
    }

    /// What the app's composer doesn't carry: the cards waiting on you beyond questions, and each board's all-done
    /// mark of the last day, as notes for the model and sentences for the template.
    public struct Extra: Equatable, Sendable {
        public var notes: [String] = []
        public var sentences: [String] = []
        public var otherCards = 0
    }

    static func extra(boards: [(name: String, board: LeadBoard)], cards: [CardStore.Card], roots: Set<String>, now: Date) -> Extra {
        var extra = Extra()
        for (name, board) in boards {
            guard let mark = board.allDone?.last, now.timeIntervalSince1970 - mark.at < LeadEngine.allDoneShown else { continue }
            let what = mark.summary.map { NodeBrief.clean($0.headline) } ?? "\(mark.merged) of \(mark.tasks.count) tasks merged"
            extra.notes.append("\(NodeBrief.clean(name)): all its tasks finished; \(what).")
            extra.sentences.append("\(NodeBrief.clean(name)) finished all its tasks: \(what).")
        }
        let others = cards.filter { card in card.kind != .question && roots.contains(card.root) }
        extra.otherCards = others.count
        if !others.isEmpty {
            let kinds = others.map { card -> String in
                switch card.kind {
                case .approval: return "a merge to approve"
                case .configHeld: return "held config to look at"
                case .baseMove: return "a moved base to accept or keep"
                case .shell: return "a shell an agent asks to open"
                // A feature plugin's: what one is called (`PluginCard.noun`), as its plugin says it.
                case .plugin: return "a " + NodeBrief.clean(card.plugin?.noun ?? "request from an agent")
                case .question: return "a question"
                }
            }
            let said = Array(Set(kinds)).sorted().joined(separator: ", ")
            extra.notes.append("Also waiting on the user: \(said).")
            extra.sentences.append("Also waiting on you: \(said).")
        }
        return extra
    }

    /// The briefing: the model's (`generate`, blocking) from the app's prompt with `extra`'s notes, else the app's
    /// template with `extra`'s sentences. In English: a node has no language setting yet.
    static func write(_ input: BriefingInput, extra: Extra, generate: Summarizer.Generate?, now: Double) -> BriefingText {
        var text = Briefing.write(input, language: .english, generate: { prompt in
            guard let generate else { return nil }
            return generate(prompt + (extra.notes.isEmpty ? "" : "\n" + extra.notes.joined(separator: "\n")))
        }, now: now)
        if !text.byModel {
            // No model asked: the written briefing says so only when the model was meant to write it.
            text.notice = generate == nil ? nil : text.notice
            if !extra.sentences.isEmpty {
                let base = text.text.hasPrefix("No project lead is running and no session needs you") ? "" : text.text + " "
                text.text = base + extra.sentences.joined(separator: " ")
            }
        }
        return text
    }
}

/// `vibeswitcher brief`'s text: the briefing's words (inert), what waits on you, and who wrote it.
public enum BriefCommandLines {
    public static func lines(_ result: NodeWire.Value) -> [String] {
        let asks = result["asks"]?.int ?? 0
        var out = [ConfigSeal.inert(result["text"]?.string ?? "", limit: 4_000)]
        out.append(asks == 0 ? "Nothing waits on you."
            : "\(asks) thing\(asks == 1 ? "" : "s") wait\(asks == 1 ? "s" : "") on you: `vibeswitcher questions` lists the cards.")
        if let notice = result["notice"]?.string { out.append(ConfigSeal.inert(notice, limit: 300)) }
        out.append(result["byModel"]?.bool == true ? "(written by Claude Haiku from the boards and logs)" : "(written from the boards and logs, no model asked)")
        return out
    }
}
