# VibeSwitcher 2: the page, redesigned around the lead (2026-11-23)

The design the user settled while prototyping on the real node's data on 2026-11-23. The prototype is the reference
for layout and behaviour: `~/projects/vibeswitcher-ui-concepts/real-data/quick2.py` (it writes one self-contained page
from a snapshot of the node; `quick.py` holds how each line is derived). Where this text and the prototype differ, this
text wins.

## Why

The page mirrored the Mac app: a list of every session, a chat with every tool call. On the real node that was ten
rows of mostly noise, and the home said "Nothing needs you" while two things did. The user's words:

- "When I'm looking at a specific project, I want to just be talking to the lead … telling me as little as possible so
  that I don't get noise … very clean messages between the leader and myself, and decisions that need to be taken or
  status updates."
- "A list of the projects and the settings, and just the ultra-high-level stuff on the left side, small. Then in the
  center, the lead of whatever project we have selected. On the right side, the detail on the project: the tasks that
  are ongoing and whatever stats we have … similar to what we have on the Mac application, maybe a little bit better
  organized."
- "Very confusing: sometimes the tree is on the right side or the left." "I don't like having to go back."
- "We need different high-level goals so that we can keep track of everything. At the moment there are only tasks."
- "We need a system to estimate the duration of the tasks … part of the conversation between the lead and the worker,
  and then see how well they're actually doing the estimation."
- "It needs to be completely fully accessible and doable, everything from the website." "For now trust the page
  completely."

## Goals

1. Opening the page says, before anything is read, whether something waits on the user and where.
2. One project at a time: the user and its lead, nothing else in the centre.
3. Everything the user can do is doable from the page.
4. A roadmap per project in goals, with dates that are measured against what happened.

Not goals: the Mac app's window (unchanged); a phone layout beyond "usable"; cost panels.

Anti-goals: anything that moves between columns; bordered cards with a coloured edge; long text shown by default; an
invented number or date presented as the lead's.

## The layout: three fixed columns

One header row across all three, one gutter, one section-title style. Nothing changes sides in any state.

**Left, small (about 220 px).** The projects, each with a ring of its tasks by state and one line (`2 need you`, `4 in
motion`, `quiet`). New project. At the bottom: Your own sessions, This node, Settings. A one-line summary under them
(`1 need you · 4 in motion`). The session list of the old page is gone from here: sessions outside a project live
under Your own sessions.

**Centre.** The selected project. A header saying what needs the user (`2 things need you`, red, or `Nothing needs
you`), a switch between **Lead** and **Roadmap**, and in Lead the noise dial. Under it the team strip (counts by state,
each with its colour).

- **Lead**: only what passes between the lead and the user, one line each, oldest first:
  - a decision the lead asked (the question itself as the line: the first sentence that asks, else the first sentence),
    with the user's answer under it as theirs; an answered one is drawn muted, only an open one in the asking colour;
  - a result (what landed);
  - with the dial at its widest, the lead's status updates.
  Hashes are shortened to eight characters, a line is cut at a word.
  The whole text of any line opens in a side sheet rendered from its markdown (bold, code, lists, tables). Never a
  "more" link in the flow.
  **What waits on the user** sits at the bottom, above the message box, under `N question(s) for you`: who asks and
  since when, whether it blocks, the question, each option a full-width row, "or answer in your own words", and one
  line on what answering does. Two cards about one matter are shown as one (the node says which cards belong together:
  a held config change and the lead's question about it).
  Answering in the page sends the answer; the question leaves, the answer joins the conversation with "take it back"
  while the lead hasn't read it.
- **The dial** has three levels, each with its count: *Waiting on me* (open questions only), *Decisions and results*
  (the default), *Everything* (status updates too). Changing it keeps the view at the newest line.
- **Roadmap**: below.

**Right (about 320 px), tabs.** *Team*: the lead's latest statement and its time; tasks in motion and blocked, each
with a five-step bar (queued, working, audit, ready to merge, merged) in its state's colour; the queued count. A task
opens **in place**, under itself: its latest note, its audit, why it is blocked and on whom it waits, since when, and a
link to the worker's chat. *Stats*: the project's scorecard. *Files*: the lead's files and the project's place.
The right column is hidden in the Roadmap view.

**Other screens** (in the centre, same columns): Your own sessions (sessions outside a project, with the session view
the page has today: chat, terminal, inspector), This node (health, build, plugins), Settings, a worker's chat.

State colours, one meaning each, used everywhere: asked of you; working; in review or audit; ready or merged; blocked;
queued. Scrollbars are thin, without buttons. Light and dark. The page's words follow the browser's language (English
and Spanish first; a string table, no library).

**Deep links.** The address says what is on screen and back/forward walk it:
`#/p/<project>/lead?show=asks|all&tab=stats|files&task=<slug>&sheet=<item>`, `#/p/<project>/roadmap?open=<goal>,…`,
`#/sessions`, `#/s/<session>`, `#/node`, `#/settings`. The old `#/s/…`, `#/p/…` addresses keep working.

## Goals (new in the node)

A project's lead keeps three to five goals and every task belongs to one.

- A goal: an id, a title in plain words, one line on what "done" means, an order, `open` or `done`.
- The lead's tools gain: set the goals (add, rename, reorder, close), and a task's goal (at `plan_task` and later). A
  task with none is "unsorted" and the lead is reminded at its next step while any is.
- The board carries the goals and each task's goal; so do the wire and `vibeswitcher board`.
- Kept in the lead's records with the board (the lead's own data: no new trust).
- A lead that keeps no goals costs nothing: the roadmap falls back (below).

