// The ways a message goes into a session's agent (the node's `send` `when`, after what the agents themselves offer):
// at its next step (the default: read after the tool calls it runs, in the same turn), now (read immediately: what it
// runs goes to the background or stops), after this turn (Codex's queue; where the agent has one), or interrupt, then
// send (Esc, then the message as a new turn). The node lists a session's own (`sendWays`); without the list, step and
// now. What was actually done is the node's to say (`result.when`, `result.said`); the page never claims more.

import { t } from './i18n.js';

export const WAYS = ['step', 'now', 'after', 'interrupt'];

// The ways `session`'s agent takes, in the menu's order.
export function waysFor(session) {
  const listed = Array.isArray(session?.sendWays) ? session.sendWays.filter((way) => WAYS.includes(way)) : null;
  return listed?.length ? WAYS.filter((way) => listed.includes(way)) : ['step', 'now'];
}

// `send`'s arguments for `way` to `session` (its value). `when` goes only to a node that lists the session's ways (one
// before it refuses the field); `now` is said the old way too, which both take.
export function sendArgs(session, text, way, images = []) {
  const knowsWhen = Array.isArray(session?.sendWays);
  return { session: session?.id, text, ...(knowsWhen ? { when: way } : {}), ...(way === 'now' ? { now: true } : {}), ...(images.length ? { images } : {}) };
}

// A way's name in the menu, and its one line.
export const wayName = (way) => t({ step: 'swStep', now: 'swNow', after: 'swAfter', interrupt: 'swInterrupt' }[way]);
export const wayLine = (way) => t({ step: 'swStepLine', now: 'swNowLine', after: 'swAfterLine', interrupt: 'swInterruptLine' }[way]);

// What became of a message sent `way`, from the node's reply: its own words first, then what it did.
export function sentWords(way, result = {}) {
  if (result?.said) return result.said;
  if (result?.queued) return t('sayHeld', { why: result.waits || '' });
  const done = WAYS.includes(result?.when) ? result.when : result?.steered ? 'now' : way;
  if (done === 'now' && result?.steered === false && result?.working === false) return t('sayTyped');
  return t({ step: 'swSentStep', now: 'swSentNow', after: 'swSentAfter', interrupt: 'swSentInterrupt' }[done]);
}
