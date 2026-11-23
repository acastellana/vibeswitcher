import Foundation

/// Every request kind, declared once (the architecture review's row 1): its name, who may send it, whether it changes
/// state, what serves it, and its typed arguments and result. The server's lists are views of this table, not lists of
/// their own: who may send a kind (`NodeWire.kinds`), the user's-voice kinds that change nothing (`changesNothing`,
/// `changesState`), the kinds this server takes (`NodeWire.taken`), the live hub's (`LiveHub.kinds`), the terminal's
/// (`NodeLive.terminalKinds`), the typed kinds the command line asks and sends (`WireKinds.typed`, `changes`,
/// `leftOut`), and the kinds table of docs/guide/v2-architecture.md (`KindsTable`). A kind is one entry here, and an
/// entry with a field left out doesn't compile (`KindSpec.init` has no defaults).
///
/// The table's order is the order the server lists kinds in (`NodeWire.taken`, a page's `hello.kinds`).
public struct KindSpec: Sendable {
    /// What a kind does, as the voice rule counts it (EN-D5: a user's-voice kind that changes state needs its typed
    /// word; a page's that does is a draft or a terminal's).
    public enum Effect: Sendable, Equatable {
        /// Changes nothing a person decides on: a read, or a user's-voice request that only makes the card or the list
        /// the next request takes.
        case read
        /// Changes state.
        case change
        /// A lead's tool server's post of its own question (sealed by the host as the lead's, EN-D10): it changes the
        /// cards, but under the post's seal, not the user's voice; `changesState` is false for it, as it always was.
        case toolPost
    }

    /// What answers a kind: `Requests` (its `act`, `questionPost` or `draft`, by who sends it), the live hub, or the
    /// terminal relay (a page's, on a server that opens terminals).
    public enum Server: Sendable, Equatable {
        case requests
        case hub
        case terminalRelay
    }

    /// A kind's typed arguments and result (`WireKind`), or why it has none here: a shape a page or a tool server sends,
    /// which `WireSchema` checks (`page`), or a kind the command line uses that isn't typed yet (`notYet`).
    public enum Wire: Sendable {
        case typed(any WireKind.Type)
        case page(String)
        case notYet(String)
    }

    public let name: String
    public let sender: NodeWire.Voice
    public let effect: Effect
    public let servedBy: Server
    public let wire: Wire

    /// Every field required: a kind can't be added with one left to a default.
    public init(_ name: String, sender: NodeWire.Voice, effect: Effect, servedBy: Server, wire: Wire) {
        self.name = name
        self.sender = sender
        self.effect = effect
        self.servedBy = servedBy
        self.wire = wire
    }

    /// Its wire type, when it has one.
    public var typed: (any WireKind.Type)? { if case .typed(let type) = wire { return type } else { return nil } }

    /// Whether it changes state (`NodeWire.changesState`).
    public var changesState: Bool { effect == .change }

    private static let page = Wire.page("a page's: WireSchema checks it")
    private static let pageRead = Wire.page("a page's read: WireSchema checks it")
    private static let live = Wire.page("the live protocol's (the live wire contract): WireSchema checks it")
    private static let post = Wire.page("the lead's tool server's post (QuestionPost)")
    private static let plugins = Wire.notYet("the external plugins' (the plugins lane's, to follow the pattern)")

