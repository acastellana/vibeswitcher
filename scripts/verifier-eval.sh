#!/bin/bash
# Replays a known-bad commit to one verifier, started the way audit starts it, and says whether its findings name the
# known bugs. Every incident becomes a case, and the verifier is scored again when its prompt or model changes (the
# idea from Anthropic's post on how the Claude Code team reviews code). One run costs about what an audit does: run
# it on purpose, and remember that one or two runs say nothing about a rate.
#
# scripts/verifier-eval.sh [--checklist auto|off] [--max-usd N] [--dry-run] CASE
#   CASE: a case's name below.  --checklist: auto (the default) puts the security checklist in where an audit would
#   (LeadToolset.securityReason); off leaves it out.  --max-usd N: Claude stops past N dollars (20).  --dry-run: all
#   but the model's run (the prompt, settings and command are kept), free.
#
# Cases, one a line in `cases` below: NAME COMMIT FILE:LINE[,FILE:LINE…] DESCRIPTION
#   NAME: the case's name (the board task's slug).  COMMIT: the known-bad commit, full hash, on a branch that stays
#   (a merged task's commit on the base, not its agent/ branch's, which cleanup deletes).  FILE:LINE: each known bug's
#   place at COMMIT, from the repository's root, comma-separated.  DESCRIPTION: one line, what the bugs are.
#   The case's base is COMMIT's first parent, and its contract is COMMIT's message.
#
# What it does, none of it on project-lead, the board, the vault, the session host or a real session:
#   1. A scratch clone (`git clone --no-local`, under a scratch folder removed on exit) with only `project-lead` (the
#      commit's parent) and `agent/NAME` (the commit): every other ref and the reflog are dropped and the rest pruned,
#      so the later fix isn't in its history.
#   2. Its .vibeswitcher/workflow.md holds this project's sensitive_paths and verifier_model, nothing else: no
#      test_command, so the verifier isn't asked for the full suite on a cold clone (focused tests only, as a finder).
#   3. vibeswitcher-mcp --verifier-prompt builds what audit gives a single verifier: LeadPrompts.verifier's prompt
#      (with the checklist where LeadToolset.securityReason says), LeadLaunch's verifier permission rules, and the
#      audit model (verifier_model, else another than your ~/.claude settings' model).
#   4. One `claude -p` in the clone with them: the audit's own start line, --setting-sources user --strict-mcp-config
#      as audit has, --permission-mode auto, under a scratch HOME (its Library/Keychains linked to yours, for Claude's
#      login; nothing else of your home) and TMPDIR. Its settings add deny rules for your real ~/.vibeswitcher and this
#      checkout by absolute path (its `~` is the scratch HOME); a Bash command reading them isn't covered.
# What differs from a real audit: no done report, no lead's notes (so no hint the lead gave), no ~/.claude settings,
# CLAUDE.md or hooks, and no VibeSwitcher tool server: the prompt gets a last section asking for submit_audit's
# arguments as JSON instead, which this reads from the last such block in any of its messages (a background task's
# notification can give it one more turn after its verdict).
#
# Output: each known bug found or missed (a finding in the same file within 3 lines, as the audit's vote matches
# findings; one finding counts for one bug, so a finding that names two of them scores one: read the findings too),
# every finding, the tokens and the cost (Claude's own total). Exit 0: all found; 1: one missed; 2: it couldn't run.
# Kept in .build/verifier-eval/NAME-CHECKLIST-TIME/: prompt.md, settings.json, command.txt, stream.jsonl (every
# message), score.txt.
set -uo pipefail

cases='
a-fix-s-regression 87d9b1cf5a18b2627b46f275b1ea50b83acce09b Sources/VibeCore/LeadLaunch.swift:80,Sources/VibeCore/LeadLaunch.swift:69,Sources/VibeCore/LeadLaunch.swift:74 Worker and verifier allows for a scratch export: git archive --remote/--exec runs a command (F1), --add-file reads any file (F2), a symlinked folder takes tar -x -C and mkdir -p out of the TMPDIR (F3). Pre-audit head 56ef4b5 on the board, the same code merged as this commit.
'

checklist=auto
max_usd=20
dry=0
name=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --checklist) checklist=${2:-}; shift 2 ;;
        --max-usd) max_usd=${2:-}; shift 2 ;;
        --dry-run) dry=1; shift ;;
        -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
        -*) echo "unknown option $1"; exit 2 ;;
        *) name=$1; shift ;;
    esac
