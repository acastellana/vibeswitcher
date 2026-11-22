# V2 feature review: remote and web, chat and composer, notifications and sounds, the switcher and sidebar

The feature review of 2026-11-22 (`.build/notes/briefs/feature-review.md`), for four `###` groups of
[v2-parity.md](v2-parity.md). For each row, V1's behaviour was read in its code (`Sources/VibeSwitcher`, `Sources/VibeCore`)
and V2's was looked at, not taken from the row: the page on a scratch node (`scripts/sandbox-server.sh --web-root`,
FakeClaude sessions, a fake lead with a board) in headless Chrome at desktop and phone widths, and the node's code.

Verdicts: **good** (does what a V1 user relies on, as well or better), **improve** (works, but worse than V1 in a way a
user notices), **missing**, **blocked** (waits on a user decision or a real Mac).

## The switcher, sidebar and attention

| Row | Verdict | Why | Fix |
| --- | --- | --- | --- |
| The session list with its states | improve | The states, times, the lead's question count and its team fold are there and live. Two of V1's row marks aren't: the green check on a lead whose board cleared since you last opened it (`WindowRowView.allDone`), and a replaced lead's row (V1 greys its LEAD tag and says it was replaced and where to continue); on the page a replaced lead reads as a live lead with its old status. | The lead's row shows a check while its board's all-done mark is unseen (`board.allDone.seen`); a session the lead's record lists as `replaced` reads "replaced" with a grey tag and links to the lead that took over. |
| Group by attention or by project, filter | good | Both groupings and the filter (⌥F) behave as V1's; the filter narrows by title, project and folder. | |
| Next needing you, 1–9, next and previous | good | Ctrl+J / ⌥ digits / ⌥↑↓ as V1's ⌘ keys, where the browser lets a page have them (README's Keys). | |
| Command palette | good | Sessions first, then V1's commands with their keys; the session's actions; new session and lead forms. | |
| Start page | good | What needs you, Brief me, the new session and lead forms with their lines, recent projects. | |
| Inspector | good | Overview (branch, pid, command, size, usage), Activity, Team (tasks with details, records, results). | |
| A finished session counts as seen | good | `seen` after 1.5 s on a finished session, V1's rule. | |
| Menu bar dots and popover; sidebar mode, Spaces, hot key | good (not needed) | macOS only; a design non-goal. | |
| Statistics window | good | `#/stats` and `vibeswitcher stats`, V1's own wording. | |

## Chat and composer

| Row | Verdict | Why | Fix |
| --- | --- | --- | --- |
| Read a conversation | good | Prompts, replies (markdown to nodes), folded tool runs with diffs, to-dos and output, paged history, a windowed list that scrolls a long chat as a short one. | |
| Team messages | good | Shown as cards under their sender. | |
| Images in the chat | good | Pictures from `chat.image`, wide when tapped. | |
| Composer | good (within scope) | `/` and `@` complete, images paste, drop, pick or go by path; it leaves drafts that `vibeswitcher send` types. Typing from the page itself is the H1 decision (out of scope). | |
| Answer a session's own prompt | good (within scope) | The card shows the question and the `reply` line; answering from the page is H1's. | |
| Find, Export, Copy as Markdown, Edit, Send Again | good | All there; find covers rows not drawn. | |
| "New since you looked" marker | improve | The marker and its summary are drawn, but the chat opens at its end. V1 opens where you were reading in that chat, else at the marker (its top), else at the end (`ChatView.initialScroll`): coming back to a busy chat you start at what you haven't read, not after it. | The chat opens at the place you left it in this page (by its top row), else with the marker at the top, else at the end. |
| Run a code block | good | V1's rules (`RunnableCommand`), a draft the user's `send` types. | |
| The all-done card | good | In the chat and on the board. | |
| Push-to-talk dictation | good | The browser's speech service, off until turned on. | |
| Chat text size | good (not needed) | The browser zooms. | |
| (seen on the page) the composer on a phone | improve | At 390 px the placeholder ("Steer Claude while it works… (↩ leaves a send-now draft, ⌥↩ one for after its turn)") wraps to two lines and is cut. | A short placeholder on a narrow screen ("Message Claude…", "Steer Claude…"); the long one where it fits. |

## Notifications and sounds

| Row | Verdict | Why | Fix |
| --- | --- | --- | --- |
| Banners when a session needs input or finishes | good | V1's two kinds, each its own toggle; a click opens the session; not for the session you look at. | |
| A sound when a session needs input | good | A chime on the page, its own toggle, off until turned on (a page can't play before a click). | |
| Reminders about waiting or stuck sessions | improve | The node works out V1's reminders (waiting on you 10 min, no progress 15) but only as `status` notices: the page neither notifies nor has V1's "Remind me about waiting or stuck sessions" toggle, so a session left waiting goes unnoticed unless you read This node. | The node carries them structured (`reminders`: session, kind, words, since); the page notifies once per reminder (as V1: once), with its own toggle beside the others, on by default as V1's. |
| Phone push notifications | blocked | The user's decisions ([the push decision note](v2-push-decision.md)). | |

## Remote and web

| Row | Verdict | Why | Fix |
| --- | --- | --- | --- |
| Phone access over Tailscale | blocked (partly good) | Reading, drafts, the phone layout and pairing are good on `web --tailnet`; key presses and answers from the phone are the H1 decision, and Chrome access waits on the remote decisions. | |
| Dev pages, previews | blocked (partly good) | Dev servers list and open on the loopback page; previews for the phone wait on the remote decisions (a proxy on the tailnet). | |
| A web page for the desktop | good | Paired by a typed code, reads and drafts, never answers; CSP, Trusted Types, no cookie. | |

## Built

The improve rows, most visible first, each its own commit with tests (see the parity rows):

1. The chat opens where you left it, else at "New since you looked".
2. Reminders about waiting or stuck sessions notify on the page, with their toggle.
3. The sidebar's all-done check and replaced leads.
4. A short composer placeholder on a phone.
