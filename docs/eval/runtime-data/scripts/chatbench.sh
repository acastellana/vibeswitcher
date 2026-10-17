#!/bin/zsh
S=$1
BIN=/Applications/VibeSwitcher.app/Contents/MacOS/VibeSwitcher
T=(
 /Users/albert/.claude/projects/-Users-albert-dev-vibeswitcher/cb896e2c-220f-4d94-896e-e529225104a3.jsonl
 /Users/albert/.claude/projects/-Users-albert-dev-genlayerlabscom-site/c75103a3-fab8-4b1c-a3c3-9e4a2a111b32.jsonl
 /Users/albert/.claude/projects/-Users-albert-dev-genlayer-site/801dfe04-af35-4fc8-8ebc-b246ddb95782.jsonl
)
mkdir -p $S/chatbench
for i in 1 2 3; do
  for mode in plain live stack; do
    out=$S/chatbench/t$i-$mode.txt
    case $mode in
      plain) env /usr/bin/time -l $BIN --chat-bench $T[$i] > $out 2> $out.time ;;
      live)  env VIBESWITCHER_BENCH_LIVE=1 /usr/bin/time -l $BIN --chat-bench $T[$i] > $out 2> $out.time ;;
      stack) env VIBESWITCHER_BENCH_STACK=1 /usr/bin/time -l $BIN --chat-bench $T[$i] > $out 2> $out.time ;;
    esac
    echo "done t$i $mode rc=$?"
  done
done
# bonus: hang watchdog end-to-end, writes only into the bench home
env CFFIXED_USER_HOME=$S/benchhome VIBESWITCHER_BENCH_STALL=1 /usr/bin/time -l $BIN --chat-bench $T[3] > $S/chatbench/t3-stall.txt 2> $S/chatbench/t3-stall.txt.time
echo "done stall rc=$?"
