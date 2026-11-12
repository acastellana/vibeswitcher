# Review of the VibeSwitcher 2 design (2026-11-12)

Three reviewers who hadn't seen the design read
[it](../../superpowers/specs/2026-11-12-vibeswitcher-2-design.md) (at `537ca1f4`) and the code, one each for
architecture, security and distribution. Nothing was built. These are their findings, condensed; "inferred" marks what
a reviewer didn't verify in the code. The design hasn't been changed for them yet.

## Verdicts

- **Architecture:** the node, client and fleet split and most of the eight rules are sound. The plan underestimates
  how tangled the app's logic is with its views, and treats main as read-only, which makes the branch the main risk.
- **Security:** fine for the owner through stage 4 on repositories they trust. Not against a deliberate worker, and
  not to distribute: the plain mode is guard rails only, the strong mode is undesigned, updates are unsigned.
- **Distribution:** not distributable as designed. Install, update, compatibility and support are undefined. Broad
  Linux distribution is realistic after stage 8 with a Release stage and a support matrix; the Mac not before
  milestone 5.

## Architecture

1. **The branch pays a growing port tax.** In 14 days main's `Sources` changed +47,347/−5,858 lines, with 34 new app
   files and 56 new `VibeCore` files; `LeadToolset.swift` took 81 commits, `LeadController.swift` 35. The lints and
   the `AGENTS.md` line reach main only at landing. Recommended: put the lints, an Ubuntu build job, `Platform/` and
   the file splits on main now, as behaviour-neutral changes the Mac's lead verifies; keep `v2` additive. Give `v2`
   its own `records_dir` (`docs/lead/progress.md` had 733 commits on main in 14 days).
2. **"Move the AppKit lines to `+Mac.swift`" fails on the real files.** Stored properties and default arguments use
   types declared in view files, and neither can move to an extension: `LeadController.swift` 388 (`LeadMailFeed`),
   404 (`KeepAwake`), 603, 653; `ChatModel.swift` 97, 123, 612; `SessionStore.swift` 11, 50-59, 97; `PhoneLeads.swift`
   141, 159. 85 of 130 app files import Apple-only frameworks. The fix is extracting declarations from hot view files,
   which is the non-mechanical change the design forbids.
3. **Control logic blocks on modal UI**: `LeadController.swift` 595, 857, 2026-2080 (`NSAlert.runModal`);
   `PhoneAccess.swift` 1266-1433 (`DispatchQueue.main.sync`). A server can't block on a remote click; these become
   asynchronous question cards.
4. **The models are single-window, polling view models, not a source of deltas.** One `ChatModel` and one
   `WindowModel`, publishing search, scroll and selection; 2 s and 3 s heartbeats; whole-collection `@Published`
   values; `ChatItem`, `Session`, `WindowSection` aren't Codable. Recommended: server-side resource stores keyed by
   id with explicit change events, view state in the client, file-watched board reads.
5. **Rule 4's seam is in the wrong place.** Starting a worker, merging and auditing run in `vibeswitcher-mcp` through
   `LeadToolset.swift` (6,632 lines, 100 `Worktrees.` calls), and roles come from the local host's process tree.
   Milestone 4 rewrites it unless a placement protocol is defined in `VibeCore` now. Vault records should name the
   node that attested them.
6. **A rule is missing: project identity.** Boards are keyed by absolute path; `LeadBoard.swift` stores worktree
   paths and ttys; hook state is `state/<tty>.json`. A project id and a node id; paths become a node's own attribute.
7. **Landing is gated on milestone 5**, the largest and least designed piece. Recommended: land after milestone 2,
   and decide now that the Mac app embeds the node in-process.
8. **Stage 3 ports a throwaway** (`PhoneAccess.swift`, 1,755 lines of `[String: Any]` JSON, replaced in stage 8), and
   the terminal's latency is tested only in stage 6. Recommended: the command line as the first client; the protocol
   and terminal spike right after stage 2.
9. **Stage 5 blocks stages 6 and 7 with six admitted holes.** Design worker sandboxing first.
10. **Cards as data on `v2` only** means every card main adds is built twice until milestone 5. "Platform plugin"
    duplicates `Platform/`.
11. **Not addressed:** sequence epochs and durable action ids across a server restart; schema versions and migration
    (`UserDefaults`: 85 uses in 23 app files); a stale cached web client meeting a newer server; node logs and
    health; delta coalescing for slow clients; type checking for the web client.

## Security

