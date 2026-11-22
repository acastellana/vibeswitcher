import Foundation
import VibeCore

/// The live wire's shapes as data (the live plan's LW-D10 and E1, lane E's file): each entity and message the live wire
/// contract (docs/superpowers/specs/2026-11-17-v2-live-wire-contract.md) specifies, field by field, with its type and
/// whether it may be absent. `WireVectorsTests` holds it to what the encoders write (`CardStore.Card.value`,
/// `LeadStore.Lead.value`, `NodeWire`'s messages), both ways; `WireVectors` writes it out as the web client's
/// `WebApp/wire/validators.js`, whose `validate` follows `check` here rule for rule.
///
/// Rule 3 throughout: a field the schema doesn't name passes (but for `check`'s `strict`, which the encoders are held
/// to), and a word a list of words doesn't name passes as any string does (a status the client doesn't know shows as
/// `unknown`; a right it doesn't know is ignored); a union's case it doesn't know passes too.
public enum WireSchema {
    /// A field's type. `words` is a string whose known values are listed (for the reader; any string passes).
    public indirect enum Kind: Equatable, Sendable {
        case string, int, bool, date, any
        case words([String])
        case list(Kind)
        /// An object whose keys are data (`verdicts`, `applied`), each value of the type.
        case map(Kind)
        case shape(String)
        case nullable(Kind)

        /// This type, or null.
        public var orNull: Kind { .nullable(self) }
    }

    public struct Field: Equatable, Sendable {
        public var name: String
        public var type: Kind
        /// It may be absent (the contract's "optional"). A field that may be null is `nullable` instead: always there.
        public var optional: Bool
        /// Who writes it, when not the shape's own encoder (yet): such a field isn't asked of that encoder, and its
        /// samples needn't show it. Nil: the encoder writes it.
        public var pending: String?
    }

    public struct Shape: Equatable, Sendable {
        public var name: String
        public var fields: [Field]
        /// A union instead of fields: the field that tells the case, and each case's shape. A case not listed passes.
        public var union: (tag: String, cases: [String: String])?
        /// What writes it.
        public var from: String

        public static func == (a: Shape, b: Shape) -> Bool {
            a.name == b.name && a.fields == b.fields && a.union?.tag == b.union?.tag && a.union?.cases == b.union?.cases && a.from == b.from
        }
    }

    /// Whether a field was there, absent or null, as `check` reports each it looks at.
    public enum Seen: String, Sendable { case present, absent, null }

    // MARK: The table

    /// The entities: one per keyed collection's value, and a chat's item.
    public static let entities = ["node", "session", "lead", "card", "chat.item", "board"]
    /// The messages: the envelopes, and each live kind's `args` and `result` (`<kind>.args`, `<kind>.result`).
    public static let messages = ["request", "reply", "failure", "hello", "bye", "event", "snapshot", "delta", "auth.args",
                                  "subscribe.args", "subscribe.result", "unsubscribe.args", "chat.page.args", "chat.page.result",
                                  "draft.args", "draft.result", "draft.clear.args",
                                  "board.args", "board.result", "seen.args",
                                  "session.draft.args", "session.draft.result", "session.draft.clear.args",
                                  "session.presets.args", "session.presets.result", "session.complete.args", "session.complete.result",
                                  "session.attach.args", "session.attach.result", "session.usage.args", "session.usage.result",
                                  "chat.image.args", "chat.image.result", "stats.args", "stats.result", "session.ports.args", "session.ports.result",
                                  "board.task.args", "board.task.result", "board.image.args", "board.image.result",

                                  "settings.args", "settings.result", "set.args", "set.result", "mail.args", "mail.result", "recent.args", "recent.result", "brief.args", "brief.result"]
    /// A keyed collection's entity.
    public static let collections = ["node": "node", "sessions": "session", "leads": "lead", "cards": "card", "boards": "board"]

    /// Every shape by name, the parts of entities and messages among them.
    public static let shapes: [String: Shape] = Dictionary(uniqueKeysWithValues: table.map { ($0.name, $0) })

    private static func field(_ name: String, _ type: Kind) -> Field { Field(name: name, type: type, optional: false, pending: nil) }
    private static func optional(_ name: String, _ type: Kind) -> Field { Field(name: name, type: type, optional: true, pending: nil) }
    private static func shape(_ name: String, from: String, _ fields: [Field]) -> Shape { Shape(name: name, fields: fields, union: nil, from: from) }
    private static func union(_ name: String, from: String, tag: String, _ cases: [String: String]) -> Shape {
        Shape(name: name, fields: [], union: (tag, cases), from: from)
    }

    private static let contractNode = "the contract's §5 until B2's NodeStatusStore"
    private static let contractSession = "the contract's §5 until B2's Session.liveValue"
    private static let contractChat = "ChatValue"
    private static let contractLive = "the contract's §3 and §4 until B1's LiveStream"

