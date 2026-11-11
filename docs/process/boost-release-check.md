# Boost release check, 2026-11-11

Keep the Boost defaults: load threshold 36, 18 Mac-wide team sessions, 7 workers per project and 3 heavy slots.
Boosted periods recorded 1.89 successful merge outcomes per sampled hour against 0.85 normally, but freezes rose
from 1.28/h to 5.02/h and median merge-command time rose from 9.05 to 14.30 minutes. This is a throughput and
responsiveness tradeoff, not evidence that any individual default caused the difference or that the release met
all its performance guards. Prefer Automatic when throughput while away is the goal.

## Recorded comparison

Source: the installed app's `~/.vibeswitcher/stats/load-*.jsonl`, `merges-*.jsonl` and the names of
`~/.vibeswitcher/debug/hang-*.txt` / `.log`. Window: November 1 through **November 11 at 18:34:01 CET**, 2026,
on a 12-core Mac. The user confirmed the app was installed and Boost had been On for days. Explicit `boost` samples
first appear November 3; older unlabelled minutes are excluded from the mode comparison.

| Measurement | Normal (`boost: false`) | Boosted (`boost: true`) |
| --- | ---: | ---: |
| Sampled minutes / hours | 3,668 / 61.13 | 3,488 / 58.13 |
| Active sampled hours (worker, verifier or heavy slot present) | 58.47 | 57.73 |
| 1-minute load median / p90 / maximum | 3.8 / 16.3 / 224.7 | 6.4 / 39.7 / 224.8 |
| Minutes at load 48 or above | 83 (2.3%) | 272 (7.8%) |
| Memory pressure warning minutes | 203 (5.5%) | 743 (21.3%) |
| Worker + verifier sessions median / maximum | 2 / 10 | 4 / 12 |
| Heavy slots held median / maximum | 0 / 3 | 1 / 3 |
| Matched freeze events | 78 | 292 |
| Freezes per sampled hour | 1.28 | 5.02 |
| Recorded merge attempts / successful outcomes | 59 / 52 | 125 / 110 |
| Successful outcomes per sampled hour | 0.85 | 1.89 |
| Successful outcomes per active sampled hour | 0.89 | 1.91 |
| Tested merge rows | 56 | 120 |
| Median command duration, per tested merge row | 543 s (9.05 min) | 858 s (14.30 min) |
| Median command duration, shared batch counted once | 496 s (8.27 min) | 832 s (13.87 min) |
| First-run failures, per tested row | 16/56 (28.6%) | 24/120 (20.0%) |

The longest uninterrupted labelled boosted stretch contains 469 samples, November 10 **12:57:04–20:45:36 CET**
(about 7 h 49 min); a gap over two minutes ends a stretch. This checks the release against a real installed boosted run.

These rates use sampled hours (minutes / 60), not elapsed calendar hours. A freeze is a distinct hang-log timestamp,
counting `.txt` and `.log` together once. A merge is assigned to the nearest sample to its **command start**, within
120 seconds; a freeze uses the same rule. Assignment happens against all samples before partitioning, so a boundary
event cannot count in both modes. The merge outcome rate counts `passed` and `passed_on_rerun`, including one row
per task in a batch. It measures recorded successful checks, not independently verified landed commits or unique tasks.

“Suite time” in `load-report.sh` is `duration_s`: initialization, tests, regression commands and any rerun combined,
excluding load and slot waits. It is not isolated full-suite runtime. Its default median repeats a shared batch duration
for each task; the additional median above counts each `(project, batch)` once and each unbatched tested row once.
The mix differs: normal tested rows are VibeSwitcher 43, studio-metrics 12, GenSwap 1; boosted rows are VibeSwitcher
86, studio-metrics 13, GenSwap 14, wallet-manager 7. Even within VibeSwitcher, median recorded command duration is
662 s normally versus 908.5 s boosted; project mix alone does not explain the slowdown.

Coverage reconciles to 9,716 samples (161.93 h), 276 merge rows and 572 distinct hang timestamps. There are no
duplicate sample timestamps or exactly duplicated merge rows. Outside the comparison are 2,560 unlabelled minutes
(42.67 h), 78 associated merge attempts and 174 freezes; another 14 merge attempts and 28 freezes have no sample
within two minutes. Missing labels and missing samples are unknown, never assumed normal or freeze-free.

