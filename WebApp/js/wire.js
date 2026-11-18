// The node's values as the views read them. The views were drawn against the mock's shapes (README.md); the node
// sends the wire contract's (docs/superpowers/specs/2026-11-17-v2-live-wire-contract.md §5). This maps one to the
// other and invents nothing: a field the node doesn't send yet stays empty, and the view that would show it says
// less. Everything else passes through as the node wrote it (rule 3: fields we don't know are kept, not read).

// A session from the `sessions` collection. `leadOf` maps a session id to the project it leads (from `leads`).
//
// - status: what the user reads (`shownStatus`: a lead with a question open needs you), else the agent's own.
// - title: what it's working on, when the node knows (`task`); null lets the views fall back to its folder.
// - detail: the tool call it runs right now (`activity`), else the node's detail.
// - since: when its status began. A session whose status the node can't read (no hook wrote for it) says the start of
//   time; that's no moment to count from, so the row shows no duration for it.
// - lead: the project a lead session leads. A worker's or a verifier's lead isn't on the wire yet: null, so it shows
//   as a session of its own rather than under a team it can't be placed in.
export function session(value, leadOf) {
  return {
    ...value,
    status: value.shownStatus || value.status,
    since: knownMoment(value.since),
    title: value.task || null,
    detail: value.activity || value.detail || null,
    lead: value.role === 'lead' ? leadOf.get(value.id) || null : null,
    paused: false,
  };
}

// Which project each live lead session leads: { session id → project id }.
export function leadsBySession(leads) {
  const map = new Map();
  for (const lead of leads.values()) if (lead.session) map.set(lead.session, lead.project);
  return map;
}

// A date the node sent, or null when it's no real moment (before 2001: `Date.distantPast` and the like).
const EARLIEST = Date.UTC(2001, 0, 1);
function knownMoment(iso) {
  const at = Date.parse(iso);
  return Number.isFinite(at) && at >= EARLIEST ? iso : null;
}