    private static let table: [Shape] = {
        let strings = Kind.list(.string)
        var shapes: [Shape] = []

        // Messages (NodeWire's, the contract's §1, §2 and §10).
        shapes += [
            shape("request", from: "NodeWire.Request", [field("v", .int), field("id", .string), field("kind", .string),
                                                        optional("args", .map(.any)), optional("action", .string), optional("must", .bool)]),
            shape("reply", from: "NodeWire.Reply", [field("v", .int), field("re", .string), field("ok", .bool), optional("result", .any),
                                                    optional("error", .shape("failure"))]),
            shape("failure", from: "NodeWire.Failure", [field("code", .words(NodeWire.Code.allCases.map(\.rawValue))), field("message", .string)]),
            shape("hello", from: "NodeWire.Hello", [
                field("v", .int), field("kind", .words(["hello"])), field("node", .string), field("epoch", .string),
                field("server", .shape("hello.server")), field("host", .shape("hello.host")), field("kinds", strings),
                field("peer", .shape("hello.peer")), field("rule", .words(["systemd", "weaker", "closed", "approval"])),
                optional("auth", .shape("hello.auth")), optional("assets", .string), optional("plugins", .list(.shape("hello.plugin")))]),
            // The feature plugins that are on (`PluginRegistry.onValue`, 2026-11-22).
            shape("hello.plugin", from: "PluginRegistry.onValue", [field("id", .string), field("title", .string)]),
            shape("hello.server", from: "NodeWire.Hello.Server", [field("commit", .string), field("startedAt", .date), field("pid", .int)]),
            shape("hello.host", from: "NodeWire.Hello.Host", [optional("startedAt", .date), optional("notes", .shape("host.notes")),
                                                             optional("pid", .int)]),
            shape("hello.peer", from: "NodeWire.Hello.Peer", [field("voice", .words(["user", "other"])), optional("why", .string)]),
            shape("hello.auth", from: "the web gate (F1)", [field("rights", .list(.words(["read", "draft"]))), optional("token", .string),
                                                           field("expiresAt", .date)]),
            shape("bye", from: "NodeWire.Bye", [field("v", .int), field("kind", .words(["bye"])), field("reason", .string),
                                                optional("code", .words(["auth", "revoked", "version", "too-long", "not-object",
                                                                         "not-request", "must", "stopping"]))]),
            shape("event", from: "any event a client doesn't know", [field("v", .int), field("kind", .string), optional("must", .bool)]),
        ]

        // The live protocol's events and kinds (the contract's §3, §4, §6 and §8).
        let collection = Kind.words(["node", "sessions", "leads", "cards", "chat", "boards"])
        shapes += [
            shape("snapshot", from: contractLive, [
                field("v", .int), field("kind", .words(["snapshot"])), field("sub", .string), field("collection", collection),
                optional("key", .string), field("epoch", .string), field("seq", .int), optional("entries", .list(.shape("entry"))),
                optional("after", Kind.string.orNull), optional("more", .bool), optional("items", .list(.shape("chat.item")))]),
            shape("entry", from: contractLive, [field("id", .string), field("value", .any)]),
            shape("delta", from: contractLive, [
                field("v", .int), field("kind", .words(["delta"])), field("sub", .string), field("prev", .int), field("seq", .int),
                field("at", .date), optional("changes", .list(.shape("change"))), optional("ops", .list(.shape("chat.op")))]),
            shape("change", from: contractLive, [field("id", .string), field("value", Kind.any.orNull)]),
            union("chat.op", from: contractChat, tag: "op",
                  ["add": "chat.op.add", "text": "chat.op.text", "set": "chat.op.set", "remove": "chat.op.remove"]),
            shape("chat.op.add", from: contractChat, [field("op", .words(["add"])), field("item", .shape("chat.item"))]),
            shape("chat.op.text", from: contractChat, [field("op", .words(["text"])), field("id", .string), field("at", .int),
                                                      field("append", .string)]),
            shape("chat.op.set", from: contractChat, [field("op", .words(["set"])), field("item", .shape("chat.item"))]),
            shape("chat.op.remove", from: contractChat, [field("op", .words(["remove"])), field("id", .string)]),
            shape("auth.args", from: "the contract's §2", [optional("pair", .string), optional("token", .string), field("client", .string),
                                                          optional("assets", .string)]),
            shape("subscribe.args", from: "the contract's §3", [
                field("sub", .string), field("collection", collection), optional("key", .string),
                optional("since", .shape("subscribe.since")), optional("after", Kind.string.orNull), optional("limit", .int)]),
            shape("subscribe.since", from: "the contract's §3", [field("epoch", .string), field("seq", .int)]),
            shape("subscribe.result", from: contractLive, [field("sub", .string), field("mode", .words(["snapshot", "resume", "tail"]))]),
            shape("unsubscribe.args", from: "the contract's §3", [field("sub", .string)]),
            shape("chat.page.args", from: "the contract's §6", [field("session", .string), field("before", .string), optional("limit", .int)]),
            shape("chat.page.result", from: contractChat, [field("items", .list(.shape("chat.item"))), field("more", .bool)]),
            shape("draft.args", from: "the contract's §8", [field("card", .string), field("text", .string), field("version", .int)]),
            shape("draft.result", from: "Requests.draft", [field("applied", .map(.int)), field("card", .string)]),
            shape("draft.clear.args", from: "the contract's §8", [field("card", .string)]),
            shape("seen.args", from: "Requests.seen (the parity gaps of 2026-11-19)", [optional("session", .string), optional("project", .string)]),
            shape("session.draft.args", from: "Requests.sessionDraft (driving sessions, 2026-11-20)", [field("session", .string), field("text", .string),
                                                                                                    optional("images", strings), optional("now", .bool)]),
            shape("session.draft.result", from: "Requests.sessionDraft", [field("applied", .map(.int)), field("session", .string)]),
            shape("session.draft.clear.args", from: "Requests.sessionDraft", [field("session", .string)]),
            // The launch presets (the composer's lane, 2026-11-20): a read, what the page's New session form offers.
            shape("session.presets.args", from: "Requests.presets (launch presets, 2026-11-20)", [optional("folder", .string)]),
            shape("session.presets.result", from: "Requests.presets", [field("presets", .list(.shape("session.preset"))), field("problems", strings)]),
            // An image a page pasted into a session's composer, in parts (the composer's lane, 2026-11-20).
            shape("session.attach.args", from: "Requests.attach (the composer, 2026-11-20)", [
                field("session", .string), field("upload", .string), field("type", .words(["image/png", "image/jpeg", "image/gif", "image/webp"])),
                field("part", .int), field("parts", .int), field("data", .string)]),
            shape("session.attach.result", from: "Requests.attach", [field("session", .string), field("received", .int), optional("path", .string)]),
            // What a session's composer completes (the composer's lane, 2026-11-20): a read, at the page's keystrokes.
            shape("session.complete.args", from: "Requests.complete (the composer, 2026-11-20)", [
                field("session", .string), field("kind", .words(["slash", "mention"])), field("query", .string)]),
            shape("session.complete.result", from: "Requests.complete", [field("items", .list(.shape("session.completion")))]),
            shape("session.completion", from: "SessionCompletions.value", [field("insert", .string), field("title", .string), field("subtitle", .string)]),
            // A session's tokens and cost (the inspector, 2026-11-21): a read of its transcript's tail. `cost` is in US
            // dollars, a number (an int when whole).
            shape("session.ports.args", from: "Requests.sessionPorts (the dev pages row, 2026-11-21)", [field("session", .string)]),
            shape("session.ports.result", from: "DevPorts.value", [field("ports", .list(.shape("session.port")))]),
            shape("session.port", from: "DevPorts.value", [field("port", .int), field("address", .string), field("pid", .int),
                                                           field("program", Kind.string.orNull), field("url", .string)]),
            shape("session.usage.args", from: "ChatStore.usage (the inspector, 2026-11-21)", [field("session", .string)]),
            shape("session.usage.result", from: "ChatStore.usageValue", [
                field("turns", .list(.shape("session.usage.turn"))), field("count", .int), field("partial", .bool),
                field("tokens", Kind.shape("session.usage.tokens").orNull), field("cost", Kind.any.orNull), field("costPartial", .bool)]),
            shape("session.usage.turn", from: "ChatStore.usageValue", [
                field("id", .string), field("at", Kind.date.orNull), field("partial", .bool), field("tokens", Kind.shape("session.usage.tokens").orNull),
                field("cost", Kind.any.orNull)]),
            shape("session.usage.tokens", from: "ChatStore.usageValue", [field("input", .int), field("cached", .int), field("output", .int)]),
            // The Statistics window from the node (2026-11-21): the Mac's words; bars per mille, a trend day's value in thousandths.
            shape("stats.args", from: "Requests.stats (2026-11-21)", [optional("range", .words(["today", "week", "month"]))]),
            shape("stats.result", from: "StatisticsWire.value", [
                field("range", .words(["today", "week", "month"])), field("title", .string), field("span", .string),
                field("mac", .list(.shape("stats.figure"))), field("columns", strings), field("projects", .list(.shape("stats.row"))),
                field("total", Kind.shape("stats.row").orNull), field("quality", Kind.shape("stats.quality").orNull)]),
            shape("stats.figure", from: "StatisticsWire.figure", [
                field("label", .string), field("value", .string), field("detail", Kind.string.orNull), field("help", Kind.string.orNull),
                field("meter", Kind.shape("stats.meter").orNull), field("trend", .list(.shape("stats.day")))]),
            shape("stats.meter", from: "StatisticsWire.figure", [field("used", .int), field("elapsed", Kind.int.orNull), field("reached", .bool)]),
            shape("stats.day", from: "StatisticsWire.figure", [field("label", .string), field("value", Kind.int.orNull), field("text", .string)]),
            shape("stats.row", from: "StatisticsWire.row", [field("id", .string), field("name", .string), field("note", Kind.string.orNull),
                                                             field("cells", strings)]),
            shape("stats.quality", from: "StatisticsWire.quality", [
                field("sections", .list(.shape("stats.section"))), field("columns", strings), field("columnHelp", strings),
                field("breakdown", .list(.shape("stats.breakdown"))), field("modelsNote", Kind.string.orNull), field("trend", .list(.shape("stats.week"))),
                field("compared", .shape("stats.compared"))]),
            shape("stats.section", from: "StatisticsWire.quality", [field("title", .string), field("figures", .list(.shape("stats.figure")))]),
            shape("stats.breakdown", from: "StatisticsWire.quality", [field("name", .string), field("model", .bool), field("cells", strings)]),
            shape("stats.week", from: "StatisticsWire.quality", [
                field("label", .string), field("merged", .int), field("passRate", .string), field("passBar", Kind.int.orNull), field("cost", .string),
                field("costBar", Kind.int.orNull)]),
            shape("stats.compared", from: "StatisticsWire.quality", [
                field("title", .string), field("badge", .string), field("method", .string), field("columns", strings),
                field("groups", .list(.shape("stats.group")))]),
            shape("stats.group", from: "StatisticsWire.quality", [field("title", .string), field("rows", .list(.shape("stats.comparedRow")))]),
            shape("stats.comparedRow", from: "StatisticsWire.quality", [field("label", .string), field("help", .string),
                                                                         field("cells", .list(.shape("stats.cell")))]),
            shape("stats.cell", from: "StatisticsWire.quality", [field("value", .string), field("detail", Kind.string.orNull)]),
            // An image of a session's chat, a part of its bytes at a time (the chat's images, 2026-11-21): a read.
            shape("chat.image.args", from: "ChatStore.image (the chat's images, 2026-11-21)", [
                field("session", .string), field("id", .string), optional("offset", .int)]),
            shape("chat.image.result", from: "ChatImageBytes.part", [
                field("mediaType", .words(["image/png", "image/jpeg", "image/gif", "image/webp"])), field("bytes", .int), field("offset", .int),
                field("data", .string)]),
            shape("session.preset", from: "SessionPresets.value", [
                field("name", .string), field("kind", .words(["claude", "codex", "shell"])), field("command", .string), field("env", strings),
                field("keepShell", .bool), field("project", .bool), field("default", .bool), field("builtIn", .bool), field("digest", .string),
                field("refused", Kind.string.orNull), optional("values", .map(.string))]),
        ]

        // The node (the contract's §5).
        shapes += [
            shape("node", from: contractNode, [
                field("node", .string), field("epoch", .string), field("root", .string), field("server", .shape("node.server")),
                field("host", .shape("node.host")), field("rule", .shape("node.rule")), field("cards", .shape("node.cards")),
                field("accepted", .list(.shape("node.accepted"))), field("notices", strings),
                field("restart", Kind.shape("node.restart").orNull), field("reopen", .list(.shape("node.reopen"))), field("ended", .list(.shape("node.ended"))), field("ending", .list(.shape("node.ending"))),
                field("builds", Kind.any.orNull), field("web", .shape("node.web")), field("usage", Kind.shape("node.usage").orNull),
                optional("health", .shape("node.health")), field("boost", Kind.shape("node.boost").orNull),
                optional("plugins", .list(.shape("hello.plugin")))]),
            // Boost (the app's `BoostMark`, 2026-11-21): null before the engine's first look.
            shape("node.boost", from: "LeadEngine.boostValue", [field("mode", .words(BoostMode.allCases.map(\.rawValue))), field("on", .bool),
                                                               field("why", .string), field("limits", .shape("node.boost.limits"))]),
            shape("node.boost.limits", from: "LeadEngine.boostValue", [field("loadThreshold", .string), field("maxSessions", .int),
                                                                      field("maxWorkers", .int), field("heavySlots", .int)]),
            shape("node.health", from: "NodeHealth.value (2026-11-21)", [
                field("since", .date), field("stalled", Kind.int.orNull), field("freezes", .list(.shape("node.health.freeze"))),
                field("slowRefreshes", .int), field("slowestRefresh", Kind.int.orNull), field("lastSlowRefresh", Kind.date.orNull),
                field("serverRestarts", Kind.int.orNull), field("refusedConnections", Kind.int.orNull), field("hostRestartAt", Kind.date.orNull),
                field("waiting", strings), field("errors", .list(.shape("node.health.error"))), field("causes", .list(.shape("node.health.cause")))]),
            shape("node.health.cause", from: "NodeHealth.value", [field("kind", .string), field("count", .int), field("last", .date)]),
            shape("node.health.freeze", from: "NodeHealth.value", [field("at", .date), field("seconds", .int)]),
            shape("node.health.error", from: "NodeHealth.value", [field("at", .date), field("line", .string)]),
            shape("node.server", from: "Requests.statusValue", [field("pid", .int), field("startedAt", .date), field("commit", .string)]),
            shape("node.host", from: "Requests.statusValue", [
                field("startedAt", Kind.date.orNull), field("pid", Kind.int.orNull), field("state", .string),
                field("liveSessions", .int), field("notes", Kind.shape("host.notes").orNull)]),
            shape("host.notes", from: "Requests.value(_:at:)", [
                field("startedAt", .date), field("serverRestarts", .int), field("replacedPaths", strings),
                field("refusedAppConnections", .int), field("lockHeldElsewhere", Kind.string.orNull),
                field("build", Kind.string.orNull), field("at", .date)]),
            shape("node.rule", from: "Requests.statusValue", [field("mode", .words(["systemd", "weaker", "closed", "approval"])), field("says", .string),
                                                             field("scopes", strings)]),
            shape("node.cards", from: "Requests.counts", [field("questions", .int), field("approvals", .int), field("config", .int),
                                                         field("base", .int)]),
            shape("node.accepted", from: "Requests.Accepted.value", [
                field("kind", .string), field("action", Kind.string.orNull), field("subject", Kind.string.orNull), field("at", .date),
                field("pid", .int), field("cgroup", Kind.string.orNull), field("commandLine", strings)]),
            shape("node.restart", from: "LeadEngine.restartValue", [field("at", .date), field("before", .date), field("gone", strings),
                                                                   field("reset", .string), field("sessions", .int)]),
            shape("node.reopen", from: "LeadEngine.offeredValue (the stability lane, 2026-11-20)", [
                field("session", .string), field("folder", .string), field("name", .string), field("conversation", Kind.string.orNull)]),
            // Ended within the grace, listed for `resume` at `listedAt` (2026-11-21).
            shape("node.ending", from: "LeadEngine.endingValue", [field("session", .string), field("folder", .string), field("name", .string),
                                                                 field("at", .date), field("listedAt", .date)]),
            shape("node.ended", from: "LeadEngine.endedValue (the stability lane, 2026-11-20)", [
                field("session", .string), field("folder", .string), field("name", .string), field("conversation", Kind.string.orNull),
                field("at", .date), field("exit", Kind.shape("node.ended.exit").orNull)]),
            // How it ended (the inspector's Exit, 2026-11-21): `HostSession.Exit`'s status, its `cause` and when.
            shape("node.ended.exit", from: "LeadEngine.endedValue", [field("status", .int), field("cause", .string), field("at", .date)]),
            shape("node.web", from: contractNode, [field("state", .string), field("port", Kind.int.orNull), field("tokens", .int),
                                                  field("connections", .int)]),
            // The account's usage (the parity table's "Usage shown to you", 2026-11-21): null until the engine's first refresh.
            shape("node.usage", from: "NodeUsage.value", [
                field("account", Kind.string.orNull), field("limits", .list(.shape("node.usage.limit"))), field("ignored", .bool),
                field("threshold", .int), field("fableHeldBack", Kind.date.orNull)]),
            shape("node.usage.limit", from: "NodeUsage.value", [
                field("name", .string), field("label", .string), field("model", Kind.string.orNull), field("usedPercent", .int),
                field("reached", .bool), field("resetsAt", Kind.date.orNull), field("holds", .bool), field("text", .string)]),
        ]

        // A session (the contract's §5).
        shapes.append(shape("session", from: contractSession, [
            field("id", .string), field("terminal", .string), field("agent", .words(["claude", "codex"])), field("cwd", Kind.string.orNull),
            field("status", .words(["needs-you", "working", "background", "done", "idle", "unknown"])), field("since", .date),
            field("hosted", .bool), field("role", Kind.words(["lead", "worker", "verifier"]).orNull),
            field("shownStatus", .words(["needs-you", "working", "background", "done", "idle", "unknown"])), field("project", .string),
            field("task", Kind.string.orNull), field("detail", Kind.string.orNull), field("activity", Kind.string.orNull),
            field("activitySince", Kind.date.orNull), field("startedAt", .date), field("hasHooks", .bool), field("leadAsks", .bool),
            field("startFolder", Kind.string.orNull), field("backgroundJobs", .int), field("hasTranscript", .bool),
            field("prompt", Kind.shape("session.prompt").orNull), field("draft", Kind.shape("session.draft").orNull),
            field("name", Kind.string.orNull), field("pausedUntil", Kind.date.orNull), field("agentSession", Kind.string.orNull),
            field("queued", .list(.shape("session.queued"))),
            // The inspector's (2026-11-21): the agent's pid, its folder's branch, the host's command and size, its board.
            field("pid", .int), field("branch", Kind.string.orNull), field("command", Kind.string.orNull),
            field("size", Kind.shape("session.size").orNull), field("lead", Kind.string.orNull), field("boardTask", Kind.string.orNull)]))
        shapes.append(shape("session.size", from: "Session.liveValue(prompt:draft:queued:host:branch:)", [field("cols", .int), field("rows", .int)]))
        // What the node keeps beside a session (driving sessions, 2026-11-20): the question on its screen, a page's draft.
        shapes.append(shape("session.prompt", from: "SessionPrompt.value", [
            field("question", .string), field("options", strings), field("descriptions", .list(Kind.string.orNull)), field("text", .list(.int)),
            field("multiSelect", .bool), field("at", .date)]))
        shapes.append(shape("session.draft", from: "SessionDraft.value", [field("text", .string), field("images", strings), field("at", .date),
                                                                          field("action", .string), optional("now", .bool)]))
        // A message `send` holds until the question on the session's screen closes (the composer's lane, 2026-11-20).
        shapes.append(shape("session.queued", from: "HeldSend.value", [field("text", .string), field("images", .int), field("at", .date),
                                                                       field("action", .string)]))

        // A lead (the contract's §5): the store's value, with what `status` adds.
        let byStatus = "Requests.leadValue adds it"
        shapes += [
            shape("lead", from: "LeadStore.Lead.value", [
                field("project", .string), field("root", .string), field("session", Kind.string.orNull), field("named", Kind.string.orNull),
                field("bound", Kind.string.orNull), field("replaced", strings), field("held", .int), field("reportsWaiting", .int),
                field("notice", Kind.string.orNull), field("starting", .bool), field("lastStart", Kind.string.orNull),
                field("lastStartAt", Kind.date.orNull), field("push", Kind.shape("lead.push").orNull), pending(field("looks", .int), byStatus),
                pending(field("questions", .shape("lead.questions")), byStatus), pending(field("cards", strings), byStatus)]),
            shape("lead.questions", from: "Requests.leadValue", [field("open", .int), field("blocking", .int)]),
            // The push its lead asked for, while it's open (push_remote, `PushAsks.swift`).
            shape("lead.push", from: "LeadStore.Lead.pushValue", [
                field("id", .string), field("commit", .string), field("short", .string), field("branch", .string), field("remote", .string),
                field("target", .string), field("url", .string), field("ahead", .int), field("subjects", strings), field("askedAt", .date)]),
        ]

        // A card (the contract's §5).
        shapes += [
            shape("card", from: "CardStore.Card.value", [
                field("id", .string), field("kind", .words(CardStore.Kind.allCases.map(\.rawValue))), field("project", .string),
                field("root", .string), field("open", .bool), field("closed", Kind.string.orNull), field("notice", Kind.string.orNull),
                field("at", .date), field("blocking", .bool), optional("question", .shape("card.question")),
                optional("approval", .shape("card.approval")), optional("config", .shape("card.config")),
                optional("base", .shape("card.base")), optional("shell", .shape("card.shell")),
                optional("plugin", .shape("card.plugin")), field("draft", Kind.shape("card.draft").orNull)]),
            // A feature plugin's card (`PluginCard`, Plugins/PluginWire.swift, 2026-11-22): one shape for every plugin.
            shape("card.plugin", from: "PluginCard.value", [
                field("plugin", .string), field("request", .string), field("session", .string), field("asker", .string),
                field("title", .string), field("noun", .string), field("ask", .string), field("summary", .string),
                field("facts", .list(.shape("card.plugin.fact"))), field("body", .shape("card.plugin.body")),
                field("context", Kind.shape("card.plugin.context").orNull),
                field("severity", .words(PluginCard.Severity.allCases.map(\.rawValue))), field("expiresAt", Kind.date.orNull),
                field("actions", .list(.shape("card.plugin.action"))), field("waiting", Kind.string.orNull), field("state", .string),
                field("outcome", Kind.string.orNull)]),
            shape("card.plugin.fact", from: "PluginCard.Fact", [field("name", .string), field("label", .string), field("value", .string),
                                                                field("folder", .bool)]),
            shape("card.plugin.body", from: "PluginCard.Body", [field("name", .string), field("label", .string), field("note", Kind.string.orNull),
                                                                field("lines", strings), field("bytes", .int), field("size", .string)]),
            shape("card.plugin.context", from: "PluginCard.Context", [field("name", .string), field("label", .string), field("text", .string)]),
            shape("card.plugin.action", from: "PluginCard.Action", [field("word", .string), field("label", .string), field("acts", .bool),
                                                                    field("short", .string), field("does", .string), field("verb", .string),
                                                                    field("marks", .string)]),
            shape("card.shell", from: "CardStore.Card.value (ShellCards.swift, 2026-11-21)", [
                field("request", .string), field("session", .string), field("asker", .string), field("cwd", .string), field("command", .string),
                field("label", .string), field("filedAt", .date), field("expiresAt", .date),
                field("state", .words(["waiting", "starting", "started", "declined", "expired", "failed"])),
                field("shell", Kind.string.orNull), field("name", Kind.string.orNull), field("why", Kind.string.orNull)]),
            shape("card.question", from: "CardStore.Card.value", [
                field("id", .string), field("short", .string), field("text", .string), field("options", strings),
                field("priority", .words(["blocking", "important", "whenever"])), field("whyNow", Kind.string.orNull),
                field("version", .int), field("revisionNote", Kind.string.orNull), field("proposal", Kind.string.orNull),
                field("decideBy", Kind.date.orNull), field("state", .words(["open", "answered", "withdrawn", "autoDecided"])),
                field("answer", Kind.string.orNull), field("answeredVersion", Kind.int.orNull),
                field("withdrawReason", Kind.string.orNull), field("task", Kind.string.orNull)]),
            shape("card.approval", from: "CardStore.Card.value", [
                field("commit", .string), field("tasks", strings), field("base", Kind.string.orNull), field("files", strings),
                field("diffstat", .string), field("subject", Kind.string.orNull), field("verdicts", .map(.string)),
                field("sensitive", strings.orNull), field("problems", strings)]),
            shape("card.config", from: "CardStore.Card.value", [
                field("items", .list(.shape("card.config.item"))), field("guarded", .list(.shape("card.config.rail"))),
                field("lastAccept", Kind.date.orNull), field("floor", Kind.shape("card.config.floor").orNull),
                field("baseBranch", Kind.string.orNull)]),
            shape("card.config.item", from: "CardStore.Card.value", [
                field("name", .string), field("changedAt", Kind.date.orNull), field("size", Kind.int.orNull), field("hash", .string),
                field("change", Kind.string.orNull), field("outside", .bool), field("files", strings),
                field("sinceAccept", Kind.string.orNull)]),
            shape("card.config.rail", from: "CardStore.Card.value", [field("key", .string), field("value", .string),
                                                                    field("sinceAccept", Kind.string.orNull)]),
            shape("card.config.floor", from: "CardStore.Card.value", [
                field("mergePolicy", .words(["auto", "ask_sensitive", "ask_all"])), field("auditFinders", .int),
                field("sensitivePaths", strings), field("strictPaths", strings), field("riskLines", .int), field("riskModel", .bool),
                field("verifierDifferent", .bool), field("auditSamplePercent", .int)]),
            shape("card.base", from: "CardStore.Card.value", [
                field("branch", .string), field("from", Kind.string.orNull), field("fromIs", .words(["recorded", "given", "unverified", "none"])),
                field("to", .string), field("reason", Kind.string.orNull), field("commits", .list(.shape("card.base.commit")))]),
            shape("card.base.commit", from: "CardStore.Card.value", [field("sha", .string), field("subject", .string)]),
            shape("card.draft", from: "CardStore.Card.value", [field("text", .string), field("version", .int), field("at", .date),
                                                                    field("action", .string)]),
        ]

        // A lead's board (the `boards` collection, `board`'s result: the parity table's gap 4).
        let taskStatus = Kind.words(LeadTask.Status.allCases.map(\.rawValue))
        shapes += [
            shape("board", from: "BoardValue.value", [
                field("project", .string), field("root", .string), field("baseBranch", Kind.string.orNull),
                field("tasks", .list(.shape("board.task"))), field("counts", .shape("board.counts")), field("more", .int),
                field("unreadable", Kind.string.orNull), field("decisions", .list(.shape("board.decision"))),
                field("allDone", Kind.shape("board.allDone").orNull),
                // The Team tab's records (2026-11-21, `BoardRecords`).
                field("scorecard", Kind.shape("board.scorecard").orNull), field("answered", .list(.shape("board.question"))),
                field("files", .list(.shape("board.file"))), field("recordsDir", Kind.string.orNull),
                field("results", .list(.shape("board.update")))]),
            shape("board.update", from: "BoardRecords.result", [field("id", .string), field("title", .string), field("body", .string),
                                                               field("at", .date), field("images", .int)]),
            // A task's details (`board.task`), a result's screenshot (`board.image`).
            shape("board.task.args", from: "Requests.boardTask (2026-11-21)", [field("project", .string), field("task", .string)]),
            shape("board.task.result", from: "BoardDetails.task", [
                field("slug", .string), field("title", .string), field("failure", Kind.string.orNull), field("checkpoints", .list(.shape("board.checkpoint"))),
                field("report", Kind.string.orNull), field("audit", Kind.shape("board.task.audit").orNull), field("round", Kind.int.orNull),
                field("findings", .list(.shape("board.task.finding"))), field("merged", Kind.string.orNull), field("score", Kind.string.orNull),
                field("reverted", .bool), field("worker", Kind.string.orNull), field("verifier", Kind.string.orNull)]),
            shape("board.task.audit", from: "BoardDetails.task", [
                field("last", .bool), field("passes", Kind.bool.orNull), field("completion", Kind.string.orNull), field("integrity", Kind.string.orNull),
                field("summary", Kind.string.orNull), field("vote", Kind.string.orNull), field("panel", Kind.string.orNull)]),
            shape("board.task.finding", from: "BoardDetails.task", [
                field("id", .string), field("severity", .string), field("status", .words(["open", "fixed", "dismissed", "unconfirmed"])),
                field("blocks", .bool), field("text", .string)]),
            shape("board.image.args", from: "Requests.boardImage (2026-11-21)", [field("project", .string), field("update", .string), field("index", .int),
                                                                                 optional("offset", .int)]),
            shape("board.image.result", from: "ChatImageBytes.part", [
                field("mediaType", .words(["image/png", "image/jpeg", "image/gif", "image/webp"])), field("bytes", .int), field("offset", .int),
                field("data", .string)]),
            shape("board.allDone", from: "BoardValue.allDone", [
                field("id", .string), field("at", .date), field("summary", Kind.shape("board.allDone.summary").orNull),
                field("tasks", .list(.shape("board.allDone.task"))), field("merged", .int), field("receipts", Kind.string.orNull),
                field("pricesAsOf", Kind.string.orNull), field("seen", .bool)]),
            shape("board.allDone.summary", from: "BoardValue.allDone", [field("headline", .string), field("bullets", strings), field("byModel", .bool)]),
            shape("board.allDone.task", from: "BoardValue.allDone", [field("title", .string),
                                                                    field("outcome", .words(["merged", "folded", "abandoned", "reverted"]))]),
            // The lead's decisions (`BoardRecords`, read with no link followed), each with its AI line when a long one has one.
            shape("board.decision", from: "BoardValue.decisions", [field("id", .string), field("at", Kind.date.orNull), field("text", .string),
                                                                 field("why", Kind.string.orNull), field("summary", Kind.string.orNull)]),
            shape("board.counts", from: "BoardValue.value", BoardValue.groups.map { field($0, .int) }),
            shape("board.scorecard", from: "BoardRecords.scorecard", [
                field("merged", .int), field("reverts", .int), field("mergedWithoutTests", .int), field("tiles", .list(.shape("board.tile"))),
                field("footnote", Kind.string.orNull), field("receipts", Kind.string.orNull)]),
            shape("board.tile", from: "BoardRecords.scorecard", [field("value", .string), field("label", .string), field("note", Kind.string.orNull),
                                                                  field("help", .string)]),
            shape("board.question", from: "BoardRecords.question", [
                field("id", .string), field("state", .words(["answered", "withdrawn", "autoDecided"])), field("text", .string),
                field("answer", Kind.string.orNull), field("proposal", Kind.string.orNull), field("why", Kind.string.orNull),
                field("reworded", .bool), field("task", Kind.string.orNull), field("at", .date)]),
            shape("board.file", from: "BoardRecords.fields", [field("name", .string), field("path", .string), field("present", .bool)]),
            shape("board.task", from: "BoardValue.task", [
                field("id", .string), field("slug", .string), field("title", .string), field("status", taskStatus),
                field("group", .words(BoardValue.groups)), field("state", .string), field("line", Kind.string.orNull),
                field("summary", Kind.string.orNull),
                field("blocker", Kind.string.orNull), field("worker", Kind.string.orNull), field("verifier", Kind.string.orNull),
                field("review", .words(LeadTask.Review.allCases.map(\.rawValue))), field("position", .int), field("createdAt", Kind.date.orNull),
                field("since", Kind.date.orNull), field("startedAt", Kind.date.orNull), field("attempts", .int),
                field("budgetMin", Kind.int.orNull), field("overBudget", .bool), field("branch", Kind.string.orNull), field("after", strings),
                field("checkpoint", Kind.shape("board.checkpoint").orNull), field("audit", Kind.shape("board.audit").orNull),
                field("merged", Kind.shape("board.merged").orNull)]),
            shape("board.checkpoint", from: "BoardValue.task", [field("text", .string), field("at", Kind.date.orNull)]),
            shape("board.audit", from: "BoardValue.audit", [field("verdict", Kind.words(["passed", "failed"]).orNull), field("open", .int),
                                                           field("findings", .int), field("rounds", .int)]),
            shape("board.merged", from: "BoardValue.task", [field("commit", .string), field("at", Kind.date.orNull), field("tested", .bool)]),
            shape("board.args", from: "Requests.board", [optional("folder", .string)]),
            shape("board.result", from: "Requests.board", [field("boards", .list(.shape("board")))]),
        ]

        // The node's settings (`settings`' result, `set`: the parity table's gap 9, 2026-11-20).
        shapes += [
            shape("setting", from: "NodeSettings.Shown.wire", [
                field("key", .string), field("title", .string), field("about", .string), field("section", .string),
                field("scope", .words(["node", "project"])), field("form", .words(["flag", "count", "number", "choice", "model", "paths", "text", "folder"])),
                field("home", .words(["limits", "preferences", "policy", "workflow", "floor"])), field("choices", strings),
                field("limits", Kind.string.orNull), field("value", .string), field("default", .string), field("isDefault", .bool),
                field("where", .string), field("guardRail", .bool), field("note", Kind.string.orNull)]),
            shape("settings.node", from: "Requests.settings", [field("root", .string), field("settings", .list(.shape("setting")))]),
            shape("settings.project", from: "Requests.settings", [field("project", .string), field("root", .string),
                                                                   field("settings", .list(.shape("setting")))]),
            shape("settings.left", from: "Requests.settings", [field("title", .string), field("why", .string)]),
            shape("settings.args", from: "Requests.settings", [optional("folder", .string)]),
            shape("settings.result", from: "Requests.settings", [field("node", .shape("settings.node")),
                                                                  field("project", Kind.shape("settings.project").orNull),
                                                                  field("leftOut", .list(.shape("settings.left"))),
                                                                  field("usage", .shape("node.usage"))]),
            // Brief me (`brief`, 2026-11-21).
            shape("brief.args", from: "Requests.brief", [optional("folder", .string)]),
            shape("brief.result", from: "Requests.briefValue", [field("text", .string), field("byModel", .bool), field("language", .string),
                                                               field("at", .date), field("notice", Kind.string.orNull), field("asks", .int),
                                                               field("kept", .bool)]),
            // The start page's recent projects (`recent`, 2026-11-21).
            shape("recent.args", from: "Requests.recent", []),
            shape("recent.result", from: "Requests.recent", [field("projects", .list(.shape("recent.project")))]),
            shape("recent.project", from: "Requests.recent", [field("folder", .string), field("lastUsed", Kind.date.orNull),
                                                              field("lead", Kind.string.orNull)]),
            // Between leads (`mail`, a page's read since 2026-11-21: `NodeWire.Voice.webRead`).
            shape("mail.args", from: "Requests.mail", [optional("folder", .string), optional("all", .bool)]),
            shape("mail.result", from: "Requests.mail", [field("projects", .list(.shape("mail.project")))]),
            shape("mail.project", from: "Requests.mail", [field("root", .string), field("project", .string), field("total", .int),
                                                          field("messages", .list(.shape("mail.message")))]),
            shape("mail.message", from: "Requests.mailValue", [
                field("at", .date), field("from", .string), field("to", .string), field("received", .bool),
                field("kind", Kind.words(LeadMail.Kind.allCases.map(\.rawValue)).orNull), field("text", .string),
                field("outcome", .words(["delivered", "waiting", "refused", "no_lead", "off", "failed"])), field("sent", .bool), field("detail", .string)]),
            shape("set.args", from: "Requests.set", [optional("folder", .string), field("key", .string), field("value", .string)]),
            shape("set.result", from: "Requests.set", [field("key", .string), field("value", .string), field("was", .string),
                                                        field("scope", .words(["node", "project"])), field("project", Kind.string.orNull),
                                                        field("told", Kind.words(["lead", "leads"]).orNull)]),
        ]

        // A chat's items (the contract's §6).
        func item(_ type: String, _ fields: [Field]) -> Shape {
            shape("chat.\(type)", from: contractChat, [field("id", .string), field("type", .words([type])), field("at", Kind.date.orNull)] + fields)
        }
        func detail(_ type: String, _ fields: [Field]) -> Shape {
            shape("chat.detail.\(type)", from: contractChat, [field("type", .words([type]))] + fields)
        }
        let details = ["thought", "todos", "plan", "command", "edit", "write", "read", "patch", "questions", "agent", "fields"]
        shapes += [
            union("chat.item", from: contractChat, tag: "type",
                  ["prompt": "chat.prompt", "reply": "chat.reply", "tools": "chat.tools", "team": "chat.team",
                   "allDone": "chat.allDone"]),
            item("prompt", [field("text", .string), field("steered", .bool), field("fromLead", .bool), field("images", .list(.shape("chat.image")))]),
            item("reply", [field("text", .string)]),
            // The lead's board cleared (the app's `AllDoneCard`, 2026-11-21): placed by `ChatStore` in the lead's chat.
            // Its time is always the mark's (never null, as a transcript's item's may be).
            shape("chat.allDone", from: contractChat, [field("id", .string), field("type", .words(["allDone"])), field("at", .date),
                             field("summary", Kind.shape("board.allDone.summary").orNull), field("tasks", .list(.shape("board.allDone.task"))),
                             field("merged", .int), field("receipts", Kind.string.orNull), field("pricesAsOf", Kind.string.orNull),
                             field("seen", .bool)]),
            item("tools", [field("summary", .string), field("tools", .list(.shape("chat.tool")))]),
            item("team", [field("text", .string), field("title", .string), field("sender", .shape("chat.sender")),
                          field("message", .words(["report", "audit", "witness", "userAnswer", "leadMessage", "notice", "teammatePost"])),
                          field("task", Kind.string.orNull), field("part", Kind.shape("chat.part").orNull),
                          // A long message's TL;DR (`TeamSummaryWatch.summarizeMessage`), once one came.
                          Field(name: "summary", type: .string, optional: true, pending: "ChatStore (a TL;DR the engine wrote, added to the item)")]),
            shape("chat.sender", from: contractChat, [field("kind", .words(["user", "lead", "vibeSwitcher", "teammate"])),
                                                      field("name", Kind.string.orNull), field("task", Kind.string.orNull)]),
            shape("chat.part", from: contractChat, [field("index", .int), field("count", .int)]),
            shape("chat.image", from: contractChat, [field("id", .string), field("mediaType", .string), field("bytes", .int)]),
            shape("chat.tool", from: contractChat, [
                field("id", .string), field("name", .string), field("title", .string), field("at", Kind.date.orNull),
                field("detail", .shape("chat.detail")), field("result", Kind.shape("chat.result").orNull)]),
            shape("chat.result", from: contractChat, [
                field("output", .string), field("truncated", .bool), field("failed", .bool), field("at", Kind.date.orNull),
                field("images", .list(.shape("chat.image")))]),
            union("chat.detail", from: contractChat, tag: "type", Dictionary(uniqueKeysWithValues: details.map { ($0, "chat.detail.\($0)") })),
            detail("thought", [field("text", .string)]),
            detail("todos", [field("todos", .list(.shape("chat.todo")))]),
            shape("chat.todo", from: contractChat, [field("text", .string), field("status", .words(["pending", "active", "done"]))]),
            detail("plan", [field("text", .string)]),
            detail("command", [field("command", .string)]),
            detail("edit", [field("path", .string), field("changes", .list(.shape("chat.change")))]),
            shape("chat.change", from: contractChat, [field("old", .string), field("new", .string)]),
            detail("write", [field("path", .string), field("content", .string)]),
            detail("read", [field("path", .string)]),
            detail("patch", [field("text", .string)]),
            detail("questions", [field("questions", .list(.shape("chat.question")))]),
            shape("chat.question", from: contractChat, [
                field("question", .string), field("options", strings), optional("header", .string),
                field("descriptions", .list(Kind.string.orNull)),
                field("multiSelect", .bool)]),
            detail("agent", [field("description", .string), field("prompt", .string)]),
            detail("fields", [field("fields", .list(.shape("chat.field")))]),
            shape("chat.field", from: contractChat, [field("name", .string), field("value", .string)]),
        ]
        return shapes
    }()

