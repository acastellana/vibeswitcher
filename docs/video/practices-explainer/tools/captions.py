#!/usr/bin/env python3
"""Fit the film to its voice: scene lengths, the voice track and the captions.

Usage: python3 -I tools/captions.py   (run from the project folder, after tools/voice.py)

Reads assets/voice/sNN.mp3 and .json (ElevenLabs' character timings) and rewrites, in place:
- index.html: each scene's data-start/data-duration, the film's length, one <audio> per scene between the
  `voice:begin` / `voice:end` markers;
- compositions/sNN-*.html: the scene registers K.fit(tl, base, length), which stretches its beats to its new length;
- compositions/bg.html: the background's length;
- compositions/captions.html: the caption phrases, timed to the words.
Rerunning it on unchanged voice files changes nothing.
"""
import html
import json
import math
import os
import re
import subprocess

# The silent cut's scene lengths (seconds): each scene's beats were authored against these.
BASE = {
    "s01": 10, "s02": 22, "s03": 20, "s04": 18, "s05": 18, "s06": 16, "s07": 18, "s08": 20, "s09": 18, "s10": 16,
    "s11": 18, "s12": 16, "s13": 18, "s14": 22, "s15": 18, "s16": 16, "s17": 20, "s18": 24, "s19": 14,
}
LEAD = 0.6  # the voice starts once the scene has faded in (0.4 s)
TAIL = 1.0  # and ends before the scene starts fading out (the last 0.45 s, stretched by at most ~1.4)
MAX_CHARS = 44  # one caption line
HOLD = 0.5  # a phrase stays up this long after its last word when there's room


def media_length(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
        check=True, capture_output=True, text=True,
    ).stdout
    return float(out.strip())


def words(meta):
    """[(word, start, end)] from the character timings, in the scene's own time."""
    a = meta["alignment"]
    out, cur, s, e = [], "", None, None
    for ch, cs, ce in zip(a["characters"], a["starts"], a["ends"]):
        if ch.isspace():
            if cur:
                out.append((cur, s, e))
            cur, s = "", None
            continue
        if s is None:
            s = cs
        cur += ch
        e = ce
    if cur:
        out.append((cur, s, e))
    assert " ".join(w for w, _, _ in out) == " ".join(meta["text"].split()), "timings don't match the text"
    return out


def _len(group):
    return len(" ".join(w[0] for w in group))


def _balance(group):
    """Split a run of words that's too long for one line into the fewest lines of even length."""
    if _len(group) <= MAX_CHARS:
        return [group]
    n = math.ceil(_len(group) / MAX_CHARS)
    target = _len(group) / n
    lines, cur = [], []
    for w in group:
        if cur and len(lines) < n - 1 and _len(cur + [w]) > target and abs(_len(cur) - target) <= abs(_len(cur + [w]) - target):
            lines.append(cur)
            cur = []
        cur.append(w)
    lines.append(cur)
    return [x for line in lines for x in _balance(line)] if any(_len(l) > MAX_CHARS for l in lines) and len(lines) > 1 else lines


def phrases(ws):
    """One-line phrases: break after each sentence; inside one, at commas and colons once a phrase has some length
    (never leaving a scrap of a few words behind); then even out anything still too long for a line."""
    sentences, cur = [], []
    for w in ws:
        cur.append(w)
        if w[0][-1] in ".?!":
            sentences.append(cur)
            cur = []
    if cur:
        sentences.append(cur)
    groups = []
    for sent in sentences:
        if _len(sent) <= MAX_CHARS:
            groups.append(sent)
            continue
        clauses, cur = [], []
        for i, w in enumerate(sent):
            cur.append(w)
            rest = sent[i + 1:]
            if w[0][-1] in ",:;" and _len(cur) >= 14 and rest and _len(rest) >= 12:
                clauses.append(cur)
                cur = []
        if cur:
            clauses.append(cur)
        for c in clauses:
            groups.extend(_balance(c))
    return groups


def caption_html(text):
    """Escape a phrase; numbers get the accent, as on screen."""
    out = []
    for tok in text.split(" "):
        core = tok.rstrip(".,:;?!")
        esc = html.escape(tok)
        if re.fullmatch(r"\d[\d,%]*", core):
            esc = f'<span class="n">{html.escape(core)}</span>{html.escape(tok[len(core):])}'
        out.append(esc)
    return " ".join(out)


