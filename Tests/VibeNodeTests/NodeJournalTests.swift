import Foundation
import Testing
import VibeCore
import VibeNode

/// The journal as the command line reads it (`NodeJournal`, the engine plan's EN-D15), on a stand-in `journalctl -o
/// json`'s output: an entry counts for what journald's own fields say (`_UID`, `_SYSTEMD_CGROUP`), never for what it
/// carries. The Mac runs these.
struct NodeJournalTests {
    static let uid: uid_t = 1000
    static let rule = VoiceRule(mode: .systemd, scopes: VoiceRule.terminalScopes, uid: uid, says: "test")
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// One line of `journalctl -o json`.
    static func line(_ fields: [String: Any], at date: Date) -> String {
        var all = fields
        all["__REALTIME_TIMESTAMP"] = String(Int64(date.timeIntervalSince1970 * 1_000_000))
        let data = try! JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// systemd's line for the node's unit's start (or stop).
    static func job(_ type: String, boot: String? = nil, at date: Date) -> String {
        var fields: [String: Any] = ["USER_UNIT": "vibeswitcher-node.service", "JOB_TYPE": type, "JOB_RESULT": "done",
                                     "MESSAGE": "Started vibeswitcher-node.service.", "_UID": "1000",
                                     "_SYSTEMD_CGROUP": "/user.slice/user-1000.slice/user@1000.service/init.scope"]
        if let boot { fields["_BOOT_ID"] = boot }
        return line(fields, at: date)
    }

    /// An entry of the command line's, from `cgroup` (nil: journald recorded none, its writer had ended), sent with
    /// the nonce `entry` when given.
    static func own(_ event: String, kind: String? = nil, action: String? = nil, epoch: String? = nil, cgroup: String? = "/init.scope",
                    uid: String = "1000", entry: String? = nil, at date: Date) -> String {
        var fields: [String: Any] = ["SYSLOG_IDENTIFIER": "vibeswitcher", "VIBESWITCHER_EVENT": event, "MESSAGE": "vibeswitcher \(event)",
                                     "_UID": uid]
        if let cgroup { fields["_SYSTEMD_CGROUP"] = cgroup }
        if let entry { fields[NodeJournal.entryField] = entry }
        if let kind { fields["VIBESWITCHER_KIND"] = kind }
        if let epoch { fields["VIBESWITCHER_EPOCH"] = epoch }
        if let action { fields["VIBESWITCHER_ACTION"] = action }
        return line(fields, at: date)
    }

    static func read(_ lines: [String]) -> [JournalEntry] { NodeJournal.entries(json: lines.joined(separator: "\n")) }

    @Test func aStartTheJournalDoesntExplainIsMarkedUntilAcknowledged() throws {
        let entries = Self.read([Self.job("start", at: Self.start)])
        let events = NodeJournal.events(entries)
        #expect(events == [.init(kind: .start, at: Self.start)])
        let unexplained = NodeJournal.unexplained(starts: events, entries: entries, rule: Self.rule)
        #expect(unexplained == events)
        #expect(!NodeJournal.acknowledged(events[0], entries: entries, rule: Self.rule))
        // A `vibeswitcher start` of the user's a moment before explains it.
        let explained = Self.read([Self.own("request", kind: "start", at: Self.start.addingTimeInterval(-5)), Self.job("start", at: Self.start)])
        #expect(NodeJournal.unexplained(starts: NodeJournal.events(explained), entries: explained, rule: Self.rule).isEmpty)
        // One long before, or after it, doesn't.
        let stale = Self.read([Self.own("request", kind: "start", at: Self.start.addingTimeInterval(-600)), Self.job("start", at: Self.start),
                               Self.own("request", kind: "stop", at: Self.start.addingTimeInterval(5))])
        #expect(NodeJournal.unexplained(starts: NodeJournal.events(stale), entries: stale, rule: Self.rule).count == 1)
        // Acknowledged by a later ack of the user's.
        let acked = Self.read([Self.job("start", at: Self.start), Self.own("ack", at: Self.start.addingTimeInterval(30))])
        let event = try #require(NodeJournal.events(acked).first)
        #expect(NodeJournal.acknowledged(event, entries: acked, rule: Self.rule))
        // An ack from before it acknowledges nothing.
        let early = Self.read([Self.own("ack", at: Self.start.addingTimeInterval(-30)), Self.job("start", at: Self.start)])
        #expect(!NodeJournal.acknowledged(event, entries: early, rule: Self.rule))
        // The host's line for a server child ended is a server restart.
        let restart = Self.read([Self.line(["MESSAGE": "vibeswitcher-host: server child pid 77 ended after 12 s: killed by SIGKILL; started again in 1 s"], at: Self.start)])
        #expect(NodeJournal.events(restart) == [.init(kind: .serverRestart, at: Self.start)])
    }

    @Test func aForgedStartEntryFromAUserUnitDoesntClearTheMark() {
        let unit = "/user.slice/user-1000.slice/user@1000.service/app.slice/run-u7.service"
        let forged = Self.read([Self.own("request", kind: "start", cgroup: unit, at: Self.start.addingTimeInterval(-5)), Self.job("start", at: Self.start)])
        #expect(NodeJournal.unexplained(starts: NodeJournal.events(forged), entries: forged, rule: Self.rule).count == 1)
        // Nor one from another user, nor one with no cgroup, nor a forged ack.
        let other = Self.read([Self.own("request", kind: "start", uid: "1001", at: Self.start.addingTimeInterval(-5)), Self.job("start", at: Self.start)])
        #expect(NodeJournal.unexplained(starts: NodeJournal.events(other), entries: other, rule: Self.rule).count == 1)
        let ack = Self.read([Self.job("start", at: Self.start), Self.own("ack", cgroup: unit, at: Self.start.addingTimeInterval(9))])
        #expect(!NodeJournal.acknowledged(NodeJournal.events(ack)[0], entries: ack, rule: Self.rule))
        // A field the entry names `_UID` or `_SYSTEMD_CGROUP` is journald's, so a sender can't write it.
        #expect(entriesNameNoTrustedField())
    }

    /// The entries the command line writes can't carry journald's trusted fields (`Platform.Journal.encode` refuses
    /// them), so a forged `_SYSTEMD_CGROUP` never reaches the journal from it.
    private func entriesNameNoTrustedField() -> Bool {
        NodeJournal.entry(event: "request", action: "a", kind: "start").allSatisfy { !$0.name.hasPrefix("_") }
    }

    /// The host's start line (the start plan's S5, ST-D24), as journald records it from `pid` over `transport`.
    static func startLine(pid: Int, build: String = String(repeating: "a", count: 40), transport: String = "stdout", uid: String = "1000",
                          cgroup: String = "/user.slice/user-1000.slice/user@1000.service/app.slice/vibeswitcher-node.service",
                          boot: String? = nil, at date: Date) -> String {
        var fields: [String: Any] = ["MESSAGE": "vibeswitcher-host: started pid \(pid) build \(build) SWIFT_BACKTRACE=enable=no",
                                     "_PID": String(pid), "_TRANSPORT": transport, "_UID": uid, "_SYSTEMD_CGROUP": cgroup]
        if let boot { fields["_BOOT_ID"] = boot }
        return line(fields, at: date)
    }

    /// The review of S5 (2026-11-16): a line with the unit's main pid counts only from the unit's own cgroup, from the
    /// user, from the start's boot and from the start on. A pid outlives nothing: with `Restart=no` the unit's
    /// `ExecMainPID` names a dead pid once the host ends, which another process can be given, and a user unit started
    /// at login gets nearly the same pid each boot.
    @Test func aStartLineFromOutsideTheUnitOrBeforeItsStartIsNotTheHosts() throws {
        let host = 4242
        let at = Self.start.addingTimeInterval(1)
        let forged = String(repeating: "f", count: 40)
        let outside = [
            // From a scope outside the unit (`systemd-cat` in a terminal, given the dead host's pid).
            Self.startLine(pid: host, build: forged, cgroup: "/user.slice/user-1000.slice/user@1000.service/app.slice/app-term.scope", boot: "b1", at: at),
            // From another user.
            Self.startLine(pid: host, build: forged, uid: "1001", boot: "b1", at: at),
            // From another boot than the start's.
            Self.startLine(pid: host, build: forged, boot: "b2", at: at),
        ]
        // The same line from the unit, the user and the start's boot is the host's.
        let ours = Self.read([Self.job("start", boot: "b1", at: Self.start), Self.startLine(pid: host, boot: "b1", at: at)])
        #expect(NodeJournal.events(ours, mainPID: Int32(host), uid: Self.uid).first?.detail?.hasPrefix("pid \(host) ") == true)
        for line in outside {
            let events = NodeJournal.events(Self.read([Self.job("start", boot: "b1", at: Self.start), line]), mainPID: Int32(host), uid: Self.uid)
            #expect(events.count == 1 && events[0].detail == nil, "\(events)")
        }
        // Journald's `_SYSTEMD_USER_UNIT` names the unit too.
        let named = Self.read([Self.job("start", at: Self.start),
                               Self.line(["MESSAGE": "vibeswitcher-host: started pid \(host) build \(forged) SWIFT_BACKTRACE=unset", "_PID": String(host),
                                          "_TRANSPORT": "stdout", "_UID": "1000", "_SYSTEMD_USER_UNIT": "vibeswitcher-node.service"], at: at)])
        #expect(NodeJournal.events(named, mainPID: Int32(host), uid: Self.uid).first?.detail?.contains(forged) == true)
        // The earlier invocation's line with the same pid (a reboot gave it again), and the latest start with none
        // (refused, crashed early, or still hashing its images): the latest start has no line.
        let later = Self.start.addingTimeInterval(600)
        let reused = Self.read([Self.job("start", at: Self.start), Self.startLine(pid: host, at: at), Self.job("start", at: later)])
        let starts = NodeJournal.events(reused, mainPID: Int32(host), uid: Self.uid)
        #expect(starts.count == 2)
        #expect(starts.last?.detail == nil, "\(starts)")
        // Only one start in the entries, and a line with its pid from before it: not its line.
        let before = Self.read([Self.startLine(pid: host, at: Self.start.addingTimeInterval(-3600)), Self.job("start", at: Self.start)])
        #expect(NodeJournal.events(before, mainPID: Int32(host), uid: Self.uid).first?.detail == nil)
        // An earlier start's unchecked line is still only one from the unit.
        let unchecked = Self.read([Self.job("start", at: Self.start), Self.startLine(pid: 1, build: forged, uid: "1001", at: at),
                                   Self.job("start", at: later)])
        #expect(NodeJournal.events(unchecked, mainPID: Int32(host), uid: Self.uid).first?.detail == nil)
        // Without the user, nothing is taken.
        #expect(NodeJournal.events(Self.read([Self.job("start", at: Self.start), Self.startLine(pid: host, at: at)]), mainPID: Int32(host))
            .first?.detail == nil)
    }

