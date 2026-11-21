// A shell request's card (ShellCards.swift): what would run, whole, and the lines that settle it in a terminal.
// A page never acts; an agent's words are only ever text.
export const commandSize = (command) => {
  const text = String(command || ''), lines = text.split('\n').length;
  return `${lines} line${lines === 1 ? '' : 's'}, ${new TextEncoder().encode(text).length} bytes`;
};

const OUTCOME = { declined: 'Declined', expired: 'Expired unanswered', starting: 'Starting…' };

export function shellFacts(card) {
  const s = card.shell || {}, short = String(card.id).replace(/^.*:card:/, '').slice(0, 8);
  return {
    asker: s.asker || 'a session', folder: s.cwd || '', lines: String(s.command || '').split('\n'), size: commandSize(s.command),
    label: s.label || '', state: s.state || 'waiting', expiresAt: s.expiresAt || null,
    run: `vibeswitcher answer ${short} run`, decline: `vibeswitcher answer ${short} decline`,
    outcome: s.state === 'started' ? `Started${s.name ? `: session “${s.name}”` : ''}`
      : s.state === 'failed' ? `Didn’t start${s.why ? `: ${s.why}` : ''}` : OUTCOME[s.state] || null,
  };
}

// A session's own open shell cards, oldest first.
export const shellCardsOf = (cards, session) => [...cards]
  .filter((c) => c.kind === 'shell' && c.open && String(c.shell?.session).toLowerCase() === String(session).toLowerCase())
  .sort((a, b) => String(a.at).localeCompare(String(b.at)));
