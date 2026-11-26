import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher status [--long] [--json]`: the node as its server sees it (sessions, leads, cards, the user's-voice requests
/// it accepted, its notices, the host's notes), with what the command line reads itself (the engine plan's E1,
/// EN-D15): the machine's facts (`NodeFacts`, the standing plain-mode line first) and the journal (starts, stops and
/// server restarts nothing explains, until acknowledged; accepted requests the journal has no entry for; entries from
/// a cgroup that isn't a terminal's). With no node it exits 69, naming `status --probe`. The default is 8 lines at most
/// (2026-11-25, the text walk after a switch: 17 to 22 lines every time): the node and its build, the page, the
/// sessions and leads, the open cards, what waits on the user with the command that settles each kind, and one line for
/// anything wrong; `--long` says everything, as before.
///
/// `vibeswitcher status --probe [--json]`: stage 1's local read, without the server: the agent sessions on this machine
/// (`LocalSessions`), one line each: terminal, agent, folder, status, since when.
///
/// `vibeswitcher status --health [--json]`: the server's health digest only (`NodeHealth`: freezes of the engine's queue,
/// slow refreshes, the host's restarts and refused connections, sessions left waiting or stuck, the server's last errors).
///
/// `vibeswitcher status --check-updates [--json]`: Check for Updates now (`UpdateWatch`, as the 6 h watch looks and into
/// its record): the newer build on v2 both CI runs passed and its install line, or that there is none, or why it
/// couldn't look (exit 1). Read-only: it installs nothing.
///
/// `vibeswitcher status --ack`: acknowledges what the journal shows (a journal entry the command line writes after the
/// typed code), never a server request.
enum StatusCommand {
    static let usage = "usage: vibeswitcher status [--long] [--json] | status --health [--json] | status --probe [--json] | status --check-updates [--json] | status --ack"

    /// The JSON form's version.
    static let format = 1

    static func run(_ arguments: [String]) -> Int32 {
        let words = Set(arguments)
        guard words.count == arguments.count, words.isSubset(of: ["--json", "--long", "--probe", "--ack", "--health", "--check-updates"]),
              !(words.contains("--long") && !words.isSubset(of: ["--long", "--json"])),
              !(words.contains("--ack") && words.count > 1), words.intersection(["--health", "--probe", "--check-updates"]).count < 2 else { return Say.usage(usage) }
        if words.contains("--check-updates") { return checkUpdates(json: words.contains("--json")) }
        if words.contains("--probe") { return probe(json: words.contains("--json")) }
        if words.contains("--ack") { return acknowledge() }
        return throughServer(json: words.contains("--json"), health: words.contains("--health"), long: words.contains("--long"))
    }

    /// `--check-updates`: the server's `update.check`, said as `UpdateWatch.lines` (with `json`, its object).
    static func checkUpdates(json asJSON: Bool) -> Int32 {
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let checked: WireKinds.UpdateCheck.Result, raw: NodeWire.Value
        switch client.read(WireKinds.UpdateCheck.self, WireNoArgs(), timeout: Requests.updateCheckPatience) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let given, let whole): (checked, raw) = (given, whole)
        }
        if asJSON {
            Platform.Stdio.output(NodeWire.printable(NodeWire.line(raw)))
        } else {
            Say.out(UpdateWatch.lines(checked).joined(separator: "\n"))
        }
        return checked.problem == nil ? 0 : 1
    }

    /// Stage 1's read, as it was.
    static func probe(json asJSON: Bool) -> Int32 {
        guard let sessions = LocalSessions().read() else {
            Platform.Stdio.error("vibeswitcher: the process table couldn't be read; try again\n")
            return 1
        }
        let text = asJSON ? json(sessions) : lines(sessions)
        return Platform.Stdio.output(text + "\n") ? 0 : 1
    }

    /// `health`: only the health digest (`NodeHealth.lines`; with `json`, its object).
    static func throughServer(json asJSON: Bool, health: Bool = false, long: Bool = false) -> Int32 {
        let context = NodeContext.current()
        // The Mac: the user's node's LaunchAgent says first whether its host runs, and its build (MacAgentCommand.swift);
        // reached only once the Mac's refusal (`usersNodeRefusal`) is lifted.
        if MacAgent.statusChecksHost(onTheMac: Platform.Service.manager == .launchd, isScratch: context.isScratch, refused: context.usersNodeRefusal != nil,
                                     json: asJSON), let code = MacAgentCommand.status(json: asJSON) { return code }
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure):
            if case .notRunning = failure {
                Say.err("vibeswitcher: \(failure.message); `vibeswitcher status --probe` reads this machine's sessions without it")
                return 69
            }
            return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let result: WireKinds.Status.Result, raw: NodeWire.Value
        switch client.read(WireKinds.Status.self, WireNoArgs()) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let given, let whole): (result, raw) = (given, whole)
        }
        if health {
            guard let digest = result.health, digest != .null else { return Say.refused("this node's server keeps no health digest (an older build)") }
            if asJSON {
                Platform.Stdio.output(NodeWire.printable(NodeWire.line(digest)))
            } else {
                Say.out(NodeHealth.lines(digest).joined(separator: "\n"))
            }
            return 0
        }
        let facts = context.facts()
        // A node started detached: the weaker rule, and its pid file any worker can write (the start plan's S3).
        let modeLines = NodeTexts.statusLines(mode: context.mode)
        let journal = journalLines(context, accepted: result.accepted ?? [], epoch: result.epoch, restart: result.restart, long: long || asJSON)
        if asJSON {
            var report = raw.object ?? [:]
            report["format"] = .int(format)
            report["facts"] = .array((facts.lines + modeLines).map(NodeWire.Value.string))
            report["startLine"] = .string(StartCheck.startLine(facts: facts))
            report["journal"] = .array(journal.map(NodeWire.Value.string))
            let data = NodeWire.printable(NodeWire.line(NodeWire.Value.object(report)))
            Platform.Stdio.output(data)
            return 0
        }
        guard long else {
            Say.out(short(result, modeLines: modeLines, journal: journal).joined(separator: "\n"))
            return 0
        }
        var out: [String] = []
        let server = result.server, host = result.host
        out.append("node \(inert(result.node)), server pid \(server?.pid.map(String.init) ?? "?") since \(inert(server?.startedAt)), build \(inert(server?.commit))")
        let notes = host?.notes
        // The host's pid (its welcome's) and its build (its notes', the build-info its start checked; the start plan's S5).
        out.append("host pid \(host?.pid.map(String.init) ?? "?") since \(inert(host?.startedAt)) (\(inert(host?.state)))"
                   + (notes != nil ? ", server restarts: \(notes?.serverRestarts ?? 0), refused app connections: \(notes?.refusedAppConnections ?? 0)" : "")
                   + ", build \(notes?.build.map { inert($0) } ?? "unknown")")
        for path in notes?.replacedPaths ?? [] { out.append("the host took back its path \(inert(path))") }
        out += facts.lines + modeLines
        out.append("after a stop, start it with: \(StartCheck.startLine(facts: facts))")
        out.append("voice rule: \(inert(result.rule?.says))")
        if let line = webLine(result.web) { out.append(line) }
        if let line = tailnetLine(result.webTailnet) { out.append(line) }
        out += NodeUsage.lines(result.usage)
        if let line = LeadEngine.boostLine(result.boost) { out.append(line) }
        let sessions = result.sessions ?? []
        out.append(sessions.isEmpty ? "No agent sessions." : "sessions:")
        for session in sessions {
            let name = session["name"]?.string.map { "  \u{201C}\(inert($0))\u{201D}" } ?? ""
            let paused = session["pausedUntil"]?.string == nil ? "" : "  (paused)"
            out.append("  \(inert(session["terminal"]?.string))  \(inert(session["agent"]?.string))  \(inert(session["cwd"]?.string))  \(inert(session["status"]?.string))\(name)\(paused)")
        }
        out += CardText.statusLines(leads: result.leads ?? [], cards: result.cards.map(NodeWire.Value.init(wire:)))
        if let line = waitingLine(result.cards) { out.append(line) }
        // What a build switch would wait on now, each with what it does and since when (the rule on switches).
        let holders = (result.switchBlockers ?? []).map { inert($0) }
        if !holders.isEmpty { out.append("a build switch waits now on: " + holders.joined(separator: "; ")) }
        let parks = (result.switchParks ?? []).map { inert($0) }
        if !parks.isEmpty { out.append("a build switch would park first (idle since their last report): " + parks.joined(separator: ", ")) }
        // The feature plugins that are on (a server before them says nothing).
        if let plugins = result.plugins?.array {
            out.append("plugins on: " + (plugins.isEmpty ? "none" : plugins.map { inert($0["id"]?.string) }.joined(separator: ", ")) + " (`vibeswitcher plugin list`)")
        }
        // What was done in the user's voice: its kind, when, and from where (`NodeTexts.acceptedLine`).
        for accepted in result.accepted ?? [] { out.append(NodeTexts.acceptedLine(accepted, ruleMode: result.rule?.mode)) }
        for notice in result.notices ?? [] { out.append("notice: \(inert(notice))") }
        if let line = updateLine(result.update) { out.append(line) }
        out += journal
        Say.out(out.joined(separator: "\n"))
        return 0
    }

    /// The default `status`: 8 lines at most. The node and its build; the page and whether it can act; the sessions and
    /// leads, counted; the open cards; what waits on the user, each kind with the command that settles it; and the first
    /// thing wrong (a restart not yet acknowledged, the unit's last failure, a start or stop nothing explains, a path the
    /// host took back, a notice), with how many more; then where the rest is (`--long`).
    static func short(_ result: WireKinds.Status.Result, modeLines: [String], journal: [String]) -> [String] {
        var out: [String] = []
        let build = result.server?.commit.map { String($0.prefix(12)) } ?? "?"
        out.append("node \(inert(result.node)): build \(inert(build)), up since \(inert(result.server?.startedAt))")
        out.append(shortWebLine(result.web, tailnet: result.webTailnet))
        let sessions = result.sessions ?? []
        let agents = Dictionary(grouping: sessions.compactMap { $0["agent"]?.string }, by: { $0 }).map { "\($0.value.count) \(inert($0.key))" }.sorted()
        let leads = (result.leads ?? []).compactMap { $0["root"]?.string }.map { inert(($0 as NSString).lastPathComponent) }
        out.append("sessions: \(sessions.count)" + (agents.isEmpty ? "" : " (\(agents.joined(separator: ", ")))")
                   + "; leads: \(leads.count)" + (leads.isEmpty ? "" : " (\(leads.joined(separator: ", ")))"))
        let cards = result.cards
        func counted(_ count: Int?, _ one: String, _ many: String) -> String? {
            guard let count, count > 0 else { return nil }
            return "\(count) \(count == 1 ? one : many)"
        }
        let open = [counted(cards?.questions, "question", "questions"), counted(cards?.approvals, "approval", "approvals"),
                    counted(cards?.config, "held config", "held config"), counted(cards?.base, "base move", "base moves")].compactMap { $0 }
        out.append("open cards: " + (open.isEmpty ? "none" : open.joined(separator: ", ")))
        if let line = waitingLine(cards) { out.append(line) }
        let wrong = wrongLines(result, modeLines: modeLines, journal: journal)
        if let first = wrong.first {
            out.append("needs a look: \(first)" + (wrong.count > 1 ? "; and \(wrong.count - 1) more" : ""))
        }
        out.append("more: vibeswitcher status --long")
        return out
    }

    /// The page in one line: its address (and the tailnet's), and whether it can act.
    static func shortWebLine(_ web: NodeWire.Value?, tailnet: NodeWire.Value?) -> String {
        guard let web, let state = web["state"]?.string else { return "web: not known (an older server)" }
        let level = web["acts"]?["level"]?.string ?? (web["acts"]?["on"]?.bool == true ? "trust" : "off")
        let acts: String
        switch level {
        case "trust": acts = "the page acts as you at each click"
        case "confirm": acts = "the page acts with your passkey"
        default: acts = "the page reads and drafts, it can't act"
        }
        let there = tailnet?["state"]?.string == "listening"
            ? " and http://\(inert(tailnet?["name"]?.string)):\(tailnet?["port"]?.int.map(String.init) ?? "?")/ on the tailnet" : ""
        switch state {
        case "off": return "web: off (`vibeswitcher web` opens it)"
        case "listening":
            let pages = web["connections"]?.int ?? 0
            return "web: http://127.0.0.1:\(web["port"]?.int.map(String.init) ?? "?")/\(there), \(pages) page\(pages == 1 ? "" : "s") open; \(acts)"
        default: return "web: \(inert(state))"
        }
    }

    /// What waits on the user, each kind with the one command that settles it: held config and base moves
    /// `vibeswitcher approve` takes with one code, and those it sets aside by their own command (held config whose accept
    /// records the project's rules: `config held FOLDER`; a base that moved from a commit the node hadn't recorded:
    /// `base show FOLDER`), and the questions and approvals to answer. Nil when nothing waits.
    static func waitingLine(_ cards: WireKinds.Status.CardCounts?) -> String? {
        guard let cards else { return nil }
        let own = cards.own ?? []
        var parts: [String] = []
        let batch = max(0, (cards.config ?? 0) + (cards.base ?? 0) - own.count)
        if batch > 0 { parts.append("\(batch) to accept: `vibeswitcher approve`") }
        // Each set aside with its card's own command (`CardStore.Card.settle`, the one the page and `approve` say too).
        for card in own {
            let what = card.kind == "config" ? "rules to confirm" : "a base move"
            parts.append("\(what) in \(inert((card.folder as NSString).lastPathComponent)): `\(inert(card.settle))`")
        }
        let answers = (cards.questions ?? 0) + (cards.approvals ?? 0)
        if answers > 0 { parts.append("\(answers) to answer: `vibeswitcher questions`") }
        return parts.isEmpty ? nil : "waiting on you: " + parts.joined(separator: "; ")
    }

    /// What is wrong, most pressing first, each in a few words with what to do: the host not connected, a restart not
    /// yet acknowledged, the journal's warnings, a path the host took back, the mode's warning, the server's notices.
    static func wrongLines(_ result: WireKinds.Status.Result, modeLines: [String], journal: [String]) -> [String] {
        var wrong: [String] = []
        if let state = result.host?.state, state != "connected" { wrong.append("the node's host is \(inert(state))") }
        if let unchecked = NodeTexts.uncheckedNotice(result.accepted ?? [], ruleMode: result.rule?.mode) { wrong.append(unchecked) }
        // The journal's lines but its informational ones (the last start's line, no journal to read on a scratch node).
        wrong += journal.filter { line in
            !line.hasPrefix("journal: the node's last start at") && !line.hasPrefix("journal: no ")
                && !(line.hasPrefix("the node's unit last ended: success"))
        }.map { $0.hasPrefix("journal: ") ? String($0.dropFirst("journal: ".count)) : $0 }
        wrong += (result.host?.notes?.replacedPaths ?? []).map { "the host took back its path \(inert($0))" }
        wrong += modeLines
        wrong += (result.notices ?? []).map(inert)
        return wrong
    }

    /// The last update check's answer when it has nothing to offer (a newer build is a notice): up to date, or why it
    /// couldn't look. Nil before a look, and on a server that doesn't check (a scratch node).
    static func updateLine(_ update: NodeWire.Value?) -> String? {
        guard let update, update != .null, update["commit"]?.string == nil else { return nil }
        if let problem = update["problem"]?.string { return "updates: couldn't check v2 for a newer build (\(inert(problem)))" }
        guard let at = update["checkedAt"]?.string else { return nil }
        return "updates: no newer build on v2 that both CI runs passed (checked \(inert(at)))"
    }

    /// What the journal says that the user should see (EN-D15): a host restart the server saw (`restart`, E8) with how
    /// the host ended and whether a `vibeswitcher start` explains it, until acknowledged; unexplained starts, stops and
    /// server restarts not yet acknowledged, how the unit's last process ended, and `NodeJournal.marks` (given the
    /// server's `epoch`).
    static func journalLines(_ context: NodeContext, accepted: [NodeWire.Value], epoch: String?, restart: NodeWire.Value? = nil, long: Bool = true) -> [String] {
        let entries: [JournalEntry]
        let state = context.unitState()
        let ended = state?.result.map { "it last ended \(inert($0)), status \(inert(state?.execMainStatus))" }
        switch context.journalEntries() {
        case .failure(let failure):
            // Without a journal the restart is still said, and that nothing here can say how the host ended.
            return restartLines(restart, ended: ended ?? "how it ended isn't known (\(failure.reason))", explained: nil, acknowledged: false, long: long)
                + ["journal: \(failure.reason)"]
        case .success(let read): entries = read
        }
        let rule = context.journalRule
        var lines: [String] = []
        if let at = restart?["at"]?.string.flatMap(NodeWire.date) {
            let event = NodeJournal.Event(kind: .start, at: at)
            lines += restartLines(restart, ended: ended ?? "how it ended isn't known (the node's unit says nothing)",
                                  explained: NodeJournal.unexplained(starts: [event], entries: entries, rule: rule).isEmpty,
                                  acknowledged: NodeJournal.acknowledged(event, entries: entries, rule: rule), long: long)
        }
        if let state, let result = state.result {
            lines.append("the node's unit last ended: \(inert(result)), status \(inert(state.execMainStatus)), started \(inert(state.execMainStartTimestamp))")
        }
        // Each start with the host's line, taken only from the unit's main pid and the user (ST-D24, the start plan's S5).
        let events = NodeJournal.events(entries, mainPID: state?.execMainPID, uid: rule.uid)
        if let last = events.last(where: { $0.kind == .start }), let detail = last.detail {
            lines.append("journal: the node's last start at \(NodeWire.dateText(last.at)): \(inert(detail))")
        }
        for event in NodeJournal.unexplained(starts: events, entries: entries, rule: rule)
            where !NodeJournal.acknowledged(event, entries: entries, rule: rule) {
            lines.append("journal: a \(event.kind.rawValue) at \(NodeWire.dateText(event.at)) that no `vibeswitcher start` or `stop` explains (`vibeswitcher status --ack` once read)"
                         + (event.detail.map { "; its host said: \(inert($0))" } ?? ""))
        }
        let requests = accepted.map { ($0["kind"]?.string ?? "?", $0["action"]?.string, $0["at"]?.string.flatMap(NodeWire.date)) }
        lines += NodeJournal.marks(accepted: requests, epoch: epoch, entries: entries, rule: rule).map { "journal: " + $0 }
        return lines
    }

    /// The host restart the server saw (E8), until acknowledged: when, what it reset, how the host before ended
    /// (`ended`) and whether a `vibeswitcher start` or `stop` entry explains it (`explained`; nil: no journal to ask).
    /// Not `long`: what happened and what to do, in one line; `long`: how the host before ended, whether a start explains
    /// it, and what the restart reset.
    static func restartLines(_ restart: NodeWire.Value?, ended: String, explained: Bool?, acknowledged: Bool, long: Bool = true) -> [String] {
        guard let restart, let at = restart["at"]?.string, !acknowledged else { return [] }
        guard long else { return ["the node restarted at \(inert(at)): it asks you to confirm each project's rules once (`vibeswitcher status --ack` once read)"] }
        let explains: String
        switch explained {
        case true?: explains = "a `vibeswitcher start` or `stop` entry in the journal explains it"
        case false?: explains = "no `vibeswitcher start` or `stop` entry in the journal explains it"
        case nil: explains = "whether you started it can't be read"
        }
        return ["restart: the node restarted at \(inert(at)) (the one before started at \(inert(restart["before"]?.string))): it asks you to confirm "
                + "each project's rules once; \(ended); \(explains); what it forgot: \(inert(restart["reset"]?.string)) (`vibeswitcher status --ack` once read)"]
    }

    /// `status --ack`: the journal entry that clears what it shows, after the typed code.
    static func acknowledge() -> Int32 {
        let context = NodeContext.current()
        if let unbuilt = context.usersNodeRefusal { return Say.unbuilt(unbuilt) }
        context.sayScratch()
        guard context.journalSocket != nil else { return Say.refused(NodeContext.noStandIn) }
        let action = UUID().uuidString.lowercased()
        let outcome = TypedWord.ask(code: NodeIds.code(action: action), what: "This acknowledges the starts, stops and restarts the journal shows.")
        guard outcome == .typed else { return Say.refused(TypedWord.refusal(outcome)) }
        guard context.writeJournal(NodeJournal.entry(event: "ack", action: action)) else {
            Say.err("vibeswitcher: the acknowledgment couldn't be written to the journal")
            return 1
        }
        Say.out("acknowledged")
        return 0
    }

    /// Untrusted text for the terminal (`ConfigSeal.inert`, no length limit).
    static func inert(_ text: String?) -> String { ConfigSeal.inert(text ?? "?", limit: .max) }

    /// `status`'s `web` (the live plan's I1) as one line: the page's address while it listens, with the tokens and
    /// pages, or why the port couldn't be had; nil from a server that doesn't say.
    static func webLine(_ web: NodeWire.Value?) -> String? {
        guard let web, let state = web["state"]?.string else { return nil }
        let tokens = web["tokens"]?.int ?? 0, connections = web["connections"]?.int ?? 0
        // Acting from the page (its level, since when, the acting pages open); and that pairings are the host's vault's.
        let acts = web["acts"].map { acts -> String in
            let level = acts["level"]?.string ?? (acts["on"]?.bool == true ? "on" : "off")
            let since = acts["since"]?.string.flatMap(NodeWire.date).map { " since \(NodeWire.dateText($0))" } ?? ""
            return "; acting from the page: \(inert(level))\(level == "off" ? "" : since)" + ((acts["pages"]?.int ?? 0) > 0 ? ", \(acts["pages"]?.int ?? 0) acting" : "")
        } ?? ""
        let vault = "; pairings are kept by the host: after a host restart, pair each page again (`vibeswitcher web`)"
        switch state {
        case "off": return "web: off (`vibeswitcher web` opens it)" + (tokens > 0 ? "; \(tokens) tokens alive" : "") + acts
        case "listening":
            return "web: http://127.0.0.1:\(web["port"]?.int.map(String.init) ?? "?")/, \(tokens) tokens alive, \(connections) pages open" + acts + vault
        default: return "web: \(inert(state))"
        }
    }

    /// The user's node's page on the tailnet (`web --tailnet`), when the server has one.
    static func tailnetLine(_ web: NodeWire.Value?) -> String? {
        guard let web, let state = web["state"]?.string else { return nil }
        let tokens = web["tokens"]?.int ?? 0, connections = web["connections"]?.int ?? 0
        switch state {
        case "off": return "web on the tailnet: off (`vibeswitcher web --tailnet` opens it)" + (tokens > 0 ? "; \(tokens) tokens alive" : "")
        case "listening":
            let place = "http://\(inert(web["name"]?.string)):\(web["port"]?.int.map(String.init) ?? "?")/ (\(inert(web["address"]?.string)))"
            return "web on the tailnet: \(place), \(tokens) tokens alive, \(connections) pages open"
        default: return "web on the tailnet: \(inert(state))"
        }
    }

    /// `{"format":1,"node":"local","sessions":[{"id","terminal","agent","cwd","status","since"}]}`: `cwd` null when
    /// it isn't known, `since` an ISO 8601 date.
    static func json(_ sessions: [LocalSession]) -> String {
        let dates = ISO8601DateFormatter()
        let report: [String: Any] = [
            "format": format,
            "node": LocalSessions.node,
            "sessions": sessions.map { session -> [String: Any] in
                ["id": session.id, "terminal": session.terminal, "agent": session.agent.rawValue,
                 "cwd": session.cwd ?? NSNull(), "status": session.statusWord, "since": dates.string(from: session.since)]
            },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: NodeWire.printable(data), as: UTF8.self)
    }

    /// One line a session, in columns: `ttypts3  claude  /home/me/project  needs you  since 14:03:21`.
    static func lines(_ sessions: [LocalSession]) -> String {
        guard !sessions.isEmpty else { return "No agent sessions." }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd HH:mm"
        let rows = sessions.map { session in
            [session.terminal, session.agent.rawValue, session.cwd ?? "?", session.status.word.text,
             "since " + (Calendar.current.isDateInToday(session.since) ? clock : day).string(from: session.since)]
        }
        let widths = (0..<4).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { column, word in
                column < widths.count ? word.padding(toLength: widths[column], withPad: " ", startingAt: 0) : word
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
