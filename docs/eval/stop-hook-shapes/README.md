# What Claude Code shows for each Stop-hook answer

Evidence: on 2026-10-19 08:06 the genswap lead's window showed the user's "done" answer under
`Ran 2 stop hooks` / `Stop hook error: [VibeSwitcher · messages, v2] …`, and the user asked what had gone wrong.
Nothing had: VibeSwitcher hands over at the turn's end whatever arrived while the agent worked (a user answer, a
report, a lead message) through the Stop hook, and it did so with `{"decision": "block", "reason": text}`, which
Claude Code shows as an error.

## Method

A scratch Claude Code in a pty (`run_shape.py`, screen drawn by pyte, 140×60) with `HOME` and `CFFIXED_USER_HOME`
on a scratch folder, its project folder outside the user's home, talking to a local stand-in for the Messages API
(`mock_api.py`, `ANTHROPIC_BASE_URL` on 127.0.0.1, a dummy key): no login, nothing of the user's read or touched,
no real session typed into. The prompt is `hello`; the hook (`probe_hook.sh`) answers its event once, in one shape,
with a two-line message laid out as VibeSwitcher lays one out and a `VSTEST-<shape>` marker. The mock records every
request and replies `ACK: VSTEST-<shape>` when what came after the model's last turn carries the marker. That reply
on screen means the hook's text reached the model and the turn went on to act on it. `summarize.py` prints, per
run, the window from the prompt on, where the text reached the model, and the transcript records holding it
(`results.txt`).

    python3 -m venv .build/stophook/venv && .build/stophook/venv/bin/pip install pyte
    .build/stophook/venv/bin/python docs/eval/stop-hook-shapes/run_shape.py \
        ~/.local/share/claude/versions/2.1.302 <shape> .build/stophook/runs/<shape> $TMPDIR/stophook-projects/<shape>
    python3 -I docs/eval/stop-hook-shapes/summarize.py .build/stophook/runs

`replay` hands over the exact bytes `vibeswitcher-hook` prints at a Stop. Write them with
`STOP_HOOK_REPLAY_FILE=$PWD/.build/stophook/replay.json swift test --filter aStopHandsOverTheUsersAnswerAsAddedContext`,
then run the shape with `VSTEST_REPLAY` set to that file.

## The table (Claude Code 2.1.302)

| The hook's answer | Window | The model gets | The turn | Transcript |
|---|---|---|---|---|
| exit 2, text on stderr | `Ran 1 stop hook` ⎿ `Stop hook error: [<command>]: <text>` | user turn `Stop hook feedback:\n[<command>]: <text>` | goes on, model acts | user (isMeta), stop_hook_summary |
| `{"decision": "block", "reason": text}` (VibeSwitcher until now) | `Ran 1 stop hook` ⎿ `Stop hook error: <text>` | user turn `Stop hook feedback:\n<text>`, and `Stop hook blocking error from command: "<command>": <text>` | goes on, model acts | user (isMeta), attachment hook_blocking_error, stop_hook_summary |
| the same with `"suppressOutput": true` | the same: `Stop hook error: <text>` | the same | goes on, model acts | the same |
| the same with a `systemMessage` | ⎿ `Stop says: <systemMessage>`, then `Stop hook error: <text>` | the same | goes on, model acts | the same |
| `{"continue": true, "systemMessage": text}` | ⎿ `Stop says: <text>` | nothing | ends | attachment hook_system_message |
| `{"hookSpecificOutput": {"hookEventName": "Stop", "additionalContext": text}}` | `Ran 1 stop hook` ⎿ `Stop hook feedback: <text>` | `<system-reminder>Stop hook additional context: <text></system-reminder>` | goes on, model acts | attachment hook_additional_context, stop_hook_summary |
| plain stdout, exit 0 | nothing (the transcript view only) | nothing | ends | attachment hook_success |
| exit 2 from a hook set `asyncRewake: true` (an `@internal` option), `rewakeSummary` set | the turn ends; then `⏺ <rewakeSummary>` | a new user turn: `<task-notification>` and a system-reminder framing it as "an automated background-task event, NOT a message from the user" | ends, then a new one starts | queue-operation, user |
| UserPromptSubmit: `hookSpecificOutput.additionalContext` | nothing (only the prompt) | `UserPromptSubmit hook additional context: <text>` with the prompt | n/a (the prompt's turn) | attachment hook_additional_context |
| UserPromptSubmit: plain stdout | nothing | `UserPromptSubmit hook success: <text>` with the prompt | n/a | attachment hook_success |

`Stop hook feedback` is Claude Code's own label for a Stop hook's added context. No shape that keeps the turn going
shows the text with no label at all.

## The choice

`hookSpecificOutput.additionalContext`, the shape VibeSwitcher already used on PostToolUse and UserPromptSubmit,
now used on Stop as well:

- no error label: the window shows `Stop hook feedback: [VibeSwitcher · messages, v2] …`, then the sender line
  (`The user sent this while you were working (through VibeSwitcher)…`, `Your project lead (…) sent this…`,
  `VibeSwitcher (not the user) reports (…)`) and the quoted text;
- the turn goes on at once, with no keystroke, and the model reads the text as a system-reminder and acts on it;
- the transcript records it as a `hook_additional_context` attachment, which the chat reads under its sender, like
  a delivery after a tool. A block was recorded as a `hook_blocking_error`, which the chat never showed.

Not chosen:

- exit 2 and `decision: block` are the "Stop hook error" this fixes.
- `systemMessage` and plain stdout never reach the model, and the turn ends.
- `asyncRewake` is `@internal` and undocumented. The turn ends first, so VibeSwitcher sees the agent idle and could
  type over the wake-up. The message also reaches the model framed as an automated event, "NOT a message from the
  user", which is wrong for the user's answer.

The text handed over is unchanged, byte for byte, as are its header, sender lines and seal. Only the JSON around it
changed.

Checked with the bytes `vibeswitcher-hook` now prints (`replay` in `results.txt`): on 2.1.300, 2.1.302 and 2.1.303
the window shows `Stop hook feedback:` and the model replies `ACK: VSTEST-replay` in the same turn.
