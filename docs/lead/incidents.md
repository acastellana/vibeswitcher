# Incidents

## 2026-10-27 17:54:07 message() to a long-idle worker (its turn had ended about 24 h before) said "Typed into … as its next prompt", but the prompt was never submitted. It sat as a draft in the input box, and a resend with clear_draft wasn't submitted either.

Evidence: 2026-10-27, task launch-video (worker session 8D1B0D7B, last turn 2026-10-26 16:27). First message at about 17:05: the tool returned "Typed into launch-video's worker as its next prompt (it was between turns)", yet read_session showed no new turn and sessions still showed "finished its turn". The second message, with clear_draft:true, returned "a leftover draft was cleared first", which confirms the first was stuck as a draft. 20 s later sessions still showed "finished its turn". The lead stopped the worker and started a fresh task (launch-video-v3-narrated). Expected: the tool either confirms the session took the prompt (a turn started), or it reports that the prompt wasn't submitted.

Task: launch-video
Check: task turn-this-incident-into turns it into a check that runs before merge.

## 2026-10-27 20:14:19 The app froze about 20 times, 2–25 s each, between 19:31 and 20:12 on 2026-10-27, with project-b's long lead chat selected. The time went to SwiftUI accessibility, layout and session-list rebuilds.

Evidence: ~/.vibeswitcher/debug/hang-20261027-193139 … hang-20261027-201159 (the longest is hang-20261027-200308 at 25.2 s). In every one, a lead session was selected (project-b, about 290 entries), the chat was shown and the window was not key. The loads ranged from 8 to 36. The top frames were SwiftUI AccessibilityNode.updateChildren, AccessibilityProperties.merge, NSAccessibility entry points, SessionListView.body → LeadTeams.arrange, and LeadTeamPane.body → MacLoad.count. The fix task is lead-chat-freezes-of; its acceptance includes a bench with an accessibility client walking a 300-entry chat.

Task: lead-chat-freezes-of
Check: task turn-this-incident-into-2 turns it into a check that runs before merge.

## 2026-10-27 21:15:41 The witness reports "ended without a verdict (its agent quit; the session's shell is still open)" while the agent's claude process is still alive and waiting on a background command. The lead then restarts the audit and throws away a working verifier.

