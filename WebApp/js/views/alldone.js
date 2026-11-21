// The all-done card (the app's `AllDoneCard`): where a lead's board cleared, "All tasks finished", the batch's summary
// (a headline and bullets), what it cost, and its tasks folded, each with how it ended. The board shows its newest
// (views/board.js), the lead's chat each one in its place (views/chat.js). Drawn from the node's value: nothing asked.

import { h } from '../dom.js';
import { allDoneCard, since } from '../words.js';

export function allDoneView(mark, { className = 'board-group all-done' } = {}) {
  const card = allDoneCard(mark);
  return h('section', { class: className, 'aria-label': 'All tasks finished' },
    h('h2', { class: 'section-title board-group-head' }, h('span', null, 'All tasks finished'),
      mark.at ? h('time', { class: 'board-task-when', data: { since: mark.at } }, since(mark.at)) : null),
    card.headline ? h('p', { class: 'all-done-headline' }, card.headline) : h('p', { class: 'node-says' }, 'Writing a short summary of what was done…'),
    card.bullets.length ? h('ul', { class: 'all-done-bullets' }, card.bullets.map((bullet) => h('li', null, bullet))) : null,
    card.cost ? h('p', { class: 'all-done-cost', title: card.costNote || '' }, card.cost) : null,
    h('details', { class: 'all-done-tasks' }, h('summary', null, card.count),
      h('ul', null, card.tasks.map((task) => h('li', { class: task.merged ? 'merged' : '' }, `${task.title} (${task.word})`)))));
}
