# Backtest: how often would a "tests got weaker" check have fired?

Idea 2 of [the addyosmani/agent-skills review](addyosmani-agent-skills.md) proposes a sibling of `testCensus` (`Sources/VibeCore/LeadRisk.swift:251`). The census catches tests removed by name and an added `.disabled`, but not assertions dropped from a test that keeps its name. Decision 2026-11-06 22:35 prefers an incident before a new check, so the idea is taken only if it raises few merges.

**Result: 4 of the last 100 merged tasks raise, only 1 of them is a new audit, and that one is a refactor. Don't build it yet.** The verdict and its numbers are at the end.

## The rule

A task raises when either holds:

- **Count:** in a Swift file under `Tests/`, the net count of `#expect`, `#require` and `XCTAssert*` over the task's diff falls.
- **Marker:** the branch adds a line under `Tests/` with `XCTSkip`, `withKnownIssue`, `.enabled(if: false)` or `@Suite(.disabled`.

## Method

A scratch script, not in the repository, applied the rule with `git diff -U0 -M` to each task's commit range.

- **The 100 tasks:** the newest 100 distinct `Merged <slug>:` entries in `docs/lead/progress.md` and `progress-archive.md`, ordered by logged time: 2026-11-05 00:30 to 2026-11-09 09:52.
- **Commit ranges:** tasks land by rebase, so main has no merge commit per task. A range runs back from the tip the log names to the previous logged tip, a `Lead:` commit or a merge. 93 tasks have a logged tip; 6 merged by hand log none, and their commits were picked by subject from those at the logged minute. The last, `github-merge-third-try`, landed only merge `ba5dff57`, which has no diff against its first parent.
- **Cross-check:** recounting the Count half from whole files before and after, without reading the patch, agreed with the script on all 99 tasks with a diff.
- **Each raise was read by hand** against its test diff.

## The raises

"Audited anyway" means the task went to audit whether or not this check existed, so a raise there costs nothing and adds nothing.

| Task (merged) | Range | What fired | Audited anyway? | Verdict |
| --- | --- | --- | --- | --- |
| `fix`: the stuck-verifier-prompt test waits on the fake's state (2026-11-05 17:30) | `2d169eec..4df695ac` | Count: `StuckVerifierPromptTests.swift` +0 −5 | **No, review none** | **Refactor** |
| `tests-long-synchronous` (2026-11-07 10:32) | `667eaedc..204a442f` | Marker: `withKnownIssue` ×3 | Yes, raised for test infrastructure | **Refactor** |
| `chat-the-run-buttons` (2026-11-07 20:04) | `25cb467a..7c7e0c95` | Count: `RunButtonTests.swift` +3 −4 | Yes, review audit | **Refactor** |
| `correctness-tests-stop` (2026-11-08 17:47) | `9550d4b7..8f771a1c` | Count: `KeepAwakeTests.swift` +6 −7, `PhoneMainThreadTests.swift` +5 −6 | Yes, review audit | **Real, and intended** |

- **`fix`.** All five removed `#expect` conditions moved into `h.waitFor { … }`, which records an issue and throws on timeout (`Tests/VibeSwitcherTests/ChatSyncTests.swift:790`). The same conditions are checked; the test now waits for them rather than reading once, which was the task.
- **`tests-long-synchronous`.** All three `withKnownIssue` lines already existed and only gained `await`. Each file's net count of the marker is unchanged. Two of them are tests that fail on purpose to prove a failing test's host is ended.
- **`chat-the-run-buttons`.** `RunButton.run` went from returning `Bool` to reporting an outcome. Three assertions moved to the outcome and are stronger (`.refused("Not run: because.")` instead of `false`). The fourth, in `aPlainLineIsTypedWithoutAsking`, asserted the old return value; the effect it stands for is still asserted by `#expect(typed == ["! swift test"])`.
- **`correctness-tests-stop`.** Most lines swap a time bound for an order of events (`took < 0.05` becomes `comesBack`), but two assertions go with nothing in their place. `#expect(look() < 0.05)` in `KeepAwakeTests` becomes a bare `look()`, and `#expect(end.timeIntervalSince(start) >= Self.readTime - 0.05)` in `PhoneMainThreadTests` goes. The second only timed the test's own fake read, which no longer sleeps. The first is a small real loss in normal runs. This was the task's stated purpose, and its audit came back clean with 2 nits and 1 pre-existing item open.

