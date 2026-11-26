// The all-done card (the app's `AllDoneCard`): where a lead's board cleared, t('adAllTasksFinished'), the batch's summary
// (a headline and bullets), what it cost, and its tasks folded, each with how it ended. The board shows its newest
// (views/board.js), the lead's chat each one in its place (views/chat.js). Drawn from the node's value: nothing asked.

import * as kit from '../kit.js';
import { h } from '../dom.js';
import { allDoneCard, since } from '../words.js';
import { t } from '../i18n.js';

export function allDoneView(mark, { className = 'board-group all-done' } = {}) {
  const card = allDoneCard(mark);
  return h('section', { class: className, 'aria-label': t('adAllTasksFinished') },
    kit.sectionTitle('h2', { class: 'board-group-head' }, h('span', null, t('adAllTasksFinished')),
      mark.at ? h('time', { class: 'board-task-when', data: { since: mark.at } }, since(mark.at)) : null),
    card.headline ? h('p', { class: 'all-done-headline' }, card.headline) : h('p', { class: 'node-says' }, t('adWritingAShortSummaryOf')),
    card.bullets.length ? h('ul', { class: 'all-done-bullets' }, card.bullets.map((bullet) => h('li', null, bullet))) : null,
    card.cost ? h('p', { class: 'all-done-cost', title: card.costNote || '' }, card.cost) : null,
    h('details', { class: 'all-done-tasks' }, h('summary', null, card.count),
      h('ul', null, card.tasks.map((task) => h('li', { class: task.merged ? 'merged' : '' }, `${task.title} (${task.word})`)))));
}
