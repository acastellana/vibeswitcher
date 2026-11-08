#!/bin/bash
# The product inventory: what VibeSwitcher already does, for the user, read from its code. The lead reads it before it
# proposes a feature or asks the user anything (LeadWorkflow's lead prompt), so it never proposes what exists.
#
# scripts/product-inventory.sh [--root DIR] [--write]
#   prints docs/process/product-inventory.md as the code in DIR (default: this repository) makes it:
#   the menu bar with its shortcuts, the command palette, context menus, Settings' tabs and options, sheets and
#   dialogs, the chat's, the terminal's and the window's features, and the sandbox's commands and sheets; each line
#   names its source file.
#   --write   writes it to DIR/docs/process/product-inventory.md instead of printing it
#   --inputs  prints the folders it reads (relative to DIR), one per line, and nothing else
#
# inputs: Sources/VibeSwitcher
# (what it reads, relative to DIR: the tool server takes these and the script out of a commit to run it.)
# Deterministic: the same code gives the same bytes (no dates, no line numbers, files in sorted order). It reads only
# DIR/Sources/VibeSwitcher and writes nothing but --write's file. A feature in its curated list whose code is gone
# prints "not found" and a warning on stderr; the exit status is still 0, so a merge's regeneration never fails on it
# (ProductInventoryTests fails instead). After a merge that changes Sources/VibeSwitcher, the lead's tool server runs the base's
# copy of this script and commits the result with the lead's records (LeadRecords, `ProductInventory`).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
write=""
while (($#)); do
    case "$1" in
        --root) root="${2:?--root needs a folder}"; shift 2 ;;
        --write) write=1; shift ;;
        --inputs) sed -n 's/^# inputs: //p' "$0" | tr ' ' '\n'; exit 0 ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "product-inventory: unknown argument $1 (--help)" >&2; exit 2 ;;
    esac
done
[[ -d $root/Sources/VibeSwitcher ]] || { echo "product-inventory: no Sources/VibeSwitcher in $root" >&2; exit 2; }

out=/dev/stdout
if [[ -n $write ]]; then
    mkdir -p "$root/docs/process"
    out="$root/docs/process/product-inventory.md"
fi
LC_ALL=C /usr/bin/python3 -I - "$root" > "$out" <<'PY'
import os, re, sys

ROOT = sys.argv[1]
SRC = "Sources/VibeSwitcher"
files = sorted(
    os.path.relpath(os.path.join(d, f), ROOT)
    for d, _, names in os.walk(os.path.join(ROOT, SRC)) for f in names if f.endswith(".swift"))
text = {f: open(os.path.join(ROOT, f), encoding="utf-8").read() for f in files}
out = []
warnings = []

def emit(line=""):
    out.append(line)

def where(f):
    return f"`{f}`"

# MARK: Swift scanning: strings (with interpolation), comments, balanced brackets.

def skip_string(s, i):
    """i at the opening quote; returns the index after the closing one."""
    if s.startswith('"""', i):
        end = s.find('"""', i + 3)
        return len(s) if end < 0 else end + 3
    i += 1
    while i < len(s):
        c = s[i]
        if c == "\\":
            if i + 1 < len(s) and s[i + 1] == "(":
                i = match(s, i + 1) + 1
                continue
            i += 2
            continue
        if c == '"' or c == "\n":
            return i + 1
        i += 1
    return i

