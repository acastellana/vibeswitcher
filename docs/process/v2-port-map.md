# The v2 port map

The ledger the design's [Strict isolation](../superpowers/specs/2026-11-12-vibeswitcher-2-design.md#strict-isolation)
asks for. The Mac app target isn't edited on `v2`, so the node rebuilds the part of the app's logic a lead needs in
`VibeNode`. Until milestone 5 moves the Mac onto `VibeNode`, that logic exists twice, and this file keeps the two in
step.

Seeded 2026-11-13 from `47636aaf`, with the files the lead engine replaces (the outline is in
[the bootstrap path](../superpowers/plans/2026-11-13-v2-bootstrap-path.md#the-engine)). Line counts are at that commit.

## How it is kept

- **At every merge from main**, list the commits that touched a file below:
  `git log --format='%h %s' <last merge>..main -- <file>…`. Each gets a line under [Merges](#merges): ported (with
  the `v2` commit), not needed (with the reason), or owed. A merge isn't finished while a line has been owed for more
  than a week.
- **A row's status** is `owed` until `VibeNode` has what the row names and the ported tests pass on Linux, then
  `ported` with the commit. `not needed` takes a reason. A row whose file main deletes keeps its line, marked so.
- **New cards and settings main adds** get a row each, in the same table, as they arrive.
- **Non-seam edits**: every edit to a file shared with main (`Sources/VibeCore`, `Sources/VibeHost`, the three
  executables) that isn't a call switched to `VibePlatform`, an import removed or a whole file or block moved, gets a
  line in [Non-seam edits](#non-seam-edits), with what it costs a merge.

## Files the engine replaces

| App file | Lines | What replaces it in `VibeNode` | Status |
| --- | --- | --- | --- |
| `Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift` | 2,295 | `LeadEngine` and its parts: start (807-1117), questions (1118-1207), delivery and holding (1208-1252), wake and typing (1335-1468), refresh and witness (1469-1585, 1813-1988), telling a session (1989-2015). Rotation (2084-2287), replaced-lead routing (1253-1334), the watches (1586-1774), app health (1775-1812) and the alerts (2024-2083) are after the bootstrap or become cards | owed |
| `Sources/VibeSwitcher/MainWindow/Lead/ConfigHolds.swift` | 167 | `ConfigHoldStore`: a held config change as a card, accepted from the command line | owed |
| `Sources/VibeSwitcher/MainWindow/Lead/BaseMoves.swift` | 245 | `BaseMoveStore`: a moved base as a card, accepted from the command line | owed |
| `Sources/VibeSwitcher/MainWindow/Lead/PushRequests.swift` | 105 | `PushRequestStore`. Before the bootstrap it lists a request and refuses to push; the bootstrap's lead has no remote | owed |
| `Sources/VibeSwitcher/MainWindow/Lead/RoleSweep.swift` | 78 | `RoleSweep` in the engine, on `HostLink` | owed |
| `Sources/VibeSwitcher/MainWindow/Lead/PromptDecline.swift` | 55 | `PromptDecline` in the engine, on `HostLink` | owed |
| `Sources/VibeSwitcher/MainWindow/Lead/AllDoneWatch.swift` | 67 | the engine's all-done note, as text in `status` | owed |
| `Sources/VibeSwitcher/HostClient.swift` | 1,259 | `HostLink`: connection, welcome and events (152-500), requests and spawn (656-761), input units (1046-1177), screens, history, kill and remove (1214-1252). Starting, replacing and handing over the host (183-221, 293-366, 539-655) are the node's `start` and install, not the engine's; attach, resize and direct keys (762-1045, 1178-1213) are a client's | owed |
| `Sources/VibeSwitcher/SessionStore.swift` | 523 | `NodeSessions`, grown from stage 1's `LocalSessions`: refresh and apply (202-264, 298-452), details (481-503), the state folder's watch (504-523). Terminal.app tabs, Spaces, pausing, renaming and the ledger stay the Mac's | owed |
| `Sources/VibeSwitcher/Heartbeat.swift` | 81 | the engine's refresh timer (3 s; replaced by store events in stage 3, see the design's VibeNode section) | owed |
| `Sources/VibeSwitcher/AppDelegate.swift`, `HookSetup` and `HookBinary` only (1160-1245) | 86 | `vibeswitcher hooks install|remove` (stage 1) and the install step, sealed through the engine | owed |

Not replaced (view or Mac-only): `LeadViews`, `TeamViews`, `TeamRows`, `TeamSummaryModel`, `LeadMailViews`,
`BoardBench`, `TeamChurnBench`.

## Merges

| Date | Main commits | File | Outcome |
| --- | --- | --- | --- |

## Non-seam edits

Rows marked *planned* are the ones the plans expect, listed before they are made so an executor doesn't stop to ask;
each becomes a line number and a commit when made. Lines are at `47636aaf`.

| File and line | What | Why | Merge cost |
| --- | --- | --- | --- |
| `Sources/vibeswitcher-hook/main.swift` top (planned, stage 1 R5) | `signal(SIGPIPE, SIG_IGN)` moved above the first statement | the first host round trip (line 87) came before it | low: one line moved |
| `Sources/vibeswitcher-mcp/main.swift` 38-44 and 153 (planned, stage 1 R5) | SIGPIPE settled after the mode dispatch, and in the read-only hook branch before its write | that branch writes stdout at line 41 | low |
| `Sources/VibeHost/HostServer.swift` (planned, stage 2 Task 4b) | `appPrincipal` member, nil by default; two lines in `acceptAll` | the Linux app is a principal (S2-D1) | low: a member and two lines in a function main rarely changes |
| `Sources/VibeHost/HostServer.swift` 944-960 (planned, Task 4b) | `HostProcesses.orphanParents`; `orphans(running:)` over each | an orphan on Linux goes to a subreaper, not pid 1 (S2-D6) | low |
| `Sources/VibeHost/ClientConnection.swift` `readAvailable`, the decoder (planned, Task 7) | each chunk's sender passed to `onRead`; the decoder notes a frame's senders | per-message credentials (S2-D4) | medium: main may touch the read loop |
| `Sources/VibeHost/HostServer.swift` `checkPeer` (642-654), `start()`, `start(restoring:)` (planned, Task 7) | `checkPeer(client, sender:)`; `senderKeepsIdentity`; `enableCredentials` on the listener | per-message credentials (S2-D4) | medium: signature change |
| `Sources/VibeHost/HostServer.swift` `tidy` (895-904) (planned, Task 8) | one line: a running server child keeps the host from idling | S2-D1 | low |
| `Sources/VibeHost/HostHandover.swift` `State`, `write`, `read`, `SecretChannel` (planned, Tasks 8 and 9) | `serverChild` and `ownImageFD` (optional fields); the state's hash through the secret channel on Linux; `read` checks it | S2-D8, S2-D7 | medium: the handover's format and channel are shared with every Mac build |
| `Sources/VibeHost/HostServer.swift` `Config`, `handOver(to:)` (700), `.spawn` (planned, Tasks 9 and 10) | `installRoot`, `projectAllowList` (nil by default); one hook line each | S2-D7, S2-D11 | low |
| `Sources/vibeswitcher-host/main.swift` (planned, Tasks 5a, 8, 9, 10) | `--test-app-pid` (scratch only); `--server`; the restore check; `HostHardening.atStart`; launcher from the own image; the fallback from the held image (line 85); `installRoot`, `--install-root` (scratch only); the test secret flags only for a scratch host (142-143) and stripped; `projectAllowList`; `holdsFirstLook` | S2-D1, D3, D5, D7, D8, D11 | medium: main.swift changes with every host feature |
| `Sources/VibeCore/LeadVault.swift` `Book`, around 1366, and `ConfigSeal.swift` (planned, Task 10) | `holdsFirstLook`, false by default | a memory vault must not seal what a worker left before a restart (S2-D3) | medium: the seal's logic is busy on main |
| `Sources/VibeCore/LeadGateBuild.swift` 41-55 (planned, bootstrap step 8) | `ServerBuild` reads `build-info` where there is no app bundle | merge receipts name the build | low |
| `Sources/VibeCore/ConfigSeal.swift` 306-315 (planned, bootstrap step 8) | one hook: the platform's extra home files, empty on the Mac | the config seal's Linux list | low |