    private static func pending(_ field: Field, _ who: String) -> Field {
        var field = field
        field.pending = who
        return field
    }

    // MARK: Checking

    /// The kinds `check` (and `validators.js`'s `validate`) take: every shape, and `frame` (any message, told apart by
    /// its fields), `reply.<kind>` (a reply whose result is `<kind>.result`, when the schema has one) and
    /// `delta.<collection>` (a delta whose changes are that collection's entities). `request` checks `args` as
    /// `<kind>.args` when the schema has it; `snapshot` checks its entries as its collection's entities.
    ///
    /// The first failure, as `<path>: <why>` (`entries[0].value.since: expected a date`), or nil. `strict`: a key the
    /// schema doesn't name fails too, and a `pending` field may be missing (the encoders' check). `seen` is told each
    /// field looked at, as `<shape>.<field>`.
    public static func check(_ value: NodeWire.Value, as kind: String, strict: Bool = false,
                             seen: ((String, Seen) -> Void)? = nil) -> String? {
        Checker(strict: strict, seen: seen).top(value, kind)
    }

    /// What `check` must report seeing for samples of `kinds` to cover their shapes: for each field reached (through
    /// fields that aren't `pending`), `<shape>.<field> present`, and `absent` when it may be absent, `null` when it
    /// may be null.
    public static func coverage(of kinds: [String]) -> Set<String> {
        var wanted: Set<String> = []
        var visited: Set<String> = []
        func reach(_ type: Kind) {
            switch type {
            case .shape(let name): visit(name)
            case .list(let inner), .map(let inner), .nullable(let inner): reach(inner)
            default: break
            }
        }
        func visit(_ name: String) {
            guard let shape = shapes[name], visited.insert(name).inserted else { return }
            if let union = shape.union { union.cases.values.forEach(visit) }
            for field in shape.fields where field.pending == nil {
                let key = "\(name).\(field.name)"
                wanted.insert("\(key) \(Seen.present)")
                if field.optional { wanted.insert("\(key) \(Seen.absent)") }
                if case .nullable = field.type { wanted.insert("\(key) \(Seen.null)") }
                reach(field.type)
            }
        }
        kinds.forEach(visit)
        return wanted
    }

