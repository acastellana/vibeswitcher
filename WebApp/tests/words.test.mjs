// The page's words (the UX review of 2026-11-25, U11, U17, U18, U19): one name for each thing in English and in
// Spanish, Spanish that contracts "a el" and "de el" however a sentence is built, the left column's places in words,
// and a way forward from a project that is gone. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom } from './fakedom.mjs';

installDom();
const { TABLES, t, setLanguage } = await import('../js/i18n.js');

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
