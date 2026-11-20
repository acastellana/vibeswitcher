import Foundation

/// The fake Claude Code the engine's tests run on a scratch host's sessions (`NodeHarness`), copied from the app's
/// tests (`Tests/VibeSwitcherTests/FakeClaude.swift`, the port map's "Copied from the app"), with what the node needs
/// besides: a launcher, so the process table sees it as Claude (`install(in:)`); Claude's own arguments taken and
/// skipped; its files per terminal (`--fake-folder`); and one more control op, `mcp`, which calls a tool of the tool
/// server its `--mcp-config` names. The three positional arguments the app's harness passes still work. Started
/// through its launcher, it writes its shell snapshot at its start, as Claude Code does
/// (`<CLAUDE_CONFIG_DIR or ~/.claude>/shell-snapshots/snapshot-bash-<ms>-<random>.sh`, the start plan's ST-D19), never in
/// the account's own home.
enum FakeClaude {
    /// Where an installed fake is: its launcher (`claude`, the program a session runs) and the folder its sessions'
    /// files go in.
    struct Install: Sendable {
        /// `<fake-bin>/claude`: `exec <fake-bin>/py/claude -I -u <script> --fake-folder <folder> "$@"`.
        let launcher: URL
        /// `<folder>/<terminal>/transcript.jsonl`, `control.jsonl`, `state.json`: each session's own.
        let folder: URL

        /// The files of the fake running on `terminal` (`HostSession.tty`: `ttypts3` on Linux, `ttys003` on the Mac). A
        /// fake starts them fresh: the folder an ended fake left on that terminal (Linux hands a pty's number out again)
        /// it moves aside first, to `<terminal>.ended-<8 hex>`, so a control line written before the fake starts isn't read.
        func files(terminal: String) -> Files {
            let own = folder.appendingPathComponent(terminal, isDirectory: true)
            return Files(transcript: own.appendingPathComponent("transcript.jsonl"), control: own.appendingPathComponent("control.jsonl"),
                         state: own.appendingPathComponent("state.json"))
        }
    }

    struct Files: Sendable {
        let transcript: URL
        let control: URL
        let state: URL
    }

    /// Writes the fake into `folder` (made if missing): `fake-bin/fake_claude.py`, `fake-bin/py/claude` (a symbolic link
    /// to `/usr/bin/python3`: exec'd by that name, the process's `comm` is `claude` and its `argv[0]` ends in `claude`,
    /// which `ProcessTable.identify` needs), the launcher `fake-bin/claude` (copied by `/bin/cp` from `claude.sh`), and
    /// the sessions' folder `fake/`. From a thread that may block (it waits for the copy). `program`: the link's path under
    /// `fake-bin/py`, the name the fake runs by; `share/claude/versions/2.1.328` runs it as Claude Code's native installer
    /// does when started by its resolved path (the user's node, EN-D13): `comm` and `argv[0]` its version, not `claude`.
    static func install(in folder: URL, program: String = "claude") throws -> Install {
        let bin = folder.appendingPathComponent("fake-bin", isDirectory: true)
        let py = bin.appendingPathComponent("py", isDirectory: true)
        let python = py.appendingPathComponent(program)
        let sessions = folder.appendingPathComponent("fake", isDirectory: true)
        for made in [python.deletingLastPathComponent(), sessions] { try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true) }
        let file = bin.appendingPathComponent("fake_claude.py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: python.path, withDestinationPath: "/usr/bin/python3")
        let launcher = bin.appendingPathComponent("claude")
        // Written here as data (`claude.sh`, never exec'd), and copied to the launcher by a child: this process never
        // holds the launcher open for writing, so no child it starts meanwhile (another test's session, a git) can
        // inherit that and make exec'ing the launcher fail (ETXTBSY) while it lives.
        let text = bin.appendingPathComponent("claude.sh")
        try """
        #!/bin/sh
        exec \(quoted(python.path)) -I -u \(quoted(file.path)) --fake-folder \(quoted(sessions.path)) "$@"

        """.write(to: text, atomically: true, encoding: .utf8)
        guard try runToEnd("/bin/cp", [text.path, launcher.path]) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: launcher.path])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return Install(launcher: launcher, folder: sessions)
    }

    /// `text` as one word of a shell line.
    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static let script = #"""
# A stand-in for Claude Code on a scratch pty, for the chat sync harness (ChatSyncTests). It draws what Claude Code
# 2.1.303 draws for the parts the chat mirrors, read from its own UI code: the prompt box and queued messages, an
# AskUserQuestion (tab bar with the open tab on a coloured background, single- and multi-select rows, "Type
# something." free text, "Chat about this", the Submit / Next row, the review tab), a permission prompt and the
# /model picker; it takes keys the way those do, and writes the transcript lines Claude writes.
#
# Usage: python3 -I -u fake_claude.py TRANSCRIPT CONTROL STATE (the app's harness), or
#        python3 -I -u fake_claude.py --fake-folder FOLDER [Claude's arguments] (the node's, through its launcher): its
# TRANSCRIPT, CONTROL and STATE are FOLDER/<its terminal's name>/transcript.jsonl, control.jsonl and state.json, so a
# lead and its workers each have their own. Claude's own arguments (--settings, --mcp-config, --model,
# --permission-mode, --append-system-prompt, each with its value, any other flag alone) are taken and skipped, but
# --mcp-config is kept for the "mcp" op; a trailing prompt is submitted at the start, as Claude's is.
# The test appends JSON lines to CONTROL ({"op": "ask" | "permission" | "work" | "take" | "done" | "freeze" | "thaw" |
# "turns" (from now on a prompt starts a turn, as Claude's do: it works until "done") | "slowShell" (from now on a `!`
# command runs until "background", which moves it to the background as the 120 s Bash timeout does) | "imageRead" (how
# long a pasted image path takes to read, "seconds") | "child" (it starts `sleep 600` and goes on: in its own process
# group, as a background shell, or with "foreground" in one of its own that takes the terminal's foreground; its pid
# goes in "children"; "program": another path to run as `sleep`, a link to it by another name) | "realShell" (from now on a `!` command really runs, in zsh, its output what it printed: the
# sandbox's, to show a code block's Run) | "voice" (its /voice, as code.claude.com/docs/en/voice-dictation tells it: "mode"
# off | hold | tap, "account" yes | none (no claude.ai sign-in: "Unknown command: /voice") | expired (it can't use the
# sign-in: "Voice mode requires a Claude.ai account"), "transcript", "interim" (what it shows dim while it listens; the
# transcript's first half by default; "" for silence, its level cursor grey), "warmup" (repeats before it listens), "gap"
# (seconds without a repeat that end a hold), "statusLine" (a custom status line: the footer shows it and never the
# voice footer, and the box its caret, as a focused terminal's), "focusEvents" (it asks for focus events, DECSET 1004,
# and takes CSI I and CSI O as them; else they're Esc and typed text), "focused" (its terminal has focus: only then
# does it draw its caret and level cursor), "processing" (seconds a recording takes to process once it ends: a
# Space then is typed, and it drops what it heard if the box changed meanwhile, as 2.1.312's input_diverged), "stuck" (a
# recording goes on after the Spaces stop, until Esc), "loud" (its level cursor coloured though no words show), "wrap"
# (a box wider than this many characters is word-wrapped onto rows of its own, as Claude Code draws a long draft, and ⌃U
# deletes only the row the caret is on, as its deleteToLineStart does)) | "voiceStop" (it stops listening by itself, as after 15 s of silence) |
# "processed" (the recording being processed is done now, whatever "processing" said) | "print" (the bytes of "file"
# written on its terminal, as a command's output) |
# "trust" (its folder-trust question, as 2.1.30x draws it at the start in a new folder: rows with no numbers, the cursor
# on "No, exit"; Enter there or Esc quits, Enter on "Yes, I trust this folder" goes on, "trusted" true in STATE; with
# "lose", that many of its first keys are lost, as a menu not yet taking keys loses them) | "autoMode" (2.1.329's
# "Teach auto mode about your environment?" popup over its box: Esc closes it, "autoMode" "declined" in STATE; Enter on
# Continue "scanned"; Space or Enter on a setting toggles it) | "dialog" (a dialog it draws over its box that nothing
# reads: "lines", the text drawn; Esc closes it) |
# "exit" (it quits, as /exit) | "mcp" (the node's: {"op": "mcp", "tool": NAME, "arguments": {...}} starts the tool
# server its --mcp-config names, a path or inline JSON, "server" or the one named vibeswitcher or the first; sends
# initialize and the tools/call, and records the reply, or what failed, in "mcp" in STATE)).
# Its /voice keeps Claude Code 2.1.312's timings: a repeat chain breaks 120 ms after the last Space (the key let go),
# 5 repeats start recording, and a second push of the key within 300 ms of a transcript going in sends it. A held
# Space's first two presses are typed and its later repeats swallowed until it records, when those two go. Esc cancels a
# recording, or one being processed (2.1.312: any voice state but idle), the box as it was before it.
# the agent writes its state (mode, tab, answers, the free-text field, queued messages) to STATE after every change.
import datetime
import json
import os
import re
import select
import signal
import subprocess
import sys
import threading
import time
import tty
import uuid

