// App shell: routing, player bar, now-playing panel (lyrics/queue), shortcuts, PWA.
import { api, auth, flushOutbox } from "./api.js";
import { itemMenu, markPlaying, navigate, toggleLike } from "./components.js";
import { onOfflineChange } from "./offline.js";
import { player } from "./player.js";
import { $, $$, artSrc, empty, fmtTime, html, hydrateIcons, icon, prompt, setRangeFill, toast } from "./ui.js";
import * as V from "./views.js";
import { spotifyCallbackView, streamingView } from "./connect_view.js";

const routes = [
  [/^\/$/, V.homeView],
  [/^\/search$/, V.searchView],
  [/^\/library$/, V.libraryView],
  [/^\/liked$/, (el, p, q) => V.collectionView(el, p, q, "liked")],
  [/^\/playlist\/(?<id>\d+)$/, (el, p, q) => V.collectionView(el, p, q, "playlist")],
  [/^\/album\/(?<id>\d+)$/, (el, p, q) => V.collectionView(el, p, q, "album")],
  [/^\/artist\/(?<id>\d+)$/, (el, p, q) => V.collectionView(el, p, q, "artist")],
  [/^\/radio$/, V.radioView],
  [/^\/streaming$/, streamingView],
  [/^\/connect\/spotify$/, spotifyCallbackView],
  [/^\/podcasts$/, V.podcastsView],
  [/^\/podcast\/itunes\/(?<itunes>\d+)$/, V.podcastView],
  [/^\/podcast\/(?<id>\d+)$/, V.podcastView],
  [/^\/recognize$/, V.recognizeView],
  [/^\/tools$/, V.toolsView],
  [/^\/settings$/, V.settingsView],
];

let cleanup = null;
const viewRef = { el: $("#view") };

async function route() {
  cleanup?.();
  cleanup = null;
  const { pathname, search } = location;
  const loggedIn = auth.loggedIn;
  document.body.classList.toggle("logged-out", !loggedIn);
  $("#sidebar").hidden = $("#tabbar").hidden = !loggedIn;
  const fresh = viewRef.el.cloneNode(false); // drop listeners from the previous view
  viewRef.el.replaceWith(fresh);
  viewRef.el = fresh;
  if (!loggedIn) {
    $("#player").hidden = true;
    return V.loginView(fresh);
  }
  $$("[data-link]").forEach((a) => {
    const href = a.getAttribute("href");
    a.classList.toggle("active", href === "/" ? pathname === "/" : pathname.startsWith(href.split("?")[0]) && href !== "/");
  });
  for (const [re, fn] of routes) {
    const m = pathname.match(re);
    if (m) {
      $("#main").scrollTop = 0;
      const out = await fn(fresh, m.groups || {}, new URLSearchParams(search));
      if (typeof out === "function") cleanup = out;
      hydrateIcons(fresh);
      return;
    }
  }
  fresh.innerHTML = empty("search", "Page not found", "", html`<a class="btn" href="/" data-link>Go home</a>`).s;
}

window.addEventListener("lipina:navigate", (e) => go(e.detail));
function go(path) {
  if (path !== location.pathname + location.search) history.pushState(null, "", path);
  route();
}
document.addEventListener("click", (e) => {
  const a = e.target.closest("a[data-link]");
  if (!a || e.metaKey || e.ctrlKey || e.shiftKey || a.target === "_blank") return;
  e.preventDefault();
  go(a.getAttribute("href"));
});
window.addEventListener("popstate", route);

// ------------------------------------------------------------- sidebar

async function loadSidebarPlaylists() {
  if (!auth.loggedIn) return;
  try {
    const list = await api.list("/api/playlists/");
    $("#sidebar-playlists").innerHTML = html`<a href="/liked" data-link>♥ Liked Songs</a>${list.map((p) => html`<a href="/playlist/${p.id}" data-link>${p.name}</a>`)}`.s;
  } catch { /* offline */ }
}
async function newPlaylist() {
  const name = await prompt("New playlist", { placeholder: "My playlist", ok: "Create" });
  if (!name) return;
  try {
    const p = await api.post("/api/playlists/", { name });
    loadSidebarPlaylists();
    go(`/playlist/${p.id}`);
  } catch (e) { toast(e.message); }
}
$("#new-playlist").addEventListener("click", newPlaylist);
window.addEventListener("lipina:new-playlist", newPlaylist);
window.addEventListener("lipina:playlists", loadSidebarPlaylists);

// ------------------------------------------------------------ player bar

