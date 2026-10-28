# Incidents

## 2026-10-27 17:54:07 message() to a long-idle worker (its turn had ended about 24 h before) said "Typed into … as its next prompt", but the prompt was never submitted. It sat as a draft in the input box, and a resend with clear_draft wasn't submitted either.

Evidence: 2026-10-27, task launch-video (worker session 8D1B0D7B, last turn 2026-10-26 16:27). First message at about 17:05: the tool returned "Typed into launch-video's worker as its next prompt (it was between turns)", yet read_session showed no new turn and sessions still showed "finished its turn". The second message, with clear_draft:true, returned "a leftover draft was cleared first", which confirms the first was stuck as a draft. 20 s later sessions still showed "finished its turn". The lead stopped the worker and started a fresh task (launch-video-v3-narrated). Expected: the tool either confirms the session took the prompt (a turn started), or it reports that the prompt wasn't submitted.

Task: launch-video
Check: task turn-this-incident-into turns it into a check that runs before merge.

## 2026-10-27 20:14:19 The app froze about 20 times, 2–25 s each, between 19:31 and 20:12 on 2026-10-27, with stakegen's long lead chat selected. The time went to SwiftUI accessibility, layout and session-list rebuilds.

Evidence: ~/.vibeswitcher/debug/hang-20261027-193139 … hang-20261027-201159 (the longest is hang-20261027-200308 at 25.2 s). In every one, a lead session was selected (stakegen, about 290 entries), the chat was shown and the window was not key. The loads ranged from 8 to 36. The top frames were SwiftUI AccessibilityNode.updateChildren, AccessibilityProperties.merge, NSAccessibility entry points, SessionListView.body → LeadTeams.arrange, and LeadTeamPane.body → MacLoad.count. The fix task is lead-chat-freezes-of; its acceptance includes a bench with an accessibility client walking a 300-entry chat.

Task: lead-chat-freezes-of
Check: task turn-this-incident-into-2 turns it into a check that runs before merge.

## 2026-10-27 21:15:41 The witness reports "ended without a verdict (its agent quit; the session's shell is still open)" while the agent's claude process is still alive and waiting on a background command. The lead then restarts the audit and throws away a working verifier.

Evidence: 2026-10-27, task land-pr-1-host. The verifier with claude pid 1558 (spawned 20:57:23) was reported as quit; its transcript (~/.claude/projects/-Users-albert-dev-vibeswitcher--vibeswitcher-worktrees-land-pr-1-host/42d3d0fc-….jsonl) shows it mid-request at 21:03:42. The lead re-audited and it was killed at 21:04:34 (host.log). The next verifier (claude pid 19328, spawned 21:04:35) started a background load run (test-under-load.sh) and ended its turn at 21:09:17 with "I'll finish the audit when it reports". The witness again said "its agent quit", but `ps` shows pid 19328 alive, with the parent vibeswitcher-host. The hang-detector-don-t worker was reported the same way at about 21:03. Probable cause: the witness judges "agent quit" from the terminal's foreground process (or the screen showing a shell prompt), which changes while Claude Code runs a background shell. It should check that the agent's own process (the session's claude pid) has exited.

Task: land-pr-1-host
Check: task turn-this-incident-into-3 turns it into a check that runs before merge.

## 2026-10-28 07:47:49 The lead's vibeswitcher tool server exits in the middle of a session ("connection closed (cleanly)"), leaving the lead with no tools until the user runs /mcp. It happened twice in 14 h. The first time was preceded by EBADF ("Bad file descriptor") from cleanup and start_worker.

Evidence: 2026-10-27: cleanup(lead-chat-freeze) and auto_advance's start of lead-chat-deliver-wake failed with "Error Domain=NSPOSIXErrorDomain Code=9 'Bad file descriptor'". A manual cleanup failed the same way. Minutes later the tool server (pid 10199, running since Oct 24) was gone, and Claude's MCP log (~/Library/Caches/claude-cli-nodejs/-Users-albert-dev-vibeswitcher/mcp-logs-vibeswitcher/2026-10-24T14-28-45-819Z.jsonl) shows "connection closed after 764s (cleanly)" at 17:45Z. The user reconnected with /mcp at about 19:06Z. 2026-10-28: the server disconnected again at about 06:40Z and the user reconnected with /mcp. The tool server writes no log of its own, so the cause of the exit isn't recorded. The Mac was under heavy load (35–97) around both events, and slept at 2 % battery overnight.

Check: task turn-this-incident-into-4 turns it into a check that runs before merge.

