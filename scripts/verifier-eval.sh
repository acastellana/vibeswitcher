#!/bin/bash
# Replays a known-bad commit to one verifier, started the way audit starts it, and says whether its findings name the
# known bugs; a clean case, one that passed its audit and caused nothing later, says whether it raised a false alarm.
# Every incident becomes a case, and the verifier is scored against all of them when its prompt or model changes (the
# idea from Anthropic's post on how the Claude Code team reviews code). One run costs about what an audit does: run
# it on purpose, and remember that one or two runs say nothing about a rate. The cases, where each came from and the
# last summaries: docs/process/verifier-eval.md.
#
# scripts/verifier-eval.sh [--checklist auto|off] [--max-usd N] [--total-usd N] [--dry-run] CASE | --all
# scripts/verifier-eval.sh --summary RUN_FOLDER | --score CASE_FOLDER CASE
# scripts/verifier-eval.sh --patch NAME HEAD
#   CASE: a case's name below.  --all: every case, one after the other, and one summary: bugs found of the total,
#   Important findings on clean cases (false alarms), tokens and cost (about $5 a case: see the doc).  --checklist:
#   auto (the default) puts the security checklist in where an audit would (LeadToolset.securityReason); off leaves
#   it out.  --max-usd N: Claude stops past N dollars (20), per case.  --dry-run: all but the model's run (the clone,
#   prompt, settings and command are made and kept), free; with --all it shows that every case resolves.
#   --total-usd N: with --all, each case's cap is what's left of N, and no case starts once less than $1 of it is left.
#   --summary RUN_FOLDER, --score CASE_FOLDER CASE: --all's summary, or a case's score, from the files a run kept; no
#   model, no clone (and the check of either on made-up files: Tests/VibeCoreTests/VerifierEvalScriptTests.swift).
#   --patch NAME HEAD: writes scripts/verifier-eval/NAME.patch.gz, the branch at HEAD (an audited commit, still in
#   this repository) against its merge-base with the base branch, for a case whose commit won't stay (below).
#
# Cases, one a line in `cases` below: NAME COMMIT PLACES DESCRIPTION
#   NAME: the case's name (the board task's slug).  COMMIT: the audited commit, full hash.  PLACES: each known bug's
#   place at COMMIT, FILE:LINE from the repository's root, comma-separated; a bug the verifier may place in more than
#   one spot (the finding's line and where the fix went) lists them with |, any one counts.  Or, for a clean case,
#   the marker expect-no-Important: any Important finding on it is a false alarm.  DESCRIPTION: one line, the board
#   task and finding it came from and what the bug is.
#   The commit and its base: with scripts/verifier-eval/NAME.patch.gz (made by --patch), the base is the patch's
#   (a commit on the base branch), and the clone gets the patch on it as one commit, refused unless its tree is COMMIT's
#   (a squashed merge leaves a branch's audited commit on no branch, and git's gc drops it in a few weeks). Without
#   one, COMMIT is on a branch that stays (a merged task's commit on the base, not its agent/ branch's, which cleanup
#   deletes), and its first parent is the base. The contract is scripts/verifier-eval/NAME.contract.md (the board
#   task's, as text) when there is one, else COMMIT's message.
#
# What it does, none of it on the base branch, the board, the vault, the session host or a real session:
#   1. A scratch clone (`git clone --no-local`, under a scratch folder removed on exit) with only the base branch (the
#      base) and `agent/NAME` (the commit, or the patch's one commit on the base): every other ref and the reflog are
#      dropped and the rest pruned, so the later fix isn't in its history.
#   2. Today's REVIEW.md from this repository's base branch goes on the clone's base and under its branch, the same
#      file on both so the branch's diff doesn't change: LeadRisk.reviewGuide then reads it from the clone's base, as in
#      a real audit. A case whose own diff changes REVIEW.md is refused; --all reads the file once, so every case gets
#      the same one.
#   3. Its .vibeswitcher/workflow.md holds this project's sensitive_paths and verifier_model, nothing else: no
#      test_command, so the verifier isn't asked for the full suite on a cold clone (focused tests only, as a finder).
#   4. vibeswitcher-mcp --verifier-prompt builds what audit gives a single verifier: LeadPrompts.verifier's prompt
#      (with the checklist where LeadToolset.securityReason says), LeadLaunch's verifier permission rules, and the
#      audit model (verifier_model, else another than your ~/.claude settings' model).
#   5. One `claude -p` in the clone with them: the audit's own start line, --setting-sources user --strict-mcp-config
#      as audit has, --permission-mode auto, under a scratch HOME (its Library/Keychains linked to yours, for Claude's
#      login; nothing else of your home) and TMPDIR. Its settings add deny rules for your real ~/.vibeswitcher and this
#      checkout by absolute path (its `~` is the scratch HOME); a Bash command reading them isn't covered.
# What differs from a real audit: no done report, no lead's notes (so no hint the lead gave), no ~/.claude settings,
# CLAUDE.md or hooks, and no VibeSwitcher tool server: the prompt gets a last section asking for submit_audit's
# arguments as JSON instead, which this reads from the last such block in any of its messages (a background task's
# notification can give it one more turn after its verdict).
#
# Output: each known bug found or missed (a finding in the same file within 3 lines of one of its places, as the
# audit's vote matches findings; one finding counts for one bug, so a finding that names two of them scores one: read
# the findings too) and how many of those found were Important (only those stop a merge), or a clean case's Important
# findings; every finding, the tokens, the cost (Claude's own total), the Claude Code version and how many permission
# denials it had (only counted: a read-only verifier is denied edits by design). A run that ended with an error gets no
# score: it says "not scored", and with --all it's in no total. Exit 0: all found, or a clean case with no Important
# finding; 1: one missed, or a false alarm; 2: it couldn't run, or wasn't scored (with --all: 2 when any case was so).
# Kept in .build/verifier-eval/NAME-CHECKLIST-TIME/: prompt.md, settings.json, command.txt, stream.jsonl (every
# message), score.txt and score.json; --all's in .build/verifier-eval/all-CHECKLIST-TIME/: a folder per case, each
# case's log and summary.txt.
set -uo pipefail

