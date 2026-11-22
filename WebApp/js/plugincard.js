// A feature plugin's card (Sources/VibeNode/Plugins/Plugin.swift, `card.plugin`): one shape for every plugin, drawn by
// one renderer (views/cards.js's pluginCard). What it asks, whole, and the lines that settle it in a terminal. A page
// never acts; an agent's words are only ever text.

const cap = (text) => { const s = String(text || ''); return s ? s[0].toUpperCase() + s.slice(1) : s; };

// The card as the page draws it: its facts (labels as a heading starts them), its body whole, the agent's words, and
// each answer word as the line that settles it.
export function pluginFacts(card) {
  const p = card.plugin || {}, short = String(card.id).replace(/^.*:card:/, '').slice(0, 8), body = p.body || {};
  return {
    plugin: p.plugin || '', title: p.title || 'An agent asks', severity: p.severity || 'important',
    asker: p.asker || 'a session', ask: p.ask || '',
    facts: (p.facts || []).map((fact) => ({ label: cap(fact.label), value: fact.value || '', folder: !!fact.folder })),
    body: { name: cap(body.name || 'request'), lines: Array.isArray(body.lines) ? body.lines : [], size: body.size || '', note: body.note || '' },
    // The agent's own words, marked as its own here whatever the plugin labels them.
    context: p.context ? { label: `${cap(p.context.label)} (the agent’s words)`, text: `“${p.context.text || ''}”` } : null,
    state: p.state || 'waiting', expiresAt: p.expiresAt || null, waiting: p.waiting || '',
    outcome: p.outcome || null,
    actions: (p.actions || []).map((action) => ({ word: action.word, label: action.label, line: `vibeswitcher answer ${short} ${action.word}`, says: `the command that ${action.short}` })),
  };
}

// The plugins the node has on: its status's (live), else its hello's; null: a node before plugins.
export const pluginsOn = (state) => (Array.isArray(state?.node?.plugins) ? state.node.plugins : state?.plugins ?? null);

// Whether the node has `plugin` on, as its hello said (null: a node before plugins, which lists none).
export const pluginOn = (plugins, plugin) => plugins == null || plugins.some((p) => p.id === plugin);

// A session's own open plugin cards, oldest first, of the plugins that are on.
export const pluginCardsOf = (cards, session, plugins = null) => [...cards]
  .filter((c) => c.kind === 'plugin' && c.open && c.plugin && pluginOn(plugins, c.plugin.plugin)
    && String(c.plugin.session).toLowerCase() === String(session).toLowerCase())
  .sort((a, b) => String(a.at).localeCompare(String(b.at)));
