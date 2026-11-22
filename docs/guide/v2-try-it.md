# VibeSwitcher 2 on Linux: try it

A walk through everything on v2 as it is today (2026-11-21), for a first real try. Each step says what to run and what
you should see. If something surprises you, report what you ran, what you expected and what happened.

`vs` is `~/.vibeswitcher/v2/builds/current/bin/vibeswitcher`: an alias you write yourself, never a `vibeswitcher` found
on PATH. Anything that acts in your name (starting, sending, answering, setting) shows what it will do and asks you to
type a short code: nothing else on the machine can answer it for you. Reads ask nothing.

## 1. The node

```sh
vs status        # build, host, sessions, leads, open cards, account usage, boost, notices
vs doctor        # what the node needs, each missing piece with the exact command for you to run
vs brief         # what happened lately and what is asked of you, in a few sentences
```

`brief` is written by Claude Haiku while AI summaries are on, otherwise from the boards and logs. It says how many
things wait on you. If the node isn't running: `vs start --interop-is-on`.

## 2. Your own sessions

```sh
vs new ~/projects/app                   # Claude there (--model haiku picks one)
vs new ~/projects/app --agent codex     # your Codex (needs its link, below); --agent shell for a shell
vs presets ~/projects/app               # the launch presets; vs new FOLDER --preset NAME starts one
vs status                               # each session: its terminal (ttypts4), its id, your name for it
```

Name a session by its short id, by the terminal `status` prints (`ttypts4`), or by the name you gave it:

```sh
vs send ttypts4 "explain this repository in five lines"    # typed in as you
vs send ttypts4 "use the new parser" --now                 # steers it mid-turn, at its next step
vs send ttypts4 "what's wrong here?" --image ~/shot.png
vs reply ttypts4 1                      # answers the question on its screen (a permission, a choice)
vs rename ttypts4 "Release notes" ; vs pause "Release notes" --hours 2 ; vs end "Release notes"
vs resume                               # sessions that ended lately; vs resume SESSION reopens one in its conversation
```

Right after `end`, `resume` says the session ended N s ago and is listed in M s (the node waits 30 s first).

Codex runs through a link you make once: `ln -s ~/.bun/bin/codex ~/.local/bin/codex`. Without it, `new --agent codex`
says so and names the link.

## 3. The page

```sh
vs web                  # prints an address with #pair=…: open it within two minutes, in a browser here
```

What to look at:

- **Start page**: what needs you; *Brief me* (with *Speak*, read aloud by the browser); recent projects and sessions
  that ended, each with the line that starts or resumes it.
- **A session**: its live chat (images, tool calls folded, a long message's TL;DR, the lead's all-done card), its
  terminal (watching only), the composer and answer boxes. These leave a **draft** and show the one line to run in a
  terminal: a page never acts for you.
- **Inspector** (⌘⌥0): Overview (branch, pid, command, tokens and cost, the **dev servers** the session listens on),
  Activity, and for a lead's team the **Team** tab: tasks and each task's details, decisions, scorecard, answered
  questions, **results**, between leads, files.
- **Board** (Projects → a project → Board): what's asked of you, what runs, a review waiting on a usage limit, the AI
  summary of what each agent is doing, decisions, the batch that cleared the board and its cost.
- **This node**: host, server, build, account usage, Boost (a bolt beside This node while it's on), **health**,
  between leads, notifications (per kind: something needs me, a session finishes; a sound), **dictation**.
- **Settings**: a search box; every setting with the line that sets it; *Terminal Look* (this browser's own).
- **Statistics** and **Between leads**: ⌘K, then their names.
- **Dictation**: turn it on in This node. Then hold the mic beside a box and speak; it fills the box only. Chrome sends
  your voice to Google to recognise it. Firefox has no speech recognition, so the mic isn't there.

`vs web --revoke` closes every page.

### On your phone, over Tailscale

```sh
vs web --tailnet        # Tailscale up here and on the phone, same tailnet, MagicDNS on
```

It prints `http://<machine>.<tailnet>.ts.net:47830/#pair=…`: open it on the phone within two minutes. The phone reads
and drafts for 8 hours. No terminal, notifications or dictation there: browsers don't count plain HTTP inside
Tailscale's encryption as a secure page. If Tailscale isn't ready, it says what's missing and changes nothing.

## 4. A project lead

```sh
vs lead ~/projects/app --goal "a small real task"
vs board ~/projects/app                  # tasks, waits, decisions, the last batch's summary and cost
vs questions --wait                      # blocks until something needs you
vs answer CARD "your answer"             # or draft it on the page, then: vs answer CARD
vs hold CARD                             # stops a question's timer
vs tell ~/projects/app "a note for the lead, not an answer"
vs push ~/projects/app                   # when the lead asks to push (or: vs decline-push ~/projects/app)
vs mail                                  # what the leads told each other
vs stats week
```

The lead plans tasks, starts workers, has their work audited, and merges through the tests. A change to sensitive
files asks you to approve the exact commit first.

## 5. Settings

```sh
vs settings                              # this node's; vs settings ~/projects/app adds the project's
vs settings --find "team sessions"
vs set node_max_sessions 8               # mac_max_sessions works too
vs set ai_summaries off
vs set ~/projects/app lead_rotation never
```

## 6. Switching builds

```sh
vs status --check-updates   # asks now (else every 6 h): the newer green build on v2 and its install line
vs switch COMMIT        # parks workers idle since their report (named first); refuses at once while one is mid-turn
vs rollback
```

## 7. After a reboot

```sh
vs start --interop-is-on                 # two codes the first time: what plain mode doesn't promise
vs approve                               # every held config, moved base and hooks update shown whole, one code
vs lead FOLDER --resume                  # the lead comes back in its own conversation
vs reopen                                # your own sessions the restart ended
```

`vs approve` lists what a plain accept settles (your home's and each project's held config, each moved base, the hooks
when a build changed them), each as `vs config held` and `vs base show` show it, asks one code and does them in order,
stopping at the first refusal; `--only config,base,hooks` narrows it. Questions, merge approvals and pushes it only
lists: each keeps its own answer. `vs config held FOLDER` and `vs base show FOLDER` still show one at a time.
The seal holds every team until you accept what changed. When Claude Code has updated itself, the card says "this looks
like Claude Code's own update to X". VibeSwitcher can't tell it from a file a session put there, so it asks you.
`DISABLE_AUTOUPDATER=1` in Claude Code's settings stops those holds.

## Known limits, honestly

- **Sessions aren't sandboxed yet.** The sandbox is built, but nothing launches a session in a box (its last slice is
  still to come). Workers run with your rights, under the seal and the voice rule.
- **Approvals on a Mac with Touch ID** aren't on: the Mac node isn't built yet.
- **A page can't act for you.** Typing into a terminal, one-click answers and replies from the phone wait on the web
  listener moving into the host (H1). They also wait on two of your decisions: which sessions a page may type into,
  and what right a page needs (`docs/process/v2-h1-plan.md`).
- **Phone push** and **wallet requests** wait on your decisions (`docs/process/v2-push-decision.md`; the parity
  table's wallet row).
- **Codex** needs its link (above). Codex *workers* stay off until Codex's sandbox is measured.
- **Briefings** are in English and spoken by the browser's own voice (no ElevenLabs on the node).
- Windows interop is on, so the security document's S11 list applies (`vs start` prints it once).