# Claude's own flags that take a value (each skipped with it); any other flag is skipped alone.
CLAUDE_VALUES = ("--settings", "--mcp-config", "--model", "--permission-mode", "--append-system-prompt", "--resume")


def terminal_name():
    """Its terminal's name as the node's session list has it: /dev/pts/3 is ttypts3, /dev/ttys003 ttys003."""
    name = os.ttyname(0)
    name = name[len("/dev/"):] if name.startswith("/dev/") else os.path.basename(name)
    name = name.replace("/", "")
    return name if name.startswith("tty") else "tty" + name


def parse(argv):
    """(TRANSCRIPT, CONTROL, STATE, the --mcp-config given, the prompt given, its terminal's name)."""
    folder, mcp, positional = None, None, []
    index = 0
    while index < len(argv):
        arg = argv[index]
        name, _, inline = arg.partition("=")
        if name == "--fake-folder" or name in CLAUDE_VALUES:
            value = inline if inline else (argv[index + 1] if index + 1 < len(argv) else "")
            index += 1 if inline else 2
            if name == "--fake-folder":
                folder = value
            elif name == "--mcp-config":
                mcp = value
            continue
        if arg.startswith("--"):
            index += 1
            continue
        positional.append(arg)
        index += 1
    if folder is None:
        return positional[0], positional[1], positional[2], mcp, None, None
    terminal = terminal_name()
    own = os.path.join(folder, terminal)
    if os.path.exists(own):
        # An ended fake's, on a pty number handed out again: this one starts fresh, its control lines unread.
        os.rename(own, own + ".ended-" + uuid.uuid4().hex[:8])
    os.makedirs(own)
    return (os.path.join(own, "transcript.jsonl"), os.path.join(own, "control.jsonl"), os.path.join(own, "state.json"), mcp,
            positional[-1] if positional else None, terminal)


TRANSCRIPT, CONTROL, STATE, MCP_CONFIG, PROMPT, TERMINAL = parse(sys.argv[1:])


def resumed(argv):
    """The conversation --resume names (None: none), as Claude Code takes it."""
    for index, arg in enumerate(argv):
        name, _, inline = arg.partition("=")
        if name == "--resume":
            return inline if inline else (argv[index + 1] if index + 1 < len(argv) else None)
        if arg == "--":
            break
    return None


for path in (TRANSCRIPT, CONTROL):
    if not os.path.exists(path):
        open(path, "a").close()
ESC = "\x1b"
RULE = "─" * 60
TAB_BG = ESC + "[48;2;177;185;249m" + ESC + "[38;2;0;0;0m"
PLAIN = ESC + "[49m" + ESC + "[39m"
TICK = "✔"

state = {
    "mode": "idle",          # idle | working | question | permission | picker
    "input": "",
    "queued": [],
    "reply": "Ready.",
    "frozen": False,
    "turns": False,          # a prompt starts a turn (working until "done")
    "pid": os.getpid(),
    "suggest": 0,            # the slash menu's chosen row
    "dismissed": False,      # Esc closed the slash menu (until the box changes)
    "slowShell": False,      # a `!` command runs until "background" (Claude Code's 120 s Bash timeout)
    "realShell": False,      # a `!` command really runs (in zsh), as Claude Code's do
    "imageRead": 1.0,        # how long a pasted image path takes to read (see `take_paste`)
    "reading": False,        # pasted image paths are being read
    "images": 0,             # the session's images so far ([Image #N])
    "attached": 0,           # the images in the box
    "droppedEnters": 0,      # Enters held back while images were read, then dropped
    "children": [],          # the pids of the children "child" started
    "enters": 0,             # Enter keys taken in the prompt box
    "voice": "off",          # /voice: off | hold | tap
    "voiceAccount": "yes",   # yes | none (/voice isn't a command) | expired (it can't use the sign-in)
    "transcript": "open the composer view on main",
    "interim": None,         # what it shows dim while listening (None: the transcript's first half)
    "warmup": 5,             # key repeats before a held Space starts recording
    "gap": 0.12,             # no repeat this long: the key was let go (the chain breaks)
    "doublePush": 0.3,       # a second push this soon after a transcript went in sends it, 120 ms on
    "disarms": 0,            # sends a double push armed or could, called off by another key
    "processing": 0.0,       # seconds a recording takes to process once it ends (0: its transcript goes in at once)
    "stuck": False,          # a recording goes on after the Spaces stop, until Esc
    "loud": False,           # its level cursor coloured though no words show (a level heard, the words not in yet)
    "dropped": 0,            # transcripts dropped: the box changed while they were processed
    "doubleSubmits": 0,      # prompts sent by a double push
    "statusLine": False,     # a custom status line in the footer, never its voice footer; the box shows its caret
    "focusEvents": False,    # it asked for focus events (DECSET 1004)
    "focused": True,         # its terminal has focus: it draws its caret and level cursor
    "focusIns": 0,           # CSI I taken
    "focusOuts": 0,          # CSI O taken
    "recording": "",         # "" | warming | listening | tap
    "voiceMessage": "",      # what its footer says about dictation
    "voiceStarts": 0,        # recordings started
    "longestGap": 0.0,       # the longest a recording went between two repeats (seconds)
    "heldRepeats": 0,        # repeats taken while recording
    "voiceCancels": 0,       # recordings cancelled (Esc)
    "voiceInserts": 0,       # transcripts written into the box
    "strayed": 0,            # spaces typed by held chains that broke before recording (a stall past "gap"): they stay
    "killed": 0,             # ⌃U taken
    "wrap": 0,               # the box's width for a long draft, word-wrapped onto rows (0: one line, as the pty wraps it)
    "terminal": TERMINAL,    # its terminal's name (None: started with the app harness's three files)
    "prompt": PROMPT,        # the prompt it was started with (None: none)
    "resume": resumed(sys.argv[1:]),  # the conversation --resume carried on (None: a fresh one)
    "mcp": [],               # the "mcp" op's calls: {"tool", "reply"} or {"tool", "error"}
    "trusted": False,        # "Yes, I trust this folder" chosen on the "trust" op's question
    "trustLose": 0,          # the trust question's keys still to be lost (the op's "lose")
    "autoMode": "",          # its auto-mode popup: "" never shown, "open", "declined" (Esc), "scanned" (Continue)
}
MCP_DONE = threading.Event()  # an "mcp" call has finished: STATE to be written
MCP_LOCK = threading.Lock()
# "awaiting": a transcript went in and a second push of the key would send it (2.1.312's awaitingVoiceSubmitDoubleTap);
# "push": when the first push came; "submitAt": when an armed send fires (120 ms after the second push); "typed": the
# spaces the chain going now typed (its first two presses).
VOICE = {"before": "", "last": float("-inf"), "repeats": 0, "awaiting": False, "push": 0.0, "submitAt": None,
         "until": 0.0, "box": "", "processed": 0, "typed": 0}
