import Foundation
import Testing
@testable import VibeCore

/// The incident of 2026-10-31 and 2026-11-01 (docs/lead/incidents.md): a verifier's session waited indefinitely on a
/// permission prompt no one could see or answer, often for read-only commands (`git ls-files -s …; git remote -v; git
/// branch -r | grep …; grep … package-lock.json`), and the lead could only start the audit again, the finders' work
/// lost. (a) Read-only command lines run without a prompt (`ReadOnlyCommand`, the verifier's `PermissionRequest`
/// hook); (b) a prompt still waited on after `LeadWitness.promptWait` is declined, the lead told once.
struct VerifierPromptTests {
    let temp = Scratch()
    // MARK: (a) What runs without a prompt

    /// The command lines that run without a prompt.
    static let allowed = [
        // The second incident's command, as the finder ran it.
        "git ls-files -s Package.swift; git remote -v; git branch -r | grep origin/main; grep -n lodash package-lock.json",
        "git log --oneline -5", "git --no-pager log -3 --stat", "git show HEAD:Sources/a.swift", "git diff main...HEAD -- Sources",
        "git status --short", "git rev-parse HEAD", "git merge-base main HEAD", "git cat-file -p HEAD", "git blame -L 1,9 a.swift",
        "git remote", "git remote -v", "git branch -a", "git branch -r", "git branch -av", "git branch --show-current",
        "git branch --list 'agent/*'", "git branch --merged main", "git branch -r --contains HEAD", "git branch --sort=-committerdate",
        "grep -rn 'foo bar' Sources", "rg -n \"func allows\" Sources", "rg -C3 -i --glob '*.swift' --hidden TODO", "rg -uu --files", "rg -n -- -x a", "head -50 a.txt", "tail -n 20 a.log", "wc -l a b",
        "sort -u names.txt", "git log | head -3", "git diff --stat && git status", "git log -1 || git status",
        "grep -c x a.txt 2>/dev/null", "git log 2>&1 | tail -5", "git show HEAD > /dev/null", "rg x >/dev/null 2>&1",
        "git log --format='%h %s' -3", "git status\ngit log -1", "grep 'a;b|c' x.txt", "grep a\\;b x",
    ]

    /// The ones that still prompt: anything that writes, runs something else, isn't on the list, or doesn't parse.
    static let refused = [
        "", "   ", "ls", "cat a.txt", "git", "git config user.name x", "git config --list", "git push", "git fetch", "git checkout main",
        "git -C ../other log", "git -c core.pager=x log", "git --git-dir=/x log", "GIT_PAGER=x git log", "env git log",
        // git branch that changes something.
        "git branch foo", "git branch -D foo", "git branch -d foo", "git branch -m a b", "git branch -M a", "git branch -f a HEAD",
        "git branch --force a", "git branch -u origin/x", "git branch --set-upstream-to=origin/x", "git branch -c a b",
        "git branch --edit-description", "git branch -r -D origin/x", "git branch --del x", "git branch -a x",
        "git remote add x y", "git remote remove origin", "git remote set-url origin x", "git remote -v add x y",
        // git that writes a file or runs a program the repository's config names (abbreviations included).
        "git log --output=x", "git diff --output x", "git log --outp=x", "git diff --ext-diff", "git diff --ext", "git show --textconv HEAD:a",
        "git cat-file --filters HEAD:a", "git cat-file --fi HEAD:a", "git log --output-directory=x",
        // Redirection to a file, substitutions, expansions, subshells, background, here-docs, comments, globs.
        "git log > out.txt", "git log >> out.txt", "git log 2> err.txt", "git log >out", "git log>out", "git log &> /dev/null",
        "grep x < a.txt", "grep x <<EOF", "git log $(rm -rf x)", "git log `rm x`", "grep \"$HOME\" a", "grep $X a",
        "git log & rm x", "git log &", "(git log)", "{ git log; }", "git log # comment", "! git log", "grep x *.swift",
        "grep x a?.txt", "grep x [ab].txt", "git log |& head", "git log >| /dev/null", "git log 3>&1",
        // A part not on the list, or an empty one.
        "git log; rm -rf build", "git status && touch x", "git log | xargs rm", "git log | sh", "git log | tee out.txt",
        "git log;; git status", "git log |", "&& git log", "git log ;", "git log | | head", "grep x a\\\nb",
        // Unclosed quotes, and escapes in double quotes.
        "grep 'x a", "grep \"x a", "grep \"a\\\"b\" x",
        // Options of the listed programs that write, run something, or never end.
        "sort -o out.txt a", "sort -uo out a", "sort --output=x a", "sort --out=x a", "sort --compress-program=sh a",
        "rg --pre ./x foo", "rg --pre=./x foo", "rg -z foo", "rg --search-zip foo", "tail -f a.log", "tail -F a.log",
        "tail --follow a.log", "tail --fol a.log", "/usr/bin/grep x a", "./grep x a",
        // Brace expansion turns a word the checks pass into the flags they refuse (the blind check's).
        "git diff --{output=out.txt,stat}", "git diff --{ext-diff,stat}", "git cat-file --{filters,batch-check} HEAD:a",
        "rg --{pre=./x,hidden} foo", "sort --{output=f,unique} a", "tail --{follow,lines=5} a.log", "git log @{u}..HEAD",
        // ripgrep flags that run programs, or that it may gain: only the known reading ones are taken.
        "rg --hostname-bin=./x --hyperlink-format=default foo", "rg --hostname-bin ./x foo", "rg --some-new-flag foo",
    ]

