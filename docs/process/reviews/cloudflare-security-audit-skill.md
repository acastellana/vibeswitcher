# Ideas review: cloudflare/security-audit-skill

- **Repository:** https://github.com/cloudflare/security-audit-skill
- **Commit read:** `c1c8a8c1471069fb0e188eeaff69b8e8db6564a8` (2026-09-14, "Clarify guidance and full audit modes")
- **Licence:** MIT, Copyright (c) 2025-2026 Cloudflare, Inc. Reuse is allowed if the notice is kept when substantial
  portions are copied. This report quotes only short phrases, and any adaptation below should be written fresh.

**What it really is.** A set of instructions for a coding agent: about 1,800 lines of Markdown prompts for a six-phase
whole-repository security audit, plus a JSON schema and two zero-dependency Node validators with tests (22 files). It
has no runtime of its own: the host agent does the orchestrating, and the validators check only format and ledger
consistency. Its README says it seeded Cloudflare's larger harness and that one run found about half of what repeated
runs found, but the repository holds no eval data to support that.

Read as documents only: nothing in it was run or installed. It audits foreign code for vulnerabilities across a whole
repository, while VibeSwitcher's verifier judges one branch from its own worker against a contract, so most of its
machinery doesn't transfer. What does transfer is a few habits about what a checker does with a doubt, a state and a
claim of coverage.

## The baseline these ideas aim at

From the 2026-11-01 `--all` run in `docs/process/verifier-eval.md` (14 known bugs, 3 clean cases, $49.81, one sample):

- **8 of 14 found by place, only 4 as Important.** The other 4 (a-fix-s-regression F1 and F3, the-briefing-uses F1,
  ending-a-session-ends F2) were Nits, which never stop a merge. Those are real bugs that would have landed.
- **6 missed.** By my reading of the case table, 5 of them are a state or a sibling path the happy path doesn't walk:
  a value not reset on a session switch (a-slash-command-that), a command still running (a-base-branch-the F2), a
  setting read once before a long pass (finished-work-lands), a crashed or stopped run (steadier-merge-gate), a file
  git merged cleanly rather than with a conflict (lead-record-commits). The sixth is a language error the contract
  itself wrote (ending-a-session-ends F3).
- **0 false alarms** on 3 clean cases, so there is room to be stricter, though 3 cases is a small guard.

The eval scores by place, and its own notes show a place match can miss the substance. Each measurement below should
also read the findings' text.

**This baseline runs without `REVIEW.md`, and real audits don't.** The verifier gets the file from the base branch
(`LeadRisk.reviewGuide`, `LeadWorkflow.swift:1528`), and the eval's clones have it only if the case's base does. None
of the 12 bases holds it (I checked each with `git cat-file`), because it arrived on 2026-10-26, after those commits.
Its lines already name two of the misses (`REVIEW.md:6` a-slash-command-that, `:16` finished-work-lands) and make
a-fix-s-regression's escapes Important (`:13`). So the eval understates real audits on exactly those bugs.

**Before ideas 1 and 2:** have the eval give each case today's `REVIEW.md` (a small script change), and run `--all` once
for a true baseline (about $50). Otherwise a change can win on bugs real audits are already told about.

## Ideas, ranked

Ideas 1 and 2 can then share one `scripts/verifier-eval.sh --all` (about $50, which
`docs/process/verifier-eval.md:8` requires before a verifier prompt change merges anyway). They stay attributable
because each is scored only on its own bugs: idea 1 on the four that were Nits, idea 2 on three that were missed.

### 1. A doubt about behaviour gets settled, not filed as a Nit