    /// The pattern a date matches: ISO 8601 with a time zone (`NodeWire.dateText` writes milliseconds and `Z`).
    public static let datePattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$"#
    private static let dateExpression = try! NSRegularExpression(pattern: datePattern)

    private struct Checker {
        let strict: Bool
        let seen: ((String, Seen) -> Void)?

        func top(_ value: NodeWire.Value, _ kind: String) -> String? {
            if kind == "frame" { return top(value, Self.frameKind(value)) }
            if kind == "request" {
                if let failure = shape(value, "request", "", kind) { return failure }
                guard let name = value["kind"]?.string, let args = value["args"], shapes["\(name).args"] != nil else { return nil }
                return type(args, .shape("\(name).args"), "args", kind)
            }
            if kind.hasPrefix("reply.") {
                if let failure = shape(value, "reply", "", kind) { return failure }
                let result = "\(kind.dropFirst("reply.".count)).result"
                guard value["ok"]?.bool == true, let body = value["result"], shapes[result] != nil else { return nil }
                return type(body, .shape(result), "result", kind)
            }
            if kind == "snapshot" || kind.hasPrefix("delta.") {
                let envelope = kind == "snapshot" ? "snapshot" : "delta"
                if let failure = shape(value, envelope, "", kind) { return failure }
                let collection = kind == "snapshot" ? value["collection"]?.string ?? "" : String(kind.dropFirst("delta.".count))
                guard let entity = collections[collection] else { return nil }
                let list = envelope == "snapshot" ? "entries" : "changes"
                for (index, entry) in (value[list]?.array ?? []).enumerated() {
                    guard let body = entry["value"], body != .null else { continue }
                    if let failure = type(body, .shape(entity), "\(list)[\(index)].value", kind) { return failure }
                }
                return nil
            }
            guard shapes[kind] != nil else { return "\(kind): no such kind" }
            return shape(value, kind, "", kind)
        }

