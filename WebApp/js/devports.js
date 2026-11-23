// A session's dev servers as the inspector shows them (`session.ports`, the node's `DevPorts`; the app's dev pages):
// each port its processes listen on, and whether this page can open it. The parts with no page in them, for the tests.
import { t } from './i18n.js';


// Whether a page at `hostname` runs on the node's own machine (the loopback page), where localhost at that port is the
// session's server; on the tailnet it would be the phone's own localhost.
export const onTheNode = (hostname) => hostname === '127.0.0.1' || hostname === 'localhost' || hostname === '[::1]';

// A port as a row: its words, and the address to open (null where this page can't open it, or the node's answer
// doesn't name exactly localhost at that port).
export function portRow(entry, hostname) {
  const port = Number(entry?.port);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) return null;
  const who = entry.program ? `${entry.program} (pid ${entry.pid})` : `pid ${entry.pid}`;
  const where = entry.address === '0.0.0.0' || entry.address === '::' ? t('dpEvery') : t('dpLocal');
  // The node's address for it, taken only when it is exactly the page on this machine's localhost at that port.
  const named = typeof entry.url === 'string' ? entry.url.match(/^http:\/\/localhost:(\d{4,5})\/$/) : null;
  const url = named && Number(named[1]) === port ? entry.url : null;
  return { label: `localhost:${port}`, about: `${who} · ${where}`, url: onTheNode(hostname) ? url : null };
}
