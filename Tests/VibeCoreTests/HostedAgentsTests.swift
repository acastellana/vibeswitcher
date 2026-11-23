import Foundation
import Testing
@testable import VibeCore

/// `HostedAgents`: a hosted terminal's agent is the program the host started as one, whatever its name; nothing else on
/// a hosted terminal is, whatever its name; a terminal the host didn't start is the process table's to decide (the
/// user's node), or nobody's (a scratch node). On fake tables, `enabled` given (the Mac's answer is nil everywhere).
struct HostedAgentsTests {
    private let scratch = Scratch()
    static let start = Date(timeIntervalSince1970: 1_000)

    static func process(_ pid: Int32, ppid: Int32 = 1, tty: String?, comm: String, agent: Agent? = nil, at offset: TimeInterval = 0) -> ProcInfo {
        ProcInfo(pid: pid, ppid: ppid, tty: tty, comm: comm, startTime: start.addingTimeInterval(offset), agent: agent)
    }

    static func session(tty: String, program: Int32, agent: String?, label: String = "Lead · repo", live: Bool = true) -> HostSession {
        HostSession(id: UUID(), tty: tty, childPID: program, cwd: "/repo", command: agent == nil ? nil : "claude", label: label, agent: agent,
                    title: "", startedAt: start, cols: 80, rows: 24, exit: live ? nil : .init(status: 0, at: start))
    }

    /// The lead's session runs a program by any name (`runner`, as a versioned binary's `2.1.328` is); a tool it runs
    /// names itself `claude`. A plain shell session runs a program named `claude`. An outside terminal runs another.
    struct World {
        let lead = HostedAgentsTests.session(tty: "ttypts1", program: 100, agent: "claude")
        let shell = HostedAgentsTests.session(tty: "ttypts2", program: 200, agent: nil, label: "Shell")
        var hosted: [HostSession] { [lead, shell] }
        let table: [Int32: ProcInfo] = [
            100: process(100, ppid: 10, tty: "ttypts1", comm: "runner"),
            101: process(101, ppid: 100, tty: "ttypts1", comm: "claude", agent: .claude, at: 5),
            102: process(102, ppid: 101, tty: "ttypts1", comm: "vibeswitcher-mc", at: 6),
            200: process(200, ppid: 10, tty: "ttypts2", comm: "claude", agent: .claude),
            300: process(300, ppid: 1, tty: "ttypts3", comm: "claude", agent: .claude),
            10: process(10, ppid: 1, tty: nil, comm: "vibeswitcher-ho"),
        ]
        var reader: HostedAgents.Reader { .table(table, arguments: [100: ["/opt/runner"], 200: ["/x/claude"]]) }
    }

