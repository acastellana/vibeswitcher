/// The fake Claude Code the chat sync harness runs on a scratch pty (see `ChatSyncTests`); written to a scratch file and
/// run with `python3 -I -u`.
enum FakeClaude {
    static let script = #"""
# A stand-in for Claude Code on a scratch pty, for the chat sync harness (ChatSyncTests). It draws what Claude Code
# 2.1.303 draws for the parts the chat mirrors, read from its own UI code: the prompt box and queued messages, an
# AskUserQuestion (tab bar with the open tab on a coloured background, single- and multi-select rows, "Type
# something." free text, "Chat about this", the Submit / Next row, the review tab), a permission prompt and the
# /model picker; it takes keys the way those do, and writes the transcript lines Claude writes.
#
# Usage: python3 -I -u fake_claude.py TRANSCRIPT CONTROL STATE
# The test appends JSON lines to CONTROL ({"op": "ask" | "permission" | "work" | "take" | "done" | "freeze" | "thaw" |
# "turns" (from now on a prompt starts a turn, as Claude's do: it works until "done") | "slowShell" (from now on a `!`
# command runs until "background", which moves it to the background as the 120 s Bash timeout does) | "imageRead" (how
# long a pasted image path takes to read, "seconds") | "child" (it starts `sleep 600` and goes on: in its own process
# group, as a background shell, or with "foreground" in one of its own that takes the terminal's foreground; its pid
# goes in "children") | "realShell" (from now on a `!` command really runs, in zsh, its output what it printed: the
# sandbox's, to show a code block's Run) | "voice" (its /voice, as code.claude.com/docs/en/voice-dictation tells it: "mode"
# off | hold | tap, "account" yes | none (no claude.ai sign-in: "Unknown command: /voice") | expired (it can't use the
# sign-in: "Voice mode requires a Claude.ai account"), "transcript", "interim" (what it shows dim while it listens; the
# transcript's first half by default; "" for silence, its level cursor grey), "warmup" (repeats before it listens), "gap"
# (seconds without a repeat that end a hold), "statusLine" (a custom status line: the footer shows it and never the
# voice footer, and the box its caret, as a focused terminal's), "focusEvents" (it asks for focus events, DECSET 1004,
# and takes CSI I and CSI O as them; else they're Esc and typed text), "focused" (its terminal has focus: only then
# does it draw its caret and level cursor)) | "voiceStop" (it stops listening by itself, as after 15 s of silence) |
# "exit" (it quits, as /exit)).
# Its /voice keeps Claude Code 2.1.312's timings: a repeat chain breaks 120 ms after the last Space (the key let go),
# 5 repeats start recording, and a second push of the key within 300 ms of a transcript going in sends it. A held
# Space's first two presses are typed and its later repeats swallowed until it records, when those two go.
# the agent writes its state (mode, tab, answers, the free-text field, queued messages) to STATE after every change.
import datetime
import json
import os
import re
import select
import signal
import subprocess
import sys
import time
import tty
import uuid

TRANSCRIPT, CONTROL, STATE = sys.argv[1], sys.argv[2], sys.argv[3]
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
    "doublePush": 0.3,       # a second push this soon after a transcript went in sends it
    "doubleSubmits": 0,      # prompts sent by a double push
    "statusLine": False,     # a custom status line in the footer, never its voice footer; the box shows its caret
    "focusEvents": False,    # it asked for focus events (DECSET 1004)
    "focused": True,         # its terminal has focus: it draws its caret and level cursor
    "focusIns": 0,           # CSI I taken
    "focusOuts": 0,          # CSI O taken
    "recording": "",         # "" | warming | listening | tap
    "voiceMessage": "",      # what its footer says about dictation
    "voiceStarts": 0,        # recordings started
    "voiceCancels": 0,       # recordings cancelled (Esc)
    "voiceInserts": 0,       # transcripts written into the box
    "killed": 0,             # ⌃U taken
}
VOICE = {"before": "", "last": 0.0, "repeats": 0, "inserted": -10.0, "pushes": 0}
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
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(snapshot, f)
    os.replace(tmp, STATE)


def out(text):
    os.write(1, text.encode())


# MARK: drawing

