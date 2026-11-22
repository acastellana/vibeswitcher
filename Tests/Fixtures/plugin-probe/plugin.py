#!/usr/bin/python3
# The node's test plugin (docs/superpowers/specs/2026-11-22-v2-feature-plugins.md, "External plugins"): protocol v1 on
# stdin and stdout, one JSON object a line. A request's first word chooses how it behaves, hostile ones included:
# normal, page, nohash, controls (a card with an escape), wrong-id, out-of-order, oversize (a 300 KiB line), hang
# (no answer to card), refuse (file refuses). It ends at the end of its input.
import base64, json, sys

def say(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()

def words_of(payload):
    return json.loads(base64.b64decode(payload))["words"]

ACTIONS = [
    {"word": "run", "label": "Run", "acts": True, "short": "runs it", "does": "runs the probe", "verb": "run a probe", "marks": "running"},
    {"word": "decline", "label": "Decline", "acts": False, "short": "declines it", "does": "declines the probe", "verb": "decline a probe",
     "marks": "declined"},
]
SCRIPT = "document.title='probe'"

for line in sys.stdin:
    ask = json.loads(line)
    call, rid = ask["call"], ask["id"]
    if call == "hello":
        say({"id": rid, "plugin": "probe", "version": "1.0.0"})
    elif call == "file":
        if ask["words"][:1] == ["refuse"]:
            say({"id": rid, "refuse": "this probe was asked to refuse"})
        else:
            say({"id": rid, "payload": base64.b64encode(json.dumps({"words": ask["words"]}).encode()).decode(), "expiresIn": 900})
    elif call == "card":
        words = words_of(ask["payload"])
        mode = words[0] if words else "normal"
        if mode == "hang":
            continue
        if mode == "oversize":
            say({"id": rid, "card": {"title": "x" * (300 * 1024)}})
            continue
        if mode == "out-of-order":
            say({"id": rid + 1000, "ok": True})
            continue
        if mode == "wrong-id":
            say({"id": rid + 1, "card": {}})
            continue
        body = " ".join(words)
        if mode == "controls":
            body = "probe \x1b[2J hidden"
        say({"id": rid, "card": {
            "title": "A probe asked for", "noun": "probe request", "ask": "asks for a probe",
            "facts": [{"label": "depth", "value": ask["settings"].get("depth", "1"), "decisive": True}],
            "body": {"name": "words", "label": "probing exactly", "text": body},
            "context": {"label": "why", "text": "a test"},
            "actions": ACTIONS, "waiting": "nothing runs until you answer run"}})
    elif call == "perform":
        words = words_of(ask["payload"])
        mode = words[0] if words else "normal"
        if ask["word"] == "run" and mode in ("page", "nohash"):
            html = "<!doctype html><title>probe</title><script>" + SCRIPT + "</script>"
            hashes = [] if mode == "nohash" else [base64.b64encode(__import__("hashlib").sha256(SCRIPT.encode()).digest()).decode()]
            say({"id": rid, "page": {"html": html, "scripts": hashes, "styles": [], "life": 60}})
        elif ask["word"] == "run":
            say({"id": rid, "outcome": {"state": "ran", "person": "Ran the probe", "agent": "The user ran your probe."}})
        else:
            say({"id": rid, "outcome": {"state": "declined", "person": "Declined", "agent": "The user declined your probe."}})
    elif call == "page.answer":
        if ask["answer"] == '{"ok":true}':
            say({"id": rid, "outcome": {"state": "answered", "person": "The page answered", "agent": "Your probe's page was answered."}})
        else:
            say({"id": rid, "refuse": "not an answer"})
    elif call == "settings.check":
        if ask["value"] == "99":
            say({"id": rid, "refuse": "1 to 9"})
        else:
            say({"id": rid, "ok": True})
    elif call == "withdrawn":
        say({"id": rid, "ok": True})
