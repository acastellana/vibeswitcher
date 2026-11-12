# VibeSwitcher 2, Stage 0 (Ground) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every push to `v2` is built and tested by a macOS runner and checked by an Ubuntu runner, and the measured
distance from compiling on Linux is on record for the stage 1 plan.

**Architecture:** Two GitHub Actions workflows that run only for `v2`. The macOS one builds everything and runs the
suite through `scripts/test.sh`, minus a short written list of tests a hosted runner can't run. The Ubuntu one
installs the pinned Swift, builds the one dependency that already compiles there and runs the web tests. No source
file the Mac compiles is changed in this stage.

**Tech Stack:** GitHub Actions (`macos-26`, `ubuntu-24.04`), Swift 6.4.2 through swiftly on Linux, bash, Node 22.

**Spec:** `docs/superpowers/specs/2026-11-12-vibeswitcher-2-design.md` (Stage 0; The branch; Building without a Mac)

## Global Constraints

- All work is on branch `v2`. Never commit to, push or open a pull request against `main`.
- No file under `Sources/` or `Tests/` changes in this stage, and `scripts/test.sh` is not edited.
- Tests run only through `scripts/test.sh` (`AGENTS.md`). Nothing is installed on this machine by an agent.
- Swift commands on this machine need `. ~/.local/share/swiftly/env.sh` first, and `--build-system native`.
- Workflows trigger on `push` to `v2` and `workflow_dispatch` only; `permissions: contents: read`; no secrets.
- Actions are pinned by commit: `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` (v7.0.1),
  `actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9` (v7.0.2). No other action is used.
- `.github/` is one of the lead's sensitive paths: each workflow change gets a reviewer before it is pushed.
- Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.

## Review Focus

1. A workflow that also runs for `main`, a tag or a fork's pull request: it must run for `v2` pushes only (Task 1
   and Task 2 check the trigger block by test).
2. A skip that hides a real failure: a Mac test skipped on the runner must be named in the list with its reason, and
   the run must print how many were skipped (Task 3).
3. A stale skip: after a merge from main renames or deletes a test, a skip naming it must fail the run, not pass
   silently (Task 3).
4. The runner's Swift differing from the Mac's (the Mac builds with Xcode 27.2): the run prints both versions first,
   and the Xcode it selects is written in the workflow, not left to the image's default (Task 2).
5. A hung test or a leftover session host holding the job for six hours: every job has `timeout-minutes` (Tasks 1
   and 2).

---

### Task 1: The Ubuntu workflow

**Files:**
- Create: `.swift-version`
- Create: `.github/workflows/v2-linux.yml`
- Create: `scripts/ci/check-workflows.sh`

**Interfaces:**
- Produces: `scripts/ci/check-workflows.sh` (no arguments; exit 0 when every file in `.github/workflows/` passes the
  checks below, else 1 with one line per failure). Task 2 runs it on its own workflow.

- [ ] **Step 1: Write the failing check**

`scripts/ci/check-workflows.sh`, bash, `set -uo pipefail`, run from the repository's root. For each
`.github/workflows/*.yml` it fails, naming the file and the rule, unless:

- the `on:` block is exactly `push` with `branches: [v2]`, and `workflow_dispatch` (no `pull_request`, no `schedule`,
  no other branch);
- it contains `permissions:` followed by `contents: read` and no other permission;
- every `uses:` line is one of the two pinned actions in Global Constraints, by full commit hash;
- every job has `timeout-minutes:`;
- it contains no `secrets.`.

With no workflow files it prints `no workflows` and exits 1.

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/ci/check-workflows.sh`
Expected: `no workflows`, exit 1.

- [ ] **Step 3: Write `.swift-version` and the workflow**

`.swift-version`: the single line `6.4.2`.

`.github/workflows/v2-linux.yml`:

```yaml
name: v2 linux
on:
  push:
    branches: [v2]
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: v2-linux-${{ github.ref }}
  cancel-in-progress: true
