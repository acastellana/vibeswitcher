// Check for Updates as This node shows it (the `node` value's `update`, the server's `UpdateWatch.value`): up to date as
// of the last look, a newer build with its install and switch lines, or why the node couldn't look; and always the line
// that looks now (`vibeswitcher status --check-updates`, the user's in a terminal: a page asks GitHub nothing). The
// parts with no page in them, so the tests can read them.
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
    state = t('upNewer', { commit: update.commit.slice(0, 12) }) + ahead;
    if (update.install) lines.push({ label: t('upTheCommandThatInstallsIt'), text: update.install });
    lines.push({ label: t('upThenTheCommandThatSwitches'), text: `vibeswitcher switch ${update.commit}` });
  } else if (update.checkedAt) {
    tone = 'done';
    state = t('upUpToDateNoNewer');
  } else {
    state = update.problem ? t('upNotCheckedYetTheLast') : t('upNotCheckedYet');
  }
  lines.push({ label: t('upTheCommandThatChecksNow'), text: checkNowLine });
  return { tone, state, checkedAt: update.checkedAt || null, problem: update.problem || null, lines };
}
