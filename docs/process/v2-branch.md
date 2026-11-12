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
- Swift on this machine: `. ~/.local/share/swiftly/env.sh` first; the version is `.swift-version`'s.

## What CI runs

Both workflows run for a push to `v2` or by hand, and for nothing else; `scripts/ci/check-workflows.sh` refuses a
workflow that says otherwise, and the Ubuntu run starts with it.

- **`v2 linux`** (Ubuntu 24.04): the workflow check, the pinned Swift, what builds on Linux, the web tests.
- **`v2 macos`** (GitHub's hosted Mac): builds everything and runs the suite through `scripts/ci/macos-tests.sh`,
  without the tests listed, each with its reason, in `scripts/ci/macos-runner-skips.txt`.

How far the code is from compiling on Linux: [the inventory](v2-linux-inventory.md).