jobs:
  linux:
    runs-on: ubuntu-24.04
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - name: Check the workflows
        run: bash scripts/ci/check-workflows.sh
      - name: Install Swift
        run: |
          sudo apt-get update
          sudo apt-get install -y gnupg2 libcurl4-openssl-dev libsqlite3-dev libxml2-dev libz3-dev
          curl -fsSLO https://download.swift.org/swiftly/linux/swiftly-x86_64.tar.gz
          tar zxf swiftly-x86_64.tar.gz
          ./swiftly init --assume-yes --quiet-shell-followup --skip-install
          . "$HOME/.local/share/swiftly/env.sh"
          swiftly install --assume-yes "$(cat .swift-version)"
          swift --version
          echo "$HOME/.local/share/swiftly/bin" >> "$GITHUB_PATH"
      - name: Build what builds on Linux
        run: swift build --build-system native --product SwiftTerm
      - name: Web tests
        run: bash scripts/test.sh --web Tests/Web
```

The swiftly flags are as remembered, not checked: if `swiftly init --help` on this machine shows different names
for "don't ask" and "don't install a toolchain yet", use those.

- [ ] **Step 4: Run the check and the steps locally**

Run: `bash scripts/ci/check-workflows.sh && . ~/.local/share/swiftly/env.sh && swift build --build-system native --product SwiftTerm && bash scripts/test.sh --web Tests/Web`
Expected: exit 0; the last lines include `web tests: 7 of 7 passed`.

- [ ] **Step 5: Commit, push, and watch the run**

```bash
git add .swift-version .github/workflows/v2-linux.yml scripts/ci/check-workflows.sh
git commit -m "v2: Ubuntu workflow, pinned Swift, workflow checks"
git push
gh run watch "$(gh run list --branch v2 --workflow 'v2 linux' --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

Expected: the run ends `completed success`. A failure in "Install Swift" is fixed in the workflow and pushed again;
nothing else in this task changes for it.

---

### Task 2: The macOS workflow, build only

**Files:**
- Create: `.github/workflows/v2-macos.yml`

**Interfaces:**
- Consumes: `scripts/ci/check-workflows.sh` from Task 1.
- Produces: a job named `macos` whose last step Task 3 replaces; the step `Select Xcode`, which exports
  `DEVELOPER_DIR`.

- [ ] **Step 1: Write the workflow**

```yaml
name: v2 macos
on:
  push:
    branches: [v2]
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: v2-macos-${{ github.ref }}
  cancel-in-progress: true
jobs:
  macos:
    runs-on: macos-26
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - name: Select Xcode
        run: |
          ls -d /Applications/Xcode*.app
          echo "DEVELOPER_DIR=/Applications/Xcode_27.2.app/Contents/Developer" >> "$GITHUB_ENV"
      - name: Versions
        run: |
          xcodebuild -version
          swift --version
          node --version
          sw_vers
      - name: Build
        run: swift build --build-system native
```

- [ ] **Step 2: Check it, push it, watch it**

Run: `bash scripts/ci/check-workflows.sh` (expected: exit 0), then commit `.github/workflows/v2-macos.yml` as
"v2: macOS workflow, build only", push, and watch as in Task 1 with `--workflow 'v2 macos'`.

- [ ] **Step 3: Settle the Xcode**

If `Select Xcode` shows no `Xcode_27.2.app`: choose the newest Xcode the image lists whose Swift is 6.4 or later,
write its path in the step, and add a comment line above it giving the Mac's version (27.2) and the runner's. If
none has Swift 6.4, use the newest and record in `docs/process/v2-linux-inventory.md` (Task 4) which Swift the
runner builds with. Push and watch again.

Expected at the end: `Build` succeeds and `Versions` shows the Xcode written in the workflow.

---

### Task 3: The Mac suite on the runner, with a written skip list

**Files:**
- Create: `scripts/ci/macos-runner-skips.txt`
- Create: `scripts/ci/macos-tests.sh`
- Modify: `.github/workflows/v2-macos.yml` (add the steps after `Build`)

