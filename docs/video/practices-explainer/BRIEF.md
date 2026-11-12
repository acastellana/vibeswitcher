---
workflow: general-video
flow: automation
storyboard: no
message: "VibeSwitcher wraps Claude Code sessions in an engineering process (contracts, isolated workers, independent audits, a tested merge gate, incidents turned into checks), so one conversation can run a team you can trust."
destination: youtube
aspect: 1920x1080
language: en
audience: developers who already use Claude Code (or Codex) and drive one or a few sessions by hand
length: about 7 minutes (6:52 narrated; the silent cut was 5:42)
angle: explainer, process walk-through with the project's own numbers
narration: yes (ElevenLabs, see NARRATION.md)
---

## Intent

The user, 2026-11-12, after sharing a Claude Code team talk and a still of rows of sessions moving through
checkpoints: "create a video explaining the software engineering practices that are enabled by vibeswitcher in a
similar way that this video does, with animations and stuff. It can be any style you want and any length you want. I
want it to be thorough, explaining the benefits of this type of programming system versus using Claude itself."

The lead's task contract (an-animated-explainer) set the rest: built autonomously from the contract with no interview,
every VibeSwitcher claim sourced in `sources.md`, Claude Code presented fairly (what the system adds, never a knock),
clarity over flash.

Chosen telling: a switchyard. Each task is a car that runs from its contract, through its own worktree, the audit and
the merge gate, onto the lead's branch. The name VibeSwitcher suggests it, and it differs from the talk's look, where
rows of sessions move through checkpoints. The road not taken was a character-led story about a day of the user's
work. It's more charming but less thorough, and the contract asks for thorough.

## Customizations

- Narrated (user, 2026-11-12: "use elevenlabs for the voices"). An ElevenLabs voice explains each scene, the screen
  keeps the detail, and captions carry every word. Still no music. The script, voice and model are in `NARRATION.md`;
  `tools/voice.py` voices it, and `tools/captions.py` fits the scene lengths, the voice track and the captions to it.
  The silent cut (5:42) had on-screen text only, decided autonomously per the first contract.
- Real numbers count up where they make a point. Each one is listed in `sources.md`.

## Notes

- No logos, trademarks or footage from Anthropic or anyone else. Product names appear as plain text only.
- Don't imitate the talk's exact visuals: no rows-of-sessions-through-checkpoints grid. The design is our own
  (`frame.md`).
- Boundaries: only `docs/video/practices-explainer/`. No global installs.
