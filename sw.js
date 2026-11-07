/* Hotel Ops service worker: always try the network first (so updates show at once), fall back to the last copy when offline. */
const C = "hotelops-shell-v1";
self.addEventListener("install", e => { self.skipWaiting(); });
self.addEventListener("activate", e => { e.waitUntil(self.clients.claim()); });
self.addEventListener("fetch", e => {
  const r = e.request;
  if (r.method !== "GET" || r.mode !== "navigate") return;
  e.respondWith(fetch(r).then(res => { const cp = res.clone(); caches.open(C).then(c => c.put("./", cp)); return res; })
    .catch(() => caches.open(C).then(c => c.match("./")).then(m => m || new Response("Offline", { status: 503 }))));
});
