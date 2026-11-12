---
format: 1920x1080
duration: 342s
message: "VibeSwitcher wraps Claude Code sessions in an engineering process, so one conversation can run a team you can trust."
arc: Hook → Starting point → Structure → The task's journey (contract → worktree → report → audit → findings → gate) → What keeps it running (auto_advance, incidents, limits, models, memory) → Your controls → Comparison → Proof
audience: developers who drive Claude Code (or Codex) sessions by hand
mode: autonomous
---

Every number is from `sources.md`. Scenes are sub-compositions in `compositions/`, mounted back to back in
`index.html`. Each fades in over 0.4 s and out over 0.4 s, with hard cuts between scenes. The kicker in the top-left
(`NN / NAME`) numbers the chapters.

## Frame 1: Title

- scene: The yard draws itself, one car runs onto the main line, title lands
- duration: 10s
- poster: 6s
- transition_in: cut
- status: animated
- src: compositions/s01-title.html
- motion: titlecard-reveal; svg-path-draw (rails), nudge-curve (car), ambient-glow-bloom

On screen: "One conversation. A whole engineering team." / "The practices VibeSwitcher builds around Claude Code
sessions" / mono: "numbers from the project's own records · 17 Oct – 12 Nov 2026".

## Frame 2: The starting point

- scene: Claude Code's own building blocks on the left; the human at the centre of eight jobs on the right
- duration: 22s
- poster: 18s
- status: animated
- src: compositions/s02-by-hand.html
- motion: waterfall-entry (list), center-outward-expansion (jobs around "you"), kinetic-type-beats (closing line)

Left, "Claude Code already gives you a lot": subagents with their own context · git worktrees (`claude --worktree`)
· hooks that can block an action or run tests · permission rules, auto mode, a sandbox · CLAUDE.md and auto memory ·
Remote Control from your phone.
Right, "Run a few sessions by hand and you are the process": write each brief · keep sessions out of each other's
files · read every diff · decide what's tested enough · merge, in order · remember why · notice who's stuck · watch the
Mac and the usage limits.
Close: "VibeSwitcher turns that process into software."

## Frame 3: One conversation

- scene: You → lead → workers and a verifier, drawn as a signal-box diagram
- duration: 20s
- poster: 15s
- status: animated
- src: compositions/s03-structure.html
- motion: constellation-hub; svg-path-draw (links), spring-pop-entrance (nodes)

You: "direction, taste, anything irreversible". Lead: "one Claude Code session per repository · plans, starts
workers, judges, merges · never edits code (deny rules)". Workers: "Claude or Codex · one task each". Verifier:
"read-only".
Why one conversation: "You talk to one session about the project. It keeps the board, the team and the history, and
asks you only what's yours to decide." Mono: "questions are cards · a reversible one can carry a 10-min timer ·
never a blocking or outward-facing one".

## Frame 4: The contract

- scene: A real task's contract types onto a card; its fields light up one by one
- duration: 18s
- poster: 14s
- status: animated
- src: compositions/s04-contract.html
- motion: grid-card-assemble (fields), discrete-text-sequence (field values)

Card (task `a-task-s-time`, merged 2026-11-12): goal "A worker's time budget counts only time the Mac was awake, and
a stall whose whole window the Mac slept through isn't reported as a stall." · acceptance (3 of 4 checks, abridged) ·
boundaries "May change: LeadBudget, LeadWitness, LeadStall and tests. Don't change any threshold's length." · review:
audit · budget_min: 90.
Side: "Every task is a contract: what must be true, how to show it, where the worker may touch." / "The worker gets it
word for word, with your working policy." / "Its hash rides in the merge commit: `VS-Contract`."

## Frame 5: Isolated, in parallel

- scene: The main line with three sidings branching off; a car on each, labelled with real branch names
- duration: 18s
- poster: 14s
- status: animated
- src: compositions/s05-worktrees.html
- motion: spatial-pan-stations (light); svg-path-draw (sidings), nudge-curve (cars)

`.vibeswitcher/worktrees/<task>` on `agent/<task>`. "Up to 3 workers per project, 7 with Boost." "Each in its own
worktree and branch: no two agents in one checkout." "Workers can't push, move refs or check out the lead's branch:
Claude Code permission rules deny it." "To catch up, a worker merges the base in."

## Frame 6: Owned through completion

- scene: A worker's lane, events ticking along it, ending in a report card that stamps itself
- duration: 16s
- poster: 13s
- status: animated
- src: compositions/s06-worker.html
- motion: agent-progress-theater; waterfall-entry

