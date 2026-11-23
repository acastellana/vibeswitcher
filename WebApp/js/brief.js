// Brief me on the page (views/start.js's, the `brief` kind): what happened lately and what's asked of you, as the node
// writes it (by the summaries' model when AI summaries are on, else from the boards and logs), read aloud on request by
// the browser's own speech (`speechSynthesis`: nothing leaves the browser for it). Read-only.
import { t } from './i18n.js';


// What the briefing's line under its words says: what waits on you, and who wrote it.
export function briefFoot(result) {
  const asks = result?.asks || 0;
  const waits = asks === 0 ? t('brNothingWaitsOnYou') : t('brWaits', { n: asks });
  return `${waits} ${result?.byModel ? t('brByModel') : t('brByBoards')}`;
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
