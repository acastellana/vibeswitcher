# VibeSwitcher 2 on Linux: try it

A walk through everything on v2 as it is today (2026-11-23), for a first real try. Each step says what to run and what
you should see. If something surprises you, report what you ran, what you expected and what happened.

`vs` is `~/.vibeswitcher/v2/builds/current/bin/vibeswitcher`: an alias you write yourself, never a `vibeswitcher` found
on PATH. Anything that acts in your name (starting, sending, answering, setting) shows what it will do and asks you to
type a short code: nothing else on the machine can answer it for you. Reads ask nothing. If the server restarts while
it acts, the command asks again and says whether it was done, or that its outcome isn't known; it never does it twice.

## 1. The node

```sh
vs status        # build, host, sessions, leads, open cards, account usage, boost, notices
vs doctor        # what the node needs, each missing piece with the exact command for you to run
vs brief         # what happened lately and what is asked of you, in a few sentences
vs status --health   # freezes, slow refreshes, restarts, refused connections, watches the system couldn't give
vs logs --lines 50   # the server's and host's log; --sessions: each session started and how it ended
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

What to look at (the page was redesigned around the lead on 2026-11-23; it opens on the project that most waits on
you):

- **Left**: your projects, each with a ring of its tasks and one line (`2 need you`, `4 in motion`, `quiet`); New
  project; Your own sessions, This node, Settings. The line at the bottom says what needs you; click it for *Brief
  me* (with *Speak*).
- **Centre, Lead**: only what passes between you and the lead: its questions with your answers, its results, and
  with the dial at *Everything* its decisions. Click a line for its whole text in a side sheet. What waits on you is
  at the bottom: pick an option or write your own words; that leaves a **draft** and shows the one line to run in a
  terminal (a page never acts for you yet). The box under it drafts a note for the lead as a `vs tell` line.
- **Centre, Roadmap**: the tasks in motion, the blocked ones and whom they wait on, the queue as one band. No dates
  yet: they come with the workers' estimates.
- **Right**: *Team* (each task with five steps; click one to open it in place, with a link to its worker's chat),
  *Stats* (the scorecard), *Files* (the lead's files and the project's place).
- **Your own sessions**: the sessions outside any project, each opening the session view: its live chat, its
  terminal (watching only), the composer, and the inspector (Overview with the **dev servers**, Activity). Starting
  a session and the ones that ended lately are there too.
- **This node**: host, server, build, account usage, Boost (a bolt by the name while it's on), **health**, plugins,
  notifications, **dictation**. Statistics and Between leads are linked from it and from ⌘K.
- **Settings**: a search box; every setting with the line that sets it; *Terminal Look* (this browser's own).
- **Dictation**: turn it on in This node. Then hold the mic beside a box and speak; it fills the box only. Chrome sends
  your voice to Google to recognise it. Firefox has no speech recognition, so the mic isn't there.
- The page's own words follow your browser's language (English or Spanish); the address says what is on screen, so a
  link opens the same view and back and forward walk it.

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
stopping at the first refusal; `--only config,base,hooks` narrows it. What needs your own decision it lists first with
its command, never in the batch: questions, merge approvals and pushes, a project's first accept or changed guard rails
(`vs config held FOLDER`), a base it can't vouch for (`vs base show FOLDER`), the hooks beside a config accept.
The seal holds every team until you accept what changed. When Claude Code has updated itself, the card says "this looks
like Claude Code's own update to X". VibeSwitcher can't tell it from a file a session put there, so it asks you.
`DISABLE_AUTOUPDATER=1` in Claude Code's settings stops those holds.

## 8. Plugins: the wallet

Optional features are plugins: `vs plugin list` shows each, on or off, what it adds and why one can't run;
`vs plugin off NAME` and `on NAME` take a code. Shell requests are built in and on. The wallet is an external
plugin in a repository of its own, `vibeswitcher-wallet` (a local repository at `~/projects/vibeswitcher-wallet`; its
README is the full guide). Build it, add it, turn it on, and name your chains (none is built in):

```sh
cd ~/projects/vibeswitcher-wallet && bash scripts/build.sh
vs plugin add ~/projects/vibeswitcher-wallet     # check the program's SHA-256 against the build's, type the code
vs plugin on wallet
vs set wallet_chains "42424242, GenLayer, https://scan.chain.genlayer.com, GEN, https://rpc.chain.genlayer.com; 4221, GenLayer Testnet, https://scan.testnet-chain.genlayer.com, GEN, https://rpc.testnet-chain.genlayer.com"
```

An agent then asks with `vs-wallet request --from 0x… --chain 4221 --to 0x… --amount … --reason "…"`. Its card shows the
chain and the decoded call as the wallet plugin's words, and the transaction whole. `vs answer CARD sign` prints a
one-time page address in your terminal (nothing opens a browser): open it in the browser that has your wallet, and
confirm or reject in the wallet's popup. `vs answer CARD decline` declines. A rebuild changes the program's SHA-256, so
the node holds the plugin until you `vs plugin remove wallet` and add it again.

## Known limits, honestly

- **Sessions aren't sandboxed yet.** The sandbox is built, but nothing launches a session in a box (its last slice is
  still to come). Workers run with your rights, under the seal and the voice rule.
- **Approvals on a Mac with Touch ID** aren't on: the Mac node isn't built yet.
- **A page can't act for you.** Typing into a terminal, one-click answers and replies from the phone wait on the web
  listener moving into the host (H1). They also wait on two of your decisions: which sessions a page may type into,
  and what right a page needs (`docs/process/v2-h1-plan.md`). H1 is built, and you answered both on 2026-11-25
  (every session, with a key each device makes at pairing, checked on each message); that isn't built yet.
- **Phone push** waits on your decision (`docs/process/v2-push-decision.md`). You answered it on 2026-11-25 (push
  over HTTPS through `tailscale serve`); it isn't built yet. **Wallet requests** are the external
  wallet plugin (section 8): signed in your browser wallet only; the Mac's Wallet Manager path isn't on Linux.
- **Codex** needs its link (above). Codex *workers* stay off until Codex's sandbox is measured.
- **Briefings** are in English and spoken by the browser's own voice (no ElevenLabs on the node).
- Windows interop is on, so the security document's S11 list applies (`vs start` prints it once).
