// The node's health digest as This node shows it (the `node` value's `health`, the server's `NodeHealth`): freezes of
// the engine's queue, slow refreshes, the host's restarts and refused connections, how the server last ended on its own
// (the node's stand-in for the Mac's crash reports), sessions left waiting or stuck, and the server's last errors. The parts with no page in them, so the tests can read them.
import { t } from './i18n.js';



// "45 s", "12 min", "3 h", "2 days" (the server's NodeHealth.duration).
export function duration(seconds) {
  if (seconds < 120) return `${seconds} s`;
  if (seconds < 7200) return `${Math.floor(seconds / 60)} min`;
  if (seconds < 172800) return `${Math.floor(seconds / 3600)} h`;
  return t('heDays', { n: Math.floor(seconds / 86400) });
}

// The digest as rows and lines: { tone ('done' | 'needs-you'), rows: [[name, value]], lines: [{ at, text }] }, or null
// when the node keeps none.
export function healthFacts(health) {
  if (!health) return null;
  const freezes = health.freezes || [];
  const errors = health.errors || [];
  const waiting = health.waiting || [];
  const rows = [];
  if (health.stalled != null) rows.push([t('heStalledNow'), t('heStalled', { n: health.stalled })]);
  rows.push([t('heFreezes'), freezes.length ? t('heFreezeCount', { n: freezes.length, longest: Math.max(...freezes.map((f) => f.seconds)) }) : t('heNone')]);
  rows.push([t('heSlowRefreshes'), health.slowRefreshes ? t('heSlow', { n: health.slowRefreshes, slowest: health.slowestRefresh }) : t('heNone')]);
  if (health.serverRestarts != null) rows.push([t('heServerRestarts'), String(health.serverRestarts)]);
  if (health.refusedConnections) rows.push([t('heRefusedConnections'), String(health.refusedConnections)]);
  if (health.serverEnded) rows.push([t('heServerLastEnded'), t('heEnded', { cause: health.serverEnded.cause, after: duration(health.serverEnded.ran) })]);
  rows.push([t('heSessionsWaitingOrStuck'), waiting.length ? String(waiting.length) : t('heNone')]);
  // The causes (the Mac's digest of error kinds): the most frequent first, a repeat standing out from a one-off.
  const causes = health.causes || [];
  if (causes.length) rows.push([t('heCauses'), causes.slice(0, 3).map((cause) => `${cause.kind} ×${cause.count}`).join(' · ')]);
  const lines = [
    ...freezes.map((freeze) => ({ at: freeze.at, text: t('heFroze', { n: freeze.seconds }) })),
    ...(health.serverEnded ? [{ at: health.serverEnded.at, text: t('heEndedLine', { cause: health.serverEnded.cause, after: duration(health.serverEnded.ran) }) }] : []),
    ...waiting.map((text) => ({ at: null, text })),
    ...errors.map((error) => ({ at: error.at, text: error.line })),
  ];
  const tone = health.stalled != null || freezes.length || errors.length || waiting.length ? 'needs-you' : 'done';
  return { tone, rows, lines };
}
