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

    /// Whether the vault records a kind before it acts (EN-D11: every state-changing user's-voice kind, and `start`),
    /// and if so all that goes with it; a kind that isn't recorded may still have a phrase for the Mac's dialog (a read
    /// in the user's voice, which asks no dialog).
    public enum Voiced: Sendable {
        case notRecorded(phrase: String?)
        case recorded(Recorded)
    }

    /// What a recorded kind declares: every field required (`Recorded.init` has no defaults).
    public struct Recorded: Sendable {
        /// The keys it takes (`RequestArguments` refuses any other, naming it): its typed arguments' (`WireArgs.keys`), or
        /// listed for a kind not typed yet.
        public enum Arguments: Sendable {
            case ofType
            case keys(Set<String>)
        }

        /// The keys the Mac's approval dialog takes (`Requests.approvalArguments`): the kind's arguments, some left out
        /// (one only `approve`'s batch sets) or one more (asked for the dialog's text).
        public enum Dialog: Sendable {
            case asArguments
            case argumentsWithout(Set<String>)
            case argumentsWith(Set<String>)
        }

        public let arguments: Arguments
        /// Its retry (`Requests.RetryRule`): whether the vault's record keeps its result for a retry (none with a secret
        /// in it), and whether a retry begun with no outcome is done again (only what leaves things as one does).
        public let keepsResult: Bool
        public let rerun: Bool
        /// It acts on a card, whose code (EN-D5), typed by the user, is checked first.
        public let carded: Bool
        /// It may be an item of `approve`'s batch (one code for several plain accepts).
        public let batch: Bool
        /// What it does, after "<program> is trying to " in the Mac's dialog (`ApprovalVoice.action`).
        public let phrase: String
        public let dialog: Dialog

        public init(arguments: Arguments, keepsResult: Bool, rerun: Bool, carded: Bool, batch: Bool, phrase: String, dialog: Dialog) {
            self.arguments = arguments
            self.keepsResult = keepsResult
            self.rerun = rerun
            self.carded = carded
            self.batch = batch
            self.phrase = phrase
            self.dialog = dialog
        }
    }

    public let name: String
    public let sender: NodeWire.Voice
    public let effect: Effect
    public let servedBy: Server
    public let wire: Wire
    public let voiced: Voiced

    /// Every field required: a kind can't be added with one left to a default.
    public init(_ name: String, sender: NodeWire.Voice, effect: Effect, servedBy: Server, wire: Wire, voiced: Voiced) {
        self.name = name
        self.sender = sender
        self.effect = effect
        self.servedBy = servedBy
        self.wire = wire
        self.voiced = voiced
    }

    /// Its record's declaration, when it is recorded.
    public var recorded: Recorded? { if case .recorded(let recorded) = voiced { return recorded } else { return nil } }

    /// Its phrase for the Mac's dialog, when it has one.
    public var phrase: String? {
        switch voiced {
        case .recorded(let recorded): return recorded.phrase
        case .notRecorded(let phrase): return phrase
        }
    }

    /// The keys a recorded kind takes; nil for one that isn't recorded (a read's arguments aren't checked so).
    public var arguments: Set<String>? {
        guard let recorded else { return nil }
        switch recorded.arguments {
        case .keys(let keys): return keys
        case .ofType:
            guard let type = typed as? any WireChangeKind.Type else { return [] }
            return Self.keys(of: type)
        }
    }

    private static func keys<K: WireChangeKind>(of _: K.Type) -> Set<String> { K.Args.keys }

    /// The keys the Mac's dialog takes for it; nil for one with no dialog.
    public var dialogArguments: Set<String>? {
        guard let recorded, let arguments else { return nil }
        switch recorded.dialog {
        case .asArguments: return arguments
        case .argumentsWithout(let without): return arguments.subtracting(without)
        case .argumentsWith(let more): return arguments.union(more)
        }
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
        KindSpec("status", sender: .anyone, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Status.self),
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("start", sender: .user, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Start.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: true, carded: false, batch: false, phrase: "start your VibeSwitcher node", dialog: .asArguments))),
        KindSpec("stop", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Stop.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: false, batch: false, phrase: "stop your VibeSwitcher node", dialog: .asArguments))),
        KindSpec("lead", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Lead.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: false, batch: false, phrase: "start a project's lead for you", dialog: .asArguments))),
        KindSpec("questions", sender: .anyone, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Questions.self),
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("draft", sender: .webDraft, effect: .change, servedBy: .requests, wire: page,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("draft.clear", sender: .webDraft, effect: .change, servedBy: .requests, wire: page,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("answer", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Answer.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: true, batch: false, phrase: "answer a lead's question for you", dialog: .asArguments))),
        KindSpec("hold", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Hold.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: true, batch: false, phrase: "hold a lead's question for you", dialog: .asArguments))),
        KindSpec("config.held", sender: .user, effect: .read, servedBy: .requests, wire: .typed(WireKinds.ConfigHeld.self),
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("config.accept", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.ConfigAccept.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: true, batch: true, phrase: "accept a change to a watched file", dialog: .argumentsWithout(["batch"])))),
        KindSpec("base.show", sender: .user, effect: .read, servedBy: .requests, wire: .typed(WireKinds.BaseShow.self),
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("base.accept", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.BaseAccept.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: true, batch: true, phrase: "accept a moved base branch", dialog: .asArguments))),
        KindSpec("base.keep", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.BaseKeep.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: true, batch: false, phrase: "keep a base branch where it was", dialog: .asArguments))),
        KindSpec("question.post", sender: .leadToolServer, effect: .toolPost, servedBy: .requests, wire: post,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("question.revise", sender: .leadToolServer, effect: .toolPost, servedBy: .requests, wire: post,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("question.withdraw", sender: .leadToolServer, effect: .toolPost, servedBy: .requests, wire: post,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("hooks.install", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.HooksInstall.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: true, carded: false, batch: true, phrase: "install VibeSwitcher's hooks", dialog: .asArguments))),
        KindSpec("hooks.remove", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.HooksRemove.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: true, carded: false, batch: false, phrase: "remove VibeSwitcher's hooks", dialog: .asArguments))),
        KindSpec("build.switch", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.BuildSwitch.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: false, batch: false, phrase: "switch your node to another build", dialog: .asArguments))),
        KindSpec("subscribe", sender: .anyone, effect: .read, servedBy: .hub, wire: live,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("unsubscribe", sender: .anyone, effect: .read, servedBy: .hub, wire: live,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("web.open", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.WebOpen.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: false, rerun: false, carded: false, batch: false, phrase: "open the web page to a device", dialog: .asArguments))),
        KindSpec("web.revoke", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.WebRevoke.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: true, carded: false, batch: false, phrase: "revoke a device's web access", dialog: .asArguments))),
        KindSpec("chat.page", sender: .anyone, effect: .read, servedBy: .hub, wire: live,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("tell", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Tell.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: false, batch: false, phrase: "tell a lead something for you", dialog: .asArguments))),
        KindSpec("board", sender: .anyone, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Board.self),
                 voiced: .notRecorded(phrase: nil)),
        // A finished session seen (the parity gaps of 2026-11-19): it changes nothing but the seen mark, so no voice.
        KindSpec("seen", sender: .anyone, effect: .read, servedBy: .requests, wire: pageRead,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("send", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Send.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: false, batch: false, phrase: "type into a session for you", dialog: .asArguments))),
        KindSpec("session.new", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SessionNew.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: false, batch: false, phrase: "start a session for you", dialog: .argumentsWith(["values"])))),
        KindSpec("session.end", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SessionEnd.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: true, carded: false, batch: false, phrase: "end a session", dialog: .asArguments))),
        KindSpec("session.reply", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SessionReply.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: false, batch: false, phrase: "answer a session's question for you", dialog: .asArguments))),
        KindSpec("session.draft", sender: .webDraft, effect: .change, servedBy: .requests, wire: page,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("session.draft.clear", sender: .webDraft, effect: .change, servedBy: .requests, wire: page,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("session.presets", sender: .anyone, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Presets.self),
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("session.complete", sender: .anyone, effect: .read, servedBy: .requests, wire: pageRead,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("session.attach", sender: .webDraft, effect: .change, servedBy: .requests, wire: page,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("session.usage", sender: .anyone, effect: .read, servedBy: .hub, wire: live,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("chat.image", sender: .anyone, effect: .read, servedBy: .hub, wire: live,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("stats", sender: .anyone, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Stats.self),
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("session.ports", sender: .anyone, effect: .read, servedBy: .requests, wire: pageRead,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("board.task", sender: .anyone, effect: .read, servedBy: .requests, wire: pageRead,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("board.image", sender: .anyone, effect: .read, servedBy: .requests, wire: pageRead,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("settings", sender: .anyone, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Settings.self),
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("set", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SetSetting.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: true, carded: false, batch: false, phrase: "change a VibeSwitcher setting", dialog: .asArguments))),
        KindSpec("push", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Push.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: false, batch: false, phrase: "push a lead's branch for you", dialog: .asArguments))),
        KindSpec("push.decline", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.PushDecline.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: true, carded: false, batch: false, phrase: "decline a lead's push", dialog: .asArguments))),
        KindSpec("session.reopen", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SessionReopen.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: false, batch: false, phrase: "reopen your sessions after a restart", dialog: .asArguments))),
        // Between leads: a read, but the projects' private record of their leads' messages, so never a session's.
        KindSpec("mail", sender: .webRead, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Mail.self),
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("prompt-audit", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.PromptAudit.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: true, carded: false, batch: false, phrase: "change a project's prompt-audit reminder", dialog: .asArguments))),
        KindSpec("session.rename", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SessionRename.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: true, carded: false, batch: false, phrase: "rename a session", dialog: .asArguments))),
        KindSpec("session.pause", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SessionPause.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: true, carded: false, batch: false, phrase: "pause a session's reminders", dialog: .asArguments))),
        KindSpec("session.resume", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.SessionResume.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: true, carded: false, batch: false, phrase: "resume an ended session", dialog: .asArguments))),
        KindSpec("shells", sender: .user, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Shells.self),
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("session.close-shells", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.CloseShells.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: true, carded: false, batch: false, phrase: "close finished shells", dialog: .argumentsWith(["folder"])))),
        KindSpec("presets.edit", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.PresetsEdit.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: false, batch: false, phrase: "edit your launch presets", dialog: .asArguments))),
        // The folders Claude Code and Codex know, the user's other projects among them: never a session's.
        KindSpec("recent", sender: .webRead, effect: .read, servedBy: .requests, wire: pageRead,
                 voiced: .notRecorded(phrase: nil)),
        // Brief me: a read of the user's own, which may ask the summaries' model: never a session's.
        KindSpec("brief", sender: .webRead, effect: .read, servedBy: .requests, wire: .typed(WireKinds.Brief.self),
                 voiced: .notRecorded(phrase: nil)),
        // Check for Updates now: it asks GitHub and keeps only its answer; the user's, never a session's or a page's.
        KindSpec("update.check", sender: .user, effect: .read, servedBy: .requests, wire: .typed(WireKinds.UpdateCheck.self),
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("approve.list", sender: .user, effect: .read, servedBy: .requests, wire: .typed(WireKinds.ApproveList.self),
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("approve", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.Approve.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: false, carded: false, batch: false, phrase: "accept the batch you listed", dialog: .asArguments))),
        KindSpec("plugin.list", sender: .anyone, effect: .read, servedBy: .requests, wire: .typed(WireKinds.PluginList.self),
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("plugin.on", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.PluginOn.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: true, carded: false, batch: false, phrase: "turn a plugin on for this node", dialog: .asArguments))),
        KindSpec("plugin.off", sender: .user, effect: .change, servedBy: .requests, wire: .typed(WireKinds.PluginOff.self),
                 voiced: .recorded(.init(arguments: .ofType, keepsResult: true, rerun: true, carded: false, batch: false, phrase: "turn a plugin off for this node", dialog: .asArguments))),
        // External plugins: what an add shows a read of the user's; add and remove the user's voice; an agent's vs-ask
        // files through its tool server (the host stamps it there), never a page (`WebAccess` refuses it by name).
        KindSpec("plugin.inspect", sender: .user, effect: .read, servedBy: .requests, wire: plugins,
                 voiced: .notRecorded(phrase: "read a plugin's folder")),
        KindSpec("plugin.add", sender: .user, effect: .change, servedBy: .requests, wire: plugins,
                 voiced: .recorded(.init(arguments: .keys(["folder", "manifest", "program"]), keepsResult: true, rerun: false, carded: false, batch: false, phrase: "add a program as a plugin of this node", dialog: .asArguments))),
        KindSpec("plugin.remove", sender: .user, effect: .change, servedBy: .requests, wire: plugins,
                 voiced: .recorded(.init(arguments: .keys(["plugin"]), keepsResult: true, rerun: true, carded: false, batch: false, phrase: "remove a plugin from this node", dialog: .asArguments))),
        KindSpec("plugin.file", sender: .anyone, effect: .read, servedBy: .requests, wire: plugins,
                 voiced: .notRecorded(phrase: nil)),
        // A page's terminal: watched on the user's node, typed into on a scratch node only (LW-D12).
        KindSpec("term.open", sender: .webTerminal, effect: .change, servedBy: .terminalRelay, wire: page,
                 voiced: .notRecorded(phrase: nil)),
        KindSpec("term.close", sender: .webTerminal, effect: .change, servedBy: .terminalRelay, wire: page,
                 voiced: .notRecorded(phrase: nil)),
    ]

    /// The table by name.
    public static let byName: [String: KindSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func spec(_ name: String) -> KindSpec? { byName[name] }
}
