// The page's words (the UX review of 2026-11-25, U11, U17, U18, U19): one name for each thing in English and in
// Spanish, Spanish that contracts "a el" and "de el" however a sentence is built, the left column's places in words,
// and a way forward from a project that is gone. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom } from './fakedom.test.mjs';

installDom();
const { TABLES, t, tParts, setLanguage } = await import('../js/i18n.js');

const text = (word) => (typeof word === 'string' ? word : Object.values(word).join(' | '));
const holding = (table, pattern) => Object.entries(table).filter(([, word]) => pattern.test(text(word))).map(([key]) => key);

test('U11: one name for each thing, the same in every place, English and Spanish', () => {
  for (const code of ['en', 'es']) {
    setLanguage(code);
    // The numbers: Statistics, on the project's tab as on their page (the Scorecard is a section of it).
    assert.equal(t('tabStats'), t('stats'), code);
    // The merged tasks: the lead's session's strip counts them as the project's does.
    assert.equal(t('wCountDone', { n: 2 }), t('merged', { n: 2 }), code);
    // What waits on the user: "needs you", on the dial as in the header, the left column and a session's state.
    assert.equal(t('dialAsks'), t('wNeedsYou'), code);
    assert.equal(t('emptyAsks'), t('brNothingWaitsOnYou'), code);
    assert.equal(t('brNothingWaitsOnYou'), t('nothingNeedsYou') + '.', code);
  }
  setLanguage('en');
  assert.deepEqual(holding(TABLES.en, /\bboards?\b/i), [], 'the board is the Team');
  // (A task still "waits on you" or on the lead, as it waits on other tasks: that is the task's word, not the place's.)
  for (const key of ['dialAsks', 'emptyAsks', 'nextWaiting', 'brNothingWaitsOnYou', 'brWaits']) {
    assert.doesNotMatch(text(TABLES.en[key]), /wait/i, key);
    assert.doesNotMatch(text(TABLES.es[key]), /espera/i, key);
  }
  assert.deepEqual(holding(TABLES.en, /\bStats\b/), []);
  assert.equal(TABLES.en.leBoard, 'Open the project');
  // Spanish: no retired word in any key's text.
  assert.deepEqual(holding(TABLES.es, /\btableros?\b/i), [], 'Equipo, never Tablero');
  assert.deepEqual(holding(TABLES.es, /\bcifras\b/i), [], 'Estadísticas, and Marcador for its section');
  assert.deepEqual(holding(TABLES.es, /lo que me espera|\ben reposo\b|\bhechas\b(?! hoy)/i), []);
  assert.equal(TABLES.es.leBoard, 'Abrir el proyecto');
  assert.equal(TABLES.es.rcScorecard, 'Marcador');
  // The node's notices are Avisos; this browser's notifications are Notificaciones, never avisos.
  assert.equal(TABLES.es.noNotices, 'Avisos');
  assert.equal(TABLES.es.ntNotifications, TABLES.es.noNotifications);
  const notifications = Object.keys(TABLES.en).filter((key) => /notif/i.test(TABLES.en[key]));
  assert.ok(notifications.length >= 10, notifications.join(' '));
  assert.deepEqual(notifications.filter((key) => /\bavis(o|os|a|ar)\b/i.test(text(TABLES.es[key]))), []);
  // The inspector's Overview isn't Brief me's Resumen.
  assert.notEqual(TABLES.es.inOverview, 'Resumen');
  assert.match(TABLES.es.apTeamOverviewAndActivity, new RegExp(TABLES.es.inOverview));
});

test('U11: a session’s state words agree with “sesión” in Spanish', () => {
  for (const key of ['wDone', 'wIdle', 'wEnded', 'wUnknown', 'wDoneOne', 'wIdleOne', 'wEndedOne']) assert.match(TABLES.es[key], /a$/, key);
});

test('U18: Spanish contracts “a el” and “de el” wherever a sentence is built, from any of its words and values', async () => {
  setLanguage('es');
  // The roadmap's undated task, as the review saw it: “sin fecha: espera a el líder”.
  const vectors = JSON.parse((await import('node:fs')).readFileSync(new URL('../wire/vectors.json', import.meta.url), 'utf8'));
  const board = structuredClone(vectors.board[1].result.boards[0]);
  const { landingWords } = await import('../js/forecast.js');
  const pricing = board.tasks.find((task) => task.slug === 'pricing-copy');
  assert.equal(landingWords(pricing.forecast, Date.parse('2026-11-25T12:00:00Z'), { task: pricing, board }).date, 'sin fecha: espera al líder');
  assert.equal(landingWords({ basis: 'blocked', waitsOn: 'the lead (it failed)' }, Date.now(), { task: {}, board }).date, 'sin fecha: espera al líder (falló)');
  assert.equal(t('chSteerShort', { agent: t('drTheAgentLow') }), 'Guía al agente…');
  assert.equal(t('chSteerShort', { agent: 'Claude' }), 'Guía a Claude…');
  assert.equal(t('mlFromLead', { other: 'el sitio' }), 'del líder del sitio');
  // Every word with a blank, filled with every Spanish value that starts with “el ”: never “a el” or “de el”, by t and
  // by tParts alike.
  const els = [...new Set(Object.values(TABLES.es).flatMap((word) => (typeof word === 'string' ? [word] : Object.values(word))).filter((word) => /^el /.test(word)))];
  assert.ok(els.includes('el líder') && els.includes('el agente'), els.join(' | '));
  let checked = 0;
  for (const [key, word] of Object.entries(TABLES.es)) {
    const names = [...new Set([...text(word).matchAll(/\{(\w+)\}/g)].map((found) => found[1]))];
    for (const value of names.length ? els : []) {
      const values = Object.fromEntries(names.map((name) => [name, name === 'n' ? 2 : value]));
      for (const said of [t(key, values), tParts(key, values).join('')]) {
        assert.doesNotMatch(said, /(?<!\p{L})(a|de) el(?!\p{L})/iu, `${key}: ${said}`);
        checked += 1;
      }
    }
  }
  assert.ok(checked > 200, String(checked));
  // A name's capital “El” isn't contracted; nor is anything in English.
  assert.equal(t('toLead', { p: 'El Prat' }), 'Al líder de El Prat');
  setLanguage('en');
  assert.equal(t('chSteerShort', { agent: 'el agente' }), 'Steer el agente…');
});

