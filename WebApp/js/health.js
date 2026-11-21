// The node's health digest as This node shows it (the `node` value's `health`, the server's `NodeHealth`): freezes of
// the engine's queue, slow refreshes, the host's restarts and refused connections, sessions left waiting or stuck, and
// the server's last errors. The parts with no page in them, so the tests can read them.

const plural = (count, word) => `${count} ${word}${count === 1 ? '' : 's'}`;

// The digest as rows and lines: { tone ('done' | 'needs-you'), rows: [[name, value]], lines: [{ at, text }] }, or null
// when the node keeps none.
export function healthFacts(health) {
  if (!health) return null;
  const freezes = health.freezes || [];
  const errors = health.errors || [];
  const waiting = health.waiting || [];
  const rows = [];
  if (health.stalled != null) rows.push(['Stalled now', `the engine hasn’t answered for ${health.stalled} s`]);
  rows.push(['Freezes', freezes.length ? `${plural(freezes.length, 'freeze')}, the longest ${Math.max(...freezes.map((f) => f.seconds))} s` : 'None']);
  rows.push(['Slow refreshes', health.slowRefreshes ? `${health.slowRefreshes}, the slowest ${health.slowestRefresh} s` : 'None']);
  if (health.serverRestarts != null) rows.push(['Server restarts', String(health.serverRestarts)]);
  if (health.refusedConnections) rows.push(['Refused connections', String(health.refusedConnections)]);
  rows.push(['Sessions waiting or stuck', waiting.length ? String(waiting.length) : 'None']);
  // The causes (the Mac's digest of error kinds): the most frequent first, a repeat standing out from a one-off.
  const causes = health.causes || [];
  if (causes.length) rows.push(['Causes', causes.slice(0, 3).map((cause) => `${cause.kind} ×${cause.count}`).join(' · ')]);
  const lines = [
    ...freezes.map((freeze) => ({ at: freeze.at, text: `The engine didn’t answer for ${freeze.seconds} s` })),
    ...waiting.map((text) => ({ at: null, text })),
    ...errors.map((error) => ({ at: error.at, text: error.line })),
  ];
  const tone = health.stalled != null || freezes.length || errors.length || waiting.length ? 'needs-you' : 'done';
  return { tone, rows, lines };
}
