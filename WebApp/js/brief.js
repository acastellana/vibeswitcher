// Brief me on the page (views/start.js's, the `brief` kind): what happened lately and what's asked of you, as the node
// writes it (by the summaries' model when AI summaries are on, else from the boards and logs), read aloud on request by
// the browser's own speech (`speechSynthesis`: nothing leaves the browser for it). Read-only.

// What the briefing's line under its words says: what waits on you, and who wrote it.
export function briefFoot(result) {
  const asks = result?.asks || 0;
  const waits = asks === 0 ? 'Nothing waits on you.' : `${asks} thing${asks === 1 ? '' : 's'} wait${asks === 1 ? 's' : ''} on you.`;
  return `${waits} ${result?.byModel ? 'Written by Claude Haiku from the boards and logs.' : 'Written from the boards and logs.'}`;
}

// The browser's speech, or null where it has none.
export function speech(env = globalThis) {
  return env.speechSynthesis && typeof env.SpeechSynthesisUtterance === 'function' ? { synth: env.speechSynthesis, Utterance: env.SpeechSynthesisUtterance } : null;
}

// Reads `text` aloud in `language`, stopping whatever was being read; `done` when it ends or is stopped.
export function speak(voice, text, language = 'en', done = () => {}) {
  voice.synth.cancel();
  const said = new voice.Utterance(text);
  said.lang = language;
  said.onend = done;
  said.onerror = done;
  voice.synth.speak(said);
  return said;
}
