// The node's settings on the page (views/settings.js's data, the `settings` kind): the node's own vector read in its
// shape and grouped as the page shows it, the line a change drafts quoted as the shell needs (the page never sets a
// setting: `set` is the user's voice, in a terminal), what a draft is checked against, the routes, and the mock's answer
// in the node's shape. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validate } from '../wire/validators.js';
import { settingSections, setLine, draftProblem, shownValue, usageFacts, settingMatches } from '../js/settings.js';
import { parseRoute } from '../js/ui.js';
import { settingsHref } from '../js/views/settings.js';
import { createMock } from '../js/mock.js';

const vectors = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'wire', 'vectors.json'), 'utf8'));
const [asked, answered] = structuredClone(vectors.settings);

test('the node’s settings vector is a read the page may ask, in its shape', () => {
  assert.equal(asked.kind, 'settings');
  assert.equal(validate('request', asked), null);
  assert.equal(validate('settings.args', asked.args), null);
  assert.equal(validate('reply.settings', answered), null);
  assert.ok(vectors['hello.web'].kinds.includes('settings'));
  assert.ok(!vectors['hello.web'].kinds.includes('set'), 'a page is never the user’s voice');
  assert.equal(vectors['set.from-a-page'].error.code, 'voice');
});

test('the settings are grouped by their sections, in the node’s order', () => {
  const sections = settingSections(answered.result.node.settings);
  assert.deepEqual(sections.map((section) => section.title), ['Machine-wide limits', 'Usage limits', 'Boost', 'Leads', 'Working policy']);
  assert.deepEqual(settingSections(answered.result.project.settings).map((section) => section.title), ['Models', 'Team', 'Review rules floor']);
  assert.deepEqual(settingSections([]), []);
});

test('a change is drafted as the line that sets it, every word quoted as the shell needs', () => {
  const node = answered.result.node.settings;
  const project = answered.result.project.settings;
  const at = (list, key) => list.find((setting) => setting.key === key);
  assert.equal(setLine(at(node, 'mac_max_sessions'), '8'), 'vibeswitcher set mac_max_sessions 8');
  // A node's setting names no folder, even if one is given.
  assert.equal(setLine(at(node, 'boost'), 'on', '/home/u/acme-site'), 'vibeswitcher set boost on');
  assert.equal(setLine(at(project, 'max_workers'), '5', '/home/u/acme site'), "vibeswitcher set '/home/u/acme site' max_workers 5");
  assert.equal(setLine({ key: 'floor_strict_paths', scope: 'project', form: 'paths' }, 'Sources/Auth/, docs/', '/r'), "vibeswitcher set /r floor_strict_paths 'Sources/Auth/, docs/'");
  // What was typed never becomes another command once pasted.
  assert.equal(setLine(at(node, 'policy'), "- Don't $(rm -rf ~).\n- Two."), "vibeswitcher set policy '- Don'\\''t $(rm -rf ~).\n- Two.'");
  assert.equal(setLine(at(project, 'lead_model'), 'default', '/r'), 'vibeswitcher set /r lead_model default');
});

test('a draft is checked against its form before a line is shown', () => {
  const node = answered.result.node.settings;
  const at = (key) => node.find((setting) => setting.key === key);
  assert.equal(draftProblem(at('mac_max_sessions'), '8'), null);
  assert.match(draftProblem(at('mac_max_sessions'), 'lots'), /whole number/);
  assert.equal(draftProblem(at('mac_max_sessions'), 'default'), null);
  assert.equal(draftProblem(at('boost'), 'automatic'), null);
  assert.match(draftProblem(at('boost'), 'turbo'), /one of off, on, automatic/);
  assert.equal(draftProblem(at('lead_mail'), 'off'), null);
  assert.match(draftProblem(at('policy'), '  '), /some text/);
  assert.equal(shownValue(at('policy')), '- Ship small. (and 1 more line)');
});

test('Settings has its routes: the node’s, and a project’s by its id', () => {
  assert.deepEqual(parseRoute('#/settings'), { name: 'settings', id: null });
  const project = answered.result.project.project;
  assert.deepEqual(parseRoute(settingsHref(project)), { name: 'settings', id: project });
  assert.equal(settingsHref(null), '#/settings');
  assert.deepEqual(parseRoute('#/node'), { name: 'node' });
});

test('the mock answers settings in the node’s shape, a folder with no lead gone', async () => {
  const mock = createMock({ apply() {}, setConnection() {}, chatSnapshot() {} }, { still: true });
  const node = await mock.request({ v: 1, id: '1', kind: 'settings', args: {} });
  assert.equal(validate('settings.result', node.result), null);
  assert.equal(node.result.project, null);
  const site = node.result.node.settings.length && await mock.request({ v: 1, id: '2', kind: 'settings', args: { folder: '/home/dev/projects/example-site' } });
  assert.equal(validate('settings.result', site.result), null);
  assert.ok(site.result.project.settings.some((setting) => setting.guardRail));
  const gone = await mock.request({ v: 1, id: '3', kind: 'settings', args: { folder: '/elsewhere' } });
  assert.equal(gone.error.code, 'gone');
  mock.stop();
});

test('the account’s usage is shown from the node’s value: each limit, the ones that hold work back, Fable held back', () => {
  assert.equal(usageFacts(null), null, 'nothing before the node has read it');
  const usage = answered.result.usage;
  assert.equal(validate('node.usage', usage), null);
  const facts = usageFacts(usage, (iso) => iso.slice(0, 10));
  assert.equal(facts.account, usage.account);
  assert.deepEqual(facts.limits.map((limit) => limit.title), usage.limits.map((limit) => limit.label.charAt(0).toUpperCase() + limit.label.slice(1) + (limit.model ? '' : ' (every model)')));
  const weekly = facts.limits.find((limit) => limit.title.startsWith('The weekly limit'));
  assert.equal(weekly.value, '84% used, resets 2026-11-19');
  assert.equal(weekly.holds, true);
  assert.equal(facts.limits.find((limit) => limit.title.startsWith('The 5-hour')).holds, false);
  assert.equal(facts.limits.find((limit) => limit.title.startsWith('The fable')).value.startsWith('reached'), true);
  assert.ok(facts.notes.some((note) => note.startsWith('Fable held back until 2026-11-18')));
  assert.ok(facts.notes.some((note) => note.startsWith('At 80% of a limit')));
  const ignored = usageFacts({ ...usage, ignored: true, fableHeldBack: null, limits: [] });
  assert.deepEqual(ignored.limits, []);
  assert.deepEqual(ignored.notes, ['Ignore usage limits is on: only a limit Claude refused a request at holds work back.']);
});

test('the settings search keeps those holding every word, in their key, title, description or section', () => {
  const all = [...answered.result.node.settings, ...answered.result.project.settings];
  assert.ok(all.every((setting) => settingMatches(setting, '')), 'no query keeps every one');
  const usage = all.filter((setting) => settingMatches(setting, 'usage LIMITS'));
  assert.ok(usage.length > 0 && usage.every((setting) => /usage/i.test(setting.title + setting.about + setting.section)), JSON.stringify(usage.map((s) => s.key)));
  assert.deepEqual(all.filter((setting) => settingMatches(setting, 'max_workers')).map((setting) => setting.key), ['max_workers']);
  assert.equal(all.filter((setting) => settingMatches(setting, 'nothing-like-this')).length, 0);
});