## Estimates (new in the node)

- **Given by the worker, to the lead**: when a worker starts (its first progress report) and at each later one it says
  a likely time to done and a worst case, in minutes (`report_progress` gains `likelyMin`, `worstMin`; the lead's
  brief to a worker asks for them). The lead may set or correct a task's estimate itself.
- **Recorded by the node**: for every task its estimates as given (each with its time), when it started, each state
  change, when it merged.
- **Scored**: per project, how actual time to merge compares with the first likely estimate, over the last 20 merged
  tasks (the median ratio, and how many landed within the worst case). The correction is that ratio.
- **Forecast**: a task's landing is its corrected remaining estimate; a queued task's is placed after what it waits on
  and by the number of workers the project runs; a goal's is its last task's. Each is shown as a likely time and a
  range (to the corrected worst case). A blocked task has no date and says on whom it waits.
- A project with fewer than five merged tasks with estimates says so and shows the uncorrected numbers.
- The Stats tab shows the score ("estimates here run 1.8× over; 70% land inside the worst case").

## The roadmap view

A time axis from a little before now to the last landing: now, the hours of today, each midnight.

- **With goals**: one row per goal: its bar from its first start to its landing, the likely range as a band, a mark
  where each of its tasks lands (a diamond at now for a blocked one), the date and range on the right. A goal opens in
  place to its tasks, one line each, joined to it by branch lines, each with its own bar and date.
- **Without goals**: the tasks in motion, the blocked ones, and the queue as one band ("12 more tasks, all by …"),
  which opens to its rows.
- Every date says it is an estimate and where it comes from (the worker's, corrected by this project's history).

## Acting from the page (a change to the user's-voice rule)

Decided by the user on 2026-11-23: "for now trust the page completely", after being told what it costs: any process
that reaches a paired page's token can then act as the user, a team's own session included (it could approve its own
merge). Recommended instead, and the planned next step: a passkey touch per acting request.

- A paired page on **this machine's loopback** may send every request the command line can: answer, approve (single
  and batch), config and base accept or keep, send, tell, reply, new, end, rename, pause, resume, reopen, lead start
  and stop, settings, plugin on and off and add and remove, push and decline, hooks install, switch, stop. Each is
  recorded in the vault as the user's action as today, marked as made from a page (which token, which origin).
- A page reached over the **tailnet** keeps today's rule (reads and drafts) until the user decides otherwise.
  *2026-11-25, the user's answers:* the phone's page moves to HTTPS through `tailscale serve`, and page input reaches
  every session with each device's own key checked per message ([the H1 plan](../../process/v2-h1-plan.md#what-h1-alone-doesnt-decide-the-users-decisions));
  the rule above stands until that is built.
