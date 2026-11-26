# VibeSwitcher 2: what versions are locked

What a build is made of should be what was checked. This page says what is held fixed, what isn't, and why.
`DependencyLockLintTests` keeps the locked part locked.

## Locked

- **Swift packages.** Package.swift names each package with an exact version. Package.resolved is tracked and pins
  every package by version and commit, the packages those bring in too. Every SwiftPM command in the scripts and the
  workflows takes Package.resolved as it is (`--only-use-versions-from-resolved-file`, from `swiftpm_options` in
  `scripts/lib/swift-jobs.sh`; the install scripts give it themselves). When Package.resolved no longer matches
  Package.swift, the build fails ("an out-of-date resolved file was detected"). Without the flag, SwiftPM would
  quietly resolve again and rewrite the file.
- **The Swift toolchain.** `.swift-version` names it (6.4.2). The install scripts refuse a toolchain that says
  another version, and every CI job checks its Swift against it (`scripts/ci/check-versions.sh swift`). On Linux CI,
  swiftly 1.2.0 installs that version, its download checked by SHA-256, unless the image already says 6.4.2. The Mac
  never installs a toolchain: its jobs take the image's Xcode 27.2 (`DEVELOPER_DIR`), whose Swift the check reads.
- **GitHub actions.** Each one is pinned by its commit, and only the two listed in `scripts/ci/check-workflows.sh`
  are allowed.
- **Downloads.** Every file a workflow or a script downloads is checked against its SHA-256 on the next lines.

## Checked, not locked

- **Node.js and Google Chrome.** The page tests run on the runner's Node, and the browser checks run on its Chrome.
  Both come with the runner image and change with it. `scripts/ci/checked-versions.txt` gives the range of major
  versions they last passed on, and `scripts/ci/check-versions.sh` stops a CI job on any other major. Widen a range
  only after a green run on the new major.

## Not locked

- **The runner images** (`ubuntu-24.04`, `xcode-27`). GitHub updates them about weekly, and a workflow can't pin a
  hosted image to one build. Their own tools (git, Python, Node's minor versions) move with them, and so does what
  they have at all. The first example: on 1e377af0, one `v2 linux` runner's image had no Swift 6.4.2, where every
  green run's had. swiftly installed it, and scripts/test.sh's scratch HOME then hid swiftly's own folder from its
  `swift` ("Could not load swiftly's configuration file"), so no Swift test ran. The swiftly step now gives the
  steps after it `SWIFTLY_HOME_DIR`, `SWIFTLY_BIN_DIR` and `SWIFTLY_TOOLCHAINS_DIR`, and the lint holds every workflow
  to it. A path the images had always taken can still break on a runner that takes the other one.
- **apt packages.** The Linux workflows install `gnupg2` and the toolchain's libraries at the archive's current
  versions. They are needed only when the image lacks Swift 6.4.2, for swiftly's toolchain.
- **Claude Code and Codex.** VibeSwitcher doesn't build with them. It runs the ones installed on the machine, which
  update themselves (a team session starts Claude Code with its updater off, so it doesn't change mid-task). Tests
  that read Claude Code's screen name the version they were written for. A new Claude Code or Codex is checked by
  using it, not by CI.
