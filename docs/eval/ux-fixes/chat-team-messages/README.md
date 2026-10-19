# Team messages in the chat

Before (2026-10-19 08:45): a worker's report delivered to the lead showed in the chat view in full, as one of the
user's own messages (right-aligned, "from another agent (not you)"). The terminal doesn't show it at all, since
Claude Code doesn't display context a hook adds.

After: offscreen renders of the real chat view (`ChatView`) on a made-up lead transcript, light and dark, drawn by

    HOME=$SCRATCH CFFIXED_USER_HOME=$SCRATCH TEAM_MESSAGE_SNAPSHOT_DIR=$PWD/docs/eval/ux-fixes/chat-team-messages \
        swift test --filter TeamMessageSnapshots

(the transcript is written under the scratch home's `.claude/projects`; the TL;DR lines come from a fake helper,
not from Claude).

- `chat-team-messages-light.png`, `chat-team-messages-dark.png`, from the top: the user's prompt and the agent's
  reply (unchanged); the wake-up VibeSwitcher typed while the lead was idle; a worker's report, collapsed to its
  first line with its TL;DR; a witness notice; a failed audit, opened (Markdown as the chat renders it); the user's
  answer relayed through the hook, opened, shown in the user's colour inside the card; part 2 of 3 of a long report;
  the agent's next reply.

Each card is purple (the user's prompts are blue, steered messages orange, the agent's replies plain text). Its
title names the sender and what it is, the gist is its first line, and the chevron or a click opens it (kept per
conversation, like tool groups). VoiceOver reads it as a button: "title: gist", collapsed or expanded.
