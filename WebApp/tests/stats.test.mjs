// The Statistics page's parts that need no page (views/stats.js): its ranges, its address, its bars. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { RANGES, rangeOf, statsHref, percent } from '../js/views/stats.js';
import { parseRoute } from '../js/ui.js';

test('the ranges are the Mac’s, 7 days unless the address says another', () => {
  assert.deepEqual(RANGES.map((range) => range.label), ['Today', '7 days', '30 days']);
  assert.equal(rangeOf('month'), 'month');
  assert.equal(rangeOf(null), 'week');
  assert.equal(rangeOf('year'), 'week');
  assert.equal(statsHref('week'), '#/stats');
  assert.equal(statsHref('today'), '#/stats/today');
  assert.deepEqual(parseRoute('#/stats/month'), { name: 'stats', id: 'month' });
  assert.deepEqual(parseRoute('#/stats'), { name: 'stats', id: null });
});

test('a bar’s per mille is a width the style takes, kept between 0 and 100%', () => {
  assert.equal(percent(423), '42.3%');
  assert.equal(percent(1700), '100%');
  assert.equal(percent(-5), '0%');
  assert.equal(percent(null), '0%');
});
