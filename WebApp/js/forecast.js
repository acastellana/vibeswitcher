// The estimates on the roadmap (the redesign's "Estimates" and "The roadmap view"), no page in it: whether a board has
// any date to draw, a landing said as the node says it (BoardValue's forecast, LeadForecast.text's words), where every
// date comes from, and the time axis (now, today's hours, each midnight) the bars are placed on. Dates are the browser's
// locale's; nothing here invents one: a forecast without a date draws none.

import { t, lang } from './i18n.js';

const DATED = new Set(['estimated', 'median', 'partial']);
const ms = (iso) => { const at = Date.parse(iso || ''); return Number.isFinite(at) ? at : null; };

// A landing with a date to place: estimated, by the median, or a goal's "at least".
export const dated = (landing) => !!landing && DATED.has(landing.basis) && ms(landing.likely) !== null;

// Whether the board has any date to draw: else the roadmap draws what it drew before the estimates.
export function hasDates(board) {
  return [...(board?.tasks || []), ...(board?.goals || [])].some((one) => dated(one.forecast));
}

// 14:30 today; "Tue 24 Nov, 09:10" another day; in the browser's language.
export function when(iso, now = Date.now()) {
  const at = new Date(ms(iso) ?? 0);
  const today = at.toDateString() === new Date(now).toDateString();
  return new Intl.DateTimeFormat(lang(), today ? { hour: 'numeric', minute: '2-digit' }
    : { weekday: 'short', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' }).format(at);
}

// A landing in words, as the node says it: "~09:50", "by 10:20", "at least ~09:50", "no date: waits on X", "past its
// worst case by 25 min", and for a merged task when it merged. { date, range, note, late }; empty for none.
export function landingWords(landing, now = Date.now(), { task = null, board = null } = {}) {
  if (!landing) return { date: '', range: '', note: '', late: false };
  if (landing.basis === 'blocked') return { date: t('fcWaits', { who: whoWaits(landing, task, board) }), range: '', note: '', late: false };
  if (landing.basis === 'overdue') return { date: t('fcOverdue', { n: landing.overdueMin ?? 0 }), range: '', note: '', late: true };
  if (landing.basis === 'done') return { date: ms(landing.likely) ? t('fcMerged', { when: when(landing.likely, now) }) : '', range: '', note: '', late: false };
  if (!dated(landing)) return { date: '', range: '', note: '', late: false };
  const notes = [landing.basis === 'median' ? t('fcByMedian') : landing.over ? t('fcOver') : '', landing.undated ? t('fcUndated', { n: landing.undated }) : ''].filter(Boolean);
  return {
    date: (landing.basis === 'partial' ? t('fcAtLeast') : '') + '~' + when(landing.likely, now),
    range: ms(landing.worst) ? t('fcBy', { when: when(landing.worst, now) }) : '',
    note: notes.join('; '), late: !!landing.over,
  };
}

// Whom a task with no date waits on, said as a who (the node's `waitsOn` is one string for several things): a task it
// comes after (by its slug: its title), the user (a question names the task), the lead (it failed, it was kept back, or
// the blocker's first line: the question itself stays for the task opened in place), or what the node said.
export function whoWaits(landing, task = null, board = null) {
  const said = String(landing?.waitsOn || '').trim();
  if (!said) return t('fcNotSaid');
  const after = board?.tasks?.find((one) => one.slug === said);
  if (after) return `“${after.title}”`;
  if (/^you\b/.test(said)) return t('fcWhoYou');
  if (/^(the lead|kept back by the lead)\b/.test(said)) return said.startsWith('kept') ? t('fcWhoKept') : t('fcWhoLeadFailed');
  if (said === 'something not said') return t('fcNotSaid');
  const blocker = String(task?.blocker || '').split('\n').find((line) => line.trim())?.trim() || '';
  if (blocker && (blocker === said || blocker.startsWith(said))) return t('fcWhoLead');
  return task ? t('fcWhoLead') : said;
}

// Where a date comes from, for its hover and focus: always marked as an estimate.
export function basisWords(landing, { estimate = null, score = null, goal = false } = {}) {
  if (!dated(landing)) return '';
  const history = score?.enough ? t('fcCorrected', { x: ((score.correctionPct || 100) / 100).toFixed(1) }) : t('fcUncorrected');
  if (landing.basis === 'median') return t('fcBasisMedian');
  if (goal) return t(landing.basis === 'partial' ? 'fcBasisGoalPartial' : 'fcBasisGoal', { n: landing.undated || 0 }) + ' ' + history;
  const who = estimate?.by === 'lead' ? t('fcByLead') : t('fcByWorker');
  return t('fcBasisEstimate', { who, likely: estimate?.likelyMin ?? '?', worst: estimate?.worstMin ?? '?' }) + ' ' + history;
}

// A task's estimate in words: "30–60 min, the worker's, at 09:20".
export function estimateWords(estimate, now = Date.now()) {
  if (!estimate) return '';
  const who = estimate.by === 'lead' ? t('fcByLead') : t('fcByWorker');
  return t('fcEstimate', { likely: estimate.likelyMin, worst: estimate.worstMin, who }) + (estimate.at ? ` · ${when(estimate.at, now)}` : '');
}

const HOUR = 3600e3;

// The axis the bars are placed on: from a little before now (or the earliest start shown) to past the last date,
// its ticks every few hours (as few as read well) and at each midnight, now among them. `x(at)`: a percentage.
export function timeAxis(points, now = Date.now()) {
  const known = points.filter((at) => Number.isFinite(at));
  const from = Math.max(Math.min(now - 2 * HOUR, ...known), now - 24 * HOUR);
  const last = Math.max(now + 4 * HOUR, ...known);
  const to = last + (last - from) * 0.08;
  const span = to - from;
  const step = [1, 2, 3, 6, 12, 24].find((hours) => span / (hours * HOUR) <= 8) || 24;
  const ticks = [];
  const first = new Date(from);
  first.setMinutes(0, 0, 0);
  for (let at = first.getTime() + HOUR; at < to; at += HOUR) {
    const hour = new Date(at).getHours();
    if (hour === 0) ticks.push({ at, day: true, label: new Intl.DateTimeFormat(lang(), { weekday: 'short', day: 'numeric' }).format(new Date(at)) });
    else if (hour % step === 0) ticks.push({ at, day: false, label: new Intl.DateTimeFormat(lang(), { hour: 'numeric' }).format(new Date(at)) });
  }
  const x = (at) => Math.max(0, Math.min(100, ((at - from) / span) * 100));
  return { from, to, now, ticks, x };
}

// The moments a board's bars need on the axis: each dated landing's likely and worst, and each start drawn.
export function axisPoints(board) {
  const points = [];
  for (const one of [...(board?.tasks || []), ...(board?.goals || [])]) {
    if (!dated(one.forecast)) continue;
    points.push(ms(one.forecast.likely), ms(one.forecast.worst));
    if (one.startedAt) points.push(ms(one.startedAt));
  }
  return points.filter((at) => at !== null);
}