done
[[ $checklist == auto || $checklist == off ]] || { echo "--checklist is auto or off"; exit 2; }
[[ $max_usd =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "--max-usd takes a number"; exit 2; }
line=$(printf '%s\n' "$cases" | awk -v n="$name" '$1 == n')
if [[ -z $name || -z $line ]]; then
    echo "usage: scripts/verifier-eval.sh [--checklist auto|off] [--max-usd N] [--dry-run] CASE; cases:"
    printf '%s\n' "$cases" | awk 'NF { print "  " $1 }'
    exit 2
fi
read -r _ commit places description <<< "$line"

cd "$(dirname "$0")/.." || exit 2
repo=$(cd "$(git rev-parse --git-common-dir)" && pwd)
git cat-file -e "$commit^{commit}" 2>/dev/null || { echo "$commit isn't in this repository"; exit 2; }

source scripts/lib/scratch.sh
scratch_tmpdir vs-verifier-eval

echo "building vibeswitcher-mcp…"
swift build --product vibeswitcher-mcp > /dev/null 2>&1 || { echo "the build failed: run swift build --product vibeswitcher-mcp"; exit 2; }
mcp="$(swift build --show-bin-path)/vibeswitcher-mcp"

out=".build/verifier-eval/$name-$checklist-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
out=$(cd "$out" && pwd)

# 1. The clone: the case's two branches and nothing after them.
clone=$tool_scratch/clone
git clone --quiet --no-local --no-checkout "$repo" "$clone" || { echo "the clone failed"; exit 2; }
git -C "$clone" checkout --quiet -B "agent/$name" "$commit" || exit 2
git -C "$clone" branch --quiet -f project-lead "$commit^" || exit 2
git -C "$clone" remote remove origin
git -C "$clone" for-each-ref --format='%(refname)' | while read -r ref; do
    [[ $ref == "refs/heads/agent/$name" || $ref == refs/heads/project-lead ]] || git -C "$clone" update-ref -d "$ref"
done
git -C "$clone" reflog expire --expire=now --all
git -C "$clone" gc --quiet --prune=now || { echo "pruning the clone failed"; exit 2; }
if [[ -n $(git -C "$clone" rev-list --all --not "$commit") ]]; then
    echo "the clone has commits after $commit"
    exit 2
fi

# 2. Its workflow.md: the project's sensitive_paths and verifier_model.
mkdir -p "$clone/.vibeswitcher"
{
    echo "---"
    grep -E '^(sensitive_paths|verifier_model):' "$repo/../.vibeswitcher/workflow.md" 2>/dev/null
    echo "---"
} > "$clone/.vibeswitcher/workflow.md"
git -C "$clone" log -1 --format=%B "$commit" > "$tool_scratch/message.txt"

# 3. What audit gives the verifier.
"$mcp" --verifier-prompt "$clone" "$name" project-lead "$tool_scratch/message.txt" "$checklist" > "$tool_scratch/start.json" \
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
there. Do everything else as above. Then end your last message with what you would give submit_audit, as one JSON \
object in a ```json block: {"completion": …, "integrity": …, "tests": …, "summary": …, "findings": [{"severity": …, \
"file": …, "line": …, "evidence": …, "failure_scenario": …}]}.
"""
open(sys.argv[2] + "/prompt.md", "w").write(start["prompt"] + replay)
json.dump(start["settings"], open(sys.argv[2] + "/settings.json", "w"), indent=2, sort_keys=True)
open(sys.argv[2] + "/model.txt", "w").write(start["model"] + "\n")
open(sys.argv[2] + "/security.txt", "w").write((start["security"] or "") + "\n")
EOF
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

if [[ $dry == 1 ]]; then
    echo "dry run: nothing sent; the prompt, settings and command are in $out"
    exit 0
fi

# 4. One verifier.
echo "running the verifier (minutes; it reads the branch and may run focused tests)…"
started=$(date +%s)
(cd "$clone" && export HOME=$home CFFIXED_USER_HOME=$home && with_tmpdir "$tool_scratch/verifier-tmp/" "${command[@]}" < /dev/null) \
    > "$out/stream.jsonl" 2> "$out/stderr.log"

python3 -I - "$out" "$places" "$description" "$(( $(date +%s) - started ))" <<'EOF'
import json, re, sys
out, places, description, seconds = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
tolerance = 3
result, texts = None, []
for raw in open(out + "/stream.jsonl", errors="replace"):
    try:
        event = json.loads(raw)
    except Exception:
        continue
    if event.get("type") == "assistant":
        texts += [part.get("text", "") for part in event.get("message", {}).get("content", []) if part.get("type") == "text"]
    elif event.get("type") == "result":
        result = event
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
expected = [(p.rsplit(":", 1)[0], int(p.rsplit(":", 1)[1])) for p in places.split(",")]
used, lines, found = set(), [], 0
for file, line in expected:
    near = [(abs(int(f.get("line") or 0) - line), i) for i, f in enumerate(findings)
            if i not in used and str(f.get("file", "")).lstrip("./") == file and abs(int(f.get("line") or 0) - line) <= tolerance]
    if near:
        i = min(near)[1]
        used.add(i)
        found += 1
        lines.append(f"  found  {file}:{line}  by {findings[i].get('severity')} at line {findings[i].get('line')}")
    else:
        lines.append(f"  missed {file}:{line}")
usage = result.get("modelUsage") or {}
tokens = {key: sum(int(m.get(key) or 0) for m in usage.values())
          for key in ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens")}
cost = result.get("total_cost_usd")
report = [f"{description}", f"known bugs found: {found} of {len(expected)} (findings read from {how})"] + lines
report.append(f"findings: {len(findings)}")
for f in findings:
    evidence = re.sub(r"\s+", " ", str(f.get("evidence", "")))[:160]
    report.append(f"  {f.get('severity')} {f.get('file')}:{f.get('line')}  {evidence}")
report.append("tokens: " + ", ".join(f"{k} {v}" for k, v in tokens.items()) + f"; total {sum(tokens.values())}")
report.append((f"cost: ${cost:.2f} (Claude's total_cost_usd)" if isinstance(cost, (int, float)) else "cost: not given")
              + f", {len(texts)} messages, {seconds / 60:.1f} min")
if result.get("is_error"):
    report.append(f"claude ended with an error: {result.get('subtype')} {result.get('terminal_reason') or ''}")
open(out + "/score.txt", "w").write("\n".join(report) + "\n")
print("\n".join(report))
print(f"kept in {out}")
sys.exit(0 if found == len(expected) else 1)
EOF