test('U17: the left column’s places say what they count, in words: what needs you, else how many; the node’s notices', async () => {
  const { leftColumn } = await import('../js/views/left.js');
  const { find, byClass } = await import('./fakedom.test.mjs');
  const app = (sessions, notices) => ({
    store: { state: { node: { notices, web: null }, connection: 'live', phrase: null, sessions: new Map(sessions.map((one) => [one.id, one])), leads: new Map(), boards: new Map(), cards: new Map() },
      acts: () => false, can: () => true },
    ui: { state: { route: { name: 'home' } } },
  });
  const own = (status, i) => ({ id: `local:own${i}`, role: null, status, cwd: '/home/dev' });
  const place = (left, key) => find(left.el, (node) => node.dataset?.place === key);
  const shown = (el) => (el.hidden ? '' : el.textContent);
  for (const [code, needs, notice, notices] of [['en', '1 needs you', '1 notice', '2 notices'], ['es', '1 te necesita', '1 aviso', '2 avisos']]) {
    setLanguage(code);
    const left = leftColumn(app([own('needs-you', 0), ...[1, 2, 3, 4].map((i) => own('idle', i))], ['example-site: landing-base moved']), { brief() {} });
    left.render();
    const sessions = place(left, 'ownSessions');
    assert.equal(shown(find(sessions, byClass('place-waiting'))), needs, 'what needs you, in words');
    assert.equal(shown(find(sessions, byClass('place-count'))), '', 'never two numbers side by side');
    assert.ok(sessions.classList.contains('asked'));
    assert.equal(shown(find(place(left, 'thisNode'), byClass('place-count'))), notice);
    const calm = leftColumn(app([1, 2, 3, 4, 5].map((i) => own('idle', i)), ['a', 'b']), { brief() {} });
    calm.render();
    assert.equal(shown(find(place(calm, 'ownSessions'), byClass('place-count'))), '5', 'nothing waits: how many are yours');
    assert.equal(shown(find(place(calm, 'ownSessions'), byClass('place-waiting'))), '');
    assert.equal(shown(find(place(calm, 'thisNode'), byClass('place-count'))), notices);
    const none = leftColumn(app([], []), { brief() {} });
    none.render();
    assert.equal(shown(find(place(none, 'thisNode'), byClass('place-count'))), '');
  }
  setLanguage('en');
});

test('U19: a project that is gone says so and offers the start page, as a gone session does', async () => {
  const { projectView } = await import('../js/views/project.js');
  const { find, findAll } = await import('./fakedom.test.mjs');
  for (const [code, title, button] of [['en', 'This project isn’t on this node', 'Start Page'], ['es', 'Este proyecto no está en este nodo', 'Página de inicio']]) {
    setLanguage(code);
    const state = { node: null, connection: 'live', phrase: null, pageWords: null, sessions: new Map(), leads: new Map(), boards: new Map(), cards: new Map(),
      cardKeys: new Map(), acting: new Map(), draftRefused: new Map() };
    const app = { store: { state, acts: () => false, can: () => true, subscribe() {}, request: () => Promise.resolve({ ok: true }), read: () => Promise.resolve({ ok: false }), cardKey: (id) => id, draftOf: () => null },
      ui: { state: { route: { name: 'project', id: 'local:project:gone', view: 'lead' } }, subscribe() {}, go() {} } };
    const view = projectView(app, { sheet: { open() {}, close() {} } });
    view.render();
    const gone = find(view.el, (node) => node.classList?.contains('empty-state') && !node.hidden);
    assert.ok(gone, 'the gone page shows');
    assert.match(gone.textContent, new RegExp(title));
    const links = findAll(gone, (node) => node.tag === 'a');
    assert.deepEqual(links.map((link) => [link.textContent, link.getAttribute('href')]), [[button, '#/']]);
  }
  setLanguage('en');
});

test('the page leaves no English of its own in Spanish: the folder field’s placeholder is a word of the table', async () => {
  const { readFileSync } = await import('node:fs');
  const drive = readFileSync(new URL('../js/views/drive.js', import.meta.url), 'utf8');
  assert.doesNotMatch(drive, /placeholder: '\//, 'no placeholder written in the view');
  // A folder as the forms show it, ~/… (D12).
  assert.equal(TABLES.es.drPathPlaceholder, '~/proyectos/mi-app');
  assert.equal(TABLES.en.drPathPlaceholder, '~/projects/my-app');
});
