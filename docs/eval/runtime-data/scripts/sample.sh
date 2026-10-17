#!/bin/zsh
# usage: sample.sh OUT DURATION_S INTERVAL_S
OUT=$1; DUR=$2; INT=$3
APP=${APP:-33127}; HPID=${HPID:-4086}
echo "ts,proc,pid,cputime_s,rss_kb,vsz_kb,threads,fds,top_cpu" > $OUT
end=$(( $(date +%s) + DUR ))
tosec() { awk -F'[:.]' '{ if (NF==4) print $1*3600+$2*60+$3+$4/100; else print $1*60+$2+$3/100 }' <<< "$1"; }
while [ $(date +%s) -lt $end ]; do
  ts=$(date +%s)
  topout=$(top -l 2 -s 1 -pid $APP -pid $HPID -stats pid,cpu 2>/dev/null | tail -n 3)
  for p in app:$APP host:$HPID; do
    name=${p%%:*}; pid=${p##*:}
    line=$(ps -o time=,rss=,vsz= -p $pid) || continue
    t=$(echo $line | awk '{print $1}'); rss=$(echo $line | awk '{print $2}'); vsz=$(echo $line | awk '{print $3}')
    th=$(( $(ps -M -p $pid | wc -l) - 1 ))
    fds=$(( $(lsof -n -p $pid 2>/dev/null | wc -l) - 1 ))
    tc=$(echo "$topout" | awk -v p=$pid '$1==p{print $2}' | tail -1)
    echo "$ts,$name,$pid,$(tosec $t),$rss,$vsz,$th,$fds,$tc" >> $OUT
  done
  sleep $(( INT - ( $(date +%s) - ts ) > 0 ? INT - ( $(date +%s) - ts ) : 1 ))
done