def match(s, i):
    """i at an opening ( [ or {; returns the index of its closing bracket (len(s) - 1 when unbalanced)."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = [pairs[s[i]]]
    i += 1
    while i < len(s):
        c = s[i]
        if c == '"':
            i = skip_string(s, i)
            continue
        if s.startswith("//", i):
            end = s.find("\n", i)
            i = len(s) if end < 0 else end
            continue
        if s.startswith("/*", i):
            end = s.find("*/", i + 2)
            i = len(s) if end < 0 else end + 2
            continue
        if c in pairs:
            stack.append(pairs[c])
        elif c in ")]}":
            stack.pop()
            if not stack:
                return i
        i += 1
    return len(s) - 1

def split_args(s):
    """Top-level comma-separated parts of an argument list."""
    parts, depth, start, i = [], 0, 0, 0
    while i < len(s):
        c = s[i]
        if c == '"':
            i = skip_string(s, i)
            continue
        if c in "([{":
            i = match(s, i) + 1
            continue
        if c == ",":
            parts.append(s[start:i].strip())
            start = i + 1
        i += 1
    if s[start:].strip():
        parts.append(s[start:].strip())
    return parts

def literal(arg):
    """A string literal's text, `\\(…)` as "…"; None when the argument isn't one."""
    arg = arg.strip()
    m = re.match(r'(?:\w+:\s*)?"', arg)
    if not m:
        return None
    i, end = m.end() - 1, skip_string(arg, m.end() - 1)
    body = arg[i + 1:end - 1]
    res, j = "", 0
    while j < len(body):
        if body[j] == "\\" and j + 1 < len(body):
            if body[j + 1] == "(":
                j = match(body, j + 1) + 1
                res += "…"
                continue
            res += {"n": " ", "t": " ", "r": "\r", '"': '"', "\\": "\\"}.get(body[j + 1], body[j + 1])
            j += 2
            continue
        res += body[j]
        j += 1
    return re.sub(r"……+", "…", res)

def code_only(s):
    """`s` with comments blanked (strings kept), so a pattern never matches inside a comment."""
    res, i = [], 0
    while i < len(s):
        if s[i] == '"':
            j = skip_string(s, i)
            res.append(s[i:j]); i = j
        elif s.startswith("//", i):
            j = s.find("\n", i); j = len(s) if j < 0 else j
            res.append(" " * (j - i)); i = j
        elif s.startswith("/*", i):
            j = s.find("*/", i + 2); j = len(s) if j < 0 else j + 2
            res.append(re.sub(r"[^\n]", " ", s[i:j])); i = j
        else:
            res.append(s[i]); i += 1
    return "".join(res)

code = {f: code_only(t) for f, t in text.items()}

# Every type declared in the sources: its file(s), its bodies (with its extensions'), whether it's a SwiftUI View.
DECL = re.compile(r"^[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|final|open|indirect)\s+)*"
                  r"(struct|class|enum|extension)\s+([A-Z]\w*)([^{\n]*)\{", re.M)
types = {}
for f in files:
    s = code[f]
    for m in DECL.finditer(s):
        body = s[m.end() - 1:match(s, m.end() - 1) + 1]
        entry = types.setdefault(m.group(2), {"files": [], "bodies": [], "view": False})
        if m.group(1) != "extension" and f not in entry["files"]:
            entry["files"].append(f)
        entry["bodies"].append((f, body))
        if re.search(r"\bView\b", m.group(3)):
            entry["view"] = True

def calls(s, names):
    """Each call `Name(` in s whose name is in `names`, with its position."""
    pattern = re.compile(r"\b(" + "|".join(names) + r")\(")
    return [(m.start(), m.group(1), m.end() - 1) for m in pattern.finditer(s)]

# MARK: Menu bar

KEYS = {"endSessionKey": "⌫", "up": "↑", "down": "↓"}
GLYPH = {"\r": "↩", " ": "Space"}
MODS = [(".control", "⌃"), (".option", "⌥"), (".shift", "⇧"), (".command", "⌘")]

def shortcut(key, mods):
    if not key:
        return ""
    k = literal(key)
    if k is None:
        k = KEYS.get(key.strip(), key.strip())
    elif k == "…":
        k = "1–9"
    else:
        k = GLYPH.get(k, k.upper())
    if not k:
        return ""
    mods = mods if mods is not None else ".command"
    return "".join(g for name, g in MODS if name in mods) + k

def menu_bar():
    f = f"{SRC}/MainWindow/MainMenu.swift"
    if f not in code:
        warnings.append(f"no {f}"); return
    s = code[f]
    consts = {m.group(1): m.group(2) for m in re.finditer(r'static let (\w+) = "([^"]*)"', s)}
    def item(args):
        a = split_args(args)
        pos = [x for x in a if not re.match(r"tag:", x)]
        title = literal(pos[0]) if literal(pos[0]) is not None else consts.get(pos[0].strip(), pos[0].strip())
        key = pos[2] if len(pos) > 2 else ""
        mods = pos[3] if len(pos) > 3 else None
        if title.startswith("Session …"):
            title = "Session 1–9"
        return title, shortcut(key, mods)
    # Nested menus (Find): their items, and the variable the parent lists.
    nested = {}
    for m in re.finditer(r"(\w+)\.submenu = NSMenu\(title: \"([^\"]+)\"\)", s):
        var, title = m.group(1), m.group(2)
        fill = re.search(r"\[(.*?)\]\.forEach\(" + var + r"\.submenu!\.addItem\)", s[m.end():], re.S)
        items = [item(fill.group(1)[c + 1:match(fill.group(1), c)]) for _, _, c in calls(fill.group(1), ["item"])] if fill else []
        nested[var] = (title, items)
    emit("## Menu bar")
    emit()
    emit("The main window's menus (`MainMenu.build`); standard items go to the first responder.")
    for m in re.finditer(r'submenu\("([^"]+)", \[', s):
        menu = m.group(1)
        start = m.end() - 1
        block = s[start + 1:match(s, start)]
        lines = []
        # The items in order, nested menus where the parent lists their variable.
        tokens = sorted([(p, "item", c) for p, _, c in calls(block, ["item"])] +
                        [(mm.start(), "nested", mm.group(1)) for mm in re.finditer(r"^\s*(\w+),\s*$", block, re.M)])
        for p, kind, c in tokens:
            if kind == "item":
                title, keys = item(block[c + 1:match(block, c)])
                if title in ("Services",):
                    continue
                lines.append(f"- {menu} › {title}{' ' + keys if keys else ''} — {where(f)}")
            elif c in nested:
                title, items = nested[c]
                for t, keys in items:
                    lines.append(f"- {menu} › {title} › {t}{' ' + keys if keys else ''} — {where(f)}")
        # Items after the array (`] + (1...9).map { item(…) }`).
        after = s[match(s, start) + 1:]
        joined = re.match(r"\s*\+", after)
        close = after.find("\n        submenu(")
        close = after.find("\n        return main") if close < 0 else close
        for _, _, c in (calls(after[:close], ["item"]) if joined else []):
            title, keys = item(after[c + 1:match(after, c)])
            lines.append(f"- {menu} › {title}{' ' + keys if keys else ''} — {where(f)}")
        emit()
        emit(f"### {menu}")
        if not lines:
            emit(f"- {menu}: filled by AppKit — {where(f)}")
        for l in lines:
            emit(l)
    emit()

# MARK: Command palette

def palette():
    f = f"{SRC}/MainWindow/MainWindowController.swift"
    if f not in code:
        warnings.append(f"no {f}"); return
    s = code[f]
    emit("## Command palette (⌘K)")
    emit()
    emit("Sessions in attention order, then these commands, then New <preset> in <recent project>.")
    seen = []
    briefings = f"{SRC}/MainWindow/CommandPalette.swift"
    for name, c, s, f in [(n, c, code[g], g) for g in (f, briefings) if g in code for _, n, c in calls(code[g], ["command", "PaletteItem"])]:
        a = split_args(s[c + 1:match(s, c)])
        if name == "command":
            if len(a) < 3 or literal(a[2]) is None:
                continue
            titles = [literal(x) for x in re.findall(r'"(?:[^"\\]|\\.)*"', a[0])]
            title, keys = " / ".join(t for t in titles if t), literal(a[2])
        else:
            t = [x for x in a if x.startswith("title:")]
            k = [x for x in a if x.startswith("subtitle:")]
            if not t or literal(t[0]) is None:
                continue
            title = literal(t[0])
            first = (literal(k[0]) or "").split(" ")[0] if k else ""
            keys = first if re.fullmatch(r"[⌃⌥⇧⌘]+\S{1,2}", first) else ""
        line = f"- {title}{' ' + keys if keys else ''} — {where(f)}"
        if title and line not in seen:
            seen.append(line)
    for l in seen:
        emit(l)
    emit()

# MARK: Context menus

AREAS = [("MainWindow/Chat/", "Chat"), ("Shell/", "Chat, shell request card"), ("Wallet/", "Chat, wallet card"),
         ("MainWindow/SessionListView", "Sidebar session row"), ("PopoverView", "Menu bar popover, session row"),
         ("MainWindow/Lead/LeadController", "Project lead"), ("MainWindow/Lead/", "Lead's Team tab"), ("MainWindow/", "Window")]

def area(f):
    rel = f[len(SRC) + 1:]
    for prefix, name in AREAS:
        if rel.startswith(prefix):
            return name
    return os.path.splitext(os.path.basename(f))[0]

VIEWS = [n for n, t in types.items() if t["view"]]

def menu_items(block, prefix, depth=0):
    """Button and Menu titles in a context menu's block, in order; a View it names (RowMenu) read too."""
    found, i = [], 0
    pattern = re.compile(r"\b(Button|Menu)\(\s*\"|\b(" + "|".join(VIEWS) + r")\(" if VIEWS else r"\b(Button|Menu)\(\s*\"")
    while True:
        m = pattern.search(block, i)
        if not m:
            return found
        if m.group(1):
            open_paren = block.index("(", m.start())
            close = match(block, open_paren)
            title = literal(split_args(block[open_paren + 1:close])[0])
            i = close + 1
            if m.group(1) == "Menu":
                brace = block.find("{", close)
                if brace >= 0:
                    found += menu_items(block[brace + 1:match(block, brace)], prefix + [title], depth)
                    i = match(block, brace) + 1
            elif title:
                found.append(" › ".join(prefix + [title]))
        else:
            i = m.end()
            if depth < 2:
                for f, body in types[m.group(2)]["bodies"]:
                    b = re.search(r"var body: some View \{", body)
                    if b:
                        found += menu_items(body[b.end():match(body, b.end() - 1)], prefix, depth + 1)

