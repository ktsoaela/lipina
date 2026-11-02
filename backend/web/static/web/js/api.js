// REST client with JWT refresh. GET responses are cached by the service worker,
// so pages you've visited keep working offline.
import { db } from "./db.js";

const store = {
  get access() { return localStorage.getItem("lipina.access"); },
  get refresh() { return localStorage.getItem("lipina.refresh"); },
  save(access, refresh) {
    access ? localStorage.setItem("lipina.access", access) : localStorage.removeItem("lipina.access");
    refresh ? localStorage.setItem("lipina.refresh", refresh) : localStorage.removeItem("lipina.refresh");
  },
};

export class ApiError extends Error {
  constructor(message, status, data) { super(message); this.status = status; this.data = data; }
}

let refreshing = null;
async function refreshToken() {
  refreshing ??= (async () => {
    try {
      const r = await fetch("/api/auth/token/refresh/", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ refresh: store.refresh }),
      });
      if (!r.ok) throw new Error("refresh failed");
      const d = await r.json();
      store.save(d.access, d.refresh || store.refresh);
      return true;
    } catch {
      if (navigator.onLine) { store.save(null, null); window.dispatchEvent(new Event("lipina:logout")); }
      return false;
    } finally { setTimeout(() => { refreshing = null; }); }
  })();
  return refreshing;
}

function errorMessage(data, status) {
  if (!data) return status === 0 ? "You're offline" : `Request failed (${status})`;
  if (data.detail) return data.detail;
  const first = Object.entries(data)[0];
  if (!first) return `Request failed (${status})`;
  const [k, v] = first;
  return `${k === "non_field_errors" ? "" : k + ": "}${Array.isArray(v) ? v[0] : v}`;
}

export async function request(path, { method = "GET", body, query, raw = false, auth = true, signal } = {}) {
  const url = new URL(path, location.origin);
  if (query) Object.entries(query).forEach(([k, v]) => v != null && v !== "" && url.searchParams.set(k, v));
  const doFetch = () => {
    const headers = {};
    if (auth && store.access) headers.Authorization = `Bearer ${store.access}`;
    let payload = body;
    if (body && !(body instanceof FormData)) { headers["Content-Type"] = "application/json"; payload = JSON.stringify(body); }
    return fetch(url, { method, headers, body: payload, signal });
  };
  let res;
  try {
    res = await doFetch();
  } catch (e) {
    if (e.name === "AbortError") throw e;
    throw new ApiError("You're offline", 0);
  }
  if (res.status === 401 && auth && store.refresh && (await refreshToken())) res = await doFetch();
  if (raw) return res;
  const text = await res.text();
  const data = text ? (() => { try { return JSON.parse(text); } catch { return null; } })() : null;
  if (!res.ok) throw new ApiError(errorMessage(data, res.status), res.status, data);
  return data;
}

export const api = {
  get: (p, query, opts) => request(p, { query, ...opts }),
  post: (p, body) => request(p, { method: "POST", body }),
  put: (p, body) => request(p, { method: "PUT", body }),
  patch: (p, body) => request(p, { method: "PATCH", body }),
  del: (p) => request(p, { method: "DELETE" }),
  list: async (p, query) => { const d = await request(p, { query }); return Array.isArray(d) ? d : d?.results ?? []; },

  /** Upload with progress (fetch has no upload progress, so XHR). */
  upload(path, formData, onProgress) {
    return new Promise((resolve, reject) => {
      const send = (retry) => {
        const xhr = new XMLHttpRequest();
        xhr.open("POST", path);
        if (store.access) xhr.setRequestHeader("Authorization", `Bearer ${store.access}`);
        xhr.upload.onprogress = (e) => e.lengthComputable && onProgress?.(e.loaded / e.total);
        xhr.onload = async () => {
          if (xhr.status === 401 && retry && (await refreshToken())) return send(false);
          let data = null;
          try { data = JSON.parse(xhr.responseText); } catch { /* empty */ }
          xhr.status < 300 || (xhr.status === 400 && data?.tracks) ? resolve(data) : reject(new ApiError(errorMessage(data, xhr.status), xhr.status, data));
        };
        xhr.onerror = () => reject(new ApiError("Upload failed — check your connection", 0));
        xhr.send(formData);
      };
      send(true);
    });
  },

  /** Queue a write for later replay (idempotent server-side via client_id). */
  async enqueue(path, body) {
    const id = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    await db.put("outbox", { id, path, body: { ...body, client_id: id } });
    if (navigator.onLine) flushOutbox();
  },
};

let flushing = false;
export async function flushOutbox() {
  if (flushing || !store.refresh) return;
  flushing = true;
  try {
    for (const item of await db.all("outbox")) {
      try {
        await api.post(item.path, item.body);
        await db.del("outbox", item.id);
      } catch (e) {
        if (e.status === 0) break; // still offline
        await db.del("outbox", item.id); // permanent rejection
      }
    }
  } finally { flushing = false; }
}

export const auth = {
  get loggedIn() { return !!store.refresh; },
  user: null,
  async login(username, password) {
    const d = await request("/api/auth/token/", { method: "POST", body: { username, password }, auth: false });
    store.save(d.access, d.refresh);
    await this.loadMe();
  },
  async register(username, email, password) {
    const d = await request("/api/auth/register/", { method: "POST", body: { username, email, password }, auth: false });
    store.save(d.access, d.refresh);
    this.user = d.user;
    localStorage.setItem("lipina.me", JSON.stringify(d.user));
  },
  async loadMe() {
    try {
      this.user = await api.get("/api/auth/me/");
      localStorage.setItem("lipina.me", JSON.stringify(this.user));
    } catch (e) {
      if (e.status !== 0) throw e;
      this.user = JSON.parse(localStorage.getItem("lipina.me") || "null"); // offline: cached profile
    }
    return this.user;
  },
  logout() {
    store.save(null, null);
    localStorage.removeItem("lipina.me");
    this.user = null;
    caches?.delete("lipina-api").catch(() => {});
  },
};
