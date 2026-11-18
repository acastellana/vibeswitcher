# Cold prompt caches and Claude Code mods in team sessions, 2026-11-18

Written by a worker (task cache-aware-vibeswitcher) after the user asked how the cache-clock mod could save tokens in
VibeSwitcher, and how VibeSwitcher should treat mods. No product code or setting was changed, and nothing was
installed. The numbers come from `scripts/cache-cold-cost.py`.

## In short

**Cold caches are a small cost here: 0.3% of the week's tokens and about 3 to 6% of its estimated bill.** In the 7
days to 2026-11-18 11:45, this project's sessions spent 1.86 billion tokens. 5.0 million of them were cache writes after
a gap longer than the cache's lifetime, in 40 cold re-sends: 27 by the lead, 6 by workers, 7 by workers' subagents, none
by a verifier. Writing that context again instead of reading it cost an estimated $20 at the Receipts prices, or $63 if
Fable 5.2 (which has no price in that table) is priced as Fable 5.1.

Three things keep the number low. Workers are released during audits. Every audit ended inside the hour. And Claude
Code compacts a large idle session itself, a few minutes before its cache expires: 13 times this week, 4 of them the
lead.

**The mod would save nothing in VibeSwitcher, and its default action must not run in a team session.** It is a display
for a person at a terminal. Left on, it submits a prompt by itself and writes a file into the session's root.

**The tokens are in carrying large contexts, not in re-sending them.** 97% of all tokens are cache reads. The lead read
311 million tokens in 1,214 requests, a mean prompt of 261k. The proposals that save real tokens shrink what is carried:

1. Hand the lead over to a fresh one when it has been idle 50 minutes with a large context, while its cache is warm:
   about 80M tokens a week by simulation.
2. Wake the lead less often for reports that need no action: about 0.6M tokens per wake avoided.
3. Keep releasing workers during audits: by tokens that is already the cheaper choice.

A countdown in the sidebar is cheap and honest but saves under 1M tokens a week. A keep-warm request spends 8 times
more tokens than it saves.

**Mods: the user's own sessions keep them; team sessions should run with an allowlist written into each role's
`--settings`.** Today every worker, verifier and lead loads every plugin the user has enabled, mods included.

## 1. Measurement

### Sample and method

- **Sessions.** Every session VibeSwitcher started for this project whose transcript was written in the window: 2 lead
  sessions, 118 worker sessions, 110 verifier sessions, and their subagents (130 of workers', 6 of the lead's). They
  are told apart by the name VibeSwitcher starts them with (`lead-…`, `worker-<slug>`, `verify-<slug>`,
  `finder<N>-<slug>`). The user's own sessions in the same folders are skipped after their name.
- **What is read from a transcript.** A response's usage numbers and model, the time its request was sent, the session's
  name, which kind of sender started a turn (`turnOrigin`), an error's kind, and a compaction's token counts. No message
  text is read, kept or printed. The script's header lists the exact keys.
- **What is read from elsewhere.** The Mac's sleeps from `pmset -g log` (48.8 hours asleep in the window). From the
  board and its archive: each task's start, done report, merge and end times, and each question's asked and answered
  times.
- **A cache line** is one transcript's responses in order. A subagent has its own, and so does a session's advisor.
- **The TTL in force** at a request is the bucket the line last wrote to: 1 hour for `ephemeral_1h` tokens, 5 minutes
  for `ephemeral_5m`.
- **A cold re-send** is a response whose request was sent more than that TTL after the previous one. Its cache-write
  tokens are "written cold". The part that had been in the cache before the gap is "re-sent".
- **Codex workers** keep no Claude Code transcript and are not in these numbers.

Reproduce, from the repository's root:

```sh
python3 -I scripts/cache-cold-cost.py --until "2026-11-18 11:45" --events
python3 -I scripts/cache-cold-cost.py --until "2026-11-18 11:45" --price-as claude-fable-5-2=claude-fable-5-1
```

The first gives every token count and the dollars at the Receipts prices. The second gives the dollars with Fable 5.2
priced as Fable 5.1 (section 2); its token counts are the same. Two runs of the same window a few minutes apart differed
by under 0.5% in the token totals, since responses in flight at the window's end are written late. Claude Code also
prunes old transcripts, so a much later run may find fewer.

### Which TTL each role gets

Measured from the buckets, not assumed:

| Role | Cache write | In the 1 h bucket | In the 5 min bucket | TTL it gets |
| --- | ---: | ---: | ---: | --- |
| Lead | 6.2M | 100.0% | 0.0% | 1 hour |
| Worker | 19.3M | 99.2% | 0.6% | 1 hour |
| Verifier | 8.3M | 100.0% | 0.0% | 1 hour |
| Lead's subagents | 813k | 0.0% | 100.0% | 5 minutes |
| Workers' subagents | 12.3M | 0.0% | 97.1% | 5 minutes |
| Workers' advisor (29 calls) | 0 | – | – | none: it neither reads nor writes a cache |

The transcripts hold the same answer as a field: each response records `promptCacheRequested` as `1h` (main sessions)
or `5m` (subagents).

The TTL holds in the data. Of 9,919 requests sent within the hour of the last one on a 1-hour line, 32 missed the
cache. Past 2 hours, 17 of 18 missed:

| TTL in force | Gap since the last request | Responses | Missed the cache | Cache read / last prompt |
| --- | --- | ---: | ---: | ---: |
| 1 h | up to 5 min | 9,491 | 28 | 99.9% |
| 1 h | 5–30 min | 399 | 3 | 99.4% |
| 1 h | 30–55 min | 27 | 1 | 98.7% |
| 1 h | 55–60 min | 2 | 0 | 100.1% |
| 1 h | 60–70 min | 4 | 2 | 50.5% |
| 1 h | 70–120 min | 11 | 9 | 27.3% |
| 1 h | over 2 h | 18 | 17 | 9.3% |
| 5 min | up to 5 min | 2,387 | 1 | 100.0% |
| 5 min | 5–30 min | 7 | 5 | 23.6% |