def context_menus():
    emit("## Context menus")
    emit()
    emit("Right-click menus, by where they are. The chat's message text adds Copy and Select All to its own items.")
    # Helpers that put their trailing closure in a contextMenu (ChatView's onceReached).
    wrappers = set()
    for f in files:
        for m in re.finditer(r"func (\w+)\b[^{]*\{", code[f]):
            body = code[f][m.end() - 1:match(code[f], m.end() - 1)]
            if "contextMenu(menuItems:" in body:
                wrappers.add(m.group(1))
    lines = []
    for f in files:
        s = code[f]
        names = ["contextMenu"] + sorted(wrappers)
        for m in re.finditer(r"\.(" + "|".join(names) + r")\b", s):
            j = m.end()
            if j < len(s) and s[j] == "(":
                close = match(s, j)
                inner = s[j + 1:close]
                block = None
                b = re.search(r"menuItems:\s*\{", inner)
                if b:
                    block = inner[b.end():match(inner, b.end() - 1)]
                j = close + 1
            else:
                block = None
            if block is None:
                rest = s[j:]
                b = re.match(r"\s*\{", rest)
                if not b:
                    continue
                k = j + b.end() - 1
                block = s[k + 1:match(s, k)]
            for title in menu_items(block, []):
                lines.append((area(f), title, f))
        # Menus of message text: ChatTextMenuItem titles; NSMenuItems built for a right-click (menu(for:)).
        for m in re.finditer(r'ChatTextMenuItem\(title: ("(?:[^"\\]|\\.)*")', s):
            lines.append((area(f), literal(m.group(1)), f))
        if not f.endswith("MainMenu.swift"):
            for m in re.finditer(r"func menu\(for event: NSEvent\)", s):
                body = s[m.end():match(s, s.index("{", m.end()))]
                for t in re.finditer(r'NSMenuItem\(title: ("(?:[^"\\]|\\.)*")', body):
                    lines.append((area(f), literal(t.group(1)), f))
    seen = []
    for a, title, f in lines:
        line = f"- {a}: {title} — {where(f)}"
        if line not in seen:
            seen.append(line)
    for l in sorted(seen, key=lambda l: (l.split(":")[0], seen.index(l))):
        emit(l)
    emit()

