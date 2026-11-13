# The v2 branch's routine

Version 2 ([design](../superpowers/specs/2026-11-12-vibeswitcher-2-design.md)) is built on `v2`. Main is never
committed to, pushed or opened a pull request against from this work.

## Taking in main

At least every working day:

```sh
git fetch origin && git switch v2 && git merge origin/main
bash scripts/ci/check-workflows.sh && bash scripts/ci/macos-tests.sh --check-list
bash scripts/test.sh --web Tests/Web        # from stage 1 on: bash scripts/test.sh
git push
```

Then both workflows (`v2 linux`, `v2 macos`) are green before anything else joins the branch.

- Conflicts are settled on `v2`.
- A merge that breaks a runner is fixed before new work.
- A skip in `scripts/ci/macos-runner-skips.txt` that the merge made stale is removed in that merge.
- A target main adds is mirrored into `Package.swift`'s Linux half: into `portableTargets` when it compiles on Linux,
  else into `notYetPortableTargets`.
- The port map's merge step: the commits that touched a file in [the port map](v2-port-map.md) each get a line under
  its Merges, as [it says](v2-port-map.md#how-it-is-kept).
- Swift on this machine: `. ~/.local/share/swiftly/env.sh` first; the version is `.swift-version`'s.

## What CI runs

Both workflows run for a push to `v2` or by hand, and for nothing else; `scripts/ci/check-workflows.sh` refuses a
workflow that says otherwise, and the Ubuntu run starts with it.

- **`v2 linux`** (Ubuntu 24.04), three jobs, each the workflow check, the pinned Swift, then `scripts/test.sh` with a
  filter: `platform` (`VibePlatformTests`), `core` (`VibeCoreTests|VibeNodeTests`) and `host` (`VibeHostTests`).
- **`v2 macos`** (GitHub's hosted Mac), four jobs, each building everything and running its part of the suite through
  `scripts/ci/macos-tests.sh`, without the tests listed, each with its reason, in `scripts/ci/macos-runner-skips.txt`:
  `platform` (`VibePlatformTests`), `core` (`VibeCoreTests|VibeNodeTests`), `host` (`VibeHostTests`) and `app`
  (`VibeSwitcherTests`).

How far the code is from compiling on Linux: [the inventory](v2-linux-inventory.md).

## Pushing

- Push only with every `v2` job green, under the time box below, and never while a `v2 macos` run someone is waiting
  on is in progress.
- **The time box:** a Mac-only failure in new platform code gets at most two pushes of investigation. Then it is
  listed in `scripts/ci/macos-runner-skips.txt` with the experiment that will find its cause, and in
  [the Mac's checks](v2-mac-tasks.md), and Linux work goes on.
