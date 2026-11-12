/* Hotel Ops service worker
   - network first for the page (updates show at once), last copy when offline
   - phone notifications for tasks, with the unread count on the app icon */
const C = "hotelops-shell-v4";
const LIB = "vendor/supabase-2.117.3.js";
self.addEventListener("install", e => { self.skipWaiting(); e.waitUntil(caches.open(C).then(c => c.add(LIB)).catch(() => {})); });
self.addEventListener("activate", e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k.startsWith("hotelops-shell-") && k !== C).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener("fetch", e => {
  const r = e.request;
  if (r.method !== "GET") return;
  /* versioned library files never change: serve the saved copy so a weak network can't break the app */
  if (new URL(r.url).pathname.includes("/vendor/")) {
    e.respondWith(caches.open(C).then(c => c.match(r, { ignoreSearch: true }).then(m => m || fetch(r).then(res => { if (res.ok) c.put(r, res.clone()); return res; }))));
    return;
  }
  if (r.mode !== "navigate") return;
  e.respondWith(fetch(r).then(res => { const cp = res.clone(); caches.open(C).then(c => c.put("./", cp)); return res; })
    .catch(() => caches.open(C).then(c => c.match("./")).then(m => m || new Response("Offline", { status: 503 }))));
});
self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { title: "Hotel Ops", body: e.data ? e.data.text() : "" }; }
  e.waitUntil((async () => {
    await self.registration.showNotification(d.title || "Hotel Ops", {
      body: d.body || "", icon: "icons/icon-192.png", badge: "icons/badge-96.png",
      tag: "n" + (d.id || Date.now()), data: { url: d.url || "./" }, dir: "auto", lang: "ar", vibrate: [200, 100, 200], renotify: true, requireInteraction: false, silent: false, timestamp: Date.now()
    });
    try { if (self.navigator.setAppBadge && d.badge != null) { d.badge ? await self.navigator.setAppBadge(d.badge) : await self.navigator.clearAppBadge(); } } catch (x) {}
    const cs = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    cs.forEach(c => c.postMessage({ type: "notif" }));
  })());
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "./", self.registration.scope).href;
  e.waitUntil((async () => {
    const cs = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of cs) { if (c.url.startsWith(self.registration.scope)) { try { await c.focus(); } catch (x) {} c.postMessage({ type: "open", url }); return; } }
    await self.clients.openWindow(url);
  })());
});
