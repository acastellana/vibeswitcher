// The node's settings as the page reads them (the `settings` kind's result: the node's own and a project's, each with
// its value, its default, where it lives and whether it is a guard rail). The page never sets one: a change is drafted
// as the line that sets it in a terminal (`vibeswitcher set [FOLDER] KEY VALUE`), where the typed code is asked. These
// are the parts with no page in them, so the tests can read them.

import { shellWord } from './views/drive.js';

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
    case 'flag': return ['on', 'off'].includes(text) ? null : 'on or off';
    case 'choice': return setting.choices.includes(text) ? null : `one of ${setting.choices.join(', ')}`;
    case 'count': return /^\d+$/.test(text.trim()) ? null : `a whole number${setting.limits ? ` (${setting.limits})` : ''}`;
    case 'number': return Number(text) > 0 ? null : `a number${setting.limits ? ` (${setting.limits})` : ''}`;
    case 'model': return /^[A-Za-z0-9.\-_[\]:]{1,100}$/.test(text.trim()) ? null : 'one word, a model’s name as claude --model takes it';
    case 'paths': return text.includes('\n') ? 'one line' : null;
    case 'text': return text.trim() ? null : 'some text (or default)';
    default: return null;
  }
}

// A value as a row shows it: on one line, a long text by its first line and how many more.
export function shownValue(setting) {
  const value = setting.value ?? '';
  if (setting.form !== 'text') return value;
  const lines = value.split('\n');
  return lines.length > 1 ? `${lines[0]} (and ${lines.length - 1} more line${lines.length === 2 ? '' : 's'})` : value;
}