const el = {
  bar: $("#player"), art: $("#p-art"), title: $("#p-title"), sub: $("#p-sub"), like: $("#p-like"),
  play: $("#p-play"), prev: $("#p-prev"), next: $("#p-next"), shuffle: $("#p-shuffle"), repeat: $("#p-repeat"),
  seek: $("#p-seek"), cur: $("#p-cur"), dur: $("#p-dur"), vol: $("#p-vol"), mute: $("#p-mute"),
  lyrics: $("#p-lyrics"), queue: $("#p-queue"), speed: $("#p-speed"), viz: $("#p-viz"), panel: $("#np-panel"),
};
el.prev.innerHTML = icon("prev").s;
el.next.innerHTML = icon("next").s;
el.shuffle.innerHTML = icon("shuffle").s;
el.lyrics.innerHTML = icon("lyrics").s;
el.queue.innerHTML = icon("queue").s;

let seeking = false;
function renderBar() {
  const it = player.current;
  el.bar.hidden = !it || !auth.loggedIn;
  if (!it) return;
  const np = player.nowPlaying?.raw;
  el.title.textContent = np || it.title;
  el.sub.innerHTML = it.live ? html`<span class="live-badge">● LIVE</span> ${np ? it.title : it.subtitle}`.s
    : it.artistId ? html`<a href="/artist/${it.artistId}" data-link>${it.subtitle}</a>`.s
      : it.service ? html`${it.subtitle} <span class="svc-badge">${it.preview ? "Preview" : it.service}</span>`.s : html`${it.subtitle}`.s;
  if (el.art.dataset.src !== (it.art || "")) { el.art.src = artSrc(it.art); el.art.dataset.src = it.art || ""; }
  el.play.innerHTML = icon(player.playing ? "pause" : "play").s;
  el.play.setAttribute("aria-label", player.playing ? "Pause" : "Play");
  el.like.hidden = it.kind !== "track";
  el.like.innerHTML = icon(it.liked ? "heart" : "heartO").s;
  el.like.classList.toggle("on", !!it.liked);
  el.shuffle.classList.toggle("on", player.shuffle);
  el.repeat.innerHTML = icon(player.repeat === "one" ? "repeat1" : "repeat").s;
  el.repeat.classList.toggle("on", player.repeat !== "off");
  [el.prev, el.next, el.shuffle, el.repeat, el.speed].forEach((b) => { b.disabled = !!it.live; });
  el.speed.disabled = !!(it.live || it.provider);
  el.seek.disabled = !!it.live;
  el.speed.textContent = `${player.rate}×`;
  el.mute.innerHTML = icon(player.muted || player.volume === 0 ? "mute" : "volume").s;
  el.vol.value = player.muted ? 0 : player.volume * 100;
  setRangeFill(el.vol);
  renderTime();
  document.title = player.playing ? `${np || it.title} · ${it.live ? it.title : it.subtitle}` : "Lipina — Music, Radio & Podcasts";
}
function renderTime() {
  const it = player.current;
  if (!it) return;
  const d = player.duration, t = player.currentTime;
  el.cur.textContent = it.live ? "LIVE" : fmtTime(t);
  el.dur.textContent = it.live ? "" : fmtTime(d);
  if (!seeking) el.seek.value = d ? (t / d) * 1000 : 0;
  setRangeFill(el.seek);
  el.bar.style.setProperty("--fill", `${d ? (t / d) * 100 : 0}%`);
  if (panelMode === "lyrics") syncLyrics();
}

el.play.onclick = () => player.toggle();
el.prev.onclick = () => player.prev();
el.next.onclick = () => player.next();
el.shuffle.onclick = () => player.toggleShuffle();
el.repeat.onclick = () => player.cycleRepeat();
el.like.onclick = () => player.current && toggleLike(player.current);
el.art.onclick = () => togglePanel("lyrics");
el.mute.onclick = () => player.toggleMute();
el.vol.oninput = () => player.setVolume(el.vol.value / 100);
el.seek.oninput = () => { seeking = true; el.cur.textContent = fmtTime((el.seek.value / 1000) * player.duration); setRangeFill(el.seek); };
el.seek.onchange = () => { player.seek((el.seek.value / 1000) * player.duration); seeking = false; };
el.speed.onclick = () => {
  const rates = [0.75, 1, 1.25, 1.5, 1.75, 2];
  player.setRate(rates[(rates.indexOf(player.rate) + 1) % rates.length]);
  toast(`Playback speed ${player.rate}×`);
};
el.lyrics.onclick = () => togglePanel("lyrics");
el.queue.onclick = () => togglePanel("queue");
el.bar.addEventListener("click", (e) => {
  // on small screens, tapping the bar opens the full player panel
  if (innerWidth <= 760 && !e.target.closest("button,a,input")) togglePanel("lyrics");
});
el.bar.addEventListener("contextmenu", (e) => { if (player.current) { e.preventDefault(); itemMenu(e, player.current); } });

