---
format: 1920x1080
duration: 537.7s at 1x (the delivered MP4 is 1.7x: 316.3s)
message: "VibeSwitcher wraps Claude Code sessions in an engineering process, so one conversation can run a team you can trust."
arc: Hook → Starting point → Structure → The task's journey (contract → worktree → report → audit → findings → gate) → What keeps it running (auto_advance, incidents, limits, models, memory) → Your controls → Comparison → Proof
audience: developers who drive Claude Code (or Codex) sessions by hand
mode: autonomous
---

Narrated cut: each scene's length below is the silent cut's. `tools/captions.py` now stretches each scene to fit its
voice (`NARRATION.md`), never shorter, so the film runs 8:57.7 (8:29 after the first update of 2026-11-17, 6:54 before it). Every number is from `sources.md`. Scenes are sub-compositions in `compositions/`, mounted back to back in
`index.html`. Each fades in over 0.4 s and out over 0.4 s, with hard cuts between scenes. The kicker in the top-left
(`NN / NAME`) numbers the chapters.

## Update of 2026-11-17: what's new since the last render

The last render was cc0e9da0 (2026-11-12 15:42). This inventory lists what a viewer would notice that merged since
then, read from `git log cc0e9da0..main` (code commits, not "Lead:" ones), `docs/lead/decisions.md` entries from
2026-11-12 on and the diff of `docs/process/product-inventory.md`. A few older features the film never showed are
listed too, because the update's contract names them. Internal fixes (test waits, lints, prompt trimming, benches,
sandbox commands) are left out. Sources for each line are in `sources.md`, "Added 2026-11-17".

| Feature or process change | Merged | Already in the film? | Where it goes |
| --- | --- | --- | --- |
| Small tasks skip their audit: an audit task done in its first round in under 30 min of work, touching nothing sensitive, not raised by the risk check and not Codex's, merges on its tests; the 10 % random sample still audits some | 03d03896, 2026-11-12 | No (the 10 % sample was) | s07: a line on screen and in the narration |
| Faster merges: a merge's test run gets the cores that are free, not only its slot's share; failing tests rerun by name; a test that's red on main too doesn't send the branch back: it merges and a fix task is filed | 64c99ed9, e0692549, 2026-11-12 | The rerun of failing tests, yes (s11); the rest no | New scene s20, "Merges keep flowing" |
| "Merges are held" reports: a task ready 20 min with no merge landing gets the lead one report naming the cause (the battery hold, main red, its records, every slot held, the load hold, the gate not installed, a merge running), counted in the Mac's awake time, sleep named | 87ebb3e0 (2026-11-12), 268df9cb (11-16), 7d463d18 (11-17) | No | s20 |
| Sleep shows its cost: in-flight time paused by sleep, a wake notice, status and digest lines | 93d317db, 2026-11-12 | No | s20, one line |
| Workers told once when main turns red and again when it's green | e8d07039, 2026-11-13 | No | s20, one line on screen |
| Fable→Opus fallback at Fable's usage limit, back at the reset | 1aab1823, c50bca46 (2026-11-12, just before the last render) | No | s15: rewritten |
| Each role's model, built: lead on Fable, Fable advisor for hard tasks, re-rolls and sensitive or security audits on Fable, per-task effort | a3e2a30e, 2026-11-12 | Shown dashed as "being built" | s15: dashed chips become solid |
| App-health watcher: freezes, crashes and error lines grouped by cause; a cause on 3 of 7 days, or doubling, is proposed to the lead as a task, once | a58f8d4e (2026-11-08), dd2aed86, 7f0969d2 | No | New scene s21, "The app checks itself" |
| UI journeys: scripted runs of the real app in the sandbox, each screenshot diffed against its baseline (smoke, select-copy, run-card, dictate) | d2852803 … 3ab471b5, 2026-11-15 | No | s21 |
| Memory: on macOS 27.2 malloc kept every freed page (+74 MB an hour); the app restarts itself with MallocLargeCache=0. Image-heavy chats: images decoded at the size shown, two at a time (+1,012 MB peak → +178 MB) | 961dda62, 1d061b10, c01ff549, 2026-11-17 | No | s21 |
| Restart card: after a Mac restart, one card lists the sessions open at shutdown, with Reopen all and Choose…; leads reopen first with --resume | d8b85010 … 7059ab0a, 2026-11-16 | No | New scene s22, "Day to day" |
| The chat's model chip follows /model at once, and its menu offers Fable | 8906e144, 73bbffc6, 2026-11-15 | No | s22 |
| A reminder card to run /doctor prompt-audit every 14 days per project, or when the model changed | ce72a400, 2026-11-12 | No | s22, one line on screen |
| A Run card tells the asking session how its command ended (exit status, last output) | 233acccc, 2026-11-12 | Run cards, yes (s17); the ending no | s22, one line on screen |
| Workers and verifiers can't read your prompt history, other sessions' transcripts or anything in ~/.claude but skills, plugins and projects | ba88848a, 614b59e4, db598c14, f579c69b, 2026-11-14 | No | s05: one line on screen |
| The lead's records refuse another project's name or a credential's shape | 87ebb3e0, 2026-11-12 | No | s16: one line on screen |
| Pushing to GitHub only on your click | 2c727025 (2026-11-05) | Yes: s17's Push card and its narration | No change |
| Claude Code's own skill sync accepted by the config seal, every other change still held | a2600cdd, 40c23d08, 51072b49 (2026-11-17; decision 09:46) | No | s17: a line on the config seal's key and in the narration (added in the second update, re-voiced) |
| Update check: every 6 hours, GitHub's main and this Mac's; a plain-language changelog card; Install & Restart asks for the signing password, never stored; GitHub ahead → the lead merges first, tested | 279ed53b (2026-11-17; decision 11:44) | No | s22: a card under the restart card, and in the narration (added in the second update, re-voiced) |
| Team mode (several workers on one task, a post wall) | 2026-11-13 … 11-15 | No | Left out: dropped as a default after its experiment (decision 2026-11-16 07:21) |
| Floating dots panel removed | a27af4a0 | Never shown | Left out (a removal) |
| Merge dry run; batch receipts | 9ee1c37d, 6dd2304b | No | Left out: the lead's bookkeeping, team experiment |

