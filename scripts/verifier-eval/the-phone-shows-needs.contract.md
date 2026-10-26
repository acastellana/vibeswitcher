The phone shows "needs you" only for the user, like the Mac

What the Pre-existing finding at Sources/VibeSwitcher/PhoneAccess.swift:583 shows is no longer true: The phone reads the prompt menus of every session where session.status == .needsInput (also :630, and statusLabel at :522 uses session.status.label), with no team filter: a worker or verifier waiting on its lead is offered to the user as needing input on the phone, and a lead with an open question but an idle terminal is not. Outside this task's boundaries (the phone isn't named) and unchanged by the branch; same 'needs you only means the user' rule.

Acceptance checks:
- The finding at Sources/VibeSwitcher/PhoneAccess.swift:583 no longer holds: what showed it (The phone reads the prompt menus of every session where session.status == .needsInput (also :630, and statusLabel at :522 uses session.status.label), with no te…) now shows it fixed, with a test that would have caught it

Boundaries:
- Sources/VibeSwitcher/PhoneAccess.swift and its tests

Context:
Same rule as notifications-only-when and needs-you-follow-ups (merged or merging): "needs you" means the user. PhoneAccess.swift :522, :583 and :630 use session.status, so a worker or verifier waiting on its lead appears on the phone as needing the user. Use Session.shownStatus / LeadTeams.waitsOnLead as the Mac does. A team member's prompt is not offered to the user as theirs to answer. The lead's open question does read "needs you". Also fold in needs-you-follow-ups:F2: the menu bar dot's tooltip (AppDelegate.swift:455) uses the raw status; use shownStatus. Focused tests on the phone's state output, failing without the fix. Keep it small: PhoneAccess is sensitive, hence the audit.
