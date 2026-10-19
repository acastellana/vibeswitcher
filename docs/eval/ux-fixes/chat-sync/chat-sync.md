# Chat and terminal in sync: before and after

Pictures from `ChatSyncSnapshots` (`CHAT_SYNC_SNAPSHOT_DIR=… CHAT_SYNC_SNAPSHOT_NAME=before|after swift test --filter
ChatSyncSnapshots`): the real chat view over the fake Claude Code of `ChatSyncTests` (a scratch host, never a real
session), with the terminal's screen as the app's pane reads it on the right. `before` is the code at 832569c, `after`
the fixes.

- **tabs**: Fruit answered, then ← back to it in the terminal. Before, the card stays on "Question 2 of 2" and asks
  "Which toppings?" over Fruit's options, because the open tab was taken to be the first one not answered (Claude marks
  the open tab only by its background colour, which the screen read dropped). After, the open tab is read from the
  highlight: "Question 1 of 2", "Which fruit?".
- **multi-select**: Cream ticked, the terminal's cursor on the Submit row. Before, the card is gone (no option was
  marked, so no menu was read) and the chat shows the working line instead. After, ticks as checkboxes, the free-text
  row as Other…, and a Submit button.
- **send-during-prompt**: "1 more thing, then stop" sent from the composer while a permission prompt is open. Before,
  it was typed into the prompt: "1" allowed the command and the rest went into the agent's box. After, the prompt is
  untouched, and the message waits ("waits until the question is answered"), going in once it's answered.