    /// Every session is in the unit's cgroup, so a `logger` there lands under the unit too: a start line is the host's
    /// only when journald's `_PID` is the unit's `ExecMainPID` and its `_TRANSPORT` is `stdout`. One from an earlier
    /// invocation can't be checked, and says so.
    @Test func aStartLineFromASessionIsNotTheHosts() throws {
        let host = 4242
        let at = Self.start.addingTimeInterval(1)
        let ours = Self.read([Self.job("start", at: Self.start), Self.startLine(pid: host, at: at)])
        let event = try #require(NodeJournal.events(ours, mainPID: Int32(host), uid: Self.uid).first)
        #expect(event.kind == .start)
        #expect(event.detail == "pid \(host) build \(String(repeating: "a", count: 40)) SWIFT_BACKTRACE=enable=no", "\(event)")
        // From another pid in the unit (a session's `logger -t vibeswitcher-host`), or through syslog: not the host's.
        let forged = String(repeating: "f", count: 40)
        for lines in [[Self.job("start", at: Self.start), Self.startLine(pid: 777, build: forged, at: at)],
                      [Self.job("start", at: Self.start), Self.startLine(pid: host, build: forged, transport: "syslog", at: at)],
                      [Self.job("start", at: Self.start), Self.startLine(pid: host, build: forged, transport: "journal", at: at)]] {
            let entries = Self.read(lines)
            let events = NodeJournal.events(entries, mainPID: Int32(host), uid: Self.uid)
            #expect(events.count == 1 && events[0].kind == .start)
            #expect(events[0].detail == nil, "\(events)")
        }
        // A forged line beside the host's own: the host's is the one taken, whichever came last.
        let both = Self.read([Self.job("start", at: Self.start), Self.startLine(pid: host, at: at),
                              Self.startLine(pid: 777, build: forged, at: at.addingTimeInterval(1))])
        #expect(NodeJournal.events(both, mainPID: Int32(host), uid: Self.uid).first?.detail?.contains(forged) == false)
        // Without the unit's main pid, nothing is taken.
        #expect(NodeJournal.events(ours).first?.detail == nil)
        // An earlier invocation's line: shown, as not checked (its pid was another main pid's).
        let later = Self.start.addingTimeInterval(600)
        let two = Self.read([Self.job("start", at: Self.start), Self.startLine(pid: 1111, at: at),
                             Self.job("start", at: later), Self.startLine(pid: host, at: later.addingTimeInterval(1))])
        let starts = NodeJournal.events(two, mainPID: Int32(host), uid: Self.uid)
        #expect(starts.count == 2)
        #expect(starts.first?.detail?.hasSuffix("(not checked)") == true, "\(starts)")
        #expect(starts.first?.detail?.contains("pid 1111") == true, "\(starts)")
        #expect(starts.last?.detail == "pid \(host) build \(String(repeating: "a", count: 40)) SWIFT_BACKTRACE=enable=no", "\(starts)")
        // Not a start event itself: the job's line is.
        #expect(NodeJournal.events(Self.read([Self.startLine(pid: host, at: at)]), mainPID: Int32(host), uid: Self.uid).isEmpty)
        // The unit's main pid as `systemctl --user show` gives it.
        #expect(NodeJournal.unitState(show: "Result=success\nExecMainPID=4242\n").execMainPID == 4242)
        #expect(NodeJournal.unitState(show: "ExecMainPID=0\n").execMainPID == nil)
    }

