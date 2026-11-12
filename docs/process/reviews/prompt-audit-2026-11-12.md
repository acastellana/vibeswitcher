# Prompt audit, 2026-11-12: AGENTS.md, the lead's prompt and the worker's brief

The audit from the claude-api skill (`prompt-audit`, shared/prompt-audit.md), run on the text every lead and worker
session reads, after the Claude Code team's talk of the same day: an instruction file holds only what the model can't
see from the code, and emphasis written for older models sends today's off track.

## Assumptions

- **Scope:** AGENTS.md (CLAUDE.md only imports it); the lead's prompt, `LeadPrompts.lead`, and the worker's brief,
  `LeadPrompts.worker`, in Sources/VibeCore/LeadWorkflow.swift, with the texts they include (`LeadPrompts.Policy`,
  `newTests`, `scratchFiles`, `debuggers`, `loadTests`, `heavyWork`, `SessionNote.realTerminal`, `WorkerBrief`).
  Left out on purpose: the verifier's prompt and REVIEW.md (another task is measuring them), and the user's working
  policy (`WorkingPolicy`: the user's words, and every role's). A text the verifier shares with the worker
  (`debuggers`, `loadTests`, `heavyWork`, `scratchFiles`) is unchanged; where the worker's copy changed, it now has its
  own wording.
- **Target model:** Claude Opus 5.5 and Claude Fable 5.2, the models the sessions run on.
- **Line numbers** are at cbff298d, the commit this audit started from.
- **Not applicable:** Group 4 (request config): VibeSwitcher builds no API requests; Claude Code does.

## Summary

The prompts had little dated emphasis: they were written plainly from the start, with a reason beside most rules. What
they had instead was text that something else already says to the model, and so costs every session without telling
it anything:

1. **Rules the tools, permission rules and scripts already enforce, said again in prose.** The worker's brief listed
   all 80 git commands its permission rules refuse (2,800 characters), the report tool's evidence fields and refusal,
   the load harness's own caps, and vs-heavy twice. The lead's prompt restated ask_user's, update_task's and
   dismiss_finding's descriptions and audit's out-of-date refusal.
2. **Stale facts.** The lead's prompt listed 22 tools while it has 28, and AGENTS.md's lint command named 9 of the 14
   lint suites: a session following it skipped 5 lints.
3. **The worker's file rules said three times** ("don't rm" in three places, in two paragraphs).

Counts: Group 1 (dated text) 3, Group 2 (instruction files) 4, Group 3 (tool contracts shadowed by prose) 9.

Size of the rendered prompts, in characters, from the fixture the tests use (`LeadPolicyTextsTests.task`,
`LeadWorkflow.parse("")`, root `/r`, the default working policy, default Mac limits), and from this repository's own
root (its lint list and sandbox paragraph included):

| Prompt | Fixture before | Fixture after | Repository before | Repository after |
|---|---|---|---|---|
| Lead | 20,395 | 18,153 (−11 %) | 20,740 | 18,498 |
| Worker (task section included) | 12,791 | 8,600 (−33 %) | 14,020 | 9,842 |

## Findings

Each removed rule is either enforced or said elsewhere ("Where it's said now"), or something the model sees from the
code. High: contradicted by the repository or said word for word by a tool the model has. Medium: the documented
pattern, the model's behaviour judged rather than measured.

### Applied