METER = ESC + "[38;2;215;119;87m" + "▃" + ESC + "[39m"   # its recording-level cursor: a coloured bar, not dim
QUIET = ESC + "[38;2;128;128;128m" + "▁" + ESC + "[39m"  # the same below a low level: grey
CARET = ESC + "[7m" + " " + ESC + "[27m"                  # a focused terminal's caret at the box's end
# claude-hud's lines, as a custom status line draws them under the box (its context bar in bar glyphs).
STATUS = ["  [Opus 5.5] vibeswitcher | 9 hooks | ctx " + ESC + "[32m" + "███░░░░░" + ESC + "[39m" + " 41%",
          "  ✓ Read ×3 | ✓ Edit ×1"]
# The slash commands its menu offers while "/…" is typed in the box.
COMMANDS = [("/clear", "Clear conversation history"), ("/compact", "Clear history but keep a summary"),
            ("/help", "Show help and available commands"), ("/model", "Set the AI model for Claude Code")]
question = None              # the AskUserQuestion on screen
permission = None
picker = None
trust = None                 # the "trust" op's question: its cursor's row (0: "No, exit", 1: Yes)
auto = None                  # the "autoMode" op's popup: {"focus", "shell", "repos"}
dialog = None                # the "dialog" op's lines
control_offset = 0
paste = None                 # bytes of a bracketed paste being read
reading = None               # a paste whose image paths are being read (see `take_paste`)
# Claude Code's image extensions for a pasted path (c0t).
IMAGE = re.compile(r"\.(png|jpe?g|gif|webp)$", re.IGNORECASE)
PNG = "iVBORw0KGgo="


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def record(line):
    line.setdefault("uuid", str(uuid.uuid4()))
    line.setdefault("timestamp", now())
    line.setdefault("isSidechain", False)
    with open(TRANSCRIPT, "a") as f:
        f.write(json.dumps(line) + "\n")


def save_state():
    snapshot = dict(state)
    if question:
        snapshot["tab"] = question["tab"]
        snapshot["answers"] = question["answers"]
        snapshot["focus"] = question["focus"]
        snapshot["texts"] = question["texts"]
        snapshot["checked"] = [sorted(c) for c in question["checked"]]
    if permission:
        snapshot["focus"] = permission["focus"]
    if picker:
        snapshot["focus"] = picker["focus"]
    if trust is not None:
        snapshot["focus"] = trust
    with MCP_LOCK:
        snapshot["mcp"] = list(state["mcp"])
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(snapshot, f)
    os.replace(tmp, STATE)


def out(text):
    os.write(1, text.encode())


# MARK: drawing

def box_rows(text):
    """The rows a draft is drawn on, as (start, end) offsets: word-wrapped at "wrap" characters (one row when it's 0)."""
    width = state["wrap"]
    rows, start = [], 0
    while width and len(text) - start > width:
        cut = text.rfind(" ", start, start + width + 1)
        rows.append((start, cut if cut > start else start + width))
        start = cut + 1 if cut > start else start + width
    rows.append((start, len(text)))
    return rows