5 of the 33 gaps past the hour still read the cache. Something refreshed it that the transcript doesn't record as a
response. The mod's notes name one such thing: `/recap` and `/btw` send the conversation as a side request. So a
countdown built from the transcript can say "cold" when the cache is still warm, never the other way round.

### Cache writes by role, and the cold share

| Role | Tokens | Cache write | Written cold | Share of its writes | Cold re-sends | Median context at one | A session's first write | Other miss inside the TTL |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Lead | 318.0M | 6.2M | 3.8M | 60.8% | 27 | 218k | 30k | 668k |
| Worker | 1.16B | 19.3M | 589k | 3.1% | 6 | 163k | 3.3M | 830k |
| Verifier | 142.5M | 8.3M | 0 | 0.0% | 0 | – | 4.0M | 0 |
| Lead's subagents | 23.1M | 813k | 0 | 0.0% | 0 | – | 112k | 0 |
| Workers' subagents | 210.1M | 12.3M | 617k | 5.0% | 7 | 130k | 3.8M | 0 |
| **All** | **1.86B** | **47.0M** | **5.0M** | **10.6%** | **40** | 202k | 11.3M | 1.5M |

Nearly all of the cold writes are re-sent context (5.0M of 5.0M): the gap added little that was new.

A session's first write is not a re-send, and it is the larger item: 11.3M tokens, more than twice the cold writes. 118
workers, 110 verifiers and 136 subagents each start by writing their system prompt, tools and brief. A worker's first
prompt is 57k tokens and a verifier's 59k.

### Causes of the cold re-sends

| Role | Cause | Cold re-sends | Written cold | Share of the role's cold writes |
| --- | --- | ---: | ---: | ---: |
| Lead | A prompt typed in after an idle: the user, or a notice of the app's own | 15 | 2.0M | 53.2% |
| Lead | Mac sleep | 11 | 1.5M | 40.7% |
| Lead | The user's answer to a question | 1 | 234k | 6.2% |
| Lead | A worker's report, an audit's verdict or a merge's result | 0 | 0 | 0.0% |
| Worker | Waiting on a merge | 2 | 265k | 45.0% |
| Worker | Waiting on an audit | 2 | 153k | 26.0% |
| Worker | Waiting on the lead (no audit, merge or question in the gap) | 1 | 133k | 22.6% |
| Worker | Mac sleep | 1 | 38k | 6.5% |
| Workers' subagents | Mac sleep | 5 | 613k | 99.2% |
| Workers' subagents | A tool call past the 5 min TTL | 2 | 5k | 0.8% |
| Any | A usage-limit stop | 0 | 0 | 0.0% |

How each cause is decided:

- **Mac sleep**: the gap, less the time the Mac slept in it, is no longer than the TTL. The gap would have stayed warm
  on an awake Mac.
- **Usage-limit stop**: the session logged a `rate_limit` error in the gap. There were 5 such errors in the window, and
  none came before a cold re-send. A stop VibeSwitcher makes itself (holding new starts until the reset) leaves no error
  in a transcript and would show under "waiting on the lead".
- **A worker waiting on an audit or a merge**: the gap overlaps an audit of its task (a verifier's first request to its
  last) or its merge's test run, whichever more.
- **Waiting on the user**: a question about the task was open for at least half the gap.
- **What woke the lead**: a board event (a done report, a merge, an answer) or the end of a worker's or verifier's turn
  in the 90 seconds before the wake. VibeSwitcher wakes an idle lead within 8 seconds of a report
  (`LeadWake`, `Sources/VibeCore/LeadDelivery.swift:503`). With none, the wake was typed in.

Does that last test work? Of the lead's 532 typed-in turns, 353 began within 90 seconds of a team event. Of the 27 cold
ones, 1 did: the user's answer to a question. None began with a report, a verdict or a merge. So the lead is not being
woken cold by reports. While the team works, reports arrive more often than
hourly and the lead stays warm. The long idles end when the user comes back.

What the method can't tell apart: a prompt the user typed from a notice the app typed (a question's timer, a stall
notice). Both show as typed. Those 15 gaps ran from 1.3 to 20.6 hours.

### What the compactions show

Claude Code compacted 13 main sessions in the window: 4 times the lead (1.2M tokens before, 87k after) and 9 times a
worker (2.4M before, 192k after). All 13 came 50 to 60 minutes after the session's last response, with the trigger
`auto`, each at 200k tokens or more. That matches what the mod's README describes as Claude Code's idle compaction
(2.1.299 and later, on by default): a conversation of 200k tokens or more, idle about 54 minutes, is compacted before
its one-hour cache expires.

So Claude Code already avoids some of the dearest cold re-sends, and VibeSwitcher doesn't see it happen. A lead
compacted this way carries on with a summary Claude Code wrote, not with VibeSwitcher's handover.

It doesn't catch them all. The lead had 16 cold re-sends whose context was 200k or more before the gap:

- 4 had been compacted in the gap, and re-sent 38k to 74k instead of 205k to 457k.
- 7 were sleeps. The Mac was asleep before minute 54.
- 5 were neither, and 4 of those re-sent 233k to 321k in full. I didn't establish why no compaction ran.

## 2. What it costs

Prices are `LeadPrices.table` (`Sources/VibeCore/LeadReceipt.swift`, as of 2026-10-06), the ones the Receipts line
uses. The script parses them from the source. Cache writes cost 2× input in the 1-hour bucket and 1.25× in the 5-minute
one. Reads cost a tenth of input or less.

