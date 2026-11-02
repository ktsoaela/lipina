// Tiny view helpers: auto-escaping html`` templates, icons, toasts, menus, modals.

const ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
export const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ESC[c]);

class Raw { constructor(s) { this.s = s; } toString() { return this.s; } }
export const raw = (s) => new Raw(s);

const render = (v) => (v instanceof Raw ? v.s : Array.isArray(v) ? v.map(render).join("") : v === false || v == null ? "" : esc(v));

/** Tagged template: interpolations are escaped unless wrapped in raw() or produced by html``. */
export function html(strings, ...values) {
  let out = strings[0];
  values.forEach((v, i) => { out += render(v) + strings[i + 1]; });
  return new Raw(out);
}

export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

const P = {
  home: "M12 3 2 12h3v8h6v-6h2v6h6v-8h3z",
  search: "M15.5 14h-.8l-.3-.3A6.5 6.5 0 1 0 9.5 16a6.5 6.5 0 0 0 4.2-1.6l.3.3v.8l5 5 1.5-1.5zm-6 0a4.5 4.5 0 1 1 0-9 4.5 4.5 0 0 1 0 9",
  radio: "M3.2 6.3 15.8 1l.7 1.9L8.3 6H20a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V8c0-.8.5-1.5 1.2-1.7M7 20a3 3 0 1 0 0-6 3 3 0 0 0 0 6m13-8v-2h-2v2h-2v-2H4v2z",
  podcast: "M12 1a9 9 0 0 0-3 17.5v-2.2a7 7 0 1 1 6 0v2.2A9 9 0 0 0 12 1m0 4a5 5 0 0 0-2 9.6v-2.3a3 3 0 1 1 4 0v2.3A5 5 0 0 0 12 5m0 5a1.5 1.5 0 0 0-1.5 1.5c0 .5.2.9.5 1.2V23h2V12.7c.3-.3.5-.7.5-1.2A1.5 1.5 0 0 0 12 10",
  library: "M4 6H2v14a2 2 0 0 0 2 2h14v-2H4zm16-4H8a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V4a2 2 0 0 0-2-2m-2 5h-3v5.5a2.5 2.5 0 1 1-1-2V5h4z",
  wave: "M3 10h2v4H3zm4-3h2v10H7zm4-4h2v18h-2zm4 4h2v10h-2zm4 3h2v4h-2z",
  focus: "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20m0 18a8 8 0 1 1 0-16 8 8 0 0 1 0 16m.5-13H11v6l5.2 3.2.8-1.3-4.5-2.7z",
  settings: "M19.1 12.9a7 7 0 0 0 0-1.8l2-1.6-2-3.4-2.4 1a7 7 0 0 0-1.5-.9L14.8 3h-4l-.4 2.6a7 7 0 0 0-1.5.9l-2.4-1-2 3.4 2 1.6a7 7 0 0 0 0 1.8l-2 1.6 2 3.4 2.4-1c.5.4 1 .7 1.5.9l.4 2.6h4l.4-2.6c.5-.2 1-.5 1.5-.9l2.4 1 2-3.4zM12.8 15.5a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7",
  play: "M8 5v14l11-7z",
  pause: "M6 19h4V5H6zm8-14v14h4V5z",
  next: "M6 18l8.5-6L6 6zM16 6v12h2V6z",
  prev: "M6 6h2v12H6zm3.5 6 8.5 6V6z",
  shuffle: "M10.6 9.2 5.4 4 4 5.4l5.2 5.2zM14.5 4l2 2L4 18.6 5.4 20 18 7.5l2 2V4zm.3 9.4-1.4 1.4 3.1 3.1-2 2.1H20v-5.5l-2 2z",
  repeat: "M7 7h10v3l4-4-4-4v3H5v6h2zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2z",
  repeat1: "M7 7h10v3l4-4-4-4v3H5v6h2zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2zm-4-2V9h-1l-2 1v1h1.5v4z",
  heart: "M12 21.4 10.6 20C5.4 15.4 2 12.3 2 8.5 2 5.4 4.4 3 7.5 3c1.7 0 3.4.8 4.5 2.1A6 6 0 0 1 16.5 3C19.6 3 22 5.4 22 8.5c0 3.8-3.4 6.9-8.6 11.5z",
  heartO: "M16.5 3c-1.7 0-3.4.8-4.5 2.1A6 6 0 0 0 7.5 3C4.4 3 2 5.4 2 8.5c0 3.8 3.4 6.9 8.6 11.5l1.4 1.4 1.4-1.4c5.2-4.6 8.6-7.7 8.6-11.5C22 5.4 19.6 3 16.5 3m-4.4 15.6-.1.1-.1-.1C7.1 14.2 4 11.4 4 8.5 4 6.5 5.5 5 7.5 5c1.5 0 3 1 3.6 2.4h1.9C13.5 6 15 5 16.5 5c2 0 3.5 1.5 3.5 3.5 0 2.9-3.1 5.7-7.9 10.1",
  more: "M12 8a2 2 0 1 0 0-4 2 2 0 0 0 0 4m0 2a2 2 0 1 0 0 4 2 2 0 0 0 0-4m0 6a2 2 0 1 0 0 4 2 2 0 0 0 0-4",
  download: "M5 20h14v-2H5zM19 9h-4V3H9v6H5l7 7z",
  downloaded: "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20m-2 15-5-5 1.4-1.4 3.6 3.6 7.6-7.6L19 8z",
  queue: "M15 6H3v2h12zm0 4H3v2h12zM3 16h8v-2H3zM17 6v8.2a3 3 0 1 0 2 2.8V8h3V6z",
  lyrics: "M4 4h16v2H4zm0 4h10v2H4zm0 4h16v2H4zm0 4h10v2H4z",
  volume: "M3 9v6h4l5 5V4L7 9zm13.5 3A4.5 4.5 0 0 0 14 8v8a4.5 4.5 0 0 0 2.5-4M14 3.2v2a7 7 0 0 1 0 13.6v2a9 9 0 0 0 0-17.6",
  mute: "M16.5 12A4.5 4.5 0 0 0 14 8v2.2l2.5 2.5zM19 12c0 .9-.2 1.8-.5 2.6l1.5 1.5A8.9 8.9 0 0 0 21 12a9 9 0 0 0-7-8.8v2A7 7 0 0 1 19 12M4.3 3 3 4.3 7.7 9H3v6h4l5 5v-6.7l4.3 4.2c-.7.5-1.4.9-2.3 1.2v2a9 9 0 0 0 3.7-1.8l2 2 1.3-1.3-9-9zM12 4 9.9 6.1 12 8.2z",
  add: "M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6z",
  close: "M19 6.4 17.6 5 12 10.6 6.4 5 5 6.4 10.6 12 5 17.6 6.4 19 12 13.4 17.6 19 19 17.6 13.4 12z",
  upload: "M9 16h6v-6h4l-7-7-7 7h4zm-4 2h14v2H5z",
  folder: "M10 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-8z",
  mic: "M12 14a3 3 0 0 0 3-3V5a3 3 0 0 0-6 0v6a3 3 0 0 0 3 3m5-3a5 5 0 0 1-10 0H5a7 7 0 0 0 6 6.9V21h2v-3.1a7 7 0 0 0 6-6.9z",
  back15: "M11 18V6l-8.5 6zm.5-6 8.5 6V6z",
  fwd30: "M4 18l8.5-6L4 6zm9-12v12l8.5-6z",
  bed: "M7 13a3 3 0 1 0 0-6 3 3 0 0 0 0 6m12-6h-8v7H3V5H1v15h2v-3h18v3h2v-9a4 4 0 0 0-4-4",
  device: "M17 1H7a2 2 0 0 0-2 2v18a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V3a2 2 0 0 0-2-2m0 18H7V5h10z",
  logout: "M10.1 15.6 11.5 17l5-5-5-5-1.4 1.4 2.6 2.6H3v2h9.7zM19 3H5a2 2 0 0 0-2 2v4h2V5h14v14H5v-4H3v4a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2",
  note: "M12 3v10.6A4 4 0 1 0 14 17V7h4V3z",
  person: "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8m0 2c-2.7 0-8 1.3-8 4v2h16v-2c0-2.7-5.3-4-8-4",
  album: "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20m0 14.5a4.5 4.5 0 1 1 0-9 4.5 4.5 0 0 1 0 9m0-5.5a1 1 0 1 0 0 2 1 1 0 0 0 0-2",
  cast: "M21 3H3a2 2 0 0 0-2 2v3h2V5h18v14h-7v2h7a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2M1 18v3h3a3 3 0 0 0-3-3m0-4v2a5 5 0 0 1 5 5h2a7 7 0 0 0-7-7m0-4v2a9 9 0 0 1 9 9h2A11 11 0 0 0 1 10",
  check: "M9 16.2 4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z",
};