## What the rule can't see

These limit how much the count says about real weakening:

- **24 tasks removed an assertion and raised nothing,** because the file's net count held or rose. I read the 3 of those that were review none (next section) and not the other 21, which were all audited. A rule on counts can't tell a rewrite from a swap of a strong assertion for a weak one, and `#expect(x == 1)` becoming `#expect(x > 0)` changes no count at all.
- **It missed a real case in this very sample.** `correctness-tests-stop` also moved `aSnapshotIsQuickOnABusyMac` to `@Test(.tags(.perf), .enabled(if: perfRun, perfOnly))`, so it no longer runs in the normal suite, and dropped an assertion from `ProcessTableTests` whose file's net held. The census keeps the test because its name survives, and `.enabled(if: false)` doesn't match a variable condition. Here the task was audited and the move was the point, but on a review none task nothing would raise it.
- **12 review none tasks is a small sample.** It can't show this never happens; it shows it didn't happen here.

## The review none test repairs

These are the tasks with the most reason to weaken a test and the fewest eyes on them, so I read all five, including the ones that raised nothing. None lost a check.

- `fix`: the raise above; the conditions moved into a wait.
- `walletdesktests-waits` (+5 −5): `#expect(count == 1)` became `#expect(await until { count == 1 })`, five times.
- `fix-the-flaky-test-20` (+2 −2): `took < 1.2` became a check on one heartbeat, plus a direct bound on the delay it depends on (`confirmAfter < 0.9`).
- `accountusagetests-don-t` (+3 −1): the tests read a fixed clock instead of today's, and gain checks either side of the reset.
- `fix-the-flaky-test-21`: no assertion changed.

Those four with removals are every review none task in the window that removed an assertion.

## Numbers

| Measure | Count |
| --- | --- |
| Tasks in the window | 100 |
| Tasks with a diff | 99 |
| Tasks changing a file under `Tests/` | 90 |
| Tasks removing at least one assertion | 27 |
| Assertions added / removed, all tasks | 5,455 / 868 |
| **Raised by the rule as written** | **4** (3 Count, 1 Marker, 0 both) |
| Raised if the Marker half counts net per file | 3 |
| Real weakening among the 4 | 1, intended and already audited |
| Refactors among the 4 | 3 |
| Review none tasks in the window | 12 |
| **New audits the check would have caused** | **1 of 100** (the 1 raise among those 12) |
| Real weakenings among the new audits | **0** |
| Weakened-test incidents in `docs/lead/incidents.md` and the decisions files | 0 (searched for weakened, dropped, removed or deleted assertions) |

## Verdict: don't build yet

Noise isn't the obstacle: 4 raises in 100, and 1 new audit, clears the "raises few merges" bar easily. What's missing is anything for it to catch. It would have added one audit in 100 merges, to a correct refactor. The only real weakening it found was intended and had an auditor on it already. Five of the 12 review none tasks were test repairs, the tasks with the most reason to weaken a test, and none of them lost a check. With no incident on record, decision 2026-11-06 22:35 says to wait.

**Build it when** a merged task is found to have dropped or loosened an assertion that should have caught a defect. The check is small and this backtest shows it will be quiet, so waiting costs little. If it is built, count the Marker half net per file as well, which removes the `tests-long-synchronous` raise, and treat any `.enabled(if:` added to a `@Test` as a marker, which closes the gap above.