| | At the Receipts prices | With Fable 5.2 priced as Fable 5.1 |
| --- | ---: | ---: |
| The week's tokens | 1.86B | 1.86B |
| Estimated bill | $744, plus 175.1M tokens with no price | $1,100 |
| Written cold | 5.0M tokens = 0.3% of tokens, 10.6% of cache writes | the same |
| Extra cost of re-sending instead of reading | $20 = 2.7% | $63 = 5.7% |
| Of it the lead's | $14 | $54 |
| Of it workers' | $4 | $6 |
| Of it workers' subagents' | $3 | $3 |

**The Receipts table has no price for `claude-fable-5-2`**, the model of 175.1M of the week's tokens (part of the lead's
week and many verifiers'). A receipt with those tokens shows "cost unknown", and 9 of the 15 verifier receipts on the board
do. The right-hand column is an assumption of mine, not a published price.

By role, with that assumption: lead $164, workers $503, workers' subagents $137, verifiers $218, workers' advisor $67,
lead's subagents $10.

One cold re-send of the lead's median context (218k) costs about $1.70 on Opus 5.5 and $4.30 on Fable at 5.1 rates.
Reading it warm costs 4 to 5 cents.

## 3. Proposals, ranked by tokens saved against cost

"Tokens saved" is per week, by this measurement. Dollars use the Fable 5.2 assumption above.

### 1. Hand the lead over at a long idle when its context is large

- **Saves**: about 81M cache-read tokens a week (a quarter of the lead's tokens) and 0.5M cold-written tokens, est.
  $27. From the script's simulation with a 150k threshold: 8 handovers in the week, 5 of them with the Mac awake at
  minute 50. With a 100k threshold: 11 handovers, 88M tokens. With 200k: 5 handovers, 48M. The simulation hands over
  only where the lead's context was still whole at its next request. Where Claude Code had compacted it in the gap (4
  times), it counts nothing.
- **Why it's large**: the saving is not the re-send. It is every later request. A fresh lead starts near 58k and the
  simulation gives it 80k after it has read its handover. Each later request then carries that much less, until the context has grown back.
- **What changes**:
  - `LeadRotation.reason` (`Sources/VibeCore/LeadRotation.swift:18`) gains a rule: idle 50 minutes and context over a
    token count. Today's context rule is a percent of the window (over 60%), checked only when the lead is quiet. The
    lead reached 457k tokens this week, and Claude Code's idle compaction got to it first, 4 times.
  - `LeadController.rotateIfDue` (`Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift:2178`) already runs every
    3 seconds and already has the whole flow: ask for a note, write it, start the fresh lead. It needs the time of the
    lead's last request, which the transcript's tail has.
  - When the Mac was asleep at minute 50 (3 of the 8), the cache is cold at the wake. Then either hand over from the
    records without a note, or pay the re-send. Decide by size.
- **Risk: medium.** A fresh lead knows only what the note, the board and the records say. A user who comes back after
  an hour finds a lead that has lost the thread of the conversation. That already happens to a lead over 200k through
  Claude Code's compaction, with a summary VibeSwitcher doesn't write. The simulation assumes the fresh lead's context
  grows as the old one's did, which flatters it: a fresh lead re-reads things.
- **Try first**: one week at 150k, then compare the lead's tokens and the user's corrections.

### 2. Wake the lead less often for reports that need no action

