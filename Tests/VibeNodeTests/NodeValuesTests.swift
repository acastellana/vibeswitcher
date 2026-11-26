import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// What the page shows as a card or a control, from values the node sends rather than a notice's text or the page's own
/// guess (the no-terminal inventory's C3, C4 and B10's node half, 2026-11-26):
///
/// - C3: the restart's offer to reopen the user's sessions, `node.reopenOffer` (`LeadEngine.reopenOffer`): there after a
///   host restart that ended sessions of the user's, null otherwise, and gone once answered (all reopened, or put away).
/// - C4: each project due a prompt audit, `node.promptAudits` (`PromptAuditWatch.value`): why it's due and what the
///   page's buttons take, and gone once snoozed or turned off.
/// - B10: each setting's page rule in `settings` (`Setting.page`, `pageWhy`, from `NodeSettings`' `page`), additive on
///   the wire; and the node still refuses a page's `set` the rule forbids, whatever the page offered.
///
/// On the Mac and Linux alike: the values are made from the engine's records, and `pageSetRefusal` asked of a server
/// without a host.
@Suite(.timeLimit(.minutes(2)))
struct NodeValuesTests {
    private let scratch = Scratch()

    // MARK: C3: the reopen offer

    private static func entry(_ name: String, project: String, folder: String, conversation: String?) -> RestartReopen.Entry {
        RestartReopen.Entry(id: UUID(), folder: folder, agent: .claude, agentSessionID: conversation, role: .user, project: project, name: name,
                            command: "'/x/claude' --model 'opus'", label: "Claude", cols: 100, rows: 30)
    }