Evidence: 2026-10-27, task land-pr-1-host. The verifier with claude pid 1558 (spawned 20:57:23) was reported as quit; its transcript (~/.claude/projects/-Users-albert-dev-vibeswitcher--vibeswitcher-worktrees-land-pr-1-host/42d3d0fc-….jsonl) shows it mid-request at 21:03:42. The lead re-audited and it was killed at 21:04:34 (host.log). The next verifier (claude pid 19328, spawned 21:04:35) started a background load run (test-under-load.sh) and ended its turn at 21:09:17 with "I'll finish the audit when it reports". The witness again said "its agent quit", but `ps` shows pid 19328 alive, with the parent vibeswitcher-host. The hang-detector-don-t worker was reported the same way at about 21:03. Probable cause: the witness judges "agent quit" from the terminal's foreground process (or the screen showing a shell prompt), which changes while Claude Code runs a background shell. It should check that the agent's own process (the session's claude pid) has exited.

Task: land-pr-1-host
Check: task turn-this-incident-into-3 turns it into a check that runs before merge.

## 2026-10-28 07:47:49 The lead's vibeswitcher tool server exits in the middle of a session ("connection closed (cleanly)"), leaving the lead with no tools until the user runs /mcp. It happened twice in 14 h. The first time was preceded by EBADF ("Bad file descriptor") from cleanup and start_worker.

Evidence: 2026-10-27: cleanup(lead-chat-freeze) and auto_advance's start of lead-chat-deliver-wake failed with "Error Domain=NSPOSIXErrorDomain Code=9 'Bad file descriptor'". A manual cleanup failed the same way. Minutes later the tool server (pid 10199, running since Oct 24) was gone, and Claude's MCP log (~/Library/Caches/claude-cli-nodejs/-Users-albert-dev-vibeswitcher/mcp-logs-vibeswitcher/2026-10-24T14-28-45-819Z.jsonl) shows "connection closed after 764s (cleanly)" at 17:45Z. The user reconnected with /mcp at about 19:06Z. 2026-10-28: the server disconnected again at about 06:40Z and the user reconnected with /mcp. The tool server writes no log of its own, so the cause of the exit isn't recorded. The Mac was under heavy load (35–97) around both events, and slept at 2 % battery overnight.

Check: task turn-this-incident-into-4 turns it into a check that runs before merge.

## 2026-10-28 07:59:44 After PR #1 was installed, the Mac-wide limits (mac_max_sessions, the per-project counts in status) count only the calling lead's own team. Each lead now sees the Mac as emptier than it is and can start past the shared limit of 10.

Evidence: 2026-10-28 07:59: installed build 1793170724 (PR #1 merged as f5bdf1a), and the host handed over. Right after, the lead's status read "5 team sessions across 1 project (vibeswitcher 5)", while `ps` showed 9 team agents: vibeswitcher 5, project-b 3 (worker-landing-page-fixes-and, worker-shared-css-and-style, worker-sidebar-and-badge) and project-c 1 (worker-make-github-ci-pass). Before the install, status read "vibeswitcher 6, project-b 3, project-c 1". Cause: PR #1 filters hello's session list to what the caller may access, and the Mac-wide census is built from HostCall.sessions (hello).

Check: task turn-this-incident-into-5 turns it into a check that runs before merge.

## 2026-10-30 21:42:14 auto_advance merged a task the lead had set to kept: it ran the merge gate on build-app-sh-install and sent its worker the failure, and the task's status went from kept back to running.

Evidence: 2026-10-30. build-app-sh-install's audit passed at 21:26. The lead then set update_task(status: kept, reason: main's suite fails 2 pre-existing tests) and got "Updated build-app-sh-install: state kept." At ~21:41 (setback.at 1793392902), auto_advance reported "Merge of build-app-sh-install failed: Tests fail rebased onto main … Sent its worker the output; it's back at work." board(build-app-sh-install) afterwards shows status running, with keptBecause still set. The merge should have been refused for a kept task (step 6: merge refuses it until the lead sets it back). Possible cause: the merge was queued at the clean verdict, before the hold, and didn't re-check status at run time.

Task: build-app-sh-install
Check: task turn-this-incident-into-2 turns it into a check that runs before merge.

## 2026-10-31 16:48:31 A worker's or verifier's session that hits the account's usage limit isn't reported as stopped: status keeps it running or in review, and no witness report is sent, so the lead and the user wait on a session that will do nothing until the reset.

Evidence: 2026-10-31, two projects. (1) Reported by another project's lead: at about 16:41 a re-audit started, ran one command, and its session printed "You've hit your weekly limit · resets Nov 3 at 1am (Europe/Madrid)" and sat there. status kept showing the task in review as if the audit were running, no witness report said stalled or stopped, and the user had to ask "u sure we're not stuck?". It was found only with read_session(verifier). (2) In this project, agents-know-they-can's worker hit the same limit at about 16:35. status showed "its turn ended on an API error (You've hit your weekly limit …)" only when called, and no report came. The fix: the witness treats a usage-limit line in a worker's or verifier's output as a stop, reports it to the lead with the reset time (parsed when present), and status shows the task as waiting on the limit, not running or in review.

Task: agents-know-they-can
Check: task turn-this-incident-into-6 turns it into a check that runs before merge.

## 2026-10-31 16:51:30 `build-app.sh --install` replaced the bundle of a VibeSwitcher that was still running. Its process check (`pgrep -x VibeSwitcher`) finds nothing from a sandboxed shell, so the script printed "VibeSwitcher isn't running", copied over the live app, and `open` only brought the old process forward.

Evidence: 2026-10-31 ~16:46, the user ran `! scripts/build-app.sh --install` from a Claude Code session. The output: "VibeSwitcher isn't running." … "Installed /Applications/VibeSwitcher.app, but no new VibeSwitcher process is up 10s after the launch (running: )." Meanwhile `ps` shows pid 3218 /Applications/VibeSwitcher.app/Contents/MacOS/VibeSwitcher, started 14:37:49, still running at 16:51. From the same shell, `pgrep -x VibeSwitcher` exits 1, while `ps -Ao pid=,comm=` lists it. This is the second install that left the old process running (the first was 2026-10-30, fixed in scripts/lib/install-app.sh), and it's worse this time: the bundle was removed and replaced under the live process. The fix: running() finds the app with ps (by its executable path inside DEST_APP, not just the name), and fails closed. If the process list can't be read, or a process of that path is up and won't quit, nothing is copied. The test drives install-app.sh with a stand-in process that pgrep can't see but ps can.

Check: task turn-this-incident-into-7 turns it into a check that runs before merge.

## 2026-11-01 00:32:38 A verifier's session waits indefinitely on a permission prompt the user can't see or reach, often for read-only commands, and the only way out is restarting the audit, which throws away the finders' work. It has happened twice.

Evidence: Reported by another project's lead. (1) 2026-10-31 ~16:2x: vault-structure-v1's verifier hung on a probe script's permission prompt (that project's incidents.md, 16:23). (2) 2026-11-01 00:31: crypto-hardening-harness's audit finder waited on a prompt for `git ls-files -s …; git remote -v; git branch -r | grep …; grep … package-lock.json`, all read-only. Each time the lead could only restart the audit. Two fixes are wanted. (a) Verifiers (and finders) run read-only git (ls-files, remote -v, branch -r/-a, log, show, diff, status, rev-parse, merge-base, cat-file) and grep/rg/head/tail/wc/sort without a prompt, including when chained with ; && | in one command, as long as every part is on the read-only list. (b) The witness treats a verifier or finder waiting on a permission prompt for more than ~2 minutes as stuck: it declines the prompt with a reason the verifier can act on ('No one answers verifier prompts: use only read-only commands, or report what you couldn't check') and tells the lead what was asked, instead of leaving the audit hanging.

