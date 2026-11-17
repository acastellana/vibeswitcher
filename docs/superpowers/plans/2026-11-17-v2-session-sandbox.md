# VibeSwitcher 2, the Session Sandbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A team session on a Linux node runs in a sandbox the node builds for it, so that a worker that tries can
no longer act as the user. A worker writes its own worktree and nothing else of the home; it doesn't see `~/.ssh`,
`~/.config`, `~/.vibeswitcher`, other projects, the node's sockets, the user's systemd, D-Bus, the journal, WSL
interop or `/mnt/c`; it sees only its own processes; its network goes through the node's proxy or is off. The code a
branch brings (a merge's tests, an audit's run, `init_command`, a verifier's commands) runs in a box of its own with
no way back to the session that started it. Most of the security document's S11 list becomes "a confined session
can't", in slices, the first of which already closes the worst of it.

**Architecture:** The node builds the sandbox itself, with the kernel's namespaces and a seccomp filter, from C in
`CVibePlatform` behind `Platform.Sandbox`. Nothing is installed: no bubblewrap, no slirp4netns, no nftables rule.
What a session sees is a **plan**, a list of mounts computed by pure code (`SandboxPlanner` in `VibeCore/V2`) from the
session's role, its worktree and the project's guarded settings. The root is built from nothing, so a path the plan
doesn't name isn't there. The session's **launcher** (the host's `--pty-exec` mode, a fresh single-threaded process
started from the launchers' sealed copy) applies the plan: it makes the namespaces, stays outside as the session's
**keeper** and leader of its terminal, and forks the sandbox's **init** (pid 1 inside, ours, non-dumpable), which
forks the program. When the program ends, init ends, and the kernel ends every process left in the namespace.

A confined session's tool server and hook don't run inside. Inside there is a **door**, a Unix socket only that
sandbox has; the `vibeswitcher-mcp` and `vibeswitcher-hook` the agent starts see the door and become **relays**. Init
hands each door connection to the session's **porter**, a process outside that the host started from a sealed copy
with the session's connector. The porter starts the real helper outside, with the role, root and task the host
recorded and the relay's own stdin, stdout and stderr. So the session's identity is its porter's connector, never a
pid, and nothing a worker can reach holds a right. Network egress is a proxy mode of the host's image that serves a
listener each sandbox makes inside its own network namespace and hands out. The Mac changes nothing.

**Tech Stack:** Swift 6.4.2 (language mode 5), SwiftPM `--build-system native`; C in `CVibePlatform` with the kernel's
own headers (`<sched.h>`, `<sys/mount.h>`, `<linux/seccomp.h>`, `<linux/filter.h>`, `<linux/audit.h>`,
`<linux/capability.h>`); `VibePlatform`, `VibeCore`, `VibeHost`, `VibeNode`. No new dependency, no libseccomp.

**Spec:**
- The security document, `docs/superpowers/specs/2026-11-13-v2-security-architecture.md`: S1 (modes), S4 (the
  session connector), S5, S6, S10, S11 (the list this plan closes), S12 (items 1 to 4, 9, 10, 14, 15, 17), the
  threats table.
- The design, `docs/superpowers/specs/2026-11-12-vibeswitcher-2-design.md`: Security (requirement 3, the modes
  table), Rules from the first line (4, 6, 10), Left to the builder (the sandbox's mechanism), Risks.
- The bootstrap path, `docs/superpowers/plans/2026-11-13-v2-bootstrap-path.md`: "Deliberately after the bootstrap",
  decisions D1, D2, D4, D7, D8, D9, D15, D18, D19, D20.
- The stage 2 plan's edit kinds (its Global Constraints), and the port map, `docs/process/v2-port-map.md`.

**Code references** are at `v2` `f62aef61`.

**Status:** written 2026-11-17 beside the bootstrap, at the lead's request, so the sandbox can be built as early as
possible instead of adding guard rails to plain mode. Nothing is built. The measurements below were made that day,
read-only, on the node's machine. Decisions marked **needs the lead** or **needs the user** wait for an answer;
everything else is written on the recommendation.

## Words

- **The session sandbox**, or a session's **box**: what this plan builds. Not `scripts/sandbox-app.sh`, the Mac
  app's UI sandbox, which `AGENTS.md` calls "the sandbox" and this plan doesn't touch.
- **Plan**: the list of mounts, the network kind, the environment and the filter of one box (`Platform.Sandbox.Plan`).
- **Launcher, keeper, init**: one image in three places. The launcher is the host's `--pty-exec` child. After it
  made the namespaces it is the keeper, outside. Its first child is init, pid 1 inside.
- **Door, relay, porter**: the socket inside, the helper the agent starts inside, the process outside that answers.
- **Branch run**: any run of a branch's code that isn't a worker's own session: a merge's tests, an audit's shared
  run, `init_command`, `merge_remote`, `ProductInventory`, an accepted git hook, a verifier's Bash command.
- **Mount kinds**, used in every table below: `ro` (the real folder, read-only), `rw` (the real folder), `private`
  (reads the real folder, writes go to the session's own layer and are thrown away with it: an overlay), `own` (a
  fresh folder of the session's, thrown away with it), `absent` (no such path inside).
- **A day of agent work** is 8 agent-hours.

## What exists, and what this plan builds

| Piece | Today | This plan |
| --- | --- | --- |
| How a session starts | `PTYSpawn.spawn` starts the launcher (`vibeswitcher-host --pty-exec`) from the launchers' sealed copy; it takes the terminal and execs `bash --noprofile --norc -c …` as the user, in the user's namespaces | SB3: the launcher applies a plan first; with no plan, as today |
| Process spawning | `Platform.Spawn` (posix_spawn; the host never forks) | SB1: `Platform.Sandbox`, entered only by a single-threaded launcher |
| Who a session is | ancestry or terminal, read from `/proc` at accept (S4) | SB5: a confined session is its porter's connector; ancestry stays for the rest |
| The tool server and the hook | children of the agent, as the user; they read and write `~/.vibeswitcher` (`state/`, `steer/`, `lead/`, `debug/`), the main checkout (`board.json`, `records.lock`, `evidence/`, the records folder) and connect to `host.sock` by path | SB4: relays inside, the real ones outside through the porter |
| Branch code | `BranchCode.wrapper` (a bash known by its argv), in a POSIX session of its own, as the user | SB6: the same command inside a box with no door, no terminal, no network |
| Network | open | SB9, SB10: a proxy with a list, or off |
| What a role may not do | Claude Code deny rules (`LeadLaunch.deny`, `Platform.Tools.roleDenyRules`): slips only | the rules stay as messages; the box is the lock |
| The Mac | no OS sandbox for sessions (`ConfigSeal.swift:9`: macOS refuses a sandbox inside a sandbox, and SwiftPM starts one); Codex workers use Codex's own | unchanged |

## Measured on this machine (2026-11-17)

Ubuntu 24.04.1 under WSL2, kernel `5.15.167.4-microsoft-standard-WSL2`, glibc 2.39, util-linux 2.39.3, systemd 255,
uid 1000. Read-only: nothing was installed or configured, and every namespace was a throwaway over a scratch folder.
SB0 moves this section into `docs/process/v2-linux-inventory.md` and turns each row into a test where one can be
written.

| What | Command or call | Output | What follows |
| --- | --- | --- | --- |
| User namespaces | `unshare -U true`; `unshare -Ur id` | exit 0; `uid=0(root) gid=0(root) groups=0(root),65534(nogroup)` | Works without root |
| Debian's knob | `/proc/sys/kernel/unprivileged_userns_clone` | No such file or directory | Nothing here to turn them off with |
| Limits | `/proc/sys/user/max_user_namespaces` (and `max_mnt_`, `max_pid_`, `max_net_`, `max_cgroup_namespaces`) | 384738 each | No practical limit |
| AppArmor's restriction | `/proc/sys/kernel/apparmor_restrict_unprivileged_userns`; `aa-status` | No such file or directory; `apparmor not present.` (`# CONFIG_SECURITY_APPARMOR is not set`, `# CONFIG_SECURITYFS is not set`: there is no `/sys/kernel/security`) | No profile is needed here. Ubuntu 24.04 on bare metal, and GitHub's hosted runner, refuse them (SB-D15, SB-D18) |
| bubblewrap | `bwrap --version` | `bwrap: command not found` | Not used (SB-D1) |
| Landlock | `/sys/kernel/security/landlock`; `landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)` | the path doesn't exist (no securityfs); the call returns `1` (`CONFIG_SECURITY_LANDLOCK=y`, first in `CONFIG_LSM`) | Landlock is on, at ABI 1 |
| Landlock ABI 1 and renames | a process restricted with every ABI-1 right allowed under a scratch folder, and another with every right allowed under `/` | rename within one directory: ok; rename across two allowed directories: `EXDEV`; hard link across them: `EXDEV`; read `~/.profile` outside the rule: `EACCES`; read the parent's `/proc/PID/environ`: `EACCES` | Under ABI 1 any restricted process loses renames and links between folders (ABI 2, kernel 5.19, adds `REFER`). Package managers and builds rename between folders, so **Landlock is not the file lock on this kernel** (SB-D1). It does scope ptrace |
| seccomp | `/proc/sys/kernel/seccomp/actions_avail`; `/proc/1/status` | `kill_process kill_thread trap errno user_notif trace log allow`; `Seccomp: 2`, `Seccomp_filters: 1` on pid 1 and on every process | Filters work, and WSL already puts one on everything: ours stacks on it |
| Yama | `/proc/sys/kernel/yama/ptrace_scope`; `prctl(PR_SET_PTRACER)` | No such file or directory (`# CONFIG_SECURITY_YAMA is not set`); `EINVAL` | No ptrace scope: only a pid namespace keeps one session out of another |
| pidfds | `pidfd_open`, `pidfd_send_signal`, `pidfd_getfd` of a child of the same uid, `waitid(P_PIDFD)` | an fd; 0; an fd; ok | All there. `pidfd_getfd` of a dumpable process of the user works, which is S11 item 6's route |
| Peer pidfds | `getsockopt(SO_PEERPIDFD)`, `setsockopt(SO_PASSPIDFD)` | `ENOPROTOOPT` both (kernel 6.5) | 5.15 lacks them, and `PIDFD_THREAD` (6.9: `EINVAL`). A peer is a pid number here; this plan's identity needs no pid (SB-D4) |
| Other calls | `clone3`, `close_range`, `openat2`, `mount_setattr`, `memfd_secret` | present; present; present; present; `ENOSYS` | Enough for the shim; idmapped mounts need root, and aren't needed |
| cgroups | `/proc/self/cgroup`; `/sys/fs/cgroup/unified/cgroup.controllers`; `systemctl show user@1000.service -p Delegate,DelegateControllers`; `ls -ld` of the v1 `pids` and `memory` folders of `user@1000.service` | `0::/init.scope` from a terminal; empty; `Delegate=yes`, `DelegateControllers=cpu memory pids`; both `root root` | Hybrid: the user owns its subtree in the v2 tree (`cgroup.procs`, `cgroup.kill`, `cgroup.freeze`), which has no controller, and the v1 controllers are root's. **No pids or memory limit can be set for a box here** (SB-D13). From a terminal there is no delegated cgroup at all |
| overlayfs in a user namespace | `mount -t overlay overlay -o lowerdir=…,upperdir=…,workdir=…` as mapped root | mounted; the lower file read through it | `private` mounts work (`CONFIG_OVERLAY_FS=y`) |
| The other mounts | tmpfs; `mount --rbind /usr` then `remount,bind,ro`; `proc`; `devpts -o newinstance`; `pivot_root`; `umount -l` of the old root | each ok; `touch /usr/x`: `Read-only file system` | The whole shape can be built without root |
| A whole box, with `unshare(1)` | user, mount, pid, net, ipc, uts and cgroup namespaces, a tmpfs root, `/usr` and `/etc` read-only, a scratch worktree read-write, then a second user namespace mapping uid 1000 and `setpriv --no-new-privs` | `id: 1000:1000  caps: 0000000000000000  NoNewPrivs: 1`; 4 processes visible, pid 1 the shell; `~/.ssh`, `~/.config`, `~/.vibeswitcher`, `~/.claude`, `~/projects`, `/run/user/1000/bus`, `/run/user/1000/systemd/private`, `/run/systemd/journal/socket`, `/run/WSL`, `/init`, `/mnt/c`, `/tmp/.X11-unix`, the docker socket and `/sys/fs/cgroup` all absent; the worktree writable; `net links: lo`; `curl https://1.1.1.1`: `000`; a service on the host's loopback: refused; `systemctl --user`: `offline`; `kill -0` of a process outside: `No such process`; a new pty inside: `/dev/pts/0`; `unshare -Ur true` inside: allowed | The file, process and network halves of S12 item 1 hold as built by hand. Nested user namespaces work, which SB6 and the project's own tests need (SB-D10) |
| Lifting a cover from a nested namespace | a tmpfs mounted over a folder with a file in it; then, in a second user and mount namespace made inside the first, `umount` and `umount -l` of that tmpfs | `not mounted` both times (how `umount` words the kernel's `EINVAL` for a locked mount); the folder still empty | A mount the box inherited can't be taken off from a namespace nested in it: what the plan covers stays covered (SB-D10) |
| WSL interop | `cat /proc/sys/fs/binfmt_misc/WSLInterop*`; `ls -la /run/WSL /init` | two entries, both `interpreter /init`, `magic 4d5a`, flags `PF` and `P`; the sockets `srwxrwxrwx`; `/init` `-rwxrwxrwx root` | Interop is on today (M5 isn't done yet) |
| A Windows program from inside | a copy of `cmd.exe` run outside any namespace; inside a box (no `/init`, no `/run/WSL`); with only `/run/WSL` covered | it runs; `failed to run command './cmd.exe': No such file or directory`; `/init` starts, finds no socket and fails (`UtilGetPpid … Failed to parse: /proc/1/stat`) | A box with neither path runs no Windows program. Here the missing `/init` was enough, because the entry tried first names it by path. The other entry holds the interpreter open (flag `F`), so where that one is tried only the missing `/run/WSL` stops it: the box hides both, and the attack checks both |
| Hyper-V sockets | `socket(AF_VSOCK, SOCK_STREAM)` in the host's network namespace, and inside a new one | `ok` both (`CONFIG_HYPERV_VSOCKETS=y`) | **A network namespace doesn't cover `AF_VSOCK`**: a box could still talk to the Windows side over a Hyper-V socket. The filter refuses the family (SB1). New for S11 |
| Other families | `AF_PACKET`, raw `AF_INET`; `AF_ALG`, `NETLINK_NETFILTER` | `EPERM`; `ok` | The filter leaves `AF_UNIX`, `AF_INET`, `AF_INET6` and route netlink only |
| nftables | `nft list tables` as the user; `nft add table …` in an own user and network namespace | `Operation not permitted (you must be root)`; a ruleset listed | A rule for the uid in the host's network needs root, so egress isn't filtered that way. Inside a namespace of its own any process can load netfilter rules: kernel surface the filter cuts |
| slirp4netns, pasta | `command -v` | missing both (`/dev/net/tun` is `crw-rw-rw-`, and a tap device can be made in an own namespace, so either would work if installed) | Not needed (below) |
| Egress with nothing installed | a TCP listener bound to `127.0.0.1:3128` inside a new network namespace, its descriptor passed out with `SCM_RIGHTS`, accepted by a process outside that answers `CONNECT` | outside: `bound to ('127.0.0.1', 3128)` while its own namespace has 9 links; inside: `links = lo`; `curl -x http://127.0.0.1:3128 https://example.com/`: `200`; with no proxy: `Could not resolve host` | **A socket belongs to the namespace it was made in, whoever holds it.** The proxy needs no tap device and no relay (SB-D7) |
| Unix sockets across namespaces | a path socket bound outside, connected from inside a user, net and pid namespace; an abstract one | connected; `SO_PEERCRED` gives the connector's pid as the listener numbers it, whose `/proc/<pid>/ns/pid` differs from the listener's; the abstract one: `Connection refused` | A path socket is reachable exactly when it is in the mount view: hiding is the lock. Abstract sockets stay behind with the network namespace |
| A terminal made outside | the slave of a pty as stdin of a process whose `/dev/pts` is a devpts of its own | `isatty(0)`: True; `ttyname(0)`: `ENODEV` (`tty` says `not a tty`); `/proc/self/fd/0`: `/dev/pts/5`; `/dev/tty` opens; `getsid(0)`: 0; a new pty inside: `/dev/pts/0`; `tty_nr`: `136:5`; an interactive bash turns job control on | The session keeps its host terminal number (`ttypts5`), so every tty-keyed record still matches. Programs that ask the terminal's name get none: SB0 measures Claude Code |
| Writing the uid map | a non-dumpable process after `unshare(CLONE_NEWUSER)`; a dumpable one, made non-dumpable after | `EACCES`; written | The launcher runs from an unreadable copy, so it must be dumpable while it writes its maps, which it already is before its exec (`HostImages.beforeProgram`). Init hardens again afterwards |
| Claude Code 2.1.326 | the loader's `--list` of the binary; `stat` of `~/.claude.json` five minutes apart; the files beside it | `librt`, `libc`, `libpthread`, `libdl`, `libm` from `/lib/x86_64-linux-gnu`; inode 1789508, then 771029; seven `~/.claude.json.tmp.<pid>.<ms>` files; `.credentials.json` unchanged | The agent needs `/usr` and its own file. It replaces `~/.claude.json` by a temporary file and a rename beside it, so that file can't be a single bound file: the home inside is a folder of the session's own |
| Around it | `kernel.unprivileged_bpf_disabled`; `perf_event_paranoid`; `vm.unprivileged_userfaultfd`; `/proc` | 2; 2; 0; no `hidepid` | The filter refuses `bpf`, `perf_event_open` and `userfaultfd` anyway |
| This network | `/etc/resolv.conf`; `ip -o addr`; `ss -ltn` | the tailnet's resolver (`100.100.100.100`); a `tailscale0` link beside the LAN's; three listeners on loopback | What the proxy must refuse is really here |

**What 5.15 lacks, and what it costs:** `SO_PEERPIDFD` and `SCM_PIDFD` (6.5), not needed by this plan; Landlock's
`REFER` (5.19), so no Landlock for sessions; Landlock's network rules (6.7) and its scopes for abstract sockets and
signals (6.12), done here by the namespaces; cgroup limits, missing because of the hybrid layout, not the kernel.

**Prerequisites the user would install: none.** Optional, the user's, each only an improvement:

- A newer WSL kernel, if `wsl --update` offers one: 5.19 or later gives Landlock's `REFER`, so Landlock as a second
  file lock; 6.5 or later gives `SO_PEERPIDFD`.
- cgroup v2 alone (for WSL, `kernelCommandLine = cgroup_no_v1=all` under `[wsl2]` in `.wslconfig`; not measured
  here): pids and memory limits for each box through the delegated tree.
- On Ubuntu 24.04 bare metal, later: an AppArmor profile that lets the host's binary make user namespaces (S12 item
  5; the release installs it, stage 8).
- bubblewrap, slirp4netns and pasta would work here and aren't needed.

## Global Constraints

The v2 rules, as in the start plan (`2026-11-16-v2-start-install-seal.md`), with what this plan adds marked **(new)**.

- **All work on `v2`, never `main`.** Nothing under `Sources/VibeSwitcher`, `Tests/VibeSwitcherTests` or `Web/` is
  edited. Each task is built in a worktree of its own (`bash scripts/worktree-init.sh` first) and joins the
  `v2-sandbox` branch after a reviewer who hasn't seen it; `v2-sandbox` joins `v2` a slice at a time.
- **Shared files.** An edit to an existing file under `Sources/VibeCore`, `Sources/VibeHost` or an executable shared
  with main (`vibeswitcher-host`, `-hook`, `-mcp`) must be one of stage 2's edit kinds (1 to 8; the stage 2 plan's
  Global Constraints).
  - Each edit of kinds 4 to 8 gets a row in the port map's Non-seam edits. The ones this plan makes are listed under
    [Non-seam edits](#non-seam-edits-this-plan-makes). An executor who needs another stops and asks.
  - New `VibeCore` files go in `Sources/VibeCore/V2/`, new `VibeHost` ones in `Sources/VibeHost/V2/`.
- **No `#if os` outside `VibePlatform`** (`PlatformLint`). "On Linux" outside it reads
  `!Platform.CodeIdentity.isAvailable`; "where a box can be built" reads `Platform.Sandbox.probe()`. The Mac's form
  of every new call does nothing, and a Mac test says so.
- **Tests only through `scripts/test.sh`**, never a bare `swift test`. Lints run before a task is reported done. New or
  changed tests also run under `scripts/test-under-load.sh --load 24 -r 3`. Long or many-core jobs run under
  `vs-heavy`.
- **Tests never touch the real `~/.claude`, `~/.vibeswitcher`, `$XDG_RUNTIME_DIR`, the user's journal or systemd.**
  - Every box a test builds is planned over scratch folders: a scratch home, a scratch repository, a scratch node
    root. `refuseTheAccountRoot` stays in every suite's support.
  - **(new) A probe aimed at a real path only looks.** From inside a box a test may `lstat`, `access` or
    connect-and-close a real fixed path (`/run/user/<uid>/bus`, `/run/user/<uid>/systemd/private`,
    `/run/systemd/journal/socket`, `/run/WSL`, `/init`, `/mnt/c`), and must find it absent. It never sends a byte to
    one, writes one, or signals or traces a process it didn't start. Every write, signal, trace and send is aimed at
    a **decoy** the test made: a scratch unit folder, a scratch host socket with a listener, a `sleep` standing for
    another session, a second scratch worktree, a listener on loopback.
  - **(new) No real Windows program is run.** The interop probe executes a two-byte `MZ` file the test wrote.
  - A `--node` host is never started by a test. A scratch host confines only when its test tells it to.
- **(new) The host never forks.** A box is entered only by a launcher: a process `posix_spawn` started for that, at
  its first statement, while it has one thread. `unshare(CLONE_NEWUSER)` refuses a process with more.
- **(new) A box fails closed.** A plan that can't be applied (a mount refused, a map not written, the filter not
  loaded) starts nothing and says which step failed, on the session's terminal and in the host's log. A role the node
  confines is never started unconfined instead.
- **Close-on-exec from creation, and every spawn names `keep`** (stage 2's rule). The program in a box holds
  descriptors 0, 1 and 2 and nothing else.
- **Nothing secret in an argument or an environment variable.** A plan travels in sealed memory, by descriptor
  number.
- **(new) A test waits with a bound** through `Platform.Spawn` and `waitpid`, never Foundation's
  `Process.waitUntilExit`, which hangs on the hosted Mac.
- **Agents start nothing in the user's systemd manager**, and run no `vs` subcommand that changes the real node's
  state (D14).
- **Real-agent tests only with `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR` given** on the run's command line (D16), on
  Sonnet or smaller. Each gated run needs the user's go-ahead.
- **A fix's test is shown failing** without the fix: `git diff <pre-fix> HEAD -- <fix files> | git apply -R`, run the
  test, re-apply. A new feature's tests fail first for the right reason. **(new)** Every attack test is also shown
  succeeding against its decoy with the box off (SB7), so a probe that proves nothing is found.
- **Every job is green before the next task's first push.** "Green" means the `v2 linux` and `v2 macos` jobs on one
  commit.
- **Never install anything** (brew, npm -g, pip, apps, toolchains, kernel modules), and never change the machine's
  configuration (`sysctl`, `/etc`, `.wslconfig`).
- Commit messages end with the attribution line the session gives.

## What each role can read, write, run and reach

`<home>` is the account's home, `<root>` the lead's main checkout, `<wt>` a session's worktree
(`<root>/.vibeswitcher/worktrees/<slug>`), `<git>` the repository's common git folder (`<root>/.git`), `<build>` the
node's build folder (`<prefix>/<commit>`), `<box>` the session's own folder outside
(`<home>/.vibeswitcher/v2/boxes/<session id>`, 0700, removed with the session). Every path keeps its real spelling
inside, so transcripts, records and error messages name the same files on both sides.

### Files

| What | Worker | Verifier's agent | Lead | Branch run |
| --- | --- | --- | --- | --- |
| `/usr`, `/etc`, `/opt` (root's), with `/bin`, `/lib`, `/lib64`, `/sbin` as links | ro | ro | ro | ro |
| `/proc` (its own), `/dev` (`null`, `zero`, `full`, `random`, `urandom`, `tty`, a devpts of its own, `shm`), `/sys` (read-only, if SB1's measurement mounts it) | own | own | own | own |
| `/tmp`, `/var/tmp` | own | own | own | own |
| Its TMPDIR (the folder `SessionTemp.make` made for it) | rw | rw | rw | the run's scratch home's `tmp/` |
| `<home>` itself | own (in `<box>`) | own | own | the run's scratch home, as today |
| Its worktree | `<wt>` rw | its audit checkout rw | absent | the run's scratch worktree rw |
| `<git>` | ro, with rw: `objects/`, `worktrees/<slug>/`, `refs/heads/agent/`, `logs/refs/heads/agent/` (the list `LeadLaunch.codexWritableRoots` already gives a Codex worker) | ro, with its own `worktrees/<name>/` rw | ro | ro, with the scratch worktree's own git folder rw |
| The base branch's ref, `packed-refs`, `HEAD`, `config`, `hooks/`, `info/`, tags | ro | ro | ro | ro |
| The worktree's pointers: its `.git` file, and `commondir` and `gitdir` in its git folder | ro | ro | — | ro |
| `<root>`'s working files | absent | absent | private (it may build; nothing reaches the real checkout) | absent |
| Other sessions' worktrees | absent | absent | ro | absent |
| `<root>/.vibeswitcher/` (`board.json`, `workflow.md`, `evidence/`, `run/`, `records.lock`) | absent | absent | ro | absent |
| The toolchain: every folder on the unit's PATH that the user can write (swiftly's, node's, `<build>/Resources/bin`), `<build>/bin`, `<home>/.vibeswitcher/bin` (the installed hook) | ro | ro | ro | ro |
| The agent's program (`<home>/.local/share/claude/versions/<v>`, the file the lead resolved, EN-D13) | ro | ro | ro | absent |
| The agent's config (below) | as below | as below | as below | absent |
| Package caches (`<home>/.cache/org.swift.swiftpm`, `<home>/.swiftpm`, `<home>/.npm`, and what the project's `sandbox_private` lists) | private | private | absent | private |
| What the project's `sandbox_read` lists (guarded, SB-D16) | ro | ro | ro | ro |
| The heavy-work slots (`/tmp/vibeswitcher-<uid>/slots`, SB-D14) | rw, shared | rw, shared | rw, shared | absent (the slot is held outside, and `VIBESWITCHER_TEST_LOCK` says so) |
| The door, `/run/vibeswitcher/door` | yes | yes | yes | **no** |
| `<home>/.ssh`, `.gnupg`, `.config` (gh's token, `systemd/user`, `environment.d`, `autostart`), `.aws` and the other cloud folders, `.docker`, `.codex`, `.bashrc`, `.profile`, `.bash_profile`, `.bash_login`, the user's `.gitconfig`, every other project | absent | absent | absent | absent |
| `<home>/.vibeswitcher` (`host.sock`, `host.lock`, `v2/server.sock`, `v2/builds` but for `<build>/bin` and `Resources/bin`, `v2/projects`, `state/`, `steer/`, `lead/`, `debug/`, later `keys/`) | absent | absent | absent | absent |
| `/run/user/<uid>` (the manager's private socket, the session bus, the gpg-agent, wayland), `/run/systemd` (the journal's socket), `/dev/log`, `/run/WSL`, `/init`, `/mnt` (`c`, `wslg`), `/tmp/.X11-unix`, a docker socket, `/var/spool/cron`, `/sys/fs/cgroup`, `/snap` | absent | absent | absent | absent |
| Other processes | its own only (a pid namespace) | its own | its own | its own; never the session that started it |
| Other terminals (`/dev/pts/N` of any other session, the user's) | absent | absent | absent | none at all (a POSIX session of its own, no `/dev/tty`) |

Inside, git gets a generated `<home>/.gitconfig`: the user's `user.name` and `user.email`, `gc.auto=0`, and no
credential helper.

**Execute.** Anything it can read, as the user's own uid with no capability, `no_new_privs` set and every mount
`nosuid` and `nodev`: a setuid program gains nothing, so `sudo`, `su`, `newgrp`, `crontab` and `at` do nothing there.
A Windows program doesn't start (measured). The seccomp filter refuses what no session needs: sockets other than Unix,
IPv4, IPv6 and route netlink (so `AF_VSOCK`, `AF_PACKET`, `AF_ALG`, netfilter netlink); `bpf`, `perf_event_open`,
`userfaultfd`, the keyring calls, `kexec`, modules, `swapon`, `open_by_handle_at`; `TIOCSTI`; and, unless the
project's `sandbox_nesting` allows it, new user namespaces and the mount calls. `ptrace` is left: inside, it reaches
only the box's own processes.

### Network

| | Slice 1 | From slice 2 |
| --- | --- | --- |
| Worker | the host's network, as today (SB-D6) | a network namespace of its own; the proxy, with the agent's API and the project's `sandbox_hosts` |
| Verifier's agent | as today (not confined yet) | from slice 3: the proxy, the agent's API only |
| Lead | as today (not confined yet) | from slice 3: the proxy, the agent's API only. Fetching a remote is its tool server's, outside |
| Branch run | **none** (an empty network namespace) | none, or the proxy with the project's `sandbox_run_hosts` when `init_command` fetches packages |

The proxy tunnels `CONNECT host:443` (and plain HTTP to a listed host) for names on the session's list, resolves the
name itself, and refuses whatever the list says: loopback, which under mirrored networking is also the Windows side;
the tailnet (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`, `*.ts.net`); link-local and cloud metadata (`169.254.0.0/16`,
`fe80::/10`); an address literal; a listed name that resolves to a refused address. Private ranges (`10/8`,
`172.16/12`, `192.168/16`, `fc00::/7`) are refused unless the project names the host. Inside there is no resolver
and no route, so a program that ignores the proxy variables reaches nothing. No GitHub credential is inside (no
`gh` token, no helper, no ssh key), so a listed `github.com` is anonymous.

**What a list doesn't stop:** sending what the session can read to an account of the attacker's on a listed host
(the agent's API takes any key; a package host takes uploads). Slice 4 closes it for the agent's API by keeping the
login outside. For the rest, a project lists as few hosts as it can, and the proxy logs every host asked for.

### The agent itself: Claude Code inside

Claude Code is one native binary plus a config folder and a file beside it. What it needs, and what it gets:

| What Claude Code uses | Inside | Why |
| --- | --- | --- |
| Its binary and the C library | ro | Measured: it links only `/lib`'s |
| `<home>/.claude.json` | a seeded copy in the session's own home: the account's identity fields and this folder's trust entry; no other project's entry, no user-scope tool servers (SB-D9) | It rewrites the file by a rename beside it (measured), so the folder must be the session's. The other entries name the user's other projects and may hold tool servers' keys |
| `<home>/.claude/`, the folder | own | It makes temporary files and new entries there |
| `settings.json`, `settings.local.json`, `CLAUDE.md`, `skills/`, `agents/`, `commands/`, `plugins/`, `keybindings.json`, the status line's script, `policy-limits.json*`, `remote-settings.json*`, each where it exists (`ClaudeFiles.readOnlyEntries`; an entry not on the list isn't shown) | ro, each bound into the session's folder | The user's settings, hooks and instructions still apply, and no session can change what the next one loads (S11 item 8) |
| `projects/<this folder's name>/` (the transcript, its memory) | rw, the real folder | The lead's `read_session`, receipts and `tellLead` read transcripts from outside, and a resumed or rotated session finds its own |
| Everything else there (on this machine: `shell-snapshots/`, `session-env/`, `history.jsonl`, `file-history/`, `paste-cache/`, `debug/`, `cache/`, `tasks/`, `teams/`, `jobs/`, `sessions/`, `state/`, `backups/`, the daemon's files, the caches) | own, empty at start | The Bash tool sources its snapshot before every command: a snapshot of the session's own can't carry another session's function (S11 item 8, measured route) |
| `.credentials.json` (the login) | ro in slices 1 to 3; gone in slice 4 (SB-D8) | The agent can't call its API without it today |
| `<home>/.cache/claude*`, `<home>/.local/state/claude`, `/tmp/claude-<uid>/` | own | Locks, staging and its tasks' output |
| Its Bash tool's shell | `/bin/bash`, with no startup file in the session's home | `~/.bashrc` and the login files Claude Code sources (Task 12b) aren't there |
| Its hooks | the user's `settings.json` names `<home>/.vibeswitcher/bin/vibeswitcher-hook`, which is there, read-only, and relays | No setting changes |
| Its tool server | the role's `--mcp-config` names `<build>/bin/vibeswitcher-mcp`, which is there, read-only, and relays | No launch setting changes |
| Its updates | off (`DISABLE_AUTOUPDATER=1`): the versions folder is read-only | An update inside would write what every agent runs |
| Its API | slice 1: as today. From slice 2: `HTTPS_PROXY`, `HTTP_PROXY` and their lower-case forms name the box's listener | Measured for `curl`; Claude Code, git, npm and SwiftPM are SB0's to measure |
| Environment | `HOME USER LOGNAME SHELL PATH LANG LC_* TERM COLORTERM TERM_PROGRAM VIBESWITCHER_SESSION VIBESWITCHER_ROLE VIBESWITCHER_DOOR TMPDIR` and the role's named ones (`GIT_OPTIONAL_LOCKS`, `VIBESWITCHER_HEAVY_*`, a verifier's three): an allow-list (S12 item 17) | A spawn's `env` can no longer carry a name nobody listed |

**Not measured yet, and SB0's first job** (a gated run with M1's test login in a prototype box): whether Claude Code
writes any top-level entry of its config folder besides the ones marked own (it would fail on a bound one); whether
it refreshes its login during a session and how it writes it; which hosts it asks for; whether its TUI minds a
terminal with no name; whether a seeded trust entry spares `answerTrust`'s typing. The table's "ro" and "own" lists
are a platform answer (`ClaudeFiles`), so a new Claude Code version changes one list and its test.

Codex stays off (D15). Its own sandbox would run inside this one; that is measured before `VIBESWITCHER_CODEX_WORKERS`
goes back on, in a task of its own after slice 3.

### The tool server, the hook, and the host

Today a worker's tool server and hook are its agent's children. They write `~/.vibeswitcher/state/<tty>.json`,
read and write `~/.vibeswitcher/steer/`, `lead/git-hooks/` and `debug/`, read and write the **main checkout's**
`board.json`, records and `evidence/`, read the lead's transcript and connect to `host.sock` by path. Giving a box
all of that would give back most of what it takes away (S11 items 5, 7 and 29). So they move out.

```
 inside the session's box                    │ outside
                                             │
 claude ──starts──► vibeswitcher-mcp (relay) │
        ──starts──► vibeswitcher-hook (relay)│
                        │ connect            │
                        ▼                    │
              /run/vibeswitcher/door         │
                        │ accepted by        │
                        ▼                    │
              init (pid 1, ours) ──the connection itself, by SCM_RIGHTS──► porter (one per session,
                                             │                            │   sealed copy, non-dumpable)
                                             │                            │ starts, with the relay's own
                                             │                            ▼ stdin, stdout and stderr
                                             │              vibeswitcher-mcp / vibeswitcher-hook (the real one)
                                             │                            │ the session's connector
                                             │                            ▼
                                             │                          host
```

- **The door** is a `SOCK_STREAM` socket init binds at `/run/vibeswitcher/door`, in the box's own tmpfs: it has no
  path outside. Whatever runs in the box may connect; that is what "being the session" means there. A branch run's
  box has no door.
- **The relay** is the same binary the settings already name. Its first statement sees `VIBESWITCHER_DOOR`,
  connects, sends one line (`{"v":1,"mode":"mcp"|"hook"|"statusLine"|"permission","args":[…]}`, 64 KiB at most) with
  its own stdin, stdout and stderr as descriptors, waits for `exit N`, and exits N. It reads no path and no host
  socket.
- **Init** only passes connections on: it reads nothing from them. It is non-dumpable, never execs, and holds the
  door line and nothing else.
- **The porter** takes the mode from the line and everything else from its own arguments, which the host gave it
  from the session's record (`SpawnRequest.helper`: role, root, task): a relay can't choose a role, a root or a task.
  It starts the helper from sealed copies of the tool server's and the hook's images (hashed against `build-info`),
  with the three descriptors as its stdio and the session's connector kept. When the relay goes, it ends the helper;
  when the helper ends, it answers the status. A hook's helper is told the relay's pid (`SO_PEERCRED`, as the porter
  numbers it), so it finds its agent and terminal as it does today.
- **The connector** is S4's, held by the porter instead of the session: a `SOCK_SEQPACKET` pair the host made at
  spawn and bound to the session's id. A helper asks on it for a stream; the host answers only a non-dumpable child
  of that porter, and that stream is the session's (S5's sender check then holds per message, as for the app).
- **Hooks reach the node** that way: the real hook writes the state file and takes the steer inbox outside, in at
  most the 3 s it has today (SB4 measures the added time).
- **What it replaces:** the keeper and `BinaryWatch` (the porter restarts nothing in place: a helper that died is
  started again at the relay's next connection, from the sealed copy), D18's copy, and the hardened wrapper of S12
  item 10.

A plain session (the Mac, a scratch host, a node that can't confine, the user's own sessions) has no door: its tool
server and hook run as they do today.

**What the outside must not do for a box.** Moving the helpers out makes them deputies: they are the user, and they
act on what a box wrote. Two rules keep a box from using them, and SB6b holds both:

- **No program is run outside in a folder a box can write.** Git takes its repository, config and hooks from the
  folder it runs in, and `GitGuard` accepts the hooks of a repository it sees for the first time. Today the hook
  runs `git rev-parse` in the folder of the agent's own git command (`GitMoves`), which is the worktree. For a
  confined session the relay does that reading, inside, and sends what it found as data; the vault already takes a
  session's `ranGit` as that session's word. Everything else the helpers run, they run in `<root>`, whose git
  folder a box can't write but for objects and its own refs. The worktree's own pointers are read-only, so a
  worker can't aim its worktree at a repository of its own making.
- **No link a box made is followed out of its folders.** A helper that opens a path under a worktree (a done
  report's evidence images, the load script, a records file) opens it beneath that worktree, no link followed
  out (`openat2` with `RESOLVE_BENEATH`, which this kernel has), so a link to `~/.ssh` planted as evidence is
  never copied into the checkout.

## What it closes

### S11 item → task

"Closed" means for a confined session and for branch code; a process of the user's that isn't confined is as before
(S12's "Doesn't promise"). Slice 1 confines workers and branch runs; slice 3 the lead and the verifiers' agents.

| S11 item | Closed by | How | What stays |
| --- | --- | --- | --- |
| 1. Interop, `sudo`, a docker socket: one step from root | SB1, SB3 | no `/init`, no `/run/WSL` (measured), `AF_VSOCK` refused, `no_new_privs` and `nosuid`, no docker socket, no way to the user's shell | D2 stays recommended for what isn't confined. It is no longer what every lock rests on |
| 2. `/mnt/c`: `.wslconfig`, the Startup folder | SB3 | absent | the same |
| 3. Becoming the host: the unit, drop-ins, `environment.d`, the install folder, `build-info`, the toolchain, an install's scratch folder | SB3 (workers), SB6 (branch code), SB11 (lead, verifiers) | absent or `ro`; no signal reaches the host (pid namespace); no manager socket | signed releases for installs (stage 8) |
| 4. Tracing the host in its own start | SB3 | the host isn't a process the box can name | an unconfined process of the user |
| 5. A socket or a lock put at the host's path | SB3 | `~/.vibeswitcher` absent | the same |
| 6. Acting as any session by ptrace or `pidfd_getfd` | SB3, SB4, SB5 | a pid namespace; the tool server outside and non-dumpable; identity by connector | the same |
| 7. Routes into a role without ptrace | SB3, SB4, SB6, SB6b | the run folder, the hooks copy with its record, `board.json` and `engine.json` absent; the tool server's file `ro` and no keeper; branch code has no door, so being "under a runner" or not changes nothing; SB6b for what the helpers outside read and run | text (item 12) |
| 8. Replacing what every agent runs | SB3 | the agents' settings and versions `ro`; no startup file; snapshots the session's own; PATH folders `ro` | the seal's two residuals, for unconfined writers |
| 9. Moving the lead's base through the shared `.git` | SB2, SB3 | the base's ref, `packed-refs`, `config` and `hooks` are `ro` | other `agent/` refs and the object store stay writable until clones (SB-D5) |
| 10. Branch code unconfined, a patched toolchain | SB6 | every branch run in a box; the toolchain `ro` | — |
| 11. A query written to a session's `/dev/pts/N` | SB3 | a devpts of its own | a session's own terminal |
| 12. Turning the lead or a verifier by text | — | not by confinement | the floor, approvals, two finders on another model |
| 13. The user's voice: the user's shell or command line by ptrace; `ssh localhost` | SB3; SB10 | pid namespace, no terminal but its own, `server.sock` absent; no loopback | the user's own Claude Code turned by text (signed approvals) |
| 14. The user's processes acting for a worker: PATH, aliases, the user's terminal | SB3 | absent or `ro` | — |
| 15. The command line's binary replaced | SB3 | `ro` | signed releases |
| 16. Another session's terminal; a window on the Windows desktop | SB3; SB10 | own devpts; the X and Wayland sockets absent; abstract sockets behind the network namespace | D9 for what isn't confined |
| 17. Text the user reads | — | not by confinement | cards built from git and the vault |
| 18. Every file of the user; sending it out | SB3 (reading); SB10 (sending); SB13 (the agent's login) | the home absent but for the plan's list; the proxy's list | the project's own tree, to a listed host |
| 19. Sockets by fixed path under `/run/user/<uid>`; WSLg | SB3 | absent | — |
| 20. `/proc/<pid>/environ` and `cmdline` of the user's processes | SB3 | a `/proc` of its own | another user's view of command lines |
| 21. Credentials name no reader | — | unchanged; a box's descriptors can't leave it but through the door | — |
| 22. Windows-side localhost under mirrored networking | SB6 (branch runs), SB10 | no network, or the proxy, which refuses loopback | workers in slice 1 (SB-D6) |
| 23. Code that runs later as the user: crontab, units, autostart, startup files, `set-environment`, `at` | SB3 | every one absent; no manager socket; setuid helpers do nothing | — |
| 24. A scratch host of its own | SB3, SB5 | it can run one inside, where it reaches nothing; the node confines by role, whatever the folder | — |
| 25. Signals to the host, the server, the parsers | SB3 | they aren't processes the box can name | memory, disk and process exhaustion (SB-D13) |
| 26. Filling the host's client slots | SB3 | no `host.sock`; the door reaches its own porter only | — |
| 27. A host restart erases the team's state | not in this plan | strong mode's key file needs every team session confined first | after slice 3 ([Not in this plan](#not-in-this-plan)) |
| 28. Logs; journal entries from a session | SB3 | no journal socket inside, so a session can't add a line under the unit | the logs' lint |
| 29. Replaying a sealed message into the lead's inbox | SB3; SB11 | `steer/` absent for workers, then for the lead (its hook is outside) | signed approvals |
| 30, 31. The handover's state; the browser's storage | — | 30 closed already; 31: `/mnt/c` absent to a box | stage 4's design check |
| New: Hyper-V sockets ignore the network namespace | SB1 | the filter refuses the family | — |
| New: netfilter, bpf and the mount calls from a namespace of one's own are kernel surface any process of the user has today | SB1 | the filter refuses them unless the project allows nesting | a kernel bug reachable through what is left |
| The project allow-list (S2-D11) | SB5, SB11 | the node confines by role; a folder outside the plan isn't there | goes at stage 6, as decided |

### Guard rails that become locks, or go

| Today's guard rail | After |
| --- | --- |
| Linux's deny rules (`strace`, `systemctl --user`, `systemd-run`, `crontab`, `at`, `wsl.exe`, `gh`, edits under `~/.config/systemd`, `/mnt/c`) | Kept as the message a slip gets. The box is the lock: none of them has anything to reach |
| The sessions' environment list, and the refused names of a spawn's `env` | The paths those variables name are absent. A confined spawn's `env` is an allow-list (S12 item 17, SB5) |
| `bash --noprofile --norc` | No startup file exists inside |
| The config seal | A lock for confined sessions (they can't write what it watches). It stays the detector for what isn't confined, and holds fewer teams for nothing |
| Verdicts and merges | Locks against a worker that tries once slice 1 is in (the worker and every run of its code are confined), and against a turned lead or verifier with a shell once slice 3 is. Text stays (item 12) |
| The `BranchCode` wrapper known by its argv, and S12 item 10's hardened wrapper | Not needed: a branch run has no door and no host socket |
| `MCPKeeper`, `BinaryWatch`, D18's sealed copy (S12 item 14) | Not needed for confined sessions: helpers start from the porter's sealed copies |
| GitGuard's accepted hooks and D19's check (S12 item 15) | The copy is out of a box's reach. The check becomes optional |
| D4's subreaper, the orphan sweep, `SessionStrays`' signals | Not needed for confined sessions: the namespace ends with its program, and init reaps |
| The launcher's terminal check, token-matched ancestry, per-message senders | Stay for plain sessions and for the app. A confined session isn't told by pid |
| The cgroup voice rule | Stays for plain sessions. A box has no `server.sock` |
| D2 (interop and automount off), D9 (the gpg-agent's ssh socket, WSLg), D11 (the narrowed `gh` token) | Still recommended while anything of a team is unconfined (slices 1 and 2). After slice 3 they protect the user's own sessions only |
| D12 (root's toolchain for installs), D14 (the supervising Claude Code's deny rules) | Unchanged: both concern what isn't confined |

## The Mac

Nothing changes there. `Platform.Sandbox.probe()` answers "unavailable" on Darwin, `HostServer.Config.confinement` is
nil by default, a spawn's `helper` is ignored, the relays never see a door, `BranchRun` hands back today's wrapper,
and `LeadLaunch`, the keeper and the hook run as on main. Each has a Mac test (`theMacHasNoSandbox`,
`theMacConfinesNothing`, `onTheMacBranchCodeRunsAsBefore`, `theMacsToolServerNeverRelays`). SB8 adds one line to
`docs/process/v2-mac-tasks.md`.

Its equivalent later is milestone 5's to design (the design's modes table: "the Mac's own"). What carries over
unchanged: the plan (`SandboxPlanner` is pure and already names every path), the door, relay and porter (plain Unix
sockets and descriptor passing), and the egress proxy. What differs is only who enforces the plan. The candidates,
for that design: a Seatbelt profile rendered from the plan (what Codex and Claude Code's own sandbox use on macOS),
with builds told not to start a sandbox of their own, since macOS refuses one inside another (`swift build
--disable-sandbox`; the reason `ConfigSeal.swift` gives for having none today); or the team run in a Linux virtual
machine on the Mac, where this plan's box applies as it is. Neither is decided here.

## How it is tested

1. **Pure.** `SandboxPlannerTests`, `EgressRulesTests` and `PorterTests`' rules run on both systems with no kernel:
   they hold "nothing of the home is a source that the plan doesn't name".
2. **The shim, on scratch folders.** `SandboxShimTests` start the test binary's own helper mode through
   `Platform.Spawn`, as `SocketsTests` already does under `unshare(1)`: the helper enters a plan over scratch folders
   and reports what it sees. They skip, saying why, where the kernel refuses a user namespace
   (`Platform.Sandbox.probe()`); see SB-D15 for the hosted runner.
3. **Sessions under a scratch host.** `TestHost` and `ScratchNode` with `Config.confinement` set and `FakeClaude` as
   the agent: a confined worker's hook writes its state file, its tool call reaches the scratch vault, a merge's
   tests run in a branch run's box. The scratch home stands for the home: decoy `.ssh/id_ed25519`,
   `.config/systemd/user/decoy.service`, `.config/gh/hosts.yml`, a second project, a second worktree.
4. **The attack** (SB7): a hostile worker, as a script its session runs and as branch code a merge runs. Each line is
   a test; each must fail inside, and each is shown succeeding against its decoy with the box off.

   | The hostile worker tries to | Test (`SandboxAttackTests.`) | Aimed at |
   | --- | --- | --- |
   | ptrace, `process_vm_readv` and `pidfd_getfd` another session's agent | `aWorkerCantTraceReadOrTakeDescriptorsOfAnotherSession` | a decoy session's `sleep` |
   | signal the host, the server, another session | `aWorkerCantSignalAnythingOutsideItsBox` | the scratch host and a decoy |
   | read `~/.ssh`, `~/.gnupg`, gh's token, another project | `aWorkerCantReadTheUsersKeysOrAnotherProject` | decoy files in the scratch home; the real paths only looked at |
   | write the unit folder, `environment.d`, autostart, a startup file, the crontab | `aWorkerCantWriteWhatRunsLaterAsTheUser` | the scratch home's |
   | write the install folder, `build-info`, the command line, the hook, the toolchain, `claude`'s versions | `aWorkerCantReplaceWhatTheNodeOrAnAgentRuns` | a scratch build folder and toolchain |
   | connect to the host's socket and the server's; bind its own at their paths | `aWorkerCantReachOrSquatTheNodesSockets` | the scratch host's |
   | reach the systemd user manager, the session bus, the gpg-agent, the journal | `aWorkerCantReachTheUsersManagerBusAgentOrJournal` | the real fixed paths, looked at only; decoy listeners at the same names under the scratch home |
   | run a Windows binary through interop | `aWorkerCantRunAWindowsProgram` | an `MZ` stub; `/init`, `/run/WSL`, `/mnt/c` looked at |
   | open a Hyper-V socket | `aWorkerCantOpenAHyperVSocket` | `socket()` only |
   | write another worktree, the main checkout, `board.json`, the base's ref, the git hooks, the hooks copy | `aWorkerCantWriteAnotherWorktreeTheCheckoutOrTheBase` | the scratch repository |
   | read or write another session's terminal; type into its own by `TIOCSTI` | `aWorkerCantTouchAnotherTerminalOrTypeByIoctl` | a decoy pty |
   | read another session's screen, the node's state, the host's memory | `aConfinedSessionCantReadAnotherSessionsScreenTheNodesStateOrTheHostsMemory` (S12's first named test) | the scratch host |
   | outlive its session: double fork, `setsid`, `nohup`, a nested namespace | `nothingAWorkerStartsOutlivesItsSession` | its own processes |
   | ask the door for another role, root or task; pass a fourth descriptor; send a 1 MiB line | `theDoorGivesAWorkerOnlyAWorkersHelpers` | its own porter |
   | aim its worktree at a repository of its own (the `.git` file, `commondir`, a nested repository) and wait for the node's git to run its hooks or config | `aWorkerCantMakeTheNodesGitRunItsHooksOrConfig` | the scratch team's helpers |
   | plant a link in its worktree to a key, as evidence or as a file the node reads, and wait for it to be copied or read | `aLinkPlantedForTheNodeToFollowLeadsNowhere` | a decoy key in the scratch home |
   | uncover a hidden path: `umount`, a nested mount namespace, `/proc/1/root`, `..` out of the root | `aWorkerCantUncoverWhatThePlanHides` | its own box |
   | regain a privilege: setuid programs, a nested user namespace's capabilities over the box's mounts | `aWorkerGainsNothingFromSetuidOrNesting` | its own box |
   | exfiltrate: a host off the list, an address literal, loopback, the tailnet, metadata, DNS, a raw socket | `aWorkerCantSendToAnythingOffItsList` (slice 2) | a decoy listener on loopback and a stand-in resolver; no real host |
   | the same, as branch code in a merge's tests, plus: reach the lead's tool server, the door, the network | `branchCodeInAMergeCanDoNoneOfIt` | the scratch team |
   | as a verifier's command: trace the verifier's agent, use its door, type into its terminal | `aVerifiersCommandCantBecomeTheVerifier` | a fake verifier |

5. **Real agents, gated.** One Sonnet worker in a box under a scratch host does a small task, reports, is audited
   and merged (SB8), with M1's test config folder. It needs the user's go-ahead per run.
6. **The lints.** A new one, `SandboxLintTests`: nothing in `VibeHost` or the executables calls `unshare`, `clone`,
   `fork`, `mount` or `pivot_root` outside `VibePlatform`; `Platform.Sandbox.enter` is called only from a launcher's
   first statements; the relays' first statements come before anything reads `VibePaths`.

## Slices, and what each costs

Costs are agent-hours of task work with its review fixes, estimated from this branch's own history: the engine's ten
tasks took 1 to 1.5 hours each with their reviews (2026-11-15 13:30 to 2026-11-16 03:25). A task here that adds C to
the shim or needs an attacker's review is counted at three to five times that. They are estimates. What would move
them most is SB0 finding that Claude Code needs something the tables don't give.

| Slice | Tasks | What is confined after it | S11 items closed | Cost |
| --- | --- | --- | --- | --- |
| **1. Files and processes** | SB0 to SB8, with SB6b | workers, and every branch run (a merge's tests, an audit's run, `init_command`, a verifier's commands) | 1 to 11, 13 (all but `ssh localhost`), 14, 15, 16, 18 (reading), 19, 20, 23 to 26, 28, 29 for workers, and the two new ones | about 40 agent-hours: 5 days of one agent's work. Its longest chain (SB1, SB3, SB5, SB7, SB8) is 22 agent-hours, so about 3 days in four worktrees, less if agents work through the night as the engine's did; then the sweep |
| **2. Network** | SB9, SB10 | the same, with a network namespace and the proxy | 18 (sending), 22, the rest of 13 and 16 | about 9 agent-hours |
| **3. The lead and the verifiers' agents** | SB11, SB12 | every team session | 3, 6, 7, 29 for a turned lead or verifier with a shell; the allow-list no longer carries anything | about 9 agent-hours |
| **4. The login leaves the box** | SB13 | — | the rest of 18: the agents' logins | about 4 agent-hours, after a gated measurement |

**The smallest first slice is slice 1.** It can't be smaller: a confined worker whose tests are then run unconfined by
a merge is no lock, so branch runs come with it (SB6); and a worker's tool server left inside needs the node's state
and the main checkout, so the door comes with it (SB4, SB5), and with the door the care the helpers outside must take
(SB6b). It leaves the lead and the verifiers' agents as they are, which is safe against a worker because they run none
of its code themselves, and leaves the worker's network open, which SB-D6 puts to the user.

## Decisions this plan makes

Numbered SB-D1 and up. Each is the plan author's recommendation. Those marked **needs the lead** or **needs the
user** aren't the author's to settle; the rest are calls, recorded as the lead's, and can be overruled before their
task starts.

1. **SB-D1: Our own shim, not bubblewrap; namespaces and seccomp, not Landlock.** *Recommended.* It is S12 item 1 and
   the design's "left to the builder". Nothing is installed, the shim is a few hundred lines of C we test, and it
   does the two things bubblewrap wouldn't: hand the door's connections and the proxy's listener out. Landlock is
   left out on this kernel because ABI 1 breaks renames between folders for the whole process (measured). Where the
   kernel has ABI 2 or later it is added as a second lock by a later task (`Platform.Sandbox.Facts.landlockABI` is
   already read). *Otherwise:* bubblewrap as a prerequisite the user installs (`sudo apt install bubblewrap`); the
   plan and the door stay, SB1 shrinks, and the node depends on a program under `/usr/bin` it must find and trust.
2. **SB-D2: The box is built by the launcher, which stays outside as the keeper.** The host never forks, and
   `unshare(CLONE_NEWPID)` puts only children in the new namespace. So the launcher keeps its pid, its POSIX session
   and the terminal (the host's `TIOCGSID` check and `holdsIdentity` hold unchanged), init is its child, and the
   program is init's. The program is the terminal's foreground group; a branch run has no terminal. The host's end
   of a session (`terminate`: SIGHUP to the groups, SIGKILL after 5 s) works as it is, since the host numbers every
   process of the box; the keeper's death ends the namespace (`PR_SET_PDEATHSIG`). *Changes S12 item 1's wording*
   ("only the session's slave passed in" stays true; the session leader is outside).
3. **SB-D3: The tool server and the hook run outside, through a door and a porter.** **Needs the lead.**
   *Recommended.* The other way, giving the box `host.sock`, `state/`, `steer/`, `lead/git-hooks/` and the main
   checkout's `board.json` and records, keeps S11 items 5, 7 and 29 open and makes every later change to the tool
   server a sandbox change. *Costs:* two hook lines each in `vibeswitcher-mcp` and `vibeswitcher-hook`, which main
   shares; a process per confined session; a hook's event crosses two sockets. *Changes:* S4 (the connector is the
   porter's), D18 and S12 items 10 and 14 (not needed for confined sessions).
4. **SB-D4: A confined session is its connector; nothing reads its pid.** S4 left two candidates and a measurement
   (whether Claude Code passes an inherited descriptor to its children). The door needs neither: any process in the
   box reaches it, and the host answers only the porter's own children. `claudePassesTheConnectorToItsToolServerAndHooks`
   is dropped; `aConnectorConnectionIsItsSession`, `branchCodeHasNoConnector` and `theConnectorSurvivesAHandover`
   keep their names (SB5, SB6).
5. **SB-D5: Worktrees stay in slice 1, with the base read-only; clones come later.** **Needs the lead.**
   *Recommended.* A worker gets exactly the git folders a Codex worker's sandbox already gets
   (`LeadLaunch.codexWritableRoots`), which closes S11 item 9 for the base, tags, config and hooks without changing
   how the lead reads a result. *Costs:* a worker can still move another `agent/` branch's ref or damage the object
   store (caught by the vault's heads and the audit; a denial of service). *Otherwise:* clones first (S12 item 3,
   rule 4's seam): about a day more before slice 1, in `Worktrees.swift` and the merge.
6. **SB-D6: In slice 1 a worker keeps the host's network; branch runs get none.** **Needs the user.**
   *Recommended*, to have the file and process locks days earlier. *Costs:* until slice 2 a worker that tries can
   still send out what it can read (its worktree, the agent's login) and reach loopback services, the Windows side's
   included. *Otherwise:* SB9 and SB10 join slice 1 (about 9 agent-hours more), and no worker runs confined before
   the proxy's list is right for Claude Code.
7. **SB-D7: Egress is a proxy mode of the host's image, serving listeners the boxes make.** Each box binds
   `127.0.0.1:3128` inside its own network namespace and hands the listener out; the proxy, outside, accepts on it
   (measured). No tap device, no relay, no root, nothing installed, and each listener is one session, so each has
   its own list. One proxy per node, started by the host from a sealed copy as parsers are, non-dumpable, restarted
   when it ends. **Needs the user:** the default list per agent (recommended: the agent's API host and what SB0's
   log shows it needs to stay logged in; telemetry and updates off).
8. **SB-D8: The agent's login is read-only inside until slice 4.** **Needs the user.** *Recommended.* *Costs:* a
   worker can read the user's Claude login until then (S11 item 18's "agents' logins"), and if Claude Code must
   rewrite the file during a long session, SB0 says so and the file becomes the one `rw` entry of the config folder.
   *Otherwise:* slice 4 first, which waits on a measurement nobody has made (whether Claude Code works with the
   login held by the proxy).
9. **SB-D9: The agent's config inside is a folder of the session's own, with named read-only entries.** **Needs the
   user** for one consequence: user-scope tool servers and other projects' entries are left out of the seeded
   `~/.claude.json`, so a confined role runs only the node's tool server. *Recommended:* yes; they would have
   neither their credentials nor their network there. *Otherwise* (an overlay over the whole folder): simpler, and
   every entry Claude Code adds in a later version is visible to every worker until someone hides it.
10. **SB-D10: Nested user namespaces are allowed inside a box when the project says so.** VibeSwitcher's own tests
    build boxes, a verifier's command gets one (SB11), and a browser's sandbox uses one. The project's guarded
    `sandbox_nesting` (default off; on for the bootstrap clone) lifts the filter's refusal of `CLONE_NEWUSER` and
    the mount calls. A nested namespace gains nothing over the box: the mounts it inherits are locked together
    (measured: a cover can't be lifted from one) and its capabilities end at its own namespace. *Costs:* more
    kernel surface where it is on.
11. **SB-D11: A verifier's command runs in a box inside the verifier's, made by the prefix program.** From slice 3.
    The door is covered, the process namespace is new, the terminal is left behind. *Otherwise:* a sibling box the
    host makes for each command, which puts a spawn per command, its signals and its exit status into the host.
    Until slice 3 the verifier's agent is plain and its prefix makes an ordinary branch run's box (SB6).
12. **SB-D12: The lead's checkout is `private` to the lead.** It reads the real files; what it writes (a build it
    tries) goes to its own layer. Everything the lead changes for real goes through its tool server, outside.
13. **SB-D13: No resource limits in slice 1.** The controllers are root's here (measured). A box's process, memory
    and disk use are bounded only by `oom_score_adj` and the session's end. Where the delegated tree has
    controllers, a later task puts each box in a cgroup of its own with `pids.max` and `memory.high`. S11 item 25
    keeps its exhaustion half.
14. **SB-D14: The heavy-work slots get a folder of their own on Linux.** **Needs the lead** (a shared file).
    Today the slots' lock files and every session's TMPDIR share `/tmp/vibeswitcher-<uid>`, so sharing the slots
    would share the TMPDIRs. On Linux `TestLock.standard` and `vs-heavy`'s default move to
    `/tmp/vibeswitcher-<uid>/slots` (a platform answer and one line of the script), bound `rw` into every box.
    *Costs:* a hostile worker can hold every slot or write a misleading note (a denial of service, shown by
    `status`); notes name pids of the box's own numbering. *Later:* slots asked for through the door.
15. **SB-D15: The hosted Linux runner is told to allow user namespaces.** **Needs the user** (`.github/**` is a
    sensitive path). GitHub's Ubuntu 24.04 image refuses them through AppArmor (`SocketsTests.noPidNamespace`
    already skips there). *Recommended:* one step in `v2-linux.yml`, `sudo sysctl -w
    kernel.apparmor_restrict_unprivileged_userns=0`, so the shim's and the attack's tests gate every push.
    *Otherwise:* they skip there, saying why, and only this machine runs them.
16. **SB-D16: The project's settings for its boxes are guarded keys of `workflow.md`.** **Needs the user** for the
    opt-out. `sandbox_read`, `sandbox_private`, `sandbox_hosts`, `sandbox_run_hosts`, `sandbox_nesting`, and
    `sandbox: off`, which the design's risks table asks for ("a project can run unconfined, and says so on every
    card"). They join `LeadVault.guardedKeys`, so a worker's edit of `workflow.md` changes nothing until the user
    accepts it. A path under a hidden folder (`.ssh`, `.gnupg`, `.config`, `.vibeswitcher`, another project) is
    refused whatever the key.
17. **SB-D17: When it is built.** **Needs the lead.** *Recommended:* SB0, SB1, SB2, SB4 and SB9 start now, beside
    the bootstrap's step 10: they are new files, and touch nothing step 8's or step 10's work touches. SB3, SB5 and
    SB6, which put hook lines into shared files, start once `v2-step8` is in `v2`. Slice 1 joins `v2` after the
    bootstrap's first merge, as the lead's first backlog item, or before it if the lead would rather have the first
    team confined.
18. **SB-D18: A node that can't build a box says so and runs plain.** `start` and `status` say which roles are
    confined ("confined: workers, branch code; plain: lead, verifiers" during slices 1 and 2). A kernel that refuses
    user namespaces (a hardened host, some containers, Ubuntu 24.04 bare metal without the profile) gives plain
    mode, with S11's list in full, as today. Never silently.
19. **SB-D19: A role can't ask to be unconfined.** The host decides from the role in the request's `helper` and the
    node's facts. The vault binds the worker role only to a session the host confined, where the node confines
    workers (one hook in the host's `.vault` case). The app (the engine starting a lead, the user's own sessions)
    may still start a plain session.

## Review Focus

1. **Nothing is inside that the plan doesn't name.** The root starts empty; every source is in `SandboxPlanner`'s
   output; the planner refuses a source under `~/.vibeswitcher` (but the two build folders and the installed hook),
   `/run`, `/mnt`, `/init` and the hidden home folders for every role and every project setting. A new visible path
   is a planner change with a test.
2. **Nothing a box can reach holds a right.** Init reads nothing from the door and holds only the door line; it is
   non-dumpable and its image is unreadable. The porter takes the role, root and task from the host. The connector
   answers only the porter's non-dumpable children. A branch run has no door.
3. **It fails closed**, at every step of entering a plan, and a role the node confines never starts plain.
4. **The host stays small.** It makes a socket pair, starts a porter, passes a plan by descriptor and ends a box
   with its session. It parses nothing a box wrote. It never forks.
5. **The program holds three descriptors**, no capability, `no_new_privs`, the filter, and a uid that is the user's
   own (so files it writes in its worktree are the user's).
6. **Tests can't hurt the machine.** Real paths are only looked at; every write, signal, trace and send has a decoy;
   no Windows program runs; no test confines the user's node.
7. **The Mac doesn't change**, and each shared-file edit is in [Non-seam edits](#non-seam-edits-this-plan-makes)
   with a Mac test.
8. **The helpers outside are no deputies.** Nothing is run outside in a folder a box can write, and no link a box
   made is followed out of its folders (SB6b). A new tool that reads a worktree goes through `BoxPath`.
9. **What stays open is said**, by `status` and in S11: the roles not yet confined, the worker's network in slice 1,
   the login until slice 4, exhaustion, text.

## Module structure

```
Sources/CVibePlatform/
  include/CVibePlatform_sandbox.h   SB1  the plan as C sees it; vibe_sandbox_enter; the facts' probes
  shim_sandbox.c                    SB1  namespaces, maps, mounts, pivot, the keeper, init, the door's listener
  shim_seccomp.c                    SB1  the filter, as classic BPF
Sources/VibePlatform/
  Sandbox.swift                     SB1  Platform.Sandbox: Plan, Mount, Network, Facts (both systems; Step 1)
  Sandbox+Linux.swift               SB1  probe(), enter(…)
  Sandbox+Darwin.swift              SB1  unavailable; enter returns a Failure of ENOTSUP
Sources/VibeCore/V2/Sandbox/
  SandboxRole.swift                 SB2  worker, verifier, lead, branchRun
  SandboxPolicy.swift               SB2  the project's guarded keys, and what they may not name
  SandboxPlanner.swift              SB2  inputs → Platform.Sandbox.Plan
  ClaudeFiles.swift                 SB2  the agent's read-only and own entries; the seeded config
  GitRoots.swift                    SB2  a worktree's git folders, read from files, never by running git
  BranchRun.swift                   SB6  a branch run's command through the shim
  BoxPath.swift                     SB6b opening a path beneath a folder a box writes, no link followed out
  EgressRules.swift                 SB9  which host a list lets through, and what no list does
Sources/VibeCore/V2/Door/
  DoorProtocol.swift                SB4  the path, the variable, the one line, the modes
  DoorRelay.swift                   SB4  the relay inside
  Porter.swift                      SB4  the porter outside
  HookCaller.swift                  SB4  whose event a hook's helper handles
Sources/VibeHost/V2/
  SessionSandbox.swift              SB3  the launcher's flags; reading the plan; entering it
  SessionConfinement.swift          SB5  who is confined; inputs from a spawn; the session's folder
  SessionConnector.swift            SB5  a session's connector, answered for its porter's children
  PorterChild.swift                 SB5  the porter: started, ended, carried across a handover
  EgressProxy.swift                 SB9  the --egress-proxy mode
  EgressChild.swift                 SB9  the proxy: started, restarted, given each box's listener
```

`Package.swift` doesn't change.

## Non-seam edits this plan makes

| File | What | Kind | Task |
| --- | --- | --- | --- |
| `Sources/CVibePlatform/include/CVibePlatform.h` | one `#include "CVibePlatform_sandbox.h"` | 4 | SB1 |
| `Sources/VibeHost/PTYSpawn.swift`, `execIfLaunched` | one hook after `beforeProgram()`: `SessionSandbox.enterIfAsked(&program)` (returns only for a plain session or a failure) | 4 | SB3 |
| `Sources/VibeHost/PTYSpawn.swift`, `spawn` | one hook: `SessionSandbox.launching(sandbox)` adds its flags and its kept descriptors | 4 | SB3 |
| `Sources/VibeHost/HostedSession.swift`, `spawn` | an argument `sandbox: SessionSandbox.Launch? = nil`, passed on | 5 | SB3 |
| `Sources/VibeHost/HostServer.swift`, `Config` | `confinement: SessionConfinement? = nil` | 5 | SB5 |
| `Sources/VibeHost/HostServer.swift`, the `.spawn` handler | one hook before `HostedSession.spawn`: `SessionConfinement.launch(for:caller:id:)`, a refusal answered as the allow-list's is | 4 | SB5 |
| `Sources/VibeHost/HostServer.swift`, where a session is removed | one hook: `SessionConfinement.ended(id)` (the porter, the connector, the folder) | 4 | SB5 |
| `Sources/VibeHost/HostServer.swift`, `identify` | one hook: a connection made on a session's connector is that session's (as `AppConnector`'s is the app's) | 4 | SB5 |
| `Sources/VibeCore/HostProtocol.swift`, `SpawnRequest` | `helper: SessionHelper?` (role, root, task) | 6 | SB5 |
| `Sources/VibeCore/HostProtocol.swift`, `HostNotes` | `confined: [String]?`, the roles the host confines | 6 | SB5 |
| `Sources/VibeHost/HostHandover.swift`, the state | an optional list of porters and connectors (pid, start ticks, descriptor, session) | 6 | SB5 |
| `Sources/VibeCore/LeadToolset.swift`, `launch` | one hook: the spawn's `helper` from the role, root and task it already has | 4 | SB5 |
| `Sources/VibeHost/HostServer.swift`, the `.vault` case | one hook before the vault answers a `bind`: `SessionConfinement.bindRefusal` (SB-D19). If the book has no reader for a grant's role, the executor stops and asks | 4 | SB5 |
| `Sources/vibeswitcher-host/main.swift` | one hook: `config.confinement = SessionConfinement.forNode(…)`; one first-statement hook: `EgressProxy.runIfAsked(arguments)` | 4 | SB5, SB9 |
| `Sources/vibeswitcher-mcp/main.swift` | three first-statement hooks, before anything reads a path: `BranchRun.execIfLaunched`, `DoorRelay.runIfConfined`, `Porter.runIfAsked` | 4 | SB4, SB6 |
| `Sources/vibeswitcher-hook/main.swift` | one first-statement hook, `DoorRelay.runIfConfined`; `HookCaller.pid(arguments)` in place of `getpid()` in the lineage | 4 | SB4 |
| `Sources/VibeCore/Worktrees.swift`, where `BranchCode.wrapper` is run (`Shell.run(branchCode:)`, `runPrefix`) | one hook each: `BranchRun.command(…)` wraps the wrapper | 4 | SB6 |
| `Sources/VibeCore/LeadToolset.swift`, where a worktree's file is opened (`report`'s evidence and load script; the list is SB6b Step 1's) | one hook each: `BoxPath.open(_:beneath:)` | 4 | SB6b |
| `Sources/vibeswitcher-hook/main.swift`, where `GitMoves.steps(for:)` is asked | one hook: `HookCaller.steps(arguments) ?? GitMoves.steps(for: payload)`, so a helper given the relay's reading runs no git | 4 | SB6b |
| `Sources/VibeCore/TestLock.swift`, `standard`; `Resources/bin/vs-heavy`, its default folder | the slots' folder is `Platform.Tools.heavySlotFolder` (Linux: `…/slots`; the Mac: today's) | lead-approved (SB-D14) | SB5 |
| `Sources/VibeCore/LeadVaultGuarded.swift`, `guardedKeys` and `guardedValue` | the six `sandbox*` keys, read by `SandboxPolicy` | lead-approved (SB-D16) | SB2 |

---

### Task SB0: What the box must give, measured

**Needs:** nothing. **Worktree:** `sb-measure`.

**Files:**
- Create: `Tests/Fixtures/sandbox/prototype.sh` (a throwaway box from `unshare(1)`, over scratch folders it is
  given; nothing in the product runs it), `Tests/VibeNodeTests/SandboxPrototypeTests.swift`,
  `Tests/VibeNodeTests/RealClaudeSandboxTests.swift` (gated)
- Modify: `docs/process/v2-linux-inventory.md` (a section, "The session sandbox, measured": this plan's table, then
  this task's results)

**Interfaces:**
- Consumes: `ScratchNode`, `FakeClaude`, `RealClaudeTests`' gate (`VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR`).
- Produces: for SB2, the final lists of `ClaudeFiles` and the default egress hosts; for SB3, how Claude Code takes a
  terminal with no name.

- [ ] **Step 1: The prototype.** `prototype.sh HOME WORKTREE CONFIG -- COMMAND…` builds the worker's box of the
  tables above by hand: scratch home, config folder as `ClaudeFiles` proposes, a devpts of its own, no network
  namespace. It refuses a `HOME` that is the account's. `SandboxPrototypeTests.thePrototypeRefusesTheAccountsHome`.
- [ ] **Step 2: Ungated measurements**, each recorded in the inventory with its command and output: `swift build`
  of a small package and one `scripts/test.sh --filter` suite inside (what SwiftPM writes under `~/.cache` and
  `~/.swiftpm`; whether `private` caches spare the network); git in a worktree with the read-only common folder
  (commit, `git status`, `git log`, a rebase; `gc.auto=0`); `vs-heavy` with the slots' folder; `/sys` mounted
  read-only in an own network namespace or not; `RLIMIT_NPROC` set before the user namespace is made, as a process
  limit for the box (kernel 5.14's per-namespace counts).
- [ ] **Step 3: Gated, with the user's go-ahead.** `RealClaudeSandboxTests.aRealClaudeTurnRunsInThePrototype`: a
  copy of M1's test config folder (never the folder itself), Claude Code started in the prototype on Sonnet, one
  turn that runs `touch made-in-the-box` with Bash. Recorded: every entry of the config folder whose inode or
  change time moved, and any write it was refused; whether `.credentials.json` was written; the hosts it asked a
  logging stand-in proxy for; whether the TUI drew and took input on a terminal with no name; whether the seeded
  trust entry spared the trust question; the hook's events through a stand-in door.
- [ ] **Step 4:** The lists in this plan's tables are corrected to what was found, in the commit that records it.

### Task SB1: The shim, `Platform.Sandbox`

**Needs:** nothing. **Worktree:** `sb-shim`. Step 1 is pushed alone, first, so SB2 and SB4 can start.

**Files:**
- Create: `Sources/VibePlatform/Sandbox.swift`, `Sandbox+Linux.swift`, `Sandbox+Darwin.swift`;
  `Sources/CVibePlatform/include/CVibePlatform_sandbox.h`, `shim_sandbox.c`, `shim_seccomp.c`;
  `Tests/VibePlatformTests/SandboxShimTests.swift`, `SandboxSeccompTests.swift`, `SandboxFactsTests.swift`,
  `SandboxLintTests.swift`
- Modify: `Sources/CVibePlatform/include/CVibePlatform.h` (one include)

**Interfaces:**
- Produces, in `extension Platform`:
  - `public enum Sandbox`:
    - `struct Facts: Equatable, Sendable { userNamespaces: Bool; overlay: Bool; landlockABI: Int; vsock: Bool;
      why: String? }` and `static func probe() -> Facts` (made once, in a child `Platform.Spawn` starts: it never
      unshares this process). The Mac: all false, `why` "macOS".
    - `struct Mount: Codable, Equatable, Sendable { target: String; kind: Kind }` with `enum Kind { readOnly(source);
      readWrite(source); overlay(lower, upper, work); empty(mode: mode_t); proc; devpts; sysfs; device(String);
      link(to: String); file(contents: Data, mode: mode_t) }`. Every mount is `nosuid` and `nodev`.
    - `enum Network: Codable, Equatable { shared; none; proxied(port: UInt16) }`.
    - `struct Plan: Codable, Equatable, Sendable { mounts: [Mount]; network: Network; hostname: String;
      directory: String; environment: [String]; door: String?; terminal: Terminal; nesting: Bool }`, with `enum
      Terminal { foreground; none }`.
    - `struct Failure: Error, Equatable { step: String; code: Int32 }` and `static func enter(_ plan: Plan,
      doorLine: Int32?, proxyOut: Int32?, program: [String]) -> Failure`: called by a single-threaded process as its
      last act. It returns only when nothing was started, naming the step that failed.
- The order inside, which the review checks line by line:
  1. dumpable (the uid map can't be written otherwise: measured); `unshare` of the user, mount, pid, ipc, uts and
     cgroup namespaces, and the network one unless `shared`; `setgroups` `deny`; the uid and gid maps, each the
     user's own id to itself.
  2. `fork`. The parent is the keeper: it closes everything but its terminal, waits, passes SIGHUP, SIGTERM and
     SIGINT on, and exits as its child did (the same status, or the same signal raised on itself).
  3. The child is init: `PR_SET_PDEATHSIG(SIGKILL)`; the mount tree made private; an empty tmpfs root; the plan's
     mounts in order, a read-only remount keeping the flags the source's mount locks; `pivot_root`; the old root
     detached; the hostname; loopback up; the door bound and listening; the proxy's listener bound and sent to
     `proxyOut`; non-dumpable again.
  4. `fork`. The child is the program: its own process group and the terminal's foreground, or `setsid` for
     `Terminal.none`; every capability dropped from every set and the bounding set; `no_new_privs`; the filter;
     `close_range` from 3; `execve`.
  5. Init then loops: a door connection is sent whole to `doorLine` and closed; children are reaped; when the
     program ends, init exits as it did, and the kernel ends the rest.
- The filter (`shim_seccomp.c`): allow by default; `EPERM` for `socket` with a family other than `AF_UNIX`,
  `AF_INET`, `AF_INET6` or `AF_NETLINK` with a protocol other than `NETLINK_ROUTE`; for `bpf`, `perf_event_open`,
  `userfaultfd`, `add_key`, `request_key`, `keyctl`, `kexec_load`, `kexec_file_load`, `init_module`,
  `finit_module`, `delete_module`, `swapon`, `swapoff`, `open_by_handle_at`, `ioctl` with `TIOCSTI`; and, without
  `nesting`, for `unshare` and `clone` with `CLONE_NEWUSER`, `mount`, `umount2`, `pivot_root`, `fsopen`, `fsconfig`,
  `fsmount`, `move_mount`, `open_tree`, `mount_setattr`, `setns`. `clone3` answers `ENOSYS` without `nesting`, so
  the C library falls back to `clone`, whose flags the filter can read. An architecture other than the build's is
  killed.

- [ ] **Step 1: The types**, with `SandboxPlanCodingTests.aPlanSurvivesItsCoding` and `theMacHasNoSandbox`. Pushed.
- [ ] **Step 2: Failing tests.** `SandboxShimTests`, each through the test binary's helper mode over scratch
  folders, skipped with its reason where `probe()` says no:
  - `theProgramSeesOnlyWhatThePlanMounts`
  - `aReadOnlyMountRefusesWritesAndKeepsItsLockedFlags`
  - `aPrivateMountKeepsWritesOutOfTheRealFolder`
  - `theProgramIsTheUsersUidWithNoCapabilityAndNoNewPrivileges`
  - `theProgramSeesOnlyItsOwnProcesses`
  - `everyProcessEndsWithTheProgram` (a double fork with `setsid` and `nohup` is gone)
  - `aKilledKeeperEndsTheNamespace`
  - `theProgramsExitStatusAndItsSignalComeThrough`
  - `theProgramHoldsNoDescriptorButItsThree`
  - `initIsNotDumpableAndCantBeTracedOrReadFromInside`
  - `aPlanThatCantBeAppliedStartsNothingAndSaysWhich`
  - `aProcessWithThreadsIsRefused`
  - `theDoorHandsEachConnectionToItsLine`
  - `aListenerMadeInsideIsServedFromOutside`
  - `theProgramIsItsTerminalsForegroundGroupAndTheKeeperItsLeader`
  - `aRunWithNoTerminalHasNone`
  - `anEmptyNetworkHasLoopbackAndNothingElse`
- [ ] **Step 3:** `SandboxSeccompTests`: `hyperVPacketAndNetfilterSocketsAreRefused`,
  `bpfPerfUserfaultfdAndTheKeyringsAreRefused`, `typingIntoTheTerminalByIoctlIsRefused`,
  `aNestedUserNamespaceIsRefusedUnlessThePlanAllowsIt`, `aThreadedProgramAndAShellPipelineStillRun`,
  `tracingAProcessOfTheBoxIsAllowed`.
- [ ] **Step 4:** `SandboxFactsTests`, which keep this plan's measurements true or say what changed:
  `landlocksAbiIsReadFromTheKernel`, `aLandlockedProcessCantRenameAcrossFoldersBeforeAbi2`,
  `hyperVSocketsIgnoreTheNetworkNamespace`, `aNonDumpableProcessCantWriteItsOwnUidMap`,
  `aTerminalMadeOutsideHasNoNameInsideButStaysATerminal`, `aWindowsStubDoesntStartWithoutInit`.
- [ ] **Step 5:** The implementation, in the order above.
- [ ] **Step 6:** `SandboxLintTests.onlyThePlatformCallsTheNamespaceAndMountCalls`,
  `enterIsCalledOnlyFromALaunchersFirstStatements`. Lints, then the suite under load.

### Task SB2: The planner: what each role sees

**Needs:** SB1 Step 1. **Worktree:** `sb-plan`.

**Files:**
- Create: `Sources/VibeCore/V2/Sandbox/SandboxRole.swift`, `SandboxPolicy.swift`, `SandboxPlanner.swift`,
  `ClaudeFiles.swift`, `GitRoots.swift`; `Tests/VibeCoreTests/SandboxPlannerTests.swift`, `SandboxPolicyTests.swift`
- Modify: `Sources/VibeCore/LeadVaultGuarded.swift` (the six keys; SB-D16)

**Interfaces:**
- Consumes: `Platform.Sandbox.Plan`; `ProjectAllowList`'s way of reading a worktree's `.git` file and `commondir`
  from files.
- Produces:
  - `public enum SandboxRole: String, Codable, Sendable { worker, verifier, lead, branchRun }`.
  - `public struct SandboxPolicy: Codable, Equatable, Sendable { enabled: Bool; read: [String]; privateFolders:
    [String]; hosts: [String]; runHosts: [String]; nesting: Bool }`, `static func read(_ workflow: LeadWorkflow) ->
    Result<SandboxPolicy, SandboxRefusal>`, `static let hidden: [String]` (the home folders no key may name).
  - `public struct SandboxInputs: Equatable, Sendable { role; home; uid; gid; root; worktree; temporary; build;
    pathFolders: [String]; agentProgram: String?; box: String; policy: SandboxPolicy; network:
    Platform.Sandbox.Network; slots: String? }`.
  - `public enum SandboxPlanner { static func plan(_ inputs: SandboxInputs) -> Result<Platform.Sandbox.Plan,
    SandboxRefusal> }`: pure, the same plan for the same inputs.
  - `public enum GitRoots { static func read(worktree: String) -> Result<(common: String, own: String, slug:
    String), SandboxRefusal> }`: from files only; a `.git` file that names a folder outside its repository's
    `worktrees/` is refused.
  - `public enum ClaudeFiles { static let readOnlyEntries: [String]; static let ownEntries: [String]; static func
    projectFolder(cwd: String) -> String; static func seededConfig(from: Data, cwd: String) -> Data }`.
  - `public struct SandboxRefusal: Error, Equatable, CustomStringConvertible`.

- [ ] **Step 1: Failing tests** (`SandboxPlannerTests`, on both systems):
  - `aWorkerWritesItsWorktreeItsGitFolderTheObjectsAndTheAgentRefsOnly`
  - `theBasesRefTheConfigTheHooksAndTheTagsAreReadOnlyToAWorker`
  - `aWorktreesGitFileAndItsFoldersPointersAreReadOnly`
  - `nothingOfTheHomeIsASourceThatThePlanDoesntName` (over every role and a table of policies)
  - `theNodesFolderIsNeverASourceButForItsBuildAndTheHook`
  - `theRuntimeFolderTheJournalInteropAndTheWindowsDrivesAreNeverASource`
  - `everyUserWritableFolderOnThePathIsReadOnly`
  - `theAgentsConfigIsTheSessionsOwnWithNamedReadOnlyEntries`
  - `theSeededConfigHasThisFoldersEntryAndNoToolServers`
  - `aBranchRunHasNoDoorNoTerminalNoAgentAndNoNetwork`
  - `aLeadReadsItsCheckoutPrivatelyAndWritesNoWorktree`
  - `aVerifierIsNeverGivenTheWorkersWorktree`
  - `aWorktreeWhoseGitFileLeavesItsRepositoryIsRefused`
  - `theSameInputsGiveTheSamePlan`
- [ ] **Step 2:** `SandboxPolicyTests`: `aPathUnderAHiddenFolderIsRefusedNamingIt`,
  `aLinkIsResolvedBeforeItIsJudged`, `aRelativeOrHomelessPathIsRefused`, `aHostWithASchemeAPathOrAnAddressIsRefused`,
  `theSandboxKeysAreGuarded` (a changed key is held until accepted, as `test_command` is).
- [ ] **Step 3:** Implementation. `ClaudeFiles`' lists come from SB0 Step 4; until then, from this plan's table.

### Task SB3: The launcher builds the box

**Needs:** SB1, SB2; `v2-step8` merged into `v2`. **Worktree:** `sb-launch`.

**Files:**
- Create: `Sources/VibeHost/V2/SessionSandbox.swift`; `Tests/VibeHostTests/SessionSandboxTests.swift`
- Modify: `Sources/VibeHost/PTYSpawn.swift` (two hooks), `Sources/VibeHost/HostedSession.swift` (one argument)

**Interfaces:**
- Produces:
  - `enum SessionSandbox`: `static let planFlag = "--pty-sandbox"`, `doorLineFlag = "--pty-door-line"`,
    `proxyFlag = "--pty-proxy-out"`, each followed by a descriptor's number, after `--pty-exec` and before the
    program, where `SessionIdentityChecks.launcherFlags` already go.
  - `struct Launch { plan: Platform.Sandbox.Plan; doorLine: Int32?; proxyOut: Int32? }`.
  - `static func launching(_ launch: Launch?) -> (flags: [String], keep: [Int32], close: [Int32])`: the plan
    written to a sealed memory file (`Platform.ProcessSelf`'s), its number in the flags.
  - `static func enterIfAsked(_ program: inout [String])`: the launcher's side. With no flag it returns at once.
    Otherwise it reads the plan, calls `Platform.Sandbox.enter`, and on a failure writes "VibeSwitcher: this
    session's sandbox couldn't be built: <step>" to the terminal and exits 127.
- `takeTerminal` and `beforeProgram` are unchanged and run first: the launcher is the terminal's leader and is
  dumpable before it unshares.

- [ ] **Step 1: Failing tests** (`TestHost`, `/bin/sh` sessions, a plan over the test's scratch folders):
  - `aConfinedSessionsScreenInputResizeAndExitAreAsBefore`
  - `aConfinedSessionHoldsItsIdentityWhileItsKeeperLeadsItsTerminal`
  - `endingAConfinedSessionEndsEveryProcessInIt`
  - `aProcessThatLeftTheProgramsTreeInsideDiesWithIt`
  - `aConfinedSessionSurvivesAHandover`
  - `thePlanTravelsInSealedMemoryAndNoArgumentNamesAPath`
  - `aLauncherThatCantBuildItsBoxExits127AndSaysWhy`
  - `aConfinedProgramIsStillTheOOMKillersFirstPick`
  - `aSessionWithNoPlanStartsAsBefore`, and on the Mac `theMacStartsNoBox`
- [ ] **Step 2:** Implementation. The two hooks and the argument go into the port map's Non-seam edits.
- [ ] **Step 3:** `HostHardeningTests.aSessionsProgramHoldsNoImageDescriptor` and
  `HostedSessionTerminalTests` pass unchanged for a confined session (run again with a plan, as parameterised cases).

### Task SB4: The door: relays inside, the porter outside

**Needs:** SB1 Step 1 (the door's path and line are constants). It runs beside SB1 to SB3 on a socket pair that
stands for the door line. **Worktree:** `sb-door`.

**Files:**
- Create: `Sources/VibeCore/V2/Door/DoorProtocol.swift`, `DoorRelay.swift`, `Porter.swift`, `HookCaller.swift`;
  `Tests/VibeNodeTests/DoorTests.swift`, `PorterTests.swift`, `MCPLintTests.swift`;
  `Tests/VibeCoreTests/DoorProtocolTests.swift`
- Modify: `Sources/vibeswitcher-mcp/main.swift` (two first-statement hooks), `Sources/vibeswitcher-hook/main.swift`
  (one first-statement hook; the lineage's pid)

**Interfaces:**
- Consumes: `HostConnection.register(connector:for:)` and `HostConnector.connect(over:timeout:)`
  (`V2/HostConnector.swift`), `Platform.Spawn`, `Platform.ProcessSelf.SealedCopy`.
- Produces:
  - `enum DoorProtocol`: `static let path = "/run/vibeswitcher/door"`, `variable = "VIBESWITCHER_DOOR"`,
    `maxHello = 64 << 10`; `enum Mode: String, Codable { mcp, hook, statusLine, permission }`; `struct Hello:
    Codable, Equatable { v: Int; mode: Mode; args: [String] }`; `static func exitLine(_ status: Int32) -> String`.
  - `enum DoorRelay { static func runIfConfined(_ mode: (arguments: [String]) -> DoorProtocol.Mode?, arguments:
    [String], environment: [String: String]) }`: with no door variable it returns. Otherwise it never does: it
    connects, sends the line with descriptors 0, 1 and 2, waits, exits with the answered status; 69 with a reason on
    stderr when the door refuses or isn't there.
  - `struct SessionHelper: Codable, Equatable, Sendable { role: String; root: String; task: String? }` (also
    `SpawnRequest.helper`, SB5).
  - `enum Porter`: `static let flag = "--porter"`; arguments `--session ID --role R --root ROOT [--task T]
    --door-line N --host-connector M --host-socket PATH --tool-server-image A --hook-image B`;
    `static func runIfAsked(_ arguments: [String])`; `static func allowed(_ hello: DoorProtocol.Hello, for helper:
    SessionHelper) -> String?` (pure: nil, or why not); `static func command(_ hello:, helper:, caller: pid_t) ->
    [String]` (pure: the helper's arguments, none of them from `hello.args` but a hook's agent name out of a fixed
    set).
  - `enum HookCaller { static func pid(_ arguments: [String]) -> pid_t }`: `--for-pid P`, else `getpid()`.
- The porter's first statements are the server's (`PlatformLintTests`' order): close the inherited image, harden,
  exit if traced, mark its descriptors.

- [x] **Step 1: Failing tests.** `DoorProtocolTests` (pure): `aHelloSurvivesItsCoding`,
  `anOversizedOrMalformedHelloIsRefused`. `PorterTests`:
  - `nothingFromInsideChoosesTheRoleTheRootOrTheTask`
  - `aModeItsRoleDoesntHaveIsRefused`
  - `onlyThreeDescriptorsAreTakenAndAFourthIsClosed`
  - `theHelpersAreStartedFromSealedCopiesAndAreNotDumpable`
  - `aHelperThatOutlivesItsRelayIsEnded`
  - `thePorterEndsWhenItsDoorLineCloses`
  - `aHelperThatDiedIsStartedAgainAtTheNextConnection`
- [x] **Step 2:** `DoorTests` (the built `vibeswitcher-mcp` and `vibeswitcher-hook`, `FakeClaude`, a scratch host):
  - `aToolCallMadeInsideIsAnsweredByTheToolServerOutside`
  - `aHooksEventWritesTheStateFileOfItsSessionsTerminal`
  - `aHooksOutputAndExitStatusComeBack`
  - `aHookThroughTheDoorAnswersWithinItsThreeSeconds` (the added time is recorded in the inventory)
  - `aSteerMessageIsDeliveredThroughTheDoor`
  - `theStatusLineAndThePermissionHookWorkThroughTheDoor`
  - `withNoDoorTheToolServerAndTheHookRunAsBefore`, and on the Mac `theMacsToolServerNeverRelays`
- [x] **Step 3:** `MCPLintTests.theRelayAndThePorterComeBeforeAnythingReadsAPath` (the hooks' place in both mains).
- [x] **Step 4:** Implementation.

**As built (2026-11-17, `v2-sandbox-b`):** a helper the porter starts finds its session's connector in
`VIBESWITCHER_SESSION_CONNECTOR` and `VIBESWITCHER_SESSION_HOST_SOCKET`, which `DoorRelay.runIfConfined` registers
first thing (so the hook's main needs no second hook). The hook's helper is given `--for-pid P --caller-socket N`, `N`
the door connection kept open in it: `HookCaller.pid` takes `P` only when `N`'s peer is `P`, so a plain process can't
name another session's agent (`PorterTests.aHookTakesItsRelaysPidOnlyFromItsConnection`). A confined status line
always runs with `--user-settings-only` (a project's settings are in a folder the box writes). A verifier has no
permission hook through the door until `SessionHelper` carries its audit checkout (SB11). A porter serves at most
`Porter.maxConnections` connections at once, each line within `Porter.helloPatience`. Added tests:
`PorterTests.aBoxCantHoldMoreThanItsShareOfRequests`, `aHookTakesItsRelaysPidOnlyFromItsConnection`,
`DoorTests.theHelpersReachTheHostOnlyThroughTheSessionsConnector`. Multi-descriptor messages are
`Platform.Sockets.send(_:with:over:)` and `receive(over:count:room:)` (`shim_descriptors.c`).

### Task SB5: The host confines what a lead starts

**Needs:** SB3, SB4. **Worktree:** `sb-host`. The only task that edits `HostServer.swift` and
`vibeswitcher-host/main.swift` in slice 1.

**Files:**
- Create: `Sources/VibeHost/V2/SessionConfinement.swift`, `SessionConnector.swift`, `PorterChild.swift`;
  `Tests/VibeHostTests/ConfinedSpawnTests.swift`, `SessionConnectorTests.swift`;
  `Tests/VibeNodeTests/ConfinedTeamTests.swift`
- Modify: `Sources/VibeHost/HostServer.swift` (a `Config` field, four hooks), `Sources/VibeCore/HostProtocol.swift`
  (two optional fields), `Sources/VibeHost/HostHandover.swift` (one optional field),
  `Sources/vibeswitcher-host/main.swift` (one hook), `Sources/VibeCore/LeadToolset.swift` (one hook),
  `Sources/VibeHost/V2/HostImages.swift` (`Loaded` gains sealed copies of the tool server's and the hook's images,
  each checked against `build-info` as the server's is), `Sources/VibeCore/TestLock.swift` and
  `Resources/bin/vs-heavy` (SB-D14), `Sources/VibeNode/Facts/NodeFacts.swift` and `NotPromised.swift` (the mode line)

**Interfaces:**
- Consumes: `AppConnector`'s `openAppConnector` and `answer` (the same exchange, a different rule for who may ask),
  `ServerChild`'s way of starting from a sealed copy and of being carried across a handover, `SandboxPlanner`,
  `HostImages.Loaded`.
- Produces:
  - `struct SessionConfinement { facts: Platform.Sandbox.Facts; roles: Set<SandboxRole>; boxes: URL; build:
    String?; images: (toolServer: Platform.ProcessSelf.SealedCopy, hook: Platform.ProcessSelf.SealedCopy) }`;
    `static func forNode(arguments:ownsLaunchers:accountHome:images:) -> SessionConfinement?` (the node's host on
    Linux where `probe()` says yes; a scratch host only with `--confine ROLES`; else nil);
    `func launch(for request: SpawnRequest, caller: LeadVault.Caller, id: UUID) -> Result<SessionSandbox.Launch?,
    SessionConfinement.Refused>` (`Refused` an `Error` with its text, answered as `ProjectAllowList.refusal`'s is);
    `func bindRefusal(_ request: LeadVault.Request, vault: LeadVault.Book?) -> String?` (SB-D19); `func ended(_ id:
    UUID)`.
  - `Platform.Tools.confinedSpawnEnvironment: Set<String>`: the names a confined spawn's `env` may carry.
  - `HostServer.Config.confinement`, `SpawnRequest.helper`, `HostNotes.confined`.
- The session's folder is made under `boxes` only, 0700, by the host, and removed when the session is.

- [ ] **Step 1: Failing tests.** `ConfinedSpawnTests`:
  - `aLeadsWorkerIsStartedInABox`
  - `aWorkerCantBeAskedForPlain`
  - `aSpawnWhoseFolderIsntAWorktreeOfItsRootIsRefused`
  - `aConfinedSpawnsEnvironmentIsAnAllowList`
  - `theWorkerRoleBindsOnlyToAConfinedSessionWhereTheNodeConfines`
  - `theSessionsFolderIsMadeUnderTheNodesAndRemovedWithIt`
  - `aNodeThatCantBuildABoxSaysSoAndStartsPlain`
  - `aScratchHostConfinesNothingUnlessTold`, and on the Mac `theMacConfinesNothing`
- [ ] **Step 2:** `SessionConnectorTests`:
  - `aConnectorConnectionIsItsSession`
  - `onlyAChildOfThePorterIsAnsweredOnItsConnector`
  - `aDumpableHelperIsRefused`
  - `anotherProcessWritingOnAHelpersConnectionMakesItNobodys`
  - `aPorterThatDiedIsStartedAgainAndItsDoorStillAnswers`
  - `theConnectorSurvivesAHandover`
  - `aConfinedSessionsConnectionsAreCountedPerSession`
- [ ] **Step 3:** `ConfinedTeamTests.aFakeTeamPlansBuildsReportsAndMergesWithItsWorkerConfined` (the engine's E9
  Step 1 scenario, the worker in a box), `NodeFactsTests.statusSaysWhichRolesAreConfined`,
  `StartCommandTests.theNotPromisedListSaysWhatIsClosedForWhom`, `TestLockTests.theSlotsHaveAFolderOfTheirOwnOnLinux`.
- [ ] **Step 4:** Implementation; the port map's rows.

### Task SB6: Branch code runs in a box of its own

**Needs:** SB1, SB2; `v2-step8` merged into `v2`. It runs beside SB3 to SB5. **Worktree:** `sb-runs`. The only task
that edits `Worktrees.swift`.

**Files:**
- Create: `Sources/VibeCore/V2/Sandbox/BranchRun.swift`; `Tests/VibeCoreTests/BranchRunTests.swift`,
  `Tests/VibeNodeTests/BranchRunHostTests.swift`
- Modify: `Sources/VibeCore/Worktrees.swift` (two hooks), `Sources/VibeCore/V2/BranchCodeSession.swift` (its child is
  the box's launcher), `Sources/vibeswitcher-mcp/main.swift` (one first-statement hook)

**Interfaces:**
- Produces: `enum BranchRun`: `static let flag = "--branch-run"`; `static func command(_ wrapped: [String], cwd:
  String, home: String, policy: SandboxPolicy, server: String, facts: Platform.Sandbox.Facts) -> (executable:
  String, arguments: [String], keep: [Int32])` (where a box can't be built, and on the Mac: `wrapped` as it is);
  `static func execIfLaunched(_ arguments: [String])` (the tool server's image as a launcher: it enters the plan and
  execs `BranchCode.wrapper`'s command; it has one thread, being a fresh process).
- A branch run's plan: role `branchRun`, the scratch worktree and scratch home `rw`, the toolchain and caches as a
  worker's, `Terminal.none`, `Network.none` (or `proxied` with `runHosts`, from slice 2), no door.
- `BranchCode.isRunner` stays: the host still treats what is under a wrapper as no session's, for plain sessions.

- [ ] **Step 1: Failing tests.** `BranchRunTests`: `aBranchRunsCommandGoesThroughTheLauncher`,
  `whereNoBoxCanBeBuiltTheWrapperIsTodays`, `onTheMacBranchCodeRunsAsBefore`. `BranchRunHostTests`:
  - `aMergesTestsRunWithNoDoorNoHostSocketAndNoNetwork`
  - `anAuditsRunCantWriteTheCheckoutOrAnotherWorktree`
  - `initCommandsWritesStayInItsScratchWorktreeAndHome`
  - `aVerifiersCommandCantSeeTheVerifiersProcesses`
  - `aVerifiersCommandHasNoTerminal`
  - `branchCodeHasNoConnector`
  - `theRunsExitStatusOutputAndTimeoutAreItsCommands`
  - `anInterruptEndsEveryProcessOfARun` (Task 12b's measurement, with the box)
  - `aScriptInsideARunSeesTheSlotItsRunHolds`
- [ ] **Step 2:** Implementation; the port map's rows.

### Task SB6b: The outside trusts nothing a box wrote

**Needs:** SB4. It runs beside SB5 and SB6; its hooks in `LeadToolset.swift` land after SB5's. **Worktree:**
`sb-deputy`.

**Files:**
- Create: `Sources/VibeCore/V2/Sandbox/BoxPath.swift`; `Tests/VibeCoreTests/BoxPathTests.swift`,
  `Tests/VibeNodeTests/DeputyTests.swift`
- Modify: `Sources/VibeCore/V2/Door/DoorRelay.swift` and `HookCaller.swift` (the hook's git reading, done by the
  relay), `Sources/vibeswitcher-hook/main.swift` (one hook, after SB4's are in), `Sources/VibeCore/LeadToolset.swift`
  (the hooks Step 1 lists)

**Interfaces:**
- Produces: `enum BoxPath { static func open(_ path: String, beneath folder: String) -> Result<Int32,
  Platform.Errno>; static func read(_ path: String, beneath folder: String, limit: Int) -> Result<Data,
  Platform.Errno> }` (`openat2` with `RESOLVE_BENEATH` and `RESOLVE_NO_MAGICLINKS`; on the Mac and for a plain
  session, today's open); `HookCaller.steps(_ arguments: [String])`, the `(root, step)` pairs `GitMoves.steps(for:)`
  gives, as the relay read them inside, or nil when the helper was given none.

- [ ] **Step 1: The list.** Every place a tool server's or a hook's helper opens a path under a worktree, or runs
  a program in one, read from the code and written into the review record: at least `GitMoves.checkout(at:)`,
  `report`'s `KeptImages` and `checkLoadProof`, `Worktrees.remove`, and the records a branch carries. Each gets
  one of: done by the relay inside; opened through `BoxPath`; run in `<root>` instead.
- [ ] **Step 2: Failing tests.** `BoxPathTests`: `aLinkOutOfTheFolderIsRefused`, `aLinkInsideTheFolderIsFollowed`,
  `aPathThroughDotDotIsRefused`, `aFolderSwappedForALinkDuringTheOpenIsRefused`. `DeputyTests`:
  `aHooksGitReadingIsDoneInsideItsBox`, `noHelperRunsAProgramInAFolderItsBoxCanWrite` (a decoy `git` wrapper
  records every folder it was run in), `aRewrittenGitFileRunsNoHookAndNoConfigOutside`,
  `evidenceThatIsALinkOutOfTheWorktreeIsRefusedNamingIt`.
- [ ] **Step 3:** Implementation; the port map's rows.

### Task SB7: The attack

**Needs:** SB5, SB6, SB6b. Its fixtures (the decoys, the hostile script) are written beside SB3 to SB6, against
SB0's prototype. **Worktree:** `sb-attack`.

**Files:**
- Create: `Tests/Fixtures/hostile/worker.sh` (plain `sh` and `/usr/bin` tools), a helper mode of the test binary for
  what a shell can't do (`ptrace`, `pidfd_getfd`, `process_vm_readv`, `socket(AF_VSOCK)`, connect-and-close,
  `TIOCSTI`), `Tests/VibeNodeTests/AttackStage.swift` (the scratch home's decoys, the decoy session, the scratch
  team), `Tests/VibeNodeTests/SandboxAttackTests.swift`

- [ ] **Step 1:** `AttackStage`, and `SandboxAttackTests.everyProbeSucceedsAgainstItsDecoyWithTheBoxOff`: each
  probe run in a plain session of the scratch host reaches its decoy. A probe that fails here is fixed before it
  counts.
- [ ] **Step 2:** The tests of [How it is tested](#how-it-is-tested), item 4, all but the network's, each run from
  a confined worker's session and, where it applies, as branch code in a merge.
- [ ] **Step 3:** `SandboxAttackTests.noProbeTouchedARealPath`: the stage records every path a probe opened for
  writing, every pid it signalled or traced and every socket it sent on; all are the stage's own.
- [ ] **Step 4:** A reviewer who didn't write the box reads the plan, the shim and the porter as an attacker and
  adds probes; the record goes under `docs/process/reviews/`.

### Task SB8: Real agents, and the documents

**Needs:** SB7. **Worktree:** `sb-docs`. The only task of slice 1 that edits the security document.

**Files:**
- Modify: `Tests/VibeNodeTests/RealClaudeSandboxTests.swift`, the security document (S4, S10, S11, S12, the threats
  table, the Mac and Linux table), the design (requirement 3's "a socket it inherited"), the bootstrap path
  ("Deliberately after the bootstrap"), `docs/process/v2-linux-inventory.md`, `docs/process/v2-mac-tasks.md` (one
  line), `docs/process/v2-port-map.md`

- [ ] **Step 1: Gated, with the user's go-ahead.** `RealClaudeSandboxTests.aConfinedWorkerOnSonnetBuildsReportsAndIsMerged`:
  under a scratch host and a scratch home, a real lead (plain) starts a real worker (confined), whose change is
  audited and merged through the gate, its tests in a branch run's box.
- [ ] **Step 2:** The security document: each S11 item says what is closed for whom, by which slice; S12 items 1, 2,
  10, 14 and 17 are rewritten as built; every new test name goes under a `Held by:` line
  (`SecurityDocumentLintTests` checks them).
- [ ] **Step 3:** The sweep: a multi-lens review of slice 1, the suites under load, both jobs green on one commit.

### Task SB9: The egress proxy

**Needs:** SB1 Step 1. It runs beside all of slice 1. **Worktree:** `sb-egress`.

**Files:**
- Create: `Sources/VibeCore/V2/Sandbox/EgressRules.swift`; `Sources/VibeHost/V2/EgressProxy.swift`, `EgressChild.swift`;
  `Tests/VibeCoreTests/EgressRulesTests.swift`, `Tests/VibeHostTests/EgressProxyTests.swift`
- Modify: `Sources/vibeswitcher-host/main.swift` (one first-statement hook, after SB5's is in)

**Interfaces:**
- Produces:
  - `struct EgressRules: Codable, Equatable, Sendable { hosts: [String] }`; `func decision(host: String, port:
    UInt16, resolved: [EgressRules.Address]) -> Decision` with `enum Decision: Equatable { allow([Address]);
    refuse(String) }`; `static let neverAllowed`: the ranges and names of the Network section.
  - `enum EgressProxy`: `static let flag = "--egress-proxy"`; `static func runIfAsked(_ arguments: [String])`. It
    takes, over an inherited socket pair, messages of one listener each (`SCM_RIGHTS`) with a session's id and its
    `EgressRules`, and a message that ends a session's. It resolves and connects through a `Dialer` a test replaces.
  - `EgressChild`: started by the host from its own sealed copy, restarted as parsers are; `func add(listener:
    Int32, session: UUID, rules: EgressRules)`.
- It logs a line per refused request: the session, the host and port asked, the reason. Never a header or a byte of
  the tunnel.

- [ ] **Step 1: Failing tests.** `EgressRulesTests`: `aNameOffTheListIsRefused`,
  `loopbackTheTailnetLinkLocalAndMetadataAreRefusedWhateverTheListSays`,
  `aListedNameThatResolvesToARefusedAddressIsRefused`, `privateRangesNeedTheProjectsWord`,
  `anAddressLiteralIsRefused`, `onlyPort443UnlessTheEntryNamesAnother`, `aWildcardCoversSubdomainsAndNotTheNameItself`.
- [ ] **Step 2:** `EgressProxyTests`: `aTunnelToAListedHostCarriesBytesBothWays`,
  `aRefusedRequestGets403AndALogLineWithNoPayload`, `eachListenerHasItsOwnList`,
  `aSlowOrSilentClientHoldsUpNoOther`, `theProxyIsNotDumpableAndIsStartedAgain`,
  `plainHttpIsCarriedOnlyToAListedHost`, `aSessionsListenerIsClosedWithItsSession`.
- [ ] **Step 3:** Implementation.

### Task SB10: Boxes on their own network

**Needs:** SB5, SB9; SB-D7's list. **Worktree:** `sb-net`.

**Files:**
- Modify: `Sources/VibeHost/V2/SessionConfinement.swift` (the network kind, the listener handed to `EgressChild`),
  `Sources/VibeCore/V2/Sandbox/SandboxPlanner.swift` (the proxy variables; `NO_PROXY` empty),
  `Sources/VibeCore/V2/Sandbox/BranchRun.swift` (`runHosts`), `Tests/VibeNodeTests/SandboxAttackTests.swift`

- [ ] **Step 1: Failing tests.** `SandboxAttackTests.aWorkerCantSendToAnythingOffItsList`,
  `aWorkerCantReachLoopbackOrTheWindowsSide`, `nameLookupsInsideGoNowhere`,
  `aBranchRunWithNoListedHostHasNoNetwork`; `ConfinedSpawnTests.aConfinedAgentIsToldItsProxy`.
- [ ] **Step 2:** Gated: a real Claude turn through the proxy with the default list; the hosts refused are recorded
  and the list is settled with the user.
- [ ] **Step 3:** The security document: S11 items 13, 16, 18 and 22, S12 item 4.

### Task SB11: The lead and the verifiers' agents in boxes

**Needs:** SB5, SB6, SB10. **Worktree:** `sb-roles`.

**Files:**
- Modify: `Sources/VibeCore/V2/Sandbox/SandboxPlanner.swift` (the two roles as the tables give them),
  `Sources/VibeCore/V2/Sandbox/BranchRun.swift` (a run started from inside a box is a nested one: the door covered,
  a new process namespace, no terminal; SB-D11), `Sources/VibeHost/V2/SessionConfinement.swift` (every role),
  `Sources/VibeNode/Engine/LeadStart.swift` (the lead's spawn carries its `helper`)
- Create: `Tests/VibeNodeTests/ConfinedLeadTests.swift`, `ConfinedVerifierTests.swift`

- [ ] **Step 1: Failing tests.** `ConfinedLeadTests`: `aLeadsToolsWorkThroughItsPorter` (start a worker, merge,
  records, questions to the server), `aLeadsShellWritesNothingOfItsCheckout`,
  `aLeadsShellCantReachTheVaultButThroughItsTools`, `theLeadsBoardNamesTheAgentInsideItsBox` (the porter tells the
  helper its caller's pid). `ConfinedVerifierTests`: `aVerifiersCommandCantBecomeTheVerifier`,
  `aVerifiersVerdictStillComesFromItsToolServer`, `aVerifiersCommandRunsWithTheProjectsNestingOrIsRefusedSayingSo`.
- [ ] **Step 2:** `SandboxAttackTests.branchCodeInAMergeCanDoNoneOfIt` again, with the lead confined.
- [ ] **Step 3:** Implementation.

### Task SB12: Every team session is confined, and the node says so

**Needs:** SB11. **Worktree:** `sb-docs`.

- [ ] **Step 1:** `NodeFactsTests.statusSaysEveryTeamSessionIsConfined`; `NotPromised` prints only what stays.
- [ ] **Step 2:** The security document's S11 and S12 for slice 3; the design's stage 2 Done-when, second half
  (S12 item 9), is held by `aConfinedSessionCantReadAnotherSessionsScreenTheNodesStateOrTheHostsMemory`.
- [ ] **Step 3:** The sweep, as SB8 Step 3.

### Task SB13: The login leaves the box

**Needs:** SB10; a gated measurement first. **Worktree:** `sb-login`.

- [ ] **Step 1: Gated measurement.** Whether Claude Code, started with its API's base address pointed at a
  plain-HTTP listener of the proxy and a placeholder token, works when the proxy adds the account's real
  authorization and speaks TLS to the API itself. Recorded in the inventory. If it doesn't, this task stops, and S11
  item 18 keeps "the agents' logins, read-only to confined sessions".
- [ ] **Step 2:** `EgressProxyTests.theAccountsAuthorizationIsAddedOutsideAndAnyOtherIsReplaced`,
  `SandboxPlannerTests.noLoginIsMountedOnceTheProxyHoldsIt`,
  `SandboxAttackTests.aWorkerCantReadTheAgentsLoginOrUseAnotherAccount`.
- [ ] **Step 3:** Implementation, in `EgressProxy` and `ClaudeFiles`.

## Not in this plan

Each has its place, and a reason it isn't here.

- **Strong mode's key file** (S12 item 5, S11 item 27): after slice 3, in a plan of its own. A key under
  `~/.vibeswitcher/keys` is a secret only once no team session can read the home, which is what slice 3 gives.
- **Clones for workers** (S12 item 3, rule 4): with the team seam of stage 4. SB-D5 closes the base's half now.
- **`SO_PEERPIDFD` and `SCM_PIDFD`** (S12 item 6): where the kernel has them, for plain sessions and the server's
  socket. Confined sessions don't need them.
- **The AppArmor profile** (S12 item 5): Ubuntu 24.04 bare metal and stage 8's release. Not this machine.
- **Codex workers** (D15): Codex's own sandbox inside a box, measured, in a task after slice 3.
- **Limits per box** (SB-D13), **slots through the door** (SB-D14), **Landlock where ABI 2 or later** (SB-D1):
  follow-ups, each small, none needed for a lock.
- **Reply rights, masked screens, the wallet page's origin** (S12 item 16), **signed approvals** (item 11): stages 3
  and 4.

## Order

Four lanes, each a worktree at a time, so four agents can work at once. A task's hot files are its alone.

| Task | Needs | Runs beside | Shared files it alone edits | Agent-hours | The user or the lead |
| --- | --- | --- | --- | --- | --- |
| SB0 | — | SB1, SB2, SB4, SB9 | the inventory | 3 | a go-ahead for Step 3's gated run |
| SB1 (Step 1 first) | — | SB0, SB2, SB4, SB9 | `CVibePlatform.h` | 6 | SB-D1 |
| SB2 | SB1 Step 1 | SB0, SB1, SB4, SB9 | `LeadVaultGuarded.swift` | 3 | SB-D5, SB-D16 |
| SB4 | SB1 Step 1 | SB0 to SB3, SB6, SB9 | `vibeswitcher-mcp/main.swift` (two of its three hooks), `vibeswitcher-hook/main.swift` | 5 | SB-D3 before it starts |
| SB3 | SB1, SB2; step 8 in `v2` | SB4, SB6, SB9 | `PTYSpawn.swift`, `HostedSession.swift` | 4 | — |
| SB6 | SB1, SB2; step 8 in `v2` | SB3, SB4, SB5, SB9 | `Worktrees.swift`, `BranchCodeSession.swift`; its hook in `vibeswitcher-mcp/main.swift` after SB4's are in | 4 | — |
| SB5 | SB3, SB4 | SB6, SB9; SB7's fixtures | `HostServer.swift`, `HostProtocol.swift`, `HostHandover.swift`, `vibeswitcher-host/main.swift`, `LeadToolset.swift`, `TestLock.swift`, `vs-heavy` | 5 | SB-D14 |
| SB6b | SB4 | SB5, SB6, SB9 | its hook in `vibeswitcher-hook/main.swift` after SB4's are in; its hooks in `LeadToolset.swift` after SB5's is in | 3 | — |
| SB7 | SB5, SB6, SB6b (fixtures: SB0) | SB9 | — | 4 | — |
| SB8 | SB7 | SB9 | the security document, the design, the bootstrap path, the Mac's tasks | 3 | a go-ahead for the gated run; SB-D6 recorded |
| SB9 | SB1 Step 1 | everything in slice 1 | its hook in `vibeswitcher-host/main.swift`, after SB5's is in | 5 | SB-D7's list |
| SB10 | SB5, SB9 | SB11's tests | — | 4 | a go-ahead for the gated run |
| SB11 | SB5, SB6, SB10 | — | `LeadStart.swift` | 6 | SB-D11, SB-D12 |
| SB12 | SB11 | SB13 | the security document | 3 | — |
| SB13 | SB10 | SB11, SB12 | — | 4 | SB-D8; a go-ahead for the gated measurement |

- **Lanes for slice 1:** the kernel lane (SB1, SB3, SB5), the tool server lane (SB2, SB4, SB6, SB6b), the measuring lane
  (SB0, SB7's fixtures, SB7, SB8), and the network lane (SB9), which is slice 2's and starts at once.
- Every job is green before the next task's first push, whatever runs beside.
- The port map's Non-seam rows are added by each task in a commit of its own at its end, so two lanes never rewrite
  the same lines.
- A slice joins `v2` only after its sweep (SB8 Step 3, SB12 Step 3).

## Changes to the spec

What this plan does differently from the security document, the design and the bootstrap path. SB8 and SB12 write
them in.

- **S12 item 1.** The box is built by the session's launcher, which stays outside as its keeper and its terminal's
  leader; init is ours and reaps (S2-D6's subreaper, inside the namespace). The slave is inherited, and a terminal
  made outside has no name inside (measured).
- **S4 and S12 item 2.** The session's connector is held by its porter, outside; inside there is a door. Nothing
  reads a pid or a pid namespace, and the measurement S4 asked for isn't needed (SB-D4).
- **S12 item 3.** Clones come later; the base is read-only to a worker in slice 1 (SB-D5).
- **S12 item 4.** The proxy serves a listener each box makes in its own network namespace. It also refuses private
  ranges unless listed, and Hyper-V sockets are refused by the filter, since no namespace covers them here.
- **S12 items 10, 14 and 15.** Not needed for confined sessions: a branch run has no door; helpers start from the
  porter's sealed copies; the hooks copy is out of reach.
- **S12 item 17.** A confined spawn's environment is an allow-list (SB5).
- **S11 gains** two items (Hyper-V sockets; the kernel's surface from a user namespace of one's own) and says, per
  item, what is closed for whom.
- **Landlock** isn't used on this kernel (ABI 1: no rename between folders).
- **The design's requirement 3**: "its identity is a socket it inherited from the host" becomes "a door only its
  sandbox has, answered outside by a process the host started".
- **D2 and D9** stay recommended until slice 3, and are then no longer what a team's locks rest on.
- **The tool server's and the hook's work is done outside the session's process tree** for confined sessions: the
  orphan sweep's tool servers and `MCPKeeper` concern plain sessions only.
- **The heavy-work slots** have a folder of their own on Linux (SB-D14).

## Done when

- Slice 1: `SandboxPlannerTests`, `SandboxPolicyTests`, `SandboxShimTests`, `SandboxSeccompTests`,
  `SandboxFactsTests`, `SessionSandboxTests`, `DoorTests`, `PorterTests`, `ConfinedSpawnTests`,
  `SessionConnectorTests`, `ConfinedTeamTests`, `BranchRunTests`, `BranchRunHostTests`, `BoxPathTests`, `DeputyTests`
  and `SandboxAttackTests` pass
  on Linux with the lints, and the pure ones and the Mac's cases pass on the Mac.
- Every attack test was shown succeeding against its decoy with the box off, and failing inside.
- The gated run passed once: a real worker in a box built, reported, was audited and merged.
- `status` says which roles are confined; the security document's S11 says what is closed for whom, and its lint
  passes.
- Every shared-file edit is in [Non-seam edits](#non-seam-edits-this-plan-makes) and the port map, each with a Mac
  test.
- The `v2 linux` and `v2 macos` jobs are green on one commit, after the slice's sweep.
- Slices 2 to 4: the same for their suites, and the documents say what each closed.
