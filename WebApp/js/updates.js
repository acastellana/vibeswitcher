// Check for Updates as This node shows it (the `node` value's `update`, the server's `UpdateWatch.value`): up to date as
// of the last look, a newer build with its install and switch lines, or why the node couldn't look; and the line that
// looks now (`vibeswitcher status --check-updates`), or where the page acts and the node lists `update.check`, Check now
// (views/node.js). The parts with no page in them, so the tests can read them.
import { t } from './i18n.js';


export const checkNowLine = 'vibeswitcher status --check-updates';

// { tone ('done' | 'needs-you' | 'unknown'), state (the words), lines ([{ label, text }]: lines to copy), problem }, or
// null when the node keeps no update check (a scratch node's).
export function updateFacts(update) {
  if (!update) return null;
  const lines = [];
  let tone = 'unknown', state;
  if (update.commit) {
    tone = 'needs-you';
    const ahead = update.aheadBy != null ? t('upAhead', { n: update.aheadBy }) : '';
    state = t('upNewer', { commit: update.commit.slice(0, 7) }) + ahead;
    if (update.install) lines.push({ label: t('upTheCommandThatInstallsIt'), text: update.install });
    lines.push({ label: t('upThenTheCommandThatSwitches'), text: `vibeswitcher switch ${update.commit}` });
  } else if (update.checkedAt) {
    tone = 'done';
    state = t('upUpToDateNoNewer');
  } else {
    state = update.problem ? t('upNotCheckedYetTheLast') : t('upNotCheckedYet');
  }
  lines.push({ label: t('upTheCommandThatChecksNow'), text: checkNowLine, checks: true });
  return { tone, state, checkedAt: update.checkedAt || null, problem: update.problem || null, lines };
}

// What a look now found (`update.check`'s reply, the watch's record), in words: a newer build, up to date, or why it
// couldn't look.
export function checkedWords(result = {}) {
  if (result.commit) return t('upCheckedNewer', { commit: String(result.commit).slice(0, 7) }) + (result.aheadBy != null ? t('upAhead', { n: result.aheadBy }) : '');
  if (result.problem) return t('upCheckedProblem', { why: result.problem });
  if (result.checkedAt) return t('upCheckedCurrent');
  return t('upCheckedNothing');
}