cases='
a-fix-s-regression 87d9b1cf5a18b2627b46f275b1ea50b83acce09b Sources/VibeCore/LeadLaunch.swift:80,Sources/VibeCore/LeadLaunch.swift:69,Sources/VibeCore/LeadLaunch.swift:74 Worker and verifier allows for a scratch export: git archive --remote/--exec runs a command (F1), --add-file reads any file (F2), a symlinked folder takes tar -x -C and mkdir -p out of the TMPDIR (F3). Pre-audit head 56ef4b5 on the board, the same code merged as this commit.
a-slash-command-that ff1546029dce37a96d629db95af29eb9e6b8260b Sources/VibeSwitcher/MainWindow/Chat/ChatSync.swift:199 Board a-slash-command-that, F1 (Important, fixed in round 2): noMenuSince is one value for every session and never reset on a switch, so a message held for session A while its picker is open is typed into that picker after the user visits B and comes back.
the-briefing-uses e42ccaeb12cf3456aedf02ec6a752c608de01d86 Sources/VibeSwitcher/SettingsWindow.swift:540 Board the-briefing-uses, F1 (Important, fixed in round 2): the login shell key is re-read in the Briefing section’s onAppear, but SettingsWindowController keeps one window, so reopening Settings never looks again.
ending-a-session-ends 0f2c4448309bc1723b30af38af6776b2d7844bbf Tests/VibeHostTests/EndingASessionTests.swift:60,Tests/VibeHostTests/EndingASessionTests.swift:63,Tests/VibeHostTests/EndingASessionTests.swift:34 Board ending-a-session-ends, F1-F3 (Important, fixed in round 2): the new test fails in the suite (F1, :60), reads terminationReason of a process still running, which throws (F2, :63), and its perl `setsid` is a bareword, not POSIX::setsid, so the job never leaves its group (F3, :34).
memory-the-host-parser 196c2a67f4099e5c42092d94dc6a7868a1e1aa15 Sources/VibeHost/HostedSession.swift:634|Sources/VibeHost/HostedSession.swift:688 Board memory-the-host-parser, F1 (Important, fixed in round 2): long history reads take ring.replay(), which starts at the last reset, so the lines before a clear or a pager are lost (the same call at :634 and :688).
lead-record-commits c001aacb09f75df15ca2b79127adebd52692a8ba Sources/VibeCore/Worktrees.swift:789|Sources/VibeCore/Worktrees.swift:600 Board lead-record-commits, F1 (Important, fixed in round 2): takeBaseRecords puts the base version only on unmerged files, so a record file that git merges cleanly lands with the branch’s edits (the fix also takes the base’s on every pick of the rebase at :600).
a-base-branch-the d87df70ba9923d70d136cec30d79a711e708a14d Sources/VibeCore/LeadBaseMoves.swift:353,Sources/VibeCore/LeadBaseMoves.swift:220|Sources/VibeSwitcher/MainWindow/Lead/BaseMoves.swift:112 Board a-base-branch-the, F1 and F2 (Important, fixed in round 2): BaseMoveNote.save writes .vibeswitcher/run with raw createDirectory/write (PrivateWriteLint fails, F1); a team session’s git command still running never marks the move as the team’s, so a user’s typed `! git` takes it as theirs (F2; the board says BaseMoves.swift:404, a line that file doesn’t have at this commit: the guard is at :112, the fix went in at LeadBaseMoves.swift:220).
finished-work-lands 5ba2037edc9c12847d3e597e656f14a3ba4ad748 Sources/VibeCore/LeadAdvance.swift:307|Sources/VibeCore/LeadAdvance.swift:312 Board finished-work-lands, F1 (Important, fixed in round 2): a pass reads auto_advance and the per-task opt-out once, then merges or audits every task in review, so turning either off during a long merge doesn’t stop the next one.
steadier-merge-gate 9b127cd8efaced0939f6ce7c1059a68d3d892e9b Sources/VibeCore/MergeRerun.swift:35|Sources/VibeCore/MergeRerun.swift:41 Board steadier-merge-gate, F1 (Important, fixed in round 2): a run that crashed or was stopped reruns with --filter on the tests it named, so the rest of the suite never runs and the merge goes on a partial pass.
the-lead-s-rules a2e23b04d0ae485c974f3a8918b300f77a3c8e71 expect-no-Important Board the-lead-s-rules, clean: four of the lead’s rules become checks in start_worker, audit, merge and add_task; first audit complete and clean (2 Nits), nothing fixed in that code since.
the-phone-shows-needs 72de968534d9d0a4a2b5dacd1aa5eeca6b35719f expect-no-Important Board the-phone-shows-needs, clean: the phone shows "needs you" only for the user’s sessions, as the Mac does; first audit complete and clean (1 Nit), nothing fixed in that code since.
every-task-gets-a 46628021a610aa42c0c146f6d9bc9b4551cd9e3c expect-no-Important Board every-task-gets-a, clean: every finished task gets a receipt (time, tokens per role, cost, rounds); touches sensitive_paths (Worktrees.swift, Sandbox.swift), so the checklist is in; first audit complete and clean (3 Nits), nothing fixed in that code since.
'

