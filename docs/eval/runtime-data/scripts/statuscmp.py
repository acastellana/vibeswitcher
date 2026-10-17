import json, subprocess, time, sys, datetime
BIN = "/Applications/VibeSwitcher.app/Contents/MacOS/VibeSwitcher"
rounds, gap = int(sys.argv[1]), int(sys.argv[2])
for r in range(rounds):
    st = json.load(open("/Users/albert/.vibeswitcher/app-status.json"))
    dump = subprocess.run([BIN, "--dump"], capture_output=True, text=True).stdout
    d = {}
    for line in dump.split("\n\n")[0].splitlines():
        f = line.split("\t")
        if len(f) >= 4: d[f[0]] = (f[1], f[3], f[5] if len(f) > 5 else "")
    a = {s["tty"]: s for s in st["sessions"]}
    now = datetime.datetime.now().strftime("%H:%M:%S")
    missing = sorted(set(d) - set(a)); extra = sorted(set(a) - set(d))
    print(f"{now} app-status updatedAt={st['updatedAt']} app={len(a)} dump={len(d)} missing_in_app={missing} extra_in_app={extra}")
    for tty in sorted(set(a) & set(d)):
        print(f"   {tty} app={a[tty]['status']:10s} hooks={a[tty]['hooks']!s:5s} dump={d[tty][1]} {('['+d[tty][2][:60]+']') if d[tty][2] else ''}")
    sys.stdout.flush()
    if r < rounds - 1: time.sleep(gap)