## Default decision

The [impact ledger's Boost hypothesis](impact.md#im-11-boost-mode-boost-release-6-7-planned) asks for at least
1.0 merges/h and 1.6 per active hour: the observed boosted rates exceed both, with the definitions above. Its load
bucket guard also holds in boosted samples: 36–48 has 9.23 freezes/h versus 5.71 at 24–36, a ratio of 1.62, below 2.
First-run failures are below 35%, but those failures include genuine failures and cannot establish a flaky-merge rate.
The median isolated full-suite guard of 300 s is **not established** by these command-duration records; the available
proxy is 858 s and is worse while boosted. The release should not be described as an unqualified performance win.

Retain the defaults because this observational comparison cannot select a better value. Historical load/session/worker
limits and per-project overrides are not in the samples; `boost: true` identifies the policy state, not the exact
settings then. The observed session maximum (12) is below the default boosted cap (18), so the cap's benefit is not
tested here. Elevated load and warning pressure coexist, running work can outlast a mode change, and the window
includes changing app versions, workloads and batch sizes. Above load 48, boosted periods have 233/292 freezes
(79.8%) and no tested merge rows starting there: these spikes already exceed the default start threshold 36.
Lowering a threshold cannot be assumed to stop work already running or unrelated processes. Three slots were held
in both modes at times; normal slots can be overridden per project. This does not isolate the effect of a 2-to-3 slot
change. Raising limits is unsupported, and choosing a new lower default from these aggregate data would be arbitrary.
No default or runtime behavior changes are made by this check.

## Reproduce the report

Run from the repository while these 14-day recorder files are retained. The cutoff below freezes the selected lines
of the partial last day. The Python is analysis documentation, not an installed tool: save it as `compare.py` in a new
TMPDIR folder, then run `python3 -I "$work/compare.py" "$work"`. It writes partitions and outputs only there and
runs the unchanged `scripts/load-report.sh --home PARTITION 2026-11-01 2026-11-11` for each mode. Empty hang files
stand for names only; no hang contents or account credentials are read. The printed SHA-256 values identify the
selected JSONL lines, each terminated by a newline. Source files may later expire; the captured output follows.

```sh
work=$(mktemp -d "${TMPDIR:-/tmp}/boost-release-check.XXXXXX")
# Save the Python below as "$work/compare.py", then:
python3 -I "$work/compare.py" "$work"
```

```python
import bisect, collections, datetime as dt, glob, hashlib, json, os, pathlib, re, statistics, subprocess, sys
source = pathlib.Path(os.path.expanduser('~/.vibeswitcher'))
work = pathlib.Path(sys.argv[1])
cutoff = dt.datetime.fromisoformat('2026-11-11T18:34:01+01:00')
start = dt.datetime.fromisoformat('2026-11-01T00:00:00+01:00')
def stamp(row): return dt.datetime.fromisoformat(row['t'])
def read(kind):
    rows = []
    for path in sorted((source / 'stats').glob(kind + '-*.jsonl')):
        selected = [line for line in path.read_text().splitlines() if start <= stamp(json.loads(line)) <= cutoff]
        if selected:
            print(path.name, len(selected), hashlib.sha256(('\n'.join(selected)+'\n').encode()).hexdigest())
        rows.extend(json.loads(line) for line in selected)
    return rows
samples = sorted((s for s in read('load') if s.get('load')), key=stamp)
merges = read('merges')
times = [stamp(s) for s in samples]
def mode(s): return 'boosted' if s.get('boost') is True else 'normal' if s.get('boost') is False else 'unknown'
def nearest(at):
    i = bisect.bisect_left(times, at)
    choices = [j for j in (i-1,i) if 0 <= j < len(times)]
    j = min(choices, key=lambda j: abs((times[j]-at).total_seconds())) if choices else None
    return samples[j] if j is not None and abs((times[j]-at).total_seconds()) <= 120 else None
parts = {name: {'samples':[], 'merges':[], 'hangs':[]} for name in ('normal','boosted','unknown','unsampled')}
for s in samples: parts[mode(s)]['samples'].append(s)
for m in merges:
    s = nearest(stamp(m)); parts[mode(s) if s else 'unsampled']['merges'].append(m)
hangs = {}
for path in (source / 'debug').iterdir():
    match = re.fullmatch(r'hang-(\d{8}-\d{6})\.(txt|log)',path.name)
    if match:
        at = dt.datetime.strptime(match[1],'%Y%m%d-%H%M%S').astimezone()
        if start <= at <= cutoff: hangs.setdefault(at,path.name)
for at,name in hangs.items():
    s = nearest(at); parts[mode(s) if s else 'unsampled']['hangs'].append(name)
print('duplicates: samples',len(times)-len(set(times)), 'merge exact rows',len(merges)-len({json.dumps(m,sort_keys=True) for m in merges}))
for name, part in parts.items():
    root = work / name
    (root / 'stats').mkdir(parents=True,exist_ok=True); (root / 'debug').mkdir(exist_ok=True)
    for kind, key in [('load','samples'),('merges','merges')]:
        by_day = collections.defaultdict(list)
        for row in part[key]: by_day[stamp(row).astimezone().date().isoformat()].append(json.dumps(row))
        for day, lines in by_day.items(): (root/'stats'/f'{kind}-{day}.jsonl').write_text('\n'.join(lines)+'\n')
    for hang in part['hangs']: (root/'debug'/hang).touch()
    output = subprocess.check_output(['bash','scripts/load-report.sh','--home',str(root),'2026-11-01','2026-11-11'],text=True)
    (work/(name+'.txt')).write_text(output)
    hours = len(part['samples'])/60
    active = sum(any(x.get('n',0)>0 and x.get('role')!='lead' for x in s.get('sessions',[])) or bool(s.get('heavy',{}).get('held')) for s in part['samples'])/60
    passed = [m for m in part['merges'] if m.get('result') in ('passed','passed_on_rerun')]
    tested = [m for m in part['merges'] if m.get('first_run')]
    durations = [m['duration_s'] for m in tested]
    unique = {}
    for i,m in enumerate(tested): unique.setdefault((m['project'],m.get('batch') or ('single',i)),m['duration_s'])
    print(name, json.dumps({'minutes':len(part['samples']),'hours':hours,'active_hours':active,'freezes':len(part['hangs']),'freezes_per_hour':len(part['hangs'])/hours if hours else None,'merge_outcomes':dict(collections.Counter(m.get('result') for m in part['merges'])),'successful_merges_per_hour':len(passed)/hours if hours else None,'successful_merges_per_active_hour':len(passed)/active if active else None,'tested_rows':len(tested),'duration_median_s':statistics.median(durations) if durations else None,'batch_deduplicated_duration_median_s':statistics.median(unique.values()) if unique else None,'first_run_failed':sum(m['first_run']=='failed' for m in tested),'first':part['samples'][0]['t'] if hours else None,'last':part['samples'][-1]['t'] if hours else None}))
    if hours: print(output.split('Load by hour')[0])
# Longest uninterrupted run of boosted samples; a gap over 120 s ends a stretch.
best=[]; current=[]
for s in samples:
    if mode(s)!='boosted': current=[]; continue
    if current and (stamp(s)-stamp(current[-1])).total_seconds()>120: current=[]
    current.append(s)
    if len(current)>len(best): best=list(current)
print('longest boosted stretch',len(best),'samples',best[0]['t'],best[-1]['t'])
```

## Captured load-report output

### Normal

```text
Load report 2026-11-01 .. 2026-11-11 (<TMPDIR>/boost-release-check/normal)
Samples: 3668 minutes (61.1 h); 1-min load median 3.8, p90 16.3, max 224.7; 12 cores
Memory pressure: normal 3465 min, warn 203 min; swap used at most 12041 MB
Team sessions (workers and verifiers): median 2, max 10; heavy slots held: median 0, max 3

load       minutes   share  freezes  per hour  merges  suite median  1st-run fails
0-12          3146     86%        8      0.15      40       9.0 min          11/40
12-24          317      9%       22      4.16      11      11.8 min           4/11
24-36           83      2%        4      2.89       2      10.8 min            1/2
36-48           39      1%        5      7.69       0             -              -
48-72           35      1%        7     12.00       3       9.1 min            0/3
72-100          31      1%       12     23.23       0             -              -
100-150         12      0%        1      5.00       0             -              -
150+             5      0%       19    228.00       0             -              -

Load by hour of day (1-min load: mean / max, minutes sampled)
  00:00    20.2 /   89.7  (119)
  01:00    59.0 /  207.1  (13)
  02:00    86.4 /  224.7  (3)
  03:00    13.3 /   17.1  (2)
  04:00    24.3 /  103.9  (23)
  05:00    12.3 /   74.4  (20)
  06:00    34.1 /   96.2  (14)
  07:00    12.8 /   34.7  (14)
  08:00     4.3 /   11.2  (18)
  09:00    13.7 /  199.8  (145)
  10:00    11.1 /  112.9  (234)
  11:00     5.7 /  116.2  (269)
  12:00     4.4 /   34.2  (294)
  13:00     5.8 /   73.7  (253)
  14:00     4.8 /   45.0  (260)
  15:00     3.1 /   10.8  (240)
  16:00     3.0 /   10.1  (240)
  17:00     4.6 /   57.4  (257)
  18:00     8.1 /  142.0  (306)
  19:00    12.3 /  109.8  (192)
  20:00    11.9 /  127.6  (160)
  21:00     7.5 /  102.6  (171)
  22:00     5.4 /   25.4  (226)
  23:00    12.0 /  145.5  (195)

Busiest process groups in minutes over load 48 (command, project: minutes named)
  Google               -                        76
  com.apple.Virtu      -                        45
  swiftpm-testing      vibeswitcher             35
  swift-frontend       vibeswitcher             25
  CleanMyMac_5_He      -                        17
  Wispr                -                        16
  VibeSwitcher         -                        16
  Telegram             -                        14
  2.1.319              vibeswitcher             13
  vibeswitcher-mc      vibeswitcher             11
```

### Boosted

```text
Load report 2026-11-01 .. 2026-11-11 (<TMPDIR>/boost-release-check/boosted)
Samples: 3488 minutes (58.1 h); 1-min load median 6.4, p90 39.7, max 224.8; 12 cores
Memory pressure: normal 2745 min, warn 743 min; swap used at most 11852 MB
Team sessions (workers and verifiers): median 4, max 12; heavy slots held: median 1, max 3

load       minutes   share  freezes  per hour  merges  suite median  1st-run fails
0-12          2414     69%       10      0.25      80      14.4 min          14/80
12-24          496     14%       13      1.57      28      14.9 min           8/28
24-36          189      5%       18      5.71      11      13.9 min           2/11
36-48          117      3%       18      9.23       1       7.7 min            0/1
48-72          108      3%       36     20.00       0             -              -
72-100          59      2%       17     17.29       0             -              -
100-150         55      2%       64     69.82       0             -              -
150+            50      1%      116    139.20       0             -              -

Load by hour of day (1-min load: mean / max, minutes sampled)
  00:00    16.4 /  148.2  (67)
  01:00    30.7 /  125.8  (60)
  02:00    13.9 /   20.4  (8)
  03:00    78.6 /  224.8  (51)
  04:00    63.4 /  215.5  (51)
  05:00    53.2 /  204.9  (53)
  06:00    13.3 /  111.9  (100)
  07:00    12.1 /  148.7  (153)
  08:00    24.9 /  195.8  (221)
  09:00    12.8 /   91.7  (177)
  10:00    15.0 /  178.9  (230)
  11:00    10.2 /   84.9  (184)
  12:00     7.0 /   48.9  (100)
  13:00     6.9 /   55.8  (133)
  14:00    10.3 /   98.2  (193)
  15:00    10.1 /   82.0  (230)
  16:00    11.8 /  129.1  (245)
  17:00    16.0 /  165.8  (276)
  18:00    20.5 /  103.3  (122)
  19:00    11.3 /  168.2  (133)
  20:00    17.9 /  172.2  (148)
  21:00    20.8 /  194.4  (167)
  22:00    15.7 /  106.1  (199)
  23:00    15.9 /  151.8  (187)

Busiest process groups in minutes over load 48 (command, project: minutes named)
  Google               -                        237
  com.apple.Virtu      -                        164
  swift-frontend       vibeswitcher             114
  swiftpm-testing      vibeswitcher             89
  CleanMyMac_5_He      -                        57
  swift-package        vibeswitcher             57
  2.1.319              vibeswitcher             38
  VibeSwitcher         -                        34
  vibeswitcher-mc      vibeswitcher             31
  swiftpm-testing      merge-batch              22
```

## Source fingerprints

Selected-line counts and SHA-256, from the same analysis run:

```text
load-2026-11-01.jsonl 628 bd98f7337af51f71f414e0a6be3b6d67124ac624b73710fc3908ab909e5799df
load-2026-11-02.jsonl 1396 ceb1b6e8759ef110b5c4d111e8e97d129aa6b109583a558473ad3c75759c0258
load-2026-11-03.jsonl 1358 14323db1f24f9b24cf4653f88cdefdc62e7a0a67757b732d4c7858cab756ee40
load-2026-11-04.jsonl 730 50e4ff5aa49ab16451c34983c17cd937f073350e3d4d28600d9d738926a38fce
load-2026-11-05.jsonl 695 d66d0ec63031c6086b787460be8af0d78fc0b3253726d723018be01b2c311934
load-2026-11-06.jsonl 732 eaff8cb0f7df803e1ee9df9eb12844c23dc2a1842428851635efa0198cbcfae1
load-2026-11-07.jsonl 889 ce24cd9bdc82ce33696f3f0765d57487e7b4159b4c00e26a23affb76794f2a72
load-2026-11-08.jsonl 1134 79a480dbf429749998cee7a3e59323fa4c3fbe4fe8716cff42c20936c5685c44
load-2026-11-09.jsonl 848 a989f77b7c430b0645ba5d9a28633e363f37be006d53c7f191b08d9e62fa84ee
load-2026-11-10.jsonl 867 73c7656f55a5ecb2b36044c7701486ad7b7984362d384b797ae9597934d21ba3
load-2026-11-11.jsonl 439 40c64856d5a81a9e8b9f0c7d9aaaca6a80d5f58b5646aef327fd6bbf81e34987
merges-2026-11-01.jsonl 31 eba0879c6231841a29cbaadfdff4f79928535968568e21b6579fc7c8fc3ddf96
merges-2026-11-02.jsonl 48 0ed8f3c75441cc9182c0244d286b2ae3308b05ee59f076522bfc63a29f605695
merges-2026-11-03.jsonl 6 e11de7c1aa46a7e7101532f71d8b1b33c44b9fbc5d8e3b533cd76238d2654049
merges-2026-11-04.jsonl 11 4229973e056c638705a3e268d4af2537fc16c4923a09ba714d61a130a6aa82f9
merges-2026-11-05.jsonl 30 09f9a218427cac247da0301c0447e2a41d1046fab8a3b2de421f0a0f111d3d74
merges-2026-11-06.jsonl 1 446ee87fe5816b2ca4e2fdac5cb5a46179030e6a7959882d6fb3be49c87a6c9f
merges-2026-11-07.jsonl 37 faa65b020f5c2548c2275776a0bbdb9d76a46331e9cfe5a40fca91bdbdfc51dc
merges-2026-11-08.jsonl 52 9208a316b8085fd8670b3a9713233d9f92858ce831f78eff3d8210ec108d1c66
merges-2026-11-09.jsonl 39 750e5022a051775d1ddc3599d8fd34a81a4341942e8b2846c20767f18a0ee45e
merges-2026-11-10.jsonl 17 c20e037d3ad9c028db5081385ce785eae871f685f88c635d151c78c417521145
merges-2026-11-11.jsonl 4 a7d1e6a4c41cc436ae1bbd979b23b6c5680bef9f5c1a4611923f6db130766f19
```