**Interfaces:**
- Produces: `scripts/ci/macos-tests.sh` (no arguments; runs `scripts/test.sh` with a `--skip` per listed test; exit
  status is the suite's, or 2 for a bad list).
- `scripts/ci/macos-runner-skips.txt` format: one test a line as `SuiteName/testName` or `SuiteName`, then two
  spaces, then the reason. `#` starts a comment line. Sorted.

- [ ] **Step 1: Write `scripts/ci/macos-tests.sh` and its self-check**

The script, in order:

1. Reads the list. A line that isn't a comment and doesn't match `^[A-Za-z0-9_]+(/[A-Za-z0-9_]+)?  .+$` → prints
   the line, exit 2 (a skip with no reason is refused).
2. For each entry, the suite name (and the test name, when given) must appear in a `.swift` file under `Tests/`
   (`grep -rqw`). One that doesn't → `stale skip: NAME`, exit 2.
3. Prints `runner skips: N` and the list.
4. Runs `bash scripts/test.sh --skip NAME …` and exits with its status.

`scripts/ci/macos-tests.sh --check-list` does steps 1 to 3 only and exits 0, so the list can be checked on Linux.

- [ ] **Step 2: Test the list checks on this machine**

Run each and compare:

```bash
printf '# none yet\n' > scripts/ci/macos-runner-skips.txt
bash scripts/ci/macos-tests.sh --check-list                 # prints "runner skips: 0", exit 0
printf 'NoSuchSuiteAnywhere  made up\n' > /tmp/skips-bad && SKIPS=/tmp/skips-bad bash scripts/ci/macos-tests.sh --check-list   # "stale skip: NoSuchSuiteAnywhere", exit 2
printf 'LeadBoardTests\n' > /tmp/skips-bad && SKIPS=/tmp/skips-bad bash scripts/ci/macos-tests.sh --check-list                # prints the line, exit 2
```

(`SKIPS` overrides the list's path, for these checks only. Use the session's scratch folder in place of `/tmp`.)

- [ ] **Step 3: Add the discovery run to the workflow and push**

After `Build`:

```yaml
      - name: Tests
        run: bash scripts/ci/macos-tests.sh 2>&1 | tee test.log
      - name: Keep the log
        if: always()
        uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9
        with:
          name: macos-test-log
          path: test.log
          retention-days: 14
```

Add `shell: bash` with `-o pipefail` for the `Tests` step so the suite's status isn't lost to `tee`
(`defaults: run: shell: bash` at the job level, which GitHub runs with `-eo pipefail`).

- [ ] **Step 4: Find what the runner can't run**

Watch the run, download the log (`gh run download RUN -n macos-test-log`), and for each failing test decide:

- it needs what a hosted runner doesn't have (the login Keychain's dialogs, the signing identity, a real window
  server behaviour, Terminal automation, timing under an unknown load) → add it to the list with that reason;
- it fails for a reason that would also fail on a Mac → stop and report it: that is a finding about the branch, not
  a skip.

Repeat until the run is green. If the suite can't finish inside 90 minutes, or more than a fifth of the suites
would be skipped, stop and report the numbers: the design's fallback (the real Mac at the end only) then carries
more weight, and the user should know.

Expected at the end: `v2 macos` green, the log's `runner skips: N` line matching the list.

- [ ] **Step 5: Commit**

```bash
git add scripts/ci/macos-runner-skips.txt scripts/ci/macos-tests.sh .github/workflows/v2-macos.yml
git commit -m "v2: the Mac suite on the hosted runner, with a written skip list"
git push
```

---

### Task 4: The record

**Files:**
- Create: `docs/process/v2-linux-inventory.md`
- Create: `docs/process/v2-branch.md`
- Modify: `docs/superpowers/specs/2026-11-12-vibeswitcher-2-design.md` (one link)

- [ ] **Step 1: Write `docs/process/v2-linux-inventory.md`**

The spike's measurement of 2026-11-12 (main at `f2ebe92b`, Swift 6.4.2, Ubuntu 24.04), as measured:

- `VibeCore`: 505 errors in 34 of 171 files; the other 137 type-check unchanged. By kind (errors, files): process
  inspection 177, 11; `posix_spawn` 74, 4; Keychain 48, 1; kqueue and file-system sources 38, 3; Network.framework
  38, 1 (`PreviewProxy.swift`, understated: about 55 lines use it); Mach clocks and host statistics 34, 8;
  CoreGraphics, ImageIO, UTType 33, 2; Darwin `stat` fields 19, 9; peer credentials and socket options 18, 4; other
  libc 11, 5; CoreFoundation boolean test 6, 2; Foundation gaps 6, 2; `SecRandomCopyBytes` 3, 1; CryptoKit 0;
  Objective-C runtime 0.
- `VibeHost`: 142 errors in 8 of 13 files: `posix_spawn` 62, 3; code signing and Mach-O 29, 1 (`AppCode.swift`);
  Keychain 25, 1 (`VaultStorage.swift`); process inspection 12, 2; process sources 5, 3; peer credentials 5, 4;
  other 4, 2.
