## 2026-10-30 21:27:20 2026-10-30: fix main's 2 failing tests (task main-s-full-suite) before merging anything else. build-app-sh-install (audit clean) is kept and test-under-load-sh has auto_advance off until it lands; then merge both.

build-app-sh-install's verifier found TeamRowsTests.voiceOverReadsTheRow and HomeIsolationTests' installer test failing on main after today's ~130-commit pull. Every merge gate runs the full suite, so it would fail and bounce the workers' output onto code outside their tasks.

## 2026-10-31 00:40:21 2026-10-31: after the user pulls outside work into main (e.g. from GitHub), the lead has the full suite run on main (a small review-none task, or the next merge's gate watched closely) before stacking tasks behind it. Failures on main get their own fix task first.

On 2026-10-30, a ~130-commit pull left main failing 2 tests on this Mac (Spanish locale, Swift 6.4 per-target bundles). It surfaced only at the first merge and held 3 tasks back.

