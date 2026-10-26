Lead record commits carry no trailer, and conflicts in them resolve themselves

VibeSwitcher's 'Lead: decisions and progress' commits carry no Co-Authored-By or other trailer. A branch whose only conflict with the base is in the lead's records directory merges with the base's records, without a person resolving it.

Acceptance checks:
- LeadRecords.message has no trailer line, and a test checks it.
- A test repository: a worker branch that merged an older base in and conflicts with the base only in <records_dir>/{decisions,progress,incidents}.md lands, and the base's records are kept exactly as they are. Test it through both the rebase path and the merge/squash path.
- A conflict in any other file still refuses as before (test).
- Nothing rewrites existing history.
- The affected tests pass. The merge runs the full suite.

Boundaries:
- Sources/VibeCore/LeadRecords.swift.
- The conflict handling for the records directory in Worktrees.swift (rebaseAndTest and the merge/squash paths) and in audit's trial merge, if that also refuses on it.
- Their tests.
- Don't touch other conflict handling. Don't rewrite any branch's history.

Context:
genswap's workflow forbids Co-authored-by trailers (its regression_command rejects them). All 32 trailers on its mainnet-prep branch come from LeadRecords.swift:50-51, which hard-codes one, and its lead has started a history rewrite to remove them. Workers can't edit the records (LeadLaunch.swift:84 denies it), so a branch's copy of the records only ever differs because it holds an older base: the base's version is always the right one. One records conflict on genswap waited 13.9 h until the user resolved it by hand. Evidence: /private/tmp/claude-501/-Users-albert-dev-vibeswitcher/9f1ce4d8-7f5e-4b39-b432-f985b701d5ec/scratchpad/genswap/report.md (read only).
