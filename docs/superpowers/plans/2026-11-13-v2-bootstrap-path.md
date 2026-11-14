# VibeSwitcher 2: the path to the bootstrap

The order of work from where `v2` stands (2026-11-13, `47636aaf`) to the bootstrap, across stages 1 to 4, with what
each step proves. It is a map, not a task plan: each step points at the plan that holds its tasks, and the one piece
that had no plan, the lead engine, was outlined here and now has [its own](2026-11-13-v2-engine.md).

## Decisions awaiting the user

Asked once, in one message, at the start, so later work never stops to ask. Every plan is written on the
recommendations; the answers go into the design's Decided section before stage 2's Task 2, and an answer other than
the recommendation changes the tasks it names first. **This is the only list**: the security document, the stage 2
plan, the engine plan and the design point here. Those documents cite a decision by a fixed tag ("decision 2"); the
tag is in brackets after each title ([D2]); the numbers 1 to 11 are only the order of importance. A gated test
waiting on one of these is an open item, not a stop.

### Trade-offs to accept

1. **The app on Linux, and what stays open until the sandbox** [D1]. *Recommended:* the app is the host's own server
   child, reached through a socket it inherited (S2); and you accept the security document's S11 list of what a worker
   that tries can still do (restart the host into files it edited, act as any session by ptrace, the lead and
   verifiers included, drive your own shell or Claude Code) while the node runs only VibeSwitcher's own repository and
   WSL interop is off. *Costs:* until the sandbox and stage 4's signed approvals, verdicts, merges and your
   command-line answers are guard rails, not locks. *Otherwise:* another principal rewrites stage 2's Tasks 4b2, 5a and
   8a first; "no Linux app before signed approvals" moves the bootstrap after stage 4.
