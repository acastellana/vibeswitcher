# Sources

Every claim the video makes, and where it comes from. Paths are relative to the repository root. Numbers were
read on 2026-11-12 from this Mac's records of the vibeswitcher project. The board itself (`.vibeswitcher/`) is
git-ignored, so the command that read each number is given too.

## The numbers on screen

| On screen | Value | Source |
| --- | --- | --- |
| Tasks on the board since the first lead | 549 tasks, first created 2026-10-17 12:15 | `.vibeswitcher/board.json` + `board-archive.jsonl` (each task's latest record, by id); `createdAt` |
| Merged | 495 (all 495 with `merged.tested: true`) | same, `merged` field |
| Ended without merging | 18 abandoned, 10 folded | same, `status` |
| Audited before merging | 272 audited tasks, all with a passing final verdict; the impact script counts 271 of 495 merges audited | board `audits`; `scripts/impact-metrics.sh 2026-10-01..2026-11-12` |
| Audit rounds | 191 passed in round 1; 62 took 2 rounds, 17 took 3, 2 took 4 (1.38 rounds per audited task) | board `audits.rounds`; impact script |
| Important findings | 82 fixed, 15 dismissed with a reason, 1 open (on a task not yet merged); 61 tasks had at least one | board `audits.findings[].severity/status` |
| Raised to audit by the risk check | 35 tasks (e.g. "it changes 577 lines outside tests, over risk_lines (400)") | board `riskRaised` |
| Random audit sample draws | 10 tasks drawn at 10 % | board `auditSample` |
| Re-rolls | 2 | board `receipt.rerolls` |
| Reverts | 0 | impact script, `reverts: 0` |
| Flaky tests at the gate | 72 of 271 merges with a receipt passed only on the rerun (27 %); the flake ledger holds 206 flakes of 167 tests in 44 merges | impact script, `flaky-merge rate` |
| Full suite size | 3,986 tests in the largest recorded merge test run | board `receipt.tests` (max) |
| Median full-suite duration at the gate | 752 s over 172 recorded merge runs | impact script |
| Median start-to-merge | 77 min | impact script |
| Worker hours | 154.4 h on 295 tasks that ended with a receipt | impact script, `worker hours` |
| Estimated cost per task | $10.70 (281 receipts with a known cost) | impact script |
| Incidents | 21 entries in `docs/lead/incidents.md`, each with a `Check: task …` line | `grep -c '^Check: task' docs/lead/incidents.md` = 21 |
| Lead rules backed by a check | 33 of 52 rules enforced by a check or test; 19 guidance | `docs/process/lead-rules.md`, "Counts" |
| Decisions on record | 221 entries (93 in decisions.md, 128 archived) | `grep -c '^## 20' docs/lead/decisions*.md` |
| Progress lines | 4,716 (2,300 + 2,416 archived) | `grep -c '^- 20' docs/lead/progress*.md` |
| Sessions launched per model (since tasks record it) | Opus 175, Fable 70, Codex 17, Sonnet 8 | board `launchedModels` (147 tasks record it) |
| Codex-worked tasks | 19, each audited by a Claude verifier | board `codexWorked`; docs/guide/project-lead.md "Codex workers" |

The impact script reports a 1018.6 h window because its range starts 2026-10-01; the board's first task is 2026-10-17,
so the video says "since 17 October" and gives no per-hour rate.

## How the system works (each scene's claims)

| Claim | Source |
| --- | --- |
| One lead per repository: plans, runs workers, checks and merges; asks you only what's yours | `README.md` "What it does"; `docs/guide/project-lead.md` intro |
| A new lead reads `workflow.md`, `decisions.md` and the end of `progress.md` | `docs/guide/project-lead.md` "Starting a lead" |
| Contract: goal, acceptance, boundaries, context; plus review, `after`, `budget_min`, `model`, `auto_advance` | `docs/guide/project-lead.md` "How a lead plans: the task contract" |
| Workers in `.vibeswitcher/worktrees/<task>` on `agent/<task>`; `max_workers` 3 (7 with Boost) | `docs/guide/project-lead.md` "Workers", "Boost" |
| Workers can't push, move refs or check out the lead's branch (deny rules); they merge the base in | `docs/guide/project-lead.md` "Workers"; `docs/process/lead-rules.md` #2 |
| Worker reports `done` with evidence per acceptance check and a blind check; `blocked`; `over_budget` | `docs/guide/project-lead.md` "Workers"; lead-rules #15 |
| New tests proven under load before done | `docs/process/lead-rules.md` E5 |
| Review levels none / audit; risk check (400 lines, deletes or rewrites, permissions, processes, locks or threads, test or build setup, tests removed; a small model may raise); sensitive paths; 10 % sample | `docs/guide/project-lead.md` "Review levels and audits"; `README.md` "Merge gates and reviews" |
| Read-only verifier, real commands, on a different model from the worker by default | `docs/guide/project-lead.md`; lead-rules #12 |
| 1–3 finders with different focuses; findings most finders raised stay open, the rest are unconfirmed; `strict_paths` | `docs/guide/project-lead.md` "Several finders", "Strict paths" |
| Important blocks, Nit never blocks or becomes a task, Pre-existing never fails | `docs/guide/project-lead.md` "Findings"; lead-rules E4 |
| Round cap 2 → reconsider, re-plan, ask, or re-roll (branch kept as `archive/<task>-<n>`) | `docs/guide/project-lead.md` "The round cap" |
| Merge gate: exact checked commit, rebased in a worktree no agent works in, init + test + regression commands, fast-forward, never a merge commit or force | `docs/guide/project-lead.md` "The merge gate" |
| Stall detection at the gate: `stall_min` 10, `test_timeout_min` 45 | same; incidents.md 2026-11-06 22:39:58 |
| Flaky tests: rerun once (≤ 20 named tests); 3 flakes in 7 days → a task to fix it | same, "Flaky tests" |
| Gate lag: merges run by the installed app's tool server; `status` says when the base holds gate code the build lacks, and `merge_remote` refuses | same; `Sources/VibeCore/LeadGateBuild.swift` (`gateLag`) |
| Merge policy auto / ask_sensitive / ask_all; an approval covers one exact commit | same, "Merge policy" |
| `revert` = one new commit, tests run, nothing rewritten | `docs/guide/project-lead.md` "revert" |
| auto_advance steps | `docs/guide/project-lead.md` "auto_advance" |
| Incidents become check tasks (`record_incident`) | `docs/process/lead-rules.md` "Also enforced"; `docs/lead/incidents.md` |
| Example incident: hung test runs held a heavy slot 30–60 min at 0 % CPU, 5 times | `docs/lead/incidents.md` 2026-11-06 22:39:58 |
| Example incident: the census counted only one lead's team after an install | `docs/lead/incidents.md` 2026-10-28 07:59:44 |
| Time budget 120 min of working time; over_budget report; nothing stopped | `docs/guide/project-lead.md` "Time budget" |
| Witness: silent 15 min, idle 10 min, compacted 5 min, inbox 5 min | `docs/guide/project-lead.md` "The witness" |
| Mac-wide: 10 team sessions, load 2 × cores, heavy slots cores ÷ 6, `vs-heavy`, `VS_HEAVY_CORES` | `docs/guide/project-lead.md` "Mac-wide limits" |
| Battery hold below 50 %; usage back-off at 80 % of a limit | same, "The battery hold", "The account's usage limits" |
| Boost: load 36, 18 sessions, 7 workers, 3 slots | same, "Boost" |
| Model routing: Opus by default; Fable for the lead's advice, hard tasks, re-rolls, sensitive or security audits | `docs/lead/decisions.md` 2026-11-12 09:06:53 |
| Codex for bounded mechanical tasks; `agent: auto` picks Codex when Claude is tight (70 %, or 10 points ahead of pace) and Codex has room; Codex work always audited by Claude | `docs/guide/project-lead.md` "Codex workers", "Auto routing" |
| Records in `docs/lead`, committed by the tool server as "Lead: decisions and progress"; workers can't edit them | `docs/guide/project-lead.md` "The records" |
| Provenance trailers `VS-Task`, `VS-Review`, `VS-Worker-Model`, `VS-Verifier-Model`, `VS-Build`, `VS-Contract` | `docs/guide/project-lead.md` "Provenance" |
| Receipts: time, tokens, cost, rounds, re-rolls, reruns, tests, questions | `docs/guide/project-lead.md` "The Team tab…" |
| Review rules floor; config seal and its Accept card; push card; shell card; wallet card; question timers never on blocking or outward-facing questions | `docs/guide/project-lead.md`; `README.md` "Around the lead" |
| Phone over Tailscale: list, screens, leads' questions and boards; replies need a separate switch | `docs/guide/phone-access.md`; `README.md` "The phone" |

## Claude Code (checked against code.claude.com docs, 2026-11-12)

The video says what VibeSwitcher adds on top of Claude Code, not what Claude Code lacks. Claude Code's own features
named on screen, each confirmed in its docs:

| On screen | Doc |
| --- | --- |
| Subagents with their own context, run in parallel | https://code.claude.com/docs/en/sub-agents.md |
| Git worktrees built in (`claude --worktree`, `isolation: worktree`) | https://code.claude.com/docs/en/worktrees.md |
| Hooks that can block an action or run tests | https://code.claude.com/docs/en/hooks.md |
| Permission rules and modes, auto mode, sandbox | https://code.claude.com/docs/en/permission-modes.md, https://code.claude.com/docs/en/sandboxing.md |
| CLAUDE.md and auto memory | https://code.claude.com/docs/en/memory.md |
| Headless `claude -p`, GitHub Actions, Agent SDK | https://code.claude.com/docs/en/headless.md |
| Remote Control from the phone | https://code.claude.com/docs/en/remote-control.md |
| Agent teams (experimental, off by default) | https://code.claude.com/docs/en/agent-teams.md |

VibeSwitcher's own use of these: its workers are Claude Code sessions, its deny rules are Claude Code permission
rules, its live status comes from Claude Code hooks, and its usage reading comes from the status line's
`rate_limits` (`docs/guide/project-lead.md` "The account's usage limits").