player.addEventListener("change", renderBar);
player.addEventListener("time", renderTime);
player.addEventListener("track", () => {
  renderBar();
  markPlaying(viewRef.el);
  if (panelMode) renderPanel();
});
player.addEventListener("queue", () => panelMode === "queue" && renderPanel());
player.addEventListener("lyrics", () => panelMode === "lyrics" && renderPanel());
player.addEventListener("error", () => player.error && toast(player.error));

// ---------------------------------------------------- now playing panel

let panelMode = null;
function togglePanel(mode) {
  panelMode = panelMode === mode ? null : mode;
  el.panel.hidden = !panelMode;
  el.lyrics.classList.toggle("on", panelMode === "lyrics");
  el.queue.classList.toggle("on", panelMode === "queue");
  if (panelMode) renderPanel();
}

let activeLine = -1;
async function renderPanel() {
  const it = player.current;
  const close = html`<button class="icon-btn" data-close aria-label="Close">${icon("close")}</button>`;
  if (!it) { el.panel.innerHTML = html`<h3>Nothing playing ${close}</h3>`.s; return bindPanel(); }
  if (panelMode === "queue") {
    const up = player.upNext;
    el.panel.innerHTML = html`<h3>Queue ${close}</h3><p class="muted small">Now playing</p>
      <div class="list-item playing">${html`<img src="${artSrc(it.art)}" alt="">`}<div class="meta"><div class="tt">${it.title}</div><div class="ts">${it.subtitle}</div></div></div>
      <p class="muted small" style="margin-top:16px">Next up</p>
      ${up.length ? up.map((u, i) => html`<div class="list-item" data-up="${i}"><img src="${artSrc(u.art)}" alt="" loading="lazy"><div class="meta"><div class="tt">${u.title}</div><div class="ts">${u.subtitle}</div></div><button class="icon-btn" data-rm="${i}" aria-label="Remove">${icon("close")}</button></div>`) : html`<p class="muted">Nothing queued. Use ⋮ → Add to queue.</p>`}`.s;
    return bindPanel();
  }
  el.panel.innerHTML = html`<h3>${it.live ? "Live radio" : "Lyrics"} ${close}</h3>
    <img src="${artSrc(it.art)}" alt="" style="width:100%;aspect-ratio:1;object-fit:cover;border-radius:12px;margin-bottom:16px">
    <div style="font-weight:800;font-size:20px">${player.nowPlaying?.raw || it.title}</div><div class="muted" style="margin-bottom:16px">${it.subtitle}</div>
    <div data-lyrics><p class="muted">${it.live || it.kind === "episode" ? "" : "Loading lyrics…"}</p></div>`.s;
  bindPanel();
  if (it.live || it.kind === "episode") return;
  const l = player.lyrics?.key === it.key ? player.lyrics : await player.loadLyrics();
  if (player.current !== it || panelMode !== "lyrics") return;
  const box = $("[data-lyrics]", el.panel);
  activeLine = -1;
  if (l.synced?.length) {
    box.innerHTML = html`<div class="lyrics">${l.synced.map((ln, i) => html`<p data-t="${ln.t}" data-l="${i}">${ln.text || "♪"}</p>`)}</div>`.s;
    box.onclick = (e) => { const p = e.target.closest("[data-t]"); if (p) player.seek(+p.dataset.t); };
    syncLyrics();
  } else if (l.plain) box.innerHTML = html`<div class="lyrics plain">${l.plain}</div>`.s;
  else box.innerHTML = html`<p class="muted">No lyrics found for this song.</p>`.s;
}
function syncLyrics() {
  const lines = player.lyrics?.synced;
  if (!lines?.length || el.panel.hidden) return;
  const t = player.currentTime + 0.25;
  let idx = -1;
  for (let i = 0; i < lines.length && lines[i].t <= t; i++) idx = i;
  if (idx === activeLine) return;
  activeLine = idx;
  $$("[data-l]", el.panel).forEach((p, i) => { p.classList.toggle("active", i === idx); p.classList.toggle("past", i < idx); });
  $(`[data-l="${idx}"]`, el.panel)?.scrollIntoView({ block: "center", behavior: "smooth" });
}
function bindPanel() {
  $("[data-close]", el.panel)?.addEventListener("click", () => togglePanel(panelMode));
  el.panel.onclick = (e) => {
    const rm = e.target.closest("[data-rm]");
    if (rm) return player.removeUpNext(+rm.dataset.rm);
    const up = e.target.closest("[data-up]");
    if (up) player.jumpUpNext(+up.dataset.up);
  };
}

