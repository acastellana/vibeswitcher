## 2026-10-30 21:27:20 2026-10-30: fix main's 2 failing tests (task main-s-full-suite) before merging anything else. build-app-sh-install (audit clean) is kept and test-under-load-sh has auto_advance off until it lands; then merge both.

build-app-sh-install's verifier found TeamRowsTests.voiceOverReadsTheRow and HomeIsolationTests' installer test failing on main after today's ~130-commit pull. Every merge gate runs the full suite, so it would fail and bounce the workers' output onto code outside their tasks.

