#!/usr/bin/env python3 -I
"""Terminal.app's screen for a capture by capture-claude-status-rows.py, at each of its marks: the reference
StatusRowsTests compares SessionParser's rows with.

    python3 -I Tests/Tools/terminal-app-reference.py CAPTURE.raw FIXTURE.json [PNG_DIR]

Opens ONE new Terminal window of the capture's size (touching no other window, only this one by its id), replays the
capture up to each mark in it (`cat`, the line raw so Terminal's answers to queries aren't echoed), reads its visible
rows (AppleScript `contents`, trailing blanks dropped), screenshots it into PNG_DIR if given, then closes it.
FIXTURE.json gets the marks, the size and Terminal.app's rows at each mark.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

MARKS = ["idle", "spinner", "permission"]
HOLD = 8


def osa(script, strip=True):
    out = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, check=True).stdout
    # osascript ends its output with a newline; the screen's own leading blank rows stay.
    return out.strip() if strip else out[:-1]


def main():
    raw, fixture = sys.argv[1], sys.argv[2]
    shots = sys.argv[3] if len(sys.argv) > 3 else None
    capture = open(raw, "rb").read()
    marks = json.load(open(os.path.splitext(raw)[0] + ".marks.json"))
    cols, rows = marks["cols"], marks["rows"]
    work = tempfile.mkdtemp(prefix="terminal-reference.", dir="/tmp")
    for mark in MARKS:
        with open(f"{work}/{mark}.raw", "wb") as f:
            f.write(capture[:marks[mark]])
    # Each replay: a reset, the bytes, then HOLD s to read it.
    steps = "; ".join(f"printf '\\033c'; cat {work}/{mark}.raw; sleep {HOLD}" for mark in MARKS)
    with open(f"{work}/run.sh", "w") as f:
        f.write(f"sleep 2; stty raw -echo; {steps}; stty sane; exit\n")
    window = osa(f'''tell application "Terminal"
  set t to do script "exec /bin/sh {work}/run.sh"
  set number of columns of t to {cols}
  set number of rows of t to {rows}
  delay 0.5
  return id of (first window whose tabs contains t)
end tell''')
    screens = {}
    try:
        time.sleep(5)
        for mark in MARKS:
            size = osa(f'tell application "Terminal" to get {{number of columns, number of rows}} of tab 1 of window id {window}')
            assert size == f"{cols}, {rows}", f"the window is {size}, not {cols}x{rows}"
            text = osa(f'tell application "Terminal" to get contents of tab 1 of window id {window}', strip=False)
            screens[mark] = [line.rstrip() for line in text.split("\n")][:rows]
            if shots:
                subprocess.run(["screencapture", "-x", "-o", f"-l{window}", f"{shots}/terminal-app-{cols}-{mark}.png"], check=True)
            time.sleep(HOLD)
    finally:
        time.sleep(2)
        osa(f'tell application "Terminal" to close window id {window}')
        subprocess.run(["rm", "-rf", work])
    with open(fixture, "w") as f:
        json.dump({"marks": {mark: marks[mark] for mark in MARKS}, "cols": cols, "rows": rows, "terminalApp": screens},
                  f, indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