# MARK: Settings

CONTROLS = ["Section", "Toggle", "Picker", "Stepper", "TextField", "SecureField", "Button", "LabeledContent",
            "DisclosureGroup", "Link"]

def settings():
    f = f"{SRC}/SettingsWindow.swift"
    if f not in code:
        warnings.append(f"no {f}"); return
    s = code[f]
    tv = s.find("TabView(selection:")
    if tv < 0:
        warnings.append("Settings: no TabView"); return
    brace = s.index("{", tv)
    block = s[brace + 1:match(s, brace)]
    emit("## Settings")
    emit()
    emit("Settings (⌘,), tab by tab: each section and option, in order, with the views it's made of.")
    prev = 0
    for m in re.finditer(r'\.tabItem \{ Label\("([^"]+)"', block):
        tab = m.group(1)
        segment = block[prev:m.start()]
        prev = m.end()
        roots = [n for _, n, _ in calls(segment, VIEWS)]
        emit()
        emit(f"### {tab}")
        emit(f"- Settings › {tab} tab — {where(f)}")
        visited = set()
        def walk(name, depth):
            if name in visited or depth > 4:
                return
            visited.add(name)
            for vf, body in types[name]["bodies"]:
                tokens = []
                for p, kind, c in calls(body, CONTROLS):
                    a = split_args(body[c + 1:match(body, c)])
                    title = literal(a[0]) if a else None
                    if title:
                        tokens.append((p, "control", f"{kind}: {title}"))
                for p, n, _ in calls(body, [v for v in VIEWS if v != name]):
                    tokens.append((p, "view", n))
                for p, kind, value in sorted(tokens):
                    if kind == "control":
                        emit(f"- {value} — {where(vf)}")
                    else:
                        walk(value, depth + 1)
        for r in roots:
            walk(r, 0)
    emit()