// --------------------------------------------------------- visualizer

(function viz() {
  const c = el.viz.getContext("2d");
  const data = new Uint8Array(64);
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const draw = (now) => {
    requestAnimationFrame(draw);
    if (el.bar.hidden || document.hidden) return;
    // Cross-origin radio and podcasts play outside Web Audio, so the analyser
    // stays empty. Fall back to a moving pattern while something is playing.
    const dpr = devicePixelRatio || 1;
    const cssW = el.viz.clientWidth || 120;
    const cssH = el.viz.clientHeight || 32;
    const bw = Math.max(1, Math.round(cssW * dpr));
    const bh = Math.max(1, Math.round(cssH * dpr));
    if (el.viz.width !== bw || el.viz.height !== bh) {
      el.viz.width = bw;
      el.viz.height = bh;
    }
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    c.clearRect(0, 0, cssW, cssH);
    const an = player.analyser;
    const live = !!(an && player.playing && !player.ext && player.audio === player.fx);
    if (live) an.getByteFrequencyData(data);
    const bars = 24;
    const gap = 2;
    const w = (cssW - gap * (bars - 1)) / bars;
    const t = now / 1000;
    for (let i = 0; i < bars; i++) {
      let v = 0.14;
      if (live) v = data[i + 2] / 255;
      else if (player.playing && !reduceMotion) {
        const env = 0.45 + 0.55 * Math.sin(Math.PI * i / (bars - 1));
        const a = Math.abs(Math.sin(t * 6.2 + i * 0.85));
        const b = Math.abs(Math.sin(t * 2.1 + i * 0.42));
        v = (0.18 + (a * 0.55 + b * 0.45) * env) * 0.85;
      }
      const h = Math.max(3, v * cssH);
      c.fillStyle = `rgba(30,214,160,${0.45 + Math.min(v, 1) * 0.55})`;
      c.beginPath();
      c.roundRect(i * (w + gap), cssH - h, Math.max(1, w), h, Math.min(2, w / 2));
      c.fill();
    }
  };
  requestAnimationFrame(draw);
})();

// ----------------------------------------------------------- shortcuts

document.addEventListener("keydown", (e) => {
  if (e.target.closest("input, textarea, select, [contenteditable]") || e.metaKey || e.ctrlKey || e.altKey) return;
  const k = e.key.toLowerCase();
  const actions = {
    " ": () => player.toggle(), arrowright: () => player.seekBy(e.shiftKey ? 30 : 5), arrowleft: () => player.seekBy(e.shiftKey ? -30 : -5),
    n: () => player.next(), p: () => player.prev(), s: () => player.toggleShuffle(), r: () => player.cycleRepeat(), m: () => player.toggleMute(),
    l: () => player.current?.kind === "track" && toggleLike(player.current), "/": () => go("/search"),
    arrowup: () => player.setVolume(player.volume + 0.05), arrowdown: () => player.setVolume(player.volume - 0.05),
  };
  if (actions[k] && player.current || k === "/") { e.preventDefault(); actions[k]?.(); }
});

// ---------------------------------------------------- online / offline

function updateOnline() {
  $("#offline-banner").hidden = navigator.onLine;
  if (navigator.onLine) flushOutbox();
}
window.addEventListener("online", () => { updateOnline(); toast("Back online"); });
window.addEventListener("offline", updateOnline);
onOfflineChange(() => markPlaying(viewRef.el));

// ---------------------------------------------------------------- PWA

if ("serviceWorker" in navigator && !window.LIPINA.debug) {
  navigator.serviceWorker.register("/sw.js", { scope: "/" }).catch((e) => console.warn("SW registration failed", e));
}
window.addEventListener("beforeinstallprompt", (e) => { e.preventDefault(); window.__lipinaInstall = e; });

// --------------------------------------------------------------- boot

window.addEventListener("lipina:login", async () => { loadSidebarPlaylists(); go(location.pathname === "/login" ? "/" : location.pathname); renderBar(); });
window.addEventListener("lipina:logout", () => { auth.logout(); player.pause(); go("/"); });

(async function boot() {
  hydrateIcons(document);
  updateOnline();
  if (auth.loggedIn) {
    try { await auth.loadMe(); } catch { /* token invalid → logout handled by api */ }
    loadSidebarPlaylists();
    flushOutbox();
  }
  renderBar();
  route();
})();
