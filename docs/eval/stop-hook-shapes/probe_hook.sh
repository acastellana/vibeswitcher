#!/bin/zsh
# A Stop / UserPromptSubmit hook for the probe: answers its event once, in the shape named by $VSTEST_SHAPE, with a
# message laid out as VibeSwitcher lays one out; every later call (the turn the answer started) says nothing.
# For "replay" it prints $VSTEST_REPLAY as it is. $VSTEST_OUT is the run's folder: the payloads land there, and a
# flag file makes the answer one-shot.
payload=$(cat)
event=$(print -r -- "$payload" | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("hook_event_name",""))')
print -r -- "$payload" >> "$VSTEST_OUT/payloads.jsonl"
case $VSTEST_SHAPE in
  ups-*) [[ $event == UserPromptSubmit ]] || exit 0 ;;
  *) [[ $event == Stop ]] || exit 0 ;;
esac
[[ -e $VSTEST_OUT/answered ]] && exit 0
touch "$VSTEST_OUT/answered"
text="VibeSwitcher · from the user
> done VSTEST-$VSTEST_SHAPE"
json() { /usr/bin/python3 -I -c 'import json,sys; print(json.dumps(eval(sys.argv[1], {"t": sys.argv[2], "e": sys.argv[3]})))' "$1" "$text" "$event"; }
case $VSTEST_SHAPE in
  exit2|async-rewake) print -r -- "$text" >&2; exit 2 ;;
  block) json '{"decision": "block", "reason": t}' ;;
  block-suppress) json '{"decision": "block", "reason": t, "suppressOutput": True}' ;;
  block-sysmsg) json '{"decision": "block", "reason": t, "systemMessage": "VibeSwitcher handed over a message"}' ;;
  sysmsg) json '{"continue": True, "systemMessage": t}' ;;
  context) json '{"hookSpecificOutput": {"hookEventName": e, "additionalContext": t}}' ;;
  stdout) print -r -- "$text" ;;
  ups-context) json '{"hookSpecificOutput": {"hookEventName": e, "additionalContext": t}}' ;;
  ups-stdout) print -r -- "$text" ;;
  replay) cat "$VSTEST_REPLAY" ;;  # the bytes vibeswitcher-hook prints (SteerTests writes them, see README)
esac
exit 0