# MARK: Sheets, popovers and dialogs

def sheets():
    emit("## Sheets, popovers and dialogs")
    emit()
    seen = []
    for f in files:
        s = code[f]
        for m in re.finditer(r"\.(sheet|popover|alert|confirmationDialog)\(", s):
            close = match(s, m.end() - 1)
            a = split_args(s[m.end():close])
            title = literal(a[0]) if a else None
            if not title:
                brace = s.find("{", close)
                body = s[brace + 1:match(s, brace)] if brace >= 0 and brace - close < 4 else ""
                shown = [n for _, n, _ in calls(body, VIEWS)]
                title = shown[0] if shown else None
            line = f"- {area(f)}: {m.group(1)} — {title} — {where(f)}"
            if title and line not in seen:
                seen.append(line)
                emit(line)
    emit()

# MARK: Curated features (each found by its anchor in the code)

FEATURES = {
    "Chat": [
        ("Search the conversation: ⌘F opens the search bar, ⌘G / ⇧⌘G step through the matches", "MainWindow/Chat/ChatView.swift", r"struct ChatSearchBar\b"),
        ("Export Chat… (⇧⌘E): the conversation as a Markdown file", "MainWindow/MainWindowController.swift", r"func exportChatAction\b"),
        ("Latest button: jumps to the end while it's off screen", "MainWindow/Chat/ChatView.swift", r"struct LatestButton\b"),
        ("Code block header: the language, Copy, and Run when the session takes it", "MainWindow/Chat/ChatMessageText.swift", r"class ChatCodeHeader\b"),
        ("Code block Run: types a shell block into the session after you confirm; says Sent or why Not run", "MainWindow/Chat/ChatRunner.swift", r"struct RunButton\b"),
        ("Tool calls folded into groups; open a group, then a tool, for its input and output", "MainWindow/Chat/ToolViews.swift", r"struct ToolGroupView\b"),
        ("The to-do list or plan steps, pinned above the conversation while any is open", "MainWindow/Chat/ChatView.swift", r"struct TodoPanel\b"),
        ("Answer card: a question or permission prompt on the session's screen as buttons (⌘1–⌘9, ↩, ↑ / ↓)", "MainWindow/Chat/ChatView.swift", r"struct AnswerCard\b"),
        ("Show N earlier: long chats open at their end, earlier messages a page at a time", "MainWindow/Chat/ChatView.swift", r"chat\.showEarlier\(\)"),
        ("New since you looked: a marker with a summary where you left off", "MainWindow/Chat/ChatView.swift", r"New since you looked"),
        ("Selecting across messages and copying it (plain text and rich text)", "MainWindow/Chat/ChatMessageText.swift", r"override func writeSelection\b"),
        ("Image viewer for attached and tool images", "MainWindow/Chat/ToolViews.swift", r"struct ImageViewer\b"),
        ("Composer: ↩ sends, ⇧↩ adds a line, ↑ / ↓ walk earlier prompts, / commands, @ files, pasted or dropped images, ⌘. stops", "MainWindow/Chat/ComposerView.swift", r"struct ComposerView\b"),
        ("Push-to-talk dictation in the composer", "Dictation/DictationViews.swift", r"struct DictationButton\b"),
        ("Chat text size: ⌘+, ⌘−, ⌘0 while the chat is shown", "MainWindow/Chat/MarkdownView.swift", r"enum ChatFont\b"),
        ("Team messages between the lead and its workers, as cards", "MainWindow/Chat/TeamMessageCard.swift", r"struct TeamMessageCard\b"),
        ("All-done card: a batch's summary and receipts", "MainWindow/Chat/AllDoneCard.swift", r"struct AllDoneCard\b"),
        ("Shell request cards: an agent asks for a shell; Run or Decline", "Shell/ShellCard.swift", r"struct ShellCard\b"),
        ("Wallet request cards: an agent's transaction request; Send to Wallet Manager or sign in a browser wallet", "Wallet/WalletCard.swift", r"struct WalletCard\b"),
    ],
    "Terminal": [
        ("Selection survives output: select and copy while a build or server prints", "MainWindow/TerminalPane.swift", r"func feedOutput\b"),
        ("Option-drag selects past a program that asked for the mouse (Claude Code's fullscreen, vim, tmux); Shift-drag too", "MainWindow/TerminalPane.swift", r"selectingPastProgram"),
        ("Find in the scrollback: ⌘F while the terminal is shown", "MainWindow/MainWindowController.swift", r"terminal\.performFindPanelAction"),
        ("Clear Scrollback (⇧⌘K)", "MainWindow/TerminalPane.swift", r"func clearScrollback\b"),
        ("Terminal text size: ⌘+, ⌘−, ⌘0 while the terminal is shown", "MainWindow/MainWindowController.swift", r"func terminalFontSize\b"),
        ("Focus Terminal (⇧⌘↩): the terminal takes the whole window", "MainWindow/MainWindowController.swift", r"func focusTerminalAction\b"),
        ("Wallet request strip along the terminal", "MainWindow/TerminalWalletStrip.swift", r"struct TerminalWalletStrip\b"),
    ],
    "Window and app": [
        ("Start page: recent projects, shortcuts, ended sessions (⇧⌘H)", "MainWindow/StartPage.swift", r"struct StartPage\b"),
        ("Command palette (⌘K)", "MainWindow/CommandPalette.swift", r"class CommandPaletteController\b"),
        ("Inspector (⌥⌘0): the lead's Team tab and the session's details", "MainWindow/InspectorView.swift", r"struct InspectorView\b"),
        ("A lead's Team tab: tasks, decisions, scorecard, messages between leads", "MainWindow/Lead/TeamViews.swift", r"struct LeadTeamPane\b"),
        ("Brief Me (⇧⌘B): a spoken briefing across led projects, or one project's", "Briefing/BriefingViews.swift", r"struct BriefMeButton\b"),
        ("Statistics window", "Statistics/StatisticsView.swift", r"class StatisticsWindowController\b"),
        ("Floating dots panel", "FloatingPanel.swift", r"class FloatingPanelController\b"),
        ("Menu bar popover: every session, switch, pause, rename", "PopoverView.swift", r"\.contextMenu"),
        ("Global hot key", "HotKey.swift", r"class HotKey\b"),
        ("Phone access: a web app for the phone over Tailscale", "PhoneAccess.swift", r"\S"),
        ("New project sheet", "MainWindow/NewProject/NewProjectSheet.swift", r"struct NewProjectSheet\b"),
    ],
}

