// Driving an ordinary session from the page (the parity table's gaps 1, 3 and 6): a message for it, its own question,
// starting one and ending one. No click is the user's voice (the plan's LW-D6): a message is left as a draft beside
// the session (`session.draft`), and everything else is the one line that does it in a terminal, a click to copy. The
// node shows that line's effect when it happens; the terminal asks for the typed code first.

import { h, setText, setClass } from '../dom.js';
import { icon } from '../marks.js';
import { AGENTS } from '../words.js';
import { copyLine } from './cards.js';

// A session as the command line names it: the first 8 characters of its host id (`vibeswitcher send` takes any prefix
// of 4 or more that only one session has).
export const sessionShort = (id) => String(id || '').replace(/^[^:]*:/, '').slice(0, 8);

// `text` as one shell word: as it is when it needs no quoting, else in single quotes, each ' written '\''. What the
// user typed never becomes a command that does something else when pasted.
export function shellWord(text) {
  const value = String(text);
  return /^[A-Za-z0-9._\/:@%+=,-]+$/.test(value) ? value : `'${value.replace(/'/g, `'\\''`)}'`;
}

// Whether the page may drive `session` at all: one the node's host started, still running.
export const drivable = (session) => !!session?.hosted && !session.ended;

// The message drafted for a session, over its composer: the text as it will be typed, the line that sends it, and
// Edit (back into the box) and Discard. Returns { el, update(session) }.
export function draftBox(app, { edit }) {
  const label = h('span', { class: 'confirm-label' });
  const text = h('p', { class: 'confirm-text' });
  const lineSlot = h('div');
  const refused = h('p', { class: 'card-notice', role: 'alert', hidden: true });
  let id = null;
  let drawn = '';
  const editButton = h('button', { class: 'confirm-clear', type: 'button', title: 'Put the message back in the box', onclick: () => {
    const drafted = app.store.sessionDraftOf(id);
    if (drafted) edit(drafted.text);
  } }, 'Edit');
  const discard = h('button', { class: 'confirm-clear', type: 'button', title: 'Take the draft off the session', onclick: () => app.store.sessionDraft(id, null) }, 'Discard');
  const note = h('p', { class: 'confirm-note' }, 'Run it in a terminal: it shows the message and asks for a code. Nothing is typed into the session before that.');
  const el = h('div', { class: 'confirm composer-draft', role: 'group', 'aria-label': 'Send your message from a terminal', hidden: true },
    h('div', { class: 'confirm-head' }, label, h('span', { class: 'confirm-actions' }, editButton, discard)), text, lineSlot, note, refused);

  return {
    el,
    update(session) {
      id = session?.id || null;
      const drafted = id ? app.store.sessionDraftOf(id) : null;
      const why = id ? app.store.state.sessionDraftRefused.get(id) : null;
      el.hidden = !drafted && !why;
      refused.hidden = !why;
      if (why) setText(refused, why);
      if (!drafted) return;
      setClass(el, 'sending', drafted.sending);
      setText(label, drafted.sending ? 'Saving your message…' : `Your message for ${AGENTS[session.agent] || 'the agent'}`);
      setText(text, drafted.text);
      const line = `vibeswitcher send ${sessionShort(id)}`;
      if (line !== drawn) {
        drawn = line;
        lineSlot.replaceChildren(copyLine(line, 'the command that sends it'));
      }
    },
  };
}

// The question open on a session's screen (a permission prompt, its own question, a plan to approve), as the node read
// it: the options numbered as the screen numbers them. A pick shows the line that answers it, `vibeswitcher reply`;
// an option that takes words opens a field, and the line carries them. Returns { el, update(session) }.
export function promptCard(app) {
  const el = h('article', { class: 'card ask session-prompt', tabindex: -1, hidden: true });
  let key = '';
  let chosen = null;
  let words = '';

  function draw(session) {
    const prompt = session.prompt;
    const agent = AGENTS[session.agent] || 'The agent';
    const takes = new Set(prompt.text || []);
    const short = sessionShort(session.id);
    const buttons = prompt.options.map((option, index) => h('button', {
      class: 'option' + (chosen === index ? ' chosen' : ''), type: 'button', 'aria-pressed': String(chosen === index),
      onclick: () => { chosen = index; draw(session); el.querySelector(takes.has(index) ? '.answer-input' : '.copy-button')?.focus(); },
    }, h('span', { class: 'option-key', 'aria-hidden': 'true' }, String(index + 1)), h('span', { class: 'option-text' }, option),
    prompt.descriptions?.[index] ? h('span', { class: 'option-note' }, prompt.descriptions[index]) : null));
    const parts = [
      h('header', { class: 'card-head' }, h('span', { class: 'priority blocking' }, `${agent} is asking`)),
      h('pre', { class: 'ask-text' }, prompt.question),
    ];
    if (prompt.multiSelect) {
      parts.push(h('ol', { class: 'options read-only' }, prompt.options.map((option) => h('li', { class: 'option' }, h('span', { class: 'option-text' }, option)))),
        h('p', { class: 'confirm-note' }, 'It takes several ticks: answer it in the session’s own terminal.'));
    } else {
      parts.push(h('div', { class: 'options' }, buttons));
      if (chosen !== null && takes.has(chosen)) {
        const input = h('input', { class: 'answer-input', type: 'text', value: words, placeholder: 'Your words', 'aria-label': 'Your words for this option',
          oninput: () => { words = input.value; line.replaceChildren(command()); } });
        parts.push(input);
      }
      const command = () => {
        if (chosen === null) return h('p', { class: 'confirm-note' }, 'Pick an answer: the line that gives it in a terminal shows here.');
        const typed = takes.has(chosen) && words.trim() ? ` ${shellWord(words.trim())}` : '';
        return copyLine(`vibeswitcher reply ${short} ${chosen + 1}${typed}`, 'the command that answers it');
      };
      const line = h('div', { class: 'prompt-line' }, command());
      parts.push(line, h('p', { class: 'confirm-note' }, 'Run it in a terminal: it shows this question and asks for a code, then answers it as you, only while this question is still on the screen.'));
    }
    el.replaceChildren(...parts);
  }

  return {
    el,
    update(session) {
      const prompt = drivable(session) ? session.prompt : null;
      el.hidden = !prompt;
      if (!prompt) { key = ''; return; }
      const now = JSON.stringify([session.id, prompt.question, prompt.options, prompt.at]);
      if (now === key) return;
      // Another question (or the same one asked again): nothing picked for it yet.
      if (!key.startsWith(JSON.stringify([session.id, prompt.question]).slice(0, -1))) { chosen = null; words = ''; }
      key = now;
      draw(session);
    },
  };
}

// Ending a session, under its header: the line that ends it and what that does. A lead and a lead's team aren't ended
// from here (their lead and `vibeswitcher stop` are). Returns { el, toggle(), update(session) }.
export function endStrip() {
  const lineSlot = h('div');
  const close = h('button', { class: 'icon-button', type: 'button', 'aria-label': 'Close', title: 'Close' }, icon('close', 13));
  const el = h('div', { class: 'end-strip', role: 'group', 'aria-label': 'End this session', hidden: true },
    h('div', { class: 'end-text' }, h('strong', null, 'End this session'), h('span', null, ' — its agent stops, with everything running in its terminal.')),
    lineSlot, close);
  let open = false;
  let id = null;
  close.addEventListener('click', () => { open = false; el.hidden = true; });
  return {
    el,
    toggle() { open = !open; el.hidden = !open; if (open) el.querySelector('.copy-button')?.focus(); },
    update(session) {
      if (session?.id !== id) { open = false; id = session?.id || null; }
      const can = drivable(session) && !session.role;
      if (!can) open = false;
      el.hidden = !open;
      if (can) lineSlot.replaceChildren(copyLine(`vibeswitcher end ${sessionShort(session.id)}`, 'the command that ends it'));
      return can;
    },
  };
}

// Starting a session: a folder, Claude or a shell, Claude's model; the line that starts it, as you type. `folder()`
// gives the folder to offer first. Returns { el, update() }.
export function newSessionForm(app, { folder }) {
  let agent = 'claude';
  const path = h('input', { class: 'answer-input', type: 'text', placeholder: '/path/to/project', 'aria-label': 'Folder', spellcheck: 'false', autocomplete: 'off' });
  const model = h('input', { class: 'answer-input model-input', type: 'text', placeholder: 'Model (optional)', 'aria-label': 'Model', spellcheck: 'false', autocomplete: 'off' });
  const kinds = ['claude', 'shell'].map((kind) => h('button', { type: 'button', onclick: () => { agent = kind; draw(); } }, kind === 'claude' ? 'Claude' : 'Shell'));
  const lineSlot = h('div', { class: 'prompt-line' });
  const el = h('section', { class: 'new-session', 'aria-label': 'Start a session' },
    h('h2', { class: 'new-title' }, 'Start a session'),
    h('div', { class: 'new-fields' }, path, h('div', { class: 'segmented', role: 'group', 'aria-label': 'Agent' }, kinds), model),
    lineSlot,
    h('p', { class: 'confirm-note' }, 'Run it in a terminal on this node: it asks for a code, then starts the session here.'));
  let offered = false;

  function draw() {
    kinds.forEach((button, index) => button.setAttribute('aria-pressed', String((index === 0) === (agent === 'claude'))));
    model.hidden = agent !== 'claude';
    // `~/` is the node's home, as a shell would read it (the command line takes the folder as given).
    const home = app.store.state.node?.home;
    const typed = path.value.trim();
    const where = home && (typed === '~' || typed.startsWith('~/')) ? home + typed.slice(1) : typed;
    if (!where) {
      lineSlot.replaceChildren(h('p', { class: 'confirm-note' }, 'Give a folder: the line that starts it shows here.'));
      return;
    }
    const chosenModel = agent === 'claude' ? model.value.trim() : '';
    const line = `vibeswitcher new ${shellWord(where)}${agent === 'shell' ? ' --agent shell' : ''}${chosenModel ? ` --model ${shellWord(chosenModel)}` : ''}`;
    lineSlot.replaceChildren(copyLine(line, 'the command that starts it'));
  }
  path.addEventListener('input', draw);
  model.addEventListener('input', draw);

  return {
    el,
    update() {
      if (!offered && !path.value) {
        const given = folder();
        if (given) { path.value = given; offered = true; }
      }
      draw();
    },
  };
}