    @Test func readOnlyLinesRunWithoutAPromptAndEverythingElseStillPrompts() {
        for line in Self.allowed { #expect(ReadOnlyCommand.allows(line), "should run without a prompt: \(line)") }
        for line in Self.refused { #expect(!ReadOnlyCommand.allows(line), "should still prompt: \(line)") }
    }

    /// Claude Code's `PermissionRequest` event, as its hook gets it on stdin: the allow for a read-only Bash call,
    /// nothing for anything else (the prompt shows).
    @Test func theHookAllowsOnlyReadOnlyBashCalls() throws {
        func event(_ tool: String, _ input: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input])
        }
        let answer = try #require(ReadOnlyCommand.hookAnswer(try event("Bash", ["command": "git remote -v; git branch -r | grep main"])))
        let object = try #require(try JSONSerialization.jsonObject(with: answer) as? [String: Any])
        let output = try #require(object["hookSpecificOutput"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        #expect((output["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        #expect(ReadOnlyCommand.hookAnswer(try event("Bash", ["command": "git config user.name x"])) == nil)
        #expect(ReadOnlyCommand.hookAnswer(try event("Write", ["file_path": "notes.txt", "content": "git log"])) == nil)
        #expect(ReadOnlyCommand.hookAnswer(Data("not json".utf8)) == nil)
    }

