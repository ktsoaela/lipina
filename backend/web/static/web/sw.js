// Lipina service worker — offline-first app shell + API cache.
// Strategy:
//   app shell & static assets  → stale-while-revalidate
//   GET /api/* (not streams)    → network-first, fall back to cache when offline
//   cover images (/media/covers, external art) → cache-first with size cap
//   audio streams               → never cached here (downloads live in IndexedDB)
const VERSION = "lipina-v2";
const SHELL = "lipina-shell-" + VERSION;
const API = "lipina-api";
const ART = "lipina-art";
const SHELL_URLS = [
  "/",
  "/manifest.webmanifest",
  "/static/web/css/app.css",
  "/static/web/js/app.js",
  "/static/web/js/api.js",
  "/static/web/js/db.js",
  "/static/web/js/ui.js",
  "/static/web/js/player.js",
  "/static/web/js/offline.js",
  "/static/web/js/tools.js",
  "/static/web/js/views.js",
  "/static/web/js/components.js",
  "/static/web/js/streaming.js",
  "/static/web/js/connect_view.js",
  "/static/web/icons/icon.svg",
];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(SHELL).then((c) => c.addAll(SHELL_URLS)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith("lipina-shell-") && k !== SHELL).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

async function trim(cacheName, max) {
  const c = await caches.open(cacheName);
  const keys = await c.keys();
  for (let i = 0; i < keys.length - max; i++) await c.delete(keys[i]);
}

async function networkFirst(req) {
  const cache = await caches.open(API);
  try {
    const res = await fetch(req);
    if (res.ok) { cache.put(req, res.clone()); trim(API, 400); }
    return res;
  } catch {
    const hit = await cache.match(req);
    return hit || new Response(JSON.stringify({ detail: "You're offline" }), { status: 503, headers: { "Content-Type": "application/json" } });
  }
}

async function staleWhileRevalidate(req, cacheName) {
  const cache = await caches.open(cacheName);
  const hit = await cache.match(req);
  const net = fetch(req).then((res) => { if (res.ok) cache.put(req, res.clone()); return res; }).catch(() => hit);
  return hit || net;
}

async function cacheFirst(req) {
  const cache = await caches.open(ART);
  const hit = await cache.match(req);
  if (hit) return hit;
  try {
    const res = await fetch(req);
    if (res.ok || res.type === "opaque") { cache.put(req, res.clone()); trim(ART, 600); }
    return res;
  } catch { return new Response("", { status: 504 }); }
}

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (req.headers.has("range") || url.pathname.includes("/stream/")) return; // audio → network
  if (url.origin === location.origin) {
    if (url.pathname.startsWith("/api/auth/")) return;
    if (url.pathname.startsWith("/api/")) return e.respondWith(networkFirst(req));
    if (url.pathname.startsWith("/media/covers/")) return e.respondWith(cacheFirst(req));
    if (url.pathname.startsWith("/static/")) return e.respondWith(staleWhileRevalidate(req, SHELL));
    if (url.pathname.startsWith("/admin")) return;
    if (req.mode === "navigate") {
      // SPA: every client route is served the cached shell when offline
      return e.respondWith(fetch(req).catch(() => caches.match("/", { ignoreSearch: true })));
    }
    return;
  }
  if (req.destination === "image") e.respondWith(cacheFirst(req));
});
