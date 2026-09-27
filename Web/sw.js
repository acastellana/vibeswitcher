// Notifications only: the app itself always loads fresh data (no offline cache of session content).
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));

self.addEventListener('push', event => {
  let message = {};
  try { message = event.data ? event.data.json() : {}; } catch (e) { message = { title: 'VibeSwitcher' }; }
  event.waitUntil(self.registration.showNotification(message.title || 'VibeSwitcher', {
    body: message.body || '',
    tag: message.tag || undefined,
    renotify: Boolean(message.tag),
    icon: '/icon-192.png',
    badge: '/icon-192.png',
    data: { tty: message.tty || null },
  }));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const tty = event.notification.data && event.notification.data.tty;
  const target = tty && /^ttys\d{1,4}$/.test(tty) ? `/#s=${tty}` : '/';
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if ('focus' in client) {
        client.postMessage({ open: tty || null });
        return client.focus();
      }
    }
    return self.clients.openWindow(target);
  })());
});
