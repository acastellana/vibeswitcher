# Calm Team view

Offscreen renders of the lead's Team tab (`LeadTeamView.glance`), light and dark, drawn by
`TEAM_SNAPSHOT_DIR=$PWD/docs/eval/ux-fixes/calm-team swift test --filter TeamSnapshots`. The AI lines are fixed
strings here (no Claude runs); the question card's text field and button don't draw offscreen (yellow blocks).

- `busy-team`: a question, a fresh decision, then a task that needs you, a rework, one working, one in review, two queued, merged folded.
- `quiet-team`: one task, nine merged, earlier decisions folded.
- `fresh-decision`: a decision just taken, opened (decision and why), and a long one shown by its summary.
- `faded-decisions`: the same 2¼ minutes on, fading and blurred; `faded-decisions-history`: all folded, the history unfolded.
- `expanded-row`: the rework row opened: last failure, checkpoints with times, worker report, audit, open worker and verifier.
