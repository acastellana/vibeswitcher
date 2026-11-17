# Narration

The voiceover for the practices explainer, scene by scene. It's written to be heard: short sentences that give the
idea behind each scene, while the screen carries the detail (names, fields, thresholds). Every claim is one that
`sources.md` backs; numbers are the ones on screen.

**Voice:** George (`JBFqnCBsd6RMkjVDRZzb`), an ElevenLabs premade voice. **Model:** `eleven_v4`, through
`POST /v1/text-to-speech/{voice_id}/with-timestamps` (`output_format=mp3_44100_128`).

Why George: the project's ElevenLabs key may only call text-to-speech, so the account's voices couldn't be listed
(`GET /v1/voices` answers 401, `voices_read` missing), and the voice wasn't picked from a listing. George is the voice
ElevenLabs' own quickstart uses with `eleven_v4` (its voice-description pages weren't reachable). On the opening sample
he reads at a measured pace, about 130 words a minute, with every word clear in transcription, which suits a technical
walk-through. Whether the voice is as warm as wanted is for a human ear to judge. ElevenLabs' model guide recommends `eleven_v4` (or `eleven_multilingual_v2`) for video narration.

**Characters used:** the first cut (2026-11-12): the 19 scene files held 5,218 characters, and 6,661 were spent: 6,338
voicing scenes (s04, s08, s15 and s16 were voiced twice, after a review tightened their wording to the sources) and 323
on a probe, the opening sample and a speed test. The update of 2026-11-17 spent **1,854** more: s07 (354) and s15
(445), re-voiced because their text changed, and the new s20 (362), s21 (403) and s22 (290). No other scene was
re-voiced. A second update the same day spent **988** more: s17 (423) and s22 (565), re-voiced to add the config seal's
skill-sync exception and the update check, once both had merged. That's 9,503 characters in all; the 22 scene files
now hold 6,891. The account's quota couldn't be read
(`GET /v1/user/subscription` needs `user_read`), and no call was refused. **Voice length:** 8:21 of speech in an 8:58
film at its natural pace. The model ignores `voice_settings.speed` (1.0, 1.1 and 1.2 gave the same length), so the
voice keeps its natural pace, about 130 words a minute, and the delivered MP4 is the whole film sped up 1.7× with the
pitch kept (4:59.6; see `STORYBOARD.md`).

The update's new and changed scenes were transcribed with whisper (`small.en`): "Fable", "Opus", "Codex", "UI
journeys", "178 megabytes" and "/model" come through as written, and "macOS 27.2" as "Mac OS 27.2".