- **Source:** `skills/security-audit/VALIDATION-AND-REPORTING.md:87` (the unresolved state is "never a parking place
  for a speculative idea"), `SKILL.md:152`, `HUNTING.md:71` (narrowest check that settles the claim).
- **VibeSwitcher today:** "Nit: everything else, style, naming, a doubt" (`Sources/VibeCore/LeadWorkflow.swift:1516`).
  A verifier that half-sees a bug can record it where it can't hold the merge.
- **Change:** in the verifier prompt, a doubt about what the code does must end one of three ways before submit_audit:
  Important with its failure_scenario (reading the path is enough; a focused test or a TMPDIR probe where one is
  cheap, as the checklist already allows at `LeadWorkflow.swift:1623`); dropped, if the code refutes it; or a Nit
  starting `Unresolved:` with the one fact that decides it and the command that would settle it. Style Nits are
  untouched. No new severity: a fourth state would touch the board, the vote and merge for no measured gain yet.
- **Goal:** fewer issues. **Size:** S. **Verdict:** adapt.
- **Risk:** more Importants mean more rounds and false alarms. The two-round `reconsider` cap (`lead-rules.md` #11)
  bounds the rounds.
- **Measure:** how many of the four Nit-only bugs (a-fix-s-regression F1 and F3, the-briefing-uses F1,
  ending-a-session-ends F2) come back as Important, against the baseline run with `REVIEW.md`; target 2 more than that
  run, with 0 Important on the clean cases. Watch cost per case.

### 2. Give the single verifier a bug walk, from the contract's invariant

- **Source:** `HUNTING.md:43` (work from a concrete invariant), `HUNTING.md:37` (read sibling, retry, cancellation and
  error paths), `HUNTING.md:58` (absent, stale, reordered, concurrent, failed-dependency states).
- **VibeSwitcher today:** the default audit is one verifier (`auditFinders = 1`, `LeadWorkflow.swift:49`), and its
  check step is acceptance checks, reading the diff, and looking for integrity problems (`LeadWorkflow.swift:1495`).
  Reading "the code around it and its callers" exists only in the `bugs` finder's brief (`LeadWorkflow.swift:1307`),
  which a single verifier never gets. `REVIEW.md` already covers two states, shared per-session state (`:6`) and a
  setting read once before a long step (`:16`). The security-contract rule of 2026-11-05 00:30:32 works at contract
  time and only for security.
- **Change:** add the three states `REVIEW.md` lacks, in its own form and each from its case: a run that crashed or was
  stopped (steadier-merge-gate); an operation still in flight (a-base-branch-the F2); the other branch of the path,
  such as clean versus conflicted (lead-record-commits). They must fit the 349 bytes left under its 2,048-byte clip
  (`LeadRisk.swift:314`). In the first-audit check, add one sentence: name the invariant the contract implies and read
  the callers. Keep it specific: the checklist's own comment says general text only adds cost (`LeadWorkflow.swift:1607`).
- **Goal:** fewer issues. **Size:** S. **Verdict:** adapt.
- **Risk:** a longer prompt and longer audits. Overfitting too: these misses both motivate the lines and score them,
  so a gain needs confirming on cases added later (backlog C3).
- **Measure:** those three bugs, 0 of 3 today, read for substance; target at least 2; 0 Important on clean cases. The
  baseline run also shows, for free, whether `REVIEW.md:6` and `:16` catch their two misses. If they don't, more lines
  of that kind won't help either, and this idea should stop.

### 3. A verifier says what it checked, file by file

- **Source:** `RECONNAISSANCE.md:154` (the ledger, not a sentence, is the coverage claim), `HUNTING.md:213` (each check
  owns its reviewed paths and invariant).
- **VibeSwitcher today:** submit_audit takes a free-text summary, tests, findings and verdicts, and nothing per file
  (`Sources/VibeCore/LeadToolset.swift:651`). When a bug is missed, nothing shows whether the verifier looked there.
- **Change:** take the ledger's idea at the scale of a diff. Start with the summary ending in a `Checked:` list: one
  line per changed non-test source file, with the invariant checked and whether by reading or running. If it earns its
  place, make it an optional submit_audit field the tool compares with `git diff --name-only`.
- **Goal:** fewer issues; a miss becomes diagnosable, which helps backlog C3. **Size:** S to try, M as a tool field.
  **Verdict:** adapt.
- **Risk:** form-filling. The skill says itself that validators prove format only (`VALIDATION-AND-REPORTING.md:118`),
  so don't gate merges on it.
- **Measure:** on the 6 missed bugs, how many were in a file listed as checked (wrong conclusion) versus not listed
  (never looked). That split decides whether idea 2 or more focus is the fix. Keep it only if the split is informative.

### 4. A real finding triggers a search for its variants in the branch

- **Source:** `HUNTING.md:65` (search for lexical, structural and logical variants of a reusable root cause).
- **VibeSwitcher today:** nothing asks for it at audit time. Decision 2026-11-05 00:30:32 covers it for security
  contracts, before the work. memory-the-host-parser (`:634` and `:688`) and lead-record-commits (`:789` and `:600`)
  are bugs with two places.
- **Change:** one sentence: after an Important finding, look for the same cause in the branch's files and callers, and
  name each place in that finding.
- **Goal:** fewer issues, cheaper (fewer rounds). **Size:** S, plus a small scoring change. **Verdict:** adapt.
- **Risk:** drift beyond the branch; limit it to files the branch touches and their callers.
- **Measure:** the eval counts a bug as found at any one place (`scripts/verifier-eval.sh:346`), so it can't see this
  yet. Score places found out of places listed, and count re-audit Importants that share a cause with an earlier one.

### 5. One checklist line for identity taken from the message

- **Source:** `DESKTOP-MOBILE-AND-LOCAL-IPC.md:46` (claimed principal versus channel identity), and
  `RECONNAISSANCE.md:88` (select a domain by the boundary found, not by a name that appears).
- **VibeSwitcher today:** a five-line checklist, each line with its board cases (`LeadWorkflow.swift:1608`). None covers
  a receiver that believes a name carried in the message. Lead mail's first contract had that shape and took 3
  follow-up tasks (decision 2026-11-05 00:30:32).
- **Change:** add one line, cited to that case, for branches that add a channel or a sender: where does the receiver
  get who is speaking, and can the sender write that part? Add nothing from the skill's taxonomy without a VibeSwitcher
  case behind it; that is the checklist's own rule.
- **Goal:** safer. **Size:** S. **Verdict:** adapt.
- **Risk:** small; it only reaches branches that get the checklist.
- **Measure:** add the lead-mail audit as an eval case, then with and without the line, as a-fix-s-regression was
  measured (3 of 3 with the checklist, 0 of 3 without).

### 6. A closed finding can come back if its lines change

- **Source:** `RECONNAISSANCE.md:68` and `SKILL.md:102` (a rejection suppresses only the unchanged claim).
- **VibeSwitcher today:** "A closed finding below is never raised again, under its id or another"
  (`LeadWorkflow.swift:1694`), even if a later fix rewrites those lines and the failure returns.
- **Change:** add "unless this diff changes its lines and the failure is back".
- **Goal:** fewer issues. **Size:** S. **Risk:** re-arguing dismissed findings. **Verdict:** skip for now.
- **Why skip:** no incident shows it, and the standing policy is incident first, then the check (decision
  2026-11-06 22:35:21). Build it if an escape lands on a closed finding's lines. The eval has no re-audit case to
  measure it, so it would be measured by that board count.

### 7. A minority Important gets verified instead of outvoted

- **Source:** `VALIDATION-AND-REPORTING.md:5` (every candidate gets a fresh verifier; there is no vote).
- **VibeSwitcher today:** a finding fewer than most finders raised is `unconfirmed` and doesn't hold the merge unless
  strict_paths does (`LeadToolset.swift:6262`). Focused finders disagree by design, so the vote can discard exactly a
  specialist's finding, as decision 2026-10-26 11:01:23 noted.
- **Change:** send an unconfirmed Important to one fresh verifier that tries to refute it.
- **Goal:** safer. **Size:** M. **Risk:** one more agent per such finding. **Verdict:** skip.
- **Why skip:** `audit_finders` defaults to 1 and I found no record of an audit of this project run with more than one
  finder (the one trace, in `docs/lead/incidents.md`, is another project's). The eval replays a single verifier, so it
  can't measure this, and strict_paths has its own check due on 2026-11-15 (IM-3 in `docs/process/impact.md`). Revisit
  only if finders come into regular use.

## Looked good, but already here or already rejected

| In the skill | Where VibeSwitcher stands |
|---|---|
| The checker is never the finder (`README.md:95`) | Worker versus verifier, on another model: `lead-rules.md` #6, #12 |
| A finding needs evidence and a concrete result (`SKILL.md:140`) | Important needs a failure_scenario, else it's a Nit: `lead-rules.md` #10 |
| Verifier ignores the author's claims | Backlog B7; the scratch-worktree half is backlog C8 |
| Structured verdicts checked by code | submit_audit and `LeadFindingsTests`, `lead-rules.md` #10 |
| A clean run may have no findings (`VALIDATION-AND-REPORTING.md:186`) | "Nothing found: leave findings out", `LeadWorkflow.swift:1521` |
| Quick, standard and deep profiles | Review level from what the diff touches: `LeadRisk.deterministic`, `lead-rules.md` #16, decision 2026-10-25 13:45:22 |
| Regression case for each fix | `lead-rules.md` G12, decision 2026-10-25 09:46:35; mechanical check is backlog A7 |
| Run-to-run variance (`README.md:98`) | "One run of one case is one sample" in `docs/process/verifier-eval.md`; a larger eval is backlog C3 |
| Hidden measurement of a checker's recall | Parked: decision 2026-11-06 22:35:21 |
| Findings remembered between runs | The re-audit's open and known lists, `LeadWorkflow.swift:1239` |
| Coverage-critic waves (`HUNTING.md:221`) | Rejected: the working policy's no-audit-loop rule; decision 2026-10-26 11:01:23 (b) and (c) |
| A scheduled whole-repository sweep | Rejected: decision 2026-10-26 11:01:23 (c) |
| OS sandbox for code under review (`SKILL.md:33`) | Rejected as unworkable: a sandbox can't nest around SwiftPM (`Sources/VibeCore/ConfigSeal.swift:10`); config seals and scratch homes instead, `lead-rules.md` #23 |

## What doesn't fit

- **The six-phase run itself.** Even its `quick` profile starts four reconnaissance agents, then hunters, a critic and
  a verifier per candidate, against one verifier at $1.65 to $5.86 a case here. It also targets a repository, not a
  branch with a contract.
- **Artifact promotion by descriptor (`SKILL.md:68`).** It guards against hostile target files. VibeSwitcher's branch
  code comes from its own workers, which have already run it with the same authority.
- **Five-level severity (`SKILL.md:154`).** Important or Nit is what merge needs.
- **A way round the filter.** The security review the safety filter stopped on 2026-11-08 stays the user's call
  (decision 2026-11-08 14:15:49). Adopting this skill's framing isn't a route around it.