    /// The table.
    public static let all: [KindSpec] = [
        KindSpec("status", sender: .anyone, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Status.self)),
        KindSpec("start", sender: .user, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Start.self)),
        KindSpec("stop", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Stop.self)),
        KindSpec("lead", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Lead.self)),
        KindSpec("questions", sender: .anyone, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Questions.self)),
        KindSpec("draft", sender: .webDraft, effect: .change, servedBy: .requests, wire: page),
        KindSpec("draft.clear", sender: .webDraft, effect: .change, servedBy: .requests, wire: page),
        KindSpec("answer", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Answer.self)),
        KindSpec("hold", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Hold.self)),
        KindSpec("config.held", sender: .user, effect: .read, servedBy: .requests, wire: .typed(WireKinds.ConfigHeld.self)),
        KindSpec("config.accept", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.ConfigAccept.self)),
        KindSpec("base.show", sender: .user, effect: .read, servedBy: .requests, wire: .typed(WireKinds.BaseShow.self)),
        KindSpec("base.accept", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.BaseAccept.self)),
        KindSpec("base.keep", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.BaseKeep.self)),
        KindSpec("question.post", sender: .leadToolServer, effect: .toolPost, servedBy: .requests, wire: post),
        KindSpec("question.revise", sender: .leadToolServer, effect: .toolPost, servedBy: .requests, wire: post),
        KindSpec("question.withdraw", sender: .leadToolServer, effect: .toolPost, servedBy: .requests, wire: post),
        KindSpec("hooks.install", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.HooksInstall.self)),
        KindSpec("hooks.remove", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.HooksRemove.self)),
        KindSpec("build.switch", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.BuildSwitch.self)),
        KindSpec("subscribe", sender: .anyone, effect: .read, servedBy: .hub, wire: live),
        KindSpec("unsubscribe", sender: .anyone, effect: .read, servedBy: .hub, wire: live),
        KindSpec("web.open", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.WebOpen.self)),
        KindSpec("web.revoke", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.WebRevoke.self)),
        KindSpec("chat.page", sender: .anyone, effect: .read, servedBy: .hub, wire: live),
        KindSpec("tell", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Tell.self)),
        KindSpec("board", sender: .anyone, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Board.self)),
        // A finished session seen (the parity gaps of 2026-11-19): it changes nothing but the seen mark, so no voice.
        KindSpec("seen", sender: .anyone, effect: .read, servedBy: .requests, wire: pageRead),
        KindSpec("send", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Send.self)),
        KindSpec("session.new", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SessionNew.self)),
        KindSpec("session.end", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SessionEnd.self)),
        KindSpec("session.reply", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SessionReply.self)),
        KindSpec("session.draft", sender: .webDraft, effect: .change, servedBy: .requests, wire: page),
        KindSpec("session.draft.clear", sender: .webDraft, effect: .change, servedBy: .requests, wire: page),
        KindSpec("session.presets", sender: .anyone, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Presets.self)),
        KindSpec("session.complete", sender: .anyone, effect: .read, servedBy: .requests, wire: pageRead),
        KindSpec("session.attach", sender: .webDraft, effect: .change, servedBy: .requests, wire: page),
        KindSpec("session.usage", sender: .anyone, effect: .read, servedBy: .hub, wire: live),
        KindSpec("chat.image", sender: .anyone, effect: .read, servedBy: .hub, wire: live),
        KindSpec("stats", sender: .anyone, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Stats.self)),
        KindSpec("session.ports", sender: .anyone, effect: .read, servedBy: .requests, wire: pageRead),
        KindSpec("board.task", sender: .anyone, effect: .read, servedBy: .requests, wire: pageRead),
        KindSpec("board.image", sender: .anyone, effect: .read, servedBy: .requests, wire: pageRead),
        KindSpec("settings", sender: .anyone, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Settings.self)),
        KindSpec("set", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SetSetting.self)),
        KindSpec("push", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Push.self)),
        KindSpec("push.decline", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.PushDecline.self)),
        KindSpec("session.reopen", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SessionReopen.self)),
        // Between leads: a read, but the projects' private record of their leads' messages, so never a session's.
        KindSpec("mail", sender: .webRead, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Mail.self)),
        KindSpec("prompt-audit", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.PromptAudit.self)),
        KindSpec("session.rename", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SessionRename.self)),
        KindSpec("session.pause", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SessionPause.self)),
        KindSpec("session.resume", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SessionResume.self)),
        KindSpec("shells", sender: .user, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Shells.self)),
        KindSpec("session.close-shells", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.CloseShells.self)),
        KindSpec("presets.edit", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.PresetsEdit.self)),
        // The folders Claude Code and Codex know, the user's other projects among them: never a session's.
        KindSpec("recent", sender: .webRead, effect: .read, servedBy: .requests, wire: pageRead),
        // Brief me: a read of the user's own, which may ask the summaries' model: never a session's.
        KindSpec("brief", sender: .webRead, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Brief.self)),
        // Check for Updates now: it asks GitHub and keeps only its answer; the user's, never a session's or a page's.
        KindSpec("update.check", sender: .user, effect: .read, servedBy: .requests, wire: .typed(WireKinds.UpdateCheck.self)),
        KindSpec("approve.list", sender: .user, effect: .read, servedBy: .requests, wire: .typed(WireKinds.ApproveList.self)),
        KindSpec("approve", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Approve.self)),
        KindSpec("plugin.list", sender: .anyone, effect: .read, servedBy: .requests, wire: .typed(WireKinds.PluginList.self)),
        KindSpec("plugin.on", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.PluginOn.self)),
        KindSpec("plugin.off", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.PluginOff.self)),
        // External plugins: what an add shows a read of the user's; add and remove the user's voice; an agent's vs-ask
        // files through its tool server (the host stamps it there), never a page (`WebAccess` refuses it by name).
        KindSpec("plugin.inspect", sender: .user, effect: .read, servedBy: .requests, wire: plugins),
        KindSpec("plugin.add", sender: .user, effect: .change, servedBy: .requests, wire: plugins),
        KindSpec("plugin.remove", sender: .user, effect: .change, servedBy: .requests, wire: plugins),
        KindSpec("plugin.file", sender: .anyone, effect: .read, servedBy: .requests, wire: plugins),
        // A page's terminal: watched on the user's node, typed into on a scratch node only (LW-D12).
        KindSpec("term.open", sender: .webTerminal, effect: .change, servedBy: .terminalRelay, wire: page),
        KindSpec("term.close", sender: .webTerminal, effect: .change, servedBy: .terminalRelay, wire: page),
    ]

    /// The table by name.
    public static let byName: [String: KindSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func spec(_ name: String) -> KindSpec? { byName[name] }
}