1. **Critical: "only a human" is a bearer token a worker can read or drive** (the browser's storage, on WSL through
   `/mnt/c`; injected clicks, inferred). Require: every approval is a device key's signature over the exact action
   and a host nonce, verified by the host, not the server; user presence (WebAuthn) for pairing, guarded settings,
   Push and wallet.
2. **Critical: a tailnet identity is a machine's, not a person's.** Any process on any of the user's machines reaches
   another node's `tailscale serve` with the owner's login; locally the header is forgeable on the loopback port.
   Require: serve's backend is a Unix socket with a peer check; a separate local listener that ignores those headers;
   workers' network egress can't reach the tailnet, loopback or cloud metadata.
3. **Critical: one script injection in a full-rights window is a shell on every node.** `Web/app.js` today uses only
   `textContent` under a strict CSP; the design specifies neither and adds markdown, diffs, images and served files.
   Require: that CSP with Trusted Types; a lint against HTML sinks; agent files from a separate sandboxed origin; no
   remote images; link schemes allow-listed.
4. **High: relaying through one node makes one node's compromise everyone's.** Require from milestone 1: actions
   carry the device's signature end to end; node principals get a short fixed list of capabilities (offer, run a
   placed task, return one ref, report), never typing, screens or approvals.
5. **High: placement is remote code execution for an injected lead, and remote verdicts are self-issued.** Require:
   placed work always sandboxed; an acceptance policy per node, set locally by a person; worker and verifier on
   different nodes; the placing node fetches one ref and never accepts pushes; upstream credentials stay home.
6. **High: the sandbox as sketched leaks.** Worktrees share the main `.git` (planted hooks and config); verifier and
   code under test share a sandbox; the lead stays unconfined; network and abstract sockets are shared; agents' OAuth
   tokens stay readable. Require: workers get clones and results are fetched; one inherited socket per session as
   its identity, replacing process-tree checks; tests sandboxed apart; the lead confined; an allow-listing egress
   proxy.
7. **High: the person approves text an agent wrote.** Require: cards show facts the host derived (commit, diffstat,
   the command verbatim, the decoded transaction, who asks) in chrome agents can't imitate; no truncation or bidi
   controls; the signature covers what was shown.
8. **High: a browser terminal turns output into input** (emulator replies sent back as keystrokes, OSC 52, OSC 8).
   Require: only the host's parser answers queries; OSC 52 off; links confirmed.
9. **High: updates are a pull of a branch taking about 100 agent commits a day, installed with root.** Require:
   release tags signed by a key agents can't use, verified by a root-owned updater; lockfile enforced; vendored
   JavaScript's hashes checked against upstream.
10. **Medium: rights and sockets.** "Reply" types into a user's shell; `originAllowed(nil)` returns true; "unknown
    kinds are skipped" fails open for revocations. Require: first-frame authentication, rights checked per action,
    revocation closes sockets, a must-understand flag on security messages.
11. **Medium: misconfiguration and secrets at rest.** Refuse non-loopback binds; the handover file holds session
    output; logs get pasted into issues.

## Distribution

1. **There is nothing to install**: clone and compile with Swift 6.4. Recommended: a Release stage; CI builds x86_64
   and aarch64 tarballs with the Swift runtime linked in, a `.deb` and an install script. ARM is never mentioned.
2. **The code assumes an app bundle or a source checkout at run time** (`WebAssets.swift` 38-44, `LeadGateBuild.swift`
   41-55, `TestLock.swift` 122-125, 16 hard-coded `/usr/bin/git` or `/bin/zsh`). A rule: a node runs from its
   binaries alone.
3. **One setup is designed**: Ubuntu, systemd, root, Tailscale, one user. Recommended: a support matrix; the plain
   mode with loopback pairing as a supported path; per environment, what is guaranteed.
4. **Claude Code's and Codex's behaviour is hard-coded** against specific versions in 13 files, with no tested range.
   Recommended: one adapter per CLI that declares its tested versions and is probed at start; outside them, status
   only, with a message; a nightly canary against the latest.
5. **No release engineering**: no versions, tags, changelog, checksums; updates track a branch.
6. **On-disk state is unversioned**: no schema version, migration, downgrade or uninstall. A rule: every file carries
   a format version.
7. **The author's defaults are in shared code**: GenLayer chains, model choices, dated price tables, limits, records
   committed into the user's repository; 46 files mention the wallet.
8. **macOS needs the author's signing ritual.** Milestone 5 needs Developer ID and notarization.
9. **Nothing ships to others until milestone 5.** Recommended: Linux pre-releases from `v2` after stage 8.
10. **First run and support assume the author.** Recommended: `vibeswitcher doctor` and `vibeswitcher report`.
11. **Licence notices and a non-affiliation line are missing.**
