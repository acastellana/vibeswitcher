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
# command runs until "background", which moves it to the background as the 120 s Bash timeout does) | "exit" (it quits,
# as /exit));
# the agent writes its state (mode, tab, answers, the free-text field, queued messages) to STATE after every change.
import datetime
import json
import os
import select
import sys
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
}
# The slash commands its menu offers while "/…" is typed in the box.
COMMANDS = [("/clear", "Clear conversation history"), ("/compact", "Clear history but keep a summary"),
            ("/help", "Show help and available commands"), ("/model", "Set the AI model for Claude Code")]
question = None              # the AskUserQuestion on screen
permission = None
picker = None
control_offset = 0
paste = None                 # bytes of a bracketed paste being read


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
        lines.append("❯ " + state["input"].replace("\n", " "))
        lines.append(RULE)
        menu = suggestions()
        if menu:
            # Claude's suggestions: paddingX 2, the chosen one with its pointer, names padded to one column.
            for index, (name, description) in enumerate(menu):
                pointer = "❯ " if index == state["suggest"] else "  "
                lines.append("  " + pointer + name.ljust(14) + description)
        else:
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

def submit_prompt(text):
    text = text.strip()
    if not text:
        return
    if state["mode"] == "working":
        state["queued"].append(text)
        return
    if text == "/model":
        open_picker()
        return
    if text.startswith("!"):
        state["shell"] = {"command": text[1:].strip(), "at": now()}
        if not state["slowShell"]:
            finish_shell("ran " + state["shell"]["command"])
        return
    record({"type": "user", "message": {"role": "user", "content": text}})
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
        if name not in ("up", "down"):
            state["suggest"] = 0
            state["dismissed"] = False
        if name == "enter":
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


def feed(data):
    """Turns what came in into keys (a paste goes into the box whole, as Claude Code takes it)."""
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
                state["input"] += paste
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
        if c == "\r" or c == "\n":
            key("enter")
        elif c == "\t":
            key("tab")
        elif c == "\x7f":
            key("backspace")
        elif c == " " and state["mode"] == "question":
            key("space")
        elif c >= " ":
            key(c)
        i += 1


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
        elif op == "background":
            finish_shell("Command did not complete within its 120s timeout and was moved to the background (ID: bfake). "
                         "Output is being written to: /tmp/bfake.output. You will be notified when it completes.")
        elif op == "exit":
            state["mode"] = "exited"
            save_state()
            out(ESC + "[?2004l" + ESC + "[2J" + ESC + "[H")
            sys.exit(0)
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
                data = os.read(0, 65536)
                if not data:
                    return
                feed(data)
                changed = True
        else:
            select.select([], [], [], 0.02)
        if changed:
            draw()


main()
"""#
}