    @Test func aHostedSessionsAgentIsTheProgramTheHostStartedWhateverItsName() {
        let world = World()
        let lead = HostedAgents.running(on: "ttypts1", session: nil, hosted: world.hosted, reader: world.reader, enabled: true)
        #expect(lead == .some(LeadAgent(pid: 100, tty: "ttypts1", session: world.lead.id.uuidString, agent: .claude)))
        #expect(HostedAgents.runs(LeadAgent(pid: 100, tty: "ttypts1", session: nil), hosted: world.hosted, reader: world.reader, enabled: true) == true)
        // The tool server under it: its agent is the program, not the nearer process named `claude`.
        let ancestors = [world.table[101]!, world.table[100]!, world.table[10]!]
        #expect(HostedAgents.current(ancestors: ancestors, hosted: world.hosted, reader: world.reader, enabled: true)
                == .some(LeadAgent(pid: 100, tty: "ttypts1", session: world.lead.id.uuidString, agent: .claude)))
    }

    /// A worker's tool server, whose host list holds only its team's sessions: the lead's terminal isn't in it, so the
    /// lead runs while its pid is still a process on its terminal, named anything; a terminal it sees is the record's.
    @Test func aTerminalTheCallerCantSeeRunsWhileItsProcessIsOnIt() {
        let world = World()
        let lead = LeadAgent(pid: 100, tty: "ttypts1", session: world.lead.id.uuidString)
        #expect(HostedAgents.runsForTeam(lead, hosted: [world.shell], reader: world.reader, enabled: true) == true)
        #expect(HostedAgents.runsForTeam(LeadAgent(pid: 100, tty: "ttypts9", session: nil), hosted: [world.shell], reader: world.reader, enabled: true) == false)
        #expect(HostedAgents.runsForTeam(LeadAgent(pid: 999, tty: "ttypts1", session: nil), hosted: [world.shell], reader: world.reader, enabled: true) == false)
        #expect(HostedAgents.runsForTeam(LeadAgent(pid: 101, tty: "ttypts1", session: nil), hosted: world.hosted, reader: world.reader, enabled: true) == false)
        #expect(HostedAgents.runsForTeam(lead, hosted: [], reader: world.reader, enabled: false) == nil)
    }

    @Test func aProcessThatOnlyNamesItselfClaudeOnAHostedTerminalIsNoAgent() {
        let world = World()
        // A tool on the lead's terminal named `claude` isn't the lead's agent.
        #expect(HostedAgents.runs(LeadAgent(pid: 101, tty: "ttypts1", session: nil), hosted: world.hosted, reader: world.reader, enabled: true) == false)
        // A plain shell session's program named `claude` is no agent; nor is a tool server under it.
        #expect(HostedAgents.running(on: "ttypts2", session: nil, hosted: world.hosted, reader: world.reader, enabled: true) == .some(nil))
        #expect(HostedAgents.runs(LeadAgent(pid: 200, tty: "ttypts2", session: nil), hosted: world.hosted, reader: world.reader, enabled: true) == false)
        #expect(HostedAgents.current(ancestors: [world.table[200]!, world.table[10]!], hosted: world.hosted, reader: world.reader, enabled: true)
                == .some(nil))
        // A session that ended is no agent's, its program's pid whoever's now.
        let ended = HostedAgentsTests.session(tty: "ttypts1", program: 100, agent: "claude", live: false)
        #expect(HostedAgents.running(on: "ttypts1", session: nil, hosted: [ended], reader: world.reader, enabled: true) == nil)
    }

    @Test func aTerminalTheHostDidntStartIsTheProcessTablesAndTheMacsAlways() {
        let world = World()
        #expect(HostedAgents.running(on: "ttypts3", session: nil, hosted: world.hosted, reader: world.reader, enabled: true) == nil)
        #expect(HostedAgents.runs(LeadAgent(pid: 300, tty: "ttypts3", session: nil), hosted: world.hosted, reader: world.reader, enabled: true) == nil)
        #expect(HostedAgents.current(ancestors: [world.table[300]!], hosted: world.hosted, reader: world.reader, enabled: true) == nil)
        #expect(HostedAgents.decided(nil, or: { LeadAgent(pid: 300, tty: "ttypts3", session: nil) })?.pid == 300)
        #expect(HostedAgents.decided(.some(nil), or: { LeadAgent(pid: 300, tty: "ttypts3", session: nil) }) == nil)
        // Not enabled (the Mac): nothing is decided here.
        #expect(HostedAgents.running(on: "ttypts1", session: nil, hosted: world.hosted, reader: world.reader, enabled: false) == nil)
        #expect(HostedAgents.runs(LeadAgent(pid: 101, tty: "ttypts1", session: nil), hosted: world.hosted, reader: world.reader, enabled: false) == nil)
        #expect(HostedAgents.current(ancestors: [world.table[101]!, world.table[100]!], hosted: world.hosted, reader: world.reader, enabled: false) == nil)
        #expect(HostedAgents.overlay(world.table, hosted: world.hosted, scratch: true, reader: world.reader, enabled: false).mapValues(\.agent)
                == world.table.mapValues(\.agent))
    }

    /// The host's shell that didn't exec its command (a list): the agent is its oldest child on the terminal.
    @Test func aShellTheHostStartedThatDidntExecHandsTheAgentToItsOldestChild() {
        let lead = HostedAgentsTests.session(tty: "ttypts1", program: 100, agent: "claude")
        let table: [Int32: ProcInfo] = [
            100: Self.process(100, ppid: 10, tty: "ttypts1", comm: "bash"),
            103: Self.process(103, ppid: 100, tty: "ttypts1", comm: "2.1.328", at: 1),
            104: Self.process(104, ppid: 100, tty: "ttypts1", comm: "claude", at: 9),
        ]
        let shell = Platform.Tools.sessionShellArguments(shell: "/bin/bash", command: "cd x && claude", keepShell: false)
        let reader = HostedAgents.Reader.table(table, arguments: [100: shell])
        #expect(HostedAgents.agentPid(of: lead, reader: reader) == (HostedAgents.isHostShell(shell) ? 103 : 100))
    }

    @Test func theOverlayGivesHostedTerminalsTheHostsRecordAndAScratchNodeNothingElse() {
        let world = World()
        let node = HostedAgents.overlay(world.table, hosted: world.hosted, scratch: false, reader: world.reader, enabled: true)
        #expect(node[100]?.agent == .claude && node[101]?.agent == nil && node[102]?.agent == nil)
        #expect(node[200]?.agent == nil)
        // The user's own terminal on the user's node: as the table read it.
        #expect(node[300]?.agent == .claude)
        let scratch = HostedAgents.overlay(world.table, hosted: world.hosted, scratch: true, reader: world.reader, enabled: true)
        #expect(scratch[100]?.agent == .claude && scratch[300]?.agent == nil && scratch[200]?.agent == nil)
        #expect(scratch.keys.sorted() == world.table.keys.sorted())
        // As a scan reads it: one session, the lead's, by its program.
        let state = self.scratch.url("state")
        let scan = SessionScanner(processes: { scratch }, stateDir: { state }, cwd: { _ in "/repo" },
                                  arguments: { _ in [] }).scan(now: Self.start.addingTimeInterval(60))
        #expect(scan.map(\.tty) == ["ttypts1"] && scan.map(\.pid) == [100], "\(scan)")
    }

    /// A session under another session host than this node's (a scratch node's: an agent's test, its fake `claude` on
    /// a terminal that host started) isn't the user's node's to list; the user's own terminal's is, and so is this
    /// node's hosted one. By ancestry: the nearest host above it.
    @Test func aSessionUnderAnotherSessionHostIsntListed() {
        var table = World().table
        table[20] = Self.process(20, ppid: 1, tty: nil, comm: "vibeswitcher-ho")
        table[400] = Self.process(400, ppid: 20, tty: "ttypts4", comm: "bash")
        table[401] = Self.process(401, ppid: 400, tty: "ttypts4", comm: "claude", agent: .claude, at: 2)
        // The user's terminal: under a terminal emulator and a shell, no host.
        table[30] = Self.process(30, ppid: 1, tty: nil, comm: "tmux: server")
        table[31] = Self.process(31, ppid: 30, tty: "ttypts5", comm: "bash")
        table[310] = Self.process(310, ppid: 31, tty: "ttypts5", comm: "claude", agent: .claude, at: 3)
        let world = World()
        let node = HostedAgents.overlay(table, hosted: world.hosted, scratch: false, ownHost: 10, reader: .table(table, arguments: [100: ["/opt/runner"]]), enabled: true)
        #expect(node[401]?.agent == nil, "the scratch host's session")
        #expect(node[310]?.agent == .claude && node[300]?.agent == .claude, "the user's own terminals")
        #expect(node[100]?.agent == .claude, "this node's hosted lead")
        // Its own host isn't another: with no host of its own known, every host is another's (the hosted terminals keep
        // the record's answer).
        #expect(HostedAgents.underOtherHost(401, in: table, ownHost: 10) && !HostedAgents.underOtherHost(310, in: table, ownHost: 10))
        #expect(!HostedAgents.underOtherHost(101, in: table, ownHost: 10) && HostedAgents.underOtherHost(101, in: table, ownHost: nil))
        // A loop in a table read mid-change ends.
        table[50] = Self.process(50, ppid: 51, tty: "ttypts6", comm: "claude", agent: .claude)
        table[51] = Self.process(51, ppid: 50, tty: "ttypts6", comm: "bash")
        #expect(!HostedAgents.underOtherHost(50, in: table, ownHost: 10))
    }
}
