// The node's settings as the page reads them (the `settings` kind's result: the node's own and a project's, each with
// its value, its default, where it lives and whether it is a guard rail). The page never sets one: a change is drafted
// as the line that sets it in a terminal (`vibeswitcher set [FOLDER] KEY VALUE`), where the typed code is asked. These
// are the parts with no page in them, so the tests can read them.

import { shellWord } from './views/drive.js';
import { t, nodeWords } from './i18n.js';
import { dateTime } from './words.js';

// `settings` rows grouped as the page shows them: by section, in the node's order.
export function settingSections(settings) {
  const sections = [];
  for (const setting of settings || []) {
    const last = sections[sections.length - 1];
    if (last && last.title === setting.section) last.settings.push(setting);
    else sections.push({ title: setting.section, settings: [setting] });
  }
  return sections;
}

// The line that sets `setting` to `value` (`default` puts it back), for the project in `folder` when it is a project's.
// Every word quoted as the shell needs, so what was typed is never another command once pasted.
export function setLine(setting, value, folder) {
  const words = ['vibeswitcher', 'set'];
  if (setting.scope === 'project' && folder) words.push(shellWord(folder));
  words.push(setting.key, value === '' ? "''" : shellWord(value));
  return words.join(' ');
}

// What a value is checked against before a line is drafted: the node checks again, and the terminal shows it before the
// code. Null: it may be drafted; else why not.
export function draftProblem(setting, value) {
  const text = String(value ?? '');
  if (text.trim().toLowerCase() === 'default') return null;
  switch (setting.form) {
    case 'flag': return ['on', 'off'].includes(text) ? null : t('slOnOff');
    case 'choice': return setting.choices.includes(text) ? null : t('slOneOf', { list: setting.choices.join(', ') });
    case 'count': {
      const range = countRange(setting.limits);
      const whole = /^\d+$/.test(text.trim());
      if (range) return whole && Number(text) >= range.low && Number(text) <= range.high ? null : t('slWholeRange', range);
      return whole ? null : t('slWhole') + (setting.limits ? ` (${setting.limits})` : '');
    }
    case 'number': {
      const ceiling = numberCeiling(setting.limits);
      const number = /^\s*\d+(\.\d+)?\s*$/.test(text) ? Number(text) : NaN;
      if (number > 0 && (ceiling === null || number <= ceiling)) return null;
      return ceiling === null ? t('slNumber') + (setting.limits ? ` (${setting.limits})` : '') : t('slNumberAtMost', { high: ceiling });
    }
    case 'model': return /^[A-Za-z0-9.\-_[\]:]{1,100}$/.test(text.trim()) ? null : t('slOneWordAModelS');
    case 'paths': return text.includes('\n') ? t('slOneLine') : null;
    case 'text': return text.trim() ? null : t('slSomeTextOrDefault');
    case 'folder': return /^(\/|~$|~\/)/.test(text.trim()) && !text.includes('\n') ? null : t('slAFullPathOrOne');
    default: return null;
  }
}

// The node's limits as it words them (SettingsRequest: a count's "1 to 12", a number's "above 0, at most 48"), read
// back as numbers; null where it says none.
export function countRange(limits) {
  const found = /^(\d+) to (\d+)$/.exec(String(limits || '').trim());
  return found ? { low: Number(found[1]), high: Number(found[2]) } : null;
}
export function numberCeiling(limits) {
  const found = /at most (\d+(?:\.\d+)?)/.exec(String(limits || ''));
  return found ? Number(found[1]) : null;
}

// A value as a row shows it: on one line, a long text by its first line and how many more.
export function shownValue(setting) {
  const value = setting.value ?? '';
  if (setting.form !== 'text') return value;
  const lines = value.split('\n');
  return lines.length > 1 ? lines[0] + t('slMoreLines', { n: lines.length - 1 }) : value;
}

// The account's usage as the page shows it (the node's `usage`, `NodeUsage.value`): one line per limit still holding
// on the account Claude Code is logged in to, the most used first ("The weekly limit: 84% used, resets Nov 3, 01:00"),
// marked when it holds work back; and until when Fable is held back. Null while the node hasn't read it yet.
export function usageFacts(usage, when = (iso) => dateTime(iso)) {
  if (!usage) return null;
  const limits = (usage.limits || []).map((limit) => ({
    title: capital(nodeWords(limit.label)) + (limit.model ? '' : t('slEveryModel')),
    value: (limit.reached ? t('slReached') : t('slUsed', { n: limit.usedPercent })) + (limit.resetsAt ? t('slResets', { when: when(limit.resetsAt) }) : ''),
    holds: !!limit.holds,
    percent: limit.reached ? 100 : Math.max(0, Math.min(100, limit.usedPercent)),
  }));
  const notes = [];
  if (usage.ignored) notes.push(t('slIgnoreUsageLimitsIsOn'));
  else notes.push(t('slThreshold', { n: usage.threshold }));
  if (usage.fableHeldBack) notes.push(t('slFable', { when: when(usage.fableHeldBack) }));
  return { account: usage.account || null, limits, notes };
}

const capital = (text) => String(text || '').charAt(0).toUpperCase() + String(text || '').slice(1);

// The app's Settings search: whether every word of `query` is in the setting's key, title, description or section
// (case aside). An empty query keeps every setting.
export function settingMatches(setting, query) {
  const words = String(query || '').toLowerCase().split(/\s+/).filter(Boolean);
  const text = [setting.key, setting.title, setting.about, setting.section].join(' ').toLowerCase();
  return words.every((word) => text.includes(word));
}