    /// What `journalctl` is asked (`NodeContext.journalEntries` runs these as they are): the user's journal, as JSON,
    /// the node unit's entries and the command line's own, each matched on the user's `_UID` too. The user's journal
    /// lists the user's own entries without it (the bootstrap path's M4, 2026-11-17); with it nothing of another user
    /// is read wherever a journal holds more.
    @Test func theJournalIsAskedForTheUsersEntriesOnly() {
        #expect(NodeJournal.readArguments(uid: 1000) == [
            ["--user", "-o", "json", "--no-pager", "-u", "vibeswitcher-node.service", "_UID=1000"],
            ["--user", "-o", "json", "--no-pager", "SYSLOG_IDENTIFIER=vibeswitcher", "_UID=1000"],
        ])
        #expect(NodeJournal.readArguments(uid: 1234).allSatisfy { $0.last == "_UID=1234" && $0.first == "--user" })
    }

    /// The read `status` does (2026-11-27: 22-30 s on the user's node, the unit's whole journal of libdispatch's
    /// "Failed to set thread priority" lines read and decoded): with a journalctl that matches patterns, the unit is read
    /// only for the manager's job lines and the host's start and restart lines, never whole; what `events` makes of it
    /// is the same. Counted by the reads asked, not by the clock: however much else the unit logged, none of it is read.
    @Test func theUnitsJournalIsReadOnlyForWhatCounts() {
        let boot = "b00t"
        let job = Self.job("start", boot: boot, at: Self.start)
        let host = Self.startLine(pid: 4242, boot: boot, at: Self.start.addingTimeInterval(1))
        let spam = (0..<5000).map { _ in Self.startLine(pid: 9, at: Self.start).replacingOccurrences(of: "vibeswitcher-host: started pid 9", with: "Failed to set thread priority") }
        var asked: [[String]] = []
        let journal = { (pcre: Bool) in { (arguments: [String]) -> (status: Int32, output: String)? in
            asked.append(arguments)
            if arguments == ["--version"] { return (0, "systemd 255 (255.4)\n+PAM +AUDIT " + (pcre ? "+PCRE2" : "-PCRE2") + " +XZ\n") }
            if arguments.contains("SYSLOG_IDENTIFIER=systemd") { return (0, job) }
            if arguments.contains("--grep") { return (0, host) }
            if arguments.contains("-u") { return (0, ([job, host] + spam).joined(separator: "\n")) }
            return (0, "")
        } }
        let narrow = NodeJournal.read(uid: Self.uid, run: journal(true))
        let reads = asked
        #expect(!reads.contains { $0.contains("-u") && !$0.contains("SYSLOG_IDENTIFIER=systemd") && !$0.contains("--grep") }, "the unit read whole: \(reads)")
        #expect(reads.count == 4 && reads.dropFirst().allSatisfy { $0.last == "_UID=1000" }, "\(reads)")
        guard case .success(let entries) = narrow else { Issue.record("\(narrow)"); return }
        #expect(entries.count == 2, "only what counts is decoded: \(entries.count)")
        let events = NodeJournal.events(entries, mainPID: 4242, uid: Self.uid)
        #expect(events.count == 1 && events.first?.detail?.hasPrefix("pid 4242 build ") == true, "\(events)")
        // The same events from the whole read a journalctl without pattern matching gets.
        asked = []
        guard case .success(let whole) = NodeJournal.read(uid: Self.uid, run: journal(false)) else { Issue.record("no whole read"); return }
        #expect(asked.dropFirst().map { $0 } == NodeJournal.readArguments(uid: Self.uid), "\(asked)")
        #expect(NodeJournal.events(whole, mainPID: 4242, uid: Self.uid) == events)
        // A pattern read that found nothing ends 1 with nothing written: no entries, not a failure.
        let empty = NodeJournal.read(uid: Self.uid) { arguments in
            arguments == ["--version"] ? (0, "+PCRE2") : arguments.contains("--grep") ? (1, "") : (0, "")
        }
        #expect((try? empty.get())?.isEmpty == true, "\(empty)")
    }

    /// journald reads a writer's cgroup as it takes the datagram, so an entry whose writer had ended has no
    /// `_SYSTEMD_CGROUP` (the bootstrap path's M4, 2026-11-17: `logger`'s entry). It never counts, whoever wrote it
    /// (any process of the user's can write one and end); `status` says it for what it is on a line of its own, never
    /// as an entry "from no cgroup, not a terminal's".
    @Test func anEntryJournaldRecordedNoCgroupForNeverCountsAndIsSaidSo() throws {
        let said = "journald recorded no cgroup (the writer ended first)"
        #expect(NodeJournal.noCgroupSaid == said)
        let ended = try #require(Self.read([Self.own("ack", cgroup: nil, at: Self.start)]).first)
        #expect(ended.cgroup == nil && !NodeJournal.passes(ended, rule: Self.rule) && NodeJournal.hasNoCgroup(ended, rule: Self.rule))
        // Only the user's, and only with none: an entry from a cgroup, or another user's, is the old case.
        for line in [Self.own("ack", at: Self.start), Self.own("ack", cgroup: "/system.slice/cron.service", at: Self.start),
                     Self.own("ack", cgroup: nil, uid: "1001", at: Self.start)] {
            #expect(!NodeJournal.hasNoCgroup(try #require(Self.read([line]).first), rule: Self.rule), "\(line)")
        }
        // It explains no start and acknowledges none.
        let start = Self.read([Self.own("request", kind: "start", cgroup: nil, at: Self.start.addingTimeInterval(-5)), Self.job("start", at: Self.start),
                               Self.own("ack", cgroup: nil, at: Self.start.addingTimeInterval(30))])
        let events = NodeJournal.events(start)
        #expect(NodeJournal.unexplained(starts: events, entries: start, rule: Self.rule) == events)
        #expect(!NodeJournal.acknowledged(try #require(events.first), entries: start, rule: Self.rule))
        // An ack: one mark, a line of its own, saying so and vouching for nothing.
        let line = "isn't counted: \(said), so who wrote it can't be told"
        let ack = NodeJournal.marks(accepted: [], entries: [ended], rule: Self.rule)
        #expect(ack.count == 1 && ack.first?.hasPrefix("a journal entry of the command line's (ack at ") == true, "\(ack)")
        #expect(ack.first?.hasSuffix(line) == true && ack.first?.contains("not a terminal's") == false, "\(ack)")
        // Another user's entry with none is still "not a terminal's".
        let foreign = Self.read([Self.own("request", kind: "stop", action: "a1", cgroup: nil, uid: "1001", at: Self.start)])
        let foreignMarks = NodeJournal.marks(accepted: [("stop", "a1", Self.start)], entries: foreign, rule: Self.rule)
        #expect(foreignMarks.count == 2 && foreignMarks.first?.contains("no entry") == true, "\(foreignMarks)")
        #expect(foreignMarks.last?.hasSuffix("came from no cgroup, not a terminal's") == true, "\(foreignMarks)")
        // Beside the user's own entry that counts, the request is recorded, and the one without is still marked.
        let both = Self.read([Self.own("request", kind: "stop", action: "a1", at: Self.start),
                              Self.own("request", kind: "stop", action: "a1", cgroup: nil, at: Self.start.addingTimeInterval(1))])
        let bothMarks = NodeJournal.marks(accepted: [("stop", "a1", Self.start)], entries: both, rule: Self.rule)
        #expect(bothMarks.count == 1 && bothMarks.first?.hasPrefix("a journal entry of the command line's (request at ") == true, "\(bothMarks)")
        #expect(bothMarks.first?.hasSuffix(line) == true, "\(bothMarks)")
    }

    /// Any session's process can write an entry with no cgroup (`logger -t vibeswitcher`, which exits at once) naming
    /// an accepted request's action, kind and epoch. It softens nothing (the security review of 2026-11-17): the
    /// request's mark is word for word the one it has with no entry at all, the forged entry is marked on a line of
    /// its own, and neither line is left out for the other.
    @Test func aForgedEntryWithNoCgroupLeavesAnAcceptedRequestsMarkAsItIs() {
        let accepted: [(kind: String, action: String?, at: Date?)] = [("stop", "a1", Self.start)]
        for epoch in ["e1", nil] as [String?] {
            let alone = NodeJournal.marks(accepted: accepted, epoch: epoch, entries: [], rule: Self.rule)
            #expect(alone.count == 1 && alone.first?.hasSuffix("(action a1) and the journal has no entry for it") == true, "\(alone)")
            let forged = Self.read([Self.own("request", kind: "stop", action: "a1", epoch: "e1", cgroup: nil, at: Self.start.addingTimeInterval(1))])
            let marks = NodeJournal.marks(accepted: accepted, epoch: epoch, entries: forged, rule: Self.rule)
            #expect(marks.count == 2, "\(marks)")
            // The request's own mark: the same words.
            #expect(marks.first == alone.first, "\(marks)")
            #expect(marks.first?.contains("journald recorded no cgroup") == false && marks.first?.contains("isn't counted") == false, "\(marks)")
            // The entry's own line, still there.
            #expect(marks.last?.hasPrefix("a journal entry of the command line's (request at ") == true, "\(marks)")
            #expect(marks.last?.hasSuffix("isn't counted: journald recorded no cgroup (the writer ended first), so who wrote it can't be told") == true,
                    "\(marks)")
        }
        // Several forged entries: one line each, and the request's mark once, unchanged.
        let many = Self.read((0..<3).map { Self.own("request", kind: "stop", action: "a1", cgroup: nil, at: Self.start.addingTimeInterval(Double($0))) })
        let marks = NodeJournal.marks(accepted: accepted, entries: many, rule: Self.rule)
        #expect(marks.count == 4 && marks.filter { $0.hasSuffix("the journal has no entry for it") }.count == 1, "\(marks)")
    }

    /// The command line stays until the journal holds the entry it sent (`NodeContext.writeJournal` on both nodes), so
    /// journald reads its cgroup while it is there: a poll on the entry, by its nonce, on an injected clock.
    @Test func theCommandLineWaitsUntilTheJournalHoldsItsEntry() {
        let nonce = "3f0c1d52-6f0e-4c53-9d0b-0d6c6a7b9a11"
        let mine = Self.read([Self.own("ack", entry: nonce, at: Self.start)])
        let others = Self.read([Self.own("ack", entry: "another", at: Self.start), Self.own("request", kind: "stop", at: Self.start)])
        final class World {
            var now: TimeInterval = 1_000, reads = 0, slept: [TimeInterval] = []
        }
        func wait(patience: TimeInterval = 5, _ world: World, read: @escaping (Int) -> [JournalEntry]?) -> NodeJournal.Written {
            NodeJournal.awaitEntry(nonce: nonce, patience: patience, pause: 0.02, awake: { world.now },
                                   sleep: { world.slept.append($0); world.now += $0 }, read: { world.reads += 1; return read(world.reads) })
        }
        // Not there for three looks (the journal unread once, then others' entries only), then there: returned at that
        // look, after three pauses and no more.
        let late = World()
        #expect(wait(late) { $0 == 1 ? nil : $0 < 4 ? others : others + mine } == .recorded)
        #expect(late.reads == 4 && late.slept == [0.02, 0.02, 0.02], "\(late.reads) \(late.slept)")
        // There at the first look: no pause at all.
        let first = World()
        #expect(wait(first) { _ in mine } == .recorded)
        #expect(first.reads == 1 && first.slept.isEmpty)
        // There with no cgroup: said at once (journald writes an entry once), not waited on.
        let ended = World()
        #expect(wait(ended) { _ in Self.read([Self.own("ack", cgroup: nil, entry: nonce, at: Self.start)]) } == .noCgroup)
        #expect(ended.reads == 1 && ended.slept.isEmpty)
        // Never there: looked for until the patience has passed, by the clock given, then missing.
        let never = World()
        #expect(wait(never) { $0 % 2 == 0 ? nil : others } == .missing)
        #expect(never.now >= 1_005 && never.now < 1_005.1 && (250...252).contains(never.reads), "\(never.now) \(never.reads)")
        #expect(never.slept.allSatisfy { $0 == 0.02 })
        // The entry is the one carrying the nonce, whatever else names it; one of the two without a cgroup is said.
        #expect(NodeJournal.written(nonce: nonce, in: others) == nil)
        #expect(NodeJournal.written(nonce: nonce, in: Self.read([Self.own("ack", action: nonce, at: Self.start)])) == nil)
        #expect(NodeJournal.written(nonce: nonce, in: mine + Self.read([Self.own("ack", cgroup: nil, entry: nonce, at: Self.start)])) == .noCgroup)
        // How the user's node asks for it, and the name is one a sender may write.
        #expect(NodeJournal.entryArguments(nonce: nonce, uid: 1000)
            == ["--user", "-o", "json", "--no-pager", "VIBESWITCHER_ENTRY=\(nonce)", "_UID=1000"])
        #expect(Platform.Journal.mayName(NodeJournal.entryField))
        // What the command line says of each.
        #expect(NodeJournal.notCounted(.recorded, event: "ack", patience: 5) == nil)
        #expect(NodeJournal.notCounted(.noCgroup, event: "ack", patience: 5)
            == "the journal entry for this (ack) isn't counted: journald recorded no cgroup for it, though this command waited for it")
        #expect(NodeJournal.notCounted(.missing, event: "request", patience: 5)
            == "the journal entry for this (request) was sent, but the journal didn't show it within 5 s, so it isn't taken as written")
    }

    @Test func anAckSurvivesAServerRestart() throws {
        // The ack is the journal's, read afresh by each command line: a server that restarted (a new epoch, nothing
        // in its memory) changes nothing.
        let lines = [Self.job("start", at: Self.start), Self.own("ack", at: Self.start.addingTimeInterval(60)),
                     Self.line(["MESSAGE": "vibeswitcher-host: server child pid 9 ended after 300 s: exit 1; started again in 1 s"], at: Self.start.addingTimeInterval(120))]
        for _ in 0..<2 {
            let entries = Self.read(lines)
            let shown = NodeJournal.unexplained(starts: NodeJournal.events(entries), entries: entries, rule: Self.rule)
                .filter { !NodeJournal.acknowledged($0, entries: entries, rule: Self.rule) }
            // The start is acknowledged; the server restart after the ack is still shown.
            #expect(shown == [.init(kind: .serverRestart, at: Self.start.addingTimeInterval(120))])
        }
    }

    @Test func aJournalEntryFromANonTerminalCgroupIsMarkedInStatus() {
        let entries = Self.read([Self.own("request", kind: "stop", action: "a1", at: Self.start),
                                 Self.own("request", kind: "start", action: "a2", cgroup: "/system.slice/cron.service", at: Self.start)])
        let marks = NodeJournal.marks(accepted: [("stop", "a1", Self.start), ("start", "a2", Self.start)], entries: entries, rule: Self.rule)
        #expect(marks.count == 2, "\(marks)")
        #expect(marks.contains { $0.contains("/system.slice/cron.service, not a terminal's") }, "\(marks)")
        // And the entry from cron doesn't record the request it names: that one is marked as having none.
        #expect(marks.contains { $0.contains("accepted start") && $0.contains("a2") && $0.contains("no entry") }, "\(marks)")
    }

    @Test func aForgedRequestEntryDoesntHideAnAcceptedRequest() {
        // `logger -t vibeswitcher` from a session's process writes the identifier and the fields it likes; journald's
        // `_UID` and `_SYSTEMD_CGROUP` say who sent it. An entry that doesn't pass the rule records nothing.
        let unit = "/user.slice/user-1000.slice/user@1000.service/app.slice/vibeswitcher-node.service"
        for (cgroup, uid) in [("/system.slice/cron.service", "1000"), (unit, "1000"), ("/init.scope", "1001")] {
            let entries = Self.read([Self.own("request", kind: "stop", action: "a1", cgroup: cgroup, uid: uid, at: Self.start)])
            let marks = NodeJournal.marks(accepted: [("stop", "a1", Self.start)], entries: entries, rule: Self.rule)
            #expect(marks.contains { $0.contains("accepted stop") && $0.contains("a1") && $0.contains("no entry") }, "\(cgroup) \(uid): \(marks)")
        }
        // The user's own entry naming the action, but of another kind (or of none), doesn't record it either.
        for kind in ["start", nil] as [String?] {
            let entries = Self.read([Self.own("request", kind: kind, action: "a1", at: Self.start)])
            let marks = NodeJournal.marks(accepted: [("stop", "a1", Self.start)], entries: entries, rule: Self.rule)
            #expect(marks.count == 1 && marks.first?.contains("accepted stop") == true, "\(String(describing: kind)): \(marks)")
        }
        // Nor an event other than a request's.
        let ack = Self.read([Self.own("ack", kind: "stop", action: "a1", at: Self.start)])
        #expect(NodeJournal.marks(accepted: [("stop", "a1", Self.start)], entries: ack, rule: Self.rule).count == 1)
        // The user's own entry of that kind does.
        let recorded = Self.read([Self.own("request", kind: "stop", action: "a1", at: Self.start)])
        #expect(NodeJournal.marks(accepted: [("stop", "a1", Self.start)], entries: recorded, rule: Self.rule).isEmpty)
    }

    @Test func aRequestEntryCountsOnlyForTheServersEpoch() {
        // `status` gives the server's epoch: the entry the command line wrote for a request to it carries that one.
        let mine = Self.read([Self.own("request", kind: "stop", action: "a1", epoch: "e1", at: Self.start)])
        #expect(NodeJournal.marks(accepted: [("stop", "a1", Self.start)], epoch: "e1", entries: mine, rule: Self.rule).isEmpty)
        // Another server's epoch, or none, doesn't record it.
        for entry in [Self.own("request", kind: "stop", action: "a1", epoch: "e0", at: Self.start),
                      Self.own("request", kind: "stop", action: "a1", at: Self.start)] {
            let marks = NodeJournal.marks(accepted: [("stop", "a1", Self.start)], epoch: "e1", entries: Self.read([entry]), rule: Self.rule)
            #expect(marks.count == 1 && marks.first?.contains("accepted stop") == true, "\(marks)")
        }
    }

    @Test func anAcceptedRequestWithNoJournalEntryIsMarked() {
        let entries = Self.read([Self.own("request", kind: "start", action: "a1", at: Self.start)])
        let marks = NodeJournal.marks(accepted: [("start", "a1", Self.start), ("stop", "a9", Self.start)], entries: entries, rule: Self.rule)
        #expect(marks.count == 1, "\(marks)")
        #expect(marks.first?.contains("accepted stop") == true && marks.first?.contains("a9") == true, "\(marks)")
        // What the command line writes for a request carries ids and hashes only.
        let fields = NodeJournal.entry(event: "request", action: "a1", kind: "answer", digest: String(repeating: "f", count: 64), epoch: "e")
        #expect(Set(fields.map(\.name)) == ["SYSLOG_IDENTIFIER", "MESSAGE", "VIBESWITCHER_EVENT", "VIBESWITCHER_ACTION", "VIBESWITCHER_KIND",
                                             "VIBESWITCHER_DIGEST", "VIBESWITCHER_EPOCH"])
        #expect(fields.first { $0.name == "MESSAGE" }?.value == "vibeswitcher request answer")
    }
}