- Executables, type-checked against stubs: `vibeswitcher-hook` 0, `vibeswitcher-mcp` 1, `vibeswitcher-host` 4.
- One construct is 103 of the errors: optional `posix_spawnattr_t` and `posix_spawn_file_actions_t` at 9 spawn
  sites in 7 files. One shared spawn wrapper removes them.
- swift-crypto 3.15.1 is a drop-in for the 20 files that use CryptoKit.
- SwiftTerm 1.19.0 builds on Linux unchanged.
- OpenCombine 0.14.0 builds (three products: `OpenCombine`, `OpenCombineDispatch`, `OpenCombineFoundation`). It has
  no `combineLatest` or `merge`; the app calls `combineLatest` 10 times.
- The tests' home guard (`@_section("__DATA,__mod_init_func")`) compiles on Linux and does nothing there;
  `@_section(".init_array")` runs at load.
- How it was measured: the import swaps and the 89 `Darwin.`-qualified calls rewritten, in a scratch copy;
  `--build-system native`, since the default build system stops at the first failing batch. Not covered: closure
  bodies that failed inference, and runtime-only Mac dependencies (`osascript` 4 lines, `Library/` paths 12,
  `/Applications` 7, `UserDefaults` 7).
- From Task 2 and 3: the runner's Xcode and Swift, how long the Mac suite takes there, and the number of skips.

- [ ] **Step 2: Write `docs/process/v2-branch.md`**

The branch's routine, as commands:

```bash
git fetch origin && git switch v2 && git merge origin/main      # at least every working day
bash scripts/ci/check-workflows.sh && bash scripts/ci/macos-tests.sh --check-list
bash scripts/test.sh --web Tests/Web                            # and, from stage 1, bash scripts/test.sh
git push                                                        # then both runs green before anything else lands
```

And the rules it serves, one line each, from the design's "The branch": main is never pushed to; conflicts are
settled on `v2`; a merge that breaks a runner is fixed before new work; a stale skip is removed in the merge that
made it stale.

- [ ] **Step 3: Link them from the design**

The design (revised 2026-11-12) already carries the spike's findings. Check that its Stage 0 links
`docs/process/v2-linux-inventory.md`, and add to its "The branch" a link to `docs/process/v2-branch.md`.

- [ ] **Step 4: Check the links and commit**

Run: `grep -n 'v2-linux-inventory\|v2-branch' docs/superpowers/specs/2026-11-12-vibeswitcher-2-design.md docs/process/*.md`
Expected: each new file is linked from the design or from the other.

```bash
git add docs/process/v2-linux-inventory.md docs/process/v2-branch.md docs/superpowers/specs/2026-11-12-vibeswitcher-2-design.md
git commit -m "v2: the Linux inventory, the branch's routine, design corrections from the spike"
git push
```

---

### Task 5: A fully static build, tried

Needs the user's go-ahead first: it installs Swift's static Linux SDK into the home folder (`swift sdk install`, no
sudo), and agents install nothing by themselves.

**Files:**
- Modify: `docs/process/v2-linux-inventory.md` (the result)

- [ ] **Step 1: Ask the user to install the SDK**, giving the exact `swift sdk install` command for Swift 6.4.2 from
  swift.org's static Linux SDK page, with its checksum.

- [ ] **Step 2: Build a one-file probe statically, for both architectures**

In the session's scratch folder, a package with one executable that prints its version, hashes a string with
swift-crypto and starts a child with `posix_spawn`. Build it with
`swift build --swift-sdk x86_64-swift-linux-musl -c release` and `--swift-sdk aarch64-swift-linux-musl`.
Expected: two binaries; `file` calls each "statically linked"; the x86_64 one runs here and prints its three lines.

- [ ] **Step 3: Try SwiftTerm the same way**

Add SwiftTerm 1.19.0 to the probe and build both again. Expected: it builds, or the error is recorded.

- [ ] **Step 4: Record the result** in the inventory (sizes, what built, what didn't), commit and push.

---

## Done when

Both workflows are green on the same `v2` commit, `scripts/ci/macos-runner-skips.txt` says in writing what the
hosted Mac can't run, and the inventory, with the static build's result, is in the repository for the stage 1
plan to be written from.