        /// The kind `frame` checks a message as: a reply has `re`, a request `id`, an event its `kind`.
        static func frameKind(_ value: NodeWire.Value) -> String {
            guard let fields = value.object else { return "event" }
            if fields["re"] != nil { return "reply" }
            if fields["id"] != nil { return "request" }
            let kind = fields["kind"]?.string ?? ""
            return ["hello", "bye", "snapshot", "delta"].contains(kind) ? kind : "event"
        }

        private func at(_ path: String, _ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
        private func label(_ path: String, _ root: String) -> String { path.isEmpty ? root : path }

        func type(_ value: NodeWire.Value, _ type: Kind, _ path: String, _ root: String) -> String? {
            switch type {
            case .string, .words:
                return value.string != nil ? nil : "\(label(path, root)): expected a string"
            case .int:
                return value.int != nil ? nil : "\(label(path, root)): expected an integer"
            case .bool:
                return value.bool != nil ? nil : "\(label(path, root)): expected true or false"
            case .date:
                guard let text = value.string,
                      WireSchema.dateExpression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else {
                    return "\(label(path, root)): expected a date"
                }
                return nil
            case .any:
                return nil
            case .nullable(let inner):
                return value == .null ? nil : self.type(value, inner, path, root)
            case .list(let inner):
                guard let items = value.array else { return "\(label(path, root)): expected a list" }
                for (index, item) in items.enumerated() {
                    if let failure = self.type(item, inner, "\(path)[\(index)]", root) { return failure }
                }
                return nil
            case .map(let inner):
                guard let fields = value.object else { return "\(label(path, root)): expected an object" }
                for key in fields.keys.sorted(by: WireVectors.precedes) {
                    if let failure = self.type(fields[key]!, inner, at(path, key), root) { return failure }
                }
                return nil
            case .shape(let name):
                return shape(value, name, path, root)
            }
        }

        func shape(_ value: NodeWire.Value, _ name: String, _ path: String, _ root: String) -> String? {
            guard let shape = shapes[name] else { return "\(label(path, root)): no shape \(name)" }
            guard let fields = value.object else { return "\(label(path, root)): expected an object" }
            if let union = shape.union {
                guard let tag = fields[union.tag] else { return "\(at(path, union.tag)): missing" }
                guard let word = tag.string else { return "\(at(path, union.tag)): expected a string" }
                guard let named = union.cases[word] else { return nil }
                return self.shape(value, named, path, root)
            }
            for field in shape.fields {
                let key = "\(name).\(field.name)"
                guard let found = fields[field.name] else {
                    seen?(key, .absent)
                    if field.optional || (strict && field.pending != nil) { continue }
                    return "\(at(path, field.name)): missing"
                }
                seen?(key, found == .null ? .null : .present)
                if let failure = type(found, field.type, at(path, field.name), root) { return failure }
            }
            if strict, let extra = fields.keys.sorted(by: WireVectors.precedes).first(where: { key in !shape.fields.contains { $0.name == key } }) {
                return "\(at(path, extra)): not in the schema"
            }
            return nil
        }
    }
}