    /// No host restart, one that ended none of the user's sessions: no offer (null). One that did: when, and each
    /// session by the id `session.reopen` takes and its names, never its folder, conversation or command; valid as the
    /// wire's `node.reopenOffer`.
    @Test func theReopenOfferIsThereAfterARestartWithSessionsAndOnlyThen() throws {
        #expect(LeadEngine.reopenOffer(nil) == .null)
        #expect(LeadEngine.reopenOffer(EngineState.Restart(at: 1_800_000_000, before: 1_799_990_000, gone: ["/w/site"])) == .null)
        #expect(LeadEngine.reopenOffer(EngineState.Restart(at: 1_800_000_000, before: 1_799_990_000, gone: [], sessions: [])) == .null)

        let conversation = UUID().uuidString.lowercased()
        let site = Self.entry("Fix the hero", project: "site", folder: "/home/u/projects/site", conversation: conversation)
        let notes = Self.entry("notes", project: "notes", folder: "/home/u/notes", conversation: nil)
        let restart = EngineState.Restart(at: 1_800_000_000, before: 1_799_990_000, gone: [], sessions: [site, notes])
        let offer = LeadEngine.reopenOffer(restart)
        #expect(offer["at"] == .date(Date(timeIntervalSince1970: 1_800_000_000)), "\(offer)")
        let sessions = try #require(offer["sessions"]?.array, "\(offer)")
        #expect(sessions.map { $0["session"] } == [site, notes].map { .string(NodeIds.session(host: $0.id)) }, "\(sessions)")
        #expect(sessions.map { $0["name"] } == [.string("Fix the hero"), .string("notes")])
        #expect(sessions.map { $0["project"] } == [.string("site"), .string("notes")])
        for session in sessions { #expect(Set(session.object?.keys.map { $0 } ?? []) == ["session", "name", "project", "agent"], "\(session)") }
        let text = String(decoding: NodeWire.line(offer), as: UTF8.self)
        for hidden in ["/home/u", conversation, "--model", "claude'"] { #expect(!text.contains(hidden), "\(hidden) in \(text)") }
        #expect(WireSchema.check(offer, as: "node.reopenOffer", strict: true) == nil, "\(WireSchema.check(offer, as: "node.reopenOffer", strict: true) ?? "")")
    }

    /// Answered: the sessions reopened leave the offer, the last one ends it (null); Not now (`forget`) ends it at once.
    @Test func theReopenOfferIsGoneOnceAnswered() throws {
        let one = Self.entry("one", project: "a", folder: "/w/a", conversation: UUID().uuidString.lowercased())
        let two = Self.entry("two", project: "b", folder: "/w/b", conversation: UUID().uuidString.lowercased())
        let restart = EngineState.Restart(at: 1_800_000_000, before: 1_799_990_000, gone: [], sessions: [one, two])

        var chosen = restart
        #expect(chosen.takeOffered([one.id]).map(\.id) == [one.id])
        #expect(LeadEngine.reopenOffer(chosen)["sessions"]?.array?.map { $0["name"] } == [.string("two")])
        #expect(chosen.takeOffered([one.id]).isEmpty, "taken once")
        #expect(chosen.takeOffered([two.id]).map(\.id) == [two.id])
        #expect(LeadEngine.reopenOffer(chosen) == .null && chosen.sessions == nil)

        var forgotten = restart
        #expect(forgotten.forgetOffered() == 2)
        #expect(LeadEngine.reopenOffer(forgotten) == .null)
        #expect(forgotten.forgetOffered() == 0)
    }

    /// A server without an engine (no record of the user's sessions) sends no offer and no audit: the page's `node`
    /// carries both, null and empty, and the command line's `status` the same.
    @Test func aServerWithoutAnEngineOffersNothing() {
        let queue = DispatchQueue(label: "engine")
        let link = HostLink(dialer: NoHost(), root: scratch.url("link-root"), queue: queue)
        let requests = Requests(link: link, sessions: nil, rule: VoiceRule(mode: .weaker, scopes: [], uid: getuid(), says: "a test's"),
                                root: scratch.url("node-root"), hostSocket: "/nonexistent/host.sock", commit: "abc123", hostPID: 1)
        for forPage in [false, true] {
            let status = queue.sync { requests.statusValue(forPage: forPage) }
            #expect(status["reopenOffer"] == .null && status["promptAudits"] == .array([]), "\(forPage): \(status)")
        }
        let store = NodeStatusStore(requests: requests)
        queue.sync { store.look() }
        let node = store.changes.values[NodeIds.node]
        #expect(node?["reopenOffer"] == .null && node?["promptAudits"] == .array([]), "\(String(describing: node))")
        #expect(WireSchema.check(node ?? .null, as: "node") == nil, "\(WireSchema.check(node ?? .null, as: "node") ?? "")")
    }

    private struct NoHost: HostDialer {
        func connect(queue: DispatchQueue, patience: TimeInterval) throws -> HostConnection { throw HostLink.Failure("no host in this test") }
    }

    // MARK: C4: the prompt audits due

    private final class Roots: PromptAuditLeads {
        let roots: Set<String>
        init(_ roots: Set<String>) { self.roots = roots }
        var promptAuditRoots: Set<String> { roots }
    }

    /// Each project due an audit, by why: the interval (its days, whether a run was seen) or a model change (from, to),
    /// with its folder (what `prompt-audit` takes) and its lead's session (what Run it sends to), or null; none: empty.
    @Test func eachDueAuditIsAValueOfWhyAndWhatItsButtonsTake() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PromptAuditWatch.value([:], now: now, session: { _ in "local:x" }) == .array([]))
        let due: [String: PromptAudit.Due] = [
            "/w/site": .interval(since: now - 15 * 86_400, ranBefore: false),
            "/w/api": .modelChanged(from: "claude-opus-5", to: "claude-opus-5-5"),
            "/w/docs": .interval(since: now - 21 * 86_400, ranBefore: true),
        ]
        let value = PromptAuditWatch.value(due, now: now, session: { $0 == "/w/site" ? "local:lead-site" : nil })
        let audits = try #require(value.array, "\(value)")
        #expect(audits.map { $0["folder"] } == [.string("/w/api"), .string("/w/docs"), .string("/w/site")])
        #expect(audits.map { $0["project"] } == [.string("api"), .string("docs"), .string("site")])
        #expect(audits[0]["reason"] == .string("model") && audits[0]["from"] == .string("claude-opus-5") && audits[0]["to"] == .string("claude-opus-5-5"))
        #expect(audits[1]["reason"] == .string("interval") && audits[1]["days"] == .int(21) && audits[1]["ranBefore"] == .bool(true))
        #expect(audits[2]["days"] == .int(15) && audits[2]["ranBefore"] == .bool(false) && audits[2]["session"] == .string("local:lead-site"))
        #expect(audits[0]["session"] == .null)
        let text = String(decoding: NodeWire.line(value), as: UTF8.self)
        #expect(!text.contains("vibeswitcher") && !text.contains(PromptAudit.command), "\(text)")
        for audit in audits { #expect(WireSchema.check(audit, as: "node.promptAudit", strict: true) == nil, "\(audit)") }
    }

    /// The watch's own: a project due after the interval is in its value; Remind me in a week takes it out, and so
    /// does Not for this project for another; nothing else changes what's due.
    @Test func aDueAuditIsGoneOnceSnoozedOrTurnedOff() async throws {
        let root = scratch.url("node")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = DispatchQueue(label: "engine")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (site, api) = ("/w/site", "/w/api")
        var book = PromptAudit.Book()
        for project in [site, api] { book.projects[project] = PromptAudit.Project(firstSeen: now - 15 * 86_400) }
        try book.save(to: root.appendingPathComponent("prompt-audit.json"))
        let watch = PromptAuditWatch(queue: queue, root: root, home: scratch.url("home").path, clock: nil, note: { _ in })
        let leads = Roots([site, api])
        watch.leads = leads
        watch.now = { now }
        let value = { queue.sync { watch.value(session: { _ in nil }) }.array?.compactMap { $0["folder"]?.string } ?? [] }

        let looked = Locked(false)
        queue.async { watch.look { looked.value = true } }
        try #require(await eventually { looked.value })
        #expect(value() == [api, site])

        for (folder, change, left) in [(site, PromptAuditWatch.Change.snooze, [api]), (api, .off, [])] {
            let done = Locked(false)
            queue.async { watch.change(root: folder, change) { _ in done.value = true } }
            try #require(await eventually { done.value })
            #expect(value() == left, "\(change)")
        }
    }

    // MARK: B10: each setting's page rule

    /// Every setting the node lists carries its page rule, the catalog's own: `sets` (no why), `lowersOnly` and
    /// `terminalOnly` (each with its why); the ones the page used to guess among them.
    @Test func everySettingCarriesItsPageRule() throws {
        for setting in NodeSettings.all {
            let typed = NodeSettings.Shown(setting: setting, value: "", defaultValue: "", place: "").typed
            #expect(typed.page == setting.page.word && typed.pageWhy == setting.page.why, "\(setting.key)")
            #expect(NodeSettings.Page.words.contains(typed.page ?? ""), "\(setting.key)")
            #expect((typed.page == "sets") == (typed.pageWhy == nil), "\(setting.key)")
            let wire = NodeSettings.Shown(setting: setting, value: "", defaultValue: "", place: "").wire
            #expect(WireSchema.check(wire, as: "setting", strict: true) == nil, "\(setting.key): \(WireSchema.check(wire, as: "setting", strict: true) ?? "")")
        }
        let rule = { (key: String) in NodeSettings.setting(key).map { NodeSettings.Shown(setting: $0, value: "", defaultValue: "", place: "").typed.page } }
        for key in ["lead_mail", "verifier_model", "security_audit_model", "max_workers", "policy", "floor_merge_policy"] {
            #expect(rule(key) == "terminalOnly", "\(key)")
        }
        #expect(rule("web_acts") == "lowersOnly")
        for key in ["node_heavy_slots", "boost", "lead_model", "prompt_audit"] { #expect(rule(key) == "sets", "\(key)") }
    }

    /// A plugin's setting is the terminal's, and says so.
    @Test func aPluginsSettingCarriesTheTerminalsRule() throws {
        let setting = PluginInfo.Setting(key: "allow", title: "Allowed commands", about: "What runs without asking.", form: "text")
        let typed = NodeSettings.Shown(setting: LeadEngine.catalogSetting(ShellPlugin(), setting), value: "", defaultValue: "", place: "").typed
        #expect(typed.page == "terminalOnly" && typed.pageWhy?.isEmpty == false, "\(typed)")
    }

    /// Additive on the wire: the fields a setting had are as they were, `page` and `pageWhy` beside them; a reader of
    /// the setting from before them (an older page or command line) decodes it as before; and a reply from a node
    /// before them decodes with no rule (the page then offers no Set) and is written again unchanged.
    @Test func thePageRuleIsAdditive() throws {
        let setting = try #require(NodeSettings.setting("max_workers"))
        let wire = NodeSettings.Shown(setting: setting, value: "4", defaultValue: "4", place: "workflow.md").wire
        let before: Set<String> = ["key", "title", "about", "section", "scope", "form", "home", "choices", "limits", "value", "default", "isDefault",
                                   "where", "guardRail", "note"]
        let keys = Set(wire.object?.keys.map { $0 } ?? [])
        #expect(keys.subtracting(before) == ["page", "pageWhy"] && before.isSubset(of: keys), "\(keys)")

        struct Older: Decodable, Equatable {
            var key: String, title: String, scope: String, form: String, value: String, guardRail: Bool
            var note: String?
        }
        let older = try JSONDecoder().decode(Older.self, from: NodeWire.line(wire))
        #expect(older == Older(key: "max_workers", title: setting.title, scope: "project", form: "count", value: "4", guardRail: setting.guardRail, note: nil))

        var old = try #require(wire.object)
        old["page"] = nil
        old["pageWhy"] = nil
        let typed = try NodeWire.Value.object(old).wire(WireKinds.Settings.Setting.self)
        #expect(typed.page == nil && typed.pageWhy == nil)
        #expect(NodeWire.line(typed) == NodeWire.line(NodeWire.Value.object(old)))
    }

    /// The node is the enforcer: a page's `set` of each setting is refused exactly where its rule (as `settings` sends
    /// it) says a page may not set it, whatever the page offered: every `terminalOnly` one, `web_acts` raised; never a
    /// `sets` one. (On a node with acting off, as a fresh one is: `web_acts` may go only to off.)
    @Test func theNodeRefusesWhatTheRuleForbidsWhateverThePageSends() {
        let queue = DispatchQueue(label: "engine")
        let link = HostLink(dialer: NoHost(), root: scratch.url("link-root"), queue: queue)
        let requests = Requests(link: link, sessions: nil, rule: VoiceRule(mode: .weaker, scopes: [], uid: getuid(), says: "a test's"),
                                root: scratch.url("node-root"), hostSocket: "/nonexistent/host.sock", commit: "abc123", hostPID: 1)
        let refusal = { (key: String, value: String) in
            queue.sync { requests.pageSetRefusal(NodeWire.Request(id: "1", kind: "set", args: ["key": .string(key), "value": .string(value)])) }
        }
        for setting in NodeSettings.all {
            let rule = NodeSettings.Shown(setting: setting, value: "", defaultValue: "", place: "").typed.page
            switch rule {
            case "sets": #expect(refusal(setting.key, "1") == nil, "\(setting.key)")
            case "terminalOnly":
                for value in ["1", "on", "default", "opus"] { #expect(refusal(setting.key, value)?.contains("from a terminal") == true, "\(setting.key) \(value)") }
            default:
                #expect(rule == "lowersOnly" && setting.key == "web_acts", "\(setting.key)")
                for value in ["trust", "confirm", "TRUST", " off"] { #expect(refusal(setting.key, value) != nil, "\(value)") }
                for value in ["off", "default"] { #expect(refusal(setting.key, value) == nil, "\(value)") }
            }
        }
    }
}
