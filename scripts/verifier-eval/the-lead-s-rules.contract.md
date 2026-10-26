The lead's rules that matter become checks, not just notes

The rules that live only as prose in docs/lead/decisions.md (454 lines), workflow.md's notes and the lead's brief are sorted. Those that matter are enforced by VibeSwitcher, so a lead that forgets one can't break it. The rest are marked as guidance on purpose. Deliver (1) an inventory and (2) mechanical checks for at most the 5 rules whose breach has cost the most (incidents, reverted merges, the user's time). Start with "don't change a branch while its audit runs": if a task's branch head moves during its audit, VibeSwitcher ends that verifier and audits the new head, or refuses the change, whichever fits the existing audit code.

Acceptance checks:
- docs/lead/rules.md: each rule found, one line each, with its source (decision date or file:line) and its status. 'enforced by <check/test>' or 'guidance: <why no check>'. Duplicates and rules that are obsolete are listed as such, and nothing is deleted from decisions.md.
- For each of up to 5 rules made mechanical: a focused test that breaks the rule and shows it refused or corrected, failing without the change (git apply -R). One of the five is the branch-moves-during-audit rule, unless the code already handles it, in which case show the test that proves it and pick another.
- The lead's brief (LeadWorkflow.swift) drops the prose for rules now enforced, or shortens it to one line saying the tool enforces it. The brief doesn't get longer overall.
- Done report: the inventory's counts (enforced before, enforced now, guidance), and per new check what breach it stops, with the incident or decision it came from.

Boundaries:
- docs/lead/rules.md, the lead tools and checks in VibeCore where each rule's action happens (LeadToolset, LeadAdvance and other sensitive files are fine: this task is audited), LeadWorkflow.swift's briefs, and tests.
- At most 5 new checks. No rule that makes a lead ask the user more often. Stop when those 5 work and the inventory is written: no second round.

Context:
Idea from "harness engineering": write an important rule twice, as guidance and as a check the agent can't bypass, so a past failure becomes a permanent improvement and the next agent doesn't have to remember it. Today's example (decision 2026-10-25): the lead changed the planted-git-hooks branch while its audit ran, so a verifier audited a stale head and two verifiers ran. incidents.md lists incidents that already became tests. Don't duplicate those, just mark them enforced. This runs after the tasks now changing LeadToolset, LeadAdvance and the tool server are merged, to avoid conflicts.

Added: also keep decisions.md short. Every lead reads it at start, and it's 454 lines. Move decisions that are superseded, obsolete, or now enforced by a check into docs/lead/decisions-archive.md, keeping their text and date, with one line in decisions.md pointing to the archive. The current decisions stay in decisions.md, unchanged. This replaces 'nothing is deleted from decisions.md': nothing is deleted, but archived ones move. Report the line count before and after. (Idea from Octopus-SI-OS's memory consolidation: merge duplicates, withdraw stale notes.)

Changed by the lead after the worker's question: the inventory goes to docs/process/lead-rules.md (workers can't write docs/lead*, a guard rail). The decisions.md trim and the archive are dropped from this task. The inventory only marks superseded or obsolete decisions. docs/lead/ stays untouched.