- **Saves**: about 0.6M tokens per wake avoided (the lead's 318M tokens over 532 typed-in turns). 353 of those turns
  began with a team event, about 210M tokens a week. What share of them needed the lead at once I can't measure without
  reading the reports.
- **What exists**: `LeadWake` batches the reports that arrive within 5 to 8 seconds into one prompt, and
  `LeadAdvance.wakes` (`Sources/VibeCore/LeadAdvance.swift:311`) already delivers housekeeping lines without waking.
- **What changes**: widen the non-waking kinds (a done report that auto_advance is already auditing, a clean merge), and
  hand them over with the next wake that matters. A process step first: list a week's reports by kind and by whether
  the lead acted.
- **Risk: medium.** A lead told later reacts later. A report misfiled as non-waking stalls a task until the next wake.
- Delivering a held report "just before the cache goes cold" has nothing to act on: no report was held past the TTL,
  and no cold wake began with one.

### 3. Workers across audits: keep releasing, by tokens too

- **Measured**: 110 audits, median 4 minutes, all within 55 minutes. 21 workers were started within 10 minutes after
  their task's audit ended, replacing a released one; in 19 of those the released worker's cache would still have been
  warm.
- **Which is cheaper**: a kept worker would have taken its findings on a warm cache, but carrying a median context of
  227k. Its replacement starts at 57k. The replacements ran a median of 35 requests. So keeping costs about 35 × 170k ≈
  6M more cache-read tokens per fix round, and releasing costs one fresh start (1.2M tokens of first prompts across all
  21, 559k of them written) plus re-reading files. Over the 21, releasing saved on the order of 100M tokens.
- **So**: no change to the rule. Releasing was built for Mac slots and memory (`LeadToolset.releaseWorker`,
  `Sources/VibeCore/LeadToolset.swift:2637`). It is also the cheaper choice: in raw tokens always, and in dollars unless
  the fix takes under about 6 requests (a fresh start's cache write costs what 6 requests' extra reads do). Its cost is
  time: the replacement rediscovers what the first worker knew.
- **One extension**: release a worker that waits on its merge too, once its audit has passed. The 2 cold re-sends
  "waiting on a merge" (265k tokens) were workers kept alive for a merge that took over an hour. Risk: low.

### 4. A cache countdown per session, in the sidebar and the Team panel

- **Saves**: nothing by itself. It lets the user send a message before the hour instead of after. The cold re-sends a
  person could have beaten that way are the lead's typed-in wakes under 2 hours: 5 in the week, 0.7M tokens, est. $9.
- **What changes**: `ChatUsage` (`Sources/VibeCore/ChatTranscript.swift:74`) keeps no time and no bucket today. It
  would keep the last request's time and the bucket last written, which `LeadReceipts.responses` already parses. The
  chip sits beside the context meter in the chat, and on the lead's and the workers' rows.
- **More useful than the clock is the price**: on a cold session, "the next message re-sends 260k tokens". That is the
  one fact the user can't see today.
- **Risk: low.** It will sometimes say cold when the cache is warm (5 of 33 here), and it adds a moving number to rows
  the user reads at a glance.

### 5. A keep-warm request for a session about to go cold

- **Lead**: one request every 55 minutes, for up to 24 of them, avoids 16 of the 27 cold re-sends (the 11 sleeps can't
  be kept warm). It saves 2.2M re-sent tokens and spends 75 requests that read 18.8M. In dollars it gains: est. $34
  saved for $5 spent, because a read costs a fortieth of a write or less.
- **Worker**: 5 avoided, 0.5M saved, 13 requests reading 2.4M.
- **Not recommended.** It spends 8 times more tokens than it saves, and how reads weigh against the plan's limits I
  don't know. Each request is a turn in the session. It would also stop the idle compaction and proposal 1, which save
  far more by letting a large context go. And the table counts only idles that ended in a wake: requests into an idle
  that never ends are pure cost.

### What none of these reach

The 11 lead re-sends after a sleep (1.5M tokens) happen because the Mac sleeps on idle. Only proposal 1's cold case
touches them.

## 4. The cache-clock mod

Read at commit `39e5177f` of `ray-amjad/claude-code-mods`: `plugins/cache-clock`, version 0.5.4, MIT. It is one hooks
module, `hooks/register.js` (275 lines), listed in `hooks/hooks.json` under `modules`.

**What it does.** It draws one line above the prompt: time left on the cache, context used, and a second clock while a
subagent is warm. Every model request restarts the clock. It reads the TTL from the last 300 lines of the session's
transcript (`ephemeral_1h` or `ephemeral_5m`). At 5 minutes left it shows a toast. It saves no tokens: it tells a person
when to type.

**Worth copying into VibeSwitcher:**

- Measure the TTL from the buckets rather than assume it, and look further back when a response only read the cache.
- Two clocks: 1 hour for the main session, 5 minutes for subagents. The measurement confirms both.
- On a resumed session, start the clock from the time since the last response, not from zero.
- Act while the cache is warm, once per idle stretch, and only when no turn is running. That is the idea behind
  proposal 1, done with VibeSwitcher's own handover rather than a prompt of the mod's.
- Its README's pointer to Claude Code's idle compaction, which the transcripts here confirm.
- Its honesty about side requests keeping the cache warm.

**What must not run in a worker, a verifier or a lead:**

- **It submits a prompt by itself.** With the default setting (`onWarning: handoff`), at 5 minutes left, if no turn is
  running and nothing was submitted since the last prompt, it calls `$.prompt.submit` with a request to write a handoff
  note. A worker waiting 55 minutes on its audit or merge would get a turn nobody sent. So would an idle lead, every
  idle hour, and that turn reads its whole context and resets the idle clocks that VibeSwitcher's rotation and Claude
  Code's compaction go by.
- **It writes `HANDOFF-<first 8 of the session id>.md` into `$.session.root()`.** In a worker that is the worktree: an
  untracked file that fails the "nothing modified or untracked" check, or gets committed into the branch and merged. In
  the lead it is the main checkout.
- **Its headless check doesn't cover team sessions.** It stays quiet when `isInteractive` is false (`-p`, the SDK).
  VibeSwitcher's sessions run in a terminal of their own and are interactive.
- It fires even when a draft is typed and not sent (its README says so). VibeSwitcher types its own messages into that
  box.
- The band itself is harmless and useless there: nobody looks at a worker's terminal, and the lead's chat is
  VibeSwitcher's view.

If the user installs it for their own sessions before any allowlist exists, the stopgap is one line in each role's
settings: `CACHE_CLOCK_ON_WARNING=off` in `env`. The band stays, the prompt and the file don't.

## 5. Mods in team sessions

A mod is a plugin with a hooks module: JavaScript that runs inside the session and can draw, register tools, see every
turn and submit prompts.

### What each role inherits today

From `LeadLaunch.prepare` (`Sources/VibeCore/LeadLaunch.swift:574`):

| Role | Started with | So it loads |
| --- | --- | --- |
| Lead | `--settings <its file> --mcp-config <its file>`, no `--setting-sources` | The user's, the project's and the local settings: every enabled plugin, every hook, every MCP server |
| Worker | The same | The same |
| Verifier | The same, plus `--setting-sources user --strict-mcp-config` | The user's settings only: still every enabled plugin and its hooks. No project settings, no MCP servers but VibeSwitcher's |
| Team summaries (headless) | `-p --setting-sources "" --strict-mcp-config` (`Sources/VibeCore/TeamSummaries.swift:210`) | Nothing of the user's |

Checked in the transcripts of the last 3 days (55 workers, 44 verifiers, 1 lead). This is the one place I read more
from a transcript than usage numbers and times: the names of the tools, skill namespaces and hook events each session
was started with, from its listing lines, with a one-off probe that isn't committed. No message text. The lead may
prefer to strike this list; the table above stands on the code alone.

- **Every worker, verifier and lead** lists the skills of superpowers, vercel, claude-hud, codex, brag and
  frontend-design, runs a `SessionStart` hook, and has the savvy-progress tools, which that plugin's hooks module
  registers. The synced plugins (design, productivity, brand-voice, marketing) are in more than half.
- **Workers and the lead** also get the user's MCP servers and connectors: the browser extension, mail, calendar,
  documents, an issue tracker, and 17 servers that plugins bring.
- **Verifiers** get none of those, but do get the browser extension and the savvy-progress tools: `--strict-mcp-config`
  doesn't stop what a hooks module registers.

`claude plugin list` shows 12 plugins enabled (one of them in two versions) and 5 more loaded (4 synced, 1 from the
skills folder). Nothing under `~/.claude` was opened for this.

This worker's own start shows what that means. A `SessionStart` hook told it that it was in a "learning" output style
and should ask the user to write 5 to 10 lines of code at decision points. Another told it that it must invoke a skill
before any response. A worker has no user to ask, and its brief says otherwise. Both came from plugins the user enabled
for their own sessions.

### What the config seal does with plugins

`ConfigSeal` (`Sources/VibeCore/ConfigSeal.swift`) watches each enabled plugin for what of it runs: its manifest, its
`hooks/hooks.json`, its MCP and LSP servers, and the files their commands name.

- An edit made while no team session ran is sealed as the user's.
- One made while the team ran holds new workers, verifiers and merges until the user accepts it.
- A plugin whose version folder moved (an update) always waits for Accept, whoever made it (decision 2026-11-08
  06:33:00), and so does one first seen after the seal began watching plugins.
- The lead's own start is never held, and running sessions keep the hooks they started with.
- It doesn't watch a plugin's skills and commands.

So the seal answers "did this code change without the user seeing?". It doesn't answer "should this plugin run in a
worker at all?": everything enabled runs everywhere.

**A gap, by reading the code (not demonstrated):** the seal follows `command` entries (`ConfigSealCommands.commands`,
`Sources/VibeCore/ConfigSealCommands.swift:23`). A hooks module is listed under `modules`, not as a command. So
`hooks.json` is hashed but the module file it names is not. An edit to a mod's `register.js` inside its version folder
would pass unseen. An update is still caught, because the folder moves. This is the config seal, so it needs its own
audited task.

### What the Code Mode trial found

`docs/experiments/code-mode-trial.md`: Claude Code refused Code Mode because of savvy-progress, "whose JavaScript hooks
may check tool calls". Every worker, verifier and lead would run without Code Mode while that plugin is enabled. The
trial turned it off for its own processes only, with `"enabledPlugins": {"savvy-progress@claude-kit": false}` in each
process's `--settings` file. Nothing under `~/.claude` changed, and `claude plugin list` still showed it enabled. That is
the mechanism the allowlist needs, and it is shown to work for one plugin.

### Proposed rules

| Sessions | Rule |
| --- | --- |
| The user's own sessions (started from the sidebar or a terminal) | Unchanged. They keep every mod, cache-clock included if the user installs it. That is where a person watches the prompt. |
| Lead | An allowlist. Default: plugins with no hooks module and no hooks. Mods off unless the user ticks them. |
| Worker | The same allowlist. |
| Verifier | None by default. It checks a branch, and the fewer instructions injected into it the better. |

How:

- **Per process, through `--settings`.** `LeadLaunch.prepare` already writes each role's settings file. It adds
  `enabledPlugins`, with `false` for every plugin the user's settings enable that isn't on the allowlist.
  `ConfigSeal.plugins(home:enabledIn:)` already lists them. The user's files are never edited.
- **Off by default for anything new.** A plugin installed tomorrow is off in team sessions until ticked. That is the
  point of an allowlist: installing a mod for yourself stops being a change to every worker.
- **Where the user sets it**: Settings › Project lead, one row per enabled plugin, marked "has a hooks module" or "has
  hooks" where `ConfigSeal.pluginParts` finds one.
- **The seal** can then hold the team only for plugins on the allowlist. An update to a plugin no team session loads
  needn't stop workers. It still gets a card, since the user's sessions and the lead's chat run it.

### What breaks either way

**If mods stay on in team sessions (today):**

- A mod that submits prompts or writes files does so in workers and the lead. cache-clock's default does both.
- Instructions meant for a person reach workers and verifiers, as this worker's start shows.
- Code Mode stays off for every role while one mod blocks it.
- Every plugin update holds new workers, verifiers and merges until Accept.
- Each session's first prompt carries every plugin's skill list and tool list. How many of a worker's 57k first-prompt
  tokens that is wasn't measured: it needs one worker started with and one without.

**If team sessions get an allowlist:**

- Workers lose skills the user may want them to have, until ticked: frontend-design for UI tasks, the Swift and
  TypeScript language servers, superpowers' workflows.
- The user's mental model breaks once: "I enabled it, why doesn't the lead have it?" The settings row has to say so.
- Workers and the lead lose the plugin-brought MCP servers. The user's own MCP servers and connectors are a separate
  question (`--strict-mcp-config`, as the verifier has); this proposal leaves them.
- A lead resumed after a restart must get the same list, or its tools change mid-conversation.

**Not yet known, and a 10-minute trial like the Code Mode one would settle it:**

- Whether `enabledPlugins: false` in `--settings` also turns off the synced plugins and the one loaded from the skills
  folder, which `claude plugin list` shows as "loaded", not "enabled".
- Whether turning a plugin off that way also removes the tools its hooks module registered.
- How many first-prompt tokens the allowlist saves per session.

## Found on the way

Each is outside this task's boundaries. None was changed.

- **Advisor calls are never cached and are not on any receipt.** Workers' advisor made 29 calls with 4.9M uncached
  input tokens and no cache read or write: est. $67 at Fable 5.1 rates, more than every cold re-send together. They sit
  in `usage.iterations`, which `LeadReceipts.responses` doesn't read.
- **`claude-fable-5-2` has no price in `LeadPrices.table`**, so receipts with it say "cost unknown".
- **The seal doesn't hash a mod's module file** (section 5).
- **Subagents run on the 5-minute cache**: workers' subagents wrote 12.3M tokens to it and cost est. $137, more than
  twice the cold re-sends of every role.
- **Claude Code compacts idle leads** without VibeSwitcher knowing (section 1).

## Limits

- One week, one project, one user's habits. A week with more overnight batches would show more lead wakes by reports.
- Dollars are API prices. The sessions run on a plan, and I don't know how its limits weigh a cache read against a
  write.
- The lead's handover simulation and the workers' keep-or-release sum are estimates built on measured counts. Each
  proposal says which part is which.
- Usage-limit stops made by VibeSwitcher itself, and the split between the user's typing and the app's notices, are not
  visible in what the script reads.

## Follow-up: the handover built, keep-warm measured and not built (2026-11-18)

Written by the worker of task lead-context-cost-hand. The user asked on 2026-11-18 whether a heartbeat that keeps the
lead's cache fresh makes sense. This uses the same window and prices as section 1: the 7 days to 2026-11-18 11:45, with
Fable 5.2 priced as Fable 5.1. Only usage numbers and timestamps were read. To reproduce:

```sh
python3 -I scripts/cache-cold-cost.py --until "2026-11-18 11:45" --price-as claude-fable-5-2=claude-fable-5-1 --keep-warm
```

`--keep-warm` adds the three tables below to the script's output.

"Work in flight" is what VibeSwitcher itself would go by (`KeepAwake.working`): a worker or verifier working, or the lead
merging. The transcripts can only approximate it, as a worker's or verifier's request in the last 10, 30 or 55 minutes,
or a merge's test run. The loosest reading, any task open on the board, also counts tasks that were only waiting on the
user's answer.

**One difference from section 1.** The Mac's power log (`pmset -g log`) no longer reaches back to the morning of 11-11.
So this run sees less sleep in the first cold wake's gap (11-11 14:08) and calls it typed in, where section 1 called it
a Mac sleep. That leaves 10 sleep-caused cold wakes here instead of 11. Every other number in section 1 stands.

### In short

**Handover: built.** At 150k tokens and 50 idle minutes it would have run 8 times in the week.

- It saves about 81M cache-read tokens. The script's estimate is $27 and 0.5M cache-write tokens, but that overstates it.
  In 5 of the 8 handovers (11-12 08:24, 11-14 07:38, 11-15 07:46, 11-15 11:14, 11-18 03:37), the wake came over an hour
  after the fresh lead started. Its own ~80k cache had expired by then and was written again: 0.4M tokens the
  simulation doesn't charge, about $6 at these prices. So it saves about $21, and the cache writes roughly break even.
  The 81M reads are the saving.
- It spends about $0.43 on the 5 notes the old lead writes while its cache is still warm, reading 1.0M tokens.
- It also pays for 8 fresh starts of about 80k tokens each, 0.64M in all, already netted in the 0.5M.

**Keep-warm: settled, not built (the lead agreed, 2026-11-18).** Sent only while work is in flight, a heartbeat would
have kept 2 of the 27 cold lead wakes warm.

- **Dollars:** it pays 12 to 14 times what it costs. With the handover running it saves $2.34 a week and spends $0.17. Without the
  handover it saves $6.72 and spends $0.54 to $0.71.
- **Tokens:** it loses. Its requests read about 0.6M tokens to save 0.17M, 3 to 4 times more than they save. The plan's
  limits count tokens, and how they weigh a read against a write isn't known (section 2).
- **An injected turn:** each heartbeat is a turn typed into the lead's conversation, which the user reads, and it resets
  the idle that the handover and Claude Code's compaction go by.
- **Upper bound:** counting any open task as work in flight, it would have saved $13.75 for $2.17, reading 8.4M tokens
  to save 1.2M.

At about $2 a week in API dollars, paid for in more tokens than it saves and with a turn in the user's chat, it doesn't
pay.

**What would change the answer:**

- Usage billed in dollars rather than counted against token limits. Then the dollar ratio decides, though the
  sum stays a few dollars a week.
- Many more cold wakes with work in flight, for example overnight batches with workers running past the hour while the
  lead idles. A week with dozens would be worth measuring again with this command.
- A way to refresh the cache that isn't a turn in the conversation.

**Claude Code's idle compaction.** A heartbeat sent after it refreshes only the summary. One sent before it would by
inference stop the compaction and keep the large context. The handover at minute 50 comes before both.

### Break-even: one heartbeat against one cold re-send

A heartbeat reads the context N from the cache, writes its own ~200 tokens to the 1-hour bucket, and gets ~30 tokens back.
A cold re-send writes N to the 1-hour bucket (2× input) instead of reading it. The wake that follows pays the read either
way, so the "extra" column is what keep-warm can save per re-send.

| context | model | one heartbeat (reads it) | one cold re-send (writes it) | of it extra over a warm read | heartbeats per re-send | idle hours of heartbeats |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 100k | claude-fable-5-2 | $0.030 | $2.00 | $1.98 | 65 | 59 h |
| 150k | claude-fable-5-2 | $0.043 | $3.00 | $2.96 | 69 | 63 h |
| 218k | claude-fable-5-2 | $0.060 | $4.36 | $4.31 | 72 | 66 h |
| 300k | claude-fable-5-2 | $0.081 | $6.00 | $5.93 | 74 | 67 h |
| 100k | claude-opus-5-5 | $0.022 | $0.80 | $0.78 | 35 | 32 h |
| 150k | claude-opus-5-5 | $0.032 | $1.20 | $1.17 | 36 | 33 h |
| 218k | claude-opus-5-5 | $0.046 | $1.74 | $1.70 | 37 | 34 h |
| 300k | claude-opus-5-5 | $0.062 | $2.40 | $2.34 | 38 | 34 h |

In dollars a heartbeat costs 1/35 to 1/74 of a re-send, so 32 to 67 idle hours of heartbeats equal one cold re-send. In
tokens the two are equal: a heartbeat reads N tokens, and a re-send writes N.

### Each of the week's 27 cold lead wakes

What the columns mean:

- **Compacted:** Claude Code compacted the lead in the gap.
- **Handed over:** the 150k / 50-minute handover would have run. The context counted is the one left after the
  simulation's earlier handovers.
- **In flight:** whether work was in flight 55 minutes into the idle, when a heartbeat would be sent.
- **Last column:** what keep-warm would have done, with no handover.

| wake | gap | of it asleep | context before | re-sent | cause | compacted in the gap | handed over at 150k | a worker, verifier or merge active (in the last 10 / 30 / 55 min; any task open) | keep-warm while one was active in the last 10 min, no handover |
| --- | ---: | ---: | ---: | ---: | --- | --- | --- | --- | --- |
| 2026-11-11 14:08 | 1.4 h | 2.7% | 106k | 106k | typed in after an idle |  |  | no/no/no/yes | nothing in flight |
| 2026-11-11 15:32 | 1.1 h | 51.0% | 108k | 108k | Mac sleep |  |  | no/no/no/yes | nothing in flight |
| 2026-11-11 18:33 | 3.0 h | 16.3% | 108k | 108k | typed in after an idle |  |  | no/no/no/yes | nothing in flight |
| 2026-11-11 22:29 | 1.8 h | 0.0% | 134k | 134k | typed in after an idle |  |  | no/no/no/yes | nothing in flight |
| 2026-11-12 08:24 | 7.7 h | 0.0% | 175k | 175k | typed in after an idle |  | yes | no/no/no/yes | nothing in flight |
| 2026-11-12 21:26 | 1.7 h | 30.9% | 196k | 196k | typed in after an idle |  | yes | no/no/no/yes | nothing in flight |
| 2026-11-13 00:43 | 3.3 h | 47.5% | 197k | 197k | typed in after an idle |  |  | no/no/no/yes | nothing in flight |
| 2026-11-13 08:51 | 8.1 h | 89.0% | 198k | 198k | Mac sleep |  |  | no/no/no/yes | asleep at the request's time |
| 2026-11-13 10:12 | 1.3 h | 43.0% | 202k | 4k | Mac sleep |  |  | no/no/no/yes | asleep at the request's time |
| 2026-11-13 16:57 | 6.7 h | 8.8% | 205k | 72k | typed in after an idle | yes |  | no/no/no/yes | nothing in flight |
| 2026-11-13 18:30 | 1.5 h | 0.0% | 76k | 76k | typed in after an idle |  |  | no/no/no/yes | nothing in flight |
| 2026-11-14 07:38 | 6.2 h | 20.2% | 233k | 233k | woken by the user's answer to a question |  | yes | no/no/no/yes | nothing in flight |
| 2026-11-14 09:57 | 2.3 h | 4.7% | 238k | 238k | typed in after an idle |  |  | yes/yes/yes/yes | kept warm (2 sent) |
| 2026-11-15 07:46 | 20.6 h | 40.5% | 330k | 321k | typed in after an idle |  | yes | yes/yes/yes/yes | nothing in flight (5 sent) |
| 2026-11-15 11:14 | 2.2 h | 91.9% | 435k | 435k | Mac sleep |  | yes | yes/yes/yes/yes | asleep at the request's time |
| 2026-11-15 19:21 | 5.9 h | 0.0% | 457k | 74k | typed in after an idle | yes |  | no/no/no/yes | nothing in flight |
| 2026-11-16 01:37 | 1.1 h | 92.6% | 223k | 0 | Mac sleep |  | yes | yes/yes/yes/yes | asleep at the request's time |
| 2026-11-16 04:37 | 1.2 h | 99.4% | 230k | 0 | Mac sleep |  |  | yes/yes/yes/yes | asleep at the request's time |
| 2026-11-16 05:38 | 1.0 h | 99.3% | 231k | 0 | Mac sleep |  |  | yes/yes/yes/yes | asleep at the request's time |
| 2026-11-16 13:18 | 1.0 h | 93.7% | 339k | 339k | Mac sleep |  | yes | no/no/no/yes | asleep at the request's time |
| 2026-11-16 16:33 | 2.2 h | 0.0% | 345k | 74k | typed in after an idle | yes |  | no/no/no/yes | nothing in flight |
| 2026-11-16 23:38 | 7.1 h | 0.0% | 76k | 48k | typed in after an idle |  |  | no/no/no/yes | nothing in flight |
| 2026-11-17 07:53 | 5.0 h | 99.0% | 119k | 92k | Mac sleep |  |  | no/no/no/yes | asleep at the request's time |
| 2026-11-17 15:30 | 1.7 h | 0.0% | 218k | 38k | typed in after an idle | yes |  | no/no/no/yes | nothing in flight |
| 2026-11-18 03:37 | 4.1 h | 49.1% | 254k | 0 | typed in after an idle |  | yes | no/no/no/yes | nothing in flight |
| 2026-11-18 07:48 | 3.6 h | 94.0% | 256k | 256k | Mac sleep |  |  | no/no/no/yes | asleep at the request's time |
| 2026-11-18 09:04 | 1.3 h | 0.0% | 260k | 260k | typed in after an idle |  |  | yes/yes/yes/yes | kept warm (1 sent) |

Of the 27 cold wakes: 16 nothing in flight, 9 asleep at the request's time, 2 kept warm.

- **Asleep:** a heartbeat can't be sent from a sleeping Mac, so these can't be helped. They are 9 of the 10
  sleep-caused wakes. The 10th, 11-11 15:32, had no work in flight.
- **Nothing in flight:** the team was idle, mostly waiting on the user. In one of these (11-15 07:46), 5 heartbeats would
  have gone out while work ran. They stopped when the work did, and the wake came cold anyway.
- **Kept warm:** 11-14 09:57 and 11-18 09:04.

The 10-, 30- and 55-minute windows agree on every wake. Only the loosest reading, any task open, says yes for all 27.

### Keep-warm only while work is in flight

| work in flight means | with the handover | at most | cold re-sends avoided | re-sent tokens avoided | requests | tokens they read | est. saved | est. spent |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| a worker, verifier or merge active in the last 10 min | no | 4 | 2 | 497k | 7 | 2.1M | $6.72 | $0.54 |
| a worker, verifier or merge active in the last 10 min | no | 24 | 2 | 497k | 8 | 2.4M | $6.72 | $0.62 |
| a worker, verifier or merge active in the last 10 min | yes | 4 | 2 | 171k | 7 | 575k | $2.34 | $0.17 |
| a worker, verifier or merge active in the last 10 min | yes | 24 | 2 | 171k | 7 | 575k | $2.34 | $0.17 |
| a worker, verifier or merge active in the last 30 min | no | 4 | 2 | 497k | 7 | 2.1M | $6.72 | $0.54 |
| a worker, verifier or merge active in the last 30 min | no | 24 | 2 | 497k | 8 | 2.4M | $6.72 | $0.62 |
| a worker, verifier or merge active in the last 30 min | yes | 4 | 2 | 171k | 7 | 575k | $2.34 | $0.17 |
| a worker, verifier or merge active in the last 30 min | yes | 24 | 2 | 171k | 7 | 575k | $2.34 | $0.17 |
| a worker, verifier or merge active in the last 55 min | no | 4 | 2 | 497k | 7 | 2.1M | $6.72 | $0.54 |
| a worker, verifier or merge active in the last 55 min | no | 24 | 2 | 497k | 9 | 2.7M | $6.72 | $0.71 |
| a worker, verifier or merge active in the last 55 min | yes | 4 | 2 | 171k | 7 | 575k | $2.34 | $0.17 |
| a worker, verifier or merge active in the last 55 min | yes | 24 | 2 | 171k | 8 | 655k | $2.34 | $0.20 |
| any task open on the board | no | 4 | 10 | 1.3M | 40 | 9.0M | $16.54 | $2.23 |
| any task open on the board | no | 24 | 14 | 1.7M | 57 | 13.1M | $21.16 | $3.28 |
| any task open on the board | yes | 4 | 9 | 815k | 39 | 6.0M | $8.28 | $1.53 |
| any task open on the board | yes | 24 | 14 | 1.2M | 55 | 8.4M | $13.75 | $2.17 |

The review's own estimate, $34 saved for $5 spent, let heartbeats run through every idle, with work in flight or not.
Kept to work in flight, keep-warm meets almost no cold wakes. While the team works, its reports wake the lead more often
than hourly (section 1). The long idles are the user's absences, when nothing is in flight. Since keep-warm wasn't built,
the contract's cap N on heartbeats in a row doesn't arise.

### Keep-warm and Claude Code's idle compaction

All 13 compactions in the window were automatic, at 200k tokens or more, and came 50 to 60 minutes after the session's
last response. That matches Claude Code's idle compaction at about 54 minutes. A keep-warm request has to be sent before
the 60-minute TTL, at minute 55 here.

- **After the compaction (minute 54 to 60):** the heartbeat finds the context already compacted to a summary, 38k to 74k
  tokens this week. It keeps only that warm, which saves little: the compaction's own request had just refreshed the cache.
- **Before the compaction:** the heartbeat is a request in the session, so the session isn't idle at minute 54. By
  inference Claude Code then doesn't compact it, and every later request carries the large context. This wasn't tested:
  it needs a real lead, and this task's tests use fake sessions only.

Either way a heartbeat works against the cheaper outcome, which is letting a large context go. The handover at minute 50
comes before both.

Something can hold the handover past minute 54: a question asked in the last 10 minutes, or the 5-minute retry after a
failed attempt. Then the compaction gets there first. The handover sees the `compact_boundary` in the transcript's tail
and leaves that lead alone.

### What was built

- **Settings** in `.vibeswitcher/workflow.md`, also set with `configure`:
  - `handover_idle_min: 50`. 0 is off, and a value under 10 reads as 10.
  - `handover_tokens: 150000`. 0 is off, and a value under 100000 reads as 100000. A fresh lead starts near 80k tokens,
    so a lower threshold would hand it over every idle hour.
  - Settings › Project lead's lead rotation set to never turns the handover off too.
- **The rule** (`LeadRotation.idle`):
  - The lead has been idle past the threshold, counted from the last response in its transcript.
  - Its context then was at least the token threshold.
  - It wasn't compacted after that response.
- **How it runs:** the rule joins the scheduled rotation's reasons and uses its path (`LeadController.rotateIfDue`). The
  lead must be quiet, with no queued report and no typing for 2 minutes. The old lead writes a note. A fresh lead starts
  from the board, `decisions.md`, its last turns and `scheduled-lead-handover.md`. Then the role moves on the board and in
  the vault.
- **Never mid-exchange.** Each of these holds the handover:
  - the lead's turn running, a report queued for it, or its own question dialog open;
  - a question on the board less than 10 minutes old (`LeadRotation.conversationOpen`). This holds the scheduled rotation
    too.
- **When the cache has expired, or will before a note could land** (past minute 55, as after the Mac slept through
  minute 50), the idle handover writes its note itself instead of asking for one. Asking would be the very re-send the handover avoids. The simulation
  charged a note only for the 5 handovers with the Mac awake at minute 50. The scheduled rotations still ask, as before.
- **At most 2 tries per idle.** A note that never comes (a timeout, a failed start) cancels the try. The ask's own reply
  restarts the idle, so the rule would try again 50 minutes later, all night. It gives up after 2 tries
  (`LeadRotation.maxIdleAttempts`) until the user types to the lead again.
- **It hands over ahead of the wake, not at it.** The app's 3-second refresh runs the rule. A wake that comes first
  still goes to the old lead: the user typing, or a report, in the seconds a handover takes once the Mac wakes from a
  sleep past minute 50. In the first 2 minutes after the app starts, no handover runs.
- **The note VibeSwitcher writes itself** can't name what lived only in the old lead's context. The board's timers and
  the last turns with the user still carry over.
- **What it tells:**
  - The chat's line under the fresh lead says when and why: "Started a fresh lead session at 13:32 (the last one had been
    idle 52 minutes with 238k tokens of context, past handover_idle_min 50 and handover_tokens 150k)".
  - The same reason goes in `progress.md`: "Handed the lead over to a fresh session: …". Every handover is logged this
    way, the scheduled ones too.
