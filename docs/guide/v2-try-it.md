# VibeSwitcher 2 on Linux: try it

A short walk through the node as it is now, for a first real try. Each step says what you should see. Anything that
surprises you is worth reporting: what you ran, what you expected, what happened.

In every command, `vs` is `~/.vibeswitcher/v2/builds/current/bin/vibeswitcher` (an alias you write yourself, never a
`vibeswitcher` found on PATH). A command that acts in your name asks you to type a short code first: that is the point,
nothing else on the machine can answer it for you.

## 1. The node

```sh
vs status
```

You see the node's build, its host, your sessions, the leads and the open cards. If the node isn't running:
`vs start --interop-is-on` (two codes after a reboot: the first says you read what plain mode doesn't promise).

After a reboot or a restart of the node, the seal shows you what it holds before any team works again:

```sh
vs config held          # what changed since you last accepted, one line each
vs config accept CARD   # the card's id from the line above
```

## 2. The web page

```sh
vs web
```

Open the address it prints within two minutes, in a browser on this machine. You see:

- the sessions on the left, by what needs you;
- a session's live chat, its terminal (watching only), its overview;
- a project's board (Projects → the project → Board): what's asked of you, what needs attention, what runs, what's done;
- notifications, if you allow them (the page asks once).

The page never acts for you: it drafts, and shows the one line to run.

### On your phone, over Tailscale

```sh
vs web --tailnet
```

With Tailscale running on this machine and the phone, on the same tailnet, and MagicDNS on: it prints
`http://<this machine>.<tailnet>.ts.net:47830/#pair=…`. Open it on the phone within two minutes. The phone's access
lasts 8 hours; `vs web --revoke` ends every page, here and on the phone. No terminal there, and no notifications (the
page is plain HTTP inside Tailscale's encryption, which browsers don't count as secure). If Tailscale isn't installed,
isn't running, or MagicDNS is off, it says so: nothing is installed or changed. `vs status` shows where it listens.

## 3. A session of your own

```sh
vs new ~/projects/some-project            # a Claude session there
vs status                                 # its id
vs send SESSION "explain this repository in five lines"
```

Watch it answer on the page. If it asks you something (a permission, a question), the page shows the question with
the line that answers it:

```sh
vs reply SESSION 1
vs end SESSION
```

## 4. A project lead

```sh
vs lead ~/projects/some-project --goal "a small real task"
vs board ~/projects/some-project
vs questions --wait                        # blocks until something needs you
vs answer CARD "your answer"               # or leave a draft on the page, then: vs answer CARD
vs tell ~/projects/some-project "a note to the lead that answers no question"
```

The lead plans tasks, starts workers, has their work audited by two reviewers and merges through the tests.
Changes to sensitive files ask for your approval of the exact commit first.

## 5. After a reboot

```sh
vs start --interop-is-on
vs config held ; vs config accept CARD     # for your home, then for the project (vs config held FOLDER)
vs base show FOLDER ; vs base accept CARD
vs lead FOLDER --resume                    # the lead comes back in its own conversation
```

## Known limits today

- Approvals on a Mac aren't built yet (they will use Touch ID).
- No settings screen yet (being built): some limits are still edited in `.vibeswitcher/workflow.md`.
- `send` doesn't take `/` commands, `@` files or images yet; `new` has no launch presets yet (being built).
- The sandbox's first slice is still being finished: sessions don't run boxed yet.
- Windows interop is on, so the security document's S11 list applies (`vs start` prints it once).