2. **Nothing one step from root during the bootstrap** [D2]. *Recommended:* WSL interop and automount off (M5), no
   `sudo` in this distribution while a team runs, Docker's daemon kept off. *Costs:* no Windows programs and no
   `/mnt/c` from Linux meanwhile (links don't open in the Windows browser; files cross through `\\wsl$`).
   *Otherwise:* any Linux process becomes root through `wsl.exe`, so every lock is void; `start` refuses unless told
   `--interop-is-on`, and `status` says so. With automount kept on, the seal watches `.wslconfig` and the Startup
   folder, as a detector only.
3. **The vault lives in memory only** [D3]. *Recommended:* yes. *Costs:* any host restart (a crash, an OOM kill, WSL
   stopping, a worker killing it) ends every team's state, and before a lead starts again you run, reading what each
   shows, `config held`, `config accept CARD`, `base show FOLDER [--from COMMIT]` and `base accept CARD` (M9).
   *Otherwise:* a key file now, which any worker can read and so forge the vault with (stage 2's 4c and 10e change).
4. **How the node starts, and what team sessions run with** [D17; D12's second half]. *Recommended:* `vibeswitcher
   start` writes a systemd user unit (step 8), started, not enabled at login, `Restart=no`, `KillMode=control-group`,
   the listed `UnsetEnvironment=`, and the PATH root's folders, then your swiftly and node `bin` folders. `claude` is
   not on it: each lead and role runs the file `~/.local/bin/claude` resolves to at its start. *Costs:* a host exit for
   any reason ends every session, and a killed host stays down until you `start` it; the swiftly and node folders are
   yours, so a worker can replace the compiler or node that team sessions and the merge gate's tests run (the seal
   watches them; S11 item 10). *Otherwise:* without those folders workers can't build and `scripts/test.sh` can't run;
   `Restart=on-failure` restarts the host into whatever a worker left in the unit; without systemd the user's-voice
   rule is the weaker one, and `status` says so.
5. **The review floor for the bootstrap clone** [D13]. *Recommended:* `audit_finders: 2` with verifiers on a model
   other than the workers', `merge_policy: ask_sensitive`, and `sensitive_paths`: `.github/**`, `scripts/ci/**`,
   `scripts/install-node.sh`, `scripts/test.sh`, `scripts/lib/**`, `Package.swift`, `Package.resolved`,
   `Sources/VibeHost/**`, `Sources/VibePlatform/**`, `Sources/CVibePlatform/**`, `Sources/VibeCore/**`,
   `Sources/VibeNode/**`, `Sources/vibeswitcher-*/**`, `Tests/SecurityAudit/**`, `Tests/**/*LintTests.swift` and
   `docs/superpowers/specs/2026-11-13-v2-security-architecture.md`. *Costs:* nearly every merge waits for your
   approval. *Otherwise* (the narrow list: `.github/**`, `scripts/ci/**`, `scripts/install-node.sh`, `Package.swift`,
   `Package.resolved`, `Sources/VibeHost/**`, `Sources/VibePlatform/**`, the security document): most merges go
   through unasked, and a worker can change what "tests green" means for its own merge (a merge runs the branch's own
   `scripts/test.sh`) or the code that checks your voice.
6. **The GitHub credential** [D11]. *Recommended:* the `gh` token git uses replaced by a fine-grained one that only
   reads this repository (or `gh` logged out and a credential typed at each push), and rulesets on `main`, `v2` and
   tags requiring a pull request, with you as a bypass actor (M2). *Costs:* you push `v2` yourself. *Otherwise:* any
   session can push to any of your repositories, VibeSwitcher's `main` included.
7. **Deny rules in the Claude Code that supervises the bootstrap** [D14]. *Recommended:* it is denied every
   `vibeswitcher` subcommand that changes state (`start`, `stop`, `lead`, `answer`, `hold`, `config accept`, `base
   accept`, `base keep`, `hooks install`, `hooks remove`, `switch`, `rollback`, `status --ack`) and edits under
   `~/.vibeswitcher/v2` (M6); it may still run `status`, `questions`, `config held` and `base show`. *Costs:* you type
   those yourself. *Otherwise:* text a worker planted can make your own Claude Code send "your" answer; the typed code
   is then the only rail.
8. **What an install builds with** [D12]. *Recommended:* a Swift toolchain owned by root, outside `$HOME` (M3), used
   only by `scripts/install-node.sh`, with the static standard library, a fresh package cache and a clean worktree of
   a commit both CI runners passed. *Costs:* one root install of Swift, kept at swiftly's version. *Otherwise:* a
   worker that patches your toolchain or package cache gets its code into the next installed build, and `build-info`
   vouches for it.
9. **The project allow-list** [D10]. *Recommended:* `~/.vibeswitcher/v2/projects`, one line you write naming the
   bootstrap clone (M8), removed when you mark stage 6 passed. *Costs:* the node starts sessions in no other
   repository until then. It is a guard rail: a worker can add a line, forge a worktree pair or run a scratch host
   with no list. *Otherwise:* another place changes stage 2's Task 10d; with no list, S11 isn't acceptable before
   stage 6.
10. **Agent sockets and WSLg during the bootstrap** [D9]. *Recommended:* the gpg-agent's ssh socket off, or no key
    cached (M8), and WSLg off (M5). *Costs:* no ssh keys through the agent and no Linux windows on the desktop
    meanwhile. *Otherwise:* any session uses your cached ssh keys and gpg signing by a fixed socket path, and can open
    a window on the Windows desktop styled as anything (S11 items 16 and 19).
11. **Deferrals and small rules, accepted as a block.** *Recommended:* yes to all; any one can be answered apart.
    1. [D5] The handover goes through sealed memory and writes no file. *Costs:* none. *Otherwise:* the state file
       comes back with its hash check (stage 2's 9c).
    2. [D6] No switch of builds while a worker or verifier runs, until stage 2's Task 3b measurement passes here.
       *Costs:* you switch between tasks, not during them.
    3. [D4] No subreaper before the bootstrap; an escaped process is refused by the cgroup rule instead. *Otherwise:*
       every `waitpid` in the host must first tolerate adopted children (stage 2's 4b1).
    4. [D7] Sessions identified by an inherited socket come with the sandbox. *Costs:* until then a session can be
       passed as by pid reuse, which ptrace already allows.
    5. [D8] Clones for workers come after the bootstrap. *Costs:* a worker can move the lead's base through the shared
       `.git`; the vault's head record and `base show` catch it.
    6. [D18, new] The tool server's keeper restarting it from a sealed copy comes with the sandbox (stage 2's Task
       11b): built now it breaks five uses of the tool server's own path, and it stops nothing while a worker can
       ptrace the tool server. *Costs:* a file written over a running tool server's binary is what its keeper
       restarts; the seal watches the install folder. *Otherwise:* 11b is built before the bootstrap, with those five
       sites fixed.
    7. [D19, new] No GitGuard hash check of the lead's hooks copy before the bootstrap: its record sits beside the
       copy, and a worker rewrites both. *Costs:* a planted hook runs as the lead's until the seal's next look, which
       watches that folder. *Otherwise:* the accepted hashes move into the vault and stage 2's Task 10c checks them
       before each run.
    8. [D20, new] The security document's S12 gains items 14 to 16: the two above, and three of the design's
       requirements no list carried (reply rights type only into confined sessions, view rights get masked screens,
       the wallet's signing page on an origin of its own). *Costs:* none before stages 3 and 4, where they exist.
    9. [D15] Codex workers off (`VIBESWITCHER_CODEX_WORKERS=0` in the lead's session) until Codex's sandbox is
       measured on this kernel. *Costs:* Claude workers only.
    10. [D16] Real-agent tests run only with `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR` on each gated run's command line
        (M1), never in a startup file. *Costs:* you type it per run; until then those tests are skipped and work
        goes on.

### Things only you can do on the machine

An agent can't do these (they are yours by the rules above, or need your Windows side or your hands). Run the
command line by its absolute path or an alias you write, never a `vibeswitcher` found on PATH, which a worker could
place first (that defeats PATH only: the binary is still your file, S11 item 15); below, `vs` is
`~/.vibeswitcher/v2/builds/current/bin/vibeswitcher`.

- **M1. Now** (stage 1's R10, stage 2's 12a and 12b, the engine's E9): a Claude Code config folder for the gated
  tests, not your `~/.claude`: `CLAUDE_CONFIG_DIR=~/.vibeswitcher-test-claude claude`, log in, `/exit`. Each gated run:
  `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR=~/.vibeswitcher-test-claude bash scripts/test.sh --filter <suite>` [D16].
- **M2. Before the bootstrap:** on github.com, a fine-grained token that reads this repository only, then
  `gh auth login --with-token < token.txt` and remove the file (or `gh auth logout`); rulesets on `main`, `v2` and tags
  requiring a pull request, with you as bypass [D11].
- **M3. Before step 8's first install:** Swift 6.4.2 owned by root, from swift.org's Ubuntu 24.04 x86_64 tarball with
  its signature checked: `sudo mkdir -p /opt/swift-6.4.2 && sudo tar -xzf swift-6.4.2-RELEASE-ubuntu24.04.tar.gz -C
  /opt/swift-6.4.2 --strip-components=1`; tell the agent the path [D12].
- **M4. During the engine's E1, before its voice rule** (E1 Step 1): give the agent the output of `cat
  /proc/self/cgroup` in a new Windows Terminal tab; the same run by the Bash tool of a `claude` started in that tab;
  `systemd-run --user --wait --pipe cat /proc/self/cgroup`; and `logger -t vibeswitcher-probe hello; journalctl --user
  -t vibeswitcher-probe -n 1 --no-pager` (whether your journal lists your own entries).
- **M5. Before step 8's `start`** [D2, D9]: `sudo nano /etc/wsl.conf` and add `[interop]` with `enabled=false` and
  `appendWindowsPath=false`, and `[automount]` with `enabled=false`; in `C:\Users\<you>\.wslconfig` (from Windows),
  `guiApplications=false` under `[wsl2]`; then `wsl --shutdown` in PowerShell and reopen. No `sudo` here while a team
  runs (or `Defaults timestamp_timeout=0` with `sudo visudo -f /etc/sudoers.d/timeout`).
- **M6. Before step 8's `start`** [D14]: in the supervising Claude Code's `~/.claude/settings.json`,
  `permissions.deny` gains, for each subcommand trade-off 7 lists and in both spellings, a rule such as
  `"Bash(vibeswitcher answer:*)"` and `"Bash(/home/<you>/.vibeswitcher/v2/builds/current/bin/vibeswitcher answer:*)"`,
  and `"Edit(~/.vibeswitcher/v2/**)"`, `"Write(~/.vibeswitcher/v2/**)"`.
- **M7. Step 8, on the real node:** `vs start` (read S11's list, type the code: your acknowledgment); `vs hooks
  install`; the WSL measurement (note `vs status`'s host start time, close every Windows Terminal and WSL window for
  10 minutes, reopen one, `vs status` again: the same start time and the agent's test session still live mean WSL keeps
  the node up; if not, keep a terminal open during the bootstrap or set up a Windows-side keep-alive yourself); then
  `vs switch COMMIT` (a commit the agent installed), `vs status`, `vs rollback`.
- **M8. Step 10, before the lead's first start** [D9, D10, D13]: `systemctl --user disable --now
  gpg-agent-ssh.socket` (or `gpgconf --kill gpg-agent` before each team start); `printf '%s\n'
  "$HOME/projects/vibeswitcher-v2-lead" > ~/.vibeswitcher/v2/projects`; read the floor lines of the clone's
  `.vibeswitcher/workflow.md` [D13]; then `vs config held ~/projects/vibeswitcher-v2-lead`, `vs config accept
  CARD`, `vs base show ~/projects/vibeswitcher-v2-lead`, `vs base accept CARD`, `vs lead
  ~/projects/vibeswitcher-v2-lead --goal "…"`.
- **M9. After every host restart** [D3]: `vs status` (how the host ended; `vs status --ack` once read), then M8's
  `config held`, `config accept`, `base show` (`--from COMMIT` when you know the last good head) and `base accept`,
  then `vs lead` again.
- **M10. While a lead runs:** `vs questions`, `vs answer CARD "…"`, `vs hold CARD`.

**The bootstrap** (the design's, unchanged): from an installed build, a lead on this machine plans a real version 2
task, a worker builds it, it is audited, and it merges into `v2` through the gate with the tests green. From then on
the lead builds the rest of version 2, supervised from Claude Code.

**Sources:** the design (`docs/superpowers/specs/2026-11-12-vibeswitcher-2-design.md`, The bootstrap), the stage 1
plan's [remaining work](2026-11-12-v2-stage-1-core-on-linux.md#remaining-work-revised-2026-11-13), the
[stage 2 plan](2026-11-13-v2-stage-2-session-host.md), the
[security architecture document](../specs/2026-11-13-v2-security-architecture.md) (its sections S1 to S12 and its
decisions are named below as S1, S2, … and "decision 1", "decision 2", …, the tags D1, D2, … of the list above),
and the port map
(`docs/process/v2-port-map.md`). Code references are at `47636aaf`.

**Revised 2026-11-13** to take the security document's changes for this path (its
[Changes](../specs/2026-11-13-v2-security-architecture.md#changes-the-stage-2-plan-needs), "for the other plans'
authors"): step 8 (the unit, the install, the seal's list, the rule on switches, the server image on a switch), the
engine outline (E1, E4, E6, E8) and the questions. **Consolidated 2026-11-13** after two readers compared the five
documents: the questions and decisions of all of them are the one list above; how `claude` is found, the scratch
command line's check, `stop`'s fallback, the switch's request and step 9's owner are settled here, and the other
documents were corrected to match.

## What runs on a lead's path

| Piece | What it does for a lead | Where it stands |
| --- | --- | --- |
| `vibeswitcher-host` | PTYs, parsers, the vault (roles, seals, approvals), spawning, screens and input | doesn't build on Linux (142 errors); stage 2 |
| `vibeswitcher-mcp` | every lead tool: workers, worktrees, audits, `auto_advance`, the merge gate | builds on Linux; needs a host for its role |
| `vibeswitcher-hook` | hook state files, the steer inbox's hand-over | builds on Linux; not yet run with a real agent here |
| the lead engine | starts and wakes leads, delivers reports and answers, watches for stalls, holds | doesn't exist; the app's `LeadController` imports AppKit and Combine and can't be edited on `v2` |
| `vibeswitcher` (built as `vibeswitcher-cli`) | the user's voice: start, status, lead, questions, answers, accepts | doesn't exist |
| the install step | an installed, statically linked build of a pushed commit, never the working copy | doesn't exist |

The engine is the largest piece and the likeliest to slip, so it gets a plan of its own ([below](#the-engine)).

## Who starts the node and keeps it running

On the Mac the app starts the host and the host outlives the app. On Linux there is no app, so `vibeswitcher start`
does it, and the node has to outlive the terminal it was started from.

What this machine has (read, not changed): `/etc/wsl.conf` sets `systemd=true`; pid 1 is systemd; the user's own
`systemd --user` runs (pid 284) and lingering is on for the user (`/var/lib/systemd/linger/albert`), so the user's
manager runs without a login session; `~/.config/systemd/user` has no units. `claude` is in `~/.local/bin`, which the
interactive shell's PATH has and a user unit's default PATH doesn't. The Windows side's `.wslconfig` sets
`networkingMode=mirrored` and no idle timeout. WSL interop is on and `/mnt/c` is mounted (S1): until the user turns
them off (decision 2), every lock the node has is a guard rail.

**`vibeswitcher start`** (the security document's S9 and decision 17; the user confirms):

- Before anything, it checks what is one step from root (S1): with WSL interop on it refuses, saying why, unless the
  user passes `--interop-is-on`; it reports automount and a `kernel=` line in `.wslconfig`. It compares the manager's
  environment (`/usr/bin/systemctl --user show-environment`) with the expected set and names anything extra. The first
  time, it prints the document's S11 (what plain mode doesn't promise) and records the user's acknowledgment.
- Where the user's systemd answers (`$XDG_RUNTIME_DIR/systemd/private` exists), it writes
  `$XDG_CONFIG_HOME/systemd/user/vibeswitcher-node.service` (`~/.config` when unset):
  - `ExecStart=<prefix>/<commit>/bin/vibeswitcher-host --node --node-root <prefix>/<commit> --server
    <prefix>/<commit>/bin/vibeswitcher-server` (the commit's folder, never `current`, so a moved link changes
    nothing until the user switches);
  - `Restart=no`;
  - `KillMode=control-group`, stated, with its consequence said to the user: when the host exits for any reason (a
    crash, an OOM kill, an idle exit, a failed fallback, `stop`), every session, the server and every process left in
    the unit's cgroup end with it, as the vault's loss already ends every team; and `TimeoutStopSec=`;
  - `UnsetEnvironment=LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH GCONV_PATH BASH_ENV ENV VIBESWITCHER_HOME CFFIXED_USER_HOME`
    and `Environment=SWIFT_BACKTRACE=enable=no`, so `systemctl --user set-environment` can't reach the host's start.
    `SWIFT_BACKTRACE` is **not** in `UnsetEnvironment=`: systemd applies that line last, after `Environment=`, and a
    bare name there removes the unit's own assignment too (`systemd.exec(5)`); the unit's `Environment=` already
    overrides the manager's value. (The security document's S9 listed it in both; corrected.)
  - `Environment=HOME=…` and `Environment="PATH=/usr/local/bin:/usr/bin:/bin:<swiftly's bin>:<node's bin>"`, quoted,
    with no `/mnt/` folder. Team sessions get this PATH and no startup file (stage 2's S2-D12), so it must hold what
    workers build and test with: the user's Swift toolchain (`~/.local/share/swiftly/bin`) and node (`~/.nvm/…/bin`,
    which `scripts/test.sh` needs, `test.sh:28-29`). Both are folders the user, and so every worker, can write: they
    are named in the unit, put on the seal's list (below) and in S11 (decision 12). The host itself runs nothing found
    on PATH (its git is `Platform.Tools.git`, its `systemctl` absolute, its binaries static). `claude` is not found on
    PATH either: `~/.local/bin/claude` links to `~/.local/share/claude/versions/2.1.322`, a folder of files named by
    version and none named `claude`, so the engine launches the absolute path it resolves from that link at each
    lead's or role's start (the engine's E4), and an update of Claude Code changes nothing in the unit;

  then runs `/usr/bin/systemctl` by its absolute path (never one found on PATH): `--user daemon-reload`, `--user start
  vibeswitcher-node`. It is started, not enabled: nothing starts by itself after a reboot unless the user asks with
  `start --at-login`. A switch to another build (step 8) rewrites `ExecStart`.
- **Why `Restart=no`** (S2): a worker of the same user can kill the host, and with `on-failure` systemd would start it
  again from whatever the unit, its drop-ins, `~/.config/environment.d` and the install folder then name, with an
  empty vault (S7). With `no`, a killed host stays down until the user's `vibeswitcher start`. This doesn't stop a
  worker that runs `systemctl --user` itself, which works from any session (S10 doesn't keep it out). So the host
  writes its starts, the server's restarts and how it ended to stderr, which the unit sends to the user journal; the
  command line reads `journalctl --user -u vibeswitcher-node` and `/usr/bin/systemctl --user show -p
  Result,ExecMainStatus,ExecMainStartTimestamp` itself and shows every start, stop and server restart that no
  `vibeswitcher start` or `stop` explains, and how the previous host ended, until the user acknowledges them
  (`status --ack`). What the server says about itself is no mitigation once the server is seized; the journal is.
- Where there is no user systemd (a container, WSL without systemd), it starts the host in a session of its own
  (`setsid`, a double fork, its output to the host log) and records its pid; `stop` ends it. There is no cgroup to
  tell the user's voice by, so the server uses S3's weaker rule, and `status` says so.
- Before either, it checks that `claude` resolves to an executable file, that the PATH it will give finds `swift` and
  `node`, and that there is a `git` in a folder owned by root and writable by nobody else (`Platform.Tools.git`, stage
  2's Task 10c), and refuses, saying which is missing, when one isn't.
- **How it is tested** without touching the user's systemd: `StartCommandTests` set `XDG_CONFIG_HOME` to a scratch
  folder and give the start command a recording stand-in for `systemctl` (the command type takes the path it runs;
  the installed command line always passes `/usr/bin/systemctl`, and no environment variable changes it), and check
  the unit written (`Restart=no`, `KillMode`, `UnsetEnvironment`, the PATH, `--node`, `--node-root`, the commit's
  folder) and the calls made; `noNameIsBothUnsetAndAssigned` reads the unit and fails if a name in
  `UnsetEnvironment=` is also set by `Environment=`. The host writes its `SWIFT_BACKTRACE` to the journal at its start
  (its environment can't be read once it is non-dumpable), which step 8's switch check reads. The no-systemd path
  takes **the host command it runs as a parameter** of the start command type (the installed command line always
  gives `<prefix>/<commit>/bin/vibeswitcher-host --node …`); the test gives a scratch host with `--lock` and no
  `--node`, in a scratch home with `XDG_RUNTIME_DIR` pointing at an empty folder, and checks the host runs in its own
  session and `stop` ends it. That the real path carries `--node` is asserted from the arguments the command builds,
  not by starting it: a `--node` host takes the account's real `~/.vibeswitcher` (stage 2's Task 9b). Nothing in a
  test reaches the real `$XDG_RUNTIME_DIR`, the user's journal or the user's home.
- The unit file, its folder, `environment.d` and the install folder are on the config seal's Linux list (step 8). That
  is a detector at points in time: a worker that edits the unit and then restarts the host starts a fresh vault, and
  with stage 2's extended first look (Task 10e) that vault holds every watched file, the guarded settings, the
  checkout's hooks and the floor until the user's `config held` and `config accept CARD`, which show each with its
  change time, size, hash and value, so the edit is shown to the user, not "caught".
- A host restart loses the vault (S7): `lead` is refused until the user has run `config held`, `config accept CARD`,
  `base show FOLDER [--from COMMIT]` (the commits from the head named, else from the last accepted snapshot's head,
  marked unverified: the vault no longer knows it) and `base accept CARD` (M9), and the engine's restart path (E8)
  says what that costs.

**Whether WSL keeps it running with no terminal open is not known.** WSL may stop the distribution once the last
Windows terminal into it closes, whatever runs inside. It is measured in step 8: start the node, close every WSL
terminal for 10 minutes, reopen, and check that the host's start time is unchanged and a session is still live; the
result goes into `docs/process/v2-linux-inventory.md`. Closing every Windows terminal is the user's step (an agent
runs inside one), so it is [M7](#things-only-you-can-do-on-the-machine): the agent prepares the check and reads the
result, the user closes and reopens. If WSL stops it, the user decides how to keep it up (a terminal left open
during the bootstrap needs nothing changed; a Windows-side keep-alive is the user's to set up, never an agent's).

## The steps

Each ends in something that runs.

1. **Stage 1 closed** (stage 1 plan, remaining work: R1 to R3, R5, R7, R8a, R8b, R9, R10, R12; the failures by cause
   A to P are covered by the core-test fixes (2026-11-13)).
   - **Proves:** the core, the hook and the tool server run on Linux; the tool server answers MCP with no host; a real
     Claude Code session is seen going from working to needs-you to done (once the user's config folder exists).
   - **Also proves:** `VibeCoreTests` green on Linux, which the merge gate's `test_command` needs; every job green on
     one commit, as stage 1's R3 defines green.
2. **The user's answers, asked once** ([above](#decisions-awaiting-the-user)), in parallel with step 1. Nothing later
   stops to ask; a gated test waits as an open item.
3. **The security document reviewed and answered** (stage 2, Task 1), before any of the host is ported: its review
   record written, the stage 2 plan and this path holding its changes, the user's answers to the decisions above
   recorded in the design's Decided section, its lint passing.
4. **The host on Linux** (stage 2, Tasks 2 to 10e).
   - **Proves:** `VibeHostTests` and the host audit green on Ubuntu; terminal names match the hook's (`ttypts<N>`), and
     a session's terminal is its own from the start; each message's sender checked; the app is only what the host
     makes through its live server child's connector, never a connection by path; host, parsers, server, probe and a
     handover's new image non-dumpable from their exec (sealed copies, measured); every descriptor close-on-exec from
     its creation; nothing run from a file changed after the host loaded it; a handover writes no file and a fallback
     keeps the vault; a parser types only replies; sessions get no agent sockets and run no shell startup file; the
     project allow-list holds; a fresh vault holds every record's first look.
5. **The lead's tool server under a host** (stage 2, Task 11a; the keeper's sealed copy, Task 11b, is moved after
   the bootstrap, decision 18).
   - **Proves:** with a lead's role bound, `tools/list` has `start_worker`, `audit`, `merge` and `status`, and a call is
     served. (Moved from stage 1: with no host the tool server has no role and lists nothing.)
6. **A real Claude under the host** (stage 2, Tasks 12a and 12b; gated, doesn't hold up step 7).
   - **Proves:** PTYs, parsers and handover hold with the real agent, on Sonnet; what Claude Code's Bash tool sources
     and whether a verifier's command in its own session still times out are measured.
7. **The engine** (its own plan, [`2026-11-13-v2-engine.md`](2026-11-13-v2-engine.md), written from
   [the outline below](#the-engine); where they differ, the plan is right). Its
   [Order](2026-11-13-v2-engine.md#order) table is the schedule; in short: E0 after stage 2's 4b2 and 5a (it adds
   `VibeHost` and `vibeswitcher-host` to `VibeNodeTests`' dependencies, a `Package.swift` row in the port map, and
   `NodeTestHost`, since stage 2's `TestHost` lives in `VibeHostTests`); E2 beside stage 2's 6a to 8b; E3 after 6a; E1
   after 10c (and 3a, 7, 8a, 8b, 9b); E4 after 11a (and 10a, 10b, 10d, 10e).
   - **Proves:** under a scratch host, a lead started from the command line on a scratch repository plans, asks a
     question, and is answered from the command line by the user's voice only; an audit can't hang on a prompt; the
     lead hears every report.
8. **Start, install and the seal.**
   - `vibeswitcher start | stop` as [above](#who-starts-the-node-and-keeps-it-running). `stop` goes through the
     server (the engine's EN-D6); when no server answers, the command line runs `/usr/bin/systemctl --user stop
     vibeswitcher-node` itself (without systemd, it ends the recorded pid), after the same typed code. The app's host
     lifecycle tests are ported here, against `start`, `stop` and the switch: `HostClientReapTests` (the no-systemd
     `stop`), `HostClientPlanTests`, `HostClientSlowStartTests`, `HostClientSlowProbeTests`, `HostClientHandoverTests`
     (the cases the engine's E2 didn't take), `HostRestartTests` (its two cases), as the port map lists them.
   - **The install**, `scripts/install-node.sh COMMIT` (S9, decision 12):
     - it refuses a dirty working tree, and builds from a clean, detached `git worktree add` of a commit on `origin/v2`
       that both CI runners passed (checked through GitHub's API before it builds);
     - with a Swift toolchain the user installed outside `$HOME` (root's, for example under `/opt`; decision 12), a
       fresh package cache, and `--static-swift-stdlib` (Foundation included), so nothing an installed binary runs
       loads from `~/.local/share/swiftly` or any folder the user can write; it checks each built binary with `ldd`
       and refuses one that loads a library from a folder the user can write
       (`InstallTests.anInstalledBinaryLoadsNothingFromAFolderTheUserCanWrite`, which also reads `/proc/<pid>/maps` of
     the installed host, server and a parser);
     - a release build of `vibeswitcher-host`, `vibeswitcher-server`, `vibeswitcher-cli` (installed as
       `vibeswitcher`), `vibeswitcher-hook` and `vibeswitcher-mcp` into `<prefix>/<commit>/bin`, with
       `Resources/bin/vs-*` in `<prefix>/<commit>/Resources/bin` (where `TestLock.commandFolder` looks: two folders up
       from the resolved executable, then `Resources/bin`) and the install script itself in
       `<prefix>/<commit>/Resources/install-node.sh`;
     - a `build-info` in the format stage 2's Task 9b fixes: the commit, each binary's SHA-256, `swift --version` and
       `Package.resolved`'s hash; the host's start check and the handover-target check read it;
     - `<prefix>/current` pointing at it. `<prefix>` is `~/.vibeswitcher/v2/builds`;
     - the next install runs the previously installed build's copy of the script, not the working copy's;
     - `InstallTests.anInstallFromADirtyTreeIsRefused`.

     The command the user runs is `<prefix>/current/bin/vibeswitcher`; nothing is put on PATH, and the user runs
     answers and accepts by that absolute path (or an alias the user writes), so a `vibeswitcher` a worker placed
     earlier on PATH isn't the one that runs. That defeats PATH only: the binary itself is the user's file (S3, S11
     item 15), which the seal watches.
   - `ServerBuild` reads `build-info` on Linux (`LeadGateBuild.swift:41-55` reads only an app bundle's `Info.plist`;
     a non-seam edit, logged), so merge receipts name the build.
   - `vibeswitcher hooks install`, now through the server, which writes as the app and so seals the change
     (`vault.appWrite`), as the app's `HookSetup` does. Because it seals, it takes only the user's voice, typed (S3):
     `aSessionsProcessCannotInstallHooks`.
   - **The config seal's Linux list.** `ConfigSeal.homeFiles` (`ConfigSeal.swift:306-315`) has the Mac's files only
     (the shell startup files `.bashrc`, `.bash_profile`, `.profile` among them). A platform answer, empty on the
     Mac, adds what Claude Code's Bash tool reads here (Task 12b's additions, approved by the lead 2026-11-14):
     `~/.bash_login` beside the Mac's three, all four watched whether they exist or not, what they source (here
     `~/.local/share/swiftly/env.sh`), `~/bin` (absent here, first on the snapshot's PATH once made) and the agents'
     `shell-snapshots` folders; and `~/.config/systemd/user`, `~/.config/environment.d`, `~/.config/autostart`,
     `~/.vibeswitcher/v2/projects`, `~/.vibeswitcher/v2/builds`, `~/.vibeswitcher/lead/run` (the roles' launch
     folders, a detector now that their settings are inline), `~/.vibeswitcher/lead/git-hooks` (the lead's accepted
     hooks copy and its `accepted.json`: with GitGuard's check after the bootstrap, decision 19, the only check on
     them), `~/.local/bin` (on the interactive PATH, though not first on it here, so a `vibeswitcher` or `git`
     placed there could still shadow a later one), the Claude Code install (`~/.local/share/claude/versions`), the
     toolchain's `usr/bin`, every other folder on the unit's PATH that the user can write (`~/.local/share/swiftly/bin`
     and node's `bin`, which team sessions build and test with), and, while `/mnt/c` is
     mounted, `.wslconfig` and the Windows Startup folder. One hook line in `ConfigSeal` (logged), and a test that a
     write to each is held. Until the sandbox this is the one check on what an unconfined worker changes there: a
     detector at points in time (a change swapped in and restored between two looks is missed), reset to "held until
     accepted" by a host restart (S7). The user's crontab lives in `/var/spool/cron`, which the seal's file reads
     can't reach (only `crontab -l` shows it), so it stays on S11's list (item 23).
   - **Running tool servers keep their build across a switch** (S9, said plainly). A tool server runs from
     `<prefix>/<commit>/bin/vibeswitcher-mcp` and its `BinaryWatch` watches that path (`vibeswitcher-mcp/main.swift:474`).
     An install writes another commit's folder, so the watched file never changes and a running tool server never
     switches; the only thing that would set it off is someone writing over the old commit's file, which the seal
     watches. So in the user's node a tool server keeps its build until its session restarts, and only tool servers
     started after the switch (whose MCP config names the new `<node-root>`, the engine's E4) report the new commit:
     `aRunningToolServerKeepsItsBuildAcrossASwitch`, `aToolServerStartedAfterASwitchIsTheNewBuilds`. (These replace
     the document's earlier `aToolServerSwitchesOnlyToTheBuildTheUserSwitchedTo`, a rule that would never fire; S9
     now says so.)
   - **A switch and a rollback**: `vibeswitcher switch COMMIT` (an installed commit) and `vibeswitcher rollback` (the
     commit installed before the current one). The command line asks the server with **`build.switch`** (`commit`;
     the user's voice, its own typed code, recorded in the vault like the engine's E6 requests, and a row of the
     engine's request table). The server checks the rule below, then asks the host to hand over; once the handover
     succeeded, the command line rewrites the unit's `ExecStart` to the new commit's folder and runs `daemon-reload`.
     The host hands over to the new build's host with the new build's `--node-root` and `--server` in its arguments,
     never the old one's (stage 2's S2-D7), its sealed copy checked against the new `build-info` as stage 2's Task 9d
     says; the new build's `vibeswitcher-server`, checked the same way, travels with the handover and the server is
     restarted from it once idle. Check that the host, the server and a tool server started after the switch all
     report the new commit, and that the journal shows `SWIFT_BACKTRACE=enable=no` at the new host's start; rollback
     restores all three.
   - **The rule on switches** (S8, decision 6): until stage 2's Task 3b measurement has passed on this machine, the
     server refuses `build.switch` while a worker or verifier session is live, saying so; the lead may stay:
     `aSwitchWhileAWorkerRunsIsRefused`.
   - The WSL measurement above, with the user ([M7](#things-only-you-can-do-on-the-machine)).
   - **Proves:** the lead runs from an installed, statically linked build of a pushed commit, never the working copy.
9. **A full scratch run on Sonnet** (a harness through `scripts/test.sh`, gated like the real-agent tests, on a
   scratch host with its own `VIBESWITCHER_HOME` and lock, so the user's host and its allow-list aren't involved).
   - **The command line's checks in scratch form** (the engine's EN-D8). Under E1's rules the command line refuses a
     server that isn't a child of the node unit's `MainPID`, and a state change with no word typed on a controlling
     terminal; a scratch host run by a harness has neither a unit nor a terminal. With `VIBESWITCHER_HOME` set to a
     folder other than the account's own `~/.vibeswitcher` (by `getpwuid`), the command line checks instead that the
     server is a child of the process holding `<root>/scratch-host.lock` (`Platform.Processes.lockHolder`); with it
     set to the account's own, it checks the user's node. The harness answers under a pty from `script` (installed
     here), typing the code, so the typed-word rule is exercised, not skipped. The cgroup rule uses the scratch scopes
     the scratch host passes through `--server-arg`.
   - **Owner:** a task of this path, written once step 8 and the engine's E9 are done:
     `Tests/VibeNodeTests/ScratchRunTests.swift`, `aScratchTeamPlansBuildsAuditsAndMerges` on the engine's
     `ScratchNode`, gated like E9's Step 2 (M1), recorded in `docs/process/v2-linux-inventory.md`. Done when it passed
     once here.
   - **Proves:** two workers in worktrees, one audit, one merge through the gate with tests green, one question
     answered from the command line: the design's stage 4 Done-when, on a scratch repository.
10. **The bootstrap.**
    - **Before:** the user's steps M2, M3, M5, M6 and M8
      ([above](#things-only-you-can-do-on-the-machine)). `vibeswitcher start` checks interop; the rest are the
      user's, and `status` names what it can see of them.
    - **Setup:** install from a `v2` commit both runners passed. The lead runs on its own clone
      (`~/projects/vibeswitcher-v2-lead`), base branch `v2`, so Claude Code's commits in the working copy don't move
      the lead's base under it; commits move between the two on purpose, and each move is accepted as a base move.
      The clone's `.vibeswitcher/workflow.md` (not in git): `base_branch: v2`, `records_dir: docs/lead-v2`, a
      `test_command` scoped to what passes on Linux (run with the unit's PATH, which holds swiftly's and node's
      folders: step 8; the command names no folder of its own), no remote. The user sets the review floor as the app would
      (decision 13): `audit_finders` 2 with verifiers on a model other than the workers', `merge_policy:
      ask_sensitive`, and `sensitive_paths` covering `.github/**`, `scripts/ci/**`, `scripts/install-node.sh`,
      `scripts/test.sh` and `scripts/lib/**` (a branch's merge tests run that branch's own `scripts/test.sh`, so a
      worker could change what "tests green" means for its own merge), `Package.swift`, `Package.resolved`,
      `Sources/VibeHost/**`, `Sources/VibePlatform/**`, `Sources/CVibePlatform/**`, `Sources/VibeCore/**` (the vault,
      `ConfigSeal`, `GitGuard`, `BranchCode`, `LeadLaunch`'s deny rules, `HostConnection`), `Sources/VibeNode/**` (the
      user's-voice rule, the cards, answers at rest), `Sources/vibeswitcher-*/**`, `Tests/SecurityAudit/**`, every
      `Tests/**/*LintTests.swift`, and the security document (decision 13).
      The user writes the clone's path as the one line of `~/.vibeswitcher/v2/projects` (decision 10), and takes the
      floor and the clone's first look with M8's accepts. The lead starts with Codex workers off (decision 15).
    - **Proves:** the design's bootstrap Done-when.

## The engine

The node's lead engine, in `VibeNode`, rebuilt from the app's code (which `v2` may not edit) and run in
`vibeswitcher-server`, the host's server child. It reaches the host through `VibeCore`'s calls (`HostCall`,
`LeadVault.standard`), each a new connection, which `HostConnection` makes through the connector the server inherits
(registered for the host's socket path, never falling back to the path); the host takes each as the app because it
made it for its server child (S2, stage 2's S2-D1). Each app file it replaces has a row in
`docs/process/v2-port-map.md`.

Rules for the port:

- Rebuilt, not moved: plain Swift, no AppKit, no Combine; a small change-stream type stands in for `@Published`.
  Pure helpers may be copied, each with a port-map line.
- What the app asks in a modal dialog becomes a command-line flag or a card the user answers from the command line.
- The app's tests are the engine's spec: their cases are ported into `VibeNodeTests` and run on Linux.
- The engine refreshes every 3 s, as the app's `Heartbeat` does. That breaks the design's "a store learns of changes
  from events, never from a timer"; stage 3's stores replace it after the bootstrap, and the design records the
  exception.
- `vibeswitcher-server` is started as `--host-connector N --host-socket PATH` and either `--node --node-root PATH`
  or `--root PATH --node-root PATH` (stage 2's Task 8a; a scratch host adds its `--server-arg`s). It refuses a
  `--host-socket` other than `<root>/host.sock` (the engine's EN-D3). Its first statements, and their order, are the
  engine plan's E1 (close the inherited image, harden, exit if traced, mark the connector close-on-exec, settle
  SIGPIPE; then its root, the socket check, git, and only then the connector's registration). Its install folder
  (`vibeswitcher-mcp`, the command folder) is `--node-root`, never its own image, which is a memfd.
- The server never execs and never connects to the host by path (stage 2's `ServerLintTests.theServerNeverExecs`
  covers `Sources/vibeswitcher-server` and `Sources/VibeNode`). Every descriptor it makes is close-on-exec from its
  creation, and every spawn names `keep` (stage 2's `CloseOnExecLintTests`).
- Nothing secret in its arguments or environment; nothing it writes to stderr (the journal, readable by the `adm`
  group) carries an answer's text, a goal or screen content: ids and hashes only.

The parts, in order. Line ranges are in `Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift` unless named.

| # | Part | Rebuilt from | Ends in | Tests ported or new |
| --- | --- | --- | --- | --- |
| E1 | `vibeswitcher-server`, its socket, and the command line's check of it | new | The server runs as the host's child through its connector, and asks `hostNotes` on each refresh. Its socket is a 0600 Unix socket in a 0700 folder under `~/.vibeswitcher/v2/`, the peer's uid checked at accept and **each request's sender checked** as the host checks its messages (S5; a different sender closes the connection); it checks its own socket's inode as the host does (stage 2's Task 8b). A small versioned request/reply protocol (a format number, a request id, a kind; an unknown kind answered, not fatal; a must-understand kind closes), the seed of stage 3's. Every request kind is listed with the voice it needs (S3's table; anything unlisted refused). **The user's voice** (S3): a peer of the user's uid whose cgroup is outside `user@<uid>.service` and the node's unit (the scopes measured here recorded and accepted only), whose ancestry has no session program, parser, server or host, whose terminal is no session's, whose environment has no `VIBESWITCHER_SESSION`, not under a `BranchCode` runner; any field that can't be read counts against it; without a user systemd, the weaker four lines, said by `status`. **A state-changing request asks for the user's hands**: the command line shows what it will do and asks for a word typed on its controlling terminal, refusing with no terminal. Each accepted user's-voice request goes to the journal (ids and hashes only) and is shown by `status` with its pid, cgroup and command line. **The command line checks the server it reached**: the listener (`SO_PEERCRED` on the client's end) non-dumpable, in the node's unit's cgroup (read from `/proc`), a child of the unit's `MainPID` (read with `/usr/bin/systemctl`). `vibeswitcher start`, `stop` and `status` go through it; `status --ack` and `start`'s acknowledgment of S11 are journal entries the command line writes (the engine's EN-D15); `start` refuses with interop on unless `--interop-is-on`, prints S11 once with an acknowledgment, and compares the manager's environment; `status` has a standing plain-mode line, interop, automount and `kernel=` reports, and the starts the journal shows that no `start` explains | `theServerIsNotDumpable`, `anUnknownRequestIsAnsweredNotFatal`, `statusThroughTheServerListsWhatTheProbeLists`, `aSessionsProcessCannotStopTheNode`, `anUnlistedRequestIsRefused`, `anAcceptedRequestIsShownByStatus`, `aRequestFromAnotherSenderOnTheServersSocketIsRefused`, `theServersSocketIsTheUsersAlone`, `theCommandLineRefusesAServerThatIsntTheHostsChild`, `theCommandLineRefusesADumpableListener`, `anAnswerFromTheNodesCgroupIsRefused`, `anAnswerFromATransientUserUnitIsRefused`, `aPeerWhoseCgroupCantBeReadIsNotTheUser`, `aPeerWhoseEnvironmentCantBeReadIsNotTheUser`, `aStateChangeWithNoTerminalIsRefused`; `StartCommandTests.startRefusesWhileInteropIsOnUnlessTold`; `NodeFactsTests.statusSaysPlainModeAndInterop` |
| E2 | `HostLink` | `HostClient.swift`: connecting, the welcome and events (152-518), requests and spawning (656-761), input units (1046-1177), screens, history, kill and remove (1214-1252) | The engine's one view of the host: sessions as they change, spawn, input units, screens | the cases of `HostClientReplyTimerTests`, `HostClientReapTests`, `InputUnitDeliveryTests` |
| E3 | `NodeSessions` | `SessionStore.swift`: refresh and apply (202-264, 298-452), details (481-503), the state folder's watch (504-523); built on stage 1's `LocalSessions` and `HostLink` | One session list with statuses, the agent's quitting, background jobs | the cases of `SessionStoreTests` that aren't about Terminal.app or Spaces |
| E4 | Starting a lead | `startLead(in:)` 807-848, `startLead(root:)` 890-952, `startPending` 953-962, keeping leads running 963-995, `prepareLead` 996-1090, `spawnLead` 1091-1117, the lead sessions and roots 718-795 | `vibeswitcher lead FOLDER --goal "…" [--take-head] [--replace]` starts a lead (the dialogs at 2039-2063 become the two flags; the first-commit offer, 850-889, becomes a refusal that says the folder needs a commit). Taken only from the user's voice, typed. **Refused on a fresh vault until `config accept` and `base accept` are done** (S7). No floor is seeded from `workflow.md` while the vault holds its first look (stage 2's Task 10e). The lead's session gets `VIBESWITCHER_CODEX_WORKERS=0` (decision 15). Every lead's and role's `claude` is the absolute path resolved from `~/.local/bin/claude` at that start (its folder is not on the unit's PATH, step 8); roles' MCP configs name `<node-root>/bin/vibeswitcher-mcp` | `LeadRelaunchTests`, `LeadFilesTests`, the parts of `LeadStartsHostTests` not about starting the host; new: `aSessionsProcessCannotStartALead`, `aLeadIsRefusedOnAFreshVaultUntilAccepted`, `aLeadIsLaunchedByClaudesResolvedPath` |
| E5 | Delivery and wake | delivering and holding 1208-1252, waking 1335-1405, flushing and typing 1406-1468, telling a session 1989-2023 | A worker's report reaches an idle lead: the wake prompt is typed once for all that wait | the cases of `ComposerDeliveryTests` and `PasteDeliveryTests` that are about delivery, not the composer view |
| E6 | Questions, answers and holds | `answer` 1127-1165, `hold` 1166-1195, timers 1196-1207; `ConfigHolds.swift`; `BaseMoves.swift`; `PushRequests.swift` (listed and refused: no remote) | `vibeswitcher questions`, `answer CARD TEXT`, `hold CARD`, `config held` then `config accept CARD`, `base show FOLDER [--from COMMIT]`, `base accept CARD`, `base keep CARD`, taken only from the user's voice, each that changes state typed (S3). **Cards are built by the engine** from what it derives (the task, the full commit, the files and diffstat from git, the verdict from the vault, the sensitive paths touched), and an answer is bound to its card's id in the server's memory, never to text in `board.json`. **Questions come from the lead's tool server through the server's own socket**, never read back from the board; the question's text is still the lead's. **Answers at rest**: an accepted answer or hold is recorded in the host's vault (an app-only write) before it is acted on; a restarted server takes answers only from there and asks again for anything it can't find. A `.user` seal verifies false once the server retired it or 15 minutes after it was made (the engine's EN-D11), so a sealed message of the user's copied back into an inbox is delivered at most once, inside that window | `LeadApprovalAnswerTests`, `LeadChatQuestionTests`, `ConfigHoldsTests`, `BaseMovesTests`; new: `anAnswerFromASessionsProcessIsRefused`, `anAnswerFromAProcessCarryingASessionMarkerIsRefused`, `anAnswerFromBranchCodeIsRefused`, `anApprovalCardIsBuiltFromGitAndTheVault`, `aQuestionWrittenToTheBoardIsNotShown`, `aReplayedUserMessageIsNotDeliveredTwice` |
| E7 | Refresh and the witness | `refresh` 1474-1525, `refreshed` 1526-1564, `sweepRoles` 1565-1585, `forgetFinished` 1813-1822, `witness` 1823-1885, `witnessed` 1886-1967, `stopForBudget` 1968-1988; `RoleSweep.swift`, `PromptDecline.swift`, `AllDoneWatch.swift`; `Heartbeat.swift` as the 3 s timer | Sessions whose tools never connected are ended; `auto_advance` is nudged for ended verifiers and releasable workers; stuck verifier prompts are declined; the budget is kept; finished teams forgotten | `WitnessOffMainTests`, `RoleSweepTests`, `StuckVerifierPromptTests`, `AllDoneWatchTests`, `HeartbeatTests` |
| E8 | Restarts | the rebind in `startLead(root:running:)` 916-952 and `keepRunning` 975-995 | After a server restart the lead is rebound and nothing it was told is lost. After a host restart (an empty vault) the engine says the team is gone and **lists what was reset** (roles, verdicts, approvals, the floor, the seal) and **how the host ended** (from the journal); `status` marks a start or restart no `start` explains until `status --ack`. The fresh vault holds every record's first look (stage 2's Task 10e): `config held` lists everything held with its change time (ctime), size, hash prefix and, for a guarded key, its value, and for the floor the values `workflow.md` proposes, with a card bound to those hashes; `config accept CARD` seals exactly those, anything changed since held again, then records the floor; `base show FOLDER [--from COMMIT]` makes a card of `git log <from>..<now>`, from the commit named, else the snapshot's head marked unverified (the vault lost the head), and `base accept CARD` records the head. **The "last accepted" snapshot** (hashes, guarded values, the floor, each lead's last head) is written at each accept as a diff aid, not a lock. Then the lead is started again | new: `aServerRestartKeepsTheLeadAndItsHeldMessages`, `anAnswerWrittenToTheServersFilesIsNotTakenAfterARestart`, `aHostRestartSaysTheTeamIsGone`, `aHostRestartHoldsWorkersUntilTheConfigIsAccepted`, `aStartTheUserDidntMakeIsShownUntilAcknowledged`, `configAcceptSealsOnlyWhatItShowed`, `configHeldShowsChangeTimesSizesAndHashes`, `baseAcceptAfterARestartShowsWhatMoved` |

Not ported before the bootstrap (the lead's own later work): rotation (2084-2287), replaced-lead routing (1253-1334),
the power, toolchain, heavy-slot, heavy-job, room and policy watches (1586-1774), app health (1775-1812), keep-awake,
summaries and mail, the wallet desk.

## Deliberately after the bootstrap

The lead's backlog, roughly in this order:

- **From stage 2** (the security document's S12): the sandbox through the shim (and in it the subreaper), the session
  connector or the sandbox's pid namespace, clones for workers, the egress proxy, strong mode's key file and the
  AppArmor profile, `SO_PEERPIDFD` and `SCM_PIDFD`, the logs' lint, `vibeswitcher attach`, the stage 2 Done-when's
  second half, a hardened branch-code wrapper; and, moved here by the stage 2 plan's revision (decisions 18 to 20),
  the keeper's sealed copy (its Task 11b), GitGuard's accepted hooks recorded in the vault, and the design's reply
  rights, masked screens and the wallet page's own origin (S12 items 14 to 16). The handover through
  sealed memory, the unreadable images and the static build are no longer here: they are before the bootstrap (stage
  2's Tasks 3b, 9b, 9c; step 8).
- **From stage 3:** the stores with snapshot and delta, and the engine moved off its 3 s refresh onto them; the
  WebSocket; device keys and pairing; the terminal spike; the two-node smoke test.
- **From stage 4:** approvals as device signatures, with the person's presence (WebAuthn) for pairing, Push, wallet and
  guarded settings (S11 item 31); the team seam with clones (rule 4); launch rules checked against the agents' adapters.
- **From the engine:** rotation, the watches, keep-awake, summaries, mail, the wallet desk.
- **From stage 1:** the binary decision, the cross-process start time, `platform-parity.md`, dev previews, thumbnails,
  `doctor` (its summary of S11 included), the adapters, resources inside the binaries, format versions beyond the
  settings file, the Darwin cost follow-ups, Task 10's leftovers.
- **From stage 8:** signed releases.

Until stage 4's signed approvals, an answer from the command line is a guard rail, not a lock (S3, S11). So, until the
sandbox, are verdicts and merges: with no Yama a worker can ptrace a session's agent or tool server and act as that
session, the lead or a verifier included; a worker can restart the host into what the install folder and the unit name
(S2); and while WSL interop is on, nothing is a lock at all (S1). That is acceptable only because the one project on the
node is VibeSwitcher's own, which the project allow-list enforces in the user's host (S2-D11, S11), and because the
user turns interop off for the bootstrap (decision 2).