The second update's s17 and s22 were transcribed the same way (whisper-cpp, `small.en`): "skill sync", "Claude Code's
own", "by its shape", "every other change still waits for your click", "every six hours", "GitHub", "this Mac's main",
"Install and restart", "signing password", "never stores it" and "merges it in and tests the result" come through as
written, and "VibeSwitcher" as "vibe switcher". (A first pass without timestamps skipped the Install and Restart
sentence; transcribed with timestamps, and on its own, it's all there.)

The opening was sampled first and transcribed with whisper (`small.en` and `base.en`): "VibeSwitcher", "worktree" and
"Codex" come through as written.

`tools/voice.py` reads each scene's text below (the lines starting with `>`), asks for one audio file per scene and
keeps the character timings that the captions are built from: `assets/voice/sNN.mp3` and `assets/voice/sNN.json`.
`tools/captions.py` turns those timings into `compositions/captions.html` and sets each scene's length to fit its
voice.

## s01 · Title

> One conversation, running a whole engineering team. This is how VibeSwitcher builds a working process around Claude
> Code sessions.

## s02 · The starting point

> Claude Code already gives you a lot: subagents, worktrees, hooks, permission rules, memory, even control from your
> phone. But run a few sessions by hand, and you become the process. You write every brief, keep the sessions apart,
> read every diff, and decide when it's tested enough. VibeSwitcher turns that process into software.

## s03 · One conversation

> You talk to one session: the lead, one per repository. It plans the work, starts the workers, judges what comes
> back, and merges it. It never edits code itself. Workers, Claude or Codex, take one task each, and a read-only
> verifier checks them. You're asked only what's yours to decide: direction, taste, and anything you can't undo.

## s04 · The contract

> Every task starts as a contract: what must be true when it's done, how the worker has to show it, and where it may
> make changes. The worker gets it word for word, with your working policy. And its hash is recorded with the merge.

## s05 · Isolated, in parallel

> Workers run side by side, each in its own worktree and branch, so no two agents share a checkout. Up to three at a
> time, or seven with Boost. Claude Code's own permission rules stop a worker from pushing, or touching the lead's
> branch. To catch up, it merges the base in.

## s06 · Owned through completion

> A worker owns its task to the end. It marks its milestones, asks the lead only about direction, scope or risk, and
> proves new tests under load. When it says it's done, it brings evidence for every check, or the report is refused.

## s07 · Who gets audited

> Not every change needs an audit. By default, the merge's full test run is the check, and a small task, done in under
> thirty minutes and touching nothing sensitive, merges on its tests too. But sensitive paths, risky changes and a
> random ten percent sample are always raised to an audit, and nothing can lower that. So far, 271 of 495 merges were
> audited.

## s08 · An independent verifier

> The audit is independent. A read-only verifier works from the contract, not the worker's story, and runs real
> commands to try to break the change, on a different model by default. An audit can also use two or three finders,
> sharing one build. Then a finding stays open when most of them raised it.

## s09 · Findings, rounds, re-rolls

> An Important finding blocks the merge until it's fixed, or dismissed with a reason. A nit never blocks. Each fix
> gets a round that checks only those findings. After two failed rounds, there's no third: the lead re-plans, asks
> you, or re-rolls the task with a fresh worker.

## s10 · The merge gate

> Then comes the merge gate. It takes exactly the commit that was checked, rebases it where no agent is working, runs
> the full suite, and only then fast-forwards. Never a merge commit, and never forced, so any merge can be undone with
> one revert.

## s11 · When tests misbehave

> Tests misbehave, so the gate plans for it. A failing test gets one more run, and if it passes, it's recorded as a
> flake. A run that goes silent is stopped, and the last test it started is named. 495 merges, every one tested at the
> gate. Zero reverts.

## s20 · Merges keep flowing

> Merges got faster, too. A merge's test run takes whatever cores are free, and only the failing tests run again. A
> test that's red on main as well doesn't send the branch back: it merges, and a task to fix that test is filed. And
> when finished work stops landing, the lead is told why: main is red, the slots are full, or the Mac is loaded,
> asleep, or on battery.

## s12 · It moves on its own

> Between steps, the board moves on its own. A done report starts the audit or the merge, findings go back to the
> worker, and the next task in line begins. It never moves a task the lead is holding. And you choose the merge
> policy.

## s13 · Incidents become checks

> When something goes wrong, it becomes a check. In November, hung test runs held a shared test slot for up to an
> hour, five times in two days. That became a rule: a run with no output, and next to no CPU, for ten minutes, is
> stopped. All 21 incidents on record became check tasks.

## s21 · The app checks itself

> The app is held to the same standard. UI journeys drive the real app in a sandbox, and compare each screenshot with
> its baseline. A health watcher groups the app's own freezes and errors by cause, and proposes a task when one keeps
> coming back. And memory is measured: on macOS 27.2, freed memory now goes back at once, and an image-heavy chat adds
> 178 megabytes at its peak, down from about a gigabyte.

## s14 · A shared Mac, a finite account

> The Mac is shared, and the account is finite, so both are budgeted. Each task has a budget of working time. When it
> runs out, nothing is killed: the worker commits what works, and proposes what's next. A witness tells the lead when
> a session goes quiet. Heavy jobs take turns in shared slots, and new work holds off on low battery, or near a usage
> limit.

## s15 · The right model for each role

> Each role gets a model that suits it. Fable leads, advises on hard tasks, takes re-rolls, and audits anything
> sensitive. In this project, Opus does the work and the routine audits. Codex takes bounded, mechanical tasks: with
> agent set to auto, it's picked when Claude's limits run tight, and a Claude verifier always audits its work. And when
> Fable reaches its usage limit, workers and audits move to Opus on their own, and go back at the reset.

## s16 · Memory that lives in the repo

> The project's memory lives in the repository: decisions with their reasons, progress, and incidents. The tool server
> commits them, and workers can't edit them. A new lead reads them first. And every merge records its task, its
> review, its models, and its contract.

## s17 · You keep the keys

> And you keep the keys. You set the review floor, the sensitive paths and the merge policy, and an approval covers
> one exact commit. Pushes, installs and wallet requests come to you as cards. A seal guards the configuration: a
> finished round of Claude Code's own skill sync is let through by its shape, and every other change still waits for
> your click. And your phone can follow along, with replies behind their own switch.

## s22 · Day to day

> Day to day, it looks after you as well. After a Mac restart, one card offers to reopen the sessions you had open,
> leads first, and nothing reopens until you click. The chat's model chip follows /model the moment you switch. A Run
> card tells the session that asked how its command ended. And every six hours, the app checks GitHub and this Mac's
> main for a newer VibeSwitcher, and says what changed in plain words. Install and Restart asks for the signing
> password each time, and never stores it. If GitHub is ahead, the lead first merges it in and tests the result.

## s18 · What the system adds

> So what does this add to Claude Code by hand? Planning becomes contracts on a board. Parallel work gets a worktree
> per task. Review gets an independent verifier, merging gets a gate, and mistakes become checks. The Mac's load and
> limits are watched, and memory lives in git. And you're asked only what's yours to decide. Underneath, it's the same
> Claude Code. Its permission rules, hooks and status line are how VibeSwitcher works.

## s19 · Proof

> In under four weeks on this repository, 495 tasks merged, every one tested at the gate. 82 Important findings fixed
> before merge. Zero reverts. You decide what to build. The system runs the process.
