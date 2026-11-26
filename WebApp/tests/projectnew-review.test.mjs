// The security review of `project.new` (review-v2-s-new, 2026-11-26; untracked, the reviewer's copy only): the node's
// sentence, the name and a lead's refusal are shown as text, never markup; a refusal whose sentence names a path or a
// command line outside the projects folder is said in the page's own words.
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom, find } from './fakedom.test.mjs';

installDom();
const { setLanguage, t } = await import('../js/i18n.js');
const { createStore } = await import('../js/store.js');
const { newProjectForm } = await import('../js/views/drive.js');

const flush = () => new Promise((resolve) => setImmediate(resolve));
function rig() {
  const store = createStore({ later: () => () => {} });
  let answer = null;
  store.connect({ request() { return new Promise((resolve) => { answer = resolve; }); }, subscribeChat() {}, unsubscribeChat() {}, resync() {} });
  store.setKinds(['project.new', 'lead'], null, ['read', 'draft', 'watch', 'act']);
  store.reconcile('sessions', []);
  store.reconcile('leads', []);
  const app = { store, ui: { state: { route: { name: 'new' } }, go() {}, subscribe() {} }, later: () => () => {} };
  return { app, answer: (reply) => answer(reply) };
}
const field = (el, label) => find(el, (node) => node.tag === 'input' && node.attrs['aria-label'] === label);
const primary = (el) => find(el, (node) => node.tag === 'button' && node.classList.contains('start-button'));
const MARKUP = '<img src=x onerror=alert(1)><script>alert(2)</script>';

// A name can't hold a slash (the node and the page refuse it): its markup has none.
const NAME_MARKUP = '<img src=x onerror=alert(1)>';
async function send(result, name = 'Shop' + NAME_MARKUP) {
  setLanguage('en');
  const r = rig();
  const form = newProjectForm(r.app);
  const one = field(form.el, t('drProjectName'));
  one.value = name;
  one.dispatch('input');
  primary(form.el).click();
  r.answer({ ok: true, result });
  await flush();
  await flush();
  return form.el;
}

const noMarkup = (el) => assert.equal(find(el, (node) => node.tag === 'img' || node.tag === 'script'), null, 'no element made from a string');

test('review: a node sentence with markup (an unknown refusal) is shown as its text', async () => {
  const el = await send({ made: false, name: null, folder: null, commit: null, lead: null, session: null, refused: 'failed', said: MARKUP, notes: [] });
  noMarkup(el);
  assert.ok(el.shownText.includes(MARKUP), el.shownText);
});

test('review: a repository refusal naming a path outside and a git command line is said in the page words, not the node sentence', async () => {
  const said = "git couldn't say ~/dev is in no repository (fatal: detected dubious ownership in repository at '/Users/other/secret'\nTo add an exception for this directory, call:\n\n\tgit config --global --add safe.directory /Users/other/secret): nothing was made.";
  const el = await send({ made: false, name: null, folder: null, commit: null, lead: null, session: null, refused: 'repository', said, notes: [] });
  assert.ok(!el.shownText.includes('/Users/other/secret'), el.shownText);
  assert.ok(!el.shownText.includes('git config'), el.shownText);
});

test('review: a made project whose name and lead refusal hold markup shows them as text', async () => {
  const el = await send({ made: true, name: 'Shop' + MARKUP, folder: '/home/u/dev/shop' + MARKUP, commit: 'a'.repeat(40), lead: 'refused', session: null,
    refused: null, said: 'x', notes: [MARKUP] });
  noMarkup(el);
  assert.ok(el.shownText.includes(MARKUP), el.shownText);
});
