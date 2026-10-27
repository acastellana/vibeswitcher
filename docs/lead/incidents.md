# Incidents

## 2026-10-27 17:54:07 message() to a long-idle worker (its turn had ended about 24 h before) said "Typed into … as its next prompt", but the prompt was never submitted. It sat as a draft in the input box, and a resend with clear_draft wasn't submitted either.

Evidence: 2026-10-27, task launch-video (worker session 8D1B0D7B, last turn 2026-10-26 16:27). First message at about 17:05: the tool returned "Typed into launch-video's worker as its next prompt (it was between turns)", yet read_session showed no new turn and sessions still showed "finished its turn". The second message, with clear_draft:true, returned "a leftover draft was cleared first", which confirms the first was stuck as a draft. 20 s later sessions still showed "finished its turn". The lead stopped the worker and started a fresh task (launch-video-v3-narrated). Expected: the tool either confirms the session took the prompt (a turn started), or it reports that the prompt wasn't submitted.

Task: launch-video
Check: task turn-this-incident-into turns it into a check that runs before merge.

