# Incidents

## 2026-11-20 00:35:04 On the Linux node, every start of a Claude Code session re-creates the link ~/.local/bin/claude (same target), and the vault takes it as a config change made while team sessions ran: audits, workers and merges are held until the user accepts, again and again (four accepts in one evening).

Evidence: 2026-11-19/20: holds on ~/.local/bin at about 23:25, 00:30, 00:33 and 00:35, each accepted by the user at the command line. `ls -la --time-style=full-iso ~/.local/bin/claude` showed the link re-created at 00:32:24 and again at 00:34:42, both times pointing at the same ~/.local/share/claude/versions/2.1.329 (that file's own time: 23:16:55, the one real update). Nothing else in ~/.local/bin changed. Each new finder or worker session starts Claude Code, whose updater rewrites the link. Refusals: "finder not started: ~/.local/bin … changed while the team's sessions ran"; port-map-rows-from's merge refused after its tests passed. The check to add: a link replaced by one with the same target (and a folder whose only change is that) is not a change for the seal (LinuxSealList), with a test; a link whose target changed still is.

Check: task turn-this-incident-into turns it into a check that runs before merge.