The numbers on screen (tasks, merges, audits, findings) stay those read on 2026-11-12, as the title card says
("17 Oct – 12 Nov 2026"); refreshing them would re-voice six scenes for no new feature.

New and changed scenes, in film order: s05 (screen only), s07 (re-voiced), s11, then **s20**, s12, s13, then
**s21**, s14, s15 (re-voiced), s16 (screen only), s17, then **s22**, s18, s19. The second update the same day (after
the two features above merged) re-voiced s17 and s22 only, and changed s21's threshold line on screen. The chapter kickers after s13 are
renumbered (screen only). The delivered MP4 is this film sped up 1.7×, pitch kept.

**Render of 2026-11-17.** `npx hyperframes@0.9.37 render . --fps 30 --quality looks` under `vs-heavy` gave the 1× film
(1920×1080, 30 fps, 8:29.4, 50.2 MB, not committed). The delivered `practices-explainer.mp4` is that file through
`ffmpeg -filter_complex "[0:v]setpts=PTS/1.7,fps=30[v];[0:a]atempo=1.7[a]" -c:v libx264 -preset slow -crf 18
-pix_fmt yuv420p -c:a aac -b:a 160k -movflags +faststart`: 1080p30, **4:59.6** (the cut before was 6:54 at 1×),
31.6 MB. `atempo` keeps the voice's pitch. Stills in `stills/` are frames of the delivered file, named by their time
in it (`at-1.7x-151s.png`: s20; 194 s: s21; 229 s: s15; 267 s: s22; 86 s: s07); the old cut's stills were removed.

