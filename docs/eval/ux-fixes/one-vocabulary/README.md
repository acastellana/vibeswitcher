# One vocabulary for one state (WL-3)

Every surface names a session's state with the word `StateWord` (VibeCore, `Models.swift`) gives it: Needs you,
Working, Background, Done, Idle, Paused, Ended (and Unknown, when nothing says). After a count it says "1 needs you",
"2 need you", "1 in background". Every duration is `Durations.short`: 45s, 12m, 3h 5m, 2d 4h.

| Was | Now |
|---|---|
| Row: "waiting", "background jobs", "status unknown" | "needs you", "background", "unknown" |
| Group header: "Ready" | "Done" |
| Pill and popover: "Needs input" | "Needs you" |
| Phone chips: "1 need you", "1 background" | "1 needs you", "1 in background" |
| Popover: "26h 0m"; rows and pill: "1d" | "1d 2h" everywhere |

Pictures, light and dark:

- `popover-and-sidebar-*.png`: the popover's and the sidebar's session rows, the menu bar and the pill
  (`STATUS_SNAPSHOT_DIR=… STATUS_SNAPSHOT_NAME=popover-and-sidebar scripts/test.sh --filter StatusSnapshots`).
- `window-rows-*.png`: the window's sidebar list by attention, with its group headers, a row per state and the Ended fold
  open; `window-pills-*.png`: the header's pill for each state
  (`GLOSSARY_SNAPSHOT_DIR=… scripts/test.sh --filter GlossarySnapshots`).
- `phone-*.png`: the phone's list at 390 px, from Web/ with a stubbed `/api/state` (one session per state, one paused),
  in headless Chrome.

`GlossaryTests` holds it: a lint of the string literals in Sources/VibeSwitcher, Sources/VibeCore and Web/app.js for
words outside the glossary; the glossary on the rows, headers, pill and `/api/state`; app.js's `WORDS`, `counted` and
`short`, run in JavaScriptCore, against `StateWord` and `Durations.short`; and no duration arithmetic of their own in the
popover, the rows or the phone.