Events: `progress` (a milestone on its lane) → `ask_lead` (only direction, scope or risk) → affected tests while
editing → new tests run under load → `report(done)`. Report: "evidence for every acceptance check · a blind check by a
fresh agent · the routine calls it made". "A done without evidence for every check is refused."

## Frame 7: Who gets audited

- scene: A switch splits two tracks, none and audit; three gates divert cars onto the audit track
- duration: 18s
- poster: 15s
- status: animated
- src: compositions/s07-review.html
- motion: comparison-split; spring-pop-entrance, counting-dynamic-scale

none: "the merge's full test run is the check". audit: "a verifier must pass it first". Raised anyway: sensitive
paths (`.claude/` `AGENTS.md` `.github/` `.env` `*.entitlements` …) · the risk check (over 400 lines outside tests ·
deletes or rewrites files · changes permissions · spawns processes · adds locks or threads · touches test or build
setup · removes tests · plus a small model's look) · a random 10 % sample. "Nothing can lower a review." Count: 35
raised by the risk check · 272 of 495 merged tasks audited.

## Frame 8: An independent verifier

- scene: The inspection shed: one build, three finders, findings dropping into a vote tally
- duration: 20s
- poster: 16s
- status: animated
- src: compositions/s08-verifier.html
- motion: constellation-hub (finders), particle-burst-free dots via stat-bars-and-fills

"Read-only. Works from the contract, not the worker's story. Runs real commands and tries to break it." "On a
different model from the worker, by default." "Reads REVIEW.md from the base branch, so a worker can't edit its own
audit." Finders (`audit_finders: 2 or 3`): contract & acceptance · bugs & regressions · security or tests. "One build
and test run, its logs to every finder." Vote: "raised by most finders → open · the rest → unconfirmed, not
blocking (unless `strict_paths`)".

## Frame 9: Findings, rounds, re-rolls

- scene: Severity chips, a two-round loop, then the re-roll switch; counters
- duration: 18s
- poster: 15s
- status: animated
- src: compositions/s09-findings.html
- motion: svg-path-draw (loop), counting-dynamic-scale

Important "blocks the merge until fixed or dismissed with a reason" · Nit "never blocks, never becomes a task" ·
Pre-existing "never fails the task". Loop: fix → re-audit checks only those findings. "After 2 failed rounds: no third.
Re-plan, ask you, or re-roll: a fresh worker from the base, the old branch kept as `archive/<task>-<n>`." Numbers: 191
passed round 1 · 81 needed more rounds · 82 Important findings fixed · 15 dismissed with a reason · 2 re-rolls.

## Frame 10: The merge gate

- scene: Four signal lamps turn green in sequence as a car passes through to main
- duration: 16s
- poster: 13s
- status: animated
- src: compositions/s10-gate.html
- motion: spatial-pan-stations; nudge-curve

1 "Take exactly the commit that was checked." 2 "Rebase it onto the lead's branch, in a worktree no agent works in."
3 "Run the setup, the full suite and any regression command." 4 "Fast-forward." Stamp: "Never a merge commit. Never a
force. Any merge can be undone by a revert commit."

## Frame 11: When tests misbehave

- scene: Three panels for flaky, hung and lagging, then the gate's record
- duration: 18s
- poster: 15s
- status: animated
- src: compositions/s11-gate-safety.html
- motion: grid-card-assemble; counting-dynamic-scale

Flaky: "failing tests run once more (up to 20) · pass → recorded as a flake · 3 flakes in 7 days → a task to fix it".
Hung: "no output, under 1 % of a core for 10 min → stopped, naming the last test". Gate lag: "merges run on the
installed build · status says when the base holds gate code that build lacks". Record: 495 merges, each tested at the
gate · 72 passed only on the rerun · up to 3,986 tests a run · 0 reverts.

## Frame 12: It moves on its own

- scene: An auto_advance loop: events on the left trigger steps on the right
- duration: 16s
- poster: 13s
- status: animated
- src: compositions/s12-advance.html
- motion: waterfall-entry; svg-path-draw (connectors)

done (review none) → merge · done (audit) → start the audit · clean verdict → merge · Important findings → back to the
worker, once per verdict · verifier quit without a verdict → retry once · merge failed → its output to the worker ·
merged → clean up · `after` satisfied → start the next task. "Never moves a task the lead holds: kept, blocked, failed,
folded, abandoned." Merge policy: `auto` · `ask_sensitive` · `ask_all`.

## Frame 13: Incidents become checks

- scene: A real incident card turns into a check card; counters
- duration: 18s
- poster: 15s
- status: animated
- src: compositions/s13-incidents.html
- motion: card-morph-anchor (light); counting-dynamic-scale

Incident 2026-11-06: "Hung test runs held a Mac-wide test slot for 30–60 min at 0 % CPU. 5 times in 2 days." →
task `turn-this-incident-into-10` → check: "`stall_min`: a run with no output and under 1 % of a core for 10 min is
stopped, and the last test it started is named." Counts: 21 incidents recorded · 21 turned into check tasks · 33 of
the lead's 52 rules enforced by a check or test.

## Frame 14: A shared Mac, a finite account

- scene: Three gauges (time, attention, capacity) with their thresholds
- duration: 22s
- poster: 18s
- status: animated
- src: compositions/s14-limits.html
- motion: stat-bars-and-fills; waterfall-entry

Time: "a budget of 120 min of working time per task (waiting on you, the lead or a test slot doesn't count) · reached →
commit what works, report what's missing, propose. Nothing is killed." Witness: "silent 15 min · idle 10 min · stuck
at a compaction 5 min · an unread message 5 min → the lead hears". Capacity, for every project on the Mac: 10 team
sessions · start nothing above a load of 2 × cores · builds and suites take turns in `vs-heavy` slots (cores ÷ 6) ·
on battery below 50 %, pause · at 80 % of a usage limit, start nothing new on that model · Boost while you're away on
AC power: 18 sessions, load 36, 3 slots.

## Frame 15: The right model for each role

- scene: Three lanes by model, with role chips sliding into them
- duration: 18s
- poster: 15s
- status: animated
- src: compositions/s15-models.html
- motion: comparison-split; counting-dynamic-scale

Fable, judgment: "the lead's advisor · hard tasks · re-rolls · sensitive and security audits". Opus, doing: "the
default for workers and routine work". Codex, bounded: "mechanical tasks with a tight contract · `agent: auto` picks
it when Claude is tight (a limit at 70 %, or 10 points ahead of pace) and Codex has room · always audited by a Claude
verifier". "Verifier and worker on different models, by default." Sessions launched: Opus 175 · Fable 70 · Codex 17 ·
Sonnet 8. Note: "routing as decided 2026-11-12".

## Frame 16: Memory that lives in the repo

- scene: A folder of records stacks up; a commit with its trailers
- duration: 16s
- poster: 13s
- status: animated
- src: compositions/s16-memory.html
- motion: grid-card-assemble; typewriter-reveal (trailers)

`docs/lead/`: decisions.md "221 decisions, each with its why" · progress.md "4,716 lines" · incidents.md "21".
"Committed by the tool server. Workers can't edit it. A new lead reads it first." Commit trailers: `VS-Task`,
`VS-Review`, `VS-Worker-Model`, `VS-Verifier-Model`, `VS-Build`, `VS-Contract`. Receipt per task: "time, tokens, cost,
rounds, reruns, tests, your waits".

## Frame 17: You keep the keys

- scene: Seven key cards, each one a control that only the user holds
- duration: 20s
- poster: 17s
- status: animated
- src: compositions/s17-controls.html
- motion: grid-card-assemble; spring-pop-entrance

Review rules floor · sensitive and strict paths · merge policy (an approval covers one exact commit) · Push card ·
Shell and wallet cards · Config seal · Phone over Tailscale (replies behind their own switch).

## Frame 18: What the system adds

- scene: A two-column ledger, row by row
- duration: 24s
- poster: 21s
- status: animated
- src: compositions/s18-compare.html
- motion: comparison-split; waterfall-entry

Columns: "By hand, with Claude Code" | "With VibeSwitcher on top". Rows: planning · parallel work · review · merging ·
mistakes · load and limits · memory · your time. Footer: "Same Claude Code underneath: its permission rules, hooks and
status line are how VibeSwitcher works."

## Frame 19: Proof

- scene: Counters across the yard, then the closing line
- duration: 14s
- poster: 11s
- status: animated
- src: compositions/s19-close.html
- motion: dataviz-countup; kinetic-type-beats

"17 Oct – 12 Nov 2026, this repository": 549 tasks · 495 merged, each tested at the gate · 272 audited · 82 Important
findings fixed before merge · 154 worker-hours · 0 reverts. Close: "You decide what to build. The system runs the
process." Footer: "Sources: sources.md, beside this video."
