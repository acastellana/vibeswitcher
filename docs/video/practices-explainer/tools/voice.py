#!/usr/bin/env python3
"""Voice each scene of NARRATION.md with ElevenLabs, one file per scene.

Usage: python3 -I tools/voice.py [--force] [--sample TEXT OUT] [sNN ...]   (run from the project folder)

Writes assets/voice/sNN.mp3 and assets/voice/sNN.json (the scene's text and ElevenLabs' character timings, which
tools/captions.py builds the captions from). A scene whose files exist is skipped unless --force, so a rerun spends no
characters. The API key comes from ELEVENLABS_API_KEY and goes only into the request header: it is never printed,
logged or written. Stops at the first refused call (quota or otherwise) and says which scenes are done.
"""
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

VOICE_ID = "JBFqnCBsd6RMkjVDRZzb"  # George, ElevenLabs premade (the voice in ElevenLabs' quickstart)
VOICE_NAME = "George"
MODEL_ID = "eleven_v4"
OUTPUT_FORMAT = "mp3_44100_128"
SEED = 1912  # fixed, so a re-voiced scene sounds like its neighbours
URL = f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE_ID}/with-timestamps?output_format={OUTPUT_FORMAT}"


def scenes(path="NARRATION.md"):
    """[(id, text)] in order: each `## sNN · Name` heading and the `>` lines under it."""
    out, cur = [], None
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^## (s\d\d) ", line)
        if m:
            cur = [m.group(1), []]
            out.append(cur)
        elif cur and line.startswith(">"):
            cur[1].append(line[1:].strip())
    return [(sid, " ".join(t for t in lines if t)) for sid, lines in out]


def speak(text, prev=None, nxt=None):
    key = os.environ.get("ELEVENLABS_API_KEY", "")
    if not key:
        sys.exit("ELEVENLABS_API_KEY is empty")
    body = {"text": text, "model_id": MODEL_ID, "seed": SEED}  # voice_settings.speed: eleven_v4 ignores it (1.0, 1.1 and 1.2 gave the same length)
    if prev:
        body["previous_text"] = prev
    if nxt:
        body["next_text"] = nxt
    req = urllib.request.Request(
        URL,
        data=json.dumps(body).encode(),
        headers={"xi-api-key": key, "Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:600]
        raise SystemExit(f"refused: HTTP {e.code}: {detail}")


def save(res, text, mp3, meta):
    open(mp3, "wb").write(base64.b64decode(res["audio_base64"]))
    al = res.get("alignment") or {}
    json.dump(
        {
            "voice": VOICE_NAME,
            "voice_id": VOICE_ID,
            "model_id": MODEL_ID,
            "text": text,
            "characters": len(text),
            "alignment": {
                "characters": al.get("characters", []),
                "starts": al.get("character_start_times_seconds", []),
                "ends": al.get("character_end_times_seconds", []),
            },
        },
        open(meta, "w", encoding="utf-8"),
        ensure_ascii=False,
        indent=1,
    )


def main(argv):
    force = "--force" in argv
    argv = [a for a in argv if a != "--force"]
    if argv[:1] == ["--sample"]:
        text, out = argv[1], argv[2]
        save(speak(text), text, out, os.path.splitext(out)[0] + ".json")
        print(f"sample: {len(text)} characters -> {out}")
        return
    all_scenes = scenes()
    want = set(argv) or {sid for sid, _ in all_scenes}
    os.makedirs("assets/voice", exist_ok=True)
    spent, done = 0, []
    for i, (sid, text) in enumerate(all_scenes):
        if sid not in want:
            continue
        mp3, meta = f"assets/voice/{sid}.mp3", f"assets/voice/{sid}.json"
        if not force and os.path.exists(mp3) and os.path.exists(meta):
            print(f"{sid}: kept")
            continue
        prev = all_scenes[i - 1][1] if i > 0 else None
        nxt = all_scenes[i + 1][1] if i + 1 < len(all_scenes) else None
        try:
            res = speak(text, prev, nxt)
        except SystemExit as e:
            print(f"{sid}: {e}\ndone before it: {', '.join(done) or 'none'}; characters spent: {spent}")
            raise SystemExit(1)
        save(res, text, mp3, meta)
        spent += len(text)
        done.append(sid)
        print(f"{sid}: {len(text)} characters")
    print(f"characters spent this run: {spent}")


if __name__ == "__main__":
    main(sys.argv[1:])