def features():
    for name in ["Chat", "Terminal", "Window and app"]:
        emit(f"## {name}")
        emit()
        for title, rel, anchor in FEATURES[name]:
            f = f"{SRC}/{rel}"
            if f in code and re.search(anchor, code[f]):
                emit(f"- {title} — {where(f)}")
            else:
                emit(f"- {title} — not found (its anchor /{anchor}/ matches nothing in {where(f)})")
                warnings.append(f"{name}: '{title}' not found in {f}")
        emit()

# MARK: The sandbox

def short(help_text, limit=110):
    help_text = re.sub(r"\s+", " ", help_text).strip()
    if len(help_text) <= limit:
        return help_text
    cut = help_text[:limit].rsplit(" ", 1)[0].rstrip(",;:(")
    return cut + "…"

def sandbox():
    f = f"{SRC}/Sandbox.swift"
    if f not in code:
        warnings.append(f"no {f}"); return
    s = code[f]
    emit("## Sandbox (`scripts/sandbox-app.sh`)")
    emit()
    emit("`run`, `shot NAME` and `quit` (the script's own), then the sandbox's commands (`help` lists them whole).")
    m = re.search(r"static let commands: \[\(name: String, help: String\)\] = \[", s)
    if m:
        block = s[m.end():match(s, m.end() - 1)]
        for part in split_args(block):
            if not part.startswith("("):
                continue
            a = split_args(part[1:match(part, 0)])
            name = literal(a[0]) if a else None
            helps = re.findall(r'"(?:[^"\\]|\\.)*"', a[1]) if len(a) > 1 else []
            if name:
                emit(f"- `{name}` — {short(literal(helps[0]).rstrip(': ') if helps else '')} — {where(f)}")
    emit()
    emit("### Sandbox sheets (`sheet NAME`)")
    for list_name in ["sheets", "windowSheets"]:
        m = re.search(r"static (?:let|var) " + list_name + r": \[[^=\n]*(?:= \[|\{ \[)", s)
        if not m:
            warnings.append(f"Sandbox: no {list_name} list")
            continue
        block = s[m.end():match(s, m.end() - 1)]
        for part in split_args(block):
            if not part.startswith("("):
                continue
            a = split_args(part[1:match(part, 0)])
            name = literal(a[0]) if a else None
            if not name:
                continue
            shown = [n for _, n, _ in calls(a[1] if len(a) > 1 else "", VIEWS)]
            view = next((n for n in shown if types[n]["files"]), None)
            src = types[view]["files"][0] if view else f
            emit(f"- `{name}`{' — ' + view if view else ''} — {where(src)}")
    for extra in ["choose-folder", "new-session-menu"]:
        if f'"{extra}"' in s:
            emit(f"- `{extra}` — {where(f)}")
    emit()

emit("# Product inventory")
emit()
emit("What VibeSwitcher already does for the user, generated from `Sources/VibeSwitcher/` by "
     "`scripts/product-inventory.sh`, and regenerated with the lead's records after a merge that changes them: "
     "don't edit it by hand. Before proposing a feature or asking the user, check here (and the code): "
     "what's listed exists.")
emit()
menu_bar()
palette()
context_menus()
settings()
sheets()
features()
sandbox()

while out and out[-1] == "":
    out.pop()
sys.stdout.write("\n".join(out) + "\n")
for w in warnings:
    print(f"product-inventory: {w}", file=sys.stderr)
PY