Check: task turn-this-incident-into-8 turns it into a check that runs before merge.

## 2026-11-05 15:54:03 A verifier stops on a permission prompt to Read the worker's evidence screenshots (<repo>/.vibeswitcher/evidence/<task>/<report>/*.png, outside its worktree), VibeSwitcher can't decline that prompt, and the audit hangs until the user allows it or the lead restarts it. Three times on 2026-11-05: once here and twice in another project, one of them for 155 minutes.

Evidence: Here: wallet-requests-marked's audit at 6d0d8cc5, 2026-11-05 15:14: the witness reported "The verifier … has waited 2 min for input no one answers. It waited on: Allow: Read 4-marked-no-peer-main-dark.png {file_path: …/.vibeswitcher/evidence/wallet-requests-marked/<report id>/4-marked-no-peer-main-dark.png} VibeSwitcher couldn't decline it (that prompt isn't on its screen, or it changed while the keys went in)"; it went on only after the user chose Allow (question 7A3D6D24). Another project's lead reported the same prompt twice the same day on one task's audit, the first sitting 155 minutes until the audit was restarted. Cause as read in the code: a verifier's settings (LeadLaunch.prepare: allow, deny, the PermissionRequest hook for Bash only) give it no read access to the evidence folder in the main checkout, while its prompt names the screenshots there; and the witness's decline (LeadWitness.stuckPrompts) only handles a "Do you want to …?" prompt, not a Read prompt.

Task: wallet-requests-marked
Check: task turn-this-incident-into-3 turns it into a check that runs before merge.

## 2026-11-05 23:33:26 The user's Allow on a verifier's Read permission prompt didn't reach the session, twice on 2026-11-05: the user answered "I allowed it" and "allowed in both", yet the verifiers stayed on the prompt (136 and 164 minutes in all) until the user answered it with the keyboard in the session's Terminal view.

Evidence: wallet-requests-marked's first audit: stopped 15:14 on "Allow: Read 4-marked-no-peer-main-dark.png"; the user answered question 7A3D6D24 "I allowed it" about 15:25; the verifier's transcript had no tool result and its state no event until the audit was replaced at 20:42. Second audit of the same task stopped 20:44, and wallet-requests-reach-a's stopped 23:24; the user answered A0CDD1C6 "Done: allowed in both" about 23:28; ~/.vibeswitcher/state/ttys008.json and ttys011.json still read lastEvent Notification, notificationType permission_prompt, toolName Read, lastEventAt 20:44 and 23:24 at 23:30. After the user answered in each session's Terminal view with the keyboard (question A0056E73), both state files read lastEvent PostToolUse at 23:33. Where the first Allow clicks were made (the Chat view's buttons, a notification) isn't known yet: the user has been asked. The witness said of the same prompts "VibeSwitcher couldn't decline it (that prompt isn't on its screen, or it changed while the keys went in)", so the app's own keys for this prompt don't match what the session shows.

Task: wallet-requests-reach-a
Check: task turn-this-incident-into-4 turns it into a check that runs before merge.