    /// The verifier's settings carry the hook (by the tool server, which answers it); the lead's and workers' don't,
    /// and the verifier's deny rules are as they were (Claude Code asks the hook only about what they let through).
    @Test func onlyTheVerifiersSettingsCarryTheHook() throws {
        let root = temp.url("verifier-hook").path
        for role in [LeadLaunch.Role.lead, .worker, .verifier] {
            let launch = try LeadLaunch.prepare(role: role, root: root, task: role == .lead ? nil : "x", base: "claude", prompt: "p",
                                                start: "Go.", server: "/opt/vibe switcher/vibeswitcher-mcp", name: "\(role)-x",
                                                temporary: temp.url("session-tmp"))
            let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any])
            let hooks = settings["hooks"] as? [String: Any]
            guard role == .verifier else {
                #expect(hooks == nil, "\(role)")
                continue
            }
            let groups = try #require(hooks?["PermissionRequest"] as? [[String: Any]])
            #expect(groups.count == 1 && groups[0]["matcher"] as? String == "Bash")
            let handler = try #require((groups[0]["hooks"] as? [[String: Any]])?.first)
            #expect(handler["command"] as? String == "'/opt/vibe switcher/vibeswitcher-mcp' --read-only-permission")
            let deny = try #require((settings["permissions"] as? [String: Any])?["deny"] as? [String])
            #expect(deny == LeadLaunch.deny(.verifier))
        }
    }

    // MARK: (b) A prompt no one answers

    func board(_ slug: String = "audit-me", verifier: String = "v1") -> LeadBoard {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = .review
        task.worker = "w1"
        task.verifier = verifier
        var board = LeadBoard()
        board.tasks = [task]
        return board
    }

    static let command = "git ls-files -s x; git config --get remote.origin.url"

    func waiting(since: Date, started: Date) -> LeadWitness.Seen {
        LeadWitness.Seen(live: true, status: .needsInput, since: since, detail: "Bash: git ls-files -s x",
                         pending: PendingPrompt(text: "Run: " + Self.command, since: since.timeIntervalSince1970),
                         started: started.timeIntervalSince1970, boundAt: started.timeIntervalSince1970,
                         toolsAt: started.timeIntervalSince1970 + 2)
    }

    /// Before the wait, nothing: no stuck prompt, and no "is waiting for input" for the lead (who could only start the
    /// audit again). From the wait on, one stuck prompt, keyed as the waiting notice was (told once); still nothing in
    /// `events`. A worker waiting is told at once, as before.
    @Test func aVerifierWaitingOnAPromptIsStuckAfterTheWaitAndNotToldBefore() {
        let t0 = Date(timeIntervalSince1970: 1_793_500_000)
        let started = t0.addingTimeInterval(-300)
        let seen = ["v1": waiting(since: t0, started: started),
                    "w1": LeadWitness.Seen(live: true, status: .done, since: t0, activity: .idle(background: nil), started: started.timeIntervalSince1970 - 600)]
        let board = board()
        for after in [0.0, 30, 119] {
            #expect(LeadWitness.stuckPrompts(board: board, seen: seen, now: t0 + after).isEmpty, "\(after)s")
            #expect(!LeadWitness.events(board: board, seen: seen, now: t0 + after).contains { $0.key.hasPrefix("v1|") }, "\(after)s")
        }
        for after in [120.0, 600, 7_200] {
            let stuck = LeadWitness.stuckPrompts(board: board, seen: seen, now: t0 + after)
            #expect(stuck.map(\.key) == ["v1|input-\(Int(t0.timeIntervalSince1970))"], "\(after)s")
            #expect(stuck.first?.slug == "audit-me" && stuck.first?.prompt.text == "Run: " + Self.command)
            #expect(!LeadWitness.events(board: board, seen: seen, now: t0 + after).contains { $0.key.hasPrefix("v1|") }, "\(after)s")
        }
        // Not once its verdict is in, nor for a session that ended or a verifier at work.
        var done = board
        done.tasks[0].evidence = LeadEvidence(completion: .complete, integrity: .clean, summary: "")
        #expect(LeadWitness.stuckPrompts(board: done, seen: seen, now: t0 + 600).isEmpty)
        var working = seen
        working["v1"]?.status = .working
        #expect(LeadWitness.stuckPrompts(board: board, seen: working, now: t0 + 600).isEmpty)
        // A worker waiting is the lead's to answer: told at once.
        var workerBoard = board
        workerBoard.tasks[0].status = .running
        let workerSeen = ["w1": waiting(since: t0, started: started)]
        #expect(LeadWitness.events(board: workerBoard, seen: workerSeen, now: t0 + 5).contains { $0.key == "w1|input-\(Int(t0.timeIntervalSince1970))" })
    }

    static let permissionScreen = """
    ⏺ Bash(git ls-files -s x; git config --get remote.origin.url)
    ╭──────────────────────────────────────╮
    │ Bash command                         │
    │                                      │
    │   git ls-files -s x; git config --get remote.origin.url │
    │                                      │
    │ Do you want to proceed?              │
    │ ❯ 1. Yes                             │
    │   2. Yes, and don't ask again for git ls-files commands │
    │   3. No                              │
    ╰──────────────────────────────────────╯
    Esc to cancel · Tab to amend
    """

    static let prompt = PendingPrompt(text: "Run: " + command)

    /// The keys: down to the No row, Tab to open its text field (Claude Code 2.1.316's plain "No" takes text only
    /// after Tab), the reason typed there, Enter. A No row that reads otherwise gets no Tab. A question on screen
    /// isn't a permission prompt.
    @Test func theDeclineGoesToTheNoRowWithTheReason() throws {
        let plan = try #require(LeadWitness.declinePlan(screen: Self.permissionScreen, prompt: Self.prompt))
        let down: [UInt8] = [27, 91, 66]
        #expect(plan.writes.map(\.bytes) == [down, down, [9], Array(LeadWitness.declineReason.utf8), [13]])
        #expect(plan.no == 2 && plan.amend)
        let older = Self.permissionScreen.replacingOccurrences(of: "3. No  ", with: "3. No, and tell Claude what to do differently (esc)")
        let olderPlan = try #require(LeadWitness.declinePlan(screen: older, prompt: Self.prompt))
        #expect(olderPlan.writes.map(\.bytes) == [down, down, Array(LeadWitness.declineReason.utf8), [13]] && !olderPlan.amend)
        let question = " ☐ Color\nWhich color do you prefer?\n❯ 1. Yes\n  2. No\n  3. Type something.\n\nEnter to select · ↑/↓ to navigate · Esc to cancel"
        #expect(LeadWitness.declinePlan(screen: question, prompt: Self.prompt) == nil)
        #expect(LeadWitness.declinePlan(screen: "> \n? for shortcuts", prompt: Self.prompt) == nil)
        // Only a shell command's prompt, found on screen.
        #expect(LeadWitness.declinePlan(screen: Self.permissionScreen, prompt: PendingPrompt(text: "Allow: WebFetch x")) == nil)
    }

    /// Claude Code 2.1.304's layout, captured (Tests/VibeHostTests/Fixtures/claude-2.1.304-status-rows-110x40.json): the
    /// command between rules above "Do you want to proceed?", and four rows, the third switching to auto mode.
    static let realScreen = """
    ──────────────────────────────────────────────────────────────────────────────────────
     Bash command
     Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
     Probe the remote
    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
     git ls-files -s x; git config --get remote.origin.url
    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and always allow access to /Users/x/repo from this project
       3. Yes, and switch to auto mode · auto mode handles these prompts for you
       4. No

     Esc to cancel · Tab to amend
    """

    func moved(_ screen: String, to row: Int, no: String = "No") -> String {
        var lines = screen.components(separatedBy: "\n").map { line -> String in
            guard let dot = line.range(of: #"[❯ ] ?\d\. "#, options: .regularExpression), line.contains(". ") else { return line }
            let number = line[dot].filter(\.isNumber)
            let rest = line[dot.upperBound...]
            let indent = line[..<dot.lowerBound]
            return indent + (Int(String(number)) == row ? "❯ " : "  ") + number + ". " + rest
        }
        if no != "No" { lines = lines.map { $0.hasSuffix("4. No") ? $0.replacingOccurrences(of: "4. No", with: "4. " + no) : $0 } }
        return lines.joined(separator: "\n")
    }

    /// Each key goes only while the screen shows the stuck prompt with the cursor where the keys so far put it: Tab
    /// on the plain No row, the reason once Tab opened its text field (its placeholder showing), Enter only on the No
    /// row showing the reason. A No row Tab didn't open, keys taken as moves, a prompt answered meanwhile or another
    /// one opened since stop it (and never land Enter on a Yes row).
    @Test func eachKeyGoesOnlyWhereThePlanExpectsIt() throws {
        let plan = try #require(LeadWitness.declinePlan(screen: Self.realScreen, prompt: Self.prompt))
        #expect(plan.no == 3 && plan.amend && plan.writes.count == 6)
        let placeholder = "and tell Claude what to do differently"
        #expect(LeadWitness.declineMayGo(plan, step: 0, screen: Self.realScreen))
        #expect(LeadWitness.declineMayGo(plan, step: 1, screen: moved(Self.realScreen, to: 2)))
        #expect(LeadWitness.declineMayGo(plan, step: 2, screen: moved(Self.realScreen, to: 3)))
        #expect(LeadWitness.declineMayGo(plan, step: 3, screen: moved(Self.realScreen, to: 4)))
        #expect(LeadWitness.declineMayGo(plan, step: 4, screen: moved(Self.realScreen, to: 4, no: placeholder)))
        #expect(LeadWitness.declineMayGo(plan, step: 5, screen: moved(Self.realScreen, to: 4, no: LeadWitness.declineReason)))
        // The arrow's redraw not shown yet: wait (the app reads again).
        #expect(!LeadWitness.declineMayGo(plan, step: 1, screen: Self.realScreen))
        // Tab didn't open the text field (a No row that takes no reason): the reason's letters, j and k among them,
        // would be the menu's keys, so they don't go.
        #expect(!LeadWitness.declineMayGo(plan, step: 4, screen: moved(Self.realScreen, to: 4)))
        // Tab only on the plain No row (an open field would close).
        #expect(!LeadWitness.declineMayGo(plan, step: 3, screen: moved(Self.realScreen, to: 4, no: placeholder)))
        // The reason didn't show, or the cursor left the row: no Enter.
        #expect(!LeadWitness.declineMayGo(plan, step: 5, screen: moved(Self.realScreen, to: 4, no: placeholder)))
        #expect(!LeadWitness.declineMayGo(plan, step: 5, screen: moved(Self.realScreen, to: 4)))
        #expect(!LeadWitness.declineMayGo(plan, step: 5, screen: moved(Self.realScreen, to: 3)))
        #expect(LeadWitness.escapeMayGo(plan, screen: moved(Self.realScreen, to: 3)))
        // Another prompt (the stuck one answered, the verifier on to its next command): nothing goes, not even Esc.
        let other = Self.realScreen.replacingOccurrences(of: "git ls-files -s x; git config --get remote.origin.url", with: "touch probe.txt")
        #expect(LeadWitness.declinePlan(screen: other, prompt: Self.prompt) == nil)
        for step in 0..<6 { #expect(!LeadWitness.declineMayGo(plan, step: step, screen: moved(other, to: min(step + 1, 4)))) }
        #expect(!LeadWitness.escapeMayGo(plan, screen: other))
        // The same command with other rows (three, the cursor's moves meant for four): no key.
        let threeRows = Self.permissionScreen
        #expect(!LeadWitness.declineMayGo(plan, step: 2, screen: threeRows))
        #expect(!LeadWitness.declineMayGo(plan, step: 0, screen: "> \n? for shortcuts"))
    }

    @Test func theLeadIsToldWhatWasAskedAndWhatTheVerifierWasTold() {
        let t0 = Date(timeIntervalSince1970: 1_793_500_000)
        let stuck = LeadWitness.StuckPrompt(key: "v1|input-1", session: "v1", slug: "audit-me",
                                            prompt: PendingPrompt(text: "Run: " + Self.command, since: t0.timeIntervalSince1970))
        let told = LeadWitness.declinedText(stuck, now: t0 + 180)
        #expect(told.contains("The verifier on audit-me waited 3 min on a permission prompt no one answers: “Run: \(Self.command)”."), "\(told)")
        #expect(told.contains(LeadWitness.declineReason))
        let couldnt = LeadWitness.undeclinedText(stuck, now: t0 + 180)
        #expect(couldnt.contains("Run: \(Self.command)") && couldnt.contains("couldn't decline"), "\(couldnt)")
        let escaped = LeadWitness.escapedText(stuck, now: t0 + 180)
        #expect(escaped.contains("Run: \(Self.command)") && escaped.contains("with Esc"), "\(escaped)")
    }
}