def draw():
    lines = []
    if state["mode"] == "question":
        lines = draw_question()
    elif state["mode"] == "permission":
        lines = draw_permission()
    elif state["mode"] == "picker":
        lines = draw_picker()
    elif state["mode"] == "trust":
        lines = draw_trust()
    elif state["mode"] == "autoMode":
        lines = draw_auto()
    elif state["mode"] == "dialog":
        lines = list(dialog)
    else:
        lines.append("⏺ " + state["reply"])
        lines.append("")
        if state["mode"] == "working":
            lines.append("✻ Working… (esc to interrupt)")
            lines.append("")
        for text in state["queued"]:
            lines.append("  ⎿ " + text.replace("\n", " "))
        lines.append(RULE)
        live = CARET if state["statusLine"] and state["focused"] else ""
        if state["recording"] in ("listening", "processing"):
            # What it hears so far, dimmed until it's final; its level cursor where the caret was (focused, recording).
            words = state["transcript"].split()
            heard = state["interim"] if state["interim"] is not None else " ".join(words[:max(1, len(words) // 2)])
            cursor = (METER if heard or state["loud"] else QUIET) if state["focused"] and state["recording"] == "listening" else ""
            live = ESC + "[2m" + heard + ESC + "[22m" + cursor
        flat = state["input"].replace("\n", " ")
        drawn = [flat[a:b] for a, b in box_rows(flat)]
        drawn[-1] += live
        lines.append("❯ " + drawn[0])
        lines.extend("  " + row for row in drawn[1:])
        lines.append(RULE)
        menu = suggestions()
        footer = {"warming": "keep holding…", "listening": "listening…", "tap": "● REC · tap to send",
                  "processing": "Voice: processing…"}.get(state["recording"])
        if state["statusLine"]:
            footer = None
            lines.extend(STATUS)
        if footer or state["voiceMessage"]:
            lines.append("  " + (footer or state["voiceMessage"]))
        elif menu:
            # Claude's suggestions: paddingX 2, the chosen one with its pointer, names padded to one column.
            for index, (name, description) in enumerate(menu):
                pointer = "❯ " if index == state["suggest"] else "  "
                lines.append("  " + pointer + name.ljust(14) + description)
        elif not state["statusLine"]:
            lines.append("  ? for shortcuts")
    out(ESC + "[H" + ESC + "[2J" + "\r\n".join(lines))
    save_state()


def tab_bar():
    q = question
    parts = []
    single = len(q["questions"]) == 1 and not q["questions"][0].get("multiSelect")
    if not single:
        parts.append("←  ")
    for index, item in enumerate(q["questions"]):
        mark = "☒" if index in q["answers"] else "☐"
        title = " " + mark + " " + item.get("header", "Q%d" % (index + 1)) + " "
        parts.append(TAB_BG + title + PLAIN if index == q["tab"] else title)
    if not single:
        title = " " + TICK + " Submit "
        parts.append(TAB_BG + title + PLAIN if q["tab"] == len(q["questions"]) else title)
        parts.append("  →")
    return "".join(parts)


def rows(q):
    """The rows of the open tab: (kind, label) with kind option | other | chat."""
    item = q["questions"][q["tab"]]
    result = [("option", option["label"]) for option in item["options"]]
    result.append(("other", None))
    if not item.get("multiSelect"):
        result.append(("chat", "Chat about this"))
    return result


def draw_question():
    q = question
    lines = ["⏺ I'll ask you.", RULE, tab_bar(), ""]
    multi = len(q["questions"]) > 1 or q["questions"][0].get("multiSelect")
    hint = "Enter to select · " + ("Tab/Arrow keys to navigate" if multi else "↑/↓ to navigate") + " · Esc to cancel"
    if q["tab"] == len(q["questions"]):
        lines.append("Review your answers")
        lines.append("")
        for index, item in enumerate(q["questions"]):
            if index in q["answers"]:
                lines.append(" ● " + item["question"])
                lines.append("   → " + ", ".join(q["answers"][index]))
        lines.append("")
        lines.append("Ready to submit your answers?")
        lines.append("")
        for index, label in enumerate(["Submit answers", "Cancel"]):
            lines.append(("❯ " if q["focus"] == index else "  ") + "%d. %s" % (index + 1, label))
        lines.append("")
        lines.append(hint)
        return lines
    item = q["questions"][q["tab"]]
    lines.append(item["question"])
    lines.append("")
    is_multi = item.get("multiSelect")
    tab_rows = rows(q)
    for index, (kind, label) in enumerate(tab_rows):
        pointer = "❯ " if q["focus"] == index else "  "
        if kind == "chat":
            lines.append(RULE)
        if kind == "other":
            text = q["texts"].get(q["tab"], "")
            label = text if text else ("Type something" if is_multi else "Type something.")
        box = ""
        if is_multi:
            box = "[" + (TICK if index in q["checked"][q["tab"]] else " ") + "] "
        lines.append(pointer + "%d. " % (index + 1) + box + label)
        if kind == "option":
            description = item["options"][index].get("description")
            if description:
                lines.append("     " + description)
    if is_multi:
        last = q["tab"] == len(q["questions"]) - 1
        lines.append(("❯ " if q["focus"] == len(tab_rows) else "  ") + "   " + ("Submit" if last else "Next"))
    lines.append("")
    lines.append(hint)
    return lines


def draw_permission():
    p = permission
    if p.get("file"):
        # A file tool's prompt as Claude Code 2.1.318 builds it (read in its bundle, not captured from a terminal): the
        # title "Read file", the call it asks about as a tool-use line ("Read(<path>)"), "Do you want to proceed?".
        lines = ["⏺ Read(" + p["file"] + ")", "╭" + "─" * 58 + "╮", "│ Read file", "│", "│   Read(" + p["file"] + ")", "│",
                 "│ Do you want to proceed?"]
    else:
        lines = ["⏺ Bash(" + p["command"] + ")", "╭" + "─" * 58 + "╮", "│ Bash command", "│", "│   " + p["command"], "│",
                 "│ Do you want to proceed?"]
    for index, label in enumerate(p["options"]):
        if index == 2 and p["amend"]:
            # 2.1.316's No row with its text field open, drawn after its label (the Bash prompt's inlineDescriptions
            # make its Select pass showLabel): "No, " and the text typed, or the placeholder while there's none and
            # the cursor is on it.
            label = "No, " + (p["feedback"] or ("and tell Claude what to do differently" if p["focus"] == 2 else ""))
        lines.append("│ " + ("❯ " if p["focus"] == index else "  ") + "%d. %s" % (index + 1, label))
    lines.append("╰" + "─" * 58 + "╯")
    lines.append("Esc to cancel · Tab to amend" if p["v316"] else "Esc to cancel")
    return lines


def draw_picker():
    p = picker
    lines = ["Select model", "Switch between Claude models. Your pick becomes the default for new sessions.", ""]
    for index, label in enumerate(p["options"]):
        current = "  " + TICK if index == p["current"] else ""
        lines.append(("❯ " if p["focus"] == index else "  ") + "%d. %s%s" % (index + 1, label, current))
    lines.append("")
    lines.append("Enter to confirm · Esc to cancel")
    return lines


def draw_trust():
    folder = os.getcwd()
    lines = [" Accessing workspace:", "", " " + folder, "",
             " Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source",
             " project, or work from your team). If not, take a moment to review what's in this folder first.", "",
             " Claude Code'll be able to read, edit, and execute files here.", "", " Security guide", ""]
    for index, label in enumerate(["No, exit", "Yes, I trust this folder"]):
        lines.append((" ❯ " if trust == index else "   ") + label)
    lines.append("")
    lines.append(" Enter to confirm · Esc to cancel")
    return lines


def draw_auto():
    rows = ["How you use Claude here     Mixed", "Also scan shell history     " + ("on" if auto["shell"] else "off"),
            "Also scan your other repos  " + ("on" if auto["repos"] else "off"), "Continue"]
    lines = [" Teach auto mode about your environment?", "",
             " Claude Code reads this project, your recent Claude sessions, and optionally your shell history and other",
             " repositories. Claude analyzes this data and customizes auto mode to make better decisions.", ""]
    for index, row in enumerate(rows):
        lines.append((" ❯ " if auto["focus"] == index else "   ") + row)
    lines.append("")
    lines.append(" ↑/↓ to navigate · Space to toggle · Esc to cancel")
    return lines


def auto_key(key):
    global auto
    if key == "up":
        auto["focus"] = max(0, auto["focus"] - 1)
    elif key == "down":
        auto["focus"] = min(3, auto["focus"] + 1)
    elif key == "esc":
        auto = None
        state["autoMode"] = "declined"
        state["mode"] = "idle"
    elif key == "enter" and auto["focus"] == 3:
        auto = None
        state["autoMode"] = "scanned"
        state["mode"] = "idle"
    elif key in ("space", "enter") and auto["focus"] in (1, 2):
        name = "shell" if auto["focus"] == 1 else "repos"
        auto[name] = not auto[name]


def trust_key(key):
    global trust
    if state["trustLose"] > 0:
        state["trustLose"] -= 1
        return
    if key == "up":
        trust = 0
    elif key == "down":
        trust = 1
    elif key == "esc" or (key == "enter" and trust == 0):
        state["mode"] = "exited"
        save_state()
        out(ESC + "[2J" + ESC + "[H")
        sys.exit(0)
    elif key == "enter":
        trust = None
        state["trusted"] = True
        state["mode"] = "idle"
        state["reply"] = "Trusted."


# MARK: what happens

def suggestions():
    text = state["input"]
    if state["mode"] not in ("idle", "working") or state["dismissed"] or not text.startswith("/") or " " in text:
        return []
    return [c for c in COMMANDS if c[0].startswith(text)]


def run_command(name):
    if name == "/model":
        open_picker()
    elif name == "/clear":
        state["reply"] = "Cleared."
    else:
        state["reply"] = "Ran " + name
    state["ran"] = name

def voice_command(text):
    """/voice [hold|tap|off]: the reply it prints."""
    if state["voiceAccount"] == "none":
        return "Unknown command: /voice"
    if state["voiceAccount"] == "expired":
        return "Voice mode requires a Claude.ai account. Run /login."
    arg = text[len("/voice"):].strip()
    if arg == "off" or (arg == "" and state["voice"] != "off"):
        state["voice"] = "off"
        return "Voice mode disabled."
    state["voice"] = arg if arg in ("hold", "tap") else (state["voice"] if state["voice"] != "off" else "hold")
    return "Voice mode enabled (%s). Hold space to record. Dictation language: en (/config to change)." % state["voice"]


def voice_space():
    """A Space in the prompt box with /voice on; True when it took it (not typed)."""
    t = time.monotonic()
    if state["recording"] == "processing":
        # Its hold is over: the first two of a new chain are typed, the rest swallowed (no recording starts meanwhile).
        VOICE["processed"] += 1
        return VOICE["processed"] > 2
    if state["recording"] == "listening":
        state["longestGap"] = max(state["longestGap"], round(t - VOICE["last"], 3))
        state["heldRepeats"] += 1
        VOICE["last"] = t
        return True
    if state["voice"] == "tap":
        if state["recording"] == "tap":
            finish_recording(submit=True)
            return True
        if state["input"] == "":
            VOICE["before"] = ""
            state["recording"] = "tap"
            state["voiceStarts"] += 1
            return True
        return False
    if state["voice"] != "hold":
        return False
    if state["recording"] == "" and VOICE["awaiting"]:
        # After a transcript went in (2.1.312's push-to-talk handler): a push while a send is armed calls it off; a
        # second push within 300 ms of the first arms one, 120 ms on, and is taken; a later one calls it off. Either way
        # a push not taken goes on as a press of the key.
        if VOICE["submitAt"] is not None:
            disarm()
        elif VOICE["push"] and t - VOICE["push"] <= state["doublePush"]:
            VOICE["push"] = 0.0
            VOICE["submitAt"] = t + state["gap"]
            return True
        elif VOICE["push"]:
            disarm()
        else:
            VOICE["push"] = t
    if t - VOICE["last"] <= state["gap"] and state["recording"] in ("", "warming") and VOICE["repeats"] >= 0:
        VOICE["repeats"] += 1
    else:
        # A new chain. The spaces the last one typed stay in the box if it broke before recording (a stall past `gap`
        # between two repeats, as on a loaded Mac): a recording takes out only its own chain's.
        state["strayed"] += VOICE["typed"]
        VOICE["typed"] = 0
        VOICE["repeats"] = 0
        VOICE["before"] = state["input"]
    VOICE["last"] = t
    if VOICE["repeats"] >= state["warmup"]:
        if state["voiceAccount"] != "yes":
            state["voiceMessage"] = "Voice mode requires a Claude.ai account. Run /login."
            state["recording"] = ""
            VOICE["repeats"] = -1000
            return False
        # The warmup's spaces go; it records.
        state["input"] = VOICE["before"]
        VOICE["typed"] = 0
        state["recording"] = "listening"
        VOICE["awaiting"] = False
        VOICE["submitAt"] = None
        state["voiceMessage"] = ""
        state["voiceStarts"] += 1
        return True
    if VOICE["repeats"] >= 1:
        state["recording"] = "warming"
    # Its first two presses are typed; the later repeats are swallowed.
    if VOICE["repeats"] < 2:
        VOICE["typed"] += 1
        return False
    return True


def finish_recording(submit=False):
    """The key let go (hold) or tapped again (tap): the transcript goes in at the cursor; tap mode sends three words or more."""
    # At the cursor (the box's end here): after whatever was typed while it recorded.
    state["input"] = state["input"] + state["transcript"]
    state["recording"] = ""
    VOICE["repeats"] = 0
    VOICE["awaiting"] = state["voice"] == "hold"
    # A recording started next goes on after it (its warmup's spaces go, not the transcript).
    VOICE["before"] = state["input"]
    VOICE["push"] = 0.0
    VOICE["submitAt"] = None
    state["voiceInserts"] += 1
    if submit and len(state["transcript"].split()) >= 3:
        text = state["input"]
        state["input"] = ""
        submit_prompt(text)


def end_recording():
    """A recording ends: processed for `processing` seconds (its transcript going in after), or at once."""
    if state["processing"] <= 0:
        finish_recording()
        return
    state["recording"] = "processing"
    VOICE["until"] = time.monotonic() + state["processing"]
    VOICE["box"] = state["input"]
    VOICE["processed"] = 0


def disarm():
    """Another key (or a push that came too late) calls off the send a double push would make."""
    if VOICE["awaiting"]:
        state["disarms"] += 1
    VOICE["awaiting"] = False
    VOICE["push"] = 0.0
    VOICE["submitAt"] = None


def voice_tick():
    """No repeat for `gap`: a held key was let go. An armed double push sends. True when the screen changed."""
    if VOICE["submitAt"] is not None and time.monotonic() >= VOICE["submitAt"]:
        VOICE["submitAt"] = None
        VOICE["awaiting"] = False
        text = state["input"].rstrip(" ")
        state["input"] = ""
        state["doubleSubmits"] += 1
        submit_prompt(text)
        return True
    if state["recording"] == "processing" and time.monotonic() >= VOICE["until"]:
        if state["input"] != VOICE["box"]:
            # Typed into meanwhile: what it heard is dropped.
            state["recording"] = ""
            state["dropped"] += 1
            VOICE["repeats"] = 0
        else:
            finish_recording()
        return True
    if state["recording"] == "listening" and state["stuck"]:
        return False
    if state["recording"] in ("warming", "listening") and time.monotonic() - VOICE["last"] > state["gap"]:
        if state["recording"] == "listening":
            end_recording()
        else:
            state["recording"] = ""
        VOICE["repeats"] = 0
        return True
    return False


def submit_prompt(text):
    text = text.strip()
    images, state["attached"] = state["attached"], 0
    if not text:
        return
    if text == "/voice" or text.startswith("/voice "):
        state["reply"] = voice_command(text)
        return
    if state["mode"] == "working":
        state["queued"].append(text)
        return
    if text == "/model":
        open_picker()
        return
    if text.startswith("/model "):
        model_alias(text[len("/model "):].strip())
        return
    if text.startswith("!"):
        state["shell"] = {"command": text[1:].strip(), "at": now()}
        if state["realShell"]:
            ran = subprocess.run(["/bin/zsh", "-f", "-c", state["shell"]["command"]], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
            finish_shell(ran.stdout.decode(errors="replace").rstrip("\n"))
        elif not state["slowShell"]:
            finish_shell("ran " + state["shell"]["command"])
        return
    content = text
    if images:
        # As Claude writes a prompt with pasted images: its text (with the [Image #N] placeholders), then the images.
        content = [{"type": "text", "text": text}] + [{"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                                                                   "data": PNG}}] * images
    record({"type": "user", "message": {"role": "user", "content": content}})
    if state["turns"]:
        state["mode"] = "working"
        return
    state["reply"] = "Got: " + text.replace("\n", " ")
    record({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": state["reply"]}]}})


def finish_shell(stdout):
    """A `!` command has run (or gone to the background): Claude Code writes it only now, as 2.1.302 does: the caveat,
    the command (stamped when it was sent, `!` gone) and its output. No assistant turn follows."""
    shell = state.pop("shell")
    record({"type": "user", "isMeta": True, "message": {"role": "user", "content": "<local-command-caveat>The command below was run "
            "directly in Claude Code, not sent to you as a request, and its output goes straight to the user. It's recorded here "
            "as context for later messages.</local-command-caveat>"}})
    record({"type": "user", "timestamp": shell["at"], "message": {"role": "user",
            "content": "<bash-input>" + shell["command"] + "</bash-input>"}})
    record({"type": "user", "message": {"role": "user", "content": "<bash-stdout>" + stdout + "</bash-stdout><bash-stderr></bash-stderr>"}})


MODEL_NAMES = {"fable": "Fable 5.2", "opus": "Opus 5.5", "sonnet": "Sonnet 5.5", "haiku": "Haiku 5.5"}


def model_alias(alias):
    """`/model opus`: as Claude Code writes it, the command, then its output naming the model (no assistant turn)."""
    label = MODEL_NAMES.get(alias.lower())
    out = ("Set model to \u001b[1m" + label + "\u001b[22m and saved as your default for new sessions") if label else \
        ("Model '" + alias + "' not found")
    record({"type": "system", "subtype": "local_command", "level": "info", "content": "<command-name>/model</command-name>\n"
            "<command-message>model</command-message>\n<command-args>" + alias + "</command-args>"})
    record({"type": "system", "subtype": "local_command", "level": "info", "content": "<local-command-stdout>" + out + "</local-command-stdout>"})
    state["reply"] = out
    if label:
        state["model"] = label


def open_question(questions):
    global question
    tool = "toolu_" + uuid.uuid4().hex[:20]
    record({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": tool, "name": "AskUserQuestion", "input": {"questions": questions}}]}})
    question = {"questions": questions, "tool": tool, "tab": 0, "focus": 0, "answers": {}, "texts": {},
                "checked": [set() for _ in questions], "previous": state["mode"]}
    state["mode"] = "question"


def finish_question(cancelled=False):
    global question
    q = question
    if cancelled:
        content = "The user doesn't want to proceed with this tool use. The tool use was rejected."
        record({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": q["tool"], "content": content, "is_error": True}]}})
    else:
        answered = ", ".join('"%s"="%s"' % (q["questions"][i]["question"], ", ".join(q["answers"][i])) for i in sorted(q["answers"]))
        content = "Your questions have been answered: " + answered + ". You can now continue with these answers in mind."
        record({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": q["tool"], "content": content}]},
            "toolUseResult": {"answers": {q["questions"][i]["question"]: ", ".join(q["answers"][i]) for i in q["answers"]}}})
    state["mode"] = "working"
    state["reply"] = "Thanks." if not cancelled else "Cancelled."
    question = None


def go_to_tab(index):
    q = question
    q["tab"] = max(0, min(len(q["questions"]), index))
    q["focus"] = 0


def single_question():
    return len(question["questions"]) == 1 and not question["questions"][0].get("multiSelect")


def answer_single(value):
    q = question
    q["answers"][q["tab"]] = [value]
    if single_question():
        finish_question()
    else:
        go_to_tab(q["tab"] + 1)


def question_key(key):
    q = question
    if key == "esc":
        finish_question(cancelled=True)
        return
    if key in ("left", "shift-tab") or (key == "tab" and False):
        go_to_tab(q["tab"] - 1)
        return
    multi_tab = q["tab"] < len(q["questions"]) and q["questions"][q["tab"]].get("multiSelect")
    if key == "right" or (key == "tab" and not multi_tab):
        if not single_question():
            go_to_tab(q["tab"] + 1)
        return
    if q["tab"] == len(q["questions"]):
        # The review tab: Submit answers / Cancel.
        if key in ("up", "k"):
            q["focus"] = 0
        elif key in ("down", "j"):
            q["focus"] = 1
        elif key in ("enter", "1", "2"):
            choice = int(key) - 1 if key in ("1", "2") else q["focus"]
            finish_question(cancelled=choice == 1)
        return
    tab_rows = rows(q)
    last = len(tab_rows) if multi_tab else len(tab_rows) - 1
    focused = tab_rows[q["focus"]] if q["focus"] < len(tab_rows) else ("submit", None)
    if focused[0] == "other" and (len(key) == 1 or key in ("backspace", "space")):
        text = q["texts"].get(q["tab"], "")
        text = text[:-1] if key == "backspace" else text + (" " if key == "space" else key)
        q["texts"][q["tab"]] = text
        if multi_tab:
            # Typing into the field checks it; emptying it unchecks it.
            if text:
                q["checked"][q["tab"]].add(q["focus"])
            else:
                q["checked"][q["tab"]].discard(q["focus"])
        return
    if key in ("up", "k"):
        q["focus"] = max(0, q["focus"] - 1)
    elif key in ("down", "j", "tab"):
        q["focus"] = min(last, q["focus"] + 1)
    elif key.isdigit() and len(key) == 1:
        index = int(key) - 1
        if 0 <= index < len(tab_rows):
            if multi_tab:
                q["checked"][q["tab"]] ^= {index}
            else:
                q["focus"] = index
                question_key("enter")
    elif key in ("enter", "space"):
        if multi_tab:
            if focused[0] == "submit":
                labels = []
                for index in sorted(q["checked"][q["tab"]]):
                    kind, label = tab_rows[index]
                    labels.append(q["texts"].get(q["tab"], "") if kind == "other" else label)
                q["answers"][q["tab"]] = labels
                go_to_tab(q["tab"] + 1)
            else:
                q["checked"][q["tab"]] ^= {q["focus"]}
        elif key == "enter":
            kind, label = focused
            if kind == "other":
                text = q["texts"].get(q["tab"], "").strip()
                if text:
                    answer_single(text)
            elif kind == "chat":
                finish_question(cancelled=True)
            else:
                answer_single(label)


def open_permission(command, ui=None, plain_no=False, file=None):
    global permission
    tool = "toolu_" + uuid.uuid4().hex[:20]
    v316 = ui == "2.1.316"
    if file:
        # A Read of a file outside the working directory: the call, and the file dialog's rows (2.1.318: Yes, the
        # session row naming the file's folder, and the plain No that Tab opens, as the Bash prompt's since 2.1.316).
        record({"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": tool, "name": "Read", "input": {"file_path": file}}]}})
        folder = os.path.basename(os.path.dirname(file))
        permission = {"command": "Read " + file, "file": file, "tool": tool, "focus": 0, "feedback": "", "amend": False, "v316": True,
                      "plainNo": plain_no, "options": ["Yes", "Yes, allow reading from %s/ during this session" % folder, "No"]}
        state["mode"] = "permission"
        return
    record({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": tool, "name": "Bash", "input": {"command": command}}]}})
    permission = {"command": command, "tool": tool, "focus": 0, "feedback": "", "amend": False, "v316": v316, "plainNo": plain_no,
                  "options": ["Yes", "Yes, and don't ask again for this command",
                              "No" if v316 else "No, and tell Claude what to do differently (esc)"]}
    state["mode"] = "permission"


def permission_key(key):
    global permission
    p = permission
    choice = None
    # With ui "2.1.316", the No row as Claude Code 2.1.316 has it: a plain "No" (letters are the menu's keys: j and k
    # move the cursor) until Tab, with the cursor on it, opens its text field ("amend": an input option, placeholder
    # "and tell Claude what to do differently"); then every key but the arrows, Tab, Enter and Esc is typed there,
    # leaving the row with nothing typed closes it again, and Enter declines with the text typed as the reason.
    # With "plainNo" too, Tab doesn't open it (a No row that takes no reason).
    if p["amend"] and p["focus"] == 2:
        if len(key) == 1 or key in ("backspace", "space"):
            p["feedback"] = p["feedback"][:-1] if key == "backspace" else p["feedback"] + (" " if key == "space" else key)
            return
        if key == "tab" or (key in ("up", "down") and not p["feedback"].strip()):
            p["amend"] = False
        if key == "tab":
            return
    elif key == "tab":
        if p["v316"] and p["focus"] == 2 and not p["plainNo"]:
            p["amend"] = True
        return
    if key in ("up", "k"):
        p["focus"] = max(0, p["focus"] - 1)
    elif key in ("down", "j"):
        p["focus"] = min(len(p["options"]) - 1, p["focus"] + 1)
    elif key == "enter":
        choice = p["focus"]
    elif key in ("1", "2", "3"):
        choice = int(key) - 1
    elif key == "esc":
        choice = 2
    if choice is None:
        return
    if choice == 2 and p["feedback"] and key == "enter":
        # Declined with a reason: the turn goes on with it.
        record({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": p["tool"], "is_error": True,
             "content": "The user doesn't want to proceed with this tool use. The tool use was rejected. To tell you how to proceed, the user said:\n" + p["feedback"]}]}})
        state["mode"] = "working"
        state["reply"] = "Denied: " + p["feedback"]
        state["declined"] = p["feedback"]
    elif choice == 2:
        record({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": p["tool"], "is_error": True,
             "content": "The user doesn't want to proceed with this tool use. The tool use was rejected."}]}})
        state["mode"] = "idle"
        state["reply"] = "Denied."
    else:
        record({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": p["tool"], "content": "ran " + p["command"]}]}})
        state["mode"] = "working"
        state["reply"] = "Allowed" + (" always." if choice == 1 else ".")
    permission = None


def open_picker():
    global picker
    picker = {"options": ["Default (recommended)", "Opus", "Haiku"], "focus": 0, "current": 0, "search": ""}
    state["mode"] = "picker"


def picker_key(key):
    global picker
    p = picker
    if key in ("up", "k"):
        p["focus"] = max(0, p["focus"] - 1)
    elif key in ("down", "j"):
        p["focus"] = min(len(p["options"]) - 1, p["focus"] + 1)
    elif key == "esc":
        picker = None
        state["mode"] = "idle"
        state["reply"] = "Kept the model."
    elif key == "enter":
        label = p["options"][p["focus"]]
        state["mode"] = "idle"
        state["reply"] = "Set model to " + label
        state["model"] = label
        picker = None


def key(name):
    if name != "space" and VOICE["awaiting"]:
        disarm()
    mode = state["mode"]
    if mode == "question":
        question_key(name)
    elif mode == "permission":
        permission_key(name)
    elif mode == "picker":
        picker_key(name)
    elif mode == "trust":
        trust_key(name)
    elif mode == "autoMode":
        auto_key(name)
    elif mode == "dialog":
        if name == "esc":
            state["mode"] = "idle"
    else:
        menu = suggestions()
        if menu and name in ("up", "down", "enter", "esc", "tab"):
            if name == "up":
                state["suggest"] = max(0, state["suggest"] - 1)
            elif name == "down":
                state["suggest"] = min(len(menu) - 1, state["suggest"] + 1)
            elif name == "esc":
                state["dismissed"] = True
            elif name == "tab":
                state["input"] = menu[state["suggest"]][0] + " "
            else:
                chosen = menu[state["suggest"]][0]
                state["input"] = ""
                state["suggest"] = 0
                run_command(chosen)
            return
        if state["recording"] in ("listening", "tap", "processing") and name == "esc":
            # Its cancel: the prompt as it was before the recording.
            state["input"] = VOICE["before"]
            state["recording"] = ""
            state["voiceCancels"] += 1
            return
        if name != "space":
            # Another key: a chain's spaces typed before it aren't a held Space's strays.
            VOICE["typed"] = 0
        if name == "space" and voice_space():
            return
        if name not in ("up", "down"):
            state["suggest"] = 0
            state["dismissed"] = False
        if name == "ctrl-u" and state["wrap"]:
            # Claude Code's: from the caret (at the end) to the start of its row, one row of a wrapped draft at a time.
            text = state["input"].rstrip(" ")
            state["input"] = text[:box_rows(text)[-1][0]]
            state["killed"] += 1
        elif name == "ctrl-u":
            cut = state["input"].rstrip("\n").rfind("\n")
            state["input"] = state["input"][:cut + 1] if cut >= 0 else ""
            state["killed"] += 1
        elif name == "enter":
            state["enters"] += 1
            text = state["input"]
            state["input"] = ""
            submit_prompt(text)
        elif name == "backspace":
            state["input"] = state["input"][:-1]
        elif name == "esc":
            if mode == "working":
                state["mode"] = "idle"
                state["reply"] = "Interrupted."
        elif len(name) == 1 or name == "space":
            state["input"] += " " if name == "space" else name


def unquote(part):
    """A pasted part as Claude Code reads it for a path (x()): its outer quotes dropped."""
    part = part.strip()
    if len(part) >= 2 and part[0] == part[-1] and part[0] in "'\"":
        return part[1:-1]
    return part


def take_paste(text):
    """A paste into the box, as Claude Code 2.1.310's paste handler takes it (usePasteHandler). Split at a space before a
    "/" and at newlines, the parts that are image paths (outer quotes dropped, an image extension) are read first, in
    the background: only once they're read do the images go in, as [Image #N], and the rest of the text after them. An
    Enter that comes while they're read is held back, and then dropped (its `V()` clears the held Enter; only a text
    paste's `J()` replays it). A paste of text alone goes in as it is."""
    global reading
    parts = [p for chunk in re.split(r" (?=/|[A-Za-z]:\\)", text) for p in chunk.split("\n") if p.strip()]
    paths = [p for p in parts if IMAGE.search(unquote(p))]
    if not paths:
        state["input"] += text
        return
    reading = {"until": time.monotonic() + state["imageRead"], "paths": paths, "rest": [p for p in parts if p not in paths],
               "raw": text, "enter": False}
    state["reading"] = True


def finish_reading():
    """The pasted image paths are read: the images that are files go in (the text after them); none: the paste as text."""
    global reading
    found = [unquote(p) for p in reading["paths"] if os.path.isfile(unquote(p))]
    if found:
        for _ in found:
            state["images"] += 1
            state["attached"] += 1
            state["input"] += "[Image #%d] " % state["images"]
        state["input"] += "\n".join(reading["rest"])
    else:
        state["input"] += reading["raw"]
    if reading["enter"]:
        state["droppedEnters"] += 1
    reading = None
    state["reading"] = False


def feed(data):
    """Turns what came in into keys (a paste goes into the box as Claude Code takes it, see `take_paste`)."""
    global paste
    text = data.decode("utf-8", "replace")
    i = 0
    while i < len(text):
        if paste is not None:
            end = text.find(ESC + "[201~", i)
            if end < 0:
                paste += text[i:]
                return
            paste += text[i:end]
            if state["mode"] in ("idle", "working"):
                take_paste(paste)
            else:
                for c in paste:
                    key(c)
            paste = None
            i = end + 6
            continue
        c = text[i]
        if text.startswith(ESC + "[200~", i):
            paste = ""
            i += 6
            continue
        if c == ESC and state["focusEvents"] and text[i:i + 3] in (ESC + "[I", ESC + "[O"):
            # A focus report: not a key.
            state["focused"] = text[i + 2] == "I"
            state["focusIns" if state["focused"] else "focusOuts"] += 1
            i += 3
            continue
        if c == ESC:
            seq = text[i:i + 3]
            names = {ESC + "[A": "up", ESC + "[B": "down", ESC + "[C": "right", ESC + "[D": "left", ESC + "[Z": "shift-tab",
                     ESC + "[F": "end"}
            if seq in names:
                key(names[seq])
                i += 3
                continue
            key("esc")
            i += 1
            continue
        if (c == "\r" or c == "\n") and reading is not None:
            reading["enter"] = True
        elif c == "\r" or c == "\n":
            key("enter")
        elif c == "\t":
            key("tab")
        elif c == "\x7f":
            key("backspace")
        elif c == "\x15":
            key("ctrl-u")
        elif c == " " and (state["mode"] == "question" or (state["mode"] in ("idle", "working") and paste is None)):
            key("space")
        elif c >= " ":
            key(c)
        i += 1


def mcp_config():
    """The --mcp-config it was given, read: inline JSON (as S10 makes it on Linux) or a file's path."""
    if MCP_CONFIG is None:
        raise ValueError("no --mcp-config was given")
    if MCP_CONFIG.lstrip().startswith("{"):
        return json.loads(MCP_CONFIG)
    with open(MCP_CONFIG) as f:
        return json.load(f)


def mcp_reply(proc, want, deadline):
    """The tool server's reply to request `want` (requests and notifications it sends meanwhile skipped)."""
    buffered = getattr(proc, "leftover", b"")
    while True:
        while b"\n" in buffered:
            line, buffered = buffered.split(b"\n", 1)
            if not line.strip():
                continue
            message = json.loads(line)
            if message.get("id") == want and ("result" in message or "error" in message):
                proc.leftover = buffered
                return message
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError("no reply to request %d" % want)
        ready, _, _ = select.select([proc.stdout], [], [], left)
        if ready:
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                raise EOFError("the tool server closed its output")
            buffered += chunk


def call_tool(command):
    """The "mcp" op, on a thread of its own: one tool call through the tool server named by --mcp-config."""
    entry = {"tool": command.get("tool")}
    proc = None
    try:
        servers = mcp_config().get("mcpServers", {})
        name = command.get("server") or ("vibeswitcher" if "vibeswitcher" in servers else next(iter(servers)))
        server = servers[name]
        env = dict(os.environ)
        env.update(server.get("env", {}))
        errors = open(STATE + ".mcp-stderr", "ab")
        proc = subprocess.Popen([server["command"]] + list(server.get("args", [])), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=errors, env=env)
        errors.close()
        deadline = time.monotonic() + command.get("seconds", 120)

        def send(message):
            proc.stdin.write((json.dumps(message) + "\n").encode())
            proc.stdin.flush()
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "fake-claude", "version": "1"}}})
        mcp_reply(proc, 1, deadline)
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
              "params": {"name": command.get("tool"), "arguments": command.get("arguments", {})}})
        entry["reply"] = mcp_reply(proc, 2, deadline)
    except Exception as error:  # what failed is the call's record
        entry["error"] = "%s: %s" % (type(error).__name__, error)
    finally:
        if proc is not None:
            try:
                proc.stdin.close()
                proc.wait(timeout=5)
            except Exception:
                proc.kill()
                proc.wait()
    with MCP_LOCK:
        state["mcp"].append(entry)
    MCP_DONE.set()


def start_child(foreground, program="/bin/sleep"):
    if foreground:
        # The terminal is the child's: reading or writing it from here would stop this process.
        signal.signal(signal.SIGTTIN, signal.SIG_IGN)
        signal.signal(signal.SIGTTOU, signal.SIG_IGN)

        def take_terminal():
            os.setpgid(0, 0)
            os.tcsetpgrp(0, os.getpgid(0))
        child = subprocess.Popen([program, "600"], preexec_fn=take_terminal)
    else:
        child = subprocess.Popen([program, "600"], stdin=subprocess.DEVNULL)
    state["children"].append(child.pid)


def control():
    global control_offset, trust, auto, dialog
    try:
        with open(CONTROL) as f:
            f.seek(control_offset)
            chunk = f.read()
    except FileNotFoundError:
        return False
    if not chunk.endswith("\n"):
        chunk = chunk[:chunk.rfind("\n") + 1]
    if not chunk:
        return False
    control_offset += len(chunk.encode())
    for line in chunk.splitlines():
        command = json.loads(line)
        op = command["op"]
        if op == "ask":
            open_question(command["questions"])
        elif op == "permission":
            # With "file", a Read's prompt for that file, not a Bash command's.
            open_permission(command.get("command", ""), command.get("ui"), command.get("plainNo", False), command.get("file"))
        elif op == "work":
            state["mode"] = "working"
        elif op == "take":
            # Mid-turn, the agent takes what was queued: Claude writes each as a queued_command attachment.
            for text in state["queued"]:
                record({"type": "attachment", "attachment": {"type": "queued_command", "prompt": text, "commandMode": "prompt",
                                                             "origin": {"kind": "human"}}})
            state["queued"] = []
        elif op == "done":
            state["mode"] = "idle"
            state["reply"] = command.get("reply", "Done.")
            record({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": state["reply"]}]}})
        elif op == "turns":
            state["turns"] = True
        elif op == "slowShell":
            state["slowShell"] = True
        elif op == "realShell":
            state["realShell"] = True
        elif op == "imageRead":
            state["imageRead"] = command["seconds"]
        elif op == "background":
            finish_shell("Command did not complete within its 120s timeout and was moved to the background (ID: bfake). "
                         "Output is being written to: bfake.output. You will be notified when it completes.")
        elif op == "child":
            start_child(command.get("foreground", False), command.get("program", "/bin/sleep"))
        elif op == "exit":
            state["mode"] = "exited"
            save_state()
            out(ESC + "[?2004l" + ESC + "[2J" + ESC + "[H")
            sys.exit(0)
        elif op == "voiceStop":
            if state["recording"] == "listening":
                end_recording()
        elif op == "processed":
            if state["recording"] == "processing":
                VOICE["until"] = time.monotonic()
        elif op == "voice":
            for name in ("mode", "account", "transcript", "interim", "warmup", "gap", "statusLine", "focused", "processing", "stuck", "loud", "wrap"):
                if name in command:
                    state[{"mode": "voice", "account": "voiceAccount"}.get(name, name)] = command[name]
            if "focusEvents" in command:
                state["focusEvents"] = command["focusEvents"]
                out(ESC + ("[?1004h" if command["focusEvents"] else "[?1004l"))
        elif op == "print":
            # A command's output printed on its terminal (the soak's worker: a build's and a test run's).
            with open(command["file"], "rb") as f:
                data = f.read()
            while data:
                data = data[os.write(1, data):]
            draw()
        elif op == "mcp":
            threading.Thread(target=call_tool, args=(command,), daemon=True).start()
        elif op == "autoMode":
            auto = {"focus": 1, "shell": True, "repos": False}
            state["autoMode"] = "open"
            state["mode"] = "autoMode"
        elif op == "dialog":
            dialog = command["lines"]
            state["mode"] = "dialog"
        elif op == "trust":
            trust = 0
            state["trustLose"] = command.get("lose", 0)
            state["mode"] = "trust"
        elif op == "freeze":
            state["frozen"] = True
        elif op == "thaw":
            state["frozen"] = False
    return True


def write_shell_snapshot():
    """As Claude Code does at its start (the start plan's ST-D19): CONFIG/shell-snapshots/snapshot-bash-<ms>-<random>.sh,
    CONFIG its CLAUDE_CONFIG_DIR or ~/.claude. Never in the account's own home (the user database's): a test's HOME only."""
    try:
        import pwd
        own = os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)
    except (ImportError, KeyError):
        return
    home = os.environ.get("HOME", "")
    config = os.environ.get("CLAUDE_CONFIG_DIR") or (os.path.join(home, ".claude") if home else "")
    if not config or os.path.realpath(config) == own or os.path.realpath(config).startswith(own + "/.claude"):
        return
    folder = os.path.join(config, "shell-snapshots")
    os.makedirs(folder, exist_ok=True)
    name = "snapshot-bash-%d-%s.sh" % (int(time.time() * 1000), uuid.uuid4().hex[:6])
    with open(os.path.join(folder, name), "w") as snapshot:
        snapshot.write("# Snapshot file\n# Unset all aliases to avoid conflicts with functions\nunalias -a 2>/dev/null || true\n")


def main():
    if TERMINAL is not None:
        write_shell_snapshot()
    tty.setraw(0)
    out(ESC + "[?2004h")
    if PROMPT:
        # Claude started with a prompt submits it first.
        submit_prompt(PROMPT)
    draw()
    while True:
        changed = control()
        if MCP_DONE.is_set():
            MCP_DONE.clear()
            changed = True
        if not state["frozen"]:
            ready, _, _ = select.select([0], [], [], 0.02)
            if ready:
                try:
                    data = os.read(0, 65536)
                except OSError:
                    # A child has the terminal's foreground (see `start_child`): its input isn't this one's.
                    time.sleep(0.02)
                    continue
                if not data:
                    return
                feed(data)
                changed = True
        else:
            select.select([], [], [], 0.02)
        # After what came in: an Enter read in the same moment as the paste is one held back.
        if reading is not None and time.monotonic() >= reading["until"]:
            finish_reading()
            changed = True
        if voice_tick():
            changed = True
        if changed:
            draw()


main()
"""#
}