- One setting, `web_acts`: `off` (today's rule), `on` (this decision). The user turns it on from a terminal once; the
  node says what it means when they do. Off by default on a new node.
- The confirmation step is one seam (`PageVoice`): today "none"; a passkey check slots in there without touching the
  kinds or the page.
- What a page shows before an acting click is what the command line shows before its code: the card whole, the batch
  listed, the command of a shell request in full.
- `status` and This node say the page can act and since when.
- One pairing serves every tab of that origin in that browser profile: the tabs pass its secret to each other in memory
  (a BroadcastChannel named by the origin's host and port), never through storage, never inside a frame, and a tab
  holding another pairing's token keeps its own.
- What that widens: any script that runs on the node's own origin could ask for the secret. Nothing else runs there:
  the page's content policy allows only its own scripts, it is never framed (`frame-ancestors 'none'`), and plugin
  pages are served on their own port, another origin.

As built (the node's side, after its security reviews):

- `web_acts` is a level, kept in the host's vault, never a file:
  - `off` is the default: pages read and draft.
  - `confirm` asks for a passkey at each act. That check isn't built yet, so the node refuses this level for now.
  - `trust` lets each click act as you.

  Only a terminal raises the level. A page may lower it.
- A page is admitted only on a token the host's vault knows. A host restart therefore needs every page paired again.
- Pairing is confirmed in the terminal. The page that opens `vibeswitcher web`'s address shows three words. The
  terminal asks you to type the words your own page shows, then your code.
  - Only then does that page get its pairing secret, once, on its open connection. It keeps the secret in memory only.
  - A page that merely took the address first stays a reader. So does any page after a reload.
  - A confirmed pairing watches the hosted terminals at every level, and acts as the level allows. It lasts 12 hours
    at most.
  - Turning acting off, revoking, or the pairing running out ends it at the next request. Any terminal stream it has
    open closes too.
- On a card or a batch, the page sends what it drew. If the card has changed since then, the node refuses
  (`changed`). This is checked again once the confirmation is given.
- A page never accepts a held config change whose review floor or guard rails differ from the recorded ones. The same
  goes for a first accept, or a change whose snapshot isn't sealed by this host's vault. Those are the terminal's.
- Masking shields pages only. The node masks pairing codes (and `#pair=` addresses, plain or percent-encoded) in what
  it serves a page:
  - a terminal's bytes, matched on what the screen shows, so cursor moves, colours and line breaks don't hide a code;
  - a transcript's text.

  Transcripts on disk (`~/.claude`, `~/.codex`) are not masked, and neither is a terminal you read yourself. A process
  that reads them can still read an address there. That alone no longer gives it a page that watches or acts: the
  terminal's confirmation stands in the way.
- What the terminal-only list protects, and what it doesn't. It keeps an acting page's token from widening its own
  reach, or from lasting:
  - A page can't raise `web_acts`, pair another page, switch the node to other code, install the agents' hooks, add a
    plugin, or start the node.
  - It can't set the review floors, the working policy, the reviewers' models, the guard rails, lead mail or a
    plugin's settings.
  - It can't accept a held config change that would change those.
  - An approve list from a page leaves out what a page may not approve.

  It does **not** keep an acting page from doing what you can do in a session's day. A page can:
  - accept a held config change that keeps the floor and rails as recorded, or a base move;
  - answer and approve the leads' cards, merges included;
  - edit the session presets;
  - send text into any session, and start and end sessions;
  - stop the node.

  So at `trust`, whatever holds a page's two secrets while it is open acts as you there. That is the cost the user
  accepted ("for now trust the page completely"). `confirm`, a passkey touch per request (`PageVoice`), is the
  planned next step.

## Constraints

- The page stays plain HTML, CSS and JavaScript, embedded, no framework, no remote anything (its content policy).
- Text from agents is drawn inert, as today; the side sheet's markdown renderer builds DOM nodes, never HTML strings.
- Snapshots in parts, the chat window and typed kinds stay as they are; new fields go through `WireSchema`.
- Nothing under `Sources/VibeSwitcher`, `Tests/VibeSwitcherTests` or `Web/` is edited. The lead's tools live in
  `VibeCore`, shared with the Mac app: additions only, each with a port-map row.

## Approaches considered

1. **Rework the page in place, on today's wire, then add goals, estimates and acting** (chosen). The layout, the lead
   conversation, the dial, tabs, in-place tasks and deep links need nothing new from the node; they ship first and the
   user judges them on the real node. Goals, estimates and acting are each a node change with its own review.
2. **Build the node's side first.** The roadmap would be real from day one, but nothing would be visible for a week.
3. **A second page beside the old one.** Safer to switch back, but two pages to keep and the budget (1 MiB embed) is
   95% used.

## Build order

1. The page: three columns, the lead conversation and dial, the waiting block, tabs, tasks in place, the side sheet,
   deep links, the language table, the other screens moved under the left links. Roadmap in its without-goals form
   from data the board has (no dates yet). `PageCheckTests` and the real-node page check follow the new page.
2. Acting from the page (`web_acts`, `PageVoice`, the kinds, the record's mark), with an independent security review.
3. Goals (the lead's tools, the board, the wire, the roadmap's with-goals form).
4. Estimates (the report's fields, the record, the score, the forecast, the dates on the roadmap and Stats).

## Left to the builder

The exact markup and CSS (the prototype's are a starting point, not a requirement); how the page groups two cards
about one matter until the node says so (step 1 may leave them as two); the string table's shape; the forecast's code.