checklist=auto
max_usd=20
dry=0
all=0
patch=0
name=""
patch_head=""
case_out=""
total_usd=""
guide=""
summary_of=""
score_of=""
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
while [[ $# -gt 0 ]]; do
    case $1 in
        --checklist) checklist=${2:-}; shift 2 ;;
        --max-usd) max_usd=${2:-}; shift 2 ;;
        --total-usd) total_usd=${2:-}; shift 2 ;;
        --guide) guide=${2:-}; shift 2 ;;
        --dry-run) dry=1; shift ;;
        --all) all=1; shift ;;
        --patch) patch=1; name=${2:-}; patch_head=${3:-}; shift 3 ;;
        --out) case_out=${2:-}; shift 2 ;;
        --summary) summary_of=${2:-}; shift 2 ;;
        --score) score_of=${2:-}; name=${3:-}; shift 3 ;;
        -h|--help) sed -n '2,67p' "$0"; exit 0 ;;
        -*) echo "unknown option $1"; exit 2 ;;
        *) name=$1; shift ;;
    esac
done
[[ $checklist == auto || $checklist == off ]] || { echo "--checklist is auto or off"; exit 2; }
[[ $max_usd =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "--max-usd takes a number"; exit 2; }
[[ -z $total_usd || $total_usd =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "--total-usd takes a number"; exit 2; }
cd "$(dirname "$0")/.." || exit 2
data=scripts/verifier-eval
repo=$(cd "$(git rev-parse --git-common-dir)" && pwd)
# The lead's base: workflow.md's base_branch, else main (project-lead until 2026-10-29).
base_branch=$(awk '/^base_branch:/ { sub(/^base_branch:[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit }' \
    "$repo/../.vibeswitcher/workflow.md" 2>/dev/null)
base_branch=${base_branch:-main}
# Today's REVIEW.md: the base branch's blob, not this checkout's file (--all passes one to every case as --guide).
guide=${guide:-$(git rev-parse --verify --quiet "refs/heads/$base_branch:REVIEW.md")}

# --patch: a case's commit as a patch on the base branch, for when the commit won't stay.
if [[ $patch == 1 ]]; then
    [[ $name =~ ^[a-z0-9-]+$ && -n $patch_head ]] || { echo "usage: scripts/verifier-eval.sh --patch NAME HEAD"; exit 2; }
    head=$(git rev-parse --verify --quiet "$patch_head^{commit}") || { echo "$patch_head isn't in this repository"; exit 2; }
    base=$(git merge-base "$head" "$base_branch") || { echo "$head has no merge-base with $base_branch"; exit 2; }
    mkdir -p "$data"
    {
        echo "verifier-eval case $name"
        echo "base $base"
        echo "head $head"
        echo "tree $(git rev-parse "$head^{tree}")"
        git log --reverse --no-merges --format='subject %s' "$base..$head"
        git diff --binary --full-index "$base" "$head"
    } | gzip -9n > "$data/$name.patch.gz" || exit 2
    echo "wrote $data/$name.patch.gz: $head over $base ($(git diff --shortstat "$base" "$head"))"
    echo "add the case's line to \`cases\` with COMMIT $head, and its contract as $data/$name.contract.md"
    exit 0
fi

# The summary of a run's folder: RUN, 1 for a dry run or 0, the checklist. Its exit status is --all's.
summarize() {
    python3 -I - "$1" "$2" "$3" "$cases" <<'EOF'
import json, os, sys
run, dry, checklist, cases = sys.argv[1], sys.argv[2] == "1", sys.argv[3], sys.argv[4]
names = [line.split()[0] for line in cases.splitlines() if line.strip()]
rows, scores, failed, unscored = [], [], [], []
for name in names:
    try:
        score = json.load(open(f"{run}/{name}/score.json"))
    except Exception:
        failed.append(name)
        rows.append(f"  {name}: couldn't run (see {name}.log)")
        continue
    denials = f", {score.get('denials', 0)} permission denial(s)"
    if score.get("error"):
        # An errored run gets no score: in no total, and the summary exits 2.
        unscored.append(score)
        rows.append(f"  {name}: not scored ({score.get('error_reason') or 'claude ended with an error'}), ${score.get('cost', 0.0):.2f}{denials}")
        continue
    scores.append(score)
    if score.get("dry"):
        rows.append(f"  {name}: resolves ({score['kind']}, {score['base'][:8]}..{score['commit'][:8]}, checklist {score['security'] or 'not in the prompt'})")
    elif score["kind"] == "clean":
        rows.append(f"  {name}: clean, {score['important']} Important finding(s){' (false alarm)' if score['important'] else ''}, ${score['cost']:.2f}{denials}")
    else:
        rows.append(f"  {name}: {score['found']} of {score['expected']} found ({score['found_important']} as Important), ${score['cost']:.2f}{denials}")
bugs = [s for s in scores if s["kind"] == "bug" and not s.get("dry")]
clean = [s for s in scores if s["kind"] == "clean" and not s.get("dry")]
versions = sorted({str(s.get("claude_version") or "unknown") for s in scores + unscored}) or ["unknown"]
guides = sorted({s["review_md"] for s in scores + unscored if s.get("review_md")})
report = [f"verifier eval, --all, checklist {checklist}, Claude Code {', '.join(versions)}" + (f", REVIEW.md {', '.join(guides)}" if guides else "")
          + (", dry run: nothing sent" if dry else "")]
if dry:
    report.append(f"cases that resolve: {len(scores)} of {len(names)}")
else:
    expected = sum(s["expected"] for s in bugs)
    report.append(f"bugs found: {sum(s['found'] for s in bugs)} of {expected} "
                  f"({sum(s['found_important'] for s in bugs)} as Important) in {len(bugs)} bug cases")
    report.append(f"false alarms: {sum(s['important'] for s in clean)} Important finding(s) on {len(clean)} clean cases")
    report.append(f"tokens: {sum(s['tokens'] for s in bugs + clean)}; cost: ${sum(s['cost'] for s in bugs + clean):.2f}; "
                  f"{sum(s['minutes'] for s in bugs + clean):.0f} min")
if failed:
    report.append(f"couldn't run: {', '.join(failed)}")
if unscored:
    report.append(f"not scored (claude ended with an error, in no total above): {', '.join(s['name'] for s in unscored)}; "
                  f"they spent ${sum(s.get('cost', 0.0) for s in unscored):.2f}")
report += ["per case:"] + rows
open(run + "/summary.txt", "w").write("\n".join(report) + "\n")
print("\n".join(report))
print(f"kept in {run}")
sys.exit(2 if failed or unscored else 0 if dry or (all(s["found"] == s["expected"] for s in bugs) and not any(s["important"] for s in clean)) else 1)
EOF
}

# --summary: an --all run's folder summarized again, nothing run.
if [[ -n $summary_of ]]; then
    [[ -d $summary_of ]] || { echo "$summary_of isn't a folder"; exit 2; }
    summarize "$summary_of" 0 "$checklist"
    exit $?
fi

# --all: each case by itself, then one summary.
if [[ $all == 1 ]]; then
    [[ -z $name ]] || { echo "--all runs every case: name none"; exit 2; }
    run=".build/verifier-eval/all-$checklist-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$run"
    run=$(cd "$run" && pwd)
    [[ -n $guide ]] || { echo "$base_branch has no REVIEW.md: a real audit would have one"; exit 2; }
    options=(--checklist "$checklist" --guide "$guide")
    [[ $dry == 1 ]] && options+=(--dry-run)
    for each in $(printf '%s\n' "$cases" | awk 'NF { print $1 }'); do
        # What's left of --total-usd caps this case: stops before the run can pass it.
        cap=$(python3 -I - "$run" "$max_usd" "$total_usd" <<'EOF'
import glob, json, sys
run, max_usd, total = sys.argv[1], float(sys.argv[2]), sys.argv[3]
spent = sum(json.load(open(path)).get("cost", 0.0) or 0.0 for path in glob.glob(run + "/*/score.json"))
if total and float(total) - spent < 1:
    print("stop")
else:
    print(f"{min(max_usd, float(total) - spent) if total else max_usd:.2f}")
EOF
        )
        if [[ $cap == stop ]]; then
            echo "=== stopped before $each: \$$total_usd spent (--total-usd); the cases not run are \"couldn't run\""
            break
        fi
        echo "=== $each"
        "$self" "${options[@]}" --max-usd "$cap" --out "$run/$each" "$each" 2>&1 | tee "$run/$each.log"
    done
    summarize "$run" "$dry" "$checklist"
    exit $?
fi

# One case's score from its folder's stream.jsonl: FOLDER, NAME, PLACES, DESCRIPTION. Its exit status is the case's.
score_case() {
    python3 -I - "$1" "$2" "$3" "$4" <<'EOF'
import json, re, sys
out, name, places, description = sys.argv[1:5]
try:
    seconds = int(open(out + "/seconds.txt").read())
except Exception:
    seconds = 0
try:
    review_md = open(out + "/review-md.txt").read().strip()
except Exception:
    review_md = ""
tolerance = 3
result, texts, version, denials = None, [], None, 0
for raw in open(out + "/stream.jsonl", errors="replace"):
    try:
        event = json.loads(raw)
    except Exception:
        continue
    if event.get("type") == "assistant":
        texts += [part.get("text", "") for part in event.get("message", {}).get("content", []) if part.get("type") == "text"]
    elif event.get("type") == "system" and event.get("subtype") == "init":
        version = event.get("claude_code_version") or version
    elif event.get("type") == "result":
        # A stream can hold several results. The last one's cost and usage are the run's total, but each result's
        # permission_denials are only its own turn's, so they're added up.
        result = event
        denials += len(event.get("permission_denials") or [])
if result is None:
    print(f"no answer from claude; see {out}/stderr.log")
    sys.exit(2)
text = "\n".join(texts)
findings = None
for block in reversed(re.findall(r"```json\s*(\{.*?\})\s*```", text, re.S)):
    try:
        findings = json.loads(block).get("findings") or []
        break
    except Exception:
        continue
how = "the JSON block"
if findings is None:
    # No JSON: every file:line the answer names.
    how = "file:line in its text (no JSON block)"
    findings = [{"file": f, "line": int(l), "severity": "?", "evidence": ""} for f, l in re.findall(r"([\w./+-]+\.\w+):(\d+)", text)]

def line_of(finding):
    # "35", 35 or "35-41": its first number.
    match = re.match(r"\s*(\d+)", str(finding.get("line") or 0))
    return int(match.group(1)) if match else 0

def important(finding):
    return str(finding.get("severity", "")).strip().lower() == "important"

clean = places == "expect-no-Important"
# Each bug: its places, any one of which a finding may name.
expected = [] if clean else [[(p.rsplit(":", 1)[0], int(p.rsplit(":", 1)[1])) for p in bug.split("|")] for bug in places.split(",")]
used, lines, found, found_important = set(), [], 0, 0
for bug in expected:
    near = [(abs(line_of(f) - line), i) for i, f in enumerate(findings) for file, line in bug
            if i not in used and str(f.get("file", "")).lstrip("./") == file and abs(line_of(f) - line) <= tolerance]
    named = " or ".join(f"{file}:{line}" for file, line in bug)
    if near:
        i = min(near)[1]
        used.add(i)
        found += 1
        found_important += important(findings[i])
        lines.append(f"  found  {named}  by {findings[i].get('severity')} at {findings[i].get('file')}:{findings[i].get('line')}")
    else:
        lines.append(f"  missed {named}")
importants = sum(important(f) for f in findings)
usage = result.get("modelUsage") or {}
tokens = {key: sum(int(m.get(key) or 0) for m in usage.values())
          for key in ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens")}
cost = result.get("total_cost_usd")
# A run that ended with an error is no measure of the verifier: is_error, or an error_ result that doesn't set it.
errored = bool(result.get("is_error")) or str(result.get("subtype") or "").startswith("error")
error_reason = " ".join(str(part) for part in (result.get("subtype"), result.get("terminal_reason")) if part)
if errored:
    report = [f"{description}", f"not scored: claude ended with an error ({error_reason})"]
elif clean:
    report = [f"{description}", f"clean case: {importants} Important finding(s)" + (", each a false alarm" if importants else ", no false alarm")
              + f" (findings read from {how})"]
else:
    report = [f"{description}", f"known bugs found: {found} of {len(expected)}, {found_important} of them by an Important finding (findings read from {how})"] + lines
report.append(f"findings: {len(findings)}")
for f in findings:
    evidence = re.sub(r"\s+", " ", str(f.get("evidence", "")))[:160]
    report.append(f"  {f.get('severity')} {f.get('file')}:{f.get('line')}  {evidence}")
report.append("tokens: " + ", ".join(f"{k} {v}" for k, v in tokens.items()) + f"; total {sum(tokens.values())}")
report.append((f"cost: ${cost:.2f} (Claude's total_cost_usd)" if isinstance(cost, (int, float)) else "cost: not given")
              + f", {len(texts)} messages, {seconds / 60:.1f} min")
# Only counted: a read-only verifier is denied edits by design.
report.append(f"permission denials: {denials}")
report.append(f"Claude Code: {version or 'unknown'}")
open(out + "/score.txt", "w").write("\n".join(report) + "\n")
json.dump({"name": name, "kind": "clean" if clean else "bug", "expected": len(expected), "found": found,
           "found_important": found_important, "important": importants, "findings": len(findings),
           "tokens": sum(tokens.values()), "cost": cost if isinstance(cost, (int, float)) else 0.0,
           "minutes": seconds / 60, "error": errored, "error_reason": error_reason if errored else None, "denials": denials,
           "claude_version": version or "unknown", "review_md": review_md}, open(out + "/score.json", "w"))
print("\n".join(report))
print(f"kept in {out}")
sys.exit(2 if errored else (1 if importants else 0) if clean else (0 if found == len(expected) else 1))
EOF
}

line=$(printf '%s\n' "$cases" | awk -v n="$name" '$1 == n')
if [[ -z $name || -z $line ]]; then
    echo "usage: scripts/verifier-eval.sh [--checklist auto|off] [--max-usd N] [--dry-run] CASE | --all; cases:"
    printf '%s\n' "$cases" | awk 'NF { print "  " $1 }'
    exit 2
fi
read -r _ commit places description <<< "$line"

# --score: a kept case folder's stream.jsonl scored again, nothing run.
if [[ -n $score_of ]]; then
    [[ -f $score_of/stream.jsonl ]] || { echo "$score_of has no stream.jsonl"; exit 2; }
    score_case "$score_of" "$name" "$places" "$description"
    exit $?
fi
patch_file=$data/$name.patch.gz

source scripts/lib/scratch.sh
source scripts/lib/swift-jobs.sh
scratch_tmpdir vs-verifier-eval

# The case's base, and its patch when its commit won't stay.
if [[ -f $patch_file ]]; then
    gzip -dc "$patch_file" > "$tool_scratch/case.patch" || { echo "$patch_file doesn't unpack"; exit 2; }
    field() { awk -v k="$1" '/^diff --git /{ exit } $1 == k { print $2; exit }' "$tool_scratch/case.patch"; }
    base=$(field base) tree=$(field tree)
    [[ $(field head) == "$commit" ]] || { echo "$patch_file is of $(field head), not the case's $commit"; exit 2; }
    git cat-file -e "$base^{commit}" 2>/dev/null || { echo "$patch_file's base $base isn't in this repository"; exit 2; }
else
    git cat-file -e "$commit^{commit}" 2>/dev/null || { echo "$commit isn't in this repository, and there's no $patch_file"; exit 2; }
    base=$(git rev-parse "$commit^")
fi
echo "building vibeswitcher-mcp…"
swift build $(swiftpm_options) --product vibeswitcher-mcp > /dev/null 2>&1 || { echo "the build failed: run swift build --product vibeswitcher-mcp"; exit 2; }
mcp="$(swift build $(swiftpm_options) --show-bin-path | tail -n 1)/vibeswitcher-mcp"

out=${case_out:-.build/verifier-eval/$name-$checklist-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$out"
out=$(cd "$out" && pwd)

# 1. The clone: the case's two branches and nothing after them.
clone=$tool_scratch/clone
git clone --quiet --no-local --no-checkout "$repo" "$clone" || { echo "the clone failed"; exit 2; }
if [[ -f $patch_file ]]; then
    # The patch's one commit on its base, by its subjects; its tree must be the audited commit's.
    git -C "$clone" checkout --quiet -B "agent/$name" "$base" || exit 2
    sed -n '/^diff --git /,$p' "$tool_scratch/case.patch" > "$tool_scratch/case.diff"
    git -C "$clone" apply --index --binary "$tool_scratch/case.diff" || { echo "$patch_file doesn't apply on $base"; exit 2; }
    [[ $(git -C "$clone" write-tree) == "$tree" ]] || { echo "$patch_file on $base doesn't give $commit's tree $tree"; exit 2; }
    awk '/^diff --git /{ exit } $1 == "subject" { sub(/^subject /, ""); print }' "$tool_scratch/case.patch" > "$tool_scratch/subjects.txt"
    [[ -s $tool_scratch/subjects.txt ]] || echo "agent/$name at ${commit:0:8}" > "$tool_scratch/subjects.txt"
    git -C "$clone" -c user.name=verifier-eval -c user.email=verifier-eval@localhost commit --quiet --no-verify \
        -F "$tool_scratch/subjects.txt" || { echo "committing the patch failed"; exit 2; }
    head=$(git -C "$clone" rev-parse HEAD)
else
    git -C "$clone" checkout --quiet -B "agent/$name" "$commit" || exit 2
    head=$commit
fi

# 2. Today's REVIEW.md on the base and under the branch, one new commit each, so `BASE...agent/NAME` is the case's diff.
[[ -n $guide ]] && git cat-file blob "$guide" > "$tool_scratch/REVIEW.md" \
    || { echo "no REVIEW.md on $base_branch: a real audit would have one"; exit 2; }
git -C "$clone" diff --quiet "$base" "$head" -- REVIEW.md || { echo "the case's diff changes REVIEW.md: it can't take today's"; exit 2; }
git -C "$clone" log -1 --format=%B "$head" > "$tool_scratch/head-message.txt"
guide_blob=$(git -C "$clone" hash-object -w "$tool_scratch/REVIEW.md") || exit 2
# TREE PARENT MESSAGE_FILE: a commit on PARENT with TREE and today's REVIEW.md.
with_guide() {
    local tree
    rm -f "$tool_scratch/guide.index"
    GIT_INDEX_FILE=$tool_scratch/guide.index git -C "$clone" read-tree "$1" || return 1
    GIT_INDEX_FILE=$tool_scratch/guide.index git -C "$clone" update-index --add --cacheinfo "100644,$guide_blob,REVIEW.md" || return 1
    tree=$(GIT_INDEX_FILE=$tool_scratch/guide.index git -C "$clone" write-tree) || return 1
    git -C "$clone" -c user.name=verifier-eval -c user.email=verifier-eval@localhost commit-tree "$tree" -p "$2" -F "$3"
}
echo "REVIEW.md as $base_branch has it today" > "$tool_scratch/guide-message.txt"
base_with_guide=$(with_guide "$base" "$base" "$tool_scratch/guide-message.txt") || { echo "adding REVIEW.md to the base failed"; exit 2; }
git -C "$clone" diff "$base" "$head" > "$tool_scratch/case-before.diff"
head=$(with_guide "$head" "$base_with_guide" "$tool_scratch/head-message.txt") || { echo "adding REVIEW.md to the branch failed"; exit 2; }
git -C "$clone" diff "$base_with_guide...$head" > "$tool_scratch/case-after.diff"
cmp -s "$tool_scratch/case-before.diff" "$tool_scratch/case-after.diff" || { echo "adding REVIEW.md changed the case's diff"; exit 2; }
git -C "$clone" checkout --quiet -B "agent/$name" "$head" || exit 2
git -C "$clone" branch --quiet -f "$base_branch" "$base_with_guide" || exit 2
git -C "$clone" remote remove origin
git -C "$clone" for-each-ref --format='%(refname)' | while read -r ref; do
    [[ $ref == "refs/heads/agent/$name" || $ref == "refs/heads/$base_branch" ]] || git -C "$clone" update-ref -d "$ref"
done
git -C "$clone" reflog expire --expire=now --all
git -C "$clone" gc --quiet --prune=now || { echo "pruning the clone failed"; exit 2; }
if [[ -n $(git -C "$clone" rev-list --all --not "$head") ]]; then
    echo "the clone has commits after $commit"
    exit 2
fi

# 3. Its workflow.md: the project's sensitive_paths and verifier_model.
mkdir -p "$clone/.vibeswitcher"
{
    echo "---"
    grep -E '^(sensitive_paths|verifier_model):' "$repo/../.vibeswitcher/workflow.md" 2>/dev/null
    echo "---"
} > "$clone/.vibeswitcher/workflow.md"
if [[ -f $data/$name.contract.md ]]; then
    cp "$data/$name.contract.md" "$tool_scratch/message.txt"
else
    cp "$tool_scratch/head-message.txt" "$tool_scratch/message.txt"
fi

# 4. What audit gives the verifier.
"$mcp" --verifier-prompt "$clone" "$name" "$base_branch" "$tool_scratch/message.txt" "$checklist" > "$tool_scratch/start.json" \
    || { echo "vibeswitcher-mcp --verifier-prompt failed"; exit 2; }
python3 -I - "$tool_scratch/start.json" "$out" "$HOME" "$(dirname "$repo")" <<'EOF' || exit 2
import json, sys
start = json.load(open(sys.argv[1]))
# Your real ~/.vibeswitcher and this checkout, by absolute path: in the replay, `~` in the verifier's rules is the scratch HOME.
for folder in (sys.argv[3] + "/.vibeswitcher", sys.argv[4]):
    start["settings"]["permissions"]["deny"] += [f"{tool}(/{folder}/**)" for tool in ("Read", "Edit", "Write")]
replay = """

## This audit is a replay

It scores the verifier on a past commit: no lead, board or VibeSwitcher tool server is behind it, so submit_audit isn't \
there. The task's whole contract is its goal above, the only text a replay has: its acceptance checks, boundaries \
and context are there when it has them. Do everything else as above. Then end your last message with what you would give submit_audit, as one JSON \
object in a ```json block: {"completion": …, "integrity": …, "tests": …, "summary": …, "findings": [{"severity": …, \
"file": …, "line": …, "evidence": …, "failure_scenario": …}]}.
"""
open(sys.argv[2] + "/prompt.md", "w").write(start["prompt"] + replay)
json.dump(start["settings"], open(sys.argv[2] + "/settings.json", "w"), indent=2, sort_keys=True)
open(sys.argv[2] + "/model.txt", "w").write(start["model"] + "\n")
open(sys.argv[2] + "/security.txt", "w").write((start["security"] or "") + "\n")
EOF
grep -qF "## The project's REVIEW.md" "$out/prompt.md" || { echo "the prompt has no REVIEW.md section"; exit 2; }
echo "${guide:0:8}" > "$out/review-md.txt"
echo "REVIEW.md: $(wc -c < "$tool_scratch/REVIEW.md" | tr -d ' ') bytes, blob ${guide:0:8} from $base_branch, on the clone's $base_branch and in prompt.md (see \"## The project's REVIEW.md\" in $out/prompt.md)"
model=$(cat "$out/model.txt")
security=$(cat "$out/security.txt")
home=$tool_scratch/home
mkdir -p "$home/Library" "$tool_scratch/verifier-tmp"
ln -s "$HOME/Library/Keychains" "$home/Library/Keychains"
command=(claude -p "Verify the task now, then call submit_audit." --append-system-prompt-file "$out/prompt.md"
         --settings "$out/settings.json" --setting-sources user --strict-mcp-config --model "$model"
         --permission-mode auto --output-format stream-json --verbose --no-session-persistence --max-budget-usd "$max_usd")
printf '%q ' "${command[@]}" > "$out/command.txt"
echo "case $name at ${commit:0:8}, checklist $checklist (${security:-not in the prompt}), model $model"

kind=bug
[[ $places == expect-no-Important ]] && kind=clean
if [[ $dry == 1 ]]; then
    version=$(claude --version 2>/dev/null | awk 'NR == 1 { print $1 }')
    python3 -I -c 'import json, sys; json.dump(dict(zip(("name", "kind", "commit", "base", "security", "claude_version", "review_md"), sys.argv[2:]), dry=True), open(sys.argv[1], "w"))' \
        "$out/score.json" "$name" "$kind" "$commit" "$base" "$security" "${version:-unknown}" "${guide:0:8}"
    echo "dry run: nothing sent; the prompt, settings and command are in $out"
    exit 0
fi

# 5. One verifier.
echo "running the verifier (minutes; it reads the branch and may run focused tests)…"
started=$(date +%s)
(cd "$clone" && export HOME=$home CFFIXED_USER_HOME=$home && with_tmpdir "$tool_scratch/verifier-tmp/" "${command[@]}" < /dev/null) \
    > "$out/stream.jsonl" 2> "$out/stderr.log"

echo $(( $(date +%s) - started )) > "$out/seconds.txt"
score_case "$out" "$name" "$places" "$description"
exit $?
