'use strict';

self.addEventListener('push', (event) => {
  let datos = {};
  try {
    datos = event.data ? event.data.json() : {};
  } catch (_) {
    datos = { body: event.data ? event.data.text() : '' };
  }

  event.waitUntil(self.registration.showNotification(
    datos.title || 'Bingo Express GP',
    {
      body: datos.body || 'Tienes una nueva notificación.',
      icon: './icon.svg',
      badge: './icon.svg',
      tag: datos.tag || 'bingo-express-gp',
      renotify: true,
      silent: false,
      vibrate: [220, 100, 220],
      data: { url: datos.url || 'cuenta.html' }
    }
  ));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const destino = new URL(
    event.notification.data?.url || 'cuenta.html',
    self.registration.scope
  ).href;

  event.waitUntil((async () => {
    const ventanas = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const ventana of ventanas) {
      if (ventana.url.startsWith(self.registration.scope) && 'focus' in ventana) {
        if ('navigate' in ventana) await ventana.navigate(destino);
        return ventana.focus();
      }
    }
    return clients.openWindow(destino);
  })());
});
