// A held-config card in plain words (the Mac app's economy): what changed as one title, what it holds back, the guard
// rails that changed (only those), and whether the page can accept it or it is the terminal's. From the node's own
// classification of each held item where it gives one (`item.what`: {label, from, to}) and each rail's state (`rail.state`,
// `rail.before`); until it does, from the item's name and the rail's `sinceAccept` words. No hash, no seal, no vault.

import { t } from './i18n.js';

// What a held item is, in a few words: the node's own label where it has one, else read off its name.
export function itemLabel(item) {
  const what = item?.what;
  // The node's own phrase (`what`, inert already); its versions where it gives them and the phrase doesn't say them.
  if (typeof what === 'string' && what) return item.from && item.to && !what.includes(item.to) ? `${what} (${item.from} → ${item.to})` : what;
  if (what?.label) return what.from && what.to ? `${what.label} (${what.from} → ${what.to})` : what.label;
  const name = String(item?.name || '');
  const plain = name.replace(/ \(main checkout\)/, '');
  if (/^plugin /.test(name)) return t('hcPlugin', { name: plain.slice('plugin '.length).split('@')[0] });
  if (/^~\/\.vibeswitcher\/bin\b/.test(name)) return t('hcBuild');
  if (/^\.git\/config/.test(name)) return t('hcGitConfig');
  if (/^\.git\/hooks/.test(name)) return t('hcGitHooks');
  if (/'s scripts$/.test(name)) return t('hcScripts');
  if (/^~\/\.claude\.json$/.test(name)) return t('hcMcp');
  if (/\.claude\/settings(\.local)?\.json$/.test(plain) || /^\.mcp\.json$/.test(plain)) return t('hcClaudeSettings');
  if (/^~\/\.claude\/(skills|agents|commands|hooks|output-styles)$/.test(name)) return t('hcClaudeFolder', { folder: name.split('/').pop() });
  if (/^~\/\.codex\//.test(name)) return t('hcCodex');
  if (/(CLAUDE(\.local)?|AGENTS)\.md$/.test(plain)) return t('hcInstructions', { file: plain.split('/').pop() });
  if (/^~\/\.(zshenv|zprofile|zshrc|zlogin|zlogout|bashrc|bash_profile|bash_login|profile)$/.test(name)) return t('hcShell', { file: name.slice(2) });
  if (/^~\/\.(gitconfig|config\/git\/config)$/.test(name)) return t('hcGitGlobal');
  const slash = plain.lastIndexOf('/');
  return slash > 0 ? t('hcFiles', { folder: plain.slice(0, slash) }) : t('hcChanged', { name: plain });
}

// What a held item is, as a short noun for a list ("your shell's startup file (.bashrc)"): the node's own where it
// has one, else read off its name.
export function itemShort(item) {
  const what = item?.what;
  if (typeof what === 'string' && what) return what;
  if (what?.short) return what.short;
  const name = String(item?.name || '');
  const plain = name.replace(/ \(main checkout\)/, '');
  if (/^plugin /.test(name)) return t('hsPlugin', { name: plain.slice('plugin '.length).split('@')[0] });
  if (/^~\/\.vibeswitcher\/bin\b/.test(name)) return t('hsBuild');
  if (/^\.git\/config/.test(name)) return t('hsGitConfig');
  if (/^\.git\/hooks/.test(name)) return t('hsGitHooks');
  if (/'s scripts$/.test(name)) return t('hsScripts');
  if (/^~\/\.claude\.json$/.test(name)) return t('hsMcp');
  if (/\.claude\/settings(\.local)?\.json$/.test(plain) || /^\.mcp\.json$/.test(plain)) return t('hsClaudeSettings');
  if (/^~\/\.claude\/(skills|agents|commands|hooks|output-styles)$/.test(name)) return t('hsClaudeFolder', { folder: name.split('/').pop() });
  if (/^~\/\.codex\//.test(name)) return t('hsCodex');
  if (/(CLAUDE(\.local)?|AGENTS)\.md$/.test(plain)) return t('hsInstructions', { file: plain.split('/').pop() });
  if (/^~\/\.(zshenv|zprofile|zshrc|zlogin|zlogout|bashrc|bash_profile|bash_login|profile)$/.test(name)) return t('hsShell', { file: name.slice(2) });
  if (/^~\/\.(gitconfig|config\/git\/config)$/.test(name)) return t('hsGitGlobal');
  const slash = plain.lastIndexOf('/');
  return slash > 0 ? t('hsFiles', { folder: plain.slice(0, slash) }) : plain;
}

// The card's title and the line under it: one thing, its own words and no line; several, their count, and a line
// naming the first three ("and 4 more").
export function heldTitle(items = []) {
  if (!items.length) return { title: t('hcNothing'), line: null };
  if (items.length === 1) return { title: itemLabel(items[0]), line: null };
  const shorts = [...new Set(items.map(itemShort))];
  const named = shorts.slice(0, 3).join(', ');
  return { title: t('hcCount', { n: items.length }), line: shorts.length > 3 ? t('hcAndMore', { named, n: shorts.length - 3 }) : named };
}

// A rail against the last accept: 'same', 'changed' (with `before`), 'new', 'unknown' (can't be compared: the node
// restarted, or the snapshot was rewritten), or null (no accept to compare with).
export function railState(rail) {
  // The node's own reading (`changed`: changed | same | unknown, `old`; `records`: this accept records this value).
  if (rail?.changed === 'changed') return 'old' in rail ? { state: 'changed', before: rail.old } : { state: 'new', before: null };
  if (rail?.changed === 'same') return rail.records ? { state: 'records', before: null } : { state: 'same', before: null };
  if (rail?.changed === 'unknown') return rail.records ? { state: 'records', before: null } : { state: 'unknown', before: null };
  if (rail?.state) return { state: rail.state, before: rail.before ?? null };
  const said = String(rail?.sinceAccept || '');
  if (!said) return { state: null, before: null };
  // A bare word (an older node's, or a test's): its state as said.
  if (['same', 'changed', 'new'].includes(said)) return { state: said, before: null };
  if (/^the same as/.test(said)) return { state: 'same', before: null };
  if (/^changed since/.test(said)) return { state: 'changed', before: /from “([^”]*)”/.exec(said)?.[1] ?? null };
  if (/^not in your last accept/.test(said)) return { state: 'new', before: null };
  return { state: 'unknown', before: null };
}

// What the card's face says: its title, the rails that changed (key, before, now), how many can't be compared, and
// whether accepting is the terminal's (a rail changed, new or not comparable: the node refuses a page's accept then).
// The kinds the node reads as updates (named only while the card has room; the rest counted).
const UPDATES = ['claude-update', 'plugin-update', 'build-switch'];
const UNVOUCHED = /^(not known to be the same|can.t be compared)/;

// The held things as the node names them (its `kind` and `what`): every one that isn't an update, then updates while
// fewer than three lines are shown, the rest "and N more that look like updates"; one the node can't vouch for says so.
export function itemLines(items = []) {
  const named = (item) => itemLabel(item) + (UNVOUCHED.test(item.sinceAccept || '') ? ' ' + t('hcCantCompare') : '');
  const lines = items.filter((item) => !UPDATES.includes(item.kind)).map(named);
  const updates = items.filter((item) => UPDATES.includes(item.kind));
  let shown = 0;
  for (const item of updates) {
    if (lines.length >= 3) break;
    lines.push(named(item));
    shown += 1;
  }
  return { lines, moreUpdates: updates.length - shown };
}

export function heldSummary(config = {}) {
  const rails = (config.guarded || []).map((rail) => ({ ...rail, ...railState(rail) }));
  const changed = rails.filter((rail) => rail.state === 'changed' || rail.state === 'new' || rail.state === 'records');
  // The node's own reading (`changed` on each rule) never shows the ones it can't compare; an older node's, counted.
  const nodeReads = rails.some((rail) => 'changed' in rail);
  const unknown = nodeReads ? 0 : rails.filter((rail) => rail.state === 'unknown').length;
  const items = config.items || [];
  // Nothing held but rules that would change: the title says the rules changed, not "the agents' config".
  const { title, line } = !items.length && changed.length ? { title: t('hcRulesOnly'), line: null } : heldTitle(items);
  // With the node's kinds, the lines it names; without, the one line naming three.
  const kinds = items.some((item) => item.kind);
  const named = kinds ? itemLines(items) : null;
  // Nothing held and no sealed last accept (the node's `firstLook`: it restarted, or the rules were never accepted), or
  // from a node before that field, nothing held and no rule changed: it only wants this project's rules confirmed once.
  const confirmOnly = config.firstLook === true || (!items.length && !changed.length && unknown > 0);
  // A first accept (`recordsAll`): the rules set away from their defaults (sandbox_ first, eight shown), the rest counted.
  const set = config.recordsAll === true ? rails.filter((rail) => rail.atDefault === false).sort((a, b) => /^sandbox_/.test(b.key) - /^sandbox_/.test(a.key)) : [];
  const first = config.recordsAll === true ? { shown: set.slice(0, 8), more: Math.max(0, set.length - 8), defaults: rails.filter((rail) => rail.atDefault !== false).length } : null;
  // Whether a page may accept: the node's own judgement where it gives one, else read off the rules.
  const terminal = 'pageMayAccept' in config ? config.pageMayAccept !== true : (config.recordsAll === true || changed.length > 0 || unknown > 0);
  return { title, line: named ? null : line, lines: named?.lines || null, moreUpdates: named?.moreUpdates || 0, changed, unknown, rails, confirmOnly, first,
    summary: config.summary || null, holds: config.holds || null, holdsEvery: config.holdsEvery === true, terminal };
}