| # | Location | Evidence | Pattern | Why it's obsolete | Where it's said now | Confidence | Action |
|---|---|---|---|---|---|---|---|
| 1 | LeadWorkflow.swift:634, :959 | `Your tools (the vibeswitcher MCP server): status, sessions, …` | 3: prose list shadowing the real tool list; 2: volatile specifics | Stale: lacks stop_worker, tell_lead, accept_git_hooks, questions, revise_question, withdraw_question. The model gets the real list from the MCP server. | The lead's tool list (`LeadToolset.tools`) | High | remove (two tests that read the constant now read the tool list) |
| 2 | AGENTS.md:23 | `--filter 'AccessibilityLint\|DebugAidsLint\|…\|TemporaryFolderLint'` | 2: volatile specifics | Names 9 of 14 lint suites (no AgentExportLint, DocLinksLint, ElapsedTimeLint, PrivateNamesLint, PhoneMainSyncLint). | `--filter 'LintTests/'` selects every `*LintTests` suite and nothing else (checked: 14 suites, 49 tests) | High | rewrite |
| 3 | LeadWorkflow.swift:1194 | `Git commands refused here, by your permission rules: \`git push\`, …` (≈2,800 characters) | 1e/1d: unenforced-vs-enforced; 3: shadowing | A Claude worker's permission rules refuse each one and say so when tried; the brief still says what matters to a worker (don't push, switch to the base, rebase or amend, use `git -C`). A Codex worker has no such rules (`LeadLaunch.codexUnenforced`), so its brief keeps the list. | `LeadLaunch.deny(.worker)`; the "Out of date" paragraph | High | remove from a Claude worker's brief (the lead keeps the list: it writes the briefs; a Codex worker's brief keeps it) |
| 4 | LeadWorkflow.swift:1193 | `\(heavyWork)` in the worker | 1c: repetition | The policy section every role gets has the same rule (`WorkingPolicy.heavyJobs`); vs-heavy prints why it waits and when it stops a command (exit 124). | `WorkingPolicy.heavyJobs`; Resources/bin/vs-heavy's own messages | High | remove from the worker |
| 5 | LeadWorkflow.swift:800–806 | `one entry per acceptance check: check (its number, …), how (…), result (…), and screenshots (…)` … `A done report without an entry for every check is refused` | 3: contract in prose instead of the tool | The report tool's description and its `evidence` parameter say the fields and the refusal word for word. | `LeadToolset.evidenceShape`, the report tool's description | High | rewrite (one line, plus the blind check) |
| 6 | LeadWorkflow.swift:1191, :661 | `\(loadTests)` in the worker; `report refuses a done without it` | 1c: repetition; enforced rule | test-under-load.sh caps the load at 2×ncpu and waits while the Mac is loaded; report refuses a done without the run under load. What the model can't see stays: a test waits on its event, only the script loads the Mac, no busy loops of its own. | scripts/test-under-load.sh (`--load`, `--max-load`); `LeadToolset`'s load proof (report) | High | rewrite: one worker paragraph (`newTests`); the verifier keeps `loadTests` |
| 7 | LeadWorkflow.swift:966–972 | `It doesn't block: keep working … Never put a timer on a blocking question, on merging a sensitive path, …: ask_user refuses those` | 3: shadowing; 1a: NEVER | ask_user's description says this nearly word for word, and the tool refuses each case. Kept: propose with a timer for a reversible choice, and don't act before the go-ahead. | ask_user's description and refusals | High | rewrite |
| 8 | LeadWorkflow.swift:983–985 | `audit refuses a branch that hasn't taken in main's commits …: have the worker \`git merge main\` first. That check is audit's, so the verifier needn't be told main moved.` | 2: volatile specifics | Out of date: audit now refuses only a branch that conflicts with the base, and that refusal names the files and gives the message to send the worker; a branch behind the base without a conflict is audited on the merged result. | audit's refusal (`LeadToolset`, "Message its worker to bring its branch up to date by merging…") | High | remove |
| 9 | LeadWorkflow.swift:1004–1014 | `An Important finding comes with its failure (failure_scenario …); one without is recorded as a Nit` … `for an Important one the reason must cite a file and line, …` | 3: shadowing; enforced rule | The verifier's submit_audit records a missing scenario as a Nit; dismiss_finding's description gives what to cite and refuses a reason without it. | submit_audit; dismiss_finding's description and refusal | High | rewrite (the flow kept: message the worker, answer_findings, re-audit, dismiss, or a task of its own) |
| 10 | LeadWorkflow.swift:994–1003 | `Folded when another task carries its work …: update_task(task, status: folded, into: …) … Removed only for a record made by mistake …` | 3: shadowing | update_task's description defines each status and its effects; start_worker, audit and merge refuse a finished task. Kept: never failed for a task that won't merge, and stop_worker then cleanup. | update_task's description; the tools' refusals | Medium | rewrite |
| 11 | LeadWorkflow.swift:841 | `answer_findings: fixed (commit the fix first) or disagree` | 3: shadowing | answer_findings' description says it. Kept: a reason the re-audit can check, then report done again. | answer_findings' description | High | rewrite |
| 12 | LeadWorkflow.swift:847–850 | `When it's reached, VibeSwitcher tells you to stop: commit what works, then report with status over_budget saying what works (with evidence), …` | 1c: repetition | The message at the budget (`LeadBudget`) says what an over_budget report holds, and so does the report tool's `summary`. | `LeadBudget`'s stop message; the report tool | High | rewrite |
| 13 | LeadWorkflow.swift:1174–1175 | `At each milestone (a part working, checks passing, what's next), call progress with one line: …` | 1c: repetition | The worker's start message says "Call progress at each milestone", and so does the progress tool's description. | `LeadToolset` (start_worker's start message); the progress tool | High | remove |
| 14 | LeadWorkflow.swift:1176–1182 | `Keep your temporary folder small: …don't rm what's there…` + `\(scratchFiles)` + `If an untracked file is left there anyway, don't rm it` | 1c: repetition (three "don't rm") | One rule said three times, across two paragraphs. Nothing dropped: where builds and scratch go, rm nothing (cleanup does; a removal outside the worktree waits on a prompt only the user can answer), name a big folder or a stray file. | `LeadPrompts.workerFiles` (the verifier keeps `scratchFiles`) | High | rewrite (one paragraph) |
| 15 | LeadWorkflow.swift:1172 | `Start: read the task; … look at the code you'll touch and the tests that cover it.` | 1c: default behaviour | Reading the task and the code is what the model does unprompted; only the init command is project-specific. | — | Medium | rewrite (`Start by running …`, only with an init command) |
| 16 | AGENTS.md:12 | `Run tests only through \`scripts/test.sh\` (a scratch home), never a bare \`swift test\`.` | 1d: enforced rule | Each test target refuses to run on the user's own folder and names scripts/test.sh (`VibePaths.testRefusal`). | `VibePaths.testRefusal`; the Commands block's comment | High | move to the Commands block |
| 17 | AGENTS.md:5–11 | `Never type …`, `Never hide …`, `Never attach …`, `Never touch …`, `Never install …` | 1a: pressure language without a reason | Five lines in a row opening with "Never", two without a reason. Every protection kept, each stated plainly with why (real sessions, Spaces, the password dialog, the user's app, installs). | AGENTS.md | Medium | rewrite |
| 18 | AGENTS.md:13 | `Show a fix's test failing without the fix: …` under Hard rules | 2: wrong place | A testing practice among the rules that protect the machine; it dilutes them. | AGENTS.md › Practices | Medium | move |

Also tightened while there (no rule removed): the worker's `Processes:` line now says why a loose pattern is refused
(LeadWorkflow.swift:1189), and `Stuck:` says report blocked (LeadWorkflow.swift:1213).

### Kept on purpose (flag, no edit)

| Location | Evidence | Why it stays |
|---|---|---|
| LeadWorkflow.swift:1183, :690–694 | `Debuggers: never attach one …` | A hard rule: the deny rules (`LeadLaunch.debuggers`) stop the usual tools, not every way of inspecting a process, and the dialog is on the user's screen. Its wording is shared with the verifier, so it's tightened once the verifier's audit task is done. |
| LeadWorkflow.swift:1184–1188, :1053 | the real-terminal paragraph (worker), `SessionNote.realTerminal` (lead) | It overrides Claude Code's own advice to suggest `! <command>`, which the model can't know is wrong here. |
| LeadWorkflow.swift:975 | `Workers are refused these git commands, so no brief may need one: …` (lead) | The lead writes the briefs and can't see the workers' rules; a contract that needs a refused command can never be followed. add_task could refuse such a contract instead, which would let this list go: a task for later, not this one's. |
| LeadWorkflow.swift:1106–1121 | the Mac limits paragraph (`start_worker and audit refuse while its load …`) | Deliberately said so the lead plans around the limits rather than discovering them by refusal (its doc comment). |
| LeadWorkflow.swift:954 | `You never write code yourself: no edits, no commits.` | The role line; one sentence of context. |
| LeadWorkflow.swift:644–694 | `loadTests`, `heavyWork`, `scratchFiles` | The verifier's wording; out of scope here. |
| AGENTS.md:21–39 | Commands and Practices duplicating parts of the worker's brief | AGENTS.md is read by every session in this repository, the user's own included; the brief is every project's. Working redundancy that agrees (keep-list item 8). |

## How it was checked

- The prompts were rendered before and after with the fixture above (a probe test, not committed) for the sizes, and
  read in full before and after.
- `bash scripts/test.sh --filter 'LeadPolicyTexts|LeadWorkflow|SessionNote'` and the tests of every other suite that
  renders the lead's or the worker's prompt pass; `bash scripts/test.sh --filter 'LintTests/'` passes.
- Tests that pinned removed wording now check where it's said instead: the tool's description (ask_user,
  update_task, dismiss_finding, progress, report's `evidenceShape`), the worker's start message, or the permission rule.