export const icon = (name, cls = "i") => raw(`<svg class="${cls}" viewBox="0 0 24 24" aria-hidden="true"><path d="${P[name] || P.note}"/></svg>`);

export function hydrateIcons(root = document) {
  $$("[data-icon]", root).forEach((el) => {
    if (!el.querySelector("svg")) el.insertAdjacentHTML("afterbegin", icon(el.dataset.icon).s);
  });
}

export function fmtTime(sec) {
  if (!isFinite(sec) || sec < 0) return "0:00";
  sec = Math.floor(sec);
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
  return h ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}` : `${m}:${String(s).padStart(2, "0")}`;
}

export function fmtLong(sec) {
  sec = Math.round(sec || 0);
  const h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60);
  return h ? `${h} hr ${m} min` : `${m} min`;
}

const PLACEHOLDER = "data:image/svg+xml," + encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect width="24" height="24" fill="#1c2a3e"/><path fill="#5d6b85" transform="translate(6 5) scale(.5)" d="M12 3v10.6A4 4 0 1 0 14 17V7h4V3z"/></svg>');
export const artSrc = (url) => url || PLACEHOLDER;
export const img = (url, cls = "art", alt = "") =>
  html`<img class="${cls}" src="${artSrc(url)}" alt="${alt}" loading="lazy" decoding="async" onerror="this.onerror=null;this.src='${raw(PLACEHOLDER)}'">`;

let toastTimer;
export function toast(msg) {
  const el = $("#toast");
  el.textContent = msg;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 2800);
}

/** Context menu anchored at an element or mouse event. items: [{label, icon, onClick}] */
export function menu(anchor, items) {
  closeMenu();
  const el = document.createElement("div");
  el.className = "menu";
  el.setAttribute("role", "menu");
  el.innerHTML = items.filter(Boolean).map((it, i) => html`<button role="menuitem" data-i="${i}">${it.icon ? icon(it.icon) : ""}${it.label}</button>`.s).join("");
  document.body.append(el);
  const list = items.filter(Boolean);
  el.addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (!b) return;
    closeMenu();
    list[+b.dataset.i].onClick();
  });
  const r = anchor.getBoundingClientRect ? anchor.getBoundingClientRect() : { left: anchor.clientX, bottom: anchor.clientY, top: anchor.clientY };
  const w = el.offsetWidth, h = el.offsetHeight;
  el.style.left = Math.min(r.left, innerWidth - w - 8) + "px";
  el.style.top = (r.bottom + h > innerHeight - 8 ? Math.max(8, r.top - h) : r.bottom) + "px";
  el.querySelector("button")?.focus();
  setTimeout(() => {
    document.addEventListener("click", closeMenu, { once: true });
    document.addEventListener("keydown", (e) => e.key === "Escape" && closeMenu(), { once: true });
  });
}
export function closeMenu() { $$(".menu").forEach((m) => m.remove()); }

export function modal(content, { onMount } = {}) {
  const root = $("#modal-root");
  root.innerHTML = html`<div class="modal-backdrop"><div class="modal" role="dialog" aria-modal="true">${content}</div></div>`.s;
  const close = () => { root.innerHTML = ""; };
  root.querySelector(".modal-backdrop").addEventListener("click", (e) => { if (e.target.classList.contains("modal-backdrop")) close(); });
  document.addEventListener("keydown", function onKey(e) { if (e.key === "Escape") { close(); document.removeEventListener("keydown", onKey); } });
  onMount?.(root.querySelector(".modal"), close);
  return close;
}

export function prompt(title, { value = "", placeholder = "", ok = "Save" } = {}) {
  return new Promise((resolve) => {
    let done = false;
    const close = modal(html`<h3>${title}</h3><form><input class="input" name="v" value="${value}" placeholder="${placeholder}" autofocus>
      <div class="row" style="justify-content:flex-end;margin-top:16px"><button type="button" class="btn ghost" data-cancel>Cancel</button><button class="btn primary">${ok}</button></div></form>`, {
      onMount(m) {
        const input = m.querySelector("input");
        input.focus(); input.select();
        m.querySelector("form").addEventListener("submit", (e) => { e.preventDefault(); done = true; close(); resolve(input.value.trim()); });
        m.querySelector("[data-cancel]").addEventListener("click", () => { close(); resolve(null); });
      },
    });
    const obs = new MutationObserver(() => { if (!$("#modal-root").children.length) { obs.disconnect(); if (!done) resolve(null); } });
    obs.observe($("#modal-root"), { childList: true });
  });
}

export function confirmDialog(title, message, ok = "Delete") {
  return new Promise((resolve) => {
    const close = modal(html`<h3>${title}</h3><p class="muted">${message}</p>
      <div class="row" style="justify-content:flex-end"><button class="btn ghost" data-no>Cancel</button><button class="btn danger" data-yes>${ok}</button></div>`, {
      onMount(m) {
        m.querySelector("[data-no]").onclick = () => { close(); resolve(false); };
        m.querySelector("[data-yes]").onclick = () => { close(); resolve(true); };
      },
    });
  });
}

export const empty = (ic, title, msg = "", action = "") =>
  html`<div class="empty">${icon(ic)}<h3>${title}</h3>${msg ? html`<p>${msg}</p>` : ""}${action}</div>`;

export const skeletonGrid = (n = 6) =>
  html`<div class="grid">${Array.from({ length: n }, () => html`<div class="card"><div class="skeleton" style="aspect-ratio:1"></div><div class="skeleton" style="height:14px;margin-top:10px"></div></div>`)}</div>`;

export function debounce(fn, ms = 300) {
  let t;
  return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
}

export function setRangeFill(input) {
  const pct = ((input.value - input.min) / (input.max - input.min)) * 100;
  input.style.setProperty("--fill", `${pct}%`);
}