**Second render of 2026-11-17** (after the update check and the skill-sync exception merged). s17 and s22 re-voiced
(the same voice, model and seed), captions and lengths refitted by `tools/captions.py`: s17 22.2 → 31.2 s, s22 21.9 →
41.2 s (its base 18 → 26 s for the update card), film 8:29.4 → 8:57.7 at 1×. Rendered the same way under `vs-heavy`
(1920×1080, 30 fps, 55.5 MB, not committed), and through the same `ffmpeg` line: the delivered `practices-explainer.mp4`
is 1080p30, **5:16.3** (316.3 s), 33.3 MB. New stills: `at-1.7x-260s.png` (s17, the seal's exception),
`at-1.7x-284s.png` (s22 with the update card, replacing 267 s) and `at-1.7x-194s.png` again (s21's reworded threshold);
151 s, 229 s and 86 s fall in unchanged scenes at unchanged times.

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

none: "the merge's full test run is the check"; since 2026-11-17 also "small task · an audit task done in its first
round, under 30 min of work, nothing sensitive or risky, not Codex's: merges on its tests". audit: "a verifier must pass it first". Raised anyway: sensitive
paths (`.claude/` `AGENTS.md` `.github/` `.env` `*.entitlements` …) · the risk check (over 400 lines outside tests ·
deletes or rewrites files · changes permissions · spawns processes · adds locks or threads · touches test or build
setup · removes tests · plus a small model's look) · a random 10 % sample. "Nothing can lower a review." Count: 35
raised by the risk check · 271 of 495 merged tasks audited.

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

## Frame 11b: Merges keep flowing (s20, added 2026-11-17)

- scene: Faster runs on the left; a "Merges are held" report types itself on the right, its causes lighting up
- duration: 18s (base; 28s narrated)
- status: animated
- src: compositions/s20-flow.html
- motion: waterfall-entry (list), typewriter-reveal (report), spring-pop-entrance (cause chips)

Left, "faster runs": the run takes the free cores (`VS_HEAVY_CORES`) · only failing tests run again · red on main too →
merges and a fix task is filed · main red: each worker told once, and again when green. Right: the report ("Merges are
held: task-a, task-b have been ready to merge for 24 min with no merge landing. Cause: the battery hold.") · causes ·
"after 20 min · at most every 30 min · minutes counted awake, 'paused by sleep'".

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

## Frame 13b: The app checks itself (s21, added 2026-11-17)

- scene: Three cards (UI journeys, App health, Memory), then four counters
- duration: 18s (base; 31.7s narrated)
- status: animated
- src: compositions/s21-self-check.html
- motion: grid-card-assemble; counting-dynamic-scale

UI journeys: scripted sandbox runs, each shot diffed against its baseline (`scripts/ui-journeys.sh`). App health: the
app's freezes, crashes and error lines by cause; 3 of 7 days or doubling → a proposed task (`watch_app_logs`). Memory:
macOS 27.2's malloc kept freed pages (+74 MB an hour) → `MallocLargeCache=0`; chat images decoded at the size shown,
two at a time. Counters: 4 journeys · 0.05 % ("of a shot's pixels may change; any more flags it": `scripts/ui-journeys.sh` counts a shot
as changed when more than the threshold differ) · +178 MB (from +1,012) · 3 of 7.

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

Updated 2026-11-17, the routing now built (a3e2a30e) and the Fable fallback shown. Fable, judgment: "the lead · advisor
on hard tasks · re-rolls · sensitive and security audits". Opus, doing: "the workers' model in this project · routine
audits · the lead, while Fable is held back". Codex, bounded: "mechanical tasks, tight contracts · agent: auto, when
Claude is tight · always audited by Claude". Bottom: "At Fable's usage limit, workers and audits start on Opus, a halted
worker restarts on Opus, and the lead is told. Back to Fable at the reset." Sessions launched (2026-11-12): Opus 175 ·
Fable 70 · Codex 17 · Sonnet 8.

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
Shell and wallet cards · Config seal ("One exception: a finished round of Claude Code's own skill sync, accepted by its
shape", added 2026-11-17; the phone key now waits for its line) · Phone over Tailscale (replies behind their own switch).

## Frame 17b: Day to day (s22, added 2026-11-17)

- scene: The restart card on the left, the update card under it; the model chip flipping on `/model fable`, Run cards
  and the prompt-audit reminder on the right
- duration: 26s (base, 18s before the update card; 41.2s narrated)
- status: animated
- src: compositions/s22-day-to-day.html
- motion: spring-pop-entrance; typewriter-reveal (`/model fable`)

Card: "The Mac restarted" · Lead example-api · Lead example-site · Claude example-api · docs · "Leads reopen first, and
each is told to restart its workers." · Dismiss / Choose… / Reopen all · "nothing reopens without your click". Update card (added 2026-11-17): "every 6 hours ·
GitHub's main and this Mac's main" · "A newer version" · Later / Install & Restart · "What changed, in plain words.
Install & Restart opens a shell card that asks for the signing password: never stored." · "GitHub ahead? The lead
merges it in first, tested.".

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
