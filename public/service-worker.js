// Service Worker for Zimmer push notifications
//
// This service worker handles:
// - Push notifications from the server
// - Notification click events to open/focus the relevant session

const APP_ICON = '/icons/icon-192x192.png';
const DEFAULT_URL = '/';

// Handle push events - display notification
self.addEventListener('push', (event) => {
  if (!event.data) {
    console.warn('Push event received with no data');
    return;
  }

  let data;
  try {
    data = event.data.json();
  } catch (e) {
    console.error('Failed to parse push notification data:', e);
    return;
  }

  const title = data.title || 'Zimmer';
  // URL is nested inside data.data.url (server sends {data: {url: "..."}})
  const notificationUrl = data.data?.url || data.url || DEFAULT_URL;
  const options = {
    body: data.body || '',
    icon: data.icon || APP_ICON,
    badge: APP_ICON,
    tag: data.tag || 'zimmer-notification',
    data: {
      url: notificationUrl
    },
    requireInteraction: data.requireInteraction || false,
    // Play system notification sound
    silent: false
  };

  event.waitUntil(
    self.registration.showNotification(title, options)
  );
});

// Handle notification clicks - open or focus the URL
self.addEventListener('notificationclick', (event) => {
  event.notification.close();

  const urlToOpen = event.notification.data?.url || DEFAULT_URL;

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true })
      .then((clientList) => {
        const targetUrl = new URL(urlToOpen, self.location.origin);

        // Check if there's already a window/tab open with this URL
        for (const client of clientList) {
          const clientUrl = new URL(client.url);

          if (clientUrl.pathname === targetUrl.pathname && 'focus' in client) {
            return client.focus();
          }
        }

        // If there's any existing window, navigate it to the target URL and focus
        // This handles mobile PWAs where openWindow may not work as expected
        if (clientList.length > 0) {
          const client = clientList[0];
          if ('navigate' in client) {
            return client.navigate(targetUrl.href)
              .then((navigatedClient) => {
                if (navigatedClient && 'focus' in navigatedClient) {
                  return navigatedClient.focus();
                }
              })
              .catch(() => {
                // Fallback to opening new window if navigate fails
                if (clients.openWindow) {
                  return clients.openWindow(targetUrl.href);
                }
              });
          }
        }

        // If no existing window (or navigate not supported), open a new one
        if (clients.openWindow) {
          return clients.openWindow(targetUrl.href);
        }
      })
  );
});

// Handle service worker activation
self.addEventListener('activate', (event) => {
  event.waitUntil(clients.claim());
});
