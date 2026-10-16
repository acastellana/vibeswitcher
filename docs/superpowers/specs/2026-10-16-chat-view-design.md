# Chat view

Follows the window UI (spec `2026-10-16-window-ui-design.md`). The user: "let's go ham with the chat view to see
how awesome you can make it", after these problems were named: answers arrive as raw terminal text (markdown
unrendered, tables wrapped, tool noise and diffs burying the reply), scrolling back is clumsy and unsearchable,
the input is one terminal line, files and screenshots are awkward to give, and coming back to a session lands
you at the bottom of a wall of text.

## What it is

Each agent session (window or Terminal.app, Claude or Codex) can be shown as **Chat** or **Terminal**, switched
with a segmented control in the session bar (⌥⌘1 Terminal, ⌥⌘2 Chat; the last choice is remembered). Shells
have no Chat. The chat is built from the agent's own transcript; the terminal stays the live surface (it keeps
running underneath, attached, while the chat is shown).

## The conversation

- **Your prompts**: right-aligned bubbles in the accent tint, with images you attached as thumbnails.
- **Replies**: full-width, rendered markdown: headings, paragraphs, bullet and numbered lists (nested),
  blockquotes, rules, tables (real grid, header row, column alignment), inline bold/italic/code/links, and
  code blocks with a language label, syntax colors (Swift, JS/TS, Python, Go, Rust, shell, JSON, generic) and a
  Copy button.
- **Tool runs** between two messages fold into one row: an icon strip and a summary ("Ran 3 commands · edited 2
  files · read 4 files", failures in red), plus thumbnails of any images the tools returned (browser
  screenshots), visible even when folded. Expanded, each tool is a row (icon, title, duration, ✕ when failed)
  that opens to its detail:
  - commands: the command (monospaced, Copy) and its output (first 30 lines, "Show all");
  - Edit / MultiEdit: a colored line diff with 3 lines of context; Write: the file's first 40 lines with syntax
    colors; Codex patches: the patch with +/− coloring;
  - AskUserQuestion: the questions with their options (the chosen answer marked when known);
  - agents (Task/Agent): description and prompt; other tools: their input as key/value lines.
- Images (tool screenshots, pasted images) open full size in a sheet on click.
- Times: a small timestamp per prompt; a "Worked for 3m 12s" note when a turn's tools took long.

## Live state

- At the bottom while the agent works: a progress row ("Working · Run tests · 12s", with a spinner).
- When it needs you: a card "Claude is asking in the terminal" with its detail and **Show Terminal** (answering
  menus stays in the terminal for now).
- New entries appear as they're written (file checked every second while shown; incremental reads).
- **While you were away**: entries added since you last had this chat on screen get a divider "New since you
  looked · ran 4 commands, edited 2 files" and the view opens scrolled to it; otherwise at the bottom. "Jump to
  latest" pill when scrolled up.

## Finding things

⌘F in chat: a search bar over the chat; matches across prompts, replies and tool titles/commands; "3 of 12",
↩ / ⇧↩ to step, the current match highlighted and scrolled into view; Escape closes.

## Composer (window sessions)

A growing multi-line box under the chat (1–10 lines): ↩ sends, ⇧↩ newline, ↑ in an empty box recalls earlier
prompts of this session. Paste or drop an image: saved as PNG to `~/.vibeswitcher/attachments/` (private
folder) and its path inserted; drop files/folders: their quoted paths inserted. Sending writes into the
session's terminal: as a bracketed paste when the program has enabled it (so newlines stay newlines), else
newlines become spaces; Enter follows 60 ms later. Control characters other than newline and tab are removed.
You can send while it works (the agents queue it). For Terminal.app sessions the composer is replaced by
"Runs in Terminal · Move to Window to reply here" with the Move button.

## Loading

The last 4 MB of the transcript first; "Load earlier" reads the previous 4 MB. Each read is parsed off the main
thread. Tool results are matched to their calls across reads. Ended window sessions keep their chat (the
transcript path is remembered while the row exists).

## Testing

VibeCore, unit-tested: markdown block parsing, syntax tokens, line diff with context, the chat transcript
reader (Claude and Codex lines incl. images, results across reads, AskUserQuestion, edits), timeline grouping
and summaries, away marker, search matches, composer text preparation (sanitizing, bracketed paste). Views are
checked with captures on scratch sessions; composer sending is tested on a scratch window session only.

## Out of scope (next)

Answer cards with buttons for permission prompts and questions; statistics; file tree; previews pane.