def draw():
    lines = []
    if state["mode"] == "question":
        lines = draw_question()
    elif state["mode"] == "permission":
        lines = draw_permission()
    elif state["mode"] == "picker":
        lines = draw_picker()
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
        if state["recording"] == "listening":
            # What it hears so far, dimmed until it's final; its level cursor where the caret was (focused only).
            words = state["transcript"].split()
            heard = state["interim"] if state["interim"] is not None else " ".join(words[:max(1, len(words) // 2)])
            live = ESC + "[2m" + heard + ESC + "[22m" + ((METER if heard else QUIET) if state["focused"] else "")
        lines.append("❯ " + state["input"].replace("\n", " ") + live)
        lines.append(RULE)
        menu = suggestions()
        footer = {"warming": "keep holding…", "listening": "listening…", "tap": "● REC · tap to send"}.get(state["recording"])
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
    lines = ["⏺ Bash(" + p["command"] + ")", "╭" + "─" * 58 + "╮", "│ Bash command", "│", "│   " + p["command"], "│",
             "│ Do you want to proceed?"]
    for index, label in enumerate(p["options"]):
        lines.append("│ " + ("❯ " if p["focus"] == index else "  ") + "%d. %s" % (index + 1, label))
    lines.append("╰" + "─" * 58 + "╯")
    lines.append("Esc to cancel")
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
    if state["recording"] == "listening":
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
    if state["recording"] == "" and t - VOICE["inserted"] <= state["doublePush"]:
        # A push of the key right after a transcript went in; the second one sends it.
        VOICE["pushes"] += 1
        VOICE["last"] = t
        if VOICE["pushes"] >= 2:
            text = state["input"]
            state["input"] = ""
            state["doubleSubmits"] += 1
            VOICE["inserted"] = -10.0
            submit_prompt(text)
        return True
    if t - VOICE["last"] <= state["gap"] and state["recording"] in ("", "warming") and VOICE["repeats"] >= 0:
        VOICE["repeats"] += 1
    else:
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
        state["recording"] = "listening"
        state["voiceMessage"] = ""
        state["voiceStarts"] += 1
        return True
    if VOICE["repeats"] >= 1:
        state["recording"] = "warming"
    # Its first two presses are typed; the later repeats are swallowed.
    return VOICE["repeats"] >= 2


def finish_recording(submit=False):
    """The key let go (hold) or tapped again (tap): the transcript goes in at the cursor; tap mode sends three words or more."""
    # At the cursor (the box's end here): after whatever was typed while it recorded.
    state["input"] = state["input"] + state["transcript"]
    state["recording"] = ""
    VOICE["repeats"] = 0
    VOICE["inserted"] = time.monotonic()
    VOICE["pushes"] = 0
    state["voiceInserts"] += 1
    if submit and len(state["transcript"].split()) >= 3:
        text = state["input"]
        state["input"] = ""
        submit_prompt(text)


def voice_tick():
    """No repeat for `gap`: a held key was let go. True when the screen changed."""
    if state["recording"] in ("warming", "listening") and time.monotonic() - VOICE["last"] > state["gap"]:
        if state["recording"] == "listening":
            finish_recording()
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


def open_permission(command):
    global permission
    tool = "toolu_" + uuid.uuid4().hex[:20]
    record({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": tool, "name": "Bash", "input": {"command": command}}]}})
    permission = {"command": command, "tool": tool, "focus": 0,
                  "options": ["Yes", "Yes, and don't ask again for this command", "No, and tell Claude what to do differently (esc)"]}
    state["mode"] = "permission"


def permission_key(key):
    global permission
    p = permission
    choice = None
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
    if choice == 2:
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
    mode = state["mode"]
    if mode == "question":
        question_key(name)
    elif mode == "permission":
        permission_key(name)
    elif mode == "picker":
        picker_key(name)
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
        if state["recording"] in ("listening", "tap") and name == "esc":
            # Its cancel: the prompt as it was before the recording.
            state["input"] = VOICE["before"]
            state["recording"] = ""
            state["voiceCancels"] += 1
            return
        if name == "space" and voice_space():
            return
        if name not in ("up", "down"):
            state["suggest"] = 0
            state["dismissed"] = False
        if name == "ctrl-u":
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
            names = {ESC + "[A": "up", ESC + "[B": "down", ESC + "[C": "right", ESC + "[D": "left", ESC + "[Z": "shift-tab"}
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


def start_child(foreground):
    if foreground:
        # The terminal is the child's: reading or writing it from here would stop this process.
        signal.signal(signal.SIGTTIN, signal.SIG_IGN)
        signal.signal(signal.SIGTTOU, signal.SIG_IGN)

        def take_terminal():
            os.setpgid(0, 0)
            os.tcsetpgrp(0, os.getpgid(0))
        child = subprocess.Popen(["/bin/sleep", "600"], preexec_fn=take_terminal)
    else:
        child = subprocess.Popen(["/bin/sleep", "600"], stdin=subprocess.DEVNULL)
    state["children"].append(child.pid)


def control():
    global control_offset
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
            open_permission(command["command"])
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
            start_child(command.get("foreground", False))
        elif op == "exit":
            state["mode"] = "exited"
            save_state()
            out(ESC + "[?2004l" + ESC + "[2J" + ESC + "[H")
            sys.exit(0)
        elif op == "voiceStop":
            if state["recording"] == "listening":
                finish_recording()
        elif op == "voice":
            for name in ("mode", "account", "transcript", "interim", "warmup", "gap", "statusLine", "focused"):
                if name in command:
                    state[{"mode": "voice", "account": "voiceAccount"}.get(name, name)] = command[name]
            if "focusEvents" in command:
                state["focusEvents"] = command["focusEvents"]
                out(ESC + ("[?1004h" if command["focusEvents"] else "[?1004l"))
        elif op == "freeze":
            state["frozen"] = True
        elif op == "thaw":
            state["frozen"] = False
    return True


def main():
    tty.setraw(0)
    out(ESC + "[?2004h")
    draw()
    while True:
        changed = control()
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