def main():
    ids = sorted(BASE)
    scene_files = {}
    for f in sorted(os.listdir("compositions")):
        m = re.fullmatch(r"(s\d\d)-[a-z0-9-]+\.html", f)
        if m:
            assert m.group(1) not in scene_files, f"two files for {m.group(1)}: {scene_files[m.group(1)]}, {f}"
            scene_files[m.group(1)] = f
    plan, t = [], 0.0
    for sid in ids:
        meta = json.load(open(f"assets/voice/{sid}.json", encoding="utf-8"))
        voice = media_length(f"assets/voice/{sid}.mp3")
        length = max(BASE[sid], math.ceil((LEAD + voice + TAIL) * 10) / 10)
        plan.append({"id": sid, "start": round(t, 3), "length": length, "voice": voice, "meta": meta})
        t = round(t + length, 3)
    total = t

    # index.html: scene slots, film length, voice track
    src = open("index.html", encoding="utf-8").read()
    for p in plan:
        name = scene_files[p["id"]][:-5]
        src, n = re.subn(
            rf'(<div id="{name}" [^>]*?)data-start="[\d.]+" data-duration="[\d.]+"',
            rf'\g<1>data-start="{p["start"]:g}" data-duration="{p["length"]:g}"',
            src,
        )
        assert n == 1, name
    src, n = re.subn(r'(id="(?:main-root|bg|captions)"[^>]*?data-duration=")[\d.]+(")', rf"\g<1>{total:g}\g<2>", src, flags=re.S)
    assert n == 3, f"film length set on {n} of main-root, bg, captions"
    src, n = re.subn(r"tl\.set\(\{\}, \{\}, [\d.]+\);(\s*window\.__timelines\[\"main\"\])", rf"tl.set({{}}, {{}}, {total:g});\1", src)
    assert n == 1
    audio = [
        f'      <audio id="vo-{p["id"]}" src="assets/voice/{p["id"]}.mp3" data-start="{p["start"] + LEAD:g}" '
        f'data-duration="{p["voice"]:g}" data-track-index="2" data-volume="1"></audio>'
        for p in plan
    ]
    src, n = re.subn(
        r"(      <!-- voice:begin[^\n]*\n).*?(      <!-- voice:end -->)",
        lambda m: m.group(1) + "\n".join(audio) + "\n" + m.group(2),
        src,
        flags=re.S,
    )
    assert n == 1, "voice markers missing in index.html"
    open("index.html", "w", encoding="utf-8").write(src)

    # each scene stretches its beats to its new length
    for p in plan:
        path = f"compositions/{scene_files[p['id']]}"
        s = open(path, encoding="utf-8").read()
        s, n = re.subn(
            r'(window\.__timelines\["s\d\d-[^"]+"\] = )(?:tl|K\.fit\(tl, [\d.]+, [\d.]+\));',
            rf"\g<1>K.fit(tl, {BASE[p['id']]}, {p['length']:g});",
            s,
        )
        assert n == 1, path
        open(path, "w", encoding="utf-8").write(s)

    s = open("compositions/bg.html", encoding="utf-8").read()
    s, n = re.subn(r"const T = [\d.]+;", f"const T = {total:g};", s)
    assert n == 1
    open("compositions/bg.html", "w", encoding="utf-8").write(s)

    # captions: (global start, end, phrase)
    cues = []
    for p in plan:
        base = p["start"] + LEAD
        gs = phrases(words(p["meta"]))
        for i, g in enumerate(gs):
            s0 = g[0][1]
            e0 = g[-1][2] + HOLD
            if i + 1 < len(gs):
                e0 = min(e0, gs[i + 1][0][1]) if gs[i + 1][0][1] > g[-1][2] else g[-1][2]
            cues.append((round(base + s0, 3), round(base + e0, 3), " ".join(w for w, _, _ in g)))
    for a, b in zip(cues, cues[1:]):
        assert a[1] <= b[0] + 1e-6, (a, b)
    for p in plan:
        # the stage starts fading 0.45 s before the end of the silent cut's timing, stretched by K.fit
        fade = 0.45 * p["length"] / BASE[p["id"]]
        assert LEAD + p["voice"] <= p["length"] - fade, (p["id"], "voice runs into the fade-out")

    divs = "\n".join(
        f'        <div class="cg" id="cg-{i}"><span class="tx">{caption_html(c[2])}</span></div>' for i, c in enumerate(cues)
    )
    timing = json.dumps([[c[0], c[1]] for c in cues], separators=(",", ":"))
    open("compositions/captions.html", "w", encoding="utf-8").write(CAPTIONS.format(total=f"{total:g}", divs=divs, timing=timing))
    print(f"film {total:g} s ({int(total // 60)}:{total % 60:04.1f}), {len(cues)} caption phrases")
    for p in plan:
        print(f"{p['id']}: start {p['start']:g}, length {p['length']:g} (silent cut {BASE[p['id']]}), voice {p['voice']:.2f}")


CAPTIONS = """<!doctype html>
<html>
  <head>
    <meta charset="UTF-8" />
  </head>
  <body>
    <!-- Generated by tools/captions.py from assets/voice/*.json: edit NARRATION.md and rerun, not this file. -->
    <template>
      <style>
        #captions-root {{
          position: absolute;
          inset: 0;
          pointer-events: none;
        }}
        .cg {{
          position: absolute;
          left: 0;
          right: 0;
          bottom: 36px;
          display: flex;
          justify-content: center;
          opacity: 0;
          visibility: hidden;
        }}
        .cg .tx {{
          max-width: 1560px;
          padding: 10px 28px 12px;
          border-radius: 12px;
          background: rgba(18, 17, 15, 0.88);
          border: 1px solid #3a352d;
          font-family: "Montserrat", "Helvetica Neue", sans-serif;
          font-weight: 500;
          font-size: 38px;
          line-height: 1.3;
          color: #f1ebe0;
          white-space: nowrap;
        }}
        .cg .n {{
          color: #f0a63a;
          font-weight: 700;
        }}
      </style>
      <div id="captions-root" data-composition-id="captions" data-width="1920" data-height="1080">
{divs}
      </div>
      <script>
        (function () {{
          // [start, end] of each phrase, in film time (this composition starts at 0).
          const CUES = {timing};
          const tl = gsap.timeline({{ paused: true }});
          CUES.forEach(([s, e], i) => {{
            const el = document.getElementById("cg-" + i);
            tl.set(el, {{ visibility: "visible" }}, s);
            tl.fromTo(el, {{ opacity: 0 }}, {{ opacity: 1, duration: 0.1, ease: "power1.out" }}, s);
            tl.to(el, {{ opacity: 0, duration: 0.1, ease: "power1.in" }}, Math.max(s + 0.1, e - 0.1));
            tl.set(el, {{ opacity: 0, visibility: "hidden" }}, e);
          }});
          tl.set({{}}, {{}}, {total});
          window.__timelines["captions"] = tl;
        }})();
      </script>
    </template>
  </body>
</html>
"""

if __name__ == "__main__":
    main()
